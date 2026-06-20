---
title: "Building A Custom Memory Allocator With Size Classes, Thread Caching, And Segregated Lists (Tcmalloc)"
description: "A comprehensive technical exploration of building a custom memory allocator with size classes, thread caching, and segregated lists (tcmalloc), covering key concepts, practical implementations, and real-world applications."
date: "2022-10-17"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/building-a-custom-memory-allocator-with-size-classes,-thread-caching,-and-segregated-lists-(tcmalloc).png"
coverAlt: "Technical visualization representing building a custom memory allocator with size classes, thread caching, and segregated lists (tcmalloc)"
---

# Introduction: What Happens When `malloc` Becomes the Bottleneck

Every software engineer knows `malloc`. It’s the universal tool for dynamic memory allocation—a black box that just works. We call it, we get a pointer, we free it later, and we move on. For most applications, that’s perfectly fine. But what happens when your application serves thousands of requests per second, runs on dozens of CPU cores, and allocates millions of objects per minute? Suddenly, that humble `malloc` becomes a firehose of contention, cache misses, and fragmentation. Your carefully tuned multithreaded server starts to crawl. You add more cores, but throughput flatlines. You profile and see that over 30% of CPU cycles are spent inside `malloc`. The system isn’t doing your work—it’s fighting itself for a single global lock.

This is the problem that drives every high‑performance system away from general‑purpose allocators and toward custom designs. The standard allocators provided by operating systems and glibc—while excellent for typical desktop workloads—were not built for the massive concurrency and allocation patterns of modern distributed databases, web servers, game engines, or real‑time analytics pipelines. The trick is to design an allocator that matches the workload: one that minimizes lock contention, reduces fragmentation, and plays nicely with the CPU cache hierarchy. Over the past two decades, a handful of production‑proven allocators have emerged—jemalloc, mimalloc, and the one we’ll explore in this post: **tcmalloc** (Thread‑Caching Malloc).

Tcmalloc, developed at Google and later open‑sourced as part of `gperftools`, pioneered a set of ideas that are now considered standard in high‑performance memory management: **size classes**, **thread‑local caches**, and **segregated free lists**. These three concepts form the backbone of a design that can handle millions of allocations per second with minimal overhead and near‑zero lock contention. In this post, we’ll peel back the layers of tcmalloc, examine its internals, walk through allocation and deallocation step by step, compare it with other allocators, and understand why it remains a go‑to choice for latency‑sensitive systems.

---

## Background: The General‑Purpose Allocator Problem

Before we appreciate tcmalloc’s genius, we need to understand what makes traditional allocators struggle under load. The most widely used allocator on Linux is **glibc’s malloc** (ptmalloc3). It’s a variant of Doug Lea’s `dlmalloc`, improved by Wolfram Gloger for multithreading. Like many allocators, it uses a **free‑list** structure: memory is split into chunks, each chunk has a size tag, and free chunks are kept in bins sorted by size. When a thread calls `malloc`, it searches the appropriate bin for a chunk large enough, splits it if needed, and returns a pointer. When a thread calls `free`, the chunk is inserted back into a bin, and adjacent free chunks are coalesced to prevent fragmentation.

This design works well for single‑threaded programs and moderate concurrency, but it has three fatal flaws when scaled:

1. **Global lock serialization.** The free‑list bins are global data structures. In ptmalloc3, there is a single **arena** per thread (or per CPU core) to reduce contention, but arenas still require locks when borrowing from or returning to the global pool. Under high thread counts, threads spend most of their time waiting for locks. Even with per‑thread arenas, the number of arenas is typically capped (e.g., 2× CPU cores), leading to lock contention when threads overflow.

2. **Cache miss amplification.** In ptmalloc, the metadata (bin headers, chunk sizes, free‑list pointers) is interleaved with user data. When thread A allocates memory, it accesses the free list, which is likely in a different cache line than thread B’s recently freed chunk. This false sharing causes cache line bouncing across cores, devastating performance in NUMA systems.

3. **Fragmentation.** General‑purpose allocators must handle any size request from 1 byte to huge blocks. To be flexible, they maintain many bins (e.g., 64 bins covering sizes 16–512 bytes, then larger bins for powers of two). But because the bins are sparse, small allocations often waste bytes (internal fragmentation). Worse, frequent mixed‑size allocations and frees can lead to external fragmentation over time, leaving large holes that can’t be reused.

These problems manifest as slow downs, high TLB miss rates, and memory bloat. The standard malloc is fine for a text editor or a small web server, but for a high‑traffic database like MySQL, a web framework like Nginx with many workers, or a real‑time trading system, it becomes a bottleneck.

