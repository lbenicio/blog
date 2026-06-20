---
title: "Implementing The Minimum Spanning Tree Algorithms: Kruskal With Union Find And Prim With Fibonacci Heap"
description: "A comprehensive technical exploration of implementing the minimum spanning tree algorithms: kruskal with union find and prim with fibonacci heap, covering key concepts, practical implementations, and real-world applications."
date: "2026-01-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Implementing-The-Minimum-Spanning-Tree-Algorithms-Kruskal-With-Union-Find-And-Prim-With-Fibonacci-Heap.png"
coverAlt: "Technical visualization representing implementing the minimum spanning tree algorithms: kruskal with union find and prim with fibonacci heap"
---

# The Hidden Architecture of Networks: Implementing Kruskal and Prim at Full Throttle

Imagine you are the chief engineer for a new data center. You have a sprawling server farm—thousands of machines, each a node in a vast digital brain. Your task is to connect every single server to the network, ensuring they can all communicate. The catch? You have a finite budget for copper cabling and fiber optics. Every meter of cable costs money, and you are not allowed to waste a single centimeter. You must find the cheapest possible way to link every machine together, creating a network with no cycles—a tree—that connects everyone at the lowest total cost.

This is not a hypothetical. This is the **Minimum Spanning Tree (MST)** problem, and it is one of the most fundamental, elegant, and practically powerful concepts in computer science. It is the quiet engine behind the design of power grids, the routing of circuit boards, the clustering of galaxies in astronomical data, and yes, the layout of your local area network. The MST is the solution to the primal economic equation of connectivity: _How do we connect everyone to everything, with the least possible resource expenditure?_

But here is the rub. The problem is easy to explain. The solution is deceptively hard to implement efficiently at scale. A naive algorithm might get the job done for 100 nodes, but the moment you have a million nodes and a billion potential connections, the computation becomes a herculean task. This is where the beauty of computer science shines—not just in having an answer, but in having the _right_ answer, delivered with blistering speed.

There are two primary algorithms for finding an MST: **Kruskal’s Algorithm** and **Prim’s Algorithm**. Both are correct. Both are optimal in terms of the core logic. But their performance characteristics are worlds apart. They are like two different vehicles designed for the same destination: one is a nimble sports car for sparse highways, the other a robust truck for dense urban grids. Choosing the wrong one can mean the difference between a computation that finishes in milliseconds and one that crawls for hours.

In this deep dive, we will not only explore the theory behind these algorithms but also get our hands dirty with concrete implementations, complexity analysis, and real-world benchmarks. We’ll dissect the hidden data structures that make them tick—the Union-Find that powers Kruskal and the Fibonacci heap that can supercharge Prim. We’ll examine edge cases, common pitfalls, and advanced variations like parallel MST algorithms. By the end, you will understand not just _how_ these algorithms work, but _when_ and _why_ to use each one, and how to implement them at full throttle on graphs with millions of nodes.

## The Minimum Spanning Tree: A Formal Definition

Before we dive into the algorithms, let’s get our mathematical foundations solid. A **graph** $G = (V, E)$ consists of a set of vertices $V$ and a set of edges $E$, where each edge connects two vertices. In the context of our problem, each edge has a weight $w(e)$, typically a non-negative real number representing cost, distance, or latency. A **spanning tree** is a subgraph that:

- Connects all vertices (it is spanning).
- Contains no cycles (it is a tree).
- Has exactly $|V|-1$ edges.

Among all possible spanning trees, the **minimum spanning tree** (MST) is the one with the smallest total sum of edge weights. Note that the MST is not necessarily unique—if multiple edges have the same weight, there can be multiple MSTs.

### Why MSTs Matter: A Gallery of Applications

The MST problem is not just a textbook curiosity; its applications span an astonishing range of fields:

- **Network Design:** As in our opening scenario, laying cables for telecom, computer networks, or power grids. The MST gives the cheapest way to provide connectivity.
- **Circuit Design:** In VLSI design, connecting pins on a chip with minimum total wire length (often approximated with Manhattan distance MST).
- **Clustering:** In machine learning, MST-based clustering (e.g., single-linkage clustering) can identify clusters by cutting the longest edges of the MST.
- **Approximation Algorithms:** The MST is a building block for approximating solutions to NP-hard problems like the Traveling Salesman Problem (TSP). Christofides’ algorithm uses an MST to get a 1.5-approximation for TSP.
- **Image Segmentation:** Graph-based segmentation methods use MSTs to merge regions.
- **Astronomy:** Connecting galaxies in a cosmic web to study large-scale structure.
- **Routing Protocols:** Some multicast routing algorithms use MSTs to minimize total path cost.

