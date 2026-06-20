---
title: "Memory Consistency Models: From Sequential Consistency to the C++11 Memory Model"
description: "A rigorous treatment of memory consistency models: Lamport's sequential consistency, the transition to relaxed models, the formal semantics of the C++11 memory model with its acquire-release and relaxed atomics, and how to reason about concurrent code that doesn't tear."
date: "2025-06-24"
author: "Leonardo Benicio"
tags: ["memory-model", "concurrency", "sequential-consistency", "cpp", "weak-ordering", "formal-methods"]
categories: ["theory", "systems"]
draft: false
cover: "/static/images/blog/memory-consistency-models-sequential-consistency-cpp11-formal.png"
coverAlt: "Diagram showing program order, memory order, and happens-before relations across multiple threads with store buffers and cache coherence"
---

Here is a fragment of C++ code. Tell me what it prints:

```cpp
#include <atomic>
#include <thread>
#include <iostream>

std::atomic<int> x{0};
std::atomic<int> y{0};
int r1, r2;

void thread1() {
    x.store(1, std::memory_order_relaxed);
    r1 = y.load(std::memory_order_relaxed);
}

void thread2() {
    y.store(1, std::memory_order_relaxed);
    r2 = x.load(std::memory_order_relaxed);
}

int main() {
    std::thread t1(thread1), t2(thread2);
    t1.join(); t2.join();
    std::cout << r1 << " " << r2 << std::endl;
}
```

If you answered "0 0 is impossible," you have been betrayed by your intuition about how computer memory works. With relaxed atomics, the outcome `r1 = 0, r2 = 0` is not only possible but routinely observable on ARM and POWER processors. Both threads can see each other's stores as happening in the opposite order — or not at all. The hardware is not broken. The compiler is not buggy. The problem is that we have not specified which _memory consistency model_ should govern the interactions between these threads.

This article is about memory consistency models: the contracts that define what values a read may return in a concurrent program. We will travel from Lamport's pristine sequential consistency through the pragmatic relaxations of x86-TSO and ARM, arriving at the formal semantics of the C++11 memory model — the most carefully specified concurrency model in any mainstream programming language. Along the way, we will learn to reason about acquire-release ordering, why `volatile` has nothing to do with threads, how to verify concurrent code with model checkers, and why the Out-Of-Thin-Air problem makes formal semantics of weakly consistent memory one of the hardest problems in programming language theory.

## 1. Coherence vs. Consistency: First Distinctions

Before discussing consistency, we must dispel a common confusion between two related but distinct concepts.

### 1.1 Cache Coherence

**Cache coherence** is a per-address property. It ensures that all processors see a consistent order of writes to a _single_ memory location. Specifically, a coherent memory system guarantees:

1. **Write serialization:** All writes to address \(A\) appear to occur in some total order that is observed identically by all processors.
2. **Write propagation:** A write to \(A\) by processor \(P\) eventually becomes visible to all other processors.
3. **Read-after-write:** A read of \(A\) by \(P\) returns the value of the most recent write to \(A\) by \(P\) (in program order) that hasn't been overwritten.

Most modern CPUs implement cache coherence via protocols like MESI, MOESI, or MESIF. Coherence is about a _single_ address. It does not constrain the order of accesses to _different_ addresses.

### 1.2 Memory Consistency

**Memory consistency** is a multi-address property. It defines what values a read may return given the writes performed by all processors, specifying the allowed _interleavings_ (or lack thereof) of memory operations across addresses.

Formally, a memory consistency model is a set of rules that, for a given program and a given execution, determine which values may legally be observed by each read. The model sits between the programmer (who writes code assuming certain ordering guarantees) and the hardware (which reorders memory operations aggressively for performance).

The distinction matters because programmers typically reason about programs assuming consistency, but hardware provides only coherence. The gap between the two is filled by memory barriers (fences) and by the language memory model's ordering constraints.

## 2. Sequential Consistency: The Gold Standard

In 1979, Leslie Lamport — the same Lamport who gave us Paxos, vector clocks, and LaTeX — published "How to Make a Multiprocessor Computer That Correctly Executes Multiprocess Programs," defining **sequential consistency (SC)**:

> "A multiprocessor is sequentially consistent if the result of any execution is the same as if the operations of all the processors were executed in some sequential order, and the operations of each individual processor appear in this sequence in the order specified by its program."