---

## Core Concepts of tcmalloc

Tcmalloc attacks all three problems simultaneously by separating concerns into three layers:

- **Thread‑Local Cache (TLC)** – Each thread has a cache of pre‑allocated, fixed‑size objects. This eliminates locking for most small allocations.
- **Central Free List (via transfer cache)** – When a thread’s cache is empty or full, it exchanges memory with a central pool using a lock‑free or lightweight‑locked mechanism.
- **Page‑Level allocator** – Large allocations (above a threshold) bypass caches and use direct `mmap`, minimizing fragmentation.

The key insight is that real‑world workloads have a **skewed size distribution**: most objects are small (tens to hundreds of bytes), and a few are large. Tcmalloc optimizes for the common case—small objects—while making large allocations straightforward.

### Size Classes and Segregated Free Lists

The fundamental building block of tcmalloc is the **size class**. Instead of handling arbitrary sizes via variable‑length chunks, tcmalloc pre‑defines a set of round‑number sizes:

```c
// Example size classes (actual gperftools list is ~90 classes)
0:      8 bytes
1:     16 bytes
2:     24 bytes
3:     32 bytes
...
8:     64 bytes
16:   128 bytes
24:   256 bytes
36:  1024 bytes
...
```

The size classes grow slowly (often by 8–16 bytes for small sizes, then roughly exponentially). When user code requests, say, `malloc(58)`, tcmalloc rounds up to the next class (64 bytes). The wasted space is at most the step size – typically less than 10% of the request. This is **internal fragmentation**, but it’s bounded and predictable.

For each size class, tcmalloc maintains a **segregated free list** – a linked list of free objects of exactly that size. These free lists exist both per‑thread (in the thread‑local cache) and globally (in the central free list). This segregation means that an allocation only ever looks at the free list for its exact size class. No more searching bins, splitting, or coalescing. The free list is essentially a stack (LIFO), which returns the most recently freed object, keeping it hot in the cache.

The segregated free list approach dramatically reduces fragmentation because all objects in a list are the same size, so an `alloc(64)` always reuses a slot that was `free(64)` before. There’s no need to split large blocks into small pieces or merge adjacent small blocks back together. Over time, memory naturally stays packed.

### Thread‑Local Caches (TLC)

The real star of tcmalloc is the **thread‑local cache**. Each thread has a small, per‑size‑class stash of free objects – typically a few dozen to a few thousand depending on usage. When a thread calls `malloc`, it first checks its own cache. If the cache for that size class is non‑empty, it pops the top object and returns it. No lock is acquired. No atomic operation. Just a pointer move.

Similarly, when a thread calls `free`, the object is returned to the thread‑local cache for its size class. If the cache is full (exceeds a high‑water mark), the thread “garbage collects” by transferring a batch to the central free list.

This design nearly eliminates contention: threads only interact when a thread‑local cache empties and must fetch from the central pool, or when it overflows and returns memory to the pool. In practice, the interaction rate is low because typical alloc‑free patterns are balanced within a thread (e.g., request processing cycles). The result is that 95‑99% of small allocations and deallocations are lock‑free.

### Central Free List and Transfer Cache

The central free list holds the global pool of free objects for each size class. But fetching from the central list requires a lock. To reduce the number of trips to the central list, tcmalloc uses an intermediate **transfer cache**. The transfer cache is a small, lock‑free ring buffer (usually using atomic operations) that sits between the thread‑local cache and the central free list.

When a thread’s cache is empty, it first tries to grab a batch from the transfer cache (e.g., 10 objects). If the transfer cache is empty, it then acquires a lock to the central free list and refills both the transfer cache and its own cache. Similarly, when a thread’s cache is full, it first dumps a batch to the transfer cache, and if that is full, it locks the central list and moves objects there.

Because the transfer cache is lock‑free (using compare‑and‑swap), most batch exchanges between threads are non‑blocking. The central list lock is only contended when all transfer caches are empty or full, which is rare under steady state.

### Span Management and Page‑Level Allocation

Tcmalloc doesn’t allocate memory from the OS one object at a time. Instead, it grabs large chunks (called **spans**) from the OS, typically using `mmap` or `sbrk`. A span is a contiguous run of pages (usually 8KB pages, but configurable). The span is then carved into fixed‑size objects of a given size class using a page‑level bitmap or linked list.

