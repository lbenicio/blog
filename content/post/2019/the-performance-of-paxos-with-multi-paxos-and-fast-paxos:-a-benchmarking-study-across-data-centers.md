---
title: "The Performance Of Paxos With Multi Paxos And Fast Paxos: A Benchmarking Study Across Data Centers"
description: "A comprehensive technical exploration of the performance of paxos with multi paxos and fast paxos: a benchmarking study across data centers, covering key concepts, practical implementations, and real-world applications."
date: "2019-02-27"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-performance-of-paxos-with-multi-paxos-and-fast-paxos-a-benchmarking-study-across-data-centers.png"
coverAlt: "Technical visualization representing the performance of paxos with multi paxos and fast paxos: a benchmarking study across data centers"
---

# The Phantom Consensus: Why Your Database is Slower than Lamport Imagined

In the quiet, air-conditioned halls of a major cloud provider, an engineer is staring at a dashboard. The red line has just crossed the threshold. A global retail chain is seeing three-second checkout delays. The cause isn’t a cyberattack; it’s not a hardware failure; and it’s not a bug in the application code. The cause is a philosophical disagreement—a failure of consensus—between servers in Virginia, Frankfurt, and Singapore.

This is the silent war of modern distributed systems. It is not fought with brute force (more CPU cores) or simple speed (faster networks), but with the elegant, maddening, and often misunderstood mathematics of agreement. At the heart of this war sits Paxos, the algorithm famously described by its creator, Leslie Lamport, as so simple that even his peers could not understand it. For decades, Paxos has been the gold standard for fault tolerance, the invisible hand ensuring that when you book a flight or send a message, the system doesn’t lie to you. It guarantees that even if servers crash, networks partition, or data centers go dark, the system will converge on a single, irrevocable truth.

But here is the uncomfortable secret that keeps distributed systems architects up at night: **Paxos, in its purest, most classic form, is painfully slow.**

Lamport’s genius was not in optimizing for speed, but for safety. The original “Basic Paxos” algorithm is a masterclass in theoretical resilience. It can survive the simultaneous failure of multiple nodes and the loss of messages. It is a rock. But rocks do not move quickly. In the real world, especially across the continental divides of a global data center deployment, the raw latency of Basic Paxos is a liability. Every single consensus decision requires multiple network round trips between multiple data centers. If you are building a database that needs to commit a transaction, that delay is a death sentence.

This blog post is not a beginner’s guide to Paxos. It is a deep dive into the **phantom consensus**—the hidden overhead that makes your database slower than you think, the cost of safety that nobody talks about, and the engineering trade-offs that turn a theoretical masterpiece into a practical nightmare. We will dissect the algorithm, count every network message, and explore the real-world optimizations that systems like Google Spanner, etcd, and Apache Kafka use to live with—or escape—the curse of Basic Paxos. By the end, you will understand why a three-second checkout delay is not a hardware problem, but a mathematical one.

---

## 1. The Architecture of Agreement: Paxos in Theory

Before we can complain about speed, we must understand the machinery. Paxos solves the _consensus problem_: a set of processes must agree on a single value, even if some processes fail or messages are lost. It is the foundation of replicated state machines, where a log of commands is kept identical across servers.

### 1.1 The Roles

Basic Paxos defines three roles:

- **Proposers**: Initiate consensus by suggesting a value (e.g., “commit transaction T”).
- **Acceptors**: Vote on proposals and remember the highest-numbered proposal they have accepted.
- **Learners**: Learn the outcome (the decided value).

In practice, a single server often plays all three roles, but the logical separation is crucial.

### 1.2 The Two Phases

The algorithm proceeds in two phases, each consisting of two messages (prepare/promise and accept/accepted). Let’s walk through a simplified example with three acceptors (A, B, C) and one proposer (P).

**Phase 1 (Prepare):**

1. P sends a `Prepare(n)` message to all acceptors, where `n` is a unique, monotonically increasing proposal number.
2. Each acceptor responds with a `Promise(n)` if it has not seen a higher proposal number. The promise also includes the highest-numbered proposal (and its value) that the acceptor has already accepted, if any.

