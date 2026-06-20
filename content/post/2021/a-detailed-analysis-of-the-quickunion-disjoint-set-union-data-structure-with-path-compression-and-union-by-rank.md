---
title: "A Detailed Analysis Of The Quickunion Disjoint Set Union Data Structure With Path Compression And Union By Rank"
description: "A comprehensive technical exploration of a detailed analysis of the quickunion disjoint set union data structure with path compression and union by rank, covering key concepts, practical implementations, and real-world applications."
date: "2021-11-04"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/a-detailed-analysis-of-the-quickunion-disjoint-set-union-data-structure-with-path-compression-and-union-by-rank.png"
coverAlt: "Technical visualization representing a detailed analysis of the quickunion disjoint set union data structure with path compression and union by rank"
---

# A Detailed Analysis of the Quick-Union Disjoint Set Union Data Structure with Path Compression and Union by Rank

## Introduction

Imagine you are building a social network with millions of users. Every day, two users become friends, and you need to answer queries like “Are Alice and Bob in the same friend circle?” Or consider a maze generator that decides which walls to knock down—it must avoid creating cycles. Or think of a compiler that must determine whether two variable names refer to the same object. In each of these scenarios, you face the same fundamental problem: **dynamic connectivity**. You have a collection of elements (users, maze cells, variables) that start as isolated individuals. Over time, you link them together. At any moment, you need to know whether two elements belong to the same group.

This problem is deceptively simple, yet its efficient solution powers everything from network analysis to image segmentation, from Kruskal’s algorithm for minimum spanning trees to the unification algorithm in type checkers. At the heart of these systems lies a deceptively elegant data structure: the **Disjoint Set Union** (DSU), also known as the Union-Find data structure. It solves dynamic connectivity with near-constant time operations, making it one of the most beautiful and practical inventions in computer science.

But not all DSU implementations are created equal. The naive approach—Quick-Find—offers constant-time queries but linear-time unions. The straightforward Quick-Union flips the tradeoff, giving fast unions but potentially slow finds. Then there is the **Optimized Quick-Union**, refined with two powerful heuristics: **Union by Rank** and **Path Compression**. Together, these turn a simple tree-based structure into a near‑magical algorithm whose amortized time per operation is effectively constant—the inverse Ackermann function, which grows so slowly that for any practical input size it is at most 4.

In this post, we will dissect the Quick-Union DSU with these two optimizations. We’ll start by formalizing the dynamic connectivity problem, then explore naive solutions and their limitations. We’ll build up to the optimized tree-based approach, derive the time complexity intuitively and formally, and finally dive into real-world applications with code examples. By the end, you’ll understand why this data structure is a masterpiece of algorithmic design and how to wield it effectively.

---

## 1. The Dynamic Connectivity Problem

### 1.1 Formal Definition

We have a set of **n** distinct objects, initially each in its own singleton set. We support two operations:

- **union(a, b)** – merge the sets containing elements `a` and `b` (if they are already in the same set, do nothing).
- **find(a)** – return a representative element of the set containing `a` (also called the “root”). This allows us to check connectivity: `a` and `b` are connected if `find(a) == find(b)`.

The problem is to implement these operations efficiently when we have a long sequence of intermixed union and find calls.

### 1.2 Real-World Motivation

- **Social networks**: Each user is an element. When two users become friends, we union their sets. A query “are they connected?” becomes a find operation.
- **Image segmentation**: Pixels are nodes, edges represent similarity. Union adjacent pixels that are similar to form connected components.
- **Kruskal’s algorithm**: For building a minimum spanning tree, we process edges in order of weight. For each edge (u,v), if find(u) != find(v), we add the edge and union(u,v). This prevents cycles.
- **Maze generation**: Use a grid of cells. Randomly remove walls between cells if they are in different sets; union them. This creates a perfect maze without cycles.
- **Unification in type inference**: Variables in a programming language are unified when they are assigned the same type. Union-find tracks equivalence classes.

### 1.3 Why It’s Hard

