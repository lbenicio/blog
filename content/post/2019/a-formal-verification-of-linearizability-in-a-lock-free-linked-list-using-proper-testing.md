---
title: "A Formal Verification Of Linearizability In A Lock Free Linked List Using Proper Testing"
description: "A comprehensive technical exploration of a formal verification of linearizability in a lock free linked list using proper testing, covering key concepts, practical implementations, and real-world applications."
date: "2019-07-30"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/a-formal-verification-of-linearizability-in-a-lock-free-linked-list-using-proper-testing.png"
coverAlt: "Technical visualization representing a formal verification of linearizability in a lock free linked list using proper testing"
---

# The Elusive Dream of Correct Concurrent Code: A Deep Dive into Lock‑Free Data Structures and Verification

## Introduction: The Nightmare of Rare Concurrency Bugs

Imagine debugging a concurrency bug that occurs once in every ten million operations. You’ve thrown every stress test at it: thousands of threads, randomized delays, CPU-saturating loops—all to no avail. The system runs for days in production, then suddenly corrupts a critical pointer, taking down a database, a web server, or a real-time trading engine. You stare at the code, but the interleaving that triggers the failure is so astronomically rare that even the most aggressive randomized testing cannot reproduce it. This is the nightmare of concurrent programming, and for lock‑free data structures, it is a daily reality.

Lock‑free data structures are the backbone of high‑performance concurrent systems. They underpin memory allocators, garbage collectors, kernel schedulers, and key‑value stores like Memcached and Redis. By avoiding traditional locks, they eliminate deadlock, priority inversion, and convoying, and they offer better scalability on modern multi‑core hardware. Yet this performance comes at a steep price: correctness. A lock‑free algorithm must guarantee that its operations are _linearizable_—that each operation appears to take effect atomically at a single point in time between its invocation and response, and that the resulting history is consistent with a sequential execution. Without linearizability, the data structure’s behavior becomes unpredictable, breaking every application that relies on it.

Defining correctness is one thing; proving it in practice is another. The classic lock‑free linked list—the singly‑linked, compare‑and‑swap (CAS) based structure introduced by Timothy L. Harris in 2001—remains the quintessential example of the subtlety involved. Harris’s algorithm allows concurrent insertion, deletion, and lookup through careful use of logically marked “deleted” nodes. It is beautiful, symmetric, and notoriously difficult to verify. The original paper itself acknowledged that the proof was non‑trivial and relied on a manual argument about the safety of concurrent marking and CAS.

But why do we care so much about linearizability? Because without it, the semantics of the data structure are ill‑defined. Consider a concurrent set: if a thread inserts element `x` and another thread simultaneously deletes `x`, what should a third thread’s lookup see? Linearizability demands that all operations appear to occur in some total order consistent with real time, and that every individual operation happens atomically at some point within its duration. This gives developers a clean mental model: the data structure behaves as if all operations were executed sequentially, one after another, with no interleaving visible.

This blog post will take you on a journey through the world of lock‑free data structures. We will start with the fundamental problems of locks that motivate the field, then explore the core concepts of lock‑free programming, and finally dive deep into Harris’s linked list as a case study. Along the way we will examine memory reclamation, verification strategies, and modern trends. By the end, you will understand not only the beauty of these algorithms but also the immense difficulty of getting them right.

## The Trouble with Locks

Before we celebrate lock‑free data structures, we must appreciate why locks are so problematic in concurrent systems. Locks are the traditional mechanism for ensuring mutual exclusion: a thread acquires a lock before accessing a shared resource, and releases it when done. While conceptually simple, locks introduce several severe issues in practice.

### Deadlock

Deadlock occurs when two or more threads are each waiting for the other to release a lock, resulting in a standstill. For example, thread A holds lock L1 and waits for L2; thread B holds L2 and waits for L1. This classic deadlock scenario is easy to induce in code with multiple locks, especially when lock ordering is not enforced. Deadlock is a total system failure because the involved threads can never make progress.

### Priority Inversion