For example, a span of 8 pages (64KB) dedicated to 256‑byte objects will be split into 256 slots. Each slot is an object in the free list. The span itself is a metadata structure that records:

- Start address and length (in pages)
- Size class of objects in this span
- Number of free objects remaining
- Pointer to the free‑list head within the span
- Link to next span in the list

Spans are organized into a **span list** for each size class. When a thread’s cache needs more memory, it requests a span from the central cache. The central cache either returns a previously freed span (if any) or allocates a fresh span from the OS.

Large allocations (above a threshold, default 256KB or 1MB) are handled directly: tcmalloc returns a span of whole pages, not carved into small objects. This avoids the overhead of managing many small slots for huge requests and reduces fragmentation.

### Garbage Collection and Return to OS

Thread‑local caches are not allowed to grow unbounded. Each size class has a maximum cache size (e.g., 2^20 bytes). When a thread’s total cached memory exceeds this limit, the garbage‑collection routine is triggered: it frees some objects from the thread’s caches, returning them to the central free list. This is typically done for all size classes at once to amortize overhead.

Furthermore, tcmalloc can return unused spans to the OS when memory pressure is high. This is done via `madvise` (MADV_DONTNEED) or `munmap`. The policy is configurable. In Google’s production environment, they typically keep spare memory to avoid the cost of later allocations.

---

## Detailed Walkthrough: How tcmalloc Handles `malloc(64)`

Let’s trace a simple allocation through the entire pipeline. The code snippets below are illustrative, based on the open‑source `gperftools` implementation (simplified for clarity).

### Step 1: Determine Size Class

```c
// In the global table, mapping size -> class index
static const int kNumClasses = 89;
static const size_t kClassSizes[kNumClasses] = {8, 16, 24, ...};
// Lookup can be done via a small array indexed by (size - 1) / 8 for tiny sizes
int class_idx = GetSizeClass(64); // returns 8 (if 64 is class 8)
// round up: actual allocated size = 64 bytes
```

### Step 2: Check Thread‑Local Cache

```c
// Per‑thread structure
struct ThreadCache {
    FreeList per_class_cache[kNumClasses];
};

// Inside malloc:
ThreadCache* cache = GetThreadCache(); // TLS variable
FreeList* fl = &cache->per_class_cache[class_idx];
if (fl->length > 0) {
    void* ptr = fl->Pop();  // O(1), no lock
    return ptr;
}
```

`fl->Pop()` returns the head of a singly linked list. The free list stores objects using the first bytes of the object itself as a next pointer (since the memory is not in use by the user). This is safe because the object is free.

### Step 3: Refill from Transfer Cache (if empty)

If the thread‑local cache is empty, we try to refill it from the **transfer cache** – a lock‑free buffer per size class, shared by all threads.

```c
struct TransferCache {
    // A circular buffer with atomic head/tail
    void* buffer[TRANSFER_SIZE];
    std::atomic<int> head, tail;
};

// Attempt atomic pop of a batch
void* ptr = NULL;
int count = 0;
// We'll try to move up to 16 objects from transfer cache to thread cache
while (count < 16) {
    void* obj = TransferCachePop(class_idx);
    if (!obj) break;
    thread_cache->Push(class_idx, obj);
    count++;
}
// If we got at least one, return first one
if (count > 0) return thread_cache->Pop();
```

The `TransferCachePop` uses a CAS loop to atomically increment the tail index and retrieve the pointer. If the transfer cache is empty, we go to the central free list.

### Step 4: Central Free List (with Lock)

```c
// CentralFreeList per size class, protected by a spinlock
struct CentralFreeList {
    SpinLock lock;
    SpanList spans; // list of spans with free objects
    size_t size_class;
};

// Called when both thread cache and transfer cache are empty
// We'll acquire a batch of 64 objects from the central list
{
    LockGuard l(&central_free_lists[class_idx].lock);
    // Find a span with free objects
    Span* span = central_free_lists[class_idx].nonempty_span;
    if (!span) {
        // Need to allocate a new span from page heap
        span = page_heap->NewSpan(class_idx);
        // Split the span into objects, create free list
        // ... (see below)
    }
    // Transfer a batch to transfer cache and thread cache
    void* batch[64];
    int fetched = span->PopObjects(64, batch);
    // Store batch in transfer cache
    for (int i = 0; i < fetched; i++) {
        TransferCachePush(class_idx, batch[i]);
    }
}
// After releasing lock, refill thread cache from transfer cache and return
return thread_cache->Pop();
```

### Step 5: New Span Allocation from Page Heap

