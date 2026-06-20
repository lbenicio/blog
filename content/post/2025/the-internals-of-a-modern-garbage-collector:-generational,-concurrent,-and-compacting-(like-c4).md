---
title: "The Internals Of A Modern Garbage Collector: Generational, Concurrent, And Compacting (like C4)"
description: "A comprehensive technical exploration of the internals of a modern garbage collector: generational, concurrent, and compacting (like c4), covering key concepts, practical implementations, and real-world applications."
date: "2025-03-30"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/The-Internals-Of-A-Modern-Garbage-Collector-Generational,-Concurrent,-And-Compacting-(like-C4).png"
coverAlt: "Technical visualization representing the internals of a modern garbage collector: generational, concurrent, and compacting (like c4)"
---

## When the World Stops: The Hidden War for Your Heap

### Introduction (From the user's provided text)

Imagine you are a master chef. Your kitchen is your empire: a symphony of sizzling pans, sharp knives, and fresh ingredients. You move with practiced grace, creating dishes that delight the senses. But every few minutes, a rule is enforced. You must stop. Not to taste, not to plan. You must put down your knife, step away from the stove, and spend a full minute meticulously washing, drying, and re-organizing every single dish, pot, and utensil in the entire kitchen. The guests wait, the soufflé deflates, the steak over-cooks.

This is the world of modern software before a concurrent, generational, compacting garbage collector. For decades, the vast majority of applications written in managed languages like Java, C#, and Go have operated under a similar, albeit far more complex, tyranny: the Stop-The-World (STW) pause. And while those pauses have shrunk from the seconds of a 1990s JVM to the milliseconds of a modern generational collector, for a certain class of applications—finance, high-frequency trading, real-time analytics, interactive gaming, and large-scale microservices—even a single 50-millisecond pause is a catastrophe. It’s a dropped tick, a lost trade, a frame stutter, a user that clicks away in frustration.

The garbage collector is the unsung, often vilified, hero of our runtime environments. It is the automated janitor that prevents your application from drowning in its own detritus—the abandoned objects, the orphaned strings, the forgotten HTTP connections. Without it, every programmer would be trapped in the manual memory management nightmare that still haunts the C and C++ ecosystems: `malloc` and `free`, dangling pointers, and memory leaks that crash the server at 3 AM on a Friday. But this hero comes with a price. Every time the collector needs to do its job—to trace the live object graph, to sweep the dead, to compact the heap to fight fragmentation—it must stop the application threads. Those pauses, known as Stop-The-World (STW) events, are the price we pay for memory safety and productivity.

The story of garbage collection innovation over the past two decades is the story of reducing that price. From the naive mark-sweep of early Java to the generational copying collectors of the mid-2000s, each step shaved off milliseconds. But the ultimate prize—a collector that _never_ imposes a significant pause—remained elusive. Enter the C4 garbage collector. Developed by Azul Systems for their Zing JVM, C4 (Concurrent Continuously Compacting Collector) was a groundbreaking achievement: a fully concurrent, generational, compacting garbage collector that could keep pause times below 10 milliseconds, and in many workloads, below 1 millisecond. For the first time, applications that demanded extreme latency could run on a managed runtime without the constant fear of the world stopping.

In this post, we’ll peel back the layers of C4. We’ll explore why low-pause GC is so hard, what makes C4 unique, and how it achieved its seemingly impossible goal. We’ll compare it with modern contenders like ZGC and Shenandoah, and we’ll look at the real-world impact on latency-sensitive systems. Whether you're a seasoned systems engineer, a curious developer, or someone who simply wants to understand what makes your trading platform tick, this deep dive will equip you with a thorough understanding of one of the most elegant pieces of runtime engineering ever built.

---

## 1. The Cost of Memory Management: Why GC Matters

