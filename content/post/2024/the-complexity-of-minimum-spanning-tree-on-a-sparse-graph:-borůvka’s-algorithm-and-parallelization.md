---
title: "The Complexity Of Minimum Spanning Tree On A Sparse Graph: Borůvka’S Algorithm And Parallelization"
description: "A comprehensive technical exploration of the complexity of minimum spanning tree on a sparse graph: borůvka’s algorithm and parallelization, covering key concepts, practical implementations, and real-world applications."
date: "2024-08-11"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-complexity-of-minimum-spanning-tree-on-a-sparse-graph-borůvka’s-algorithm-and-parallelization.png"
coverAlt: "Technical visualization representing the complexity of minimum spanning tree on a sparse graph: borůvka’s algorithm and parallelization"
---

# The Complexity Of Minimum Spanning Tree On A Sparse Graph: Borůvka’s Algorithm And Parallelization

## Introduction

Imagine you are a network engineer tasked with connecting a thousand servers in a sprawling data center using the least amount of fiber-optic cable. Each server can communicate with a handful of nearby neighbors, but cabling costs differ between every pair. You need a subset of links that keeps the network fully connected while minimizing total cable length. This is the classic **Minimum Spanning Tree (MST)** problem, and it pervades modern computing: from designing transportation networks and electric power grids to constructing phylogenetic trees in biology and solving approximation algorithms for the traveling salesman problem. In the era of massive graphs—social networks with billions of users, the Internet’s autonomous system topology, or the human brain’s connectome—finding MSTs efficiently is not just an academic exercise; it is a practical necessity.

The MST problem is deceptively simple: given a connected, undirected graph with weighted edges, find a spanning tree (a subset of edges connecting all vertices with no cycles) whose total edge weight is minimal. Three classical algorithms have dominated textbooks for nearly a century: Kruskal’s algorithm (1956), Prim’s algorithm (1957), and Borůvka’s algorithm (1926). The first two are the darlings of undergraduate data structures courses, beloved for their clean use of union-find (Kruskal) or priority queues (Prim). Borůvka’s algorithm, though historically the first, is often relegated to footnotes—a victim of its age and a perceived complexity that obscures its modern relevance. But in an age of parallel and distributed computing, Borůvka’s algorithm deserves a second, deeper look. Its unique structure makes it a natural fit for parallelization, especially on the sparse graphs that dominate real-world applications.

Why do sparse graphs matter? Most graphs encountered in practice are not dense—they have far fewer edges than the complete graph \(O(V^2)\). A sparse graph is typically defined as having \(E = O(V)\), where \(V\) is the number of vertices and \(E\) the number of edges. Social networks, web graphs, transportation networks, and neural connectomes all exhibit this property. On such graphs, the classic MST algorithms exhibit different performance characteristics, and Borůvka’s algorithm—often overlooked—can offer advantages in both sequential and parallel settings.

In this article, we will dissect the MST problem with a focus on sparse graphs. We will review the three classical algorithms, analyze their complexities, and then dive deep into Borůvka’s algorithm. We will examine why it is uniquely suited for parallelization, provide detailed examples with pseudocode, and discuss advanced variations used in modern graph processing frameworks. By the end, you will understand why Borůvka’s algorithm is not just a historical curiosity but a powerful tool for solving MST on massive, sparse graphs in distributed environments.

## The Minimum Spanning Tree Problem: Formal Definition and Properties

Before exploring algorithms, let us establish a rigorous foundation. Let \(G = (V, E)\) be a connected, undirected graph with a weight function \(w: E \to \mathbb{R}\). A spanning tree of \(G\) is a subset \(T \subseteq E\) such that:

- \(|T| = |V| - 1\),
- The subgraph \((V, T)\) is connected and acyclic.

A minimum spanning tree is a spanning tree that minimizes \(\sum\_{e \in T} w(e)\). The MST is not necessarily unique if edge weights can be equal, but the set of all MSTs shares the same total weight.

**Key properties:**

- **Cut property:** For any cut \((S, V \setminus S)\), the minimum-weight edge crossing the cut belongs to some MST.
- **Cycle property:** For any cycle, the maximum-weight edge in the cycle is not in any MST.

These properties form the correctness proofs for all three algorithms. They also hint at the structural simplicity that makes MST tractable even for huge graphs—it is a matroid optimization problem, and greedy algorithms work.

