---
title: "A Comprehensive Comparison Of Lock Free And Wait Free Data Structures: Definitions, Progress Conditions, And Examples"
description: "A comprehensive technical exploration of a comprehensive comparison of lock free and wait free data structures: definitions, progress conditions, and examples, covering key concepts, practical implementations, and real-world applications."
date: "2023-01-07"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/a-comprehensive-comparison-of-lock-free-and-wait-free-data-structures-definitions,-progress-conditions,-and-examples.png"
coverAlt: "Technical visualization representing a comprehensive comparison of lock free and wait free data structures: definitions, progress conditions, and examples"
---

# The Fragile Art of Waiting – And Why It’s Time to Stop

## Introduction: A Developer’s Nightmare

Every developer who has ever built a multithreaded application knows the feeling. You’ve carefully wrapped every critical section with a mutex, your locks are fine-grained, your code is (you think) deadlock-free. Then, under high load, the system stutters. A thread holding a lock is preempted by the OS scheduler. Other threads pile up, waiting. Latency spikes. Throughput plummets. And worst of all—in a real-time system—a low-priority thread can unknowingly block a high-priority thread, causing a missed deadline and cascading failure. This is the dark side of blocking synchronization: the very tool meant to protect data becomes a bottleneck, and worse, a source of unpredictability.

The problem isn’t new. Since the dawn of multiprocessing, programmers have struggled with the tension between correctness and performance. Lock-based synchronization is intuitive, well-understood, and—with decades of research—reasonably safe. But it’s fundamentally _blocking_: a thread that wants access to a shared resource must wait until the lock holder releases it. That waiting introduces delays, invites priority inversion, and worst of all, makes the system vulnerable to a single slow or crashed thread. In an era of dozens of cores, cloud-scale deployments, and real-time constraints, the old guard of mutexes and condition variables is showing its age.

Consider a typical online transaction processing system. Hundreds of threads handle user requests, each needing to update a shared counter, push onto a global work queue, or modify a hash table. With mutexes, a thread that acquires a lock and then suffers a page fault or a cache miss can stall the progress of every other thread waiting for that lock. The result is a system that behaves correctly 99.9% of the time but occasionally collapses under load—the dreaded “convoy effect” where threads queue up behind a slow lock holder, like cars behind a stalled truck on a single-lane highway. In safety-critical systems—avionics, medical devices, autonomous vehicles—this unpredictability is unacceptable.

Enter a radical alternative: **non-blocking synchronization**. Instead of relying on locks, these techniques use atomic hardware primitives—compare-and-swap (CAS), load-linked/store-conditional (LL/SC), or transactional memory—to allow threads to operate on shared data without ever blocking. No waiting. No lock holder. No priority inversion. At least, that’s the promise. But non-blocking is not a monolithic concept. It spans a spectrum of _progress conditions_—obstruction-free, lock-free, and wait-free—each with its own trade-offs in complexity, performance, and guarantees. In this article, we’ll dissect the anatomy of non-blocking synchronization, from the hardware building blocks to carefully engineered data structures, and explore why, after decades of research, this approach is finally becoming mainstream.

## The High Cost of Blocking: More Than Just Waiting

Blocking synchronization may seem benign, but its impact ripples far beyond the immediate act of waiting. To understand why non-blocking approaches are so compelling, we must first fully appreciate the pathologies of locks.

### Priority Inversion: The Silent Killer

Priority inversion occurs when a low-priority thread holds a lock needed by a high-priority thread. If a medium-priority thread preempts the low-priority holder, the high-priority thread may be delayed indefinitely. This famously caused the Mars Pathfinder rover to reset during its mission in 1997. The fix? A form of priority inheritance—a band-aid that complicates the scheduler. In real-time systems, priority inversion is a nightmare, and non-blocking synchronization eliminates it entirely: no thread ever waits for another, so priority is irrelevant.

### Convoying and Thundering Herds

