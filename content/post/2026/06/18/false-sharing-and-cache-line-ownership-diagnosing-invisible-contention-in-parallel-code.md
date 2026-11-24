---
title: "False Sharing and Cache-Line Ownership: Diagnosing Invisible Contention in Parallel Code"
description: "A practical deep dive into false sharing: why independent variables contend, how cache coherence turns writes into a distributed protocol, and how to detect the problem with hardware counters, perf c2c, and controlled experiments."
date: "2026-06-18"
author: "Leonardo Benicio"
tags: ["parallel computing","cache coherence","performance engineering","false sharing","systems design"]
categories: ["Computer Science","Systems Engineering","Performance"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/false-sharing-and-cache-line-ownership-diagnosing-invisible-contention-in-parallel-code-2026-06-18.jpg"
coverAlt: "A text-free systems diagram showing two CPU cores contending over a single cache line that holds two independent variables, contrasted with the same variables placed in separate cache lines with no contention."
---

June 18, 2026

# False Sharing and Cache-Line Ownership: Diagnosing Invisible Contention in Parallel Code

## The benchmark that refuses to scale

A parallel program has four threads. Each thread owns a private counter. The threads increment their counters in a tight loop. There are no locks, no atomics shared between threads, no obvious data races. The code looks embarrassingly parallel. Yet when the program runs on four cores, it is only slightly faster than the single-threaded version. Sometimes it is slower. A profiler shows low instructions per cycle, a high rate of cache misses, and a surprising amount of coherence traffic. The source code offers no explanation. The variables are independent.

This is the classic signature of false sharing. It is one of the most common and most misunderstood performance problems in shared-memory parallel computing. The word false is important. The threads are not sharing data in the algorithmic sense. They are sharing a cache line in the hardware sense. The hardware does not know that the variables are independent. It only knows that two cores are writing to the same cache line. To preserve coherence, it must serialize those writes.

False sharing is invisible at the source level because it emerges from a mismatch between two granularities: the granularity of program variables and the granularity of cache coherence. Program variables can be one byte, four bytes, eight bytes, or a struct. Cache coherence operates on cache lines, typically 64 bytes on x86-64 and many ARM systems, and sometimes 128 bytes on other architectures. Any two variables that fall into the same cache line are coupled by the coherence protocol, whether the programmer intended it or not.

This article is about diagnosing that coupling. It is not enough to know the definition. To fix false sharing, you need to understand what the hardware is doing, how to measure it, and how to separate true sharing from accidental sharing. The first step is to stop thinking in terms of variables and start thinking in terms of cache lines, coherence states, and ownership.

## Cache lines are the unit of coherence, not variables

Modern CPUs do not read and write individual bytes from main memory. They move data in fixed-size blocks called cache lines. A cache line is the unit of transfer between memory and cache, and it is also the unit of coherence between cores. When a core loads a variable, the entire cache line containing that variable is brought into the core's cache hierarchy. When a core stores to a variable, it must obtain exclusive ownership of the entire cache line.

On most x86-64 processors, the cache line size is 64 bytes. Some CPUs split a line into two 32-byte sectors for certain operations, but coherence is still managed at line granularity in the common case. Apple silicon and some ARM cores also use 64-byte lines, though 128-byte lines appear in other designs. The exact size matters because it determines how many variables can be accidentally coupled. A 64-byte line can hold eight 8-byte counters, sixteen 4-byte integers, or a small struct plus its metadata.

This granularity is a deliberate engineering choice. Larger lines amortize tag overhead and improve spatial locality. Smaller lines reduce false sharing but increase tag storage and coherence messages. The hardware designer picks a line size that balances these factors for expected workloads. Parallel software engineers must live with that choice. The only defense is to control data layout.

A cache line can be in several coherence states. In the common MESI protocol, a line is Modified, Exclusive, Shared, or Invalid. Modified means the line is dirty and owned by this cache. Exclusive means the line is clean and owned by this cache, and no other cache has a copy. Shared means the line is clean and may be present in multiple caches. Invalid means the cache does not have a valid copy. MOESI adds an Owned state, and other protocols add more states, but the core idea is the same: only one core may modify a line at a time, and other cores must be told when their copies become stale.

## What false sharing actually is

True sharing occurs when multiple threads access the same variable, and at least one thread writes it. A shared counter, a queue head, a lock word, or a reference count are examples of true sharing. The coherence traffic is necessary because the threads genuinely depend on the same data. False sharing occurs when multiple threads access different variables that happen to reside in the same cache line, and at least one thread writes its variable. The threads do not depend on each other, but the hardware treats their accesses as conflicting because they target the same line.

Read-only sharing is usually cheap. If several cores only read a line, they can all hold it in the Shared state. No invalidation is needed. The line may be replicated in multiple caches, and each core can read it without further coherence traffic. The trouble begins with writes. A write to a line that is currently Shared requires the writing core to invalidate all other copies. If another core later writes its own variable in that same line, it must invalidate the first core's copy. The line ping-pongs between caches.

This ping-pong is not a software lock, but it has a similar effect. The coherence protocol serializes writes to the line. Each write may require a request for ownership, an invalidation message, an acknowledgment, and a data transfer. The latency of these operations is much higher than a local store. If the writes are frequent, the cost dominates. The program spends its time moving cache lines instead of doing useful work.

The word false is a statement about intent, not about hardware behavior. From the hardware's perspective, the sharing is real. The line is being written by multiple cores. The protocol must maintain correctness. The programmer's mistake is placing independent variables in the same line.

## A concrete example

Consider a simple C++ struct with two counters:

```cpp
struct Counters {
    std::atomic<uint64_t> a{0};
    std::atomic<uint64_t> b{0};
};
```

If a `Counters` object is allocated normally, `a` and `b` are likely adjacent in memory. On a 64-byte cache line, they occupy the same line. Thread 0 increments `a`; thread 1 increments `b`. Each increment is a read-modify-write operation. When thread 0 writes `a`, it must own the line exclusively. That invalidates thread 1's copy. When thread 1 writes `b`, it must own the line exclusively. That invalidates thread 0's copy. The two threads are not sharing a variable, but they are sharing a cache line. The result is a coherence storm.

The fix is to separate the counters into different cache lines:

```cpp
struct PaddedCounters {
    alignas(64) std::atomic<uint64_t> a{0};
    alignas(64) std::atomic<uint64_t> b{0};
};
```

Now each counter has its own line. Thread 0 can write `a` without invalidating thread 1's line, and vice versa. The coherence traffic disappears. The struct becomes larger, but the performance difference can be dramatic. This is the essential trade-off of false sharing mitigation: spend memory to buy coherence independence.

## The coherence protocol underneath

To diagnose false sharing, it helps to understand the coherence protocol at a mechanical level. The details differ across x86, ARM, POWER, and RISC-V, but the general shape is similar. Each core has private L1 and often private L2 caches. The last-level cache is shared or partitioned. Coherence is maintained either by snooping or by a directory.

In a snooping protocol, each cache watches a shared bus or interconnect for transactions. When a core wants to write a line, it broadcasts a request. Other caches check whether they have the line and invalidate their copies if necessary. In a directory-based protocol, a directory tracks which caches have copies of each line. The requesting core sends a message to the directory, which forwards invalidations to the sharers. Directory protocols scale better because they avoid broadcast, but they add indirection and directory state.

When a core wants to write a line that it does not own, it issues a Read For Ownership, often abbreviated RFO. The RFO fetches the line and obtains exclusive ownership. If another cache has a modified copy, that cache must write the line back or forward it to the requester. This is why a load can miss in local cache but hit in another core's cache. The hardware counter event HITM, or Hit Modified, records a load that hit a modified line in another cache. HITM is a strong signal of sharing, and in the context of false sharing, it is a strong signal of accidental sharing.

Once a core owns a line, it can write to it locally. But if another core requests the line, the owner must respond. The line may move back and forth. Under heavy contention, the interconnect becomes a bottleneck. The coherence protocol is a distributed agreement protocol running in hardware at cache-line granularity. It is optimized for correctness and common cases, not for pathological ping-pong.

## Why the cost is not just cache misses

False sharing is often described as a cache miss problem. That is incomplete. A false sharing event may not cause a traditional data cache miss in the sense of going to DRAM. The line may be present in the shared last-level cache or in another core's private cache. The cost is coherence latency and bandwidth, not just memory latency.

When a core writes to a shared line, it may stall waiting for ownership. The store buffer can absorb some latency, but if the store buffer fills, the core must stall. The invalidation messages consume interconnect bandwidth. The other core must process the invalidation and invalidate its copy. If the other core is also writing, the requests collide. The line bounces between caches. The effective throughput of the workload becomes limited by the coherence round-trip time, not by the arithmetic or memory bandwidth of the cores.

This is why false sharing can be worse than true sharing in some cases. True sharing is often structured with locks, atomics, or message passing that amortize the coherence cost. False sharing can cause coherence traffic on every write to what the programmer believes is private data. The programmer sees independent counters, but the hardware sees a shared line under contention.

The effect is also not limited to atomics. Ordinary non-atomic writes can cause false sharing. If two threads write to different non-atomic variables in the same cache line without synchronization, the program has a data race, which is undefined behavior in C and C++. But even with synchronization, false sharing can occur when the synchronization is coarse or when the writes are to distinct variables that are protected by different locks. The hardware does not care about the synchronization structure. It only sees writes to the same line.

## How to detect false sharing

Detection begins with measurement. The first question is whether the performance problem is actually false sharing. It could be true sharing, lock contention, memory bandwidth saturation, NUMA effects, or an algorithm that does not scale. False sharing has a particular signature: high coherence traffic, high HITM events, and a source-level absence of shared variables.

On Linux, the `perf c2c` tool is designed for this problem. It samples loads and stores and attributes cache-line contention to source lines and symbols. The workflow is usually:

```bash
perf c2c record -a -- sleep 5
perf c2c report --stdio
```

The report shows cache lines with high contention, including HITM counts and the instructions that caused them. If a cache line has a high HITM count and the source code shows two different variables accessed by different threads, false sharing is likely. `perf c2c` is not the only tool. Intel VTune has a Memory Access analysis that reports false sharing. AMD uProf has similar capabilities. Hardware performance counters can also be used directly, though event names vary by microarchitecture. Common events include `mem_load_l3_hit_retired.xsnp_hitm`, `mem_load_l3_miss_retired.remote_hitm`, and various offcore response counters. The exact names depend on the CPU generation and the kernel's performance monitoring unit support.

A simple first pass can use `perf stat` to look at cache misses and coherence-related events:

```bash
perf stat -e cache-misses,cache-references,LLC-load-misses,LLC-store-misses ./program
```

But aggregate counts are not enough. They tell you that something is wrong, not where. You need source-level attribution. Sampling profilers that record data addresses, such as `perf c2c`, are more useful because they connect contention to memory locations.

## A method for confirmation

Once a suspect cache line is identified, confirm it with a controlled experiment. Pinning threads to specific cores reduces scheduler noise. Running the workload with one thread establishes a baseline. Scaling to two, four, and more threads shows whether the problem grows with parallelism. If performance degrades as more threads are added, and the profiler shows contention on a line that should be private, false sharing is a strong hypothesis.

The next step is to change the data layout. Add padding or alignment so that the suspected variables occupy different cache lines. Re-run the same workload. If the contention disappears and performance improves, the hypothesis is confirmed. The experiment should be repeated with the padding removed to ensure that the change, not some unrelated factor, caused the improvement. This is basic performance engineering: isolate the variable, change one thing, measure again.

It is also useful to inspect the actual memory addresses. A debugger or a small instrumented program can print the addresses of the variables. If the addresses are within 64 bytes of each other, they share a cache line on most x86-64 systems. Tools such as `pahole` can show struct layout and padding. Compiler flags such as `-fdump-class-hierarchy` or `-Wpadded` can help in C++. For dynamically allocated objects, the allocator's placement matters. Two objects allocated consecutively may share a line even if their types are unrelated. Thread-local storage is another common source: two thread-local variables in the same translation unit may be placed adjacently by the linker.

The goal is not to eliminate all sharing. The goal is to distinguish necessary sharing from accidental sharing. Necessary sharing should be optimized with algorithmic techniques: reduce the frequency of writes, batch updates, use per-thread accumulators, or use message passing. Accidental sharing should be fixed with layout: padding, alignment, sharding, or separating hot variables into different lines.

## Common patterns that produce false sharing

False sharing appears in predictable places. Per-thread statistics are a classic example. An array of counters indexed by thread ID is compact and cache-friendly for reading, but if each thread writes its own counter, adjacent counters share lines. The fix is to pad each counter to a cache line, or to accumulate locally and merge periodically.

Producer-consumer queues are another common case. A queue may have a head index and a tail index. If they are adjacent in the same cache line, the producer writing the tail and the consumer writing the head will invalidate each other's lines. The queue may be lock-free and correct, but it will not scale. Separating the head and tail into different cache lines is a standard optimization.

Locks and flags adjacent to protected data also cause false sharing. A lock word and a frequently read data field in the same line means that acquiring the lock invalidates readers of the data field. Padding the lock to its own line can help, though it increases memory use. Reference counts are similar. A reference count next to an object's immutable data will be written on every reference increment, causing coherence traffic for readers of the data.

Memory allocators and garbage collectors are especially vulnerable. Per-thread free lists, allocation bitmaps, and mark bits can be packed densely. A write to one thread's free list can invalidate another thread's free list if they share a line. Allocator designers often use cache-line alignment for per-thread structures, but the details matter. NUMA systems add another layer: a write that invalidates a line on a remote socket is more expensive than a local invalidation.

Even read-mostly data can suffer. If a line is mostly read but occasionally written, the writer must invalidate all readers. The readers then re-fetch the line. If the write is rare, the cost may be acceptable. If the write is frequent, the line becomes a bottleneck. The solution is often to separate the write-heavy field from the read-heavy fields, or to use read-copy-update so that writers create new versions instead of modifying shared lines in place.

## Initial mitigation strategies

The most direct mitigation is cache-line padding. In C and C++, `alignas(64)` can align a variable or struct member to a 64-byte boundary. Padding arrays can ensure that each element starts on a new line. Some libraries provide cache-line constants, such as `std::hardware_destructive_interference_size` in C++17, though its value is implementation-defined and should be checked. The constant name reflects the problem: destructive interference occurs when two threads write to the same line.

Padding is not free. It increases memory footprint, which can reduce cache capacity and TLB efficiency. If the padded data is read together, padding may hurt locality. If the data is written independently by different threads, padding usually helps. The trade-off must be measured. Over-padding a large array can waste megabytes of cache and make the working set larger than the last-level cache.

A more scalable approach is to avoid sharing altogether. Per-thread or per-core data structures can accumulate updates locally, and a reduction phase can merge them later. This is common in parallel loops, where each thread accumulates a private partial result and the partials are combined at the end. The reduction phase may still contend, but it happens once instead of on every iteration. Batching updates has a similar effect: instead of writing a shared counter on every event, write a local batch and flush it periodically. The flush frequency controls the coherence cost.

For concurrent data structures, the layout of metadata matters as much as the layout of data. A queue with head and tail in the same line will not scale. A lock table with adjacent locks will suffer false sharing when different threads acquire different locks. A hash table with per-bucket locks may need padding between buckets. These are not exotic optimizations. They are standard practice in high-performance concurrent code.

Finally, remember that false sharing is a hardware-specific problem. The cache line size, coherence protocol, and interconnect topology vary across systems. A fix that works on one CPU may not be optimal on another. Portable code should use alignment constants from the platform or runtime, and performance-critical code should be benchmarked on the target hardware. The next sections will examine specific case studies in concurrent queues, reference counting, per-thread allocators, and NUMA-aware data placement, and will build a small measurement harness to reproduce and diagnose false sharing in controlled conditions.

## Case study: a lock-free queue with a shared head and tail

A single-producer single-consumer queue is often implemented with a ring buffer, a head index, and a tail index. The producer writes the tail; the consumer writes the head. If the two indices are adjacent members of the same struct, they share a cache line. The producer's store to tail invalidates the consumer's cached copy of head, and the consumer's store to head invalidates the producer's copy of tail. The queue may be correct, but each operation pays a coherence penalty.

```cpp
struct Queue {
    std::atomic<size_t> head{0};
    std::atomic<size_t> tail{0};
    // buffer...
};
```

Padding separates them:

```cpp
struct Queue {
    alignas(64) std::atomic<size_t> head{0};
    alignas(64) std::atomic<size_t> tail{0};
    // buffer...
};
```

The padded version uses more memory, but the producer and consumer no longer invalidate each other's cache lines. The same principle applies to multi-producer multi-consumer queues. If the queue uses a sequence number per slot, adjacent slots may share a line. A common design is to pad each slot to a cache line, or to use a ring buffer where the producer and consumer indices are in separate lines and the slots are large enough to avoid false sharing. The cost of padding must be weighed against the cost of coherence traffic. For a queue with high throughput, padding is usually worth it.

## Case study: reference counts in an array of objects

Consider a pool of objects, each with an atomic reference count. If the objects are allocated contiguously, their reference counts may share cache lines. Thread A increments the count for object 0; thread B increments the count for object 1. Even though the objects are independent, the counts are in the same line. The atomic increments serialize on the line. Padding each object's reference count to a cache line can help, but it may waste memory. A better design may separate hot reference counts from cold object data, or use per-thread reference counts and merge them.

The same problem appears in garbage collectors. Mark bits, card tables, and remembered sets are often dense bitmaps. A write to one thread's region can invalidate another thread's region if they share a cache line. Generational collectors may use per-thread allocation buffers. If the buffers' metadata is packed together, the collector's threads will false-share. The fix is to align per-thread metadata to cache lines and to ensure that the hot fields are not adjacent to fields written by other threads.

## Case study: per-thread allocators and free lists

Memory allocators maintain per-thread caches to avoid global locks. A per-thread free list is a stack of free blocks. The head pointer is updated on every allocation and free. If two threads' free-list heads are adjacent in a global array, the threads will false-share. Allocators like jemalloc and tcmalloc use cache-line alignment for per-thread structures, but the exact layout is complex. A common bug is to store per-thread statistics next to per-thread free lists. The statistics are updated on every allocation, causing the same line to bounce. Separating statistics into a different cache line or using per-thread local counters that are flushed periodically avoids the problem.

Another allocator pattern is the size-class free list. Each size class has a free list. If two threads allocate from different size classes but the free-list heads are in the same line, they will false-share. Padding each size class's free list to a cache line is a standard optimization. The trade-off is memory overhead. For a small number of size classes, the overhead is acceptable. For a large number, a different layout may be needed, such as grouping free lists by thread and then by size class, with padding between thread groups.

## NUMA: when the remote socket pays the coherence cost

On a multi-socket system, cache lines are owned by a home node. A write from a core on socket 0 to a line homed on socket 1 must traverse the interconnect. The invalidation and data transfer are more expensive than local coherence. False sharing across sockets is particularly damaging because every write may cross the interconnect. NUMA-aware allocation, first-touch placement, and thread pinning can reduce the cost. If two threads on different sockets write to the same line, the line migrates between sockets. The fix is to ensure that each thread's data is allocated on its local node and padded to avoid sharing.

The measurement signal is also different. On a NUMA system, `perf c2c` may show remote HITM events. The `Rmt` column in the report indicates remote accesses. A high remote HITM count on a line that contains independent variables is a strong sign of cross-socket false sharing. The remedy may be to replicate the data per socket, to use per-socket counters, or to change the thread-to-data mapping. Sometimes the best fix is to avoid the shared line entirely by giving each socket its own copy of the data structure.

## Building a controlled measurement harness

To diagnose false sharing, build a small benchmark that isolates the effect. The benchmark should have a parameter for padding and a parameter for the number of threads. Each thread writes to its own counter. The counters are either packed or padded.

```cpp
#include <atomic>
#include <thread>
#include <vector>
#include <cstdint>
#include <cstdio>

struct Packed {
    std::atomic<uint64_t> counters[8];
};

struct Padded {
    alignas(64) std::atomic<uint64_t> counters[8];
};

template <typename T>
void run(T& data, int thread_id, uint64_t iterations) {
    for (uint64_t i = 0; i < iterations; ++i) {
        data.counters[thread_id].fetch_add(1, std::memory_order_relaxed);
    }
}

int main() {
    constexpr uint64_t iterations = 100000000;
    constexpr int threads = 8;

    Packed packed;
    Padded padded;

    auto bench = [&](auto& data, const char* name) {
        std::vector<std::thread> pool;
        auto start = std::chrono::steady_clock::now();
        for (int t = 0; t < threads; ++t) {
            pool.emplace_back(run<decltype(data)>, std::ref(data), t, iterations);
        }
        for (auto& th : pool) th.join();
        auto end = std::chrono::steady_clock::now();
        std::printf("%s: %lld ms\n", name,
            std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count());
    };

    bench(packed, "packed");
    bench(padded, "padded");
}
```

Compile with optimization and run on an otherwise idle machine. Pin threads to distinct cores with `taskset` or `sched_setaffinity` to reduce scheduler noise. Run each configuration several times and report the median. The packed version should show much worse scaling than the padded version. If it does not, the workload may not be dominated by false sharing, or the cache line size may be different.

The harness can be extended to test different strides. Instead of one counter per thread, use an array with a configurable stride between counters. A stride of 1 means adjacent counters; a stride of 8 means counters are 8 bytes apart; a stride of 16 means 16 bytes apart. When the stride crosses the cache line boundary, the false sharing disappears. This experiment directly measures the cache line size and the cost of sharing.

```cpp
template <typename T>
void run_strided(T* data, int thread_id, int stride, uint64_t iterations) {
    auto& counter = data[thread_id * stride];
    for (uint64_t i = 0; i < iterations; ++i) {
        counter.fetch_add(1, std::memory_order_relaxed);
    }
}
```

By sweeping the stride from 1 to 32, you can see the performance cliff at the cache line boundary. The cliff is usually sharp: strides that keep counters in the same line are slow, and strides that separate them are fast. This is a simple and reliable way to confirm false sharing without a profiler. It also shows how padding changes the memory access pattern and the working set size.

## Reading perf c2c output

`perf c2c report` shows a table of cache lines. The columns include `Rmt`, `Lcl`, `Tot`, `Hitm`, and source information. A high `Hitm` count means loads that hit a modified line in another cache. The `Rmt` column indicates remote accesses. The source line shows the instruction that caused the hit. If two different variables in the same cache line have high Hitm, false sharing is likely. The report also shows the offset within the line, which helps identify the variables.

A typical workflow is:

```bash
perf c2c record -a -- ./benchmark
perf c2c report --stdio
```

The report may show a cache line with a physical address and a set of symbols. If the symbols point to two different counters in the same struct, and the counters are written by different threads, the diagnosis is clear. If the symbols point to the same counter, it is true sharing, and the fix is algorithmic. If the symbols point to allocator metadata, the fix may be in the allocator or in the data layout.

## Interpreting offcore response counters

Offcore response counters on Intel CPUs can distinguish local and remote cache hits. Events like `OCR.DEMAND_DATA_RD.L3_HIT.SNOOP_HITM` count demand reads that hit a modified line in another core's cache. The exact event names are model-specific. Use `perf list` to find them. A high count of snoop hitm events relative to cache references indicates sharing. If the source line is a private variable, false sharing is the likely cause.

On AMD CPUs, similar events exist under different names. The `ls_dmnd_fills_from_sys` and `ls_any_fills_from_sys` events can indicate remote fills. The `ls_l1_dtlb_miss` and `ls_l2_dtlb_miss` events are not directly related to false sharing, but they can help rule out other memory problems. The key is to combine coherence events with source-level attribution. Aggregate counts alone are rarely enough to diagnose false sharing.

## A systematic diagnosis workflow

A practical workflow for diagnosing false sharing is:

1. Measure scaling. Run the workload with 1, 2, 4, and 8 threads. If performance does not improve or degrades, there is contention.
2. Inspect the source for shared variables. Look for per-thread counters, queues, locks, and allocator metadata that may be adjacent in memory.
3. Use `perf c2c` or a similar tool to find cache lines with high HITM counts.
4. Map the cache line to source variables. Use debug information and address offsets.
5. Confirm with a controlled experiment. Add padding or change the layout, then re-run.
6. Measure the trade-off. Padding increases memory use and may reduce cache capacity.
7. Consider algorithmic alternatives. Per-thread accumulation, batching, and sharding can reduce coherence traffic without excessive padding.

The workflow is iterative. A fix for one bottleneck may reveal another. False sharing is often one of several scalability problems. The goal is not to eliminate all coherence traffic, but to ensure that the traffic that remains is necessary and amortized. When the hardware is no longer serializing independent writes, the program can scale.

The next section will examine how to apply these techniques to a real concurrent hash table and a parallel particle simulation, where the interaction between false sharing and algorithmic design becomes even more subtle.

## Case study: a concurrent hash table under cache-line pressure

A concurrent hash table is a useful stress test for cache-line ownership because it combines random access, frequent mutation, and metadata that is easy to pack too tightly. A typical bucket contains a lock, a pointer to the first entry, and perhaps a count of entries. If those fields are placed in a small struct and the bucket array is contiguous, adjacent buckets share cache lines. Two threads operating on different buckets can then invalidate each other even though they never touch the same logical bucket.

The first symptom is often misleading. The table may use fine-grained locks, and the lock acquisition itself looks cheap in isolation. But the lock word and the bucket head sit in the same line. When thread A locks bucket 3, it obtains exclusive ownership of the line containing bucket 3. If bucket 4 is in the same line and thread B is reading or locking bucket 4, thread B's copy is invalidated. The lock is fine-grained in software, but the coherence protocol sees a coarser conflict. The same problem appears with per-bucket occupancy counters. If every insertion increments a counter next to the bucket head, the counter update becomes a coherence event for every operation on neighboring buckets.

A common first fix is to separate the lock array from the bucket array. The locks are padded to cache-line boundaries, and the bucket data remains compact. This helps because lock acquisition no longer invalidates the data line for neighboring buckets. But it does not eliminate all false sharing. If the bucket entries themselves are small, two threads writing different buckets in the same cache line still contend. The table may need cache-line-sized buckets, or a hybrid layout where each cache-line segment contains several buckets and one lock protects the segment. That design deliberately trades concurrency for coherence independence. Operations on different buckets in the same segment serialize, but they no longer generate a storm of ownership transfers across the interconnect.

A padded bucket layout makes the trade-off explicit:

```cpp
struct Bucket {
    alignas(64) std::mutex lock;
    std::atomic<Entry*> head{nullptr};
    uint64_t count{0};
};
```

This layout wastes memory. For a table with millions of buckets, the waste can be unacceptable. A more practical design groups buckets into cache-line-sized segments:

```cpp
struct Segment {
    alignas(64) std::mutex lock;
    Bucket buckets[4];
    uint64_t count{0};
};
```

Now the lock, the buckets, and the count share one line. Threads that operate on different segments do not interfere. Threads that operate on different buckets within the same segment contend on the segment lock, but that contention is visible and bounded. The segment is the unit of cache-line ownership. The table's concurrency is reduced, but the coherence traffic is controlled. For read-heavy workloads, a read-write lock or a seqlock per segment may be better than a plain mutex. For write-heavy workloads, the segment lock is often the right compromise.

Open-addressing tables have a different layout problem. A slot may contain a key, a value, and a state byte. If slots are packed densely, two threads inserting into different slots in the same line will invalidate each other. The state byte is particularly dangerous because it is written on every insertion and deletion. A common mitigation is to make the slot large enough that each slot occupies its own cache line. That is expensive. Another approach is to separate the state array from the key and value arrays. The state array is still byte-packed, so false sharing remains possible, but the key and value writes are isolated. A third approach is to use a cache-line bucket: eight slots per line, with one lock or one atomic ownership word per line. The table probes within the line, and ownership is acquired at line granularity. This is a direct application of cache-line ownership: the line is the unit of mutation, not the individual slot.

Resizing is another source of invisible contention. A table that grows by allocating a new bucket array and migrating entries may use a shared progress counter. If the counter is adjacent to a bucket that workers are migrating, every progress update invalidates the bucket line. The counter should be padded and updated with relaxed atomics. Migration itself should be partitioned into cache-line-aligned chunks. Each worker owns a set of source and destination lines. Workers can read neighboring chunks, but only the owner writes them. This avoids false sharing during the most expensive phase of the resize. If the table uses a shared migration queue, the queue's head and tail should be separated, as in the earlier queue example. The same ownership discipline applies to the table's metadata: any field that is written frequently by one worker should not share a line with a field written by another worker.

Measurement for a hash table should focus on the bucket and segment lines. A `perf c2c` report may show high HITM counts on a line that contains a lock and a neighboring bucket head. The source attribution may point to the lock acquisition in one thread and the bucket read in another. If the line contains only one bucket and its lock, the sharing is true sharing: the threads are contending for the same bucket. If the line contains multiple buckets or multiple locks, the sharing is likely false. A controlled experiment can confirm this. Run the table with the original packed layout, then with padded segments. Measure throughput and HITM counts. If the padded version improves scaling and reduces HITM on lines that contain different buckets, the diagnosis is confirmed. The experiment should also measure memory use. A table that is 30 percent faster but uses four times more memory may not be acceptable for a large working set.

## Case study: parallel particle simulation and ownership of moving data

A particle simulation presents a harder version of the same problem because the data moves. Particles are stored in arrays or cell lists. Threads process particles, compute forces, and update positions. The writes are frequent, and the data layout changes as particles migrate between spatial cells. False sharing can appear in the particle arrays, the force accumulators, the cell metadata, and the neighbor lists.

Consider an array of particles stored as an array of structs. Each particle might contain position, velocity, force, and an identifier. If the struct is smaller than a cache line, adjacent particles share a line. A thread that owns a contiguous range of particles writes to its range. At the boundary between two threads' ranges, the last particle of one range and the first particle of the next range may share a line. When both threads update their boundary particles, the line ping-pongs. The fix is to align thread ranges to cache-line boundaries. Each thread starts and ends on a line boundary, so no line is written by two threads. This may leave a few unused particles at the end of a range, but the coherence savings are usually worth it. The same technique applies to loops over arrays: partition by cache-line-aligned blocks rather than by arbitrary indices.

Array-of-structs layouts have another problem. If the struct is exactly 64 bytes, each particle occupies its own line, which is good for ownership but may waste memory and reduce spatial locality for reads. If the struct is 32 bytes, two particles share a line. A thread that processes every other particle may write to the same line as another thread. A structure-of-arrays layout can separate the hot fields. Positions and velocities can be in separate arrays. Force accumulators can be in a third array. The arrays are still packed, so adjacent particles in the force array share lines. The ownership rule still applies: assign cache-line-aligned blocks of particles to threads, and ensure that each thread writes only to its own blocks. Reads from neighboring blocks are fine because read-only sharing is cheap. The problem is writes.

Force computation often creates a symmetric update. Particle i contributes a force to particle j, and particle j contributes an equal and opposite force to particle i. If thread A owns particle i and thread B owns particle j, and both threads update the force array directly, the force array line may be written by both threads. This is true sharing in the algorithmic sense, but it can be avoided with per-thread force buffers. Each thread accumulates force contributions for the particles it touches into a private buffer. The buffers are padded to avoid false sharing between threads. At the end of the time step, the buffers are reduced into the particle force array. The reduction is a separate phase with its own ownership rules. The cost is extra memory and an extra pass over the data. The benefit is that the force computation phase has no cross-thread writes to the particle array. For a simulation with many time steps, the reduction cost is amortized, and the coherence savings can be large.

Per-thread force buffers introduce their own false-sharing risk. If the buffers are stored as a two-dimensional array indexed by thread and particle, adjacent threads' buffers may share lines. The buffer for thread 0 and the buffer for thread 1 should be separated by cache-line padding. Within a thread's buffer, adjacent particles are fine because only one thread writes them. The reduction phase should also be ownership-aware. If thread 0 reduces the first half of the particles and thread 1 reduces the second half, the boundary between halves should be cache-line aligned. Otherwise, the reduction reintroduces false sharing at the boundary.

Spatial cells add another layer. A simulation may maintain a count of particles per cell, a list head per cell, and a lock per cell. If the cell metadata is packed densely, threads updating different cells false-share. The count is especially problematic because it is written on every insertion and removal. Padding every cell's metadata to a cache line can waste a lot of memory if the grid is large. A better approach is to use per-thread local counts and merge them periodically. If the simulation needs exact counts for allocation, a two-pass approach can count particles per cell in parallel and then prefix-sum the counts. The counting pass uses per-thread local arrays, and the merge is a separate phase. The cell metadata is then written once per time step, not on every particle movement.

Particle migration is the hardest case. When particles move from one cell to another, multiple threads may write to the same destination cell's list. This is true sharing, and it requires synchronization. A lock per cell is one option. The lock and the list head should be in the same line, because they are accessed together, but the lock should not share a line with a neighboring cell's lock. If the cell locks are packed, threads locking different cells will false-share. Padding the locks is the simplest fix. A more scalable design uses per-thread staging buffers. Each thread appends migrating particles to its own buffer. A merge phase then combines the buffers into the destination cells. The merge phase partitions cells by cache-line-aligned ranges, so each thread owns a set of destination lines. This avoids both lock contention and false sharing during the merge. The staging buffers themselves must be padded, or the threads will false-share while appending.

Neighbor lists are another source of accidental sharing. A neighbor list may be stored as an array of list heads indexed by particle. Each thread builds lists for its own particles. If the list heads are adjacent in memory, two threads writing different heads share a line. The fix is to pad the per-thread list heads or to allocate each thread's list heads from a separate cache-line-aligned pool. The list nodes themselves are often allocated from a shared allocator. If the allocator returns adjacent nodes to different threads, the nodes may false-share. A per-thread pool for list nodes avoids this. The pool's metadata should also be padded. This is the same pattern as the per-thread allocator case: the allocator's internal free lists and statistics are as important as the objects it returns.

Measurement for a particle simulation should separate the phases. Run the force computation, the integration, and the migration phases separately. Use `perf c2c` to identify lines with high HITM counts in each phase. A high HITM count on the force array during the force phase suggests false sharing between thread ranges or symmetric updates. A high HITM count on cell metadata during migration suggests packed locks or counters. A controlled experiment can change the block size or the padding and measure the effect. If aligning thread ranges to cache-line boundaries removes the HITM events and improves scaling, the diagnosis is confirmed. The experiment should also check whether the alignment changes the load balance. A cache-line-aligned partition may give some threads slightly more work. The performance benefit from reduced coherence traffic usually outweighs the small imbalance, but it should be measured.

## From padding to ownership: a design discipline

The case studies point to a broader principle. Padding is a local fix. Cache-line ownership is a design discipline. The question is not only whether two variables are adjacent, but which thread is allowed to write to each line. If a line is written by only one thread, there is no false sharing on that line. If a line must be written by multiple threads, the writes should be infrequent, batched, or protected by a protocol that makes the sharing true and necessary.

A practical design review should identify every line that is written frequently. For each such line, ask which threads write it. If the answer is more than one, ask whether those threads are cooperating on the same logical data. If they are, the sharing is true, and the solution is algorithmic: reduce the frequency of writes, batch updates, use a lock or atomic protocol, or use message passing. If they are not cooperating, the sharing is false, and the solution is layout: separate the variables into different lines, partition the data by ownership, or use per-thread buffers. The distinction matters because the fixes are different. Padding a true-sharing line does not help; it just wastes memory. Reducing the frequency of writes on a false-sharing line may help, but the layout is still wrong.

Ownership partitioning is often better than padding because it scales with the number of threads without wasting memory per variable. Instead of padding every counter, partition the counters into cache-line-aligned blocks and assign each block to a thread. Instead of padding every cell's metadata, group cells into cache-line-sized segments and assign segments to threads. Instead of padding every particle's force accumulator, use per-thread buffers and reduce. The goal is to make the unit of ownership match the unit of coherence. The hardware owns lines; the software should own lines too.

This discipline also applies to read-mostly data. A line that is read by many threads and written rarely can remain shared. The cost of an occasional invalidation may be acceptable. The danger is a line that is mostly read but written often enough to cause repeated invalidations. In that case, separate the write-heavy field from the read-heavy fields. A version counter, a statistics counter, or a dirty flag next to immutable data is a classic example. The immutable data is read by many threads; the counter is written by one or more threads. If they share a line, every counter update invalidates the readers. Moving the counter to its own line or batching its updates can eliminate the interference.

The same reasoning applies to allocators, queues, hash tables, and simulations. The details differ, but the pattern is consistent. Find the lines that are written by multiple threads without a logical reason. Change the layout so that each line has a clear owner. If ownership cannot be exclusive, make the sharing explicit and amortize it. Measure the result with hardware counters and controlled experiments. Do not assume that a source-level absence of shared variables means an absence of sharing. The hardware sees lines, not variables.

The next section will examine how to encode these ownership rules in reusable data structures and how to validate them with regression benchmarks that catch false sharing before it reaches production.

## Encoding ownership in reusable data structures

Reusable components are where false sharing most often escapes review. A generic container, lock table, thread registry, or memory pool is written once and used in many contexts. Its internal layout is rarely visible to callers. If the structure packs independently written fields into the same cache line, every caller inherits the coherence cost. The fix is not to sprinkle padding into application code. The fix is to make cache-line ownership part of the component's interface and invariants.

A small wrapper type is useful for making ownership explicit. It does not solve every layout problem, but it gives names to the concepts and makes accidental adjacency harder.

```cpp
constexpr std::size_t kCacheLine = 64;

template <typename T>
struct alignas(kCacheLine) CacheLineAligned {
    T value;
};

static_assert(alignof(CacheLineAligned<std::atomic<std::uint64_t>>) == kCacheLine);
static_assert(sizeof(CacheLineAligned<std::atomic<std::uint64_t>>) % kCacheLine == 0);
```

The wrapper guarantees that each instance starts on a cache-line boundary. For an array of wrappers, the size assertion matters as much as the alignment assertion. If the type's size were not a multiple of the line size, adjacent elements could still share a line. In practice, a complete object type's size is a multiple of its alignment, but the static assertion documents the requirement and catches platform-specific surprises. The constant should be chosen from the target platform or from a documented build-time definition. C++17's `std::hardware_destructive_interference_size` is tempting, but its value is implementation-defined and can differ between translation units or runtimes. Treat it as a hint, not a universal 64-byte guarantee.

The wrapper is only the first step. A reusable component should expose ownership in its API. A per-thread registry, for example, should not return a pointer to a packed array element and expect callers to know the layout. It should provide a `for_thread(thread_id)` accessor that returns a reference to a line-aligned slot. The implementation can use an array of `CacheLineAligned<Slot>` and the caller never needs to reason about padding. The same idea applies to per-thread statistics, per-thread allocators, and per-thread scratch buffers. The component owns the layout policy; the caller owns the logical data.

Hidden adjacency is common in class hierarchies. A base class subobject and a derived class member may be placed in the same cache line. If the base holds a lock or a reference count and the derived member is read by other threads, the hierarchy reintroduces false sharing even though the derived class looks independent. Composition is often safer than inheritance for hot data. If inheritance is required, the base should be aligned or the hot fields should be moved into a separate, explicitly aligned member. Empty base optimization can also place a base subobject at the same address as the first member, which is another reason to inspect the final layout rather than assuming that separate declarations imply separate lines.

Containers need special attention because they are designed to pack elements. `std::vector<std::atomic<uint64_t>>` is compact and cache-friendly for reads, but it is a false-sharing trap when different threads write different elements. A padded container should make the stride explicit:

```cpp
template <typename T, std::size_t N>
class PaddedArray {
    static constexpr std::size_t kStride =
        (sizeof(T) + kCacheLine - 1) / kCacheLine * kCacheLine;

public:
    T& operator[](std::size_t i) {
        return *reinterpret_cast<T*>(
            reinterpret_cast<unsigned char*>(storage_) + i * kStride);
    }

private:
    alignas(kCacheLine) unsigned char storage_[N * kStride];
};
```

This is a sketch, not a production-ready container. It ignores construction, destruction, aliasing, and alignment details for types with stricter alignment than the line size. The important part is the policy: the stride is rounded up to a cache line, so adjacent elements do not share a line. A production version should use placement new, provide iterators, and enforce alignment with `static_assert`. It should also document the memory cost. A padded array of one million elements can waste tens of megabytes. That cost may be justified for a hot per-thread array and unacceptable for a cold lookup table.

The API should also distinguish between "packed for locality" and "padded for ownership." A single container cannot be optimal for both. A read-only table benefits from packing because it improves spatial locality and reduces cache footprint. A write-heavy table with per-thread ownership benefits from padding because it reduces coherence traffic. Reusable components should offer both layouts, or at least make the choice visible in the type name and documentation. A type called `PaddedArray` that silently packs elements is worse than no abstraction at all.

## Ownership-aware containers and allocators

The next level of the discipline is to partition data by cache line rather than by element count. A thread should own complete lines, not arbitrary slices of an array. This is the difference between padding individual variables and designing an ownership-aware container. Padding fixes a known adjacency; ownership partitioning prevents new adjacencies from appearing as the data structure grows.

A block-partitioned container makes the unit of ownership explicit. The block size is chosen so that a block occupies one or more cache lines, and the container assigns blocks to threads. The boundary between two threads' regions falls on a line boundary. A thread may read neighboring blocks, but it writes only its own blocks. This is a stronger invariant than "each thread has its own counter." It applies to arrays, hash tables, particle lists, and work queues.

```cpp
template <typename T, std::size_t ItemsPerLine>
struct alignas(kCacheLine) OwnedBlock {
    T items[ItemsPerLine];
};

template <typename T, std::size_t ItemsPerLine>
class BlockPartitionedArray {
public:
    OwnedBlock<T, ItemsPerLine>& block_for(std::size_t block_id) {
        return blocks_[block_id];
    }

private:
    std::vector<OwnedBlock<T, ItemsPerLine>> blocks_;
};
```

The container does not need to know which thread owns which block. It only needs to guarantee that a block is line-aligned and that its size is a multiple of the line size. The scheduler or the algorithm assigns blocks to threads. The invariant is simple: if a thread writes to a block, no other thread writes to that block. Reads from other blocks are allowed and remain cheap as long as the line is not being modified.

Allocators are the other half of the problem. A container can request line-aligned memory, but the allocator must honor the request. Over-aligned types require aligned allocation. In C, `aligned_alloc` or `posix_memalign` can provide the alignment. In C++, the allocator used by a container must respect `alignof(T)` and any stronger alignment requested by the type. A custom pool allocator should separate its metadata from its payload. The metadata for thread 0 and thread 1 should not share a line, because the allocator updates that metadata on every allocation. The payload blocks can be packed within a thread's arena, because only that thread writes them. This split between hot metadata and cold payload is a recurring pattern. It reduces false sharing without padding every allocated object.

A lock table is another place where ownership matters. A striped lock table with adjacent locks will false-share when different threads acquire different locks. Padding each lock to a cache line is the direct fix, but it can waste memory for large tables. A segmented lock table groups several locks into a cache-line-sized segment and uses one lock per segment. The segment is the unit of ownership. Threads that acquire different segments do not interfere. Threads that acquire different locks in the same segment serialize, but that contention is visible and bounded. The design trade-off is explicit: fewer locks, more coherence independence. For a table with many hot locks, the segmented design is often better than a densely packed lock array.

The same reasoning applies to memory pools and free lists. A per-thread free list should be line-aligned, and its head pointer should not share a line with another thread's head pointer. The free-list nodes themselves can be packed within a thread's arena. If the allocator maintains global statistics, those statistics should be separated from the per-thread free lists. A global counter updated on every allocation is a true-sharing bottleneck, but a per-thread counter adjacent to a per-thread free list is false sharing. The fix is to keep the hot metadata in its own line and flush the statistics periodically.

## Regression benchmarks for invisible contention

False sharing is invisible to functional tests. A program with false sharing produces the correct answer, often with the same output as a fast version. The only difference is time and hardware behavior. That makes regression testing difficult. A test suite that checks correctness will not catch the problem. A performance regression suite can, but only if it is designed to isolate layout effects and to tolerate machine noise.

The most useful regression test is a controlled canary. The canary should have two versions of the same algorithm: one with packed per-thread data and one with line-aligned per-thread data. The algorithm should be trivial, so the only difference is layout. A per-thread counter benchmark is a good canary. Each thread increments its own atomic counter. The packed version places the counters in one array. The padded version places each counter on its own line. The test measures the time for both versions and compares their scaling as the thread count increases.

```cpp
struct PackedCounters {
    std::atomic<std::uint64_t> counters[8];
};

struct PaddedCounters {
    alignas(kCacheLine) std::atomic<std::uint64_t> counters[8];
};

template <typename Counters>
std::chrono::nanoseconds run_counters(Counters& c, int threads,
                                     std::uint64_t iterations) {
    auto start = std::chrono::steady_clock::now();
    std::vector<std::thread> pool;
    for (int t = 0; t < threads; ++t) {
        pool.emplace_back([&, t] {
            for (std::uint64_t i = 0; i < iterations; ++i) {
                c.counters[t].fetch_add(1, std::memory_order_relaxed);
            }
        });
    }
    for (auto& thread : pool) thread.join();
    return std::chrono::steady_clock::now() - start;
}
```

The test should pin threads to distinct cores, run each version several times, and use the median. The absolute times are machine-specific. The useful metric is the ratio between the packed and padded versions at the same thread count. If the packed version becomes much slower as threads increase while the padded version scales, the canary is detecting false sharing. A regression threshold can be expressed as a maximum allowed ratio. The threshold should be calibrated on the target hardware and should be loose enough to avoid flakiness. A canary that fails on a noisy CI runner is worse than no canary.

If hardware counters are available, the test can also record coherence events. A `perf stat` wrapper can count snoop-hitm or remote-HITM events for the packed and padded versions. The event names are model-specific, so the test should treat them as optional. The timing ratio is the portable signal; the counter ratio is corroborating evidence. A high HITM count on the packed version and a low count on the padded version confirms the diagnosis. A high count on both versions suggests true sharing or a different bottleneck.

The regression suite should also check layout invariants. Static assertions can verify that a padded type's alignment and size are multiples of the cache line. Runtime checks can verify that dynamically allocated per-thread structures are aligned. These checks are cheap and catch accidental changes to a struct's layout. A field added to a hot struct can silently undo padding. A static assertion on `sizeof` and `alignof` will fail at compile time, which is much better than a mysterious performance regression in production.

Finally, the benchmark harness itself must avoid false sharing. If the harness collects per-thread results in a packed array, the measurement code can become the bottleneck. Use padded result slots or accumulate locally and merge once. The same ownership discipline applies to the test as to the program under test. A regression benchmark that is itself contaminated by false sharing will produce misleading numbers and erode trust in the suite.

A subsequent section will turn these ideas into a code-review checklist and a set of diagnostics that can be run before a release, including how to inspect struct layouts and how to choose between padding, partitioning, and algorithmic reduction.
