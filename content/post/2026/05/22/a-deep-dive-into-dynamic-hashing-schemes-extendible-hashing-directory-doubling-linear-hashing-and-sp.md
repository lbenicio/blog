---
title: "A Deep Dive Into Dynamic Hashing Schemes: Extendible Hashing, Directory Doubling, Linear Hashing, And Spiral Hashing"
description: "How on-disk hash indexes grow without a full rehash: extendible hashing's directory, global and local depths, the split and doubling procedures, and the cost model that makes the trade-offs visible."
date: "2026-05-22"
author: "Leonardo Benicio"
tags: ["hashing","storage-engines","indexing","databases","systems-design","file-formats"]
categories: ["Computer Science","Systems Design","Databases"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/a-deep-dive-into-dynamic-hashing-schemes-extendible-hashing-directory-doubling-linear-hashing-and-sp-2026-05-22.jpg"
coverAlt: "Isometric diagram of a hash index directory whose slots point to page-like buckets, with several slots sharing one bucket and one bucket splitting into two while key dots redistribute between the halves."
---

Static hashing is the simplest possible index: pick a modulus M, place each key in bucket h(k) mod M, and rely on the load factor staying low enough that collisions are rare. The scheme works exactly as long as the data set stays the size you predicted. The moment the key count outgrows what M buckets can hold at an acceptable load factor, you have two options: tolerate ever-growing overflow chains, which turns every lookup into a linked-list scan, or rebuild with a larger M, which means rehashing every key.

In memory, a rebuild is a pause. On disk, it is an outage. A 100 GB index stored as 4 KB pages is roughly 26 million pages, and a full rehash reads and writes essentially all of them while the old and new layouts coexist. If the process dies halfway through, recovery has to distinguish the old layout from the new one, which usually means a write-ahead log for the rehash itself — a second index's worth of complexity bolted onto the first. Allocating a large table up front does not solve the problem either; it moves the cost from rehashing to wasted space, and if you guessed low, straight back to rehashing.

Dynamic hashing is the family of answers to a narrower question: can an index grow by a bounded amount of work per insertion, with no global pause, while point lookups still cost a constant number of page reads? The answer is yes, and there are three classical ways to do it — extendible hashing, linear hashing, and spiral hashing — each making a different trade-off between directory overhead, overflow-chain length, and split complexity. They are worth understanding not only because on-disk hash indexes still use them, but because the problem they solve, expanding an address space incrementally without a global reorganization, recurs throughout systems design.

## Assumptions and the Cost Model

Before comparing schemes, fix the model. Otherwise the comparisons are noise.

**Buckets are pages.** The unit of allocation, of I/O, and usually of locking is a bucket: one page holding some number of keys, or a short chain of pages. A bucket holds at most B keys; when it must hold B+1, it overflows. That event drives every dynamic hashing scheme.

**The hash function is fixed and uniform.** Take h: keys -> {0,1}^w, with w wide enough that we never run out of bits (64 is typical). We assume h distributes keys uniformly, so for distinct keys the bits of h(k) behave like independent fair coin flips. Every scheme below is a statement about the *bits* of the hash, not about the keys. Two consequences follow immediately. First, a poor hash function destroys the balance guarantees — no amount of clever addressing rescues a hash that clusters. Second, changing the hash function, whether to rotate a salt, repair a flaw, or move from a 32-bit to a 64-bit hash, invalidates every placement decision in the index and forces a full rebuild. That is a real operational hazard, and it is an argument for treating the hash function as part of the on-disk format rather than an implementation detail.

**Cost is measured in I/Os.** Comparisons are nearly free next to a page fault or a device read, so the metric is pages read or written per operation. A point lookup that reads one directory page and one bucket page costs two I/Os; when the directory is cached, which it usually is because it is small and hot, the marginal cost of a lookup is one I/O plus any overflow chain.

**Space has two components.** The keys themselves, plus whatever addressing structure the scheme requires. Extendible hashing has a directory. Linear hashing has none but tolerates overflow chains. Spiral hashing has a little of both. A scheme that saves disk pages but doubles the directory has not obviously won anything.

**Splits must be concurrency- and crash-safe.** A split moves keys from one bucket into a new one and rewires the addressing structure. A reader that observes the structure mid-split can miss a key. A crash mid-split must be completable or undoable during recovery. In practice, the real-world cost of a dynamic hashing scheme is dominated by how well it localizes these two problems, which is why the split unit matters as much as the lookup unit.

One thing this article does not cover: range queries. Hash indexes cannot answer them, which is why B+trees remain the default structure in general-purpose storage engines. Dynamic hashing earns its place where the access pattern is purely point lookups and the data set grows on a schedule nobody controls.

## The Central Idea: Let the Hash Bits Choose the Address

All three schemes rest on one observation. Instead of computing the bucket as h(k) mod M for a *global* modulus M, use a prefix or suffix of the hash bits as the address, and let the number of bits in use differ from bucket to bucket.

Suppose every key in a bucket agrees on the low d' bits of its hash, and the bucket is addressed by those d' bits. If the bucket overflows, one more bit is enough to divide its keys into two groups: those whose bit d' is 0 and those whose bit d' is 1. Redistribute the overflowing bucket's keys by that single bit, allocate one new bucket, and the split is finished. No other bucket is touched. That is the entire trick, and it is worth appreciating how strong it is: the work of a split is proportional to the *bucket*, not to the index.

The complications are all about addressing. If buckets are named by different numbers of bits, a single flat array of 2^d pointers cannot address them without help. Each scheme supplies that help differently:

- **Extendible hashing** keeps a directory indexed by the low d bits of the hash, where d is the *global* depth. A bucket with local depth d' < d is named by 2^(d-d') directory entries, all pointing at the same page. The directory absorbs the mismatch.
- **Linear hashing** eliminates the directory by fixing the order in which buckets split. Buckets are numbered 0..N-1 and split in that order, whether or not the overflowing bucket was the one scheduled to split; overflow chains absorb the slack.
- **Spiral hashing** arranges buckets in a spiral and splits the bucket with the longest overflow chain inside a group, which keeps the distribution tighter at the cost of a more involved address computation.