Lock convoying happens when a thread holding a lock is descheduled (e.g., due to a page fault or time slice expiry). All other threads waiting for that lock are blocked, even though the lock holder isn’t actively using the CPU. Once the holder resumes, the waiting threads all try to acquire the lock simultaneously, causing a “thundering herd” of context switches and cache misses. Non-blocking structures avoid this: if a thread is preempted mid-operation, others simply retry their atomic operation and succeed.

### Deadlock and Livelock

Deadlock requires no introduction—two threads waiting for each other’s locks. Livelock is subtler: threads are not blocked but keep yielding and retrying without progress. Both are classic pitfalls with mutexes and condition variables. Non-blocking algorithms are designed to be _deadlock-free_ by construction: since no thread ever blocks, the classic “deadly embrace” cannot occur. However, they are not immune to livelock (e.g., two threads repeatedly CAS-failing on each other), but such scenarios can be mitigated with exponential backoff or other heuristics.

### The Scalability Ceiling

Amdahl’s law tells us that the serial fraction of a program limits speedup. Locks inherently create serial sections. Even with fine-grained locking, the overhead of acquiring and releasing locks—plus the cache coherence traffic they induce—grows with core count. A heavily contended lock becomes a sequential bottleneck, and the system’s throughput plateaus. Non-blocking algorithms, on the other hand, allow true parallelism: multiple threads can operate on different parts of a data structure simultaneously, as long as they don’t conflict on the same memory location.

### The Failure Model

In a distributed or fault-tolerant system, a thread holding a lock may crash or hang. With locks, the entire system may stall if recovery mechanisms are not in place. Non-blocking algorithms are _fault-tolerant_ in the sense that any thread’s failure (as long as it eventually stops writing garbage) does not prevent other threads from making progress. A crashed thread simply stops participating; others can continue.

## The Hardware Toolbox: Atomic Primitives That Changed Everything

Non-blocking algorithms rely on hardware-provided atomic operations. These primitives are the building blocks from which all lock-free data structures are assembled. Let’s examine the most important ones.

### Compare-and-Swap (CAS)

CAS is the workhorse of non-blocking synchronization. It atomically compares the content of a memory location to an expected value and, if equal, stores a new value. CAS returns a boolean indicating success. In C++11, it’s available as `std::atomic::compare_exchange_weak` or `compare_exchange_strong`. The difference: weak CAS may fail spuriously (e.g., due to store buffer flushes on PowerPC), while strong CAS always succeeds if the values match.

**Example: Non-blocking counter**

```cpp
std::atomic<long> counter{0};

void increment() {
    long old = counter.load();
    while (!counter.compare_exchange_weak(old, old + 1)) {
        // old is updated to the current value on failure
    }
}
```

This loop retries until the CAS succeeds. It is **lock-free** because at least one thread will make progress on each step (assuming the CAS eventually succeeds).

### Load-Linked / Store-Conditional (LL/SC)

LL/SC is used in ARM, PowerPC, and MIPS architectures. It consists of two instructions: `load-linked` reads a memory location and marks it for monitoring; `store-conditional` writes back only if no other thread has written to that location since the load-linked. LL/SC avoids the ABA problem (discussed later) and is generally more robust than CAS, but it is harder to implement efficiently on x86, which uses CAS instead.

### Transactional Memory (HTM)

Hardware transactional memory (e.g., Intel TSX) allows a sequence of reads and writes to execute atomically as a transaction. If a conflict occurs (e.g., another thread writes to the same cache line), the transaction aborts and is rolled back. HTM can simplify the construction of non-blocking data structures, but it has limitations: transactions have a finite capacity (cache lines), may abort spuriously, and are not guaranteed to succeed in all environments. Nevertheless, HTM is used in the implementation of concurrent data structures in libraries like the C++ concurrency library.

### Memory Barriers (Fences)

