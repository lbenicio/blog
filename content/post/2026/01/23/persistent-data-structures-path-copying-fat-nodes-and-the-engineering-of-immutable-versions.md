---
title: "Persistent Data Structures: Path Copying, Fat Nodes, and the Engineering of Immutable Versions"
description: "A deep, implementation-oriented tour of persistent data structures: the four degrees of persistence, path copying, fat nodes, node copying with modification boxes, the DSST framework, the amortization trap, purely functional structures, persistent vectors, HAMTs, copy-on-write B+ trees, Git's object graph, confluent persistence, memory management, cache behavior, and the concurrency benefits of versioned data."
date: "2026-01-23"
author: "Leonardo Benicio"
tags: ["data structures","persistence","immutability","functional programming","memory management","concurrency","databases","systems design"]
categories: ["Computer Science","Systems Design"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/persistent-data-structures-path-copying-fat-nodes-and-the-engineering-of-immutable-versions-2026-01-23.jpg"
coverAlt: "An abstract technical illustration of branching versioned data structures, with glowing path-copied nodes, layered persistent trees, and interconnected graph motifs on a dark background."
---

# Persistent Data Structures: Path Copying, Fat Nodes, and the Engineering of Immutable Versions

There is a class of ideas in computer science that spend years looking like academic curiosities and then turn out to be load-bearing. Persistent data structures are one of them. The technique shows up in version control, copy-on-write filesystems, snapshot isolation in databases, functional programming runtimes, incremental build systems, and the immutable state trees that front-end frameworks rebuild thousands of times per second. Once you know what to look for, you start seeing persistence everywhere.

The central question is deceptively simple. Suppose you have a data structure, and you want to keep every previous version of it accessible after you update it. The naive answer is to copy the whole thing on every write. That answer is correct, and it is also almost always unacceptable: it turns an O(log n) update into an O(n) update and turns a sequence of m updates into O(n·m) total space.

Persistence is the study of how to do better. The good news is that for a huge class of pointer-based structures, you can get persistence essentially for free: constant amortized space per update and constant time per operation, in the partially persistent case. The bad news is that the moment you want to write to old versions, or merge two versions together, or persist a structure whose efficiency depends on amortization, the costs reappear and the design space becomes genuinely subtle.

This article is a working engineer's tour of that design space. We will define persistence precisely, survey the four classical degrees of it, walk through the three canonical implementation techniques (path copying, fat nodes, and node copying), examine the theoretical framework that ties them together, and then look hard at the places where theory and practice diverge: amortization, memory reclamation, cache locality, and concurrency.

## 1. What Persistence Means, and What It Does Not

The word 'persistent' is overloaded in systems work, and the collision causes real confusion. In storage and operating systems, persistence usually means durability: data survives a crash because it was written to a non-volatile medium. A persistent hash map in that sense is a hash map backed by a file or a memory-mapped region.

That is not what we mean here. In the data-structure literature, persistence is a statement about versions. A data structure is persistent if operations can be applied to versions other than the most recent one. The structure lives in memory; the question is whether the old shapes remain reachable.

A useful way to frame it: persistence is a property of the interface, not of the implementation. You can build a persistent structure by copying, by tagging nodes with version numbers, or by never mutating anything at all. The interface promises that after you perform an update, the old version is still there and still correct. How you deliver on that promise is an implementation detail.

This distinction matters because it separates persistence from immutability. An immutable structure is trivially persistent: there is only ever one version, and every operation returns a new one. But a persistent structure need not be immutable internally. Fat nodes and node copying both mutate memory in place; they simply maintain enough bookkeeping that old versions remain readable. The classic 1986 paper by Driscoll, Sarnak, Sleator, and Tarjan is entirely about adding persistence to structures that were designed to be ephemeral, using mutation as the implementation strategy.

There is a third term worth pinning down: ephemeral. An ephemeral structure has exactly one version. When you update it, the previous state is gone. Almost every data structure you learned in an undergraduate algorithms course is ephemeral: arrays, linked lists, balanced trees, hash tables. Persistence is the property that ephemeral structures lack.

## 2. The Four Degrees of Persistence

The standard taxonomy, introduced by Driscoll, Sarnak, Sleator, and Tarjan, distinguishes four levels. They are worth memorizing because they predict which techniques are available and what they cost.

**Ephemeral.** One version. Updates destroy the previous state. This is the baseline against which everything else is measured.

**Partially persistent.** Every version is readable, but only the newest version is writable. The versions form a linear sequence: v0, v1, v2, and so on. You can ask 'what did this look like at version 7?' but you cannot go back and modify version 7 to produce a new version 7-prime. Partial persistence is the model behind snapshot isolation, time-travel queries, and undo logs.

**Fully persistent.** Every version is both readable and writable. Updating an old version produces a new version that branches off it. The versions now form a tree rather than a line: each update creates a child of the version it was applied to. Full persistence is what you get in a purely functional language, where every operation on a value produces a new value and the old one remains available for further use.

**Confluent persistence.** Every version is readable and writable, and additionally you may combine two versions into one. The versions form a directed acyclic graph rather than a tree. Confluent persistence is the model behind merge operations: version control systems, CRDTs, and any system where two divergent histories must be reconciled.

The progression is not just about features; it is about cost. Partial persistence of a bounded-in-degree pointer structure is essentially free. Full persistence costs a logarithmic-in-log factor in the general case. Confluent persistence costs a logarithmic factor and, in some formulations, can blow up space exponentially if you are careless. Each step up the ladder buys expressive power with asymptotic overhead.

There is also a variant called **erasable persistence**, where old versions may be deleted to reclaim memory. Driscoll and colleagues considered this case too. It matters in practice because a long-running system that keeps every version forever will eventually run out of memory; you need a policy for discarding versions that are no longer reachable. In a garbage-collected language this falls out naturally from reachability. In a manual-memory language you have to build it.

## 3. Why Persistence Matters in Practice

Before diving into mechanisms, it is worth being concrete about why anyone should care. Persistence is not a solution in search of a problem; it is a solution to several problems that recur constantly.

**Undo and redo.** Any editor, drawing tool, or configuration system needs to move backward and forward through states. If your state is a persistent structure, undo is just keeping a pointer to the previous version. There is no need to record inverse operations, and there is no risk that an inverse operation is subtly wrong. The cost is the space of the versions you keep.

**Snapshot isolation in databases.** A transaction should see a consistent view of the database as of the moment it started, unaffected by concurrent writers. If the storage engine is a copy-on-write B+ tree, a snapshot is a pointer to a root page. Readers never block writers and writers never block readers, because they are literally looking at different trees that share most of their pages.

**Time-travel queries.** 'Show me the state of this account as of last Tuesday.' With a versioned structure, this is a lookup, not a replay of the write-ahead log. Systems like Datomic and XTDB build entire products around this capability.

**Functional programming.** In a language without mutable state, every operation must produce a new value. If the runtime copies the whole value each time, functional programming is unusably slow. Persistent data structures are what make immutable collections practical. Clojure's vectors and maps, Scala's immutable collections, Haskell's containers, and OCaml's Map and Set are all persistent.

**Concurrency.** An immutable value can be shared across threads with no synchronization at all. A reader that holds a reference to a version is guaranteed that the version will not change underneath it. This is the foundation of read-copy-update (RCU) in the Linux kernel, of persistent data structures in concurrent runtimes, and of the 'snapshot' pattern in lock-free algorithms.

**Incremental computation and caching.** If two computations produce structurally identical results, a persistent structure lets them share memory. Build systems, memoization layers, and incremental view maintenance all exploit this. Nix's store, Bazel's action cache, and Git's object database are all examples of content-addressed sharing.

**Version control and patch theory.** Git's entire object model is a persistent structure: a Merkle DAG in which unchanged subtrees are shared between commits. The reason `git commit` is fast even in a huge repository is that it only writes the objects that changed.

**Copy-on-write filesystems.** ZFS, Btrfs, and APFS all use copy-on-write trees. A snapshot is a root pointer. The filesystem never overwrites a live block; it writes a new block and updates the parent pointer, recursively up to the root. This is path copying applied to a B-tree on disk.

**Distributed state and CRDTs.** When two replicas diverge and must be merged, the merge operation is a confluent-persistence operation. Conflict-free replicated data types are, in effect, persistent structures whose merge function is designed to be commutative, associative, and idempotent.

The pattern is consistent: whenever you need to keep old states around, share structure between them, or merge divergent states, you are in persistent-data-structure territory.

## 4. The Baseline: Copy Everything

The simplest way to make any structure persistent is to copy it before every update. If you have an ephemeral array and you want a persistent one, allocate a new array, copy the old contents, apply the change, and return the new array. Old versions remain untouched because you never wrote to them.

This is correct and it is the right answer surprisingly often. If your structure is small, or your version count is small, or updates are rare, copying is fine. It has no subtle bugs, it needs no version numbers, and it composes with everything.

The problem is the asymptotics. Copying an array of n elements costs O(n) time and O(n) space per update. If you keep m versions, you have spent O(n·m) space. For a 100,000-element array and 10,000 versions, that is a billion element-slots. The whole point of persistence research is to avoid this.

Notice that copying is wasteful in an obvious way: most of the structure did not change. If you modify one element of an array, n−1 elements are identical to the previous version. A persistent structure should be able to share them.

## 5. Path Copying

Path copying is the most intuitive way to exploit that observation. The idea: to update a node, do not modify it. Instead, allocate a new node with the updated contents. If the node has children and one of them changed, the new node points at the new child. Recurse up to the root. Every node not on the path from the root to the modified node is shared verbatim between the old and new versions.

The result is that an update touches only the nodes along one root-to-leaf path. For a balanced binary search tree of n nodes, that is O(log n) new nodes and O(log n) time. For a trie keyed by strings of length k, it is O(k). For a linked list, it is O(n), which is why path copying a linked list is no better than copying it outright.

Path copying has several properties that make it the default choice in practice.

First, it requires no version numbers and no bookkeeping. A node is either shared or new; there is no per-node history. This keeps nodes small and cache-friendly.

Second, it works regardless of in-degree. A node can have any number of parents, because you never need to update a parent in place. You only ever create new parents along the path you are already walking.

Third, it is naturally concurrent. Because you never mutate a reachable node, a reader holding a reference to the old root sees a perfectly consistent old version while a writer builds a new one. There is no window in which the structure is half-updated. This is the property that makes persistent structures so attractive for lock-free algorithms.

Fourth, it composes. If every node is immutable, then any structure built from those nodes is immutable, and you can nest persistent structures inside each other without thinking about it.

The costs are equally clear. Every update allocates O(depth) nodes, which is allocation pressure on the heap and garbage-collector pressure in managed runtimes. Each new node is a fresh cache line that was not in cache before, so the first traversal after an update is likely to miss. And the depth factor means path copying is only attractive for structures with logarithmic or constant depth.

A persistent singly linked list is the extreme case in the good direction. Prepending an element allocates one node and takes O(1) time. This is why cons lists are the canonical functional data structure: the operation that matters most (adding to the front) is free.

```c
typedef struct node {
    int value;
    struct node *next;
} node;

/* Persistent prepend: allocates one node, shares the entire tail. */
node *cons(int value, const node *tail) {
    node *n = malloc(sizeof(node));
    n->value = value;
    n->next  = (node *)tail;   /* shared, never mutated */
    return n;
}
```

The asymmetry is instructive. Prepending is O(1); appending is O(n) because you must rebuild the whole spine. Persistent structures reward operations that touch a small, bounded region and punish operations that touch the whole structure. This is a general theme: when you design a persistent data structure, you are designing for locality of change.

## 6. Fat Nodes

Path copying duplicates nodes along a path. Fat nodes take the opposite approach: keep one copy of each node, but make each field capable of storing multiple values, one per version.

Concretely, a fat node stores, for each field, a list of pairs (version, value). When you update field f of node x at version v, you append the pair (v, new_value) to f's list. When you read field f of node x at version v, you search the list for the entry with the largest version number less than or equal to v.

This is a beautiful trick because it requires no changes to the shape of the structure. The pointers between nodes stay the same; only the values stored in fields become versioned. Any ephemeral pointer structure can be made persistent this way, without regard to in-degree, without path copying, and without duplicating nodes.

The space cost is O(1) amortized per update: each update appends exactly one entry to exactly one list. The time cost depends on how you search the list. If you scan linearly, a read is O(m) in the worst case, where m is the number of versions. If you keep each list sorted by version and binary search, a read is O(log m). If you cache the most recent value in a fast path, reads of the current version are O(1).

The practical structure of a fat node therefore usually looks like this: a 'current' field holding the newest value, plus a side list holding the history. Reads of the newest version hit the current field directly. Reads of older versions fall through to the history list. This keeps the common case fast while preserving the ability to answer historical queries.

Fat nodes have two significant drawbacks. The first is read cost that grows with the number of versions. A structure with a million versions has a million-entry history in the worst case, and even binary search over that is a real cost. The second is memory overhead: every field now carries a version tag, and every node carries the machinery to hold a list. For a structure with many small nodes, that overhead can dominate.

There is a subtlety about version numbers. In partial persistence, versions are totally ordered, so 'largest version ≤ v' is well defined and binary search works. In full persistence, versions form a tree, and the natural query is 'the value as of the version on the path from v to the root' — which is not a simple comparison. Full persistence with fat nodes requires an order-maintenance structure to make version comparisons cheap, which is where the log log m factor comes from. We will return to this.

## 7. Node Copying and Modification Boxes

Node copying is the middle ground between path copying and fat nodes, and it is the technique that gives the best asymptotic results for partial persistence.

The idea: each node has a small, fixed number of extra slots, often called modification boxes. Each box can hold one pending modification: a (version, field, value) triple. When you update a node, you first try to write the change into a free box. Only when all boxes are full do you copy the node and update all of its predecessors to point at the copy.

Reads work like this: to read a field at version v, first check the modification boxes for an entry whose version is ≤ v and is the most recent such entry. If none exists, use the base value stored in the node itself.

The amortized analysis is the interesting part. Suppose each node has p modification boxes and in-degree at most p. A node is copied only after p updates have filled its boxes. The copy costs O(p) work — you must allocate the new node and update up to p predecessors. But you only pay it once per p updates, so the amortized cost per update is O(p)/p = O(1). The same argument bounds the amortized space: each copy creates one new node, and there is one copy per p updates, so space per update is O(1).

The in-degree constraint is essential. When a node is copied, every predecessor must be updated to point at the copy. If a node has unbounded in-degree, a single copy can cost O(n), and the amortization argument collapses. Driscoll and colleagues handled this with a technique called node splitting, which allows a node to be split into pieces so that each piece has bounded in-degree. The price is a log log m factor in the time bound.

Node copying is attractive because it avoids the depth factor of path copying. Updating a leaf deep in a tree does not allocate a new spine; it writes into a box. This makes it a good fit for structures where updates are frequent and localized, and where the extra boxes are affordable.

```c
#define P 4   /* modification boxes per node */

typedef struct {
    long version;      /* 0 means empty box */
    int  field_id;
    void *value;
} modbox;

typedef struct node {
    int      key;
    void    *left;
    void    *right;
    int      nboxes;
    modbox   boxes[P];
} node;

/* Read left pointer as of version v. */
void *read_left(node *x, long v) {
    void *best = x->left;
    long  best_ver = 0;
    for (int i = 0; i < x->nboxes; i++) {
        if (x->boxes[i].version != 0 &&
            x->boxes[i].version <= v &&
            x->boxes[i].field_id == FIELD_LEFT &&
            x->boxes[i].version > best_ver) {
            best = x->boxes[i].value;
            best_ver = x->boxes[i].version;
        }
    }
    return best;
}
```

The read loop is linear in P, which is a small constant, so reads are effectively O(1) for partial persistence. That is the whole point: node copying trades a constant-factor read cost for a constant-factor write cost, with no dependence on the number of versions.

## 8. The DSST Framework in Detail

The 1986 paper by Driscoll, Sarnak, Sleator, and Tarjan is the foundation on which most of this literature rests. Its central result is a general transformation: any pointer-based data structure with bounded in-degree can be made persistent with small overhead, without knowing anything about the structure's semantics.

The transformation works on what the authors call a 'linked data structure' — a structure made of nodes with a fixed number of fields, where each field holds either a value or a pointer to another node, and where the in-degree of every node is bounded by a constant. Balanced binary search trees, linked lists, tries, and most classic structures fit this model.

The results, stated informally, are roughly as follows.

For **partial persistence**, the transformation adds O(1) amortized space per update and O(1) time per access, using node copying with modification boxes. The structure keeps a single root, and versions are identified by a monotonically increasing counter. This is the 'free lunch' case: you get persistence for a constant factor.

For **full persistence**, the transformation adds O(1) amortized space per update and O(log log m) time per operation, where m is the number of versions. The extra factor comes from two sources: the need to search version lists efficiently, and the need to compare versions that are not totally ordered. The technique combines node copying with an order-maintenance structure that assigns each version a label such that labels can be compared in O(1) and inserted between existing labels in O(1) amortized time.

For **erasable persistence**, where old versions can be deleted, the bounds are similar but the bookkeeping is more involved because you must reclaim space that is no longer reachable.

The elegance of the framework is its generality. You do not need to redesign your data structure for persistence; you apply a mechanical transformation and inherit the bounds. In practice, most real systems do not implement the full DSST machinery — they use path copying, which is simpler and has better constants — but the framework tells you what is achievable and where the fundamental limits are.

It is worth being precise about what 'bounded in-degree' buys you. Without it, node copying fails because a copy can require updating arbitrarily many predecessors. Path copying does not care about in-degree, but pays a depth factor. Fat nodes do not care about in-degree either, but pay a read-time factor. The three techniques occupy three corners of a triangle: path copying trades time for simplicity, fat nodes trade read time for write simplicity, and node copying trades an in-degree constraint for the best of both.

## 9. Version Lists and Order Maintenance

Full persistence introduces a problem that partial persistence does not have: versions are not linearly ordered in a way that supports cheap comparison.

In partial persistence, versions are numbered 0, 1, 2, 3, ... and comparing two versions is comparing two integers. In full persistence, versions form a tree. When you update version v to create version v', v' is a child of v. Later you might update v again to create v''. Now v' and v'' are siblings, and neither is 'newer' than the other in a global sense. If a node's field has entries for both v' and v'', and you query at some version w, you need to determine which entry applies — which means determining whether v' or v'' is an ancestor of w, or neither.

The standard solution is to linearize the version tree. Assign each version a label from a totally ordered set such that the ancestor relation is consistent with the label order: if a is an ancestor of b, then label(a) < label(b). Then 'the most recent entry applicable to w' becomes 'the entry with the largest label ≤ label(w)', which is a binary search.

The catch is that new versions are created constantly and must be inserted into the total order between existing labels. If you use integers, you run out of room. You need an order-maintenance data structure: a structure that maintains a total order on a dynamically growing set, supporting insertion between two existing elements and comparison of two elements, both in O(1) amortized time.

Dietz and Sleator gave the first such structure in 1987, and Bender and colleagues gave simplified versions in 2002. The labels are typically large integers or tuples, relabeled periodically when the space between adjacent labels runs out. The amortized cost of relabeling is O(1) per insertion.

With order maintenance in hand, the full-persistence read becomes: binary search the version list for the largest label ≤ label(w). The list has length proportional to the number of updates to that field, and binary search over it costs O(log m). Combining this with the node-copying machinery and the fact that version lists are short on average gives the O(log log m) bound.

This is one of those places where the theory is more elaborate than most practical systems need. If your versions are linearly ordered — which is the case for snapshots, undo stacks, and MVCC — you can skip order maintenance entirely and use plain integers. Full persistence with a tree of versions is what you get in a functional language, and there the runtime usually accepts O(log m) read cost rather than paying for the order-maintenance machinery.

## 10. The Amortization Trap

Here is where persistence gets genuinely hard, and where a lot of otherwise-correct reasoning goes wrong.

Many of the data structures we rely on have amortized bounds that are much better than their worst-case bounds. A dynamic array doubles its capacity when full, giving amortized O(1) append with O(n) worst-case cost. A two-list queue reverses a list when the output list empties, giving amortized O(1) dequeue with O(n) worst-case cost. A splay tree gives amortized O(log n) access with O(n) worst-case cost.

These bounds are proved with a potential-function argument that assumes the structure is being used ephemerally. The potential accumulates during cheap operations and is spent during expensive ones. Crucially, the argument assumes that once you pay the expensive cost, the potential is gone and cannot be spent again.

Persistence breaks that assumption. Consider a persistent two-list queue. The queue maintains a front list and a back list. Enqueue pushes onto the back list. Dequeue pops from the front list; if the front list is empty, it reverses the back list and makes it the new front. The reversal is the expensive operation, and the amortized argument says each element is reversed at most once per enqueue-dequeue cycle.

Now suppose you keep a reference to the version of the queue just before a reversal. You dequeue, triggering the reversal. Then you go back to the saved version and dequeue again. The reversal happens again, from scratch, because the saved version's back list is still there and the reversal is not shared. You can repeat this arbitrarily many times, each time paying O(n) for a single dequeue. The amortized bound is destroyed.

This is the amortization trap, and it is not a corner case. It applies to dynamic arrays, splay trees, skew heaps, pairing heaps, and any structure whose efficiency depends on a potential that is consumed by an expensive operation.

The trap has a precise shape: an amortized bound is a statement about a *sequence* of operations on a *single* version. Persistence lets you fork the sequence at any point, so the sequence structure that the proof relied on no longer exists. You cannot amortize across a tree of histories the way you can across a line.

There is a second, subtler version of the trap that shows up in path copying. Suppose a structure has an operation that is amortized cheap because it is usually a no-op but occasionally rebuilds. Under path copying, the rebuild produces a new spine, and every subsequent operation on the new version must walk that spine. If the rebuild is triggered by a condition that depends on the structure's shape, and the shape is shared between versions, you can trigger the rebuild repeatedly on different versions.

The practical lesson is blunt: **do not assume that a persistent structure inherits the amortized bounds of its ephemeral counterpart.** If you are building a persistent structure, you must either prove bounds that hold across versions, or use a structure whose bounds are worst-case rather than amortized.

## 11. Escaping the Trap

There are several strategies for making an amortized structure persistent without losing its efficiency. They fall into three families.

**Laziness with memoization.** If the expensive operation is a pure function of the structure's contents, you can defer it and memoize the result. The first time anyone forces the thunk, the work happens; every subsequent access to the same version reuses the result. Because the thunk is shared between versions (it lives in the node that both versions point to), the work is done once regardless of how many versions reference it. This is the technique Okasaki uses throughout *Purely Functional Data Structures*, and it is why lazy evaluation is such a good fit for persistent structures.

The subtlety is that memoization is itself a mutation: you replace a thunk with its value. In a lazy language this is invisible. In a strict language you must implement it explicitly, usually with a mutable cell guarded by a lock or an atomic compare-and-swap. The mutation is safe because it does not change the observable value of the structure — only its evaluation state.

**Scheduling and incremental rebuilding.** Instead of doing the expensive operation all at once, spread it over the next few operations. A real-time queue, for example, maintains a schedule that gradually reverses the back list while the front list is still being consumed, so that the reversal is complete before the front list runs out. Each operation does a constant amount of the reversal work, so every operation has worst-case O(1) cost. The Hood–Melville real-time queue is the classic example, and Okasaki's implicit recursive slowdown is a generalization.

Scheduling is attractive because it gives worst-case bounds rather than amortized ones, which means it survives persistence without any further argument. The cost is complexity: you must maintain the schedule, and you must prove that the schedule never falls behind.

**Global rebuilding.** If the structure degrades after many updates, rebuild it from scratch periodically. Because the rebuild happens on a fresh copy, and because the trigger is a counter rather than a shape-dependent condition, the cost can be amortized across versions. This is the technique behind real-time deques and behind many 'rebuild every k operations' schemes. It is simpler than scheduling but gives amortized rather than worst-case bounds, so it must be applied carefully under persistence.

There is a fourth strategy that is less a technique than a design principle: **choose structures with worst-case bounds in the first place.** Red-black trees have worst-case O(log n) operations, so they persist cleanly. Treaps have expected O(log n) operations, which also persists cleanly (the randomness is fixed in the node priorities, so it is shared across versions). Splay trees do not. If you know you will need persistence, prefer the structure whose bounds do not depend on a potential function.

## 12. Purely Functional Data Structures: Okasaki's Toolkit

Chris Okasaki's 1998 book is the definitive treatment of persistent structures in a functional setting, and its techniques transfer directly to strict languages. The book's central insight is that the difficulty of persistence is almost entirely about amortization, and that laziness is the tool that resolves it.

The book's structure is a tour of data structures rebuilt with worst-case or lazily-amortized bounds. Persistent stacks are trivial (a cons list). Persistent queues require the two-list trick plus either laziness or scheduling. Persistent deques require more elaborate machinery. Persistent heaps come in several flavors: leftist heaps, binomial heaps, skew binomial heaps, and pairing heaps, each with different persistence properties. Persistent sets and maps are built on balanced trees, usually red-black or weight-balanced.

A recurring theme is that the functional version of a structure often looks nothing like the imperative version. The imperative binary heap is an array with index arithmetic; the functional leftist heap is a tree with a rank field and a merge operation. The imperative hash table is an array of buckets; the functional hash trie is a tree of bitmap-indexed nodes. The imperative deque is a circular array; the functional deque is a pair of lists with a schedule.

The reason is that persistence forbids the in-place tricks that imperative structures rely on. An array-based heap works because you can swap two elements in place. A persistent heap cannot swap in place without invalidating old versions, so it must build new nodes. The result is a different structure with different constants, and often with better asymptotic behavior for operations like merge.

Okasaki's treatment of the amortization trap is worth reading in full, but the summary is this: an amortized bound is a promise about a sequence, and persistence lets you break sequences apart. The fix is to make the promise about individual operations (worst-case bounds) or to make the expensive work shareable (laziness with memoization).

One practical note: in a strict language, laziness must be simulated. The usual approach is a thunk — a closure that computes a value on first call and caches it. This is exactly what Haskell's runtime does, and it is what OCaml's `Lazy.t` provides. In C or C++ you would implement it with a function pointer plus a state flag plus a lock or atomic. The overhead is real but small compared to the cost of the operations being deferred.

## 13. Case Study: Persistent Vectors

The persistent vector is the workhorse of modern functional programming, and its design is a good illustration of how persistence shapes a data structure.

The problem: provide an array-like structure with O(1) or near-O(1) random access, efficient append, and full persistence, without copying the whole array on every update.

The solution, used by Clojure, Scala, and many others, is a bit-partitioned trie. The vector is a tree in which each internal node has up to 32 children, and the path from the root to a leaf is determined by the index's bits, five bits per level. To access index i, you take the low five bits to select a child at the leaf level, the next five bits to select a child at the level above, and so on up to the root. For a vector of n elements, the depth is ceil(log32 n), which is at most 7 for a billion elements. That is why the access time is described as 'effectively constant': the constant is bounded by the depth, and the depth grows so slowly that it is irrelevant for any realistic n.

Appending an element is where persistence matters. To append, you walk down the rightmost spine of the tree, copying each node along the way and adding the new element at the end. Because you copy only the spine, the cost is O(log32 n) — the depth of the tree. All the other subtrees are shared with the previous version. The result is a new vector that differs from the old one in O(log32 n) nodes.

The implementation has a well-known optimization called the tail. The last 32 elements of the vector are stored not in the trie but in a separate flat array, the tail. Appending to a vector whose tail is not full is O(1): you copy the tail array (32 elements at most) and write the new element. Only when the tail fills up do you push it into the trie, which costs O(log32 n). This makes the common case of appending fast.

Structural sharing is what makes the whole thing work. If you have a vector of a million elements and you append one, you allocate about seven new nodes plus a new tail array. The other million elements are shared. If you then append another, you allocate another seven nodes, and the two new versions share almost everything with each other and with the original.

The design has a limitation: concatenation and slicing are inefficient, because the trie is balanced by bit position, not by element count. Concatenating two vectors of different depths requires rebuilding. This is what RRB-trees (relaxed radix balanced trees), introduced by Bagwell and Rompf in 2011, address. An RRB-tree allows nodes to be underfull and stores a size table in each internal node, so that concatenation and slicing can be done in O(log n) with structural sharing. Clojure's `subvec` and Scala's `Vector` concatenation use variants of this idea.

The persistent vector is a good example of a broader principle: persistence does not just add a feature to a data structure, it changes the optimal design. An ephemeral array is a flat block of memory. A persistent array is a shallow, wide tree with a tail buffer. The two have different constants, different cache behavior, and different operation costs, even though they present similar interfaces.

## 14. Case Study: HAMTs

The hash array mapped trie, or HAMT, is the persistent counterpart of the hash table, and it is used in Clojure's maps and sets, Scala's immutable maps, and Immutable.js.

A HAMT is a trie keyed by the hash of the key. Each node has up to 32 children, selected by five bits of the hash. Because hashes are uniformly distributed, the trie is shallow: for a million entries, the depth is about 4. Each node stores a 32-bit bitmap indicating which of the 32 slots are occupied, plus a packed array of the occupied children. This is the 'array mapped' part: instead of allocating 32 pointers per node, you allocate only as many as you need, and you use the bitmap to map a five-bit index to a position in the packed array.

The bitmap trick has two benefits. First, it saves memory: a node with three children uses three pointers plus a 32-bit word, not 32 pointers. Second, it makes iteration fast: you can enumerate the set bits of the bitmap to visit children in order, without scanning empty slots.

Persistence comes from path copying. Inserting a key walks down the trie, copying each node along the path. The cost is O(log32 n), which is effectively constant. All sibling subtrees are shared. Deleting a key works the same way, with the additional step of collapsing nodes that become empty.

Collisions are handled with a collision node: when two distinct keys have the same full hash, they are stored in a small list at the leaf. This is rare for good hash functions but must be handled for correctness.

HAMTs have a property that makes them attractive for concurrent systems: because they are immutable, a reader can traverse a HAMT while a writer builds a new version, with no synchronization. This is the basis of Clojure's `atom` and `ref` implementations, and of many lock-free caches. The trade-off is allocation: every insert allocates O(log32 n) nodes, which is more than an ephemeral hash table's amortized O(1) with occasional rehashing. For read-heavy workloads the trade is usually worth it; for write-heavy workloads it may not be.

## 15. Case Study: Copy-on-Write B+ Trees

The copy-on-write B+ tree is the persistent data structure that most systems engineers will encounter, whether or not they call it that. It is the storage engine behind LMDB, the on-disk format of Btrfs and ZFS, and the basis of snapshot isolation in several databases.

The idea is path copying applied to a B+ tree on disk. A B+ tree stores keys and values in leaf pages and keys and child pointers in internal pages. To insert a key, you walk from the root to the appropriate leaf. In a copy-on-write tree, you do not modify the pages you walk through; you allocate new pages, write the updated contents, and update the parent's child pointer to point at the new page. The parent is itself copied, and so on up to the root. Finally, you write a new root pointer.

The old pages are untouched and remain valid. A snapshot is simply a saved root pointer. To read a snapshot, you start at its root and follow pointers; you will never see a page written after the snapshot was taken, because new writes go to new pages.

LMDB is a particularly clean example. It is a memory-mapped B+ tree with a single writer and many concurrent readers. It maintains two meta pages, alternating between them, each containing a root pointer and a transaction ID. A write transaction builds a new tree by copying pages along the modified paths, then atomically updates one meta page. Because the update is a single page write, it is atomic with respect to crash recovery: either the old meta page is intact or the new one is. There is no write-ahead log, because the old version of the tree is never overwritten. This is the durability argument for copy-on-write: the previous consistent state is always available, so you can recover by simply reading the last valid meta page.

The cost is write amplification and space. Every update copies a path from the root to the modified leaf, which for a B+ tree of height h is h pages. If your pages are 4 KB and your tree has height 4, that is 16 KB written per small update. This is much worse than an in-place B+ tree, which would write one page plus a log record. The compensation is that snapshots are free, readers never block, and crash recovery is trivial.

Btrfs and ZFS extend the same idea to a whole filesystem. A file's data is stored in extents, extents are indexed by a tree, trees are indexed by a tree of trees, and the whole thing is rooted in a single block. A snapshot is a copy of the root block. Because the tree is copy-on-write, the snapshot and the live filesystem share all unmodified blocks, and the space cost of a snapshot is proportional to the changes made after it. ZFS adds checksums at every level, making the tree a Merkle tree: the checksum of a parent covers the checksums of its children, so any corruption is detected and localized.

There is a well-known operational hazard with copy-on-write filesystems: fragmentation. Because blocks are never overwritten in place, a file that is modified repeatedly ends up scattered across the disk. ZFS and Btrfs mitigate this with allocation policies and background defragmentation, but the tension between copy-on-write and sequential layout is fundamental.

## 16. Case Study: Git's Object Graph

Git is, at its core, a persistent data structure with a content-addressed interface, and understanding it as such clarifies a lot of otherwise-odd behavior.

Git stores four kinds of objects: blobs (file contents), trees (directory listings), commits (snapshots plus metadata), and tags. Each object is identified by the SHA-1 (or, increasingly, SHA-256) hash of its contents. Because the identifier is derived from the content, two identical contents have the same identifier, and the object is stored once.

A tree object lists names, modes, and object IDs for the entries in a directory. If a file is unchanged between two commits, the tree entry points at the same blob, and if an entire subdirectory is unchanged, the tree entry points at the same tree. This is structural sharing, implemented by content addressing rather than by pointer manipulation. The commit graph is a Merkle DAG: a commit points at a tree and at its parent commits, and the commit's own ID is the hash of all of that.

The consequence is that committing a one-line change to a large repository writes a handful of new objects: one blob, one tree per directory on the path from the changed file to the root, and one commit. Everything else is shared. This is why Git is fast despite storing the entire history of a project.

Content addressing also gives Git free deduplication and free integrity checking. If two files anywhere in history have identical contents, they share a blob. If a blob is corrupted, its hash will not match its name, and Git will detect it. The Merkle structure means that verifying a commit's hash transitively verifies every object it reaches.

The design also explains some Git quirks. Because objects are immutable, rewriting history means creating new objects with new hashes, which is why `rebase` changes commit IDs and why force-pushing is disruptive. Because trees are content-addressed, an empty directory cannot be represented (there is no blob to point at), which is why Git does not track empty directories. Because the object graph is a DAG, merges create commits with two parents, and the merge base is the lowest common ancestor in that DAG.

Git's packfiles are an orthogonal optimization: they compress objects and store deltas between similar objects to save space on disk. The logical structure remains a persistent Merkle DAG; the packfile is just an encoding of it.

## 17. Confluent Persistence and Merging

Everything so far has been about keeping old versions around. Confluent persistence adds a new operation: merging two versions into one.

In a fully persistent structure, versions form a tree. Each update creates a child. There is no operation that takes two versions and produces a third that combines them. In a confluently persistent structure, versions form a DAG, and there is a merge operation that takes two versions and produces a new version whose contents are some function of both.

This is exactly the operation that version control systems perform. When you merge two branches, you produce a new commit whose tree is derived from both parents. It is also the operation that CRDTs perform when reconciling divergent replicas, and the operation that a distributed database performs when it reconciles conflicting writes.

Confluent persistence is significantly harder than full persistence. Fiat and Kaplan's 2003 paper on the subject gives a general technique with O(log n) overhead, and shows that the naive approach — path copying plus a merge that walks both structures — can require space that grows exponentially in the number of merges. The intuition is that each merge can double the number of distinct paths through the structure, and if you are not careful about sharing, you end up materializing all of them.

The lower bound is also instructive. Fiat and Kaplan show that confluent persistence in their model requires Ω(log n) overhead per operation, which means you cannot get it for free the way you can get partial persistence. The extra cost is the price of the extra expressiveness.

There is a practical lesson here that shows up in every system that supports merging: **the merge function must be designed, not assumed.** If you merge two versions by taking the union of their changes, you need to define what happens when both changed the same thing. If you merge by taking one side's changes, you need a policy for choosing. If you merge by a three-way diff against a common ancestor, you need the ancestor. None of this is free, and none of it is determined by the data structure alone.

## 18. Confluent Persistence Meets CRDTs

Conflict-free replicated data types are the practical embodiment of confluent persistence in distributed systems, and the connection is worth making explicit.

A CRDT is a data type whose merge operation is commutative, associative, and idempotent. Those three properties are exactly what you need for the merge to be well-defined regardless of the order in which replicas exchange updates, and for repeated merges to be harmless. In algebraic terms, the set of possible states forms a join-semilattice, and merge is the join.

The connection to confluent persistence is direct. A CRDT replica's state is a version in a confluently persistent structure, and merging two replicas is the merge operation. The commutativity and associativity of merge are what make the version DAG well-behaved: it does not matter which order you merge in, you get the same result.

This is why CRDTs are often implemented with persistent data structures internally. A state-based CRDT (CvRDT) typically holds an immutable value and produces a new value on merge, which is exactly a persistent update. An operation-based CRDT (CmRDT) applies operations to a state, and the operations must commute; implementing the state as a persistent structure makes it easy to keep old versions for anti-entropy and for debugging.

There is a subtlety about garbage collection. A CRDT that never discards tombstones grows without bound, because it must remember every deletion in order to merge correctly with a replica that has not seen the deletion. This is the same problem as erasable persistence: you need a policy for discarding versions, and the policy must be safe with respect to the merge semantics. In CRDTs this is handled with causal stability: once every replica has seen an operation, the tombstones it implies can be collected.

The lesson generalizes. Any system that keeps old versions must eventually decide which versions to forget, and the decision is a distributed one if the versions are distributed. Persistence gives you the mechanism; the policy is yours to design.

## 19. Space and Time Lower Bounds

It is worth collecting what is known about the fundamental costs of persistence, because it explains why the techniques look the way they do.

For partial persistence of bounded-in-degree pointer structures, the cost is O(1) amortized space and O(1) time per operation. This is optimal: you cannot do better than constant overhead, and constant overhead is achievable.

For full persistence, the cost is O(1) amortized space and O(log log m) time per operation, where m is the number of versions. The log log factor is not known to be optimal in all models, but it is the best general bound available.

For confluent persistence, the cost is O(log n) overhead per operation in the general case, with a matching lower bound in the model Fiat and Kaplan studied. The exponential blowup of naive approaches is a real hazard.

For persistent arrays specifically, Dietz's 1989 result gives O(log log n) time per operation with O(n) space, which is a striking bound: a fully persistent array with sub-logarithmic access. The technique is a clever indirection scheme, and it is a good illustration of how much can be squeezed out with the right representation.

For structures with amortized bounds, there is no general theorem that says persistence preserves the bound, and in fact there are counterexamples. The dynamic array, the two-list queue, and the splay tree all lose their amortized bounds under naive persistence. The general principle is that amortization is a property of a sequence, and persistence destroys sequences.

One more bound worth knowing: persistent search trees. Sarnak and Tarjan used partially persistent search trees to solve planar point location, and the technique is a nice illustration of how persistence can be the key to an algorithmic result rather than just a convenience. The persistent tree stores the sweep-line state, and queries at any point in the sweep are answered by searching the version of the tree at that point.

## 20. Memory Management for Persistent Structures

Persistent structures allocate a lot. Every update to a path-copied tree allocates a new spine. Every update to a node-copied structure allocates a modification box entry. Every version that is kept alive keeps its share of the structure alive. Managing that memory is a first-class engineering concern.

**Garbage collection** is the natural fit. In a managed language, a version is alive exactly when it is reachable from a root, and the collector reclaims everything else. This is why persistent structures are so pleasant in Clojure, Scala, Haskell, and OCaml: the collector handles version reclamation automatically. The cost is that persistent structures generate garbage quickly, so the collector runs more often. Generational collectors handle this well, because most of the new nodes die young.

**Reference counting** is the alternative in unmanaged languages. Each node carries a count, and when the count drops to zero the node is freed. The problem is cycles: a persistent structure with back-pointers or with a version DAG can have cycles, and reference counting cannot reclaim them without a cycle detector. Most persistent structures are trees or DAGs with no back-edges, so reference counting works, but you must be careful.

**Arenas and regions** are a good fit for versioned structures that have a bounded lifetime. If you know that a set of versions will be discarded together — for example, all the versions created during one transaction — you can allocate them from an arena and free the whole arena at once. This is much cheaper than per-node reclamation and it avoids the fragmentation that comes from allocating and freeing many small nodes. The catch is that you must not share nodes between arenas, which limits structural sharing across arena boundaries.

**Epoch-based reclamation** is the technique used in lock-free data structures. Readers announce the epoch they are in; writers defer freeing until all readers have left the epoch in which the node was reachable. This gives safe reclamation without locks, at the cost of delaying frees. It is a good fit for persistent structures that are shared between readers and writers, and it is what RCU does in the Linux kernel.

**Explicit version management** is the fallback when none of the above is acceptable. You maintain a table of live versions and a policy for evicting them. This is what a database does with snapshot retention: keep the last N snapshots, or keep snapshots younger than T, and drop the rest. The policy must be safe — dropping a snapshot that a transaction is still reading is a correctness bug — so you need a way to know when a version is no longer in use. Reference counting, epoch tracking, or a registration protocol all work.

A practical observation: persistent structures tend to have many small nodes, which stresses the allocator. Size-class allocators and thread-local caches help a lot. So does making nodes bigger and wider — a HAMT node with 32 slots is a single allocation instead of 32 — because it reduces allocation count and improves locality.

## 21. Cache Behavior and Locality

Pointer-based structures are notoriously cache-unfriendly, and persistent structures are pointer-based by nature. The cache behavior of a persistent structure is often the dominant factor in its real-world performance, more so than its asymptotic complexity.

The fundamental issue is pointer chasing. Traversing a tree of depth d requires d dependent memory accesses, each of which may miss in cache. On a modern processor, a last-level cache miss costs on the order of a hundred cycles, so a depth-7 traversal can cost hundreds of cycles even though the operation is 'effectively constant' in the asymptotic sense.

Several design choices mitigate this.

**Wide nodes.** A node with 32 children touches one cache line to select among 32 options, whereas a binary node touches one cache line to select among 2. Wide nodes reduce depth, and depth is what costs. This is a large part of why HAMTs and persistent vectors use 32-way branching: it is not just about the depth bound, it is about the constant factor.

**Contiguous storage of node contents.** A HAMT node stores its bitmap and its packed child array contiguously, so a single cache line fetch brings in the bitmap and several children. A node with separate allocations for the bitmap and the children would take two misses instead of one.

**Fat nodes' locality advantage.** Fat nodes keep the current value in the node itself and the history in a side list. Reads of the current version touch only the node, which is the same cache behavior as an ephemeral structure. Reads of old versions touch the history, which is a separate allocation and likely a miss. This is a good trade for workloads that mostly read the newest version.

**Path copying's locality disadvantage.** Path copying allocates a fresh spine on every update. The first traversal after an update walks entirely cold memory. If updates and reads alternate rapidly, the cache never warms up. Node copying avoids this by writing into existing nodes, which are already in cache.

**Prefetching.** Because the traversal pattern of a persistent structure is determined by the key, you can often compute the address of the next node before you need it and issue a prefetch. This is standard practice in high-performance B-tree and trie implementations, and it applies to persistent versions as well.

**Structural sharing and cache pressure.** Sharing means that two versions of a structure point at the same nodes. If both versions are being traversed, they compete for cache. This is usually fine, because the shared nodes are the ones that did not change, and traversals of the two versions tend to follow similar paths.

A useful mental model: an ephemeral structure optimizes for the steady state, where the working set fits in cache. A persistent structure optimizes for change, where each update invalidates part of the working set. The two have different cache profiles, and a benchmark that measures one will mislead you about the other.

## 22. Persistence and Concurrency

The concurrency benefits of persistent structures are among the strongest practical arguments for using them, and they deserve a section of their own.

The core property is simple: **an immutable value can be read by any number of threads without synchronization.** There is no data race, because no thread writes to the value. There is no need for a lock, because there is nothing to lock. There is no need for a memory barrier on the read path, because the value was published before the reader obtained a reference to it.

This gives wait-free reads. A reader never blocks, never retries, and never observes an inconsistent state. For read-heavy workloads, this is a dramatic simplification: you can delete the read locks entirely.

Writers are a different story. If two threads want to update the same version, they each produce a new version, and one of them wins. The standard pattern is compare-and-swap on a root pointer: read the current root, build a new tree that shares structure with it, and atomically swap the root if it is still the one you read. If the swap fails, retry. This is the basis of Clojure's `swap!` on atoms, of lock-free caches, and of many functional data structures in concurrent settings.

The retry cost is the downside. Under high contention, many writers build new trees and discard them. The cost of a discarded tree is the allocation of its new nodes, which is O(depth). For a shallow structure like a HAMT, this is small; for a deep structure, it can be significant. Contention management — batching, backoff, or partitioning — is often necessary.

There is a second concurrency pattern that persistence enables: **snapshot isolation**. A reader takes a reference to the current root and works with it. Writers proceed independently, building new roots. The reader sees a consistent snapshot for as long as it holds the reference, and it never blocks a writer. This is exactly what LMDB does with its read transactions, and what MVCC databases do with their snapshots.

The third pattern is **read-copy-update**. RCU is, in effect, a persistent structure discipline applied to kernel data structures. A writer builds a new version, publishes it with an atomic pointer store, and defers freeing the old version until all readers have left the critical section. Readers see either the old version or the new version, never a mix. The Linux kernel uses RCU extensively for routing tables, file descriptor tables, and many other structures.

There is one important caveat: persistence gives you consistent reads, but it does not give you linearizable writes. Two concurrent writers can both succeed if they are updating different parts of the structure, and the result may not correspond to any sequential order. If you need linearizability, you need a consensus protocol on top of the persistent structure, or you need to serialize writes. Persistence makes the read side easy and leaves the write side as hard as it ever was.

## 23. Implementation Sketch: Fat-Node BST

Let us make the techniques concrete with a small implementation. This is a fat-node binary search tree supporting partial persistence: every version is readable, and only the newest is writable.

```c
#include <stdlib.h>
#include <stdint.h>

typedef struct entry {
    uint64_t version;
    int64_t  value;
    struct entry *next;
} entry;

typedef struct fnode {
    int64_t key;
    entry  *left;    /* history of the left pointer  */
    entry  *right;   /* history of the right pointer */
    entry  *val;     /* history of the value         */
} fnode;

/* Append a new entry to a history list. */
static void push(entry **head, uint64_t v, int64_t value) {
    entry *e = malloc(sizeof(entry));
    e->version = v;
    e->value   = value;
    e->next    = *head;
    *head      = e;
}

/* Find the value valid at version v. */
static int64_t lookup(const entry *head, uint64_t v, int64_t fallback) {
    int64_t best = fallback;
    uint64_t best_v = 0;
    for (const entry *e = head; e; e = e->next) {
        if (e->version <= v && e->version >= best_v) {
            best_v = e->version;
            best   = e->value;
        }
    }
    return best;
}

/* Update the value of a node at version v. */
static void set_value(fnode *n, uint64_t v, int64_t value) {
    push(&n->val, v, value);
}

/* Read the value of a node at version v. */
static int64_t get_value(const fnode *n, uint64_t v) {
    return lookup(n->val, v, 0);
}
```

The history lists are stored in reverse chronological order, so the most recent entry is at the head. The lookup scans the whole list, which is O(k) where k is the number of updates to that field. For a production implementation you would keep the list sorted and binary search, or you would keep a small array and use a linear scan for the common case of a recent version.

The key observation is that no node is ever copied. The tree's shape is fixed; only the field values are versioned. This means the in-degree of a node can be anything, and the space cost is one entry per update. The read cost grows with the number of versions, which is the fat-node trade-off.

A refinement that is almost always worth it: keep the newest value in a plain field alongside the history list. Reads of the newest version then take O(1) and touch only the node, and only historical reads pay the list-scan cost.

```c
typedef struct fnode2 {
    int64_t key;
    fnode2 *left_now;
    fnode2 *right_now;
    int64_t value_now;
    entry  *left_hist;
    entry  *right_hist;
    entry  *val_hist;
} fnode2;
```

This doubles the per-node overhead but makes the common case fast, which is usually the right trade.

## 24. Implementation Sketch: Path-Copying BST

Path copying is simpler to implement and has better read behavior. Here is a persistent binary search tree in C, using path copying for insertion.

```c
typedef struct tnode {
    int64_t key;
    int64_t value;
    struct tnode *left;
    struct tnode *right;
} tnode;

tnode *insert(const tnode *root, int64_t key, int64_t value) {
    if (!root) {
        tnode *n = malloc(sizeof(tnode));
        n->key = key; n->value = value;
        n->left = n->right = NULL;
        return n;
    }
    tnode *n = malloc(sizeof(tnode));
    *n = *root;                       /* copy the node */
    if (key < root->key) {
        n->left  = insert(root->left, key, value);
    } else if (key > root->key) {
        n
