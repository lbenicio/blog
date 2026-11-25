---
title: "A Deep Dive Into Seqlocks: Optimistic Snapshot Reads, Memory Ordering, And Why The Counter Is Not A Lock"
description: "How seqlocks let readers take consistent snapshots of read-mostly state without acquiring anything, why the protocol needs exactly four one-way barriers, and what the sequence counter does and does not guarantee."
date: "2026-02-11"
author: "Leonardo Benicio"
tags: ["concurrency","synchronization","memory-ordering","linux-kernel","systems-design","lock-free"]
categories: ["Computer Science","Systems Design","Parallel Computing"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/a-deep-dive-into-seqlocks-optimistic-snapshot-reads-memory-ordering-and-why-the-counter-is-not-a-loc-2026-02-11.jpg"
coverAlt: "Abstract dark-blue illustration of a stacked data payload with a glowing two-state counter beside it, a looping retry arrow on the right, and dashed lines suggesting memory barriers."
---

# A Deep Dive Into Seqlocks: Optimistic Snapshot Reads, Memory Ordering, And Why The Counter Is Not A Lock

## The read that must not take a lock

There is a class of shared state that is read constantly and written rarely. A 64-bit monotonic counter that must be sampled without tearing on a 32-bit machine. A snapshot of clock parameters that a timestamp function needs on every trace point. The generation number and current value of a configuration table that is reloaded once a minute and consulted on every request. The cached byte counters of a network interface. The parent-and-name linkage of a directory entry in a filesystem cache.

The readers in these cases are on the hot path. Every packet, every file lookup, every log line, every timer read touches the structure. The writers are on the cold path, running a few times a second or a few times a minute. The ratio of reads to writes is not ten to one; it is closer to ten million to one.

The obvious tool is a reader-writer lock. It is also the wrong tool, and the reason is not throughput in the abstract. It is cache-line ownership.

## Why reader-writer locks are the wrong shape here

A reader-writer lock keeps its state — a reader count, a writer flag, a wait queue pointer — in memory. Taking a read lock is not a read. It is a read-modify-write on shared state, and on any real multi-core machine that means an atomic operation whose cache line must be owned exclusively by the core performing it. Two cores cannot both hold the line in the Modified state. So a read lock acquisition forces the line to migrate, and the next reader forces it to migrate again.

The consequence is that the cost of a read lock grows with the number of concurrent readers rather than staying flat. Under enough reader concurrency, the lock's cache line becomes a serialization point that has nothing to do with the data the lock is protecting. The data itself may be perfectly shareable — every core can hold a clean, read-only copy — while the lock state is not.

There is a second problem, and it is often worse. A writer needs exclusive ownership of that same line. It must wait for the last reader to release, and readers can arrive faster than the writer can drain them. In a naive implementation, a steady stream of readers can postpone a writer indefinitely. Writer starvation is not a theoretical curiosity in read-mostly systems; it is the default behavior of reader-preferring rwlock implementations. The usual fixes — writer-preferring locks, phase-fair locks, ticket-based designs — all add more shared state to the reader path, which makes the first problem worse.

A third problem is structural. In many of these workloads the writer is not a peer of the reader. It is a timer interrupt, an NMI handler, a device completion, or a housekeeping thread. It may need to update the structure from a context where blocking is not merely undesirable but impossible. A lock that requires readers to participate in a mutual-exclusion protocol imposes obligations on contexts that cannot honor them.

Seqlocks take a different position. Readers do not synchronize at all. They read the data, then check whether anything changed underneath them, and if it did, they read it again. Readers never write shared state, never wait for a writer, and never block a writer. The writer, correspondingly, never waits for a reader. The entire cost of the protocol is paid in retries, and only when a read actually races with a write.

## The seqlock protocol

A seqlock is a sequence counter plus a payload. The counter is incremented twice per write: once to mark the beginning of a critical section and once to mark the end. Because it starts at an even value and is incremented by one each time, the parity of the counter tells a reader whether a write is in progress. An even value means the payload is stable. An odd value means a writer is in the middle of modifying it.

Stripped to its essentials, the protocol looks like this:

```c
/* Writer. Only one writer may be inside at a time. */
seq++;                  /* counter is now odd: write in progress */
smp_wmb();
payload = new_value;    /* one or more stores */
smp_wmb();
seq++;                  /* counter is now even: payload is stable */

/* Reader. */
unsigned s;
do {
    s = seq;            /* READ_ONCE(seq) */
    smp_rmb();
    snapshot = payload; /* one or more loads */
    smp_rmb();
} while ((s & 1) || s != seq);
```

The reader's loop has two exit conditions and they are not redundant. The `(s & 1)` test rejects the case where the reader began while a writer was already mid-update. The `s != seq` test rejects the case where a writer started and finished during the reader's window. The first test is a cheap early-out; the second is the actual correctness check.

Note what the writer is *not* doing. It is not performing an atomic read-modify-write on the counter. `seq++` is a plain load, add, and store. That is safe only because the protocol guarantees a single writer at a time — either because an embedded spinlock serializes writers, or because the caller has established that the update path is inherently single-threaded (a per-CPU structure, a timer callback, a configuration thread). The counter is not atomic because it does not need to be, and making it atomic would add a locked instruction to the write path for no benefit.

Note also what the reader is *not* doing. It is not issuing any atomic operation at all. The loads of the payload are ordinary loads. The barriers are one-way fences, not full fences, and on most architectures they compile to nothing or to a very cheap instruction. That is the entire point: the reader's fast path is a handful of loads and two comparisons.

## What a seqlock actually guarantees

A seqlock is not a lock, and treating it as one leads to bugs. It does not provide mutual exclusion. Two readers can be inside the payload simultaneously. A reader and a writer can be inside the payload simultaneously — the reader will simply detect it and retry. Nothing is ever held.

What a seqlock provides is *snapshot atomicity*. If a reader completes its loop successfully, the values it read correspond to some instant at which no writer was mid-update. The payload may be a struct with a dozen fields, and the reader's copy of that struct will be internally consistent with respect to that instant: it will not contain field A from before an update and field B from after it.

That guarantee comes with a precise caveat. The reader's snapshot is consistent, but it is not necessarily *fresh*. Between the moment the reader's loads executed and the moment the reader validated the counter, a writer may have completed an entire update. The reader will retry in that case, but the point is that the validation is what establishes consistency, not the loads themselves. The linearization point of a successful read is the final counter load, not the first one.

The most important practical rule follows directly from the retry loop: **the reader's body must be free of side effects.** It may execute more than once. It must not increment a counter, append to a buffer, update a cache, or modify anything the caller can observe. It must also be re-entrant with respect to itself, because that is exactly what the retry is.

Two further constraints are easy to miss. First, the reader must not block. In kernel contexts this means it must not sleep, must not take a lock that a writer might hold, and must not fault — a page fault taken while a writer holds the embedded lock can deadlock if the fault handler needs the same structure. Second, the reader must not be able to run indefinitely while a writer is paused. A reader that is interrupted by a writer will simply retry, which is fine. A reader that *interrupts* a writer, sees the odd counter, and spins waiting for the writer to finish will spin forever, because the writer cannot finish until the reader yields. That inversion is the reason the latch variant exists, and it is the single most important structural hazard in the design.

There is also a theoretical wraparound hazard. The reader's retry test compares the full counter value, not just its parity. If a reader's window happened to span exactly 2^31 writer updates, the counter would return to the same even value and the reader would accept a torn snapshot. No one designs around this; the window is a few instructions long and the update rate would have to be absurd. It is worth knowing that the check is an equality test rather than a monotonicity test, because that is what makes the fast path cheap.

## The four barriers

The protocol above contains four barriers, and each one closes a specific reordering window. They are worth deriving rather than memorizing, because the same reasoning applies to any optimistic-read design.

**Writer, before the payload stores.** Without a store-store barrier between the odd increment and the payload writes, the payload stores may become visible before the counter change. A reader could then load an even counter, load a partially updated payload, and re-load the same even counter — the writer has not yet incremented a second time — and accept the torn result. The barrier ensures that once a reader observes an odd counter, the payload is genuinely in flux.

**Writer, after the payload stores.** Without a store-store barrier between the payload writes and the final increment, the increment may become visible before the payload stores land. A reader could load the new even counter, load the stale payload, and re-load the same new even counter, accepting a snapshot that never existed. The barrier ensures that a reader who observes the final even counter observes a payload that is already complete.

**Reader, after the initial counter load.** Without a load-load barrier, the payload loads may be hoisted above the counter load. The reader would then pair a payload read taken during a write with a counter value read after the write finished, and accept it. The barrier ensures the counter observation precedes the payload observation in program order as seen by the memory system.

**Reader, before the final counter load.** Without a load-load barrier, the final counter load may be sunk below the payload loads. The reader would then validate against a counter value that predates its own payload reads, and a write that landed during those reads would go undetected. The barrier ensures the payload observation precedes the validation.

All four are one-way barriers. The writer needs store-store ordering and the reader needs load-load ordering; neither needs store-load ordering, which is the expensive direction on weakly ordered architectures. Using full fences here would be correct but wasteful. This is the kind of detail that makes seqlocks fast in practice and also makes them easy to get subtly wrong when they are reimplemented from a description rather than from the memory model.

## The counter is not a lock

A lock has an owner. A seqlock counter has no owner. A lock encodes a right to proceed. The counter encodes a fact about the payload: whether a write is in progress, and whether one has completed since a given observation. The distinction is not semantic hair-splitting; it changes what operations are legal.

Because the counter is not a lock, readers never acquire it. There is no acquire semantics on the initial load. The initial load is a plain read, ordered with respect to subsequent payload loads by a load-load barrier. There is no release on the final load either. The final load is a validation, not a handoff. The writer's final increment is not a release operation that publishes the payload to a waiting reader; it is a store that makes the counter even again. The payload stores are ordered before it by a store-store barrier, but no reader is waiting on that store in the sense of a condition variable.

This matters for API design. A seqlock read function cannot return a value that the caller can use as a token to later unlock. There is no such token. It cannot be used to protect a multi-step operation. If a caller needs to read two separate seqlock-protected structures and have them be consistent with each other, a seqlock alone cannot provide that. The caller would need a higher-level protocol, such as a global generation counter, or the two structures would need to be combined into one payload.

The counter also does not provide mutual exclusion between writers. The single-writer requirement is external. In the Linux kernel, the writer side is often wrapped in a spinlock. The spinlock is the lock. The seqlock is the optimistic read side plus the sequence protocol. Confusing the two leads to the classic bug of two writers incrementing the counter concurrently: both see an even counter, both increment to odd, both write, both increment to even, and a reader can validate a payload that is a mix of both writers stores. The parity test cannot detect this because the counter never stayed odd long enough for the reader to notice, or it returned to even after two increments.

So the first invariant of any seqlock is: exactly one writer at a time. The second is: the writer must be able to finish its update without being starved by readers. Readers do not block the writer, so the second invariant is usually easy to satisfy. But the writer must not be preempted indefinitely by a context that also tries to read the same seqlock, because that can create the inversion described later.

## What the writer must guarantee

The writer's side of a seqlock is deceptively simple. It must increment the counter to odd, ensure the payload stores are not reordered before that increment, perform the payload stores, ensure the final increment is not reordered before the payload stores, and increment the counter to even. It must do all of this while holding the single-writer invariant.

There are several practical details that are easy to overlook.

First, the payload stores must be plain stores. Using an atomic store for a field that is part of the payload is not wrong, but it is usually unnecessary and can be slower. The seqlock protocol already ensures that readers will not accept a torn snapshot. The only reason to use an atomic store is if some other code path reads that field without going through the seqlock, which is a different synchronization problem.

Second, the writer must not publish a pointer to the payload before the payload is fully initialized. If the seqlock protects a pointer to a separately allocated structure, the writer must complete the initialization, issue the appropriate barriers, and then update the pointer. The seqlock's store-store barrier orders the pointer store after the payload stores, but it does not order the payload stores after the allocation or initialization if those are done by a different thread. The writer must ensure that the structure is fully constructed before it is linked into the seqlock-protected location.

Third, the writer must consider the size of the payload. A seqlock works best when the payload is small enough to be copied with a few loads and stores. If the payload is large, the reader's retry loop becomes expensive, and the probability of a retry increases because the reader's window is longer. There is no hard limit, but a seqlock protecting a kilobyte-sized structure is usually a sign that a different mechanism would be better. The exception is when the structure is read rarely enough that retries are still cheaper than the alternative, or when the writer can update it in a way that keeps the reader's window short.

Fourth, the writer must not perform operations that can fault or block while the counter is odd, unless the surrounding design accounts for it. A page fault taken while the counter is odd will leave the counter odd for the duration of the fault. Readers will retry, which is safe but potentially unbounded. If the fault handler itself tries to read the same seqlock, it will see an odd counter and retry forever, because the writer cannot resume until the fault handler returns. This is a real deadlock in kernel contexts, and it is one of the reasons seqlocks are often used with data that is already resident and never paged out.

## Memory ordering in the real world

The abstract protocol requires four one-way barriers. How those barriers are implemented depends on the architecture, and the differences are instructive.

On x86, the memory model is relatively strong. Loads are not reordered with loads, and stores are not reordered with stores. The only reordering that the hardware allows is a store followed by a load to a different location, which is the store-load direction. The seqlock protocol does not need store-load ordering on the reader side, and it does not need load-load or store-store ordering on the writer side beyond what the hardware already provides. As a result, the barriers in the seqlock fast path often compile to nothing more than compiler barriers. The `smp_wmb()` calls become compiler barriers that prevent the compiler from reordering the stores, and the `smp_rmb()` calls become compiler barriers that prevent the compiler from reordering the loads. The actual CPU instructions are plain loads and stores. This is why seqlocks are extremely cheap on x86.

On ARM, the memory model is weaker. Loads can be reordered with loads, stores with stores, and stores with loads. The seqlock protocol needs explicit barriers. In the Linux kernel, `smp_wmb()` on ARM typically compiles to a `dmb ishst` instruction, which orders stores before stores. `smp_rmb()` compiles to `dmb ishld`, which orders loads before loads. These are not full `dmb ish` fences; they are one-way barriers that are cheaper than a full fence. On some ARM implementations, the cost of a `dmb ishld` is lower than a full `dmb ish`, but it is still a real instruction that can take tens of cycles. This is one reason seqlocks are less attractive on weakly ordered architectures when the read rate is extremely high and the payload is tiny.

On RISC-V, the situation is similar. The `fence r, r` instruction orders loads before loads, and `fence w, w` orders stores before stores. The seqlock protocol maps directly onto these fences. The `fence rw, rw` full fence is not needed.

On PowerPC, the `lwsync` instruction provides a lightweight barrier that orders loads before loads and stores before stores, but not stores before loads. This is exactly what the seqlock needs. The `sync` instruction is a full fence and is more expensive. Using `lwsync` in the seqlock fast path is a common optimization.

The compiler is another source of reordering. Even on x86, where the hardware does not reorder loads with loads, the compiler can. The `READ_ONCE()` and `WRITE_ONCE()` macros in the Linux kernel are designed to prevent the compiler from introducing speculative loads, merging loads, or reordering accesses across the barrier. A seqlock implementation that uses ordinary C loads and stores without these annotations is not correct, because the compiler is free to hoist the payload loads above the counter load or sink the final counter load below the payload loads. The barriers must be compiler barriers as well as CPU barriers. In the Linux kernel, `smp_rmb()` and `smp_wmb()` include compiler barriers, but a portable implementation must ensure that the compiler cannot reorder the accesses around the barrier.

## The reader's retry loop as a state machine

It is useful to think of the reader's loop as a small state machine with three states: idle, reading, and validating. The reader starts in idle, loads the counter, and transitions to reading if the counter is even. If the counter is odd, it stays in idle and retries. In the reading state, it loads the payload. Then it transitions to validating, where it loads the counter again. If the counter is still even and equal to the initial value, the read succeeds. If the counter is odd or different, the reader transitions back to idle and retries.

The state machine has an important property: the reader never waits. It never blocks on a writer. It never yields. It simply retries. This is what makes seqlocks suitable for contexts where blocking is impossible, such as interrupt handlers and NMI handlers. However, the absence of waiting does not mean the absence of starvation. A reader can be starved by a writer that updates the structure continuously. If the writer updates the structure faster than the reader can complete a read, the reader will retry forever. This is not a deadlock, but it is a livelock. In practice, writers are rare, so this is not a concern. But if the write rate is high, a seqlock is the wrong choice.

The state machine also shows why the reader's body must be side-effect-free. The body may execute multiple times. If it increments a counter, that counter will be incremented multiple times. If it appends to a buffer, the buffer will contain duplicates. If it updates a cache, the cache will be updated with values from a failed attempt. The only safe operations are pure reads and computations that do not affect shared state. Even a store to a local variable is fine, because the local variable is not shared. But a store to a location that another thread can observe is not.

## The latch variant: when readers must not spin

The standard seqlock has a subtle problem when a reader can interrupt a writer. Suppose a writer is in the middle of an update, with the counter odd. An interrupt occurs on the same CPU. The interrupt handler reads the same seqlock. It sees the odd counter and retries. But the writer cannot finish because the interrupt handler is running on the same CPU. The interrupt handler will retry forever, and the writer will never resume. This is a deadlock, not a livelock, because the writer is blocked by the reader.

The solution is the latch variant, sometimes called a seqlock with a writer latch. In this variant, the writer sets a latch flag before incrementing the counter, and the reader checks the latch before retrying. If the latch is set, the reader knows that a writer is in progress on the same CPU, or in a context that cannot be preempted by the reader, and it must not spin. Instead, it can take a different path, such as acquiring a lock, or it can return a failure indication to the caller.

The latch variant is more complex and is used only when the reader can run in a context that can interrupt the writer. In the Linux kernel, the `seqlock_t` type includes a spinlock for writers and a sequence counter. The `read_seqbegin()` function does not use a latch; it simply retries. The `read_seqbegin_or_lock()` function, used in some filesystems, does use a latch-like mechanism to avoid deadlock when the reader might be in an interrupt context. The details vary, but the principle is the same: if a reader can preempt a writer, the reader must not spin waiting for the writer to finish.

## Seqlocks versus RCU and atomics

Seqlocks are often compared to RCU and to atomic operations. The comparison is useful because it clarifies what seqlocks are for.

RCU is a broader mechanism for read-mostly data. Like seqlocks, RCU readers do not block writers and do not acquire locks. Unlike seqlocks, RCU readers can traverse linked structures and can hold references across context switches. RCU achieves this by deferring reclamation of old versions until all pre-existing readers have finished. Seqlocks do not defer reclamation; they retry. RCU is better for pointer-based structures where the reader needs to walk a graph. Seqlocks are better for small, fixed-size payloads that can be copied in a few instructions.

Atomic operations are the right tool when the entire state fits in a single word. A 64-bit counter can be read and written atomically on a 64-bit machine. A seqlock is unnecessary. On a 32-bit machine, a 64-bit counter cannot be read atomically with a single load, so a seqlock is one way to provide a consistent snapshot. The seqlock's advantage over a lock is that readers do not write shared state. The seqlock's disadvantage is that readers may retry, and the writer must be single-threaded.

## A review checklist for seqlock users

When reviewing a seqlock implementation, the following questions are worth asking.

1. Is there exactly one writer at a time? If not, the counter protocol is broken.
2. Are the writer's barriers present and correctly placed? The odd increment must precede the payload stores, and the payload stores must precede the even increment.
3. Are the reader's barriers present and correctly placed? The initial counter load must precede the payload loads, and the payload loads must precede the final counter load.
4. Are the accesses marked as `READ_ONCE()` and `WRITE_ONCE()` or equivalent? Without compiler barriers, the compiler can reorder the accesses.
5. Is the reader's body free of side effects? It may execute multiple times.
6. Can the reader block, sleep, or fault? If so, the seqlock may deadlock or livelock.
7. Can the reader interrupt the writer? If so, a latch variant or a different mechanism is needed.
8. Is the payload small enough that retries are cheap? If not, consider RCU or a different design.
9. Is the write rate low enough that readers are not starved? If not, consider a different mechanism.
10. Is the counter wide enough? On a 32-bit machine, a 32-bit counter can wrap in a few seconds if the write rate is high. A 64-bit counter is safer.

These questions are not a substitute for understanding the memory model, but they catch the most common mistakes.

## The Counter's Cache Line and the Cost of Coherence

A seqlock removes the reader's write to shared state, but it does not remove cache coherence traffic. The writer still stores to the counter and to the payload. Every store to a line that is cached read-only on other cores must invalidate those copies. The next reader on those cores takes a cache miss. This is the fundamental cost of any write to read-mostly data, and seqlocks do not eliminate it. They only ensure that readers do not cause the invalidation.

The placement of the counter relative to the payload matters. If the counter and the payload share a cache line, then a writer's increment to the counter invalidates the line for every reader, even if the payload bytes themselves are unchanged. A reader that only needs the counter will still miss. If the payload is large, the writer's payload stores will invalidate the payload lines anyway, so sharing the counter with the payload may not add much. But if the payload is small and the counter is hot, sharing can cause unnecessary invalidation. The usual fix is to place the counter on its own cache line, aligned to the cache line size, and to keep the payload in a separate, read-mostly line. This costs a second cache line in the reader's working set, but it avoids false sharing between the counter and the payload.

False sharing with unrelated data is a more common problem. A seqlock embedded in a larger structure can share a line with a field that is written frequently by another CPU. The reader's counter load will then miss because of the unrelated write. The writer's counter store will invalidate the unrelated field's readers. The solution is to align the seqlock to a cache line and to pad it. In the Linux kernel, this is done with `__cacheline_aligned_in_smp` or `____cacheline_aligned`. In userspace, `alignas(64)` or `std::hardware_destructive_interference_size` can be used.

The payload itself should be treated as read-mostly. If the payload is written by the seqlock writer and also by some other code path, the seqlock's guarantees are void. The writer's stores must be the only writes to the payload during the seqlock's critical section. Readers may read the payload without any synchronization, but they must not write it. If a reader needs to update a field, that update must go through the writer.

There is a subtlety with the counter's parity. The counter is incremented twice per write. The first increment makes it odd, the second makes it even. A reader that loads the counter while it is odd will retry. But the reader's load of the counter is a plain load. On a weakly ordered machine, the load may be served from a local cache that is stale. The barriers ensure that the reader does not proceed to the payload until the counter load is ordered. But the counter load itself may be satisfied by a stale cache line. The writer's increment will eventually invalidate that line. The reader may see an old even counter, load the payload, and then see the new even counter on the final load, causing a retry. This is correct. The retry is the cost of the optimistic read.

## The Reader's Window and the Probability of Retry

The reader's window is the interval between the initial counter load and the final counter load. During this interval, the reader loads the payload. If a writer starts and finishes within this interval, the reader retries. If a writer starts before the initial load and finishes after the final load, the reader retries. If a writer starts before the initial load and finishes before the final load, the reader may see a mix of old and new payload values and retry. The probability of a retry depends on the write rate and the length of the reader's window.

Let `f` be the write rate in writes per second. Let `T_w` be the time the writer spends with the counter odd. Let `T_r` be the time the reader spends between the initial and final counter loads. A retry occurs if a writer's odd interval overlaps the reader's window, or if a writer starts and finishes within the reader's window. For small `f`, the probability of a retry is approximately `f * (T_w + T_r)`. This is a useful approximation. If `f` is 1000 writes per second, `T_w` is 100 nanoseconds, and `T_r` is 50 nanoseconds, then the retry probability is about `1000 * 150e-9 = 0.00015`, or 0.015%. That is negligible. If `f` is 1 million writes per second, the retry probability is about 15%. That is significant. If `f` is 10 million writes per second, the retry probability is about 150%, which means the reader is likely to retry multiple times. At that point, the seqlock is livelocked.

The reader's window `T_r` is not just the time to execute the payload loads. It also includes the time the reader may be preempted. If the reader is preempted between the initial and final counter loads, the window expands. A writer that runs during the preemption will cause a retry. This is safe, but it increases the retry probability. If the reader is preempted for a long time, the counter may wrap. We will discuss that later.

The writer's odd interval `T_w` should be as short as possible. The writer should not perform expensive operations while the counter is odd. It should not allocate memory, take locks, or call functions that can sleep. It should copy the new payload into place as quickly as possible. If the writer needs to compute the new value, it should do so before incrementing the counter. The odd interval should contain only the stores to the payload and the two increments. This minimizes the window in which readers see an odd counter and retry.

Multiple readers do not affect the writer's odd interval. They do not block the writer. But they do increase cache pressure. When the writer stores to the payload, it invalidates the payload lines in all readers' caches. If many readers are reading the payload concurrently, the writer's stores will cause many invalidations. The next readers will miss. This is not a correctness issue, but it is a performance issue. The seqlock's advantage is that readers do not invalidate each other. They do not write to the counter. So the counter line can remain shared among readers. The payload lines, however, will be invalidated by the writer. If the payload is large, the invalidation traffic can be significant. This is why seqlocks are best for small payloads.

## Preemption, Interrupts, and the Same-CPU Deadlock

The standard seqlock assumes that a reader can be preempted by a writer, but not the other way around. If a reader is preempted by a writer, the writer completes its update, and the reader resumes and detects the change. That is safe. If a writer is preempted by a reader, the reader sees an odd counter and retries. If the reader is on the same CPU as the writer, the writer cannot run while the reader is running. The reader will spin forever. This is a deadlock.

This situation occurs when the reader runs in an interrupt handler or a higher-priority context that can preempt the writer. For example, a writer is updating a seqlock in process context. An interrupt occurs. The interrupt handler reads the same seqlock. It sees the odd counter and retries. The writer cannot resume because the interrupt handler is running on the same CPU. The interrupt handler spins forever. The system hangs.

The solution is the latch variant. The writer sets a latch before incrementing the counter. The reader checks the latch. If the latch is set, the reader knows that a writer is in progress on the same CPU or in a context that cannot be preempted. The reader must not spin. It can take a different path, such as acquiring a lock, or it can return a failure indication. In the Linux kernel, the `seqcount_latch_t` type provides this behavior for NMI readers. The writer updates two copies of the data and a latch, and the reader reads the latch to choose which copy to read. This allows the reader to avoid spinning even if the writer is interrupted.

Another solution is to disable interrupts or preemption on the writer side. If the writer disables interrupts while the counter is odd, then an interrupt handler cannot run and see the odd counter. The writer can complete its update without interference. This is what `write_seqlock_irqsave()` does. It disables interrupts, takes the spinlock, and increments the counter. The reader in interrupt context will either see an even counter or will not run because interrupts are disabled. This is simpler than the latch variant, but it increases interrupt latency. The latch variant is preferred when the writer's critical section is long or when interrupt latency is a concern.

## The Counter's Width and Wrap

The counter in a seqlock is typically a 32-bit unsigned integer. It is incremented twice per write. The reader compares the full counter value, not just its parity. If the counter wraps around to the same value during the reader's window, the reader may accept a torn snapshot. The probability of this happening is extremely low, but it is not zero.

For the counter to wrap, the reader's window must span exactly `2^31` writer updates. If the writer updates at 1 million writes per second, `2^31` writes take about 2147 seconds, or about 36 minutes. A reader would have to be preempted for 36 minutes between the initial and final counter loads. In a kernel, a reader can be preempted if `CONFIG_PREEMPT` is enabled, but being preempted for 36 minutes is unlikely. If the writer updates at 1 billion writes per second, `2^31` writes take about 2.1 seconds. A reader preempted for 2 seconds could see a wrap. This is why some systems use a 64-bit counter. On a 64-bit machine, a 64-bit counter is effectively impossible to wrap. On a 32-bit machine, a 64-bit counter cannot be read atomically with a single load, so a seqlock with a 64-bit counter would need two loads and two comparisons. That is more complex and slower.

The Linux kernel uses a 32-bit `seqcount_t`. The kernel documentation notes that the counter can wrap, but the window is so small that it is not a practical concern. The kernel also disables preemption in some seqlock read paths to prevent the reader from being preempted for a long time. If you are implementing a seqlock in userspace, consider whether a 32-bit counter is sufficient for your write rate and preemption model. If not, use a 64-bit counter and accept the extra cost.

## Common Anti-Patterns and How They Fail

The most common anti-pattern is using a seqlock to protect a pointer to dynamically allocated data. The reader reads the pointer, validates the counter, and then dereferences the pointer. But the writer may have freed the old data after the reader's validation. The reader then dereferences a dangling pointer. A seqlock does not manage object lifetime. If the payload is a pointer, the writer must not free the old object until it is sure no reader holds a reference. That requires RCU or a reference count. A seqlock alone cannot do it.

Another anti-pattern is using a seqlock with multiple writers. The counter increment is not atomic. If two writers increment the counter concurrently, the counter may become odd and then even without the payload being fully written. A reader can then validate a torn snapshot. The seqlock requires that writers are serialized by an external lock. The `seqlock_t` type includes a spinlock for this purpose. If you use `seqcount_t`, you must provide your own serialization.

A third anti-pattern is performing side effects in the reader. The reader's body may execute multiple times. If it increments a counter, appends to a buffer, or updates a cache, those side effects will be duplicated. The reader must be idempotent. It must only read and compute. It must not modify any shared state. Even a store to a local variable is fine, but a store to a global variable is not.

A fourth anti-pattern is sleeping in the reader. The reader must not block, sleep, or fault. If it does, the writer may be blocked, or the reader may deadlock. In a kernel, sleeping in a seqlock read path is a bug. The reader must be atomic. The same applies to taking a lock that a writer might hold. If the reader takes a lock that the writer needs, and the reader is in an interrupt context, the writer cannot run, and the reader spins forever.

A fifth anti-pattern is using a seqlock for a large payload. The reader's window is proportional to the payload size. A large payload means a long window, which increases the retry probability. It also means more cache misses. If the payload is larger than a few cache lines, consider RCU or a different mechanism.

A sixth anti-pattern is using `volatile` instead of `READ_ONCE` and `WRITE_ONCE`. `volatile` prevents some compiler optimizations, but it does not provide the same ordering guarantees as `READ_ONCE` and `WRITE_ONCE`. It also does not prevent the compiler from reordering accesses across barriers. The Linux kernel uses `READ_ONCE` and `WRITE_ONCE` for a reason. They are necessary for correctness.

## Testing and Validation

Testing a seqlock is challenging because the bugs are timing-dependent. A stress test with random delays can often expose issues. The test should have multiple readers and a single writer. The writer should update the payload in a way that makes torn reads detectable. For example, the payload can contain two fields that are always equal. The reader checks that they are equal. If a torn read occurs, the fields will differ. The test should run for a long time and with many iterations. It should also vary the write rate and the reader's window.

Formal validation is possible with litmus tests. The Linux kernel's memory model tools include litmus tests for seqlocks. These tests can be run with `herd7` to check the memory ordering. They can also be run with `klitmus` on real hardware. A litmus test for a seqlock would define the reader and writer as small programs and check that the reader never observes a torn snapshot. This is a powerful way to validate the barrier placement.

Dynamic analysis tools can also help. The Linux kernel's KCSAN (Kernel Concurrency Sanitizer) can detect data races, but seqlocks are intentionally racy. KCSAN has annotations for seqlocks, such as `kcsan_flat_atomic_begin` and `kcsan_flat_atomic_end`, which tell the tool to ignore the racy accesses. Without these annotations, KCSAN will report false positives. The `lockdep` tool can detect lock ordering issues, but it does not understand seqlocks. The `CONFIG_DEBUG_ATOMIC_SLEEP` option can detect sleeping in atomic context, which is useful for catching readers that sleep. The `CONFIG_DEBUG_PREEMPT` option can detect preemption in atomic context. These tools are not a substitute for careful reasoning, but they can catch common mistakes.

## The Shape of the API and Where It Leads

The seqlock API is usually split into two functions: `read_seqbegin()` and `read_seqretry()`. The first function returns the sequence number. The second function checks whether the sequence number is still valid. This split allows the caller to perform the read between the two calls. The caller must not return early from the read path. The caller must not perform side effects. The caller must not sleep. The API is deliberately low-level because the compiler cannot verify these constraints.

Some libraries provide a callback-based API: `seqlock_read(seqlock, callback, arg)`. The callback is invoked with the payload. If the callback returns a value, the seqlock read function retries until the callback succeeds. This is more convenient, but it has the same constraints. The callback must be idempotent and must not sleep. The callback may be called multiple times. The callback must not capture state that persists across calls.

The `read_seqbegin_or_lock()` function is a hybrid. It tries the optimistic read first. If the read fails, it falls back to acquiring a lock. This is useful when the reader cannot retry indefinitely. For example, a reader in a context where retries are expensive or where the write rate is high. The function returns a sequence number and a flag indicating whether the lock was acquired. The caller must call `read_seqretry_or_unlock()` to release the lock if it was acquired. This API is more complex but more flexible.

The API shape reflects the fundamental trade-off. A seqlock is not a lock. It is a versioned read protocol. The API must expose the version number and the retry check. It cannot hide them behind a lock-like interface without losing the ability to retry. The caller must be aware of the retry loop. This is why seqlocks are not a drop-in replacement for reader-writer locks. They are a different abstraction, and they require a different mental model.

## Seqlocks vs. Double Buffering and RCU

Double buffering is another way to provide a consistent snapshot without locks. The writer writes to an inactive buffer, then atomically flips a pointer. The reader reads the pointer once and then reads the buffer. The reader never retries. The writer never blocks. The cost is that the writer needs two buffers, and the reader must ensure that the buffer it is reading is not freed while it is in use. This is usually done with a reference count or RCU. Double buffering is better than a seqlock when the payload is large and the reader's window is long. It is worse when the payload is small, because the pointer flip and the buffer management add overhead. A seqlock is a better fit for small, fixed-size payloads.

RCU is a more general mechanism. RCU readers can traverse linked structures, can sleep, and can hold references across context switches. RCU writers defer reclamation of old versions until all pre-existing readers have finished. RCU does not require the reader to retry. However, RCU requires a grace period mechanism, which can be complex. RCU is better for pointer-based structures and for readers that need to sleep. Seqlocks are better for small, fixed-size payloads where the reader's window is short and the writer is rare. The two mechanisms are complementary. Some kernel subsystems use both, depending on the data structure.

## The Limits of Optimism

A seqlock is an optimistic protocol. It assumes that the reader will not collide with a writer. When that assumption holds, the reader is extremely fast. When it fails, the reader retries. The retry is cheap if collisions are rare. If collisions are frequent, the reader can livelock. The writer is never blocked, but the reader can starve. This is the opposite of a reader-writer lock, where the writer can starve. The choice between the two depends on which starvation is more acceptable.

The seqlock is not a general-purpose synchronization primitive. It is a specialized tool for a specific access pattern: read-mostly, small payload, single writer, short reader, no side effects, no blocking. If any of these conditions is violated, a different mechanism is likely better. The counter is not a lock. It is a version number and a write-in-progress flag. The barriers are the contract. The retry loop is the price. Understanding that contract is the key to using seqlocks correctly.

## Case Study: Timekeeping's Sequence Counter

The Linux timekeeping subsystem is one of the clearest real-world examples of a seqlock-shaped problem. Every call to `clock_gettime()`, every timestamp in a trace event, every packet timestamp, and every scheduler tick needs a consistent view of the current time. The data that defines that view is a structure — the timekeeper — containing a base offset, a multiplier and shift for converting clocksource cycles to nanoseconds, NTP correction terms, and a pointer to the active clocksource. The structure is updated when the tick advances, when NTP adjusts the clock, when the clocksource is switched, and when the system suspends or resumes. Those updates happen at rates measured in hertz. The reads happen at rates measured in millions per second.

The timekeeper is protected by a sequence counter, not by a reader-writer lock. A reader begins a sequence read, copies the fields it needs, and then validates the counter. If a writer updated the timekeeper during the copy, the reader retries. The writer holds a raw spinlock to serialize updates and increments the sequence counter around its stores. The reader never takes that spinlock. It never writes to the timekeeper. It never blocks.

This design is forced by context. Some timekeeping readers run in NMI handlers, where taking any lock is impossible. The NMI-safe clock read path cannot sleep, cannot acquire a spinlock that might be held by an interrupted writer, and cannot afford to be preempted. A seqlock read is the only viable option: it is a handful of loads, a few arithmetic operations, and a counter validation. If the validation fails, the reader retries. In an NMI, a retry is still safe as long as the writer is not the interrupted context. The timekeeping writer disables interrupts while the counter is odd, which prevents that inversion.

The timekeeper payload is larger than the tiny structs usually associated with seqlocks. A reader may copy several fields, perform a multiply and shift, and add an offset. The reader's window is therefore longer than a few instructions. That would be a problem if writes were frequent. But the write rate is low — one update per tick, plus occasional NTP corrections — so the probability that a reader overlaps a writer is tiny. The seqlock's retry cost is paid only when the tick and the read collide, and even then the retry is cheap compared with the cost of a lock acquisition on every read.

The counter here is not a lock in any meaningful sense. It is a version number for the current time. A reader that successfully validates the counter has a snapshot of the timekeeper that corresponds to some instant. It does not hold anything. It does not prevent the next tick from updating the timekeeper. It does not need to release anything. The writer does not wait for readers to drain. This is exactly the property that makes seqlocks suitable for timekeeping: the read path must be invisible to the write path, and the write path must be able to proceed even if a reader is in an NMI.

## Case Study: Directory Entry Revalidation

The dentry cache provides a second instructive example. A directory entry in a filesystem cache contains a name, a parent pointer, and a pointer to the inode. Path lookup walks these entries, reading the name and following the parent pointer. Concurrently, a rename operation can change the name or parent of an entry. A lookup that reads a stale parent or a half-updated name can construct a path that never existed.

Linux protects the linkage fields of a dentry with `d_seq`, a sequence counter. A path walk reads the parent and name under a sequence read. If a rename occurs during the walk, the sequence validation fails and the walk retries. The rename writer holds the dentry's spinlock and updates the sequence counter around the linkage changes. The reader does not take that spinlock. It does not take a reference on the dentry solely to read the linkage; the reference is managed separately. The seqlock protects consistency of the linkage, not the lifetime of the objects involved.

That separation is important. The reader may be inside an RCU read-side critical section, which keeps the dentry from being freed while the walk is in progress. The seqlock ensures that the parent and name are a consistent pair. RCU ensures that the memory holding the dentry is not reused. Neither mechanism alone is sufficient. A seqlock cannot manage object lifetime, and RCU alone does not give a consistent snapshot of two fields that are updated together. The combination is what makes lockless path lookup possible.

The writer side is also more complex than the minimal seqlock. A rename may need to update several dentries, and those updates must be serialized. The dentry spinlock provides that serialization. The sequence counter is incremented around each logical update. Readers that overlap any of those updates will retry. The counter is not a lock; it is a version stamp on the parent-and-name pair. The spinlock is the lock. Confusing the two would lead to exactly the multiple-writer bug described earlier.

## Seqlocks Under the C11 and C++ Memory Models

Implementing a seqlock in portable C11 or C++11 is more subtle than the kernel examples suggest. The kernel has `READ_ONCE()` and `WRITE_ONCE()`, which are compiler barriers that also prevent speculative loads and store tearing. It has `smp_rmb()` and `smp_wmb()`, which map to the architecture's one-way barriers. The C11 and C++ memory models do not provide those exact primitives. They provide atomic operations and fences, and they define data races as undefined behavior.

That last point is the crux. If the writer performs plain stores to the payload while a reader performs plain loads, the program has a data race unless those accesses are synchronized. A seqlock does not synchronize them in the C11 sense; it detects races and retries. The C11 standard does not have a concept of a benign data race. A conforming implementation is allowed to assume that no data race occurs and to optimize accordingly. Therefore, a portable seqlock cannot use ordinary non-atomic loads and stores for the payload while another thread may be writing it.

There are two common ways out. The first is to make every payload field an atomic type with relaxed ordering. The writer uses relaxed atomic stores, and the reader uses relaxed atomic loads. The sequence counter itself is also atomic. The fences provide the ordering. This is correct under the C11 memory model, but it can be slower than the kernel implementation because every payload access becomes an atomic operation. On many architectures, a relaxed atomic load or store compiles to the same instruction as a plain load or store, so the overhead may be zero. On others, it may inhibit optimizations or generate extra instructions.

The second approach is to use compiler-specific extensions. GCC and Clang provide `__atomic_load_n()` and `__atomic_store_n()` with `__ATOMIC_RELAXED`, as well as `__atomic_thread_fence()`. These map closely to the kernel's primitives. A seqlock built on these extensions can use relaxed atomic accesses for the payload and acquire-release fences for the ordering. This is not portable to compilers that lack the extensions, but it is the practical choice for systems code.

The fence placement in C11 terms is worth stating precisely. The writer stores an odd value to the sequence counter with relaxed ordering. It then issues an atomic thread fence with release semantics. It performs the payload stores with relaxed ordering. It issues another release fence. It stores the even sequence value with relaxed ordering. The reader loads the sequence counter with relaxed ordering, issues an acquire fence, loads the payload with relaxed ordering, issues another acquire fence, and then loads the sequence counter again for validation. The acquire and release fences are the C11 equivalents of the one-way barriers. They do not provide store-load ordering, which is exactly what the seqlock does not need.

C++20 adds `std::atomic_ref`, which allows an existing non-atomic object to be accessed atomically for a bounded lifetime. A seqlock could use `atomic_ref` on the payload fields during the read and write windows, while leaving the fields as ordinary data outside those windows. This is a cleaner expression of the intent, but it still requires that no non-atomic access overlaps the atomic window. The seqlock's retry loop means that a reader may access the payload multiple times, so the atomic window must cover the entire loop. The standard library does not provide a seqlock type, and it is unlikely to, because the correct usage depends on constraints — no side effects, no blocking, single writer — that a library type cannot enforce.

## Optimistic Concurrency Control and the Version Validation Pattern

A seqlock is a specialized form of optimistic concurrency control. In a database, optimistic concurrency control lets a transaction read data without locking it, then validate at commit time that the data has not changed. If the validation fails, the transaction aborts and retries. A seqlock does the same thing at the granularity of a single read: it reads the payload without locking, validates the version counter, and retries if the version changed.

The sequence counter is the version number. Its parity is a write-in-progress flag. The reader's retry loop is the abort-and-retry path. The payload is the data item. The writer is the transaction that commits a new version. The analogy is not perfect — a seqlock has no commit log, no rollback, and no isolation between multiple data items — but it clarifies the design.

In optimistic concurrency control, the version number must be wide enough to avoid the ABA problem. If the version wraps around to the same value, a transaction may validate successfully even though the data changed and changed back. A seqlock has the same hazard. The counter is usually 32 bits and incremented twice per write. A reader whose window spans exactly 2^31 writes would see the same even value and accept a torn snapshot. The probability is negligible in practice, but the hazard is real. Systems that cannot tolerate it use a 64-bit counter or disable preemption to bound the reader's window.

The optimistic model also explains why the reader's body must be idempotent. In a database, a transaction that aborts may be retried, so its effects must not be partially committed. In a seqlock, the reader's body may execute multiple times, so any side effect would be duplicated. The reader must be a pure function of the payload and its own local state. It may compute, compare, and copy into local variables. It must not mutate shared state, because a failed attempt's mutations cannot be undone.

Finally, the optimistic model makes clear what the seqlock does not provide. It does not provide mutual exclusion, because there is no ownership. It does not provide serializability across multiple seqlocks, because each counter is independent. It does not provide durability or ordering guarantees beyond the snapshot. It provides exactly one thing: a consistent view of a single payload at some instant, with a retry if a writer interferes. That is a narrow guarantee, but for read-mostly state on the hot path, it is often the only guarantee that can be afforded.