Let us unpack this. SC imposes two requirements:

1. **Per-processor program order:** The memory operations of each processor appear to execute in the order specified by the processor's program.
2. **Global total order:** There exists a single total order over all memory operations from all processors such that each read returns the value of the most recent write (to the same address) in that total order.

In other words, the machine behaves as if there were a single switch that connects one processor at a time to a shared memory, with each processor executing its instructions in program order when connected. This is the intuitive model that programmers naturally assume.

### 2.1 Formalizing SC

Let us define the formal ingredients:

- A **program order** \(\xrightarrow{po}\) is a strict partial order over the memory operations of each thread, reflecting the order in which operations appear in the program text (after compiler optimizations are accounted for).
- A **memory order** \(\xrightarrow{mo}\) is a strict total order over all memory operations (across all threads).
- A **reads-from** relation \(\xrightarrow{rf}\) maps each read to the write whose value it observes.

An execution is **sequentially consistent** if there exists a memory order \(\xrightarrow{mo}\) such that:

1. \(\xrightarrow{po} \subseteq \xrightarrow{mo}\) (program order is respected),
2. For each read \(r\) with \(\xrightarrow{rf}(r) = w\), we have \((w, r) \in \xrightarrow{mo}\) (a read sees a write that precedes it in memory order),
3. There is no other write \(w'\) to the same address such that \((w, w') \in \xrightarrow{mo}\) and \((w', r) \in \xrightarrow{mo}\) (the read sees the most recent write in memory order).

SC is the simplest possible model and the easiest to reason about. Every concurrent algorithm textbook assumes SC when presenting Dekker's algorithm, Peterson's lock, or lock-free data structures. The problem: SC is expensive to implement.

### 2.2 Why SC Is Expensive

The naive implementation of SC — having all processors share a single memory module and taking turns — would be catastrophically slow. Modern processors use a constellation of performance optimizations that violate SC:

- **Store buffers:** A processor that issues a store does not wait for it to complete before executing subsequent loads. The store sits in a local buffer, visible only to the storing processor, until it drains to the cache hierarchy. This means a load can bypass a preceding store — the processor sees its own store, but other processors do not yet.
- **Cache coherence delays:** Even after a store leaves the store buffer, propagating it through the cache coherence protocol takes time. Different processors see the store at different moments.
- **Write coalescing:** Multiple stores to the same cache line may be combined in the store buffer before being sent to memory, altering the apparent order.
- **Speculative execution:** Loads may be executed speculatively before preceding stores have their addresses resolved, potentially observing values that should not yet be visible.
- **Out-of-order execution pipelines:** Modern cores have deep reorder buffers (hundreds of instructions) that dynamically schedule instructions based on operand availability, not program order.

To enforce SC, the hardware would need to stall after every store until it becomes globally visible, and prevent any reordering of loads with respect to stores or other loads. This would reduce single-thread performance by a factor of 5–40× depending on the workload — an unacceptable cost.

### 2.3 The Dekker's Algorithm Litmus Test

Consider Dekker's mutual exclusion algorithm, simplified to its core memory pattern (the "store buffering" or "Dekker" litmus test):

```text
Thread 1:                Thread 2:
x = 1;                   y = 1;
r1 = y;                  r2 = x;
```

Under SC, the only possible outcomes for \((r1, r2)\) are \((0, 1)\), \((1, 0)\), and \((1, 1)\). The outcome \((0, 0)\) is impossible: if both threads see the other's flag as 0, then both must have executed their load before the other's store — but then both stores must have been first in the global order, a contradiction.

Under real hardware with store buffers (x86-TSO), \((0, 0)\) is possible. Each processor's store sits in its local buffer, invisible to the other, while both loads execute. This is the central challenge that memory consistency models must address.

## 3. Hardware Memory Models: x86-TSO and ARM/POWER

Faced with the performance cost of SC, hardware vendors adopted relaxed models that allow specific reorderings. Understanding these models is essential because the language memory model must compile efficiently to all of them.

### 3.1 x86-TSO: Total Store Order

The x86 architecture (Intel and AMD) implements a model that is very close to SC but with one critical relaxation: **store buffering** is permitted. The formal model is called **x86-TSO** (Total Store Order), formalized by Owens, Sarkar, and Sewell (2009).

Key properties of x86-TSO:

- **Loads are not reordered with loads:** If load A precedes load B in program order, load A's value is obtained before load B executes. (In hardware terms: loads execute in order.)
- **Stores are not reordered with stores:** Stores appear to all processors in program order.
- **Stores are not reordered with loads to the same address:** A load to an address sees the most recent store to that address in program order.
- **BUT: Loads may be reordered before preceding stores to different addresses.** This is the store-buffer effect: a load can complete while a prior store is still buffered.

x86-TSO also provides strong atomic operations: locked instructions (like `LOCK XCHG`, `LOCK CMPXCHG`, or the `LOCK` prefix on arithmetic instructions) act as full memory barriers — they flush the store buffer before executing and prevent subsequent loads from executing early. The `MFENCE` instruction provides an explicit full barrier, and `LFENCE`/`SFENCE` provide load-only and store-only ordering respectively.

The consequence: on x86, acquire semantics (load followed by load/store not reordered) are free — every load is already an acquire. Release semantics (store preceded by load/store not reordered) are also mostly free, except that a store must be compiled to a plain `MOV` and the preceding loads and stores are already ordered. This makes x86 an unusually strong memory model; it is often joked that x86 is "SC with store buffers."

### 3.2 ARM and POWER: Weak Ordering

ARM (v7 and earlier) and POWER processors implement **weakly ordered** memory models where almost anything can be reordered unless explicitly constrained by barriers (fences). Specifically:

- **Load-load reordering:** Allowed. Later loads can complete before earlier loads.
- **Load-store reordering:** Allowed. Later stores can complete before earlier loads.
- **Store-store reordering:** Allowed. Stores can become visible in a different order than program order.
- **Store-load reordering:** Allowed (as on x86).

This means that on ARM, even the Dekker litmus test is not the worst-case scenario. The **message passing** (MP) pattern is even more instructive:

```text
Thread 1:                Thread 2:
x = 1;                   r1 = y;
y = 1;                   r2 = x;
```

Here, Thread 1 writes a data value `x` and then sets a flag `y`. Thread 2 reads the flag, and if set, reads the data. The intuition: if Thread 2 sees `y = 1`, it must also see `x = 1` — the flag write happens after the data write. Under SC, this holds. Under x86-TSO, it holds (store-store ordering is preserved). Under ARM, it does NOT hold unless barriers are inserted: the stores to `x` and `y` can become visible out of order, or Thread 2's loads can be reordered.

ARM provides several barrier instructions:

- **`DMB` (Data Memory Barrier):** Ensures ordering between memory accesses before and after the barrier. Variants: `DMB SY` (full system), `DMB ST` (store-store), `DMB LD` (load-load), `DMB ISH` (inner shareable domain).
- **`DSB` (Data Synchronization Barrier):** A stronger barrier that also ensures cache maintenance operations complete.
- **`ISB` (Instruction Synchronization Barrier):** Flushes the pipeline and refetches instructions.

The cost of a `DMB` on ARM is typically 10–40 cycles, comparable to a branch misprediction. This is why weak memory models exist: they make the common case (no barriers) fast while requiring programmers to pay the barrier cost only when ordering matters.

### 3.3 Formalizing Weak Memory Models with Axiomatic Semantics

Modern memory model research uses **axiomatic semantics**: a set of constraints (axioms) on candidate executions, written as logical formulas over relations between memory events. An execution is allowed if it satisfies all axioms.

For example, a simplified axiomatic model for ARM might include:

- `acyclic(po-loc ∪ co ∪ rf ∪ fr)` — the union of program order for same-address accesses, coherence order, reads-from, and from-reads must be acyclic (the "SC per-address" requirement).
- `acyclic(po ∪ co ∪ rf ∪ fr ∪ rmw)` — with read-modify-writes atomically ordered.
- `acyclic(po ∪ co ∪ rf ∪ fr ∪ [dmb])` — barriers restore ordering.
- External (intra-thread) and internal (inter-thread) visibility order constraints.

The herd7 tool (Alglave, Maranget, and Tautschnig, 2014) automates this: given a litmus test and an axiomatic model description (in the `.cat` language), it enumerates all possible executions and checks which are allowed. This is the standard methodology for testing whether a particular microarchitecture conforms to its documented memory model. The companion `diy` tool can generate exhaustive litmus test suites from parameterized templates, and `memsynth` can automatically synthesize the weakest barriers needed to make a given litmus test behave as desired — a form of program synthesis specialized to memory ordering.

## 4. The C++11 Memory Model

Prior to 2011, C and C++ had no memory model. The language standard pretended threads did not exist. Concurrency was platform-specific, typically via POSIX threads (pthreads) on Unix and Windows threads on Windows. The compiler was free to reorder memory operations arbitrarily as long as single-thread semantics were preserved, and the interaction of compiler optimizations with hardware reordering was entirely unspecified.

C++11 changed everything. For the first time, a mainstream systems programming language defined a formal memory model with precise semantics for concurrent access. The model was designed by an international team led by Hans Boehm (of Boehm garbage collector fame) and involved contributions from hardware architects, compiler writers, and formal methods researchers.

### 4.1 Data Races and Undefined Behavior

The fundamental rule of the C++11 memory model is simple:

> If two accesses to the same memory location are not both atomic, at least one is a write, and they are not ordered by happens-before, the program has a **data race** and its behavior is **undefined**.

This is a crucial design choice. Rather than attempting to specify the value a non-atomic read sees in the presence of a concurrent write — which would constrain hardware and compiler optimizations enormously — the standard simply declares it undefined behavior. The programmer must use atomics to communicate between threads.

This "catch-fire" semantics for data races enables critical single-thread optimizations:

- **Register allocation:** The compiler can keep non-atomic variables in registers across loop iterations and function calls.
- **Redundant load elimination:** Two loads of the same non-atomic variable can be merged.
- **Store sinking:** A store can be delayed past control flow.
- **Speculative store bypassing:** A load can be hoisted above a possibly-aliasing store if the compiler can prove the addresses don't alias in well-defined executions.

Without the data-race prohibition, all of these optimizations would need to account for concurrent modifications — making C++ compilation dramatically more conservative and slower.

### 4.2 The Four Flavors of Atomic Ordering

C++11 atomics (`std::atomic<T>`) provide six memory ordering tags (plus `std::memory_order_consume`, which is effectively deprecated). The four primary ones, in decreasing order of strength:

#### 4.2.1 Sequentially Consistent (`memory_order_seq_cst`)

This is the default. It provides Lamport's SC: there is a single total order \(S\) over all sequentially consistent operations such that (a) the per-thread program order is respected, and (b) each load sees the value of the last modification in \(S\).

On x86, `seq_cst` loads are plain `MOV` (already acquire), and `seq_cst` stores are `XCHG` (an atomic exchange that implies a full barrier) or `MOV` followed by `MFENCE`. On ARM, both loads and stores require `DMB` barriers. `seq_cst` is the most expensive ordering but the easiest to reason about — it makes C++ atomics behave like the intuitive interleaving model.

#### 4.2.2 Acquire-Release (`memory_order_acquire`, `memory_order_release`)

Acquire-release provides pairwise ordering between threads that synchronize on the same atomic variable. The key definitions:

- An **acquire operation** (a load with `memory_order_acquire`, or a read-modify-write with `memory_order_acquire` or stronger) prevents subsequent memory operations from being reordered before it.
- A **release operation** (a store with `memory_order_release`, or an RMW with `memory_order_release` or stronger) prevents preceding memory operations from being reordered after it.
- A **release sequence** headed by a release store extends to subsequent RMW operations on the same atomic.
- A thread that performs an acquire load that reads from a release store **synchronizes-with** that store. All memory operations before the release store **happen-before** all memory operations after the acquire load.

This is exactly the ordering needed for the message-passing pattern:

```cpp
// Thread 1 (producer)
data = 42;                                  // non-atomic write
flag.store(1, std::memory_order_release);   // release store

// Thread 2 (consumer)
while (flag.load(std::memory_order_acquire) == 0); // acquire load
int val = data;  // guaranteed to see 42
```

The release store synchronizes-with the acquire load, establishing a happens-before edge from `data = 42` to `val = data`. The compiler and hardware must respect this ordering.

On x86, acquire and release are essentially free (plain `MOV` instructions suffice). On ARM, acquire loads require `LDAR` (load-acquire) and release stores require `STLR` (store-release) — introduced in ARMv8 to provide efficient acquire-release without full `DMB` barriers.

#### 4.2.3 Relaxed (`memory_order_relaxed`)

Relaxed atomics provide atomicity — a load always sees a value that some store wrote (no tearing) and RMW operations are indivisible — but absolutely no ordering guarantees with respect to other memory operations.

```cpp
x.store(1, std::memory_order_relaxed);
y.store(1, std::memory_order_relaxed);
```

Other threads may observe the store to `y` before the store to `x`. On ARM, relaxed stores can be reordered arbitrarily with respect to each other and to surrounding non-atomic accesses.

Relaxed atomics are appropriate when the only requirement is atomicity without ordering, such as:

- **Shared counters** that are incremented from multiple threads but never read until all threads have joined.
- **Statistics gathering** where occasional stale values are acceptable.
- **Memory allocator free lists** where the data structure itself provides ordering via compare-exchange.

#### 4.2.4 Consume (`memory_order_consume`)

Consume was intended to provide a weaker form of acquire that orders only _dependent_ loads. If a consume load reads a value, subsequent operations that are data-dependent on that value see the corresponding release's prior writes. In theory, this is cheaper than acquire on weakly ordered architectures (no barrier needed). In practice, compilers promote `memory_order_consume` to `memory_order_acquire` because tracking dependencies precisely is extremely difficult in the presence of compiler optimizations that can break syntactic dependencies (e.g., value numbering, constant propagation).

### 4.3 The Happens-Before Relation

The **happens-before** relation is the fundamental ordering relation of the C++11 model. It is built compositionally:

1. **Sequenced-before** (sb): The intra-thread program order after compiler transformations. If A is sequenced-before B, then A happens-before B.
2. **Synchronizes-with** (sw): Established by acquire-release pairs, SC fences, and thread creation/join. If a release store synchronizes-with an acquire load that reads from it, then the store happens-before the load.
3. **Happens-before** (hb) = (sb ∪ sw)⁺ — the transitive closure of sequenced-before and synchronizes-with.

The key guarantee: if A happens-before B, then the memory effects of A are visible to B. Moreover, happens-before is used to detect data races: two accesses to the same non-atomic location, at least one a write, without happens-before ordering between them, constitute a data race.

The happens-before relation is carefully designed to be efficiently implementable. On x86, the release-acquire synchronizes-with edge compiles to nothing — the hardware already preserves the needed ordering. On ARMv8, it compiles to `STLR`/`LDAR` instructions that are only slightly more expensive than plain loads and stores (they prevent certain reorderings within the local core's pipeline without requiring a full system-wide barrier). The portability comes from the fact that the compiler emits the cheapest instruction sequence that satisfies the axiomatic constraints on each target architecture.

### 4.4 Fences (`std::atomic_thread_fence`)

In addition to per-operation ordering, C++11 provides standalone fences. A **release fence** (`std::atomic_thread_fence(std::memory_order_release)`) prevents preceding memory operations from being reordered with subsequent stores. An **acquire fence** prevents subsequent memory operations from being reordered with preceding loads. A full **sequentially consistent fence** (`std::atomic_thread_fence(std::memory_order_seq_cst)`) restores SC ordering at that point.

Fences are more flexible than per-operation ordering but also more error-prone. The classic use case is when the release store and the data writes preceding it are on different atomic variables, or when the release "store" is actually a non-atomic operation that must be ordered.

## 5. The Out-Of-Thin-Air Problem

No discussion of memory models is complete without the **Out-Of-Thin-Air (OOTA)** problem — arguably the hardest unsolved problem in weak memory model semantics.

Consider this classic example (the "load-buffering" or "OOTA" litmus test):

```cpp
// Thread 1                // Thread 2
r1 = x.load(relaxed);      r2 = y.load(relaxed);
y.store(r1, relaxed);      x.store(r2, relaxed);
```

Assume initially `x = y = 0`. Under most operational intuitions, the only possible values for `(r1, r2)` are `(0, 0)`. But what about `(42, 42)`? Could the processors "invent" the value 42 — speculatively guessing it, storing it, loading it back, and then "validating" the speculation by confirming the initial load also returned 42?

The answer should be "no." Processors should not be allowed to fabricate values. But formalizing this prohibition — that values must come from somewhere, must have a causal origin — has proven extraordinarily difficult. The C++11 model currently has no formal prohibition against OOTA behavior; it relies on the fact that no real hardware implements such speculation and that compilers do not introduce it. The model is, in this sense, incomplete.

The Java memory model (Manson, Pugh, and Adve, 2005) attempted to address OOTA via a complex system of "causality" constraints involving multiple witnessing executions. The result was so intricate that few practitioners fully understand it. The search for a clean, compositional, OOTA-free weak memory model remains an active research area, with recent promising approaches based on **promising semantics** (Kang et al., 2017) and **operational memory models** with explicit write buffers and propagation.

## 6. Practical Verification and Tooling

Reasoning about memory ordering by hand is error-prone. Several tools help:

### 6.1 Herd7 and litmus Tests

The `herd7` tool (part of the `diy` suite, developed at University College London and Inria) takes a litmus test and a memory model (described in the `.cat` language) and enumerates all allowed executions. This is the gold standard for testing whether a proposed code pattern behaves identically across hardware architectures.

```text
ARM MP+popl
{
  int x = 0;
  int y = 0;
}
 P0          | P1          ;
 MOV W0, #1  | LDR W1, [y] ;
 STR W0, [x] | LDR W2, [x] ;
 STR W0, [y] |              ;
exists (1:W1=1 /\ 1:W2=0)
```

The `herd7` tool reports that on ARM without barriers, the outcome `W1=1, W2=0` is observable — Thread 2 sees the flag but not the data, exactly because of store-store reordering.

### 6.2 CDSChecker

CDSChecker (Norris and Demsky, 2013) is a model checker for C++11 concurrency. It systematically explores all possible interleavings and memory orderings for a given test program under the C++11 model, reporting data races and counterexamples to user-specified assertions. It uses the `relacy` race detector's happens-before analysis to prune the search space while ensuring complete coverage of the C++11 axiomatic model.

### 6.3 ThreadSanitizer (TSan)

Google's ThreadSanitizer (integrated into GCC and Clang via `-fsanitize=thread`) instruments memory accesses at compile time and detects data races at runtime. It uses a happens-before tracking approach: each memory access is associated with a vector clock, and conflicting accesses without happens-before ordering are flagged. While TSan cannot prove the absence of races (it only observes one execution), its overhead of 2–5× makes it practical for integration into CI pipelines.

## 7. The `volatile` Trap

A persistent misconception: that `volatile` in C++ (and C) makes variables thread-safe. It does not. The `volatile` qualifier has exactly two legitimate uses:

1. **Memory-mapped I/O:** Accessing hardware device registers where every read and write must be emitted exactly as written, not optimized away.
2. **`setjmp`/`longjmp` safety:** Variables modified between `setjmp` and `longjmp` should be `volatile` to prevent the compiler from keeping them in registers.

`volatile` provides **no** atomicity guarantees, **no** ordering guarantees, and **no** protection against data races. On some compilers, `volatile` accesses happen to be emitted as single instructions that the hardware treats atomically for naturally aligned word-sized accesses, but the C++ standard guarantees none of this. Use `std::atomic<T>` with appropriate memory ordering for inter-thread communication.

## 8. Designing Correct Lock-Free Code

Armed with an understanding of the memory model, we can now formulate principles for writing correct concurrent code:

### 8.1 Start with Sequential Consistency

When prototyping, use `std::memory_order_seq_cst` everywhere. It is the safest default, and on x86 it is almost as fast as acquire-release. Only relax ordering after profiling shows a bottleneck attributable to memory ordering overhead, and only after careful verification.

### 8.2 Identify Synchronization Points

For every inter-thread communication, identify: which writes must be visible to which reads? The writes must be sequenced-before a release store. The reads must be sequenced-after an acquire load that reads from that release store (or a subsequent store in the release sequence).

### 8.3 Use Acquire-Release Pairs for Message Passing

The acquire-release idiom maps perfectly to the message-passing pattern where a producer writes data and then publishes a flag. This is the most common pattern in lock-free programming and is efficiently implementable on all architectures.

### 8.4 Relaxed Atomics Only for Non-Ordering Communication

Relaxed atomics are appropriate for:

- Reference counting with `fetch_add`/`fetch_sub` (the ordering is provided by the atomicity of the RMW, not by ordering constraints).
- Sequence locks where the writer uses release/acquire and only the data loads are relaxed (but carefully).
- Monotonic counters where only atomicity matters.

### 8.5 Avoid Out-Of-Thin-Air Patterns

Any code where a store's value depends on a relaxed load from another thread that may itself see a value derived from the first thread creates a causal cycle. These patterns are formally underspecified and should be avoided entirely in production code.

### 8.6 The Correctness-Performance Spectrum

It is useful to think of memory ordering as a spectrum from "always correct, potentially slower" to "maximally fast, potentially dangerous":

- **`seq_cst` everywhere:** Correct by construction but pays barrier costs on ARM (and on x86 for stores). Use for prototyping and when correctness is paramount.
- **`acquire`/`release` pairs:** The sweet spot for most lock-free programming. Nearly free on x86, efficient on ARMv8 with `LDAR`/`STLR`. Covers message passing, reference counting publication, and most synchronization patterns.
- **`relaxed` with explicit fences:** Rarely needed; fences are harder to reason about than per-operation ordering. Use only when the acquire/release pattern cannot be expressed as a single atomic operation pair.
- **`relaxed` without fences:** Only for isolated counters and statistics where ordering is irrelevant.
- **Mixing ordering within a single algorithm:** This is where the real complexity lies. A lock-free queue might use `release` for the enqueue store, `acquire` for the dequeue load, and `relaxed` for internal cursor updates that are protected by higher-level logic. Each ordering choice must be justified by a specific happens-before path.

## 9. Conclusion

Memory consistency models are the specification of what parallel programs mean. They are the contract between the programmer (who assumes certain ordering guarantees), the compiler (which reorders instructions for performance), and the hardware (which buffers, coalesces, and reorders memory operations). Understanding this contract is not optional for anyone writing concurrent code in systems languages.

The key concepts to internalize:

- **Coherence** (per-address ordering) is not **consistency** (multi-address ordering). Hardware provides the former; the memory model provides the latter.
- **Sequential consistency** is the intuitive model — a total order respecting program order — but is too expensive to implement directly on modern hardware.
- **x86-TSO** relaxes only store-load ordering (loads can bypass stores), making acquire and release effectively free. **ARM/POWER** relax everything, requiring explicit barriers.
- The **C++11 memory model** provides a portable abstraction: `seq_cst` for correctness, `acquire`/`release` for efficiency, `relaxed` for atomicity without ordering. The **happens-before** relation is the backbone that tracks which effects are visible.
- The **Out-Of-Thin-Air problem** remains open, reminding us that formalizing weak memory is genuinely hard. Avoid the load-buffering pattern that triggers it.
- `volatile` is not about threads. Use `std::atomic`.
- Verify with tools: `herd7` for litmus tests, TSan for runtime race detection, CDSChecker for exhaustive model checking.

Memory models are a relatively young field. The C++11 model was a breakthrough, but it is not perfect — the consume ordering is broken in practice, relaxed atomics are semantically incomplete, and the specification document itself runs to over 40 dense pages of axiomatic formalism. Yet for all its complexity, the modern memory model is a triumph of systems engineering: it enables writing correct, efficient concurrent programs that run identically on processors ranging from tiny ARM Cortex-M microcontrollers to 256-core x86 servers, while preserving the single-thread performance that decades of compiler optimization have achieved.

The next time you write `std::memory_order_acquire`, remember: you are issuing an instruction that traces a lineage from Lamport's 1979 definition through decades of architecture wars, standards committee debates, and formal verification research — all so that, on an ARM phone in a café in São Paulo, your flag store reliably publishes your data load to a thread on the other side of a coherence domain boundary. The memory model is invisible when it works, catastrophic when it fails, and, like all deep systems abstractions, beautiful once you understand it.

In the end, memory models are a negotiation between the physics of silicon (signals take time to propagate across a die, let alone a motherboard), the economics of performance (no one buys a processor that stalls after every store), and the cognitive limits of programmers (who deserve a mental model that does not require simulating every reorder buffer and cache line). The C++11 model is not the final word — it is merely the first successful treaty in what will be an ongoing negotiation as heterogeneous computing, non-volatile memory, and persistent memory further complicate the already complex landscape of what it means for one computation to see the effects of another.
