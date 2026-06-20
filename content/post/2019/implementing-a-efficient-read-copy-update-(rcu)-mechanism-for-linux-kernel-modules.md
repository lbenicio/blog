---
title: "Implementing A Efficient Read Copy Update (Rcu) Mechanism For Linux Kernel Modules"
description: "A comprehensive technical exploration of implementing a efficient read copy update (rcu) mechanism for linux kernel modules, covering key concepts, practical implementations, and real-world applications."
date: "2019-09-08"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/implementing-a-efficient-read-copy-update-(rcu)-mechanism-for-linux-kernel-modules.png"
coverAlt: "Technical visualization representing implementing a efficient read copy update (rcu) mechanism for linux kernel modules"
---

# The Silent Hero of Concurrency: Implementing an Efficient Read-Copy Update (RCU) Mechanism for Linux Kernel Modules

## Introduction: The Kernel’s Invisible City Planner

The kernel is a city that never sleeps. Inside this sprawling metropolis of data structures, millions of concurrent transactions—system calls, interrupts, context switches—whirl past every second. At the heart of this chaos lies a fundamental tension: the need for speed versus the ironclad requirement of consistency. For decades, the standard solution to this tension was the lock: the mutex, the spinlock, the semaphore. These are the traffic cops of the kernel, stopping one lane of execution so another can safely cross. But what happens when the traffic never stops? What happens when the _readers_ outnumber the _writers_ ten thousand to one?

The lock becomes a bottleneck. The very mechanism designed to ensure safety begins to suffocate performance. Every read operation, no matter how trivial—a simple pointer traversal to look up a routing table entry, a hash table probe to find a file’s dentry—must take the hit of acquiring and releasing a lock. In a highly concurrent system, these millions of microseconds of waiting add up to a palpable drag on the entire machine.

This is the problem that **Read-Copy Update (RCU)** was born to solve. If conventional locking is the city’s stoplight, RCU is a tiered highway system with flyover lanes. It allows readers to fly through a data structure at near-zero overhead, never waiting, never blocking, while writers perform their modifications in the shadows. It is one of the most elegant, powerful, and intellectually satisfying synchronization mechanisms ever devised. It is also, notoriously, one of the most difficult to implement correctly.

Understanding RCU is a rite of passage for the serious kernel developer. But why does it matter to _you_, a module author? The Linux kernel itself is a testament to RCU’s power. The networking subsystem uses RCU for route caches and neighbor tables. The VFS uses it for dentry caches and file system mounts. Even the memory management layer relies on RCU to safely free memory after deferred operations. When you use a modern Web server, a database, or a container runtime on Linux, you are indirectly depending on RCU every millisecond.

In this article, we will peel back the layers of RCU, from its high-level philosophy down to the gritty implementation details required to build a correct and efficient RCU mechanism for a kernel module. We will write real code, measure performance, and explore the subtle pitfalls that make RCU both a joy and a terror to wield. By the end, you will not only understand how RCU works but also appreciate why it is the silent hero of concurrent computing.

---

## 1. The Bottleneck of Conventional Locking

Before diving into RCU, let’s quantify the problem. Consider a simple kernel data structure: a linked list of active network connections. Under heavy load, thousands of CPUs may need to traverse this list to forward packets. At the same time, a new connection is established or an old one tears down perhaps once every few milliseconds. The ratio of readers to writers is astronomical.

With a traditional reader-writer spinlock, every reader must acquire the lock for reading. Even though multiple readers can hold the lock concurrently, the acquisition and release still impose memory barriers and cache line bouncing. On a typical x86 CPU, a spin_lock() followed by spin_unlock() costs about 20–50 nanoseconds in the uncontended case. In a contended scenario—when many CPUs try to acquire the same cache line—the cost can skyrocket to hundreds of nanoseconds or even microseconds.

Multiply that by millions of operations per second, and the overhead becomes a substantial fraction of CPU time. Worse, a write that updates the list must wait for all readers to finish, which can take an unpredictable amount of time if a long-held read lock exists. In practice, reader-writer locks can suffer from writer starvation, where a constant stream of readers prevents any writer from making progress.