**Phase 2 (Accept):**

1. If P receives promises from a majority (quorum) of acceptors, it selects a value: if any promise included a previously accepted value, P must use that value (to preserve consistency); otherwise it can choose its own value.
2. P sends an `Accept(n, value)` to all acceptors.
3. Acceptors accept the proposal unless they have promised a higher number. They then send `Accepted(n, value)` to P and to all learners.

That’s it. Two round trips, and the value is decided. But wait—there’s a catch. Phase 1 is a _preparation_ phase that may be repeated if the proposer fails to get a majority. In the worst case, a single decision can take many rounds (e.g., if competing proposers keep raising numbers). But even in the best case, we have two network round trips.

### 1.3 Why Two Round Trips?

Why can’t we decide in one round? Because safety requires that if a value has already been chosen by a previous quorum, any new proposer must learn that value and propagate it. The prepare phase effectively “locks” the system to prevent conflicting proposals. This is the **safety** guarantee—the algorithm ensures that once a value is chosen, it stays chosen.

But from a latency perspective, two round trips means that the time to commit a single entry in the replicated log is at least:

```
Latency = 2 * (network round-trip time between proposer and acceptors)
```

For data centers on the same continent, RTT is ~1–10 ms. For cross-continent (e.g., US-East to Europe), RTT is ~80–150 ms. That gives us a best-case commit latency of 160–300 ms. This is the **phantom consensus** cost. And it gets worse when we consider that many databases need to commit _thousands_ of log entries per second.

---

## 2. The Real-World Performance Pitfall: Basic Paxos in Practice

Let’s make this concrete. Suppose we run a three-node database replicating across Virginia, Frankfurt, and Singapore. The average RTT between any pair of these data centers is:

- Virginia ↔ Frankfurt: ~100 ms
- Virginia ↔ Singapore: ~180 ms
- Frankfurt ↔ Singapore: ~150 ms

Now, imagine a proposer in Virginia trying to commit a transaction. It must:

1. Send `Prepare` to all three acceptors. Wait for a majority (two out of three). The slowest response is from Singapore (180 ms). So Phase 1 takes ~180 ms.
2. Send `Accept` to all again. Again wait for majority. Another 180 ms.

Total: 360 ms for _one_ log entry. If you want to commit 100 sequential transactions, that’s 36 seconds. Even with pipelining (overlapping phases for consecutive entries), you are limited by the fact that each entry needs its own two-phase execution.

But wait: can’t we use a leader to avoid the prepare phase for subsequent entries? Yes, that’s the “Multi-Paxos” optimization, which we’ll cover later. But even Multi-Paxos requires an initial leader election that itself is a round of Paxos. And in a global deployment, the leader might be far from the majority of acceptors.

### 2.1 The Cost of Failure

Basic Paxos is designed to survive failures. That means it must handle the case where the proposer crashes mid-phase. The algorithm is symmetric: any proposer can start a new round. But this leads to **livelocks** and **contention** that further increase latency. In high-contention scenarios (many concurrent proposers), the constant back-and-forth of prepare phases can cause the protocol to “spin” without making progress—a phenomenon known as the **Paxos livelock**.

Lamport himself addressed this with the notion of a **distinguished proposer** (leader) to reduce contention. But that introduces a single point of failure and requires leader election, which is itself a consensus problem.

### 2.2 Real-World Numbers: A Case Study

Large-scale systems like Google’s Spanner use Paxos for replication. Spanner spans many zones (data centers) with typical round-trip times between zones of a few milliseconds. Even with such low latency, the cost of Basic Paxos is significant. Google optimizes with **Multi-Paxos** and **paxos lease** to reduce the prepare phase for repeated decisions. But the phantom cost remains: the leader must still send `Accept` to a majority in each zone, often requiring cross-continental round trips for global transactions.

