---
title: "Building A Concurrent B Tree With Optimistic Lock Coupling And Smo Safety"
description: "A comprehensive technical exploration of building a concurrent b tree with optimistic lock coupling and smo safety, covering key concepts, practical implementations, and real-world applications."
date: "2019-10-22"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/building-a-concurrent-b-tree-with-optimistic-lock-coupling-and-smo-safety.png"
coverAlt: "Technical visualization representing building a concurrent b tree with optimistic lock coupling and smo safety"
---

**Building a Concurrent B‑Tree with Optimistic Lock Coupling and SMO Safety**  
_Introduction_

---

### The Silent Scalability Ceiling

Every time you swipe right on a dating app, post a comment on social media, or execute a financial transaction, a database somewhere must find, insert, or delete a piece of data in a fraction of a microsecond. Under the hood, a data structure most of us take for granted—the venerable B‑Tree—makes this possible. For decades, B‑Trees have been the backbone of relational databases, file systems, and key‑value stores. They balance read and write performance, minimise disk I/O, and keep data sorted. But when you multiply the load by thousands or millions of concurrent threads, the innocent‑looking B‑Tree becomes a battlefield. Race conditions, deadlocks, and cache‑line bouncing can turn a well‑intentioned concurrent implementation into a sequential bottleneck that scales only in the number of headaches it causes.

Modern hardware is not waiting for software to catch up. Systems today ship with dozens of cores, deep cache hierarchies, and Non‑Uniform Memory Access (NUMA) topologies. To harvest the full performance of such machines, we need concurrency control mechanisms that are almost as fast as the underlying hardware. The naive approach—locking the entire tree during any modification—is clearly unacceptable. Even fine‑grained locking, such as locking individual nodes, introduces contention that grows with the number of concurrent operations. What we need is a technique that minimises locking duration, allows reads to proceed without waiting for writes, and yet guarantees consistency even when structural modifications (splitting or merging nodes) are underway.

Enter **optimistic lock coupling** and **SMO safety**.

Optimistic lock coupling is a concurrency strategy that flips the usual pessimistic mindset on its head. Instead of acquiring locks before touching data, a thread proceeds optimistically: it reads without locking, checks for conflicts only when necessary, and retries if a conflict is detected. This approach works beautifully for B‑Trees because most operations are short and touch only a few nodes. Structural modifications—the infamous “SMOs” (Structure Modification Operations), such as splitting a node that has become too full—are rare. By treating the common case (simple traversals and updates) optimistically, we can dramatically reduce lock contention. But optimism must be backed by safety. Without careful guarantees, a thread could read corrupted pointers or miss a split, leading to data loss or endless loops.

That’s where SMO safety comes in. SMO safety is a set of protocols that ensures that while one thread is busy splitting or merging nodes, no other thread will ever see an inconsistent state—even if it is not holding any locks. This is not trivial. Consider a split: a node’s contents are moved into two new nodes, and the parent must be updated to point to them. During this process, there is a window where the old node still appears valid but the parent has not yet been updated. A concurrent reader that descended into the old node might miss the new node entirely. SMO safety eliminates such windows by carefully ordering updates and using versioning or epoch‑based reclamation.

The combination of optimistic lock coupling and SMO safety yields a B‑Tree that is both highly concurrent and resilient. And yet, implementing this combination correctly is a subtle art. The literature—especially the classic work by Lehman and Yao (1981) and later refinements by Graefe (2010) and others—provides the theoretical foundation, but turning theory into production‑grade code requires navigating a labyrinth of memory ordering, lock‑free techniques, and careful state machines.

### Why Should You Care?

If you are a database engineer, you might already be familiar with these concepts. But if you are a systems programmer, a scalability enthusiast, or simply someone who enjoys dissecting high‑performance data structures, this topic is a goldmine. The B‑Tree remains the default index structure for most OLTP databases (MySQL’s InnoDB, PostgreSQL, SQLite, etc.) and is increasingly used in in‑memory key‑value stores. Even as LSM‑trees have gained popularity in log‑structured stores (LevelDB, RocksDB), B‑Trees continue to dominate workloads that favour point queries and range scans over write amplification.

Moreover, the techniques we will discuss—optimistic concurrency, versioned locks, and safe memory reclamation—are not tied to B‑Trees alone. They appear in concurrent hash tables, skip lists, and even operating system schedulers. Mastering optimistic lock coupling teaches you to think in terms of _phases_ of an operation: when can you read without inhibiting writers? When must you wait? How do you distinguish between a transient inconsistency and a permanent error? These questions are central to building any scalable concurrent structure.

The stakes are high. A poorly designed concurrent B‑Tree can cause cascading failures in a distributed system. A deadlock under high load can stall an entire cluster. On the other hand, an elegantly optimised B‑Tree can sustain millions of operations per second on commodity hardware. The difference is often a matter of a few well‑placed memory barriers and a careful lock design.

### What You Will Learn

This blog post will take you from the fundamental challenges of concurrent B‑Trees to a concrete implementation sketch using optimistic lock coupling and SMO safety. We will start by revisiting the classic B‑Tree structure and its serial operations. Then we will examine why naive locking fails and introduce the concept of _lock coupling_ (also known as _lock crabbing_), where a thread holds locks on only a few nodes at a time. From there we will shift to an optimistic variant: the thread reads a node without locking, verifies its version after reading, and retries if the node was modified concurrently.

The heart of the post will address SMO safety. We will dissect the three phases of a node split—freeze, link, and propagate—and see how they interact with optimistic traversals. We will discuss the use of **timestamp‑based version numbers** (or _sequence numbers_) on each node to detect concurrent modifications, and how to pair them with a memory reclamation scheme such as epoch‑based reclamation or hazard pointers. We will also touch on the delicate issue of _long‑lived latches_ versus _short‑lived optimistic reads_.

Finally, we will present a simplified code skeleton (in C++‑like pseudo‑code) that illustrates the core logic of an optimistic B‑Tree lookup and an SMO‑safe insertion. The code will highlight the crucial ordering of loads and stores, the retry loops, and the state transitions. Along the way, I will point out common pitfalls: missing memory barriers, incorrect version checks, and subtle races that occur when a split is interrupted.

### A Note on Trade‑offs

No concurrency scheme is a silver bullet. Optimistic lock coupling shines when conflicts are rare and operations are cheap to retry. In a write‑heavy workload where splits happen frequently, the cost of retries can become non‑trivial. Moreover, optimistic approaches rely on hardware support for atomic operations and memory ordering (e.g., `load‑acquire` and `store‑release`). On weakly ordered architectures (ARM, PowerPC), you must be explicit about barriers or risk seeing stale reads. We will discuss these concerns as well.

The B‑Tree we will build is in‑memory and designed for high concurrency. Many real‑world databases add additional layers (buffer pool management, crash recovery, etc.). Our focus is on the concurrency controller, not the full database engine.

### Roadmap

Here is a quick overview of the sections that follow:

1. **Background**: The B‑Tree and why concurrency is hard.
2. **Lock Coupling (Crabbing)**: How pessimistic lock coupling works and where it falls short.
3. **Optimistic Lock Coupling**: Reading without locks, version checks, and retries.
4. **SMO Safety**: Ensuring structural consistency during splits and merges.
5. **Implementation Sketch**: Pseudo‑code for lookup and insert with full concurrency.
6. **Memory Reclamation**: Hazard pointers vs. epoch‑based reclamation.
7. **Performance Considerations**: When to be optimistic vs. pessimistic.
8. **Conclusion**: Key takeaways and further reading.