The naive approach would be to maintain a list of set membership, updating all elements on each union. That takes O(n) per union. With millions of elements and edges, that’s unacceptable. We need a structure that handles both operations quickly, ideally near O(1).

---

## 2. Basic Approaches and Their Trade-offs

### 2.1 Quick-Find (Eager Approach)

**Idea**: Maintain an array `id[]` where `id[i]` is the set identifier (representative) for element `i`. Two elements are connected iff their `id` values are equal.

- **find(i)**: return `id[i]` – O(1).
- **union(i, j)**: If `id[i] != id[j]`, change all entries with value `id[i]` to `id[j]` (or vice versa). That requires scanning the entire array – O(n) per union.

**Analysis**: If we have a sequence of m operations, the worst-case time is O(m \* n) if many unions are performed. For n=1e6, a single union costs 1e6 operations. Too slow.

### 2.2 Quick-Union (Lazy Approach)

**Idea**: Represent each set as a rooted tree. Each node points to its parent. The root of a tree is the representative. The array `parent[]` stores the parent index; for a root, `parent[i] = i`.

- **find(i)**: Follow parent pointers until we reach a root. Return root.
- **union(i, j)**: Find roots of i and j. If different, set parent of one root to point to the other.

```
// Pseudo-code
int find(int i) {
    while (parent[i] != i) i = parent[i];
    return i;
}
void union(int i, int j) {
    int ri = find(i), rj = find(j);
    if (ri != rj) parent[ri] = rj;
}
```

**Time complexity**:

- find: O(tree height). In the worst case, the tree can be a long chain, giving O(n) per find.
- union: Two finds + constant link – O(tree height).

**Example worst-case**: Perform unions on (0,1), (1,2), (2,3), … (n-2, n-1). Each union makes the root of the larger tree point to the smaller tree’s root, resulting in a chain of height n-1. Then find(0) takes n steps.

Thus Quick-Union can be as bad as Quick-Find in the worst case.

### 2.3 The Need for Heuristics

Both naive approaches have linear worst-case per operation. The key insight is that we can control the tree shape. Two simple modifications can make the trees nearly flat: **union by rank** and **path compression**.

---

## 3. Union by Rank (or by Size)

### 3.1 Motivation

In the naive Quick-Union, we always attach the first root to the second. This can create tall trees. If we always attach the root of the **smaller** tree to the root of the **larger** tree, the height grows only logarithmically.

### 3.2 Definition

**Rank** is an upper bound on the height of a node’s subtree. Initially, every node has rank 0. When we union two roots, we attach the root with lower rank to the root with higher rank. If ranks are equal, we pick one arbitrarily and increase its rank by 1.

```
// Union by rank
void union(int i, int j) {
    int ri = find(i), rj = find(j);
    if (ri == rj) return;
    if (rank[ri] < rank[rj]) {
        parent[ri] = rj;
    } else if (rank[ri] > rank[rj]) {
        parent[rj] = ri;
    } else {
        parent[ri] = rj;
        rank[rj]++;   // height increases by 1
    }
}
```

### 3.3 Effect on Tree Height

**Lemma**: A tree built using union by rank has height at most log₂ n (base 2). More precisely, the height is bounded by the rank, and the rank grows only when merging two trees of equal rank. The number of nodes in a tree of rank k is at least 2^k (by induction). Thus the height is O(log n).

**Proof sketch**:

- Base: rank 0 → at least 1 node.
- When two trees of rank r are merged, the resulting tree has rank r+1 and at least 2^r + 2^r = 2^(r+1) nodes.
  Thus if a tree has n nodes, its rank ≤ floor(log₂ n). The height of any node ≤ rank of root ≤ log₂ n.

Therefore, with union by rank alone, both find and union take O(log n) time.

### 3.4 Example

Let’s trace unions on 8 elements 0..7.

Initialize: each parent[i]=i, rank[i]=0.

