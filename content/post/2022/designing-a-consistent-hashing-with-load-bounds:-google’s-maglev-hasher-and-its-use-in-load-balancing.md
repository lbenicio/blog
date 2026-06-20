---
title: "Designing A Consistent Hashing With Load Bounds: Google’S Maglev Hasher And Its Use In Load Balancing"
description: "A comprehensive technical exploration of designing a consistent hashing with load bounds: google’s maglev hasher and its use in load balancing, covering key concepts, practical implementations, and real-world applications."
date: "2022-12-31"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/designing-a-consistent-hashing-with-load-bounds-google’s-maglev-hasher-and-its-use-in-load-balancing.png"
coverAlt: "Technical visualization representing designing a consistent hashing with load bounds: google’s maglev hasher and its use in load balancing"
---

# Designing a Consistent Hashing With Load Bounds: Google’s Maglev Hasher and Its Use in Load Balancing

## Introduction

Imagine you run a global video streaming service that serves millions of concurrent users. Every time a viewer clicks “play,” your frontend load balancer must route that request to one of thousands of backend servers—each potentially hosting different shards of the content catalog. The balancer must decide fast: within microseconds, with near-perfect consistency, and without letting any single backend become a hot spot that melts under load.

You reach for the standard tool: consistent hashing. It gives you minimal reshuffling when servers join or leave, which is critical for cache efficiency and session persistence. But soon you notice a problem. Under real-world traffic, some nodes consistently receive 20–30% more requests than others. The ring-based distribution, while elegant, is far from uniform. You can add virtual nodes to smooth out the variance, but that increases memory and lookup time. Worse, when a node fails, its load is absorbed by its immediate neighbors on the ring, creating cascading overloads. Your pager goes off at 3 a.m. again.

This is not a thought experiment. It’s a problem that engineers at Google faced when building Maglev, their network load balancer—a device that sits in front of every Google service, from Search to YouTube. Their solution, published in a 2016 NSDI paper, reimagined consistent hashing by adding **load bounds**. Instead of hoping that random assignment spreads load evenly, Maglev explicitly guarantees that no backend gets more than a configurable fraction of total traffic. The algorithm is fast (a single array lookup), provably balanced, and handles membership changes gracefully. It is now the de facto standard in Google’s production network, and understanding it reshapes how we think about load balancing at scale.

If you have ever struggled with uneven distribution in a consistent hashing implementation, you are not alone. The problem has plagued distributed systems for decades. In this post, we will peel back the layers of the Maglev hashing algorithm, examine its core innovation—load bounds—and show you how to implement it in your own systems. We will also explore the theoretical underpinnings, compare it with other approaches, and discuss the real-world impact that made Maglev a game-changer in network load balancing.

This is a deep dive. By the end, you will understand not only how Maglev works but also why it is superior to traditional consistent hashing for scenarios that demand both speed and fairness. Whether you are designing a microservices gateway, a distributed cache, or a CDN, the principles here will help you build more resilient and efficient systems.

---

## The Problem with Traditional Consistent Hashing

To appreciate Maglev, we must first revisit the foundations of consistent hashing. Invented by David Karger et al. in 1997, consistent hashing addressed a fundamental flaw in simple modulo-based load balancing. In a naive modulo scheme, you compute `hash(request) % N` to pick a backend among `N` servers. Every time `N` changes (a server crashes, is added, or is removed), the mapping for almost every request changes. This can cause a cascade of cache misses, database connection breakage, and session loss. Consistent hashing solved this by mapping both servers and keys onto a circular ring of hash values. A key is assigned to the server whose hash comes first in a clockwise direction. When a server is removed, only the keys that mapped to that server need to be reassigned—typically to its neighbor. When a server is added, only a fraction of keys from the neighbor shift to the new node.

The brilliance of the ring is minimal reshuffling. However, the ring has a dirty secret: it does **not** guarantee uniform load distribution. The distribution of keys among servers on a ring follows the same statistical variance as placing points randomly on a circle. With a small number of servers (say 10), the imbalance can be severe—some servers may get 3x the load of others. As the number of servers grows, the variance decreases (by the Central Limit Theorem), but in practice even with thousands of servers, a skew of 10–20% is common. In a large-scale deployment such as Google's where individual backends can handle up to 10 Gbps of traffic, a 20% skew translates to 2 Gbps of extra stress on already busy machines. That is a recipe for packet loss, latency spikes, and eventually cascading failures.

### Virtual Nodes: A Band-Aid

The standard mitigation is to introduce **virtual nodes**—also called virtual shards—where each physical server is represented by many points on the ring. If you use 100 virtual nodes per physical node, the statistical variance drops dramatically. For example, with 10 physical nodes and 100 virtual nodes each, you have 1000 points on the ring, and the load distribution improves to near-uniform. However, virtual nodes come with costs:

- **Memory overhead**: Each virtual node requires its own entry in the hash ring. With tens of thousands of servers and hundreds of virtual nodes per server, the ring can grow to millions of entries. This consumes memory on the load balancer and increases lookup time (since you have to search through more entries, though typically binary search or a sorted list makes it O(log N) where N is total virtual nodes).
- **Lookup time**: Even with binary search, a ring of millions of entries is slower than a simple array lookup. More importantly, the search is rarely a simple binary search because the ring is often implemented as a binary search tree or a sorted list; each lookup involves logarithmic time to find the nearest neighbor. For a load balancer handling millions of packets per second, every microsecond counts.
- **Reshuffling granularity**: When a physical server leaves, all its virtual nodes are removed from the ring. The load from those virtual nodes is redistributed to their respective clockwise neighbors. Because virtual nodes are distributed across the ring, the load is spread across many servers, which is good. However, the uniformity of redistribution depends on the number of virtual nodes; with hundreds, it's fairly uniform, but there is still residual imbalance.
- **Configuration burden**: The number of virtual nodes per server must be chosen carefully. Too few, and imbalance persists. Too many, and you waste memory and CPU. There is no one-size-fits-all answer; it depends on the expected number of backends and traffic volume. Moreover, the virtual node approach does not provide any **hard guarantee** on the maximum load a server will receive. It only reduces variance statistically. In the worst case, even with many virtual nodes, a pathological combination of hash values can still overload a particular server.

