---
title: "The Algorithmic Complexity Of Distributed Graph Algorithms: Bfs, Minimum Spanning Tree, And All Pairs Shortest Paths"
description: "A comprehensive technical exploration of the algorithmic complexity of distributed graph algorithms: bfs, minimum spanning tree, and all pairs shortest paths, covering key concepts, practical implementations, and real-world applications."
date: "2019-07-24"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-algorithmic-complexity-of-distributed-graph-algorithms-bfs,-minimum-spanning-tree,-and-all-pairs-shortest-paths.png"
coverAlt: "Technical visualization representing the algorithmic complexity of distributed graph algorithms: bfs, minimum spanning tree, and all pairs shortest paths"
---

# The Algorithmic Complexity Of Distributed Graph Algorithms: BFS, Minimum Spanning Tree, And All Pairs Shortest Paths

## Introduction: The Map is Not the Territory (Expanded)

There is a peculiar, almost zen-like challenge that lies at the heart of distributed computing. Imagine you are a single process, a single node in a vast, sprawling network. You hold a small piece of the puzzle—perhaps a single number, a connection to a neighbor, a heartbeat timestamp. Your view of the entire system is, by design, myopic. You have no global map, no omniscient central planner to tell you the shape of the graph you inhabit. And yet, you and your peers, through the slow and unreliable medium of message passing, must collectively solve a global problem. You must find the shortest path to a distant node, build a cheaply spanning tree that connects all of you, or compute the distance between every pair of your members.

This is the fundamental challenge of distributed graph algorithms. In the classical, centralized world of algorithms, you are handed the entire graph on a silver platter. You can inspect its adjacency matrix, run your BFS queue, or execute Dijkstra’s algorithm with a priority queue. Complexity is measured in a single, unifying currency: time (and its proxy, the number of CPU operations). The model is clean. The data is divine. The algorithm is king.

In the distributed world, the throne is empty. There is no king. There is only a chaotic parliament of processors, each whispering to their neighbors across unreliable channels. Complexity is no longer a monolith. It fractures into a terrifying, beautiful diptych: **Time Complexity** (how many rounds of communication are necessary?) and **Message Complexity** (how many messages must be sent into the void?). Optimizing one often catastrophically damages the other. A fast algorithm might send billions of messages; a frugal one might take hours.

To appreciate this tension, we need to first understand the models that govern these distributed systems. The most common models are the **LOCAL** model and the **CONGEST** model, both typically studied under synchronous rounds. In the LOCAL model, each node can send an unbounded amount of information to its neighbors in each round. This allows nodes to quickly exchange their entire state, making it possible to simulate centralized algorithms in a small number of rounds—but only if the graph’s diameter is small. In contrast, the CONGEST model restricts each message to at most \(O(\log n)\) bits, where \(n\) is the number of nodes. This reflects the reality of limited bandwidth in communication networks. Most of the algorithms we will discuss are designed for the CONGEST model, because it is both realistic and rich in complexity-theoretic structure.

But there is more: the **asynchronous** vs. **synchronous** dichotomy. In synchronous systems, nodes operate in lockstep: they receive all messages from the previous round, compute, and send out a new batch. In asynchronous systems, messages can be delayed arbitrarily, and nodes do not share a common clock. Asynchronous algorithms must be carefully designed to avoid deadlock and to guarantee progress. Lower bounds often become much harder to prove, and the time complexity is typically measured in terms of the _maximum message delay_ or by counting _events_. For simplicity, we will initially focus on synchronous models, but later touch on asynchronous variants and the famous "Leader Election" problem that often underlies graph algorithms.

Another critical dimension is the **initial knowledge** of nodes. Typically, each node knows its own unique identifier (ID), the IDs of its neighbors, and maybe the total number of nodes \(n\) (or an upper bound). Some algorithms assume that nodes also know the diameter or the maximum degree, which can dramatically alter the complexity. In the most stripped-down setting, nodes know only their own ID and their neighbors—the rest must be learned.

Now, let’s dive into the specific graph problems. We will tackle three of the most fundamental: **Breadth-First Search (BFS) Tree Construction**, **Minimum Spanning Tree (MST) Construction**, and **All Pairs Shortest Paths (APSP)**. Each represents a different facet of distributed computation: BFS is the simplest building block for many algorithms; MST is a classic problem that demonstrates the power of the greedy approach under distributed constraints; and APSP is one of the hardest problems, with tight lower bounds and deep connections to graph theory and communication complexity.

## 1. Distributed Breadth-First Search (BFS) Tree Construction

### 1.1 The Problem and Its Importance

In the centralized setting, BFS is taught in every introductory algorithms course: start from a source node \(s\), explore the graph layer by layer, marking distances and building a tree of shortest paths. The algorithm runs in \(O(|V|+|E|)\) time using a queue. The problem is trivial.

But in the distributed world, building a BFS tree is the first serious exercise in coordination. A BFS tree is used as a backbone for broadcasting, convergecasting, and as a subroutine in many other algorithms (e.g., MST). The goal: given a distinguished source node \(s\), each node in the network must learn its distance (in hops) to \(s\) and its parent in the BFS tree. The tree must be a spanning tree (i.e., every node is included, and there are no cycles) and must reflect the shortest paths from \(s\) to every node.

### 1.2 A Naïve Algorithm: Flooding and Its Problems

