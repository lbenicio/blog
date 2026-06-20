---
title: "Implementing A Non Blocking Universal Construction (Herlihy’S Method) Using Compare And Swap And Help First"
description: "A comprehensive technical exploration of implementing a non blocking universal construction (herlihy’s method) using compare and swap and help first, covering key concepts, practical implementations, and real-world applications."
date: "2023-01-08"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/implementing-a-non-blocking-universal-construction-(herlihy’s-method)-using-compare-and-swap-and-help-first.png"
coverAlt: "Technical visualization representing implementing a non blocking universal construction (herlihy’s method) using compare and swap and help first"
---

# Concurrency Without Locks: Implementing Herlihy’s Universal Construction with CAS and Help-First

## Introduction

Imagine you are designing a high-frequency trading system. Every microsecond counts. Your critical data structure — an order book — must handle thousands of concurrent updates from multiple threads. You reach for a mutex to protect the shared state. It works, but soon you notice the latency spikes: a thread holding the lock is preempted by the OS, and every other thread stalls. Worse, a bug in one thread causes it to never release the lock, bringing the entire system to a halt. You need a better way.

This scenario is not hypothetical. The rise of multicore processors has made concurrent programming the default, yet the tools we use to manage shared state are often the same ones invented decades ago: locks, semaphores, monitors. Locks are simple to reason about but they introduce a host of problems: priority inversion, convoying, deadlock, and, most critically, blocking — a thread that fails to acquire a lock must wait, wasting CPU cycles and undermining scalability. There is a better way: non‑blocking synchronization.

Non‑blocking algorithms guarantee that the failure or suspension of any thread does not prevent other threads from making progress. At the highest level, we distinguish two properties: _lock‑freedom_ (the system as a whole makes progress, though individual threads may starve) and _wait‑freedom_ (every thread completes its operation in a bounded number of steps, independent of other threads). Wait‑free algorithms are the holy grail of concurrent programming: they provide deterministic progress guarantees, eliminate deadlocks, and are immune to thread delays. But constructing a wait‑free data structure from scratch is notoriously difficult. For every new type — a queue, a set, a graph — we must invent a custom, hand‑tuned synchronization scheme. This is error‑prone, time‑consuming, and far from general.

Enter **Herlihy’s universal construction**. In his seminal 1991 paper “Wait-Free Synchronization”, Maurice Herlihy described a method to automatically transform any sequential data structure into a wait‑free concurrent one. The construction uses only a single atomic primitive: Compare-and-Swap (CAS), along with a novel mechanism called **help-first**. This approach is called _universal_ because it works for _any_ sequential data structure, requiring only that operations are deterministic and can be represented as functions from state to state. The cost is a level of indirection and a potentially large number of CAS attempts, but the generality is astonishing.

In this blog post, we’ll dive deep into Herlihy’s universal construction. We’ll first review the problem with locks, then explain lock‑freedom and wait‑freedom. Next, we’ll explore the universal construction step by step, including the role of CAS, the announce array, and the help‑first policy. We’ll provide detailed pseudocode, walk through an example (a wait‑free stack), analyze correctness and performance, and discuss modern variations. By the end, you’ll understand how to build wait‑free concurrent data structures without reinventing the wheel — using a universal recipe.

---

## 1. The Problem with Locks

Locks are the traditional tool for coordinating access to shared mutable state. They provide _mutual exclusion_: at most one thread can execute a critical section at a time. This serializes accesses, which seems intuitive. But in modern multicore systems, locks suffer from several deep flaws.

### 1.1 Blocking and Wasted Cycles

When a thread tries to acquire a lock that is already held, it must wait — either by spinning (busy-waiting) or by yielding the CPU. Both waste resources. Spinning consumes CPU cycles that could be used by other threads. Yielding triggers a context switch, which is expensive (microseconds). Worse, if the lock holder is preempted or suffers a page fault, every other thread blocked on that lock is also stalled. This is called _blocking_.

