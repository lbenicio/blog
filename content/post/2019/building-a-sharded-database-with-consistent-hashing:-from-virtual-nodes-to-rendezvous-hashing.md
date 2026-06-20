---
title: "Building A Sharded Database With Consistent Hashing: From Virtual Nodes To Rendezvous Hashing"
description: "A comprehensive technical exploration of building a sharded database with consistent hashing: from virtual nodes to rendezvous hashing, covering key concepts, practical implementations, and real-world applications."
date: "2019-02-08"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/building-a-sharded-database-with-consistent-hashing-from-virtual-nodes-to-rendezvous-hashing.png"
coverAlt: "Technical visualization representing building a sharded database with consistent hashing: from virtual nodes to rendezvous hashing"
---

# Building A Sharded Database With Consistent Hashing: From Virtual Nodes To Rendezvous Hashing

## Introduction

It starts, as these things always do, with a spike. Not the kind on a cactus, but a spike on a graph—the heart-stopping, hockey-stick-shaped surge in traffic that separates a side project from a real product. One moment your database is purring, handling its modest load of a few thousand reads per second. The next, your CEO is screaming from the roof of a conference room that the app just hit the front page of Hacker News. The database, a single, monolithic instance, doesn’t purr anymore. It groans. Latency climbs from 5 milliseconds to 5 seconds. Connection pools fill up. Timeout errors flood your logs. The site goes dark.

You scale vertically, throwing a larger instance at the problem. It works. For a while. But you know the truth. Vertical scaling has a ceiling, and that ceiling is the physical limit of a single server and your cloud provider’s most expensive SKU. The only permanent escape from the gravitational pull of the single-node database is to shard. To take your monolithic table and slice it into smaller, independent pieces—shards—spread across multiple machines.

At first, sharding feels like liberation. You pick a shard key (user ID, perhaps), and you write a simple routing function. Given a key, you compute a hash, take the modulo of the number of shards ($N$), and send the request to the corresponding node. `node_index = hash('user_123') % 4`. It is elegant. It is mathematical. It is a ticking time bomb.

Because the world does not stop to ask for your permission before it grows. Tomorrow, your four shards are overwhelmed. You need eight. But modulo math is a harsh mistress. When you change $N$ from 4 to 8, every single key remaps to a new node. The old `user_123` data that was on shard 2 might now belong to shard 6. Every query returns stale or empty results until you migrate terabytes of data across the network. The migration itself spikes latency even higher, and your site goes down again—this time not from traffic, but from shuffling bits. You have just discovered the cardinal sin of distributed systems: coupling your data placement logic to the number of nodes.

This is the problem that consistent hashing, virtual nodes, and rendezvous hashing solve. They decouple the mapping of keys to nodes from the node count itself, allowing you to add or remove capacity with minimal disruption. In this deep dive, we will peel back the layers of these algorithms, explore their trade-offs, and build toward a production-ready understanding of how modern databases like Cassandra, DynamoDB, and Riak handle sharding at planetary scale. We’ll move from the naïve modulo approach through the elegant ring of consistent hashing, augment it with virtual nodes for better load distribution, and then explore an even more mathematically compact alternative: rendezvous hashing. Along the way, we’ll examine real implementations, dissect performance characteristics, and learn when each technique shines—and when it falters.

By the end of this 10,000‑word journey, you will not only understand the theory behind these algorithms, but also how to choose the right one for your own distributed database system. Whether you’re building a custom sharding layer for a high‑traffic application or simply want to appreciate how the giants of the industry keep data flowing, this post will equip you with the knowledge to shard without fear.

---

## 1. The Naïve Approach: Modulo Hashing and Its Painful Consequences

Before we can appreciate the elegance of consistent hashing, we must fully understand the depths of the modulo fallacy. The formula `node = hash(key) % N` seems harmless. In a static cluster, it works perfectly: each key maps deterministically to a node, and as long as your hash function is uniform, the load is evenly distributed. The problem is that production clusters are never static. Nodes crash, are decommissioned, or (most commonly) need to be added to handle growth. Let's walk through a concrete scenario.

### 1.1 The Resharding Disaster

Suppose you have a user‑profiles table with 100 million records, distributed across 4 shards running on 4 servers. Each server holds 25 million users. Your hash function is MD5, truncated to a 64‑bit integer. The modulo‑4 mapping means that user A with hash 0x12345678 goes to shard 0 (because 0x12345678 % 4 = 0), user B with hash 0x87654321 goes to shard 1, and so on. Life is good.