Atomic operations imply memory ordering. For example, a CAS with `memory_order_release` ensures that all prior writes are visible to other threads that perform an `acquire` load. Weakly-ordered architectures (ARM, PowerPC) require explicit memory barriers to prevent reordering. In x86, CAS with sequential consistency (`default`) is sufficient, but it may be slower. Understanding memory ordering is crucial for correct non-blocking code.

## The Three Progress Conditions: Choosing Your Guarantee

Non-blocking algorithms are categorized by the progress guarantees they provide. These guarantees define what happens when multiple threads contend.

### Obstruction-Free

**Definition**: A data structure is obstruction-free if a thread can complete its operation in a finite number of steps when running in isolation (i.e., no other threads interfere). Under contention, a thread may retry indefinitely, but if all other threads are paused, it will eventually succeed.

Obstruction-free is the weakest non-blocking condition. It is relatively easy to design—just use CAS retry loops—but it does not guarantee system-wide progress under contention. A malicious scheduler could starve a thread by always interrupting it mid-operation. However, for practical purposes, with random scheduling and exponential backoff, obstruction-free algorithms often behave well. Example: a simple lock-free stack using CAS but without handling ABA can be considered obstruction-free (if we ignore ABA issues).

### Lock-Free

**Definition**: A data structure is lock-free if at any point, _at least one_ thread makes progress (completes its operation) within a finite number of steps. This is a stronger guarantee: the system cannot livelock entirely—every time a thread fails, it helps another thread make progress.

Lock-free is the most common practical non-blocking condition. It ensures throughput stability even under high contention. All the classic lock-free data structures—Treiber stack, Michael-Scott queue, Harris linked list—are lock-free, not wait-free.

**Key insight**: Lock-freedom does _not_ guarantee that each thread makes progress, only that _some_ thread does. A single thread could starve if it repeatedly fails while others succeed. However, with fair hardware (e.g., x86’s CAS fairness), starvation is extremely rare.

### Wait-Free

**Definition**: A data structure is wait-free if every thread completes its operation within a bounded number of steps, regardless of other threads’ behavior. This is the strongest guarantee: no thread can ever starve; it is deterministic.

Wait-free algorithms are notoriously difficult to design. They often require helping mechanisms: when a thread sees that another thread is stuck, it completes that thread’s operation before proceeding with its own. Wait-free data structures are the holy grail for real-time systems, but they typically have higher overhead due to memory fences and help operations. Examples: wait-free queues using two-pronged descriptors (e.g., the queue by Kogan and Petrank), or the wait-free hash table by Shalev and Shavit.

| Condition        | Guarantee                                    | Complexity | Real-time safe | Example                        |
| ---------------- | -------------------------------------------- | ---------- | -------------- | ------------------------------ |
| Obstruction-free | Thread makes progress alone                  | Low        | No             | Simple CAS loop (ignoring ABA) |
| Lock-free        | At least one thread makes progress           | Medium     | Typically no   | Treiber stack, MS queue        |
| Wait-free        | Every thread makes progress in bounded steps | High       | Yes            | Kogan-Petrank queue            |

## Building Non-Blocking Data Structures: The Classics

Let’s dive into the details of canonical lock-free data structures. We’ll include code snippets and discuss the notorious **ABA problem** that plagues CAS-based algorithms.

### 1. Lock-Free Stack (Treiber Stack)

The Treiber stack, named after R. K. Treiber, is a simple lock-free LIFO structure using CAS. It uses a top pointer that points to the head node.

```cpp
struct Node {
    int value;
    Node* next;
};

std::atomic<Node*> top{nullptr};

void push(int val) {
    Node* new_node = new Node{val, nullptr};
    Node* old_top = top.load();
    do {
        new_node->next = old_top;
    } while (!top.compare_exchange_weak(old_top, new_node));
}

bool pop(int& result) {
    Node* old_top = top.load();
    while (old_top != nullptr) {
        if (top.compare_exchange_weak(old_top, old_top->next)) {
            result = old_top->value;
            delete old_top;  // Danger! See description.
            return true;
        }
    }
    return false; // empty stack
}
```