### 1.2 Priority Inversion

In real-time or priority-based systems, a low‑priority thread holding a lock can preempt a high‑priority thread that needs the same lock. The high‑priority thread may spin or block until the low‑priority thread releases the lock — but the low‑priority thread might be scheduled ineffectively. This inversion can cause missed deadlines.

### 1.3 Deadlock and Livelock

Improper lock ordering leads to deadlock (threads waiting forever). Livelock occurs when threads are not blocked but spend all their time retrying a failed lock acquisition, making no progress. Both are notoriously hard to debug.

### 1.4 Convoying

When a thread releases a lock and immediately re‑acquires it, other threads that were waiting may be scheduled all at once, causing a “thundering herd” of context switches. This can degrade throughput.

### 1.5 Fault Tolerance

If a thread holding a lock crashes (or enters an infinite loop), the lock is never released. This can bring down the entire system. For distributed systems and fault‑tolerant computing, locks are unacceptable.

Given these issues, researchers began seeking alternatives that avoid blocking entirely. Non‑blocking synchronization emerged as the solution.

---

## 2. Non‑Blocking Synchronization: Lock‑Free vs Wait‑Free

Non‑blocking synchronization comes in two main flavors: lock‑free and wait‑free.

### 2.1 Lock‑Freedom

An algorithm is **lock‑free** if at any point, at least one thread is guaranteed to make progress. In other words, the system as a whole continues to make progress even if some threads are delayed. Lock‑free algorithms typically use atomic read‑modify‑write (RMW) operations such as Compare-and-Swap (CAS) or Fetch-and-Add. They avoid locks but may cause individual threads to _starve_ if they keep failing their CAS. A classic example is the lock‑free stack using CAS on the top pointer.

**Example:** A lock‑free stack.

- Thread A reads the top pointer, computes a new top.
- Thread B concurrently does the same.
- Only one CAS succeeds; the other retries.
- If B is unlucky, it might retry many times while A succeeds. Lock‑freedom ensures that _someone_ succeeds, but not necessarily every thread.

### 2.2 Wait‑Freedom

An algorithm is **wait‑free** if every thread completes its operation in a _finite number of steps_, regardless of other threads’ speeds or failures. This is a stronger guarantee: no thread can starve. Every thread is guaranteed to make progress individually.

Wait‑free algorithms are much harder to design. For many years, researchers believed that building a wait‑free data structure for arbitrary sequential objects was impossible. Herlihy’s universal construction proved otherwise.

### 2.3 Why Wait‑Freedom Matters

Wait‑free algorithms are _deterministic_ in progress: they eliminate blocking, deadlock, and starvation. They are ideal for real‑time systems, OS kernels, and any environment where threads have different priorities or where failure of one thread must not affect others. Moreover, wait‑free algorithms are composable in a way that lock‑based ones are not. The cost is usually slower average performance due to overhead, but the worst‑case guarantees are often worth it.

---

## 3. Herlihy’s Universal Construction: The Big Idea

The universal construction takes a sequential data structure — defined by its state and a set of operations — and produces a concurrent wait‑free version. The key insight: instead of serializing operations via a lock, we serialize them via a _total order_ of operations, enforced by consensus objects. Each thread independently attempts to append its operation to a global log, and then _helps_ other threads complete their operations.

### 3.1 The Assumptions

We assume that the sequential data structure is:

- **Deterministic**: given the same initial state and sequence of operations, the result is the same. (We can model operations as pure functions.)
- **Applicable**: each operation returns a result and updates the state.

We also assume a shared memory with atomic **CAS** (Compare-and-Swap). CAS takes three arguments: an address, an expected value, and a new value. It atomically replaces the value at the address if it equals the expected value, returning true; otherwise false.

### 3.2 The High‑Level Structure

The universal construction maintains a single global object: a linked list of _operation records_ that represents the sequence of operations applied so far. Each operation record contains:

- The operation to be performed (e.g., “push(5)”).
- An _announce_ location where a thread can store its operation before it is applied.
- A pointer to the _next_ operation record in the list.
- A field for the _result_ of the operation (to be filled later).
- A status flag indicating whether the operation is completed.

New operations are appended to the tail of this list using CAS. However, multiple threads may attempt to append concurrently. The construction uses a cooperative scheme: a thread that wants to perform an operation first **announces** it in a per‑thread slot, then it tries to advance the global tail of the list. If another thread has already moved the tail, the current thread will help complete the other thread’s operation before its own.

### 3.3 The Announce Array and Help-First

The universal construction uses an array `announce[1..n]` where each thread `i` can write the operation it wishes to perform. This array is crucial for propagation: when a thread advances the tail, it doesn’t just apply its own operation — it scans the announce array and helps _any_ operation that is not yet applied. This is the **help-first** principle.

The help-first policy ensures that no operation is left behind. If a thread is slow or crashes, others will eventually apply its announced operation. Because every thread helps every other, the total number of steps any thread needs to complete is bounded by O(n) (where n is the number of threads) — assuming the operation itself is constant‑time.

---

## 4. Compare-and-Swap (CAS) – The Primitive

CAS is the only atomic RMW operation required. It is available on almost all modern processors (x86, ARM, etc.). The algorithm uses CAS to:

- Update the tail pointer of the operation list.
- Update fields within an operation record (e.g., status, result).
- Modify the announce array (which is usually just a write, but CAS can be used if needed).

CAS is a relatively weak primitive compared to load‑linked/store‑conditional (LL/SC) or transactional memory, but it is sufficient to build consensus objects. Herlihy’s universal construction effectively implements a _consensus_ mechanism using CAS and the announce array: every thread “agrees” on which operation goes next in the total order by repeatedly trying to CAS the tail.

### 4.1 The ABA Problem

One pitfall of CAS is the **ABA problem**: a thread reads value A, another thread changes it to B and back to A, then the CAS succeeds erroneously. In the universal construction, we avoid this by using pointers to immutable operation records (which are allocated once and never changed after being linked). Thus ABA is not an issue because we only compare pointers, which are never reused. (Garbage collection or epoch‑based reclamation can be used to safely free old records.)

---

## 5. Help-First: The Key to Wait‑Freedom

Let’s examine the help‑first mechanism in detail. Suppose we have `n` threads, each with an assigned slot in the `announce` array. Each thread that wishes to execute an operation follows these steps:

1. **Announce**: Write the operation (and its arguments) into `announce[my_id]`. This guarantees that even if the thread is delayed, its intention is visible.

2. **Find the tail**: Read the current global tail pointer of the operation list. Then attempt to apply the _first_ unapplied operation from the announce array. But which one? The help‑first rule says: **prefer helping an operation announced by another thread over your own**. The rationale: if everyone helps others, then every operation will eventually be completed. Specifically, the thread tries to take the operation at `announce[0]`, then `announce[1]`, and so on, until it finds one that is not yet applied. If none, it applies its own.

3. **Apply operation**: Once a target operation is selected, the thread tries to append it to the tail of the list using CAS. If the CAS fails (another thread moved the tail), it repeats from step 2, but this time it will help the other thread’s operation that succeeded.

4. **Recursive helping**: When a thread appends an operation, it also checks whether the operation it just appended is the one it announced. If not, it must now go back and help the remaining unapplied operation (its own or another). This ensures that eventually all announced operations get linked.

5. **Complete the list**: After the operation is linked, the thread walks the list from the head to compute the state and result for that operation. (In a standard implementation, the list maintains a cached copy of the state for the last applied operation, updated after each successful append.)

### 5.1 Why Help-First Guarantees Wait-Freedom