Now, traffic grows, and you decide to double capacity to 8 shards. You provision 4 new servers, but you cannot simply move the data around because the routing logic has changed. When you flip the switch to `hash % 8`, every key’s destination changes. The fraction of keys that stay on the same node is only 1/N (in this case, 1/8 of the keys coincidentally land on the same shard). That means 87.5% of your 100 million records—87.5 million user profiles—must be migrated from their old home to a new one.

The migration generates enormous cross‑network traffic. Suppose each record is 1 KB on average. That’s 87.5 TB of data transfer. If your network links are 10 Gbps, a linear transfer would take roughly 70,000 seconds—almost 20 hours. But it’s worse because reads and writes continue during migration, causing contention, deadlocks, and eventually a complete stall. Most teams resort to a maintenance window, taking the database offline. For a business that needs 99.99% uptime, that is not a viable option.

Even if you use a double‑write strategy during migration (writing to both old and new shards), the complexity skyrockets. You need to maintain a mapping of which keys have been migrated, handle crashes during the cutover, and eventually remove the old shard. This is why early internet companies like Flickr and WordPress spent years battling sharding issues.

### 1.2 Hot Spots in Modulo Sharding

Another subtle failure mode of modulo sharding is uneven load distribution due to non‑uniform key access patterns. Even if the hash function distributes keys uniformly, the _workload_ may not be uniform. For example, if your shard key is `user_id`, and 10% of your users generate 90% of the traffic, then the shard that contains those power users is overloaded while others sit idle. Modulo hashing cannot distinguish between hot keys and cold keys; every key is treated equally. You can rebind the hot users to a shard key that includes a prefix, but that adds complexity.

Moreover, if you need to add a new shard to relieve pressure on a hot shard, you cannot simply split the hot key range—modulo mapping is a global function, not range‑based. You would have to rehash everything, causing the migration disaster described above.

### 1.3 The Need for a Dynamic Mapping

The core issue is that modulo hashing defines a _static_ mapping that depends on the cluster size. When the cluster size changes, the mapping _must_ change for all keys. What we need is a mapping that is **independent** of the cluster size, or at least changes minimally when nodes are added or removed. This is the motivation behind consistent hashing, which we will now explore.

---

## 2. Consistent Hashing: The Ring of Salvation

In a landmark 1997 paper, David Karger et al. introduced consistent hashing as a way to distribute keys across a dynamic set of cache machines (the paper was titled "Consistent Hashing and Random Trees: Distributed Caching Protocols for Relieving Hot Spots on the World Wide Web"). The technique was later popularized by Amazon’s Dynamo DB (2007) and open‑source systems like Cassandra and Riak.

The key insight: instead of mapping keys directly to nodes via modulo, we map **both keys and nodes** onto a common circular space—the hash ring—and then assign each key to the nearest node clockwise (or counter‑clockwise) on the ring.

### 2.1 How the Ring Works

Imagine a circle divided into $2^m$ equally spaced points, where $m$ is the number of bits in the hash output (e.g., 64 or 128 bits). The positions on the ring correspond to integer values from 0 to $2^m - 1$.

1. **Assign nodes to positions**: For each node (server) $S_i$, compute `hash(S_i)` (e.g., `hash("server-1")`) and place it at that position on the ring. Typically, we use the same hash function for both keys and node identifiers, ensuring a uniform distribution of nodes around the ring (assuming the hash is good).

2. **Assign keys to nodes**: For a given key $K$, compute `hash(K)` and then walk clockwise around the ring from that position until you find the first node. That node is assigned to handle the key.

To visualize:

```
Position 0:
Node A (hash("A") = 10)
Key X (hash("X") = 5) -> walk to 10 -> Node A
Key Y (hash("Y") = 20) -> wrap around to 0? Actually, if no node at 20, continue to 10? Wait, we need nodes at other positions. Let's add Node B at 30, Node C at 60.
Key Y at 20 -> clockwise finds Node B at 30.
Key Z at 70 -> clockwise from 70 wraps around to 0, then to Node A at 10? That would be wrong. Actually, the ring is circular; after 99 (if 2^m is 100) we go to 0. So if no node after 70, wrap to first node in the ring, which is the one with smallest hash value. But careful: nodes are placed at hash values; we should have at least one node. Let's assume nodes at 10, 30, 60. So key at 70 goes to 10 (since after 70, next node is 10 after wrap).
```

Thus, each node is responsible for the keys in the interval from its predecessor on the ring (clockwise) up to its own position. In a ring with $N$ nodes, each node handles approximately $1/N$ of the key space.

### 2.2 The Magic: Minimal Disruption on Node Changes

Now here’s where consistent hashing shines: when a node is added or removed, only a small fraction of keys need to be remapped.

