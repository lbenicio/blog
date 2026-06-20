---
title: "The Implementation Of A Garbage First Garbage Collector In The Hotspot Jvm: G1Heapregion, Satb, And Remembered Sets"
description: "A comprehensive technical exploration of the implementation of a garbage first garbage collector in the hotspot jvm: g1heapregion, satb, and remembered sets, covering key concepts, practical implementations, and real-world applications."
date: "2024-01-17"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-implementation-of-a-garbage-first-garbage-collector-in-the-hotspot-jvm-g1heapregion,-satb,-and-remembered-sets.png"
coverAlt: "Technical visualization representing the implementation of a garbage first garbage collector in the hotspot jvm: g1heapregion, satb, and remembered sets"
---

# The Implementation of a Garbage First Garbage Collector in the HotSpot JVM: G1HeapRegion, SATB, and Remembered Sets

---

## 1. Introduction: When the Pause Strikes

Imagine you’re running a high‑throughput online trading platform. Your service handles millions of requests per hour, each requiring sub‑millisecond response times. The application is written in Java, and its heap hovers around 64 GB. For weeks, everything runs smoothly—until one afternoon, without warning, your latency spikes from 5 milliseconds to nearly a full second. Users complain, dashboards turn red, and your on‑call pager screams. You check the logs and see the culprit: a stop‑the‑world garbage collection pause that took 900 milliseconds. The collector dragged your entire application to a halt while it tried to reclaim memory. You drill deeper. Was it the old‑generation mark‑sweep? A full GC? Why did a supposedly “low‑pause” collector cause such devastation?

This scenario is all too familiar for anyone who has tuned Java applications at scale. For years, the default garbage collector in HotSpot was the Parallel Scavenger (for young generation) combined with the Parallel Old collector—both efficient in throughput but notorious for long, unpredictable pause times. Later, the Concurrent Mark‑Sweep (CMS) collector offered lower latency by doing most work concurrently with the application threads, but it suffered from fragmentation, promotion failures, and a risk of “concurrent mode failure” that triggered a full, serial‑like GC. Enter G1 (Garbage First)—a collector designed from the ground up to provide **both** high throughput and predictable low pause times in large heaps. Since Java 9, G1 has been the default garbage collector in HotSpot, and it continues to evolve in every JDK release.

Understanding why G1 can (usually) deliver on its promises—and why it sometimes fails spectacularly—requires digging into its internals. G1 is not a monolithic, black‑box process; it is a carefully orchestrated dance of data structures, concurrent phases, and heuristic predictions. In this deep dive, we will explore three foundational components that make G1 tick: **G1HeapRegion**, **Snapshot‑At‑The‑Beginning (SATB)**, and **Remembered Sets**. By understanding these building blocks, you’ll be better equipped to diagnose pause spikes, tune G1 for your workload, and appreciate the engineering behind one of the most sophisticated garbage collectors in production use.

---

## 2. G1 Design Philosophy: Region‑Based, Predictable, Concurrent

Before we dive into implementation details, it’s important to grasp the overarching design goals that shaped G1. The HotSpot team at Sun (later Oracle) outlined the following requirements for G1 in the late 2000s:

- **Low and predictable pause times**: The collector should allow the user to set a soft pause time target (e.g., 200 ms) and then try to respect it by doing as little work as possible during stop‑the‑world phases.
- **High throughput**: Despite concurrency, allocation and object access should not be excessively penalized.
- **No fragmentation**: The old generation should not suffer from the “space‑fragmentation” problem that plagued CMS and led to promotion failures.
- **Scalability to very large heaps** (tens or hundreds of gigabytes).

To meet these conflicting goals, G1 adopts a **region‑based** memory layout. Instead of a contiguous young generation and old generation, the heap is divided into many small, fixed‑size regions (typically 1–32 MB each). A region can be an Eden region, a Survivor region, an Old region, or a Humongous region (for objects larger than half a region). This compartmentalization allows G1 to:

- **Collect only a subset of the heap** during a pause, choosing a set of regions that can be evacuated within the pause time goal. This is the “Garbage First” principle: always collect the regions that contain the most garbage (i.e., the least live data) first.
- **Perform concurrent marking** to determine which regions are most garbage‑ridden, while the application continues running.
- **Use Remembered Sets to avoid scanning the entire old generation** for cross‑region references, enabling fast per‑region collection.

The result is a collector that can typically keep pause times under 200 ms even on a 100 GB heap, provided that the live‑data set is not too large and the application does not allocate faster than G1 can evacuate.

---

## 3. G1HeapRegion: The Atomic Unit of Memory

### 3.1. Region Size and Layout

The heap in G1 is partitioned into a set of **regions**, each of which is a contiguous block of memory of the same size. The default region size is determined automatically based on the heap size:

- For heaps < 4 GB: region size = 1 MB
- For heaps 4–8 GB: region size = 2 MB
- For heaps 8–16 GB: region size = 4 MB
- For heaps 16–32 GB: region size = 8 MB
- For heaps 32–64 GB: region size = 16 MB
- For heaps ≥ 64 GB: region size = 32 MB

You can also explicitly set the region size with the JVM flag `-XX:G1HeapRegionSize=<size>`. It must be a power of two between 1 MB and 32 MB.

Each region is internally a large array of bytes (represented as a `HeapRegion` object in HotSpot). The region maintains metadata such as:

- **Region type**: Eden, Survivor, Old, or Humongous.
- **Live bytes**: The amount of live data discovered during marking (used for Garbage‑First prioritization).
- **Remembered Set (RSet)**: A data structure that tracks incoming references from outside the region.
- **Card table entries**: A fine‑grained bitmap used for dirtying cards (more on this later).
- **TLAB (Thread Local Allocation Buffer) tracking**: Regions are the units used for allocation buffers.

### 3.2. Region Types and Their Roles

G1HeapRegions come in several flavors, each participating in the garbage collection cycle differently.

**Eden Regions**  
New objects are allocated into Eden regions. Multiple threads can allocate concurrently using TLABs. When an Eden region becomes full (or when the total Eden occupancy reaches a threshold), G1 triggers a young generation collection. All Eden regions are evacuated during a young GC.

**Survivor Regions**  
After a young collection, live objects from Eden are copied (evacuated) into Survivor regions. Objects that have survived several young GCs may be promoted to old regions. Survivor regions are counted as part of the young generation.

**Old Regions**  
These contain long‑lived objects that have survived promotion. Old regions are collected only during mixed collections, which also include some young regions. The decision of which old regions to collect is based on the live‑data ratio computed during concurrent marking.

**Humongous Regions**  
Objects larger than half the region size are allocated directly as “humongous objects.” They occupy a contiguous sequence of regions (called the “humongous object header” plus data regions). Humongous objects are always allocated in the old generation and are collected during full GCs or during concurrent marking if found to be unreachable. They can cause fragmentation because they cannot be moved easily; G1 may attempt to reclaim humongous regions as part of the concurrent marking cycle.

**Archive Regions**  
These are used for class data sharing (CDS) and are never moved.

### 3.3. Region Management: Allocation and Evacuation

Allocation within a region is straightforward: each region maintains a “top” pointer (`_top`) and a “end” pointer (`_end`). When a thread requests memory (via a TLAB), it bumps the pointer. For humongous objects, G1 searches for a contiguous block of free regions.

During a garbage collection pause, G1 selects a set of regions to evacuate (the “collection set”). The live objects in those regions are copied to other regions (typically a new set of Eden regions for young objects or Survivor/Old for promoted objects). The source regions are then returned to the free list. This evacuation is a stop‑the‑world operation, but G1 tries to limit the number of regions evacuated to meet the pause time goal.

**Example**: Suppose we have a 16 GB heap with 4 MB regions. The heap contains 4096 regions. After a young GC, G1 might evacuate all 400 Eden regions (1.6 GB) into 200 Survivor regions. If the pause time goal is 200 ms and the evacuation time per region is 0.5 ms, then G1 would at most evacuate 400 regions to stay within budget. In practice, G1 uses a prediction model based on historical evacuation rates.

