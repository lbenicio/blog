---
title: "An In Depth Look At Concurrent Data Structures: Elimination Backoff Stacks, Michael Scott Queues, And Hazard Pointers"
description: "A comprehensive technical exploration of an in depth look at concurrent data structures: elimination backoff stacks, michael scott queues, and hazard pointers, covering key concepts, practical implementations, and real-world applications."
date: "2019-08-04"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/an-in-depth-look-at-concurrent-data-structures-elimination-backoff-stacks,-michael-scott-queues,-and-hazard-pointers.png"
coverAlt: "Technical visualization representing an in depth look at concurrent data structures: elimination backoff stacks, michael scott queues, and hazard pointers"
---

Here is the expanded blog post, building directly from your provided text and diving deep into the hardware realities, the pathologies of locking, the elegance of lock-free programming, and the practical art of building scalable concurrent data structures.

---

### Parallel Parking: A Deep Dive into Lock-Free, Wait-Free, and the Art of Concurrent Data Structures

The analogy is almost too perfect. Imagine a vast, congested parking lot on Black Friday. The naive, single-threaded world has one gate, one spot, and one parking attendant. Each car must drive up, wait for the car in front to complete its transaction—find a spot, maneuver in, pay—and then the next car proceeds. The throughput is abysmal. The latency for each car is the sum of everyone else's parking time. This is the world of coarse-grained locking: a single mutex protecting an entire data structure, where a single thread holds the keys to the kingdom while every other thread cools its heels in a kernel-level sleep.

Now, imagine that parking lot is your multi-core CPU, and those cars are threads. The "parking spot" is a shared data structure—a work queue, a stack of tasks, a priority queue. In the last two decades, the hardware landscape has undergone a seismic shift. Moore's Law no longer delivers exponential clock speed increases; it delivers more cores. We have traded the single, screaming-fast engine for a fleet of slower, but numerous, workhorses. A modern server chip can have 64, 96, or 128 cores. If you are still using that single parking attendant (a global mutex) to manage access to your data structures, you are paying a terrible tax. You are serializing a fundamentally parallel world. One thread runs; 127 threads watch.

The software community's response to this tectonic shift has been a quiet revolution in how we think about data. We cannot simply throw locks at every problem. Locks are a necessary evil, yes, but they are also the primary impediment to scalability. They cause blocking, priority inversion, and worst of all, **contention**. Contention is the enemy. It’s the traffic jam in our parallel parking lot. When two threads fight for the same lock, the system's performance doesn't just plateau; it often degrades. The overhead of context switching, cache invalidation, and spinning on a lock variable can make a 128-core machine perform _worse_ than a 4-core machine for an embarrassingly parallel workload.

This seemingly paradoxical behavior is the central theme of this post. We are going to dissect _why_ this happens at the level of silicon and cache lines, explore the traditional toolkit of fine-grained locking, and then venture into the fascinating, mind-bending world of lock-free and wait-free data structures. We will see how a humble concurrent stack, a queue, and a hash table can be engineered to allow a thousand cars to park simultaneously without a single attendant getting in the way.

---

#### Part I: The Threshold of Pain – Why Contention Kills Performance

Let's quantify the disaster. When a single thread holds a global mutex, the remaining 127 threads on our hypothetical machine are blocked. They are parked outside the lot, engine idling. But "idling" is a misleading term in computing. Idle threads are not free.

**The Cost of Context Switching**

When Thread B cannot acquire the lock held by Thread A, the operating system's scheduler steps in. It must decide what to do with Thread B. Typically, it will put Thread B to sleep (block it) and context switch to another thread that _can_ run. A context switch involves saving the state of the current thread (registers, program counter, stack pointer) and loading the state of the next thread. This costs thousands of CPU cycles. If Thread B is a high-priority consumer thread trying to read from a work queue, and Thread A is a low-priority producer holding the lock, we have a **priority inversion** problem. The high-priority thread is stalled by the low-priority one. The parking lot attendant (the operating system) has locked the keys in the car.

**The Cache Coherence Catastrophe**

Even worse than context switching is what happens at the cache level. Modern CPUs do not directly access main memory for every load or store. They use a hierarchy of caches (L1, L2, L3). The real magic—and the real horror—of concurrency happens in the **cache coherence protocol**. The most common protocol is MESI (Modified, Exclusive, Shared, Invalid).