RCU eliminates both problems: readers do zero synchronization (no locks, no atomic operations) beyond a lightweight memory barrier, and writers never block on readers. Instead, the writer creates a new version of the data, publishes it atomically, and then waits for all pre-existing readers to finish before reclaiming the old version. This “wait” is the grace period.

---

## 2. Conceptual Overview of RCU

At its core, RCU is based on a simple invariant: **a reader that begins reading before a writer completes its update will continue to see the old version; a reader that starts after the update is published will see the new version.** This is achieved through a combination of pointer assignment (publish) and delayed reclamation (defer).

The three key operations are:

- **Read-side critical section:** Marked by `rcu_read_lock()` and `rcu_read_unlock()`. During this time, the reader is said to be “in a quiescent state” relative to the RCU subsystem. The reader simply dereferences the pointer protected by RCU.
- **Update (publish):** The writer modifies the data structure by allocating new memory, copying old data, modifying it, then atomically swapping the pointer using `rcu_assign_pointer()`.
- **Grace period and reclamation:** After publishing the new version, the writer calls `synchronize_rcu()` or `call_rcu()` to wait until all readers that might have seen the old pointer have finished their critical sections. Only then can the old memory be freed.

The genius of RCU is that the read-side operations are extremely cheap on modern hardware. `rcu_read_lock()` often disables preemption (on !PREEMPT kernels) or does nothing on a PREEMPT kernel (since it simply marks the task as not preemptible during the critical section). The read-side barrier `rcu_dereference()` is a simple `smp_read_barrier_depends()` (or no-op on architectures like x86 that guarantee dependency ordering). Thus, a reader typically executes only a couple of assembly instructions.

---

## 3. Historical Context: The Birth of RCU

RCU was invented by Paul E. McKenney in the early 1990s for the DYNIX/ptx ® operating system. It was later adopted into the Linux kernel in 2002, primarily by Dipankar Sarma and Paul McKenney. The original motivation came from a need to scale a kernel that was moving from uniprocessor to large SMP systems. Traditional locking simply would not work for read-mostly data structures like the TCP connection table or the filesystem dcache.

The first Linux RCU implementation was quite different from today’s. It used a global grace-period counter and per-CPU quiescent state tracking. Over two decades, RCU evolved through many improvements: tree-based grace-period detection (to reduce cache line contention), preemptible RCU for real-time kernels, SRCU (Sleepable RCU) for readers that need to sleep, and RCU-bh for bottom halves. The Linux kernel now contains more than 10,000 lines of RCU code, making it one of the most heavily tested and optimized synchronization mechanisms in existence.

---

## 4. Anatomy of an RCU Implementation

To implement RCU in a kernel module, we don’t need to reinvent the entire subsystem—the kernel provides a rich RCU API. However, understanding the internal machinery helps us use it correctly and efficiently. Let’s dissect the key components.

### 4.1 Quiescent States

A quiescent state is a point in the execution of a CPU where it is guaranteed not to be holding any RCU read-side lock. For the classic RCU implementation, these occur during:

- Context switch (if the kernel is not preemptible inside an RCU critical section)
- Kernel idle loop (when a CPU is idle, it cannot be in an RCU read-side critical section)
- User mode execution (if the kernel uses RCU-sched)

The RCU subsystem tracks which CPUs have passed through a quiescent state since the start of a grace period. Once all CPUs have reported a quiescent state, the grace period ends, and deferred callbacks can be executed.

### 4.2 Grace Period Detection

Grace period detection is the core complexity of RCU. Linux uses a hierarchical (tree) structure of per-CPU and per-node data to minimize global cache line bouncing. The root of the tree, `rcu_state`, coordinates the overall grace period. Each leaf node corresponds to a group of CPUs (e.g., per-core). When a new grace period begins, the root increments a counter, and each leaf node requests that its CPUs report quiescent states. As CPUs report, the leaf nodes aggregate and eventually signal the root. Once all leaves are done, the grace period is complete.

This tree architecture scales to thousands of CPUs while keeping the overhead small.

### 4.3 RCU Callbacks

The writer must defer the freeing of old data until after a grace period. Two main mechanisms exist:

- **`synchronize_rcu()`:** Blocks the caller until a grace period has passed. Simple to use but can cause latency.
- **`call_rcu(callback_struct, func)`:** Schedules a callback to be executed after a grace period. Non-blocking, often used in interrupt context or when latency matters.

