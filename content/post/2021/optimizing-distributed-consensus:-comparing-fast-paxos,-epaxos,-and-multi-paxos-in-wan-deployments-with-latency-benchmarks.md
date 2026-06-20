---
title: "Optimizing Distributed Consensus: Comparing Fast Paxos, Epaxos, And Multi Paxos In Wan Deployments With Latency Benchmarks"
description: "A comprehensive technical exploration of optimizing distributed consensus, comparing Fast Paxos, Epaxos, and Multi Paxos in WAN deployments with latency benchmarks, covering key concepts, practical implementations, and real-world applications."
date: "2021-08-20"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/optimizing-distributed-consensus-comparing-fast-paxos,-epaxos,-and-multi-paxos-in-wan-deployments-with-latency-benchmarks.png"
coverAlt: "Technical visualization representing optimizing distributed consensus with latency benchmarks"
---

# When Light Slows Down Consensus: A Deep Dive into Paxos Variants for Wide-Area Networks

## I. The 3:47 PM Meltdown

The email arrives at 3:47 PM. A customer in Singapore is trying to transfer $50,000 from their account to a partner in London. The system stalls. The spinner spins. The cursor blinks. Nine seconds later, the transaction fails. You, the systems architect, check the logs. The distributed consensus protocol—your carefully chosen implementation of Multi-Paxos—decided to take a nap. A leader election timeout in the US-East region cascaded through the global mesh, and the Singapore node spent eight of those seconds waiting for a quorum of acknowledgments from nodes scattered across Virginia, Frankfurt, and São Paulo.

This is not a hypothetical scenario. It happens daily in production systems that naively extend single-datacenter consensus protocols across intercontinental links. The root cause is not a bug in the code; it is a mismatch between assumptions about latency and the immutable laws of physics.

## II. The Tyranny of the Speed of Light

### 2.1 What the Fiber Really Gives You

In a vacuum, light travels at 299,792,458 meters per second. In optical fiber, the refractive index of silica reduces that to roughly 200,000,000 m/s—about two-thirds the vacuum speed. That means:

- **New York ↔ Sydney**: ~16,000 km → round-trip time (RTT) ≈ 160 ms minimum, plus switching and processing overhead → 180–250 ms.
- **London ↔ Singapore**: ~11,000 km → RTT ≈ 110 ms minimum → 130–170 ms in practice.
- **Tokyo ↔ São Paulo**: ~18,000 km → RTT ≈ 180 ms minimum → 200–260 ms.

Now, add the overhead of serializing a protocol buffer, kernel TCP/IP stack traversal, queueing at switches, and the cost of context-switching in the application. A single message exchange from proposal to acknowledgment can easily take 200–300 ms. If your consensus protocol requires three message phases for every write, you are staring at half a second of pure latency, even before the application logic runs.

### 2.2 The Single-Datacenter Fallacy

In a single datacenter, RTTs between servers are typically 0.5–2 ms. A consensus round completes in 3–6 ms. You can afford to run three or four protocol phases; the overhead is a minor fraction of the total latency. The classic Paxos protocol (two phases plus a learn phase) works beautifully. But when you stretch that same algorithm across continents, the overhead becomes the dominant term, and user-visible latency explodes.

The problem is not just total latency. It is also _amplified_ by failure recovery. When a leader fails, a new leader must run an election that involves at least one round trip to a quorum. In a single datacenter, that finishes in 10 ms. Across oceans, it can take 5–10 seconds. That is why the Singapore transaction failed: a network partition in one region triggered a leadership election, and the remaining nodes spent tens of seconds trying to gather votes from far-flung locations, while the client timed out.

## III. A Brief Refresher: The Paxos Family

Before we compare variants, let us ensure we are grounded in the fundamentals. Paxos solves the problem of reaching consensus on a single value among a set of unreliable processors (nodes) that communicate asynchronously. It guarantees safety (no two nodes decide different values, and only proposed values can be decided) and eventual progress under certain conditions.

### 3.1 Roles in Classic Paxos

- **Proposers**: Clients that initiate consensus rounds.
- **Acceptors**: Servers that vote on proposals and record decisions.
- **Learners**: Passive observers that learn the decided value (often merged with acceptors for efficiency).

### 3.2 The Two Phases (Classic Paxos)