Let’s look at a global mutex variable, `lock`, located at memory address `0xFF00`.

- **Thread A** running on Core 1 wants the lock. It executes an atomic `test_and_set` or `compare_and_swap` on `0xFF00`. The cache line containing `0xFF00` is not in Core 1's L1 cache. Core 1 sends a **Read For Ownership (RFO)** request on the bus.
- **Thread B** running on Core 2 also has an interest in `0xFF00`. Before Thread A grabbed the lock, Core 2 had a copy of the line in _Shared_ (S) state.
- Core 1's RFO request invalidates Core 2's copy. The line moves to _Modified_ (M) state in Core 1's L1 cache. Thread A writes a `1` to the lock variable.
- Thread A does its work (the critical section) and releases the lock, writing a `0`.
- Now Thread B spins in a loop, trying to acquire the lock. It reads `0xFF00`. Core 2 issues a standard read request.
- The cache coherence protocol forces Core 1 to write the modified line back to the shared L3 cache. Core 2 can then fetch it.
- Thread B sees the lock is free. It issues another RFO request. Core 1's cache line is invalidated. Core 2 grabs the lock.

What happened here? Every single lock acquisition and release generated a global broadcast on the inter-core bus. This bus is a limited resource. When 128 threads are all fighting for the same lock variable, the bus becomes saturated with RFO messages and invalidation acknowledgements. The memory bandwidth is consumed not by doing useful work, but by fighting over who gets to do the work.

This is called **cache line ping-ponging**. The sole cache line holding the lock variable is bounced like a hot potato between every core in the system. The effective latency of a single locked instruction can explode from a handful of nanoseconds to thousands of nanoseconds as the cache coherency fabric struggles to keep up.

**Amdahl’s Law is Your Nightmare**

The mathematical expression of this pain is Amdahl's Law:

_Speedup = 1 / ((1 - P) + (P / N))_

Where `P` is the parallelizable portion of the program, and `N` is the number of cores.

Because the global mutex serializes the critical section, that portion of the code is **not** parallelizable. If 5% of your workload is spent inside that critical section, your theoretical maximum speedup is:
_Speedup = 1 / (0.05 + (0.95 / 128)) ≈ 1 / (0.05 + 0.007) ≈ 17x_

You have 128 cores, but you can only get 17x the performance of a single core! And this is the _best case_. In reality, cache line ping-ponging adds overhead that doesn't exist on a single core, making the serial portion `P` effectively larger as `N` increases. The performance curve goes up, plateaus, and then begins to **fall**. This is the experience of running a naive, globally-locked program on a modern server.

The solution is clear: we must eliminate the single parking attendant. We must restructure our data structures so that threads can park simultaneously without stepping on each other's toes.

---

#### Part II: The Locking Zoo – Fine-Grained Locks and the Valet Concierge

Before we throw locks away entirely, it's worth examining the intermediate steps. The most obvious response to a single hot lock is to break the data structure into smaller, independently guarded pieces. This is **fine-grained locking**.

**Hand-over-Hand Locking (Lock Coupling)**

The classic example is the concurrent singly-linked list. A global lock prevents any operation from proceeding concurrently. With hand-over-hand locking, we lock a single node, then the next, then release the previous.

```c
// Fine-Grained Hand-over-Hand List Traversal
bool contains(int value) {
    Node* prev = head;
    prev->lock();
    Node* curr = prev->next;
    curr->lock();
    prev->unlock();
    while (curr != nullptr) {
        if (curr->value == value) {
            curr->unlock();
            return true;
        }
        Node* next = curr->next;
        if (next != nullptr) next->lock();
        curr->unlock();
        curr = next;
    }
    return false;
}
```

This allows multiple threads to traverse the list concurrently, provided they are working on different parts of the list. Thread A can be inserting at the head while Thread B is searching near the tail. This is a massive improvement over a global lock.

**The Pitfalls of Fine-Grained Locking**