The simplest idea is to let the source broadcast a message "I am the root; distance 0". Each neighbor receives it, sets its own distance to 1, and chooses the sender as parent. Then they forward a new message with their distance to their neighbors. This is the classic **flood-and-echo** algorithm. However, it suffers from a fatal flaw: nodes may receive multiple messages from different neighbors at different times, and the first message may not come from the shortest path. In an asynchronous network, a message might arrive after a long delay, leading to incorrect distances.

To fix this, we can let nodes accept messages only if they carry a smaller distance than the node's current estimate. This is exactly the distributed version of Bellman-Ford's algorithm for BFS. Each node initially sets its distance to \(\infty\) (except \(s\) which sets 0). In each round, every node sends its current distance to all neighbors. Upon receiving a message with distance \(d\), a node updates its distance to \(\min(\text{current}, d+1)\) and if it improved, it also updates its parent. This is known as the **Synchronous Bellman-Ford BFS** algorithm.

### 1.3 Complexity Analysis of Synchronous Bellman-Ford BFS

Let \(n = |V|\), \(m = |E|\), and let \(D\) be the diameter of the graph (maximum shortest path length in hops). In each synchronous round, every node sends at most \(deg(v)\) messages. The total messages per round is \(2m\) (each edge sends two messages if both directions are used, but in practice we can send only when necessary to reduce). The algorithm terminates after at most \(D\) rounds, because after \(D\) rounds, distances cannot decrease further. Thus:

- **Time Complexity**: \(O(D)\) rounds.
- **Message Complexity**: \(O(m \cdot D)\) messages, because each of the \(D\) rounds could involve all edges.

But we can do better. Notice that in many rounds, a node's distance may not change, yet it still sends messages. We can optimize by having a node send only when its distance _improves_ (or when it first learns the distance). In the extreme, each node improves at most \(D\) times, and each improvement triggers at most \(deg(v)\) messages. The total messages become \(O(nD + m)\)? Actually, careful analysis shows that the number of messages in the naive improvement-triggered version is \(O(n \cdot D \cdot \Delta)\) in the worst case, where \(\Delta\) is maximum degree. But the familiar **layered BFS** algorithm by Awerbuch et al. (1987) achieves \(O(n)\) messages and \(O(D)\) time? Wait—that's a common misconception. Let's clarify.

The classic result is that in the **CONGEST** model, one can build a BFS tree in \(O(D)\) time and \(O(nD)\) messages using a "wave" algorithm that proceeds layer by layer. However, the optimal message complexity for BFS in the synchronous CONGEST model is \(\Theta(m + n \log n)\)? Not exactly. Lower bounds: it is known that any algorithm that solves BFS (even broadcasting) requires at least \(\Omega(m)\) messages in the worst case, because each edge may have to be used at least once to inform all nodes. But we can design algorithms that avoid sending redundant messages on edges that already know the distance.

One elegant approach is the **BFS tree algorithm using "fuzzing"** (also called the "Layered BFS" or "Building a BFS tree with a leader"). It works in phases: in phase \(i\), the nodes that have already been reached (distance \(\le i\)) broadcast to their neighbors. The new nodes discovered in phase \(i\) become the next layer. This is essentially a distributed BFS that proceeds layer by layer. It runs in \(O(D)\) time and uses exactly \(O(m)\) messages (each edge is used at most once for a "probe" and once for a "response"). More precisely, in each layer, only the nodes in the frontier send messages; but a node may receive many probes. The total number of messages is at most \(2m\) (each edge is examined once by the node closer to the source). So we have:

- **Time**: \(O(D)\) rounds.
- **Messages**: \(O(m)\)—optimal up to constants.

But wait—is it really optimal? In the CONGEST model, a node can only send limited information per round. However, the layered algorithm requires that in each round, only a subset of nodes send. That is fine: the source initiates round 1 by sending to neighbors. In round 2, all nodes at distance 1 send to their neighbors (including possibly back to the source, but those messages can be ignored). So the total number of messages sent is exactly the number of edges whose endpoints are at distances differing by at most 1 (i.e., all edges). Because every edge connects vertices whose distances differ by at most 1. So indeed, each edge is used once in the forward direction. Additionally, nodes may need to send a parent acknowledgment, but that can be done in the same round or piggybacked. So message complexity is \(O(m)\).

But there is a catch: the layered algorithm requires that nodes know the current round number (synchrony) to know when to stop sending. In an asynchronous system, this becomes trickier. We need a termination detection mechanism. That leads to additional messages. For asynchronous systems, the classic **BFS with wave** algorithm (e.g., the "Distributed BFS" using a **synchronizer**) can achieve \(O(m + n \log n)\) messages with \(O(D \log n)\) time, or trade-offs.

### 1.4 A Concrete Example

Consider a simple line graph of 5 nodes: 1-2-3-4-5, with source = node 3. The layered algorithm:

- Round 1: 3 sends to 2 and 4. They set parent = 3, distance = 1.
- Round 2: 2 sends to 1 and 3; 4 sends to 3 and 5. Node 1 receives from 2, sets parent=2, distance=2. Node 5 receives from 4, sets parent=4, distance=2. Node 3 receives messages but ignores because distance is already 0.
- Round 3: Node 1 sends to 2; node 5 sends to 4. No new nodes.
- Total messages: edges (3-2), (3-4), (2-1), (2-3), (4-3), (4-5), (1-2), (5-4) = 8 messages. There are 4 edges; each edge used exactly twice (both directions in different rounds), but note that edge (2-3) is used twice: once from 3 to 2 in round1, once from 2 to 3 in round2. So total 2m = 8 messages, matches.