---

## 4. Snapshot‑At‑The‑Beginning (SATB): Concurrent Marking Without Stale References

### 4.1. The Problem of Concurrent Marking

Concurrent garbage collectors, like G1, need to determine which objects are live without stopping the world for too long. The classical approach is to use a **tricolor marking** algorithm:

- **White**: Object is not yet visited (assumed dead unless eventually reachable).
- **Gray**: Object is visited but its direct references have not yet been scanned.
- **Black**: Object and all its references have been scanned.

In a concurrent setting, the application (mutator) can modify object references while the marker is running. This can lead to two types of problems:

1. **Floating garbage**: The mutator removes the last reference to a white object after the marker has already passed through it. The object is considered reachable incorrectly (a false positive), i.e., it will be reclaimed later. This is acceptable.
2. **Missed live object**: The mutator installs a reference from a black object to a white object that was not yet marked, while the black object is not re‑scanned. This white object could be missed and incorrectly collected. This is catastrophic.

To avoid missing live objects, concurrent collectors must ensure that any new reference added to an already‑black object is discovered. Two strategies exist:

- **Incremental update**: When a black object’s field is written, the field is tracked and the black object is re‑scanned (or the target is marked gray). CMS used this approach.
- **Snapshot‑At‑The‑Beginning (SATB)**: At the start of marking, a logical snapshot of the object graph is taken. All objects reachable at that snapshot are considered live, even if the mutator later deletes references to them. Newly allocated objects after the start of marking are considered live as well. The mutator’s changes between the start and end of marking are recorded, but only to ensure that the snapshot is correct—the marker does not try to follow new references, only preserve the ones that existed at the start.

G1 uses SATB. The advantage is that the marking work is mostly independent of mutator modifications, reducing the need for re‑scanning. The downside is that it retains more floating garbage until the end of marking.

### 4.2. SATB Barrier and Queue

How does G1 implement SATB? It uses a **write barrier** that intercepts all assignments to object references (except in certain cases like synchronized code). The barrier is executed by the JIT‑compiled code on every store.

The SATB barrier is:

```assembly
// Pseudo‑assembly for a typical SATB barrier
// On store to a field, if the G1 concurrent marking is in progress,
// and if the object being stored (the value) was not yet marked,
// then enqueue the previous reference (the old value) into the SATB queue.
```

In actual HotSpot code, the barrier is a sequence of instructions that check a thread‑local flag (`G1SATBBarrierActive`) and, if true, pushes the previous reference (the _old_ value of the field) onto a thread‑local **SATB mark queue**. This old value is the reference that existed at the beginning of the marking cycle for that field. The marker will later process these enqueued references, ensuring that any object that was reachable at the start of marking is marked (even if the mutator later overwrites it).

Example: Suppose we have `a.obj = b;` and the old object pointed to by `a.obj` is `c`. The SATB barrier enqueues `c` (not `b`). This is because the snapshot includes `c` as reachable at the start. The mutator may later make `c` unreachable, but SATB will still consider it live for this cycle. That’s okay—it becomes floating garbage.

### 4.3. Concurrent Marking Phases

Concurrent marking in G1 consists of several phases:

1. **Initial Mark (STW)**: This is piggybacked on a young GC pause. It marks the “root set” (thread stacks, global references) and sets the SATB snapshot start.
2. **Concurrent Root Scanning**: Scans the roots (e.g., stack frames) while the application runs. This is done by worker threads and is concurrent.
3. **Concurrent Marking**: Scans the SATB queues, processes the mark stack, and traverses the object graph. It uses a work‑stealing algorithm.
4. **Remark (STW)**: A final pause to complete marking, drain SATB queues, and process any remaining work. This is where the final liveness of objects is determined.
5. **Cleanup (STW)**: Computes per‑region live data and reclaims completely empty regions. Also sets up the next mixed collections.