1.  **Deadlock:** The classic scourge of locking. If Thread A holds the lock on Node 1 and waits for Node 2, while Thread B holds Node 2 and waits for Node 1, the system halts. The standard defense is lock ordering (always lock from head to tail), but this is difficult to enforce automatically.
2.  **Convoying:** Imagine a high-priority thread holding a lock on a busy node. It is preempted by the scheduler. Now every other thread that needs that node (and subsequent nodes) is blocked. A "convoy" of blocked threads forms, waiting for the preempted thread to resume.
3.  **Complexity and Memory Overhead:** Managing the lifecycle of dozens, hundreds, or thousands of mutex objects inside a single data structure is a recipe for bugs. Each lock consumes memory and requires careful initialization and destruction.

**Reader-Writer Locks (RW Locks)**

An excellent optimization for the "read mostly, write seldom" pattern. An RW lock allows multiple concurrent readers, and exclusive access for a single writer.

```c
RWLock lock;
int shared_data = 0;

void reader() {
    lock.read_lock();
    int val = shared_data; // Safe read
    lock.read_unlock();
}

void writer() {
    lock.write_lock();
    shared_data = 42; // Exclusive write
    lock.write_unlock();
}
```

This is the valet system with a dedicated express lane for bikes (readers). A routing table, a DNS cache, or a configuration store is perfectly suited for this. While the reader count is incremented atomically, the problem of contention on the `reader_count` variable itself remains. A constant stream of readers can starve a writer indefinitely. Furthermore, writer starvation is a real threat.

Fine-grained locks are effective up to a point. They are the workhorses of many production databases (PostgreSQL uses LWLocks, a highly optimized spinlock variant). But they are fundamentally blocking. The thread that holds the lock can be preempted, blocking everyone else. To achieve true scalability, we need to enter the world of **lock-freedom**.

---

#### Part III: The Lock-Free Promise – No Keys Required

A data structure is **lock-free** if, at any given time, at least one thread is guaranteed to make progress, regardless of the scheduling of other threads. No thread can be blocked indefinitely by the failure of another thread. This is a radical guarantee. It means concurrent `pop()` and `push()` operations on a stack can never be prevented from completing just because another thread was killed or preempted in the middle of its operation.

The fundamental building block of lock-free data structures is the **Compare-And-Swap (CAS)** atomic instruction.

```c
// CAS: Atomically compare and swap a value
bool compare_and_swap(int* addr, int expected, int new_value) {
    if (*addr == expected) {
        *addr = new_value;
        return true;
    }
    return false;
}
```

Most modern CPUs provide this in hardware (e.g., `cmpxchg` on x86). In C++11 and later, this is exposed via `std::atomic<T>::compare_exchange_weak` and `compare_exchange_strong`.

**Progress Guarantees: The Hierarchy of Freedom**

- **Wait-Freedom:** Every thread makes progress in a finite number of steps. The strongest guarantee, but extremely difficult to achieve. No thread is ever blocked.
- **Lock-Freedom:** System-wide progress is guaranteed. Some thread makes progress. A thread can starve if it keeps losing the CAS race (bad luck), but the system as a whole moves forward.
- **Obstruction-Freedom:** A thread makes progress if it eventually runs in isolation (no other threads actively interfere). The weakest guarantee.

Let's look at the simplest lock-free data structure in the world.

---

#### Part IV: The Treiber Stack – A Masterclass in a Few Lines

The Treiber Stack (1986) implements a lock-free stack using CAS.

```c
#include <atomic>

struct Node {
    int value;
    Node* next;
};

std::atomic<Node*> top{nullptr};

void push(Node* new_node) {
    Node* old_top;
    do {
        old_top = top.load();
        new_node->next = old_top;
    } while (!top.compare_exchange_weak(old_top, new_node));
}

Node* pop() {
    Node* old_top;
    Node* new_top;
    do {
        old_top = top.load();
        if (old_top == nullptr) return nullptr; // Empty stack
        new_top = old_top->next;
    } while (!top.compare_exchange_weak(old_top, new_top));
    return old_top;
}
```

**How it works:**

1.  **Push:** Read the current `top`. Point the new node's `next` to it. Atomically attempt to replace the current `top` with the new node using `CAS`. If the `top` hasn't changed (`expected == old_top`), the `CAS` succeeds. If another thread pushed or popped in the meantime, `CAS` fails, and we loop back, reading the new `top` and trying again.
2.  **Pop:** Read the current `top`. If it's `nullptr`, the stack is empty. Read `old_top->next`. Attempt to CAS `top` from `old_top` to `new_top`. If it succeeds, we have effectively removed the top node.