**The ABA Problem**: The above `pop` is flawed. Suppose thread T1 reads `old_top` as node A. Before T1 executes CAS, thread T2 pops A (frees it) and pushes a new node B which happens to have the same address as A (due to memory reuse). T1’s CAS sees the address matches, so it succeeds, but `old_top->next` now points to B’s next, which is not the intended successor. This is the **ABA problem**: a CAS succeeds even though the pointer’s target has changed.

Solutions:

- **Tagged pointers**: Use a 16-bit counter that is incremented each time a pointer is changed, so that even if the address matches, the tag differs.
- **Hazard pointers**: Deferred reclamation (see later section).
- **RCU/Lock-free memory reclamation**.

A correct lock-free stack uses hazard pointers or epoch-based reclamation to ensure that a node is not freed while any thread still holds a pointer to it.

### 2. Lock-Free Queue (Michael-Scott Queue)

The Michael-Scott (MS) queue is a lock-free FIFO structure that uses two atomic pointers: `head` and `tail`, each pointing to a dummy node initially. It handles concurrent enqueue and dequeue without locks.

**Algorithm outline** (simplified):

- Enqueue: Create a new node. Then, in a loop: read `tail`, attempt to CAS the tail’s next pointer from nullptr to new node. If successful, CAS the tail pointer itself (with the new node). If the CAS on next fails, it means another thread already linked a node, so we “help” by moving tail forward via CAS.
- Dequeue: Read `head`, read the node’s data, then CAS the head pointer to the next node. If the queue is empty, return false.

The MS queue is lock-free because at least one thread makes progress on each attempt. It is widely used in practice (e.g., Java’s `ConcurrentLinkedQueue`).

**Code snippet (pseudocode)**:

```cpp
struct Node {
    std::atomic<Node*> next{nullptr};
    int value;
};

std::atomic<Node*> head;
std::atomic<Node*> tail;

void init() {
    Node* dummy = new Node;
    head.store(dummy);
    tail.store(dummy);
}

void enqueue(int val) {
    Node* new_node = new Node{nullptr, val};
    while (true) {
        Node* last = tail.load();
        Node* next = last->next.load();
        if (last == tail.load()) { // consistency check
            if (next == nullptr) {
                if (last->next.compare_exchange_strong(next, new_node)) {
                    // linked; attempt to move tail
                    tail.compare_exchange_strong(last, new_node);
                    return;
                }
            } else {
                // tail is falling behind; help advance it
                tail.compare_exchange_strong(last, next);
            }
        }
    }
}

bool dequeue(int& result) {
    while (true) {
        Node* first = head.load();
        Node* last = tail.load();
        Node* next = first->next.load();
        if (first == head.load()) {
            if (first == last) {
                if (next == nullptr) return false; // empty
                // tail is behind; help
                tail.compare_exchange_strong(last, next);
            } else {
                result = next->value;
                if (head.compare_exchange_strong(first, next)) {
                    delete first; // beware of ABA; use hazard pointers
                    return true;
                }
            }
        }
    }
}
```

**Memory management**: Again, dequeue frees the old head node. Without hazard pointers, the node could be freed while another thread is still reading its `next` pointer. Practical implementations use hazard pointers or RCU.

### 3. Lock-Free Linked List (Harris List)

The Harris linked list supports concurrent insert, delete, and search using CAS. It uses a technique called _logical deletion_: a node is marked as deleted by setting a flag in its next pointer (typically using the lower bit of the pointer). After marking, the node is physically removed in a second step.

The algorithm is lock-free and is the basis for many concurrent set implementations (e.g., Java’s `ConcurrentSkipListMap`). It requires careful handling of the ABA problem using tagged pointers or similar.

**Basic idea**:

- Insert: find correct position, CAS the predecessor’s next pointer to the new node.
- Delete: first logically mark the node (set a bit in its next pointer), then physically unlink it by CAS on the predecessor’s next pointer, skipping the marked node.