Before we dive into the architecture of C4, let's take a step back and understand the fundamental problem that all garbage collectors solve. Modern object-oriented programs allocate memory at a furious rate. A web server processing a single HTTP request might create dozens of objects: the request object, the response object, string buffers, session objects, database connections, and countless intermediate representations. If every one of these objects had to be manually freed, the code would be littered with `free()` calls, and a single programming error—a double free, a dangling pointer, a forgotten free—could bring the entire system down. This is the reality for C and C++ applications, where memory safety is a constant battle.

### The Managed Solution: Automatic Memory Management

Languages like Java, C#, Go, and Python free the programmer from this burden by providing automatic memory management, commonly known as garbage collection. The runtime tracks which memory is still reachable from the program’s roots (stack frames, global variables, thread-local storage) and reclaims the rest. The core algorithm—tracing GC—is elegantly simple:

1. **Mark**: Starting from the roots, traverse the object graph, marking every reachable object (e.g., setting a bit in the object’s header or a separate bitmap).
2. **Sweep**: Scan the entire heap; for every unmarked object, return its memory to the free list.
3. **(Optional) Compact**: Relocate live objects to eliminate fragmentation and improve cache locality.

The mark phase is the heart of the problem. While the collector is traversing the graph, the application threads (mutators) are actively modifying references—creating new objects, updating fields, deleting references. If the collector and mutator run concurrently, the collector might miss an object that becomes reachable after it passed that part of the graph, or it might collect an object that is still reachable. This is the fundamental challenge: how to maintain a consistent view of the heap while the world is changing.

### Stop-The-World: The Simplest Solution

The most straightforward solution is to stop the world: suspend all application threads, perform a collection cycle (mark-sweep-compact) while the graph is frozen, and then resume. This eliminates all consistency problems because the collector sees a static snapshot. For decades, this was the standard approach. Early Java Virtual Machines (JVM 1.0 through 1.3) used a simple stop-the-world mark-sweep collector. For small heaps (say, 64 MB), the pause times were manageable—a few tens of milliseconds. But as heaps grew to gigabytes and beyond, pause times ballooned.

Consider a single-threaded mark-sweep collector on a 4 GB heap. Traversing the live object graph (the mark phase) might require touching millions of objects. Even if each object takes only a few nanoseconds to check and mark, the total time can easily exceed 100 milliseconds. The sweep phase scans the entire heap—4 GB of memory—which at modern memory bandwidth (~50 GB/s) still takes about 80 milliseconds. Add compaction, which moves live objects, and total STW time can reach 200-500 milliseconds. For a high-frequency trading application processing 10,000 orders per second, a 200 ms pause means 2,000 orders are delayed or lost.

### The Generational Hypothesis: Making STW Pauses Smaller

The breakthrough came from observing a statistical property: most objects die young. This is known as the _generational hypothesis_. In typical applications, 80-90% of objects become unreachable within a few milliseconds of allocation. If we can collect the young generation frequently (where objects are few and the graph is small), we can keep pause times low. The old generation, which contains long-lived objects, can be collected infrequently, accepting longer pauses.

This gave birth to generational collectors. In HotSpot's default collector up to Java 8, the **Parallel Scavenge** collector would copy surviving objects from Eden to Survivor spaces in parallel, with pause times proportional to the size of the young generation. For a 256 MB young generation, pauses were typically 10-20 ms. That was acceptable for many server workloads.

But there was a catch: when the old generation filled up, a major collection had to run. Major collections (mark-sweep-compact on the full heap) were still STW and could take seconds. The **Concurrent Mark-Sweep (CMS)** collector tried to reduce major collection pauses by running the mark phase concurrently with the application, but it still had STW phases (initial mark, remark, sweep) and suffered from fragmentation that could lead to a dreaded "concurrent mode failure"—a full stop-the-world compacting pause.

The war on pauses was escalating. For ultra-low-latency workloads, even minor pauses were problematic. And the major pauses were death. The goal became clear: **eliminate all STW pauses above 10 milliseconds**, and ideally above 1 millisecond.

---

## 2. The Pause Time Problem: From Seconds to Milliseconds