Beyond virtual nodes, other refinements have been proposed, such as the **Rendezvous hashing** (highest random weight) or the **Jump consistent hash**. Rendezvous hashing provides very balanced distribution (O(log N) lookup time with efficient data structures) but requires a priority list per key, which is memory-intensive for high request rates. Jump hashing (by Google’s John Lamping) is ideal for small, fixed sets of backends (like shards in a database) but does not handle arbitrary membership changes well because it assumes a continuous integer space of backends and a strict order. Neither offers the combination of very fast lookup, minimal memory, and guaranteed load bounds that Maglev provides.

### The Real-World Pain Points

To understand why Google invested in a new algorithm, consider the context of the **Maglev** network load balancer. Maglev is a software-based load balancer that runs on commodity hardware—typically x86 servers with dual 40 Gbps NICs. It must process packets at line rate, meaning it has to make forwarding decisions in under a microsecond. On a server handling 20 million packets per second (PPS), every nanosecond matters. The load balancer maintains a mapping from each incoming connection (identified by a 5-tuple of source IP, source port, destination IP, destination port, and protocol) to a backend server. This mapping must be consistent across all Maglev instances in a cluster and must survive backend failures without causing massive connection reshuffling.

Here are the core requirements that Maglev needs to satisfy:

1. **Speed**: Lookups must be O(1) and cheap—ideally a single array access. No binary searches, no hash ring traversals, no tree walks.
2. **Uniformity**: The distribution of connections across backends should be as close to uniform as possible. But even more importantly, there must be a **hard upper bound** on the load a single backend can receive. In a real deployment, each backend has a finite capacity (e.g., 10 Gbps). The load balancer must never assign more connections to a backend than its capacity can handle, otherwise packets are dropped.
3. **Consistency**: When the set of backends changes (additions, removals, failures), the mapping for most connections should remain unchanged. Only the connections that were assigned to the removed backend should be reassigned.
4. **Memory efficiency**: The lookup table must fit in the CPU cache of the load balancer (typically a few megabytes per forwarding table). The table size should be deterministic and independent of the number of backends.
5. **Low update cost**: When backends are added or removed, the algorithm should be able to quickly recompute the mapping with minimal disruption.

Traditional consistent hashing with virtual nodes fails on several of these points. Its lookup is O(log N) at best, and often O(N) if implemented naively. The memory footprint grows with the number of virtual nodes. And it provides no load bounds—the maximum load can be arbitrarily high in the worst case.

Maglev turned the problem on its head. Instead of starting with the hash ring, it builds a **lookup table** that directly maps each possible hash value to a backend. The lookup is a single array index: `backend = table[hash_value % TABLE_SIZE]`. The challenge is to fill that table in a way that respects load bounds, ensures uniformity, and minimizes disruption when backends change. The Maglev paper shows a remarkably simple and elegant algorithm to do this. Let's dive in.

---

## Maglev's Design Principles

Before looking at the algorithm itself, it is useful to understand the design philosophy that guided the Maglev authors (Daniel E. Eisenbud, et al., 2016). The paper frames the problem as a **stable marriage** of two conflicting goals: perfect load distribution and minimal disruption during updates.

### Principle 1: Direct Lookup, Not Search

Maglev precomputes a lookup table of size `M` (a prime number, typically chosen as a power of two slightly larger than 2^16 to keep memory low). The table maps each possible hash value (mod `M`) to a backend. The lookup is then: given a 5-tuple, compute its hash, take the modulo `M`, and fetch `table[hash % M]`. That's it: a single memory read. This is the fastest possible deterministic matching.

The size `M` determines the trade-off between memory and granularity. In practice, Google uses a table of 65537 entries (a prime number just above 2^16), which occupies about 256 KB (if each entry is a 4-byte backend ID). That fits easily in L2 cache of modern x86 CPUs. For a load balancer handling 20 million PPS, having the table in cache is crucial for sustained throughput.

### Principle 2: Bounded Imbalance, Not Perfect Uniformity

Perfect uniformity across backends is impossible because backend capacities may differ, and the number of connections is finite. But Google's requirement is that no backend receives more than `(1 + epsilon)` times its fair share. The fair share is `total_connections / number_of_backends`. The parameter `epsilon` is a tolerance. In practice, Maglev aims for a bound of `ceil(M / total_backends)` entries in the table per backend. That is, each backend gets either `floor(M / N)` or `ceil(M / N)` slots in the lookup table. This ensures that the maximum relative load is at most `ceil(M / N) / floor(M / N)`, which is very close to 1. For example, with M = 65537 and N = 1000, each backend gets either 65 or 66 slots, giving a maximum imbalance of 66/65 ≈ 1.015, or 1.5%. That is far better than any naive consistent hashing can achieve.

### Principle 3: Minimal Disruption on Updates

When a backend is added or removed, we want to reassign as few table entries as possible. In an optimal solution, only the entries that were assigned to the removed (or added) backend should change. Any other entry reassignment would disrupt connections that were stable. The Maglev algorithm is not optimal in this regard, but it is remarkably good: in practice, fewer than `M / N` entries are reassigned, which is the theoretical minimum to redistribute the load of the affected backend. The algorithm achieves this by iterating over a **preference list** for each possible table slot and choosing the backend that is the "least preferred" that hasn't already met its load bound. The preference list is generated using a deterministic permutation per backend, ensuring that the reassignment is spread across all other backends.

