---
title: "Designing A Sharded Counter With Crdts For Eventually Consistent Analytics"
description: "A comprehensive technical exploration of designing a sharded counter with crdts for eventually consistent analytics, covering key concepts, practical implementations, and real-world applications."
date: "2025-08-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Designing-A-Sharded-Counter-With-Crdts-For-Eventually-Consistent-Analytics.png"
coverAlt: "Technical visualization representing designing a sharded counter with crdts for eventually consistent analytics"
---

# The Philosophy of Counting: How Distributed Systems Learn to Count (and Sometimes Lie)

The year was 2015, and the Internet had a collective, quiet crisis. It wasn’t a security breach or a massive outage. It was a number. Specifically, the “Favorites” counter on Twitter. For months, users had noticed something deeply unsettling: the little red heart (or, at the time, the star) that represented how many people liked a tweet was… lying. It would jump from 5,000 to 10,000, back to 5,000, then to 12,000. It was a haunted jack-in-the-box, popping up with a number that felt less like a metric and more like a suggestion.

The cause, at the time, was a fascinatingly brutal engineering problem. Twitter had moved from a monolithic counter (stored in Redis on a single node) to a sharded, eventually consistent system. They needed speed. For the “time since last tweet” or the list of tweets in your timeline, minor inconsistencies were tolerable. But a count? A count felt absolute. It felt like a fact. And when the Internet’s brain trust saw a fact that was 30% incorrect, the trust fractured. The term “Eventually Consistent” became a punchline for a generation of engineers, a euphemism for “we hope it works, eventually, but we’re not sure when.”

This is the problem that has haunted distributed systems since the days of the CAP theorem: **How do you count things at scale?** It sounds trivial. Increment by one. Decrement by one. We learned that in kindergarten. But when your kindergarten has 100 servers spread across three continents, and the network occasionally turns into a bowl of molasses, the simple act of counting becomes a philosophical war. Do you block all writes until everyone agrees on a number (consistency, but slow)? Do you let every server write locally and try to stitch the numbers together later (fast, but potentially wrong)?

Most systems pick a side. They use a centralized, strongly consistent database (like Google’s Spanner or a single-leader Postgres) to ensure the counter is always “true.” This works for low traffic. But for a global “likes” system handling billions of operations per day, the trade-offs become excruciating. Twitter’s initial journey from a single Redis instance to a sharded, eventually consistent architecture is a textbook case of the CAP theorem in action. And like many such case studies, it reveals that the real lesson isn’t about picking a side—it’s about understanding what your users actually need from a number.

In this post, we’re going to dive deep into the distributed counting problem. We’ll start with the simple, idealized world of a single machine and then watch it shatter under the weight of network partitions, concurrent writes, and global replication. We’ll look at classic strong-consistency approaches, the allure of eventual consistency, the promise of CRDTs (Conflict-Free Replicated Data Types), and the practicality of approximate algorithms like HyperLogLog. By the end, you’ll not only understand why Twitter’s “likes” danced around like a ghost, but you’ll also have a toolkit for thinking about correctness, performance, and user trust in your own distributed systems.

---

## 1. The Simple World: Counting on a Single Machine

Let’s start where every engineer’s intuition begins. On a single machine, counting is trivial. In most programming languages, you write something like:

```python
counter = 0
def increment():
    global counter
    counter += 1
```

This is a perfectly correct, linearizable counter. In the absence of concurrency, it’s always accurate. Even with concurrency, a single machine can use a mutex or an atomic increment (like `fetch_and_add` on a CPU) to ensure that two simultaneous increments don’t clobber each other.

```c
// C with atomic builtins
atomic_int counter = 0;
void increment() {
    atomic_fetch_add(&counter, 1);
}
```

The key ingredient is a shared, mutable state that all threads or processes can access with low latency and total ordering. In a database, this translates to a single-node relational database with `SERIALIZABLE` isolation. For example, in PostgreSQL:

```sql
BEGIN;
UPDATE likes SET count = count + 1 WHERE tweet_id = 42;
COMMIT;
```

This works flawlessly for small-scale applications. But as soon as you need to serve traffic from multiple data centers, or as soon as your write throughput exceeds what a single machine can handle, you have to distribute the counter across multiple nodes. And that’s when the trouble begins.

---

## 2. The CAP Theorem: Why Distributed Counting Is a Philosophical War

The CAP theorem (Brewer’s theorem) states that a distributed data store can provide only two of the following three guarantees simultaneously:

- **Consistency (C):** Every read receives the most recent write or an error.
- **Availability (A):** Every request receives a (non-error) response, without the guarantee that it contains the most recent write.
- **Partition Tolerance (P):** The system continues to function despite arbitrary message loss or network partitions between nodes.

In a world without network partitions, you could achieve both C and A. But networks are unreliable. So in practice, every distributed system must choose between CP (Consistency + Partition Tolerance) and AP (Availability + Partition Tolerance). The trade-off is fundamental.

For a counter, a CP system would block writes if it cannot guarantee that all nodes see the same value. An AP system would accept writes anytime, but may return stale or conflicting values.

Most large-scale web services choose AP because the Internet is an unreliable place. But counters are special. A counter that lies—even by a small amount—can erode user trust. Twitter’s “likes” issue wasn’t just about accuracy; it was about the perceived integrity of the platform. When a number is presented as a fact, any inconsistency feels like deception.

### Strong Consistency Approaches

Let’s look at how a CP system might handle a global counter.

#### Single-Leader Replication

The simplest approach is to designate one node as the leader that owns the counter. All writes go to the leader, which then replicates the updated value to followers synchronously (or asynchronously). Reads can be served from the leader (strongly consistent) or from followers (eventually consistent). For a counter, you want reads to be consistent, so you read from the leader.

```text
Client -> Leader (write increment) -> Leader applies -> replicates to followers
Client -> Leader (read count) -> return leader's value
```

The problem is the leader becomes a bottleneck. For Twitter's scale—millions of likes per minute—a single leader cannot possibly handle the write load. You could shard by tweet ID (different leaders for different tweets), but even then, a single node might serve a viral tweet. And if the leader goes down, you have a failover process that can take seconds or minutes, during which writes are blocked.

#### Distributed Consensus (Paxos / Raft)

You can use a consensus algorithm like Raft or Paxos to ensure that every increment is agreed upon by a majority of nodes. This gives you linearizability: the counter appears as if it were on a single machine.

```go
// Pseudocode for a Raft-based increment
func increment(counterID string) {
    proposal := prepareProposal(counterID, +1)
    consensus := raftPropose(proposal)
    if consensus {
        applyIncrement(counterID)
    }
}
```

This is what Google’s Spanner does under the hood, using the TrueTime API to provide external consistency. But the latency cost is high—each increment requires multiple network round-trips between nodes in different data centers. For a “like” button that must respond in under 200ms, that’s often too slow.

#### ZooKeeper / etcd

You could also use a coordination service like ZooKeeper or etcd to store a counter as a single key. These systems use consensus to provide linearizable writes. However, they are not designed for high throughput writes. A typical etcd cluster can handle a few thousand writes per second. Twitter needs millions per second. So this approach doesn’t scale.

---

## 3. The Allure of Speed: Eventual Consistency for Counters

Given the performance limitations of strong consistency, many systems opt for eventual consistency. The idea is simple: let each node maintain its own local copy of the counter, accept increments locally, and periodically synchronize with other nodes. The final count is the sum (or merge) of all local counts. This is fast because writes are processed locally without any cross-node coordination.

### How Twitter Sharded Its Counters

In 2013, Twitter stored counters in a single Redis instance. As traffic grew, that Redis server couldn’t keep up. They moved to a sharded Redis cluster: each tweet’s like count was assigned to one of many Redis shards based on the tweet ID. This is essentially a pre-sharded, centralized design—each shard is still strongly consistent within itself, but the overall system is partitioned horizontally.

But then came the need for global replication across data centers. A tweet liked in Tokyo should eventually show up in the count visible to a user in New York. To do this without high latency, Twitter allowed each data center to have its own replica of the counter. Writes were accepted locally and then asynchronously replicated to other data centers. This is the classic “multi-leader” or “active-active” setup.

### The Problem: Concurrent Updates and Lost Writes

Consider two data centers: US-East (US) and Asia-Pacific (APAC). Two users, Alice in New York and Bob in Tokyo, simultaneously click the “like” button on the same tweet. The local counters in each data center increment to 1. Then, during replication, each data center sends its current local count to the other. Without careful design, both data centers might simply replace their count with the received value:

- US has count=1, receives count=1 from APAC, sets its count to 1 (no change).
- APAC has count=1, receives count=1 from US, sets its count to 1.