In one recorded benchmark, a Spanner transaction that touched two zones had a commit latency of ~10 ms. That seems fast, but it is an order of magnitude slower than a single-node database. And crucially, that latency is dominated by consensus, not by data access.

---

## 3. Multi-Paxos: The Optimization That Almost Works

Basic Paxos is a single-decree protocol: it decides one value. For a replicated log, we need many consecutive decisions (one per log entry). The naive approach is to run Basic Paxos for each entry. That’s expensive. Multi-Paxos improves this by electing a **stable leader** that can skip the Prepare phase for most entries.

### 3.1 How Multi-Paxos Works

1. **Leader Election**: The group selects a single leader using Basic Paxos (or a simpler mechanism like a lease). This step requires one consensus.
2. **Stable Operations**: While the leader is known and alive, it can propose values directly using only the Accept phase. It sends `Accept(n, value)` to all acceptors, and they accept as long as `n` is higher than any promise they’ve given. However, the leader must track a monotonically increasing proposal number for each log slot.
3. **Recovery**: If the leader fails, a new leader is elected. The new leader must run Prepare for each log slot that has not yet been decided, to learn the current state.

The key insight: the Prepare phase is amortized over many decisions. For thousands of entries, we pay the Prepare cost only once per leader term.

### 3.2 The Phantom in Multi-Paxos

Even with a stable leader, the Accept phase still requires a majority round trip. In a five-acceptor configuration spanning three data centers, the leader might be in Virginia, two acceptors in Virginia, one in Frankfurt, one in Singapore. To commit, the leader needs responses from a majority (three out of five). The best case is that the Virginia acceptors respond quickly (~1 ms), plus one cross-region response (e.g., Frankfurt at 100 ms). So commit latency is still ~100 ms.

But there is another phantom: **batching**. Multi-Paxos often batches multiple log entries into a single `Accept` message to amortize network overhead. Batching reduces per-entry cost but increases latency for the first entry in the batch. And if the leader crashes mid-batch, the recovery may need to re-prepare, adding more latency.

### 3.3 Linearizability and the Distributed Stamp

Consensus protocols like Paxos, Raft, and Zab implement **strong consistency** (linearizability). In a replicated system, any update must appear to happen instantaneously at some point between its invocation and response. This requires that the commit timestamp is not just a local clock value, but a **consensus-derived timestamp**. In Spanner, this is the **TrueTime** API, which uses GPS and atomic clocks to bound clock uncertainty. But even with TrueTime, the commit process must wait for a majority of acceptors to confirm the entry. That wait is pure latency.

---

## 4. Raft: The Usability Competitor and Its Own Phantoms

The Paxos family is vast, but most practitioners encounter **Raft**, which popularized a simpler, more understandable design. Raft achieves the same fault tolerance as Paxos but with a leader-centric approach that includes explicit leader election, log replication, and safety guarantees.

### 4.1 Raft’s Latency Profile

Raft’s normal operation requires only the leader to send `AppendEntries` (which includes new log entries) to followers. Followers respond after appending to their log. The leader commits when it has received acknowledgments from a majority. That is **one round trip** for each batch of entries (after leader election). In that sense, Raft’s normal-case latency is similar to Multi-Paxos with a stable leader.

However, Raft’s leader election is more heavyweight: it uses randomized timeouts to avoid split votes, but the election duration can be several hundred milliseconds. During that time, no commits happen. This is a phantom cost that Paxos avoids through its symmetric design (any proposer can act). But as we saw, Paxos’s symmetry can lead to livelocks.

### 4.2 The Join/Split Cost

In both Paxos and Raft, adding or removing nodes requires a configuration change (a joint consensus). This change itself requires a series of consensus decisions, often slower than normal operations. The phantom here is that cluster reconfiguration temporarily pauses the normal commit stream.

### 4.3 The Real Phantom: The Network Delays They Cannot Hide