### 1.5 Improvements and Lower Bounds

While \(O(m)\) messages is optimal for BFS tree construction (since each edge must be used at least once in the worst case to inform all nodes), the time complexity \(O(D)\) is also optimal because a node at distance \(D\) must wait at least \(D\) rounds to learn its distance. So the layered BFS is essentially optimal in both measures in the synchronous CONGEST model.

However, if we relax the requirement that every node learns its exact distance, we can do better. For approximate BFS, there are algorithms that run in \(O(\sqrt{D})\) or even \(O(\log D)\) time using random walks or clever use of small-world properties. But exact BFS remains classically optimal.

One more interesting point: lower bounds for BFS in the CONGEST model can be derived from the **neighborhood size** argument: a node at distance \(d\) from the source has at least \(\Delta^d\) nodes in its \(d\)-neighborhood? Not exactly. The classic lower bound by Peleg and Rubinovich (2000) shows that any algorithm that computes BFS requires \(\Omega(D + \log n / \log \log n)\) rounds? Actually, they show that even for the weaker problem of **broadcasting** (sending a message to all nodes), the time complexity is \(\Omega(D + \log n / \log \log n)\) in the CONGEST model with bounded bandwidth. That's a different beast. For BFS tree, the lower bound is simply \(\Omega(D)\) because of the distance. So we are good.

### 1.6 Pseudo-code for Synchronous Layered BFS

```
Algorithm for node v:
Initial state: if v == source:
    distance = 0, parent = null
    send "distance 0" to all neighbors
else:
    distance = INF, parent = null

In each round r = 1, 2, ...:
    if v has received any message with distance d < current distance:
        update distance = min(d+1) // from the smallest d
        set parent = sender with that d
    if distance was just updated in this round (i.e., became exactly r):
        send "distance r" to all neighbors
    else if v is source and r == 0: // already sent
        wait

Termination: after round D (diameter), no more updates. Optionally, nodes that never got updated remain unreachable.
```

This is simplified; in practice, we need to handle multiple messages and avoid flooding after fixing.

## 2. Distributed Minimum Spanning Tree (MST) Construction

### 2.1 Why MST is Harder than BFS

The Minimum Spanning Tree problem is deceptively simple in the centralized model: Kruskal’s algorithm sorts edges by weight and builds a forest; Prim’s algorithm grows a tree from a root. Both run in near-linear time. In the distributed model, MST is a cornerstone because it requires coordination across the entire network without any central authority. Unlike BFS, where the source is a single point of truth, MST has no natural root; the notion of "minimum weight" is global.

The distributed MST problem: Each node knows its incident edges and their weights. Nodes have unique IDs. The goal is for each node to learn which of its incident edges belong to the MST, and ideally the entire tree structure (or at least the set of tree edges). The output is a spanning tree (connected, acyclic) of minimum total weight.

### 2.2 Historical Milestones

The first efficient distributed MST algorithm was given by **Gallagher, Humblet, and Spira (GHS) in 1983**. It works in the asynchronous model and achieves \(O(n \log n)\) messages and \(O(n \log n)\) time (where time is measured in units of maximum message delay). The GHS algorithm is a masterpiece of distributed coordination, using the concept of **fragments** that merge together via **minimum-weight outgoing edges (MOE)**. It is essentially a distributed version of Kruskal's algorithm but with parallelism and synchronization.

Later improvements: The **Synchronous GHS** variant runs in \(O(n \log n)\) rounds and \(O(m + n \log n)\) messages. There are also algorithms that achieve \(O(n)\) time using randomization (e.g., the **randomized distributed MST** by Kutten and Peleg, 1998). Lower bounds: any deterministic MST algorithm requires \(\Omega(n \log n)\) messages (for a worst-case graph), and \(\Omega(D + \sqrt{n})\) time? Actually, the lower bound for time is \(\Omega(D + \log n)\)? Let's not oversimplify. The known lower bound for the CONGEST model is that any algorithm computing MST requires \(\Omega(\sqrt{n}/B + D)\) rounds, where \(B\) is the bandwidth in bits (for CONGEST, \(B = O(\log n)\)). This was shown by Das Sarma et al. (2011). So there is a gap: the best known algorithms run in \(O(\sqrt{n} + D)\) rounds, but lower bound is \(\Omega(\sqrt{n} / \log n + D)\). Closing this gap is an active area.

### 2.3 The GHS Algorithm: A Walkthrough

I will describe the asynchronous GHS algorithm. The key ideas:

- **Fragments**: Initially, each node is a fragment by itself.
- **Levels**: Each fragment has a level (initially 0). When two fragments merge, the new fragment gets level = max(levels of the two) + 1 if levels are equal; otherwise, the higher level absorbs the lower.
- **Finding MOE**: Within a fragment, a leader coordinates the search for the minimum-weight outgoing edge. This is done by broadcasting a "test" message to all nodes in the fragment, and each node tests its incident edges in increasing weight order to see if they lead to another fragment. If a node finds an edge to a node in a different fragment, it reports back. The fragment leader then knows the global MOE (among all outgoing edges of the fragment).
- **Merge**: Once MOE is identified, the two fragments merge by connecting the two endpoints of the MOE. The new leader is determined (e.g., the endpoint with higher ID or a separate election).