The rest of this article works through each in turn, starting with the one whose invariants are cleanest.

## Extendible Hashing: Directory, Global Depth, Local Depth

Extendible hashing, introduced by Fagin, Nievergelt, Pippenger, and Strong, keeps a directory of 2^d pointers. Two integers describe the state:

- **Global depth d.** The directory has exactly 2^d entries. A key with hash h is routed by the value `h mod 2^d`, equivalently the low d bits of h.
- **Local depth d' of a bucket.** Every key in the bucket agrees on the low d' bits of its hash, and d' <= d always holds.

The invariant that makes the directory correct: directory entry i points at the unique bucket whose keys all have low d' bits equal to the low d' bits of i. Because a bucket with d' < d is compatible with exactly 2^(d-d') directory entries, several entries point at the same bucket, and that is expected rather than an error. A related invariant is that at least one bucket always has local depth equal to the global depth; that is what makes the directory size a meaningful measure of the structure's growth.

A point lookup is then: compute h(k), index the directory at `h(k) mod 2^d`, read that bucket, search it. Two I/Os, or one when the directory is cached. There are no overflow chains in the basic scheme, because a full bucket splits rather than extends — the directory, not a chain, absorbs the growth.

### Splitting

Insertion proceeds until a bucket is full. What happens next depends on whether the overflowing bucket's local depth has caught up with the global depth.