The callbacks are stored in per-CPU lists. When a grace period ends, the RCU core invokes all pending callbacks on each CPU. This is done in a softirq context to minimize latency.

### 4.4 Read-Side Primitives

```c
rcu_read_lock();
// Preemption is disabled (or the task is marked non-preemptible)
// Then:
p = rcu_dereference(ptr);
// Access p safely
rcu_read_unlock();
```

`rcu_dereference()` is a read-side barrier that ensures the pointer value is fetched after all previous memory accesses. On most architectures, this is a no-op if the compiler emits proper address dependencies. But to be portable, the macro includes a `smp_read_barrier_depends()`.

### 4.5 Write-Side Primitives

```c
new = kmalloc(sizeof(*new), GFP_KERNEL);
*new = *old; // copy
new->field = new_value;
rcu_assign_pointer(ptr, new);
// Now readers see the new version
// ... later ...
synchronize_rcu();
kfree(old);
```

`rcu_assign_pointer()` is a store-release barrier that ensures all writes to the new structure are visible before the pointer assignment.

---

## 5. Implementing an RCU-Protected linked list in a Kernel Module

Let’s build a concrete example. We’ll create a kernel module that maintains a list of network endpoints (IP address + port). The list is read often (every packet forward) and updated rarely (new connection, timeout). We’ll implement insert and delete operations using RCU.

### 5.1 Data Structures

```c
#include <linux/slab.h>
#include <linux/rcupdate.h>
#include <linux/list.h>

struct endpoint {
    struct rcu_head rcu;          // For deferred freeing
    struct list_head list;        // Embedded list node
    __be32 ip;
    __be16 port;
};

static LIST_HEAD(endpoint_list);
static DEFINE_SPINLOCK(endpoint_lock); // For serializing writers
```

We use `rcu_head` inside the element so we can pass it to `call_rcu()`.

### 5.2 Reader

```c
struct endpoint *lookup_endpoint(__be32 ip, __be16 port)
{
    struct endpoint *ep;
    rcu_read_lock();
    list_for_each_entry_rcu(ep, &endpoint_list, list) {
        if (ep->ip == ip && ep->port == port) {
            rcu_read_unlock();
            return ep;
        }
    }
    rcu_read_unlock();
    return NULL;
}
```

`list_for_each_entry_rcu()` uses `rcu_dereference()` on the next pointer. This works because the list is a circular doubly linked list where the next pointer is updated atomically during insertion/removal.

### 5.3 Writer – Insertion

```c
int add_endpoint(__be32 ip, __be16 port)
{
    struct endpoint *ep;
    ep = kmalloc(sizeof(*ep), GFP_KERNEL);
    if (!ep)
        return -ENOMEM;
    ep->ip = ip;
    ep->port = port;
    INIT_LIST_HEAD(&ep->list);

    spin_lock(&endpoint_lock);
    list_add_rcu(&ep->list, &endpoint_list);
    spin_unlock(&endpoint_lock);
    return 0;
}
```

`list_add_rcu()` calls `rcu_assign_pointer()` to insert the new node after the head. The spinlock ensures only one writer modifies the list at a time (multiple writers are rare; if they were common, we’d need more sophisticated schemes).

### 5.4 Writer – Deletion

```c
void remove_endpoint(struct endpoint *ep)
{
    spin_lock(&endpoint_lock);
    list_del_rcu(&ep->list);
    spin_unlock(&endpoint_lock);
    call_rcu(&ep->rcu, free_endpoint_rcu);
}

static void free_endpoint_rcu(struct rcu_head *head)
{
    struct endpoint *ep = container_of(head, struct endpoint, rcu);
    kfree(ep);
}
```

`list_del_rcu()` detaches the node from the list, making it invisible to future readers. We then schedule `free_endpoint_rcu()` to be called after a grace period. At that point, no readers can still hold a reference to `ep`, so it is safe to free.

### 5.5 Performance Considerations

- The `spinlock` serializes writers, but we could also use `rcu_assign_pointer()` for individual pointer replacements.
- In a module, we must ensure that `call_rcu()` does not sleep—it returns immediately. However, the callback runs in softirq context, so it cannot sleep either.
- On a kernel with `CONFIG_PREEMPT_RT`, `call_rcu()` might be different; but standard kernels are fine.