Priority inversion arises in preemptive schedulers when a high‑priority thread needs a lock held by a low‑priority thread, but the low‑priority thread gets preempted by a medium‑priority thread. The high‑priority thread is blocked indefinitely while the medium‑priority thread runs on the CPU. This can cause catastrophic real‑time violations (e.g., a spacecraft’s control system missing a deadline, as famously happened with the Mars Pathfinder rover). Solutions like priority inheritance add complexity and are not always available or efficient.

### Convoying and Contention

When multiple threads repeatedly contend for the same lock, the lock becomes a bottleneck. In a coarse‑grained locking scheme, only one thread can execute inside a critical section at a time, while others spin or block. This reduces scalability on multi‑core systems to nearly one core’s worth of work. Moreover, when a thread holding the lock is preempted (e.g., by a time slice), all other waiting threads must wait even longer—a phenomenon known as _convoying_.

### Non‑Composability

Locks do not compose well. If you have two lock‑based data structures, each internally correctly using locks, combining them in a single atomic operation often requires additional external locks, leading to potential deadlock or performance penalties. For example, a “move element from set A to set B” operation cannot be made atomic simply by calling a lock‑protected remove and then a lock‑protected insert; the two operations are not atomic as a group. You need a higher‑level lock that covers both structures, which breaks modularity.

### Overhead and OS Dependence

Acquiring a lock often involves a system call (e.g., `pthread_mutex_lock`) or a spinlock that wastes CPU cycles. Even user‑space spinlocks cause cache coherence traffic and memory ordering issues. Additionally, locks rely on the operating system’s scheduler; if a thread holding a lock is preempted, all other threads waiting for that lock are also effectively blocked.

Lock‑free programming sidesteps all these problems. In a lock‑free algorithm, progress is guaranteed at the system level: if multiple threads are operating concurrently, at least one of them makes progress (i.e., completes its operation) in a finite number of steps, even if any thread is delayed or preempted. This property is known as _lock‑freedom_ and is strictly stronger than obstruction‑freedom and strictly weaker than wait‑freedom (where every thread makes progress). Wait‑freedom is even harder to achieve but eliminates the possibility of starvation entirely.

## Foundations of Lock‑Free Programming

### Compare‑and‑Swap (CAS)

The central primitive of lock‑free programming is an atomic read‑modify‑write instruction, most commonly Compare‑and‑Swap (CAS). A CAS operation takes three arguments: a memory address, an _expected_ value, and a _new_ value. It atomically reads the value at the address, compares it to the expected value, and if they are equal, writes the new value and returns true; otherwise, it returns false and does nothing. On many modern CPUs, CAS is implemented as a hardware atomic instruction, e.g., `CMPXCHG` on x86.

CAS enables the fundamental pattern of lock‑free programming: read a shared variable, compute a new value based on what was read, and attempt to atomically update the variable from the old value to the new value. If the CAS fails, another thread changed the variable, so you retry the whole operation. This is the core of “optimistic concurrency.”

Example: a lock‑free counter increment:

```c
int* counter;
int old, new;
do {
    old = *counter;           // read
    new = old + 1;            // compute
} while (!CAS(counter, old, new));
```

This loop will eventually succeed as long as no thread repeatedly fails. Under lock‑freedom, we also need to ensure that at least one thread makes progress (increment succeeds) even if others retry.

### LL/SC: Load‑Linked / Store‑Conditional

CAS suffers from the ABA problem (discussed later). Some architectures provide Load‑Linked / Store‑Conditional (LL/SC) instead, which monitors the memory location for writes. LL reads a value, and SC writes only if no other write to that location occurred between LL and SC. If a write occurs, SC fails. LL/SC naturally avoids ABA but is less widely available (e.g., ARM, PowerPC). In practice, CAS is emulated on such architectures using LL/SC.

### Progress Guarantees

There are three widely recognized progress conditions for concurrent data structures:

- **Obstruction‑freedom**: A thread makes progress if it eventually runs alone (no other threads contend). If contending, a thread may be indefinitely blocked. This is weak but simple to implement.
- **Lock‑freedom**: The system as a whole makes progress: at least one thread completes an operation in a finite number of steps, regardless of thread delays. No thread can be blocked forever by another thread’s failure.
- **Wait‑freedom**: Every thread makes progress in a finite number of its own steps. Wait‑freedom implies lock‑freedom and provides the strongest progress guarantee but is much harder to achieve.