1. union(0,1): roots 0 and 1, ranks equal 0, attach 0->1, rank[1]=1.
2. union(2,3): root2 rank0, root3 rank0, attach2->3, rank[3]=1.
3. union(4,5): similar, attach4->5, rank[5]=1.
4. union(6,7): attach6->7, rank[7]=1.
5. union(1,3): root of 1 is 1 (rank1), root of 3 is 3 (rank1). Equal ranks, attach 1->3, rank[3]=2. Now tree rooted at 3 has height 2? Path: 0->1->3, 2->3, so height = 2. But rank[3]=2, so height <= rank.
6. union(5,7): roots 5 (rank1) and 7 (rank1) equal, attach5->7, rank[7]=2.
7. union(3,7): root3 (rank2), root7 (rank2) equal, attach3->7, rank[7]=3. Tree height = 3? Actually: deepest leaf (e.g., 0) path: 0->1->3->7, length 3, rank[7]=3. So height ≤ rank.

For n=8, log₂8=3, height is 3, matches bound.

---

## 4. Path Compression

### 4.1 Motivation

Even with union by rank, each find takes O(log n). But we can do better by making the tree flatter **as we find**. When we perform a find on a node, we traverse up to the root. Why not, during that traversal, make every node we visit point directly to the root? That way, subsequent finds on those nodes become O(1). This is **path compression**.

### 4.2 Implementation

Modify `find` to update parent pointers:

```
int find(int i) {
    if (parent[i] != i) {
        parent[i] = find(parent[i]);   // recursive path compression
    }
    return parent[i];
}
```

Or iterative version:

```
int find(int i) {
    int root = i;
    while (root != parent[root]) root = parent[root];
    // compress path
    while (i != root) {
        int next = parent[i];
        parent[i] = root;
        i = next;
    }
    return root;
}
```

### 4.3 Effect

Path compression dramatically flattens the tree. After many finds, every node on a path from a leaf to the root ends up pointing directly to the root. The tree becomes nearly flat. This does not affect the union by rank heuristic (we still use rank to decide which root attaches to which, but path compression may change tree shapes, making rank an upper bound but not exact height).

### 4.4 Example

Consider the chain 0->1->2->3->4->5 (root5). Before compression, find(0) traverses 0->1->2->3->4->5. After find(0), all nodes 0..4 point directly to 5. Next find(0) is O(1).

Now suppose we later do union(4,6) where root of 4 is 5, root of 6 is 6. If rank[5] > rank[6], we attach 6->5. The tree is still flat for many nodes.

---

## 5. Combined Heuristics: Time Complexity

### 5.1 Inverse Ackermann Function

When both union by rank (or union by size) and path compression are used, the amortized time per operation is O(α(n)), where α(n) is the inverse Ackermann function. This function grows **extremely** slowly:

- α(1) = 0
- α(2) = 1
- α(4) = 2
- α(16) = 3
- α(2^65536) = 4
- ... essentially for all practical n, α(n) ≤ 4 (since the Ackermann function grows so fast that its inverse is tiny for numbers we can write in decimal).

Thus for any conceivable input size, we can treat the amortized time as constant.

### 5.2 Formal Complexity Result

The seminal analysis by Tarjan and van Leeuwen (1975, 1979) shows that any sequence of m union and find operations on n elements takes O(m α(n)) time in the worst case, provided both heuristics are used. This is **amortized** (i.e., average per operation) but the worst-case for a single operation can be O(log n), though such isolated bad cases are extremely rare.

### 5.3 Intuitive Explanation

Why is it so fast? Path compression ensures that the first time you find a node deep in a tree, you flatten that path. After that, any node that was deep becomes shallow. Union by rank keeps trees from growing too tall between flattenings. The combination means each node’s parent pointer changes only a few times (bounded by the rank), and the total work over all finds is O(n log n) but with an even tighter bound.

The detailed proof involves a complex potential function. But in practice, the data structure behaves like constant time.

---

## 6. Implementation Details and Code

### 6.1 Data Structures

We need two arrays of length n (0-indexed):

- `parent[]` – for each element, its parent index (or itself if root).
- `rank[]` – for each element, an upper bound on height. Only meaningful for roots; for non-roots it may be outdated after path compression but we never use it.

Optionally, we could track `size[]` instead of rank (union by size). Both work.

### 6.2 Python Implementation