Let’s quantify the problem with a concrete example. Suppose you’re running a latency-sensitive e-commerce application built on the JVM. Your service level objective (SLO) demands the 99.9th percentile response time be under 10 ms. If a GC pause of 50 ms occurs even once every few minutes, that’s a violation. In a distributed system, tail latency is king. A single slow request can cascade into timeouts, retries, and ultimately a degraded user experience.

### The Anatomy of a Pause

A stop-the-world pause consists of overheads:

1. **Safepoint alignment**: The JVM must bring all threads to a safepoint where they are executing in a GC-safe state (e.g., at a method call or loop back-edge). This itself can take hundreds of microseconds.
2. **Marking**: Traverse the object graph. Time proportional to the number of live objects (or total objects if sweeping without marking).
3. **Sweeping/Compacting**: Freeing memory or moving objects. Time proportional to heap size or live object size.
4. **Resumption**: Wake up threads, handle barriers, etc.

Even a well-tuned parallel collector can incur 10-20 ms for young collections on a medium-sized server (e.g., 8-core, 32 GB heap). For larger heaps—say, 256 GB—the young generation might be 8 GB, and even a parallel copy (using multiple cores) takes tens of milliseconds. More critically, a full GC might take _seconds_.

### The Concurrency Imperative

The only way to break this ceiling is to run the collection phases **concurrently** with the application. If marking can happen while the application is running, the pause for marking is eliminated. If compaction can happen concurrently, the pause for compaction is eliminated. But concurrency introduces a host of problems:

- **How to track modifications to the graph while marking?** The collector must capture all new assignments that create new reachable paths. This is done via _write barriers_ (for regions that are being marked) or _read barriers_ (to detect stale references after compaction).
- **How to move objects while threads are using them?** If you copy an object to a new location, any thread that reads a reference to the old location must be redirected to the new location. This requires _load barriers_ or _forwarding pointers_.
- **How to ensure termination?** The collector and mutator compete: the mutator creates new objects and reaches new references, potentially prolonging the work. Concurrent GC must have a termination protocol.

The first commercially successful concurrent collector for Java was the **Concurrent Mark-Sweep (CMS)**, introduced in Java 5. CMS ran the mark phase concurrently (except for brief initial mark and remark pauses) and the sweep phase concurrently. However, CMS did not compact, leading to fragmentation. It also required free-list management, which could become slow. Most critically, CMS had a fallback: if the concurrent phase couldn't keep up with allocation, it triggered a full STW compacting collection ("concurrent mode failure"). For large heaps, that was catastrophic.

The next generation of collectors—G1 (Garbage-First) in Java 7, and later ZGC and Shenandoah in Java 11 and 12—took a different approach: they aimed to make _all_ phases concurrent, including compaction, while maintaining pause time guarantees. G1 uses concurrent marking but STW compaction (though it pauses for at most a few objects per region). ZGC and Shenandoah use concurrent compaction with load barriers. But C4, created by Azul Systems for their proprietary Zing JVM, was the first truly production-ready concurrent compacting collector, debuting around 2009. Its design influenced all of these later collectors.

---

## 3. The Quest for Single-Digit Millisecond Pauses: Generational and Concurrent GC

To appreciate C4, we need to understand the landscape at the time. In the late 2000s, the best available collectors for Java were CMS and the Parallel collector. Both had known weaknesses. Azul Systems had built a custom hardware platform (the Vega processor) with hardware support for GC, but that never achieved widespread adoption. Their software-only approach, C4, implemented on standard x86 hardware, was a game-changer.

### What Made C4 Different?

The name C4 stands for **Concurrent Continuously Compacting Collector**. The key words are _concurrent_ (most work runs alongside the application) and _continuously compacting_ (compaction is not a separate, sporadic phase but woven into the mark and update process). C4 is also _generational_: it divides the heap into a young generation and an old generation, each managed concurrently. This is a critical distinction from ZGC and Shenandoah, which are non-generational (single generation) in their default configurations (though ZGC recently added generational support in JDK 21).