- **Adding a node**: Suppose we add a new node D at position `hash("D") = 25`. The new node will “steal” keys from the node immediately clockwise from it. Which node is that? Starting from 25, the next node clockwise is B at 30. But wait: keys that were previously assigned to B (from position A’s successor? Let's think systematically). The interval that was previously handled by B is (position of B's predecessor, B]. B's predecessor is A at 10. So keys with hash in (10, 30] went to B. When we insert D at 25, the interval (10, 25] now goes to D, and only (25, 30] goes to B. So D takes about half of B’s interval (assuming uniform distribution). Only the keys in the interval (10, 25] need to be moved from B to D. That is roughly $1/(N+1)$ of all keys on average (if the new node splits an existing interval proportionally). In our example with N=3, that’s ~1/4 = 25% of keys. That's still large? Actually, with 3 nodes each having about 1/3 of the ring, splitting one interval into two halves transfers about 1/6 of all keys. But typical analysis says only $1/N$ of keys are moved on average when adding or removing a node. Let’s check: For N=4, adding a new node moves 1/5 of keys (since new total N=5, fraction moved is 1/5). That’s correct: when number of nodes increases from N to N+1, the fraction of keys that need to move is roughly 1/(N+1). For N large, that’s tiny.

- **Removing a node**: When a node leaves (crashes or is decommissioned), its keys are reassigned to the next node clockwise. Only the keys that belonged to the removed node need to be moved (an average of $1/N$ of all keys).

This property makes consistent hashing ideal for dynamic environments where nodes are frequently added or removed, such as content delivery networks (CDNs) or distributed key‑value stores.

### 2.3 Uniformity and Load Balancing: The Hashing Challenge

Good load balancing in consistent hashing relies on two assumptions:

1. The hash function distributes node positions uniformly around the ring.
2. The hash function distributes key positions uniformly around the ring.

In practice, hash functions like SHA‑1, MD5 (though cryptographically broken for security, still good for uniformity), or non‑cryptographic hashes like MurmurHash3 and CityHash provide excellent uniformity. However, even with a perfect hash function, the distribution of keys among nodes can be skewed because the nodes themselves are placed at random points. Imagine we have only 2 nodes placed close together on the ring: the first node might get only a small slice of the ring, while the second gets almost all the rest. The chance that $N$ random points are evenly spaced is low. This imbalance becomes less severe as the number of nodes increases, but for small clusters (e.g., 3–10 nodes), the load imbalance can be substantial.

Additionally, nodes in a real cluster might have different capacities (e.g., one server has twice the RAM of another). We might want to assign weights to nodes so that a stronger node handles more keys.

These problems lead to the introduction of **virtual nodes**.

---

## 3. Virtual Nodes: Smoothing the Distribution

Virtual nodes (commonly called `vnodes`) are a simple yet powerful refinement. Instead of placing each physical node at a single point on the ring, we assign each physical node multiple **virtual nodes**, each with its own randomly chosen position. For example, if we have 10 physical nodes and we set the number of virtual nodes per physical node to 100, we place 1000 points on the ring, each corresponding to one of the 10 nodes. When a key lands on any of those virtual nodes, it is assigned to the corresponding physical node.

### 3.1 How Virtual Nodes Improve Uniformity

With many virtual points per physical node, the distribution of key assignments becomes much more uniform. This is a direct application of the law of large numbers: as the number of random samples (virtual node positions) increases, the fraction of the ring claimed by each physical node converges to its proportion of the total virtual nodes.

If each physical node has $v$ virtual nodes, then the expected standard deviation of the load (number of keys) among nodes is proportional to $1/\sqrt{v}$. So by increasing $v$, we can achieve arbitrarily good load balance, at the cost of more entries in the ring mapping table and slightly longer lookup times (binary search on a sorted list of size $N \times v$).

### 3.2 Weighted Capacities

Virtual nodes also make it easy to handle heterogeneous hardware. If one server has double the capacity of others, we assign it twice as many virtual nodes. The ring mapping then naturally gives it twice the share of keys. This is far simpler than adjusting weights in a modulo scheme.

### 3.3 Practical Implementations

In Apache Cassandra, each physical node (a “token”) is represented by a large set of virtual tokens (default 256 tokens per node). These tokens are generated randomly and stored at node startup. When a new node joins, it picks tokens that are as evenly spread across the ring as possible using a bootstrapping procedure (often with help from the partitioner). Cassandra’s `Murmur3Partitioner` uses the hash of the row key to determine placement. The number of virtual nodes is configurable.

In DynamoDB, the internal architecture uses consistent hashing with virtual nodes, though the exact number is proprietary. DynamoDB originally used a fixed number of virtual nodes per physical node (something like 100) and relied on the randomness to achieve balance. Later versions introduced more sophisticated replication and load‑balancing techniques.