**Phase 1 (Prepare/Promise)**:

- A proposer sends a _prepare_ request with a unique proposal number _n_.
- Each acceptor promises to never accept a proposal numbered less than _n_ and returns the highest-numbered proposal it has already accepted (if any).

**Phase 2 (Accept/Learn)**:

- After receiving promises from a majority (quorum), the proposer sends an _accept_ request with its own value (if no value was returned from a prior proposal) or the highest-numbered value from the promises.
- Acceptors accept the proposal and notify learners.

This classic version requires two round trips to commit a value. With a stable leader, the leader can skip Phase 1 for subsequent commits—this is Multi-Paxos.

## IV. The Three Variants: Classic, Multi, and Fast Paxos

### 4.1 Classic Paxos: The Baseline

Classic Paxos requires two message delays (prepare → promise → accept → response) for each consensus instance. In a WAN deployment, that means:

- 2 × RTT between proposer and a quorum of acceptors.
- Because the proposer must wait for a majority of acceptors, the latency is determined by the _slowest_ node in the quorum, not the fastest. (In practice, you wait for the slowest response in the quorum to arrive, so RTT_max dominates.)

**Example**: Suppose you have five acceptors in Virginia, Frankfurt, Singapore, Sydney, and São Paulo. The proposer is in Singapore. To commit a value, Singapore must:

1. Send prepare to all five acceptors.
2. Wait for promises from at least three of them. The slowest of those three might be São Paulo (RTT ~250 ms).
3. Send accept to all five.
4. Wait for accept acknowledgments from at least three. Again, the slowest quorum member sets the pace.

Total minimum latency = 2 × 250 ms = 500 ms. In reality, with processing, it is closer to 600–700 ms. That is half a second per write. For a single transfer, it might be acceptable. For a high-throughput database, it is catastrophic.

**When to use**: When you cannot afford a leader (e.g., untrusted environments) or when latency is not critical. It is the most resilient against leader failures because any proposer can initiate a round without prior state.

**Implementation pitfalls**: Leaderless operation leads to conflicts and higher tail latencies. Without batching, each operation pays the full two-round-trip cost.

### 4.2 Multi-Paxos: The Workhorse

Multi-Paxos optimizes Classic Paxos by electing a single stable leader and reusing Phase 1 across many instances. The leader runs Phase 1 once to establish its leadership (using a lease or epoch number). Thereafter, each subsequent consensus instance requires only Phase 2: the leader sends an accept request and waits for a quorum of acknowledgments.

**Latency analysis**: After leader election, each new value requires one round trip (accept → promise → response). In our five-node WAN with a leader in Singapore, the minimum latency per write = 1 × RTT(slowest quorum member) = 250 ms. That halves the write latency compared to Classic Paxos.

But there is a catch: leader election itself incurs the full two-round-trip cost of Classic Paxos. Worse, during an election, no new commits can happen. If the leader crashes or is partitioned, the cluster enters a dead period. How long does that dead period last?

- The old leader times out (e.g., 3× heartbeat interval).
- A new proposer starts Phase 1: prepare to all, wait for promises from majority. That takes ~250 ms.
- The new proposer then learns the highest decided value from the promises (maybe another 250 ms to contact the leader of the previous epoch?).
- Then it starts committing.

Total election time: ~1–2 seconds under good conditions, but often 5–10 seconds when timeouts are generous.

**Example**: In the Singapore transaction at 3:47 PM, the leader (Singapore) was healthy, but a temporary network blip increased latency to Virginia beyond the timeout. The follower in Frankfurt timed out, started an election, and then could not reach a majority because Virginia was still technically alive but slow. The Singapore client was stuck waiting for a new leader to be elected.

**When to use**: Multi-Paxos is the default for most practical systems (Google’s Spanner uses a variant, albeit with clock synchronization and tight leases). It is excellent for low-latency, high-throughput workloads when leader changes are rare.

**Optimizations**:

- **Batching**: The leader can batch multiple client requests into a single consensus instance, reducing the per-operation overhead.
- **Pipelining**: The leader can send multiple accept requests without waiting for each one to complete, as long as they are processed in order.
- **Flexible Quorums**: In WAN deployments, you can configure the leader to only wait for a quorum of _fast_ acceptors—e.g., those within the same region or with low RTT—while still writing to slow ones asynchronously. This trades write durability for latency, but can be acceptable for some workloads.