```
class UnionFind:
    def __init__(self, n):
        self.parent = list(range(n))
        self.rank = [0] * n

    def find(self, x):
        # Path compression
        if self.parent[x] != x:
            self.parent[x] = self.find(self.parent[x])
        return self.parent[x]

    def union(self, x, y):
        rx = self.find(x)
        ry = self.find(y)
        if rx == ry:
            return
        # Union by rank
        if self.rank[rx] < self.rank[ry]:
            self.parent[rx] = ry
        elif self.rank[rx] > self.rank[ry]:
            self.parent[ry] = rx
        else:
            self.parent[ry] = rx
            self.rank[rx] += 1

    def connected(self, x, y):
        return self.find(x) == self.find(y)
```

### 6.3 Java Implementation

```
public class UnionFind {
    private int[] parent;
    private int[] rank;

    public UnionFind(int n) {
        parent = new int[n];
        rank = new int[n];
        for (int i = 0; i < n; i++) parent[i] = i;
    }

    public int find(int i) {
        if (parent[i] != i) {
            parent[i] = find(parent[i]);
        }
        return parent[i];
    }

    public void union(int i, int j) {
        int ri = find(i), rj = find(j);
        if (ri == rj) return;
        if (rank[ri] < rank[rj]) {
            parent[ri] = rj;
        } else if (rank[ri] > rank[rj]) {
            parent[rj] = ri;
        } else {
            parent[rj] = ri;
            rank[ri]++;
        }
    }

    public boolean connected(int i, int j) {
        return find(i) == find(j);
    }
}
```

### 6.4 Alternative: Union by Size

Instead of rank, we can maintain `size[]` (number of elements in the set) and attach smaller tree to larger. This also yields O(log n) height without path compression, and O(α(n)) with path compression. The proof is similar. Many implementations prefer size because it's easier to reason about.

```
// Union by size
int[] size = new int[n]; // initially 1

void union(int i, int j) {
    int ri = find(i), rj = find(j);
    if (ri == rj) return;
    if (size[ri] < size[rj]) {
        parent[ri] = rj;
        size[rj] += size[ri];
    } else {
        parent[rj] = ri;
        size[ri] += size[rj];
    }
}
```

### 6.5 Memory Considerations

We need two arrays of length n. For very large n (like 10^9), memory could be a problem. But often we can use integer arrays (4 bytes each) → 8n bytes. For n=1e9, that's 8GB, too large for typical RAM. In such cases, we might use more memory-efficient structures or map virtual nodes. However, in practice, n is often ≤ 10^6 – 10^7.

---

## 7. Applications in Depth

### 7.1 Kruskal’s Minimum Spanning Tree

**Problem**: Given an undirected weighted graph with n nodes and m edges, find a minimum spanning tree (MST).

**Algorithm**:

1. Sort edges by weight.
2. Initialize Union-Find with n nodes.
3. For each edge (u,v,w) in sorted order:
   - If find(u) != find(v):
     - Add edge to MST.
     - union(u,v).
4. Stop when MST has n-1 edges.

**Why it works**: Union-Find ensures we only add edges that connect two different components, preventing cycles. The greedy choice of smallest weight yields optimal MST.

**Complexity**: Sorting O(m log m), DSU operations O(m α(n)). Overall O(m log m). For dense graphs, we could use Prim’s algorithm with a heap, but Kruskal’s is simpler with sparse graphs.

**Example**: Consider 4 nodes A,B,C,D with edges: AB=1, BC=2, CD=3, AD=4, AC=5. Sort edges: AB, BC, CD, AD, AC. Process:

- union(A,B) → {A,B}
- union(B,C) → {A,B,C}
- union(C,D) → {A,B,C,D}
- Now all connected; ignore remaining edges. MST weight = 1+2+3=6.

### 7.2 Number of Connected Components in a Graph

Given n nodes and m edges, we can maintain a count of components. Initially, count = n. For each edge (u,v), if union(u,v) actually merges two different sets, decrement count. At the end, count is the number of connected components.

This is used in image processing: pixels are nodes, edges between adjacent pixels if they have similar color. Then connected components represent regions.