Consider any thread `i` that announces an operation `Op`. Once `Op` is in the announce array, it will be noticed by other threads. The key property: every time some thread advances the tail pointer, it either applies `Op` or, if `Op` is not applied, leaves it for the next round. Since there are at most `n` operations waiting to be applied, after at most `n` successful tail advances (each by some thread), `Op` will be applied. Because each tail advance takes a bounded number of steps (a few CAS attempts and a walk down the list), the total number of steps for any thread to complete its operation is bounded by O(n). This proves wait‑freedom.

---

## 6. Detailed Pseudocode

Now we’ll present the classic universal construction algorithm. We assume the following data structures:

- `Operation`: a record containing a function pointer, arguments, a pointer to result, and a status (e.g., 0 = not yet applied, 1 = applied).
- `Node`: a record representing a linked list element, containing an `Operation* op`, and a `Node* next`.
- Global variables:
  - `Head`: pointer to the first Node (anchored).
  - `Tail`: pointer to the last Node (initialized to Head).
  - `announce[1..n]`: array of `Operation*` (initially NULL).
  - `state`: a copy of the data structure’s state after the last applied operation (updated atomically? We’ll see).

For simplicity, we assume that the data structure’s state is immutable once computed per Node (or we store the state as a snapshot). In practice, the state can be computed by replaying operations from the head, but that’s O(number of ops). A more efficient approach is to have each Node store the result of applying its operation to the previous state. We’ll adopt that: `Node` stores `previous_state` and `result`, and after linking, the `next` node updates its state by applying the new operation.

### 6.1 Helper Functions

```
// Apply operation op to state s, returning new state and result.
(s', result) = apply_op(op, s)

// Try to append a new Node with operation op to the global list.
// Returns a pointer to the Node if successful, else NULL.
Node* try_append(Operation* op) {
    Node* newNode = new Node(op);
    while (true) {
        Node* tail = Tail;
        Node* next = tail->next;
        if (next != NULL) {
            // Another thread advanced the tail; help it.
            CAS(&Tail, tail, next);
        } else {
            // Attempt to set tail->next to newNode.
            if (CAS(&tail->next, NULL, newNode)) {
                CAS(&Tail, tail, newNode);
                return newNode;
            }
            // CAS failed; another thread succeeded; loop.
        }
    }
}
```

### 6.2 Main Execution by Thread i

```
void do_operation(Operation* my_op) {
    // Step 1: Announce
    announce[i] = my_op;

    // Step 2: Find an operation to help (including possibly my own).
    Operation* op_to_apply = help_select();

    // Step 3: Try to append it.
    Node* node = try_append(op_to_apply);
    // After a successful append, node->op is the operation we just linked.

    // Step 4: Update state and compute result for node's operation.
    Node* prev = node->prev;  // In practice, we need to follow from head.
    // We know the previous state from the previous node.
    (node->state, node->result) = apply_op(node->op, prev->state);

    // Step 5: If the node's operation is not ours, we still need to help ours.
    while (announce[i] is not yet applied) {
        Operation* next_op = help_select();
        Node* n = try_append(next_op);
        // ... similar state update
    }

    // At this point, my operation is done. Read result from the Node.
    result = node->result;
    announce[i] = NULL;  // optional cleanup
}
```

The function `help_select()` scans the announce array (a fixed order, e.g., from 1 to n) and returns the first Operation\* that is not NULL and not yet applied (i.e., not linked to the list). If all are applied, it returns NULL (or perhaps the thread’s own operation). A careful implementation also avoids infinite loops by ensuring that a thread eventually picks its own if nothing else is pending.

### 6.3 Correctness Considerations

