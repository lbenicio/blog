---
title: "Building A Huffman Coding Implementation With Canonical Huffman Trees And Bit Packing"
description: "A comprehensive technical exploration of building a huffman coding implementation with canonical huffman trees and bit packing, covering key concepts, practical implementations, and real-world applications."
date: "2022-04-02"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/building-a-huffman-coding-implementation-with-canonical-huffman-trees-and-bit-packing.png"
coverAlt: "Technical visualization representing building a huffman coding implementation with canonical huffman trees and bit packing"
---

## The Problem with Standard Huffman Trees

The textbook Huffman algorithm is deceptively simple: given a set of symbols and their frequencies, build a binary tree by repeatedly merging the two nodes with the smallest frequencies. The final tree yields a code for each symbol – a path from root to leaf, where a left branch is a 0 and a right branch is a 1. The code length for a symbol is the depth of its leaf. The result is an optimal prefix code for that frequency distribution.

Yet when you try to use this algorithm in a real compression pipeline, you quickly discover a glaring omission: _how does the decoder know which code corresponds to which symbol?_ The encoder can generate the tree, but the decoder must reconstruct it exactly. If the tree is dynamically generated from the data (as in an adaptive or semi-adaptive Huffman coder), the encoder must transmit the tree alongside the compressed bit stream. This becomes the bottleneck.

### Storing the Tree: The Naive Approach

The most straightforward way is to serialize the entire binary tree structure. For a tree with N leaves (symbols), you need to send:

- The shape of the tree (which internal nodes have children), and
- The symbol at each leaf.

One common representation is to write the tree in a pre-order traversal: for each node, emit a 0 for an internal node and a 1 for a leaf, followed by the symbol if it’s a leaf. This is compact for small alphabets but quickly becomes wasteful. For an alphabet of 256 symbols, the tree has 511 nodes (256 leaves + 255 internal). The traversal produces 511 bits (about 64 bytes) for the structure, plus 256 bytes for the symbols – total ~320 bytes. That’s not huge, but it’s a fixed overhead even for small files. Worse, the decoder must parse this tree using recursion or a stack, which is slow and memory-intensive.

Alternatively, you could transmit a list of (symbol, code length) pairs. This is better: the decoder can reconstruct the tree (or rather, the canonical code) from the lengths. But even then you must transmit each pair. For 256 symbols, that’s 256 pairs, each requiring, say, 1 byte for the symbol and 1 byte for the length (max 255 bits? No, max length rarely exceeds 30). So ~512 bytes. Still wasteful, but the real killer is that the decoder must rebuild a Huffman tree from the lengths – using a classic algorithm that involves sorting by length and assigning codes in a depth-first manner. That’s O(256 \* log 256) – not terrible, but not trivial.

All these methods share a deeper flaw: they force the decoder to perform complex work (building a tree or a decode table) on the fly. In high‑throughput systems like video codecs or network routers, every microsecond matters. The textbook tree offers no shortcut to fast decoding.

### The Case of Fixed Length Codes

Consider the alternative: fixed‑length codes. If you simply assign each of the 256 symbols an 8‑bit code, the compression ratio depends entirely on the data. For a uniform distribution, Huffman coding offers no gain; for skewed distributions, Huffman wins. But fixed codes are trivially decodable – just read N bits per symbol. The overhead is zero. The challenge is to get the best of both worlds: variable‑length codes that are as good as Huffman, yet almost as fast to decode as fixed codes.

That challenge is exactly what canonical Huffman coding solves.

## Enter Canonical Huffman Coding

The key insight is that the _lengths_ of the codes are all that matters for optimal compression. The specific bit strings, as long as they are a valid prefix code, do not affect the number of bits used. You can permute the code assignments arbitrarily while keeping the same lengths, and the compressed file will be identical in size. This freedom allows us to choose a particularly convenient ordering: the canonical ordering.

A canonical Huffman code is any prefix code that satisfies two simple properties:

1. **Length‑ordered**: For any two symbols, if the code length of symbol A is less than that of symbol B, then the numeric value of A's code is less than the numeric value of B's code (when compared as binary numbers of equal length). Actually, the standard canonical assignment is: sort symbols by the length of their Huffman code, and then by the symbol itself (or any tie‑breaker). Then assign the binary codes in increasing order, starting from zero, and for each successive length, shift the current code left by one bit and then append the new symbols.

2. **Prefix‑free**: No code is a prefix of another (guaranteed by the length‑based assignment).

