---
title: "An Algorithm For Incremental Topological Ordering Dynamic Dags: Applications In Build Systems"
description: "A comprehensive technical exploration of an algorithm for incremental topological ordering dynamic dags: applications in build systems, covering key concepts, practical implementations, and real-world applications."
date: "2020-04-10"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/an-algorithm-for-incremental-topological-ordering-dynamic-dags-applications-in-build-systems.png"
coverAlt: "Technical visualization representing an algorithm for incremental topological ordering dynamic dags: applications in build systems"
---

## The Hidden Graph That Defines Your Workday: Mastering Incremental Topological Ordering for Dynamic DAGs

**Introduction**

You have just saved a single character in a file. A trailing semicolon, long overdue for removal, is finally gone. You hit save, your mind already moving to the next task. Behind the scenes, a microsecond later, your IDE’s language server sends a notification. In the next few seconds, an entire universe of computation stirs to life. Your build system—be it Bazel, Pants, Nix, or a custom internal tool—must decide exactly what needs to happen next.

It does not rebuild the entire world. It does not recompile your operating system’s kernel because you fixed a typo in a unit test. Instead, it solves a deeply nuanced, often overlooked combinatorial optimization problem. It maintains an _incremental topological ordering_ of a _dynamic directed acyclic graph_ (DAG).

This post is about that algorithm. But before we dive into the mechanics of vertex relabelling and depth-first searches, we need to understand why this problem is so profoundly important. It is not just an academic curiosity tucked away in a dusty algorithms textbook. It is the engine that makes modern software development sustainable. It is the difference between a 30-millisecond incremental rebuild and a 30-minute clean build. It is the reason you can ship code ten times a day.

**Why "Static" is a Lie**

Most introductory computer science courses teach topological sorting as a one-time operation. You are given a pristine graph—a job schedule, a prerequisite chain, a build pipeline. You run Kahn’s algorithm or a DFS-based post-order traversal. You get a linear ordering. You are done. The graph is frozen in time.

But reality is not a csv file of static dependencies. Reality is a live, evolving, unpredictable organism. Your build system must handle continuous changes: source files are edited, new modules are added, old ones are removed, dependency edges are inserted or deleted. The graph is _dynamic_. Every edit demands a new topological ordering that respects the new constraints yet does not require reordering every vertex from scratch.

The challenge is to update the ordering _incrementally_—to take a previously valid topological order and, after a small set of changes, produce a new valid order with minimal work. The naive approach (re-run Kahn’s algorithm on the entire graph) would defeat the purpose of incremental builds: if you have to re-examine the whole dependency graph, you might as well just rebuild everything. The whole point of incrementalism is to localize the impact.

In this blog post, we will explore the elegant algorithms that make incremental topological ordering possible. We will start with a formal statement of the problem, discuss why naive solutions fail, then dive into the details of one of the most practical algorithms—the _incremental topological ordering_ algorithm by Bender, Fineman, Gilbert, and Tarjan (often called the “Bender-Fineman” algorithm or simply the “label-based algorithm”). We will walk through its operation with concrete examples, provide pseudocode, and discuss how it is used in real-world build systems. By the end, you will understand not just one algorithm, but the deep trade-offs involved in maintaining order in a changing world.

---

### 1. The Problem: Incremental Topological Ordering of Dynamic DAGs

Let’s define the problem precisely.

**Static Topological Ordering**  
Given a directed acyclic graph \( G = (V, E) \) with \( n = |V| \), find a linear ordering \( \pi \) of the vertices such that for every edge \( (u, v) \in E \), \( u \) appears before \( v \) in \( \pi \). This is fundamental.

**Dynamic Topological Ordering**  
We start with a valid topological ordering of the initial graph. Over time, the graph changes through a sequence of _edge insertions_ and _edge deletions_ (we assume vertex insertions and deletions can be handled by sequences of edge operations, or we treat them separately). After each change, we want to maintain a valid topological ordering of the new graph. The goal is to update the ordering as quickly as possible, ideally in time proportional to the size of the _affected region_ rather than the entire graph.

**Why is this hard?**  
When an edge is inserted, it may introduce a cycle—in which case the ordering becomes invalid and the graph is no longer a DAG (we must detect and reject cycles). But assuming the edge does not create a cycle, the current ordering might still be valid if the source vertex already appears before the target. However, if the target appears before the source, we have a conflict; we must reorder some vertices to restore the invariant. Similarly, when an edge is deleted, the ordering remains valid (since removing constraints never invalidates an ordering), but we might be able to optimize future operations if we maintain certain data structures.