During concurrent marking, G1 uses a **bitmap** to record marked objects. Each region has a separate bitmap (the “mark bitmap”). The marker sets bits corresponding to the live objects it encounters. The SATB queue ensures that objects that were reachable at the start but whose references were later changed are still marked.

### 4.4. Example: SATB in Action

Consider a simple object graph at the start of marking:

```
Root → A → B → C
```

All three are white at the start. The marker begins traversing from root: marks A as gray, scans its references, marks B, etc. Now suppose the mutator runs:

```java
A.obj = C;
```

At the start, `A.obj` pointed to `B`. The SATB barrier enqueues `B`. The marker, when it processes the SATB queue, finds `B` and marks it (if not already). Even though `B` is now unreachable (because `A.obj` now points to `C`), it is marked live for this cycle. `C` was already marked reachable from `B`? No, originally `B` pointed to `C`, so `C` would be visited via `B`. With the change, `A` directly points to `C`, but the marker may not have reached `C` yet. However, because `A` is already black? Actually, `A` was marked black after scanning its old references. The SATB queue now contains `B`. The marker will process `B` and follow its references, which include `C`. So `C` will still be marked. This ensures that every object that was reachable at the start is eventually marked, regardless of mutator activity.

The cost is that `B` remains live for this cycle, even though it is floating garbage. It will be reclaimed during a later GC (after the next concurrent marking cycle). This is acceptable because `B` is small and the pause time is bounded.

---

## 5. Remembered Sets: Tracking Cross‑Region References

### 5.1. Why Remembered Sets are Necessary

G1 collects only a subset of the heap at a time (the collection set). To evacuate a region, G1 must know all references **into** that region from outside the collection set (i.e., from other old regions or from the young generation). Without this information, the collector would have to scan the entire heap to find these incoming references—a prohibitively expensive operation that would destroy pause time guarantees.

**Remembered Sets (RSets)** are per‑region data structures that track all “incoming” references from other regions. They are the key to G1’s ability to collect individual regions quickly. The RSet for region R contains entries for every card (a fixed‑sized block of memory, typically 512 bytes) that contains a reference to an object inside R.

### 5.2. RSet Representation: Sparse, Fine, Coarse

To balance memory overhead and lookup speed, G1 uses a three‑tiered representation for RSets:

- **Sparse**: For regions that have few incoming references, the RSet is stored as an array of card indices (4 bytes each). This is compact but slow for very large sets.
- **Fine**: For regions with a moderate number of incoming references, the RSet stores a **bitmap** of cards (one bit per card). This is faster but uses more memory (each region’s fine RSet is a fixed bitmap of 512 bytes? Actually, the fine RSet is a chunked bitmap.) The fine RSet covers all cards in the heap but only those that are actually dirty are set.
- **Coarse**: For regions with many incoming references (e.g., a region that is frequently referenced from many other regions), the RSet may use a **coarse bitmap** where one bit represents an entire region (i.e., “any card in region X is considered an incoming reference”). This reduces memory at the cost of false positives (more scanning needed).

HotSpot dynamically converts between these representations: when a fine RSet grows too large, it collapses to coarse; when a coarse RSet is found to have few actual references, it may be broken back into fine.

### 5.3. RSet Maintenance via Write Barrier

The RSets must be kept up‑to‑date as the application mutates references. Just like SATB, G1 uses a **write barrier** to intercept reference stores. This barrier is different from the SATB barrier—it is the **RSet tracking barrier** (also known as the “post‑write barrier”).

The barrier works as follows: whenever an object field is written, the barrier determines whether the reference is pointing to a different region than the holder object. If so, it must ensure that the target region’s RSet records the source card (the location of the reference). The barrier does not immediately update the RSet; instead, it **dirties a card** in the **card table**.

The card table is a byte array (or a bit array) that maps each 512‑byte block of the heap to a “dirty” flag. When a reference store occurs, the barrier marks the card containing the source reference as dirty. Later, during the G1 pause (or concurrently), the dirty cards are scanned to update the RSets.