Note: The Harris list implements a _set_ (no duplicates). Search always traverses lists while ignoring marked nodes.

### 4. Lock-Free Hash Table

A hash table can be built on top of a lock-free linked list for each bucket, but resizing is tricky. The most common approach is **split-ordering**: the hash table is treated as a sorted list of all keys, where keys are ordered by a _split-order_ (the reverse of the bit-reversed hash). Insert and delete use the lock-free list. Resizing happens by adding more lists and transferring elements lazily. The resulting structure is lock-free and supports dynamic resizing.

## The Memory Management Quagmire: Hazard Pointers and RCU

Non-blocking data structures often suffer from the problem of **memory reclamation**: when can we safely free a node that has been removed from the structure? The issue: another thread may still hold a pointer to that node and intend to read its data or its next pointer. If we free it prematurely, we risk use-after-free.

Three main approaches exist:

### Hazard Pointers (HP)

Hazard pointers, introduced by Maged Michael, work by having each thread maintain a small array of “hazardous” pointers—pointers to nodes that the thread is currently accessing. Before reading a node’s pointer, the thread writes the pointer to its hazard pointer list (using a global atomic array). After finishing, it clears the hazard pointer. When a thread wants to free a node, it checks if any hazard pointer points to that node; if not, it can free it, otherwise it retires the node to a list to be freed later (after a grace period).

**Pros**: Bounded memory, fast reclamation.
**Cons**: Each thread must maintain a fixed number of hazard pointers; can be complex to integrate.

### Epoch-Based Reclamation (EBR)

EBR uses a global epoch counter. Threads announce their current epoch. A node is retired by placing it in a per-epoch list. When all threads have passed a given epoch (i.e., no thread holds an older epoch), the nodes in that epoch’s list are freed. EBR is simpler than hazard pointers but may delay reclamation.

### Read-Copy-Update (RCU)

RCU is used extensively in the Linux kernel. It allows updates to happen by making a copy of the data, modifying the copy, and then atomically updating the pointer from the original to the copy. Old copies are freed only after a “grace period” where all threads have passed through a quiescent state (e.g., after a context switch). RCU is not exactly non-blocking (it can block in the update side), but it provides wait-free reads.

In user-space, RCU-like approaches are used in some lock-free libraries (e.g., `liburcu`). For fully non-blocking structures, hazard pointers are more common.

## Transactional Memory: Simplifying Non-Blocking Design

Transactional memory (TM) allows the programmer to express atomic operations as transactions, and the hardware (HTM) or software (STM) guarantees atomicity and isolation. TM can simplify the construction of non-blocking data structures: just wrap the operation in a transaction, and if it conflicts, retry.

**Hardware TM (HTM)**:

- Intel TSX (Haswell onwards) supports `XBEGIN` and `XEND` instructions.
- Limited by cache line footprint and number of reads/writes.
- Spurious aborts due to interrupts, page faults, or cache evictions.

**Software TM (STM)**:

- Implemented entirely in software, using versioning and conflict detection.
- Higher overhead than HTM but more flexible.

Hybrid approaches use HTM when possible and fall back to locks or STM on aborts. TM is not yet a panacea because of its limitations, but it is a promising tool for building lock-free structures with less intellectual burden.

## Performance Considerations: When Non-Blocking Shines

Non-blocking algorithms are not always faster than well-tuned lock-based ones. Under low contention, locks can be very efficient because CAS is more expensive (it often requires a bus lock or cache line ping-pong). However, as contention increases and the number of cores grows, non-blocking algorithms scale better because they avoid the serialization inherent in locks.

**Key performance factors**:

- **Cache coherence traffic**: CAS operations invalidate cache lines across all cores. A lock-free stack with high contention can cause significant overhead.
- **Memory reclamation**: Hazard pointers and RCU introduce additional overhead.
- **Tail latency**: Non-blocking algorithms tend to have lower worst-case latency because they avoid blocking. In real-time systems, this is critical.
- **Scalability**: Lock-free queues can achieve near-linear throughput on multi-socket machines, while lock-based queues saturate quickly.