If no span has free objects for the size class, tcmalloc requests a fresh span. The page heap manages all spans allocated from the OS.

```c
Span* PageHeap::NewSpan(size_t size_class, size_t num_pages) {
    // Look up the number of pages needed for one span of this size class
    // Typically 1 page (8KB) for small size classes, but can be more
    size_t span_size_pages = SpanPagesForClass(size_class);
    Span* span = free_span_list.Get(span_size_pages);
    if (!span) {
        // mmap a large superpage (e.g., 256 pages = 2MB)
        span = mmap_alloc(span_size_pages);
    }
    // Initialize span: mark free objects by linking them
    InitSpan(span, size_class);
    return span;
}
```

The span is initialized by walking its address range and building a free‑list of fixed‑size objects. For example, a 8KB span for 64‑byte objects yields 128 objects. Their addresses are linked together (using pointers placed at the start of each object). Then the span is added to the central free list’s nonempty list.

### Step 6: Return pointer

Eventually, the user receives a pointer to 64 bytes of usable memory (the first 8 bytes of which might have been overwritten by free‑list pointers during allocation, but that’s transparent).

### `free(ptr)` Walkthrough

Deallocation mirrors allocation:

1. Determine size class from the pointer using **page map** – tcmalloc maintains a radix tree mapping every page to its owning span. The span knows the size class. This mapping is updated when spans are allocated/freed. Lookup is fast: a handful of array accesses.

2. Return object to thread‑local cache: `thread_cache->Push(class_idx, ptr);`

3. If cache length exceeds high‑water mark, run incremental garbage collection: move a batch to transfer cache. If transfer cache is full, lock central list and empty some of them.

---

## Performance Characteristics

Tcmalloc’s performance has been benchmarked extensively. In Google’s internal studies and third‑party tests, tcmalloc consistently outperforms glibc malloc for multithreaded workloads, often by factors of 2–10x. Here are the key metrics:

### Throughput (allocations/second)

Using a benchmark that spawns N threads, each repeatedly allocating and freeing objects of random small sizes (e.g., 1–256 bytes), tcmalloc scales nearly linearly up to 64 cores. glibc malloc typically flatlines after 8–16 cores. The chart below (conceptual) shows allocations per second:

| Threads | glibc malloc | tcmalloc    |
| ------- | ------------ | ----------- |
| 1       | 15 million   | 18 million  |
| 8       | 30 million   | 140 million |
| 32      | 25 million   | 550 million |
| 64      | 20 million   | 1.0 billion |

Tcmalloc’s performance does not degrade because each thread works independently.

### Lock Contention

In glibc, top‑level lock contention can be measured by `perf lock`. Under 32 threads, over 60% of lock acquisitions are contended. In tcmalloc, less than 5% of transfers involve the central lock; the rest are handled by thread‑local or transfer caches.

### Fragmentation

Memory overhead depends on workload. Tcmalloc has bounded internal fragmentation (≤ 10–15% for small objects), and external fragmentation is low because all objects in a span are same‑size. However, over‑reservation (too many unused objects in caches) can temporarily increase RSS. Google’s production systems typically see memory usage 5–10% higher than glibc for comparable workloads, which is often acceptable given the speed gains.

### Cache Locality

Because each thread has its own cache, and because free lists are LIFO, recently freed objects are likely to be reused immediately by the same thread, keeping them in L1/L2 cache. Additionally, metadata (span pointers) is kept in a separate page‑mapping structure, not interleaved with user data, reducing false sharing.

---

## Comparison with Other High‑Performance Allocators

Tcmalloc was not the last word in allocators. Two successors have gained popularity: **jemalloc** (used by Facebook, FreeBSD) and **mimalloc** (Microsoft). How do they compare?

| Feature             | tcmalloc                         | jemalloc                             | mimalloc                       |
| ------------------- | -------------------------------- | ------------------------------------ | ------------------------------ |
| Thread caching      | Per‑thread (TLS)                 | Per‑thread, also per‑arena           | Per‑thread with local bins     |
| Size classes        | Fixed (89 classes)               | Adaptive (tunable)                   | Fixed (mostly powers of 2)     |
| Central management  | Transfer cache + central FL      | Red‑black trees, lazy purging        | Segments, per‑size freelists   |
| Large allocations   | Direct spans                     | Huge pages, bypass caches            | Direct mmap                    |
| Integration         | LD_PRELOAD, gperftools           | LD_PRELOAD, jemalloc library         | LD_PRELOAD, libmimalloc        |
| Memory overhead     | Low to moderate                  | Low (more aggressive purge)          | Very low (minimal metadata)    |
| Scalability         | Excellent (TLC + transfer)       | Excellent (arena + TC)               | Excellent (fast paths)         |
| Worst‑case behavior | Cache blowout from many threads? | Slight overhead for tiny allocations | Slight fragmentation for tiny? |