This deferred update is known as “point‑of‑use” updating. It reduces the cost of the write barrier to a single byte store (plus some checks), making it very cheap. The trade‑off is that when G1 needs to use an RSet (e.g., during evacuation), it must first process all dirty cards—a phase called **“Update RSets”** or “Dirty Card Queue Processing” which is done at the start of each young GC pause.

### 5.4. RSet Scanning During Evacuation

When G1 selects a collection set, it must evacuate the live objects from those regions. To find all references into the collection set regions, G1 does the following:

1. **Pre‑Evacuation Phase (STW)**: Process all dirty cards (from the card table) to update the RSets of the collection set regions. This ensures RSets are accurate.
2. **RSet Scanning**: For each region in the collection set, iterate over its RSet to find all cards that contain references into that region. For each such card, scan the objects in that card (or the entire region if using coarse representation) to locate the exact pointers.
3. **Relocating**: For each pointer found, update it to point to the new location of the object after evacuation.

Because RSets exclude references from within the same region (self‑references don’t matter) and from other collection set regions (those objects are also moving), the scanning focuses only on external references, which are typically a small fraction of the heap.

### 5.5. Example: RSet in a Trade Processing App

Consider a trading platform where an `OrderBook` object in an old‑generation region holds a reference to a large `OrderList` object. The `OrderList` is frequently updated, but the `OrderBook` reference remains stable. Both objects are in different old regions. Every time a trader modifies an order, a new `Order` object is created in Eden. That new `Order` object might be referenced from the `OrderList` (which is in an old region). This creates a cross‑region reference from the old region containing `OrderList` to the Eden region containing `Order`. The write barrier dirties the card containing the `OrderList`’s field.

During a young GC, the collection set includes all Eden regions. G1 updates the RSets for those Eden regions by scanning dirty cards that belong to old regions. It finds the card where `OrderList`’s reference is stored, reads the pointer, and notes that the Eden `Order` is referenced from an old region. Thus, during evacuation, the `Order` is considered live and is copied to a survivor region. This is how G1 correctly handles young‑generation objects that are referenced from the old generation—without scanning the entire old generation.

---

## 6. How G1 Collects: Young, Mixed, and Full GCs

### 6.1. Young GC (Evacuation Pause)

The most common pause is a young generation collection. During this STW pause:

- G1 selects all Eden and Survivor regions as the collection set.
- The RSets for these regions are updated by processing the dirty card queue.
- For each region in the collection set, live objects are copied (evacuated) to new regions (Eden→Survivor, Survivor→Old).
- After evacuation, the old regions are freed.

Young GCs are designed to be fast because the collection set is limited to young regions, which are typically small and contain a high fraction of garbage.

### 6.2. Mixed GC

After concurrent marking completes, G1 knows which old regions have the most garbage. It then schedules a series of **mixed collections** (typically 8–32) that include both young regions and some old regions (chosen from the “garbage‑first” list). The goal is to reclaim old‑generation memory gradually, spreading the pause time across multiple collections.

Mixed collections work exactly like young GCs but with added old regions. The RSet scanning for old regions is more expensive because old regions may have many incoming references. G1 uses its prediction model to decide how many old regions to include so that the total pause time stays within the target.

### 6.3. Full GC

If G1 cannot reclaim memory fast enough (e.g., because the live‑data set is too large, or humongous objects fragment the heap, or the concurrent marking cycle fails), it will fall back to a **full GC**. This is a stop‑the‑world, serial‑like compaction of the entire heap. In the past, G1’s full GC was very slow (single‑threaded). Starting with JDK 10, G1 has a **parallel full GC** that uses multiple threads to compact the heap, significantly reducing pause times. However, a full GC is still an order of magnitude longer than a normal G1 pause.

---

## 7. Practical Examples and Diagnostics

### 7.1. Using JVM Flags to Observe Region Layout

To see how G1 divides the heap into regions, you can enable logging:

```
-XX:+PrintGCDetails -Xlog:gc+heap+region=trace
```