**When to use non-blocking**:

- High contention on short operations (e.g., counters, stacks, queues).
- Systems with many cores (16+).
- Real-time or low-latency systems where blocking is unacceptable.
- Fault-tolerant systems where a crashed thread cannot stall others.

**When to use locks**:

- Low contention (locks are cheap).
- Complex operations that require atomicity over multiple steps (e.g., database transactions) – though TM can help.
- When simplicity is paramount and contention is low.

## Real-World Applications: Where Non-Blocking is Already Winning

Non-blocking synchronization is not just an academic curiosity. It powers critical infrastructure:

### Linux Kernel

The Linux kernel uses lock-free techniques extensively:

- **Read-Copy-Update (RCU)** for many data structures (e.g., routing tables, file descriptors).
- **Lock-free list** for private file descriptor tables.
- **Lock-free work queues** for deferrable tasks.

### Java Standard Library

- `java.util.concurrent.atomic` provides `AtomicInteger`, `AtomicReference`, etc.
- `ConcurrentLinkedQueue` (based on Michael-Scott).
- `ConcurrentHashMap` uses a combination of CAS and lock stripping (not fully lock-free, but partially non-blocking in search).
- `LongAdder` uses a striped CAS counter to reduce contention.

### C++ Standard Library

- `std::atomic` (C++11) provides portable CAS, load, store.
- `std::shared_ptr` uses atomic reference counting (non-blocking ops, but not lock-free in all implementations).
- Coroutines and async frameworks increasingly rely on non-blocking synchronization.

### Database Systems

- In-memory databases like VoltDB and memcached use lock-free data structures for performance.
- Database transaction managers often use lock-free validation schemes (e.g., optimistic concurrency control).

### Networking and Real-Time

- High-frequency trading systems use lock-free queues to minimize latency.
- Middleware like Disruptor (LMAX) is a lock-free ring buffer for inter-thread communication.
- Real-time operating systems (e.g., FreeRTOS) use non-blocking constructs for critical sections.

## The Future: Beyond Locks

The landscape of concurrent programming is evolving. Some trends:

**Persistent memory** (Intel Optane DC PMem) introduces non-volatile memory that survives crashes. Non-blocking algorithms must be adapted to handle failure-atomicity (e.g., persistent CAS with ordering to prevent torn writes). Research in persistent transactional memory is ongoing.

**Hardware acceleration**: IBM’s Power8 introduced a Transactional Memory facility; ARM v8.1 adds atomic instructions for CAS. Future CPUs may provide richer primitives (e.g., LL/SC at scale, or hardware hazard pointers).

**Formal verification**: Proving correctness of non-blocking algorithms is notoriously hard. Tools like TLA+, Alloy, and model checkers are aiding verification. The goal is to make lock-free code as safe as mutex-based code.

**Concurrent data structure libraries**: The upcoming C++ Concurrency TS includes lock-free data structures like `std::atomic_shared_ptr`. Meanwhile, libraries like Boost.Lockfree, Concurrent Data Structures (CDS), and Intel TBB offer production-ready implementations.

## Conclusion: Embracing the Challenge

Non-blocking synchronization is a powerful tool, but it is not a silver bullet. It demands a deep understanding of hardware memory models, a talent for reasoning about concurrent states, and a careful choice of reclamation scheme. Yet the rewards—freedom from priority inversion, deadlock, and scalability bottlenecks—are worth the effort.

The “fragile art of waiting” is evolving into a robust science of concurrent cooperation. As multicore processors, cloud-scale systems, and real-time applications become the norm, the ability to design and implement lock-free algorithms will separate the mediocre from the exceptional. The next time you reach for a mutex, pause and ask: Is there a better way? The answer, more often than not, is yes.

_— The journey from locks to lock-free is a journey from blocking to collaboration. It’s time to stop waiting._
