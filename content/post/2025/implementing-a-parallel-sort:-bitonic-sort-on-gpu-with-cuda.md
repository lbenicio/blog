---
title: "Implementing A Parallel Sort: Bitonic Sort On Gpu With Cuda"
description: "A comprehensive technical exploration of implementing a parallel sort: bitonic sort on gpu with cuda, covering key concepts, practical implementations, and real-world applications."
date: "2025-11-14"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Implementing-A-Parallel-Sort-Bitonic-Sort-On-Gpu-With-Cuda.png"
coverAlt: "Technical visualization representing implementing a parallel sort: bitonic sort on gpu with cuda"
---

# The Paradox of Sorting in a Parallel World

We live in an age of inversion. For decades, the central dogma of computing performance was simple: make the clock run faster. We built skyscrapers of silicon, stacking transistors ever denser, just to watch the frequency counter tick higher. Software developers, myself included, were largely shielded from the architectural complexities beneath us. If your code was slow, you waited eighteen months for a new processor that, thanks to Moore’s Law, would run it twice as fast. It was a golden age of free lunches.

That lunch is over. The clock stopped. The tower of single-core performance has met the wall of power dissipation and quantum tunneling. The free lunch was revoked, and in its place, the industry served us a different, more complicated meal: the parallel architecture. We didn't get a faster car; we got a thousand horses hitched to a single cart. And now, the fundamental question of computer science has changed. It is no longer, "How fast can we do this?" but rather, "Can we do this at all in parallel?"

This tectonic shift is nowhere more apparent, and more painful, than in the world of sorting. Sorting is the bedrock. It is the R&D tax of algorithms. Databases, search engines, data analytics, computational geometry, and graph processing—all of them depend on the humble act of arranging data. For a single core, the problem is considered solved. Quicksort, Heapsort, Mergesort: we have known for decades that the lower bound for comparison-based sorting is _O(n log n)_, and we hit that bound with engineering precision. But in a massively parallel world, those elegant, recursive, divide-and-conquer strategies suddenly look awkward, brittle, and slow.

Consider the classic Quicksort. Its genius is its asymmetry. It repeatedly partitions the array into two subarrays based on a pivot, sending smaller elements to one side and larger to the other. The divide step is inherently sequential—you must choose a pivot and then rearrange elements relative to that pivot. Even the most clever parallel quicksort implementations suffer from load imbalance (one partition may be much larger than the other) and a serial bottleneck at the partitioning step. Merge sort, on the other hand, offers a more balanced tree, but its merge phase remains tricky to parallelize efficiently. The bottom-up merge sort can be parallelized across independent merges at each level, but the number of merges halves at each level, leading to diminishing parallelism.

Enter the Graphics Processing Unit (GPU). Originally designed for rendering millions of triangles in parallel, GPUs have evolved into general-purpose compute engines (GPGPU) capable of executing thousands of lightweight threads simultaneously. With CUDA (Compute Unified Device Architecture), NVIDIA provides a programming model that allows us to harness this massive parallelism. The GPU is not a faster CPU; it is a different beast. It excels at data-parallel tasks where the same operation is applied to many data elements independently. Sorting, however, is a fundamentally data-dependent task—the outcome of one comparison determines the next operation. This dependency chain makes it challenging to map sorting onto a SIMD (Single Instruction, Multiple Thread) architecture.

But there is a sorting algorithm that, despite being suboptimal on a single core, shines in the parallel world: **Bitonic Sort**. Its regular, data-independent structure perfectly matches the GPU's execution model. It requires no pivot selection, no recursive partitioning, and no load balancing. Instead, it builds a predefined sequence of deterministic comparisons that guarantee a sorted output regardless of the input. This makes Bitonic Sort one of the most GPU-friendly sorting algorithms, and understanding it provides deep insights into parallel algorithm design.

In this article, we will dissect Bitonic Sort from its theoretical foundations to a practical CUDA implementation. We will explore why it works, how to implement it efficiently on a GPU, and what trade-offs we face. We'll also discuss optimizations like shared memory usage, coalesced memory access, and warp-level primitives. By the end, you'll have a complete, production-ready Bitonic Sort kernel in CUDA and a solid understanding of how to think about sorting in a massively parallel world.

---

## 1. The Sorting Landscape: Why Not Just Use Quicksort?

Before diving into Bitonic Sort, let's understand why conventional sorting algorithms struggle on GPUs. The GPU's strength lies in its ability to run thousands of threads in lockstep (within a warp of 32 threads). This is a SIMD-like model where each thread executes the same instruction on different data. Branch divergence—when threads in the same warp take different execution paths—can cripple performance.

### 1.1 Serial Dependencies and the Memory Wall

Quicksort's partitioning step is inherently serial. Even if you parallelize the recursive calls after partitioning, the initial partition itself is a single point of failure. On a GPU, you would need to launch a kernel for each partition, and the overhead of kernel launches, plus the irregular memory access patterns, makes Quicksort impractical. Some parallel quicksort variants use sampling to select multiple pivots and partition into multiple buckets, but these still suffer from load imbalance and irregular work.

Merge sort, on the other hand, appears more parallelizable. The bottom-up merge sort can work on independent pairs of sorted subarrays. For example, if you have an array of size N, you can start with sorted pairs of size 1, then merge those into sorted pairs of size 2, then size 4, and so on. At each level, you have N/2 merges for size 1, N/4 for size 2, etc. The number of merges decreases, but they can be done in parallel. However, the merging step itself is not trivial to parallelize. A naive merge that uses a single thread per merge becomes bottlenecked. You can use a two-phase merge algorithm that uses binary search to find positions, which is more parallel, but that introduces logarithmic complexity and memory latency.

### 1.2 The GPU Execution Model

A modern GPU (e.g., NVIDIA A100) has over 6,000 CUDA cores grouped into Streaming Multiprocessors (SMs). Each SM executes warps of 32 threads. Threads in a warp share an instruction unit; if they diverge (e.g., if statements), the warp serializes both paths, reducing throughput. Memory access is also crucial: global memory is high-bandwidth but high-latency (hundreds of cycles). To hide latency, the GPU relies on massive parallelism—by having many warps resident, it can switch to another warp while one waits for memory. But this only works if threads within a warp access memory in a coalesced manner, i.e., consecutive threads access consecutive memory addresses.

For sorting, these constraints mean:

- The algorithm must have regular, predictable memory access patterns (no random swaps based on data values).
- The control flow must be uniform across threads in a warp (no data-dependent branches).
- The algorithm should be able to use all available threads at each phase.

Bitonic Sort satisfies all these constraints beautifully.

---

## 2. Bitonic Sort: Theory and Fundamentals

Bitonic Sort was invented by Kenneth Batcher in 1968 as part of his work on sorting networks. A sorting network is a fixed sequence of comparison-exchange operations (comparators) that sorts any input sequence of a given length. Unlike comparison-based algorithms like Quicksort, sorting networks are oblivious to the data—the comparisons are predetermined, and the outcome only determines whether a swap occurs. This makes them ideal for hardware implementation or parallel execution.