## The Classical Trio: Kruskal, Prim, and Borůvka

### 1. Kruskal’s Algorithm

**Idea:** Sort all edges by weight, then iterate from smallest to largest, adding an edge to the forest if it connects two different components (i.e., does not create a cycle). Use a disjoint-set data structure (union-find) to efficiently check connectivity.

**Pseudocode:**

```
function kruskal(G):
    sort E by increasing weight
    initialize empty set T
    for each vertex v: makeSet(v)
    for each edge (u,v) in sorted order:
        if find(u) != find(v):
            T = T ∪ {(u,v)}
            union(u,v)
    return T
```

**Complexity:** Sorting takes \(O(E \log E) = O(E \log V)\) since \(\log E \approx \log V\). The union-find operations (almost constant per edge) add \(O(E \alpha(V))\), where \(\alpha\) is the inverse Ackermann function. Overall: \(O(E \log V)\).

**On sparse graphs:** When \(E = O(V)\), Kruskal runs in \(O(V \log V)\), which is efficient. However, sorting all edges is a global operation that is difficult to parallelize effectively.

### 2. Prim’s Algorithm

**Idea:** Grow a tree from an arbitrary root, repeatedly adding the cheapest edge that connects the tree to a vertex outside the tree. Implement with a priority queue.

**Pseudocode (using binary heap):**

```
function prim(G, root):
    initialize min-heap for vertices
    for each v: key[v] = ∞, parent[v] = null
    key[root] = 0
    heap.insert(root)
    while heap not empty:
        u = heap.extractMin()
        for each neighbor v of u:
            if v in heap and w(u,v) < key[v]:
                key[v] = w(u,v)
                parent[v] = u
                heap.decreaseKey(v, key[v])
    return edges (parent[v], v) for all v != root
```

**Complexity:** With a binary heap, \(O((V+E) \log V) = O(E \log V)\). With a Fibonacci heap, \(O(E + V \log V)\). On dense graphs (\(E = O(V^2)\)), Prim with Fibonacci heap achieves \(O(V^2)\), which is optimal. On sparse graphs, binary heap is fine.

**Parallelization:** Prim is inherently sequential because it grows one vertex at a time. Parallel implementations exist but are complex and not as natural as Borůvka’s.

### 3. Borůvka’s Algorithm

**Idea:** Unlike Kruskal and Prim, Borůvka’s algorithm works in phases. In each phase, for every connected component, select the cheapest edge incident to that component (i.e., the edge with minimal weight that connects the component to a different component). Then contract all selected edges into new components. Repeat until only one component remains.

**History:** Otakar Borůvka first proposed the algorithm in 1926 to solve the problem of electrifying a rural region in Moravia (now Czech Republic). He wanted to minimize the length of wire needed to connect villages. The algorithm is sometimes called Sollin’s algorithm (after a 1961 rediscovery by Marshall Sollin).

**Pseudocode:**

```
function boruvka(G):
    T = empty set
    components = {each vertex as a component}
    while number of components > 1:
        for each component C:
            cheapestEdge[C] = min-weight edge from C to another component
        for each component C:
            e = cheapestEdge[C]
            if e is not already in T:
                T = T ∪ {e}
                merge the two components connected by e
            else:
                // edge already considered
        // After merging, update component identifiers
    return T
```

**Implementation details:** We need to efficiently find for each component the minimum outgoing edge. This can be done by scanning all edges and checking their endpoints. In each phase, we can process all edges in \(O(E)\) time, then merge components (using union-find) and relabel.

**Complexity:** Each phase reduces the number of components by at least a factor of 2 (in the worst case, but often more). Thus there are at most \(\log_2 V\) phases. Each phase costs \(O(E)\) to scan edges and merge components. Total sequential time: \(O(E \log V)\).

**On sparse graphs:** \(O(V \log V)\), similar to Kruskal.

**Parallelization:** This is where Borůvka shines. Each phase’s edge scanning can be done in parallel across edges or components. The independent nature of selecting the cheapest edge per component allows for data parallelism. In distributed memory, each processor can handle a subset of vertices or edges.

## Why Sparse Graphs Dominate the Real World

Sparse graphs are the norm, not the exception. A graph is sparse if \(E = O(V)\) or, more loosely, \(E = O(V \log V)\). Let’s consider a few examples:

- **Social networks:** In a friendship graph, each user has a bounded number of friends (Dunbar’s number ~150). With billions of users, average degree ~200. So \(E \approx 200V\), i.e., linear in \(V\).

- **Road networks:** Cities are connected by roads. Usually each city has at most 4-5 incident highways. The graph is planar-like, with \(E = O(V)\).

- **Internet topology:** Routers connect to a few peers. The AS (Autonomous System) graph has average degree ~20.

- **VLSI circuits:** Wires connect a limited number of components.

- **Neural connectome:** Neurons have thousands of connections, but still far less than complete.

In all these cases, algorithms that have linear or near-linear dependence on \(E\) are desirable. MST algorithms with \(O(E \log V)\) perform well. However, when \(V\) is in the billions, sequential algorithms become too slow. Parallelization is essential.

## Deep Dive into Borůvka’s Algorithm

### Detailed Example

Consider a graph with vertices {A,B,C,D,E} and edges:

- A-B: 2, A-D: 4
- B-C: 3, B-D: 5
- C-D: 1, C-E: 6
- D-E: 7

**Phase 1:**

- Components: {A}, {B}, {C}, {D}, {E}
- For each component, find cheapest outgoing edge:
  - A: min to {B}=2, {D}=4 -> cheapest= (A-B,2)
  - B: min to {A}=2, {C}=3, {D}=5 -> (A-B,2) (but note same edge)
  - C: min to {B}=3, {D}=1, {E}=6 -> (C-D,1)
  - D: min to {A}=4, {B}=5, {C}=1, {E}=7 -> (C-D,1)
  - E: min to {C}=6, {D}=7 -> (C-E,6)
- Selected edges: (A-B,2), (C-D,1), (C-E,6). Add all to T.
- Merge components: A-B forms component X; C-D-E forms component Y (since C-D and C-E connect them). Now two components: X and Y.

**Phase 2:**

- Components: X={A,B}, Y={C,D,E}
- For X: cheapest outgoing edge? Edges from X to Y: A-D (4), B-D (5). Cheapest= (A-D,4)
- For Y: cheapest outgoing edge to X: same edges, cheapest (A-D,4)
- Selected edge: (A-D,4). Add to T.
- Merge X and Y into single component. Now only one component.

Result: T = {(A-B,2), (C-D,1), (C-E,6), (A-D,4)}. Total weight=13. Is this an MST? Check: edges count=4. The cycle A-B-D-A exists? Edges: A-B, A-D, B-D? No, B-D not in T. Actually, the graph has a cycle A-B-C-D-A? Let's verify: The MST we found: A-B (2), A-D (4), C-D (1), C-E (6). That's a tree? Vertices: A connected to B and D; D connected to C; C connected to E. All vertices connected, no cycles. Indeed weight=13. The optimal MST might be different: check alternative: A-B (2), B-C (3), C-D (1), C-E (6) total=12. Wait, that is also a spanning tree. But Borůvka's algorithm selected (A-D,4) instead of (B-C,3). Why? Because in phase 1, component C selected (C-D,1) and (C-E,6) but component B selected (A-B,2). So after phase 1, components X and Y; then X looks for cheapest outgoing edge: from X to Y there are A-D (4) and B-D (5). But also from X to Y there is no B-C? Actually, B-C is an edge between B (in X) and C (in Y) with weight 3. Oh! We missed that. In the phase 2 step, when scanning edges to find cheapest for component X, we should consider all edges crossing the cut between X and Y. The edge B-C (3) connects B in X to C in Y. That weight (3) is cheaper than A-D (4). Why didn't we pick it? Because in our phase 1, component C selected (C-D,1) and (C-E,6) but not (B-C,3)? Wait, in phase 1, component C considered edges to other components: (B-C,3) connects to B (component B), (C-D,1) to D, (C-E,6) to E. The cheapest was (C-D,1). So (C-D,1) was added. But component B, in phase 1, considered edges: (A-B,2) to A, (B-C,3) to C, (B-D,5) to D. Cheapest was (A-B,2). So (A-B,2) added. After merging, X contains A and B; Y contains C, D, E. Now the edge (B-C,3) crosses the cut. So in phase 2, for component X, the cheapest outgoing edge should be (B-C,3), not (A-D,4). Let's recalc phase 2:

- Edges from X to Y: A-D (4), B-D (5), B-C (3). Minimum is 3 (B-C).
- Similarly for Y to X: same set, minimum 3.
- So we would select (B-C,3). Then merge X and Y. Final MST: (A-B,2), (C-D,1), (C-E,6), (B-C,3) total weight 12. That is indeed a true MST. My earlier mistake was forgetting B-C. The algorithm works correctly if implemented properly.

This example illustrates the importance of correctly scanning all edges in each phase.

### Correctness Proof Sketch

Borůvka’s algorithm is correct because it repeatedly applies the cut property: in each phase, for each component, the cheapest edge leaving that component is part of some MST. Since we add all such edges simultaneously (except potential duplicates), the set remains a subset of some MST. The number of components halves each time, so eventually we get a tree.

### Complexity Analysis in Depth

The naive implementation of Borůvka's algorithm runs in \(O(E \log V)\) time, but we can achieve better with clever data structures.

**Standard implementation:**

- For each phase, we reset an array `cheapest` of size \(V\) (or number of components) to infinity.
- Iterate over all edges: for each edge (u,v,w), find the component IDs of u and v (using find operation). If they are different, then for each component, update if weight is less than current cheapest.
- After scanning all edges, for each component that has a cheapest edge, add that edge to the MST and merge the two components (union).
- Complexity per phase: \(O(E)\) edge scans plus \(O(V)\) merge operations (but merges can be \(O(V)\) total across phases using union-find).
- Number of phases: at most \(\log_2 V\) (since components at least halve). So total \(O(E \log V)\).

**Improvements:** Using the fact that we only need the minimum outgoing edge per component, we can use a priority queue per component. However, this tends to increase complexity. For sparse graphs, the simple \(O(E \log V)\) is often acceptable.

**Comparison with Kruskal and Prim:**

- Kruskal: \(O(E \log V)\) but requires global sorting, which is not parallel-friendly.
- Prim: \(O(E \log V)\) with binary heap, but sequential.
- Borůvka: \(O(E \log V)\) but each phase is a simple edge scan that can be parallelized.

## Parallel Borůvka: Unleashing Concurrency

### Why Borůvka Is Naturally Parallel

In each phase, the selection of the cheapest outgoing edge for each component is independent—the choice for component A does not affect the choice for component B, except that they might select the same edge (which is fine; we just add it once). This independence allows us to process all edges in parallel, updating the cheapest edge for each component in a thread-safe manner. Moreover, the merging of components after each phase can be done using parallel union-find or by contracting the graph.

**Shared-memory parallelism (e.g., multicore CPU):**

- Distribute edges across threads. Each thread processes a subset of edges, updating `cheapest` array using atomic operations or per-thread local arrays followed by reduction.
- After edge scan, we have a list of edges to add. Merging components can be done with a parallel union-find (union operations are mostly independent but require careful synchronization).
- Number of phases decreases geometrically, so the parallel overhead is amortized.

**Distributed-memory parallelism (e.g., MPI, MapReduce):**

- Partition vertices across processors. Each processor owns a subset of vertices and their incident edges (edge-cut partitioning).
- In each phase:
  1. Each processor, for its local vertices, finds the cheapest outgoing edge among its local edges (and possibly edges to remote vertices). This requires communication if the cheapest edge goes to a vertex on another processor.
  2. Processors exchange information to determine the global cheapest edge for each component (this can be done via a reduction).
  3. Decide on which edges to add (need to avoid duplicates). Then contract components (update component IDs). This involves global communication.

Borůvka's algorithm is popular in distributed graph processing because it fits the Bulk Synchronous Parallel (BSP) model used by systems like Pregel, GraphLab, or Giraph.

### Example: MapReduce Implementation

In MapReduce (e.g., Hadoop), we can implement Borůvka as follows:

**Map phase 1 (per edge):** Emit key-value pairs where key is component ID of one endpoint, value is the edge with the other component ID and weight. For each component, we want the minimum weight edge.

**Reduce phase 1:** For each component, gather all edges, pick the smallest, and emit the selected edge (or just the pair of component IDs to be merged).

**Map phase 2:** Use a mapping from old component IDs to new component IDs (after merging). Then re-encode all edges with new component IDs. Repeat.

This approach requires careful handling of duplicate edges (the same edge might be selected by both endpoints). In practice, we can break ties by vertex IDs to ensure consistency.

### Speedup Analysis