By the end, you will have a solid mental model of how to build a concurrent B‑Tree that is both fast and correct. You will also understand the trade‑offs that come with optimism in concurrent programming.

---

Before diving into the details, let me set the stage with a brief history and a concrete motivating example.

#### A Brief History

The B‑Tree was invented in 1970 by Rudolf Bayer and Edward McCreight while working at Boeing. Their goal was to create a balanced tree that minimises disk seeks—hence the “B” might stand for “balanced,” “Bayer,” or “Boeing” (the origin is ambiguous). Early B‑Trees were designed for single‑threaded or coarse‑grained locking environments. The first concurrent B‑Tree algorithm for shared‑memory systems appeared in the 1981 paper by Lehman and Yao, “Efficient Locking for Concurrent Operations on B‑Trees.” They introduced the concept of _B‑link trees_, which added sibling pointers and allowed splits to be finalised lazily. This paper is the ancestor of many modern optimistic approaches.

Over the next four decades, researchers refined these ideas: optimistic locking (Kung & Robinson, 1981), lock‑free structures (Valois, 1995; Michael, 2002), and eventually hybrid schemes. The key insight is that most operations are _short_: traversing a B‑Tree of height 3 or 4 requires only a handful of node accesses. For those operations, the overhead of acquiring and releasing a lock is larger than the actual work. Optimistic lock coupling avoids this overhead in the common case.

#### A Concrete Example

Imagine a B‑Tree storing user IDs and profile data for a social network. A typical operation: find the record for user ID 42, update the “last login” timestamp. Under optimistic lock coupling, the thread starts at the root and reads its version number (say 7). It then reads the child pointer, jumps to the next node, reads its version, and so on. At the leaf node, it locates the record and updates it _without taking any lock at all_. Then it writes back the updated leaf and atomically increments the leaf’s version number to 8. No other thread was blocked during this process.

But what if another thread is simultaneously splitting the leaf node? The split operation will also modify the leaf and the parent. Optimistic lock coupling detects this conflict because the version number of the leaf (or the parent) will have changed between the time the first thread read it and the time it tried to commit its update. The first thread simply retries the entire search—a cheap operation since the tree is small. The split completes quickly, and the retry will see the new structure.

This “fail and retry” pattern is the essence of optimism. It works because retries are rare. The challenge, of course, is ensuring that no retry can observe an inconsistent state that would cause a crash or a logical error. That is where SMO safety comes in: we must guarantee that during a split, the tree remains _always_ in a state that a reader can safely navigate, even if some pointers are momentarily stale.

---

This introduction has set the stage for a deep dive. The journey ahead is challenging but rewarding. By understanding optimistic lock coupling and SMO safety, you will be equipped to build (or improve) concurrent data structures that scale linearly with the number of cores. If you are ready to think about memory ordering, version numbers, and atomic fences, then let’s begin.

[In the full post, the subsequent sections would follow, but as requested, this is the introduction only.]

# Building a Concurrent B-Tree with Optimistic Lock Coupling and SMO Safety

## 1. The Problem: Concurrency in B-Trees

B-trees are the backbone of modern database systems, file systems, and key-value stores. They offer excellent performance for both point queries and range scans, and they gracefully handle growing datasets by maintaining a balanced tree structure. But in today’s multi‑core world, a sequential B‑tree is a bottleneck. Every thread must wait for locks, wasting CPU cycles and limiting throughput.

The challenge is to build a B‑tree that allows many threads to read and write concurrently without sacrificing correctness or performance. Naive approaches—like a single global lock or coarse‑grained locking on each node—destroy scalability. Fine‑grained locking (e.g., latch‑coupling) works but can lead to lock contention under high concurrency.

Two key ideas have emerged to solve this problem:

- **Optimistic Lock Coupling (OLC)** – a lock‑free traversal technique that reduces contention by letting threads read without acquiring locks in most cases.
- **SMO (Structure Modification Operation) Safety** – a framework to handle the tricky cases where the tree must be restructured (splits, merges, rebalancing) without blocking concurrent operations.

In this post, we’ll build a concurrent B‑tree from the ground up, explaining every concept with theory, practical examples, and code snippets. By the end, you’ll understand how databases like PostgreSQL and modern in‑memory stores achieve high concurrency.

---

## 2. B‑Tree Refresher: Nodes, Keys, and Pointers

Let’s recall the basics. A B‑tree of order `m` (or minimum degree `t`) has the following properties:

- Every node contains between `t‑1` and `2t‑1` keys.
- Internal nodes have between `t` and `2t` children.
- All leaves appear at the same depth.
- Keys within a node are sorted.

A node is typically implemented as a fixed‑size page:

```rust
struct BTreeNode {
    is_leaf: bool,
    keys: Vec<Key>,   // sorted keys
    children: Vec<*mut BTreeNode>, // pointers to children (only for internal)
    // plus metadata for concurrency
}
```

Conventional operations:

- **Search**: Start at root, follow the correct child pointer until you hit a leaf. Compare keys in each node via binary search.
- **Insert**: Find the leaf, insert key. If full (keys == 2t‑1), split the node: push the median key up to parent and create two new children.
- **Delete**: Find key, remove it. If underflow (keys < t‑1), borrow from sibling or merge with sibling.

The trouble is that splits and merges propagate upward, potentially affecting many nodes.

---

## 3. The Concurrency Challenge: Searching While Splitting

Consider the most common scenario: many readers and an occasional writer inserting a key. A writer may need to split a node. While it is splitting, another thread is trying to navigate through that node. If the writer has not yet updated the parent pointer, the reader might follow a stale child pointer and end up in a node that is being deallocated. Classic races.

Traditional solutions:

- **Lock coupling (latch coupling)**: Acquire a latch (read or write lock) on the parent before releasing the child. This ensures that a split is visible before the parent’s lock is released. However, it serializes traversals because every node must be locked even for read.
- **Single writer / multiple readers (e.g., using a read‑write lock on the whole tree)**: Simple but poor concurrency for writes.

We need something better: optimistic lock coupling.

---

## 4. Optimistic Lock Coupling (OLC)

The insight: most of the time, the tree is stable (no splits or merges in progress). A reader can optimistically follow pointers without acquiring locks, as long as it later verifies that the node hasn’t been modified since it was accessed.

### 4.1 Basic Idea

Each node has a version counter (or sequence number) that is incremented every time the node is modified (keys, children, or pointer fields). The version is stored along with a lock bit that indicates whether a write lock is held.

```rust
struct NodeHeader {
    version: AtomicU64,  // lock bit is the LSB
    // ...
}
```

- **Read**: Before reading from a node, the reader takes a snapshot of the version (call it `v`). Reads the data. After finishing, it re‑reads the version. If it equals `v` (and the lock bit is 0), the data was consistent.
- **Write**: Acquire the lock by setting the lock bit. Increment version (with lock bit set). Do modifications. Increment version to clear the lock bit (effectively incrementing the version again).

Thus a reader can safely read without any atomic operation _during_ the read, as long as it validates the version afterwards. This is lock‑free for readers.

### 4.2 Optimistic Traversal

To navigate from root to leaf:

1. Start at `current = root`.
2. Loop:
   - Read `node = load(current)` (or follow pointer).
   - Read `version` from node header.
   - If version is odd (lock bit set), retry (spin or backoff).
   - Otherwise, read the key count and the array of keys/children.
   - Determine the next child index (or if leaf, done).
   - Read the child pointer from the node’s children array.
   - **_Before_** proceeding to the child, validate the parent’s version again:
     - If parent’s version != the snapshot (or lock bit set), retry from the beginning (or from root).
   - If valid, move to child.