### 2.1 Bitonic Sequences

The key concept is a **bitonic sequence**. A sequence a[0..n-1] is bitonic if it first monotonically increases and then monotonically decreases (or vice versa). More formally, there exists an index k such that:

- a[0] ≤ a[1] ≤ ... ≤ a[k] ≥ a[k+1] ≥ ... ≥ a[n-1]

Or a cyclic shift of such a sequence. For example, [1, 3, 5, 7, 6, 4, 2] is bitonic because it increases from 1 to 7 then decreases to 2. A single element is trivially bitonic. Two elements are always bitonic.

The power of bitonic sequences is that you can sort them efficiently using a simple operation called **bitonic merge**. Given a bitonic sequence of length n (where n is a power of two), you can sort it into a single monotonic (say, ascending) sequence using a divide-and-conquer approach:

1. Compare-and-swap a[i] with a[i + n/2] for all i in [0, n/2).
2. After this step, the first half becomes a bitonic sequence (all elements smaller than those in the second half), and the second half becomes another bitonic sequence (all elements larger).
3. Recursively apply the same process to each half until the whole sequence is sorted.

This is known as the **bitonic merge** step. The number of comparators required for merging a bitonic sequence of length n is (log n) stages, each consisting of n/2 comparators. The total number of comparators to sort an arbitrary sequence using Bitonic Sort is O(n (log n)^2).

### 2.2 The Bitonic Sort Algorithm

Given an unsorted array of length N (a power of two), Bitonic Sort works as follows:

- Phase 1: Build bitonic sequences of length 2 from adjacent pairs. (Actually, each pair is already bitonic.)
- Phase 2: For each bitonic sequence of length 4, apply a bitonic merge to sort it into a single ascending sequence. But wait—after sorting, the sequence is no longer bitonic. However, the algorithm alternates the direction: it builds bitonic sequences of increasing length, each time merging them into a sequence that is first increasing then decreasing (or vice versa) so that the next larger merge can work.

The standard construction uses a series of steps where we first double the size of the bitonic sequences and then sort them in alternating directions. Specifically:

- For k = 1, 2, 4, ... up to N/2:
  - For j = k/2, k/4, ..., 1:
    - Compare-and-swap elements that are j apart, with the direction (ascending or descending) depending on the bit (k & j) or similar rule.

In practice, the algorithm is often described with two nested loops: an outer loop over subarray size, and an inner loop over the step size. The pseudocode:

```
for (k = 2; k <= N; k *= 2) {
    for (j = k/2; j > 0; j /= 2) {
        for (i = 0; i < N; i++) {
            int ixj = i ^ j; // index of the partner
            if (ixj > i) {
                // Determine direction based on (i & k) == 0
                bool ascending = ((i & k) == 0);
                if (ascending ? (a[i] > a[ixj]) : (a[i] < a[ixj]))
                    swap(a[i], a[ixj]);
            }
        }
    }
}
```

This is a classic bitonic sort for a single thread. The key observation: the comparisons are between elements at indices i and i^j (XOR). The XOR pattern ensures that the pairs are formed in a regular, data-independent manner. The direction of sorting depends on the least significant bit of i relative to k.

### 2.3 Example Walkthrough

Let's sort [3, 7, 4, 8, 6, 2, 1, 5] using Bitonic Sort (N=8).

We'll follow the algorithm:

**k=2 (phase 1: build bitonic sequences of length 2)**
j = 1 (since k/2=1)
Loop i from 0 to 7:

- i=0: partner = 0 ^ 1 = 1. ascending = ((0&2)==0) true. Compare a[0]=3 with a[1]=7: 3<7, no swap.
- i=1: partner = 1^1=0 < i, skip.
- i=2: partner=3. ascending true. 4<8, no swap.
- i=3: skip.
- i=4: partner=5. ascending true. 6>2 => swap. Now a[4]=2, a[5]=6.
- i=5: skip.
- i=6: partner=7. ascending true. 1<5, no swap.
- i=7: skip.
  After j=1, sequences of length 2: each pair is sorted ascending. Result: [3,7,4,8,2,6,1,5].

But note: the bitonic property requires alternating directions for the next stage. Actually, after k=2, we have bitonic sequences of length 2 (each sorted in ascending order). But for k=4, we need to combine two bitonic sequences of length 2 into a bitonic sequence of length 4. The algorithm will then handle that.

**k=4 (phase 2: build bitonic sequences of length 4)**
j = 2 (k/2)
Loop i:

- i=0: partner=2. ascending = ((0&4)==0) true. Compare a[0]=3, a[2]=4: 3<4 no swap.
- i=1: partner=3. ascending true. 7>8? no.
- i=2: partner=0 skip.
- i=3: skip.
- i=4: partner=6. ascending true. 2<1? no. a[4]=2 > a[6]=1 => swap. Now a[4]=1, a[6]=2.
- i=5: partner=7. ascending true. 6>5 => swap. a[5]=5, a[7]=6.
- i=6,7: skip.
  After j=2, we now have for each pair of two-element subarrays? Actually, the algorithm continues with j=1 again. Wait, the inner loop goes j = k/2 down to 1, halving each time. So after j=2, we have j=1.

j=1:
Loop i:

- i=0: partner=1. ascending = ((0&4)==0) true. Compare a[0]=3, a[1]=7: no swap.
- i=2: partner=3. ascending true. a[2]=4, a[3]=8: no swap.
- i=4: partner=5. ascending true. a[4]=1, a[5]=5: no swap.
- i=6: partner=7. ascending true. a[6]=2, a[7]=6: no swap.
  So after k=4, we have sorted the first four elements (3,7,4,8? Actually they are ascending: [3,7,4,8] is not sorted; but remember, the algorithm only guarantees that after this phase the sequence becomes bitonic? Let's check: For the first half (indices 0-3), after the merges with direction alternating, should become ascending then descending? The standard bitonic sort for k=4: first we have two sorted ascending sequences of length 2: [3,7] and [4,8]. We then combine them into a bitonic sequence by first sorting the two halves in opposite directions. Actually, the algorithm we are using (the XOR-based version) has a different interpretation: at each stage, it builds a larger bitonic sequence that is ascending then descending (or vice versa) depending on the bit patterns.

Let's trace more carefully using the known correct algorithm. It's easier to understand the algorithm visually.

Better approach: Use the classic definition:

1. Start with sequences of length 2 sorted in ascending order.
2. For each doubling, we first sort the two halves in opposite directions to create a bitonic sequence of double size, then we perform a bitonic merge to sort that bitonic sequence in the desired direction.

But the XOR algorithm combines these steps. The typical implementation often uses a single-threaded version like:

```
void bitonicSort(int* data, int N) {
    for (int k = 2; k <= N; k *= 2) {
        for (int j = k / 2; j > 0; j /= 2) {
            for (int i = 0; i < N; i++) {
                int ixj = i ^ j;
                if (ixj > i) {
                    if ((i & k) == 0) {
                        if (data[i] > data[ixj]) swap(data[i], data[ixj]);
                    } else {
                        if (data[i] < data[ixj]) swap(data[i], data[ixj]);
                    }
                }
            }
        }
    }
}
```

This is correct for power-of-two lengths. Let's test it on our data [3,7,4,8,6,2,1,5].

We'll run through the loops manually.

N=8.

**k=2:**
j=1:
i=0: ixj=1 > i. (i&2)==0 => ascending sort. data[0]=3, data[1]=7, 3<7 no swap.
i=1: ixj=0 < i skip.
i=2: ixj=3 > i. (2&2)!=0 => descending sort. data[2]=4, data[3]=8, 4<8 -> condition for descending: if (data[i] < data[ixj]) swap. Yes, so swap -> now a[2]=8, a[3]=4.
i=3: skip.
i=4: ixj=5 > i. (4&2)==0 => ascending. data[4]=6, data[5]=2, 6>2 -> swap -> a[4]=2, a[5]=6.
i=5: skip.
i=6: ixj=7 > i. (6&2)!=0 => descending. data[6]=1, data[7]=5, 1<5 -> swap -> a[6]=5, a[7]=1.

After k=2: array = [3,7,8,4,2,6,5,1]

Now we have bitonic sequences of length 2 in alternating directions? Actually, for each pair (0-1) ascending, (2-3) descending, (4-5) ascending, (6-7) descending. So we've built bitonic sequences of length 2: each is already sorted in one direction (the first two ascending, next two descending, etc.). This matches the requirement for the next stage.

**k=4:**
j=2:
i=0: ixj=2 > i. (0&4)==0 => ascending. data[0]=3, data[2]=8, 3<8 no swap.
i=1: ixj=3 > i. (1&4)==0 => ascending. data[1]=7, data[3]=4, 7>4 -> swap => a[1]=4, a[3]=7.
i=2: skip.
i=3: skip.
i=4: ixj=6 > i. (4&4)==0 => ascending. data[4]=2, data[6]=5, 2<5 no swap.
i=5: ixj=7 > i. (5&4)==0 => ascending. data[5]=6, data[7]=1, 6>1 -> swap => a[5]=1, a[7]=6.
i=6: skip.
i=7: skip.

After j=2: array = [3,4,8,7,2,1,5,6]

Now j=1:
i=0: ixj=1 > i. (0&4)==0 => ascending. data[0]=3, data[1]=4, no swap.
i=1: skip.
i=2: ixj=3 > i. (2&4)==0 => ascending. data[2]=8, data[3]=7, 8>7 swap => a[2]=7, a[3]=8.
i=3: skip.
i=4: ixj=5 > i. (4&4)==0 => ascending. data[4]=2, data[5]=1, 2>1 swap => a[4]=1, a[5]=2.
i=5: skip.
i=6: ixj=7 > i. (6&4)==0 => ascending. data[6]=5, data[7]=6, no swap.
i=7: skip.

After j=1: array = [3,4,7,8,1,2,5,6]

Now after k=4: we have two sorted halves? First half [3,4,7,8] is ascending, second half [1,2,5,6] is ascending. But the bitonic property for the whole array? Actually, the array is now two sorted ascending sequences of length 4. The next step will build a bitonic sequence of length 8 from them.

**k=8:**
j=4:
i=0: ixj=4 > i. (0&8)==0 => ascending. data[0]=3, data[4]=1, 3>1 swap => a[0]=1, a[4]=3.
i=1: ixj=5 > i. ascending. data[1]=4, data[5]=2, 4>2 swap => a[1]=2, a[5]=4.
i=2: ixj=6 > i. ascending. data[2]=7, data[6]=5, 7>5 swap => a[2]=5, a[6]=7.
i=3: ixj=7 > i. ascending. data[3]=8, data[7]=6, 8>6 swap => a[3]=6, a[7]=8.
i=4: skip.
etc.

After j=4: array = [1,2,5,6,3,4,7,8]

Now j=2:
i=0: ixj=2 > i. ascending. data[0]=1, data[2]=5, no swap.
i=1: ixj=3 > i. ascending. data[1]=2, data[3]=6, no swap.
i=2: skip.
i=3: skip.
i=4: ixj=6 > i. ascending. data[4]=3, data[6]=7, no swap.
i=5: ixj=7 > i. ascending. data[5]=4, data[7]=8, no swap.
i=6: skip.
i=7: skip.

After j=2: no changes.

j=1:
i=0: ixj=1 > i. ascending. data[0]=1, data[1]=2, no swap.
i=2: ixj=3 > i. ascending. data[2]=5, data[3]=6, no swap.
i=4: ixj=5 > i. ascending. data[4]=3, data[5]=4, no swap.
i=6: ixj=7 > i. ascending. data[6]=7, data[7]=8, no swap.

Final array: [1,2,5,6,3,4,7,8] which is not fully sorted! Wait, that's not correct. The algorithm should produce a fully sorted ascending array. There's an error in our manual trace? Let's double-check the algorithm logic.

The standard bitonic sort using this XOR method should produce a fully sorted array at the end. Our trace shows after k=8, we have [1,2,5,6,3,4,7,8] which is not globally sorted (3 and 4 are out of order relative to 5 and 6). So something is wrong.

Perhaps the direction condition should be based on (i & k) == 0? That's what we used. But in many implementations, the condition is ((i / k) % 2 == 0) or similar. The XOR version is often written with a different nesting.

Let's examine the typical textbook algorithm:

```
for (k = 2; k <= N; k <<= 1) {
    for (j = k >> 1; j > 0; j >>= 1) {
        for (i = 0; i < N; i++) {
            int ixj = i ^ j;
            if (ixj > i) {
                if ((i & k) == 0) { // increasing direction for first half of each block
                    if (a[i] > a[ixj]) swap;
                } else { // decreasing for second half
                    if (a[i] < a[ixj]) swap;
                }
            }
        }
    }
}
```

Let's test on a known case: N=8, input [3,7,4,8,6,2,1,5]. I recall that bitonic sort works, so our manual trace must have an error. Let's re-run with a different approach: using Python mental simulation or a small program in mind.

Better to simulate algorithmically:

We'll create a table of i and partner for each step.

**k=2:**
j=1: pairs: (0,1), (2,3), (4,5), (6,7). For each pair:

- (0,1): i=0, (0&2)==0 => ascending. Compare a[0]=3, a[1]=7: no swap.
- (2,3): i=2, (2&2)!=0 => descending. Compare a[2]=4, a[3]=8: since descending, swap if a[i] < a[partner] => 4<8 => swap => a[2]=8, a[3]=4.
- (4,5): i=4, (4&2)==0 => ascending. a[4]=6, a[5]=2 => 6>2 => swap => a[4]=2, a[5]=6.
- (6,7): i=6, (6&2)!=0 => descending. a[6]=1, a[7]=5 => 1<5 => swap => a[6]=5, a[7]=1.
  After k=2: [3,7,8,4,2,6,5,1] as before.

**k=4:**
j=2: pairs: (0,2), (1,3), (4,6), (5,7). Direction based on (i & 4)==0:

- (0,2): i=0, (0&4)==0 => ascending. a[0]=3, a[2]=8 => 3<8 no swap.
- (1,3): i=1, (1&4)==0 => ascending. a[1]=7, a[3]=4 => 7>4 => swap => a[1]=4, a[3]=7.
- (4,6): i=4, (4&4)==0 => ascending. a[4]=2, a[6]=5 => 2<5 no swap.
- (5,7): i=5, (5&4)==0 => ascending. a[5]=6, a[7]=1 => 6>1 => swap => a[5]=1, a[7]=6.
  After j=2: [3,4,8,7,2,1,5,6] (same as before)

Now j=1: pairs: (0,1), (2,3), (4,5), (6,7). Direction based on (i & 4)==0:

- (0,1): i=0, ascending. a[0]=3, a[1]=4 => no swap.
- (2,3): i=2, ascending. a[2]=8, a[3]=7 => 8>7 swap => a[2]=7, a[3]=8.
- (4,5): i=4, ascending. a[4]=2, a[5]=1 => 2>1 swap => a[4]=1, a[5]=2.
- (6,7): i=6, ascending. a[6]=5, a[7]=6 => no swap.
  After j=1: [3,4,7,8,1,2,5,6] (same)

Now **k=8:**
j=4: pairs: (0,4), (1,5), (2,6), (3,7). Direction based on (i & 8)==0 (8 is 1000 binary). For i=0..3, (i&8)==0 => ascending. For i=4..7, (i&8)!=0 => descending.

- (0,4): i=0, ascending. a[0]=3, a[4]=1 => 3>1 swap => a[0]=1, a[4]=3.
- (1,5): i=1, ascending. a[1]=4, a[5]=2 => 4>2 swap => a[1]=2, a[5]=4.
- (2,6): i=2, ascending. a[2]=7, a[6]=5 => 7>5 swap => a[2]=5, a[6]=7.
- (3,7): i=3, ascending. a[3]=8, a[7]=6 => 8>6 swap => a[3]=6, a[7]=8.
  After j=4: [1,2,5,6,3,4,7,8] (again)

Now j=2: pairs: (0,2), (1,3), (4,6), (5,7). Direction based on (i & 8)==0? For i=0: ascending; i=1: ascending; i=2: ascending; i=3: ascending; i=4: descending; i=5: descending; etc.

- (0,2): i=0, ascending. a[0]=1, a[2]=5 => no swap.
- (1,3): i=1, ascending. a[1]=2, a[3]=6 => no swap.
- (4,6): i=4, descending. a[4]=3, a[6]=7 => 3<7 => descending condition: if (a[i] < a[partner]) swap? No, descending means we want a[i] >= a[partner] after swap; condition is a[i] < a[partner] then swap. So 3<7 => swap => a[4]=7, a[6]=3.
- (5,7): i=5, descending. a[5]=4, a[7]=8 => 4<8 => swap => a[5]=8, a[7]=4.
  After j=2: [1,2,5,6,7,8,3,4]

Now j=1: pairs: (0,1), (2,3), (4,5), (6,7). Directions:

- (0,1): i=0 ascending. a[0]=1, a[1]=2 no swap.
- (2,3): i=2 ascending. a[2]=5, a[3]=6 no swap.
- (4,5): i=4 descending. a[4]=7, a[5]=8 => 7<8? descending: if(a[i] < a[partner]) swap => 7<8 => swap => a[4]=8, a[5]=7.
- (6,7): i=6 descending. a[6]=3, a[7]=4 => 3<4 => swap => a[6]=4, a[7]=3.
  After j=1: [1,2,5,6,8,7,4,3]

Now final array: [1,2,5,6,8,7,4,3]. Still not globally sorted! So either the algorithm as implemented is not correct, or we misinterpret the direction. Let's verify with a known correct implementation.

Actually, I recall that the bitonic sort algorithm commonly used in parallel computing has a slightly different structure. The typical CUDA implementation uses a "bitonic sort" that sorts both ascending and descending as needed. Let's look up the standard code from NVIDIA's SDK or textbooks. The classic GPU bitonic sort from "GPU Gems" or "Programming Massively Parallel Processors" uses a different indexing:

The algorithm they use is:

```
for (unsigned int k = 2; k <= N; k <<= 1) {
    for (unsigned int j = k >> 1; j > 0; j >>= 1) {
        unsigned int i = threadIdx.x;
        unsigned int ixj = i ^ j;
        if (ixj > i) {
            if ((i & k) == 0) {
                if (a[i] > a[ixj]) swap(a[i], a[ixj]);
            } else {
                if (a[i] < a[ixj]) swap(a[i], a[ixj]);
            }
            __syncthreads();
        }
    }
}
```

This is exactly what we implemented. It should work. So why did our manual trace fail? Perhaps we made an error in deciding which i values to process. In the code, we only process when ixj < i to avoid double swaps. That part is correct. But note: the condition `(i & k) == 0` determines the direction. For the first half of the block (size k), it's ascending; for the second half, descending. That's correct. However, in our trace for k=8, after the j=4 step, we swapped (0,4) etc., and then for j=2 and j=1 we applied swaps. Let's double-check the final result with a known correct simulation.

I'll write a quick mental simulation of the algorithm in Python style using a list. Let's do it step by step with careful attention.

Initialize arr = [3,7,4,8,6,2,1,5]
We'll index 0..7.

Step k=2:
j=1:
for i in 0..7:
if ixj = i^1 > i:
dir = ascending if (i&2)==0 else descending
perform swap if needed.
Let's compute for each i:
i=0: ixj=1 >0, dir asc (0&2=0). cmp a[0]=3, a[1]=7 => 3<7 no swap.
i=1: ixj=0 <1 skip.
i=2: ixj=3 >2, dir desc (2&2=2 !=0). cmp a[2]=4, a[3]=8 => descending condition: if a[i] < a[ixj] swap. 4<8 => swap => now a[2]=8, a[3]=4.
i=3: ixj=2 <3 skip.
i=4: ixj=5 >4, dir asc (4&2=0). cmp a[4]=6, a[5]=2 => 6>2 => swap => a[4]=2, a[5]=6.
i=5: ixj=4 <5 skip.
i=6: ixj=7 >6, dir desc (6&2=2 !=0). cmp a[6]=1, a[7]=5 => 1<5 => swap => a[6]=5, a[7]=1.
i=7: skip.
After k=2: [3,7,8,4,2,6,5,1] correct.

Step k=4:
j=2:
for i in 0..7:
ixj = i^2:
i=0: ixj=2 >0, dir asc (0&4=0). a[0]=3, a[2]=8 => 3<8 no swap.
i=1: ixj=3 >1, dir asc (1&4=0). a[1]=7, a[3]=4 => 7>4 => swap => a[1]=4, a[3]=7.
i=2: ixj=0 <2 skip.
i=3: ixj=1 <3 skip.
i=4: ixj=6 >4, dir asc (4&4=0? 4&4=4 !=0, so actually dir desc? Wait, (i & k) where k=4, i=4 => 4&4=4, not zero, so dir desc. Let's recalc: (4 & 4) == 0? 4 in binary 100, 4 is 100, bitwise AND = 100 !=0, so dir is descending. But earlier I said ascending. This is a mistake! For k=4, the condition (i&k)==0 defines direction. For i=4, (4 & 4) !=0, so direction is descending. For i=5, (5 & 4) = 4 !=0 => descending. For i=0..3, (i & 4)=0 => ascending. So our earlier direction for i=4 and i=5 was wrong. Let's correct.

        i=4: ixj=6 >4, dir desc (since 4&4 !=0). a[4]=2, a[6]=5. descending condition: if a[i] < a[ixj] swap => 2<5 => swap => a[4]=5, a[6]=2.
        i=5: ixj=7 >5, dir desc (5&4=4 !=0). a[5]=6, a[7]=1 => 6<1? no, 6>1, so no swap.
        i=6: skip (ixj=4<6).
        i=7: skip.
        After j=2: array becomes [3,4,8,7,5,6,2,1]? Let's list: indices 0:3, 1:4 (swapped), 2:8, 3:7, 4:5 (swapped from 2 to 5), 5:6, 6:2, 7:1. So arr = [3,4,8,7,5,6,2,1].

    Now j=1:
        ixj = i^1:
        i=0: ixj=1 >0, dir asc (0&4=0). a[0]=3, a[1]=4 => no swap.
        i=1: skip.
        i=2: ixj=3 >2, dir asc (2&4=0). a[2]=8, a[3]=7 => 8>7 swap => a[2]=7, a[3]=8.
        i=3: skip.
        i=4: ixj=5 >4, dir desc (4&4!=0). a[4]=5, a[5]=6 => descending: if a[i] < a[ixj] swap? 5<6 => swap => a[4]=6, a[5]=5.
        i=5: skip.
        i=6: ixj=7 >6, dir desc (6&4=4 !=0). a[6]=2, a[7]=1 => 2<1? no => no swap.
        i=7: skip.
        After j=1: arr = [3,4,7,8,6,5,2,1].

Now after k=4, we have two halves: first half [3,4,7,8] ascending, second half [6,5,2,1] descending? Actually second half is [6,5,2,1] which is descending. So overall the array is bitonic (first ascending then descending). That matches expectation.

Step k=8:
j=4:
ixj = i^4:
i=0: ixj=4 >0, dir asc (0&8=0). a[0]=3, a[4]=6 => 3<6 no swap.
i=1: ixj=5 >1, dir asc (1&8=0). a[1]=4, a[5]=5 => 4<5 no swap.
i=2: ixj=6 >2, dir asc (2&8=0). a[2]=7, a[6]=2 => 7>2 => swap => a[2]=2, a[6]=7.
i=3: ixj=7 >3, dir asc (3&8=0). a[3]=8, a[7]=1 => 8>1 => swap => a[3]=1, a[7]=8.
i=4: ixj=0 <4 skip.
i=5: ixj=1 <5 skip.
i=6: ixj=2 <6 skip.
i=7: ixj=3 <7 skip.
After j=4: arr = [3,4,2,1,6,5,7,8] (since indices: 0:3,1:4,2:2,3:1,4:6,5:5,6:7,7:8)

j=2:
ixj = i^2:
i=0: ixj=2 >0, dir asc (0&8=0). a[0]=3, a[2]=2 => 3>2 swap => a[0]=2, a[2]=3.
i=1: ixj=3 >1, dir asc (1&8=0). a[1]=4, a[3]=1 => 4>1 swap => a[1]=1, a[3]=4.
i=2: skip.
i=3: skip.
i=4: ixj=6 >4, dir desc (4&8=0? 4&8=0, actually (4&8) == 0, so dir asc? Wait, for k=8, condition is (i & 8) == 0. For i=4, 4&8=0, so ascending. For i=5, also ascending. For i=6, 6&8=0 -> ascending. For i=7, 7&8=0 -> ascending. So all i from 0 to 7 have (i&8)==0 because 8's binary is 1000, and 0..7 have bits only in lower 3 bits. So for k=8, the direction is ascending for all i? That can't be right because we need to build a single ascending output. Actually, when k=N (the final stage), the entire array is a bitonic sequence that needs to be sorted in one direction (say ascending). So indeed, for k=8, the direction should be ascending for all i. So our earlier assumption that second half is descending is wrong for the last stage. For the last stage, we want to sort the entire bitonic sequence into one monotonic order. So (i & k) == 0 for all i when k >= N (since k is a power of two and N is the size, i ranges 0..N-1, so i&k is always 0 for k > max bit of i). So direction ascending for all. Let's continue.

    i=4: ixj=6 >4, dir asc. a[4]=6, a[6]=7 => 6<7 no swap.
    i=5: ixj=7 >5, dir asc. a[5]=5, a[7]=8 => 5<8 no swap.
    i=6: skip.
    i=7: skip.
    After j=2: arr = [2,1,3,4,6,5,7,8]

j=1:
ixj = i^1:
i=0: ixj=1 >0, dir asc. a[0]=2, a[1]=1 => 2>1 swap => a[0]=1, a[1]=2.
i=1: skip.
i=2: ixj=3 >2, dir asc. a[2]=3, a[3]=4 => no swap.
i=3: skip.
i=4: ixj=5 >4, dir asc. a[4]=6, a[5]=5 => 6>5 swap => a[4]=5, a[5]=6.
i=5: skip.
i=6: ixj=7 >6, dir asc. a[6]=7, a[7]=8 => no swap.
i=7: skip.
After j=1: arr = [1,2,3,4,5,6,7,8] -> Fully sorted! Success.

So the algorithm works. Our earlier manual trace had an error in the direction assumption for i=4 and i=5 in the k=4 step, which we corrected. So the XOR-based bitonic sort is correct. This exercise shows the importance of careful implementation.

Now that we understand the theory and have verified the algorithm, we can proceed to parallelize it on the GPU.

---

## 3. Mapping Bitonic Sort to CUDA

The GPU's strength is its ability to execute thousands of threads. In the single-threaded version, we have three nested loops. The innermost loop (over i) is where all the comparisons happen. For a given k and j, each comparison is independent of others. This is a perfect opportunity for data parallelism.

### 3.1 Naive Global Memory Kernel

The simplest approach: launch a 1D grid of threads, each responsible for one element. For each (k, j) pair, we run a separate kernel, or we can have a single kernel that iterates over all (k,j) pairs using loops with synchronization. However, CUDA does not support global synchronization across all threads within a kernel (except via multiple kernel launches or cooperative groups). For simplicity, we can launch a new kernel for each (k,j) pair. That would be O((log N)^2) kernel launches, which has high overhead. Alternatively, we can put the loops inside the kernel and use `__syncthreads()` to synchronize threads within a block. But `__syncthreads()` only synchronizes threads in a single block, not across the whole grid. Therefore, we can only sort data that fits within a block (typically 1024 threads for modern GPUs). For larger arrays, we need to use multiple blocks with inter-block communication or use a two-level approach.

One common method for sorting large arrays on GPU is to first sort blocks using shared memory (block-level bitonic sort), then merge blocks using a more global algorithm (e.g., a bitonic merge across blocks using global memory or a multi-block merge network). However, that becomes complex. For this article, we will focus on sorting a single block of data that fits in shared memory. This is useful for small arrays (up to a few thousand) or as a building block for larger sorts. Many practical GPU sorts (like Thrust's radix sort) use different approaches. But understanding bitonic sort at the block level is fundamental.

### 3.2 Shared Memory Block-Level Bitonic Sort

We will assign each block to sort a segment of the array (e.g., 512 or 1024 elements). The kernel will load the data from global memory into shared memory, perform the bitonic sort in shared memory, and then write back. Shared memory has low latency and high bandwidth, and we can use `__syncthreads()` to synchronize after each step.

The algorithm inside the kernel will mimic the nested loops but using thread index as the i index. Each thread handles one element (or maybe multiple elements per thread for larger blocks). The pattern of comparisons is data-independent, so no branch divergence beyond the direction condition, which depends only on the thread index and loop variables, not on data values. This is perfect for SIMD.

Let's write the kernel:

```cuda
__global__ void bitonicSortShared(int *g_data, int n) {
    extern __shared__ int s_data[];
    int tid = threadIdx.x;
    // Load data
    s_data[tid] = g_data[tid];
    __syncthreads();

    // Bitonic sort
    for (unsigned int k = 2; k <= n; k <<= 1) {
        for (unsigned int j = k >> 1; j > 0; j >>= 1) {
            unsigned int ixj = tid ^ j;
            if (ixj > tid) {
                if ((tid & k) == 0) {
                    if (s_data[tid] > s_data[ixj]) {
                        int temp = s_data[tid];
                        s_data[tid] = s_data[ixj];
                        s_data[ixj] = temp;
                    }
                } else {
                    if (s_data[tid] < s_data[ixj]) {
                        int temp = s_data[tid];
                        s_data[tid] = s_data[ixj];
                        s_data[ixj] = temp;
                    }
                }
            }
            __syncthreads();
        }
    }

    // Write back
    g_data[tid] = s_data[tid];
}
```

Note: We use `extern __shared__ int s_data[]` to declare dynamic shared memory. The size is specified at kernel launch. Also, the condition `ixj > tid` ensures only one thread per pair performs the comparison and swap to avoid double swapping. But wait: after we swap, the other thread's data is also changed. However, since we only do the swap on one side, and we synchronize after each step, the other thread will see the updated value in the next step. That's fine.

One subtlety: The ordering of comparisons is crucial. The loops over k and j must be sequential with synchronization between each j iteration. The `__syncthreads()` ensures that all threads have finished the current step before proceeding.

### 3.3 Handling Arbitrary Array Sizes with Multiple Blocks

For arrays larger than the maximum block size (e.g., 1024 on many GPUs), we need to sort across blocks. There are several strategies:

1. **Bitonic Merge of Sorted Blocks**: Sort each block independently (using the shared memory kernel above), then perform a global bitonic merge across blocks using global memory operations. This requires a two-level algorithm where blocks are the "elements" of the next level. The merge step would compare and swap entire blocks? No, we need to compare individual elements across blocks. One approach: after sorting each block, treat the whole array as a sequence of sorted blocks, then merge them in a bitonic tree using a kernel that operates on pairs of blocks. This is complex.

2. **Radix Sort**: For large arrays, radix sort is often more efficient. Bitonic sort is primarily useful for small-to-medium sizes or as a building block.

3. **Using Thrust Library**: NVIDIA's Thrust library provides `thrust::sort` which is optimized for GPUs and uses a hybrid approach (radix sort for integers, merge sort for others). For most applications, you should use Thrust.

However, for educational purposes, we will stick with a single-block sort. Later we can discuss how to extend.

### 3.4 Performance Considerations

Even within a single block, performance can be improved:

- **Bank Conflicts**: Shared memory is divided into banks. Simultaneous accesses by multiple threads to the same bank cause conflicts. The bitonic sort pattern leads to strided accesses. For example, when j is large (e.g., 256), threads i and i+256 access addresses that are 256 apart. Shared memory banks are interleaved at 4-byte granularity. Typically, consecutive 32-bit words map to consecutive banks modulo 32. So a stride of 256 (which is a multiple of 32) will cause all threads in a warp to access the same bank? Let's examine: If we have 32 threads in a warp, their indices are tid = t, t+1, ..., t+31. Their partner indices are t^j. If j is a multiple of 32, then t^j will be in the same bank modulo 32 as t? Actually, XOR with a constant that is a multiple of 32 changes the upper bits but not the lower 5 bits (since 32=2^5). So t^j will have the same lower 5 bits as t, meaning they map to the same bank. For a warp, all threads will access the same bank? Not exactly: threads in the warp have different lower 5 bits (since they are consecutive). But if j is a multiple of 32, then each thread's partner will have the same lower bits as itself. So if we have 32 threads, each thread accesses a unique bank (because lower bits are all distinct). Wait: the bank is determined by the address modulo 32 (in terms of 4-byte words). If thread i accesses s*data[i] and s_data[i^j], and i^j has the same lower bits as i (since j has zeros in lower 5 bits), then both accesses go to the same bank as i. But each thread accesses two addresses: the original and partner. The original access for each thread is to a distinct bank (lower bits of i are distinct). The partner access for each thread also goes to the same bank as its original, because partner's lower bits equal i's lower bits. So each thread accesses its own bank for both reads? Actually, reading two addresses from the same bank is a conflict (multiple accesses to same bank from same thread? No, bank conflicts occur when two \_different* threads access the same bank. Here, each thread accesses two addresses that lie in the same bank (its own bank). That's fine because they are from the same thread; bank conflicts are per warp, and two addresses from the same thread can be serialized but are not a conflict in the typical sense. However, if two different threads have the same lower bits (impossible within a warp because they are distinct), there's no cross-thread conflict. But when j is not a multiple of 32, the partner's lower bits may match another thread's lower bits, causing bank conflicts. For example, j=1: partners are i^1. For thread i=0, partner=1; thread i=1, partner=0. So threads 0 and 1 access each other's banks, causing a 2-way bank conflict? Actually, thread 0 reads s_data[0] and s_data[1]; thread 1 reads s_data[1] and s_data[0]. So both threads access banks 0 and 1. That's a 2-way conflict on each bank? In a warp, threads 0 and 1 both access bank0 and bank1. That generates conflicts. But with shared memory, bank conflicts cause serialization. However, modern GPUs have hardware to mitigate some conflicts, but it's still a performance issue.

- **Padding**: To avoid bank conflicts, we can pad the shared memory array by 1 element per row? Not exactly. For bitonic sort, the access pattern is regular. Some implementations use a "conflict-free" mapping by skewing the indices. But for simplicity, we can accept some conflicts.

- **Warp-Level Synchronization**: Instead of using `__syncthreads()` which synchronizes all threads in the block, we can use warp-level operations because threads within a warp are implicitly synchronized in lockstep. However, the bitonic sort operations involve threads across warps (e.g., j can be larger than warp size). So we need block-level sync.

- **Loop Unrolling**: For known small sizes, we can unroll the loops to reduce overhead.

- **Using Registers**: For very small sorts (e.g., 32 elements), we can avoid shared memory and use registers with warp shuffle instructions. This is extremely fast.

### 3.5 Example: Sorting 512 Elements in a Block

Let's write a complete example that sorts an array of 512 integers using a single block of 512 threads. We'll use dynamic shared memory.

Host code:

```cuda
const int N = 512;
int *h_data = new int[N];
// Initialize with random data
for (int i=0; i<N; i++) h_data[i] = rand() % 1000;

int *d_data;
cudaMalloc(&d_data, N * sizeof(int));
cudaMemcpy(d_data, h_data, N * sizeof(int), cudaMemcpyHostToDevice);

// Launch kernel with 1 block of 512 threads
bitonicSortShared<<<1, N, N * sizeof(int)>>>(d_data, N);

cudaDeviceSynchronize();
cudaMemcpy(h_data, d_data, N * sizeof(int), cudaMemcpyDeviceToHost);

// Verify sorted
for (int i=1; i<N; i++) assert(h_data[i] >= h_data[i-1]);
printf("Sorted successfully\n");
```

This works but note: the kernel uses `extern __shared__ int s_data[]` and we pass N\*sizeof(int) as the dynamic shared memory size. The kernel assumes the array size is a power of two. For non-power-of-two, we need to pad with sentinel values (e.g., INF) to avoid incorrect comparisons.

### 3.6 Handling Non-Power-of-Two Sizes

In practice, you can extend the array to the next power of two by adding dummy values (e.g., INT_MAX for ascending sort). After sorting, you can ignore the dummies. But this wastes memory and computation. Alternative: use a more general algorithm like merge sort or a recursive bitonic sort that handles arbitrary lengths.

---

## 4. Optimizing the CUDA Bitonic Sort

We can improve the naive kernel in several ways.

### 4.1 Using `__syncthreads()` Only When Necessary

The `__syncthreads()` inside the inner loop is called after each j iteration. That's many times: sum\_{k} (log2(k) - 1) ~ (log N)^2/2. For N=1024, that's about (10^2)/2 = 50 syncs. That's acceptable. But we could reduce syncs by combining multiple steps if we know the warp size? Not easily.

### 4.2 Reducing Bank Conflicts via Padding

To reduce bank conflicts, we can pad each row? Actually, the shared memory array is a linear array. Bank conflicts occur when two threads access addresses that are in the same bank (i.e., address%32). For the bitonic pattern with j as a power of two, we can show that for j <= 32, the accesses cause conflicts. For j > 32, the partners are in different warps, so conflicts may be less. One common technique is to pad the shared memory by one extra element per row (if we had a 2D array). But here it's 1D. A trick: use a different mapping: instead of storing elements consecutively, we can store them with a stride to avoid conflicts. For example, use `s_data[tid]` and access `s_data[ixj]`. If we add a constant offset to the index, we can shift the banks. However, the bitonic pattern is fixed; the best we can do is to ensure that within a warp, the accessed addresses are unique. For j=1, the pattern is swapping adjacent pairs. In a warp of 32 threads, threads 0 and 1 conflict, threads 2 and 3 conflict, etc. So we have 16 pairs of conflicts. This is a 2-way conflict on each of the 16 banks? Actually, each bank is accessed by two threads? Let's see: bank0 is addresses 0,32,64,... Thread 0 accesses s_data[0] and s_data[1]; bank0 and bank1. Thread 1 accesses s_data[1] and s_data[0]; also bank1 and bank0. So bank0 is accessed by thread0 and thread1 simultaneously, causing a 2-way conflict. Similarly bank1. So it's a 2-way conflict on each of the two banks involved. Overall, half of the banks are involved in 2-way conflicts. This can reduce performance by up to factor 2 for that step. For larger j, the pattern may cause more conflicts. For j=2, partners are (0,2), (1,3) etc. Threads 0 and 2 access bank0 and bank2; threads 1 and 3 access bank1 and bank3. So each bank is accessed by at most one thread? Actually, thread0 accesses bank0 and bank2; thread2 accesses bank2 and bank0. So bank0 is accessed by thread0 and thread2? Wait, thread0 accesses s_data[0] (bank0) and s_data[2] (bank2). Thread2 accesses s_data[2] (bank2) and s_data[0] (bank0). So bank0 is accessed by both thread0 and thread2. That's a 2-way conflict. So still conflicts. In general, for any j that is a power of two less than the warp size, the two threads that are paired together will both access each other's banks, causing a 2-way conflict on two banks per pair. For j >= 32, partners are in different warps, and since warps execute in lockstep, there are no cross-warp bank conflicts? Actually, within a warp, each thread has a partner in a different warp (if j>=32). But the warp still accesses its own set of addresses. However, the partner's address might be in the same bank as another thread's address within the same warp. Without a detailed analysis, we can say bank conflicts are inevitable. To mitigate, we can use a shared memory array of size N+1 (padding by one) and access using a skewed index: `s_data[tid]` and `s_data[ixj]` remain, but the padding may break the banking pattern slightly. Another approach is to use a `__launch_bounds__` or manually tune.

A more effective optimization is to use a **double-buffering** technique where we store the array in two halves? Not needed.

### 4.3 Using Warp Shuffle Instructions for Small Sorts

If the array size is less than or equal to 32, we can sort entirely within a warp using shuffle instructions (\_\_shfl_xor) without shared memory. This is extremely fast. For sizes up to 1024, we can combine warp-level sorts with shared memory.

### 4.4 Bitonic Sort for Larger Arrays: Multi-Block

For arrays larger than a block, we can use a hierarchical approach:

1. **Local sort**: Each block sorts its segment using shared memory.
2. **Global merge**: Then we merge segments using a bitonic-like network across blocks. This requires global synchronization, which can be done by launching multiple kernels. For each level of merging, we launch a kernel where each block handles a pair of segments. For example, after local sorts, we have M sorted segments. Then we need to merge them pairwise. This is essentially a merge sort tree. However, bitonic sort at the global level would require that we treat blocks as "elements" and perform comparisons across blocks. But blocks are not atomic; we need to compare individual elements. One approach: use a kernel that reads two sorted segments from global memory, merges them into a temporary output, and writes back. This is like a parallel merge sort. Many libraries (e.g., Thrust's merge sort) do this.

Given the complexity, it's often easier to use radix sort for large arrays.

---

## 5. Performance Analysis and Comparison

Let's analyze the performance of our block-level bitonic sort.

### 5.1 Computational Complexity

The number of compare-and-swap operations for a sequence of N elements is N _ (log N) _ (log N + 1) / 2 ≈ (N (log N)^2)/2. For N=1024, that's 1024 _ 10 _ 11 / 2 ≈ 56,320 operations. With 1024 threads, each thread does about 55 operations (since each thread handles one pair per step? Actually each thread participates in each step? In the inner loop, each thread does either 0 or 1 compare-swap (since ixj > i condition). So each thread performs exactly (number of steps) operations. Number of steps = sum\_{k=2,4,...,N} (log2(k)-1) = (log N)*(log N -1)/2. For N=1024, log N=10, steps = 10*9/2 = 45. So each thread does 45 comparisons. Total operations = 1024\*45 = 46,080 (close to earlier estimate). So the kernel does 45 syncs and 45 compare-swaps per thread. This is fine.

### 5.2 Memory Bandwidth

Each step reads two integers and writes two integers (from shared memory). With 45 steps, total reads/writes = 90 * N words. For N=1024, that's 90*1024 = 92,160 4-byte accesses, or 368,640 bytes. Shared memory bandwidth is very high (around 1-2 TB/s on modern GPUs), so the time is dominated by compute and sync. For a kernel that also loads from global memory (once) and stores back (once), global memory bandwidth is also a factor.

### 5.3 Comparison with Other Algorithms

- **Radix sort** on GPU can be much faster for large arrays (hundreds of millions of elements) because it has O(N \* bits) complexity with low overhead. For small arrays, bitonic sort may be competitive.
- **Merge sort** using GPU has similar complexity but more irregular memory access.
- **Thrust::sort** uses a hybrid: for small arrays, it may use insertion sort? Not sure.

Benchmarks: On an NVIDIA RTX 3080, sorting 1 million integers with Thrust's radix sort takes about 0.2 ms. With a bitonic sort implemented across blocks (like in the CUB library), it might be similar but not as fast.

### 5.4 When to Use Bitonic Sort

Bitonic sort is best for:

- Small arrays (≤1024) that fit in shared memory.
- Situations where you need a deterministic, data-independent algorithm (e.g., in security or real-time systems).
- Understanding parallel sorting concepts.

---

## 6. Extensions and Further Optimizations

### 6.1 Sorting in Descending Order

We can easily modify the kernel to sort in descending order by swapping the direction condition: ascending becomes descending and vice versa. Or we can simply negate the comparison.

### 6.2 Sorting Large Arrays with a Hybrid Approach

One can use bitonic sort as a building block: sort each block, then perform a bitonic merge across blocks using a global kernel. The merge step can also be done with a bitonic network where blocks are considered as groups. However, this requires careful indexing.

### 6.3 Using CUB Library

NVIDIA's CUB library provides `cub::DeviceRadixSort` and `cub::DeviceMergeSort` which are highly optimized. For production code, use those.

### 6.4 Comparison with Thrust

Thrust is a higher-level library. Under the hood, Thrust uses cub for sorting. So effectively, you are using the best available implementation.

---

## 7. Conclusion

We've journeyed from the fundamental paradox of parallel sorting to the depths of Bitonic Sort on a GPU. We've seen how a seemingly obsolete sequential algorithm can become a star in a SIMD world. Bitonic Sort's data-independent nature, regular memory access, and predictable control flow make it an ideal fit for CUDA's execution model.

We've implemented a shared-memory block-level kernel that sorts up to 1024 elements efficiently. We've discussed optimizations like bank conflict mitigation and warp-level primitives. And we've touched on the broader landscape of GPU sorting.

But remember: this is not just about sorting. The same principles apply to any algorithm that can be expressed as a sorting network or a data-independent parallel pattern. The ability to think in terms of fixed comparison networks, to recognize parallelism where others see only dependencies, is a valuable skill in the age of parallel computing.

As you move forward, consider this: the free lunch may be over, but the buffet of parallel algorithms is just opening. Bitonic Sort is one dish. Radix sort, merge sort, and hybrid algorithms are others. The key is to understand the architecture and choose the right tool for the job. And sometimes, the old, forgotten recipe is exactly what you need.

Happy coding, and may your warp always be convergent.

---

**Appendix A: Complete Code**

```cuda
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void bitonicSortShared(int *g_data, unsigned int n) {
    extern __shared__ int s_data[];
    unsigned int tid = threadIdx.x;

    // Load
    s_data[tid] = g_data[tid];
    __syncthreads();

    // Bitonic sort
    for (unsigned int k = 2; k <= n; k <<= 1) {
        for (unsigned int j = k >> 1; j > 0; j >>= 1) {
            unsigned int ixj = tid ^ j;
            if (ixj > tid) {
                if ((tid & k) == 0) {
                    if (s_data[tid] > s_data[ixj]) {
                        int temp = s_data[tid];
                        s_data[tid] = s_data[ixj];
                        s_data[ixj] = temp;
                    }
                } else {
                    if (s_data[tid] < s_data[ixj]) {
                        int temp = s_data[tid];
                        s_data[tid] = s_data[ixj];
                        s_data[ixj] = temp;
                    }
                }
            }
            __syncthreads();
        }
    }

    // Store
    g_data[tid] = s_data[tid];
}

int main() {
    const unsigned int N = 512;
    int h_data[N];
    for (unsigned int i = 0; i < N; i++) h_data[i] = rand() % 1000;

    int *d_data;
    cudaMalloc(&d_data, N * sizeof(int));
    cudaMemcpy(d_data, h_data, N * sizeof(int), cudaMemcpyHostToDevice);

    bitonicSortShared<<<1, N, N * sizeof(int)>>>(d_data, N);
    cudaDeviceSynchronize();

    cudaMemcpy(h_data, d_data, N * sizeof(int), cudaMemcpyDeviceToHost);

    for (unsigned int i = 1; i < N; i++) {
        if (h_data[i] < h_data[i-1]) {
            printf("Sort failed at index %d\n", i);
            return 1;
        }
    }
    printf("Sort succeeded!\n");

    cudaFree(d_data);
    return 0;
}
```

**Appendix B: Further Reading**

- Ken Batcher's original paper: "Sorting networks and their applications" (1968).
- NVIDIA CUDA Programming Guide.
- "Programming Massively Parallel Processors" by David Kirk and Wen-mei Hwu.
- Thrust documentation: https://thrust.github.io/
- CUB library: https://nvlabs.github.io/cub/

---

_This article is part of a series on parallel algorithms. Stay tuned for deep dives into radix sort, scan operations, and graph algorithms on the GPU._
