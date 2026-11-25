---
title: "Futexes From First Principles: Kernel Wait Queues, the Userspace Fast Path, and the Real Cost of Blocking"
description: "A deep dive into Linux futexes: the userspace/kernel contract, the atomic compare-and-sleep that closes the lost-wakeup race, the three-state lock word, and why the fast path never enters the kernel."
date: "2026-02-18"
author: "Leonardo Benicio"
tags: ["linux","concurrency","futex","synchronization","operating-systems","parallel-computing","systems-design"]
categories: ["Systems Programming","Concurrency"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/futexes-from-first-principles-kernel-wait-queues-the-userspace-fast-path-and-the-real-cost-of-blocki-2026-02-18.jpg"
coverAlt: "Isometric diagram of a userspace memory word connected by a beam to a kernel-side hash table of wait queues, with thread shapes queued in one highlighted bucket."
---

# Futexes From First Principles: Kernel Wait Queues, the Userspace Fast Path, and the Real Cost of Blocking

## The lock that costs nothing until it costs everything

Imagine a 64-core machine running a service with a thread pool of 64 workers. Each worker pulls a job from a shared queue, executes it, and comes back for more. The queue is protected by a mutex. Under light load the mutex is never contended: a worker takes it, splices a node, releases it. Under heavy load, all 64 workers converge on the same cache line at the same instant, and the mutex becomes the bottleneck for the entire service.

The interesting engineering question is not "how do we make the critical section shorter" — by the time you are reading this, that work is usually already done. The question is: *what should a thread do when it cannot acquire the lock?* There are only two honest answers, and both are bad on their own.

The first is to **spin**. The thread repeatedly executes an atomic read-modify-write on the lock word until it succeeds. This costs no kernel time and has a latency of a few nanoseconds when the lock is released quickly. But a spinning thread occupies a core, and — worse — it issues a stream of cache-line requests for the lock word. On a cache-coherent machine, a contended atomic RMW on a shared line is one of the most expensive things a core can do, because the line must be invalidated in every other core's cache and re-fetched. With 64 spinners, the coherence fabric becomes the bottleneck, and the thread *holding* the lock is slowed down by the very threads waiting for it. Spin locks do not scale by making waiting cheap; they scale by making the wait short, and that is an assumption about the workload, not a property of the lock.

The second is to **block**. A thread that blocks yields its core to other work, and the scheduler can run something useful. But a system call is not free: on a modern x86-64 machine, an uncontended `futex` syscall is on the order of a few hundred nanoseconds, and the context switch that follows costs more. If the lock is held for 50 nanoseconds, blocking is a catastrophic overreaction — you have paid thousands of cycles to avoid waiting tens of cycles.

The correct answer is a hybrid, and the hybrid is only possible if the kernel and userspace agree on a protocol. That protocol is the futex.

## What a futex actually is

The name is a contraction of "fast userspace mutex," but the name is misleading in a way that matters. A futex is not a mutex. It is not a data structure at all in the sense that a `pthread_mutex_t` is. It is a kernel-assisted wait/wake primitive over a 32-bit word in userspace.

The contract has two halves:

- **The value lives in userspace.** A futex is identified by the address of a 32-bit integer in the calling process's address space. The kernel does not own that integer, does not initialize it, and does not interpret it. Userspace reads and writes it with ordinary atomic instructions.
- **The kernel owns the wait queue.** When userspace decides that it needs to block, it calls `futex(FUTEX_WAIT, ...)`, passing the address and the value it expects to find there. The kernel compares, and if the value matches, it puts the calling thread to sleep on a wait queue keyed by that address. When another thread wants to wake waiters, it calls `futex(FUTEX_WAKE, ...)` with the same address.

The critical property is that the kernel's comparison and the enqueue are atomic with respect to the waker. If the value does not match what the caller expected, `FUTEX_WAIT` returns `EAGAIN` immediately without sleeping. That single check is what makes the whole protocol correct, and it is the reason a futex-based lock can have a userspace fast path that never touches the kernel at all.

The address is not used directly as a hash key. The kernel resolves it through `get_futex_key()`, which maps the virtual address to a stable key. For a private (process-local) mapping, the key is derived from the `mm_struct` and the page offset; for a shared mapping, it is derived from the backing inode and the offset within the file. This is why a futex in a shared memory segment works across processes, and why a futex in a private anonymous mapping does not collide with an unrelated mapping at the same virtual address in another process. It also means that the same physical page mapped twice in one process — via `mmap` aliasing — can produce two different keys, which is a real and occasionally spectacular source of bugs.

## The fast path

Here is the entire uncontended lock acquisition for a typical futex-based mutex:

```c
// lock word: 0 = unlocked, 1 = locked, 2 = locked with waiters
static inline bool try_lock(lock_t *l) {
    int expected = 0;
    return atomic_compare_exchange_strong(&l->word, &expected, 1);
}
```

That is one `LOCK CMPXCHG` on x86 (or an `LDXR`/`STXR` pair on ARM), followed by an acquire fence. On a modern core, the whole thing is on the order of 20 cycles when the line is in the local cache in the exclusive state. There is no kernel object involved, no file descriptor, no allocation, no reference counting. The kernel has no idea the lock exists.

This is the entire point of the design. A futex-based lock is a userspace lock that happens to have a kernel escape hatch. A `pthread_mutex_t` in glibc is exactly this: a 32-bit word plus a small amount of metadata, with the fast path inlined into the caller and the slow path in `libpthread`.

## The slow path, and why the value must be checked

When the compare-and-swap fails, the thread knows the lock is held. It has two options: spin for a while, or block. The interesting case is blocking, because that is where the race lives.

The naive sequence would be:

1. Read the lock word and observe that it is held.
2. Call `FUTEX_WAIT` with the address and the expected value.
3. Sleep.

The race is obvious: between steps 1 and 2, the lock holder can release the lock and call `FUTEX_WAKE`. If the wake happens before the waiter is enqueued, the wake finds an empty wait queue and does nothing. The waiter then sleeps forever, having missed the wake. This is the classic lost-wakeup problem, and it is not a bug in the futex implementation — it is a bug that the futex interface is *designed to make impossible*, provided the caller follows the protocol.

The kernel closes the race by making step 2 a **compare-and-sleep** rather than a sleep. `FUTEX_WAIT` takes the hash bucket lock for the futex key, re-reads the 32-bit value at the userspace address, and compares it against the value the caller passed. If they differ, the syscall returns `EAGAIN` and the caller retries from the top. If they match, the waiter is enqueued on the bucket's wait queue and the thread sleeps.

The waker also takes the bucket lock — it must, in order to walk the wait queue and dequeue waiters. So the two operations are serialized by the same lock. If the waiter gets the bucket lock first, it enqueues before the waker can search the queue, so the waker will find it. If the waker gets the bucket lock first, it finishes its wake-up and releases the lock; the waiter then acquires the lock, re-reads the value, and observes the waker's store. Either way, the waiter does not sleep forever.

The subtlety is the memory ordering. The waker's store to the userspace lock word happens *before* it acquires the bucket lock, and the waiter's read happens *after* it acquires the bucket lock. The lock acquisition and release act as barriers, so the store is visible to the waiter's read. The kernel also inserts explicit `smp_mb()` barriers in the futex path. This is why the man page documents `FUTEX_WAIT` as a memory barrier, and why the userspace protocol must still use acquire/release semantics on the fast path — the futex syscall does not retroactively fix a broken fast path, it only guarantees that a *correct* protocol will not lose wakeups.

This is the first of several places where the futex design reveals itself as something other than "a lock implemented in the kernel." It is a kernel primitive that lets userspace implement a lock correctly, provided userspace follows a protocol. The protocol is not optional. The kernel cannot enforce it, because the kernel does not know what the value means.

## Why the lock word needs three states

The value check only helps if the value encodes enough information to make the wake decision unambiguous. Consider the simplest possible encoding: `0` means unlocked, `1` means locked. A waiter that fails to acquire the lock calls `FUTEX_WAIT` with an expected value of `1`. The unlocker stores `0` and then has a decision to make: should it call `FUTEX_WAKE`?

If it always calls `FUTEX_WAKE`, then every unlock is a system call, and the fast path is destroyed. If it never calls `FUTEX_WAKE`, waiters sleep forever. There is no way to distinguish "there might be a waiter" from "there is definitely no waiter," because the lock word has only two states and neither of them records the presence of waiters.

The fix is to add a third state. Let `0` mean unlocked, `1` mean locked with no known waiters, and `2` mean locked with waiters. The acquisition path becomes:

```c
void lock(lock_t *l) {
    int expected = 0;
    if (atomic_compare_exchange_strong(&l->word, &expected, 1))
        return;                       // fast path: uncontended

    if (expected != 2)                // we saw 1: announce contention
        expected = atomic_exchange(&l->word, 2);

    while (expected != 0) {           // slow path: block until free
        futex_wait(&l->word, 2);      // returns EAGAIN if the value changed
        expected = atomic_exchange(&l->word, 2);
    }
}

void unlock(lock_t *l) {
    int old = atomic_exchange(&l->word, 0);
    if (old == 2)                     // someone is waiting: wake exactly one
        futex_wake(&l->word, 1);
}
```

Now the unlocker can make the decision locally, with a single atomic exchange, without any coordination. If the old value was `2`, there is at least one thread that has declared itself a waiter, and the unlocker pays for the syscall. If the old value was `1`, no thread has ever blocked on this lock, and the unlocker returns immediately. The uncontended case — the overwhelmingly common case — never enters the kernel.

The `FUTEX_WAIT` call passes `2` as the expected value, not `1`. This is not an accident. A waiter that has already announced contention is waiting for the lock to become free, which means it is waiting for the value to change from `2` to `0`. If it observes a value other than `2` on entry to `FUTEX_WAIT`, then either the lock is already free or the state has changed underneath it, and in both cases the correct response is to return to the top of the loop rather than sleep. Passing the *current* state as the expected value is what makes the compare-and-sleep check meaningful: it is a test of whether the condition the thread is waiting for is still true.

There is a second, subtler reason for the three-state encoding. The `atomic_exchange` in the lock path is not there to acquire the lock — the compare-and-swap already failed. It is there to publish the fact that a waiter exists, and it must be ordered before the `FUTEX_WAIT` call. A relaxed store would not do. The exchange is a full barrier on x86 and a release-acquire pair on weaker architectures, which is exactly the ordering needed to ensure that the unlocker's subsequent read of the lock word sees the `2` rather than a stale `1`.

This three-state pattern is not specific to futexes. It is the standard shape of every scalable blocking lock: a userspace state machine that encodes "is anyone waiting" so that the common case can be resolved without a syscall. What makes the futex version interesting is that the kernel is not involved in the state machine at all. The kernel's only job is to provide a wait queue that can be addressed by a userspace pointer, and a compare-and-sleep operation that closes the lost-wakeup window. Everything else — the state encoding, the transition rules, the memory ordering on the fast path — is the caller's problem.

That division of labor is the source of both the futex's efficiency and its difficulty. There is no kernel-side validation of the protocol. A userspace implementation that gets the ordering wrong, or that passes the wrong expected value, or that forgets to announce contention before blocking, will produce a lock that works in testing and hangs once a month in production. The kernel will do exactly what it was asked to do.

The next question is what the kernel actually does with the address — how it maps a userspace pointer to a wait queue, what data structures sit behind that mapping, and what happens when a wake operation has to find the right set of waiters among thousands of threads sleeping on thousands of distinct addresses.

## From userspace address to kernel wait queue

The kernel does not create a wait queue per futex. Instead, it maintains a global hash table of wait queues, and a futex address is hashed into one of its buckets. The wait queue is the bucket. Waiters on different addresses can share a bucket, and the kernel distinguishes them by comparing the full futex key.

The key is computed by `get_futex_key()`. For a private futex, the key is derived from the `mm_struct` and the page offset. For a shared futex, it is derived from the backing inode and the offset within the file. This is why a futex in shared memory works across processes, and why a private futex does not collide with an unrelated mapping at the same virtual address in another process.

The private/shared distinction is also a performance boundary. A shared futex requires the kernel to resolve the virtual address to a page and then to the backing inode. That means `get_user_pages_fast()` and a walk through the page's mapping, which can fault and sleep. A private futex skips all of that. This is why glibc uses `FUTEX_PRIVATE_FLAG` for process-local mutexes. Using a shared futex for a process-local lock is a common and silent performance bug.

Once the key is computed, it is hashed into the global `futex_queues` array. Each bucket is a `struct futex_hash_bucket`, which contains a spinlock and a priority-sorted list (`plist`) of waiters. The spinlock serializes all operations on that bucket: enqueueing, waking, and requeueing. The plist is sorted by task priority, which matters for priority inheritance but also means that ordinary futex wakeups are not strictly FIFO. The kernel does not promise fairness.

The waiter is represented by a `struct futex_q`, which is allocated on the waiting thread's stack. The kernel does not allocate memory for a blocked thread. The thread is already blocked, so its stack is not in use by anyone else. This means the kernel's memory footprint for futexes is proportional to the number of blocked threads, not the number of futexes. A process can create millions of uncontended futexes and the kernel will never know they exist.

The `futex_q` contains the key, a pointer to the task, a bitset, and a `lock_ptr` field. The `lock_ptr` is the bucket lock pointer. When the waiter is enqueued, it stores the bucket lock pointer. When a waker dequeues the waiter, it sets `lock_ptr` to NULL. When the waiter returns from `schedule()`, it checks `lock_ptr`. If it is NULL, the waker already removed it. If it is non-NULL, the waiter was woken by something else — a signal, a timeout, or a spurious wakeup — and it must acquire the bucket lock and remove itself. This handshake makes the wait/wake protocol robust.

## The compare-and-sleep, from the kernel side

The userspace view of `FUTEX_WAIT` is a compare-and-sleep. The kernel view is a sequence of steps that must be atomic with respect to the waker. The kernel first computes the key and locks the bucket. It then reads the 32-bit value at the userspace address with page faults disabled, because it is holding a spinlock and cannot sleep. If the value does not match, the kernel unlocks the bucket and returns `-EAGAIN`. The caller retries.

If the value matches, the kernel enqueues the `futex_q` on the bucket's plist, sets the task state to `TASK_INTERRUPTIBLE`, unlocks the bucket, and calls `schedule()`. The waker, when it calls `FUTEX_WAKE`, locks the same bucket, walks the plist, and for each matching key, removes the waiter and calls `wake_up_process()`. The bucket lock ensures that the waker cannot miss a waiter that is enqueueing, and the waiter cannot miss a wake that happens after it checks the value.

The memory ordering is equally important. The waker's store to the userspace lock word happens before it acquires the bucket lock. The waiter's read happens after it acquires the bucket lock. The bucket lock acquisition and release act as full barriers, so the store is visible to the read. The kernel also inserts explicit `smp_mb()` barriers. This is why the man page documents `FUTEX_WAIT` as a memory barrier, and why the userspace fast path must still use acquire/release semantics.

## Waking up: requeue, bitsets, and the thundering herd

`FUTEX_WAKE` takes a count and wakes up to that many waiters. For a mutex unlock, the count is 1. Waking more than one would cause the others to contend on the lock, fail, and go back to sleep — the thundering herd. The three-state lock makes this decision cheap: the unlocker checks whether the lock word was `2`, and if so, calls `FUTEX_WAKE` with count 1. If it was `1`, no one is waiting, and the unlocker never enters the kernel.

Condition variables have a different problem. A `pthread_cond_broadcast` must wake all waiters, but waking them all at once causes a thundering herd. The kernel provides `FUTEX_REQUEUE` and `FUTEX_CMP_REQUEUE` to avoid it. These operations move waiters from one futex to another without waking them. When a thread broadcasts on a condition variable, glibc can requeue all the waiters from the condition variable's futex to the mutex's futex. Then, when the mutex is unlocked, the unlocker wakes exactly one waiter. That waiter reacquires the mutex, checks the condition, and either proceeds or goes back to sleep. The others are still asleep, but now they are waiting on the mutex. This is a significant optimization.

`FUTEX_CMP_REQUEUE` adds a comparison: it checks that the value at the source futex matches an expected value before requeueing. The kernel locks both buckets in a fixed order to avoid deadlock. This is one of the more complex parts of the futex implementation.

`FUTEX_WAKE_OP` combines an atomic operation on a second futex word with a wake on the first. glibc uses this to implement condition variable signaling without a separate atomic operation in userspace. `FUTEX_WAKE_BITSET` allows the waker to wake only waiters whose bitset matches a given mask. This is used to distinguish between waiters waiting on different conditions or clock IDs.

## Priority inheritance and robust futexes

The futex interface has two extensions that change the contract significantly: priority inheritance (PI) and robust futexes. Both require the kernel to know more about the lock than just its address and value.

A PI futex is used when a thread can be preempted while holding a lock, and a higher-priority thread blocks on that lock. Without priority inheritance, the high-priority thread can be delayed indefinitely by a low-priority thread that is not scheduled — a priority inversion. The PI futex solves this by having the kernel boost the priority of the lock owner to that of the highest-priority waiter. To do this, the kernel must know who the owner is. The lock word for a PI futex encodes the TID of the owner, along with bits for `FUTEX_WAITERS` and `FUTEX_OWNER_DIED`. The fast path is still a userspace compare-and-swap: a thread tries to change the lock word from 0 to its own TID. If that fails, it calls `FUTEX_LOCK_PI`, and the kernel takes over.

The kernel's PI implementation is built on the real-time mutex (`rt_mutex`) infrastructure. When a thread blocks on a PI futex, the kernel reads the owner's TID, finds the task, and boosts its priority. The waiter is inserted into the bucket's plist sorted by priority. When the owner unlocks, it calls `FUTEX_UNLOCK_PI`, and the kernel wakes the highest-priority waiter and adjusts priorities. This is much more expensive than the three-state lock, and it is only used when the mutex is created with `PTHREAD_PRIO_INHERIT`.

Robust futexes solve a different problem: what happens if a thread dies while holding a lock? Without robust futexes, the lock is stuck forever. With robust futexes, the thread registers a list of futexes it owns with the kernel via `set_robust_list`. When the thread exits, the kernel walks the list. For each futex, it checks whether the thread is still the owner. If so, it sets the `FUTEX_OWNER_DIED` bit in the lock word and wakes a waiter. The waiter then knows that the previous owner died and can take corrective action. This is how `PTHREAD_MUTEX_ROBUST` works. The kernel does not know the semantics of the lock; it only knows the address and the owner TID. The userspace library must interpret the `FUTEX_OWNER_DIED` bit correctly.

## The real cost of blocking

The fast path of a futex-based lock is on the order of 20 cycles: one atomic compare-and-swap and an acquire fence. The slow path is on the order of a few hundred nanoseconds for the syscall alone, and several microseconds when the context switch and the wakeup IPI are included. On a modern x86-64 machine, an uncontended `futex` syscall costs roughly 300–500 nanoseconds without mitigations, and 500–1000 nanoseconds with them. A context switch costs 1–3 microseconds. An inter-processor interrupt to wake a thread on another CPU costs 1–2 microseconds. A cache miss costs around 100 nanoseconds. The total cost of blocking can easily be 100 to 1000 times the cost of the fast path.

This is the tradeoff that every mutex implementation must make. If the critical section is short — a few tens of nanoseconds — spinning is cheaper than blocking. If the critical section is long — microseconds or more — blocking is cheaper, because spinning wastes a core. The optimal strategy depends on the workload, the number of cores, and the number of runnable threads. The three-state lock makes the decision at unlock time, not at lock time. The unlocker checks whether the lock word was `2`. If it was, there is at least one waiter, and the unlocker pays for the syscall. If it was `1`, there are no waiters, and the unlocker returns without entering the kernel. This is optimal for the common case.

The cost of blocking is not just the syscall and the context switch. It is also the cost of the wait queue operations: locking the bucket, walking the plist, and waking the task. The bucket lock is a global resource, and if many futexes hash to the same bucket, their wait and wake operations serialize. The kernel uses a hash table to spread the load, but collisions are possible. A malicious or unlucky workload can create contention on a single bucket, which slows down all futex operations that hash to it. This is a known scalability limit of the futex design.

The `FUTEX_PRIVATE_FLAG` is a significant optimization for the slow path. A private futex avoids the page and inode lookup, which can be expensive and can fault. A shared futex requires `get_user_pages_fast()` and a walk through the page's mapping. This is why glibc uses private futexes for process-local locks. If you are implementing your own futex-based lock and it is only used within a single process, always use `FUTEX_PRIVATE_FLAG`. The performance difference in the slow path can be substantial.

Finally, the cost of blocking includes the cost of waking a thread on another CPU. The waker sends an IPI, which interrupts the target CPU, causing it to enter the kernel and schedule the woken thread. This is expensive, and it is one of the reasons why blocking should be avoided when the wait is likely to be short. The kernel does not provide a way to wake a thread on a specific CPU from the futex interface. The scheduler decides where to run the woken thread. If the waker and the waiter are on different CPUs, the woken thread may suffer cache misses when it resumes.

## Beyond the mutex: waitv and the evolution of the interface

The futex interface has evolved over time to meet new use cases. The most recent addition is `futex_waitv`, introduced in Linux 5.16. It allows a thread to wait on multiple futexes at once. The syscall takes an array of `struct futex_waitv`, each containing an address, an expected value, and flags. The kernel locks all the relevant buckets, checks all the values, and if all match, enqueues the waiter on all the wait queues. When any one of the futexes is woken, the waiter is removed from all the queues and returns. This is used by Wine to implement `WaitForMultipleObjects`. Without `futex_waitv`, Wine would have to use a separate thread or a complex userspace protocol. The kernel implementation is complex because it must lock multiple buckets without deadlocking and handle the case where one of the futexes is woken while the waiter is still enqueueing on the others. But it reduces the number of syscalls and the latency for event loops that wait on multiple synchronization objects.

The evolution of the futex interface is a good illustration of the design philosophy. The kernel provides a small set of primitives: wait, wake, requeue, and a few variants. Userspace libraries combine these primitives into mutexes, condition variables, semaphores, and read-write locks. When a new use case appears — such as waiting on multiple objects — the kernel can add a new primitive without changing the existing ones. The fast path remains a userspace atomic operation, and the kernel remains uninvolved until a thread actually needs to block. This is why futexes have remained the foundation of Linux synchronization for two decades, and why they are likely to remain so for the foreseeable future.

The cost of blocking is real, but it is a cost that is paid only when contention is real. The fast path is free, or as close to free as an atomic instruction can be. The three-state lock ensures that the kernel is not involved in the common case. The hash table ensures that the kernel's memory footprint does not grow with the number of futexes. The wait queue node on the stack ensures that blocking does not require allocation. These design choices are what make futexes scale to millions of locks and thousands of threads. They are also what make futexes difficult to implement correctly: the kernel trusts userspace to follow the protocol, and it provides no validation. The protocol is the lock. The kernel is just the escape hatch.

## The cache line is the real lock

Every discussion of lock performance eventually arrives at the same uncomfortable fact: the lock word itself is not the bottleneck. The cache line containing it is. On a cache-coherent multiprocessor, an atomic read-modify-write instruction does not just execute in the core's pipeline. It acquires exclusive ownership of the cache line, which means invalidating that line in every other core's cache. The line then migrates to the requesting core, and if another core immediately requests it, it migrates back. This is the cache-line ping-pong that dominates the cost of contended synchronization.

The three-state futex lock does not avoid this. The fast path is a `LOCK CMPXCHG` on the lock word, which is exactly the kind of operation that forces the line into the exclusive state. When ten threads spin on the same lock, all ten are issuing atomic operations on the same line. The holder, trying to execute a short critical section, finds its own cache line repeatedly invalidated by the spinners. The critical section slows down, which makes the lock held longer, which makes the spinners spin longer. This is a positive feedback loop, and it is why spin locks degrade so badly under contention.

Blocking breaks the loop by removing the waiter from the coherence protocol. A thread that calls `FUTEX_WAIT` stops issuing atomic operations on the lock word. It stops fetching the cache line. It stops invalidating the holder's copy. The only cost it imposes on the holder is the one-time cost of the `FUTEX_WAIT` syscall and the bucket lock acquisition, which happens once. After that, the holder runs on a quiet cache line. This is a benefit of blocking that is rarely mentioned: it is not just about yielding the CPU, it is about yielding the cache line.

The kernel's wait queue is deliberately not on the same cache line as the userspace lock word. The `futex_q` is on the waiter's stack, and the hash bucket is in a kernel data structure. When a waiter blocks, it stops touching the userspace line. When it is woken, it touches the line again, but only once. This separation is what makes the futex design scale. A userspace spin lock has no such separation: the waiters and the holder all share the same line, and the line becomes a hot spot.

This also explains why false sharing is so damaging to futex-based locks. If two unrelated locks happen to share a cache line, then threads contending on one lock will invalidate the line for threads using the other lock. The atomic operations on one lock will cause the other lock's line to bounce, even though the two locks are logically independent. This is why lock implementations often pad their lock words to a full cache line. The futex interface does not require this, but it does not prevent it either. The kernel hashes the futex address to a bucket, and the address is the userspace address. If two futexes are in the same cache line, they will hash to different buckets (because the addresses differ), but they will still share a cache line in userspace. The kernel's wait queues are separate, but the userspace lock words are not. So the coherence traffic on the fast path is still shared. Padding is the userspace's responsibility, and it is one of the most effective optimizations for contended locks.

## Adaptive spinning: the userspace policy that the kernel cannot see

The futex interface gives userspace two choices: spin or block. It provides no information about which is better. The kernel knows how many threads are waiting on a futex, how long they have been waiting, and which CPU the lock owner is running on. But none of that information is exposed to userspace. The `FUTEX_WAIT` syscall returns only when the thread is woken or interrupted. There is no `FUTEX_POLL` or `FUTEX_HINT` that says 'the lock is likely to be released soon' or 'the owner is not running.' Userspace libraries must guess.

The most common guess is adaptive spinning. A thread that fails to acquire the lock spins for a bounded number of iterations before calling `FUTEX_WAIT`. The bound is chosen empirically: glibc's adaptive mutex spins a fixed number of times (typically 100) and then blocks. The rationale is that if the lock is held for a very short time, the holder will release it within the spin window, and the waiter avoids a syscall. If the lock is held longer, the spin is wasted, but it is bounded, so the waste is limited.

The problem with this heuristic is that it is blind to the actual state of the system. On a machine with many cores, a spin of 100 iterations might take a few hundred nanoseconds, which is enough for a short critical section. On a machine with few cores, or under heavy load, the lock holder might be preempted, and no amount of spinning will help. Worse, spinning on a lock whose owner is not running is pure waste: the waiter is burning a core that could be used to run the owner. This is the classic priority inversion scenario, and adaptive spinning can make it worse.

A more sophisticated approach is to spin only if the lock owner is currently running on another CPU. This requires knowing the owner's TID and querying the scheduler, which is not possible from userspace without a syscall. Some libraries use a heuristic: spin if the number of runnable threads is less than the number of CPUs. This can be queried with `sched_getaffinity` and `/proc/loadavg`, but it is coarse and racy. The futex interface does not provide a way to make this decision atomically with the wait.

The `sched_yield` syscall is sometimes used as a middle ground: instead of blocking, the thread yields the CPU and immediately tries again. This is almost always a mistake. `sched_yield` moves the thread to the end of the run queue, but it does not guarantee that the lock holder will run. On a busy system, the yielding thread may be scheduled on a different CPU, losing its cache locality. And it is still a syscall, so it does not avoid the kernel entry cost. The only case where `sched_yield` is reasonable is when the thread is at the same priority as the holder and the scheduler is FIFO, which is rare.

The futex's design intentionally leaves the spin policy to userspace. The kernel cannot know the critical section length, and it cannot know the scheduling latency. The only entity that can make a good decision is the application, and even then it is a guess. This is why the most scalable locks often use a two-level approach: a short spin, then a `FUTEX_WAIT`, but with a backoff that increases with the number of failed attempts. The backoff reduces the coherence traffic during the spin phase, and the eventual block removes the waiter from the fight. The kernel does not help, but it does not hinder. The protocol is entirely in userspace.

## The scheduler as an unwitting participant

When a thread calls `FUTEX_WAKE`, the kernel does not simply mark the waiter as runnable. It calls `wake_up_process()`, which invokes the scheduler's `try_to_wake_up()`. This function decides where and when the woken task will run. The decision is based on CPU affinity, load balancing, and the current state of the run queues. The futex interface provides no way to influence this decision. The waker cannot say 'wake this thread on the same CPU' or 'wake it on the CPU where it was running before.' The kernel's scheduler makes the call.

For a mutex unlock, the waker is often the thread that just released the lock. It may continue running, or it may block on something else. The woken thread is the new lock owner. If the scheduler places the woken thread on a different CPU, the lock word's cache line must migrate to that CPU. The woken thread will then execute the critical section, and when it unlocks, the line may migrate again. This migration is expensive. It is one of the reasons why blocking can be slower than spinning for short critical sections: the syscall and context switch are only part of the cost; the cache-line migration is the rest.

The kernel has a hint for this: `WF_SYNC`. When a waker is about to sleep (e.g., a producer waking a consumer), it can pass `WF_SYNC` to `wake_up_process()` to indicate that the woken task should preempt the waker. But the futex wake path does not use `WF_SYNC` by default. The waker is not necessarily going to sleep; it may just be releasing a lock and continuing. So the scheduler uses its default policy, which may or may not be optimal. Some kernels have experimented with using the futex key to track the last CPU of the waiter, but this is not part of the stable interface.

The cost of an inter-processor interrupt is also significant. When a waker on CPU 0 wakes a waiter on CPU 1, the kernel sends an IPI to CPU 1. The IPI interrupts whatever CPU 1 is doing, causing a kernel entry, a scheduler decision, and a return to userspace. On a modern x86-64 machine, an IPI costs on the order of 1–2 microseconds. This is a fixed cost that is paid regardless of how short the critical section is. It is why blocking is a bad idea when the wait is likely to be shorter than a few microseconds.

NUMA adds another layer. The global futex hash table is allocated with `alloc_large_system_hash()`, which can spread the buckets across NUMA nodes. But the hash function is based on the futex address, which is a virtual address. The same virtual address in different processes may hash to different buckets if the processes have different address space layouts. Even within a single process, the bucket for a given futex is fixed. If the waker is on node 0 and the bucket is on node 1, the waker must acquire a remote lock. This is a cross-node cache-line transfer, which is slower than a local one. The waiter's `futex_q` is on its stack, which is on its node. The waker must read and write the `futex_q` to dequeue it, which is another cross-node access. These NUMA effects are not addressed by the futex interface. Applications that care about NUMA latency must pin threads and ensure that futexes are allocated on the same node as the threads that use them. But the kernel's hash table placement is not under application control.

## Futexes in the wild: glibc, Rust, Go, and the JVM

The futex syscall is not usually called directly by applications. It is wrapped by language runtimes and standard libraries, each of which makes different choices about spinning, blocking, and the use of futex flags. These choices have a profound effect on performance, and they illustrate how much of the futex's behavior is determined by userspace policy.

glibc is the canonical implementation. Its `pthread_mutex_t` is a 32-bit word with three states: 0 for unlocked, 1 for locked without waiters, and 2 for locked with waiters. The fast path is an inline `atomic_compare_exchange_strong`. The slow path calls `FUTEX_WAIT_PRIVATE` with an expected value of 2. The unlock path calls `FUTEX_WAKE_PRIVATE` with a count of 1 if the old value was 2. For condition variables, glibc uses a separate futex for the sequence number and a mutex. The `pthread_cond_signal` calls `FUTEX_WAKE` with a count of 1, and `pthread_cond_broadcast` calls `FUTEX_REQUEUE` to move waiters to the mutex's futex. glibc also implements `pthread_mutex_timedlock` using `FUTEX_WAIT_BITSET` with an absolute timeout. The `PTHREAD_MUTEX_ADAPTIVE_NP` type adds a spin loop before blocking. The `PTHREAD_MUTEX_PRIO_INHERIT` type uses `FUTEX_LOCK_PI` and `FUTEX_UNLOCK_PI`. glibc's implementation is a masterclass in using the futex interface correctly, and its source code is the best reference for anyone implementing a futex-based lock.

Rust's standard library uses futexes on Linux for `std::sync::Mutex` and `std::sync::Condvar`. The implementation is in `library/std/src/sys/pal/unix/futex.rs`. It uses a `AtomicU32` for the lock word and calls `futex_wait` and `futex_wake`. The standard library's mutex is not adaptive; it blocks immediately on contention. This is a deliberate choice for simplicity and portability. The `parking_lot` crate, which is widely used, implements a more sophisticated lock with adaptive spinning and a custom `WordLock`. `parking_lot` uses a 64-bit lock word with separate bits for the lock state, the number of waiters, and a fairness flag. It uses `FUTEX_WAIT_BITSET` and `FUTEX_WAKE_BITSET` to wake specific waiters. This allows it to implement fair locking and to avoid the thundering herd. The difference between the standard library and `parking_lot` is a good example of how much the userspace policy matters: the kernel primitive is the same, but the performance can differ by a factor of two or more under contention.

Go's runtime has its own futex implementation. The `runtime.futexsleep` and `runtime.futexwakeup` functions are used by the scheduler and by synchronization primitives. Go's `sync.Mutex` is a spin-then-block lock with a starvation mode. It uses a 32-bit state word with bits for locked, woken, starving, and waiter count. The fast path is a compare-and-swap, and the slow path calls `futexsleep`. Go's runtime also uses futexes for network polling and for the garbage collector's stop-the-world phase. The Go implementation is interesting because it does not use glibc; it makes direct syscalls. This avoids the overhead of the C library and allows the runtime to control the spin policy precisely.

The JVM (HotSpot) uses futexes for `ObjectMonitor` and for `java.util.concurrent` locks. Historically, HotSpot used its own adaptive spinning and then a `pthread_mutex` or a direct futex call. Modern JVMs use `futex` directly for `LockSupport.park` and `unpark`. The JVM's spin policy is configurable with `-XX:+UseSpinning` and `-XX:PreBlockSpin`. Like the other runtimes, the JVM uses `FUTEX_WAIT_PRIVATE` and `FUTEX_WAKE_PRIVATE` for process-local locks. The JVM also implements biased locking and thin locks, which are userspace-only fast paths that avoid futexes entirely in the uncontended case. This is another example of the same pattern: the futex is the slow path, and the fast path is a userspace atomic operation.

Across all these implementations, the same themes recur. The fast path is a userspace atomic operation. The slow path is a `FUTEX_WAIT` with a carefully chosen expected value. The wake path is a `FUTEX_WAKE` with a count that is chosen to avoid the thundering herd. The private flag is used whenever possible. The spin policy is a userspace heuristic, and it is the main source of performance differences. The kernel provides the primitive, but the policy is the library's responsibility.

## The return value is part of the protocol

A futex wait is not a blocking read that returns the new value. It is a syscall whose return value tells the caller what happened to the wait, and the caller must interpret that return value correctly. The kernel returns `0` when the thread was woken by a `FUTEX_WAKE`, `-1` with `errno` set to `EAGAIN` when the value at the futex address no longer matches the expected value, `EINTR` when the wait was interrupted by a signal, and `ETIMEDOUT` when a timeout expired. It can also return `EFAULT` if the address is invalid and `EINVAL` for malformed arguments. None of these returns means 'the condition is now true.' They mean 'the wait ended for this reason.' The userspace loop must re-read the futex word and re-evaluate the condition after every return.

This is the part of the futex contract that is easiest to get wrong. A thread that treats `0` as 'I acquired the lock' will eventually acquire a lock that is still held. A thread that treats `EAGAIN` as an error will fail spuriously whenever another thread changes the value before the syscall reaches the kernel. A thread that treats `EINTR` as a wake will proceed without the condition being true. The correct shape is always a loop:

```c
for (;;) {
    int v = atomic_load_explicit((_Atomic int *)word, memory_order_acquire);
    if (condition_is_true(v))
        break;

    int rc = futex_wait(word, v, timeout);
    if (rc == 0)
        continue;                 // woken: recheck the condition
    if (errno == EAGAIN)
        continue;                 // value changed: recheck
    if (errno == EINTR) {
        if (cancellation_requested())
            return -ECANCELED;
        continue;                 // signal: recheck and maybe wait again
    }
    if (errno == ETIMEDOUT)
        return -ETIMEDOUT;
    return -errno;
}
```

The loop is not defensive programming. It is the protocol. The kernel's compare-and-sleep only checks the value once, at the moment the syscall enters the kernel and takes the bucket lock. It does not keep checking the value while the thread sleeps. It does not know what the value means. It does not know whether the waker intended to wake this particular waiter. It only knows that a thread asked to sleep if a 32-bit word still had a particular value, and that some other thread later asked to wake waiters on that address. The woken thread must decide whether the wake was useful.

This is also why `FUTEX_WAKE` does not read the futex word. A waker can call `FUTEX_WAKE` on an address without knowing the current value, without holding the userspace lock, and without changing the word. The wake is a scheduling hint, not a condition-variable signal. It tells the kernel to mark up to `count` waiters on that address as runnable. Those waiters return from the syscall and recheck the word. If the waker changed the word before calling `FUTEX_WAKE`, the waiters will see the new value and proceed. If the waker did not change the word, the waiters will see the old value and go back to sleep. The kernel does not distinguish between these cases.

The same applies to `FUTEX_WAKE_BITSET`. The bitset is a filter on which waiters are eligible to be woken, not a condition on the futex word. A waiter that passes the bitset check is woken, returns from the syscall, and rechecks the word. The bitset does not make the wake conditional on the word's value. It only reduces the set of threads that are disturbed.

The return value from `FUTEX_WAKE` is the number of waiters that were actually woken. This is useful for diagnostics and for adaptive policies, but it is not a reliable indicator of contention. A waker can observe zero woken waiters and still have a waiter arrive immediately afterward. A waker can observe one woken waiter and have that waiter find the condition false and go back to sleep. The count is a snapshot of the wait queue at the moment the bucket lock was held, not a promise about the future.

The kernel's wait queue is also not a message queue. It does not store a wake reason. A waiter that returns `0` does not know whether the wake came from the unlocker, from a signal handler that called `FUTEX_WAKE`, or from a timeout that raced with a wake. The userspace protocol must be idempotent: rechecking the condition must be safe no matter how many times it happens. This is why condition variables use a sequence number or a generation counter. The waiter waits for a specific generation to change; the waker increments the generation and calls `FUTEX_WAKE`; the waiter rechecks the generation. A spurious wake just causes another recheck. A lost wake is impossible as long as the waker increments the generation before calling `FUTEX_WAKE` and the waiter reads the generation before calling `FUTEX_WAIT`.

The return value is therefore not an afterthought. It is the userspace half of the compare-and-sleep contract. The kernel provides the atomic compare and the parking operation. The userspace provides the condition, the state transition, and the loop that interprets the return value. If the loop is wrong, the kernel cannot save it.

## Alignment, residency, and the 32-bit contract

A futex is a 32-bit word. There is no 64-bit futex, no 128-bit futex, and no futex over a byte or a 16-bit integer. The kernel reads and compares a `u32`, and the address must be aligned to a 4-byte boundary. A misaligned address is rejected. This is not an arbitrary restriction. The kernel's compare happens while holding a spinlock, and it uses an ordinary 32-bit load. On the architectures Linux supports, an aligned 32-bit load is atomic with respect to other aligned 32-bit accesses. A misaligned load may be split into multiple bus transactions, may cross a cache line, and may not be atomic. The kernel cannot allow that, because the compare must be a single observation of the word.

The userspace side must use a true atomic operation on the same word. On x86-64, that means a `LOCK`-prefixed instruction or an instruction with an implicit lock, such as `XCHG`. On ARM64, it means a load-exclusive/store-exclusive pair or an atomic instruction from the Large System Extensions. On other architectures, it means whatever the architecture provides for atomic read-modify-write. If the compiler emits a call to a lock-based atomic library instead of an inline atomic instruction, the fast path is no longer lock-free. A lock-based atomic implementation can deadlock if it is used inside a futex-based lock, because the library's internal lock may itself block on a futex. The futex protocol assumes that the userspace atomic operations are actually atomic and do not sleep.

The kernel's read is not a C11 atomic load. It is a `get_user()` under the bucket spinlock. It relies on the architecture's aligned 32-bit load being atomic and on the bucket lock for ordering. This is why the userspace side must use acquire and release semantics on the fast path. The kernel's read does not retroactively make a relaxed userspace store visible in the right order. The userspace protocol must publish the state change before the wake and must acquire the state before the wait.

There is a second constraint that is less obvious: the futex word must be resident in memory at the moment of the compare. The kernel cannot take a page fault while holding the bucket spinlock. If the page containing the futex word is not present, the compare fails and the syscall returns an error. The key resolution step may fault the page in before the bucket lock is taken, but the compare itself cannot sleep. This is why futex words are usually placed in memory that is already resident and not subject to reclaim while waiters exist. A futex in a file-backed mapping that can be paged out is a poor choice unless the mapping is locked or the page is guaranteed to stay resident. A futex in a shared memory segment that is swapped out can produce a failed wait at exactly the wrong moment.

The kernel never writes the futex word during an ordinary `FUTEX_WAIT` or `FUTEX_WAKE`. It only reads the word for the wait compare. The wake operation does not read or write the word at all. This is a deliberate division of labor: the kernel cannot corrupt the userspace state machine, and the userspace cannot rely on the kernel to update it. The only exception is `FUTEX_WAKE_OP`, which performs an atomic operation on a second futex word as part of the wake. That operation is explicitly requested by userspace and is not part of the ordinary wait/wake path.

The 32-bit width has practical consequences. A lock that needs to encode an owner TID, a waiter count, and several flags must fit those fields into 32 bits. Priority-inheritance futexes use the word to store the owner TID plus flag bits. Robust futexes use flag bits to mark owner death. A userspace lock that wants a 64-bit generation counter cannot put the whole counter in a single futex word; it must use a separate word or split the state across multiple futexes. This is one reason why lock word design is a compression problem. Every bit must earn its place.

## Lifetime and address reuse

The kernel identifies a futex by a key derived from the address, not by an object handle. For a private futex, the key includes the `mm_struct` and the address within the mapping. For a shared futex, the key includes the backing inode and the offset within the file. The kernel does not know when the userspace object that owns the futex is destroyed. It does not receive a destructor call. It only knows that a thread asked to sleep on a key, and that another thread later asked to wake waiters on the same key.

This means the lifetime of a futex is entirely a userspace responsibility. If a thread is blocked on a futex and another thread unmaps the page containing the futex word, the blocked thread remains on the kernel's wait queue. The kernel does not cancel the wait because the page was unmapped. The wait queue entry is on the waiter's stack and does not reference the userspace page after enqueue. The waiter will sleep until it is woken, interrupted by a signal, or timed out. If the address is never woken, the thread can sleep forever.

Worse, the address can be reused. If the page is unmapped and a new mapping is created at the same virtual address, a new futex at that address can produce the same key as the old one. A `FUTEX_WAKE` intended for the new object can then wake the old waiter. The old waiter returns from the syscall, rechecks the word at the address, and sees whatever the new object has stored there. If the new object's state happens to satisfy the old waiter's condition, the old waiter proceeds as if it had acquired the new object's lock. This is not a theoretical concern. It is a real hazard in any system that destroys synchronization objects while threads may still be waiting on them.

The protocol rule is simple: do not destroy a futex until every thread that could wait on it has been woken and has left the wait queue. In practice, this means the destruction path must acquire the lock, set a state that prevents new waiters from blocking, wake all existing waiters, and wait for them to observe the state and return. This is the same rule that applies to condition variables and semaphores. The kernel cannot enforce it because the kernel does not know the object's lifetime. It only knows the address.

The same issue applies to shared futexes across processes. A shared futex is keyed by the backing inode and offset. If the file is truncated, the mapping is removed, or the offset is reused for a different object, the key can be reused. A process that is still waiting on the old key can be woken by a wake intended for the new object. The kernel's key is stable for the lifetime of the mapping, but the mapping's lifetime is controlled by userspace. The kernel does not track the logical object that the futex represents.

This is why futex-based locks are not composable with arbitrary memory management. A lock embedded in a heap object cannot be freed while another thread might be blocked on it. A lock in a memory-mapped file cannot be unmapped while another process might be waiting on it. The userspace protocol must include a quiescence step: stop new waiters, wake existing waiters, and wait for them to leave. The kernel's wait queue is a parking lot, not a reference-counted object. It will hold the waiter until someone wakes it, even if the address it was waiting on no longer exists.

The kernel's key computation also explains why a futex in a private anonymous mapping cannot be shared across processes. The key includes the `mm_struct`, so two processes that map the same physical page at the same virtual address still have different keys. The kernel will not connect their wait queues. A shared futex must be backed by a shared file mapping, because the key must be derived from something that both processes can name: the inode and the offset. This is not an implementation detail. It is the definition of what it means for a futex to be shared.

The address is the identity. The value is the state. The kernel is the parking attendant. The protocol is the lock. If the address is reused while a waiter is still parked, the attendant cannot tell the difference between the old car and the new one. The userspace must not create that ambiguity.