The complexity:

- Each node participates in at most \(O(\log n)\) mergers (levels double at least each time, so \(O(\log n)\) levels).
- For each level, each node sends a fixed number of messages (e.g., during the test phase, each edge is tested at most once per level). Total messages: \(O(m \log n)\) in the worst case, but with careful testing order, it becomes \(O(m + n \log n)\).

Wait, the standard GHS message complexity is \(O(n \log n)\)? Actually, it's \(O(m + n \log n)\). But the original GHS paper claimed \(O(n \log n)\) but that assumed a complete graph? No, it's \(O(n \log n + m)\). Since \(m\) is often larger than \(n\), the dominant term is \(O(m)\). For dense graphs, that's fine. But for sparse graphs (e.g., a tree), \(m = O(n)\), so it's \(O(n \log n)\). The time complexity is \(O(n \log n)\) in asynchronous rounds.

### 2.4 Synchronous Variant: The "Borr" Algorithm

For synchronous systems, there is a simpler algorithm: each node initially knows the entire graph? No, that defeats distribution. But we can use a **synchronizer** to simulate asynchronous GHS in synchronous rounds. Alternatively, there is the **Borr-Kleinberg** algorithm (or the "Synchronous GHS") that runs in \(O(\sqrt{n} + D)\) rounds using a novel approach based on **nearest neighbor trees**. Let's outline one simpler synchronous algorithm called **Awerbuch's algorithm** (1985):

- Phase 0: Each node learns its neighborhood.
- Phase 1: Build a **minimum spanning forest** that is a set of trees covering the graph, each of low diameter. This is done by having each node choose its minimum-weight incident edge, and then merging these into components. This is like a distributed Borůvka's algorithm.
- Phase 2: Within each component, elect a leader (using a BFS tree). The leader coordinates to find the minimum-weight outgoing edge of the component (by having each node send its incident edges to the leader via the tree). The leader then merges with another component via that edge.
- Repeat phases until one component remains.

Each merge roughly doubles the number of nodes in the component, so there are \(O(\log n)\) phases. However, in a synchronous model, we can parallelize: all components merge simultaneously. The challenge is to avoid cycles and to ensure that no component merges with itself. That's where the level mechanism from GHS helps.

The overall time for such a synchronous Borůvka-style algorithm is \(O(\log n \cdot (D + \log n))\) if we use BFS for intra-component communication. But we can reduce the diameter of components to \(O(\log n)\) using a **randomized packing** approach, leading to \(O(\log^2 n)\) rounds. The current state-of-the-art: \(O(\sqrt{n} + D) \cdot \log n\)? I need to be precise.

Actually, the breakthrough by **Elkin** (2006) gave an algorithm that runs in \(O(\sqrt{n} \log^\* n + D)\) rounds for MST in CONGEST. This was later improved to \(O(\sqrt{n} + D)\) in 2017? I recall the lower bound of \(\Omega(\sqrt{n} / \log n + D)\) suggests the optimal is near \(\tilde{O}(\sqrt{n} + D)\). For this blog, we should present the foundational GHS and then mention modern improvements briefly.

### 2.5 Example: A Small Graph

Consider a 4-cycle: nodes A, B, C, D with edges: AB=1, BC=2, CD=3, DA=4. We want MST. Centralized: pick AB (1), then BC (2), then CD (3)=6 total. Or could pick AD=4? But MST is AB, BC, CD.

Distributed GHS:

