---
title: "The Parallelism Inside a Word: SWAR Arithmetic, Broadword Masks, and Bit-Sliced Execution"
description: "Bit-level parallelism is the cheapest parallelism a system has: no threads, no locks, no cache traffic. This installment builds a correct mental model and a provably correct primitive ladder — guard bits, nonzero-byte masks, wrapping byte addition, and branch-free selection — and explains the taxes that decide when SWAR beats SIMD."
date: "2026-08-20"
author: "Leonardo Benicio"
tags: ["bit manipulation","parallel computing","SWAR","broadword algorithms","performance engineering","data structures"]
categories: ["Computer Science","Parallel Computing"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/the-parallelism-inside-a-word-swar-arithmetic-broadword-masks-and-bit-sliced-execution-2026-08-20.jpg"
coverAlt: "Abstract macro image of a glowing silicon surface with sixty-four thin vertical light channels in a row, some lit and some dark, connected by faint amber arcs that suggest carries moving between adjacent channels."
---

Every 64-bit general-purpose register is a 64-lane SIMD machine. It has no instruction set documentation that calls it that, no compiler intrinsic that admits it, and no name in the architecture manual, but the lanes are there: 64 independent one-bit operations per instruction, or 8 independent eight-bit operations, or 4 sixteen-bit operations, all executed by the same ALU with the same latency and the same power budget as a single scalar add. The catch is that the hardware performs carry propagation across the whole word, and carry propagation is exactly what destroys lane independence. Everything interesting in bit-parallel programming is a technique for preventing, absorbing, or exploiting that carry.

That is the whole subject in one sentence, and it is why the field has the character it does. There is no scheduler, no synchronization, no coherence traffic, and no false sharing. There is only arithmetic designed so that lanes cannot interfere, and the discipline of proving that they cannot. When it works, a single `AND` does the work of sixty-four branches. When it fails, it fails silently and produces plausible-looking numbers, which is why the field rewards the kind of person who writes down the maximum value of an intermediate before trusting the code.

This article is about bit-level parallelism as a first-class engineering technique rather than a bag of party tricks. We will build the primitive ladder from the bottom — carry-free addition, exact per-byte masks, branch-free selection — with proofs short enough to check by hand. Later sections take the machinery into the places where it actually pays: broadword rank and select over compressed bitvectors, bit-parallel string matching and NFA simulation, bit-sliced column stores, and bitset graph traversal. The recurring theme is a cost model: bit-parallelism is not free, it is *prepaid*, and the price is paid in extra ops, narrowed lanes, and expensive extraction.

## Bit lanes are the cheapest parallelism you own

It helps to place bit-level parallelism on the same axis as the other kinds, because the placement explains the economics.

Thread-level parallelism gives you independent instruction streams, but each one costs a stack, a scheduler slot, cache footprint, and synchronization wherever the streams touch shared state. Data-level parallelism via SIMD gives you 16 or 32 or 64 lanes per instruction with real lane granularity — byte compares, byte shuffles, per-lane shifts — but the lanes are wide enough that bit-dense data wastes most of the register. Bit-level parallelism gives you lanes one bit wide. It has zero startup cost, zero communication cost, and zero scheduling cost. What it lacks is *expressiveness per lane*: there are no per-lane shifts, no per-lane variable shifts at all, no cheap cross-lane permutation, and comparisons are only available insofar as you can synthesize them.

The naming is worth fixing because the terms get used loosely.

**SWAR** — SIMD Within A Register — is the general technique of treating a word as a vector of sub-word lanes.

**Broadword programming** is Donald Knuth's term for the same idea used to manipulate bitvectors efficiently, and it carries a connotation of asymptotically meaningful algorithms rather than fixed-width hacks: broadword rank and select, broadword predecessor search, broadword search in compressed text.

**Bit-slicing** is the transposed layout: instead of packing many small values into one word, you store one bit-plane of many values per word, so that a single instruction advances 64 values in lockstep. Bit-sliced layouts are what make software implementations of ciphers (the classic bitsliced DES) and bit-parallel query execution viable.

These are the same arithmetic seen from three angles, and they compose. A bit-sliced index over a column of machine words is itself a bitvector, so rank and select over that index is broadword, and the masking inside it is SWAR.

The reason this matters to systems engineers rather than only to compiler writers is that the data structures with the best memory density are already bit-dense. Bloom and cuckoo filter arrays, roaring bitmaps, learned index fences, wavelet trees, succinct hash tables, and bitmap join indexes all represent state as bits. If you widen those bits to bytes so that ordinary SIMD compares can touch them, you have multiplied your memory traffic by eight to reach an instruction that was never the bottleneck. The winning move is usually to keep the bits and pay the SWAR tax in ALU ops, because ALU ops are what modern cores have in surplus.

## A cost model for bit-parallel kernels

Before writing any code, it is worth being explicit about where SWAR kernels spend their time, because the naive intuition — "64 operations per instruction, therefore 64x" — is wrong in a specific and instructive way.

A SWAR kernel pays three taxes.

**The guard-bit tax.** Lanes interfere through carries and borrows. To prevent that you either narrow the lanes (use 7 bits of each byte, leaving one guard bit) or add fix-up ops that fold the carry back into the right place. Narrowing costs a bit of range per lane; fix-ups cost instructions. Neither is free, and the choice between them is the main design decision in any SWAR routine.

**The compaction tax.** Producing a mask is cheap. Turning a mask into something a program can branch on, iterate over, or use as an index is not. On hardware with BMI2's `PEXT` and `PDEP` this is one instruction; without them it is a `ctz` loop whose cost scales with the number of set bits. Any SWAR design whose output is a large mask must budget for extraction, or it will lose to the byte-oriented version it was meant to replace.

**The dependency tax.** A word-at-a-time kernel is a single serial recurrence unless you unroll it. `nz8` below has a three-instruction dependency chain, which at four cycles of latency and three ALU ports means you need roughly a dozen independent words in flight to saturate the machine. This is not different from any other latency-bound loop, but it is more visible here because the loop bodies are so short that the compiler's scheduling decisions dominate the measured throughput.

Against those taxes, SWAR buys two things. First, lane count: at 64 lanes per word, the per-lane cost of the loop overhead, the load, and the store rounds to nothing. Second, and underrated, *predictability*: no branches, no partial-register stalls, no vector-width-dependent code paths, and no downclocking. A branch-free SWAR kernel has a data-independent instruction trace, which is also why it turns up in constant-time cryptographic code.

The practical corollary is that SWAR wins where the work per word of input is small and uniform — popcount, membership tests, bitvector intersections, sparse filtering — and loses where the per-word work is large or irregular, such as sorting, permutation, or anything that needs a variable shift per lane. Those are jobs for real SIMD, which has the permutes and per-lane shifts that SWAR cannot synthesize cheaply.

## The primitive ladder

Everything downstream rests on four primitives. The code below is written for 64-bit unsigned words; the same constants generalize to any word width, and the reasoning does not change. All shifts are on unsigned values, so they are logical, and the word size is assumed to be 64 throughout.

```c
#include <stdint.h>

#define ONES 0x0101010101010101ULL
#define HIGH 0x8080808080808080ULL
#define LOW7 0x7F7F7F7F7F7F7F7FULL
```

### 1. Exact per-byte nonzero mask

The goal is a word whose bit 7 is set in exactly those bytes of `v` that are nonzero. The trap is that the classic zero-byte test, `(v - ONES) & ~v & HIGH`, tells you only *whether some* byte is zero. It is not a per-byte mask, because subtracting one from a zero byte borrows from its neighbor and corrupts the answer for that neighbor. Using it as a mask is one of the most common bugs in hand-written bit code.

The correct construction exploits the fact that a maximal 7-bit value plus 0x7F cannot carry out of its byte:

```c
static inline uint64_t nz8(uint64_t v) {
    uint64_t lo = (v & LOW7) + LOW7;   /* no cross-byte carry: max 0x7F + 0x7F = 0xFE */
    return (lo | v) & HIGH;            /* bit 7 set iff low7 != 0 or the high bit is set */
}
```

The proof is one line per lane. Masking with `LOW7` leaves each byte at most 0x7F. Adding 0x7F to a value in [0, 0x7F] yields [0x7F, 0xFE], which never exceeds 0xFF, so no lane can carry into its neighbor and whole-word addition is exactly per-byte addition. Within a lane, the sum's bit 7 is set precisely when the masked value was at least 1. OR-ing the original `v` reintroduces the original high bit, and the final mask keeps bit 7 of each lane. A byte is nonzero iff its low 7 bits are nonzero or its high bit is set.

### 2. Exact per-byte equality mask

Equality is nonzero-ness on the XOR:

```c
static inline uint64_t eq8(uint64_t a, uint64_t b) {
    return ~nz8(a ^ b) & HIGH;   /* bit 7 set in lanes where a and b agree */
}
```

This is where the difference from the zero-byte test becomes visible. `nz8` gives a genuine per-lane truth value, so its complement is a genuine per-lane equality mask, and it can be widened into something usable for selection.

### 3. Wrapping per-byte addition

Addition with full 8-bit lanes cannot avoid carries by masking, because a legitimate lane result can exceed 0xFF. What it can do is separate the low-bit contribution from the high-bit contribution and recombine them with XOR, which is addition without carry:

```c
static inline uint64_t add8(uint64_t x, uint64_t y) {
    return ((x & LOW7) + (y & LOW7)) ^ ((x ^ y) & HIGH);
}
```

Per lane, write `x = 128*xh + xl` and `y = 128*yh + yl` with `xh, yh` in {0,1} and `xl, yl` in [0,127]. The masked sum `s = xl + yl` lies in [0, 0xFE], so it does not carry out of its byte; it contributes `s mod 128` to the low bits and its own bit 7 to the high-bit position. The true wrapping sum's high bit is `(bit7(s) + xh + yh) mod 2`, and `(x ^ y) & HIGH` supplies exactly `xh XOR yh`. XOR-ing the two gives the correct high bit while leaving the low seven bits untouched. Two lanes' worth of examples are enough to make it concrete: `0xFF + 0x01` gives `s = 0x80`, high bit `1 XOR 1 XOR 0 = 0`, result `0x00`, as wrapping arithmetic requires; `0x7F + 0x7F` gives `s = 0xFE`, high bit `1 XOR 0 XOR 0 = 1`, result `0xFE`.

That is a complete byte-wise adder in three ALU ops plus the mask constants, versus eight scalar adds. It is also a template: the pattern of "compute the carry-free part, compute the carry information separately, recombine with XOR" recurs in SWAR subtraction, saturating arithmetic, and average-without-overflow (`(x & y) + (((x ^ y) >> 1) & LOW7)` on 7-bit lanes, which is worth deriving yourself as an exercise).

### 4. Widening a high-bit mask and selecting

Masks arrive as bit 7 per lane; selection needs a full-byte mask. The multiply-by-0xFF idiom is popular and subtly broken in the top lane, where the intermediate `v << 8` wraps out of the 64-bit word. An arithmetic identity avoids the problem entirely:

```c
static inline uint64_t widen(uint64_t m) {
    /* m has only bit 7 set per lane; produce 0xFF in those lanes */
    return m | (m - (m >> 7));
}
```

In each selected lane, subtracting 0x01 from 0x80 yields 0x7F with no borrow, since 0x80 ≥ 0x01; OR-ing the original 0x80 recovers 0xFF. In each unselected lane, the subtraction leaves 0x00 and the OR leaves 0x00, and again no borrow crosses lanes. Selection is then the ordinary masked blend:

```c
static inline uint64_t select8(uint64_t a, uint64_t b, uint64_t mask_high) {
    uint64_t m = widen(mask_high);
    return (a & ~m) | (b & m);
}
```

Four instructions, no branches, no data-dependent control flow, and correct for all 256 values in every lane. Byte-wise min and max, saturating add, and clamp all follow from `add8` plus this blend; the only thing that does not follow easily is *ordering*, because unsigned less-than needs the high bit of each lane evaluated as a separate bit-plane, then the low seven bits compared under a bias that guarantees no borrow. That derivation is worth doing carefully rather than by pattern matching, and we will do it where the payoff is largest.

Notice what the ladder is really constructing: a small, total, and checkable algebra over lanes, in which every operation carries a precondition about the range of its inputs and a one-line argument about why carries cannot escape. That algebra is the difference between code that works on the test data and code that works.

The masks are now in hand, and the arithmetic is sound. What remains is the part where bit-parallel code either becomes twenty times faster or stays a curiosity: what you do with a mask once you have sixty-four of them at once.

## Consuming the mask: rank, select, and the extraction tax

A mask is not a result. It is a promise that some lanes are interesting, encoded in the only form the ALU can produce cheaply. The moment a program needs to know *which* lanes, or needs to turn those lanes into addresses, indices, or iteration counts, the bit-parallel advantage starts to leak away. The leak is not a bug; it is the compaction tax from the cost model, and it is the single most common reason a hand-written SWAR routine loses to a plain byte loop on real data.

The cheapest consumer of a mask is another word-level operation. If the mask can stay in a register and be combined with other masks, there is no tax at all. This is why the most successful SWAR kernels are pipelines: load a word, compute a mask, combine it with an accumulator, move on. A membership filter over a Bloom filter array is the canonical example. The array is a bitvector; a query hashes to `k` bit positions; the kernel tests those positions by loading the containing words, shifting to align the bits, and AND-ing them into a running result. No lane is ever extracted. The answer is a single bit at the end, and the cost is a handful of ALU ops per hash. The same shape appears in bitmap join indexes, in sparse dot products over bitvectors, and in bit-parallel NFA simulation, where the state set is a bitvector and each input symbol advances all states at once.

The tax begins when the mask must become control flow. The standard idiom is the count-trailing-zeros loop:

```c
uint64_t m = nz8(v);
while (m) {
    int bit = __builtin_ctzll(m);
    int byte = bit >> 3;
    /* process lane `byte` */
    m &= m - 1;              /* clear lowest set bit */
}
```

This is compact and correct, and for sparse masks it is often the right answer. Its cost is proportional to the number of set bits, not the number of lanes. Each iteration has a `ctz`, a decrement-and-AND, a branch, and whatever work the lane requires. If the mask has one bit set out of sixty-four, the loop is nearly free. If it has thirty-two, the loop is thirty-two branches, thirty-two dependent `ctz` operations, and thirty-two unpredictable control transfers. At that point the branch-free alternative — process all sixty-four lanes with `select8` and let the mask decide — is usually faster, even though it does eight times as much arithmetic. The crossover is data-dependent and worth measuring, but the rule of thumb is that iteration wins below roughly one set bit per eight lanes, and branch-free blending wins above it.

When the mask is dense and the work per lane is a simple update, the right move is to keep the mask as a mask and use it to select between two whole-word results. The `select8` primitive from the ladder does exactly this. Suppose a kernel needs to add a per-lane increment only where a predicate holds. The branch-free form is:

```c
uint64_t pred = eq8(x, y);          /* high-bit mask */
uint64_t inc  = 0x0101010101010101ULL;
uint64_t sum  = add8(acc, inc);
acc = select8(acc, sum, pred);
```

There is no branch, no extraction, and no per-lane loop. The predicate is computed for all lanes at once, and the blend applies it to all lanes at once. This is the pattern that makes SWAR kernels predictable: the instruction trace is independent of the data, which is why the same shape appears in constant-time cryptography and in branch-predictor-hostile query execution.

Extraction has its own hardware story. On x86-64 with BMI2, `PEXT` extracts a bit field from a word and compacts it to the low bits, and `PDEP` does the reverse. With `PEXT`, turning a mask into a list of indices is a single instruction per word: extract the mask bits, then use the compacted result as an offset into a lookup table or as a vector index. Without BMI2, the same operation is a `ctz` loop, and the cost is again proportional to the number of set bits. This is a place where the ISA matters more than the algorithm. A SWAR design that assumes `PEXT` will be fast on one machine and disappointing on another, and the portable fallback is the loop. The lesson is not that `PEXT` is magic; it is that the compaction tax is real enough that hardware architects added an instruction to reduce it.

Rank and select are the broadword primitives that turn masks into indices without a loop. Rank answers "how many set bits are there before position i?" and select answers "where is the k-th set bit?" They are the inverse pair that makes succinct data structures possible: a bitvector of length n can answer rank in O(1) with a small number of precomputed superblock counts, and select in O(log n) with a binary search over those counts, or in O(1) with a more elaborate directory. Inside a single 64-bit word, both operations are pure SWAR. Rank is `__builtin_popcountll(w)`, which is a single instruction on most modern cores and a handful of SWAR ops otherwise. Select is a binary search over the word using popcounts of masked halves:

```c
static inline int select64(uint64_t w, int k) {
    int pos = 0;
    uint32_t lo = (uint32_t)w;
    int c = __builtin_popcount(lo);
    int hi = (k >= c);
    w = hi ? (w >> 32) : w;
    pos += hi << 5;
    k -= hi ? c : 0;
    /* repeat for 16, 8, 4, 2, 1 */
    return pos;
}
```

The branches can be replaced with conditional moves, and the whole routine is a fixed sequence of shifts, popcounts, and adds. It is not the fastest possible select — the fastest uses multiplication to broadcast a byte count into a mask — but it is the clearest, and it shows the shape of the cost: select within a word is O(log word) popcounts, which is six popcounts for a 64-bit word. That is cheap enough that broadword rank and select over a compressed bitvector often beats a byte-oriented scan by a wide margin, even after the extraction tax is paid.

The practical summary of this section is that a mask should be consumed at the highest level of abstraction the algorithm allows. If the answer is a bit, keep it a bit. If the answer is a blend, use `select8`. If the answer is a list of indices, use `PEXT` if you have it, and a `ctz` loop if you do not. Only when the algorithm genuinely needs per-lane control flow should the mask become a branch, and even then the branch should be over a word's worth of lanes, not over a single lane.

## Bit-sliced execution: one instruction, sixty-four rows

The primitive ladder and the mask consumers are all SWAR in the original sense: many small lanes packed into one word, with carries suppressed by guard bits or fix-ups. Bit-slicing is the same idea taken to its logical conclusion. Instead of packing many values into one word and trying to keep their arithmetic independent, you transpose the layout so that each bit position of many values lives in its own word. The lanes are no longer sub-word fields; they are the bits of the word itself, and the operations are the ordinary bitwise operations that have no carries at all.

The canonical layout is a column of 64 values, each `b` bits wide. The bit-sliced representation is `b` words. Word `i` holds bit `i` of all 64 values, with value `j` contributing bit `j` of that word. A bitwise AND of two such words computes the AND of bit `i` across all 64 values simultaneously. A bitwise XOR computes XOR. There is no masking, no guard bit, and no carry propagation, because each word is a single bit-plane and the hardware's bitwise operations are already lane-independent at the bit level. This is the purest form of bit-level parallelism: 64 lanes per instruction, with no arithmetic tax at all for the bitwise operations.

The tax moves to the operations that are not bitwise. Addition, comparison, and shifting all require carrying information from one bit-plane to the next, and that carrying is done explicitly in software. A bit-sliced ripple-carry adder for two `b`-bit vectors is a loop over bit-planes:

```c
/* A[i], B[i] are bit-planes; S[i] is the sum, C is the carry */
uint64_t carry = 0;
for (int i = 0; i < b; ++i) {
    uint64_t a = A[i], b = B[i];
    S[i] = a ^ b ^ carry;
    carry = (a & b) | (carry & (a ^ b));
}
```

Each iteration is five bitwise ops and advances all 64 additions by one bit. For `b = 8`, that is 40 instructions to add 64 pairs of 8-bit numbers. A scalar loop would execute 64 adds, plus loads and stores. The bit-sliced version is not just fewer instructions; it is a fixed, branch-free sequence with no per-lane indexing. For `b = 4`, it is 20 instructions for 64 additions. For `b = 64`, it is 320 instructions for 64 additions, which is worse than scalar, and that is the key trade-off: bit-slicing wins when the values are narrow, and loses when they are wide. The crossover is around 8 to 16 bits on most machines, depending on how well the scalar loop is optimized.

Comparison is the other primitive that bit-slicing handles well. Unsigned less-than between two bit-sliced vectors is a scan from the most significant bit-plane down, maintaining a mask of lanes that are still equal:

```c
uint64_t lt = 0, eq = ~0ULL;
for (int i = b - 1; i >= 0; --i) {
    uint64_t a = A[i], b = B[i];
    lt |= eq & ~a & b;   /* a=0, b=1 at first differing bit */
    eq &= ~(a ^ b);
}
```

After the loop, `lt` has a 1 in every lane where `A < B`. This is four ops per bit-plane, so 32 ops for 64 comparisons of 8-bit values, versus 64 scalar comparisons. Again, the advantage comes from narrow values and from the fact that the result is a bitmask that can be combined with other predicates without branching. Range queries, filters, and joins over bit-sliced columns are built from exactly this pattern: compute a mask for `x >= lo`, a mask for `x <= hi`, AND them together, and use the result to select rows. The entire query is a sequence of bitwise operations over bit-planes, with no per-row control flow.

The cost that bit-slicing does not eliminate is transposition. Data usually arrives in row-major form, and turning a block of 64 rows into `b` bit-planes requires a bit-matrix transpose. For 8-bit values, that is an 8x64 transpose, which can be done with SWAR masks and shifts in a few dozen instructions. The classic 8x8 transpose uses three stages of masks and shifts, and the 64-bit version extends it by treating the 64 rows as eight groups of eight. The transpose is not free, but it is amortized: if the data is stored bit-sliced and queried many times, the transpose cost is paid once and the query cost is paid per query. This is why bit-sliced column stores and bitmap indexes are attractive for read-heavy analytical workloads. The storage is compact, the scans are branch-free, and the predicates compose with bitwise AND, OR, and NOT.

Bit-slicing also changes the economics of memory traffic. A bit-sliced column of 8-bit values uses exactly one bit per value per bit-plane, which is the same total memory as the row-major 8-bit column. But a query that touches only the high bit-plane — for example, a filter for values above 127 — reads only one-eighth of the column. In a row-major layout, the same filter reads every byte and discards the low seven bits. This is the same argument that makes column stores fast, pushed down to the bit level. The cost is that the bit-planes must be stored separately, and that updates are more expensive because a single row update touches `b` different words. For append-only or read-mostly data, the trade is usually worth it.

The connection back to SWAR is direct. The `nz8` and `eq8` primitives are SWAR because they pack eight byte-lanes into a word and use guard bits to keep carries from crossing. A bit-sliced representation is what you get if you take that packing to its limit: instead of eight lanes of eight bits, you have sixty-four lanes of one bit, and the guard-bit problem disappears because there is no arithmetic within the word. The two techniques are not alternatives; they are points on a spectrum. SWAR is better when the data is already byte-oriented and the operations are arithmetic. Bit-slicing is better when the data is narrow, the operations are bitwise or comparison-heavy, and the layout can be chosen in advance. A system that understands both can choose the representation per column, per query, or even per operator, and that choice is often worth more than any single instruction-level optimization.

The next question is how these representations interact with real SIMD. A bit-sliced word is already a vector of 64 bits, and a SIMD register is a vector of 128 or 256 or 512 bits. The obvious move is to widen the bit-plane to the full vector width, which multiplies the lane count by the vector width and keeps the same bitwise operations. That works, and it is the basis of many high-performance bitmap indexes. But it also reintroduces the taxes that SWAR avoids: wider registers have their own load/store costs, and the compiler may or may not keep the bit-planes in registers across a loop. The decision between SWAR and SIMD is therefore not about lane count alone; it is about whether the kernel can keep its working set in registers and whether the extraction and transposition costs can be amortized. We will take that decision apart next.

## The SWAR–SIMD boundary is a register-pressure boundary

The previous section ended with a promise to take apart the choice between SWAR and SIMD. The first thing to say is that lane count is not the deciding factor. A 512-bit vector register holds 512 one-bit lanes, eight times as many as a 64-bit general-purpose register. If lane count were the only metric, SIMD would always win. It does not, because a kernel's throughput is usually limited by something other than the number of lanes in a single instruction: register pressure, domain crossings, memory bandwidth, or the cost of turning a mask into control flow.

Start with the register file. On x86-64, a SWAR kernel draws its words from the same sixteen general-purpose registers that hold pointers, loop counters, and addresses. Every live bitvector competes with the bookkeeping of the loop. A kernel that keeps eight 64-bit words in flight has already consumed half the register file before it has loaded a single pointer. SIMD kernels use a separate register file. On AVX-512 machines there are thirty-two vector registers, and they do not compete with scalar address arithmetic. That separation is a real advantage for kernels that need many live vectors, such as a bit-sliced query with several predicate masks in flight.

But the separate register file has a cost: moving data between the two domains. A vector compare produces a vector mask. To branch on it, to use it as an index, or to feed it to a `ctz` loop, the program must move that mask into a general-purpose register, usually with `movemask` or an equivalent. That instruction is not free. It has latency, it occupies a port, and it sits on the critical path whenever the mask immediately controls a branch. A SWAR kernel never pays this tax. Its mask is already a general-purpose register, ready for `tzcnt`, `blsr`, or an ordinary `test`. For sparse filters, where most words produce an empty mask and the loop skips them, this difference is often the whole story. The SWAR loop tests a register and branches; the SIMD loop computes a vector predicate, extracts a mask, tests the mask, and branches. The extra extraction is small in isolation, but it repeats for every word or vector of input.

SIMD earns its place when the algorithm needs operations that SWAR cannot synthesize cheaply. Per-lane variable shifts are the clearest example. A SWAR kernel can shift every lane by the same amount, but shifting each byte by a different amount requires a sequence of masks and fix-ups that grows with the number of distinct shift amounts. SIMD has `vpsllvd` and `vpsrlvd`, which do it in one instruction. Byte shuffles are another: `vpshufb` permutes bytes within a vector according to a control vector, and SWAR has no comparable primitive. Gathers, scatters, and wide byte compares are in the same category. If the kernel is dominated by these operations, the domain-crossing tax is irrelevant because the alternative is not a few extra instructions; it is an algorithm that cannot be expressed efficiently at all.

Memory bandwidth complicates the comparison further. A 512-bit load moves eight times as much data as a 64-bit load, but it does not necessarily do so in one cycle. On many cores, a 512-bit load is split into two 256-bit operations, and the L1 data cache delivers a fixed number of bytes per cycle regardless of the instruction width. If the kernel is streaming through a large bitvector, both SWAR and SIMD will be limited by the cache or by DRAM. The lane count only matters when the data is already resident in registers or in L1 and the ALU is the bottleneck. That is precisely the regime where SWAR is most competitive, because a 64-bit word that is already in a general-purpose register costs nothing to keep there.

There is also the matter of frequency. On some server processors, sustained 512-bit AVX-512 workloads reduce the core clock, which slows down every other instruction in the loop, including the scalar address arithmetic and the branch logic. SWAR never triggers this. A SWAR kernel runs at the same frequency as the surrounding scalar code, which makes its performance more predictable and easier to reason about. Predictability is not a minor virtue in a library that must run well on many microarchitectures.

The practical decision rule has four clauses. Use SWAR when the data is bit-dense and already in general-purpose registers; when the operations are bitwise, addition, comparison, or popcount; when the masks feed control flow or scalar indices; and when portability across instruction sets matters. Use SIMD when the data is byte- or word-oriented and arrives from memory; when the algorithm needs per-lane shifts, shuffles, gathers, or wide byte compares; when masks can stay in vector registers for blending; and when the domain crossings can be amortized over enough work. The clauses are not mutually exclusive. The best kernels are often hybrids: SIMD for the bulk load and the byte-wise predicate, `movemask` to collapse the vector mask into a 64-bit word, then SWAR and broadword operations to rank, select, and iterate over the result. That hybrid shape appears in high-performance bitmap indexes, in bit-sliced query engines, and in string-matching kernels that use SIMD to find candidate positions and SWAR to verify them.

The cost model from earlier still applies, but the taxes are different. SWAR pays in guard bits, compaction, and dependency chains. SIMD pays in domain crossings, alignment requirements, frequency effects, and code that is tied to a vector width. Neither set of taxes is universally smaller. The engineering question is which tax the kernel can hide. A long dependency chain can be hidden by unrolling and interleaving independent words. A domain crossing can be hidden by processing several vectors before extracting a mask. A guard-bit tax cannot be hidden; it is a permanent reduction in lane range. That asymmetry is why SWAR remains the right default for bit-dense data even on machines with wide vectors.

## Broadword rank and select over compressed bitvectors

Compressed bitvectors are where broadword programming stops being a curiosity and becomes the only way to make the data structure work. A roaring bitmap, an Elias-Fano sequence, a wavelet tree, and a succinct hash table all store their state as bits, and all of them need to answer rank and select without decompressing the whole structure. Rank asks how many ones appear before a given position. Select asks where the k-th one is. Both operations are the interface through which the compressed representation is navigated, and both are built from the same primitive ladder.

Rank inside a single 64-bit word is `popcount`. Rank over a longer bitvector is a hierarchy of popcounts. The standard layout stores a cumulative count every 512 bits, a second-level count every 64 bits, and then the word itself. A rank query at position i loads one superblock count, one block count, and one word, masks off the bits above i, and adds three popcounts. That is a handful of instructions and two or three cache lines, and it is O(1) regardless of the length of the bitvector. The broadword part is the masking: to count bits below position i within a word, the kernel computes `w & ((1ULL << (i & 63)) - 1)` and popcounts the result. The shift and subtract are exact because the shift amount is less than 64. No guard bit is needed because the operation is bitwise, not arithmetic.

Select is harder, and it is where the extraction tax returns. To find the k-th one, the kernel must locate the block that contains it and then locate the bit within that block. The block search can be a binary search over the cumulative counts, which is O(log n) branches, or it can be a broadword search over packed counts. The packed-count approach is the interesting one. Suppose the kernel has eight 8-bit counts packed into a 64-bit word, each count being the number of ones in a 64-bit block. To find the block containing the k-th one, it broadcasts k into every byte, subtracts the packed counts, and looks for the first byte that borrows. The borrow pattern is a high-bit mask, and `ctz` on that mask gives the block index. This is a SWAR operation in the purest sense: eight independent comparisons in one subtraction, with the borrow serving as the comparison result. It replaces a branchy binary search with a fixed sequence of arithmetic and a single `ctz`.

Once the block is known, select within the block is the `select64` routine from the mask-consuming section: a binary search over popcounts of masked halves. That routine is six popcounts deep, which is a dependency chain of roughly eighteen cycles on a typical core. For a query that performs many selects, that latency can dominate. The standard optimizations are to widen the search unit or to use a lookup table. A 16-bit chunk has 65,536 possible patterns, so a table of select results for each pattern is large but feasible, and it turns the inner search into one load and one add. A 8-bit chunk has only 256 patterns, and a table of 256 bytes fits in L1, so the search becomes a sequence of byte-level lookups. The trade is memory for latency, and the right choice depends on how many selects the workload performs and how much cache pressure it can tolerate.

Broadword rank and select are not limited to static bitvectors. They are the engine inside dynamic succinct structures that support insertions and deletions by maintaining a hierarchy of counts and rebuilding small blocks. They are also the engine inside compressed text indexes, where select is used to map a position in a compressed string to a position in the original string. In every case, the pattern is the same: keep the data compressed, use broadword operations to navigate it, and pay the extraction tax only when a scalar index is actually needed. The alternative — expanding the bitvector to one byte per bit — multiplies memory traffic by eight and usually loses, even though the expanded form has cheaper per-bit operations.

The same broadword techniques give predecessor search. Given a sorted array of 8-bit values packed into a 64-bit word, the predecessor of a query value is the largest packed byte that is less than or equal to the query. A SWAR kernel can compute this with a sequence of comparisons and a `ctz` or `clz`, without unpacking the bytes. That operation is the inner loop of learned index fences and wavelet-tree navigation. It is also a reminder that the primitive ladder is not a fixed set of four functions; it is a method for deriving new comparisons and selections as the data structure requires them.

## Bit-sliced execution in practice: filters, joins, and the transpose budget

A bit-sliced column store takes the transposed layout seriously. Each column is stored as b bit-planes, where b is the bit width of the column. A filter predicate such as `x > c` is evaluated by comparing the bit-planes of x against the precomputed bit-planes of c. The comparison loop from the previous section produces a mask of rows where the predicate holds. A second predicate produces a second mask, and the conjunction is a single `AND`. The result is a bitmask of selected rows, one bit per row, and it is produced without branching on any row value. This is the bit-sliced equivalent of a vectorized filter, but it works on values as narrow as one bit and as wide as the bit-plane count allows.

Projection is where the mask must become data movement. If the mask is sparse, the kernel iterates over set bits with `ctz` and gathers the selected rows from the row-major payload. If the mask is dense, the kernel can use `PEXT` to compress each bit-plane. For a bit-sliced column, the selected bits of a bit-plane are extracted with `PEXT` and packed into a contiguous output word. Repeating that for each bit-plane produces a compact bit-sliced result. The operation is branch-free and processes 64 rows per instruction, but it depends on BMI2. Without `PEXT`, the fallback is a `ctz` loop, and the cost scales with the number of selected rows. That is the compaction tax in its purest form: the filter is cheap, but materializing the result is not.

Joins over bit-sliced data are built from bitmaps. A bitmap join index stores, for each value in a dimension, a bitmap of the fact rows that have that value. A join between two dimensions is the bitwise `AND` of their bitmaps. A range predicate on a dimension is a union of bitmaps, which is a bitwise `OR`. A bit-sliced column extends this to ranges without materializing a bitmap per value: the comparison loop produces the range mask directly, and the join is still a bitwise `AND`. The cost of the join is proportional to the number of rows divided by 64, not to the number of matching rows. That is the same asymptotic advantage that bitmap indexes have always had, but bit-slicing makes it work for narrow numeric columns without expanding them to one bitmap per distinct value.

The transpose budget is the price of admission. Data arrives row-major, and turning a block of 64 rows into b bit-planes requires a bit-matrix transpose. For 8-bit values, the transpose is an 8x64 operation. The standard algorithm treats the 64 rows as eight groups of eight. Each 8x8 block is transposed with three stages of masks and shifts. The masks are the familiar `0x00FF00FF00FF00FF`, `0x0F0F0F0F0F0F0F0F`, `0x3333333333333333`, and `0x5555555555555555`. Each stage swaps groups of bits between positions, and the three stages together move every bit to its transposed location. The whole 8x64 transpose costs roughly two hundred instructions for 64 rows, which is about three instructions per row. That is not free, but it is small compared to the cost of loading and storing the data, and it is paid once if the bit-sliced layout is persistent.

Amortization is the deciding factor. If the data is row-major and queried once, the transpose may cost more than the query saves. If the data is stored bit-sliced and queried many times, the transpose is a one-time ingest cost and the query cost is paid per query. This is the same trade that makes column stores attractive for analytical workloads, pushed down to the bit level. The bit-sliced layout also reduces memory traffic for predicates that touch only the high bit-planes. A filter for values above 127 reads only the most significant bit-plane, which is one-eighth of the column. A row-major layout reads every byte and discards the low seven bits. For wide columns, the savings are even larger.

Updates are the weak point. A single-row update in a bit-sliced column touches b different words, one per bit-plane. If the column is large, those words are scattered across memory, and the update becomes a random-access write pattern. The standard solution is a delta store: keep a small row-major buffer of recent updates and merge it into the bit-sliced base periodically. Queries consult both the base and the delta, which costs an extra comparison and an extra mask, but the merge is batched and sequential. This is the same architecture that column stores use for mutable data, and it preserves the read-optimized layout for the bulk of the data.

A practical bit-sliced query engine does not bit-slice everything. It bit-slices the columns that appear in predicates, because those are the columns that benefit from branch-free comparison and compact masks. It keeps the payload columns row-major, because projection and materialization are dominated by memory traffic rather than by arithmetic. The query plan is then a pipeline: evaluate bit-sliced predicates to produce a row mask, combine masks with bitwise operations, and use the final mask to gather payload rows. The gather is the expensive step, but it is proportional to the number of selected rows, not to the total number of rows. The bit-sliced predicates do the filtering work at 64 rows per instruction, and the row-major payload does the materialization work with ordinary loads.

That pipeline is also the clearest example of how the three techniques compose. The transpose is a SWAR kernel. The comparison is a bit-sliced kernel. The mask combination is broadword. The final gather is a `ctz` loop or a `PEXT`-based compaction. None of these pieces is exotic on its own, but together they turn a query that would otherwise be a sequence of unpredictable branches into a fixed instruction trace whose cost is predictable from the number of rows and the number of predicates. The next step is to measure that cost against the alternatives, because the decision to bit-slice a column is ultimately an empirical one: it depends on the query mix, the update rate, and the width of the data. The arithmetic is settled; the engineering is in the budget.

## Bit-parallel string matching and NFA simulation

String matching is a natural fit for bit-level parallelism because the state of a matcher is a set of positions in the pattern, and a set of positions is a bitvector. The simplest kernel is Shift-And. For a pattern of length m ≤ 64, precompute for each byte c a mask `B[c]` with bit i set when pattern[i] == c. Maintain a state word D where bit i is set when the prefix of length i+1 matches a suffix of the text read so far. The update is:

```c
D = ((D << 1) | 1) & B[c];
if (D & (1ULL << (m - 1))) { /* match ending here */ }
```

The shift moves each prefix match one position to the right; the OR with 1 starts a new match at the current position; the AND with B[c] keeps only positions whose pattern character equals c. The high-bit test is a mask test, not a branch on the text. The kernel is four instructions per input byte plus the load of B[c], and it is branch-free. For a pattern of length 64, it processes one byte per iteration; for shorter patterns, it still uses a full word. The cost is independent of m except for the final mask. This is why Shift-And beats a naive matcher for short patterns and why it is the inner loop of many intrusion-detection and DNA-scanning systems.

The first tax appears when m exceeds 64. A multiword matcher must shift the state across word boundaries. The carry from word i to word i+1 is the high bit of word i before the shift. The update for each word becomes:

```c
uint64_t carry = 1;
for (int w = 0; w < words; ++w) {
    uint64_t d = D[w];
    uint64_t next = (d << 1) | carry;
    carry = d >> 63;
    D[w] = next & B[c][w];
}
```

The `carry` is not arithmetic carry; it is the bit that falls off the top of the previous word. There is no guard bit and no borrow, because the shift is logical and the words are independent except for this explicit bit. The loop is a serial recurrence across words, which is the dependency tax in miniature. For long patterns, the matcher is latency-bound on the carry chain, and the usual fix is to process several text positions in parallel or to use a different algorithm for very long patterns. The bit-parallel advantage is largest when m is near 64 and the pattern fits in one or two words.

NFA simulation generalizes the same state representation. A Thompson NFA for a regular expression has a set of states; the active set is a bitvector. For each input symbol, the simulator computes the next active set by following the transitions labeled with that symbol and then taking the epsilon closure. The epsilon closure is a precomputed relation: for each state, a bitmask of states reachable by epsilon transitions. The per-symbol transition is a relation as well. If the NFA is small enough to fit in a few words, the active set and the transition masks are words, and the simulator can process one input symbol with a sequence of shifts, ANDs, and ORs. The exact sequence depends on the NFA representation. For a Glushkov NFA over pattern positions, the transition relation is encoded in follow masks and the update is a masked shift plus a union; for a Thompson NFA with arbitrary transitions, the kernel may need to iterate over active states and OR their destination masks. In both cases the active set stays a bitvector, and the cost is proportional to the number of words times the number of transition operations, not to the number of states visited one at a time. The win is the same as in Shift-And: the simulator advances all active states in lockstep, and the instruction trace is independent of which states are active.

The practical limit is the size of the NFA. A regular expression with a few hundred states needs several words per state set, and the transition relation may be dense. At that point the bit-parallel simulator becomes a sparse boolean matrix-vector multiply, and the cost model changes. The kernel must choose between iterating over active states and OR-ing destination masks, or precomputing a transition table for each character and each word. The first is better when the active set is sparse; the second is better when the active set is dense and the alphabet is small. This is the same sparse-versus-dense trade-off that appears in bitmap indexes and graph traversal, and it is resolved by the same rule: keep the representation that makes the common case a word-level operation.

## Bitset graph traversal: the frontier as a word

A graph frontier is a set of vertices, and a set of vertices is a bitvector. Breadth-first search is therefore a natural broadword kernel. Store the adjacency of each vertex as a bitset of its neighbors. Store the frontier as a bitset. The next frontier is the union of the adjacency rows of all vertices in the current frontier, minus the vertices already visited:

```c
for (int w = 0; w < words; ++w) {
    uint64_t f = frontier[w];
    while (f) {
        int v = (w << 6) | __builtin_ctzll(f);
        for (int j = 0; j < words; ++j)
            next[j] |= adj[v][j];
        f &= f - 1;
    }
}
for (int j = 0; j < words; ++j) {
    next[j] &= ~visited[j];
    visited[j] |= next[j];
}
```

The inner loop over `j` is a word-wise OR of an adjacency row. For a dense graph with n vertices, each row is n/64 words, so the cost of expanding one frontier vertex is n/64 ORs. If the frontier contains k vertices, the cost is k*n/64. A scalar BFS that iterates over adjacency lists costs the sum of degrees of the frontier vertices. The bitset version wins when the average degree is large relative to 64, because each OR processes 64 potential edges at once. It loses on sparse graphs, where most adjacency words are zero and the loop is dominated by memory traffic. The crossover is the same as in the column-store discussion: bit-level parallelism pays when the data is dense enough that each word carries many useful bits.

The frontier itself can be consumed at the word level. If the frontier is dense, the `ctz` loop is the wrong choice; it pays the extraction tax for every vertex. A better kernel processes each frontier word as a whole and uses a precomputed table of adjacency-row unions for groups of eight vertices. The table is indexed by the byte of the frontier and returns the OR of the adjacency rows for the vertices set in that byte. The table is large — 256 entries per group of eight vertices — but it turns eight vertex expansions into one lookup and one OR. This is the same compaction trade-off as before: the table buys fewer branches at the cost of memory and cache pressure. For a graph with a stable structure and many BFS runs, the table is often worth it. For a single traversal, the `ctz` loop is simpler and usually fast enough.

The visited set is another broadword structure. Marking a vertex visited is a bit set; testing it is a bit test. The intersection of the next frontier with the complement of the visited set is a word-wise AND-NOT. There is no branch per vertex. The only branch is the loop over frontier words and the `ctz` loop over set bits. If the frontier is sparse, the branch is predictable because most words are zero. If the frontier is dense, the branch is taken often and the `ctz` loop becomes the bottleneck. That is the point where a bit-sliced frontier or a SIMD frontier can help, but the underlying representation is still a bitvector. The graph kernel and the bitmap index kernel are the same kernel: a set is a word, a union is an OR, an intersection is an AND, and the cost is the number of words touched.

The direction of traversal matters as well. A top-down BFS expands the frontier by adjacency rows; a bottom-up BFS tests each unvisited vertex against the frontier using the reverse adjacency. The bottom-up form is often faster when the frontier is large and the graph is sparse, because it touches each edge once from the unvisited side. In bitset form, the bottom-up step is a word-wise AND of the frontier with the reverse adjacency row of each unvisited vertex. The same primitives appear: bit tests, word-wise ANDs, and popcounts to decide whether a vertex has a parent in the frontier. The choice between top-down and bottom-up is a choice of which side of the graph is denser, and the bit-parallel implementation makes that choice cheap to switch at runtime. The frontier stays a word, the visited set stays a word, and the traversal advances 64 vertices per instruction.

This is where the article's cost model closes its loop. The same guard-bit discipline that makes `nz8` correct makes the byte-wise matcher correct. The same compaction tax that makes mask extraction expensive makes the `ctz` frontier loop expensive. The same register-pressure boundary that decides between SWAR and SIMD decides whether a graph kernel should keep its frontier in general-purpose registers or in vector registers. The remaining question is empirical: which representation keeps the working set in registers, and which tax the kernel can hide.