This will output a region summary like:

```
Heap before GC:
 regions: 512 (1 MB)
   young: 200 regions (200 MB)
   survivors: 25 regions (25 MB)
   old: 200 regions (200 MB)
   humongous: 2 regions (2 MB)
   free: 85 regions (85 MB)
```

You can also use `jcmd` to dump the heap region information:

```
jcmd <pid> GC.heap_info
```

Output:

```
G1 Heap:
   regions  = 8192
   capacity = 64 GB (512 MB/region)
   used     = 32 GB (50%)
   free     = 32 GB (50%)
   young gen = 2048 regions (16 GB)
      eden  = 1900 regions (14.8 GB)
      surv  = 148 regions (1.2 GB)
   old gen  = 4000 regions (32 GB)
   humongous= 200 regions (1.6 GB)
```

### 7.2. Analyzing Pause Times with G1GC Logs

Enable G1 GC logging with `-Xlog:gc*` to see detailed pause phases:

```
[2025-03-28T14:23:45.123+0000] GC pause (G1 Evacuation Pause) (young) 1024M->512M(64G) 120.234ms
   [Update RSets: 20.5ms]
   [Scan RSets: 45.3ms]
   [Object Copy: 50.1ms]
   [Termination: 4.3ms]
```

If `Update RSets` is high, it may indicate too many dirty cards due to high mutation rate. If `Scan RSets` is high, there are too many cross‑region references into the collection set, possibly due to many old‑generation objects referencing young ones. You could then tune `-XX:G1MixedGCLiveThresholdPercent` to limit the inclusion of heavily referenced old regions.

### 7.3. Code Example: Simulating Cross‑Region References

To see how RSets work, consider the following Java program:

```java
public class G1Demo {
    static class Node {
        Node next;
        int[] data = new int[1000]; // large object
    }

    public static void main(String[] args) throws InterruptedException {
        Node head = new Node();
        Node tail = head;
        for (int i = 0; i < 100000; i++) {
            Node n = new Node();
            tail.next = n;
            tail = n;
            if (i % 1000 == 0) Thread.sleep(1); // allow GC to run
        }
        // Keep head alive, rest floating garbage
        System.gc(); // force a full GC to see RSet activity
    }
}
```

When you run with G1 logs, you can see how the RSet scanning time increases as the linked list is created. The head object is in an old region, while the many `Node` objects are allocated in Eden and become garbage. The cross‑region reference from `head.next` to the second node will be tracked in the RSet of the young region containing the second node. During a young GC, G1 must scan that reference to keep the second node live (until it is overwritten). This illustrates how G1 protects young objects that are referenced from old.

---

## 8. Advanced Topics and Pitfalls

### 8.1. Humongous Objects and Their Impact

Humongous objects are allocated in a contiguous block of regions. They cannot be moved during young or mixed GCs because the copying cost is too high. G1 attempts to reclaim humongous objects during concurrent marking if they are found to be unreachable. However, if many large objects are short‑lived (e.g., large byte arrays used for network buffers), they can quickly fill up the heap and trigger a full GC.

**Mitigation**: Use `-XX:G1HeapRegionSize` to increase region size so that fewer objects become humongous. Alternatively, avoid allocating objects larger than half a region.

### 8.2. SATB Buffer Overflow

During concurrent marking, threads enqueue old references into SATB mark queues. If a thread produces references faster than the marker can consume them, the queue may overflow. In that case, the JVM triggers a **Concurrent Mode Failure** and falls back to a full GC. This can happen when a highly mutative application (e.g., a cache that constantly replaces entries) causes many enqueues.

**Mitigation**: Tune the size of the SATB queues with `-XX:G1SATBBufferEnqueueThreshold` or increase the number of concurrent marking threads with `-XX:ConcGCThreads`.

### 8.3. To‑Space Exhaustion

If G1 cannot find enough free regions to evacuate live objects during a pause, it may fail with a **to‑space overflow**. This typically occurs when the heap is nearly full, and G1 is forced to stop the world and perform a full GC. To‑space exhaustion is a sign that either the heap is too small for the live data, or the mixed collection cycle is not aggressive enough.