Now the global count is 1, but it should be 2. This is a classic **lost update** problem. To avoid it, you need to _merge_ counts rather than overwrite them. The simplest merge is **addition**: each node keeps track of _all increments_ it has seen and sends that delta to other nodes. If each node sends the number of local increments it performed (or a list of increment operations), then the receiving node can add them to its own delta. This way, the total count becomes the sum of all deltas across all nodes.

This is essentially an **operation-based** approach, and it’s the foundation of Conflict-Free Replicated Data Types (CRDTs). But before we dive into CRDTs, let’s see why Twitter’s eventual consistency system still produced incorrect numbers.

### Twitter’s Specific Failure

Twitter’s early implementation of sharded counters used a “last-writer-wins” (LWW) approach combined with time-based conflict resolution. Each write would include a timestamp (from the local machine’s clock). When a node received a replication update, it would compare timestamps and keep the one with the latest timestamp. This is a common pitfall.

Clocks are not perfectly synchronized across machines. Even with NTP, there can be clock skew of tens of milliseconds, sometimes more. If two increments happen at nearly the same time, the one with the later timestamp wins, but the other increment is lost. Worse, if a node’s clock drifts backwards (due to NTP correction), a later write might have an earlier timestamp, causing it to be ignored. The result: the count could go down when replication occurred, causing the wild oscillations observed by users.

### The JavaScript Example: A Mental Model

Imagine a primitive distributed counter built with just timestamps and overwrite:

```python
# Node A
local_count = 0
last_timestamp = 0.0

def increment():
    global local_count, last_timestamp
    local_count += 1
    last_timestamp = time.now()
    replicate_to_other_nodes({'count': local_count, 'ts': last_timestamp})

def on_receive(data):
    global local_count, last_timestamp
    if data['ts'] > last_timestamp:
        local_count = data['count']
        last_timestamp = data['ts']
```

Two nodes running this code will experience lost updates and count decreases due to clock skew. This is exactly what caused Twitter’s heart to dance.

---

## 4. When Counting Breaks: A Deeper Look at Inconsistencies

Let’s categorize the ways an eventually consistent counter can go wrong.

### Lost Increments (Missed Updates)

As shown above, if two nodes each perform an increment and replicate via a last-writer-wins scheme, one increment disappears. The canonical example: two users like a tweet at the same moment, but the counter shows only one like. In a system with millions of likes, even a 0.1% loss rate means thousands of likes vanish.

### Double Counting (Overcounts)

If the replication mechanism is not idempotent, the same increment might be applied multiple times. For example, if a node sends its delta multiple times due to retries, and the receiver does not deduplicate, the count inflates. With pure additive merging (no tracking of which increments have been seen), you can easily double-count.

### Oscillations (Count Goes Down)

This is the most disconcerting for users. A count can appear to decrease because a node previously had a higher local value, then received a replication from another node with a lower value and overwrote its own. Net effect: the global sum drops temporarily until the missing increments are replayed. Twitter’s users saw counts drop from 10,000 to 5,000 and back up—that’s oscillation.

### Ordering Violations and Non-commutativity

Even if you use additive merging, you need to ensure that increments are commutative. Addition is commutative, so merging by summing should be safe. However, if you have decrements as well (e.g., unlikes), you need to be careful. Subtraction is not commutative with addition in the presence of order-dependence? Actually, addition and subtraction are commutative as operations but not as state merges if you only send net deltas. Let’s explore.

If you allow both likes and unlikes, you could represent the counter as an integer that can be incremented or decremented. In a distributed setting, you might have two nodes:

- Node A sees two likes and one unlike → net +1.
- Node B sees one like → net +1.

Merging by adding net deltas: (+1) + (+1) = +2. But reality might have been that Alice liked, then Bob unliked, then Charlie liked. The correct count should be 1 (assuming initial 0). Wait, let’s be precise:

- Initial count = 0.
- Alice likes: +1 → count=1.
- Bob unlikes: -1 → count=0.
- Charlie likes: +1 → count=1.

If Node A only saw Alice’s like and Bob’s unlike (net 0), and Node B only saw Charlie’s like (net +1), then merging net deltas gives +1. But the actual sequence is:

If Node A had the state after Alice and Bob: count_A=0. Node B after Charlie: count_B=1. Merge by summing local states: 0 + 1 = 1. That matches. But if Node A had not seen Bob’s unlike yet (so net +1), and Node B had Charlie’s like (net +1), then merging net deltas yields +2. However, this is an artifact of not having a globally consistent ordering. The true count might be 2 if both events happened independently. The point is that without global ordering, you cannot always reconstruct the exact final state from net deltas alone if you also have decrements that depend on previous increments. But if you treat the counter as a **grow-only set** of (increment, decrement) events, you can always compute the exact count by replaying all events in any order (since addition and subtraction are commutative as operations on integers when applied in a consistent total order? Actually subtraction is not commutative with addition if you consider the order of operations affecting intermediate results? But the final result of a series of +1 and -1 is the same regardless of order, as long as you apply the same multiset of operations. So it is order-independent for the final sum. So net deltas should work? Wait, the problem is that net deltas lose information about which decrements correspond to which increments. If you have an unlike, it may be targeted at a specific prior like. In some systems, you cannot unlike a like that hasn't happened yet. That causality is lost in a pure net-counter. So the widely adopted approach for counters with both increments and decrements is to use a **PN-Counter** (Positive-Negative Counter) which is two G-Counters (grow-only counters): one for increments, one for decrements. The final count is positive minus negative. This works because both G-Counters are monotonic and commutative.

But in the simple increment-only case (like “likes” that cannot be un-liked? Actually Twitter allows unlikes, but historically the like counter was just increment only? They later allowed toggling. The 2015 issue was with the star, which could be unstarred? Actually the star (favorite) could be toggled; the count should reflect current favorites. That required decrements. So the problem was more complex.)

### The Human Cost

Beyond engineering aesthetics, inconsistent counters cause real problems:

- **Social validation**: A tweet with wildly fluctuating like counts appears glitchy, reducing its perceived credibility.
- **Analytics and trends**: If counts are off by 30%, trending topics may be incorrectly ranked.
- **Monetization**: If advertisers pay based on impressions or likes, inconsistent counts can lead to billing disputes.

Twitter’s eventual solution involved moving the like count computation to a more strongly consistent layer. But that took years. In the meantime, engineers everywhere learned a painful lesson: **counters are deceptively hard**.

---

## 5. CRDTs to the Rescue

Conflict-Free Replicated Data Types (CRDTs) are data structures designed to be replicated across multiple nodes and merged automatically without conflicts. They guarantee that all replicas converge to the same state, given that all updates are eventually delivered. For counters, the classic CRDTs are:

- **G-Counter** (Grow-only Counter): only supports increments. State is a vector of per-node counters. Merge takes the maximum for each node.
- **PN-Counter** (Positive-Negative Counter): consists of two G-Counters: one for increments, one for decrements. The final value is inc_G - dec_G.

### G-Counter in Detail

A G-Counter stores a vector `[c1, c2, ..., cn]` where `ci` is the number of increments performed by node `i`. To increment, a node increments its own entry. To query the total count, sum all entries. When merging two replicas, take the element-wise maximum of their vectors.

```python
class GCounter:
    def __init__(self, node_id, num_nodes):
        self.node_id = node_id
        self.vector = [0] * num_nodes

    def increment(self):
        self.vector[self.node_id] += 1

    def value(self):
        return sum(self.vector)

    def merge(self, other):
        for i in range(len(self.vector)):
            self.vector[i] = max(self.vector[i], other.vector[i])
```

This works because `max` is associative, commutative, and idempotent. No lost updates: if two nodes each increment once, one node’s vector becomes `[1,0]` and the other `[0,1]`. After merging, both have `[1,1]`, sum=2.

### PN-Counter

To support decrements, we maintain two G-Counters:

```python
class PNCounter:
    def __init__(self, node_id, num_nodes):
        self.p = GCounter(node_id, num_nodes)  # increments
        self.n = GCounter(node_id, num_nodes)  # decrements

    def increment(self): self.p.increment()
    def decrement(self): self.n.increment()
    def value(self): return self.p.value() - self.n.value()
    def merge(self, other):
        self.p.merge(other.p)
        self.n.merge(other.n)
```

This ensures that the final count is monotonic with respect to the total number of increments minus decrements, and merges converge.

### Why CRDTs Are Not a Silver Bullet

CRDT counters solve the lost update and oscillation problems, but they come with costs:

- **Metadata overhead**: The vector size grows linearly with the number of nodes (or data centers). For global systems with hundreds of nodes, sending the full vector on every update is expensive. You can optimize by using delta-state CRDTs or operation-based CRDTs that only send the increment itself, but then you need causal delivery.
- **Need for causal delivery**: In an operation-based CRDT (CmRDT), each node broadcasts its increment operation, and other nodes apply it only after receiving all causally previous operations. This requires a reliable, ordered transport (like using vector clocks). In a network with disconnects, this can be difficult.
- **Storage of all per-node state**: Each replica must store the full vector. For 1000 nodes, that’s a 1000-element vector per counter. For a system with billions of tweets, that’s terabytes of metadata.
- **Decrements and composition**: While PN-Counter works, it cannot prevent the count from going negative (if more decrements than increments are applied). For likes, that might be undesirable but technically valid. For other applications, you might need a **bounded counter** or **point counter** (see later).

CRDTs were heavily studied in academia and adopted by Riak (key-value store) and Redis CRDT (via the `@RedisBloom` module). But Twitter did not use CRDTs for its like counter. Why? Simplicity and existing infrastructure. Instead, they eventually moved to a hybrid approach: use a strongly consistent database for the authoritative count, with caching for performance. This is the pragmatic path many companies take.

---

## 6. The Cost of Truth: Strong Consistency in Practice

Given the complexity of CRDTs and the performance concerns, many large-scale systems revert to a centralized, strongly consistent store for critical counters, while using eventual consistency for less critical data.

### Google’s Spanner

Google’s Spanner is a globally distributed relational database that provides external consistency using TrueTime (GPS + atomic clocks). Spanner can handle millions of reads and writes per second across data centers, making it suitable for counters. However, Spanner is complex and expensive to operate. For most companies, it’s overkill.

### Amazon’s Dynamo and Counters

Amazon’s DynamoDB offers strongly consistent reads and writes (optional). For counters, DynamoDB supports atomic increment operations (`UpdateItem` with `ADD`). This is linearizable per partition (using a single leader per partition). DynamoDB can handle massive write throughput by sharding. So each counter is essentially strongly consistent within its shard, and there is no need for cross-shard coordination because each counter lives on exactly one partition. This is the same as the single-leader Redis shard approach, but with built-in replication and durability.

Twitter eventually migrated its “favorites” counter to a sharded strongly consistent system based on Manhattan (Twitter’s in-house distributed key-value store) or using Presto for offline computation? There’s evidence they moved to a strongly consistent service (maybe using MySQL with Memcached as cache). The key takeaway: for the user-facing count (the one shown in the UI), they needed strong consistency. They could tolerate eventual consistency for the total count in analytics.

### The Cost: Availability and Latency

With strong consistency, writes must be acknowledged by a quorum of replicas (or a leader). This adds latency, especially across data centers. But it may be acceptable if the latency is within a few hundred milliseconds. For a like button that returns instantly (optimistic UI), you can show an increment immediately on the client and then update the server counter asynchronously. However, if the server counter eventually converges to the true value, you still have inconsistency. The optimist update might later be reneged if the server write fails. That can be confusing.

Many systems adopt a “local increment first, then sync” pattern: the client sees an instant +1, the server confirms with a strongly consistent write, and if the write fails, the counter is decremented. This is similar to “pessimistic” but with client feedback. It works because the client can afford to be wrong temporarily.

---

## 7. When Exactness Isn't Needed: Approximate Counting

Sometimes, you don’t need an exact count. You just need a reasonably accurate estimate. For example, the number of page views, unique visitors, or “likes” for a top tweet might be used for trending but not for billing. This is where approximate counting algorithms shine.

### HyperLogLog

HyperLogLog (HLL) is a probabilistic algorithm that estimates the number of distinct elements (cardinality) in a data stream using a small, fixed amount of memory (e.g., 12 KB for a standard error of ~2%). It’s often used to count unique visitors, unique views, etc. For a counter like “number of likes,” which is not about uniqueness but total increments, HLL is not directly applicable. But for unique likes (one like per user), HLL is perfect.

### Count-Min Sketch

Count-Min Sketch is a probabilistic data structure that estimates frequencies of items in a stream (e.g., total likes per tweet) with sublinear space. It can overcount but never undercount, which is useful for heavy hitters detection. However, for accurate absolute values, it’s not ideal.

### Redis HyperLogLog

Redis provides native support for HyperLogLog via `PFADD` and `PFCOUNT`. Many applications use it for near-real-time unique counts. The trade-off is accuracy vs. memory.

For total likes (including multiple likes by the same user), you need an exact or approximate sum, not distinct count. There are approximate sum algorithms like **T-digest** or **Moment Sketches**, but they are more complex.

### Why Approximate Works for Non-critical Features

If the like count is used only to show “10K likes” on a tweet, a 1-2% error is imperceptible to users. Twitter’s problem was much larger than 2%—it was 30%. So approximate algorithms, if properly implemented, could actually be more accurate than a broken eventual consistency system. The choice depends on the allowable error bound.

---

## 8. Real-World Solutions: How the Industry Solved It

Let’s look at how various companies have tackled the distributed counter problem.

### Twitter: Movement to Strong Consistency

After the 2015 incident, Twitter moved the favorite count to a strongly consistent system. They built a custom service called **Flocking** (or later **LZ4 counters**? I recall a talk about their switch from Redis to a Java-based strongly consistent store). The key was to accept the performance cost for the sake of correctness. They also implemented batching and caching to reduce latency.

### Facebook (Meta): Many Distributed Counters

Facebook uses a multi-layered approach. For “likes” and “comments,” they likely use a sharded MySQL database with strong consistency per shard. For large counts (billions), they use asynchronous update to a secondary system for analytics. They also use periodic reconciliation (offline Hadoop jobs) to correct any discrepancies. This is typical: online systems provide fast, mostly correct counts; offline systems provide perfect counts with a delay.

### Pinterest: Using Sharded Redis with CRDT-ish Merging

Pinterest’s Pin counts went through a similar evolution. They initially used a sharded Redis cluster, then introduced CRDT-inspired merging across data centers. They implemented a custom version of a PN-Counter with delta state transfers. Their talk at RedisConf 2016 details how they achieved convergence while maintaining low latency.

### YouTube: Distributed Counters with Eventual Consistency

YouTube’s video view counter is famously eventually consistent. It has been known to freeze, jump, and sometimes not increase for hours. But YouTube views are not social validation in the same way as Twitter likes; they are used for trending and advertising, and moderate inconsistency is acceptable. YouTube uses a combination of client-side caching, server-side sharding, and periodic batch updates. The counter updates in a “hockey stick” pattern—a burst of views appears after a delay. Users have learned to accept it.

---

## 9. The Human Factor: Why We Care So Much About Counts

The enthusiasm for accurate counters is not just a technical fixation. Numbers are a form of social proof. When we see a tweet with 10,000 likes, we assign it value. When that number flips to 5,000, we feel deceived. The platform’s credibility is at stake.

Moreover, counters are used for real-time decision-making. For example, Twitter’s trending topics algorithm uses counts (of tweets, likes, retweets) to identify trends. If the counts are inconsistent, trend detection can produce false positives or miss real trends.

Finally, for content creators, like counts are a measure of success. Inconsistency creates anxiety and frustrates users. Twitter's support forums were filled with complaints about the “ghost likes” problem.

The lesson for engineers: **not all data is equal**. Some data must be correct at all times (e.g., bank balances, like counts on a social platform, inventory stock counts). Other data can tolerate eventual consistency (e.g., timeline order, search results). You must identify which is which and choose the appropriate consistency model.

---

## 10. Conclusion: The Counter as a Microcosm of Distributed Systems

The humble counter—a single integer that goes up and down—has been a crucible for distributed systems thinking. It encapsulates the fundamental trade-offs between consistency, availability, performance, and complexity. Twitter’s 2015 crisis taught the engineering community that eventual consistency, while powerful, is not a panacea. The same lesson was learned by Amazon with Dynamo, by Facebook with its counters, and by countless startups that thought they could “just use Redis and replicate.”

Today, we have better tools. CRDTs provide a theoretical guarantee of convergence without coordination. Strongly consistent distributed databases like Spanner, CockroachDB, and TiDB offer global consistency with acceptable latency for many workloads. Approximate algorithms like HyperLogLog provide efficient storage for certain use cases.

But the fundamental tension remains. Every time you increment a counter, you are making a small bet on the reliability of a network of computers. The bet is usually won, but when it fails, the number—once a fact—becomes a lie.

The next time you build a distributed system, ask yourself: _How much do I trust this number?_ The answer will guide your choice of consistency model, replication strategy, and error handling. And if you ever see a counter dancing between 5,000 and 10,000, you’ll know exactly why—and you’ll know how to fix it.

---

_Thanks for reading. If you enjoyed this post, please consider giving it a like. Or not. I won’t mind if the counter is eventually consistent._