Azul’s innovation was to combine all the pieces: a **load barrier** (which intercepts every read of an object reference field) to ensure that the mutator always sees a consistent view of the heap, **concurrent marking** using a tri-color abstraction with the load barrier acting as the "mutator notification" mechanism, and **concurrent compaction** by relocating objects on-the-fly and updating references using the same load barrier.

C4’s design goal was audacious: **no pause longer than 10 milliseconds, and typical pauses under 1 millisecond**. This was not just for small heaps; it had to work for heaps up to hundreds of gigabytes. The Zing JVM, which includes C4, became the go-to platform for trading firms like Goldman Sachs and for high-performance cloud applications.

---

## 4. Enter C4: Azul's Zing and the C4 Collector

Azul Systems was founded in 2002 with a mission to deliver a JVM that could run large, latency-sensitive applications without GC pauses. Their first product was the Vega hardware appliance, a specialized server with a custom processor that implemented a “read barrier” in hardware. In 2009, they introduced the C4 collector for their Zing JVM on standard x86 hardware, using a software load barrier. The “Secret Sauce” was the load barrier: a small sequence of instructions inserted by the JIT compiler at every read of an object reference. This barrier, on the hot path, checks the state of the referenced object or region. The overhead was around 5-10% throughput, but in exchange, it enabled fully concurrent GC.

### How C4’s Load Barrier Works

Consider a typical Java statement: `Foo f = bar.baz;`. This reads the `baz` field of the `bar` object. In a JVM without a barrier, this is a simple memory load. In C4, the JIT compiles this to something like:

```
load baz -> %rdi
check if %rdi points to a "marked" region
  if not (or if the region needs compaction):
    call into GC stub to handle current state
    update %rdi to the correct location
use %rdi
```

The “check” is a fast inline test on the loaded reference. It examines a few bits in the pointer (in Azul’s design, the pointer carries state using unused high bits or a biased representation). For example, the pointer might be tagged with a “compacted” bit indicating whether the target object has been relocated. If the bit says “moved”, the barrier redirects to the forwarding pointer stored in the object header or a thread-local table.

This load barrier serves dual purposes:

1. **Concurrent Marking**: During the mark phase, the barrier can detect when a thread reads a reference to an object that has not yet been marked as live. The barrier then marks that object on the fly (or the GC stub marks it), ensuring that the tri-color invariant is maintained: no black (marked) object points to a white (unmarked) object without a grey (marked but not yet scanned) intermediary. The load barrier effectively turns every mutator read into a “scanner” that propagates the mark.

2. **Concurrent Compaction**: When the collector relocates an object, it leaves a forwarding pointer in the old location. The load barrier intercepts reads that land on the old address and transparently forwards them to the new address. Over time, the collector updates all direct references through barrier-assisted “self-healing” (the mutator writes back the new address). This is known as “self-healing load barriers”.

### Generational Collecting with C4

C4 is generational. The heap is divided into:

- **Young Generation**: Where new objects are allocated. Collectors that target the young generation are performed concurrently. The load barrier ensures that references from the young generation to old objects are tracked using a remembered set (updated by a write barrier), and references from old to young are handled through the load barrier during the young collection’s marking phase.

- **Old Generation**: Long-lived objects. The old generation is collected infrequently but also concurrently. Compaction of the old generation happens incrementally—C4 continuously compacts (in the background) to prevent fragmentation, without a massive stop-the-world copy.

The genius of C4 is that there is no explicit “mark phase” and “compact phase” in the traditional sense. The collector runs a background thread that walks the object graph, marking objects concurrently. While it does so, the load barrier ensures that any changes made by the mutator are captured. Compaction is done concurrently by scanning the heap, selecting regions to compact, moving objects, and updating references. The load barrier handles the temporary inconsistency.

### Overhead and Throughput