This is beautiful. There is no blocking. No waiting. Threads only fail because they lost a race. They immediately retry. There is no lock holder to be preempted. This is the gold standard for scalability.

**The Dragon in the Details: The ABA Problem**

The Treiber stack has a notorious flaw.

1.  Thread A calls `pop()`. It reads `top = Node1`. It reads `Node1->next = Node2`. Thread A is then preempted.
2.  Thread B calls `pop()`. Gets `Node1`. Top is now `Node2`.
3.  Thread B calls `pop()` again. Gets `Node2`. Top is now `Node3`.
4.  Thread B frees `Node1` and `Node2`.
5.  Thread C calls `push()`. It allocates a new node. The memory allocator (due to reuse) gives it the **exact same memory address** that `Node1` used to occupy. This new node has value 99. It points to `Node3`. Top is now this new `Node1`.
6.  Thread A wakes up. It sees `top == Node1` (the expected value!). It performs a CAS.
7.  **The CAS succeeds!** `top` is replaced with `old_top->next`, which was `Node2`.
8.  The stack is now corrupted. It points to `Node2`, which was freed long ago.

The CAS succeeded based on an _address_, but the _logical state_ of the stack has changed completely. `Node1` is not the same node it was before Thread A was preempted.

**Solutions to ABA: Hazard Pointers and Epoch-Based Reclamation**

The ABA problem forces us to solve memory reclamation. We cannot simply `free` a node the moment it is removed.

**Hazard Pointers (Maged Michael, 2002)**
Each thread maintains a globally accessible list of hazard pointers—pointers it is currently accessing and must not be freed.

1.  Before reading `top`, a thread announces the pointer in its hazard pointer list.
2.  It then verifies the `top` hasn't changed since the announcement.
3.  If it passes verification, the thread can safely attempt the CAS.
4.  When a thread successfully pops a node, it cannot free it immediately. It must place it in a "retired list".
5.  Periodically, or when the retired list gets too long, the thread scans the hazard pointers of _all_ threads. If a retired node is not protected by any hazard pointer, it is safe to free it.

Hazard pointers are a powerful but manual technique. The overhead of managing the hazard pointer list on every `push` and `pop` is non-trivial.

**Epoch-Based Reclamation (EBR)**
A simpler, more performant alternative used extensively in the Linux kernel (as RCU, Read-Copy-Update).

- Global epoch counter.
- Threads announce which epoch they are in.
- A grace period ends when all threads have left the previous epoch.
- Memory freed in epoch `N` can be safely deallocated when the global epoch has moved past `N` and all threads have acknowledged it.

RCU is the superstar of the Linux kernel's networking stack. Readers never take any locks or perform atomic writes. An update (e.g., changing a routing table entry) involves:

1.  **Read:** The reader simply reads a pointer. (Memory barrier).
2.  **Copy:** The writer allocates a new version of the data structure.
3.  **Modify:** The writer modifies the new copy.
4.  **Publish:** The writer atomically updates the global pointer to point to the new copy.
5.  **Grace Period:** The writer calls `synchronize_rcu()`, which blocks until every pre-existing reader has finished.
6.  **Free:** The writer can safely free the old copy.

```c
// RCU-protected pointer
struct routing_table *gptr;

// Reader (no locks!)
void lookup_rcu(struct packet *pkt) {
    rcu_read_lock();
    struct routing_table *rt = rcu_dereference(gptr);
    // Use rt to route the packet
    rcu_read_unlock();
}

// Writer
void update_rcu(struct routing_table *new_table) {
    struct routing_table *old;
    old = rcu_dereference(gptr);
    rcu_assign_pointer(gptr, new_table); // Atomic publish
    synchronize_rcu(); // Wait for all readers using *old* to finish
    free(old);
}
```

RCU is a lock-free mechanism that can dramatically simplify design and improve performance on read-heavy workloads.

---

#### Part V: The Workhorse – The Michael-Scott Queue