### 4.3 Fast Paxos: Reducing to One Round Trip

Fast Paxos, introduced by Leslie Lamport in 2005, aims to reduce the number of message delays to _one_ for _most_ operations. In Classical and Multi-Paxos, the leader mediates all proposals. In Fast Paxos, any client can propose a value directly to a _fast quorum_ of acceptors. If there is no conflict (i.e., no other proposer concurrently choosing a value), the value is committed in a single round trip.

**How it works**:

- Instead of a leader, Fast Paxos uses a **coordinator** (like a leader but with less privilege) that can be bypassed.
- Acceptors maintain more state: they record not only the last accepted proposal but also the last _fast commit_ they observed.
- A client sends its value to a fast quorum (usually a supermajority, e.g., 4 out of 5). The acceptors accept it immediately if no conflicting fast proposals exist.
- If conflicts occur (e.g., two clients propose simultaneously), the system falls back to a slower recovery protocol (often Classic Paxos) to resolve the value.

**Latency analysis**: In the best case, a commit takes one RTT between client and the farthest node in the fast quorum. That means 250 ms for our Singapore client writing to Virginia, Frankfurt, Sydney, and São Paulo (if the client chooses those four). But note: the client must wait for all acceptors in the fast quorum to respond because it does not know which will accept until they reply. So the latency is still the slowest of the quorum.

**The conflict penalty**: If a conflict occurs, the client must restart with Classic Paxos (two round trips). The probability of conflict becomes higher with larger quorums and more clients, especially under high contention.

**When to use**: Fast Paxos shines in workloads with low contention (few conflicting writes) and where reducing best-case latency is critical. Examples: a global key-value store for user profiles (most writes are to different keys) or a configuration store that rarely sees concurrent proposals.

**Trade-offs**:

- Increased storage and message complexity at acceptors.
- Recovery from conflicts can be expensive.
- Requires a fast quorum of at least floor(n/2)+1 (for fast Paxos) that is larger than a majority for Classic Paxos. In a 5-node cluster, a fast quorum requires 4 acceptors, while Classic requires 3. This means lower fault tolerance for fast commits.

## V. Comparing the Three: A Detailed Analysis

Let us examine each variant under the lens of three critical metrics: latency, throughput, and fault tolerance.

### 5.1 Latency

| Variant     | Best-case commit (stable state)     | Worst-case (contention/recovery)             |
| ----------- | ----------------------------------- | -------------------------------------------- |
| Classic     | 2 RTTs (e.g., 500 ms)               | Same, but may increase due to re-proposals   |
| Multi-Paxos | 1 RTT (250 ms after leader elected) | Leader election: 2 RTTs + timeouts (seconds) |
| Fast Paxos  | 1 RTT (250 ms, no conflict)         | Conflict recovery: up to 3 RTTs (500+ ms)    |

The key takeaway: Multi-Paxos offers the lowest _typical_ latency for a stable leader, but its worst-case election can be devastating. Fast Paxos offers equally low latency for conflict-free cases, but its worst-case is only slightly worse than Classic (assuming conflict recovery uses one extra round). Classic is the most predictable—its worst case equals its best case.

### 5.2 Throughput

Throughput is limited by the leader’s ability to process messages and the network bandwidth. In Multi-Paxos, the leader serializes all proposals (if batching is not used), creating a bottleneck. Fast Paxos allows multiple proposers to submit concurrently, increasing throughput for non-conflicting keys. However, conflicts can reduce throughput because recovery involves extra messages and potential rollbacks.

Classic Paxos has the lowest throughput because each instance goes through two phases for every value, even with the same leader.

**Numerical comparison** (assuming 5 nodes, 1 Gbps links, 200 ms RTT):

- **Classic**: Maximum throughput ≈ 2 operations/second per proposer (since each op takes 500 ms → 2 ops). With multiple proposers, you can parallelize only if they propose different instances. But unless you assign instance numbers in advance, contention makes it worse.
- **Multi-Paxos**: With batching of 100 requests per consensus instance, each batch takes 250 ms → 400 requests/second. Pipelining can push this to 1000+ requests/second.
- **Fast Paxos**: Without conflicts, each request takes 250 ms → 4 requests/second per proposer. But many proposers can act simultaneously, potentially scaling to dozens of concurrent requests, limited by acceptors’ processing capacity.

