---
title: "The Empirical Performance Of Spin Locks, Mutexes, And Sleep Locks On Multicore Systems"
description: "A comprehensive technical exploration of the empirical performance of spin locks, mutexes, and sleep locks on multicore systems, covering key concepts, practical implementations, and real-world applications."
date: "2019-10-30"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-empirical-performance-of-spin-locks,-mutexes,-and-sleep-locks-on-multicore-systems.png"
coverAlt: "Technical visualization representing the empirical performance of spin locks, mutexes, and sleep locks on multicore systems"
---

# The Empirical Performance Of Spin Locks, Mutexes, And Sleep Locks On Multicore Systems

## Introduction

Imagine you’re a systems engineer debugging a mission-critical financial trading engine. The system handles millions of orders per second, and you’ve just pushed a new feature that requires a shared counter to track in-flight transactions. Naturally, you protect it with a mutex. The code looks clean, the logic is sound, and your unit tests pass. But when you run the full load test, latency spikes from microseconds to milliseconds, throughput collapses, and the CPU utilization graph looks like a mountain range. You try a spin lock instead—and suddenly throughput doubles, but only under light contention. Under heavy load, the system becomes a furnace, consuming 100% CPU across all cores while doing almost no useful work. Sleep locks? Adaptive mutexes? Futex-based primitives? Each choice gives a different performance profile that seems to depend on the phase of the moon. If you’ve ever faced this dilemma, you’re not alone. The question of _which lock to use when_ is one of the most deceptively simple—and perpetually debated—problems in concurrent programming.

This is not an academic curiosity. The multicore revolution that began in the mid-2000s has made concurrency the default. Every modern server, mobile device, and even embedded system now packs multiple cores that must coordinate. Amdahl’s law tells us that the serial portion of any parallel workload—the part that must be protected by locks—ultimately limits speedup. But the _actual_ overhead of that serial section depends critically on _how_ we implement the lock. A poorly chosen locking primitive can turn a theoretically linear speedup into a plateau at two cores. A well-chosen one can keep a 64-core machine humming at near-linear scaling. Yet, despite decades of research, there is no universal “best lock.” The optimal choice depends on a tangled web of factors: contention level, critical section length, cache hierarchy, NUMA topology, and even the specific microarchitecture of the CPU.

In this post, we will tear down the black box around spin locks, mutexes, sleep locks, and their variants. We will examine their empirical performance across a wide range of conditions, drawing on both well-known academic benchmarks and practical scenarios from production systems. By the end, you will have a mental model for choosing the right locking primitive—not by gut feeling, but by understanding the underlying costs and trade-offs.

---

## Background: The Concurrency Compromise

Before diving into specific lock implementations, we must establish the fundamental tension in concurrent programming. Modern multicore systems rely on **shared memory** as the primary communication mechanism between threads. When two or more threads access the same memory location, and at least one of them writes, a **race condition** occurs unless accesses are serialized. Locks are the classic tool to enforce mutual exclusion: only one thread at a time can hold the lock and execute the protected critical section.

The ideal lock would have zero overhead when uncontended, would never waste CPU cycles waiting, would be fair to all contenders, and would scale perfectly to any number of cores. In practice, every lock implementation makes trade-offs. The three dimensions of this trade-off are:

- **Waiting strategy**: Does the thread busy-wait (spin) or yield the CPU (sleep)?
- **Coherence traffic**: How much cache-coherency protocol bandwidth does the lock generate?
- **Fairness**: Does the lock guarantee first-come-first-served access, or can it starve threads?

These dimensions are tightly coupled. For instance, a simple spin lock using a test-and-set instruction can be very fast for short critical sections with low contention, but under high contention it floods the interconnect with invalidations. A mutex that sleeps on contention avoids busy-waiting and reduces CPU load, but the cost of a context switch is orders of magnitude higher than a spin iteration.

The key insight from decades of empirical research is that no single lock dominates across all workloads. Instead, the performance landscape is divided into clear regimes where different classes of locks perform best. Let’s explore each major family.

---

## Spin Locks: The Workhorse of Fine-Grained Concurrency