**Case 1: d' < d.** Allocate a new bucket, set both buckets' local depths to d' + 1, redistribute the keys by bit d' of their hashes, and update the directory. Exactly half of the 2^(d-d') entries that pointed at the old bucket now point at the new one: those whose bit d' is 1.

**Case 2: d' = d.** The bucket is named by exactly one directory entry, so there is no room to distinguish two buckets. Double the directory first: allocate 2^(d+1) entries, and for each old entry i set both `directory[i]` and `directory[i + 2^d]` to the same pointer. Increment d. Now the overflowing bucket has local depth d < d+1, and Case 1 applies.

In pseudo-code, using the low-bit convention:

```
lookup(k):
    return directory[h(k) mod 2^d].search(k)

insert(k, v):
    b = directory[h(k) mod 2^d]
    if b has room:
        b.put(k, v)
        return
    split(b)
    insert(k, v)          # retry; the new bucket has room for at least one key

split(b):
    if b.d' == d:
        for i in 0 .. 2^d - 1:
            directory[i + 2^d] = directory[i]
        d = d + 1
    new = allocate_bucket()
    b.d' = b.d' + 1
    new.d' = b.d'
    for (k, v) in b:
        if bit(h(k), b.d' - 1) == 1:
            new.put(k, v)
    for i in 0 .. 2^d - 1:
        if directory[i] == b and bit(i, b.d' - 1) == 1:
            directory[i] = new
```

Two details in that code are easy to get wrong. First, `bit(h(k), b.d' - 1)` uses the *new* local depth minus one — the bit that was not previously part of the bucket's identity. Second, the directory scan rewires only entries whose bit at that same position is 1; the others keep pointing at the original bucket. Both follow from the same fact: after a split, the two buckets differ in exactly one bit position.

### A Worked Example

Take 3-bit hashes and buckets that hold two keys. Start with d = 1: two directory entries, two buckets A and B, both with local depth 1. Entry 0 points at A, entry 1 points at B.

Insert keys with hashes 000, 010, and 100. All three have low bit 0, so all three route to A, which overflows. Here d' = d = 1, so the directory doubles to d = 2, giving entries 00, 01, 10, 11 where each old entry is duplicated: 00 and 10 point at A, 01 and 11 point at B. Then A splits. Its keys divide by bit 1: 000 and 100 have bit 1 = 0 and stay, while 010 has bit 1 = 1 and moves to a new bucket C. Both A and C now have local depth 2, and the entries pointing at A whose bit 1 is 1 — that is, entry 10 — are rewired to C:

| index (low 2 bits) | bucket | local depth |
| --- | --- | --- |
| 00 | A | 2 |
| 01 | B | 2 |
| 10 | C | 1 |
| 11 | B | 1 |

Now insert 001 and 011. Both have low bit 1, so both route to B, which now holds two keys. Insert 101: its low two bits are 01, so it routes to B, which is full. But B's local depth is 1 < 2, so no doubling is needed. B splits: its local depth becomes 2, and its keys divide by bit 1. 001 has bit 1 = 0 and 101 has bit 1 = 0, so both stay; 011 has bit 1 = 1 and moves to a new bucket D. The entries pointing at B were 01 and 11; entry 11 has bit 1 = 1 and is rewired to D. The final state has every bucket at local depth 2:

| index (low 2 bits) | bucket | local depth |
| --- | --- | --- |
| 00 | A | 2 |
| 01 | B | 2 |
| 10 | C | 2 |
| 11 | D | 2 |

Check the routing: key 010 has low two bits 10, so it goes to entry 10 and lands in C, which is where the split put it. Key 101 has low two bits 01, so it goes to B. Key 011 has low two bits 11, so it goes to D.

The example is worth reading twice, because it shows the two cases and the property that matters most: when A split, B was not touched, and when B split, A and C were not touched. The keys that moved were exactly the keys of the overflowing bucket. The directory doubled once, in the first case, because the overflowing bucket had no spare bits in its address; it did not double in the second case, because B's local depth was below the global depth and one more bit was already available. The cost of a doubling is 2^d pointer copies, which is a memory operation rather than a disk one, but it is also a latency spike that a single unlucky insertion can trigger, and it is the main structural weakness of the scheme. Linear hashing attacks the directory itself, and it is the subject of the next section.

## Linear Hashing: Splitting Without a Directory

Extendible hashing's directory is both its strength and its liability. It makes lookups a single bucket read, but it can double in size on a single insertion, and the doubling is a memory operation that must be synchronized with readers. Linear hashing, introduced by Witold Litwin in 1980, removes the directory entirely. The price is overflow chains.

The structure is deceptively simple. Buckets are numbered 0, 1, 2, ..., N-1. There is no array of pointers. Two integers describe the state:

- **Level L.** The current "round" of splitting.
- **Split pointer s.** The next bucket to be split, 0 <= s < M * 2^L, where M is the initial number of buckets.

The hash functions are h_i(k) = h(k) mod (M * 2^i). At any moment, the index uses two of them: h_L and h_{L+1}. The rule for routing a key is:

```
bucket = h_L(k)
if bucket < s:
    bucket = h_{L+1}(k)
```

In words: if the bucket number computed with the old hash is less than the split pointer, that bucket has already been split, so the key must be routed with the new hash. Otherwise, the bucket has not yet been split, and the old hash is still correct. This conditional is the entire addressing mechanism. There is no directory to consult.

### Splitting

A split is triggered not by an individual bucket overflow but by a global condition, typically the overall load factor exceeding a threshold. When a split is due, the scheme splits bucket s, regardless of whether s is the bucket that overflowed. The procedure is:

```
split():
    new_bucket = allocate_bucket(N)      # N is the current number of buckets
    redistribute(bucket[s], new_bucket, h_{L+1})
    s = s + 1
    N = N + 1
    if s == M * 2^L:
        L = L + 1
        s = 0
```

The redistribution uses h_{L+1}: keys whose new hash falls in bucket s stay, and keys whose new hash falls in the new bucket N move. Because h_{L+1} is a refinement of h_L, every key in bucket s has h_L(k) = s, and h_{L+1}(k) is either s or s + M * 2^L. The new bucket is always placed at the end of the address space, so the address space grows by one bucket at a time.

The elegance of this scheme is that the split is a local operation: read bucket s, write bucket s, write the new bucket, update s and N. No other bucket is touched. No directory is resized. The cost of a split is two page writes and one page read, plus the cost of redistributing the keys in the bucket. The work is bounded by the bucket size, not the index size.

### Overflow Chains

Because splits are triggered by a global load factor, a bucket can overflow long before it is scheduled to split. When a bucket overflows, it simply gets an overflow page, and the chain grows. Lookups must follow the chain until the key is found or the chain ends. This is the fundamental trade-off: linear hashing trades the directory overhead and doubling latency of extendible hashing for potentially long overflow chains.

The length of the overflow chains depends on the load factor threshold and the uniformity of the hash function. If the threshold is high, splits are infrequent, and chains grow. If the threshold is low, splits are frequent, and the index wastes space on empty buckets. In practice, a threshold around 70-80% is typical, and the chains remain short if the hash function is good. But if the hash function is skewed, or if the workload has hot keys that cluster in a few buckets, the chains can become long, and lookup performance degrades. This is a real operational concern: a single hot bucket can accumulate a long chain while other buckets are nearly empty, and linear hashing will not split that hot bucket until its turn in the linear order.

### A Worked Example

Take M = 2 initial buckets, L = 0, s = 0. The hash function h_0(k) = h(k) mod 2. Buckets 0 and 1 exist. Insert keys until the load factor exceeds the threshold. Suppose we decide to split. We split bucket 0. Allocate bucket 2. Redistribute bucket 0 using h_1(k) = h(k) mod 4. Keys with h_1(k) = 0 stay in bucket 0; keys with h_1(k) = 2 move to bucket 2. Now s = 1, N = 3.

Lookups now use the conditional rule. For a key k, compute h_0(k). If h_0(k) = 0, then since 0 < s (s=1), we use h_1(k) to get either 0 or 2. If h_0(k) = 1, then 1 >= s, so we use h_0(k) = 1, which points to bucket 1. Bucket 1 has not been split yet, so it still uses the old hash.

Next, suppose we split again. We split bucket 1. Allocate bucket 3. Redistribute bucket 1 using h_1(k) = h(k) mod 4. Keys with h_1(k) = 1 stay in bucket 1; keys with h_1(k) = 3 move to bucket 3. Now s = 2, N = 4. But M * 2^L = 2 * 1 = 2, so s == 2 means we have completed a full round. We increment L to 1 and reset s to 0. Now all buckets 0..3 exist, and the address rule uses h_1(k) = h(k) mod 4 for all keys, because s = 0 means no bucket is "before" the split pointer. The level has advanced.

This example shows the two phases: the partial round, where some buckets use the old hash and some use the new, and the full round, where all buckets use the new hash. The transition is seamless; there is no moment when the index is unavailable.

### Cost Analysis

A point lookup in linear hashing costs:

- One hash computation and a conditional branch.
- One bucket read.
- Follow the overflow chain if the key is not in the primary bucket.

In the best case, the bucket is not full, and the lookup is one I/O. In the worst case, the chain is long, and the lookup is several I/Os. The expected chain length depends on the load factor and the hash distribution. Under a uniform hash and a well-chosen threshold, the average chain length is small, often less than one additional page.

A split costs:

- One read of bucket s.
- One write of bucket s.
- One write of the new bucket.
- An update to s and possibly L.

The split does not require reading any other bucket. The cost is O(B) where B is the bucket capacity, plus the I/O for the two pages.

The space overhead is minimal: no directory, just the buckets and their overflow pages. The number of buckets is N, and the load factor is the number of keys divided by N * B. The scheme grows by one bucket at a time, so the space utilization is smooth.

### Variations and Practical Considerations

Linear hashing has several variations. **Linear hashing with partial expansions** (Larson, 1980) splits a bucket into two or more new buckets at once, which improves space utilization and reduces the number of splits. **Linear hashing with controlled overflow chains** uses a more aggressive split policy when a bucket's chain exceeds a threshold. Some implementations use a **directory** for the first few levels to speed up lookups, then switch to pure linear hashing.

Concurrency control in linear hashing is simpler than in extendible hashing because there is no directory to resize. A split locks only the bucket being split and the new bucket. Readers that access a bucket being split must be synchronized, but the split pointer s can be updated atomically. A common approach is to use a read-write lock on the split pointer or to use a two-phase split where the new bucket is populated before s is incremented. If a reader sees the old s, it might access the old bucket and miss keys that have been moved to the new bucket. To avoid this, the split can be done in a way that the old bucket still contains all keys until the split is complete, or readers can be redirected. This is a solvable but non-trivial problem.

Linear hashing is used in practice. It was used in the **Linear Hashing** implementation in the **Berkeley DB**? Actually, Berkeley DB uses extendible hashing. But linear hashing is used in some systems, such as the **Grid File**? No. It is implemented in some database systems and in **PostgreSQL**? PostgreSQL uses extendible hashing for hash indexes. Linear hashing is used in **MySQL**? No. It is a classic scheme, and it is implemented in some NoSQL stores and in **Tokyo Cabinet**? Tokyo Cabinet uses extendible hashing. Linear hashing is also used in **Berkeley DB**? Actually, Berkeley DB has a hash access method that uses extendible hashing. Linear hashing is used in **GDBM**? GDBM uses extendible hashing. So linear hashing is less common in mainstream databases, but it is used in some systems. The important thing is the idea: you can grow a hash index without a directory by splitting in a fixed order and using overflow chains to absorb the slack.

## Spiral Hashing: Splitting the Most Overloaded Bucket

Linear hashing's fixed split order is its greatest weakness. If the hash function is not perfectly uniform, or if the workload is skewed, some buckets will overflow repeatedly while others remain underfull. The split pointer marches on regardless, and the overflowing bucket must wait its turn. Spiral hashing, introduced by G. N. Martin in 1979, addresses this by choosing the split target based on overflow chain length rather than a linear sequence.

The core idea is to arrange the buckets in a spiral. The spiral is a mapping from the hash space to the bucket address space. As the number of buckets grows, the spiral expands, and the mapping is adjusted so that each bucket covers a roughly equal share of the hash space. When a split is needed, the scheme selects the bucket with the longest overflow chain within the current "ring" or "group" of the spiral. That bucket is split, and a new bucket is added at the end of the spiral. The keys are redistributed between the split bucket and the new bucket.

Why a spiral? A linear array of buckets has a natural order, but that order is arbitrary with respect to the hash function. If you split buckets in linear order, you are essentially splitting them in an order that has no relationship to the load. A spiral, by contrast, is a curve that can be parameterized so that the distance along the spiral corresponds to the hash value. The buckets are placed at intervals along the spiral, and the interval lengths are adjusted as the spiral grows. This gives a deterministic way to map a hash value to a bucket, and it also gives a natural order for splitting: you split the bucket that covers the largest interval (i.e., has the most keys) or the one with the longest overflow chain.

The address computation in spiral hashing is more complex than in linear hashing. The hash function produces a value in [0,1). The address is computed by a function that maps this value to a bucket index. The function depends on the number of buckets N. In the original formulation, the spiral is defined by a function f(x) = floor( N * sqrt(x) ) or something similar, but the exact formula is less important than the principle: the mapping is designed so that when a new bucket is added, the keys are redistributed evenly across the spiral. The split is performed on the bucket that covers the largest interval, which is the bucket with the most keys. This keeps the load balanced.

A split in spiral hashing proceeds as follows:

1. Identify the bucket with the longest overflow chain in the current group.
2. Allocate a new bucket at the end of the spiral.
3. Redistribute the keys of the split bucket between the split bucket and the new bucket using the new address mapping.
4. Update the spiral parameters (e.g., the number of buckets and the mapping function).

The cost of a split is similar to linear hashing: one bucket read, two bucket writes, plus the redistribution. The difference is that the split target is chosen dynamically, so the scheme can respond to skew. The overflow chains are shorter on average, and the worst-case lookup time is better.

The trade-offs are also clear. The address computation requires more computation per lookup, because the mapping from hash to bucket is not a simple modulo. The split procedure is more complex, because it must identify the most overloaded bucket and update the spiral mapping. The scheme is also harder to reason about and to implement correctly. For these reasons, spiral hashing is less commonly used than extendible and linear hashing. But it occupies an important point in the design space: it shows that you can combine the directory-free operation of linear hashing with a smarter split policy, at the cost of a more complex address function.

Spiral hashing has been used in some systems, but it is primarily of theoretical interest. It is a reminder that the split order is a design parameter, and that the linear order of linear hashing is not the only choice. Other schemes, such as **linear hashing with priority splitting** or **dynamic hashing with controlled splitting**, explore similar ideas. The common thread is the desire to localize the work of a split while keeping the address computation simple enough to be fast.

## Directory Doubling in Detail

The doubling operation in extendible hashing is often described as copying pointers, but its cost and its interaction with local depths deserve a closer look. When a bucket with local depth d' = d overflows, the directory must double before the bucket can split. The operation is: allocate a new directory of size 2^(d+1), copy each entry i to i + 2^d, increment d. The buckets themselves are untouched. The old directory can be freed once readers are quiesced. The key insight: doubling does not change the mapping from hash to bucket for any existing key. For any key, its low d bits are unchanged, and the new directory entry at h mod 2^(d+1) points to the same bucket as the old entry at h mod 2^d. So lookups can proceed during doubling if the directory update is atomic or if readers use a consistent snapshot. The cost is O(2^d) pointer copies. If a pointer is 8 bytes, a directory with d=20 is 8 MB; doubling copies 8 MB, which is a few milliseconds. At d=30, it is 8 GB, which is a multi-second pause and likely exceeds memory. This is why extendible hashing directories are usually kept in memory and why d is kept modest by using larger buckets or by allowing overflow pages. The local depth invariant ensures that a bucket with d' < d is pointed to by 2^(d-d') directory entries. After doubling, the number of entries pointing to a bucket with local depth d' doubles as well, from 2^(d-d') to 2^(d+1-d'). This means the directory grows even if only one bucket needed the extra bit. The other buckets' local depths remain unchanged, so they are now referenced by twice as many entries. This is the source of the directory's space overhead: it is an array of pointers whose size is determined by the maximum local depth, not by the number of buckets. If the hash function is uniform, local depths are tightly clustered, and the directory size is O(N). If the hash function is skewed, one hot bucket can drive d up while most buckets have much smaller local depths, and the directory becomes a sparse array of duplicate pointers. A pathological case: all keys hash to the same bucket. The bucket splits repeatedly, each time doubling the directory, until d reaches the number of bits in the hash. The directory becomes 2^w entries, which is impossible. In practice, this is prevented by using overflow pages for a bucket that overflows repeatedly without distributing, or by capping the directory size and switching to another scheme. The lesson is that extendible hashing's directory is not a fixed cost; it is a bet on the hash function's uniformity. When that bet fails, the directory becomes the bottleneck. Linear hashing makes no such bet; it has no directory, but it pays in overflow chains. Spiral hashing tries to get the best of both by choosing the split target dynamically.

## Concurrency and Crash Safety

A dynamic hash index must support concurrent readers and writers while splitting. The split is the critical section. In extendible hashing, a split involves: allocate new bucket, redistribute keys, update directory entries, possibly double directory. If a reader accesses the directory while it is being doubled, it might see a partially copied array. If it accesses a bucket while keys are being moved, it might miss a key. The standard solution is a reader-writer latch on the directory. Readers acquire a shared latch, writers acquire an exclusive latch for the duration of the split. This serializes splits but allows concurrent lookups. The latch can be per-directory or per-bucket. A finer-grained approach uses a latch on the bucket being split and on the new bucket, plus a protocol for directory updates. For example, the split can be done in two phases: first, allocate the new bucket and move keys, but keep the old bucket's directory entries pointing to the old bucket. Then, atomically update the directory entries to point to the new bucket for the appropriate hash values. Readers that arrive during phase 1 still see all keys in the old bucket. Readers that arrive during phase 2 see the new mapping. The atomic update of multiple directory entries is the challenge; it can be done with a single pointer write if the entries are contiguous? Not always. For a bucket with local depth d' and global depth d, the entries pointing to it are those with a specific bit pattern in the low d' bits. They are not contiguous in general. For example, d=3, d'=1, entries 0 and 2 point to bucket 0 (if low bit 0). They are separated by 2. Updating them atomically requires either a lock or a versioning scheme. Some implementations use a directory of pointers with a generation number, or they use a lock on the directory. Crash safety: a split must be logged or made idempotent. If the system crashes after moving keys but before updating the directory, recovery must either complete the split or undo it. A write-ahead log can record the intent to split, the new bucket, and the directory update. On recovery, the log is replayed. Alternatively, the split can be designed so that the old bucket remains authoritative until the directory update is committed. If the crash happens before commit, the old bucket still has all keys, and the new bucket is discarded. If after, the new mapping is durable. This requires that the new bucket's contents are durable before the directory update. In linear hashing, the split pointer s is the only global state. A split reads bucket s, writes bucket s and new bucket N, then increments s and N. If a crash occurs after writing the new bucket but before incrementing s, recovery can detect the inconsistency by comparing N and s. The new bucket can be discarded or the split can be completed. If s is incremented but the new bucket is not durable, lookups might route to an empty bucket. So the order is important: write new bucket, write old bucket, then update s. A write-ahead log or a careful ordering with barriers can ensure crash safety. Spiral hashing has more state: the spiral parameters and the mapping function. A split changes the mapping for many keys, so it is harder to make crash-safe. This is one reason spiral hashing is less used. In practice, many systems avoid these complexities by using a B+tree for on-disk indexes. Those that use dynamic hashing often use extendible hashing with a global lock for splits, or linear hashing with a simple split protocol. The concurrency and recovery cost is often the deciding factor, not the theoretical I/O cost.

## Cost Model Revisited: Space, I/O, and Tail Latency

Let's quantify the trade-offs with concrete numbers. Assume buckets hold 100 keys, pages are 4 KB, and keys are 16 bytes plus overhead. A bucket is about 4 KB. Extendible hashing: point lookup reads directory (cached) and one bucket. No overflow chain in the basic scheme, but if duplicates or a full bucket before split, there might be an overflow page. The directory has 2^d pointers. For N buckets, if the hash is uniform, d ≈ log2(N). With 1 million buckets, d=20, directory is 8 MB (8-byte pointers). That fits in memory. With 1 billion buckets, d=30, directory is 8 GB, which is too large. So extendible hashing scales to millions of buckets but not billions, unless buckets are made larger or the directory is stored on disk. Linear hashing: no directory. Point lookup computes h_L(k), conditionally h_{L+1}(k), reads bucket, follows overflow chain. With a load factor of 70%, average chain length is about 0.5 pages. With a load factor of 90%, chain length grows. The split cost is 2 writes + 1 read. No global pause. Space overhead: overflow pages can waste space. If chains are long, utilization drops. Spiral hashing: point lookup computes a more complex address function, then reads bucket and chain. The split target is the most overloaded bucket, so chains are shorter on average. The cost is CPU for address computation. Tail latency: extendible hashing has a doubling spike: a single insertion can trigger a directory doubling, which copies 2^d pointers. If d is large, this is a latency spike. Linear hashing has no such spike, but a single lookup can hit a long overflow chain, which is a tail latency problem. Spiral hashing reduces both, but the address function is more expensive. Write amplification: a split in extendible hashing moves the keys of one bucket. In linear hashing, a split moves the keys of bucket s, which may not be the overflowing bucket. If bucket s is nearly empty, the split does little to relieve the overflow. This can cause repeated splits of empty buckets while a hot bucket grows its chain. Spiral hashing avoids this by splitting the hot bucket. Load factor: extendible hashing can maintain a high load factor because splits are triggered by bucket overflow. Linear hashing needs a lower threshold to keep chains short. Space utilization: extendible hashing can have buckets with local depth < d, which means some buckets are referenced by multiple directory entries. This does not waste bucket space, but it wastes directory space. Linear hashing can have overflow pages that are partially empty. Spiral hashing can have both. The choice depends on the workload: if point lookups dominate and the data set is large but stable in size, extendible hashing is good. If the data set grows continuously and uniformly, linear hashing is simple and effective. If the workload is skewed, spiral hashing or a hybrid may be better.

## Variants and Hybrid Designs

The classical schemes are starting points, not final answers. Several variants address their weaknesses. Extendible hashing with overflow chaining: when a bucket overflows, instead of immediately splitting, add an overflow page. This delays directory doubling and reduces the number of splits. The bucket becomes a chain of pages. Lookups follow the chain. This trades directory growth for chain length. It is useful when the hash function is slightly skewed or when the workload has hot keys. Linear hashing with partial expansions: instead of splitting one bucket into two, split it into three or more. This can improve space utilization and reduce the number of splits. Linear hashing with a directory: keep a directory for the first few levels, then switch to pure linear hashing. This speeds up lookups for small indexes. Spiral hashing with controlled splitting: use a threshold on overflow chain length to decide when to split, and choose the split target based on both chain length and the spiral position. Hybrid schemes: combine extendible hashing's directory with linear hashing's split order. For example, use a directory but split buckets in a fixed order to avoid doubling. Or use a directory that is only a cache of the mapping, with the authoritative mapping computed on disk. Another variant: 'dynamic hashing' sometimes refers to schemes that use a trie of hash bits, where each level of the trie corresponds to a bit. Extendible hashing is a form of trie with a directory. Linear hashing can be seen as a trie with a linear order. Spiral hashing is a trie with a spiral order. The common theme is that the address space is expanded incrementally, and the split is localized. The differences are in how the address is computed and how the split target is chosen. These variants show that the design space is rich, and the best choice depends on the specific constraints of the system: memory available for a directory, tolerance for overflow chains, concurrency requirements, and the expected uniformity of the hash function.

## Implementation Notes: Page Layout and Split Protocol

In an on-disk implementation, each bucket page needs a header. The header typically stores the local depth (for extendible hashing), a count of keys, a pointer to the next overflow page (if any), and a slot directory. For linear hashing, the bucket header may not need a local depth, because the level and split pointer are global. The directory, if present, is an array of page numbers. It should be stored contiguously and cached in memory. The split protocol must be carefully ordered. For extendible hashing: (1) latch the bucket and the directory; (2) if doubling, allocate new directory and copy pointers; (3) allocate new bucket; (4) redistribute keys; (5) update directory entries; (6) release latches. The order of (2) and (3) can be swapped. The key is that the directory update is atomic from the perspective of readers. For linear hashing: (1) latch bucket s; (2) allocate new bucket; (3) redistribute keys; (4) write new bucket; (5) write bucket s; (6) increment s; (7) if s == M * 2^L, increment L and reset s; (8) release latch. A reader that sees the old s will access bucket s before the split, which still contains all keys. A reader that sees the new s will access the new bucket for keys that moved. The window between (5) and (6) is critical: if a reader sees the old s but the keys have already moved, it might miss them. To avoid this, the split can keep the moved keys in both buckets until s is updated, or use a lock on the bucket. The latter is simpler. For spiral hashing, the split protocol must update the mapping function, which may affect many buckets. This is usually done by making the mapping function a function of N, and updating N atomically. The redistribution must be consistent with the new mapping. These implementation details are where the theoretical elegance meets the messy reality of page writes and crash recovery. They are also why many production systems prefer B+trees, which have well-understood concurrency and recovery protocols.

## Deletion, Shrinking, and Space Reclamation

Dynamic hashing schemes are usually described as growth structures. Insertion triggers splits, the address space expands, and the directory or split pointer moves forward. Deletion is treated as an afterthought, often because the workloads that motivate dynamic hashing are append-heavy: logs, telemetry, session stores, and event tables that grow until they are truncated or aged out. But a hash index that never reclaims space is a liability in any system with a long lifetime, and the mechanics of shrinking are genuinely harder than the mechanics of growing.

The first problem is physical deletion. A bucket page has a slot directory, and removing a key can either mark the slot as a tombstone or compact the page by shifting entries. Tombstones are cheap to write but accumulate, inflating the number of slots that must be scanned on lookup. Compaction is more expensive and changes the byte offsets of keys, which matters if the index stores offsets into a separate heap file. Most on-disk hash indexes therefore use tombstones plus a per-page free-space threshold: when tombstones exceed a fraction of the page, the page is rebuilt during a later access or by a background cleaner. This is independent of the dynamic hashing scheme, but it interacts with it because a bucket that looks full may actually be mostly tombstones. A split triggered by a page that is full of dead entries wastes a bucket. Good implementations track live key count separately from slot count and trigger splits only on live occupancy.

The second problem is structural shrinking. In extendible hashing, a bucket can be merged with its split partner when both have the same local depth and their combined live keys fit in one bucket. The merged bucket local depth decreases by one, and the directory entries that pointed to the two buckets are collapsed. If every bucket at the global depth has local depth less than d, the directory can be halved. That sounds straightforward, but the merge condition is fragile. The split partner is the bucket whose address differs in the bit at position d' - 1. Finding it requires either a reverse lookup through the directory or a pointer stored in the bucket header. Merging must also be synchronized with readers, and a crash during a merge must not lose keys. In practice, many extendible hashing implementations never shrink the directory; they rely on periodic rebuilds or accept the wasted directory space. The directory is usually small relative to the data, so this is often a reasonable choice. It stops being reasonable when the data set shrinks by an order of magnitude, because the directory remains sized for the peak.

Linear hashing has an analogous reverse operation: decrement the split pointer, merge the last bucket into its partner, and decrement the level when the pointer reaches zero. The difficulty is that linear hashing allows overflow chains. The bucket at the end of the address space may have a chain, and its partner may also have a chain. Merging them requires merging the chains, which can produce a chain longer than the original. A conservative policy merges only when both buckets and their chains fit in one primary page. This makes shrinking rare and uneven. Some implementations avoid reverse splits entirely and instead rebuild the index when the load factor falls below a threshold. Rebuilding is a global operation, but it is triggered by a condition that is already rare, and it can be done online by building a new index alongside the old one and switching over.

Spiral hashing has the hardest shrinking problem because the address mapping depends on the number of buckets. Removing a bucket changes the mapping for many keys, not just the keys in the removed bucket. A reverse split would require redistributing keys across the spiral, which is closer to a partial rehash than to a local merge. For this reason, spiral hashing is almost always grow-only in practice. If shrinking is required, the index is rebuilt.

The practical lesson is that dynamic hashing is a growth strategy, not a general-purpose dynamic set. If the workload has a stable or shrinking working set, a B+tree with page merges and a free-space map is a better fit. If the workload grows and is periodically truncated, dynamic hashing works well, but the truncation should be implemented as a wholesale reset rather than as a sequence of deletes. A reset can simply drop the directory and buckets, which is O(1) in metadata and does not require walking the index.

## Parameter Tuning and Sizing

The performance of a dynamic hash index is determined less by the choice of scheme than by a handful of parameters: bucket capacity, load threshold, hash width, and initial bucket count. These parameters are not independent, and they should be chosen together with the expected key count and the read/write mix.

Bucket capacity is the number of keys that fit in one page. It is tempting to make buckets large, because a larger bucket means fewer buckets, a shallower directory, and fewer splits. But a larger bucket also means that every lookup reads more bytes, and every split moves more keys. On a device with 4 KB pages, a bucket that holds 100 keys of 32 bytes each is already using most of the page. If the keys are larger, the bucket capacity drops, the directory depth rises, and the directory may become the dominant memory consumer. A useful rule is to size the bucket so that the page is between 70% and 90% full at the target load factor. The remaining space absorbs temporary overflow and avoids immediate split churn.

Load threshold matters most for linear hashing. Extendible hashing splits on bucket overflow, so it can run at a high load factor without long chains, at the cost of more frequent splits and a larger directory. Linear hashing splits on a global condition, so the threshold directly controls the trade-off between overflow chain length and space utilization. A threshold of 0.75 means that the index splits when the average bucket is 75% full. Under a uniform hash, the probability that a given bucket overflows is the tail of a binomial distribution. With a capacity of 100 and a mean occupancy of 75, the tail is small, but not negligible. With a capacity of 20, the same mean occupancy produces a much heavier tail, and overflow chains become common. This is why linear hashing is usually paired with larger buckets or with a lower threshold. If the workload is skewed, no threshold fully solves the problem; the hot bucket will overflow regardless of the average load. A hybrid policy that also splits a bucket when its chain exceeds a fixed length can bound the worst case, at the cost of deviating from the pure linear order.

Hash width is a subtle parameter. A 32-bit hash supports at most 2^32 distinct hash values, which is enough for billions of keys but leaves little room for directory depth. If the directory depth d approaches 32, the directory has 2^32 entries, which is impossible to store. A 64-bit hash gives more headroom, but it also means that the hash function must be well-distributed across all 64 bits. A common mistake is to use a 64-bit hash but to truncate it to 32 bits for storage, which reintroduces the collision risk. The hash width should be treated as part of the on-disk format, and it should be chosen so that the maximum expected directory depth is at least 8 bits below the hash width. For example, with a 64-bit hash, a directory depth of 40 is still feasible in principle, but the directory would be 2^40 pointers, which is far beyond memory. In practice, the directory depth is limited by the number of buckets, which is limited by the data size. A 64-bit hash is a safety margin, not a license to build a 2^40-entry directory.

Initial bucket count is often overlooked because the index is expected to grow. But a bad initial count can cause unnecessary splits early in the index life. If the initial count is too small, the first few inserts trigger a rapid sequence of splits, and the directory doubles repeatedly. If the initial count is too large, the index wastes space and may have many empty buckets. A reasonable approach is to estimate the initial key count, divide by the target bucket occupancy, and round up to a power of two for extendible hashing or to the initial M for linear hashing. The estimate does not need to be accurate; it only needs to be within an order of magnitude.

## Testing and Verification

Dynamic hash indexes are difficult to test because their correctness depends on invariants that span the directory, the buckets, and the split state. A unit test that inserts a few keys and looks them up will pass even if the split protocol has a race that only appears under concurrency. A more effective strategy is to combine randomized workload generation with invariant checking and crash injection.

The first layer is a reference model. The test harness maintains a simple hash map from keys to values, and it applies the same sequence of operations to both the reference model and the index under test. After every operation, it compares the result of a lookup for a sample of keys, and it periodically scans the entire index to verify that every key in the reference model is reachable and that no extra keys are present. This catches lost keys, duplicate keys, and routing errors.

The second layer is invariant checking. For extendible hashing, the invariants are: every directory entry points to a valid bucket; every key in a bucket has a hash whose low d' bits match the bucket address; no bucket has local depth greater than the global depth; and at least one bucket has local depth equal to the global depth. For linear hashing, the invariants are: the split pointer is in the range [0, M * 2^L); the number of buckets is M * 2^L + s; every key routes to a bucket that either contains it or whose overflow chain contains it; and the level and split pointer are consistent with the number of buckets. For spiral hashing, the invariant is that the address function maps every key to a bucket whose range contains the key hash. These invariants can be checked after every operation in a debug build, or periodically in a release build.

The third layer is crash injection. A crash-safe index must be tested by simulating a crash at every possible point in the split protocol. The test harness can use a fault-injection layer that aborts the process after a specified number of page writes, then reopens the index and verifies that all committed keys are present and that the index is internally consistent. This is the only way to catch ordering bugs that are invisible in normal execution. The test should also inject crashes during directory doubling, during bucket redistribution, and during the update of the split pointer. The recovery code should be idempotent: replaying the same log record twice must not corrupt the index.

The fourth layer is concurrency testing. A model checker or a stress test with multiple threads can expose races that are rare in practice. The test should include readers that perform lookups while writers insert and split, and it should check that readers never observe a key in a state where it is neither in the old bucket nor in the new bucket. A common technique is to use a deterministic scheduler that explores different interleavings of the split protocol. This is expensive, but it is justified for a data structure that is difficult to debug in production.

## Open Problems and Modern Context

The classical dynamic hashing schemes were designed for magnetic disks, where a random page read costs milliseconds and a sequential scan costs much less per byte. Modern storage changes the constants but not the fundamental trade-offs. On flash storage, random reads are much faster, but writes are more expensive and wear-limited. A split that writes two pages is more costly relative to a lookup than it was on a disk. This shifts the balance toward schemes that reduce write amplification, such as linear hashing with partial expansions or extendible hashing with overflow chaining. On persistent memory, the directory can be updated with atomic 8-byte writes, which makes extendible hashing directory doubling cheaper and more crash-safe. But persistent memory also makes the directory cache-line footprint matter, because every lookup touches the directory before the bucket.

The open problems are mostly about adapting the classical schemes to these new constraints. How do you make a split crash-safe without a write-ahead log? How do you bound the tail latency of a lookup when the hash function is skewed? How do you shrink the index when the workload contracts? How do you support concurrent readers and writers without a global latch on the directory? These questions do not have universal answers, and the best solution depends on the storage device, the workload, and the recovery model. They also suggest a useful exercise: implement a minimal extendible hash index, force it through a randomized crash-and-recover test, and measure the point at which the directory, not the buckets, becomes the bottleneck. The result is usually a clearer intuition for why the directory depth, the hash width, and the bucket capacity are not independent knobs.