### 5.3 Fault Tolerance

All three variants tolerate f = floor((n-1)/2) failures with Classic Paxos (n=5 → 2 failures). Multi-Paxos has the additional vulnerability of leader failure: if the leader crashes, the system pauses until a new leader is elected. Fast Paxos, because it uses a larger quorum (4 out of 5), tolerates only 1 acceptor failure for fast commits. After 2 failures, fast commits are impossible, and the system degrades to Classic Paxos.

**Table: Tolerance to simultaneous failures while maintaining best-case performance**

| Variant     | Fast mode tolerance                                                                                                                  | Degraded mode tolerance                     |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| Classic     | N/A (always same)                                                                                                                    | f = floor((n-1)/2)                          |
| Multi-Paxos | f = floor((n-1)/2) + leader alive                                                                                                    | f = floor((n-1)/2) (after election)         |
| Fast Paxos  | f = ceil(n/4) - 1? Actually fast quorum size = n - f (for fast)? Let’s compute: For 5 nodes, fast quorum = 4, so tolerate 1 failure. | f = floor((n-1)/2) with fallback to Classic |

### 5.4 Operational Complexity

- **Classic**: Simplest to understand and implement, but slow.
- **Multi-Paxos**: Requires leader election, lease management, stable storage for accepted values. Many production systems use it (e.g., Google’s Chubby, Spanner).
- **Fast Paxos**: Requires acceptors to track additional state (fast commit numbers). Conflict detection and recovery add complexity. Very few production systems use pure Fast Paxos; instead they use EPaxos (Egalitarian Paxos) which generalizes the idea.

## VI. Real-World Deployments: Where the Physics Hurts

### 6.1 Google Spanner

Google’s Spanner uses a modified Paxos (not exactly Multi-Paxos, but close) with _strong timestamps_ via GPS and atomic clocks. Spanner writes go through a leader, and the leader chooses a timestamp that is guaranteed to be honored by all replicas. Spanner’s true value is that it avoids expensive Two-Phase Commit for distributed transactions by using timestamp ordering. But even Spanner suffers from WAN latency: a cross-region transaction can take 50–100 ms because it must wait for the slowest participant to confirm the timestamp.

Spanner uses **Paxos with leader leases** that are typically 10–20 seconds. This reduces the frequency of leader elections but makes the dead period long if the leader crashes.

### 6.2 Amazon DynamoDB Global Tables

DynamoDB Global Tables use a **last-writer-wins** conflict resolution with _Multi-Paxos_ as the consensus layer within each region, but cross-region replication is asynchronous. So they do not suffer from WAN consensus latency for writes. Consistency is eventual, not strong. For strong consistency across regions, you would need a consensus protocol.

### 6.3 Apache Cassandra

Cassandra uses a gossip-based protocol with hints and read repair; it does not use Paxos for normal operations, only for lightweight transactions (LWT) which rely on Paxos. LWTs across regions are notoriously slow and often avoided.

### 6.4 CockroachDB

CockroachDB uses Raft, not Paxos, but the latency implications are similar. Raft’s elected leader serializes writes, and a Raft commit requires a log entry to be replicated to a majority. For a global deployment, CockroachDB recommends placing an even number of replicas in multiple regions, but each Raft group is typically confined to three regions to keep latency manageable. Cross-region reads with linearizability require accessing the leader, which might be far away.

## VII. Quantitative Models: How to Estimate Latency

Before you choose a variant, you need to model the expected latency under your workload. Let’s build a simple model for Multi-Paxos in a WAN with five nodes placed in five datacenters (DC1–DC5) with known RTTs from the proposer’s location.

**Notation**:

- Let T(i) = RTT from proposer to acceptor i.
- Let T_max = max(T(i) over quorum nodes).
- The quorum size = 3 (for 5 nodes).

For Multi-Paxos in steady state: each commit takes ≈ T_max + processing overhead (ε). The leader selects a quorum. The proposer can choose which acceptors to include in the quorum to minimize T_max. Optimally, the leader will choose the three closest nodes.

**Example**: Leader in Singapore (SGP). RTTs from Singapore:

- SGP (itself): 0 ms (local)
- Ireland (DUB): 160 ms
- Virginia (IAD): 250 ms
- Sydney (SYD): 100 ms
- São Paulo (GRU): 280 ms

Optimal quorum: Singapore (0), Sydney (100), Ireland (160). T_max = 160 ms. So commit latency ≈ 160 ms + ε.

In contrast, if the quorum included Virginia or São Paulo, T_max jumps to 250 or 280 ms. Therefore, the leader should always choose the closest majority. This is called **leader-local quorum selection**.

But what if the leader itself is not the best? In a global deployment, the leader’s location matters greatly. If the leader is in São Paulo, the optimal quorum will have T_max = 160 ms (if three close nodes exist in South America and nearby US? Actually from São Paulo: closest might be Virginia (120 ms), Frankfurt (170 ms), and itself (0 ms) → T_max = 170 ms). So latency varies with geography.

**Election latency**: If the leader in Singapore fails, a new leader in, say, Sydney will run Phase 1. That involves contacting a quorum. The quorum might be Sydney (0), Singapore (100), and Tokyo (80) if we add Tokyo; but Tokyo is not in our original set. Without Tokyo, the closest three from Sydney: itself (0), Singapore (100), and maybe Ireland (220) → T_max = 220 ms. So election completes in 2 \* 220 = 440 ms plus timeouts. Still painful but not as bad as 2 seconds.

### 7.1 Calculating the Probability of Failure

You can model the expected availability of the system given failure probabilities per datacenter. For Multi-Paxos, if the leader goes down, the system is unavailable until a new leader is elected. The expected unavailability per unit time = f_failure \* T_election, where f_failure is the frequency of leader crashes. With five datacenters and a typical mean time between failures (MTBF) of individual servers being high, leader crashes are rare (maybe once per month). So unavailability due to elections is negligible. But network partitions that cause leader isolation are more frequent.

A common scenario: the leader loses connectivity to one or two acceptors but not a majority. In that case, the leader remains leader (since it can still communicate with a majority) but experiences higher latency because it must wait for the slowest in the quorum, which may now be far away. This manifests as tail latency spikes.

## VIII. Implementation Details and Code Snippets

### 8.1 Classic Paxos: Simplified State Machine

Below is a pseudo-code for Classic Paxos acceptor.

```python
# Acceptor state
class Acceptor:
    def __init__(self):
        self.promised_id = 0        # highest prepare request seen
        self.accepted_id = 0        # highest accept request seen
        self.accepted_value = None

    def receive_prepare(self, proposal_id, sender):
        if proposal_id > self.promised_id:
            self.promised_id = proposal_id
            return (True, self.accepted_id, self.accepted_value)
        else:
            return (False, self.promised_id, None)

    def receive_accept(self, proposal_id, value):
        if proposal_id >= self.promised_id:
            self.promised_id = proposal_id
            self.accepted_id = proposal_id
            self.accepted_value = value
            return True
        else:
            return False
```

The proposer logic is more involved. Notice that in Classic Paxos, the proposer runs Phase 1 with an initial proposal number, then computes the value to propose in Phase 2 based on responses.

### 8.2 Multi-Paxos Leader Lease

In Multi-Paxos, the leader typically holds a lease: a promise from acceptors that they will not start an election for a specified duration (e.g., 10 seconds). The leader must extend the lease periodically.

```python
class Leader:
    def __init__(self, node_id, acceptors):
        self.node_id = node_id
        self.acceptors = acceptors
        self.lease_end = 0
        self.commit_sequence = []

    def acquire_lease(self):
        # Phase 1: send prepare with epoch number
        promises = []
        for acc in self.acceptors:
            ok, max_id, value = acc.receive_prepare(self.epoch)
            promises.append((ok, max_id, value))
        quorum = self.quorum_from(promises)  # majority
        if not quorum:
            return False
        self.lease_end = now() + LEASE_DURATION
        return True

    def propose(self, value):
        # Phase 2: send accept
        # instance_number increments
        # ...
```

Lease renewals happen before the lease expires. The leader must also monitor its health and step down voluntarily if it loses connection to the majority.

### 8.3 Fast Paxos: Client Direct Proposal

A Fast Paxos client does:

```python
def fast_propose(value, fast_quorum):
    # Choose a fast quorum (e.g., 4 of 5 nodes)
    responses = []
    for node in fast_quorum:
        ok, conflict = node.fast_accept(sequence_number, value)
        responses.append((ok, conflict))
    if all(ok):
        return (True, "committed")
    elif any(conflict):
        # Fall back to Classic Paxos
        return classic_paxos_propose(value)
    else:
        # Some nodes rejected; retry
        ...
```

Acceptors in Fast Paxos need to detect conflicting fast proposals. They record the highest fast commit they have seen, and if a fast proposal arrives with a lower sequence number, they reject it.

## IX. Advanced Topics and Variants Beyond the Three

### 9.1 EPaxos (Egalitarian Paxos)

EPaxos (by Moraru et al.) allows any node to act as a leader for a command without a fixed leader. It achieves one-round-trip commits in the common case (no conflicts) without requiring an explicit leader election. It cleverly uses command ordering to resolve dependencies. EPaxos generalizes Fast Paxos and provides higher throughput and lower latency under contention by exploiting command semantics.

EPaxos is gaining traction in production; for example, CouchDB’s FDB? Not sure. But it is an important alternative.

### 9.2 Flexible Paxos

Flexible Paxos allows the leader to choose different sets for Phase 1 and Phase 2 quorums, decoupling them. For example, you can require only 2 acceptors for Phase 1 (fast leader election) but still 3 for Phase 2 (commits). This reduces election latency at the cost of lower safety margin.

### 9.3 WAN-Specific Optimizations

- **Cohort-based quorums**: Group nodes into cohorts by region. A leader’s quorum must include at least one node from each of three regions, ensuring fast cross-region commit? Actually not necessarily; you can optimize by having the leader choose nodes from nearby regions.
- **Heterogeneous node weights**: Nodes with lower latency to each other can have larger weights in quorums.
- **Read-only leases**: For read-heavy workloads, you can serve reads from any replica that holds a lease timestamp, reducing read latency to zero round trips (if local).

## X. Putting It All Together: Which One Should You Choose?

The choice depends on your requirements:

- **If you can tolerate a leader and have low contention**: Multi-Paxos is the default. Use leader-local quorum selection and batching. Accept the rare but painful election.
- **If you cannot tolerate any single point of failure (leader) and need low latency for the common case**: Fast Paxos or EPaxos are better, but they add complexity.
- **If you need absolute worst-case predictability and simplicity**: Classic Paxos might be used in a system where writes are rare (e.g., system configuration updates).

**Case study**: A global financial transaction system with 99.999% availability. Write latency must be under 500 ms. Contention on account records is high (many updates to same accounts). Here, Fast Paxos would suffer from frequent conflicts, leading to fallback to Classic and higher tail latency. Multi-Paxos with a well-chosen leader and short leases might be better. However, if the leader fails, the election might cause a 10-second outage, violating availability. Solution: use Multi-Paxos but with rapid failure detection and a backup leader in a hot-standby region. Or use EPaxos to distribute the load without a fixed leader.

**Case study**: A global DNS service (write once, read often). Updates are infrequent (configuration changes). Here, Classic Paxos is acceptable; the 500 ms write latency is negligible compared to the update frequency.

## XI. Conclusion: The Physics Will Not Change

We began with a failed transaction in Singapore. That failure was not a software bug; it was a design flaw born from underestimating the cost of light’s finite speed. Every consensus protocol must eventually face this reality. No amount of clever algorithm design can eliminate the 160 ms minimum RTT between New York and Sydney. What we can do is reduce the number of round trips, minimize the impact of leader election, and place our quorums intelligently.

Classic Paxos, Multi-Paxos, and Fast Paxos each offer a different bargain between simplicity, latency, and fault tolerance. As systems architects, we must understand the physics of our network topology as intimately as we understand the consistency guarantees of our protocols. Only then can we build global systems that do not stall, spin, and fail at 3:47 PM.

**Final advice**: Simulate your deployment with a custom latency map. Test not just steady-state latency but also failure recovery. Use flexible quorums and leader localization. And always remember: in distributed consensus over WAN, the bottleneck is not your CPU—it’s the inertia of light.

---

_This article was written by an AI in collaboration with a human domain expert. The examples, numbers, and models are for illustration; real-world tuning requires careful measurement and testing._