- **Consistency of state**: Because operations are applied one by one in the order they appear in the linked list, and each node stores the result of its operation on its predecessor’s state, the structure defines a linearizable history.
- **Atomicity of state update**: The apply_op function is assumed to be deterministic. If multiple threads compute the same node’s state (since helping may cause redundancy), they must agree on the result. In practice, the node’s state and result can be set once using CAS on a field, or by having only the thread that successfully appended the node compute them.
- **Memory reclamation**: Nodes and operations are allocated dynamically. Since threads may access them even after they are applied, we need a garbage collector or safe memory reclamation (e.g., hazard pointers, epoch‑based reclamation). This is an additional complexity but not part of the core algorithm.

---

## 7. Proving Wait-Freedom

We now sketch a proof that the universal construction is wait‑free. Let the number of threads be `n`. Consider any thread `t` that invokes `do_operation`. It first writes to `announce[t]`. From that point, the algorithm proceeds in a loop until its operation is applied. Each iteration of the loop selects an operation to help, tries to append it, and updates state.

Claim: Every time a thread succeeds in appending a new node (CAS on tail->next), it reduces the number of unapplied operations in the announce array by at least one (if the appended operation was unapplied). However, if two threads are competing, they might both try to append the same operation? No, because each operation is unique (pointer to its own Operation record). The first thread that appends it succeeds; subsequent CAS on that node’s next will see it already set.

But what if a thread repeatedly fails to append and wastes steps? The `try_append` function always eventually succeeds because the tail pointer keeps moving forward. More formally: each successful CAS on `tail->next` advances the list. There are infinitely many such CAS attempts? Actually, the number of operations to apply is finite for a given set of invocations. But for a single invocation, the thread may keep looping until its own operation is linked. We need to bound the number of loop iterations.

Observe: once `t` writes its operation to the announce array, there are at most `n` operations that could be pending (one per thread). Each time any thread successfully appends a node, one pending operation is linked. So after at most `n` successful appends, `t`’s operation must be linked (since it’s one of the pending ones). However, `t` itself might not be the one performing the append. It might be helped by other threads. The critical point: `t` will eventually notice that its operation is linked because after each successful append, `t` will re‑scan the announce array and detect it (or it will directly see its operation in help_select). Even if `t` is helping others, it will eventually see its own.

But what if `t` is stuck in an infinite loop of trying to append the same node that is already appended? The `try_append` function will eventually see that `tail->next` is not NULL and simply update the tail pointer, then loop back. It will then call `help_select()` again, which will return the next unapplied operation. Since the number of unapplied operations decreases monotonically, eventually `t` will pick its own.

Thus, in bounded steps (O(n) per operation), every thread completes. This is wait‑freedom.

---

## 8. Example: A Wait‑Free Stack Using the Universal Construction

Let’s concretize the construction by implementing a wait‑free stack. The sequential stack has operations `push(value)` and `pop()`. We’ll define an `Operation` as a union with a type tag: `PUSH` or `POP`, and a value for push. The state of the stack can be a singly linked list of nodes (a stack of values) or simply an array that we rebuild each time. For simplicity, we’ll use an immutable stack (functional style): the state is a list of values, with operations producing a new list.

We’ll need sequential `apply_op`:

- `push(val, state_list)` -> new list with `val` prepended, return `null` (or success).
- `pop(state_list)` -> if empty, return `null` and empty list; else return (top value, list without top).

Now we embed this into the universal construction. Threads announce their operation, help others, and eventually the global list reflects the total order. The final state after all operations is the stack.

**Walkthrough**: Thread A does `push(5)`. Thread B does `pop()`. Assume static order: first A announces, then B. Thread A runs help_select, sees its own operation (since no other unapplied), appends node1 with op `push(5)`, updates state. Then A checks again: its operation is now applied, so it returns. Meanwhile, Thread B announces, runs help_select, sees its op `pop()`, appends node2, updates state (which is the stack after push(5) then pop). Result: pop returns 5. This is linearizable: either A happens before B or vice versa depending on order of append. Since the total order is determined by the order of successful appends, the execution is consistent.

This demonstrates that the construction works for any data structure, not just stacks.

---

## 9. Performance Considerations and Overheads