This validation ensures that the pointer we followed was consistent. If a split occurred after we read the parent, the version would have changed and we would detect it.

**Important**: The reader does not hold any lock while reading. The validation is a simple atomic load.

### 4.3 Snippet: Optimistic Read of a Node

```rust
fn read_node<T>(node: &BTreeNode) -> Option<ReadSnapshot<T>> {
    let v = node.header.version.load(Ordering::Acquire);
    if v & 1 == 1 { return None; } // locked

    // Read keys, children... Could use memory fencing
    let snapshot = ReadSnapshot {
        version: v,
        keys: node.keys.clone(),
        children: node.children.clone(),
    };

    // Validate
    if node.header.version.load(Ordering::Acquire) != v {
        return None;  // modified
    }
    Some(snapshot)
}
```

The challenge is that reading keys/children may be interleaved with writes. The version validation only guarantees that the node as a whole wasn’t modified, but the _pointers_ we read might be from a state before an update? Actually, the validation ensures that between reading `version` and the end, no write happened. Because a write increments version twice (once to lock, once to unlock), the version will be different. This gives us a consistent snapshot.

### 4.4 When Optimistic Fails

If the version check fails, we simply retry. This is a form of optimistic concurrency control. Under low contention, retries are rare. Under high contention, some retries occur, but the system is still far more efficient than taking a read lock on every node.

---

## 5. Structure Modification Operations (SMOs) – Splits and Merges

A split (or merge) is a structure modification that changes the shape of the tree. It must be done atomically with respect to readers and other writers. We need SMO safety.

### 5.1 What Could Go Wrong?

Consider an internal node `P` with child `C`. A writer decides to split `C` into `C_left` and `C_right`. The writer must:

1. Create new nodes `C_left` and `C_right`.
2. Insert the median key from `C` into `P` and adjust `P`’s children array.
3. Free `C`.

While the writer is in the middle of step 2, a reader might have seen the old child pointer to `C` from `P` (before update), then traversed to `C` and read keys, but `C` might later be freed. The reader needs to ensure it never reads from a freed node.

Another hazard: if two splits are happening concurrently (e.g., splitting two children of the same parent), they might try to insert into the parent simultaneously, corrupting it.

### 5.2 Lock Coupling for Writers – The Traditional Way

To make SMOs safe, writers typically use latch coupling (lock coupling) – they hold a write lock on the parent and child simultaneously during split. This prevents other writers from interfering and ensures readers see a consistent state.

With optimistic readers, we need to ensure that a writer’s modifications are visible atomically to readers. The version mechanism helps: when a writer modifies a node, it increments the version, so readers detecting the change will retry.

But there’s a subtlety: a writer splitting node `C` must update the parent `P`. The reader might have already read `P`’s children array earlier and obtained a pointer to the old child. To avoid reading a freed node, the reader’s validation of `P` will catch the version change if the writer updates `P` after the reader’s snapshot.

However, the following scenario is dangerous:

1. Reader R reads version of P (vP1), reads children array, picks old child C (pre‑split).
2. Writer W splits C: creates new nodes, updates P (insert median key, change child pointers). P’s version becomes vP2.
3. Reader R then goes to node C. It reads version of C. But C might have already been freed and its memory reused (for a different node).

To prevent this, we must ensure that the pointer to C is still valid when R reads C. The optimistic approach relies on the fact that R validated P after reading the child pointer. If P was not modified (version unchanged), then the child pointer is still valid. But in the scenario above, W updates P _after_ R read P, but _before_ R validates P. R’s validation will see vP2 != vP1 and will abort. So R never goes to C. That’s safe.

But what if W updates P _after_ R finishes validating P? Then R’s validation passed, so P was stable. Then W updates P, incrementing version. Now R is already at node C (which is still valid because W hasn’t freed it yet – w.r.t. freeing, we must ensure C is not freed until no readers might be holding a reference). This is a classic “hazard pointer” or epoch‑based reclamation (EBR) problem. We’ll discuss memory management later.

### 5.3 Safe Split Protocol

We need a protocol that ensures:

- At most one writer modifies a given node at a time (ensured by lock bit).
- The parent update and child deallocation are serialized.

A typical approach for optimistic lock coupling B‑trees:

1. **Seize a write lock on the node to split** (say `C`).
2. **Create new siblings** (C_left, C_right).
3. **Acquire a write lock on the parent `P`** (using lock coupling). Since we already hold lock on child? Actually, we need both locks. To avoid deadlock, always lock parent before child? But we are splitting a child, we already have child locked. We’ll need to lock parent as well. Standard B‑tree splitting with lock coupling: traverse from root, lock‑coupling (write lock) along the way. But here we use optimistic reads for readers, but writers still use write locks for safety.

Better: **Link‑based techniques** (like the B-link tree) decouple splitting from parent updates by using side pointers. But OLC can work without links if we treat SMOs carefully.

**Optimistic Lock‑Coupling B‑Tree with SMO Safety (The BZ‑Tree approach)**:

The BZ‑tree (used in WiredTiger) and similar designs use a “lock‑coupling lite” where writers only hold a write lock on the node they are splitting and then on the parent, but they ensure that readers can still proceed through the parent via optimistic reads.

Implementation steps for a split:

- **Writer T** arrives at node C (via optimistic traversal) and decides to split after successfully acquiring a write lock on C.
- T then acquires a write lock on parent P (using lock coupling: it spins on parent’s lock bit).
- Now T holds write locks on both P and C.
- T modifies C (or creates new nodes) and updates P.
- T increments version of C (to unlock) and increments version of P (to unlock).
- Now other readers that were traversing may have passed P before the update; they will detect the version change at some point and retry.

But wait: while T holds write lock on C, can a reader still access C? No, because the lock bit is set, so any reader trying an optimistic read of C will see odd version and will not proceed. Therefore the reader will retry, and that retry might re‑read P, see the updated version, and then read the new children. This is safe.

### 5.4 Merges

Merges are symmetric. A node becomes underfull. The writer must merge it with a sibling, delete the key from parent, and free one node. Similar locking protocol: lock child and sibling, then parent.

### 5.5 Memory Management – Epoch Based Reclamation (EBR)

Optimistic readers may hold references to nodes for a short time without any lock. If a writer frees a node after a split/merge, a reader that is still using that node (even if it will later fail validation) could cause a use‑after‑free. Therefore we need a safe memory reclamation scheme.

Options:

- **Reference counting**: Not practical for high concurrency.
- **Hazard pointers**: Each reader registers the node it is about to access; writer must check hazard pointers before freeing. Works but overhead.
- **Epoch‑based reclamation (EBR)**: Threads announce their current epoch. Nodes are freed only after all threads have left the epoch in which they could have held a reference. This is common in concurrent data structures.

For our B‑tree, we can use a simple epoch scheme: every operation (read or write) belongs to a global epoch. When a writer deletes a node, it puts it into a retire‑list for the current epoch. The node is actually freed only when the epoch counter advances and no threads are in the old epoch.

Implementing EBR is out of scope, but essential for production.

---

## 6. Putting It All Together: Example Operations

Let’s now design a full concurrent B‑tree with OLC and SMO safety. We’ll use pseudocode that resembles Rust.

### 6.1 Node Structure

```rust
struct BTreeNode {
    header: NodeHeader,
    keys: Vec<Key>,
    children: Vec<AtomicPtr<BTreeNode>>, // for internal nodes
    // for leaves: value array omitted
}

struct NodeHeader {
    version: AtomicU64, // lowest bit is write lock
    num_keys: usize,   // could be part of version for simplicity
    ...
}
```