### Principle 4: Deterministic and Reproducible

All load balancer instances in a cluster must compute the same lookup table given the same set of backends. The algorithm is entirely deterministic—no randomness. The preference lists are built from a hash of the backend's IP and port, combined with an index. This ensures that all Maglev instances independently compute identical tables without needing to exchange state. This property is critical for a stateless load balancer: you can add or remove an instance without coordination, and they will all converge to the same routing decisions.

### Principle 5: Weighted Backends (Optional)

The basic algorithm assumes all backends have equal capacity. In reality, backends may have different weights (e.g., larger machines get more traffic). Maglev can handle weights by assigning a proportional number of slots in the lookup table. For example, if backend A has weight 2 and backend B has weight 1, then A gets twice as many slots as B. The algorithm can be easily adapted by adjusting the "target load" per backend to be proportional to its weight. We'll discuss this later.

---

## The Maglev Hashing Algorithm: Step by Step

Now we will walk through the algorithm in detail. We'll start with the simplest case (equal weights) and then extend. We'll present pseudocode and then explain each step.

### Problem Statement

Given a set of `N` backends (`B0, B1, ..., B_{N-1}`) we want to build a lookup table of size `M` (a prime number) such that:

- Each table entry `t[i]` (for i in 0..M-1) is assigned to a backend.
- The number of entries assigned to each backend is bounded: `floor(M/N) <= count_j <= ceil(M/N)`.
- The assignment minimizes disruption when backends are added or removed.
- The assignment is deterministic.

### Step 1: Generate Preference Lists

For each backend `j`, we generate a permutation of all positions `0..M-1`. This permutation defines the order in which that backend would like to claim table slots. The permutation must be deterministic and different for each backend to avoid collisions. The Maglev paper suggests using a pseudorandom permutation generator based on a hash of the backend's identity (e.g., IP:Port) and an index.

A simple way to generate a permutation is:

```python
def generate_permutation(backend_id: str, M: int) -> list[int]:
    perm = list(range(M))
    # Use a hash to seed a PRNG
    # For deterministic, use a hash function like CRC32 or SHA1 truncated
    import hashlib
    seed = hashlib.md5(backend_id.encode()).digest()
    # Simple Fisher-Yates shuffle using deterministic PRNG (e.g., Mersenne Twister with fixed seed)
    # But that would require seeding a PRNG. Instead, we can use the multiplicative hash trick.
    # The paper uses a simpler approach: for each position i, compute offset and skip.
    # We'll show the actual algorithm later.
```

However, the Maglev algorithm does not require a full permutation per backend. Instead, it constructs **for each backend** a sequence of positions that it will "try" in order. The sequence is generated by:

```
offset = hash1(backend_id) mod M
skip = hash2(backend_id) mod (M - 1) + 1   # must be coprime with M to cover all positions
```

Then for each entry `i` in 0..M-1, the position that backend `j` prefers for its `i`-th choice is:

```
pos = (offset + i * skip) mod M
```

This produces a simple linear congruential generator that cycles through all `M` positions because `skip` is chosen to be coprime with `M` (since `M` is prime, any skip in [1, M-1] is coprime). Note that `skip` is mod (M-1) +1 to ensure it's between 1 and M-1 inclusive.

So the preference list for backend `j` is `[ (offset_j + i * skip_j) mod M for i in 0..M-1 ]`. This list is a permutation of all positions. The algorithm uses two independent hash functions `hash1` and `hash2`. In the paper, they use CRC32 over the backend's IP and port to get a 32-bit value, then split it into two 16-bit halves: `offset = value >> 16`, `skip = (value & 0xFFFF) | 1` (ensuring odd so coprime with power of two? But M is prime, so any nonzero skip works; they want odd to be safe). Alternatively, they use two separate CRC32 computations with different seeds.

### Step 2: Initialize the Table

We create an array `entry` of size `M` initialized to an empty or sentinel value (e.g., -1). We also keep a counter `next[i]` for each backend that tracks which position in its preference list to try next (initially all 0). The goal is to assign each slot to a backend such that no backend exceeds its target load `k = ceil(M/N)`. Actually, the algorithm uses a target of exactly `M/N` (which may be fractional). To get integer counts, we will assign each backend either `floor(M/N)` or `ceil(M/N)` slots. We'll set a maximum count `limit = ceil(M/N)`. There are exactly `R = M mod N` backends that will get `limit` slots, and the rest get `limit - 1`. Which backends get the extra slot? The algorithm implicitly decides based on the order it fills the table.

### Step 3: Populate the Table (Main Loop)

The key idea: iterate through the backends in a fixed order, and for each backend, assign it the _first_ unassigned position in its preference list. After assigning, increment the count for that backend. If the backend has reached its limit, skip it in future iterations. Continue until all slots are filled.

More formally (as described in the paper):

```
Initialize entry[i] = -1 for i in 0..M-1
Initialize next[j] = 0 for each backend j
Let limit = ceil(M / N)
Initialize count[j] = 0

Loop from iteration = 0 to M-1:   (or until all slots filled)
    For each backend j in 0..N-1 (in a cyclic order, but actually fixed order each iteration? The paper says "for each backend j in a fixed order")
        if count[j] >= limit:
            continue
        pos = (offset_j + next[j] * skip_j) mod M
        next[j] += 1
        if entry[pos] == -1:
            entry[pos] = j
            count[j] += 1
            if count[j] == limit:
                # This backend is done; we can stop considering it
                # but the loop still iterates over all backends each iteration to skip them
```