Formally, let the code lengths for the alphabet be $l_1, l_2, \dots, l_n$ (sorted by length). The canonical codes are computed as:

```
code = 0
for length L = 1 to L_max:
    for each symbol with length L (in symbol order):
        assign code to that symbol
        code += 1
    code = code << 1
```

The result is a sequence of codes where all codes of the same length are consecutive integers, and codes of shorter lengths are numerically smaller (after zero‑padding to the same length) than codes of longer lengths. This structure is the foundation of extremely fast decoding.

### Why It’s Better Than a Tree

The most immediate benefit is that the decoder no longer needs to reconstruct a tree. From the code lengths alone, it can build a small lookup table that maps any possible bit string (up to a certain maximum length) directly to a symbol. For example, in DEFLATE (used in PNG and gzip), the maximum code length is limited to 15 bits. That means the decoder can precompute a table of $2^{15} = 32768$ entries – a mere 64 KB if each entry is 2 bytes – and then decode any valid Huffman code by reading up to 15 bits, using them as an index into this table, and directly obtaining the symbol and the actual code length. This is often called a _direct decode table_.

The decoding procedure becomes:

```
while bytes remain:
    read up to L_max bits into a buffer
    index = look up in table[buffer]
    symbol = index >> length_shift (or similar)
    actual_length = index & length_mask
    advance input by actual_length bits
    output symbol
```

No branching on tree nodes, no recursive traversal. Just a constant‑time lookup. This is why all high‑performance lossless compression formats – from gzip and PNG to JPEG and bzip2 – use canonical Huffman codes.

### A Simple Example

Suppose we have three symbols A, B, C with Huffman code lengths: A:1, B:2, C:2 (e.g., frequencies 10, 5, 5). A standard Huffman tree might assign A=0, B=10, C=11. That assignment is already canonical? Let’s check: A length 1, B length 2, C length 2. Sorted by length: A(1), then B and C (both 2). In alphabetical order, B before C. So canonical assignment: start code=0 for length 1 → A gets 0. Increment code → code=1. Then shift left: code=2 (binary 10). For length 2: B gets 10, increment → 11, then C gets 11. So canonical codes are A=0, B=10, C=11 – identical to the tree’s natural assignment. Indeed, many Huffman trees already produce canonical codes, but not always. The canonical algorithm guarantees it.

Now consider a more complex case: symbols D:3, E:3, F:3, G:3, H:3, with lengths 3,3,3,3,3. Standard Huffman might assign them in some arbitrary order. Canonical ensures they are sequential: first symbol gets 000, next 001, next 010, etc. That order makes decoding trivial.

## How to Build and Use Canonical Huffman Codes in Practice

### Step 1: Building the Code Lengths

We start with the standard Huffman algorithm to compute the optimal code lengths for each symbol. This step is unchanged. In many applications, you can use _any_ method to obtain lengths – even a fixed set of lengths (like an approximated distribution). The canonical assignment only cares about lengths.

Implementation details: usually we have a frequency array `freq[symbol]`. We build a priority queue of nodes, repeatedly merge the two smallest, and then traverse the tree to collect lengths. This part is O(n log n) for n symbols. For static Huffman, we do this once per block of data. For adaptive Huffman, we update dynamically.

### Step 2: Sorting and Assigning Codes

Once we have lengths, we need to assign canonical codes. This requires knowing all symbols with their lengths. We create a list of (length, symbol) pairs, sort by length then by symbol (or by any stable tie‑breaker). Then we apply the algorithm:

```
def build_canonical_codes(lengths):
    # lengths: dict mapping symbol -> code length
    max_len = max(lengths.values())
    # create a list of (length, symbol) sorted
    symbols_sorted = sorted(lengths.items(), key=lambda x: (x[1], x[0]))
    code = 0
    codes = {}
    current_length = symbols_sorted[0][1]
    for symbol, length in symbols_sorted:
        while current_length < length:
            code <<= 1
            current_length += 1
        codes[symbol] = bin(code)[2:].zfill(length)  # store as binary string
        code += 1
    return codes
```

This function yields the canonical code for each symbol. Note that we must ensure that the total number of codes at each length does not exceed $2^{length}$; otherwise the lengths are invalid (impossible to create a prefix code). The Huffman tree guarantees that the Kraft inequality holds: $\sum 2^{-l_i} \le 1$. So this is guaranteed.

### Step 3: Transmitting the Code Lengths