### 6.2 Search (Optimistic Read)

```rust
fn search(key: &Key) -> Option<Value> {
    let mut current = root.load(Ordering::Acquire);
    loop {
        let mut node = current;
        let snapshot = read_node_optimistic(node)?; // could retry

        if node.is_leaf {
            // binary search in snapshot.keys
            // if found, return value; else None
        } else {
            // find child index i
            let child_ptr = snapshot.children[i].load(Ordering::Acquire);
            // validate parent again before moving
            if node.header.version.load(Ordering::Acquire) != snapshot.version {
                // retry from root? Actually we can restart from current node
                continue;
            }
            current = child_ptr;
        }
    }
}
```

This shows the retry loop. After reading child pointer, validate parent. If pass, move to child. If not, retry. The retry could either restart from root or from the current node (since we have the node pointer). However, if the current node changed, we might be using a stale pointer. Better to restart from root for simplicity.

### 6.3 Insert (Optimistic Traversal + Write Locks for Splits)

Insert first searches optimistically down to leaf, but with a twist: we must remember the path of nodes that we will potentially need to lock for splits. We cannot rely on optimistic reads for the nodes we intend to modify because another writer could have already modified them. So we need to “pessimize” at the point of write.

Strategy: Use optimistic traversal to find the leaf, but as we go, we also check if any node is “full” (keys == 2t‑1). If a node is full, we acquire a write lock on it and hold it until the insert is done (or we split later). This is similar to lock‑coupling but we only lock nodes that are near splitting.

Alternatively, we can use a technique called “optimistic insertion without pre‑splitting”: first find leaf optimistically, then try to insert. If leaf is full, we then lock the leaf and parent (and maybe further up) recursively. This works but may cause deadlocks.

**Better approach: pessimistic lock coupling only for writers, but readers remain optimistic.**

In many implementations (e.g., the B-tree in SQLite’s next‑generation, WiredTiger, or MongoDB’s WiredTiger storage engine), writers use lock coupling along the path from root to leaf, but readers use optimistic concurrency. This avoids the full cost of lock coupling for readers.

Let’s design a writer’s path:

1. Traverse from root with write locks? That would be too heavy. Instead, we traverse with _optimistic_ reads until we find a node that is “risky” (full). At that point, we downgrade to pessimistic: acquire a write lock on that node (and continue downwards with write locks?).

A cleaner design: **The BzTree approach (Mao et al., 2012)** uses optimistic reads for all traversals, but writers, when they need to modify a node, they attempt to acquire the lock. If the lock is held, they retry. Once they have the lock, they may need to lock parent as well (locking upward). This is safe because the locks are acquired bottom‑up? But we need to ensure no deadlock.