Given this ubiquity, the efficiency of MST computation matters enormously. Let’s now meet the two classic algorithms that solve it.

## Kruskal’s Algorithm: The Greedy Edge-Keeper

Kruskal’s algorithm, named after Joseph Kruskal who published it in 1956, is perhaps the most intuitive MST algorithm. It operates on a simple greedy principle: _take the cheapest edge that does not create a cycle, and repeat until you have a tree._

### The Algorithm in Plain English

1. Sort all edges in non-decreasing order of weight.
2. Initialize an empty set of edges (the future MST).
3. For each edge in sorted order (from smallest to largest):
   - If adding this edge to the MST set does not form a cycle, add it.
   - Otherwise, discard it.
4. Stop when you have $|V|-1$ edges in the MST.

The critical question is: how do we efficiently check whether adding an edge creates a cycle? The answer lies in a deceptively simple data structure: the **Disjoint Set Union (DSU)** or **Union-Find**.

### Union-Find: The Silent Hero

The Union-Find data structure maintains a collection of disjoint sets. Initially, each vertex is in its own set. As we add edges to the MST, we are effectively _merging_ the sets of the two endpoints. If two vertices are already in the same set, then adding an edge between them would create a cycle (since there is already a path connecting them in the current MST). So the cycle check reduces to:

- Find which set each endpoint belongs to.
- If they are in different sets → merge the sets and add the edge.
- If they are in the same set → skip the edge.

Union-Find supports two operations:

- `find(x)`: returns the representative (root) of the set containing x.
- `union(x, y)`: merges the sets containing x and y.

With two classic optimizations—**path compression** and **union by rank**—these operations run in nearly constant amortized time, specifically $O(\alpha(n))$, where $\alpha$ is the inverse Ackermann function, which grows so slowly that it is effectively constant for any practical input size.

### Implementing Kruskal in Python

Let’s walk through a concrete implementation. We'll use a simple graph representation: a list of edges, each as a tuple `(weight, u, v)`. Sorting these edges is the first step.

```python
class DisjointSet:
    def __init__(self, n):
        self.parent = list(range(n))
        self.rank = [0] * n

    def find(self, x):
        # Path compression
        if self.parent[x] != x:
            self.parent[x] = self.find(self.parent[x])
        return self.parent[x]

    def union(self, x, y):
        # Union by rank
        x_root = self.find(x)
        y_root = self.find(y)
        if x_root == y_root:
            return False
        if self.rank[x_root] < self.rank[y_root]:
            self.parent[x_root] = y_root
        elif self.rank[x_root] > self.rank[y_root]:
            self.parent[y_root] = x_root
        else:
            self.parent[y_root] = x_root
            self.rank[x_root] += 1
        return True

def kruskal(vertices, edges):
    # edges: list of (weight, u, v)
    edges.sort(key=lambda e: e[0])  # sort by weight
    ds = DisjointSet(vertices)
    mst = []
    total_cost = 0
    for w, u, v in edges:
        if ds.union(u, v):
            mst.append((u, v, w))
            total_cost += w
            if len(mst) == vertices - 1:
                break
    return mst, total_cost

# Example usage
edges = [
    (10, 0, 1), (6, 0, 2), (5, 0, 3),
    (15, 1, 3), (4, 2, 3)
]
mst, cost = kruskal(4, edges)
print("MST edges:", mst, "Total cost:", cost)
```

Notice the `break` when we have collected `vertices - 1` edges—once we have a spanning tree, any further edges are irrelevant.

### Complexity Analysis of Kruskal

- **Sorting:** $O(E \log E)$, where $E$ is the number of edges. Since $\log E \approx \log V$ in a connected graph (because $E \leq V^2$), this is often written as $O(E \log V)$.
- **Union-Find operations:** $O(E \cdot \alpha(V))$ for the find/union calls. Since $\alpha(V)$ is tiny, this is essentially linear.
- **Overall:** $O(E \log V + E \alpha(V)) = O(E \log V)$.