The core difficulty is that a single misplaced edge can require moving many vertices. In a naive approach, you could simply run a full topological sort after each change, costing \( O(n+m) \) per operation. But in a build system with millions of files, that is unacceptable. We need sublinear update time—ideally proportional to the number of vertices that actually need to change.

---

### 2. Why Traditional Topological Sort Fails

Let’s consider a typical build system scenario. Your project has 100,000 source files (vertices). Each file depends on headers and other files; the dependency graph has, say, 500,000 edges. You change one header file; that changes the dependency edges for every file that includes that header. Perhaps 10,000 files now have new or removed edges. A full topological sort would need to process all 100,000 vertices and all edges to produce a new ordering. That could take hundreds of milliseconds or even seconds, and it would need to be done for every change. Worse, during the sort you would need to hold a global lock, blocking other operations. The result: sluggish IDE responsiveness, long incremental rebuild times.

The fundamental issue is that topological sorting is a global operation: it must consider the entire graph to guarantee a valid ordering. However, we know that only a small subset of vertices are _affected_ by a change. If we could limit our work to that subset, we could achieve orders-of-magnitude speedups.

Enter incremental topological ordering. These algorithms exploit the fact that valid orderings are not unique; we have slack. When a new edge is inserted that violates the current ordering, we can “shift” a region of vertices between the source and target to reestablish order. The key insight is that the vertices that need to move form a contiguous block in the current ordering (under a careful labeling scheme), and the update can be performed in time proportional to the size of that block—plus some overhead for detection.

---

### 3. Formal Definition and Notation

We denote the graph \( G = (V, E) \). We maintain a total order \( \pi : V \rightarrow \{1, 2, \dots, n\} \) that is a topological order (i.e., \( \forall (u,v) \in E, \pi(u) < \pi(v) \)). We will use the term _label_ to mean the integer assigned to a vertex; we can interchangeably think of \( \pi(v) \) as the position or label.

**Operations:**

- `InsertEdge(u, v)`: Add directed edge from \( u \) to \( v \). If adding creates a cycle (i.e., there is already a path from \( v \) to \( u \)), the operation must be rejected. Otherwise, we must update \( \pi \) to make \( \pi(u) < \pi(v) \) if not already satisfied.
- `DeleteEdge(u, v)`: Remove edge. No immediate reordering is required; but we may want to adjust data structures for future operations (optional, often we simply update adjacency lists).

**Goal:** Maintain \( \pi \) valid after each operation, with update time ideally \( O(|affected\ region|) \) or \( O(k \cdot \log n) \) where \( k \) is number of vertices that change position.

---

### 4. The Algorithm Landscape

Several algorithms have been proposed for incremental topological ordering. The most prominent are:

- **Alpern, Hoover, Rosen, Sweeney, and Zadeck (1990)**: One of the earliest practical implementations, used in the IBM XL compilers. They use a technique called _DFS-based reordering_ limited to the set of vertices that are “dirty” (i.e., those that are reachable from the inserted edge’s source and can reach the target). Their algorithm runs in \( O(m') \) where \( m' \) is the number of edges in the affected subgraph. This is still worse than desired for dense affected regions.

- **Pearce and Kelly (2004)**: Improved upon Alpern et al. with a more sophisticated algorithm that uses _backwards search_ and _forward search_ to identify a small region to reorder. Their algorithm is still based on DFS and may touch many vertices.

- **Bender, Fineman, Gilbert, and Tarjan (2009)**: This is the breakthrough. They introduced a _label-based_ algorithm that assigns real-valued labels (or large integers with space for renumbering) and performs reordering by “spreading” labels apart in the affected region. Their algorithm achieves amortized \( O(\log n) \) time per edge insertion, with high probability, using a _randomized_ approach to maintain label order. The deterministic version achieves \( O(\log^2 n) \) amortized. This is the algorithm we will focus on, as it is both elegant and practical.

- **Bender, Fineman, Gilbert, and Tarjan (2011)**: They published a journal version with improved analysis and a simpler variant called _“Caterpillar”_ algorithm.

- **Rossi and Sastry (2012)**: A simpler algorithm for sparse graphs using _ordering by counting_.

In build systems, the Bender-Fineman algorithm (and its variants) is the gold standard. It is used in Bazel (Google’s build system) and influenced the design of other tools.

---

### 5. Deep Dive: The Bender-Fineman Incremental Topological Ordering Algorithm

We will now explore the core algorithm in detail. The intuition is beautiful: maintain a total order by assigning integers (or rational numbers) to vertices. When an edge is inserted, check if the source’s label is less than the target’s. If so, done. If not, we need to “shift” the vertices that lie between the target and source so that the source’s label becomes less than the target’s. But we cannot simply swap; we must preserve the relative order of all other edges. The trick is to reassign labels to a contiguous block of vertices in the current order, using new labels that are “spread out” within the block to accommodate both the new constraint and all existing constraints.

**Key data structures:**

- An array `order` mapping vertex ID to its label (position in the order).
- A dynamic array `vertex_at_position` (or a balanced BST) to get the vertex at a given label.
- Adjacency lists (incoming and outgoing) for each vertex.

**The Subproblem:**  
Suppose we have an insertion of edge \( (u,v) \) and currently \( \pi(u) > \pi(v) \). Let \( L = \pi(v) \) and \( R = \pi(u) \) (with \( L < R \)). The vertices with labels in \( [L, R] \) form a contiguous segment. The new edge forces \( u \) to come before \( v \), but \( u \) is currently after \( v \). Some vertices in this segment must be moved earlier or later so that the order of all edges among them is preserved and the new edge is satisfied.

The algorithm does the following:

1. **Identify the affected interval** \( [L, R] \).
2. **Extract all vertices** in this interval (call this set \( S \)).
3. **Compute a new topological ordering of \( S \)** considering only the subgraph induced by \( S \) (plus the new edge).
   - Crucially, \( S \) must be a DAG under the induced subgraph? It may not be; but we know the full graph is a DAG, and since all edges from outside \( S \) are either all from left to right (because any vertex left of \( L \) has label \( < L \) and thus must be before all vertices in \( S \); similarly, vertices to the right of \( R \) are after all in \( S \)), the only edges that could cause cycles within \( S \) are those already present among \( S \). Because the original order was topological for the full graph, no back edge existed within the induced subgraph — but after insertion of \( (u,v) \), that edge goes backward within the interval, potentially creating a cycle? Wait, if \( (u,v) \) is the only backward edge, then the induced subgraph still has no cycle because \( u \) now comes before \( v \). However, if there existed a path from \( v \) to \( u \) already, then insertion would create a cycle. So before insertion, we must check for cycles — we’ll handle that later.

4. **Assign new labels** to the vertices in \( S \) using rational numbers (or large integers) that respect the new topological order and also the gaps with vertices outside. The algorithm uses a technique called **“insertion into a sorted order with fractional cascading”** but in practice they use **real-valued labels** (or rationals with enough bits). After reordering, the new \( \pi(u) \) and \( \pi(v) \) will satisfy \( \pi(u) < \pi(v) \).

5. **Update global ordering** — this is done by redistributing labels within the interval.

**The Critical Insight:**
If we assign every vertex a _real number_ label, we can always find new labels for the interval that fit between the left neighbor (label \( L-1 \)... but wait, labels are integers? We can make them floats). However, using floating-point numbers may lead to precision issues. The algorithm uses a dynamic integer labeling scheme: we maintain a total order using integers but we keep a _gap_ between each consecutive vertex. When we need to insert a new ordering in a dense region, we can “renumber” by distributing the integers evenly across the interval. This is similar to the problem of maintaining a sorted list with insertions (like the “ordered list maintenance” problem). The Bender-Fineman algorithm cleverly combines the two: it keeps a _labeling_ that is logarithmic in space and uses _periodic rebuilds_ to avoid excessive integer blow-up.

**Simpler deterministic variant (not the final Bender-Fineman):**
Many blog posts and implementations use a simpler approach: treat labels as integers initially spaced far apart (e.g., multiples of \( n \)). When a conflict arises, we take the subgraph induced by the interval, run a topological sort on that subgraph, and then reassign labels that are evenly spread across the interval’s range. This is not guaranteed to be efficient in the worst case (the interval could be large), but in practice for build systems it often works well because intervals are small. This is the essence of the algorithm used in the _Pants_ build system.

**But the Bender-Fineman algorithm achieves logarithmic amortized time by using a **“randomized label scaling”** technique. Let’s now outline their actual method.**

---

### 5.1 The Randomized Version

The algorithm maintains an ordering as a total order but not necessarily with consecutive integer labels. Instead, it uses a technique called _linking_ and _cutting_ borrowed from dynamic tree data structures. However, the key data structure is a **balanced binary search tree** (e.g., a treap) where each node represents a vertex, and the in-order traversal gives the topological order. The labels are not stored explicitly; the relative order is determined by the tree structure. The algorithm also stores for each node a _rank_ (an integer) that is maintained to be consistent with the in-order, but ranks can be updated locally.

The high-level operation:

- Insert an edge \( (u,v) \). If \( u \) is already before \( v \) in the tree, nothing to do.
- If \( u \) is after \( v \), find the **lowest common ancestor (LCA)** of \( u \) and \( v \) in the BST—but because the tree order is topological, the LCA might not be directly helpful. Actually, the algorithm uses a **”slice”** of the tree between \( v \) and \( u \) (in the in-order sequence) and performs a **“rotation”** that moves \( u \) before \( v \) while preserving the BST property and the relative order of all other nodes.

This is reminiscent of the _Caterpillar algorithm_: the authors prove that by rotating the path between \( v \) and \( u \) in a treap, you can restore the topological order in expected \( O(\log n) \) time. The details are complex; we will instead present a simpler version that is easier to implement and understand, yet captures the spirit.

---

### 5.2 A Practical Implementation (Simplified)

Many production build systems (like Pants) use a variant that is not fully randomized but is fast enough. The idea:

- Represent the topological order as an array of vertex IDs in order.
- For each vertex, store its **index** in the array.
- When an edge \( (u,v) \) is inserted and \( index[u] > index[v] \), we need to “shift” a block. But rather than re-topologically sorting the entire interval, we can use a heuristic: find the **smallest index** that can be moved to before \( v \) while respecting constraints. Two approaches:

  **Approach A (Pearce & Kelly style):**
  1.  Run a forward DFS from \( u \) (following outgoing edges) within the interval to find the set of vertices that must be moved before \( v \). This set is the set of vertices reachable from \( u \) that have index <= index[u] but > index[v]. That gives a candidate block to move.
  2.  Move all those vertices to just before \( v \). This involves shifting the rest of the interval accordingly.

  **Approach B (label re-assignment):**
  1.  Extract the interval [index[v], index[u]].
  2.  Topologically sort the subgraph induced by these vertices (using a full sort of only that subgraph). This is safe because the interval is usually small. The size of the interval is bounded by the number of vertices that are in the _dependence chain_ between \( v \) and \( u \), which in practice is small.
  3.  Reassign the labels of these vertices to be evenly distributed in that range.

Which one is used? In Pants, they use a combination: a full topology sort of the interval, but they limit the interval by first computing the _strongly connected components_ (if any) — but they assume no cycles. This is still \( O(k^2) \) if the interval is large, but they claim intervals are usually tiny (<= 100 vertices). For very large intervals, they trigger a full rebuild.

**Why intervals are small:** In a build system, dependencies are usually _local_. A header change only affects files that directly or transitively include it, and they are often arranged topologically in a way that the interval between the changed header and the file that uses it is small (e.g., the library’s own files). However, in a monorepo with deep dependency chains, intervals can be large. That is why Google developed the more sophisticated Bender-Fineman algorithm for Bazel.

---

### 6. Detailed Example with Pseudocode

Let’s work through a concrete scenario using the label-reassignment approach (simplified, but realistic).

**Initial graph:**

```
A -> B -> C -> D
```

Topological order: [A, B, C, D] → indices: A=0, B=1, C=2, D=3.

Now we insert an edge from D to B (creating a new dependency from D to B). The graph now:

```
A -> B -> C -> D
^              |
|______________|
```

This creates a cycle? Let’s see: D -> B, B -> C -> D, so yes there is a cycle. Our algorithm must detect this and reject the insertion. So we must first check for cycles. How? One way: if we have a path from v to u before insertion, then adding (u,v) creates a cycle. So we need a way to query reachability quickly. The Bender-Fineman algorithm uses a data structure for dynamic reachability queries, but that is another deep topic. For simplicity, we assume that we maintain a _reverse adjacency_ and do a limited DFS from v backward along incoming edges (or forward from v to search for u). Because the graph is dynamic, we need an efficient reachability query. In practice, many build systems assume that the developer makes only acyclic changes (e.g., adding a dependency that would create a cycle is considered an error and rejected). They might do a full DFS from v to see if u is reachable; if \( k \) is the number of vertices in the affected region, that DFS is \( O(k) \). That is acceptable if \( k \) is small.

**Assume insertion does NOT create a cycle.** Example: Insert edge from A to D (already satisfied, no reordering). Or insert edge from C to A (would create a backward edge but no cycle because there is no path from A to C). Wait, original graph has A->B->C, so C->A would create a cycle? A->B->C->A indeed creates a cycle. So we need a non-cyclic insertion: e.g., insert edge B -> D (already satisfied because B before D). So we need an example where the new edge goes backward but does not cause a cycle. For that, we need a graph where u is after v but there is no path from v to u (or from v to u that would close a cycle). That is, the backward edge does not create a cycle because the destination u is not reachable from v. Example: Graph: A->B, C->D. Order: A, B, C, D. Insert edge D -> B. Now we have D after B, and D's target B is before D, so backward edge. Is there a path from B to D? No (B goes only to nothing). So no cycle. Good.

Now our algorithm must fix the order because D appears after B, but we need D to be before B. So we need to move D earlier, before B.

**Step 1:** Detect that index[D]=3 > index[B]=1. Set L = min(index[v], index[u])? Actually v=B=1, u=D=3, L=1, R=3.
**Step 2:** Extract vertices in interval [1,3]: vertices at indices 1:B, 2:C, 3:D.
**Step 3:** Build subgraph induced by {B,C,D}. Existing edges: B->? none; C->D (from original). New edge: D->B. So subgraph edges: C->D, D->B.
**Step 4:** Topologically sort this subgraph. The possible order: D, C, B? Check edges: D->B okay (D before B). C->D requires C before D, but in D,C,B we have C after D, so invalid. Try C, D, B: C->D fine, D->B fine. So new order for S is [C, D, B] (note: B is before C? No, B is after D). So we need to assign new indices to these three vertices within the original range [L,R] = [1,3]. We can assign: index for C = 1, D = 2, B = 3. But wait, original vertex at index 0 is A; after this change, the global order becomes: A (0), C (1), D (2), B (3). But we also had vertex D originally at index 3, now at 2. B moved from 1 to 3. Does this violate any other edges? Original edge A->B: A at 0, B at 3 -> fine. Original edge C->D still C at 1 before D at 2 fine. New edge D->B: D at 2, B at 3 fine. So valid.

This algorithm works. The key is that we only renumbered the vertices in the interval. In this example, the interval size was 3. If the interval were 1000, we would do a topological sort of 1000 vertices — which is fine if intervals are small on average.

**Pseudocode for label-reassignment (simplified):**

```python
def insert_edge(u, v):
    if index[u] < index[v]:   # already satisfied
        return
    if reachable(v, u):       # would create cycle
        raise CycleDetected
    L = index[v]
    R = index[u]
    vertices = [node for node in ordering[L:R+1]]
    # Build induced subgraph (using adjacency lists, but only edges among these vertices)
    subgraph = build_induced_subgraph(vertices)
    new_order = topological_sort(subgraph)   # returns list of vertices in topological order
    # Reassign indices within [L, R] range, evenly spaced
    for i, node in enumerate(new_order):
        ordering[L + i] = node
        index[node] = L + i
    # Done
```

This is simple but has worst-case O(k log k) where k = R-L+1. For k up to tens of thousands, it's still okay if not too frequent. But to guarantee sublinear, we need the randomized approach.

---

### 7. The Bender-Fineman Randomized Algorithm (High-Level)

The real algorithm maintains a label for each vertex that is a real number in [0,1] (or a random 64-bit integer). They use a data structure called a **"binary search tree on labels"** that supports search by label. To insert an edge (u,v), they check if label[u] < label[v]. If not, they need to find a new ordering of the vertices in the interval [label[v], label[u]] such that the relative order of all edges among them is maintained. They do this by:

- **Randomly permuting** the vertices in the interval? No, that would break existing constraints. Instead, they use the fact that the interval is a _total order_ that is almost topological—only the new edge is broken. They show that the number of vertices that need to move is small on expectation.

The actual method uses _forward edges_ to define a set of **"source blocks"** and _backward edges_ to define **"sink blocks"**. They then reassign labels to these blocks in a way that “compresses” the interval. It’s intricate; I recommend reading the original paper for completeness. The key takeaway: **expected O(log n) time per insertion.**

---

### 8. Applications in Build Systems

Now let’s connect back to build systems. Why do they need incremental topological ordering? Because the build graph (targets and their dependencies) is a DAG. When a source file changes, the build system must rebuild only the affected targets. To do that, it must:

1. Determine which targets have changed (e.g., by checking file hashes).
2. Find all targets that depend (transitively) on changed targets.
3. Schedule the rebuild in an order that respects dependencies (i.e., a topological order of the affected subgraph).

Step 3 is exactly a dynamic topological ordering problem. The build system doesn’t rebuild the entire graph every time—it rebuilds only the affected part. But to compute the affected part, it needs to traverse the dependency graph; during that traversal, it may discover that some dependencies have changed, which can affect the ordering of the affected subgraph.

**Example: Bazel’s Skyframe model.**  
Bazel models builds using a graph of _sky nodes_. Each node represents a file, a rule, or an artifact. When a source file changes, sky nodes invalidate their outputs, and the invalidation propagates through the graph. To schedule evaluation, Bazel needs to topologically order the invalidated nodes. This is done incrementally: Bazel maintains the graph in memory and uses a dynamic incremental algorithm (inspired by Bender-Fineman) to update the order.

**Example: Pants `--changed-by` logic.**  
Pants tracks dependencies dynamically; when you change a file, it computes the transitive closure of dependents and then builds them in the correct order. Pants’s dynamic graph uses a **synchronization order** that is maintained by periodic full sorts when the interval gets too large, but it works well in practice.

**Example: Make (GNU make) and Ninja.**  
Traditional `make` does not maintain a topological order incrementally; it relies on timestamps and runs a DFS-based traversal each time (which is essentially a topological sort of the entire graph). That is fine for small projects but not for large ones. Ninja is designed for speed; it also does a full topological sort but does it very fast using a static input (build.ninja). Ninja does not support dynamic graph changes—you regenerate the entire build file after each change (which itself can be a performance bottleneck). Newer build systems like Buck and Bazel aim for true incremental updates.

---

### 9. Performance Analysis and Benchmarks

How well do these algorithms perform in practice? Let’s consider a few scenarios.

**Small intervals (most common):** In a typical software project, the dependency graph has high locality. A header change only affects modules that include it, and those modules are often located in a subtree of the build graph. The interval between a changed header and its farthest affected target is often less than a few hundred vertices. In that case, a naive interval re-sort (like the simplified algorithm above) is perfectly fine—it updates the order in microseconds.

**Large intervals (rare but possible):** In a monorepo like Google’s, a change to a core library (e.g., `absl::Status`) can cascade to thousands or tens of thousands of targets. The interval between the library target and the leaf target might be huge. If we naively re-sort the entire interval, that would be a linear-time update (\( O(k) \)), which is still much better than re-sorting the entire graph (\( O(n) \)), but if \( k \) can be 10,000, we might not want to do it on every keystroke. Google’s solution (Bender-Fineman) ensures that even in these worst-case situations, the update takes \( O(\log n) \) expected time, independent of interval size. However, that comes with more complex data structures.

**Benchmarks from literature:**

- Alpern et al. (1990) reported update times of a few milliseconds for graphs with up to 10,000 vertices and an update sequence of 200,000 edges.
- Pearce and Kelly (2004) reported times roughly proportional to the size of the affected region: for a graph of 40,000 vertices and random edge insertions, average time per insertion was ~0.03ms.
- Bender et al. (2009) reported worst-case updates in under 0.1 microseconds per insertion for graphs of 10^6 vertices, once the algorithm was optimized.

In build systems, the actual bottleneck is often not the topological ordering update but the recomputation of file hashes and running build actions. However, the ordering must be fast enough to not add latency. Many systems strive for sub-millisecond updates.

---

### 10. Implementation Considerations and Pitfalls

Implementing a robust incremental topological ordering is tricky. Some practical issues:

- **Handle vertex additions and deletions.** Inserting a new vertex is easy: assign it a label between two existing vertices (using rationals or by renumbering). Deleting a vertex requires removing it from the order and optionally compacting labels.

- **Cycle detection.** As mentioned, you must detect when an edge insertion would create a cycle. One efficient way: use a dynamic reachability data structure (e.g., a transitive closure matrix, or a labeling scheme that supports O(1) reachability queries). For sparse graphs, a DFS from the target vertex backwards might be acceptable.

- **Integer overflow.** If you use integer labels and renumber by inserting numbers between neighbors, you may run out of bit space (e.g., after many insertions you might need a 64-bit integer; eventually you may need re-labeling). Real number labels (floats) have finite precision and can cause comparisons to fail. The Bender-Fineman algorithm handles this by periodic global rebuild.

- **Concurrency.** Build systems are often multi-threaded. The topological order must be protected by locks. Incremental updates are usually done on a single worker thread that also manages the graph.

- **Memory overhead.** Storing for each vertex its position and adjacency lists is standard. The Bender-Fineman algorithm requires additional pointers for the treap, which adds overhead.

---

### 11. When Is Incremental Topological Ordering Not Needed?

If your project is small (e.g., < 1000 files) and rebuilds are fast, you can simply run a full topological sort every time. The overhead of maintaining incremental structures may not be worth it. Also, if your build system uses a _static_ dependency graph (e.g., generated once from a build file and not updated), you don't need dynamic ordering. That is the case with Ninja: you regenerate the entire build file, which includes a topological sort of the whole graph. The regeneration can be expensive but is amortized over many builds.

But for interactive development environments where the build graph changes every few seconds (e.g., upon saving a file), incremental ordering is crucial.

---

### 12. Future Directions

Research continues on dynamic graph algorithms, including:

- **Dynamic topological ordering with worst-case guarantees.** The Bender-Fineman algorithm is amortized; can we achieve worst-case constant time per insertion? There are trade-offs.
- **Fully dynamic topological ordering with vertex and edge insertions and deletions.** Most algorithms assume only edge insertions; deletions are simpler but need to rebuild the ordering optimally.
- **Distributed build systems.** When the build graph is distributed across machines (e.g., remote caching), maintaining a global topological order is harder. Each machine might maintain its own local order.
- **Integration with incremental computation.** Build systems are an instance of incremental computation. In fact, incremental topological ordering is a key component of incremental algorithms like the _self-adjusting computation_ (e.g., Adapton, Incremental). The Bender-Fineman algorithm can be used to schedule re-execution of changed computations.

---

### 13. Conclusion

From a single character saved in your code editor to the final binary produced seconds later, an invisible algorithm guides the flow of work. The incremental topological ordering algorithm—especially the ingenious work of Bender, Fineman, Gilbert, and Tarjan—is the unsung hero of modern build systems. It transforms what could be a global, time-consuming recomputation into a localized, nearly instantaneous update.

We have seen why static topological sort is insufficient for a dynamic world, and we have explored both simple label-reassignment methods and the sophisticated randomized approach that guarantees logarithmic time. We have examined real-world applications in Bazel, Pants, and other build tools, and we have touched on implementation challenges.

The next time your IDE lights up with a green checkmark after a lightning-fast incremental build, take a moment to appreciate the algorithm that made it possible. It is more than just an academic curiosity; it is a lens through which we understand how to keep order in a changing world.

---

**Further Reading**

- Bender, M. A., Fineman, J. T., Gilbert, S., & Tarjan, R. E. (2009). “A new approach to incremental topological ordering.” _Proceedings of the 2009 Annual ACM-SIAM Symposium on Discrete Algorithms (SODA)_.
- Pearce, D. J., & Kelly, P. H. J. (2004). “A dynamic topological sort algorithm for directed acyclic graphs.” _ACM Journal of Experimental Algorithmics_.
- Alpern, B., Hoover, R., Rosen, B. K., Sweeney, P. F., & Zadeck, F. K. (1990). “Incremental evaluation of computational circuits.” _Proceedings of the 1990 ACM-SIAM Symposium on Discrete Algorithms_.
- The Bazel Build System: https://bazel.build
- Pants Build System: https://www.pantsbuild.org

---

_If you enjoyed this deep dive, consider sharing it with a colleague who wonders why their build system is so fast. And if you are experimenting with dynamic graph algorithms, try implementing the simplified label-reassignment — it’s a great weekend project that will teach you a lot about the interplay between theory and practice._