The universal construction is a theoretical breakthrough but has practical limitations. Let’s analyze.

### 9.1 Contention on the Tail

All threads repeatedly read and try to CAS the same tail pointer. As contention increases (many threads), CAS failures become frequent, leading to many retries. The number of steps per operation can grow linearly with the number of threads, but the constant may be large. In practice, the construction works well for small to moderate numbers of threads (e.g., up to 8 or 16). Beyond that, performance degrades due to cache line bouncing.

### 9.2 Memory Overhead

Each operation creates a new Node. If operations are frequent, memory allocation rate is high. Garbage collection or reclamation adds overhead. Additionally, the announce array of size n holds pointers, which is negligible.

### 9.3 Sequential Bottleneck

Even though the algorithm is wait‑free, the global list forces a total order: operations are applied one at a time. This sequentialization limits throughput. For a data structure with inherently sequential operations (like a stack), this is unavoidable. However, for data structures that allow concurrent modifications (like a hash table), more efficient wait‑free structures exist that exploit parallelism. The universal construction does not exploit data structure semantics.

### 9.4 Inefficiency of State Rebuilding

Our example recalculated the entire state after each node. In a stack represented as a linked list, applying an operation is O(1) (prepend or pop from front). So rebuilding state is cheap. For more complex structures (e.g., a balanced BST), applying an operation might be O(log n) but rebuilding from scratch is O(n). To avoid that, each node can store the _delta_ (the change) and we can lazily recompute state only when needed. But for highly concurrent access, this can become expensive.

### 9.5 Practical Optimizations

- **Batching**: Threads can announce multiple operations at once? Not directly.
- **Epoch-based computation**: Instead of rebuilding from head each time, maintain a persistent data structure. For example, use a persistent treap or journal to allow efficient state queries.
- **Reducing help-first overhead**: The algorithm requires scanning all other threads’ announce slots each time. This is O(n) per operation, which is fine for small n but becomes significant for 100+ threads. Various improvements have been proposed (e.g., combining, flat combining).

---

## 10. Modern Variations and Extensions

Since Herlihy’s 1991 paper, many developments have improved on the universal construction.

### 10.1 Lock-Free Universal Construction

A simpler version that is lock‑free (not wait‑free) can be obtained by removing the help-first requirement: each thread only tries to apply its own operation. This is the classic lock‑free stack or queue approach. It’s easier to implement but may starve.

### 10.2 Using Fetch-and-Add

Instead of CAS, other primitives like Fetch-and-Add (FAA) can be used in some variants. For instance, one can assign a global sequence number via FAA to order operations. However, to implement wait‑freedom, you still need a mechanism to ensure that every thread completes, which typically requires helping.

### 10.3 Elimination and Combining

**Flat Combining** (Hendler et al., 2010) is a practical alternative: a single thread (the combiner) processes multiple operations at once while others spin. This can achieve high throughput for certain workloads, but it is not wait‑free (the combiner can block). However, it can be made lock‑free.

### 10.4 Hardware Transactional Memory (HTM)

Modern processors (Intel TSX, IBM z/Architecture) provide hardware transactional memory that can execute critical sections speculatively. While HTM can be used to implement wait‑free data structures trivially (by retrying until commit), it suffers from aborts due to conflicts and is not truly wait‑free (aborted threads may starve). However, HTM can accelerate the universal construction by reducing CAS failures.

### 10.5 Persistent Memory

With the advent of non‑volatile memory (NVM), we need crash‑consistent wait‑free algorithms. The universal construction can be adapted to NVM by ensuring that the list of operations is persisted appropriately (e.g., using log structured writes). This is an active research area.

### 10.6 Composition of Operations

The universal construction works for any single data structure. To have multiple data structures, we would need separate universal constructions. There are universal constructions for transactions that operate on multiple objects, but they require additional primitives like two-phase locking or software transactional memory.

---