The sorting step dominates. For dense graphs (where $E \approx V^2$), this becomes $O(V^2 \log V)$, which can be expensive. However, for sparse graphs (where $E \approx V$), it is nearly linear.

### Edge Cases and Pitfalls

- **Disconnected Graphs:** If the graph is disconnected, Kruskal will produce a spanning forest (a set of MSTs for each connected component) but will stop when edges run out. We should check if the number of edges in the MST equals $|V|-1$ to confirm connectivity.
- **Negative Weights:** The algorithm works without modification for negative weights; it still picks the smallest. However, if all weights are negative, the MST will be the most negative (i.e., maximum total weight) but still minimal in the sense of sum; the definition of "minimum" holds.
- **Floating Point Weights:** Sorting floats is fine, but beware of precision issues when comparing equality. The algorithm does not rely on equality checks for correctness beyond the union-find.
- **Large Graphs:** Sorting all edges can be memory-intensive. For graphs with billions of edges, we may need an external sort or an alternative approach like Prim's with a priority queue that processes edges incrementally.

## Prim’s Algorithm: The Voracious Node-Grower

Prim’s algorithm, independently discovered by Vojtěch Jarník in 1930, Robert Prim in 1957, and Edsger Dijkstra in 1959 (who also gave us Dijkstra’s shortest path algorithm), takes a different perspective. Instead of sorting edges, it grows the MST from a single starting node, adding the cheapest edge that connects the current tree to a new vertex.

### The Algorithm Described

1. Choose an arbitrary starting vertex.
2. Maintain a set of vertices already in the MST and a set of vertices not yet in it.
3. For each vertex not in the tree, keep track of the smallest-weight edge connecting it to the tree.
4. Repeatedly:
   - Pick the vertex not in the tree with the smallest connection weight.
   - Add that vertex and the corresponding edge to the MST.
   - Update the connection weights for all neighbors of the newly added vertex (if a newly discovered edge is cheaper).

The critical data structure here is a **priority queue** (min-heap) that can efficiently retrieve the vertex with the smallest key.

### Naïve Implementation and Its Downfall

A straightforward approach is to maintain an array `key[v]` for each vertex, storing the minimum weight of an edge connecting `v` to the current tree. Initially, `key[start] = 0` and all others are infinity. We also have a `parent` array to reconstruct the MST. At each step, we scan all vertices to find the one with minimum key that is not yet in the tree. This scanning step is $O(V)$ per iteration, leading to $O(V^2)$ total—fine for dense graphs but terrible for sparse ones.

The efficient implementation uses a min-heap that stores (key, vertex) pairs. We extract the minimum, and for each neighbor, we check if the edge weight is less than the neighbor’s current key and if that neighbor is not yet in the tree. If so, we update the key and push a new entry into the heap (or use a decrease-key operation).

### Using a Binary Heap vs. Fibonacci Heap

Python’s `heapq` module gives us a binary heap. A binary heap supports `decrease_key` in $O(\log V)$ time if we implement it ourselves, but `heapq` does not expose that operation. A common workaround is to push multiple entries into the heap and ignore stale ones when popped (by checking if the key matches the current `key[vertex]`). This leads to heap size $O(E)$ in the worst case, but operations remain $O(\log E)$.

The alternative is a **Fibonacci heap**, which supports decrease-key in $O(1)$ amortized time, and extract-min in $O(\log V)$ amortized. Using a Fibonacci heap, Prim’s complexity drops to $O(E + V \log V)$. However, Fibonacci heaps have high constant factors and are rarely used in practice except in theoretical settings.

### Python Implementation with `heapq`