Deadlock can be avoided if we always lock nodes in a consistent order (e.g., lock parent after child? That’s opposite of typical locking; but if we lock child first, then we might need parent. If another concurrent split locks parent first, deadlock. So we need a protocol: acquire locks in a global order, e.g., by memory address, or use a try‑lock with backoff.

In practice, many concurrent B‑trees use a **lock‑coupling approach for writers** where they lock the root first (write mode) and then child, releasing parent only after locking child. That makes splits easier because when you reach a full node, you already hold its parent lock. But that forces all writes to hold a chain of write locks, which serializes writers.

**Alternate: Link‑based approach (B-link tree)** – each node has a link pointer to the next sibling. Splits do not immediately update parent; instead they create a new node and link it, and later the parent is fixed. This decouples the modification and allows optimistic searches to follow links. However, it adds complexity.

For this blog, I’ll present a simplified but effective design: writers perform a **pessimistic lock‑coupling traversal** (holding write locks on path) but use a **try‑lock** to avoid blocking other writers too much. Readers are fully optimistic.

### 6.4 Writer Implementation Details

Pseudo‑code for insert:

```rust
fn insert(key: Key, value: Value) {
    // We'll maintain a stack of locked nodes (only nodes we've locked)
    let mut lock_stack: Vec<&BTreeNode> = Vec::new();
    let mut current = root.load(Ordering::Acquire);
    loop {
        // Lock current node in write mode (spin until acquired)
        let mut node = current;
        node.lock_write();
        lock_stack.push(node);

        // Check if node is leaf
        if node.is_leaf {
            // Insert (or split) ...
            // If leaf has space, insert and unlock all
            // If full, need to split – we already have lock on leaf. We'll need parent lock.
            // Parent should be the previous node in lock_stack.
            let parent = lock_stack[lock_stack.len()-2];
            // lock parent (if not already locked; we locked it earlier when we passed through)
            // Actually we had locked parent when we came through? In lock-coupling traversal,
            // we lock child, then unlock parent. So parent is already unlocked.
            // That's a problem: we need parent locked.
            // So we must not unlock parent until we are sure no split needed.
            // Classic technique: if node is full, we split *before* descending into it.
            // We lock parent, then split the full child, then descend.
            // So we must detect full nodes during traversal.
            ...

        } else {
            // internal node: find child index
            // read key array (safe because we hold write lock)
            let child = node.children[idx].load(Ordering::Acquire);
            // try to lock child? But to avoid deadlock we need to lock parent and child in order.
            // We'll lock child, then release parent only if child is not full.
            // Continue loop.
            // But we already have parent locked, so we lock child now.
            // Actually we need a different structure.
        }
    }
}
```

The above quickly becomes messy. To keep the post focused on the combination of OLC and SMO safety, I’ll instead describe the **high-level protocol** used in BzTree and similar.

### 6.5 BzTree Protocol Overview

- **Readers**: Optimistic traversal with version validation.
- **Writers**: After finishing optimistic traversal to leaf, they acquire a write lock on the leaf. If the leaf is not full, they insert and unlock. If full, they need to split, which requires locking parent. They attempt to lock parent ( try‑lock or spin). To avoid deadlock with other splits, they use a fixed order: always lock parent (if needed) before child? But they already hold child. So they must be willing to release child, lock parent, then re‑lock child? That could cause double‑acquisition complications.

Instead, BzTree uses **optimistic lock‑coupling for SMOs** as well: they do not hold locks for long; they use a mechanism of “lock‑free” splitting using CAS. The split of a leaf is done by creating new nodes and then atomically updating the parent using a compare‑and‑swap on the child pointer. If the CAS fails (because another writer changed parent), they retry. This is truly lock‑free for writers too (though they still use spin locks on individual nodes).

Thus, SMO safety is achieved by writing to parent only with CAS, ensuring that the parent’s version is incremented atomically. Readers that saw the old child pointer will validate parent after reading child pointer and detect the change when they see parent version increment.

So a practical design for a concurrent B‑tree with OLC and SMO safety can avoid write‑locking the entire path.

Let’s outline the split operation with CAS on parent:

**Leaf split (by writer W):**

1. W locks leaf L (set lock bit, get exclusive write access).
2. W creates two new leaf nodes: L_left and L_right, with keys split.
3. W prepares to update parent P:
   - CAS operation on P’s children array at the index that pointed to L.
   - Target: replace pointer to L with pointer to L_left, and immediately after, insert median key into P.
   - But this is not atomic. Need to ensure P’s version changes in a way that invalidates readers.

Better: W increases version of P (with lock bit) _before_ modifiying children, then updates children, then increments version again to unlock. This requires having a write lock on P. So we are back to needing lock on P.

How to acquire lock on P without holding lock on L? Can release lock on L first, then lock P, then lock L again? That could cause other threads to use L.

We can follow a **lock‑coupling scheme for splits only**: when traversing, if we encounter a full node, we lock it and its parent. This is the standard approach used in many concurrent B‑trees.

Given the complexity, the final design for this blog post will assume a **lock‑coupling writer** that locks nodes along the path from root to leaf, but only if they are full. This is called **selective lock coupling** or **partial lock coupling**.

### 6.6 Practical Code Example (Simplified)

Let’s write a more concrete insert that uses **optimistic search** for the initial descent, but once at leaf, if split is needed, we switch to a lock‑coupling re‑traversal. This is acceptable because splits are rare.

```rust
fn insert(key: Key, value: Value) {
    // Phase 1: optimistic descent to leaf
    let leaf = optimistic_search_to_leaf(key);

    // Try to lock leaf
    if leaf.try_lock_write() {
        if leaf.keys.len() < MAX_KEYS {
            // simple insert
            leaf.insert(key, value);
            leaf.unlock_write();
            return;
        }
        // full - need split
        // Release leaf lock? We'll need to hold it temporarily?
        // Better to lock parent.
        // But we don't have parent pointer. So we must re-traverse from root with lock coupling.
    }
    // Could not lock or need split
    // Phase 2: pessimistic re-traversal with lock coupling
    insert_with_split_protocol(root, key, value);
}
```

This hybrid is not efficient but shows the concepts.

---

## 7. Theory: Correctness Proof Sketch

We need to ensure linearizability. The key invariant: a reader that returns a successful result must have read a state that was consistent at some point between when the operation started and ended.

- For search: The reader traverses from root to leaf, taking version snapshots. If every step’s validation passes, then there exists a linearization point where the path was exactly as observed. Because any write that changes a node increments its version, the reader would have detected it and retried. Hence the reader’s result is equivalent to some atomic snapshot of the tree.

- For insert: The write locks ensure mutual exclusion. The optimistic readers that collide with the insert will either see the old state (if they validated before the write) or the new state (after validation). Linearization point is either at the moment the write lock is released on the leaf (or parent for splits).

---

## 8. Real‑World Applications

- **WiredTiger** (used in MongoDB) implements a B‑tree with optimistic concurrency and uses a variant of OLC. Their “paged tree” allows many concurrent operations.
- **LevelDB / RocksDB** use LSM‑trees, not B‑trees, but hybrid systems combine them.
- **SQLite’s newer “B‑tree” implementation** uses a form of optimistic search with lock‑coupling for writers.
- **In‑memory databases** (e.g., MemSQL) rely on similar techniques for high throughput.
- **NewSQL databases** like CockroachDB use a distributed variant but local KV stores often use B‑trees with OLC.

---

## 9. Performance Considerations and Trade‑offs

- **Retries**: Under high contention, readers may loop many times. To mitigate, add exponential backoff.
- **Cache coherence**: The optimistic read pattern generates many atomic loads, which can be expensive on some architectures (x86 is okay, ARM is heavier). But still better than taking write locks.
- **Memory reclamation**: Epoch‑based reclamation has its own overhead; may need to tune epoch frequency.
- **Write amplification**: Splits and merges are still expensive; OLC doesn’t change that, but reduces blocking.

---

## 10. Advanced Topics (Briefly)

- **Range queries**: Optimistic lock coupling is more complex because the cursor must validate each node as it moves to next sibling. Version can change during scanning.
- **Node compression**: For space efficiency.
- **Non‑blocking progress**: OLC is not lock‑free for writers; they still use locks. Truly non‑blocking B‑trees exist (e.g., using CAS on pointers) but are extremely complex.
- **Hardware transactional memory** (HTM) can be used to implement lightweight locking.

---

## 11. Conclusion

Building a concurrent B‑tree is a rite of passage for students of concurrent data structures. Optimistic lock coupling reduces contention for readers while maintaining correctness. SMO safety ensures that structural changes like splits and merges do not corrupt the tree or cause readers to see inconsistent state.

The combination of optimistic reads for search and pessimistic writes with careful lock management yields a system that scales well on modern multi‑core hardware. While the implementation details are intricate—memory reclamation, version validation, race conditions—the payoff is a data structure that forms the bedrock of high‑performance storage engines.

Whether you are building a custom key‑value store or just want to dive deeper into concurrency, understanding OLC and SMO safety will serve you well. Armed with the concepts and code sketches from this article, you are ready to implement your own concurrent B‑tree or appreciate the low‑level tricks used in industrial databases.

_Next steps: explore the BzTree paper, study WiredTiger’s source, and experiment with your own implementation in Rust or C++._

# Building a Concurrent B-Tree with Optimistic Lock Coupling and SMO Safety

Concurrent B-trees are the backbone of countless database systems, key-value stores, and file systems. Traditional implementations rely on pessimistic lock coupling (latch coupling): as a thread traverses from root to leaf, it holds a latch on the current node, then acquires a latch on the child before releasing the parent. This serializes access along the path, guaranteeing safe structure modification operations (SMOs) like split and merge. But the overhead of acquiring and releasing latches on every node – especially for read-only operations – can dominate runtime when concurrency is high and the tree is hot.

**Optimistic lock coupling** offers an alternative: most of the time, a thread reads a node without holding any lock, relying on version counters to detect concurrent modifications. Only when the thread performs a write – or when it needs to ensure structural integrity – does it take exclusive control. This dramatically reduces cache-line bouncing and allows CPUs to work in parallel. However, SMO safety becomes much trickier: a split or merge can invalidate a node that another thread is optimistically reading. In this post, we’ll build a concurrent B-tree that combines optimistic traversal with careful structural change guards – and we’ll dive into the edge cases, performance trade-offs, and expert techniques that make it work in practice.

## Background: Nodes, Latches, and Versions

A B-tree node typically holds an array of keys, an array of child pointers (or values for leaf nodes), a count of active entries, and a lock (latch). In our design we extend each node with:

- A **version counter** (a monotonically increasing 64-bit integer, atomically loaded and stored).
- A **lock bit** embedded in the same 64-bit word (e.g., the lowest bit indicates write-locked; the remaining bits form the version).
- A **state flag** to mark nodes as “being split” or “being merged”.

The lock word is manipulated with compare-and-swap (CAS) on 16-byte aligned structs (or an 8-byte word if we pack version and lock into 63 bits). This single atomic word enables a lightweight read-write lock: writers set the lock bit, readers check it.

A key invariant: **any modification to a node – key insert, key delete, child pointer update – increments the version** (while holding the lock). Therefore, an optimistic reader can read the version at entry, read the node’s contents, then re-read the version. If the version has not changed _and_ the lock bit was never set during the read window, the data is consistent.

## Optimistic Search: Read Without Locks

Let’s consider a simple `search(key)` that returns the leaf node (or value). In a pessimistic design, we would latch each node, read the child pointer, then unlatch the parent. Optimistically, we don’t latch at all:

```c
// Pseudocode for optimistic search
Node* optimistic_search(Node* root, Key key) {
    Node* node = root;
    while (node->type == INTERNAL) {
        uint64_t v1 = atomic_load(node->lock_word);
        if (v1 & LOCK_BIT) { /* someone holds exclusive lock, retry */ continue; }

        int idx = node_find_child(node, key);
        Node* child = node->children[idx];

        // Memory fence: ensure child pointer is read before next version check
        atomic_thread_fence(memory_order_acquire);

        uint64_t v2 = atomic_load(node->lock_word);
        if (v2 != v1) {
            // Node was modified (possibly split/merged), retry from root
            node = root; // or better: restart from current node with safety
            continue;
        }
        node = child;
    }
    // Now node is a leaf; do final optimistic check
    return leaf_lock_check(node, key);
}
```

This is a textbook optimistic read, but it has subtle flaws. The most critical edge case is **node splitting**: if the current internal node is being split while we hold a pointer to a child, that child may have already been moved to a new sibling, and the child pointer in the original node might be stale or pointing to a node that no longer belongs to the B-tree’s logical structure. Our version check `v2 == v1` only tells us that no _write_ happened on the node itself – but a split of the child can occur independently. The child’s pointer in the parent is updated only _after_ the split is fully committed. So we need a different strategy.

The typical solution in optimistic B-tree implementations (e.g., PalDB, Masstree, BzTree’s ancestors) is to couple the version checks with **SMO detection** at each level. One approach: embed a “generation” or “split count” in the child pointer itself (e.g., use a versioned pointer). Another: force readers to take a shared latch on the parent when they intend to descend. But that reintroduces lock coupling.

A more elegant technique – used in the OLFIT (Optimistic Lock-Free Index Traversal) method – is to treat each step as an optimistic read on the _child_, not the parent. After we compute the child pointer, we immediately perform an optimistic read on the child node itself before releasing the parent’s validity check. This is the **optimistic lock coupling** at its core: **we rely on the child’s version, not the parent’s, to detect structural changes**. The parent’s version is used only to ensure the child pointer we read was valid at that moment.

Let’s rewrite the descent:

```c
while (node->type == INTERNAL) {
    // 1. Optimistic read of parent to get a child pointer
    uint64_t parent_v = atomic_load(node->lock_word);
    if (parent_v & LOCK_BIT) { busy_wait_retry(); continue; }
    int idx = node_find_child(node, key);
    Node* child = node->children[idx];
    atomic_thread_fence(memory_order_acquire);

    // 2. Optimistic read of child to verify its integrity
    uint64_t child_v = atomic_load(child->lock_word);
    if (child_v & LOCK_BIT) { /* child locked, retry */ ... }

    // 3. Validate the parent still points to this child (parent not split)
    uint64_t parent_v2 = atomic_load(node->lock_word);
    if (parent_v2 != parent_v) {
        // Parent changed – the child pointer may be stale
        continue; // restart from root (or re-read parent)
    }
    // 4. Now we have a consistent snapshot: parent stable, child stable
    node = child;
}
```

This double validation is the heart of optimistic lock coupling. The child’s version ensures that no one is in the middle of modifying it (split/merge). The parent’s re-check ensures that the parent hasn’t redirected the pointer (e.g., as part of a split that installed a new node). But there is still a gap: what if the child split _after_ we read its version but before we validated the parent? The next iteration will catch it because we will then attempt to validate the new child’s version. So the search either succeeds or retries – and because retries are rare, this is acceptable.

## SMO Safety: How to Split Without Breaking Optimistic Readers

Any concurrent B-tree must guarantee that while a structure modification operation (split or merge) is in progress, no reader sees an inconsistent state. When using optimistic coupling, the major challenge is ensuring that old nodes remain accessible and recognizable as valid until all active readers that might reference them have finished.

### The Split Operation

A standard B-tree split of a full leaf `L` into `L` and `new_leaf`, then inserting a separator key into the parent `P`. With optimistic readers, the steps must be:

1. **Lock the node to be split** (exclusive).
2. Increment its version (now `version | LOCK_BIT`).
3. Allocate a new sibling node.
4. Copy half the items to the new node.
5. **Insert the separator into the parent** – this is the dangerous step because the parent may be read optimistically by other threads.
6. Once the parent update is visible, release the lock on the (now half-empty) original node.

But consider a reader that has optimistically read `L` and has not yet checked its version. That reader holds a pointer to `L` from an earlier step. If we release the lock on `L` quickly, the reader may see `L`’s version unchanged (because we didn’t increment it after the parent update? Actually we did increment at step 2). The reader will detect the version change and retry. But what about a reader that just read the parent’s child pointer (pointing to `L`) and is about to read `L`? That reader will first check `P`’s version – which we haven’t changed yet (only `L` is locked). So the reader may proceed to `L` while `L` is locked. It will spin or retry because the lock bit is set. That’s safe.

The real problem occurs when the parent update is **not yet complete** in the eyes of the reader. If we update the parent’s child pointer to point to `new_leaf` (during step 5), we must ensure that the parent’s version is also incremented to force any reader that has an outdated version of the parent to retry. This is classic coupling: we lock the parent, update its slot, increment its version, then unlock.

Because we are using optimistic coupling for search, we need to avoid holding parent and child locks simultaneously for long periods (to prevent deadlock and reduce contention). A common pattern is:

- Lock the child exclusively.
- While the child is locked, prepare the new sibling.
- Then **couple** the lock to the parent: lock the parent (which may require retrying if another thread holds it), insert the separator, increment parent version, unlock parent.
- Finally unlock the child.

This is **write lock coupling** – only used for SMOs. The crucial safety property: **no thread ever sees a parent pointer to a node that is in an inconsistent “during split” state**, because we only change the parent after the child is fully split (i.e., both halves are consistent and individually valid). And we increment the parent’s version so that optimistic readers of the parent are forced to reload.

### Merging and the Ghost Node Problem

Merge operations (after deletions) present a similar but trickier edge case. When a node becomes underfull, we may decide to merge it with a sibling and then delete the common parent entry. If we simply deallocate the merged node, an optimistic reader that still holds a pointer to it will crash.

The standard solution is **garbage collection with epoch-based reclamation (EBR)** or a **global version clock**. For the B-tree itself, we can use a simpler “ghost node” technique: mark the node as **invalid** before unlinking it. A reader that detects an invalid node (e.g., a special flag in the version word) retries. However, this still requires a mechanism to eventually free the node after no active readers can see it.

A robust approach is to combine optimistic coupling with **hazard pointers** or **RCU**. In the B-tree context, a lighter variant is to use a per-thread **epoch** that tracks the current version of the tree. When a node is to be deleted, it is placed in a delay queue and not freed until all threads have advanced past the deletion epoch. For brevity, we can assume that after the parent update and version increment, we can safely retire the old node to a freelist that is freed only after a grace period.

## Edge Cases and Race Conditions

Even with the above skeleton, several subtle race conditions can arise.

### 1. **Double split of the same node**

If thread A is splitting node `N`, and thread B holds an exclusive lock waiting for `N`, thread B may see that `N` is still full after A finishes. But A inserted a separator into the parent, so `N` is now half empty. However, the parent has a new child pointer. Thread B must re-read the parent after acquiring the lock, realizing that `N`’s occupancy has changed. This requires careful unlocking: after a split, the lock holder should not assume the node is stable for further writes without re-checking.

### 2. **Cascading splits**

A split at the leaf may cause a split at the internal node if the parent is full. Using optimistic coupling for the traversal phase, we don’t pre-lock the entire path. Therefore, when we need to update the parent as part of the split, we must _acquire_ the parent lock at that moment. This could lead to a deadlock if we hold the leaf lock and try to grab the parent lock while another thread holds the parent lock and waits for the leaf. The classic solution: **never wait for a lock while holding another lock** – or always acquire locks in a consistent order (root to leaf). Since we already hold the leaf lock, we must be prepared to release it temporarily if we cannot acquire the parent lock without waiting. This introduces the risk of losing work; we can retry the entire procedure. Alternatively, we can pre-lock the entire path to the leaf using pessimistic write coupling for SMOs, and only use optimistic reads for pure search. Many practical implementations do exactly that: searches are optimistic, but modifications use traditional latch coupling from root to leaf. This hybrid approach gives the performance benefit of optimistic reads while simplifying SMO logic.

### 3. **Phantom reads in leaf after split**

A reader that falls into the old leaf after the split may see the leaf as half-empty, but the key it seeks might actually be in the new sibling. The optimistic coupling ensures that the reader will later detect the version change and retry, eventually re-entering from the parent and finding the correct leaf. However, if the reader does not re-check the parent after descending, it might miss the redirection. This is why the double validation (parent then child) is essential.

## Performance Considerations

### Cache and Contention

In a read-dominated workload, optimistic lock coupling almost entirely eliminates cache-line migrations for lock structures. Every node’s lock word is read but not written, so the cache line stays shared (S state) across many cores. Only during writes do we need exclusive access (M state). The result is excellent scalability: many implementations achieve near-linear read throughput up to dozens of cores.

However, the retry loop in optimistic reads incurs branch mispredictions and potential spinning if the lock bit is frequently set. On highly contended nodes (e.g., the root in a small tree), it may be beneficial to use a shared latch (readers-readers allowed) to avoid the retry overhead. In practice, we can employ a spin-then-yield strategy: first spin a few dozen iterations, then back off.

### Version Increments

Every write operation must increment the node’s version. This is an atomic add (or CAS) that may share cache line with concurrent readers. Because version increments are relatively infrequent compared to reads, the cache coherence cost is modest. But if many concurrent writes target the same leaf (e.g., a hotspot key range), the leaf’s version will bounce between cores, causing readers to retry. This is the classic “hot spot” problem. Mitigation: use **node splitting to spread load** (which is exactly what B-tree does), or adopt a **version per key** strategy (as in BzTree), but that’s beyond our scope.

### Memory Overhead

Each node requires an atomic lock word and a version field (often combined). The overhead is small (8 bytes) per node. For internal nodes, we also store child pointers and keys. Using packed arrays, the total memory is acceptable.

## Best Practices and Common Pitfalls

### 1. **Memory Ordering**

Never forget `memory_order_acquire` on the version check after reading child pointers, and `memory_order_release` when incrementing version after writing. Incorrect ordering can produce subtle reordering bugs that may fail only on specific ARM or PowerPC hardware.

### 2. **Retry from Root vs. Retry from Current**

Restarting the search from the root on every version mismatch is safe but can amplify latency if the tree is deep. A better approach is to retry from the current node (after a full fence), because the version mismatch only invalidates our path from that node downward. However, if the node has been split, we may need to know the new root of the subtree. The safe middle ground: retry from the current node’s parent (which we have already validated once). To do that, we need to maintain a stack of nodes with their versions – exactly as in optimistic lock coupling for the B-link tree. For simplicity, many production systems (e.g., Berkeley DB’s Concur) restart from root; the performance impact is negligible because retries are rare (single-digit percentage under moderate contention).

### 3. **Deadlock Avoidance**

As noted, never hold a child lock while waiting for a parent lock. Implement try-lock or timely release-and-retry.

### 4. **Testing with Concurrency Stress**

Use ThreadSanitizer (TSan) and Relacy Race Detector during development. Model-check the state machine of SMOs with a small tree size. A single missed fence can cause corruption that appears only after millions of operations.

### 5. **Write Amplification**

If a split causes insertion into a full parent, which triggers another split, the SMO can cascade up the tree. Optimistic reading during a cascade is not affected because each parent version is incremented only after the child modifications are complete. However, the number of locks held simultaneously increases. To prevent stack overflow and prolonged exclusive sections, consider performing the whole cascading split as a single “atomic” operation: lock the entire path first (pessimistic), then split from leaf upward, unlocking as we go. This is simpler and still uses optimistic coupling for read-only search.

## Deeper Insights: Where Optimistic Coupling Shines

Optimistic lock coupling is not just a performance trick; it is an elegant expression of **validation-based concurrency control**. The B-tree’s structure lends itself to validation: each node’s version acts as a timestamp that summarizes all recent modifications. A reader that sees an unchanged version knows that none of the pointers it read from that node have been invalidated. This is essentially a **snapshot isolation** model for tree navigation.

Contrast this with a fully lock-free B-tree (like BzTree). In a lock-free design, every pointer must be updated with CAS, and retry loops replace all locks. The complexity skyrockets, especially for SMOs that require multi-pointer atomic updates. Optimistic lock coupling offers a sweet spot: **near-lock-free reads with simpler writes**.

The technique is especially powerful in **hybrid transactional memory** systems, where short critical sections (like reading a node pointer) are accelerated by hardware, and long ones (SMOs) use software fallback. Future non-volatile memory (NVM) will also benefit – optimistic reads avoid log forces and persist barriers until the moment of version increment.

## Conclusion

Building a concurrent B-tree with optimistic lock coupling and SMO safety is a rewarding exercise in balancing correctness and performance. By embracing optimistic reads, we eliminate most lock acquisitions for the common case (search). By carefully coupling write locks during splits and merges, we maintain structural integrity without sacrificing concurrency. The key is to treat each node as an independent validation point, to double-check after every descent, and to handle retries gracefully.

The approach is not without challenges: cascading splits, hotspot nodes, and memory reclamation demand attention. But for many systems – from in-memory key-value stores to database indexes – the trade-off strongly favors optimistic coupling. It delivers scalable performance on modern hardware while keeping the codebase manageable.

Whether you are implementing a new storage engine or optimizing an existing one, consider adopting optimistic lock coupling for your B-tree. The learning curve is steep, but the rewards in throughput and simplicity are well worth it.

# Conclusion: The Art and Science of Concurrent B-Tree Design

Our journey through building a concurrent B-tree with optimistic lock coupling and SMO safety has been a deep dive into one of the most elegant yet challenging problems in systems programming. We’ve navigated the treacherous waters between performance and correctness, between the simplicity of single-threaded indexing and the messy reality of concurrent access. Before we close, let’s step back and reflect on the terrain we’ve covered—and what it means for you as a practitioner.

## What We Learned: A Recap of the Core Ideas

We began with the fundamental question: how can multiple threads safely and efficiently read and modify a B-tree without destroying performance? The naive approach—a single global lock—is correct but destroys scalability. The lock-free extreme avoids locks entirely but introduces immense complexity, especially for structure-modification operations (SMOs) like node splits and merges.

The answer lies in a balanced approach. **Optimistic lock coupling** (OLC) offers a middle ground: most readers proceed without any lock, relying on version numbers to detect concurrent modifications. This dramatically reduces contention because reads dominate in most workloads. The key insight is that read operations are cheap and frequent; they should not pay the cost of pessimistic locking unless absolutely necessary.

We then tackled the thorny problem of SMO safety. A B-tree’s topology can change at any instant: a split can introduce a new sibling, a parent pointer can change, or a merge can delete a node. Optimistic readers must detect these changes and retry. Writers, on the other hand, need to coordinate to prevent races that could corrupt the tree. We saw how **hand-over-hand optimistic locking** (also called “lock coupling with latches”) allows a writer to traverse the tree while holding only a small number of latches, using version checking to validate that the path remains consistent. For SMOs themselves, we introduced a **latched coupling parent-link scheme** or a **global SMO lock** (depending on your design philosophy) to ensure that splits and merges are atomic with respect to readers.

The design space is rich: do you use a separate lock array per node? Do you embed a version counter in the node header? Do you allow multiple concurrent splits? Do you use epoch-based memory reclamation to handle node deletion safely? We explored these trade-offs, noting that the “best” approach depends on your workload, hardware, and maintenance budget.

## Actionable Takeaways for Your Own Implementation

If you’re now convinced that concurrent B-trees are both fascinating and practical, here are concrete steps you can take to apply these ideas in your own projects:

### 1. Profile First, Optimize Later

Before implementing any concurrency scheme, understand your workload. Is it read-heavy? Write-heavy? Mixed? Do operations tend to be point lookups, range scans, or bulk inserts? Optimistic lock coupling shines when reads are common and writes are sparse. If your workload is write-dominated, a pessimistic approach (perhaps using reader-writer locks with adaptive retry) may be simpler and equally performant.

### 2. Start with a Baseline Pessimistic Design

Do not jump straight to optimistic lock coupling. Implement a simple pessimistic B-tree with hand-over-hand latches (like the classic Lehman & Yao or a basic lock coupling scheme). Use this as a correctness and performance baseline. Then introduce optimism incrementally: first for point lookups, then for scans, and finally for updates that avoid SMOs. Test each step thoroughly.

### 3. Invest in a Robust Version Number System

Version numbers are the heart of optimistic concurrency. They must be atomic, monotonically increasing, and carefully placed. A common pitfall is not updating the version number atomically with the data changes. Use `std::atomic` or memory barriers to ensure that a reader sees either the old value with the old version or the new value with the new version—never a mix. Additionally, design your reader’s retry logic to be efficient: a busy loop with a small backoff can save CPU when contention is low, but use exponential backoff only if retries become frequent.

### 4. Handle SMOs with Care

SMOs are the most error-prone part of any concurrent B-tree. Do not try to be too clever. Even in optimistic designs, you likely need a form of coupling (locking the parent and the affected nodes) during splits and merges. The classic approach is to hold a writable latch on the parent node while updating its pointer and adding a new child—this prevents concurrent readers from seeing an inconsistent state. A simpler alternative is to use a global mutex for all SMOs, but that serializes writes. If your write throughput is high, consider a more fine-grained scheme such as the “SMO lock” per node layer, or use version checking on parent pointers to allow concurrent SMOs on different subtrees.

### 5. Memory Reclamation Is Not an Afterthought

When nodes are removed (during merges or rebalancing), you cannot free them immediately because concurrent readers may still be accessing them. Failure to handle this leads to use-after-free bugs that are notoriously difficult to reproduce. Use **epoch-based reclamation (EBR)**, hazard pointers, or a garbage collector designed for concurrent data structures. EBR is often a good fit because it allows you to defer deallocation until all threads that started before a certain point have finished. Integrate this into your design from day one; retrofitting memory reclamation is painful.

### 6. Test Correctness Under Stress

You cannot manually reason about all interleavings. Use stress testing with thread sanitizers (TSan), address sanitizers (ASan), or even formal verification tools like TLA+ to model your algorithm. Implement a simple key-value store on top of your B-tree, run thousands of concurrent operations, and verify that every key inserted is eventually found, that no duplicates appear, and that range scans return consistent snapshots. Pay special attention to boundary cases: inserts at the same key, concurrent splits and lookups on the same node, and interactions with deletes.

### 7. Consider the Hardware

The performance of optimistic lock coupling can vary wildly between CPUs. Cache-line contention, memory ordering models (x86 vs. ARM), and the overhead of atomic instructions all matter. Profile on your target hardware. A design that works brilliantly on a 64-core x86 server may suffer on a multi-socket NUMA system or a low-end mobile processor. Also, be mindful of false sharing: place frequently written fields (like version numbers) on separate cache lines from read-heavy fields (like keys and pointers).

## Further Reading and Next Steps

This blog post is part of a rich literature on concurrent indexing. If you want to go deeper, I strongly recommend the following resources:

### Classic Papers

- **“Efficient Locking for Concurrent Operations on B-Trees”** by Lehman and Yao (1981) – The seminal paper that introduced hand-over-hand locking (lock coupling). A must-read.
- **“Concurrent Operations on B-Trees with O(1) Locking”** by Sagiv (1986) – Explores how to reduce lock footprint further, including early ideas of optimistic traversal.
- **“The UB-Tree: A Concurrent B-Tree Variant”** – Graefe’s work at Microsoft on B-tree concurrency, especially his comprehensive surveys “A Survey of B-Tree Locking Techniques” and “Modern B-Tree Techniques”. These are encyclopedic but invaluable.

### Modern Implementations

- **Masstree** (Mao et al., NSDI 2012) – A highly concurrent key-value store that uses a B-tree variant with optimistic lock coupling for fast internal nodes and pessimistic locking for leaves. Its approach to SMO safety (using a global “epoch” to coordinate splits) is a great reference.
- **BwTree** (Levandoski et al., VLDB 2013) – A completely latch-free B-tree that uses a delta-record approach. It’s complex but shows the extreme end of concurrent design.
- **WiredTiger** (used in MongoDB) – An open-source storage engine that uses a sophisticated mixture of optimistic and pessimistic locking for its B-tree implementation. Study its source code for real-world lessons.
- **SQLite’s B-tree** – A simpler, single-writer-many-reader design that is not concurrent in the multi-writer sense, but it’s clean and well-commented. Good for understanding B-tree fundamentals.

### Books

- **“The Art of Multiprocessor Programming”** by Herlihy and Shavit – The bible of concurrent data structures. Chapters on concurrent trees and lock-free algorithms are directly applicable.
- **“Database Systems: The Complete Book”** by Garcia-Molina, Ullman, and Widom – Covers B-tree internals and concurrency from a database perspective.
- **“Programming with POSIX Threads”** by Butenhof – While dated, it provides a solid foundation for understanding threads and synchronization primitives.

### Your Next Project

Now that you understand the theory, the best way to solidify it is to build one yourself. Start with a simple optimistic lock coupled B-tree for a single-key-value store (like an in-memory index). Implement only point lookups, inserts, and maybe range scans. Then add SMO safety with split and merge. Run your own stress tests. Then consider integrating it into a larger system—a database buffer manager, a file system, or a key-value cache. Each new context will teach you something about the trade-offs.

## Closing Thought: The Beauty of Optimism

Building a concurrent B-tree is a humbling experience. The first attempt will almost certainly have bugs—a missing version check, a wrong ordering of unlocks, a race between a split and a read. That’s okay. The beauty of optimistic lock coupling is that it forces you to think about what you _know_ and what you only _believe_ to be true at any moment. Every reader is a skeptic: “I think this page is consistent, but I will verify.” Every writer is a cautious diplomat: “I need to change the structure, but I will do so without breaking the trust of all those readers.”

In a world of massively parallel processors and demand for real-time indexing, optimism is not just a nice-to-have—it’s a practical necessity. Pessimism (locking everything in sight) kills scalability. Pure lock-freedom often proves too complex for production systems. Optimistic lock coupling, with its pragmatic mixture of cheap reads and careful writes, sits in the sweet spot. It acknowledges that most of the time, conflicts don’t happen, and it leverages that reality to extract every ounce of performance.

But remember: complexity is a cost. Only add optimistic lock coupling where you measure a clear performance gain. Document your version-number protocol carefully. Write tests that simulate the worst-case scenarios. And when you inevitably face a mysterious crash under heavy load, remember that the bug is almost certainly in your own code, not in the algorithm.

Now go forth and build faster, safer indexes. The tree of concurrent knowledge awaits.