No matter how clever the algorithm, the fundamental limit is the speed of light. A round trip between New York and Sydney is about 200 ms. With a three-node cluster spanning both coasts, commit latency is ~200 ms. With five nodes, you need three responses; if the leader is on the West Coast and two acceptors are in the East (150 ms), plus one in Europe (100 ms), the worst response might be 150 ms. Still, 150 ms per commit is too slow for many applications (e.g., real-time bidding, online payments).

This is why many distributed databases **compromise**: they either:

- Replicate within a single region (low latency, but vulnerable to region-wide outages), or
- Use **eventual consistency** with conflict detection (like DynamoDB), sacrificing strong guarantees for low latency.

---

## 5. The Phantom Consensus: Deeper Implications

The term “phantom consensus” captures a subtle but crucial insight: **the consensus algorithm is not the bottleneck you think it is**. The bottleneck is not the CPU cycles spent running the protocol; it’s the network round trips required to achieve consensus. And worse, these round trips are **indivisible**—you cannot parallelize them because the protocol requires a strict ordering of prepare and accept phases for safety.

### 5.1 The Synchrony Assumption

Most production implementations of Paxos and Raft assume **asynchronous networks** (messages can be delayed, lost, reordered). But to guarantee progress, they often rely on **failure detectors** that assume eventual timeliness. This leads to a paradox: the protocol is designed for async crashes, but its performance is heavily dependent on synchronous, low-latency communication.

### 5.2 The Hidden Phantoms

Let’s enumerate the costs that casual users overlook:

1. **Serialization and Deserialization**: Each message must be encoded/decoded. For large log entries, this adds CPU overhead that can become a bottleneck.
2. **Disk I/O**: Many implementations (e.g., etcd, Kafka) persist each log entry to disk before sending a confirmation. This adds deterministic latency (e.g., 5–20 ms for a single disk write with fsync).
3. **Clock Skew**: Even with NTP, clocks drift. Consensus algorithms that rely on timestamps (e.g., for leader leases) add margins that increase effective latency.
4. **Garbage Collection**: Java-based systems (e.g., Apache Cassandra’s Paxos implementation) suffer from GC pauses that can disrupt quorum responses, causing retries.

### 5.3 The Exponential Backoff Trap

When a leader times out waiting for quorum responses, it typically retries with a higher proposal number. In high-contention or slow networks, this can lead to a cascade of increasing round numbers, each requiring the full two-phase protocol. The phantom becomes a snowball.

---

## 6. Engineering Around Phantom Consensus

How do modern systems tame the phantom? They use a combination of techniques:

- **Leases and Local Acks**: In some systems, the leader can assume it will remain leader for a short time (a lease). During the lease, it can commit entries without explicit leader election. This reduces latency but introduces a risk of split-brain if clocks are too skewed.
- **Fast Paxos**: An optimization that can decide in one round trip if all acceptors respond promptly. However, it requires at least 𝟸𝑓+1 acceptors (where f is the max simultaneous failures) and works only in synchronous networks.
- **EPaxos (Egalitarian Paxos)**: A variant that allows any node to act as a proposer without a leader, reducing latency for geographically distributed clusters by using commutative operations. It achieves one round trip in the common case (same as Multi-Paxos) but avoids the leader bottleneck.
- **FaaV (Fast Paxos with Virtual Leaders)**: Uses a fixed set of virtual leaders to avoid livelocks.
- **Speculative Execution**: Some databases (e.g., CockroachDB) allow read-write transactions to proceed optimistically and only validate with consensus at commit time.

### 6.1 Case Study: Spanner’s TrueTime

Spanner uses Paxos for replication but leverages **TrueTime** to reduce the cost of global reads. By bounding clock uncertainty, Spanner can serve strongly consistent reads from a local replica without contacting a quorum—provided the local copy has a timestamp within the TrueTime interval. This is not a pure consensus optimization, but it sidesteps the phantom for read-heavy workloads.

### 6.2 Case Study: etcd’s Multi-Proposer