The constant load barrier check adds a few percent overhead to every reference read. Azul claimed around 5-10% CPU overhead in typical applications. For trading systems, this is acceptable; reducing tail latency is far more important than raw throughput. However, for CPU-bound, compute-heavy workloads, this overhead could be significant. Indeed, garbage collectors are always a trade-off: low-pause collectors like C4, ZGC, and Shenandoah sacrifice throughput for latency. The original Parallel Scavenge collector can achieve 99%+ throughput (GC overhead < 1%), while C4 may add 5-10% overhead. But if low latency is the goal, it’s a fair trade.

---

## 5. Deep Dive: How C4 Works

Now let’s walk through the C4 collection cycle in detail. We’ll use a simplified model to illustrate the key mechanisms.

### Heap Organization

C4 divides the heap into a number of equally-sized **regions** (similar to G1). Each region is either young or old. Young regions are further splits into Eden (for new allocations) and Survivor (for copying survivors). Unlike G1, C4 does not copy within the young generation in a stop-the-world pause; instead, it copies concurrently.

Regions are tracked with metadata, including:

- A **mark bitmap** for each region (or a global bitmap) to indicate which objects are live.
- A **compaction state** (e.g., “not compacting”, “compacting – forwarding pointer available”).
- A **thread-local allocation buffer** for fast allocation in Eden.

### The Role of the Load Barrier

Every read of an object reference passes through the load barrier. The barrier inspects the pointer value. In Azul’s implementation, pointers are “colored” using the upper bits of the 64-bit address (which are normally ignored by the hardware because most processors use 48-bit virtual addresses). The barrier extracts the color bits and performs a switch:

- **Color 0**: Normal, unmarked region. The object is not part of an ongoing mark or compaction. The barrier does nothing extra.
- **Color 1**: The object’s region is being marked. The barrier must ensure that the object is marked as live. It does this by atomically setting a bit in the region’s mark bitmap. This is the _self-marking_ property: mutator reads automatically mark objects.
- **Color 2**: The object has been moved during compaction. The “color” indicates that the old address is no longer valid; the barrier must load the forwarding pointer (stored in a special table or in the object header) and use that. It also writes back the new address to the source field to self-heal the reference (so next time the barrier can skip it).

This design is elegant: the barrier is both a barrier and a liveness filter. It ensures that unmarked objects are marked in the process of being read, which helps the concurrent marker catch up.

### Concurrent Marking: The Tri-Color Algorithm with Load Barriers

C4 uses a concurrent mark-sweep but with a twist: marking is done via a global mark bitmap. Initially, all objects are white. The GC roots (thread stacks, globals) are scanned, and their immediate references are marked as “gray” (the object itself is marked, but its referent fields have not yet been scanned). The concurrent marker threads traverse the graph: for each gray object, they scan its fields, mark all referenced objects (if not already marked), and then mark the current object as black (scanned). The marker progresses until no gray objects remain.

But while the marker is running, the mutator is modifying references. Without barriers, a mutator could:

- Write a reference from a black object to a white object, making the white object reachable but unmarked.
- Delete a reference from a gray object to a white object that hasn’t been visited yet, making it unreachable (but already marked) – a false retention (no crash, just inefficiency).

To prevent the first case (the “mutator store” problem), C4 uses a **write barrier** (in addition to the load barrier). The write barrier intercepts assignments to fields. For instance, if `o1.field = o2` is executed, and if `o1` is currently black (marked and scanned), the write barrier ensures that `o2` is marked immediately (or that `o1` is reverted to gray to be rescanned). C4’s write barrier is simple because the load barrier already provides most of the information. Typically, the write barrier records the field reference (or the old and new values) into a buffer that the concurrent marker processes. This is a variant of the **SATB (Snapshot-at-the-Beginning)** barrier used by G1.

But C4 goes further: because of the load barrier, any white object that is _read_ by the mutator becomes automatically marked (the load barrier marks it). This means that if the mutator reads a white object, the load barrier makes it gray/black, which propagates the mark to its fields when the concurrent marker later processes it. Thus, the load barrier acts as a “mutator-driven marking” that can advance the mark faster.