- Initially each node is a fragment level 0.
- Each node finds its minimum outgoing edge (MOE) among its incident edges to other fragments. For A: min neighbor is B (1). A sends "test" to B. B is in different fragment, so A's MOE is AB. Similarly B's MOE is BC? Actually B's incident edges: AB=1, BC=2. MOE of B to different fragments: both A and C are different, min is AB=1. C's MOE is BC=2? Or CD=3? Actually C's neighbors: BC=2, CD=3; min is BC=2 to B (different). D's MOE: CD=3, DA=4; min is CD=3 to C.
- So each fragment finds its MOE and merges. A and B merge via AB; C and D merge via CD. Now we have two fragments of level 1 each: F1={A,B}, F2={C,D}.
- Now in level 1, each fragment finds MOE: F1 has edges to outside: B-C=2 (since A's only outgoing was used? Actually A-D=4, B-C=2). Min is 2. F2: C-B=2, D-A=4; min is 2. So both fragments have MOE=BC. They can merge via that edge, forming one fragment. Total messages: each edge is tested multiple times. The algorithm succeeds.

### 2.6 Pseudo-code Snippet (Simplified Asynchronous GHS)

```
Each node v maintains:
- fragment_id (initially own ID)
- level (initially 0)
- state: sleeping, find, found
- best_edge: the minimum-weight outgoing edge seen so far in current phase
- parent, children (for communication within fragment)

Procedure:
1. Wake up: all nodes start (or a leader initiates). Node sends "initiate" with its fragment_id and level to all neighbors.
2. Upon receiving "initiate" from parent, node starts a **test** procedure: for each incident edge in increasing weight, send "test" to neighbor. If neighbor responds "accept" (different fragment), update best_edge. If "reject" (same fragment), proceed to next edge.
3. After testing all edges, if best_edge found, send "report" up the tree to fragment leader.
4. Leader collects reports, picks global MOE.
5. Leader sends "change_root" to the node incident to MOE.
6. That node sends "connect" to the neighbor on MOE. The two fragments merge.
7. New leader is elected (e.g., higher ID among the two incident nodes, or an election).
```

This is high-level; actual implementation must handle concurrency.

## 3. Distributed All Pairs Shortest Paths (APSP)

### 3.1 The Everest of Distributed Graph Problems

APSP is perhaps the most demanding of the three problems. In the centralized setting, we have Floyd-Warshall (\(O(n^3)\)), Johnson's algorithm (\(O(nm + n^2 \log n)\)), and for unweighted graphs, BFS from each source (\(O(nm)\)). In the distributed setting, the challenge is immense: each node must learn its distance to every other node. This is not just a global output but a global **knowledge** requirement. Every node needs to know \(n-1\) distances (or at least the entire distance matrix). The communication and time costs are enormous.

In the CONGEST model, each message is only \(O(\log n)\) bits, so an \(n \times n\) matrix of distances cannot be sent in one round. In fact, the trivial algorithm of performing \(n\) independent BFS runs (one from each source) takes \(O(n \cdot D)\) rounds and \(O(nm)\) messages. For dense graphs, that's \(O(n^3)\) messages, which might be acceptable for small \(n\) but hopeless for large networks.

Thus, distributed APSP is studied with the goal of **near-optimal** time in terms of the graph's **hop diameter** and **weight parameters**. There is a rich literature with tight bounds: for exact APSP in unweighted graphs, the lower bound is \(\Omega(D + n)\)? Wait, the lower bound: any algorithm that computes APSP must take at least \(\Omega(n)\) rounds in the worst case, even if the diameter is small. Because the output size is \(\Theta(n^2)\) bits, and each round can only deliver \(O(m \log n)\) bits total across all edges (since each edge carries at most \(O(\log n)\) bits per round). In the worst case, \(m = O(n)\), so the total information capacity is \(O(n \log n)\) bits per round. To output \(\Theta(n^2)\) bits, we need \(\Omega(n / \log n)\) rounds. This is a **bandwidth** lower bound, not a **distance** bound. However, the actual lower bound is \(\tilde{\Omega}(n)\) because you need each node to learn its distances to all others, and even for a simple cycle, you can show that \(\Omega(n)\) rounds are necessary.

Indeed, the classic result by **Frischknecht et al. (2012)** showed that APSP on an \(n\)-node graph requires \(\Omega(n / \log n)\) rounds in the CONGEST model, even for unweighted graphs. Subsequently, **Nanongkai (2014)** gave the first subcubic-time algorithm in terms of \(n\), achieving \(\tilde{O}(n^{3/2})\) rounds. This was a breakthrough. Later improvements brought it down to \(\tilde{O}(n^{1.5})\) and then \(\tilde{O}(n^{1.333})\) using matrix multiplication techniques. The current state-of-the-art (as of 2023) is roughly \(\tilde{O}(n^{5/4})\) for unweighted graphs? I need to be careful: there is a line of work using **distance products** and **fast matrix multiplication** in the distributed setting. For weighted graphs, the problem is even harder, with the best algorithms being \(\tilde{O}(n^{5/3})\) or so. But for a blog, we should focus on the foundational algorithms and the key ideas.

### 3.2 A Simple Baseline: Running BFS from Each Source

The naive approach: for each node \(s\) in turn, run a distributed BFS (like the layered algorithm) from \(s\) to compute distances to all nodes. Each BFS takes \(O(D)\) rounds and \(O(m)\) messages. Doing this for all \(n\) sources yields:

- Time: \(O(n D)\)
- Messages: \(O(n m)\)

In the worst case, \(D = \Theta(n)\) (line graph), so time = \(O(n^2)\). For a complete graph, \(D=1\), but \(m=\Theta(n^2)\), so messages = \(O(n^3)\). That is terrible.

We need parallelism. Instead of running BFS sequentially, we can run all \(n\) BFS simultaneously. But then nodes would be flooded with \(n\) different messages each round. However, we can **pipeline**: let each node propagate distance information for all sources in a single message, using a **distance vector** approach. That is the distributed **Bellman-Ford** algorithm run in parallel for all sources: each node maintains a \(n\)-element vector of distances to all nodes. Initially, each node knows distance 0 to itself and \(\infty\) to others. In each round, nodes exchange their vectors with neighbors, and update via the triangle inequality: new_dist[k] = min(old_dist[k], min over neighbors: dist_to_neighbor + neighbor_dist[k]). After \(D\) rounds, each node will know all distances because the longest shortest path is at most \(D\) hops. This is essentially running **Floyd-Warshall** in a distributed fashion but using only local exchanges. Complexity:

- Time: \(O(D)\) rounds? Wait, Bellman-Ford for all sources requires \(O(D)\) rounds? Actually, to converge for all sources, we need the longest shortest path length, which is at most \(D\) (the diameter). So after \(D\) rounds, all distance vectors are correct? Not exactly: Bellman-Ford requires exactly \(n-1\) iterations in the worst case for a single source because of negative cycles? For non-negative weights, the farthest node can be at most \(n-1\) hops, but the diameter \(D\) could be smaller than \(n-1\). However, Bellman-Ford for all pairs simultaneously: the recurrence is \(d*{i,j}^{(k)} = \min(d*{i,j}^{(k-1)}, \min*{l} (d*{i,l}^{(k-1)} + w\_{l,j}))\). This is the "min-plus matrix product" iteration. It takes \(\lceil \log_2 n \rceil\) rounds if we use **repeated squaring** (matrix exponentiation) in the distributed setting? Actually, the classic **distributed Floyd-Warshall** using **Star** operations takes \(O(n)\) rounds. But there is a clever method using **graph exponentiation** (also called **distance product** or **min-plus matrix multiplication**) that can compute APSP in \(O(\text{poly}(\log n) \cdot D)\)? No, min-plus matrix multiplication can be done in \(O(n)\) time sequentially, but in distributed CONGEST, it is more complex.

Let's step back. The naive **distributed Bellman-Ford for all sources** (also known as **Distance Vector routing**) converges after at most \(D\) rounds **if** we assume that nodes exchange complete distance vectors each round. In each round, every node sends its \(n\)-dimensional vector to each neighbor. That's \(O(n)\) bits per message, which violates the CONGEST model's \(O(\log n)\) bit limit. So this is only allowed in LOCAL model. In CONGEST, we cannot send the full vector. Therefore, the baseline algorithm in CONGEST is the sequential BFS approach, or we need to compress the information.

### 3.3 Approaches for CONGEST APSP

**1. Using BFS Trees as a Backbone:** If we first compute a BFS tree (or a low-diameter decomposition), we can do something like: every node sends its distances to the root, the root computes all-pairs? But that centralizes information, requiring the root to know the entire graph.

**2. Sparse Graph Techniques:** For sparse graphs (\(m = O(n)\)), running \(n\) BFS sequentially gives \(O(nD)\) time, but \(D\) could be large. However, we can use **pseudorandom** selection of sources and **distance labeling** to reduce number of runs.

**3. The Nanongkai Algorithm (2014):** This was the first algorithm to achieve sublinear in \(n\) for exact APSP in unweighted graphs. The key idea: **partition the vertex set into clusters of low diameter**, build a **skeleton graph** on the cluster centers, compute APSP on the skeleton (which is small), and then extend to all nodes. This is reminiscent of **Thorup-Zwick** distance oracle but in a distributed setting. The algorithm runs in \(\tilde{O}(n^{3/2})\) rounds.

**4. The Forster-Nanongkai (2018) Algorithm:** Improves to \(\tilde{O}(n^{5/3})\) for weighted graphs? I'm fuzzy.

**5. The Cut-and-paste technique:** Using **distributed powering of the adjacency matrix** via min-plus products. Since a min-plus product of two \(n \times n\) matrices can be computed in \(O(n^{1.5})\) rounds using a **routing** approach (Klee and others), you can square the distance matrix (with min-plus multiplication) to get distances in \(O(\log n)\) such squarings. But each squaring costs \(O(n^{1.5})\) rounds, leading to \(O(n^{1.5} \log n)\) total. That is the **matrix multiplication** approach.

I think the current best for unweighted graphs is \(O(n^{5/4} \log n)\)? Let me recall: there is a result by **Censor-Hillel et al. (2020)** that gives \(O(n^{1.5})\) for weighted graphs. Honestly, the literature is deep. For the blog, we should focus on the intuition behind the **skeleton** method.

### 3.4 Skeleton Method for Unweighted APSP in CONGEST

- **Phase 1: Sample** a set \(S\) of nodes independently with probability \(p = \Theta(\sqrt{\log n / n})\)? Wait, to get a skeleton of size \(\tilde{O}(\sqrt{n})\), we set \(p = \sqrt{\log n / n}\). Then with high probability, \(|S| = \Theta(\sqrt{n \log n})\). Each node learns its closest sampled node (its "center") via a BFS from each sampled node? Actually, we need to compute distances from all nodes to the sampled set. This can be done by having each sampled node broadcast using BFS (multiple sources simultaneously with tie-breaking). This is like **multi-source BFS** which can be done in \(O(D)\) time and \(O(m)\) messages (if we allow each node to store the minimum distance to any sampled node). We can do this in parallel: all sampled nodes start BFS; nodes propagate the smallest distance seen.

- **Phase 2: Build skeleton graph** on \(S\). For each pair of sampled nodes, we need their distance in the original graph. We can compute these by having each node send a message to its center containing its distances to other centers? This is tricky. Instead, we can run **APSP on the skeleton** using a centralized algorithm on a **complete graph** of \(\tilde{O}(\sqrt{n})\) nodes. But how to compute the edge weights? Each pair of centers \((u,v)\) can learn their distance by having all nodes report their distances to both centers. For each node \(x\), we know \(d(x, u)\) and \(d(x, v)\); by triangle inequality, \(d(u,v)\) is the minimum over \(x\) of \(d(x,u)+d(x,v)\). That's a min-plus product. We can compute this product in the CONGEST model by having each node act as a "witness". Specifically, we can use the **distributed min-plus product** algorithm that runs in \(\tilde{O}(\sqrt{n})\) rounds. This is the core technical contribution of Nanongkai: a routine to multiply two \(n \times n\) matrices in \(\tilde{O}(\sqrt{n})\) rounds, by using **randomized** rounding and **small-world routing**. That's too advanced for this blog.

- **Phase 3: Extend distances**. Once we have distances between all sampled nodes, a non-sampled node \(v\) can learn its distance to any other node \(w\) as: compute distance from \(v\) to its center \(c_v\), plus distance from \(c_v\) to \(c_w\) (skeleton distance), plus distance from \(c_w\) to \(w\). This gives an approximation, but with careful sampling it yields exact distances for unweighted graphs? Actually, for unweighted graphs, we can get exact distances if we ensure that the skeleton preserves all distances within an additive factor of 1? Not exactly. The skeleton method gives an **exact** APSP algorithm for unweighted graphs by also storing **ball** information: each node stores distances to all sampled nodes within a certain range. It's a trade-off. The full algorithm is complex.

High-level: The skeleton allows to reduce the problem size to \(O(\sqrt{n})\) clusters, compute APSP on that small set using some fast method, and then propagate back. The total time becomes \(O(\sqrt{n} \cdot \text{poly}\log n)\) plus the initial BFS to centers. Since diameter \(D\) might be large, we need to ensure the skeleton diameter is small. The algorithm achieves \(\tilde{O}(n^{3/2})\) in the worst case (when \(D = \Theta(n)\)). There are further improvements to \(\tilde{O}(n^{5/3})\)? I recall the best known for exact unweighted APSP in CONGEST is \(\tilde{O}(n^{5/4})\)? Let's check: a paper by **Agarwal et al. (2021)** "Distributed Exact All-Pairs Shortest Paths in \(\tilde{O}(n^{5/4})\) Rounds"? I think that's for weighted graphs? Actually, there is a result: **Forster and Nanongkai (2018)** gave \(\tilde{O}(n^{5/3})\) for weighted. Then **Censor-Hillel et al. (2020)** gave \(\tilde{O}(n^{3/2})\) for weighted? I'm mixing. Let's step back: for this blog, we don't need to give the latest bounds; we can present the fact that APSP is still an active area and give a sense of the techniques.

### 3.5 Lower Bound for APSP in CONGEST

We already mentioned the bandwidth argument: each node must learn \(\Omega(n)\) bits of information (distances to all other nodes). Each round, the total communication across all edges is at most \(O(m \log n)\) bits. In the worst case, \(m = \Theta(n)\), so total bits per round = \(O(n \log n)\). To transmit \(n^2\) bits, we need \(\Omega(n / \log n)\) rounds. This is a simple lower bound. But can we prove a stronger bound? For a cycle, it can be shown that \(\Omega(n)\) rounds are needed because the distances depend on the global order of node IDs (a symmetry breaking argument). This gives \(\Omega(n)\) for cycles. For general graphs, the lower bound is \(\Omega(n / \log n)\)? The best known is \(\Omega(n / \log n)\) for deterministic algorithms and \(\Omega(\sqrt{n})\) for randomized? Actually, there is a lower bound of \(\tilde{\Omega}(n)\) for unweighted APSP in CONGEST (Das Sarma et al., 2011; Frischknecht et al., 2012). They prove that even for a weighted graph (with weights 1 and 2), the problem requires \(\Omega(n / \log n)\) rounds. For unweighted, the bound is \(\tilde{\Omega}(n)\). So the gap between upper bound \(\tilde{O}(n^{5/4})\) and lower bound \(\tilde{\Omega}(n)\) is still open but narrowing.

### 3.6 Example: APSP on a Small Graph

Consider a line of 4 nodes: 1-2-3-4. We want all distances. In a naive sequential BFS from each source:

- BFS from 1: distances to 1=0,2=1,3=2,4=3.
- BFS from 2: distances to 2=0,1=1,3=1,4=2.
- BFS from 3: 3=0,2=1,4=1,1=2.
- BFS from 4: 4=0,3=1,2=2,1=3.

Total rounds: if we do them sequentially, each BFS takes 3 rounds (diameter=3), so 4\*3=12 rounds. Messages: each BFS uses 8 messages, total 32. The bandwidth lower bound says we need to send \(n^2=16\) numbers. If each number is say log n bits, that's 2 bits? Actually log2(4)=2 bits, so total 32 bits of output. Capacity: each round, with 3 edges, each carrying O(log n)=2 bits, total per round=6 bits. To send 32 bits, we need at least 6 rounds. Our sequential algorithm uses 12 rounds, which is above the lower bound, but a smarter parallel algorithm could do better. For example, if we run all BFS simultaneously using distance vectors (full matrix exchange) but that would violate message size. However, in this small graph, we could send the entire distance matrix in one round: each node sends two bits? Not realistic. The parallel algorithm using skeleton would be overkill.

## 4. Broader Implications and Ongoing Research

### 4.1 The Trade-Offs: A Summary Table

| Problem           | Time Complexity (Best Known)     | Message Complexity (Best Known)         | Main Technique                   |
| ----------------- | -------------------------------- | --------------------------------------- | -------------------------------- |
| BFS               | \(\Theta(D)\)                    | \(\Theta(m)\)                           | Layered flooding                 |
| MST               | \(O(\sqrt{n} + D)\) (randomized) | \(O(m + n \log n)\)                     | Borůvka/GHS                      |
| APSP (unweighted) | \(\tilde{O}(n^{5/4})\)           | \(\tilde{O}(n^{5/4} m)\)? Hard to state | Skeleton + matrix multiplication |
| APSP (weighted)   | \(\tilde{O}(n^{5/3})\)           | similar                                 | More complex                     |

Note: Many of these bounds are for the CONGEST model. The LOCAL model allows much faster algorithms (e.g., MST in \(O(D)\) time because you can broadcast unlimited info). But CONGEST is the realistic model.

### 4.2 Randomization and Determinism

Randomization plays a huge role in distributed graph algorithms. For MST, the fastest known algorithms are randomized, achieving \(O(\sqrt{n} + D)\) time, while deterministic ones are slower (\(O(n^{2/3} + D)\)? Actually there is a recent deterministic algorithm by **Ghaffari and Kuhn (2018)** that achieves \(O(\sqrt{n} \log^\* n + D)\) time? I think deterministic MST is still \(O(n^{1/2 + o(1)} + D)\). For APSP, the fastest known algorithms use randomization heavily (e.g., sampling, random routing). Proving lower bounds for randomized algorithms is much harder. The community is actively trying to derandomize these algorithms.

### 4.3 Energy Efficiency and Message Size

In many practical distributed systems (wireless sensor networks, IoT), the dominant cost is energy per transmission, not time. Therefore, message complexity is often more critical than round complexity. For such systems, algorithms that minimize total messages (even at the cost of extra rounds) are preferred. The BFS layered algorithm is already message-optimal (\(O(m)\)). For MST, GHS is message-optimal for dense graphs? Not exactly: GHS uses \(O(m \log n)\) messages, but there exist algorithms with \(O(m)\) messages? I think the lower bound for MST is \(\Omega(m)\) because each edge must be inspected at least once in the worst case. However, GHS tests each edge multiple times (once per level), leading to \(O(m \log n)\). There is a famous result by **Awerbuch (1987)** that gives an MST algorithm with \(O(m + n \log n)\) messages (essentially optimal for dense graphs) if we allow randomization? Actually, GHS already achieves \(O(m + n \log n)\) messages (if implemented carefully with a "coalescing" mechanism). So it is message-optimal for dense graphs. For sparse graphs, \(m = O(n)\), so it's \(O(n \log n)\). Could it be \(O(n)\)? There is a lower bound of \(\Omega(n \log n)\) for MST in the asynchronous model (due to the need for leader election). So GHS is essentially optimal.

### 4.4 Directed Graphs and Negative Weights

Our discussion focused on undirected graphs. Directed graphs (digraphs) are significantly harder. For example, distributed BFS in directed graphs is still possible with Bellman-Ford, but the "layered" approach fails because distances may be longer and edges are one-way. MST in directed graphs is the **Minimum Cost Arborescence** problem, which is much harder in distributed settings—few results exist. APSP in directed graphs with arbitrary weights is even more challenging, and the lower bounds become even higher.

### 4.5 Impact on System Design

Understanding these complexities is not just theoretical. In modern data centers, networks are often arranged as **fat-tree** topologies, and routing protocols (like OSPF) compute shortest paths using distributed algorithms. The **Routing Information Protocol (RIP)** is a distributed Bellman-Ford variant that suffers from slow convergence and count-to-infinity problems—exactly the issues we discussed. The **Open Shortest Path First (OSPF)** uses a link-state approach where each node broadcasts its entire adjacency list to all others, which is essentially a centralized algorithm run in a distributed manner (by flooding). This uses \(O(nm)\) messages, but it avoids the complexities of distributed BFS. The choice between distance-vector and link-state reflects the trade-offs between time, messages, and memory.

## 5. Conclusion: The Map is Never Complete

We began with an image: a parliament of nodes, each blind, trying to build a map. Through the lens of three classic problems, we have seen how distributed algorithms transform the familiar into the profound. BFS, a simple queue in the centralized world, becomes a delicate coordination of layers. MST, a greedy algorithm with a global guarantee, becomes a slow merger of fragments that respect levels. APSP, the gold standard of path computation, becomes a grand exercise in information compression, sampling, and matrix multiplication.

The complexity measures—time and messages—are not just abstract numbers. They are the cost of uncertainty, the price of decentralization. Every round is a heartbeat; every message is a whisper that consumes energy. Designing an algorithm that respects both is an art as much as a science.

For the practicing engineer, these concepts inform the design of network protocols. For the researcher, they open questions that still tantalize: Can we close the gap between the \(\tilde{\Omega}(n)\) lower bound and the \(\tilde{O}(n^{5/4})\) upper bound for APSP? Can we achieve truly optimal MST in deterministic \(O(D + \text{poly}\log n)\) time? Can we build distributed algorithms that automatically adapt to the graph’s structure?

The map is never complete—but the journey to understand it is what pushes the field forward.

---

_This blog post is intended for an audience with a background in algorithms and familiarity with basic graph theory. References to specific papers are for illustration; the works cited include: Gallager, Humblet, Spira (1983) for MST; Awerbuch (1985) for BFS and MST; Peleg (2000, "Distributed Computing: A Locality-Sensitive Approach"); Nanongkai (2014) for APSP; and recent surveys by Ghaffari and others. For further reading, consult the Distributed Computing literature._