```python
import heapq

def prim(vertices, adj, start=0):
    # adj: adjacency list as list of lists of (neighbor, weight)
    in_mst = [False] * vertices
    key = [float('inf')] * vertices
    parent = [-1] * vertices
    key[start] = 0
    heap = [(0, start)]  # (key, vertex)
    total_cost = 0
    mst_edges = []

    while heap:
        w, u = heapq.heappop(heap)
        if in_mst[u]:
            continue  # stale entry
        in_mst[u] = True
        total_cost += w
        if parent[u] != -1:
            mst_edges.append((parent[u], u, w))
        # Explore neighbors
        for v, weight in adj[u]:
            if not in_mst[v] and weight < key[v]:
                key[v] = weight
                parent[v] = u
                heapq.heappush(heap, (weight, v))
    # Check connectivity (optional: if some key remains inf, graph is disconnected)
    return mst_edges, total_cost

# Example: same graph as before
adj = [
    [(1,10), (2,6), (3,5)],
    [(0,10), (3,15)],
    [(0,6), (3,4)],
    [(0,5), (1,15), (2,4)]
]
mst, cost = prim(4, adj)
print("MST edges:", mst, "Cost:", cost)
```

Note the pattern: we push a new entry for each improvement. The same vertex may appear many times in the heap, but we skip stale entries.

### Complexity Analysis of Prim

- **Binary heap:** Each vertex is extracted exactly once ($O(V \log V)$). Each edge may cause a push (or decrease-key simulation) – up to $E$ pushes, each $O(\log V)$, so $O(E \log V)$. Overall: $O((V+E) \log V) = O(E \log V)$.
- **Fibonacci heap:** $O(E + V \log V)$.

Theoretically, Prim with Fibonacci heap wins for dense graphs where $E$ is large, because the $V \log V$ term becomes negligible compared to $E$. In practice, the constant factors of Fibonacci heaps often overshadow the theoretical advantage for moderate sizes.

## When to Use Kruskal vs. Prim: A Decision Guide

Both algorithms solve the same problem, but their performance characteristics differ significantly based on graph density and available data structures.