etcd, the key-value store behind Kubernetes, uses Raft. In its default configuration, all writes go through a single leader. However, etcd can be deployed in a multi-region setup with a “staging” leader that forwards to other regions. The latency cost is explicit: cross-region Raft commits add 100–300 ms. Kubernetes workloads often avoid cross-region replication precisely because of this.

### 6.3 The Cost of Global Consistency

The biggest “phantom” is that users often don’t realize they are paying for global consistency when they don’t need it. Many applications can tolerate eventual consistency, causal consistency, or even relaxed consistency for most operations. By defaulting to linearizability, architects pay a huge latency tax.

---

## 7. The Next Frontiers: FastPaxos, Flexible Paxos, and Data Flow

Research continues to push the boundaries. Newer algorithms aim to reduce the phantom consensus to its irreducible minimum:

- **Fast Paxos**: Achieves consensus in a single round trip (but requires 𝟸𝑓+1 acceptors and deterministic failures).
- **Flexible Paxos**: Decouples the prepare phase quorum from the accept phase quorum, allowing smaller quorums for faster operations at the cost of reduced fault tolerance during leader election.
- **Quorum Reconfiguration**: Techniques to dynamically change the quorum size based on network conditions.

### 7.1 The Zero-Round-Trip Dream

Is it possible to commit a transaction without _any_ cross-region round trips? That would require a deterministic global clock and a total order of events, which is impossible in a distributed system without timestamps. However, approaches like **CRDTs** (Conflict-free Replicated Data Types) allow updates to be applied locally and merged later without consensus—at the cost of potential conflicts that must be resolved semantically (e.g., state-based CRDTs).

But CRDTs cannot provide linearizable consistency for all operations; they are best for collaborative editing or last-write-wins registers.

### 7.2 The Role of Fast Networks

The ultimate solution may be to make the network itself faster. Emerging technologies like **RDMA** and **optical interconnects** can reduce intra-data-center round trips to microseconds. For inter-data-center links, the speed of light remains the ultimate limit. But with fiber direct paths, we can shave off tens of milliseconds. Still, the arithmetic of consensus demands at least one round trip.

---

## 8. Conclusion: Living with the Phantom

We began with a three-second checkout delay. That delay is the price of global strong consistency—a price that many businesses are willing to pay for correctness but must account for architecturally. The phantom consensus is not a bug; it is a feature of safe distributed agreement. Every time you require that all replicas agree on the value of a transaction before acknowledging it, you accept a delay proportional to the speed of light and the number of round trips.

The engineers who battle these phantoms have two choices: they can design algorithms that reduce the number of round trips (Multi-Paxos, Fast Paxos, EPaxos) or they can design systems that avoid consensus altogether for most operations (causal consistency, CRDTs, read-only replicas). The third, and most common, choice is to limit geographic distribution—replicating inside a single cloud region—and pay the phantom tax only for truly critical operations.

Lamport’s algorithm was never meant to be fast. It was meant to be safe. The irony is that safety, in the form of consensus, introduces delays that are not always visible. They lurk in the network, in the disk, in the CPU, and in the mathematics of agreement. The phantom consensus is the price we pay for trust in an untrustworthy world.

So the next time you stare at a dashboard with a red line, remember: the system isn’t broken; it’s just being true to its theoretical roots. And if you want it to go faster, you’ll have to break a little safety along the way.

---

**References and Further Reading**

- Lamport, L. (1998). The Part-Time Parliament. ACM Transactions on Computer Systems.
- Lamport, L. (2001). Paxos Made Simple. ACM SIGACT News.
- Ongaro, D., & Ousterhout, J. (2014). In Search of an Understandable Consensus Algorithm (Raft).
- Moraru, I., Andersen, D. G., & Kaminsky, M. (2013). There is More Consensus in Egalitarian Parliaments (EPaxos).
- Corbett, J. C., et al. (2013). Spanner: Google’s Globally Distributed Database.
- Howard, H., et al. (2016). Flexible Paxos: Quorum Intersection Revisited.

_All opinions are my own. Let me know if you have questions or want deeper code examples._