**Mitigation**: Increase heap size, lower the `-XX:InitiatingHeapOccupancyPercent` (default 45%) to start concurrent marking earlier, or reduce the time between mixed collections with `-XX:G1MixedGCCountTarget` (default 8).

### 8.4. Large Card Tables and RSet Memory

Remembered Sets consume memory proportional to the number of cross‑region references. In a typical application, RSet overhead is about 1–5% of the heap. However, if the application has a huge number of fine‑grained cross‑region references (e.g., a graph database with every node pointing to many others), the RSet memory can balloon. G1 provides flags to limit the cost: `-XX:G1RSetRegionEntries` (maximum number of fine entries per region) and `-XX:G1RSetSparseRegionEntries` (maximum sparse entries before upgrading).

---

## 9. Recent Improvements in G1 (JDK 11–21)

G1 has been actively developed since its debut in JDK 7. Key improvements include:

- **Parallel Full GC (JDK 10)**: Multi‑threaded full GC drastically reduces worst‑case pauses.
- **String Deduplication (JDK 8u20)**: G1 can deduplicate identical `String` objects to reduce memory.
- **Parallel Reference Processing (JDK 12)**: Reference processing (for `SoftReference`, `WeakReference`) is now done in parallel, improving pause times.
- **Eager Reclamation of Humongous Objects (JDK 9)**: During concurrent marking, dead humongous objects are reclaimed immediately without requiring a full GC.
- **NUMA Awareness (JDK 14)**: G1 can allocate regions on the same NUMA node as the allocating thread, improving locality.
- **ZGC‑like concurrent reference processing (JDK 16+)**: Ongoing work to make G1 more concurrent.

Despite these improvements, G1 is not a silver bullet. For applications requiring sub‑10ms pause times on multi‑terabyte heaps, ZGC or Shenandoah are better choices. But for the vast majority of Java applications with heaps up to a few hundred GB, G1 offers an excellent balance.

---

## 10. Conclusion

Let’s return to the trading platform scenario that opened this article. The 900‑ms pause you saw could have been caused by any number of G1 internals: a concurrent mode failure due to SATB buffer overflow, a to‑space exhaustion, an overly large RSet scan, or a concurrent marking cycle that was triggered too late. By understanding the three pillars we covered—**G1HeapRegion**, **SATB**, and **Remembered Sets**—you can now read G1 GC logs with a trained eye and identify the root cause.

- **G1HeapRegion** gives us the ability to collect incrementally. A pause that includes many old regions indicates aggressive mixed collections; you may need to tune `-XX:G1MixedGCLiveThresholdPercent` or `-XX:G1HeapWastePercent`.
- **SATB** explains how G1 can mark concurrently without risk of missing live objects, but it can also lead to floating garbage if the mutation rate is high. The `Update RSets` and `Scan RSets` phases are where you measure the cost of cross‑region references.
- **Remembered Sets** are the magic that makes per‑region collection efficient, but they come with memory and update overhead. If your application creates too many cross‑region pointers (e.g., a cache that lives in old generation and points to frequently‑allocated objects), you may need to either reduce that pattern or increase the heap.

G1 is a masterpiece of engineering—a concurrent, region‑based, generational collector that can meet soft real‑time constraints on very large heaps. But it is not a black box. It is a system of levers and heuristics that you, the operator, can tune to your workload. The next time your pager goes off, you’ll know exactly where to look.

---

_Further Reading:_

- [Garbage‑First Garbage Collection (G1) – Oracle Documentation](https://docs.oracle.com/en/java/javase/17/gctuning/g1-garbage-first-garbage-collection.html)
- [The Garbage Collection Handbook, by Richard Jones et al.] – Chapters on concurrent collectors
- [HotSpot G1 Source Code (OpenJDK)](https://github.com/openjdk/jdk) – `src/hotspot/share/gc/g1/`

---