In practice, C4 uses a combination: the write barrier catches assignments that might introduce new reachable paths, and the load barrier catches reads that bring objects into the live set. This dual approach ensures no live object is missed.

### Concurrent Compaction: Moving Objects Without Stopping

Compaction is the hardest part. Moving an object while threads might be accessing it requires that all references to the old location be updated to the new location. C4 does this by:

1. **Selecting regions to compact**: Typically, regions with low occupancy (few live objects) are chosen. The goal is to reclaim contiguous free memory.
2. **Initializing forwarding pointers**: For each live object in the target region, the collector computes its new address (e.g., at a compacted location at the start of a new region). It stores the mapping from old address to new address in a global forwarding table (or per-region mapping, using a hash table or bitmap-based approach).
3. **Setting the region to “compacting” state**: The region’s metadata is updated so that the load barrier on any pointer into this region triggers the compaction redirection. The barrier will now see color 2 for any reference pointing into this region.
4. **Moving objects**: Concurrent background threads copy the objects to their new locations. The copy is done atomically (e.g., using a self-loop or a CAS to update the object header). Once the copy is complete, the forwarding table is updated and the old object’s header may contain a pointer to the new one.
5. **Self-healing**: When an application thread reads a reference to an object in the compacting region, the load barrier detects color 2, loads the forwarding pointer, and returns it. It also writes the new address back into the originating field (the source object’s field), so that subsequent reads bypass the barrier. This is called _self-healing_ because the reference is updated inline.
6. **Final update of roots**: The collector updates root references (stacks, globals) through a brief pause (typically using a safepoint) or through barrier-assisted updates during root scanning. For stacks, a short pause may be needed, but C4 minimizes this by updating roots incrementally.

Because compaction is continuous, C4 does not have a “full compaction” that stops the world. Instead, it compacts a few regions at a time, in the background. The result: no fragmentation ever accumulates, and the heap remains dense.

### A Concrete Example: Concurrent Copy

Imagine we have an object `A` at address `0x1000`. The collector decides to move it to `0x2000`. It sets the region containing `0x1000` to “compacting” state. Now, suppose the application does:

```java
Object b = a.someRef;  // where a.someRef points to the object at 0x1000
```

The load barrier on the read of `a.someRef` checks the color bits of the pointer `0x1000`. They indicate compaction in progress. The barrier then looks up the forwarding table, finds the new address `0x2000`, and returns that. It also writes `0x2000` back into `a.someRef` (a self-healing write). The next time this code executes, the load barrier will see the pointer `0x2000` which has normal color (since the destination region is not compacting), and the barrier will do nothing extra.

This self-healing mechanism is essential for performance: it reduces the hot path overhead over time as references are updated.

### Pause Time Breakdown

So what pauses remain? In C4, there is a very brief STW pause at the start of a collection cycle to:

- Safely capture the root set (e.g., scanning thread stacks and global variables). This is known as the **initial mark pause**. In C4, this is typically less than 1 ms because it only scans the roots and does not traverse the heap. The roots are scanned incrementally and the objects they reference are marked by the load barrier as the threads resume.
- Potentially a small pause at the end to finalize any remaining work (like fixing up roots that were missed).

Additionally, when the collector decides to start a new concurrent phase (e.g., a young collection), it needs to ensure that all threads have flushed their local buffered assignments (write barrier buffers). This can cause a brief “global synchronization” pause, often in the microseconds range.

Azul claims that typical pause times are below 1 ms for heaps up to 512 GB, and rarely exceed 10 ms even under extreme conditions. This is achieved by careful engineering of the barrier overhead, the scalability of concurrent threads, and the avoidance of stop-the-world fallbacks.

### Memory Overhead

The load barrier requires that objects have extra metadata: either a coloring bit in the pointer (which uses bits that would otherwise be unused in 64-bit addressing) or a small object header. Azul uses the former: each pointer is tagged with a few bits indicating the region state. This reduces the available virtual address space but not in practice (since typical systems use only 48 bits). The forwarding table also consumes memory—typically a few percent of the heap size. Write barrier buffers (recording old/new references) are thread-local and sized to handle peak allocation pressure.