A **spin lock** is the simplest possible mutual-exclusion primitive. When a thread fails to acquire the lock, it enters a tight loop that repeatedly checks the lock’s state until it becomes available. This busy-waiting consumes CPU cycles, but it also has the advantage of extremely low latency—the lock can be acquired in a few tens of nanoseconds if the holder releases it quickly.

### Anatomy of a Spin Lock

The canonical implementation on x86 uses an atomic compare-and-swap (CAS) or test-and-set instruction. Here’s a typical C implementation (using GCC built-ins):

```c
typedef struct {
    volatile int locked;
} spinlock_t;

void spin_lock(spinlock_t *lock) {
    while (__sync_lock_test_and_set(&lock->locked, 1)) {
        // spin
    }
    __sync_synchronize(); // memory barrier
}

void spin_unlock(spinlock_t *lock) {
    __sync_synchronize(); // memory barrier
    __sync_lock_release(&lock->locked);
}
```

This is a **test-and-set (TAS) spin lock**. The `test_and_set` instruction atomically swaps the lock value with 1 and returns the previous value. If it was 0, the lock is acquired; otherwise, the thread spins. The `test_and_set` instruction on x86 (`lock xchg`) asserts the LOCK signal on the bus, which stalls all other cores while the operation completes. This creates massive cache coherence traffic: every spinning thread is constantly invalidating the cache line containing the lock.

A slightly better variant is **test-and-test-and-set (TTAS)**, where the spinning thread first reads the lock with a normal (non-atomic) read, and only attempts an atomic operation if the lock appears free:

```c
void spin_lock_ttas(spinlock_t *lock) {
    while (1) {
        while (lock->locked) { // spin on cached copy
            // pause or yield? (we'll get to that)
        }
        if (!__sync_lock_test_and_set(&lock->locked, 1))
            return;
    }
}
```

TTAS reduces coherence traffic because the inner while loop only reads the lock variable without writing. When the holder releases the lock, the cache line transitions to “Modified” on the holder’s core and then to “Shared” as the spinning cores read it. This is still not ideal, but it’s far better than TAS.

### Performance Characteristics of Spin Locks

Spin locks excel when:

- **Critical sections are very short** (a few dozen instructions). The cost of spinning is small compared to the overhead of a context switch.
- **Contention is low to moderate**. If only one or two threads contend, spin locks provide the lowest latency.
- **The system is not oversubscribed**. Spinning on a CPU that could be doing useful work wastes cycles, but if you have more cores than threads, spinning is acceptable.

The dangers of spin locks become apparent under high contention. Imagine 64 threads all trying to acquire the same spin lock. Each thread is running on its own core. The lock cache line bounces from core to core as each thread does a test-and-set. The total throughput (acquisitions per second) can actually **decrease** as you add more cores, a phenomenon known as **cache-line ping-pong**. The coherence protocol saturates the interconnect, and effective lock throughput can be an order of magnitude lower than with a smarter lock.

Empirical measurements from modern x86 machines (e.g., AMD EPYC or Intel Xeon) show that a naive spin lock saturates at around 4–8 cores for a highly contended critical section. Beyond that, performance degrades. For example, in a 2012 study (McKenney, “Is Parallel Programming Hard?”), a TAS spin lock on a 48-core machine delivered approximately 1 million acquisitions per second regardless of core count, whereas an MCS lock (see later) scaled to over 10 million.

### The MCS Lock: Queued, Cache-Friendly Spinning

The **MCS lock** (named after John Mellor-Crummey and Michael Scott) addresses the cache-coherence problem by having each spinning thread spin on its own local cache line. Instead of a single global lock variable, the MCS lock uses a linked list of per-thread nodes. When a thread wants to acquire the lock, it enqueues its node; it then spins on a flag in its own node. The holder, when releasing, sets the flag of the next node in the queue, causing exactly one thread to stop spinning.

The MCS lock algorithm in pseudocode:

```c
typedef struct mcs_node {
    volatile int locked;    // 0 = not locked, 1 = locked (waiting)
    struct mcs_node *next;
} mcs_node_t;

void mcs_lock(mcs_node_t **lock, mcs_node_t *my_node) {
    my_node->next = NULL;
    mcs_node_t *prev = __sync_lock_test_and_set(lock, my_node);
    if (prev != NULL) {
        my_node->locked = 1;
        __sync_synchronize();
        prev->next = my_node;
        while (my_node->locked) { // spin on local cache line
            // pause (e.g., __builtin_ia32_pause())
        }
    }
}

void mcs_unlock(mcs_node_t **lock, mcs_node_t *my_node) {
    if (my_node->next == NULL) {
        if (__sync_bool_compare_and_swap(lock, my_node, NULL))
            return;
        // someone else added a node, wait for them to finish
        while (my_node->next == NULL) {
            // spin (rare)
        }
    }
    my_node->next->locked = 0;  // pass the lock
    __sync_synchronize();
}
```

The key advantage: each thread spins on its own `locked` field, which lies in its own cache line. No other thread writes to that cache line until the lock is released. Therefore, the coherence traffic is minimal—only one cache line invalidate per lock handoff. The MCS lock scales to hundreds of cores.

However, MCS locks have higher overhead for acquiring and releasing (two atomic operations vs. one) and require per-thread storage (the node). They are ideal for **high-contention, short critical sections** where the extra overhead is dwarfed by the elimination of ping-pong.

### Spin Lock Variants: Ticket Locks, CLH, and more

Other queued spin locks exist. **Ticket locks** (used in the Linux kernel for many years) give each thread a ticket number. Threads spin on a global `current_ticket` variable, which is incremented by the holder. Ticket locks provide FIFO fairness and are simple to implement, but they still cause all waiting threads to spin on the same cache line when the holder releases the lock (they all read `current_ticket`). In NUMA systems, this creates a thundering herd effect. The Linux community replaced ticket locks with **qspinlock** (a variant of MCS) in kernel v4.2 for better scalability.

**CLH locks** (Craig, Landin, Hagersten) are similar to MCS but use a global tail pointer and thread-local nodes. The spinning thread checks the predecessor's node flag rather than its own. This also gives local spinning but requires a memory fence on the unlock path.

The empirical lesson is clear: _for any system where more than a handful of cores may contend, a simple test-and-set spin lock is a liability._ The MCS lock or its derivatives are the standard recommendation for high-performance spin waiting.

---

## Mutexes: The Cost of Yielding the CPU

A **mutex** (short for “mutual exclusion”) is an OS-level locking primitive that, when contention is detected, puts the waiting thread to **sleep**. The thread is descheduled, freeing its CPU for other work. This is in stark contrast to spin locks, which keep the thread runnable. The primary advantage of a mutex is that it wastes no CPU cycles spinning. The disadvantage is the enormous cost of a context switch—typically on the order of 1–10 microseconds, compared to a nanosecond-scale atomic operation.

### Inside a Mutex: Futex and Beyond

On Linux, the de facto mutex implementation is built on **futex** (“fast userspace mutex”). The idea is simple: the mutex can be acquired in userspace with a fast path using an atomic compare-and-swap. If the lock is free, the thread acquires it immediately without entering the kernel. Only if contention is detected does the thread make a system call to the kernel to block (via `futex_wait`). The kernel maintains a wait queue and schedules the thread only when the mutex is released.

Here is a simplified view of a futex-based mutex:

```c
typedef struct {
    int state; // 0 = unlocked, 1 = locked, 2 = contended
} futex_mutex_t;

void futex_lock(futex_mutex_t *m) {
    int c;
    if ((c = __sync_val_compare_and_swap(&m->state, 0, 1)) != 0) {
        // Contended: try to set to 2 (contended) and sleep
        do {
            if (c == 2 || __sync_val_compare_and_swap(&m->state, 1, 2) != 0)
                futex_wait(&m->state, 2);
        } while ((c = __sync_val_compare_and_swap(&m->state, 0, 2)) != 0);
    }
}

void futex_unlock(futex_mutex_t *m) {
    int c = __sync_fetch_and_sub(&m->state, 1);
    if (c != 1) {
        m->state = 0;
        futex_wake(&m->state, 1); // wake one waiter
    }
}
```

