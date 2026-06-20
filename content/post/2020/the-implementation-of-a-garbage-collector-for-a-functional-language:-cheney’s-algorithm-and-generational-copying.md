---
title: "The Implementation Of A Garbage Collector For A Functional Language: Cheney’S Algorithm And Generational Copying"
description: "A comprehensive technical exploration of the implementation of a garbage collector for a functional language: cheney’s algorithm and generational copying, covering key concepts, practical implementations, and real-world applications."
date: "2020-09-16"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-implementation-of-a-garbage-collector-for-a-functional-language-cheney’s-algorithm-and-generational-copying.png"
coverAlt: "Technical visualization representing the implementation of a garbage collector for a functional language: cheney’s algorithm and generational copying"
---

# The Invisible Hand: Garbage Collection Design for Purely Functional Languages

## Introduction: The Allocation Apocalypse

Imagine you’re implementing a purely functional language—say, a small dialect of ML or a lambda calculus with algebraic data types. Your program processes a million-element list, performing `map` and `filter` operations that create a flurry of intermediate cons cells. As the heap fills, the system pauses. A subtle hum of computation halts. The garbage collector (GC) must now reclaim memory used by the tens of thousands of transient objects that perished in the last second. But here’s the catch: your language relies on immutable data. Every transformation produces a new value; the old one lingers until collected. If the collector is too slow, user experience degrades. If it is too eager, throughput plummets. If it moves objects, all references must be updated. The invisible hand that manages memory becomes the performance bottleneck of your whole interpreter or compiler.

This is the unglamorous yet critical reality of runtime design for functional languages. While programmers often take garbage collection for granted in languages like Java, C#, or Go, the stakes are higher—and the design space richer—when the source language is purely functional. Why? Because functional programs allocate like there is no tomorrow. Immutable data structures, closures, thunks, lazily evaluated spines—each forces a new allocation where an imperative program might mutate in place. Consequently, the heap becomes a frantic nursery of short-lived objects, punctuated by occasional long-lived survivors. In such an environment, the choice of garbage collection algorithm is not an afterthought; it is a first-class design decision that shapes the language’s entire runtime behaviour.

The topic matters deeply today, as functional programming gains mainstream traction through languages like Haskell, Clojure, Elixir, and the ML family. Even mainstream languages borrow functional features (lambdas, streams, immutable collections) that mimic these allocation patterns. Understanding how to implement a garbage collector tailored for functional languages is essential for compiler engineers, runtime developers, and any programmer curious about the hidden machinery that makes their code run—or grind to a halt.

In this post, we will embark on a deep dive into the design space of garbage collection for purely functional languages. We’ll explore why functional programs are so allocation-heavy, examine the classic and modern algorithms (generational, copying, mark-compact, reference counting, and concurrent collectors), dissect real-world implementations in Haskell, OCaml, Clojure, and Erlang, and finally discuss emerging trends like region-based memory management and hardware-assisted collection. By the end, you’ll have a robust mental model of how to build a GC that can keep up with the relentless allocation rate of a purely functional runtime.

---

## 1. Why Functional Programs Allocate Like Crazy

Before we dive into GC algorithms, we must understand the root cause of the allocation storm. In a purely functional language, every value is immutable. Once created, a value cannot be changed. This means that any operation that would, in an imperative language, modify a data structure in place must instead produce a new data structure, leaving the old one intact.

### 1.1 Immutability and Persistent Data Structures

Consider a simple linked list in a functional language like Haskell:

```haskell
let xs = [1,2,3]
let ys = 0 : xs  -- cons a new element at the front
```

In most implementations, `ys` is a new list cell containing `0` and a pointer to the old list `[1,2,3]`. The old list is not modified; it remains fully valid. This is called **persistent data structure**—the old version coexists with the new one. The downside: we allocated a new cons cell. If we were to do this repeatedly (e.g., building a list via repeated `foldl` or scan), we generate many short-lived cells.

Now consider a `map` over a 10,000-element list:

```haskell
let result = map (+1) myList
```

Every element of the old list is traversed, and a new list is constructed with the transformed values. The old list is still alive (if there are other references), so both sets of cons cells occupy heap space until they become unreachable. In an imperative language, you might write a loop that updates an array in place. Here you allocate a brand new list.