### 7.3 Detecting Cycles in a Graph

While adding edges to a graph (e.g., building a spanning forest), if an edge connects two nodes already in the same connected component, it creates a cycle. Union-Find can detect this: if find(u) == find(v) → cycle. In Kruskal’s MST, we ignore such edges.

### 7.4 Maze Generation (Randomized Kruskal’s)

We have a grid of `r*c` cells. Each cell is a node. The walls between cells are edges. Initially all walls are present. Randomly select a wall between two cells (i,j). If they are in different sets (find(i) != find(j)), remove the wall and union(i,j). Continue until all cells are in one set (or a desired number of components). This produces a perfect maze (exactly one path between any two cells).

### 7.5 Union-Find in Image Segmentation

The **Efficient Graph-Based Image Segmentation** algorithm (Felzenszwalb and Huttenlocher) uses Union-Find to merge regions based on edge weights. It’s widely used in computer vision.

### 7.6 Unification in Programming Languages

In the type inference algorithm for languages like ML or Haskell, the unification of type variables uses a union-find structure. Each type variable starts as a separate node. When we equate two types, we union their variables. The type of a variable is stored at the root. Path compression ensures quick lookup.

### 7.7 Online Dynamic Connectivity (with Deletions)

Union-Find as described only supports union (additive) and find queries. For deletions (disconnecting sets), the problem becomes much harder and requires more complex data structures like Euler tour trees or link-cut trees. But for many applications, only unions are needed.

---

## 8. Variations and Extensions

### 8.1 Persistence (Persistent Union-Find)

Sometimes we need to query the connectivity state at different points in time. A persistent data structure allows us to union and then “go back” to a previous version. This can be done with path copying or using functional data structures (e.g., with Clojure). Complexity increases; typical implementations use O(log n) per operation.

### 8.2 Union with Extra Data (Vertex-Weighted)

Often we need to store additional information at the set root (e.g., the sum of weights, min element, max element). For example, in Kruskal’s we may need to know total weight. We can store an extra array at the root and update on union. For union by rank, we update the root’s data.

```
int[] sum = new int[n]; // initialize with node values
void union(int i, int j) {
    int ri = find(i), rj = find(j);
    if (ri == rj) return;
    if (rank[ri] < rank[rj]) {
        parent[ri] = rj;
        sum[rj] += sum[ri];
    } else { ... }
}
```

### 8.3 Union-Find for Disjoint Sets with Order (DSU with Linked Lists)

Sometimes we need to iterate over elements in a set. We can attach a linked list to each root and merge lists on union. This is used in a technique called “union-find with linked lists” for some graph algorithms.

### 8.4 Parallel and Distributed Union-Find

In multi-threaded or distributed systems, concurrent union-find is challenging. Several lock-free or wait-free algorithms exist (e.g., Anderson and Woll, 1991). They often rely on compare-and-swap for atomic pointer updates.

---

## 9. Proof Sketch of Amortized Time

We’ll outline the intuition and the potential function used in Tarjan’s proof.

### 9.1 Potential Function

Define the **rank** of a node as its height bound (like the rank we maintain in union by rank). Actually, after path compression, rank is an upper bound on the tree height, but we continue to use the original rank values (they never increase except during union on roots). Path compression does not change the rank of any node.

Define a function `f(x)` = the number of times a node’s parent changes until it becomes a direct child of a root? More formally, the potential used is the total number of nodes that have a parent with rank less than or equal to some threshold. The classic proof defines `α(n)` as the inverse of the function `A(k)` where A is the Ackermann function.

### 9.2 Key Lemma

Each time we perform a find, we traverse a path from a node to the root. Path compression reduces the depth of all nodes on that path. The total number of times a node’s parent changes (due to union or compression) is bounded by its rank plus the number of times its rank increases (which is at most log n). More precisely, the total number of “steps” (parent updates) over all operations is O(n log n) for union by rank alone, and with path compression it becomes O(n α(n)).

### 9.3 Amortized Analysis