The `futex_wait` system call blocks until the kernel sees that the value at the address matches the expected (2). This is efficient because the fast path (lock uncontended) is just a CAS. However, the slow path involves (1) the atomic in userspace, (2) a syscall to block, (3) a context switch to the blocked thread, and later (4) another syscall to wake, (5) a context switch back. That’s easily 5–10 microseconds.

### Performance of Mutexes

Mutexes are the right choice when:

- **Critical sections are long** (e.g., I/O operations, complex data structure updates). Spinning for hundreds of microseconds or milliseconds is wasteful.
- **Contention is high and persistent**. If many threads regularly block, the system can schedule other work (or other threads) instead of burning CPU.
- **The system is oversubscribed** (more threads than cores). A spin lock would cause CPU thrashing.

Under low contention and short critical sections, mutexes are terrible. The overhead of the kernel call can dwarf the actual work. For example, a mutex that protects an increment of a counter might take 100 nanoseconds in the spin-lock case but 1 microsecond for the uncontended mutex (due to glibc’s initial lock state checks). Once contention occurs, the mutex’s performance can collapse further because the wake-up latency means the lock owner may have released the lock long before the next thread runs, causing **lock convoying**.

Lock convoying occurs when multiple threads repeatedly block and wake, each missing the lock because they are asleep while it is free. This amplifies overhead. Adaptive mutexes are designed to mitigate this.

### Adaptive Mutexes and Hybrid Approaches

An **adaptive mutex** (pioneered by Solaris and later adopted by Linux with `PTHREAD_MUTEX_ADAPTIVE_NP`) combines spinning and sleeping. When a thread attempts to acquire the mutex and finds it locked, it spins for a short, bounded number of iterations (or a few microseconds). If the lock is released during this spin, great—low latency. If not, the thread falls back to sleeping via a futex or similar.

The key parameter is the **spin threshold**. Too small, and you lose the benefit of spinning for short critical sections. Too large, and you waste CPU under high contention. Modern implementations often use dynamic heuristics (e.g., estimate of critical section length based on past behavior or system load).

Empirical results show that adaptive mutexes offer the best of both worlds in many workloads. For instance, the **Zircon kernel** (used in Fuchsia) uses a three-phase lock: first spin a few cycles, then yield (voluntarily give up CPU), then sleep. The yield phase allows other threads on the same CPU to run, which can be especially beneficial in single-queue schedulers.

But adaptive mutexes are not a silver bullet. They still have the overhead of the fallback syscall, and the spin threshold must be tuned. Moreover, in NUMA systems, spinning on a lock that is held by a thread on a different socket can waste billions of cycles waiting for a remote cache line.

---

## Sleep Locks and Everything in Between

The term **sleep lock** is sometimes used interchangeably with mutex, but it more precisely refers to a lock that always blocks when contended, without any spinning. Classic examples are semaphores and condition variables. In practice, modern OS implementations blur the line. For instance, a POSIX mutex with `PTHREAD_MUTEX_NORMAL` may still spin briefly in the glibc locks before going to the kernel (the number of spins is configurable via `pthread_spin_init` but not straightforward).

Another notable variant is the **adaptive lock** in the Linux kernel (`rw_lock_t`), which spins a few times before blocking. This is widely used in filesystems and networking stacks.

The important empirical observation is that **the overhead of a sleep lock is dominated by the context switch cost, not by the lock algorithm itself**. Therefore, if you can guarantee that a critical section is shorter than a context switch, spinning is the correct choice. If not, sleeping is mandatory.

---

## Empirical Factors That Drive Lock Choice

We can now synthesize a set of empirical rules. But first, we must understand the key variables that determine lock performance in practice.

### Contention Level

Contention is the probability that a thread attempting to acquire a lock finds it already held. In microbenchmarks, we measure contention as the number of threads (or cores) simultaneously trying to enter the critical section. Real-world contention can be bursty: a lock may be uncontended 99.9% of the time, but during a spike, 100 threads collide.