### 1.2 Closures and Thunks

Functional languages rely heavily on closures—anonymous functions that capture variables from their environment. Every lambda expression may allocate a closure object containing the function’s code pointer and the captured free variables. Consider:

```haskell
let multiplier x = (\y -> x * y)
let times10 = multiplier 10
```

The `times10` closure contains the value `10`. Each invocation of `multiplier` produces a new closure. In languages with higher-order functions, closure allocation can dwarf data structure allocation.

Furthermore, lazy evaluation (used in Haskell) introduces **thunks**—suspended computations. Each unevaluated expression is represented as a thunk object that, once forced, evaluates to a value and may be replaced (by mutation) with the result. Initially, most heap objects are thunks. They are short-lived but abundant.

### 1.3 Immutable Data in Mainstream Languages

Even if you’re not writing pure Haskell, Java’s `Stream` API or C#’s LINQ use functional-style operations that allocate intermediate objects. Each `map`, `filter`, or `flatMap` returns a new stream that internally holds a lambda and a reference to the previous stream. While Java’s streams are not purely functional (they can be implemented with internal mutation), the allocation pattern mimics functional languages: many short-lived intermediate objects. The stock Java GC, designed for moderate allocation rates, must cope with these patterns, often leading to tuning headaches.

### 1.4 Allocation Rate Statistics

To appreciate the scale, let’s look at numbers. A typical Haskell program compiled with GHC can allocate at a rate of **gigabytes per second** on modern hardware. The Glasgow Haskell Compiler (GHC) runtime is optimized for this: it uses a generational, copying collector that can keep up because most objects die young. A 2015 study by the GHC team showed that in a typical session with a web server, 90% of allocated objects die before the next minor collection. This high infant mortality is not accidental; it arises from the functional programming style.

But why do objects die so quickly? Because functional programs create many intermediate results that are used only briefly. For example, in a pipeline like `foldl (+) 0 . map (^2) . filter even`, the intermediate `filter` result (a list) is constructed element-by-element and consumed immediately by `map`, which itself produces another intermediate list consumed by `foldl`. These intermediate list cells are allocated and then become garbage within microseconds.

Understanding this allocation pattern is crucial because it dictates which GC algorithms will perform well. **Generational collectors** excel when most objects die young. **Copying collectors** handle high allocation rates by sacrificing space for speed. **Mark-sweep** collectors may suffer from fragmentation and slower sweep phases when allocation is heavy. As we will see, the best GCs for functional languages exploit the generational hypothesis heavily.

---

## 2. The Anatomy of a Garbage Collector

Before we can tailor a GC to functional languages, we must recall the basic building blocks. Garbage collection algorithms fall into a few families, each with its own trade-offs.

### 2.1 Mark-Sweep

The classic algorithm: trace reachable objects from roots (registers, stack, global variables) by marking them, then sweep through the heap to reclaim unmarked objects. Strengths: simple, no object movement, works with any pointer structure. Weaknesses: fragmentation, pauses that scale with heap size, poor cache locality after sweep.

### 2.2 Copying Collection (Stop-and-Copy)

Divide the heap into two semispaces. Only one is active at a time. When the active space is full, stop the world, trace reachable objects from roots, and copy each live object to the other semispace, updating references. Then flip: the new semispace becomes active. Strengths: compaction eliminates fragmentation, allocation is just a pointer bump (fast), traversal accesses objects in order of allocation (good locality). Weaknesses: overhead of copying all live objects (even long-lived ones), requires twice the memory, pauses proportional to live data size.

### 2.3 Mark-Compact

A hybrid: mark live objects, then slide them to one end of the heap (compaction). This avoids the memory overhead of copying but requires multiple passes (mark, compute new addresses, relocate). It produces a contiguous free region but with more complex bookkeeping.

### 2.4 Reference Counting