Most practical lock‑free structures (e.g., popular concurrent queues and stacks) are lock‑free but not wait‑free. Wait‑free structures often require elaborate helping mechanisms or universal constructions (like Herlihy’s universal construction) that are expensive.

### Linearizability: The Correctness Criterion

Linearizability is the standard correctness condition for concurrent data structures. It requires that each operation appears to take effect atomically at some point (the _linearization point_) between its invocation and its response, and that the resulting history of operations is equivalent to some sequential history. In other words, there exists a total order of all operations that respects real‑time ordering: if operation A completed before operation B started, then A must appear before B in the total order.

Linearizability is important because it provides a simple abstraction: developers can reason about the data structure as if it were sequential, ignoring all concurrency. Lock‑free structures must satisfy linearizability, which usually involves identifying a single atomic step (typically a successful CAS) as the linearization point for each operation.

## Case Study: Harris’s Lock‑Free Linked List

Now we come to the heart of our exploration: Harris’s linked list. This algorithm implements a concurrent set (elements with keys) supporting `insert`, `delete`, and `lookup`. It uses a singly‑linked list sorted by key, and it employs a logical deletion scheme: a node is marked as “deleted” before it is physically removed from the list. This ensures that operations can still navigate the list safely.

### Data Structure Representation

Each node consists of:

- A `key` (assumed unique for simplicity).
- A `next` pointer, which also contains a _mark_ bit indicating if the node is logically deleted.
- Because the mark is stored in the pointer itself (e.g., the low‑order bit), reading the pointer must carefully mask out the mark, and CAS operations must preserve or update the mark accordingly.

In C‑like pseudocode:

```c
struct Node {
    int key;
    struct Node* next; // low bit is mark: 0 = valid, 1 = deleted
};

// Alias for clarity
#define MARK_MASK 1
#define ADDR_MASK (~1)
#define GET_ADDR(p) ((Node*)((uintptr_t)(p) & ADDR_MASK))
#define GET_MARK(p) ((uintptr_t)(p) & MARK_MASK)
```

The list has a sentinel head node with key = -∞ and a sentinel tail node with key = +∞. The head never gets deleted; the tail is a dummy node with `next = NULL` and is also never deleted.

### The Search Operation

The heart of Harris’s algorithm is the `search` function. It returns two adjacent nodes: `left_node` and `left_node->next` (the `right_node`). It also cleans up physically deleted nodes that it encounters. The function is designed to be called by all three operations.

Simplified pseudocode (ignoring marking for now):

```c
// Returns (left_node, right_node) such that left_node.key < key <= right_node.key
// Also physically removes any marked nodes encountered.
void search(int key, Node** left_ptr, Node** right_ptr) {
    Node* left = &head;
    Node* right = GET_ADDR(left->next);

    while (1) {
        Node* succ = GET_ADDR(right->next);
        // Check if right is logically deleted (marked)
        if (GET_MARK(right->next)) {
            // Help remove the right node: CAS left->next from right to succ
            if (CAS(&left->next, right, succ)) {
                // Success: right is now unlinked. Continue with new right.
                right = succ;
            } else {
                // CAS failed; restart from left.
                left = &head;
                right = GET_ADDR(left->next);
                continue;
            }
        } else {
            // right is valid; check if we've found the correct window.
            if (right->key >= key) {
                *left_ptr = left;
                *right_ptr = right;
                return;
            }
            // Move forward
            left = right;
            right = succ;
        }
    }
}
```

The crucial part: When `search` finds that `right` is marked (because `right->next` has its mark bit set), it attempts to physically unlink `right` by redirecting `left->next` to `succ` (the node after `right`). If the CAS fails (another thread changed `left->next`), the search restarts from the head. This helping mechanism ensures that logically deleted nodes are eventually removed.

### Insert Operation

Insert uses `search` to find the correct place. It creates a new node and then tries to link it atomically:

```c
bool insert(int key) {
    Node* new_node = new Node(key);
    while (1) {
        Node *left, *right;
        search(key, &left, &right); // ensures no node with key exists? Actually search returns left,right such that left.key < key <= right.key. If right.key == key, already exists.
        if (right->key == key) {
            // already present
            delete new_node;
            return false;
        }
        // new_node should be inserted between left and right
        new_node->next = right;
        if (CAS(&left->next, right, new_node)) {
            return true;
        }
        // CAS failed; retry
    }
}
```