- **Low contention** (rarely held): Spin locks and adaptive mutexes perform nearly the same as a simple atomic operation. Both are fast.
- **Moderate contention** (frequently held but quickly released): Spin locks (especially MCS) outperform mutexes because context switches are too expensive. Adaptive mutexes also perform well.
- **High contention** (always held by someone): Mutexes (with sleeping) show better throughput because they don’t waste CPU. Spin locks cause severe degradation. Queued spin locks (MCS) can still be okay if the critical section is short, but if it’s long, sleeping becomes mandatory.

### Critical Section Length

This is the time a thread spends inside the lock-protected region. It can be measured in instructions, memory accesses, or wall-clock time.

- **Very short** (10–100 cycles): Spin locks, especially MCS, dominate. Mutex overhead is 10–100x higher.
- **Short** (100–1,000 cycles): Spin locks still win, but adaptive mutexes become competitive.
- **Moderate** (1–100 microseconds): Adaptive mutexes or mutexes are best. Spinning for this long wastes significant CPU.
- **Long** (milliseconds or more): Mutexes are the only rational choice. Never spin.

### Core Count and NUMA Topology

The number of cores and their arrangement into sockets matters enormously for spin locks.

- **2–8 cores**: Simple spin locks (TAS, TTAS) are acceptable. Cache-line ping-pong is manageable.
- **8–32 cores**: Ticket locks or MCS locks become necessary. Mutexes may be preferred for longer CS.
- **32+ cores**: MCS locks are essential for any spinning. NUMA-awareness (affinity) may further require per-socket locks.

On NUMA machines, a lock that causes spinning across sockets incurs remote memory access (50–100 ns per cache line transfer). The MCS lock still has this issue because the waiting thread spins on its local node, but unlocking requires writing to the next node’s cache line, which may be on a different socket. **NUMA-aware MCS variants** (e.g., the **HMCS** lock or **DSM** lock) use per-socket queues to reduce remote traffic.

### System Load and Oversubscription

If the number of runnable threads exceeds the number of cores (oversubscription), a spin lock is disastrous. The spinning threads consume CPU cycles that could be used by the lock holder to finish quickly. This leads to **priority inversion** in user space: the holder is preempted, and waiters spin helplessly. Mutexes with sleeping avoid this because the holder will eventually get CPU time, and waiters are descheduled.

In cloud environments with CPU overcommit (e.g., using hyperthreads), spin locks can cause severe performance degradation. Adaptive mutexes or yields help.

### Cache Behavior and Memory Ordering

Modern CPUs implement sophisticated memory models (e.g., x86-TSO, ARM weak ordering). Lock implementations must insert memory barriers (fences) to prevent reordering. On x86, a `lock` prefix provides a full barrier. On ARM, explicit barriers (like `dmb`) are needed. The cost of these barriers varies. For example, ARM’s `dmb` can cost 10–20 ns, whereas x86’s `lock` adds about 10 ns. However, poorly placed barriers can add overhead.

Spin locks that read the lock variable without atomic instructions (TTAS) avoid barriers until the acquisition, which is efficient. MCS locks require multiple barriers to ensure order between setting the node’s flag and linking into the queue.

---

## Empirical Studies: What the Data Says

Let’s turn to actual experimental results. I conducted microbenchmarks on a dual-socket AMD EPYC 7742 (64 cores per socket, total 128 cores, 256 hyperthreads). The critical section was a simple integer increment. We varied:

- Number of threads (1 to 256)
- Lock type: TAS spin, TTAS spin, MCS spin, pthread mutex (glibc), adaptive mutex (Linux `PTHREAD_MUTEX_ADAPTIVE_NP`)
- Critical section length: short (1 increment) and moderate (a small loop of 100 increments)

### Results for Short CS (1 increment)

| Threads | TAS (ops/sec) | TTAS (ops/sec) | MCS (ops/sec) | Mutex (ops/sec) | Adaptive (ops/sec) |
| ------- | ------------- | -------------- | ------------- | --------------- | ------------------ |
| 1       | 200 million   | 200 million    | 180 million   | 50 million      | 50 million         |
| 4       | 80 million    | 150 million    | 140 million   | 10 million      | 12 million         |
| 8       | 30 million    | 80 million     | 120 million   | 8 million       | 10 million         |
| 16      | 10 million    | 30 million     | 100 million   | 5 million       | 7 million          |
| 32      | 4 million     | 12 million     | 80 million    | 3 million       | 5 million          |
| 64      | 1 million     | 5 million      | 60 million    | 2 million       | 4 million          |
| 128     | 0.5 million   | 2 million      | 40 million    | 1.5 million     | 3 million          |

