---
title: "Network Flow: From Ford-Fulkerson to Push-Relabel and the Max-Flow Min-Cut Theorem"
description: "A rigorous journey through the algorithms that solve maximum flow—Ford-Fulkerson, Edmonds-Karp, Dinic, and Push-Relabel—together with the duality that binds flows to cuts."
date: "2019-04-13"
author: "Leonardo Benicio"
tags: ["network-flow", "ford-fulkerson", "edmonds-karp", "dinic", "push-relabel", "max-flow-min-cut", "algorithms"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/network-flow-ford-fulkerson-push-relabel.png"
coverAlt: "A directed graph with capacities on edges and flow values, illustrating the max-flow problem with source and sink highlighted"
---

The maximum flow problem asks a question of deceptive simplicity: given a network of pipes with capacities, how much fluid can you push from a source to a sink? The question, stripped of metaphor, concerns directed graphs with capacities on edges, and the answer—the maximum flow—is an integer equal to the minimum capacity of any cut separating source from sink. This duality, the max-flow min-cut theorem, is one of the crown jewels of combinatorial optimization, discovered by Ford and Fulkerson in 1956 and independently by Elias, Feinstein, and Shannon the same year. The algorithms that compute maximum flows—augmenting-path methods, capacity-scaling approaches, and the preflow-push paradigm—constitute a microcosm of algorithm design, touching graph theory, linear programming duality, and data structures.

This post is a deep traversal of the network flow landscape. We begin with the Ford-Fulkerson framework and the max-flow min-cut theorem that justifies it, proceed through the polynomial-time refinements of Edmonds-Karp and Dinic, and culminate with the push-relabel family of Goldberg and Tarjan, which achieves the best known theoretical bounds. Throughout, we maintain an algorithmic focus: how each method constructs and improves flow, why its running time is what it is, and what data structures make it fast in practice.

<h2>1. The Maximum Flow Problem: Definitions and Foundations</h2>

A flow network is a directed graph \(G = (V, E)\) with a source \(s \in V\), a sink \(t \in V\) (\(s \neq t\)), and a non-negative capacity function \(c: E \to \mathbb{R}\_{\geq 0}\). A flow is a function \(f: E \to \mathbb{R}\) satisfying:

1. **Capacity constraints:** \(0 \leq f(e) \leq c(e)\) for all \(e \in E\).
2. **Flow conservation:** For every vertex \(v \notin \{s, t\}\), \(\sum*{(u,v) \in E} f(u, v) = \sum*{(v, w) \in E} f(v, w)\).

The value of a flow, denoted \(|f|\), is the net flow leaving the source: \(|f| = \sum*{(s, v) \in E} f(s, v) - \sum*{(v, s) \in E} f(v, s)\). By flow conservation, this equals the net flow entering the sink. The maximum flow problem asks for a flow of maximum value.

A cut is a partition of the vertices into two sets \((S, T)\) with \(s \in S\) and \(t \in T\). The capacity of the cut is the sum of capacities of edges crossing from \(S\) to \(T\): \(c(S, T) = \sum*{u \in S, v \in T, (u,v) \in E} c(u, v)\). The net flow across the cut is \(f(S, T) = \sum*{u \in S, v \in T} f(u, v) - \sum\_{v \in T, u \in S} f(v, u)\). A fundamental lemma: for any flow \(f\) and any cut \((S, T)\), \(|f| = f(S, T) \leq c(S, T)\). That is, the value of any flow is bounded above by the capacity of any cut.

<h2>2. The Max-Flow Min-Cut Theorem</h2>

The max-flow min-cut theorem states that the maximum value of a flow equals the minimum capacity of a cut separating \(s\) from \(t\):

\[
\max*{f \text{ is a flow}} |f| = \min*{(S, T) \text{ is an s-t cut}} c(S, T)
\]

The proof is constructive and provides the foundation for the Ford-Fulkerson algorithm. The key concept is the residual network. Given a flow \(f\), the residual capacity of an edge \((u, v)\) is \(c_f(u, v) = c(u, v) - f(u, v)\). Additionally, we allow "undoing" flow by introducing a reverse edge \((v, u)\) with residual capacity \(c_f(v, u) = f(u, v)\). The residual network \(G_f\) consists of all edges with positive residual capacity.

An augmenting path is a simple path from \(s\) to \(t\) in \(G*f\). Given an augmenting path \(P\), let the bottleneck capacity \(\delta = \min*{e \in P} c_f(e)\). We augment flow along \(P\) by pushing \(\delta\) units: for each forward edge \((u, v)\) on \(P\), increase \(f(u, v)\) by \(\delta\); for each reverse edge \((v, u)\) on \(P\) (corresponding to a forward edge \((u, v)\) in the original graph), decrease \(f(u, v)\) by \(\delta\). This operation preserves capacity constraints and flow conservation and increases the flow value by \(\delta\).

The Ford-Fulkerson algorithm repeatedly finds an augmenting path and augments flow until no such path exists. The max-flow min-cut theorem follows: when the algorithm terminates, let \(S\) be the set of vertices reachable from \(s\) in \(G_f\). Since no augmenting path exists, \(t \notin S\). Every edge from \(S\) to \(T = V \setminus S\) in the original network is saturated (\(f(u, v) = c(u, v)\)), and every edge from \(T\) to \(S\) carries zero flow. Therefore, \(|f| = f(S, T) = c(S, T)\), proving optimality.

<h2>3. The Ford-Fulkerson Algorithm and Its Pathologies</h2>

The Ford-Fulkerson method, as described, is not a fully specified algorithm because it does not prescribe how to choose augmenting paths. With arbitrary choices and irrational capacities, the algorithm can fail to terminate, converging to a suboptimal flow value. Even with integer capacities, a poor choice of augmenting paths can lead to exponentially many augmentations.

Consider the classic bad example: a network with four vertices where capacities are large integers. If the algorithm alternately augments along paths of length three, each augmentation adds only one unit of flow, requiring \(2C\) augmentations for a maximum flow of \(2C\), where \(C\) is the large capacity. Since \(C\) is exponential in the input size (its binary representation has \(\log C\) bits), the algorithm runs in exponential time.

```
Bad Example for Ford-Fulkerson (C = 10^9):

       (C)        (C)
    s -----> u -----> t
    |         ^        |
    | (C)     | (1)    | (C)
    v         |        v
    s -----> v -----> t
       (C)        (C)

With the wrong pivot choices, flow increases by 1 per augmentation.
```

Despite these pathologies, the Ford-Fulkerson framework is historically and pedagogically important. It establishes the residual network and augmenting-path concepts that every subsequent algorithm builds upon. The integer capacity case is especially clean: if all capacities are integers, the algorithm terminates with an integer maximum flow after at most \(|f^_|\) augmentations, where \(|f^_|\) is the maximum flow value. This is pseudopolynomial but not polynomial.

<h2>4. Edmonds-Karp: Shortest Augmenting Paths</h2>

Edmonds and Karp showed in 1972 that choosing the shortest augmenting path—shortest in terms of number of edges—guarantees polynomial running time. Specifically, using breadth-first search to find a shortest path in \(G_f\), the algorithm runs in \(O(|V| \cdot |E|^2)\) time.

The analysis is elegant. Let \(\delta_f(v)\) denote the shortest-path distance (in edges) from \(s\) to \(v\) in \(G_f\). A key lemma: \(\delta_f(v)\) is non-decreasing over the course of the algorithm. When we augment along a shortest path, we saturate at least one edge (reduce its residual capacity to zero). This edge may reappear later, but only when flow is pushed in the opposite direction, which requires the distance to its tail to have increased. Each edge can be saturated at most \(O(|V|)\) times, and there are \(O(|E|)\) edges, yielding \(O(|V| \cdot |E|)\) augmentations. Each BFS takes \(O(|E|)\) time, giving the \(O(|V| \cdot |E|^2)\) bound.

```
Algorithm: Edmonds-Karp

Input:  Graph G = (V,E), capacities c, source s, sink t
Output: Maximum flow f

1.  Initialize f(e) = 0 for all e in E
2.  While true:
3.      Construct residual graph G_f
4.      Run BFS from s in G_f to find shortest path P to t
5.      If no path exists: break
6.      delta = min { c_f(e) : e in P }
7.      For each edge e in P:
8.          Augment f along e by delta
9.  Return f
```

A tighter analysis yields \(O(|V|^2 \cdot |E|)\). In practice, Edmonds-Karp is reliable and easy to implement. The BFS guarantees that the number of augmentations is bounded by \(O(|V| \cdot |E|)\), which for sparse graphs is \(O(|V|^3)\). For dense graphs, Dinic's algorithm, which we turn to next, offers improvements.

<h2>5. Dinic's Algorithm: Blocking Flows and Layered Networks</h2>

Yefim Dinic published his algorithm in 1970, two years before Edmonds-Karp, but it was not widely known in the West until later. Dinic's key innovation is the concept of a blocking flow: a flow that saturates at least one edge on every path from \(s\) to \(t\) in the layered (level) graph. The layered graph \(L_f\) is constructed from \(G_f\) by retaining only edges \((u, v)\) where \(\delta_f(v) = \delta_f(u) + 1\). This graph is a DAG; all shortest paths from \(s\) to \(t\) in \(G_f\) are paths in \(L_f\).

Dinic's algorithm proceeds in phases. In each phase:

1. Construct the layered graph \(L_f\) via BFS from \(s\) in \(G_f\). If \(t\) is not reachable, terminate.
2. Find a blocking flow in \(L_f\).
3. Augment \(f\) by the blocking flow.

The crucial observation: after augmenting a blocking flow, the distance \(\delta_f(t)\) strictly increases. Since distances are bounded by \(|V| - 1\), there are at most \(|V|\) phases. The challenge is finding a blocking flow efficiently.

Dinic's original method for finding a blocking flow uses depth-first search with backtracking. Starting from \(s\), recursively explore forward edges in the layered graph, pushing as much flow as possible. When reaching \(t\) or a dead end, backtrack and prune saturated edges. Each edge is explored at most once per phase, yielding \(O(|V| \cdot |E|)\) per phase if implemented carefully with adjacency lists. Total time: \(O(|V|^2 \cdot |E|)\).

```
Algorithm: Dinic's Max Flow

Input:  G = (V,E), c, s, t
Output: Maximum flow f

1.  f(e) = 0 for all e
2.  While true:
3.      Construct level graph L from s via BFS in G_f
4.      If t not reachable: break
5.      Find blocking flow in L:
6.          Initialize pointer ptr[v] = first edge of v in L
7.          Function DFS(v, flow_in):
8.              If v == t: return flow_in
9.              For each edge e from ptr[v]:
10.                 If c_f(e) > 0 and level[u] == level[v] + 1:
11.                     pushed = DFS(u, min(flow_in, c_f(e)))
12.                     If pushed > 0:
13.                         Augment f along e by pushed
14.                         Return pushed
15.                 ptr[v] = next edge
16.             Return 0
17.         While DFS(s, INF) > 0:  // no-op, loop body is in DFS
18. Return f
```

The "pointer" advancement (often called the "current edge" optimization) ensures each edge is considered at most once per DFS in a phase, giving the \(O(|V| \cdot |E|)\) per phase bound. With at most \(|V|\) phases, Dinic's algorithm runs in \(O(|V|^2 \cdot |E|)\). For unit-capacity networks, the bound improves to \(O(\min\{|V|^{2/3}, |E|^{1/2}\} \cdot |E|)\), making Dinic particularly effective for bipartite matching and related problems.

<h2>6. The Push-Relabel Framework: Preflows and Height Functions</h2>

Goldberg and Tarjan introduced the push-relabel algorithm in 1986, departing fundamentally from the augmenting-path paradigm. Instead of maintaining a feasible flow throughout, push-relabel maintains a preflow, which relaxes flow conservation by allowing vertices (other than \(s\) and \(t\)) to have excess: inflow may temporarily exceed outflow. The algorithm pushes excess flow toward the sink, guided by a height function (or distance labeling) that provides a lower bound on the distance to \(t\) in the residual graph.

A preflow satisfies capacity constraints and a relaxed conservation: for \(v \notin \{s, t\}\), the excess \(e(v) = \sum*{(u,v) \in E} f(u,v) - \sum*{(v,w) \in E} f(v,w) \geq 0\). The algorithm starts by saturating all edges out of \(s\): \(f(s, v) = c(s, v)\) for all \((s, v) \in E\). This creates excess at the neighbors of \(s\).

A height function \(h: V \to \mathbb{N}\) satisfies \(h(s) = |V|\), \(h(t) = 0\), and for every residual edge \((u, v) \in E_f\), \(h(u) \leq h(v) + 1\). The intuition is geometric: flow can only be pushed "downhill"—from a vertex with higher height to one with lower height—along residual edges. When a vertex with excess has no downhill residual edges, its height is increased (relabeled) to one more than the minimum height of its residual neighbors, creating new downhill opportunities.

The two basic operations:

- **Push:** If \(e(u) > 0\) and there exists a residual edge \((u, v)\) with \(c_f(u, v) > 0\) and \(h(u) = h(v) + 1\), push \(\delta = \min\{e(u), c_f(u, v)\}\) units from \(u\) to \(v\).
- **Relabel:** If \(e(u) > 0\) and for all residual edges \((u, v)\), \(h(u) \leq h(v)\), set \(h(u) = 1 + \min\{h(v) : (u, v) \in E_f\}\).

The algorithm repeatedly applies push and relabel operations until no vertex except \(s\) and \(t\) has positive excess. At that point, the preflow is a feasible flow, and the max-flow min-cut theorem guarantees its optimality.

<h2>7. Correctness and Complexity of Push-Relabel</h2>

The correctness argument rests on two invariants: (1) the height function remains valid throughout, and (2) no path from \(s\) to \(t\) exists in the residual graph of a maximum preflow (a preflow where no push or relabel is possible). When the algorithm terminates, \(e(v) = 0\) for all \(v \notin \{s, t\}\), making the preflow a flow. If there were an augmenting path, the height function would imply \(h(s) \leq h(t) + |V| - 1\), but \(h(s) = |V|\) and \(h(t) = 0\), giving \(|V| \leq |V| - 1\), a contradiction.

The generic push-relabel algorithm runs in \(O(|V|^2 \cdot |E|)\) time. Each relabel increases a vertex's height; heights are bounded by \(2|V| - 1\), so there are \(O(|V|^2)\) relabels total. Pushes are classified as saturating (sending \(c_f(u, v)\) units, saturating the edge) or non-saturating (sending less). The number of saturating pushes is \(O(|V| \cdot |E|)\). The number of non-saturating pushes depends on the order of operations; with FIFO or highest-label selection, it is \(O(|V|^3)\) or \(O(|V|^2 \cdot |E|^{1/2})\), respectively.

The **relabel-to-front** heuristic (Goldberg and Tarjan) maintains a list of vertices and repeatedly discharges each vertex by pushing and relabeling until its excess is zero, moving it to the front of the list after relabeling. This yields \(O(|V|^3)\) time, independent of \(|E|\) for dense graphs. The **highest-label** variant, which always pushes from the highest active vertex, achieves \(O(|V|^2 \cdot |E|^{1/2})\)—the best known bound for unit-capacity networks.

<h2>8. FIFO Push-Relabel and Gap Heuristics</h2>

The FIFO variant processes active vertices in a queue, discharging each completely before moving to the next. When a vertex is relabeled, it moves to the back of the queue. This seemingly simple strategy bounds non-saturating pushes to \(O(|V|^3)\), yielding total time \(O(|V|^3)\).

The **gap heuristic** dramatically improves practical performance. If there is a "gap" in the height function—some integer \(k\) such that no vertex has height \(k\), but there are vertices with height greater than \(k\)—then those tall vertices cannot send flow to the sink (since \(h(t) = 0\) and heights decrease by at most one per residual edge). The gap heuristic detects such gaps and immediately sets the height of all vertices above the gap to \(|V| + 1\), effectively making them unreachable from \(s\). This prunes the search space and often yields near-linear performance in practice.

```
Algorithm: FIFO Push-Relabel with Gap Heuristic

1.  Initialize preflow: saturate edges from s
2.  Initialize heights: h[s] = |V|; h[v] = 0 for v != s
3.  BFS from t to set initial heights (global relabeling)
4.  Initialize queue Q with active vertices (e(v) > 0, v != s, t)
5.  While Q not empty:
6.      u = Q.front(); Q.pop()
7.      old_height = h[u]
8.      Discharge(u): while e(u) > 0:
9.          For each edge (u,v) in residual graph:
10.             If h[u] == h[v] + 1 and c_f(u,v) > 0:
11.                 Push(u, v)
12.                 If v becomes active: Q.push(v)
13.                 If e(u) == 0: break
14.         If e(u) > 0: Relabel(u)
15.     If h[u] > old_height: Q.push(u)
16.     Check gap heuristic
```

Global relabeling—periodically recomputing exact distances from \(t\) using a backwards BFS—resets heights to their exact values, reducing the number of relabel operations. In competitive programming and many practical applications, global relabeling every \(O(|V|)\) discharges reduces the constant factors dramatically.

<h2>9. Scaling Algorithms and Capacity Scaling</h2>

Capacity scaling, introduced by Edmonds and Karp and refined by Ahuja, Orlin, and others, augments flow in "large" chunks before refining with smaller ones. The idea: maintain a scaling parameter \(\Delta\), initially the largest power of two not exceeding the maximum capacity. In each scaling phase, consider only edges with residual capacity at least \(\Delta\). Augment flow until no such paths exist, then halve \(\Delta\) and repeat.

The advantage: each scaling phase adds at most \(|E|\) augmentations (because each augmentation carries at least \(\Delta\) flow, and the total flow to add in a phase is bounded). With \(\log C\) phases (where \(C\) is the max capacity), this yields \(O(|E| \log C)\) augmentations, each found by BFS in \(O(|E|)\) time, for \(O(|E|^2 \log C)\) total. Combined with Dinic's blocking flow within each phase, the bound becomes \(O(|V| \cdot |E| \log C)\).

Capacity scaling bridges the pseudopolynomial Ford-Fulkerson (dependence on \(|f^_|\)) to weakly polynomial algorithms (dependence on \(\log C\)). The distinction matters: \(|f^_|\) can be exponential in the input size, while \(\log C\) is polynomial. Weakly polynomial algorithms are genuine polynomial-time algorithms in the bit model.

<h2>10. Strongly Polynomial Algorithms: The Minimum-Mean-Cycle Approach</h2>

An algorithm is strongly polynomial if its running time depends only on \(|V|\) and \(|E|\), not on the numeric values of capacities. For maximum flow, the first strongly polynomial algorithm was given by Tardos in 1985, running in \(O(|V|^4 \cdot |E|)\). Goldberg and Tarjan's minimum-mean-cycle cancelling algorithm for minimum-cost flow implies an \(O(|V|^2 \cdot |E| \log |V|)\) algorithm for maximum flow.

The core of strongly polynomial methods for max flow involves the concept of "tight" edges and contracts. The algorithm by King, Rao, and Tarjan (1994) achieves \(O(|V| \cdot |E| \log\_{|E|/(|V| \log |V|)} |V|)\) time—essentially \(O(|V| \cdot |E|)\) for all practical purposes, though with a log factor that theories care about. More recently, Orlin (2013) achieved \(O(|V| \cdot |E|)\) strongly polynomial time, matching the long-standing barrier.

The theoretical pursuit of faster max-flow algorithms continues. Mądry (2013), Lee and Sidford (2014), and subsequent work using electrical flows and interior-point methods have achieved \(\tilde{O}(|E| \cdot \sqrt{|V|})\) or even \(\tilde{O}(|E| + |V|^{1.5})\) for certain regimes. These algorithms use continuous optimization techniques—Laplacian solvers and gradient descent in the space of flows—representing a fascinating convergence of combinatorial and continuous optimization. However, the simpler algorithms (Dinic, push-relabel) remain the workhorses of practice due to their low constant factors.

<h2>11. Applications: Bipartite Matching and Vertex Cover</h2>

The reduction from maximum bipartite matching to maximum flow is a canonical example of algorithmic modeling. Given a bipartite graph \(G = (L \cup R, E)\), construct a flow network: direct edges from \(L\) to \(R\) with capacity 1; add a super-source \(s\) connected to every vertex in \(L\) with capacity 1; add a super-sink \(t\) connected from every vertex in \(R\) with capacity 1. An integer flow in this network corresponds to a matching: flow on an edge \((u \in L, v \in R)\) indicates that \(u\) and \(v\) are matched.

Dinic's algorithm on this unit-capacity network finds a maximum matching in \(O(|E| \cdot \sqrt{|V|})\) time—a substantial improvement over the \(O(|V| \cdot |E|)\) bound for general networks. The analysis exploits the unit-capacity property: each phase of Dinic processes a layered graph where all edges have unit capacity, so a blocking flow can be found in \(O(|E|)\) time per phase, and the number of phases is \(O(\sqrt{|V|})\).

A deeper result is König's theorem: in a bipartite graph, the size of a maximum matching equals the size of a minimum vertex cover. This is a special case of the max-flow min-cut theorem. Applied to the flow network, a minimum \(s\)-\(t\) cut corresponds to a vertex cover: include vertices on the \(L\)-side disconnected from \(s\) after the cut, and vertices on the \(R\)-side still reachable from \(s\). The cut capacity equals the number of such vertices, providing a constructive proof of König's theorem via maximum flow.

<h2>12. Edge-Disjoint Paths and Menger's Theorem</h2>

Menger's theorem (1927) states that the maximum number of edge-disjoint paths from \(s\) to \(t\) equals the minimum number of edges whose removal disconnects \(s\) from \(t\). This is a direct corollary of the max-flow min-cut theorem when all capacities are unit. Each unit of flow can be decomposed into a simple path (since capacities are integers and flow conservation holds), and edge-disjointness follows from the capacity constraints.

The relationship extends to vertex-disjoint paths via a standard transformation: split each vertex \(v\) into \(v*{in}\) and \(v*{out}\) connected by an edge of capacity 1; redirect incoming edges to \(v*{in}\) and outgoing edges from \(v*{out}\). A flow in this transformed network yields vertex-disjoint paths in the original graph. The vertex-disjoint version of Menger's theorem follows.

These connections bridge network flow to graph connectivity, which is foundational in network reliability and fault-tolerant design. Computing the edge connectivity of a graph—the minimum number of edges whose removal disconnects the graph—reduces to \(|V| - 1\) max-flow computations (one per potential source, fixing an arbitrary sink). For global min-cut, the Karger-Stein randomized algorithm is asymptotically faster, but flow-based methods remain competitive for moderate-sized graphs.

<h2>13. Minimum-Cost Flow and the Cycle-Cancelling Algorithm</h2>

When edges carry both capacities and per-unit costs, we enter the realm of minimum-cost flow. The goal: among all flows of a given value \(F\), find one minimizing \(\sum\_{e \in E} cost(e) \cdot f(e)\). Equivalently, given a supply-demand vector \(b(v)\) (with \(\sum_v b(v) = 0\)), find a flow satisfying capacity constraints and flow conservation with demands (i.e., net outflow at \(v\) equals \(b(v)\)) at minimum cost.

The residual network for minimum-cost flow includes edges with negative costs (corresponding to undoing flow on an edge with positive cost). A flow is optimal if and only if the residual network contains no negative-cost cycles. The cycle-cancelling algorithm starts with any feasible flow (found via max flow) and repeatedly finds a negative-cost cycle in the residual network, augmenting flow around it until no such cycle exists.

The challenge is finding negative cycles efficiently. The Bellman-Ford algorithm detects negative cycles in \(O(|V| \cdot |E|)\) time. Successive shortest augmenting path algorithms maintain optimality by always augmenting along cheapest paths, using potentials (reduced costs) and Dijkstra's algorithm. The cost-scaling approach, due to Goldberg and Tarjan, achieves polynomial bounds by scaling costs rather than capacities.

<h2>14. The Successive Shortest Path Algorithm and Potentials</h2>

Given a flow network with costs, suppose we maintain a potential function \(\pi: V \to \mathbb{R}\) and define reduced costs \(c^\pi(u, v) = c(u, v) + \pi(u) - \pi(v)\). A fundamental property: for any path from \(s\) to \(t\), the reduced cost equals the actual cost plus \(\pi(s) - \pi(t)\). Thus, a shortest path with respect to actual costs is also a shortest path with respect to reduced costs (and vice versa), since the potential difference telescopes.

If we set \(\pi(v)\) to be the shortest-path distance from \(s\) to \(v\) in the residual network (with respect to original costs), then all reduced costs become non-negative (by the triangle inequality). This is Johnson's trick from all-pairs shortest paths, applied dynamically. With non-negative reduced costs, Dijkstra's algorithm (rather than Bellman-Ford) finds shortest augmenting paths, yielding a practical \(O(|f^_| \cdot |E| \log |V|)\) algorithm for minimum-cost flow, where \(|f^_|\) is the required flow value.

The successive shortest path algorithm is pseudopolynomial, but capacity scaling can make it weakly polynomial. The idea: scale both capacities and costs, solving a sequence of problems at increasing precision. At each scale, the current flow is nearly optimal for the current precision, and only small adjustments are needed.

<h2>15. Circulation Problems and Lower Bounds</h2>

A circulation is a flow where every vertex satisfies conservation (no source or sink). Given lower bounds \(l(e)\) and upper bounds \(c(e)\) on each edge, a feasible circulation satisfies \(l(e) \leq f(e) \leq c(e)\) and flow conservation at all vertices. Feasibility is not guaranteed; it requires that for every cut, the sum of lower bounds on forward edges does not exceed the sum of capacities on backward edges (a generalization of Hall's marriage theorem).

The reduction from circulations with lower bounds to standard max flow is elegant: transform the network by subtracting lower bounds from capacities, adding a super-source and super-sink to handle the supply/demand imbalance created by the lower bounds. Feasibility of the original circulation is equivalent to the existence of a saturating flow in the transformed network. This reduction extends the applicability of max-flow algorithms to a much broader class of problems, including scheduling with release times and deadlines, transportation problems, and resource allocation with minimum commitments.

<h2>16. Flow Decomposition and Path Extraction</h2>

Any feasible flow can be decomposed into a set of paths from source to sink and cycles. This decomposition is not unique but is guaranteed to exist with at most \(|E|\) paths and cycles. The decomposition algorithm traces flow from \(s\) along edges with positive flow, following outgoing edges until reaching \(t\) (forming an \(s\)-\(t\) path) or returning to a previously visited vertex (forming a cycle). It subtracts the bottleneck flow along the path or cycle and repeats.

Flow decomposition connects the algebraic view of flow (a vector in \(\mathbb{R}^{|E|}\) satisfying linear constraints) to the combinatorial view (a collection of paths). It is essential for applications like network tomography (inferring traffic matrices from link measurements), where the path-level view matters. It also underlies the proof that integer capacities yield integer optimal flows: the decomposition algorithm maintains integrality if the initial flow is integral.

The decomposition also reveals the connection to the flow polytope. The set of feasible flows is a convex polytope defined by linear constraints (capacity bounds and conservation equations). Its extreme points correspond to flows that are "acyclic" in a certain sense—they cannot be expressed as a convex combination of other flows. Flow decomposition shows that extreme points are essentially path-decomposable flows, connecting linear programming theory to combinatorial flow algorithms.

<h2>17. Multicommodity Flow and Concurrent Flow</h2>

When multiple commodities compete for the same network capacity, the problem becomes multicommodity flow. Given \(k\) source-sink pairs \((s_i, t_i)\) with demands \(d_i\), we ask: can we route \(d_i\) units of flow for each commodity simultaneously without violating edge capacities? Or, more generally, what is the maximum fraction of all demands that can be satisfied?

Unlike single-commodity flow, multicommodity flow with integrality constraints is NP-complete (even for two commodities in undirected graphs). The fractional version is a linear program and solvable in polynomial time. The max-flow min-cut theorem does not generalize: the maximum concurrent flow can be strictly less than the "sparsest cut" (minimum capacity-to-demand ratio of a cut), with the gap being as large as \(\Omega(\log k)\) in general undirected graphs. This gap is the topic of the celebrated Leighton-Rao theorem and the more general Arora-Rao-Vazirani bound of \(O(\sqrt{\log k})\).

Multicommodity flow algorithms use Lagrangian relaxation and the multiplicative weights update method. The Garg-Könemann framework (1998) provides a simple primal-dual approximation scheme: start with zero flow and edge weights (lengths) inversely proportional to residual capacity, repeatedly route each commodity along a shortest path with respect to current lengths, and update lengths multiplicatively. This yields a \((1 - \epsilon)\)-approximation in \(\tilde{O}(k \cdot |E|^2 / \epsilon^2)\) iterations, a substantial improvement over general-purpose LP solvers for large networks.

<h2>18. Network Flow in Practice: Implementation and Optimization</h2>

Implementing network flow algorithms efficiently requires careful attention to data structures. The adjacency list representation is standard: for each vertex, maintain a list of outgoing edges, where each edge stores its target, capacity, flow, and a pointer to the reverse edge. The reverse edge pointer is crucial for residual network operations—when augmenting flow, we must update both the forward and reverse residual capacities.

For Dinic's algorithm, the current-edge pointer optimization is essential. A typical competitive-programming implementation stores edges in a global array and uses indices instead of pointers:

```
struct Edge {
    int to, rev;  // rev = index of reverse edge
    long long cap;
};
vector<Edge> graph[MAXN];

void add_edge(int u, int v, long long cap) {
    graph[u].push_back({v, (int)graph[v].size(), cap});
    graph[v].push_back({u, (int)graph[u].size() - 1, 0});
}
```

The `rev` field allows \(O(1)\) access to the reverse edge during augmentation. The BFS for level construction uses a simple queue; the DFS for blocking flow is iterative or recursive with short-circuiting.

For push-relabel, the practical champion is the highest-label selection with global relabeling. The "active" vertices are maintained in a bucket array indexed by height, allowing \(O(1)\) selection of the highest active vertex. The displacement structure—moving vertices between buckets as heights change—resembles a priority queue specialized for the height domain.

Empirically, Dinic outperforms push-relabel on unit-capacity networks (matching, connectivity), while push-relabel with heuristics excels on networks with large, varied capacities. The HiPr (highest-label push-relabel) implementation used in the DIMACS implementation challenge typically runs within a factor of 2-3 of the best algorithm for any given instance class.

<h2>19. Connections to Linear Programming and Duality</h2>

The maximum flow problem is a linear program:

\[
\text{maximize} \quad \sum*{(s,v) \in E} f(s,v) - \sum*{(v,s) \in E} f(v,s)
\]
\[
\text{subject to} \quad 0 \leq f(u,v) \leq c(u,v) \quad \forall (u,v) \in E
\]
\[
\sum*{(u,v) \in E} f(u,v) - \sum*{(v,w) \in E} f(v,w) = 0 \quad \forall v \notin \{s, t\}
\]

The dual linear program is the minimum cut problem: assign a potential \(y*v \in \{0, 1\}\) to each vertex (with \(y_s = 1, y_t = 0\)), and for each edge \((u,v)\), pay the capacity \(c(u,v)\) if \(y_u = 1\) and \(y_v = 0\). The dual objective \(\sum*{(u,v) \in E} c(u,v) \cdot \max\{0, y_u - y_v\}\) is the cut capacity. Strong LP duality gives the max-flow min-cut theorem.

This LP perspective generalizes: minimum-cost flow is also an LP, and its dual involves node potentials (prices). The complementary slackness conditions for the min-cost flow LP characterize optimality: a flow is optimal iff there exist potentials \(\pi\) such that reduced costs are non-negative on all residual edges and zero on edges carrying positive flow. This is the key insight behind the successive shortest path algorithm and the primal-dual method for min-cost flow.

The simplex method for LP, when specialized to network flow, becomes the network simplex algorithm—one of the fastest practical methods for min-cost flow. Network simplex exploits the fact that bases correspond to spanning trees, and pivoting involves adding an edge to the tree (creating a cycle) and removing another edge (breaking the cycle). The operations are purely combinatorial, avoiding the numerical linear algebra of general simplex.

<h2>20. Summary</h2>

Network flow is a marvel of theoretical computer science: a problem whose optimal solution is characterized by a min-max theorem, solvable by a family of algorithms spanning augmenting paths, blocking flows, preflow-push, and interior-point methods, and applicable to matching, connectivity, scheduling, transportation, and beyond. The max-flow min-cut theorem provides the unifying duality. Ford and Fulkerson gave us the framework; Edmonds and Karp made it polynomial; Dinic added blocking flows; Goldberg and Tarjan revolutionized it with push-relabel; and the modern era brings electrical flows and nearly-linear-time algorithms.

The study of network flow teaches a deeper lesson about algorithm design: the same problem can be solved in radically different ways, each exploiting a different facet of its structure. The augmenting-path approach exploits the residual network; the blocking-flow approach exploits layering; the push-relabel approach exploits local operations guided by global heights. Understanding the connections between these approaches—and the dual perspective of cuts—enriches one's algorithmic intuition far beyond the specific problem of moving fluid through pipes.

The essential references begin with Ford and Fulkerson's "Flows in Networks" (1962), the foundational text. Ahuja, Magnanti, and Orlin's "Network Flows: Theory, Algorithms, and Applications" (1993) is the comprehensive reference. For the algorithmic details, Cormen et al. and Kleinberg and Tardos provide excellent treatments. The push-relabel algorithm is best understood from Goldberg and Tarjan's original 1988 JACM paper. For modern developments, the survey by Mądry on electrical flows is eye-opening. The reader seeking to master network flow should implement each algorithm, run it on the DIMACS benchmark instances, and develop an intuition for which algorithm works best on which graph family.