Note: The `search` function does not guarantee that `right` is not marked. However, if `right` is marked, then `search` will have removed it before returning (if that removal succeeded). In the case where the CAS linking `new_node` fails, we retry the whole insertion, including a fresh `search`. The linearization point for a successful insert is the CAS that updates `left->next`.

### Delete Operation

Delete first logically marks the node, then tries to physically remove it. The mark is stored as the low bit of `next` pointer of the node to delete. The operation first uses `search` to locate the node to delete. Then it marks the node (logical deletion) by setting the mark bit in its `next` pointer using CAS. If that succeeds, the node is considered deleted, and then the `search` mechanism (or an extra step) will physically unlink it later.

```c
bool delete(int key) {
    while (1) {
        Node *left, *right;
        search(key, &left, &right);
        if (right->key != key) {
            // not found
            return false;
        }
        // Try to logically delete right: set its mark bit in right->next
        Node* succ = GET_ADDR(right->next);
        if (CAS(&right->next, succ, (Node*)((uintptr_t)succ | MARK_MASK))) {
            // Logical deletion succeeded. Now try to physically unlink.
            // (This may fail if left->next changed; but search helped later.)
            // Attempt to CAS left->next from right to succ.
            CAS(&left->next, right, succ);
            return true;
        }
        // CAS for marking failed; retry from search.
    }
}
```

The linearization point for deletion is the CAS that sets the mark bit. After that point, `search` will treat the node as deleted and eventually unlink it. The final CAS to physically unlink is not essential for correctness; it is a performance optimization.

### Correctness Analysis: Why It Is Linearizable

Understanding why Harris’s list works requires examining possible interleavings. The critical insight is that the mark bit serves as a lock on the node’s logical presence. Once a node is marked, no thread can insert a new node after it (because insertion CASes into `left->next`, but if `left` is marked, its `next` already has mark bit set, causing CAS to fail). Also, a node cannot be marked if another thread has just inserted a node after it (the CAS for marking expects `next` to be an unmarked pointer equal to `succ`; a concurrent insert would change `left->next`, causing the marking CAS to fail). This creates a total order of logical operations.

The full proof of linearizability is non‑trivial and was given by Harris. The key points:

- For `insert`: The linearization point is the successful `CAS(&left->next, right, new_node)`.
- For `delete`: The linearization point is the successful `CAS(&right->next, succ, succ_with_mark)`.
- For `lookup`: The linearization point is when the search finds a node’s key and the node’s mark bit is not set (i.e., when it determines that the node is valid). Because `search` may remove marked nodes, the lookup must be careful not to read the mark after removal. In practice, `search` returns two nodes; if `right->key == key` and `right` is not marked at the point when we deem the lookup to be complete, we can linearize there. But what if the node becomes marked after that point? Linearizability only requires that there exists some point within the lookup’s interval. The point we choose can be the moment just before we read the mark (when we verify it is zero). This is safe because all concurrent operations are linearizable and the state is consistent.

One subtlety: A `lookup` that traverses the list may see a marked node and help remove it before returning. That helping is part of the operation but does not change the linearization point. The linearization point for lookup is when it has identified a node with matching key that is not marked; if no such node, then it never finds it, and the operation returns false.

### The Danger of ABA and How It Is Avoided

The ABA problem is a classic pitfall of CAS. Suppose thread T1 reads a value A from memory, then gets preempted. Another thread T2 changes the value from A to B and then back to A. When T1 resumes, it performs CAS with expected value A and the current value also A, so CAS succeeds even though the state has changed. In the linked list, the ABA problem can cause serious corruption.

Consider a scenario with Harris’s list: Thread T1 attempts to delete node N (mark and then unlink). T1 reads `left->next = N`. Then T1 gets preempted. Thread T2 removes N and possibly also removes the node after N, then inserts a new node M that happens to have the same address as N (due to memory reuse). T1 resumes and CAS `left->next` from N to some other value, thinking it is still N, but now N is actually M. This can break the list structure.