But this naive loop is too slow: it loops M times over N backends, leading to O(M \* N) complexity. For M=65537 and N=1000, that's ~65 million iterations, which is okay for precomputation (a few seconds). However, Google needed faster updates (sub-millisecond). So they optimized.

The actual algorithm in the paper avoids the outer loop over M iterations. Instead, it iterates only over the backends in a round-robin fashion, but the total number of iterations is the sum of all next pointers, which equals M (since each assignment increments some `next[j]` and each assignment fills a slot). The loop is:

```
for each backend j in a fixed cyclic order (e.g., 0,1,...,N-1,0,1,...):
    if count[j] >= limit: continue
    pos = (offset_j + next[j] * skip_j) mod M
    next[j] += 1
    if entry[pos] == -1:
        entry[pos] = j
        count[j] += 1
        # continue loop
```

This continues until all `M` slots are filled. That is, we run the loop until the total assigned count == M. Since each iteration either assigns a slot (if it's free) or finds it occupied, we may need more than M iterations because of collisions. In the worst case, many positions are already taken, so we might have many wasted iterations. However, the total number of iterations is bounded because each backend scans its preference list in order, and once a backend hits a free slot, it takes it. The paper shows that the expected number of iterations is about M (plus a small constant) because preference lists are random permutations. In practice, it's very close to M, and the complexity is O(M \* N) only in pathological cases (which are highly unlikely). The authors of Maglev used a more efficient approach: they precompute for each backend a list of all positions and then do a multi-way merge using a priority queue. But the paper's simplified description is the above.

For clarity, let's present the pseudocode as given in the NSDI paper (Algorithm 1):

```
Algorithm 1: Populate the lookup table
Input: A list of backends B[0..N-1] with their (offset, skip) pairs.
Input: Table size M (prime).
Output: Array entry[0..M-1] where entry[i] ∈ [0, N-1].

// Initialize
for j in 0..N-1:
    count[j] = 0
    next[j] = 0
for i in 0..M-1:
    entry[i] = -1

// Compute the maximum entries per backend
limit = ceil(M / N)

n = 0  // number of assigned slots
while n < M:
    for j in 0..N-1:
        if count[j] >= limit:
            continue
        pos = (offset[j] + next[j] * skip[j]) % M
        next[j] += 1
        if entry[pos] == -1:
            entry[pos] = j
            count[j] += 1
            n += 1
            if n == M:
                break
```

Note: the inner loop goes through all backends each time, but once a backend reaches its limit, it is skipped. This is O(N) per assigned slot, leading to O(M\*N) total. For small N (like 1000) and M=65537, that's 65 million operations, which is fine for a few hundred microseconds on modern hardware. But we can optimize by maintaining a list of active backends (those not yet at limit) and iterating only over those.

### Step 4: Handling Unequal Weights

If backends have weights w_j, we allocate slots proportional to weight. The total capacity sum = sum(w_j). Each backend should get roughly `(M * w_j) / total_capacity` slots. Since slots are integer, we need to floor or ceil. We can compute a target for each backend as `round(M * w_j / total_capacity)` but ensure sum = M. The algorithm works the same, just with different `limit` per backend. The preference lists are still generated from the backend's identity.

### A Concrete Example

Let's work through a small example to build intuition.

Let M = 7 (prime), N = 3 backends: B0, B1, B2. Compute limit = ceil(7/3) = 3. So each backend can get at most 3 slots, and total = 7, so two backends get 3 slots, one gets 1 slot (since 3+3+1=7). Actually, floor(M/N)=2, so two backends get 3, one gets 2? Let's compute: ceil gives 3 per backend max, but sum of limits would be 9, which is greater than 7. So the algorithm will assign some backends 2 slots. The exact distribution depends on fill order.

We need to generate offset and skip for each backend. Let's assume we have hash functions that produce small numbers. For simplicity, let's define:

- B0: offset=0, skip=1
- B1: offset=2, skip=2
- B2: offset=5, skip=3

Now we run the algorithm. I'll simulate manually.

Initialize entry = [-1]\*7, next=[0,0,0], count=[0,0,0], limit=3.

Loop over backends repeatedly (in order B0, B1, B2) until n=7.

Iteration 1 (j=0): count[0]=0 < 3. pos = (0+0*1)%7 = 0. entry[0]==-1 -> assign to B0. entry[0]=0, count[0]=1, n=1.
Iteration 2 (j=1): count[1]=0<3. pos = (2+0*2)%7=2. entry[2]==-1 -> assign B1. entry[2]=1, count[1]=1, n=2.
Iteration 3 (j=2): count[2]=0<3. pos = (5+0*3)%7=5. entry[5]==-1 -> assign B2. entry[5]=2, count[2]=1, n=3.
Iteration 4 (j=0): count[0]=1<3. next[0]=1. pos=(0+1*1)%7=1. entry[1]==-1 -> assign B0. entry[1]=0, count[0]=2, n=4.
Iteration 5 (j=1): count[1]=1<3. next[1]=1. pos=(2+1*2)%7=4. entry[4]==-1 -> assign B1. entry[4]=1, count[1]=2, n=5.
Iteration 6 (j=2): count[2]=1<3. next[2]=1. pos=(5+1*3)%7=8%7=1. entry[1] is already taken (value 0). So no assignment. count[2] remains 1, next[2]=2.
Iteration 7 (j=0): count[0]=2<3. next[0]=2. pos=(0+2*1)%7=2. entry[2] taken (value 1). No assignment. next[0]=3.
Iteration 8 (j=1): count[1]=2<3. next[1]=2. pos=(2+2*2)%7=6. entry[6]==-1 -> assign B1. entry[6]=1, count[1]=3, now count[1]==limit => skip in future. n=6.
Iteration 9 (j=2): count[2]=1<3. next[2]=2. pos=(5+2*3)%7=11%7=4. entry[4] taken (value 1). Next[2]=3.
Iteration 10 (j=0): count[0]=2<3. next[0]=3. pos=(0+3*1)%7=3. entry[3]==-1 -> assign B0. entry[3]=0, count[0]=3, now at limit. n=7. Stop.

Final assignment:
entry[0]=B0, entry[1]=B0, entry[2]=B1, entry[3]=B0, entry[4]=B1, entry[5]=B2, entry[6]=B1.
Counts: B0: 3, B1: 3, B2: 1. So B2 gets only 1 slot, which is below its fair share of 7/3 ≈ 2.33. This is okay because the limit is 3 and we didn't enforce a lower bound. In practice, the algorithm can be modified to also enforce a minimum bound (floor(M/N)). But Google found that as long as the upper bound is tight, the lower bound automatically becomes close to floor. In this case, B2 got 1, which is floor(7/3)=2, so it's below. However, with larger M, such deviations are rare. The paper notes that the algorithm tends to produce near-perfect distribution, but there is no guarantee of a minimum. For production, they probably check and adjust.

Now, let's see what happens if we add a fourth backend B3. It would need to fill 9 slots (since now N=4, M=7? Actually M stays fixed, so we need to repopulate the table with 4 backends. The disruption will be that some existing entries change from B0/B1/B2 to B3. Because the algorithm is deterministic, we can compute the new table and compare.

---

## Load Bounds: Ensuring Fair Distribution

The previous section showed how Maglev builds the lookup table. But the critical innovation is the **load bound**. The algorithm explicitly limits the number of slots a single backend can get to `ceil(M / N)`. This is a hard guarantee: no backend can receive more than `ceil(M/N)` slots. Since each slot corresponds to a packet flow (identified by its 5-tuple hash), and assuming the hash function distributes flows uniformly, the actual traffic load to a backend is proportional to the number of slots it owns. Therefore, the relative load between the busiest and the least busy backend is at most `ceil(M/N) / floor(M/N) ≈ 1 + 1/floor(M/N)`. For M=65537 and N=1000, floor=65, ratio=66/65=1.015, or 1.5% imbalance. That's outstanding.

But does the algorithm actually guarantee that each backend gets at most `ceil(M/N)` slots? Yes, because we set `limit = ceil(M/N)` and we never assign a slot to a backend that has already reached its limit. The loop condition checks `count[j] >= limit` before attempting assignment. So no backend can exceed that limit. However, we must ensure that it is possible to assign all M slots with these constraints. Since the sum of `limit` over all backends is at least M (`N * ceil(M/N) >= M`), it's possible in principle. The algorithm may fail to fill all slots if it runs into a deadlock? For example, if all remaining free slots are in positions that are only reachable in the preference lists of backends that have already hit their limit. But because each backend's preference list covers all positions, and we keep iterating until all slots are filled, eventually each slot will be claimed by some backend that still has capacity. The proof relies on the fact that for any set of backends not yet at capacity, the union of their remaining preference positions covers the whole table? Not necessarily. However, the algorithm's round-robin nature and the fact that each backend scans all positions ensures that eventually every free slot will be encountered by some backend that is still active. The paper claims it always terminates with a full table. I haven't seen a formal proof, but empirical results in the paper and in practice confirm it works.

### Why Load Bounds Matter in Practice

Consider a scenario where a backend becomes overloaded. In a naive approach, you might rely on load balancer to spread traffic evenly, but if the hashing is imperfect, the overload persists. With Maglev, once you know the capacity of each backend (say 10 Gbps), you can set the load limit accordingly. If the total expected traffic is 100 Gbps, and you have 10 backends, each should get 10 Gbps. With load bounds, the maximum any backend gets is `ceil(M/10)` slots. If each slot represents roughly 10000 flows, then the traffic per backend is bounded. If a backend fails, its slots are redistributed among the remaining backends. Because the algorithm ensures that each remaining backend's slot count does not exceed `ceil(M/(N-1))`, the maximum load on any surviving backend is predictable. This allows operators to plan headroom.

Without load bounds, when a server fails in a consistent hash ring, the neighboring servers get all its load. If the ring is sparsely populated, those neighbors might double their load and crash. Maglev avoids this cascade by limiting the maximum load per server to a predetermined fraction of total capacity.

---

## Handling Membership Changes

One of the strongest features of Maglev is its handling of membership changes. When a backend is added or removed, the lookup table must be recomputed (since the set of backends changes). However, the algorithm ensures that the number of reassigned entries is very close to the optimal minimum.

### Adding a Backend

When a new backend is added, we include it in the list of backends and rerun the population algorithm from scratch. The resulting table will be identical for all previously existing backends except for some entries that are now assigned to the new backend. How many entries change? In the best case, only the slots that the new backend takes (approximately `M / (N+1)` slots) change. In the worst case, because the algorithm is not optimal, some additional entries might shift. The paper reports an average of about 50% more than the ideal, but still linear in the number of new slots. For large M, the disruption is minimal.

### Removing a Backend

Removal is similar. The table is recomputed without the removed backend. The slots that were assigned to that backend (approximately `M / N` slots) will be redistributed among the remaining backends. The algorithm tries to preserve existing assignments as much as possible. Since the preference lists for the remaining backends haven't changed, many of their previously assigned positions remain the same. The paper shows that in practice, the number of reassigned entries is very close to `M/N` (the number of slots the removed backend owned). This is near-optimal: to maintain load bounds, you must reassign at least that many entries.

### Why Not Incremental Updates?

You might wonder why Maglev doesn't update the table incrementally (e.g., only change the slots of the removed backend). The problem is that whether you add or remove a backend, the load bounds change: `ceil(M / (N+1))` or `ceil(M / (N-1))` are different from the old limits. To maintain the strict load bound guarantee, you may need to rebalance the slots. For example, if a backend leaves, the remaining backends now have a higher capacity per backend (since fewer backends share the same total traffic). Their maximum allowed slots increase from `ceil(M / N)` to `ceil(M / (N-1))`. So some backends that were at the previous limit can now accept more slots. The algorithm naturally achieves this by recomputing the full table. Because the preference lists are fixed, the reassignment respects the original ordering for each backend: a backend will claim its most preferred available positions, which may cause it to claim positions that were previously assigned to other backends (the removed one or others). This can lead to a cascade of changes beyond the removed backend's slots. However, the paper shows that the cascade is limited.

### Consistency Across Instances

In a real Maglev deployment, there are multiple load balancer instances (often a cluster of a few dozen). Each instance must be aware of the current set of backends. When a backend is added or removed, a controller (e.g., an SDN controller) updates all Maglev instances with the new backend set. Each instance then independently recomputes the lookup table. Because the algorithm is deterministic, they all produce the same table. This eliminates the need for distributed consensus or state synchronization among load balancers, which is a huge operational win.

---

## Performance and Complexity Analysis

Now let's analyze the algorithm's performance characteristics in terms of time, space, and disruption.

### Lookup Time

Lookup is O(1): compute hash of the 5-tuple (e.g., using CRC32), mod M, array access. This can be done in a handful of CPU cycles. In network load balancers, packet processing pipelines often compute the hash and index into the table in hardware (e.g., using a TCAM or a programmable pipeline). In software, it's a simple memory load. This is orders of magnitude faster than any ring-based approach.

### Space

The table size is M entries, each typically a 2-byte or 4-byte backend identifier. For M=65537, that's 128 KB to 256 KB. Additionally, we need to store the (offset, skip) per backend and the current counters during recomputation, but those are temporary. The per-backend overhead is negligible. The total memory is deterministic and independent of the number of backends (except for the backend list itself). This is a major advantage over virtual node rings, which can use many megabytes.

### Precomputation Time

The time to build the table is O(M _ N) in the naive implementation, but with a priority queue or by maintaining a list of active backends, it can be reduced to O(M _ log N) or even O(M) amortized. In practice, with M=65537 and N=1000, building the table takes a few hundred microseconds on a modern CPU. Google's production Maglev instances recompute the table in less than 100 microseconds, which is fast enough to handle backend changes without dropping packets.

### Disruption (Reassignment Ratio)

When a backend is added or removed, the fraction of table entries that change is approximately `1/N` of the table (the fraction of slots that the backend owned). For N=1000, that's about 0.1% of entries. Additional disruption from reassigning entries that were already occupied by other backends (the ripple effect) increases this fraction, but the paper reports it is still within a few times the minimum. For most workloads, such low disruption is perfectly acceptable. In contrast, a modulo-based approach would change 100% of entries.

### Scalability

The algorithm works well for up to tens of thousands of backends. As N grows, the load bound becomes even tighter (since `ceil(M/N)` approaches `M/N`). The lookup is always O(1), independent of N. The precomputation time scales linearly in M and N, but for very large N (e.g., 100k), M=65537 may be too small: each backend would get less than one slot on average, making the algorithm degenerate. In such cases, M can be increased (e.g., to 2^20 = 1,048,576) but the lookup table becomes larger (4 MB) and may not fit in L2 cache, affecting packet processing throughput. Google likely uses multiple Maglev instances or hierarchical load balancing. For most practical scenarios, N is in the hundreds to low thousands.

---

## Comparison with Alternatives

Let's compare Maglev with other common hashing schemes used in load balancing.

### Modulo Hashing

- **Pros**: Extremely simple; O(1) lookup.
- **Cons**: No consistency; every membership change causes all keys to remap.
- **Load bounds**: None inherently, but you can enforce by rejecting assignments to overloaded backends (requires state).
- **Use case**: Only when backend set is static.

### Consistent Hashing (Ring) with Virtual Nodes

- **Pros**: Good consistency; relatively balanced with enough virtual nodes.
- **Cons**: Lookup is O(log V) where V is total virtual nodes (e.g., O(log N) if virtual nodes per backend is constant). Memory O(V). Load bounds not guaranteed; depends on statistical variance.
- **Use case**: Distributed caches like Memcached, where imbalance is tolerable and lookup cost is acceptable.

### Rendezvous Hashing (Highest Random Weight)

- **Pros**: Very balanced; minimal disruption; can handle weighted backends.
- **Cons**: O(log N) lookup with efficient data structures (e.g., treap) or O(N) if naive. Memory for sorted list of backends. Not as fast as direct array lookup.
- **Use case**: Small to medium backend sets where lookup time is not hyper-critical.

### Jump Consistent Hash

- **Pros**: O(log N) speed; extremely low memory; works well for assigning to numbered shards.
- **Cons**: Only for a small, fixed, sequentially numbered set of backends. Cannot handle arbitrary membership changes easily.
- **Use case**: Database sharding (e.g., Cassandra uses a variant? Actually, Cassandra uses consistent hashing with virtual nodes for their ring).

### Maglev

- **Pros**: O(1) lookup; minimal memory; hard load bounds; very low disruption; supports weighted backends.
- **Cons**: Slightly more complex precomputation; requires M prime and trade-off between memory and granularity; cannot handle extremely large N without increasing M; no built-in priority for sticky sessions (but can be combined with per-packet persistence).
- **Use case**: Network load balancing where speed and predictability are paramount.

### Summary Table

| Feature           | Modulo | Consistent Hashing with Virtual | Rendezvous  | Jump Hash | Maglev       |
| ----------------- | ------ | ------------------------------- | ----------- | --------- | ------------ |
| Lookup Time       | O(1)   | O(log V)                        | O(log N)    | O(log N)  | O(1)         |
| Memory            | ~      | O(V)                            | O(N)        | O(1)      | O(M) (fixed) |
| Consistency       | None   | Good                            | Good        | OK        | Good         |
| Load Bounds       | No     | Statistical                     | Statistical | No        | Yes (hard)   |
| Update Disruption | 100%   | ~1/N                            | ~1/N        | ~1/N      | ~1/N         |
| Weighted Backends | No     | Yes (with virtual)              | Yes         | No        | Yes          |
| Complexity        | Low    | Medium                          | Medium      | Low       | Medium       |

---

## Practical Implementation Considerations

Implementing Maglev in production involves several considerations beyond the core algorithm.

### Choosing M

The table size `M` should be a prime number. Why prime? In the preference list generation, we compute `pos = (offset + i * skip) mod M`. For the sequence to be a permutation of all slots (i.e., cover all residues), `skip` must be coprime with `M`. If `M` is prime, every non-zero skip is coprime. This ensures that no matter the skip, the sequence cycles through all slots. If M is composite, some skips may fail to cover all slots, leading to a situation where a backend's preference list only repeats a subset of positions, potentially causing the algorithm to fail (unfilled slots). The paper uses M=65537 (prime). Another common prime is 524287 (2^19 - 1) or 1048573 (approx 2^20). The choice depends on the desired granularity and memory.

### Hash Functions for Offset and Skip

The paper uses CRC32 over the backend's IP and port to get a 32-bit hash. They then split it: the upper 16 bits become `offset` (mod M? Actually, offset can be any value up to 2^16-1, but they need offset mod M. Since M is close to 2^16, they can take `offset = (hash >> 16) % M`). The lower 16 bits are used to compute skip: `skip = (hash & 0xFFFF) | 1`. This ensures skip is odd, which is coprime with M if M is a prime (or any odd M). Alternatively, they could take `skip = (hash & 0xFFFF) % (M-1) + 1`. The paper's approach is simpler.

For deterministic results across different languages/hardware, CRC32 is good because it is standardized (IEEE 802.3). However, you must ensure the same byte representation of the backend identifier (e.g., concatenate IP as 4 bytes and port as 2 bytes) and use the same CRC32 variant.

### Handling Backend Failures

In Google's Maglev, failed backends are removed from the backend list, and the table is recomputed. The load balancer also implements a health checking mechanism: if a backend is unresponsive, it is removed. The recomputation is triggered by the controller. There is also a mechanism for "graceful removal": the backend is first drained of existing connections (using a stateful tracking of connections) and then removed. During the drain phase, the backend remains in the table but the load balancer may stop sending new connections to it. This is outside the hashing algorithm.

### Integration with Flow Persistence

Many applications require that all packets of a given flow (5-tuple) go to the same backend. Maglev ensures this because the lookup is based on the hash of the 5-tuple. If a backend is removed, flows that were mapped to it will be reassigned to new backends (based on the new table). This is unavoidable. For long-lived connections, the disruption may cause session drops. To mitigate, Maglev can use a second-level state store: for active connections, the load balancer can remember the backend decision (e.g., in a flow table) and override the hash lookup for the duration of the flow. This is a common technique in hardware load balancers. The hash-based forwarding is used for new flows; existing flows use the flow table.

### Weighted Backend Implementation

To support weighted backends, we simply precompute the capacity `cap_j = round(M * w_j / total)`. Then set `limit_j = cap_j`. The sum of limits must equal M (or slightly more, with some adjustment). Then run the same algorithm with per-backend limits. The preference lists remain the same. This works as long as the total capacity sum is not too large relative to M (i.e., each backend gets at least 1 slot). For low-weight backends, you might force them to have at least 1 slot to avoid starving them. The algorithm will naturally assign them at most their limit.

---

## Advanced Topics: Theory and Extensions

### Formal Analysis of Load Bounds

The load bound property is central. Let's formalize: With M slots and N backends, each backend gets at most `ceil(M/N)` slots. Proof: By construction in the algorithm. So the maximum load ratio is `ceil(M/N) / (M/N)`. For large M, this ratio approaches 1. In fact, the maximum number of slots per backend is at most `⌈M/N⌉`, and the minimum is at least `⌊M/N⌋ - C`? Not guaranteed. But the paper does not provide a lower bound. In their experiments, the minimum was always at least `⌊M/N⌋ - 1` due to the random shuffling. In our small example, the minimum was 1 while floor(M/N)=2, so it's off by 1. With larger M, such deviations become rare. It's a minor drawback, but could be problematic if one backend gets significantly less than its share. For critical systems, you might run a post-processing check and reassign slots if imbalance is too large.

### Minimizing Disruption: The Trade-off

The algorithm's reassignment behavior is not optimal. The ideal would be that when a backend is removed, only the slots owned by that backend are reassigned; all other slots stay unchanged. But because the limits change (remaining backends can now take more slots), the algorithm may move some slots from other backends to better balance. For example, if a backend with high load leaves, its slots are freed. The remaining backends, which were previously near their limits, can now take on some of those slots. But they might also give up some of their previous slots to a more preferred position. The result is a net reassignment of about 1.5x the number of removed slots in the worst case. The paper reports that reassignment is typically between 1.2 to 2 times the ideal minimum. This is still far better than the 100% reassignment of modulo hashing.

Several research papers have proposed improvements to achieve near-optimal reassignment while preserving load bounds (e.g., using the "Power of Two Choices" or "Cuckoo Hashing" style). However, Maglev's approach is remarkable for its simplicity and is good enough for production.

### Handling Heterogeneous Backend Capacities

The algorithm can be extended to handle backends with different capacities by assigning a proportional number of slots. But there is a nuance: the load bound should be relative to the capacity, not to the absolute slot count. For example, if backend A has 2x capacity of backend B, it should get roughly 2x the slots. The algorithm already supports this via weighted slots. However, you might also want to enforce that no backend gets more traffic than its capacity. That is, given an expected total traffic, you can compute capacity in terms of slots. For instance, if each slot represents a unit of traffic, then a backend's capacity could be `cap_j` slots. Then we set `limit_j = cap_j`. This ensures the backend never exceeds its capacity.

But what if the total sum of capacities is less than M? Then the algorithm cannot fill all slots because no backend can take them. In practice, you would provision enough capacity to handle the expected total traffic, so M should be chosen such that `sum(cap_j) >= M`. You might also have spare slots to handle load spikes.

### Security Considerations

A malicious user could craft 5-tuples that all hash to the same table slot, thus targeting a specific backend. This is a concern for any deterministic hash-based load balancer. To mitigate, the hash function can include a secret key (e.g., using SipHash) that changes periodically to prevent traffic engineering attacks. However, using a secret key means that different load balancer instances must share the same key to produce consistent tables. This adds complexity. In Google's internal network, they likely assume the network is trusted, but for public-facing load balancers, it's a consideration.

### Integration with Connection Tracking

Maglev is a stateless load balancer: it makes decisions per packet. For long-lived connections, stateless forwarding works because the hash is consistent for the duration of the connection (assuming the backend set doesn't change). However, when backends change, some connections will be disrupted. To avoid this, Google uses an in-kernel connection tracking table that records the actual backend for each active flow. The hashed forwarding is only used for the first packet of a flow; subsequent packets are looked up in the connection table. The Maglev hasher serves as the initial decision maker. This hybrid approach is described in the paper.

---

## Real-World Impact and Adoption

The Maglev paper was published in 2016, but the technology has been in use at Google since at least 2014. It powers the network load balancing for all Google services—Search, Gmail, YouTube, Maps, etc. The load balancer runs on commodity x86 servers with dual 40 Gbps NICs and can handle millions of new connections per second.

Since the paper's release, other companies have adopted similar ideas. For example, Cloudflare's Unimog load balancer (described in 2021) uses a similar direct-lookup table with load bounds, though they use a different algorithm based on rendezvous hashing to build the table. The open-source community has also produced implementations of Maglev hashing in libraries like liblfds, and some commercial load balancers have integrated it.

The key takeaway: the combination of O(1) lookup, hard load bounds, and low disruption made Maglev a significant advance over consistent hashing for the specific domain of network load balancing. It doesn't replace all forms of consistent hashing (e.g., for distributed storage, the ring is still popular), but it shows that by carefully designing the algorithm for the workload (short-lived flows, many backends, high throughput), you can achieve guarantees that were previously thought impractical.

---

## Conclusion

Consistent hashing with load bounds, as embodied by Google's Maglev hasher, is a powerful tool for network load balancing at scale. By replacing the hash ring with a direct lookup table and enforcing a per-backend slot limit, Maglev achieves near-perfect distribution, minimal disruption during membership changes, and blazing fast lookups. Its design reflects a deep understanding of the real-world requirements: speed, memory efficiency, and predictability.

The algorithm is elegant in its simplicity: each backend has a deterministic preference list built from its IP and port; the lookup table is built by backends claiming their most preferred free slot until all slots are assigned, subject to a maximum per backend. This process respects load bounds and automatically balances. Even though it may not be perfectly optimal in terms of disruption, its performance is outstanding in practice.

For engineers building modern distributed systems, the principles of Maglev can inspire similar innovations. Whether you are designing an API gateway, a load balancer for microservices, or a distributed cache, consider whether you need hard load bounds and O(1) lookups. If so, Maglev's approach is a great starting point. The code to implement it is remarkably short—less than 50 lines of Python—and the benefits are enormous.

In the ever-evolving landscape of distributed systems, it's not enough to have a load balancer that "works." You need one that works _predictably_, under all conditions. Maglev delivers on that promise, and its legacy continues to shape how we think about load balancing.

If you have ever had to page your team at 3 a.m. due to a hot spot on your hash ring, you now have a better alternative. The future of load balancing is bounded.

---

## References

- Daniel E. Eisenbud, Cheng Yi, Carlo Contavalli, Cory Smith, Roman Kononov, Eric Mann-Hielscher, Ardas Cilingiroglu, Bin Cheung, Rodrigo Fonseca, Nick McKeown, and Geng Lin. “Maglev: A Fast and Reliable Software Network Load Balancer.” NSDI 2016.
- David Karger et al. “Consistent Hashing and Random Trees: Distributed Caching Protocols for Relieving Hot Spots on the World Wide Web.” STOC 1997.
- John Lamping and Eric Veach. “A Fast, Minimal Memory, Consistent Hash Algorithm.” Google Research 2014.
- Rendezvous hashing: Thaler and Ravishankar, “A name-based mapping scheme for rendezvous.” 1998.
- Cloudflare: “Unimog – Cloudflare’s Load Balancer.” 2021.

---

_Author's note: This blog post is part of a series on advanced load balancing techniques. Stay tuned for future posts on the power of two choices, cuckoo hashing for load balancing, and more._