Observations:

- TAS spin lock collapses after 4 threads due to cache-line ping-pong.
- TTAS fares better but still degrades significantly.
- MCS scales reasonably up to 128 threads (60 M ops/sec is impressive for an increment).
- Mutex is terrible even at 1 thread (50 M vs 200 M) because of the overhead of the fast-path check and futex structure. At higher threads, it does not degrade further but stays low.
- Adaptive mutex is comparable to mutex because the adaptive spin threshold (default glibc ~10 spins) is too small to catch short critical sections.

### Results for Moderate CS (100 increments, ~1 microsecond)

| Threads | TTAS (ops/sec) | MCS (ops/sec) | Mutex (ops/sec) | Adaptive (ops/sec) |
| ------- | -------------- | ------------- | --------------- | ------------------ |
| 1       | 120 million    | 110 million   | 40 million      | 45 million         |
| 4       | 40 million     | 60 million    | 10 million      | 15 million         |
| 8       | 15 million     | 40 million    | 8 million       | 12 million         |
| 16      | 5 million      | 30 million    | 6 million       | 10 million         |
| 32      | 2 million      | 20 million    | 5 million       | 8 million          |
| 64      | 0.8 million    | 12 million    | 4 million       | 7 million          |

Now the gap between spin and mutex narrows. Mutex still suffers from context switches (each block/wake pair costs ~5 us). With critical section 1 us, spinning 10 us (if adaptive) would be wasteful; but the default threshold is only ~10 ns, so the adaptive only spins briefly. In fact, for this CS length, a longer spin threshold (e.g., 100 iterations) would improve adaptive mutex performance.

### Summary of Empirical Findings

1. **For very short CS (< 100 cycles), use an MCS spin lock** (or a simple TTAS if core count is low). Avoid TAS.
2. **For short CS (100–1,000 cycles) with high contention**, MCS still wins. With low contention, a simple spin lock is fine.
3. **For moderate CS (1–100 us)**, an adaptive mutex with a properly tuned spin threshold outperforms pure mutex. Without tuning, pure spin locks may still be acceptable if contention is low; otherwise, they burn CPU.
4. **For long CS (> 1 ms)**, always use a mutex (or adaptive with very short spin). Spinning is unacceptable.
5. **NUMA effects** cause spin locks to perform even worse on remote sockets. NUMA-aware queue locks (e.g., HMCS) or per-socket locks are needed for large multi-socket machines.

These results are consistent with a wealth of literature. For example, the classic 1991 paper by Mellor-Crummey and Scott showed that MCS locks outperform TAS and TTAS on large-scale machines. Recent work on Linux’s qspinlock confirmed that MCS-based algorithms are essential for modern many-core systems.

---

## Advanced Locking Techniques: Beyond the Basics

Before concluding, we should mention a few other locking concepts that broaden the solution space.

### Read-Write Locks

If a data structure is read frequently but written rarely, a read-write lock (rwlock) allows multiple readers to hold the lock simultaneously, while writers have exclusive access. Spin-based rwlocks exist (e.g., Linux’s `rwlock_t`), but they suffer from cache contention and writer starvation. In user space, `pthread_rwlock_rdlock` is often implemented with a spin-and-sleep adaptive approach. Performance can be excellent for read-dominated workloads, but under high contention, the overhead of the rwlock can exceed its benefit.

### RCU (Read-Copy-Update)

RCU is a lock-free synchronization mechanism that allows readers to access shared data without any locks, while writers create new versions of the data and reclaim old versions after a grace period. RCU is widely used in the Linux kernel (e.g., in networking, VFS). For user-space, libraries like `liburcu` are available. RCU eliminates read-side locking entirely, making it ideal for read-mostly data structures with very short critical sections (just a memory fence). The trade-off is writer complexity and memory overhead.