To prevent ABA, lock‑free algorithms must use memory reclamation techniques that prevent immediate reuse of freed memory. We discuss these next.

## The ABA Problem and Memory Reclamation

The ABA problem is perhaps the most insidious issue in lock‑free programming using CAS. It arises because CAS only checks the value at a memory address, not the entire history. If a pointer is freed and then reallocated at the same address, a thread performing CAS may erroneously think nothing changed.

### Hazard Pointers

One widely used technique is _hazard pointers_ (introduced by Maged Michael). Each thread maintains a small array of “hazardous” pointers—pointers that the thread is currently accessing and must not be freed by any other thread. Before reading a shared pointer, a thread announces it as a hazard pointer. When a thread wants to free a node, it first checks if any hazard pointer points to that node; if so, it defers the deallocation until later (by placing the node in a per‑thread retired list, periodically scanning). This ensures that no node gets reclaimed while a thread is about to dereference it.

Hazard pointers are effective but require careful ordering of writes and reads to prevent races, and they impose some overhead.

### Read‑Copy‑Update (RCU)

RCU is a synchronization mechanism widely used in the Linux kernel. It allows readers to access data without locks, and writers proceed by creating a new version of the data and then using a grace period to ensure that all pre‑existing readers have finished before freeing the old version. RCU is particularly suited for linked data structures where reads are frequent and writes rare. Harris’s list can be adapted to use RCU: the mark bit or a similar logical flag can be checked by readers, and memory reclamation is handled by RCU callbacks.

### Epoch‑Based Reclamation (EBR)

EBR is another technique where threads record an epoch number. A node can be freed only after all threads have advanced beyond the epoch in which the node was placed in a free list. EBR is simpler than hazard pointers but requires global coordination and can be susceptible to thread stalls.

In the original Harris paper, memory reclamation was not covered in detail; it was assumed the system had a garbage collector (like Java). In C/C++ implementations, one must manually avoid ABA. Modern lock‑free libraries often use hazard pointers or EBR.

## Extending the Idea: Other Lock‑Free Structures

Harris’s linked list is just one building block. Many other lock‑free data structures exist, each with its own correctness challenges.

### Treiber Stack

The Treiber stack (1986) is a simple lock‑free LIFO structure using CAS on the head pointer. Push: create a node, then CAS head from old to new node. Pop: read head, read next, CAS head from current to next. The pop operation must handle the case where the stack becomes empty (NULL). The ABA problem appears here as well: after a pop, if the node is freed and then a new push allocates a node at the same address, a concurrent pop may incorrectly succeed. Hazard pointers or tagged pointers (pointer + version counter) can mitigate ABA.

### Michael‑Scott Queue

The Michael‑Scott queue (1996) is a lock‑first, lock‑free FIFO queue using a dummy head node. It maintains `head` and `tail` pointers. Enqueue creates a new node, then CAS to advance `tail` to the new node, possibly with help from other threads. Dequeue reads `head`, reads its next, then CAS to update `head`. The implementation is surprisingly tricky because the tail pointer can lag behind the actual end of the list. The linearization point for enqueue is the CAS that updates `tail->next`; for dequeue it’s the CAS that updates `head`.

### Concurrent Skip List

A lock‑free skip list (e.g., by Herlihy, Lev, Luchangco, and Shavit) extends the concept of linked lists to multiple levels with indices. It requires careful management of multiple pointers and mark bits at each level. This is a highly scalable data structure used in memory‑management systems (like Intel’s TBB concurrent unordered map).

## Verifying Lock‑Free Correctness

Given the extreme difficulty of getting lock‑free code right by intuition alone, verification becomes paramount. Several approaches exist.

### Model Checking

Model checking explores all possible interleavings of a small state space. Tools like SPIN (Promela) or TLA+ can model lock‑free data structures at the abstract level. For example, one can model the linked list with a limited number of keys (e.g., three) and two threads, and check that linearizability holds. Because the state space grows exponentially, model checking cannot handle realistic configurations, but it can catch fundamental flaws.

### Theorem Proving

Interactive theorem provers (Coq, Isabelle, VeriFast) have been used to mechanically prove linearizability of Harris’s list. This is a huge undertaking but provides the highest assurance. The verification typically involves defining the list invariant, the helper predicates for marking, and then proving that each operation maintains the invariant and that the linearization point is correctly identified.