### 3.4 Trade‑Offs and Overhead

- **Memory**: The token mapping table in memory grows linearly with $v$. For a cluster of 100 nodes with 256 tokens each, that’s 25,600 entries. Each entry stores the token hash and the node identifier. With 8‑byte hashes and 4‑byte node IDs, that’s about 300 KB—trivial. For much larger clusters (thousands of nodes), memory can become non‑negligible but still acceptable.

- **Lookup Time**: To find the node for a key, we compute the hash, then perform a binary search on the sorted list of token positions to find the first token greater than the key hash (clockwise). That’s $O(\log(Nv))$. With $N=1000$ and $v=256$, $Nv=256,000$, $\log_2(256k) \approx 18$, so 18 comparisons. That’s fast.

- **Rebalancing Cost**: When a node is added or removed, only its virtual nodes are moved. Since each physical node has many virtual nodes, the fraction of keys that move is still roughly $1/(N+1)$ (averaged across all keys). However, the movement is distributed across many physical nodes: each existing node donates a small fraction of its keys (proportional to the number of its virtual nodes that are adjacent to the new node's virtual nodes). This spreads the migration load evenly.

- **Implementation Complexity**: The coordinator must maintain a consistent view of the ring across all nodes. This requires a gossip protocol or a distributed consensus for token metadata. Nodes need to be able to handle the situation where a token range is split.

Despite these challenges, virtual nodes have become the standard in consistent hashing implementations. They offer a good balance of simplicity, performance, and load distribution.

---

## 4. Limitations of Consistent Hashing with Virtual Nodes

Even with virtual nodes, consistent hashing is not perfect. Here are some notable drawbacks that have motivated researchers to explore alternative algorithms like rendezvous hashing.

### 4.1 Non‑Uniform Hash Output Can Still Cause Skew

If the underlying hash function has poor output distribution (e.g., using a simple modulo with a non‑prime modulus), the virtual node positions can cluster. But modern hash functions are statistically excellent. A more practical concern is that the number of virtual nodes per physical node is a trade‑off. If you set $v$ too low, the expected variance in load is high. For example, with 10 physical nodes and $v=10$ virtual nodes each, the standard deviation of the fraction of keys assigned to a node can be as high as $\sqrt{(1/10) * (9/10) / 1000? Actually need to compute properly. For 10 nodes each with 10 vnodes, total vnodes = 100. The expected fraction per node = 0.1. The standard deviation of the fraction is $\sqrt{p * (1-p) / n} = \sqrt{0.1 * 0.9 / 100} = \sqrt{0.0009} = 0.03$, so 3% relative error. That’s acceptable. But with 3 nodes and $v=10$, the expected fraction is 1/3, stdev = $\sqrt{(1/3)*(2/3)/30} = \sqrt{0.0074} = 0.086$, absolute error of 8.6%, relative error of 26%—quite high. So for small numbers of physical nodes, you need many virtual nodes to achieve good balance.

### 4.2 Memory Overhead for Large Numbers of Vnodes

In extremely large clusters (e.g., 10,000 nodes), using 256 virtual nodes each results in 2.56 million entries. That’s about 30‑40 MB of memory—still acceptable. But the lookup time increases to $\log_2(2.56M) \approx 22$ comparisons, still fast. However, the metadata synchronization becomes more intensive; gossip rounds must exchange token ownership information. Some systems like DynamoDB originally used a fixed number of virtual nodes (100) but later moved to a dynamic allocation where each physical node has a variable number of virtual nodes based on load—adding complexity.

### 4.3 Inability to Handle Ordered Data (Range Queries)

Consistent hashing (with hashing of keys) destroys any order of keys. If you need to query a range of keys (e.g., all users whose ID is between 1000 and 2000), a hash‑based sharding scheme forces you to scatter queries to all nodes. This is a fundamental trade‑off: hash sharding provides good load distribution but sacrifices range queries. For databases that need efficient range scans, you might use **range‑based sharding** (e.g., split by key prefix), but that introduces hot spots if the range is not chosen carefully. Some systems (like MongoDB) offer both: hash‑based sharding for uniform distribution and range‑based sharding for ordered access. However, consistent hashing itself is agnostic to key ordering; you could modify it to preserve order by using a key’s natural order instead of a hash, but then the “consistent” property for rebalancing is more complex (you get prefix‑splitting techniques like those in Bigtable/Spanner, which use range splitting rather than consistent hashing).

### 4.4 Replication and “Preference Lists”

In distributed databases, replication is essential for fault tolerance. Consistent hashing can easily be extended to support replication by assigning each key to the next $R$ nodes clockwise on the ring (where $R$ is the replication factor). This creates a “preference list” of nodes that should store a copy of the data. For example, in Dynamo, each key is replicated to the first $R$ distinct nodes on the ring after the key’s token. This works well, but care must be taken to ensure that the replicas are placed on different failure domains (racks, data centers). The ring does not inherently consider physical topology; you must assign virtual nodes to physical nodes with awareness of these constraints (often using custom placement strategies).

Virtual nodes actually complicate replication: a single physical node may have many virtual nodes, and two copies of the same key could accidentally land on the same physical node if the preference list includes two virtual nodes that belong to the same physical node. The system must skip duplicate physical nodes when building the preference list. This is a manageable but important detail.

---

## 5. Rendezvous Hashing: A Different Path

Rendezvous hashing (also known as **Highest Random Weight (HRW)** hashing) is an alternative approach that avoids the complexities of the ring and virtual nodes altogether. It was introduced in 1996 by Michael Rabin and Guenter M. B. P. (though the exact origin is debated) and later formalized by John Morton. The core idea is surprisingly simple: given a key and a set of nodes, assign the key to the node that produces the **highest** combined hash value.

### 5.1 How Rendezvous Hashing Works

For each key $K$ and each node $S_i$, compute a weight $w_i = hash(S_i \oplus K)$, where $\oplus$ is some combination (often string concatenation). Then pick the node with the maximum weight:

$$ \text{assigned_node}(K) = \arg\max\_{S_i} \, \text{hash}(S_i \, || \, K) $$

That’s it. No ring, no binary search, no virtual nodes. The key is assigned to the node that “wins” the contest.

### 5.2 Properties

- **Consistent mapping**: If a node is added or removed, only the keys that had that node as the winner will change. For a given key, if its winner is removed, the next highest weight becomes the winner—which was likely the second‑highest from before. So only keys that previously mapped to the removed node need to be moved. The fraction of keys moved is exactly $1/N$ (assuming equal load capacity), identical to consistent hashing.

- **No need for virtual nodes**: Because the hash function produces values that are effectively random, the load distribution among nodes is uniform _in expectation_ without any extra parameters. But there is variance; the standard deviation is $\sqrt{N-1} / N \approx 1/\sqrt{N}$ relative. For 100 nodes, that’s about 10% relative error—comparable to consistent hashing with a moderate number of virtual nodes. However, you cannot tune the variance by adding virtual nodes; the variance is inherent to the random assignment. If you need tighter control, you can assign weights to nodes (e.g., multiply the weight by capacity factor) or use a technique like **weighted rendezvous hashing** (see later).

- **Simplicity**: The algorithm is trivial to implement and understand. No need to maintain a sorted ring or handle token metadata. This makes it appealing for systems where simplicity and small code footprint matter, such as in client‑side load balancing.

### 5.3 Performance Analysis

The naive implementation of rendezvous hashing requires $O(N)$ work per lookup: you must iterate over all nodes to compute weights and find the maximum. For a small cluster (few tens of nodes), this is acceptable. For large clusters (thousands of nodes), $O(N)$ per request becomes a bottleneck. However, many deployments have a moderate number of nodes (e.g., 10–200), so $O(N)$ is fine.

There are techniques to reduce lookup cost:

- **Tree‑based rendezvous hashing**: Build a binary tree of nodes where each internal node stores the “winner” of its subtree for a given key. Then lookup becomes $O(\log N)$. But the tree must be rebuilt when nodes change, which introduces complexity.

- **Multi‑level rendezvous**: Partition nodes into groups, perform rendezvous within a group, then between groups. This can achieve sub‑linear lookup with careful construction.

- **Caching the winner**: In many workloads, the same key is accessed repeatedly. If you cache the mapping (at least temporarily), the cost amortizes.

### 5.4 Weighted Rendezvous Hashing

To assign different capacities to nodes, you can modify the weight function: $w_i = \text{hash}(S_i \, || \, K) / \text{load\_capacity}(S_i)$. Or more commonly, $w_i = \text{hash}(S_i \, || \, K) + \text{scaled\_factor}$. The simplest is to pre‑multiply the hash by a capacity factor. For example, if node A has capacity 2 and node B has capacity 1, you can artificially insert two “virtual” copies of node A into the contestants, each with its own ID (e.g., `A-1`, `A-2`). Then the probability that a key picks A becomes twice that of picking B. This is similar to virtual nodes in consistent hashing, but now the number of virtual nodes is very small (proportional to capacity) and they are not needed for distribution.

However, note that rendezvous hashing without virtual nodes does **not** automatically handle weighted capacities. You must either use weight factors in the hash computation or simulate virtual nodes.

### 5.5 Comparison with Consistent Hashing

| Feature                      | Consistent Hashing (with vnodes)    | Rendezvous Hashing                              |
| ---------------------------- | ----------------------------------- | ----------------------------------------------- |
| Lookup complexity            | $O(\log(Nv))$                       | $O(N)$ naive, $O(\log N)$ with tree             |
| Memory overhead              | $O(Nv)$ for token list              | $O(N)$ for node list (plus optional tree)       |
| Load distribution variance   | Can be reduced by increasing $v$    | Fixed variance $1/\sqrt{N}$ (without weighting) |
| Node addition/removal        | Minimal (fraction $1/(N+1)$)        | Minimal (fraction $1/(N+1)$)                    |
| Handling weighted capacities | Trivial via different $v$           | Requires virtual nodes or weighted hash         |
| Simplicity                   | Moderate (ring maintenance, gossip) | Very simple (just max over weights)             |
| Range queries                | Not supported                       | Not supported                                   |

**When to use which?**

- Use **consistent hashing with virtual nodes** when you have a large number of nodes (>500) and need fast lookups, or when you need fine‑grained control over load distribution (e.g., heterogeneous hardware). It’s the workhorse of systems like Cassandra, Riak, and DynamoDB.

- Use **rendezvous hashing** when your cluster is small to moderate (up to a few hundred nodes), when simplicity and easy implementation are paramount, and when you can tolerate the extra per‑request computation. It is also a good choice for client‑side partitioning where the client cannot afford to maintain a complex ring structure. For example, some distributed caching systems use rendezvous hashing for cache affinity.

---

## 6. Jump Consistent Hash: A Minimalist Speed Demon

There is a third important variant worth mentioning: **jump consistent hash** (JCH), introduced by John Lamping and Eric Veach in 2014 (Google). It is designed for cases where the number of nodes changes only by adding new nodes to the end of a sorted list (a typical scenario for sharding a cache). Jump consistent hash produces a mapping that changes minimally when nodes are added, but only at the _end_ of the node list. It is incredibly fast ($O(\log N)$) and uses no memory beyond the hash function and the key.

### 6.1 How Jump Consistent Hash Works

The algorithm works by simulating a “jump” process. Given a key, it determines the bucket number by repeatedly tossing a biased coin to decide when the bucket number should increase. The pseudocode:

```python
def jump_consistent_hash(key, num_buckets):
    bucket = -1
    j = 0
    while j < num_buckets:
        bucket = j
        key = hash(key, j)  # some integer hash
        j = int((key + 2.0) / (1.0 + 2.0 * ... )) # actual formula
        # The actual formula uses floating point: j = int( (bucket + 1) / (key / 2^32) )
        # But we'll not detail here.
    return bucket
```

The key property: when `num_buckets` increases from N to N+1, only the fraction $1/(N+1)$ of keys move to the new bucket (exactly the proportion we want). But those keys are exactly the ones that would have been placed at an imaginary bucket N before the addition. The mapping for other keys remains unchanged.

### 6.2 Limitations

- The algorithm only works when node identifiers are consecutive integers from 0 to N‑1. You cannot name your nodes arbitrarily; you must map node IDs to these indices. Adding a node means appending it to the end; you cannot remove a non‑last node without causing many remappings.
- It does not support weighted capacities directly (though you can pre‑multiply N).
- It is not suitable for dynamic node removal (crashes) unless you can rearrange indices.

Jump consistent hash is excellent for cache sharding where you start with a fixed number of machines and only add machines over time (and you can tolerate occasional complete rehashing if a machine dies). It is used internally by Google’s Memcache service and in some load balancers.

---

## 7. Practical Implementation in Python

Let’s solidify our understanding with concrete code. We’ll implement both consistent hashing (with virtual nodes) and rendezvous hashing, and simulate a migration scenario.

### 7.1 Consistent Hashing Ring (with Virtual Nodes)

We will use SHA‑256 as our hash function, truncated to 64 bits for ring positions.

```python
import hashlib
import bisect

class ConsistentHashRing:
    def __init__(self, nodes=None, vnodes_per_node=150):
        self.vnodes_per_node = vnodes_per_node
        self.ring = []          # sorted list of hash values
        self.nodes = {}         # mapping from hash value -> node identifier
        self.node_list = {}     # node identifier -> list of its vnode hashes
        if nodes:
            for node in nodes:
                self.add_node(node)

    def _hash(self, key):
        return int(hashlib.sha256(key.encode('utf-8')).hexdigest(), 16) & ((1 << 64) - 1)

    def add_node(self, node):
        # Create virtual nodes
        vnode_hashes = []
        for i in range(self.vnodes_per_node):
            vnode_key = f"{node}-{i}"
            h = self._hash(vnode_key)
            bisect.insort(self.ring, h)
            self.nodes[h] = node
            vnode_hashes.append(h)
        self.node_list[node] = vnode_hashes

    def remove_node(self, node):
        for h in self.node_list.get(node, []):
            self.ring.remove(h)
            del self.nodes[h]
        del self.node_list[node]

    def get_node(self, key):
        if not self.ring:
            return None
        key_hash = self._hash(key)
        # find the first token >= key_hash, wrap around to first if beyond last
        idx = bisect.bisect_left(self.ring, key_hash)
        if idx == len(self.ring):
            idx = 0
        return self.nodes[self.ring[idx]]
```

### 7.2 Rendezvous Hashing

```python
def rendezvous_hash(key, nodes, hash_func=hashlib.sha256):
    """
    Returns the node from list nodes that has highest combined hash with key.
    """
    best_node = None
    best_weight = -1
    for node in nodes:
        combined = f"{node}-{key}"
        weight = int(hash_func(combined.encode('utf-8')).hexdigest(), 16)
        if weight > best_weight:
            best_weight = weight
            best_node = node
    return best_node
```

### 7.3 Simulating Resharding

Let’s compare the migration overhead when adding a node. We’ll generate 100,000 random keys and measure how many remap under each scheme.

```python
import random
import string

def random_key(length=10):
    return ''.join(random.choices(string.ascii_letters, k=length))

# Initial set of nodes
nodes = [f"node-{i}" for i in range(4)]
ring = ConsistentHashRing(nodes)
mapping_old = {k: ring.get_node(k) for k in keys}   # assume keys list defined

# Add a new node
ring.add_node("node-4")
mapping_new = {k: ring.get_node(k) for k in keys}

# Count changes
changes = sum(1 for k in mapping_old if mapping_old[k] != mapping_new[k])
print(f"Consistent hashing: {changes} keys moved out of {len(keys)} ({100*changes/len(keys):.2f}%)")
```

Expected output: about 20% moved (1/5 of keys). For rendezvous:

```python
nodes_old = nodes[:]
nodes_new = nodes + ["node-4"]
mapping_old = {k: rendezvous_hash(k, nodes_old) for k in keys}
mapping_new = {k: rendezvous_hash(k, nodes_new) for k in keys}
changes = sum(1 for k in mapping_old if mapping_old[k] != mapping_new[k])
print(f"Rendezvous hashing: {changes} keys moved ({100*changes/len(keys):.2f}%)")
```

Also about 20%. Good.

### 7.4 Load Distribution

We can also measure the standard deviation of the load across nodes:

```python
# For consistent hashing
loads = {node: 0 for node in nodes}
for k in keys:
    loads[ring.get_node(k)] += 1
mean = sum(loads.values())/len(loads)
variance = sum((loads[n] - mean)**2 for n in loads) / len(loads)
print(f"Std dev (consistent): {variance**0.5:.2f}")

# Increase vnodes_per_node to 1000 and see improvement.
```

---

## 8. Real‑World Case Study: Scaling from 4 to 8 Shards

Let’s walk through a detailed scenario to appreciate the operational differences.

**Scenario:** You run a social media analytics platform. Your `posts` table has 500 million rows, each row about 2 KB (1 TB of data). You currently have 4 shards (servers), each storing about 125 million rows. Read/write ratio is 10:1, peak load 50,000 QPS.

**Problem:** Traffic is growing, and the shards are running at 70% CPU and 60% disk IO. You need to double capacity to 8 shards. Under naïve modulo, you’d need to move 87.5% of data. With consistent hashing, only 12.5% (1/8) of data moves—still 12.5 million rows per shard? Wait: total data moved = 1/(N+1) = 1/5 of total? Actually adding one node to 4 nodes moves 1/5 of keys? No: from 4 to 8? That's adding 4 nodes simultaneously. If you add 4 nodes at once, the fraction moved depends on the number of new nodes. For consistent hashing, you can add each node one by one; each addition moves about 1/(current N+1) of keys. Adding 4 nodes results in cumulative movement:

- Add 5th node: moves 1/5 = 20% of keys.
- Add 6th node: moves 1/6 ≈ 16.7% of remaining keys? Actually careful: after first addition, the total has been reshuffled. The fraction of keys moved per addition in a single step is always about 1/(N+1) fraction of the _current_ total. So if you add sequentially starting from 4 nodes:
  - Step 1: from 4 to 5: moves 20% of original data.
  - Step 2: from 5 to 6: moves 1/6 ≈ 16.7% of data that _now_ exists (but note some keys already moved in step 1; however the total movement relative to original state is not simply additive because keys that moved earlier might move again. In fact, the total fraction of keys that have been moved at least once by the time you reach 8 nodes can be computed as $1 - \prod_{i=4}^{7} (1 - 1/(i+1)) = 1 - (4/5 * 5/6 * 6/7 * 7/8) = 1 - 4/8 = 0.5$. So after adding 4 nodes, 50% of keys have moved at least once. That’s still a lot of migration traffic, but much better than 87.5%.

In practice, you would add nodes gradually, allowing each migration to settle before the next. Each migration step moves only ~1/N of the data, which is manageable. The network load is spread out over time. If your total data is 1 TB, moving 250 GB in the first step (20%) and then ~200 GB in the next, etc., over 4 steps you move a total of about 1 TB (since the same key can move multiple times). This is feasible over a weekend.

**Rendezvous hashing**: With rendezvous, each addition also moves about 1/(N+1) fraction; but since there are no virtual nodes, the migration is just moving those keys for which the removed node was the winner. Same as consistent hashing. So the overhead is similar.

However, the lookup cost per request: with 8 nodes, rendezvous does 8 hash computations per request. Consistent hashing does $\log_2(4*150) \approx 10$ comparisons (if using binary search). Both acceptable.

**Decision:** For this moderate cluster size (8–20 nodes), either algorithm works. But if you plan to eventually have hundreds of nodes, consistent hashing with its $O(\log N)$ lookup becomes more attractive. Rendezvous would require optimization (tree structure or caching).

---

## 9. Advanced Topics and Future Directions

### 9.1 Consistent Hashing with Bounded Loads

Standard consistent hashing does not consider the current load of nodes. If a node is overloaded, we might want to offload some of its keys to other nodes without changing the ring (to avoid propagating changes). Techniques like **consistent hashing with bounded loads** (used in Google’s Google Cloud Pub/Sub) allow a client to try the primary node first, and if it’s overloaded (exceeds a capacity threshold), fall back to the next node on the ring. This gives fine‑grained load control without global rebalancing.

### 9.2 Rendezvous Hashing with Locality‑Sensitive Hashing

Rendezvous hashing is essentially a min‑wise independent permutation scheme. By changing the hash function, we can incorporate locality: if two keys are close in some embedding (e.g., geographical region), we might want them to hash to nearby nodes. This is an area of active research.

### 9.3 Comparison with CRDT‑Based Approaches

Some modern databases (e.g., Riak, Redis with CRDTs) use a combination of consistent hashing and conflict‑free replicated data types (CRDTs) to enable eventual consistency without the hassle of master‑slave replication. The sharding layer remains the ring, but replication strategies change.

### 9.4 Automatic Shard Splitting and Merging

In NewSQL databases like CockroachDB, shards (called “ranges”) are automatically split when they exceed a size threshold (e.g., 512 MB). This is a form of range‑based sharding, not hash‑based. However, the placement of ranges onto nodes uses consistent hashing to decide which store should host a range (with replication across stores). The split is handled by splitting the key range, not by rehashing. This hybrid approach shows that no single algorithm dominates; the best choice depends on workload.

---

## 10. Conclusion

We have journeyed from the naïve modulo hashing that breaks under the slightest cluster change, through the elegant ring‑based consistent hashing that revolutionized distributed systems, past the smooth distribution enhancements of virtual nodes, and finally to the simple yet powerful rendezvous hashing. Along the way, we encountered the trade‑offs that every system architect must weigh: lookup speed vs. memory, load uniformity vs. complexity, and ease of implementation vs. scalability.

So, which one should you use for your sharded database?

- **If you are building a large‑scale system with hundreds of nodes, heterogeneous hardware, and require fine‑grained control over load distribution**, choose **consistent hashing with virtual nodes**. This is the proven approach used by Cassandra, DynamoDB, and Riak. Its $O(\log N)$ lookup and tunable variance make it ideal for the big leagues.

- **If your cluster is small (say, fewer than 200 nodes), simplicity is your priority, and you can afford per‑request linear scans (or you implement tree‑based optimization)**, then **rendezvous hashing** is a clean and beautiful solution. It avoids the overhead of maintaining a ring and virtual tokens. It’s a great fit for internal tools or medium‑sized apps.

- **If you have a cache‑like workload where nodes are rarely removed and you need maximum performance with minimal memory**, consider **jump consistent hash**. But be wary of its inflexibility with node indices.

Ultimately, the art of sharding is not just about picking an algorithm—it’s about understanding the dynamics of your data, your traffic, and your operational constraints. The spike on the graph will come again. But armed with consistent hashing, virtual nodes, and rendezvous hashing, you will be ready to handle it without making a mess of your database.

Now go forth and distribute your data wisely. The next time your CEO screams about a front‑page post, you can calmly sip your coffee and add another shard to the ring.