---

## 6. Under the Hood: How Grace Period Detection Really Works

To truly appreciate RCU, we need to peek at the innards. Let’s trace through a simplified grace period on an x86_64 Linux kernel.

When a writer calls `synchronize_rcu()`, it invokes a series of functions:

1. `synchronize_rcu()` → `synchronize_rcu_expedited()` or a slower path depending on context.
2. The core creates a new grace period (if not already in progress) by incrementing `rcu_state.gpnum`.
3. It sends a reschedule IPI (inter-processor interrupt) to all CPUs that have not yet reported a quiescent state.
4. Each CPU, upon receiving the IPI, notes its current state. If it is in an RCU read-side critical section, it defers reporting until the critical section ends.
5. The CPU reports its quiescent state by writing to its `rcu_data` structure.
6. The tree mechanism aggregates these reports up to the root.
7. Once all CPUs have reported, the root signals the end of the grace period.
8. All pending callbacks on each CPU are executed.

The use of IPIs can be expensive on large systems, which is why expedited grace periods are used sparingly. The normal path uses a tick-based approach: each CPU checks at every timer tick whether it has passed a quiescent state. This avoids IPIs but adds latency (a jiffy or two).

---

## 7. Variants of RCU in the Linux Kernel

The vanilla RCU we described is `rcu_sched` or `rcu_preempt`, depending on kernel configuration. But Linux provides several specialized flavors:

### 7.1 SRCU (Sleepable RCU)

Introduced because classic RCU readers cannot sleep (preemption is disabled). SRCU allows readers to block, making it suitable for slower paths like filesystem lookups that might take a page fault. The API uses `srcu_read_lock()` which returns an index, and `srcu_read_unlock()`. The writer calls `synchronize_srcu()`.

### 7.2 RCU-bh (Bottom Half RCU)

Used in network code where the read-side critical section runs in softirq context. `rcu_read_lock_bh()` disables softirqs instead of preemption, aligning with the networking stack’s locking hierarchy.

### 7.3 RCU-sched

The original “sched” flavor treats the idle loop and user mode as quiescent states. This is the default on non-preemptible kernels.

### 7.4 RCU Tasks

A newer variant for tracing and BPF, where readers may be in userspace or kernel tasks that can be long-running.

Choosing the right variant is critical for correctness. A module that uses `rcu_read_lock()` (which disables preemption) in a context where sleeping is expected will crash or deadlock.

---

## 8. Common Pitfalls and How to Avoid Them

RCU is powerful but unforgiving of mistakes. Here are the most frequent bugs encountered by module authors:

### 8.1 Accessing Freed Memory

If you free memory before the grace period ends, a reader may dereference a dangling pointer. Always use `call_rcu()` or `synchronize_rcu()`.

### 8.2 Using RCU for Write-Heavy Workloads

RCU shines when reads dominate. If updates happen frequently, RCU’s overhead of allocating new memory and deferring frees can overwhelm the allocator. In such cases, a lock-free data structure or a seqcount might be better.

### 8.3 Incorrect Write-Side Serialization

RCU does _not_ protect against concurrent writers. You must use another mechanism (e.g., a mutex) to ensure only one writer modifies the data at a time. For simple pointer replacement (e.g., a single global pointer), `rcu_assign_pointer()` alone is safe because the old pointer is not modified; but for lists, you need a writer lock.

### 8.4 Mixing RCU Flavors

Using `rcu_read_lock()` while expecting an `synchronize_srcu()` to wait for you is a recipe for failure. Each flavor has its own grace period tracking.

### 8.5 Forgetting `rcu_read_unlock()`

A missing unlock will prevent grace periods from ending, causing all subsequent `synchronize_rcu()` calls to block indefinitely. Always pair `rcu_read_lock()` with `rcu_read_unlock()`.

### 8.6 Using `rcu_dereference()` without a pointer dependency

If the CPU reorders loads, a reader might see a partially initialized structure. The `rcu_dereference()` macro includes the necessary barrier to prevent this. However, on alpha architectures, the barrier is more complex; the Linux kernel handles this transparently.

---