### Linearizability Checking Algorithms

A practical approach is to automatically check linearizability of a given concurrent implementation by comparing against a sequential specification using a “linearizability checker” like `lincheck` (used in the Kotlin concurrency library) or `stresscop`. These tools run randomized tests with many threads, record the histories of all calls and returns, and then algorithmically decide whether the history is linearizable. This is effective for finding bugs but not for proving absence.

### Stress Testing with Controlled Scheduling

Tools like `ThreadSanitizer` and `Helgrind` (Valgrind) can detect data races. However, they cannot prove linearizability. For locking‑free data structures, the lack of data races is necessary but not sufficient. Specialized testing frameworks (e.g., `stress` with `yield` points) can increase the coverage of interleavings. But as the opening anecdote suggests, some bugs remain astronomically rare.

## Modern Developments and Trends

### Transactional Memory

Hardware Transactional Memory (HTM) (e.g., Intel TSX) allows a block of code to execute atomically without explicit locks. This can simplify writing concurrent data structures, but HTM typically has limitations (cache footprint, capacity aborts) and is not universally available. Software Transactional Memory (STM) provides similar semantics in software but often incurs high overhead.

Lock‑free structures remain relevant because they offer predictable performance and are not vulnerable to abort storms.

### Persistent Memory

Emerging byte‑addressable persistent memory (e.g., Intel Optane PMem) creates new challenges: crashes can leave data in an inconsistent state on non‑volatile media. Lock‑free data structures must ensure that after a power failure, the structure on durable memory is always in a valid state. This has led to “durable linearizability” and new algorithms for persistent memory.

### Wait‑Free Progress

Although lock‑freedom guarantees system progress, individual threads can starve. Wait‑free structures guarantee progress per thread. Recent work has produced wait‑free versions of many common structures, often using “helping” mechanisms where a fast thread completes the operation of a slow thread. These are typically more complex and have higher constant overhead.

## Conclusion: The Dream and the Reality

Lock‑free data structures offer a tantalizing promise: correct, scalable, deadlock‑free concurrency without the pitfalls of locking. Yet the path to that promise is fraught with subtlety. Harris’s linked list exemplifies both the elegance and the difficulty of lock‑free programming. The algorithm is beautiful in its symmetry: each operation helps others, logical deletion precedes physical removal, and CAS provides atomicity. But the price of that elegance is a correctness proof that requires deep reasoning about interleavings, memory reclamation, and linearizability.

The nightmare of a rare concurrency bug never fully disappears. Even with rigorous proof, implementations may contain errors in the memory management layer or in the interplay with the compiler’s memory model. Modern verification tools and testing methods reduce the risk, but they cannot eliminate it entirely. The dream of “correct concurrent code” remains an elusive goal, motivating ongoing research in algorithms, verification, and programming languages.

For the practitioner, the takeaway is twofold: first, appreciate the complexity—don’t attempt to write a lock‑free data structure from scratch without thorough understanding; rely on well‑tested libraries (e.g., `liblfds`, `boost.lockfree`, Java’s `java.util.concurrent`). Second, be prepared to invest in verification: use model checking on simplified models, employ tools like `ThreadSanitizer`, and run exhaustive stress tests with artiﬁcial delays. And if you ever encounter a bug that occurs once in ten million operations, remember Harris’s insight: sometimes the interleaving is so rare that you must prove it cannot happen, because you will never see it in practice.

Lock‑free programming is not for the faint of heart. But for those who master it, the rewards are immense: systems that scale to hundreds of cores, that survive worst‑case scheduling, and that never deadlock. The dream may be elusive, but the journey toward it teaches us profound lessons about concurrency, atomicity, and the nature of time in a multithreaded world.

---

_Further reading:_

- Timothy L. Harris, “A Pragmatic Implementation of Non‑Blocking Linked Lists” (2001)
- M. Herlihy, N. Shavit, _The Art of Multiprocessor Programming_ (2008)
- Maged Michael, “Hazard Pointers: Safe Memory Reclamation for Lock‑Free Objects” (2004)
- P. Marlier et al., “Evaluating a Simple Linearizability Checker” (2012)