The Treiber stack is simple, but a stack is LIFO. For FIFO ordering (producer-consumer, work queues), we need a concurrent queue. The gold standard is the **Michael-Scott Queue** (1996).

It uses a dummy node to simplify the edge cases of an empty queue. It has two atomic pointers: `head` and `tail`.

```c
struct Queue {
    struct Node {
        int value;
        std::atomic<Node*> next;
    };
    std::atomic<Node*> head;
    std::atomic<Node*> tail;

    Queue() {
        Node* sentinel = new Node{0, nullptr};
        head.store(sentinel);
        tail.store(sentinel);
    }

    void enqueue(int value) {
        Node* node = new Node{value, nullptr};
        Node* t;
        Node* next;
        while (true) {
            t = tail.load();
            next = t->next.load();
            if (t == tail.load()) { // Are we consistent?
                if (next == nullptr) { // Is tail pointing at the last node?
                    if (t->next.compare_exchange_weak(next, node)) {
                        break; // Successfully linked the new node
                    }
                } else {
                    // Tail is not pointing to the last node. Help advance it.
                    tail.compare_exchange_weak(t, next);
                }
            }
        }
        // Try to advance tail to point to the new node
        tail.compare_exchange_weak(t, node);
    }

    bool dequeue(int &value) {
        Node* h;
        Node* t;
        Node* first;
        while (true) {
            h = head.load();
            t = tail.load();
            first = h->next.load();
            if (h == head.load()) {
                if (h == t) { // Is queue empty or tail falling behind?
                    if (first == nullptr) return false; // Empty queue
                    // Tail is falling behind. Help advance it.
                    tail.compare_exchange_weak(t, first);
                } else {
                    // There is data. Read the value first!
                    value = first->value;
                    // Try to advance head to the next node
                    if (head.compare_exchange_weak(h, first)) {
                        break;
                    }
                }
            }
        }
        // Optional: Free the old sentinel node
        // (Memory reclamation needed for the old head)
        delete h;
        return true;
    }
};
```

**Why it works:**
The magic is the dummy node (`head` always points to a dummy). This means an empty queue always has one node.

1.  **Enqueue:** Link the new node to the `tail`'s `next` pointer. If the `tail` is lagging (because another thread already linked the node but hasn't updated `tail`), help it by advancing the `tail` first. This is a classic **helping** pattern.
2.  **Dequeue:** Read the value from the _second_ node (`head->next`). Then advance the `head` pointer to that node. The old `head` (dummy) is now the removed node.

The Michael-Scott queue is the foundation for many lock-free work-stealing queues (like the one in Intel TBB, Threading Building Blocks) and is heavily used in high-frequency trading and game engine job systems.

---

#### Part VI: Beyond Simple Structures – The Concurrent Hash Table

Let's put it all together. A hash table is perhaps the most universally used data structure. Building a highly concurrent one is a rite of passage.

**The Naive Approach: Global Mutex**
Terrible. One thread accessing any bucket blocks all threads.

**The Standard Approach: Striped Locking**
An array of fixed-size mutexes. A hash is taken modulo the number of locks to determine which lock to acquire. This is what `ConcurrentHashMap` in older Java versions used. It works well for small to medium thread counts, but the lock contention on a hot bucket can still be a bottleneck.

**The Lock-Free Approach: Split-Ordered List**
The definitive lock-free resizable hash table is the _split-ordered list_ by Shalev and Shavit.

The core idea is brilliant: instead of having an array of buckets, you have a **single** global lock-free list.

1.  **Base List:** All elements are stored in a single, sorted, lock-free linked list.
2.  **Buckets:** The "buckets" are just pointers into this global list. A bucket pointer points to a specific node in the list.
3.  **Resize:** When the table needs to grow, we don't rehash and move elements. We simply _add more buckets_ (more pointers into the same list). The new buckets split the old logical buckets in half.

**How the split happens conceptually:**
Imagine a list sorted by the _reverse_ of the hash key.

- Bucket 0 covers all keys.
- When we resize, we add Bucket 1. Bucket 0 now covers keys ending in `0` (binary), and Bucket 1 covers keys ending in `1`.
- You don't move any nodes. You just point the new bucket pointer to the correct starting node in the existing list.
- Inserts and lookups now hash to the new, smaller bucket, reducing contention.