The parallel speedup of Borůvka is not linear due to the halving of phases. With \(P\) processors, the first phase can process all edges in \(O(E/P + \text{overhead})\), but subsequent phases have fewer edges? Actually, the number of edges remains constant (we don't remove edges), but we only need to consider edges whose endpoints belong to different components. As components grow, many edges become internal and can be ignored. However, the algorithm still scans all edges in each phase unless we prune. Pruning can be done by maintaining adjacency lists for each component, but that adds complexity.

In practice, for very large sparse graphs, Borůvka's algorithm can achieve good parallel efficiency because the edge scanning is embarrassingly parallel and the number of phases is logarithmic. For graphs with millions of vertices and edges, the runtime is dominated by the first few phases.

## Advanced Topics and Optimizations

### Borůvka with Edge Contraction

Instead of using union-find to track components, we can physically contract edges: after each phase, we merge vertices of selected edges into a single supervertex. This reduces the number of vertices and edges (internal edges become loops or parallel edges). Keeping the graph sparse after contraction is important. Edge contraction can be done in parallel using pointer jumping or similar techniques.

### Borůvka as Part of Filter-Kruskal

**Filter-Kruskal** is a randomized algorithm that improves Kruskal by filtering out edges that are guaranteed not to be in the MST. It uses Borůvka-inspired ideas: run a few Borůvka phases to contract the graph, then apply Kruskal on the smaller graph. This yields expected linear time for random edge weights.

### Borůvka for Dynamic MST

In dynamic graphs where edges are inserted or deleted, Borůvka's algorithm can be adapted to update the MST efficiently. The key is that after a change, only a few components need to recompute their cheapest outgoing edges. This leads to algorithms with \(O(\log V)\) amortized time per update using heavy precomputation.

### Borůvka in Graph Processing Frameworks

Modern graph processing systems like **Pregel** and **GraphLab** use the “think like a vertex” paradigm. Borůvka’s algorithm can be implemented as follows:

- Each vertex, in each superstep, sends its current cheapest incident edge to its neighbors.
- Vertices collect messages, determine the global cheapest edge for their component, and if they are the “root” of the component, they decide to add the edge and merge.
- This is a natural message-passing algorithm.

## Empirical Performance: Case Studies

Let's consider a sparse graph with \(V = 10^8\) vertices and \(E = 2 \times 10^8\) edges (average degree 2). This is typical of web graphs.

- **Sequential Kruskal:** Sorting 200M edges takes thousands of seconds on a single machine. Even with external sorting, it's heavy.
- **Sequential Borůvka:** Each phase scans 200M edges, about 10-20 seconds (memory bandwidth bound). With ~27 phases (\(\log_2 10^8\)), total time ~300 seconds. Still high.
- **Parallel Borůvka on 1000 cores:** Each phase reduces edge scan to ~0.02 seconds (if perfectly parallel). With phases, total ~0.5 seconds. Add communication overhead, maybe a few seconds. This is dramatic speedup.

In practice, frameworks like **GraphX (Spark)** and **Giraph** have used Borůvka for MST on billion-edge graphs.

## Conclusion

Borůvka’s algorithm, the oldest MST algorithm, has proven its relevance in the age of massive parallelism and sparse graphs. While Kruskal and Prim are simpler for small graphs, Borůvka’s unique structure—each phase selecting minimum outgoing edges for all components independently—makes it the algorithm of choice for parallel and distributed environments. Its logarithmic number of phases, combined with the embarrassingly parallel edge scanning, allows it to scale to graphs with billions of edges.

As graph processing systems continue to evolve, algorithms that embrace parallelism will dominate. Borůvka's algorithm, long overlooked, is a shining example of how an old idea can find new life in a different technological context. Whether you are connecting servers in a data center, building the next generation of social network infrastructure, or analyzing the human brain connectome, understanding Borůvka’s algorithm gives you a powerful tool for solving MST efficiently at scale.

So next time you need a minimum spanning tree on a sparse graph, think twice before reaching for Kruskal or Prim. Consider Borůvka—the algorithm that was ahead of its time.

---

_This article has explored the complexity of Minimum Spanning Tree on sparse graphs, with a deep dive into Borůvka’s algorithm and its parallelization. For further reading, see the original paper by Borůvka (1926), the survey on parallel MST algorithms, and the documentation of graph processing frameworks._