In practice, all three are within 10–20% of each other in most benchmarks. Jemalloc is known for better memory usage under fragmentation‑prone workloads because it uses **run‑length encoding** and **lazy purging** (returning memory to OS more eagerly). Mimalloc excels at extremely low latency (it uses a compact free‑list structure and no lock‑free transfer cache; instead uses lightweight local locking). Tcmalloc remains a strong choice because of its simplicity, predictability, and widespread documentation.

---

## Advanced Topics

### Alignment

Tcmalloc guarantees alignment to at least 16 bytes for allocations up to 256 bytes, and to at least 8 bytes for smaller sizes. This is important for SSE/AVX aligned loads. The size class system inherently provides this alignment because class sizes are multiples of 8 or 16.

### Huge Pages

By default, tcmalloc uses normal 4KB pages (or 8KB). However, on systems that support transparent huge pages, tcmalloc can request spans aligned to 2MB boundaries. This reduces TLB pressure, which is critical for workloads allocating many objects. The `gperftools` library includes an option to enable huge page usage via environment variables.

### Dynamic Size Class Tuning

While tcmalloc’s size classes are fixed at compile time, modern versions allow some tuning via environment variables (`TCMALLOC_LARGE_ALLOC_REPORT_THRESHOLD`). In contrast, jemalloc can dynamically adjust size classes based on allocation patterns. Tcmalloc compensates with the **transfer cache** to mitigate the effects of slightly mismatched sizes.

### Memory Profiling

One of the killer features of the `gperftools` package is the built‑in memory profiler (`pprof`). With tcmalloc linked, you can run your application and generate heap profiles over time, showing which functions allocate the most memory. This is invaluable for debugging memory leaks and bloat. For example:

```bash
env HEAPPROFILE=/tmp/profile ./my_server
pprof --text ./my_server /tmp/profile.0001.heap > allocations.txt
```

This integration is a major reason tcmalloc remains popular in the C++ ecosystem.

---

## Potential Pitfalls and When Not to Use tcmalloc

No allocator is perfect. Here are scenarios where tcmalloc may not be the best choice:

1. **Extremely high allocation rates but very short‑lived objects** – The thread‑local cache can become a source of memory pressure if threads allocate and free many objects in tight loops, causing cache flushes. Jemalloc’s arena‑based design can be more efficient in this case.

2. **Single‑threaded applications** – The overhead of maintaining thread‑local structures (TLS) and the radix tree for mapping can be slightly higher than glibc’s minimal all‑purpose allocator. For single‑threaded tasks, glibc may be faster.

3. **Memory‑constrained environments** – Tcmalloc’s caching can keep more memory resident than necessary. If your system has tight RSS limits, tune the cache sizes or consider jemalloc’s aggressive purging.

4. **Real‑time systems** – While tcmalloc is fast, its worst‑case latency (when a thread‑local cache empties and must go to central list) can be unpredictable. For hard real‑time, consider a region‑ or arena‑based allocator.

5. **Custom OS or embedded kernels** – Tcmalloc uses `mmap`, `sbrk`, and `pthread` TLS. These may not be available in all environments. For embedded systems, a simpler buddy allocator might be appropriate.

---

## Conclusion

Tcmalloc is a testament to the principle that understanding your workload and tailoring data structures can yield dramatic performance improvements. By decoupling thread‑local fast paths from global coordination, using fixed size classes to eliminate searching and splitting, and employing a hierarchy of caches to amortize locking, tcmalloc turns `malloc` from a bottleneck into a nearly invisible operation.

Whether you are building a high‑throughput web server, a distributed database, or a game engine, tcmalloc (or one of its younger siblings) should be part of your toolbox. Its design influenced a generation of allocators and remains a benchmark against which new algorithms are measured. The next time your profiler shows 30% of CPU cycles in `malloc`, remember that it doesn't have to be that way. With the right allocator, that 30% can become 1%. And that’s the kind of free lunch you rarely get in systems programming.

If you want to explore further, the source code of tcmalloc (in `gperftools`) is remarkably readable. Start with `tcmalloc.cc`, `common.h`, and `span.h`. You’ll see the concepts we’ve discussed laid out in clean C++ with extensive comments. Happy hacking.