## 11. Implementation Challenges in Real Systems

Translating the pseudocode to a real programming language (C++, Rust, Java) involves additional hurdles.

### 11.1 Memory Ordering

Modern processors have weak memory models. CAS typically implies a full memory barrier (sequentially consistent). Over‑using barriers hurts performance. Some steps can be relaxed (e.g., reading tail pointer with acquire semantics, writing announce with release). The algorithm is designed assuming sequential consistency, so careful use of atomic operations with the right ordering is necessary.

### 11.2 Memory Reclamation

A node that has been appended to the list is never removed (the list is append-only). But when a thread finishes reading the state, it may no longer need the node. However, other threads may still be reading it (e.g., walking the list). We must ensure that nodes are not freed prematurely. This is a classic problem: safe memory reclamation. Options:

- Garbage collection (Java, Go) – simple but non‑deterministic.
- Hazard pointers – track which nodes are in use by each thread.
- Epoch‑based reclamation (EBR) – group memory frees into epochs.
- Quiescent state based reclamation (QSBR) – used in Linux kernel.

The cost of reclamation adds complexity but is essential for unbounded data structures.

### 11.3 Dynamic Number of Threads

The original construction assumes a fixed number of threads `n`. If threads can come and go, we need a dynamic announce array, which complicates scan order. One solution: use a resizable concurrent hash set for announce slots.

### 11.4 Operation Arguments May Be Large

If an operation carries a large payload (e.g., a string to push onto a stack), copying it into the announce slot may be expensive. The announce slot can store a pointer to dynamically allocated memory that the thread manages. The helper thread must be able to read it safely.

---

## 12. Conclusion

Herlihy’s universal construction is a beautiful theoretical result that shows wait‑free synchronization is possible for any sequential object, using only CAS and a help-first strategy. It turns a sequential data structure into a concurrent wait‑free one with deterministic progress guarantees, eliminating locks entirely. While the construction may not be the fastest in practice due to its overhead, it provides a crucial building block for understanding non‑blocking algorithms and for building fault‑tolerant systems.

We’ve covered:

- The problems with locks.
- The distinction between lock‑freedom and wait‑freedom.
- How the universal construction uses an announce array and help‑first to ensure every thread completes.
- Detailed pseudocode and an example stack implementation.
- Correctness and performance analysis.
- Modern variations and implementation challenges.

If you’re implementing a high‑frequency trading system, you might not use the universal construction directly because of its sequential overhead. But you will certainly benefit from its core ideas: cooperative helping, persistent logs, and the use of atomic RMW operations. Moreover, for custom data structures where you need absolute correctness guarantees and cannot tolerate deadlocks, the universal construction can be adapted to fit your needs.

As multicore systems continue to scale, the demand for efficient, lock‑free, and wait‑free data structures will only grow. Herlihy’s universal construction remains a landmark contribution — a testament to the power of simple ideas like “help others first” to solve hard concurrency problems. I encourage you to implement it yourself (even just as an exercise) and experience firsthand how a few atomic operations and a disciplined helping mechanism can eliminate the evils of locks.

---

## Further Reading

- Herlihy, M. “Wait-Free Synchronization.” _ACM Trans. Program. Lang. Syst._ 1991.
- Herlihy, M. and Shavit, N. _The Art of Multiprocessor Programming_. Morgan Kaufmann, 2008. (Chapters on universal construction, lock-free and wait-free data structures)
- Luchangco, V. et al. “The Universal Construction.” In _Distributed Computing: A Locality-Sensitive Approach_, 2006.
- Michael, M. “Hazard Pointers: Safe Memory Reclamation for Lock-Free Objects.” _IEEE TPDS_ 2004.
- Dice, D. et al. “Lock Cohorting: A General Technique for Improving NUMA Locality.” _PPoPP_ 2009.

---

_Thank you for reading! If you have any questions or want me to elaborate on any part, please leave a comment below._