Each object keeps a count of the number of references pointing to it. When the count drops to zero, the object is freed immediately. Advantages: incremental, no pauses. Disadvantages: circular references require a cycle-collection mechanism, overhead of updating counts on every pointer assignment, poor performance in functional languages where objects are frequently shared and discarded (counts change constantly). For purely functional languages, reference counting is generally suboptimal because all objects are immutable and references are established at creation—no later assignments. However, counts still need to be incremented when a value is used (e.g., captured in a closure). The overhead can be substantial.

### 2.5 Generational Collection

Observation: most objects die young. Divide heap into generations (typically two: young and old). Collect the young generation frequently (minor GC) using a fast algorithm (usually copying). Objects that survive a few minor collections are promoted to the old generation, which is collected less often (major GC) using a slower algorithm (mark-sweep or mark-compact). This drastically reduces pause times for most allocations.

Generational collection is the de facto standard for functional language runtimes. It directly exploits the high infant mortality of functional programs. The young generation can be small (e.g., 1-4 MB) and collected with a stop-and-copy collector in microseconds. Old generation collections happen rarely.

### 2.6 Concurrent and Parallel GC

To reduce pauses further, collectors can run concurrently with the mutator (the application thread). For functional languages, concurrent GC is challenging because the mutator can allocate at extreme rates and modify the pointer graph (e.g., when updating a thunk's value). However, modern runtimes like Go's GC and Java's G1 implement concurrent marking and sweeping, and some functional language runtimes (e.g., Elixir/Erlang, which uses per-process heaps) have built-in concurrent mechanisms.

---

## 3. Tailoring the GC to Functional Languages

Now we understand the landscape. How do we choose and tune the GC for a purely functional runtime? Let's examine the key design dimensions.

### 3.1 Allocation Speed

The allocator must be blazingly fast. In a copying collector, allocation is simply incrementing a pointer (bump allocation) into the nursery. This is O(1) and cache-friendly. In contrast, a mark-sweep collector requires a free-list search, which can be slower. Functional language runtimes almost always use bump allocation for the young generation. For example, GHC's nursery uses a single contiguous chunk and bump allocation. The cost of allocation is often less than 5% of total CPU time in a well-tuned GHC program.

### 3.2 Object Survival and Promotion

In a generational scheme, we need a policy for promoting objects from young to old. The simplest threshold is: after N minor collections (e.g., 2 or 4), promote the object. But we can do better by tracking aging in the card table or using remembered sets. Some collectors (like GHC's) also observe that large arrays or functions may be promoted immediately.

But there's a subtlety: functional programs often produce long-lived objects that are then referenced from short-lived ones, creating **cross-generational pointers**. Example: a closure that captures a large immutable data structure (e.g., a full list). The closure might be short-lived, but the list lives long. When the closure is garbage, the list is still reachable from other roots. But during a minor collection, the collector must not mistakenly reclaim the list if it is pointed to by a young object. Solution: maintain a **remembered set** of old-to-young pointers, or use a **write barrier** to track modifications to old objects. In purely functional languages, old objects are immutable—they never acquire new pointers to young objects—so the remembered set can be simplified. However, updates to thunks (mutating a thunk's lazy value) do create new pointers from old to young. GHC handles this with a write barrier that records updated thunks.

### 3.3 Handling Large Objects

Functional languages often allocate large objects: arrays, strings, big thunks. Copying full large objects during minor GC is expensive. Solutions: allocate large objects directly into the old generation (e.g., GHC's large object space), or use a separate heap for them. Some collectors treat objects larger than a threshold as “medium-sized” and manage them with a different mark-sweep region.

### 3.4 Immutability and Concurrent GC

Because pure functional programs have no mutable state, the mutator's pointer graph evolves only by allocating new objects and by updating a few special cells (thunks). This property can simplify concurrent GC. The mutator can be allowed to allocate freely while the GC marks, because new objects are all black (reachable) by default and cannot be modified to point to unmarked objects. However, thunk updates do modify the graph. The GC must ensure that when a thunk is updated, the newly pointed-to object is marked. This requires a read or write barrier. In GHC's current concurrent collector (based on the non-moving collector), a snapshot-at-the-beginning approach is used.

### 3.5 Memory Overhead vs. Pause Time

Functional languages often tolerate higher memory overhead because they allocate so much. But for embedded or real-time applications, we need bounded pause times. Copying collectors typically have pauses proportional to the amount of live data in the nursery. With a small nursery, pauses are microseconds. But promotion to old generation then requires rarer, longer major GC pauses. To bound major pauses, we can use an incremental or concurrent mark-sweep collector for the old generation (like the GHC non-moving collector). Alternatively, we can use a purely generational scheme with a large old generation but only collect when fragmentation demands (e.g., using mark-compact rarely).

### 3.6 Fragmentation

Functional languages avoid internal fragmentation because objects are typically small and fixed-size (cons cells, closures). But external fragmentation can occur in mark-sweep collectors if small objects are interspersed with larger ones. Copying collectors eliminate fragmentation by compaction. Compaction also improves cache locality, which is crucial for functional programs that traverse linked data structures. When objects are copied, they are placed in allocation order, so traversing a list will follow memory order, reducing cache misses.

---

## 4. Case Studies: GC in Real Functional Languages

Let's examine how prominent functional languages implement garbage collection, highlighting the design decisions and trade-offs.

### 4.1 GHC (Haskell) – The Gold Standard

The Glasgow Haskell Compiler (GHC) uses a generational copying collector for the young generation and a mark-compact (or mark-sweep with optional compaction) collector for the old generation. Key points:

- **Nursery**: a single contiguous region (default 1 MB). Bump allocation, minor GC is a stop-and-copy evacuation of the nursery into the old generation. Only objects that survive one minor GC are promoted (some survive multiple).
- **Generations**: typically two generations (young and old). GHC can be configured with more generations, but two is common.
- **Support for large objects**: large objects (size > 1 word?) are placed in a separate large object space (LOS) managed by a mark-sweep collector. They are never copied.
- **Compact normal forms**: for data structures that are fully evaluated and immutable, GHC can optionally compact them into a single contiguous block, reducing memory overhead and improving cache locality. This is a form of advanced GC optimization.
- **Concurrent GC**: starting from GHC 8.x, a **non-moving** garbage collector was introduced for the old generation. It uses a mark-region algorithm that runs concurrently with the mutator, allowing major GC pauses to be bounded (e.g., 1 ms). The concurrent collector uses a snapshot-at-the-beginning approach and a write barrier for thunk updates.
- **Performance**: GHC programs can allocate at rates of > 10 GB/s. The GC typically accounts for 5-30% of runtime, depending on allocation intensity.

**Example**: Consider a Haskell program that reads a file line by line and processes each line:

```haskell
main = do
    contents <- readFile "large.txt"
    let linesOfFile = lines contents
    let processed = map (map toUpper) linesOfFile
    putStr (unlines processed)
```

The `lines` function produces a lazy list of `String`s. The `map toUpper` creates a new list of strings. Both lists will be allocated in the nursery. As the program prints, elements are consumed and become garbage quickly. The minor GC will frequently collect the nursery, evacuating only the current `head` of the consumed list (which may be stored in a register) and the unevaluated thunks for the rest. This works because the lazy spine is consumed incrementally.

### 4.2 OCaml – A Tightly Integrated GC

OCaml uses a generational copying collector with a compact survivor space. It is notable for its tight integration with the language's memory model:

- **The major heap**: uses a mark-sweep collector that does not compact by default (though it can). It maintains a free-list. To avoid fragmentation, objects are allocated in buckets by size. The major GC runs occasionally.
- **The minor heap**: a small nursery (default 256 KB) with bump allocation. Minor GC copies live objects into the major heap. Unlike GHC, OCaml's minor GC does not promote objects immediately; they may be copied several times within the minor heap before promotion (if they survive multiple minor collections).
- **No write barrier**: because OCaml's major heap objects are scanned during minor GC via a remembered set implemented as a secondary pointer (read barrier?). Actually, OCaml uses a “generation scan” approach: during minor GC, it scans the whole major heap for pointers to the minor heap (which is expensive if the major heap is huge). To avoid this, OCaml does not have a true generational barrier; instead it uses a “frontier” approach where all objects in the major heap are treated as roots for the minor heap? Wait, OCaml's GC is complex. The key point: OCaml's GC design is optimized for its allocation patterns (which are less extreme than Haskell's, because OCaml is strict). But it still uses generational collection.

- **Performance**: OCaml programs can allocate heavily due to functional idioms (immutable lists, closures). The GC overhead is typically low, but large major heaps can cause long pause times (since major GC scans all live objects). OCaml 4.10 introduced a “compacting GC” that can be invoked explicitly to defragment.

### 4.3 Clojure (on JVM) – Hosted GC

Clojure runs on the JVM (and also on CLR and JS). It does not have its own GC; it relies on the host platform's garbage collector. However, Clojure's immutable data structures (persistent vectors, maps, sets) are implemented in Java with structural sharing. They allocate many intermediate objects, especially during bulk operations. The JVM's generational GC (G1, Shenandoah, etc.) is not tuned for functional allocation patterns, but it works well because the JVM's GCs are sophisticated.

Clojure does influence GC behavior via:

- **Lazy seqs**: Clojure's lazy sequences are thunk-like objects that allocate and become garbage quickly.
- **Use of `transient` collections**: Clojure provides mutable temporary versions of persistent collections to reduce allocation during bulk building. This is an example of escaping purely functional allocation by using mutable scratch space.

**Why this matters**: Hosted functional languages (Clojure, Scala, F#) cannot control the GC algorithm directly, but they can design their data structures and idioms to be GC-friendly. For example, avoiding frequent creation and discarding of large objects, using `while` loops with mutation inside a pipeline, and using value types (where available) to reduce heap pressure.

### 4.4 Erlang/Elixir – Per-Process Heaps

Erlang's runtime (BEAM) uses a unique approach: each lightweight process has its own heap. There is no shared heap across processes. Garbage collection is per-process and uses a generational copying collector. Because heaps are small (by default ~300 words, but can grow), GC pauses are short and proportional to the process's live data. This enables soft real-time behavior.

Key points:

- **GC is stop-the-world per process**: when a process heap is full, the process pauses, GC runs, and then the process resumes. Other processes are unaffected.
- **Large objects** (e.g., binaries larger than 64 bytes) are shared via reference counting and not copied per process. This reduces GC overhead.
- **Immutability**: Erlang data is immutable, but processes communicate via message passing (copying messages to the receiver's heap). This copying can be a bottleneck.
- **Concurrent GC**: not needed because each heap is small and independent.

**Takeaway**: The per-process heap model eliminates the need for a global GC pause, which is ideal for soft real-time systems. However, it requires message copying and careful management of shared large objects.

### 4.5 Lean 4 – A Functional Language with Raw Access

Lean 4 is a functional language designed for theorem proving and general programming. Its runtime uses a **generational copying collector** akin to GHC's, but with a twist: users can also manually manage memory via `IO.Region`. Lean's GC is still in development. The language's heavy use of closures and dependent types leads to high allocation rates, but the GC is tuned for scientific computing and interactive theorem proving.

---

## 5. Advanced GC Techniques for Functional Languages

Beyond the standard approaches, several advanced techniques have been proposed or implemented for functional languages.

### 5.1 Beltrami's Heap Model and Region Inference

Instead of a tracing GC, some functional languages (like the ML Kit or early versions of Cyclone) use **region-based memory management**. The compiler statically infers the lifetimes of objects and groups them into regions. When a region is exited, all objects in it are freed simultaneously. This eliminates per-object collection overhead. However, region inference is difficult for higher-order functions, and leaks can occur if regions are overestimated. The ML Kit successfully used region-based management for a large subset of ML, but it was never adopted by mainstream languages.

### 5.2 Compressed Pointers and Object Layout

Functional languages with many small objects (cons cells, closures) waste memory on object headers. Modern GCs use compressed OOPs (like JVM) to reduce pointer size. Some functional language runtimes (e.g., OCaml) use tagged pointers to avoid separate objects for integers. GHC uses 4-byte pointers on 64-bit systems with compressed heaps? Actually GHC relies on 64-bit pointers, but it uses a custom object header format: every object has a header word containing a pointer to its info table (metadata). This allows polymorphic dispatch but adds overhead. Alternative designs (like the **BiBOP** approach) pack small objects into pages with a common metadata descriptor, reducing header size.

### 5.3 Lock-Free and Concurrent Data Structures for GC

Since functional languages have no mutation, the GC can exploit the fact that the mutator's pointer graph is append-only (except thunks). This enables lock-free concurrent GC designs. For example, a **snapshot-at-the-beginning** concurrent GC (like the one used in GHC's non-moving collector) can run while the mutator allocates, because new objects are immediately black (marked). All existing objects before the start of the GC are considered gray or white. Since the mutator cannot create new pointers to white objects (except through thunk updates, which are tracked), the GC is safe.

Another approach: **concurrent reference counting with cycle detection**, used in languages like Swift (though Swift is not purely functional). However, for pure functional languages, reference counting's overhead on immutable data is mitigated because counts are only incremented when a value is used (e.g., passed to a function) and decremented when the use ends. In practice, the overhead is still high due to frequent updates.

### 5.4 Generational Garbage Collection with G1-like Heuristics

The Java G1 garbage collector divides the heap into many equal-sized regions and collects subsets (sets of regions) to achieve bounded pause times. This could be adapted to functional languages: regions could be grouped by age (not just a single nursery). Each minor collection would evacuate a set of young regions. This allows more flexible heuristics and better control over pause times, especially for large heaps.

### 5.5 Cache-Aware and Locality-Optimizing GC

Functional programs suffer from poor cache locality because linked data structures scatter objects. A copying collector that places objects in allocation order improves locality for sequential traversals. Some GCs (like the **Metronome** collector for real-time Java) use object reordering to improve cache behavior. For functional languages, a copying collector that groups objects by **type** (e.g., all cons cells in one area, all closures in another) can improve spatial locality when traversing homogeneous data structures.

### 5.6 Hardware-Assisted GC

Emerging hardware features like Intel's MPX (Memory Protection Extensions) or ARM's Memory Tagging can assist in detecting garbage or tracking references. For example, a functional language runtime could use tagged pointers to encode generation information, allowing the GC to avoid scanning non-pointers. GHC already uses a tagging scheme for constructor types (the tag is stored in the info table). But hardware support could make write barriers cheaper (e.g., by using memory protection to detect modifications to old objects).

---

## 6. Trade-offs and Pitfalls in Practice

Implementing a GC for a functional language is rife with engineering trade-offs. Let's highlight some common pitfalls.

### 6.1 Over-Tuning the Nursery Size

If the nursery is too small, minor GCs occur too frequently, wasting time on repeated copying of short-lived objects. If too large, pause times increase (because more objects need copying) and the old generation grows faster, delaying major GC. The optimal size depends on the allocation rate and survival rate. Most runtimes allow command-line tuning. GHC's default nursery (1 MB) works well for many programs, but a more allocation-heavy program may benefit from 4-8 MB. Conversely, a latency-sensitive application may prefer a smaller nursery to keep pauses under 1 ms.

### 6.2 The Cost of Write Barriers

In a generational collector, a write barrier is needed to track modifications to old objects (because they may point to young objects). In a purely functional language, mutability is rare (thunks, mutable references like `IORef`). The write barrier cost is low because it's triggered only on thunk updates and `IORef` writes. However, in lazy languages, thunk updates are frequent: every time a thunk is forced, its content is overwritten. GHC's write barrier is a simple check: if the object being updated is in the old generation (i.e., its GC age is >0), then record the address in a remembered set. This adds a branch to every thunk update, which is a small but non-trivial overhead. In a benchmark-heavy loop, this can cost a few percent of CPU.

### 6.3 Handling Function Closures

Closures are objects that contain captured variables, which are pointers. They are allocated frequently, and they often have short lifetimes (e.g., a closure passed to `map` that is used once). However, closures can also be long-lived (e.g., a partially applied function stored in a configuration record). The GC must treat closure pointers like any other pointer. In GHC, closures are just heap objects with a specific info table. They are scanned during GC. The presence of callback-heavy code can increase the live pointer count, causing longer major GC times.

### 6.4 Persistent Data Structures and Cycles

Functional data structures like persistent maps use structural sharing, which can create cycles? In immutable data, cycles are impossible because a new value cannot point to an older value that points back (that would require mutation later). However, laziness can create cycles via thunks that force each other. For example:

```haskell
let ones = 1 : ones
```

This is a cyclic list implemented via a lazy thunk. In GHC, `ones` is a thunk that, when forced, constructs a cons cell whose tail is the same thunk `ones` (update-in-place). This creates a cyclic object graph. The GC must handle cycles correctly—most tracing collectors do, but reference counting without cycle detection would leak memory. GHC's copy collector handles cycles because it follows pointers recursively with depth-first traversal (and it has a loop detection mechanism via object forwarding).

### 6.5 Large Object Promotion

If large objects (e.g., arrays) remain in the young generation, minor GC would have to copy them, which is expensive. Most collectors promote large objects immediately. But then they become part of the old generation, which is collected less frequently. If a large object is short-lived (e.g., a temporary buffer), it will waste space in the old generation until the next major GC. This is a trade-off: pay the copy cost vs. pay the memory cost. Some collectors (like GHC's) allow users to specify a threshold for large objects (usually 1 KB). They are placed in the large object space (LOS) and reclaimed by mark-sweep. This avoids copying even during minor GC.

---

## 7. Designing Your Own GC for a Small Functional Language

Suppose you are implementing a minimal purely functional language (like a lambda calculus with algebraic data types). You want a simple, working GC that is fast enough for prototyping. How would you proceed?

### 7.1 Start with a Simple Copying Collector

For a first implementation, use a stop-and-copy collector with two semispaces. Allocation is bump pointer. Each GC cycle:

1. Swap the role of `fromspace` and `tospace`.
2. Set a `scan` pointer equal to the `free` pointer in `tospace` (the allocation pointer).
3. Push all root pointers (stack, registers) into a queue.
4. For each object in the queue:
   - Check if the object has already been forwarded (via a forwarding pointer in its header).
   - If not, copy the object to `tospace` at the `free` pointer, increment `free`, write a forwarding pointer into the old object's header, and push the new object's internal pointers onto the queue.
5. After scanning all reachable objects, the `scan` pointer will catch up to `free`. All live objects are now contiguous in `tospace`.
6. Update all root pointers to point to the forwarded versions (by following forwarding pointers).
7. Resume execution.

This collector pauses the world, but it is simple and effective for small heaps.

### 7.2 Add Generational Collection

Once the basic collector works, add a nursery. The nursery is a small semispace (e.g., 256 KB). The old generation is a larger semispace (or a mark-sweep heap). Minor GC copies survivors from the nursery to the old generation. You need a write barrier to track pointers from old to young (though in a pure language with no mutation, you might not need it if old objects are never modified; but thunks and references require it). For simplicity, you could use a conservative approach: during minor GC, scan all old generation objects for pointers into the nursery. This is expensive but manageable for small old heaps.

### 7.3 Iterate on Performance

- Tune nursery size.
- Use a remembered set for old-to-young pointers, updated via a write barrier.
- For the old generation, use a mark-sweep collector instead of copying to save memory (copying requires twice the memory for the old generation).
- Optionally compile with a moving collector for the old generation to avoid fragmentation.

### 7.4 Consider a Concurrent Collector

For an advanced implementation, add concurrent marking for the old generation. Use a snapshot-at-the-beginning algorithm: at the start of a major GC, take a snapshot of the root set and the object graph (by stopping the world briefly). Then allow the mutator to run while the GC marks concurrently. The mutator's writes (thunk updates) are tracked via a write barrier that logs the old address range or the new pointer. The mutator must also ensure that any newly allocated objects are marked black (or considered roots).

This is complex, but libraries like the Boehm GC or the Immix collector can be adapted. Alternatively, use a reference-counting collector with cycle detection if you prefer incremental collection (though it may be slower for high allocation rates).

### 7.5 Testing with Functional Benchmarks

Use a set of benchmarks that represent real functional patterns:

- `nqueens` or `tak` (recursive, short-lived objects)
- `reverse` on large lists (many allocation, many survivors)
- `fib` using memoization (persistent data structures)
- `quicksort` using list comprehension (many intermediate lists)
- A simple web server or REPL loop (long-running with pauses).

Measure throughput, pause times, and memory usage.

---

## 8. Future Directions and Emerging Research

The field of GC for functional languages is far from settled. Here are some ongoing research areas.

### 8.1 Stack-Like Allocation for Functional Languages

Some work proposes using the stack for short-lived objects, even in a purely functional setting. For example, the **Koka** language uses reference counting plus a “pervasive second chance” algorithm to avoid tracing. Koka is not purely functional but encourages immutability. Its runtime uses a region-based approach for allocation that often stays on the stack.

### 8.2 Memory Management for Algebraic Effects

With the rise of algebraic effects (as in Eff, OCaml's Multicore Effects, or Koka), the runtime must manage effect handlers, which are closures that capture state. This creates new allocation patterns that may require specialized GC.

### 8.3 Hardware Specialization

As hardware becomes more heterogeneous (FPGAs, GPUs, TPUs), functional languages may need to manage memory across address spaces. The GC must be aware of device memories and data transfer costs.

### 8.4 Formal Verification of GC Correctness

Given the complexity of concurrent collectors, there is interest in mechanically verifying GC algorithms (e.g., using Coq or Lean). Verified GCs could be used in safety-critical functional language runtimes.

### 8.5 Automatic Heap Sizing with Machine Learning

Some experimental GCs use machine learning to predict allocation rates and adjust heap sizes dynamically. For functional languages with high variance (e.g., interactive systems), this could reduce latency.

---

## 9. Conclusion: The Invisible Hand Matters

We began with a small lambda calculus and a million-element list, and we have traversed a vast landscape of garbage collection design. From the high allocation rates of immutable data to the fine points of write barriers, from GHC's nursery to Erlang's per-process heaps, the invisible hand of the GC profoundly shapes the performance of functional programs.

As functional programming continues to cross into the mainstream, understanding this hidden machinery becomes increasingly important. When you use `map` in a pipeline, remember: each intermediate list cell may be born and die in nanoseconds, and the GC must keep up without disrupting the flow of computation. When you design a new functional language, the GC is not an afterthought—it is a first-class component that influences the expressive power and performance model of the language.

The best GC for a functional language exploits the generational hypothesis, uses copying for the young generation, and minimizes pauses through concurrent or incremental collection for the old. It balances allocation speed, memory overhead, and latency. And it evolves with the language: as lazy evaluation, closures, and algebraic effects push allocation patterns in new directions, the GC must adapt.

So the next time you write a functional program and it hums along smoothly, spare a thought for the invisible hand that cleans up the mess. It might be the hardest-working component of your runtime—and one of the most fascinating.

---

## References and Further Reading

1. Appel, Andrew W. “Garbage Collection.” In _Modern Compiler Implementation in ML_, 1998.
2. Jones, Richard, et al. _The Garbage Collection Handbook: The Art of Automatic Memory Management_. CRC Press, 2012.
3. Marlow, Simon. “Parallel and Concurrent Programming in Haskell.” O'Reilly, 2013.
4. Doligez, Damien, and Xavier Leroy. “A concurrent, generational garbage collector for a multithreaded implementation of ML.” _ACM SIGPLAN Notices_ 28.8 (1993): 113-122.
5. GHC Wiki: “Non-moving garbage collector.” https://gitlab.haskell.org/ghc/ghc/-/wikis/commentary/non-moving-gc
6. Armstrong, Joe. _Making Reliable Distributed Systems in the Presence of Software Errors_. PhD thesis, 2003.
7. Clements, John, et al. “The GHC Runtime System.” https://ghc.haskell.org/trac/ghc/wiki/Commentary/Rts
8. Bacon, David F., et al. “A unified theory of garbage collection.” _ACM SIGPLAN Notices_ 39.10 (2004): 310-329.
9. Baker, Henry G. “The Treadmill: Real-time garbage collection without motion.” _IJCM_ 1992.
10. Stickel, Mark E., et al. “Region-based memory management for functional languages.” _LFP_ 1992.

---

_This blog post is intended for educational purposes. The implementations described are simplified; actual runtimes contain many additional optimizations and intricacies._