Overall, memory overhead is around 5-15% of the heap, depending on workload.

---

## 6. Comparison with Modern Low-Pause Collectors

C4 was a pioneer, but today the JVM ecosystem offers several open-source alternatives that achieve similar latency guarantees. Let’s compare C4 with ZGC, Shenandoah, and G1.

### ZGC (OpenJDK, since Java 11)

ZGC (Z Garbage Collector) was developed by Oracle with design heavily influenced by C4. It is also a concurrent, non-generational (until JDK 21 where generational ZGC was introduced), low-latency collector. ZGC uses **colored pointers** (similar to C4’s load barrier) and a **load barrier** for both marking and compaction. Key differences:

- ZGC uses a multi-mapping technique for heap regions (remapping virtual pages to physical memory) rather than forwarding tables, which can be more efficient.
- ZGC has a single generation (old only) before JDK 21; generational ZGC adds a young generation to reduce overhead.
- ZGC has a marking phase that uses an extra “mark stack” and a “remap” phase that runs after marking to update pointers. It achieves pause times typically under 1 ms.

Criticism: ZGC’s throughput overhead can be higher than C4’s because its load barrier is more complex (colored pointer checks need to decode the color bits and possibly remap). However, ZGC is now available in the standard OpenJDK and is free.

### Shenandoah (OpenJDK, since Java 12)

Shenandoah was developed by Red Hat. It uses a **Brooks pointer** (a forwarding pointer stored in the object header) and a **load barrier** that checks the Brooks pointer (like a read barrier). Shenandoah also uses concurrent marking and concurrent compaction. Its load barrier is simpler than ZGC’s: it always loads the Brooks pointer and then loads the actual reference from there. This incurs a constant overhead (one extra load) on every reference read. Shenandoah’s pause times are also below 10 ms.

Comparison: Shenandoah’s throughput overhead is generally considered moderate (~5-10%), similar to C4. However, its use of Brooks pointers increases object header size, adding memory overhead. Shenandoah does not have a generational mode in the standard JDK (though experimental generational has been added). For very large heaps (hundreds of GB), ZGC may scale better due to its multi-mapping.

### G1 (Garbage-First, Java 7+)

G1 is a generational collector with concurrent marking but STW compaction. It divides the heap into regions and uses a **write barrier** (SATB) for concurrent marking. Compaction is done in stop-the-world pauses, but G1 tries to limit them by doing incremental compaction: it selects a set of regions to compact in each pause, aiming for a target pause time (default 200 ms). G1 is not truly low-pause; it can still experience multi-second pauses if the heap is large and full compaction is triggered (though it tries to avoid full GC via concurrent marking). G1 is a good balance for many server applications but not for ultra-low latency.

### C4’s Unique Advantages

C4’s design predates both ZGC and Shenandoah. Its maturity and optimization on the Zing JVM (which has years of tuning for real-world workloads) gave it an edge in high-performance trading systems. Some advantages:

- **Generational from the start**: Young collection is concurrent, reducing overhead further.
- **Continuous compaction**: No need for a global remap phase; compaction happens incrementally and transparently.
- **Load barrier with self-healing**: Highly optimized inline code, not a dedicated memory load like Shenandoah’s.
- **Root scanning pause minimized**: Azul’s engineering ensures that even the initial mark pause is very short (less than 1 ms).

However, C4 is proprietary and requires the Zing JVM (now owned by Microsoft? Actually Azul is independent; Zing is a commercial product). For many, the open-source ZGC or Shenandoah are sufficient.

---

## 7. Challenges and Trade-offs

No garbage collector is perfect. C4, like all low-latency collectors, comes with trade-offs:

### Throughput Overhead

