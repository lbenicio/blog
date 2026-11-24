---
title: "User-Space RCU: Grace Periods, Memory Ordering, and Reclamation Without Stop-the-World Pauses"
description: "A practical systems guide to read-copy-update in user space: how grace periods work, how to publish and retire objects safely, memory-ordering rules, liburcu variants, and design trade-offs for lock-free readers."
date: "2026-03-25"
author: "Leonardo Benicio"
tags: ["concurrency","RCU","memory reclamation","lock-free","systems programming","parallel computing"]
categories: ["Computer Science","Systems Design","Parallel Computing"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/user-space-rcu-grace-periods-memory-ordering-and-reclamation-without-stop-the-world-pauses-2026-03-25.jpg"
coverAlt: "A systems diagram of user-space RCU showing old and new versions of a linked list, reader threads traversing the old version, a writer publishing a new version, and a circular grace-period ring with quiescent-state markers."
---

# User-Space RCU: Grace Periods, Memory Ordering, and Reclamation Without Stop-the-World Pauses

## Why Memory Reclamation Is the Hard Part of Lock-Free Programming

Lock-free data structures are easy to describe and difficult to finish. The hard part is rarely the compare-and-swap loop, the atomic pointer exchange, or the linearization point. The hard part is knowing when it is safe to free an object that another thread might still be traversing. A reader can load a pointer, get preempted, and then wake up after a writer has unlinked that object. If the writer frees the object immediately, the reader will dereference freed memory. That is a use-after-free, and it is not a theoretical concern. It is the default outcome of naive lock-free deletion.

Most engineers first reach for reference counting. Each object carries an atomic reference count, readers increment it before use and decrement it after use, and the last decrement frees the object. This is correct, but the cost is paid on the read side. Every traversal becomes an atomic read-modify-write operation on a shared cache line. In read-mostly workloads, that cost dominates. Readers contend with each other and with writers, and the very concurrency that motivated the lock-free design becomes a cache-line bottleneck.

Hazard pointers are another answer. Each reader publishes the addresses it is currently using. A writer checks all hazard slots before freeing. Hazard pointers give bounded memory usage and do not require global coordination, but readers pay for publishing and clearing hazards, and writers pay for scanning hazard slots. The cost is distributed and can be made efficient, but it is still a cost on the read path.

Read-copy-update, usually abbreviated RCU, takes a different position. Readers should be almost free. Writers should pay the cost of waiting. The central idea is that readers never block writers and writers never block readers. A writer creates a new version of a data structure, publishes it atomically, and then waits until all readers that might have seen the old version have finished their read-side critical sections. Only then does the writer free the old version. The waiting period is called a grace period.

RCU is not a single algorithm. It is a family of synchronization mechanisms built around the same contract. The contract is simple enough to state in a paragraph and subtle enough to consume entire chapters of kernel documentation. This article is about user-space RCU: how the contract works outside the Linux kernel, what grace periods actually mean when the scheduler is not cooperating, how memory ordering fits into publication and subscription, and how to design systems that use RCU without turning deferred reclamation into an unbounded memory leak.

The article assumes familiarity with threads, atomic operations, and the general shape of lock-free programming. It does not assume that the reader has implemented an RCU library before. It also does not claim that RCU is always the right answer. RCU is a specialized tool for read-mostly data structures, and it fails badly when that assumption is violated. Understanding those failure modes is as important as understanding the read-side fast path.

## The Core Problem: Deferred Reclamation

Consider a singly linked list. Readers traverse from the head to the tail. A writer wants to remove a node. The writer can unlink the node with a single atomic store to the predecessor pointer. After that store, new readers will not see the node. But a reader that loaded the predecessor pointer before the store may still be walking through the node. That reader may have loaded the node pointer, then been preempted, then resumed after the writer freed the node. The writer cannot know whether such a reader exists.

A reader-writer lock solves this by making readers and writers mutually exclusive. The writer takes the lock exclusively, waits for all readers to leave, unlinks the node, frees it, and releases the lock. New readers block until the writer is done. This is correct and simple. It is also expensive when reads dominate. The lock itself becomes a shared cache line. Readers bounce it between cores. Writers suffer. Latency spikes. The data structure may be logically read-mostly, but the synchronization primitive makes it look write-heavy at the cache level.

RCU separates the act of unlinking from the act of freeing. The writer unlinks the node immediately. New readers cannot reach it. Existing readers may still be traversing it. The writer then waits for a grace period. A grace period ends when every reader that was active before the unlink has completed its read-side critical section. At that point, no reader can still hold a reference to the unlinked node. The writer frees it. The critical insight is that the writer does not need to know which readers exist or what they are doing. It only needs to know that all old readers are gone.

This is a form of deferred reclamation. The object is logically removed at time T, but physically freed at time T plus grace period. During that interval, the object remains allocated. Readers that started before T may still use it. Readers that start after T cannot reach it. This is safe because the object has not been modified in a way that breaks old readers. The old version is immutable from the perspective of readers. Writers create new versions rather than mutating shared state in place.

Immutability is a recurring theme. RCU works best when updates create a new version and publish it atomically. In-place mutation of a linked list node is possible in some cases, but it requires careful ordering and is easy to get wrong. The safest mental model is copy-on-write for the parts of the structure that readers traverse, with atomic pointer publication to make the new version visible.

## The RCU Contract

The RCU contract has three parts: read-side critical sections, publication and subscription, and grace periods. Each part has rules. Breaking any rule can produce silent memory corruption that appears only under load.

A read-side critical section is a region of code in which a thread may hold references to RCU-protected objects. The thread enters the section, traverses or reads objects, and exits the section. The section must not block. It must not sleep. It must not perform an operation that could cause the thread to be descheduled for an unbounded time. The reason is that a grace period cannot end while a reader is inside a read-side critical section. If the reader blocks, the grace period stalls, and writers waiting for that grace period stall. In the kernel, blocking inside an RCU read-side critical section is a bug. In user space, the same rule applies to classic RCU. Some variants relax the rule, but they change the cost model and the API.

Publication is how a writer makes a new version visible. The writer allocates and initializes the new object, then stores a pointer to it into a location that readers can observe. The store must be atomic and must have release semantics. Release semantics ensure that all initialization stores are visible before the pointer store becomes visible. Without release semantics, a reader on a weakly ordered CPU could observe the new pointer before observing the initialized fields. The reader would then dereference a pointer to an object whose fields are still zero or garbage.

Subscription is how a reader obtains a pointer to an RCU-protected object. The reader loads the pointer with acquire semantics. Acquire semantics ensure that subsequent loads of the object's fields cannot be reordered before the pointer load. Together, release on publication and acquire on subscription create a happens-before relationship between the writer's initialization and the reader's use of the object. This is the same pattern used in many lock-free designs, but RCU makes it central because readers do not take locks.

A grace period is the interval between a writer's publication of a new version and the moment when all readers that could have observed the old version have finished. The exact definition depends on the RCU variant. In classic RCU, a grace period ends when every CPU has passed through a quiescent state. A quiescent state is a point in a thread's execution where it cannot be holding an RCU-protected reference. A context switch is a quiescent state. A return to user mode is a quiescent state. An idle loop is a quiescent state. In user-space RCU, quiescent states are often explicit: the thread calls a function to announce that it is not in a read-side critical section.

The writer waits for a grace period and then frees the old object. Waiting can be synchronous or asynchronous. Synchronous waiting means the writer calls a function like synchronize_rcu and blocks until the grace period ends. Asynchronous waiting means the writer registers a callback with call_rcu and continues. A background thread or the next grace period processes the callback later. Synchronous waiting is simpler to reason about but can stall the writer. Asynchronous waiting is better for latency-sensitive writers but requires a callback mechanism and careful memory management for the callback itself.

## Publication and Subscription in Detail

Publication and subscription are where most RCU bugs originate. The rules are small, but they are unforgiving.

Suppose a writer allocates a new node and initializes its fields. The writer then wants to insert the node at the head of a linked list. The list head is an atomic pointer. The writer sets the new node's next pointer to the current head, then atomically stores the new node pointer into the head with release semantics. A reader loads the head with acquire semantics, then follows the next pointer. If the reader sees the new node, it is guaranteed to see the initialized next pointer and any other fields initialized before the release store. If the reader sees the old head, it simply does not see the new node. Either outcome is acceptable.

What happens if the writer uses a relaxed store for the head? On a strongly ordered architecture like x86, the store may still appear ordered to other cores because x86 stores are not reordered with other stores. But the compiler may reorder the initialization after the store. The reader could see the new pointer before the fields are initialized. On a weakly ordered architecture like Arm or Power, the hardware may also reorder the stores. The result is a reader dereferencing an object with uninitialized fields. This is not a theoretical concern. It is a common bug when porting lock-free code between architectures.

What happens if the reader uses a relaxed load for the head? The compiler or CPU may reorder subsequent loads of the node's fields before the head load. The reader could load a field from the new node before loading the pointer that makes the node reachable. In practice, the reader would be using a stale pointer or a pointer that it has not yet validated. Acquire semantics prevent this reordering.

C11 and C++11 provide atomic_load_explicit and atomic_store_explicit with memory_order_acquire and memory_order_release. These are the portable primitives. Some RCU libraries provide macros like rcu_assign_pointer and rcu_dereference. These macros usually expand to release and acquire operations, sometimes with additional compiler barriers or dependency ordering. It is important to use the library's macros rather than hand-rolled atomics unless you fully understand the memory model and the target architectures.

Data dependencies matter. If a reader loads a pointer and then dereferences it to load another pointer, the second load is dependent on the first. Some architectures respect address dependencies and do not require an acquire fence for the second load. Other architectures do. The C11 memory model does not provide a portable consume operation that is universally implemented as a cheap dependency. As a result, most portable code uses acquire semantics for pointer loads. This is slightly more expensive on some architectures, but it is correct everywhere.

## Grace Periods in User Space

In the Linux kernel, RCU can rely on the scheduler, context switches, idle loops, and interrupts to detect quiescent states. User-space RCU does not have that luxury. A user-space thread can spin in a tight loop without entering the kernel. It can be preempted at any time. It can be stopped by a debugger. It can be blocked in a system call. The RCU library must have a way to know when a thread is not in a read-side critical section.

There are several strategies. One is explicit quiescent-state reporting. The thread calls rcu_quiescent_state or an equivalent function when it is outside a read-side critical section. The library tracks each thread's state. A grace period advances when all registered threads have reported a quiescent state since the grace period began. This is the basis of QSBR, quiescent-state-based reclamation. It is very cheap on the read side: entering and leaving a read-side critical section may be no-ops. The cost is on the application: it must call the quiescent-state function at appropriate points. If a thread never calls it, grace periods never end.

Another strategy is signal-based. The library sends a signal to every registered thread. The signal handler runs in the context of that thread and marks the thread as having passed through a quiescent state. The signal handler must be async-signal-safe. It must not take locks that could deadlock with the signal. It must not call into code that might block. Signal-based RCU can detect quiescent states without application cooperation, but signals are expensive and can interfere with application behavior. A thread that blocks signals can stall grace periods. A thread that is in a long-running system call may not handle the signal promptly.

A third strategy is membarrier-based. Modern Linux provides the membarrier system call, which can force memory barriers on all threads in a process or on a set of threads. RCU can use membarrier to ensure that all threads have executed a memory barrier since the grace period began. If a thread has executed a memory barrier, it cannot still be inside a read-side critical section that started before the grace period. This is a clever trick, but it depends on kernel support and on the exact membarrier command. It also has cost: the kernel must interrupt or otherwise synchronize with other threads.

A fourth strategy is reference counting or hazard pointers combined with RCU. This is a hybrid. The read side may publish a hazard or increment a counter, but the writer uses grace periods to batch reclamation. This can reduce the cost of hazard scanning or refcount contention.

Most user-space RCU libraries support multiple flavors. The application chooses based on its threading model, its tolerance for signals, and its need for read-side speed. There is no single best flavor. The best choice depends on the workload.

## Quiescent States and Read-Side Critical Sections

A quiescent state is a moment when a thread is definitely not in a read-side critical section. If every thread has passed through a quiescent state since the grace period started, then any read-side critical section that started before the grace period must have ended. This is the fundamental invariant.

In a user-space RCU library, a read-side critical section is usually delimited by rcu_read_lock and rcu_read_unlock. In some flavors, these are no-ops. In others, they increment and decrement a per-thread nesting counter. In still others, they disable signals or set a thread-local flag. The cost varies.

Nested read-side critical sections are usually allowed. The library tracks a nesting depth. The thread is considered to be in a read-side critical section as long as the depth is greater than zero. Leaving an inner section does not make the thread quiescent. Only leaving the outermost section does.

A thread can be quiescent in several ways. It can call an explicit quiescent-state function. It can context switch. It can enter the kernel for a system call that is known to be a quiescent state. It can be idle. In user space, the library often uses a combination of explicit calls and signal-based or membarrier-based detection. The exact set of quiescent states is part of the library's contract. Application code must not assume that a particular operation is a quiescent state unless the library documents it.

The most dangerous mistake is to treat a blocking operation as a quiescent state when it is not. If a thread blocks inside a read-side critical section and the library does not consider blocking to be a quiescent state, the grace period will never end. Writers will wait forever. Memory will grow. The system will appear to hang. This is why the rule against blocking in read-side critical sections is so important. Some RCU variants, like sleepable RCU in the kernel, explicitly allow blocking, but they use a different API and a different grace-period mechanism. In user space, sleepable RCU is less common, and mixing blocking with classic RCU is a bug.

## Memory Ordering and the C11/C++11 Memory Model

Memory ordering is the part of RCU that engineers most often get wrong. The read-side fast path looks like a simple pointer load. The write-side publication looks like a simple pointer store. The compiler and CPU do not see it that way.

The C11 memory model defines data races as undefined behavior. If one thread writes a non-atomic object while another thread reads it concurrently, the program has undefined behavior. RCU-protected objects are often read by multiple threads while a writer is preparing a new version. The old version is not modified after publication. The new version is initialized before publication. The pointer that connects them is atomic. This is why RCU requires publication and subscription to use atomic operations with appropriate ordering.

Release semantics on the publication store ensure that all prior writes in the writer thread become visible before the store itself becomes visible. Acquire semantics on the subscription load ensure that no subsequent reads in the reader thread are reordered before the load. Together, they create a synchronizes-with relationship. If the reader loads the pointer value written by the writer, the reader sees all writes that happened before the release store in the writer.

Relaxed atomics do not provide this ordering. They guarantee atomicity but not visibility ordering. A relaxed store can be reordered with prior stores by the compiler or CPU. A relaxed load can be reordered with subsequent loads. Using relaxed atomics for publication and subscription is almost always a bug.

Fences can be used instead of acquire and release operations. A release fence before a relaxed store can provide release semantics. An acquire fence after a relaxed load can provide acquire semantics. Fences are sometimes more efficient when multiple operations need to be ordered, but they are easier to misplace. Acquire and release operations are usually clearer.

Compiler barriers are not memory barriers. A compiler barrier prevents the compiler from reordering operations, but it does not prevent the CPU from reordering them. On weakly ordered architectures, a compiler barrier alone is insufficient. Conversely, a memory barrier usually implies a compiler barrier, but it is still good practice to use the standard atomic operations rather than hand-written assembly.

Volatile is not a synchronization primitive. In C and C++, volatile tells the compiler that the object may change in ways the compiler cannot see, but it does not provide atomicity or inter-thread ordering. Using volatile for RCU publication is a common mistake. It may work on some compilers and architectures by accident, but it is not portable and not correct under the C11 memory model.

Address dependencies are a subtle area. Some architectures, like Linux on DEC Alpha, historically required explicit read barriers even for dependent loads. Modern architectures often respect address dependencies, but the C11 memory model does not provide a portable consume operation that is universally cheap. As a result, portable RCU implementations tend to use acquire semantics for pointer loads. This may cost slightly more than a dependency-based load, but it is correct and portable.

## A Minimal User-Space RCU Sketch

It is useful to sketch a minimal QSBR-style RCU implementation to understand the moving parts. This is not production code. It omits many details: signal handling, fork handling, thread exit, memory barriers, and scalability. But it shows the core idea.

We need a global generation counter. Each thread has a per-thread state: either inactive, active in the current generation, or active in an old generation. When a thread enters a read-side critical section, it records the current generation. When it exits, it marks itself as inactive. A writer that wants to wait for a grace period increments the global generation, then waits until every registered thread is either inactive or has recorded a generation newer than the old one.

```c
// This is a simplified sketch, not production code.
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>

#define MAX_THREADS 128

struct rcu_thread {
    atomic_uint generation;
    atomic_bool registered;
};

static struct rcu_thread threads[MAX_THREADS];
static atomic_uint global_generation;

void rcu_register(int tid) {
    atomic_store_explicit(&threads[tid].generation, 0, memory_order_relaxed);
    atomic_store_explicit(&threads[tid].registered, true, memory_order_release);
}

void rcu_read_lock(int tid) {
    unsigned gen = atomic_load_explicit(&global_generation, memory_order_acquire);
    atomic_store_explicit(&threads[tid].generation, gen, memory_order_release);
}

void rcu_read_unlock(int tid) {
    atomic_store_explicit(&threads[tid].generation, 0, memory_order_release);
}

void synchronize_rcu(void) {
    unsigned old = atomic_load_explicit(&global_generation, memory_order_relaxed);
    unsigned new = old + 1;
    atomic_store_explicit(&global_generation, new, memory_order_release);

    for (int i = 0; i < MAX_THREADS; i++) {
        if (!atomic_load_explicit(&threads[i].registered, memory_order_acquire)) {
            continue;
        }
        for (;;) {
            unsigned gen = atomic_load_explicit(&threads[i].generation, memory_order_acquire);
            if (gen == 0 || gen > old) {
                break;
            }
        }
    }
}
```

This sketch has many problems. A thread that is preempted inside rcu_read_lock but before storing its generation could be missed. A thread that exits without unregistering could stall synchronize_rcu forever. The global generation counter is a contended cache line. The writer spins on every thread, which does not scale. The memory ordering is not sufficient for all architectures. It also does not handle nested read-side critical sections. But it illustrates the basic contract: readers announce the generation they are using, and the writer waits until no reader is using an old generation.

Production libraries solve these problems with per-thread data, scalable grace-period detection, and careful memory ordering. The sketch is useful for understanding, not for deployment.

## QSBR: Quiescent-State-Based Reclamation

QSBR is one of the simplest user-space RCU flavors. The idea is that the application explicitly tells the RCU library when a thread is outside a read-side critical section. This is usually done by calling a function like rcu_quiescent_state at natural quiescent points: at the top of a loop, after processing a batch of work, or when the thread is about to block.

QSBR has extremely low read-side overhead. Entering and leaving a read-side critical section may only update a thread-local variable. There are no atomic operations, no shared cache-line writes, and no signals. The cost is that the application must cooperate. If a thread forgets to call rcu_quiescent_state, grace periods stall. If a thread calls it while inside a read-side critical section, the library may incorrectly conclude that the thread is quiescent, leading to premature freeing and use-after-free.

QSBR is a good fit for event loops, worker threads that process batches, and applications that already have natural quiescent points. It is a poor fit for threads that block for long periods without calling the quiescent-state function, or for libraries that cannot require application cooperation.

In liburcu, QSBR is available as urcu-qsbr. The API is similar to other flavors: rcu_read_lock, rcu_read_unlock, synchronize_rcu, call_rcu, rcu_assign_pointer, and rcu_dereference. The difference is in the grace-period detection. The application must call rcu_quiescent_state periodically. The library also provides rcu_thread_offline and rcu_thread_online for threads that are temporarily not participating in RCU.

## Signal-Based RCU

Signal-based RCU uses signals to force threads through a quiescent state. The library sends a signal to each registered thread. The signal handler runs and marks the thread as quiescent. Because the signal handler runs in the context of the thread, the thread cannot be inside a read-side critical section at that moment unless the signal is delivered inside the critical section. The library must ensure that the signal handler does not treat a thread inside a read-side critical section as quiescent. This is usually done by checking a per-thread nesting counter or a thread-local flag in the signal handler. If the thread is inside a critical section, the signal handler does not mark it quiescent; the grace period waits for the thread to leave the section and handle a later signal.

Signal-based RCU has the advantage that it does not require application cooperation. The library can detect quiescent states even if the application never calls a special function. The disadvantage is cost and interference. Sending signals to every thread is expensive. Signals can interrupt system calls, cause EINTR, and interact badly with application signal handlers. A thread that blocks the signal can stall grace periods. A thread that is stopped in a debugger will not handle the signal. A thread that is in a long-running uninterruptible system call may delay signal delivery.

Signal-based RCU is often used as a fallback when membarrier is not available. It is also used in liburcu's urcu-signal flavor. It is not the fastest option, but it is robust in many environments.

## Membarrier-Based RCU

Linux provides the membarrier system call, which can issue memory barriers on other threads. This is a powerful primitive for user-space RCU. If a thread has executed a memory barrier since the grace period began, it cannot still be inside a read-side critical section that started before the grace period. The membarrier system call can be used to force all threads in a process to execute a memory barrier, or to force a specific set of threads.

The membarrier-based approach avoids signals and does not require application cooperation for quiescent-state detection. It does require kernel support. The relevant command is often MEMBARRIER_CMD_PRIVATE_EXPEDITED, which forces a memory barrier on all threads in the process. The first call may be expensive, but subsequent calls can be optimized by the kernel.

Membarrier-based RCU is used in liburcu's urcu-memb flavor. It is often the best choice on modern Linux systems because it combines low read-side overhead with automatic quiescent-state detection. However, it is Linux-specific. It may not work in containers with restricted seccomp policies, and it may not be available on older kernels. The library usually falls back to another flavor if membarrier is not available.

## Bulletproof RCU

Bulletproof RCU, often called urcu-bp, is designed for cases where threads cannot be registered in advance or where the library cannot rely on signal or membarrier support. It uses a global registry and a combination of signals and memory barriers. It is more expensive than other flavors but more robust in dynamic environments. It is often used in libraries that cannot require the application to call registration functions. The trade-off is read-side overhead and grace-period latency.

## liburcu in Practice

The Userspace RCU library, usually called liburcu, is the most widely used user-space RCU implementation. It provides several flavors: urcu, urcu-qsbr, urcu-mb, urcu-signal, urcu-bp, and urcu-memb. Each flavor has different performance and portability characteristics.

The core API is consistent across flavors:

```c
#include <urcu.h>

rcu_read_lock();
struct node *p = rcu_dereference(head);
while (p) {
    // use p
    p = rcu_dereference(p->next);
}
rcu_read_unlock();
```

On the write side:

```c
struct node *new_node = malloc(sizeof(*new_node));
new_node->value = value;
new_node->next = rcu_dereference(head);
rcu_assign_pointer(head, new_node);
```

For deletion:

```c
struct node *old = rcu_dereference(head);
rcu_assign_pointer(head, old->next);
synchronize_rcu();
free(old);
```

Or asynchronously:

```c
call_rcu(&old->rcu_head, free_node);
```

The exact types and macros vary by version and flavor. The important point is that the library provides publication and subscription macros that encode the necessary memory ordering. Application code should use those macros rather than raw atomic operations unless it has a specific reason to do otherwise.

liburcu requires threads to be registered. In some flavors, registration is automatic on first use. In others, the application must call rcu_register_thread and rcu_unregister_thread. Threads that are not registered may not participate in grace periods, which can lead to premature freeing or stalled grace periods depending on the flavor. Reading the library documentation for the chosen flavor is essential.

## Designing Data Structures with RCU

RCU is a synchronization mechanism, not a data structure. The data structure must be designed to support RCU's publication and subscription model. The general pattern is: readers traverse a versioned structure without locks; writers create a new version, publish it atomically, wait for a grace period, and free the old version. The structure must be immutable from the reader's perspective during the grace period.

Linked lists are the simplest example. Insertion at the head is a single atomic pointer store. Deletion is a single atomic pointer store to unlink the node. Lookup is a lock-free traversal. The writer waits for a grace period before freeing the deleted node. This works because readers only follow next pointers, and the unlinked node's next pointer remains valid for old readers. The node is not modified after unlinking. If the writer wants to reuse the node, it must not do so until after the grace period.

Hash tables with separate chaining can use RCU for bucket traversal. Each bucket is a linked list. Lookups traverse the chain without locks. Insertions and deletions lock the bucket for the write side, but readers do not take the lock. The writer unlinks the node, waits for a grace period, and frees it. Resizing the hash table is more complex. The writer allocates a new table, rehashes entries, publishes the new table pointer, waits for a grace period, and frees the old table. During the grace period, readers may still be traversing the old table. The old table must remain valid until the grace period ends. This can double memory usage temporarily. The writer must also ensure that entries are not freed while both tables reference them. One approach is to copy entries into the new table and defer freeing the old entries until the grace period ends. Another is to use a reference-counted entry that both tables share, but that adds read-side or write-side overhead.

Radix trees and tries are common in routing and file system code. RCU is a natural fit because lookups are read-mostly and updates are relatively rare. The Linux kernel uses RCU extensively for routing tables, file descriptor tables, and many other structures. User-space routers and network appliances can use similar designs. The key is that nodes are published atomically and never modified in place in a way that breaks readers. Node replacement is done by allocating a new node, copying the relevant fields, publishing the new node, and deferring the old node's free.

Configuration snapshots are another common use case. The application maintains an atomic pointer to an immutable configuration object. Readers load the pointer and use the configuration without locks. When the configuration changes, a writer builds a new configuration object, publishes it atomically, waits for a grace period, and frees the old object. This gives readers a consistent view of the configuration for the duration of their read-side critical section. It is simple and effective. The main cost is that the entire configuration must be copied on update. If the configuration is large, updates are expensive. If updates are frequent, RCU is the wrong tool.

## Example: RCU-Protected Singly Linked List

Let us look at a more complete example of an RCU-protected singly linked list. The example uses C11 atomics for clarity, but production code should use a library like liburcu.

```c
#include <stdatomic.h>
#include <stdlib.h>
#include <stdbool.h>

struct node {
    int value;
    _Atomic(struct node *) next;
};

static _Atomic(struct node *) head;

void list_insert(int value) {
    struct node *n = malloc(sizeof(*n));
    n->value = value;
    struct node *old = atomic_load_explicit(&head, memory_order_acquire);
    atomic_store_explicit(&n->next, old, memory_order_relaxed);
    atomic_store_explicit(&head, n, memory_order_release);
}

bool list_contains(int value) {
    struct node *p = atomic_load_explicit(&head, memory_order_acquire);
    while (p) {
        if (p->value == value) {
            return true;
        }
        p = atomic_load_explicit(&p->next, memory_order_acquire);
    }
    return false;
}

bool list_remove(int value) {
    struct node *prev = NULL;
    struct node *p = atomic_load_explicit(&head, memory_order_acquire);
    while (p) {
        if (p->value == value) {
            struct node *next = atomic_load_explicit(&p->next, memory_order_acquire);
            if (prev) {
                atomic_store_explicit(&prev->next, next, memory_order_release);
            } else {
                atomic_store_explicit(&head, next, memory_order_release);
            }
            // Wait for grace period before freeing p.
            synchronize_rcu();
            free(p);
            return true;
        }
        prev = p;
        p = atomic_load_explicit(&p->next, memory_order_acquire);
    }
    return false;
}
```

This example is not thread-safe for concurrent writers. Two writers removing different nodes could race on prev->next. A production implementation would use a lock for writers or a more sophisticated lock-free algorithm. The example also assumes that synchronize_rcu is available and correct. It does not handle the case where a reader is traversing the node when it is freed. The grace period ensures that no reader is still inside a read-side critical section that started before the unlink. But the example does not show the read-side critical section. In a real implementation, list_contains would be called inside rcu_read_lock and rcu_read_unlock.

The important pattern is that the reader never takes a lock, never increments a reference count, and never writes to shared state. The writer pays the cost of synchronization and deferred free. This is the essence of RCU.

## Example: RCU-Protected Hash Table

A hash table with separate chaining is a natural extension. Each bucket is a linked list. Lookups traverse the chain under RCU. Insertions and deletions take a per-bucket lock. The writer unlinks the node, waits for a grace period, and frees it.

```c
#define BUCKETS 1024

struct entry {
    int key;
    int value;
    _Atomic(struct entry *) next;
};

static _Atomic(struct entry *) buckets[BUCKETS];

struct entry *hash_lookup(int key) {
    unsigned idx = key % BUCKETS;
    struct entry *p = atomic_load_explicit(&buckets[idx], memory_order_acquire);
    while (p) {
        if (p->key == key) {
            return p;
        }
        p = atomic_load_explicit(&p->next, memory_order_acquire);
    }
    return NULL;
}

void hash_insert(int key, int value) {
    unsigned idx = key % BUCKETS;
    struct entry *n = malloc(sizeof(*n));
    n->key = key;
    n->value = value;
    struct entry *old = atomic_load_explicit(&buckets[idx], memory_order_acquire);
    atomic_store_explicit(&n->next, old, memory_order_relaxed);
    atomic_store_explicit(&buckets[idx], n, memory_order_release);
}

bool hash_remove(int key) {
    unsigned idx = key % BUCKETS;
    struct entry *prev = NULL;
    struct entry *p = atomic_load_explicit(&buckets[idx], memory_order_acquire);
    while (p) {
        if (p->key == key) {
            struct entry *next = atomic_load_explicit(&p->next, memory_order_acquire);
            if (prev) {
                atomic_store_explicit(&prev->next, next, memory_order_release);
            } else {
                atomic_store_explicit(&buckets[idx], next, memory_order_release);
            }
            synchronize_rcu();
            free(p);
            return true;
        }
        prev = p;
        p = atomic_load_explicit(&p->next, memory_order_acquire);
    }
    return false;
}
```

Again, this example is simplified. It does not lock the bucket for writers, so concurrent insertions and removals can corrupt the chain. It also does not handle resizing. A real hash table would use a per-bucket mutex or spinlock for writers, and readers would still be lock-free. Resizing would require publishing a new table and deferring the old table's free. The old table's entries might be shared with the new table, so the writer must either copy entries or use a reference-counting scheme. This is where RCU design becomes non-trivial.

## Example: Read-Mostly Configuration Snapshot

The configuration snapshot pattern is one of the cleanest uses of RCU. The application maintains a single atomic pointer to an immutable configuration object. Readers load the pointer once and use the configuration for the duration of their read-side critical section. Writers build a new configuration, publish it, wait for a grace period, and free the old one.

```c
struct config {
    int max_connections;
    int timeout_ms;
    char *log_level;
};

static _Atomic(struct config *) current_config;

void config_update(int max_connections, int timeout_ms, char *log_level) {
    struct config *new_cfg = malloc(sizeof(*new_cfg));
    new_cfg->max_connections = max_connections;
    new_cfg->timeout_ms = timeout_ms;
    new_cfg->log_level = log_level;
    struct config *old = atomic_exchange_explicit(&current_config, new_cfg, memory_order_acq_rel);
    synchronize_rcu();
    free(old->log_level);
    free(old);
}

void handle_request(void) {
    rcu_read_lock();
    struct config *cfg = atomic_load_explicit(&current_config, memory_order_acquire);
    int timeout = cfg->timeout_ms;
    // use cfg->max_connections, cfg->log_level, etc.
    rcu_read_unlock();
}
```

This pattern gives readers a consistent snapshot. The update is atomic. The old configuration is freed only after all readers that might have seen it have finished. The cost is that the entire configuration is copied on every update. If the configuration is large or updates are frequent, this is expensive. But for read-mostly configuration, it is simple and effective.

## Grace Period Latency and Throughput

Grace period latency is the time between a writer starting to wait for a grace period and the grace period ending. It determines how long an unlinked object remains allocated. If grace periods are long, memory usage grows. If grace periods are short, writers can free memory quickly, but the RCU library may need to work harder to detect quiescent states.

Readers directly affect grace period latency. A reader that stays in a read-side critical section for a long time delays the grace period. In the kernel, long read-side critical sections are discouraged. In user space, the same rule applies. A reader that performs a blocking system call inside a read-side critical section can stall grace periods indefinitely. A reader that loops over a large data structure without exiting the read-side critical section can also stall grace periods. The RCU library cannot force a reader to exit. It can only wait.

Writers can batch their frees. Instead of calling synchronize_rcu for every deletion, a writer can unlink many objects, call synchronize_rcu once, and then free all of them. This amortizes the grace period cost. It also increases memory usage because all unlinked objects remain allocated until the batch is freed. The trade-off is between memory bloat and grace period overhead.

Asynchronous callbacks can also batch. call_rcu registers a callback. The RCU library processes callbacks after a grace period. If many callbacks are registered, the library can process them in a batch. This is more efficient than synchronous waiting for each object. However, callback backlog can grow if callbacks are registered faster than they are processed. The library must have a way to limit backlog or apply backpressure.

Grace period latency also depends on the number of threads. More threads mean more quiescent states to track. A scalable RCU implementation uses hierarchical or per-thread data structures to avoid a single global bottleneck. liburcu uses per-thread counters and a global generation counter. The writer may need to scan all threads, but the scan is usually short because most threads are quiescent most of the time. On large machines, a hierarchical design can reduce the cost.

## RCU vs Hazard Pointers

Hazard pointers and RCU both solve the deferred reclamation problem, but they make different trade-offs. Hazard pointers require readers to publish the addresses they are using. A writer scans all hazard slots before freeing an object. If an object appears in a hazard slot, the writer defers its free. Hazard pointers give bounded memory usage and do not require a global grace period. They can be used with non-blocking writers. The read-side cost is the cost of publishing and clearing hazards, which involves atomic stores and memory barriers. The write-side cost is scanning hazard slots.

RCU gives readers a cheaper read-side path. In the best case, rcu_read_lock and rcu_read_unlock are no-ops or thread-local updates. The writer waits for a grace period, which is a global or per-thread synchronization operation. RCU can tolerate unbounded memory usage if grace periods are delayed. Hazard pointers are better when memory usage must be bounded and when writers cannot wait for a global grace period.

In practice, RCU is often preferred for read-mostly data structures where readers outnumber writers by a large margin. Hazard pointers are preferred for data structures where writers need to make progress independently of readers, or where memory must be reclaimed promptly. Some systems use a hybrid: RCU for the common case and hazard pointers for objects that need prompt reclamation.

## RCU vs Epoch-Based Reclamation

Epoch-based reclamation, often abbreviated EBR, is similar to RCU. Readers announce an epoch. Writers advance a global epoch. When all readers have moved past an old epoch, objects retired in that epoch can be freed. EBR is common in lock-free data structures because it has a simple read-side protocol and bounded memory usage if readers make progress.

The difference between EBR and RCU is mostly in the details of quiescent-state detection and the API. EBR usually requires readers to announce an epoch at the start and end of a critical section. RCU may use explicit quiescent states, signals, or membarrier. EBR is often implemented as a library for lock-free data structures, while RCU is a more general synchronization mechanism. The performance characteristics are similar: readers are cheap, writers defer reclamation. The choice depends on the available libraries and the constraints of the system.

## RCU vs Reference Counting

Reference counting is the most intuitive reclamation strategy. Each object has a count. Readers increment the count before use and decrement it after use. The last decrement frees the object. The problem is that the read side pays for atomic operations on a shared cache line. In a read-mostly workload, this can be the dominant cost. RCU moves the cost to the writer and to the grace period. The reader does not touch a shared reference count. This is why RCU scales better for read-mostly data.

Reference counting is still useful for long-lived references. If a thread needs to hold a reference across a blocking operation, RCU's read-side critical section cannot be used because it must not block. In that case, the thread can acquire a reference count or use a sleepable RCU variant. A hybrid design can use RCU for short traversals and reference counting for long-lived references.

## RCU vs Reader-Writer Locks

Reader-writer locks allow multiple readers or one writer. They are simple and well understood. But they have a shared cache-line problem. Readers must update the lock state to acquire the read lock, even if the update is an atomic increment. This creates cache-line bouncing. Writers must wait for all readers to release the lock. Readers block writers, and writers block readers. RCU removes the read-side shared write. Readers do not modify a shared lock state. Writers do not block readers. The cost is deferred reclamation and the requirement that readers do not block.

For very short critical sections with few readers, a reader-writer lock may be faster because it is simpler and has less overhead. For read-mostly workloads with many readers, RCU is usually faster. The exact crossover point depends on the workload, the hardware, and the RCU flavor. There is no universal answer.

## Memory Reclamation Safety

Safety in RCU depends on correctly identifying grace periods. If a grace period ends too early, a reader may still be using an object that the writer frees. This is a use-after-free. If a grace period never ends, memory grows without bound and writers stall. Both are serious.

Thread registration is a common source of bugs. If a thread uses RCU without registering, the library may not track it. A writer may conclude that all readers are gone when the unregistered thread is still inside a read-side critical section. This leads to premature freeing. In liburcu, the registration requirements depend on the flavor. Some flavors register automatically on first rcu_read_lock. Others require explicit rcu_register_thread. The application must follow the library's contract.

Thread exit is another source of bugs. If a thread exits while registered, the library may wait forever for that thread to report a quiescent state. A well-designed library handles thread exit by unregistering the thread automatically or by detecting that the thread is gone. In practice, applications should call rcu_unregister_thread before exiting. If a thread is cancelled or exits abruptly, the library may need a cleanup mechanism.

Signal safety is important for signal-based RCU. The signal handler must be async-signal-safe. It must not call malloc, take mutexes, or perform operations that could deadlock with the interrupted code. The RCU library's signal handler is carefully written, but application signal handlers can interfere. If the application installs its own handler for the same signal, it may break RCU. The library documentation usually specifies which signals it uses and how to coexist with application handlers.

Fork is another hazard. After fork, only one thread exists in the child process. The RCU library's state may be inconsistent. Some libraries provide pthread_atfork handlers to reinitialize state in the child. If the application forks without reinitializing RCU, grace periods may stall or crash. This is a common issue in server applications that fork worker processes.

Shared library unloading is a subtle issue. If a library that uses RCU is unloaded while callbacks are pending, the callback functions may point into unloaded code. The application must ensure that all RCU callbacks are drained before unloading the library. This usually requires a destructor or an explicit shutdown function.

## Debugging and Testing RCU Code

RCU bugs are often timing-dependent. They may appear only under high load, on specific architectures, or after hours of stress testing. Debugging them requires a combination of tools and discipline.

ThreadSanitizer can detect data races, but it may not understand RCU's synchronization. RCU uses atomics and grace periods that are not visible to the sanitizer as traditional locks. Some RCU libraries provide annotations for ThreadSanitizer. Without annotations, ThreadSanitizer may report false positives or miss real bugs. Helgrind and DRD have similar limitations. It is important to understand what the tool can and cannot see.

Stress testing is essential. A test should have many readers, several writers, and a workload that exercises insertion, deletion, and traversal. The test should run for a long time and check for crashes, assertion failures, and memory leaks. It should also measure grace period latency and callback backlog. If the test uses a custom allocator, it can poison freed memory to catch use-after-free. If it uses a memory checker like Valgrind, it may slow down the program and change timing, which can hide or expose bugs.

Deterministic replay can help reproduce bugs. If the system can record thread schedules and replay them, a rare interleaving can be replayed under a debugger. This is complex to set up but valuable for hard bugs.

Model checking can verify the RCU algorithm itself. Tools like TLA+ or Spin can model the grace period protocol and check for safety and liveness. This is more common for library authors than for application developers, but it can be useful when designing a custom RCU variant.

## Performance Considerations

RCU's performance depends on the flavor, the workload, and the hardware. The read side is usually the fast path. In QSBR, rcu_read_lock and rcu_read_unlock may be no-ops. In signal-based RCU, the read side may still be cheap, but the grace period detection is expensive. In membarrier-based RCU, the read side is cheap and grace period detection is relatively efficient on modern Linux.

Cache-line bouncing is a major concern. In a naive RCU implementation, all readers update a global counter or a global generation. That counter is a shared cache line. Every reader write invalidates the cache line on other cores. This is called false sharing or true sharing depending on the layout. A scalable RCU implementation uses per-thread counters or per-CPU data to avoid this. The writer may need to scan per-thread data, but the scan is usually read-mostly and can be optimized.

NUMA effects matter. On a multi-socket system, a global counter may be on a remote NUMA node for some threads. Accessing it is slow. Per-thread data can be allocated on the local node. The RCU library should be NUMA-aware or at least not make NUMA effects worse. In practice, most user-space RCU libraries are designed for general-purpose use and may not be fully NUMA-optimized. Applications with extreme NUMA requirements may need a custom design.

Callback processing can become a bottleneck. If callbacks are processed by a single thread, that thread may not keep up with the rate of call_rcu. The callback queue grows, memory usage increases, and grace periods may be delayed. Some libraries allow multiple callback processing threads or integrate callback processing into the application's event loop. The application should monitor callback backlog and apply backpressure if necessary.

Memory allocator behavior also matters. RCU defers frees. If the allocator returns memory to the OS eagerly, the process may repeatedly grow and shrink. If the allocator caches freed memory, the process may hold onto memory longer. In some cases, it is better to use a custom allocator or a memory pool for RCU-protected objects. The allocator must be safe to call from the RCU callback context. If callbacks run in a signal handler or a restricted context, the allocator must be async-signal-safe or the library must defer callbacks to a safe context.

## When Not to Use RCU

RCU is not a universal synchronization primitive. It is a poor choice when updates are frequent. If writers update the data structure as often as readers read it, the cost of grace periods and deferred frees dominates. A lock or a different concurrent data structure may be better.

RCU is also a poor choice when readers must block. If a reader needs to perform a blocking system call, sleep, or wait on a condition variable while holding a reference, RCU's read-side critical section cannot be used. Sleepable RCU variants exist in the kernel, but they are not as widely available in user space. In user space, a reader that needs to block should copy the data it needs and exit the read-side critical section, or use reference counting.

RCU is a poor choice when memory usage must be tightly bounded. Deferred reclamation means that unlinked objects remain allocated until a grace period ends. If grace periods are delayed by a long-running reader, memory usage can spike. In systems with hard memory limits, this can cause OOM kills. Hazard pointers or reference counting may be safer.

RCU is a poor choice when the data structure cannot be made immutable. If readers traverse a structure that writers mutate in place, RCU does not protect them. The writer must create a new version and publish it atomically. If the data structure is too large or too complex to copy, RCU may not be practical. In some cases, a hybrid approach with fine-grained locks and RCU for the top-level pointer can work.

RCU is a poor choice when simplicity is more important than performance. RCU has a subtle contract. It requires careful memory ordering, thread registration, and grace period management. A mutex or a reader-writer lock is easier to reason about. If the performance benefit is small, the complexity may not be justified.

## Advanced Topics

### Expedited Grace Periods

Some RCU implementations provide expedited grace periods. An expedited grace period tries to end as quickly as possible, often by sending IPIs or signals to all threads. This is useful when a writer cannot wait for a normal grace period. The cost is higher: expedited grace periods consume more CPU and may disrupt other threads. They are not a replacement for normal grace periods. They are a tool for special cases, such as memory pressure or shutdown.

### Hierarchical RCU

On large machines, a flat RCU implementation may not scale. Hierarchical RCU organizes threads into a tree. Each leaf tracks a small group of threads. Internal nodes combine the state of their children. A writer waits for the root to indicate that all threads have passed through a quiescent state. This reduces the cost of scanning all threads. The Linux kernel uses hierarchical RCU. User-space libraries may use similar techniques, but the implementation is more complex.

### Sleepable RCU

Sleepable RCU, often called SRCU, allows readers to block inside a read-side critical section. This is useful when a reader needs to perform an operation that may sleep, such as a page fault or a blocking system call. SRCU uses a different grace-period mechanism. Each read-side critical section is associated with a sequence number, and the writer waits for all sequence numbers to advance. SRCU has higher read-side overhead than classic RCU. In user space, SRCU-like behavior can be emulated with reference counting or a dedicated library, but it is not as common as in the kernel.

### RCU and Real-Time Systems

Real-time systems have strict latency requirements. Classic RCU can introduce unbounded grace period latency if a reader is delayed. This is unacceptable in a hard real-time system. Real-time RCU variants use priority inheritance, deadline scheduling, or other techniques to bound grace period latency. In user space, a real-time application may use RCU only if it can guarantee that readers do not block and that grace periods are bounded. Otherwise, a different synchronization mechanism is needed.

### RCU and Persistent Memory

Persistent memory introduces new challenges for RCU. Objects in persistent memory must survive crashes. Deferred reclamation must be crash-consistent. If a writer unlinks an object and crashes before freeing it, the object may remain allocated after reboot. If a writer frees an object and crashes before persisting the unlink, the object may be lost. RCU's grace periods are about thread synchronization, not crash recovery. Using RCU with persistent memory requires an additional recovery protocol, such as a write-ahead log or a persistent allocator with crash consistency. This is an active area of research and engineering.

### RCU and GPUs

GPUs have different memory models and synchronization primitives. RCU as described here does not map directly to GPU programming. However, the idea of deferred reclamation appears in GPU memory management. A GPU kernel may hold references to buffers that the host wants to free. The host must wait until all kernels using the buffer have completed. This is similar to a grace period, but the mechanism is different. CUDA streams and events, or Vulkan fences, provide the synchronization. The concepts are related but the implementation is not RCU.

## API Design for a User-Space RCU Library

If you are designing a user-space RCU library, the API must balance simplicity, performance, and safety. The core operations are:

- rcu_read_lock and rcu_read_unlock: enter and exit a read-side critical section.
- rcu_dereference: load an RCU-protected pointer with acquire semantics.
- rcu_assign_pointer: store an RCU-protected pointer with release semantics.
- synchronize_rcu: wait for a grace period.
- call_rcu: register a callback to be invoked after a grace period.
- rcu_register_thread and rcu_unregister_thread: register and unregister threads.
- rcu_quiescent_state: report a quiescent state for QSBR flavors.

The API should be usable from C and C++. It should provide macros that work with different pointer types. It should document the memory ordering guarantees. It should specify which operations are safe to call from signal handlers. It should handle fork, thread exit, and library unloading.

A good library provides multiple flavors so the application can choose the best trade-off. It should have a clear default flavor and a way to select another flavor at compile time or link time. It should provide a way to query grace period statistics and callback backlog. It should have a test suite that covers stress, race conditions, and architecture-specific memory ordering.

## Common Pitfalls

Forgetting memory barriers on publication or subscription is the most common bug. It may work on x86 and fail on Arm. It may work in a test and fail in production. Always use the library's macros or standard atomics with acquire and release semantics.

Using a freed pointer after a grace period is another common bug. If a writer unlinks an object and then frees it after synchronize_rcu, no reader that started before the unlink should still hold a reference. But a reader that started after the unlink cannot reach the object because it is no longer linked. If the object is still reachable through another path, or if the reader caches the pointer outside the read-side critical section, the object may be used after free. RCU does not protect pointers held outside a read-side critical section.

Blocking inside a read-side critical section is a bug in classic RCU. It can stall grace periods indefinitely. If a reader needs to block, it should copy the data it needs and exit the critical section, or use a sleepable RCU variant.

Long read-side critical sections delay grace periods. Even if the reader does not block, staying in the critical section for a long time prevents the writer from reclaiming memory. Keep read-side critical sections short.

Missing thread registration can cause premature freeing. If the library does not track a thread, it may not wait for that thread's read-side critical sections. Always follow the library's registration rules.

Signal handler issues can break signal-based RCU. If the application installs a handler for the same signal, it may interfere with RCU. If the application blocks the signal, grace periods may stall. Check the library documentation.

Fork without reinitialization can cause deadlocks or crashes. Use pthread_atfork handlers if the library provides them. If not, avoid forking after RCU is initialized, or reinitialize RCU in the child.

Destructor ordering can cause use-after-free if a library is unloaded while callbacks are pending. Drain callbacks before unloading.

Nested read-side critical section imbalance can cause a thread to be considered permanently in a critical section. Always balance rcu_read_lock and rcu_read_unlock.

Writer starvation is possible if readers continuously enter read-side critical sections and the grace period never sees a quiescent state. In practice, this is rare because threads eventually context switch or report quiescent states. But in a tight loop with no quiescent states, it can happen. QSBR requires explicit quiescent states. If a thread never calls rcu_quiescent_state, grace periods stall. This is a design bug, not a library bug.

Callback backlog can cause memory exhaustion. Monitor the number of pending callbacks and apply backpressure if necessary.

Memory ordering on weakly ordered architectures is a common source of bugs. Test on Arm or Power if you support them. Do not assume x86 ordering.

## Conclusion

User-space RCU is a powerful tool for read-mostly data structures. It gives readers a nearly free path and moves the cost of synchronization to writers and to deferred reclamation. The contract is simple: readers enter and exit read-side critical sections without blocking; writers publish new versions atomically, wait for a grace period, and then free old versions. The subtlety is in the details: memory ordering, quiescent-state detection, thread registration, signal safety, fork handling, and callback management.

RCU is not a replacement for locks. It is a specialized mechanism that works best when reads dominate writes, when readers can avoid blocking, and when the data structure can be versioned. It is a poor choice for write-heavy workloads, for readers that need to block, and for systems with hard memory bounds. Hazard pointers, epoch-based reclamation, reference counting, and reader-writer locks all have their place. The engineering decision is about which cost you are willing to pay.

The most practical advice is to use an existing user-space RCU library rather than implementing your own. liburcu is mature, portable, and well tested. It provides multiple flavors and handles many of the edge cases that are easy to miss. If you must implement your own, start with a clear model of grace periods, use standard atomics with acquire and release semantics, test on multiple architectures, and stress the system with long-running readers and frequent writers. RCU rewards careful design and punishes shortcuts. Used correctly, it can turn a lock-contended read-mostly structure into a scalable, low-latency system. Used incorrectly, it can produce the most confusing use-after-free bugs you will ever debug.

The field continues to evolve. New kernels provide better membarrier support. New hardware changes the cost of memory barriers. New workloads stress different assumptions. The core idea, however, remains the same: let readers read, let writers publish, and free only when the old readers are gone.