Now the crucial part: instead of sending the tree, we send only the _code lengths_ for each symbol in a predefined order – usually symbol order. For an alphabet of 256 symbols, we send 256 bytes (each being a code length from 0 to max, say 15). That’s 256 bytes of overhead. Not bad, but we can compress further by using a run‑length encoding or even a small Huffman code on the lengths themselves (e.g., DEFLATE uses a separate Huffman tree for code lengths). But the point is: 256 bytes is far smaller than the 300+ bytes of a tree, and more importantly, the decoder does not have to parse a recursive structure.

However, if the alphabet is huge (e.g., 65536 symbols), sending all lengths explicitly is expensive. Then we might use a canonical code for the lengths themselves – a technique called _Huffman‑coded Huffman lengths_. This is exactly what DEFLATE does: it encodes a subset of symbols (the literal/length and distance alphabets) using a three‑layer scheme. But that’s a topic for another day.

### Step 4: Building the Decode Table

The decoder receives the code lengths for each symbol. It must build the canonical codes (the same way the encoder did) and then construct a decoding structure. The simplest structure is the direct lookup table for a maximum code length L_max. Let’s assume L_max = 15 (common in DEFLATE). The table size is $2^{15} = 32768$ entries. We can pack into each entry: the symbol (e.g., 8 bits) and the actual code length (4 bits). That’s 12 bits – easily fits into 2 bytes. So the table is 64 KB. For many embedded systems, 64 KB is acceptable; for others, we can reduce L_max or use a smaller table with a state machine.

The algorithm to populate the table is:

- Initialize table with an "INVALID" sentinel.
- For each symbol with length L, compute its canonical code `code` (as an integer). Then, for _all_ bit strings of length L*max whose top L bits equal `code`, set the table entry to point to this symbol and length L. The number of entries per symbol is $2^{L*{max} - L}$. This is done by looping `code << (L_max - L)` to `((code+1) << (L_max - L)) - 1`.

A more memory‑efficient approach is to use a _two‑level table_: first a lookup on, say, the top 8 bits, which gives a pointer to a secondary sub‑table for the remaining bits. This is commonly used in JPEG and MPEG.

### Step 5: Encoding and Decoding

Encoding is straightforward: for each input symbol, look up its canonical code and write that many bits to the output.

Decoding: as described earlier, read L_max bits, index into the table, obtain the symbol and length, advance the bit pointer by that length, and repeat.

Example in Python (stripped of bit‑stream management for clarity):

```python
MAX_LEN = 15
decode_table = [0] * (1 << MAX_LEN)

def build_decode_table(canonical_codes):
    # canonical_codes: dict symbol -> (code_int, length)
    table = [None] * (1 << MAX_LEN)
    for sym, (code, length) in canonical_codes.items():
        # number of duplicate entries for this code
        count = 1 << (MAX_LEN - length)
        base = code << (MAX_LEN - length)
        for i in range(count):
            table[base + i] = (sym, length)
    return table

def decode_next(bit_reader, table):
    bits = bit_reader.peek(MAX_LEN)
    sym, length = table[bits]
    bit_reader.advance(length)
    return sym
```

In a real implementation, `bit_reader.peek(MAX_LEN)` may require a bit buffer that tracks an integer and a bit offset. That is a standard topic in data compression.

## A Complete Walkthrough with a Small Alphabet

Let's implement a working example from scratch. We’ll compress a simple string "abacaba" using canonical Huffman.

**Step 1: Count frequencies**
a:4, b:2, c:1

**Step 2: Build Huffman tree to get lengths**
Standard algorithm: combine c(1) and b(2) → node(3). Combine node(3) and a(4) → root(7). Lengths: a:1, b:2, c:2 (exact same as earlier). So lengths = {a:1, b:2, c:2}.

**Step 3: Build canonical codes**
Sorted by (length, symbol): (1,'a'), (2,'b'), (2,'c'). Then:

- Start code=0, current_length=1.
- For 'a': length 1 → code=0 → assign 'a'=0. code++ → 1.
- Now next symbol 'b' has length 2 > current_length 1. So shift left: code = 1<<1 = 2. current_length=2.
- Assign 'b' code=2 (binary 10). code++ → 3.
- Assign 'c' code=3 (binary 11). code++ → 4.
  Result: a=0, b=10, c=11. Exactly what we expect.