This is lock-free. The resize operation does not block ongoing insertions or lookups. This design is the basis for `ConcurrentHashMap` in Java 8+ and many high-performance key-value stores (like the in-memory engine of Redis Cluster).

---

#### Part VII: The Toolkit for the Modern Programmer

The era of the big, dumb mutex is over. The modern systems programmer must be fluent in a range of concurrency patterns. Here is your takeaway toolkit:

1.  **Start Simple:** Begin with a coarse-grained lock. Profile it. Is contention your bottleneck? If not, move on to more important problems. Premature optimization is the root of all evil.
2.  **Graduate to Reader-Writer Locks:** If your data structure is read-mostly (e.g., a routing table, a config store, an LRU cache for reads), an RW lock provides an excellent performance boost with relatively low complexity.
3.  **Master Fine-Grained Locking:** For hot data structures where writes are frequent, learn hand-over-hand locking for lists and striped locking for hash tables. Be rigorous about lock ordering to avoid deadlock.
4.  **Venture into Lock-Freedom:** For the truly performance-critical hot paths (message queues, real-time trading systems, kernel data paths), lock-free is the only viable option.
    - Master `std::atomic` and the memory ordering semantics (`acquire`, `release`, `seq_cst`).
    - Understand the ABA problem. It is not a theoretical curiosity; it will bite you on production hardware.
    - Use a robust memory reclamation scheme. Hazard pointers are difficult to get right. Epoch-Based Reclamation (RCU) is often simpler and faster for read-heavy loads. Libraries like `liburcu` provide this for user-space.
5.  **Respect the Cache Line:** Know what `cache_line_size` is on your hardware. Use alignment (`alignas(64)`) to prevent false sharing. False sharing is when two independent variables on the same cache line are written to by different cores. The hardware treats them as the same variable and generates an invalidation storm, even though no logical sharing is occurring.

**A Note on the C++ Memory Model**

Modern C++ (`<atomic>`) provides a powerful, portable abstraction for lock-free programming. The default memory ordering is `memory_order_seq_cst` (sequentially consistent), which provides a strong guarantee but is expensive on weakly-ordered architectures like ARM or PowerPC. For maximum performance, you can hint at weaker orderings:

```c
atomic<int> x{0};
// Release: Writes before this store cannot be reordered past it.
// Acquire: Reads after this load cannot be reordered before it.
x.store(42, memory_order_release);
int val = x.load(memory_order_acquire);
```

Getting this wrong leads to undebuggable, Heisenbug-style crashes. The `seq_cst` default is safe. Weak ordering is for the experts optimizing to the final nanosecond.

---

#### Part VIII: Conclusion – The Road Ahead (The Holographic Valet)

We have journeyed from the single, inefficient parking attendant (coarse-grained locking) through the valet concierge (fine-grained locking) to the revolutionary self-parking car (lock-free data structures) and the holographic valet that just places a copy of the car remotely (RCU).

The future of concurrency is bright and demanding. Hardware is not getting faster; it is getting _wider_. Every two years, CPUs add cores, not GHz. The database that uses a single giant B-tree lock will be crushed by the competition using a lock-free skip list. The trading system using a global mutex for its order book will be beaten by the one using hazard pointers and a Michael-Scott queue.

Mastering these techniques is the single highest-impact investment a systems or backend engineer can make in 2025. It moves you from a programmer who _uses_ threads to an engineer who _wields_ concurrency as a tool.

The next time you write a `pthread_mutex_lock`, take a moment to imagine the parking lot. Is your single attendant a bottleneck? Could you let the cars park themselves? The answer determines whether your application will gracefully scale to fill a modern server room or will quiver and crash under the weight of its own parallelism.

**Further Reading:**

- _The Art of Multiprocessor Programming_ by Maurice Herlihy and Nir Shavit. (The undisputed bible of the field).
- _Is Parallel Programming Hard, And, If So, What Can You Do About It?_ by Paul McKenney (The definitive guide to RCU and the Linux Kernel's concurrency primitives).
- C++ Standard papers on `std::atomic` and memory ordering.

The parking lot is crowded. Drive carefully, keep an eye on your hazard pointers, and never, ever let the ABA problem sneak up on you.