We can charge the cost of a find operation to the nodes visited. The potential function ensures that each node can be visited only a limited number of times before its parent becomes a root. The actual complexity bound is proven via a **accounting method** or **potential method**.

A simpler way: The height of any tree is always bounded by the rank of the root, which is at most log n. Path compression reduces height, but we cannot guarantee that a single find is O(log n) worst-case (because a find could involve a deep node that hasn't been compressed). However, over a sequence of m operations, the total work is O(m α(n)).

### 9.4 Practical Note

In competitive programming or system design, we simply assume constant time. When n ≤ 10^8, the number of operations is typically ≤ 10^7, and the overhead from recursion (if recursive find) may be noticeable. Iterative find is recommended for very deep recursion stacks.

---

## 10. Common Pitfalls and Optimizations

### 10.1 Forgetting Path Compression

If you only use union by rank without path compression, each find takes O(log n). That’s still fast for many applications (log₂ 1e6 ≈ 20). But if you have many finds, the constant factor matters. Always implement path compression.

### 10.2 Incorrect Rank Update

When ranks are equal, you must increment the rank of the new root. If you forget, the rank won't reflect the actual height, and future unions may create taller trees because we incorrectly think the tree is smaller.

### 10.3 Using Rank After Path Compression

After path compression, some nodes may have rank larger than their actual subtree height. That’s okay because rank is an upper bound. But never use a non-root’s rank for decision-making.

### 10.4 Recursive vs Iterative Find

Recursive find is elegant but may cause stack overflow for very deep trees (path compression prevents deep trees, but if you have a chain before compression, recursion depth could be O(n). However, the first find will compress the path. In languages like Python, recursion depth limit is about 1000; for n > 1000, recursive find may crash. Always use iterative find in production.

### 10.5 Overhead of Two Arrays vs One

Some implementations use a single array storing `-size` for roots and parent index for non-roots. This saves memory but is less readable. For critical systems, memory may be a concern.

---

## 11. Performance Benchmarks

We can run a simple experiment: create n = 1,000,000 nodes, perform m = 10,000,000 random union/find operations and measure time.

- Naive Quick-Find: O(mn) → essentially impossible.
- Quick-Union without heuristics: O(mn) worst-case (if chain).
- Union by rank only: O(m log n) → about 10^7 \* 20 = 2e8 operations, feasible in a few seconds.
- With path compression: O(m α(n)) ≈ 10^7 \* 4 = 4e7 operations, much faster.

In practice, Python implementation with path compression can handle 1e7 ops in about 1-2 seconds (depending on hardware). Java is even faster.

---

## 12. Conclusion

The Disjoint Set Union data structure with path compression and union by rank is a shining example of how simple heuristics can transform a naive algorithm into a near-constant-time powerhouse. From social networks to compilers, from Kruskal’s MST to image segmentation, it is an indispensable tool in the computer scientist’s toolkit.

We started with the problem of dynamic connectivity, saw the flaws of Quick-Find and Quick-Union, and then refined the latter with two ideas: union by rank keeps trees shallow, path compression flattens them on the fly. The resulting amortized time is the inverse Ackermann function, effectively constant for all practical purposes.

Understanding this data structure deepens our appreciation for algorithmic elegance. It also teaches us that sometimes the best solutions are not complex but are built from simple ideas combined thoughtfully.

So next time you need to track connected components, remember the union-find. It’s one of the few data structures that are both beautiful and truly useful.

---

## Further Reading

- Robert Sedgewick and Kevin Wayne, _Algorithms_, 4th Ed., Chapter 1.5 – “Case Study: Union-Find”.
- Thomas H. Cormen et al., _Introduction to Algorithms_, 3rd Ed., Chapter 21 – “Data Structures for Disjoint Sets”.
- Robert E. Tarjan, “Efficiency of a Good But Not Linear Set Union Algorithm”, _J. ACM_, 1975.
- John E. Hopcroft and Jeffrey D. Ullman, “Set Merging Algorithms”, _SIAM J. Comput._, 1973.

---

_This blog post was written as a deep dive into the Quick-Union DSU with optimizations. Feel free to share and leave comments. Happy coding!_