The load barrier adds an extra conditional branch and possible function call on every reference read. For CPU-intensive applications that do many object traversals, this can cause a 5-15% throughput loss compared to a parallel collector or G1. If raw throughput is your only concern, the Parallel collector or G1 in throughput mode is better.

### Complexity and Tuning

C4 has many parameters: load barrier thresholds, region size, concurrent thread count, bail-out intervals. Azul provides default settings that work for most loads, but fine-tuning can be arcane. For a typical developer, the “set it and forget it” promise of ZGC may be more appealing.

### Memory Overhead

Colored pointers reduce the usable virtual address space (though 64-bit systems have plenty). Forwarding tables and write barrier buffers also consume memory. In memory-constrained environments (e.g., containers with fixed memory limits), the overhead can be significant. G1 and parallel collectors have lower memory overhead.

### Integration with JIT

The load barrier must be inserted by the JIT compiler into all generated code. Any custom code or JNI calls need special handling. Azul’s JIT (part of Zing) is highly optimized for C4. In OpenJDK, the JITs have been adapted to support ZGC and Shenandoah, with some remaining performance gaps.

### Behavior Under Memory Pressure

If the application allocates faster than the concurrent collector can reclaim, the heap may fill up. C4 then may need to trigger a “desperate” STW collection, which could cause a larger pause. Azul engineered C4 to avoid this by adjusting GC frequency and using dynamic thresholds, but it’s not impossible. In practice, the trade-off is that low-pause collectors require more headroom (e.g., 30-50% free heap) to avoid such failures. ZGC and Shenandoah have similar requirements.

---

## 8. Real-World Use Cases: Where C4 Shines

### High-Frequency Trading (HFT)

A typical HFT application processes thousands of market data feeds per second, executes trades in microseconds. A 50 ms pause could mean losing millions of dollars. Firms like Goldman Sachs and Citadel adopted Zing/C4 early. C4’s sub-millisecond pauses allow them to run Java-based trading engines without the GC jitter that would otherwise force them to use manual memory management or off-heap techniques.

### Financial Risk Analytics

Banks run massive Monte Carlo simulations that allocate huge heaps (hundreds of gigabytes). A pause could interrupt a calculation and lead to costly delays. C4 enables these applications to run with predictable latency.

### Interactive Gaming and Virtual Worlds

Massively multiplayer online games (MMOs) have thousands of concurrent players. A 100 ms lag can ruin the experience. C4 helps keep frame times stable.

### Large-Scale Microservices

In a microservice architecture, tail latency is amplified through the network. A single slow request can cascade. Using a low-pause GC ensures that service-level agreements are met.

### Real-Time Systems

Anything from telecom infrastructure to industrial control systems can benefit from predictable GC.

---

## 9. Conclusion and Future Directions

The C4 garbage collector was a landmark achievement in runtime engineering. It proved that it was possible to have a fully concurrent, compacting, generational collector that could keep pause times consistently below 10 ms and often below 1 ms. It opened the door for Java to be used in latency-critical domains that had previously required C++.

Today, the techniques pioneered by C4—load barriers, self-healing forwarding, concurrent compaction—are available in open-source JVMs through ZGC and Shenandoah. The community is moving towards making low-latency GC the default. With generational ZGC on the horizon (already available in JDK 21), we are approaching a world where no Java application needs to fear the GC pause.

But the story isn’t over. As we push to exascale computing, with heaps in terabytes and latency requirements in microseconds, the trade-offs will continue to sharpen. We may see hardware-assisted barriers return (Intel’s MPK, ARM’s Memory Tagging Extension), or we may see more radical collector designs (e.g., persistent memory-aware GC). The legacy of C4 is that it showed us the way: the world can stop, only **if** it’s for a few microseconds.

---

_This blog post has covered the intricate design of C4, its barriers, its concurrent algorithm, and its place in the GC landscape. The next time you deploy a latency-sensitive application, you might consider not just which collector to use, but the engineering philosophy that made low-pause GC possible. The war for your heap is no longer a battle of seconds; it is a battle of microseconds. And C4 was the first to win it._