| Aspect                             | Kruskal                                                                                                                                          | Prim                                                                                                                                                                                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Graph Representation**           | Edges list (needs sorting)                                                                                                                       | Adjacency list (needs heap)                                                                                                                                                                                                             |
| **Sparse Graphs ($E \approx V$)**  | Excellent – sorting is $O(V \log V)$, union-find is nearly linear                                                                                | Also excellent – heap operations are $O(V \log V + E \log V) \approx O(V \log V)$                                                                                                                                                       |
| **Dense Graphs ($E \approx V^2$)** | Sorting $O(V^2 \log V)$ becomes heavy. But if edges are generated on the fly (e.g., complete graph with metric weights), sorting is unavoidable. | With binary heap: $O(V^2 \log V)$ as well. But with Fibonacci heap: $O(V^2 + V \log V) = O(V^2)$ – theoretically better. Or we can use a simple array-based implementation for dense graphs and get $O(V^2)$ without any heap overhead. |
| **Memory**                         | Stores all edges – can be problematic for huge graphs                                                                                            | Stores adjacency list – typically smaller than edge list for sparse graphs; but the heap may grow large.                                                                                                                                |
| **Incremental/Online MST**         | Not easily adapted – requires all edges upfront                                                                                                  | Can work in a streaming fashion if edges arrive in order of increasing weight? Not directly, but Prim adapts to dynamic changes?                                                                                                        |
| **Parallelization**                | Kruskal’s sorting step is easily parallelizable (parallel sort). Union-find can be made concurrent with some care.                               | Prim is inherently sequential due to the greedy step; parallel variants exist but are more complex.                                                                                                                                     |
| **Negative Edges**                 | Works fine                                                                                                                                       | Works fine (but note that negative edges may cause weird behavior if graph has negative cycles – but MST is still defined because we don't care about cycles outside tree)                                                              |
| **Disconnected Graphs**            | Produces a minimum spanning forest (MSF). User must check final edge count.                                                                      | Produces a spanning tree only if graph is connected; otherwise it will fail to reach all vertices. To get MSF, we can run Prim from multiple starting points.                                                                           |

### Practical Guidance

- **Sparse graphs** (e.g., road networks, where each node has few neighbors): **Kruskal** is often simpler and faster because sorting is cheap and union-find is lightweight. It also works well when edges come pre-sorted.
- **Dense graphs** (e.g., complete graphs with Euclidean distances): **Prim** with a simple array-based priority queue (no heap) yields $O(V^2)$ time, which is better than Kruskal’s $O(V^2 \log V)$. Alternatively, Prim with a Fibonacci heap also gives $O(V^2)$ theoretically, but the array approach is easier.
- **Graphs with millions of nodes but sparse edges**: Both perform well, but Kruskal often wins due to lower memory overhead and strong locality. However, if memory is tight, Prim’s adjacency list might be preferable.
- **When you need only the total weight, not the tree itself**: Both can compute the weight incrementally. For Prim with binary heap, the total cost accumulates naturally.

## Deep Dive into Implementation Optimizations

### Kruskal: Beyond Basic Union-Find

**Path Splitting vs. Path Compression:** The classic path compression (as shown) sets every node on the path directly to the root. Another variant is path splitting, where each node points to its grandparent, reducing recursion depth. Both achieve $O(\alpha(n))$.

**Union by Size vs. Union by Rank:** The textbook uses rank (height). Alternatively, we can union by the size of the set. Both yield logarithmic amortized bounds. In practice, union by size is slightly easier to implement with a size array.

**Sorting Optimizations:** If the graph is generated dynamically (e.g., all pairwise distances in a plane), we might use geometric data structures to avoid sorting all edges. For example, the **Delaunay triangulation** of points yields a graph with $O(V)$ edges that contains the MST – we can then run Kruskal on that sparse graph.

**External Sorting:** For graphs too large to fit in RAM (e.g., $10^{10}$ edges), we must use external sorting algorithms that divide-and-conquer on disk. Kruskal then becomes I/O-bound, but it can still be performed.

### Prim: The Array-Based Implementation for Dense Graphs

If $V$ is moderate (say a few thousand) but the graph is complete (every pair has an edge), maintaining a binary heap of size $V^2$ is wasteful. Instead, we can use a simple array:

```python
def prim_dense(vertices, weight_matrix):
    # weight_matrix as list of lists or 2D array
    in_mst = [False] * vertices
    key = [float('inf')] * vertices
    parent = [-1] * vertices
    key[0] = 0
    for _ in range(vertices):
        # Find min key among non-MST vertices (O(V) scan)
        u = -1
        min_key = float('inf')
        for v in range(vertices):
            if not in_mst[v] and key[v] < min_key:
                min_key = key[v]
                u = v
        if u == -1:  # disconnected
            break
        in_mst[u] = True
        # Update neighbors
        for v in range(vertices):
            w = weight_matrix[u][v]
            if w != 0 and not in_mst[v] and w < key[v]:
                key[v] = w
                parent[v] = u
    # Reconstruct MST weight
    total = sum(key)  # key contains min edge weight for each vertex (except start)
    return total
```

Complexity: $O(V^2)$ time, $O(V^2)$ memory if storing full matrix. This is ideal for dense graphs when $V$ is up to ~10,000.

### Fibonacci Heap in Pure Python

Fibonacci heaps are complex data structures with high constant factors. For a blog post, we might mention them but rarely implement them from scratch in production. However, it's instructive to know they exist. In C++ or Java, they might be used, but in Python, the overhead of object-oriented constructs makes them slower than a binary heap for typical sizes.

### Speeding Up Prim with a Bucketed Priority Queue

If edge weights are integers from a small range (e.g., 1..1000), we can use a bucket queue (also called Dial's algorithm) to achieve $O(E + V + max\_weight)$ time. This is similar to Dijkstra with integer weights. For MST, we can maintain an array of buckets indexed by key, and extract min by scanning non-empty buckets.

## Advanced Topics and Extensions

### Minimum Spanning Forest for Disconnected Graphs

Both algorithms can be adapted to handle disconnected graphs. For Kruskal, the union-find simply never merges components that aren't connected by any edge; the resulting algorithm outputs a minimum spanning forest (MSF) – a set of MSTs for each connected component. For Prim, we can run the algorithm multiple times, each time picking a new unvisited start vertex until all vertices are visited.

### Expected Linear-Time MST Algorithms

The classic Kruskal and Prim are not the fastest known in theory. In 1984, Karger, Klein, and Tarjan introduced a randomized algorithm that runs in expected linear time $O(V + E)$. It works by a combination of Borůvka's algorithm (another classic) and random sampling. For practical purposes, however, Kruskal and Prim are often sufficient.

### Parallel MST Algorithms

For very large graphs, parallelism is key. Kruskal's sorting can be trivially parallelized using parallel sort (e.g., in C++ with `__gnu_parallel::sort`). Union-find operations are trickier to parallelize because they involve concurrent modifications. There are concurrent union-find implementations using compare-and-swap, but they add complexity.

Prim's algorithm is inherently sequential in its greedy selection. However, parallel variants like **Borůvka’s algorithm** (which repeatedly adds the cheapest edge from each component in parallel) are well-suited to parallel execution. Borůvka’s algorithm can be implemented with $O(E \log V)$ time and naturally parallelizes across components.

### Dynamic MST and Minimum Spanning Tree Under Edge Updates

What if the graph changes over time (edges added, removed, weight changes)? Maintaining the MST dynamically is a hard problem. There are algorithms (e.g., by Holm et al.) that achieve polylogarithmic update time, but they are complex. For many practical scenarios, recomputing from scratch with Kruskal or Prim is faster than the constant overhead of dynamic maintenance.

### Beyond Simple Weighted Graphs: The Euclidean MST

A special case of MST is when points are in a Euclidean plane and edge weights are distances. The Euclidean MST can be found by first computing the Delaunay triangulation (which has $O(V)$ edges) and then running Kruskal on that triangulation. This reduces the MST problem on $V$ points from $O(V^2)$ to $O(V \log V)$.

## Benchmarking Kruskal and Prim on Realistic Data

Let’s simulate some numbers to illustrate the performance trade-offs. We'll test random graphs of varying sizes and densities using Python (with `timeit`). Note: Python's `heapq` is relatively fast, but its overhead for large heaps can be significant. For fairness, we'll implement both algorithms with standard libraries.

### Sparse Graph (E ≈ 2V, i.e., almost a tree)

- V = 1,000,000, E = 2,000,000
- Kruskal: Sorting 2 million edges is fast (≈ 0.2 seconds in C++). Union-find with 1M finds/unions is under 0.1s. Total < 0.5s.
- Prim: adjacency list with binary heap. Heap operations: each edge causes a push (some pushes may be stale). 2M pushes, each O(log V) ≈ 20 steps, so ~40M operations – in Python, this could take tens of seconds. Kruskal wins.

### Dense Graph (E ≈ V^2/2, V=5000)

- V = 5000, E ≈ 12.5 million
- Kruskal: Sorting 12.5M edges – heavy. In Python, sorting 12.5 million integers is borderline (several seconds). In C++ it's fine (< 1s). Union-find 12.5M operations is okay.
- Prim with binary heap: 12.5M pushes into heap – heap size grows huge, many stale entries. Potentially very slow in Python.
- Prim with array-based dense approach (O(V^2)): 5000^2 = 25M scans – in Python, nested loops are slow but could be optimized with `numpy`. In C++, this is faster than Kruskal's sort because it avoids log factor.

Conclusion: For dense graphs, use Prim with an array (or with a Fibonacci heap in C++). For sparse, use Kruskal.

## Conclusion: The Hidden Architecture Revealed

We began with a vision of a massive data center, cables snaking between racks, every centimeter of fiber costing precious dollars. The Minimum Spanning Tree is the mathematical guarantee that you have spent no more than necessary. And now we understand the two great algorithms that solve this problem – Kruskal and Prim – not just as abstract logic, but as living pieces of software that must contend with the harsh reality of memory hierarchies, data structure overhead, and graph density.

Kruskal’s algorithm, with its elegant sorting and union-find, excels when edges are few and can be cheaply sorted. Prim’s algorithm, growing like a crystal from a seed, shines when the graph is dense and you can leverage a specialized priority queue or a simple array scan. In practice, a savvy engineer will profile their data before choosing: measure the edge count, check the memory budget, estimate the constant factors. There is no one-size-fits-all answer, but the knowledge of both algorithms equips you to make the right call.

And so, the next time you design a network, plan a circuit, or cluster a galaxy, remember: the hidden architecture of connectivity is not just a tree – it’s the _minimum_ tree, found with the right algorithm, implemented at full throttle.

---

_Further Reading:_

- Thomas H. Cormen et al., _Introduction to Algorithms_, chapters on MST.
- Robert Sedgewick and Kevin Wayne, _Algorithms_, 4th ed. – excellent Java implementations.
- The original papers: Kruskal (1956), Prim (1957), and Jarník (1930).
- For dynamic MST: Holm, de Lichtenberg, Thorup (2001).
- For parallel MST: Borůvka's algorithm and its parallel implementations.