**Step 4: Encode string**
"abacaba": a(0), b(10), a(0), c(11), a(0), b(10), a(0) → bits: 0 10 0 11 0 10 0 = 00100110100. That's 11 bits, whereas fixed 2‑bit code per symbol would be 14 bits. Compression ratio: 11/14 = 78%.

**Step 5: Decode**
Decoder receives code lengths: a:1, b:2, c:2. It builds canonical codes (same as encoder). Then builds a decode table for MAX_LEN=2 (since max length is 2). Table entries:

- For code=0 length=1: entries for all 2-bit strings starting with 0: 00 and 01 → both map to (a,1).
- For code=2 (10) length=2: only entry 10 maps to (b,2).
- For code=3 (11) length=2: only entry 11 maps to (c,2).
  So table[0]=a,1; table[1]=a,1; table[2]=b,2; table[3]=c,2.

Reading bits: first 2 bits = 00 → table[0] = (a,1). Advance 1 bit (actually we consumed 2 bits from peek, but we only advance by 1: the decoder must handle that. Better approach: peek 2 bits, decode, then advance by the length, and re‑peek. Example: start: read 2 bits = 00 → a, length=1 → advance 1 bit. Now remaining bits: 0100110100 (original bits without the first 0). Next peek 2 bits = 01 (since we are at position 1, bits 1 and 2 are 0 and 1? Let's simulate: original bits: 0 1 0 0 1 1 0 1 0 0. After removing first 0, we have 1 0 0 1 1 0 1 0 0. Peek first 2 bits: 1,0 → binary 10 = 2 → table[2] = (b,2). Advance 2 bits, and so on. The decoder will correctly produce "abacaba".

This example shows the elegance of canonical decoding: no tree walking.

## Practical Considerations and Optimizations

### Limiting Code Lengths

In the real world, Huffman code lengths can be arbitrarily long if frequencies are extremely skewed (e.g., one symbol appears almost always). A code length of 100 bits is undesirable for multiple reasons: it slows down decoding (you would need a huge lookup table), and it wastes header bits if you need to transmit lengths. Most formats impose a maximum code length – in DEFLATE it’s 15 bits, in JPEG it’s 16 bits, in bzip2 it’s 20 bits. If the Huffman algorithm produces a code longer than this limit, you must _lengthen_ the codes of the more frequent symbols to bring the longest within the limit. This is a constrained optimization problem: find the optimal set of code lengths bounded by L_max that minimizes expected code length while still being a valid prefix code. This is solved by the **package‑merge** algorithm (also known as the length‑limited Huffman algorithm), which is more complex than the classic Huffman but still O(n \* L_max). Many compression libraries (e.g., zlib) implement package‑merge for DEFLATE.

### Handling Large Alphabets

For alphabets > 256 (e.g., 32‑bit integers in LZ77 dictionaries), storing all code lengths can become prohibitive. The solution is to _run‑length encode_ the lengths, or to use a separate Huffman code for the lengths themselves. DEFLATE uses a clever three‑layer scheme: first it Huffman‑encodes the sequence of code lengths (which are then used to decode the literal/length and distance alphabets). This nested Huffman coding reduces overhead dramatically.

### Decoding Without a Full Lookup Table

If memory is tight, you can use a **state machine** decoder. The canonical property allows a simple binary search on a sorted list of (code, length, symbol). Because all codes of the same length are consecutive, you can determine the length by comparing the first few bits against the minimum code for each length. There is a classic algorithm using a list of base codes and symbol indices:

```
decode_state_machine(input_bits):
    for L in 1..L_max:
        if code_length_first[L] <= input_bits >> (L_max - L):
            # symbol is in this length group
            offset = symbol_offset[L] + (input_bits >> (L_max - L) - code_length_first[L])
            symbol = symbol_table[offset]
            length = L
            break
    advance input_bits by length
```

This uses a small amount of memory (one array per possible length). It is slower than a full table lookup (requires up to L_max iterations) but often still fast enough.

### Multi‑Symbol Decoding in Parallel

Modern SIMD instructions can decode several Huffman symbols simultaneously by pre‑computing multiple lookup tables and using specialized gather instructions. AMD's XOP/AVX2 and Intel's AVX‑512 have instructions like `VPERMB` that can perform 32 parallel lookups from a small table. This enables decoding throughput of tens of gigabytes per second. The canonical structure is crucial for these optimizations because the lookups are linear and alignment‑friendly.

## Canonical Huffman in Real‑World Formats

### DEFLATE (gzip, PNG, zlib)

DEFLATE is the most famous user of canonical Huffman. It defines two Huffman trees: one for literal/length values and one for distances. Both are limited to 15 bits. The code lengths for these trees are themselves Huffman‑coded (run‑length encoded) using a third tree called the _code length tree_. This nesting is why DEFLATE headers can be extremely compact – often less than 100 bytes.

The canonical assignment ensures that the decode tables can be built from the transmitted lengths without needing the original frequencies. The limit of 15 bits means the direct lookup table is only 64 KB – trivial on modern hardware.

### JPEG

JPEG uses Huffman coding for the quantized DCT coefficients. It defines _Huffman tables_ in the file header that contain arrays of code counts per length and symbol values. JPEG does not use the length‑limited version (max length is 16 bits). The specification explicitly describes the canonical assignment: start code = 0 for length 1, then for each length, assign codes in increasing order of symbol value (or as listed in the table). The decoding procedure in the JPEG standard is a classic example of canonical Huffman decoding with a two‑level table.

### bzip2

bzip2 uses a modified version of canonical Huffman where the alphabet is the run‑length encoded output of the Burrows‑Wheeler transform. It uses a maximum code length of 20 bits (or perhaps 16? Actually, bzip2's spec says the Huffman codes can be up to 20 bits long). To avoid a 1‑million‑entry table, bzip2 uses a different approach: it stores an array of (code, length, symbol) sorted by code, and decodes by binary search. This is slower but acceptable given bzip2’s focus on compression ratio over speed.

### Brotli

Google's Brotli compression format uses a more advanced form of canonical Huffman called _context‑based coding_ and _insert‑copy_ coding. It still relies on canonical Huffman for its literal and distance codes, but with dynamic code length limits that can be up to 24 bits. Brotli uses a multi‑level decode table to keep memory usage manageable.

## Advanced Topics: Length‑Limited Huffman and Package‑Merge

As mentioned, if the optimal Huffman code violates the maximum allowed length, we need to find a suboptimal but still efficient code. The classic algorithm is **package‑merge**, which solves the problem of constructing an optimal prefix code with a length constraint. It was invented by Larmore and Hirschberg. The algorithm works by merging packages of symbols, similar to building a Huffman tree, but with an extra constraint on depth. The result is a set of lengths that minimize cost subject to max length. The implementation is non‑trivial but crucial for formats like DEFLATE where every implementation must produce valid 15‑bit limited codes.

For example, in a file with only two symbols, each with frequency 1, Huffman would assign codes of length 1 and 1 (which sum to 2 bits per two symbols? Actually, two symbols each length 1 is valid? No, if both have length 1, then one code is 0 and the other is 1 – that’s fine. But if you have three symbols with frequencies 100, 1, 1, the optimal Huffman tree gives lengths: 100 (1), 1 (2), 1 (2) – max length 2, fine. But if you have symbols with frequencies 2^30, 1, 1, ... 1 (many rare), the optimal lengths could be 30 bits for the rare ones, which may exceed L_max. Package‑merge will increase the frequent symbol's length to make room, sacrificing a tiny amount of compression.

### Implementation Overview of Package‑Merge

The algorithm works in O(n * L_max) time. It treats each symbol initially as a *package* with cost = frequency and depth = 0. Then it repetitively merges the two smallest‑cost packages and increments depth. However, it also allows *rejecting\* a merge if it would exceed the max length. Details are beyond this post, but the key takeaway is that any real‑world Huffman coder must handle length constraints.

## Conclusion: Why You Should Care

The textbook version of Huffman coding is a beautiful teaching tool, but Canonical Huffman is the production‑grade engine that powers the digital world. By decoupling code lengths from code assignment, it enables efficient transmission of the coding table and blazing‑fast decoding using simple lookup tables. The overhead of storing the tree disappears, replaced by a compact array of lengths. The decoder can be implemented in a few dozen lines of C or assembly and can run at gigabytes per second.

If you ever need to implement a lossless compression system – for a file format, a binary protocol, or a memory‑constrained embedded device – canonical Huffman is likely the right choice. Its decades‑old design remains the gold standard for entropy coding, precisely because it elegantly solves the problem it set out to solve: making data smaller without making the decoder’s life harder.

So the next time you unzip a file, open a PNG, or stream a compressed video, remember the quiet revolution of the bits – the shift from the Huffman tree to the canonical code. It’s a small difference in memory, but a giant leap in performance.