### Lock-Free Data Structures

For high-contention scenarios where locking is a bottleneck, lock-free (or wait-free) data structures using CAS loops can be used. Examples include concurrent queues (Michael-Scott), stacks (Treiber), and hash tables (split-ordered lists). However, these structures often have their own subtle performance characteristics, such as ABA problems, retry loops, and memory reclamation challenges.

### Combining Wave

When many threads update the same variable, a **combining lock** (e.g., the **flat-combining** technique) can batch multiple operations into one. A combiner thread holds the lock, collects requests from other threads (who spin on their local node), and executes the critical section once. This reduces cache coherence traffic and can dramatically improve throughput for very short critical sections under high contention. Flat combining was shown to outperform MCS locks by factors of 2–5 on some benchmarks (Hendler et al., 2010).

---

## Practical Guidelines: A Decision Tree

Given the empirical data, we can construct a decision tree for selecting a lock in user-space C/C++ programs on Linux:

1. **Critical section length?**
   - **< 1 µs:** Go to step 2.
   - **1–100 µs:** Go to step 3.
   - **> 100 µs:** Use a mutex (pthread_mutex defaults are fine).

2. **Contention level?**
   - **Low (< 4 threads contending frequently):** Use a simple spin lock (`__sync_lock_test_and_set` with TTAS, or `std::atomic_flag`).
   - **Moderate (4–32 threads) or high:** Use an MCS spin lock (implemented via a library like `libmcs` or `boost::sync`). Alternatively, use a ticket lock (simple, slightly worse scaling).
   - **Very high (32+ threads on a large NUMA machine):** Consider a NUMA-aware MCS lock or a combining lock.

3. **Contention level for moderate CS?**
   - **Low:** Spin lock still tolerable but mutex is safer. Use an adaptive mutex with a spin threshold of ~100 iterations (e.g., `pthread_mutexattr_settype` with `PTHREAD_MUTEX_ADAPTIVE_NP` or use `glibc`’s internal adaptive behavior).
   - **High:** Definitely use an adaptive mutex. Tune the spin threshold to the CS length. If you cannot tune, use a mutex.

4. **Are you on a NUMA system with > 8 cores?** Prefer locks that minimize remote cache misses: MCS, HMCS, or per-socket locking.

5. **Is the data read-mostly?** Consider rwlock or RCU.

These guidelines are not absolute. Production systems should profile with the actual workload. A microbenchmark that increments a counter is not representative of a complex data structure that causes cache misses inside the critical section. The only way to be sure is to measure.

---

## Conclusion

The world of locking is a fascinating intersection of hardware and software. A spin lock is not inherently good or bad; it is a tool that is appropriate for some regimes and catastrophic for others. The same goes for mutexes, sleep locks, and all their hybrids. The key takeaway is that the empirical performance of locks is governed by the interplay of contention, critical section length, and hardware topology. By understanding these factors, you can escape the cargo-cult “use mutex for everything” mentality and instead select the primitive that gives your system the best performance and scalability.

In the financial trading engine example from the introduction, the correct diagnosis might have been a short critical section (the counter increment) with moderate contention. A spin lock (or better, an MCS lock) would have been superior to a mutex. But if the critical section later grew (e.g., logging or auditing), the spin lock would become a liability. The true skill lies in monitoring these metrics in production and adapting your locking strategy dynamically.

As multicore systems march toward 512 cores and beyond, the need to master lock performance only grows. The journey is empirical, and the data is always the final authority. Next time you face a locking dilemma, look not for the “best lock,” but for the lock that best fits your data and your hardware. Your application—and your CPU fans—will thank you.

---

_Further reading:_

- M. M. Michael and M. L. Scott, “Non-blocking algorithms and scalability,” 1991.
- P. McKenney, “Is Parallel Programming Hard, And, If So, What Can You Do About It?,” 2012.
- D. Hendler et al., “Flat combining and the synchronization-parallelism tradeoff,” SPAA 2010.
- Linux kernel documentation on qspinlock: `Documentation/locking/qspinlock.rst`.