## 9. Measuring the Benefit: A Microbenchmark

To convince ourselves (and readers) of the performance advantage, let’s design a microbenchmark in our kernel module. We’ll compare an RCU-protected list traversal against a spinlock-protected one.

### 9.1 Benchmark Setup

We create a list of 1000 endpoints. Then we spawn, say, 8 kthreads, each performing 10 million lookups using either RCU (inner loop with `rcu_read_lock`) or spinlock (inner loop with `read_lock`). We measure wall time using `ktime_get()`.

### 9.2 Expected Results

On a modern x86 multi-core machine, the RCU version will likely be 10–50x faster. The reason is cache line contention: with a spinlock, every read acquisition invalidates the cache line holding the lock across all CPUs. With RCU, there is no shared mutable state—the list pointers are read-only, and each CPU can cache them indefinitely.

### 9.3 Caveats

This benchmark stresses read-only access. Under mixed read/write, RCU’s write overhead (allocation, memcopy, call_rcu) becomes visible. In a real system, the trade-off often favors RCU because writes are rare.

---

## 10. Advanced Techniques: RCU and Per-CPU Data

RCU is not limited to lists. It can protect any data structure where reads are frequent and updates are rare. One elegant pattern is using RCU to manage per-CPU counters.

Suppose we want a global event counter that is incremented very frequently by many CPUs. A single atomic64 would bottleneck. Instead, we can use an array of per-CPU counters and an RCU-protected pointer to that array. When a new CPU comes online, we allocate a new array, copy values, add a new slot, and then `rcu_assign_pointer`. Old readers continue to see the old array; after a grace period we free the old array. This pattern is used in the `percpu_ref` API.

---

## 11. Debugging RCU Issues

When something goes wrong, the kernel’s lockdep and RCU stall detection come to the rescue.

- **RCU stall warnings:** If a CPU fails to report a quiescent state for too long (e.g., because a reader held `rcu_read_lock` for an extended period while preemption was disabled), the kernel prints a “RCU stall” message. This is a strong hint that you forgot to unlock in a critical section.
- **CONFIG_PROVE_RCU:** Enable this configuration to let lockdep check that RCU APIs are used correctly. It will warn if you violate rules like sleeping inside an RCU read-side critical section.
- **CONFIG_RCU_TRACE:** Exposes statistics via debugfs, showing callback queues and grace period lengths.

As a module developer, always test with these options enabled.

---

## 12. Beyond Linux: RCU in Other Contexts

While RCU is most famous in Linux, the concepts apply elsewhere. The urcu library (Userspace RCU) by Mathieu Desnoyers brings RCU to user-space applications. It leverages `membarrier()` system calls and signals to manage grace periods. Many databases and concurrent libraries (like Boost) implement similar patterns.

Understanding RCU at the kernel level gives you a deep insight into memory ordering, cache coherence, and the fundamental trade-offs of concurrency.

---

## Conclusion: The Unsung Symphony

RCU is more than a synchronization primitive; it is a philosophy. It acknowledges that in many real-world systems, the cost of blocking readers is unacceptable, and that deferred reclamation, when carefully orchestrated, can yield massive performance gains. The Linux kernel would not be able to scale to hundreds of CPUs without it.

For a kernel module author, mastering RCU is akin to a city planner understanding how to build overpasses and underpasses to keep traffic flowing. It requires a shift in mindset: instead of thinking “how do I lock this critical section?”, you ask “how can I publish a new version of the data and let the old one naturally die?”

The code we wrote—a simple RCU-protected linked list—is a microcosm of this idea. But behind those few lines lies decades of research, careful engineering, and many subtle barriers. The next time you write a kernel module and encounter a read-mostly data structure, remember the silent hero. Use RCU. Your system will thank you.

---

**References and Further Reading**

1. Paul E. McKenney, “Is Parallel Programming Hard, And, If So, What Can You Do About It?” (free online book)
2. Documentation/RCU/\* – kernel documentation
3. Linux kernel source: kernel/rcu/ directory
4. UrCU: Userspace RCU library (liburcu.org)

---

_This article was written for the curious kernel developer who wants to go beyond spinlocks and mutexes. The code snippets are simplified for clarity; always refer to current kernel headers for the exact API._
