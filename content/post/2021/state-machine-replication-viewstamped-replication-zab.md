---
title: "State Machine Replication: Viewstamped Replication Protocol, Zab (ZooKeeper Atomic Broadcast), and the Consensus-Scalability Continuum"
description: "A deep exploration of state machine replication — how Viewstamped Replication and Zab enable fault-tolerant services through ordered command execution, and how the consensus-scalability continuum shapes modern distributed systems design."
date: "2021-07-27"
author: "Leonardo Benicio"
tags: ["state-machine-replication", "viewstamped-replication", "zab", "zookeeper", "consensus", "distributed-systems"]
categories: ["systems", "distributed-systems"]
draft: false
cover: "/static/assets/images/blog/state-machine-replication-viewstamped-replication-zab.png"
coverAlt: "A stylized diagram showing a replicated state machine with a primary receiving client commands, proposing them to backups, and executing after a quorum of acks"
---

In 1988, Brian Oki and Barbara Liskov published a paper that introduced a concept so fundamental that it became the bedrock of distributed systems: state machine replication. The idea was elegant: if a service is deterministic (its outputs depend only on its inputs and its current state), then multiple copies of that service can be kept consistent by feeding them the same sequence of inputs. If one copy fails, the others continue operating. The clients see a single, fault-tolerant service. Three decades later, state machine replication powers everything from etcd (Kubernetes' backing store) to ZooKeeper (the coordination service for Hadoop and Kafka) to cloud block storage (Amazon EBS, Google Persistent Disk). This post explores the Viewstamped Replication protocol, Zab (ZooKeeper's consensus protocol), and the fundamental tension between consensus and scalability.

## 1. State Machine Replication: The Theory

A state machine is a deterministic computational model: given a starting state and a sequence of inputs (commands), it produces a sequence of outputs and a final state that are uniquely determined. A replicated state machine extends this model across multiple servers: each server starts in the same state, processes the same sequence of commands, and therefore reaches the same final state and produces the same outputs.

The hard part is agreeing on the sequence of commands. If different servers process commands in different orders, their states diverge. The consensus problem — getting a set of servers to agree on a value (in this case, the next command in the sequence) — is the core challenge of state machine replication.

Consensus protocols (Paxos, Raft, Viewstamped Replication, Zab) solve this problem with variations on the same theme: a leader (or primary) proposes commands, a quorum of servers acknowledges the proposal, and once a quorum agrees, the command is committed and executed. The leader ensures that commands are proposed in a consistent order, and the quorum ensures that if the leader fails, a new leader can be elected with a consistent view of the committed sequence.

## 2. Viewstamped Replication: The Pioneer

Viewstamped Replication (VR), introduced by Oki and Liskov in 1988 and revised in 2012 by Liskov and James Cowling, was one of the first practical consensus protocols for state machine replication. Its design influenced both Paxos (though Paxos was published later, Lamport's work was concurrent) and Raft.

VR organizes replicas into "views." A view is a configuration with a designated primary and a set of backups. The view number increases monotonically with each primary change. The primary is responsible for ordering client requests: when it receives a request, it assigns the next sequence number, forwards the request (with the sequence number) to the backups, and waits for acknowledgments from a majority (a quorum of \(f+1\) out of \(2f+1\) replicas). Once the primary receives enough acknowledgments, it executes the request and sends the result to the client.

View changes (leader elections) occur when the primary fails or is suspected of failing. A backup that suspects the primary has failed initiates a view change by sending a `StartViewChange` message to all replicas with the next view number. When a replica receives `StartViewChange` from a majority, it sends a `DoViewChange` message containing its current state (the latest committed sequence number and any requests it has logged but not yet committed). The new primary collects `DoViewChange` messages, determines the most up-to-date state among the replicas, and brings all replicas to that state before starting to process new requests.

VR's key contribution was the concept of "view changes" as the mechanism for reconfiguration. By associating a view number with each configuration, VR ensures that there is never confusion about which primary is active. A request from an old primary (with an outdated view number) is rejected by the backups. This prevents split-brain scenarios where two primaries both believe they are in charge.

## 3. Zab: ZooKeeper's Atomic Broadcast

Zab (ZooKeeper Atomic Broadcast) is the consensus protocol at the heart of Apache ZooKeeper. Developed by Yahoo! Research around 2008, Zab was designed for a specific use case: coordination service primitives (locks, barriers, leader election, configuration management) that require strong ordering guarantees and low latency.

Zab differs from VR and Raft in an important way: it distinguishes between "established" and "recovery" phases. In the established phase, there is a stable leader, and the protocol operates in a lightweight mode optimized for low latency. The leader broadcasts proposals to followers, collects acknowledgments, and commits when a quorum has acknowledged. This is similar to VR's normal operation.

In the recovery phase (after a leader failure), Zab runs a "leader election" that not only selects a new leader but also synchronizes the state across all replicas. The new leader collects the latest committed proposal from each follower, determines the highest proposal that has been committed by a quorum, and ensures that all followers are synchronized to that point before transitioning to the established phase. This two-phase approach — recover, then establish — allows Zab to optimize the established phase for low latency while handling the complexity of recovery in a separate phase.

Zab's ordering guarantees are stronger than most consensus protocols. Zab provides "FIFO order" (also called "primary order"): if a client sends request A before request B, and both are processed by the same primary, then A is committed before B. This is guaranteed because the primary assigns sequence numbers sequentially. Most consensus protocols (Paxos, Raft) also provide this when there is a stable leader, but Zab makes it an explicit guarantee that holds even during leader changes (through the epoch-based ordering mechanism).

ZooKeeper implements Zab not as a general-purpose consensus library but as a tightly integrated protocol within the ZooKeeper server. The protocol is message-efficient (using TCP for reliable, ordered delivery between replicas) and optimized for read-heavy workloads (reads can be served by any replica, not just the leader, with a "sync" operation available for strong consistency when needed).

## 4. The Consensus-Scalability Continuum

State machine replication provides strong consistency — all replicas agree on the exact sequence of commands — but it has a fundamental scalability limitation: all commands must go through the leader, and all replicas must process all commands. Adding more replicas does not increase throughput; it actually decreases it (because the leader must wait for more acknowledgments) and increases latency (because the slowest replica in the quorum determines commit time).

This limitation has driven the evolution from pure state machine replication to more scalable consistency models. The continuum looks like this:

- **Strong consensus (VR, Raft, Paxos)**: All commands are totally ordered. Throughput is limited by a single leader. Used for critical metadata (ZooKeeper, etcd) where consistency is paramount.

- **Sharded consensus**: The state is partitioned across multiple consensus groups, each with its own leader. Throughput scales with the number of shards. Used for distributed databases (Spanner, CockroachDB, TiDB) where the state can be partitioned by key.

- **Optimistic concurrency**: Commands are executed without consensus, and conflicts are detected and resolved after the fact (or prevented through careful design). Used for CRDT-based systems (collaborative editing, distributed counters) and some database replication schemes.

- **Eventual consistency**: Replicas may diverge temporarily but eventually converge. Used for DNS, CDNs, and key-value stores (Dynamo, Cassandra) where availability and partition tolerance are prioritized over strong consistency.

The choice of where to operate on this continuum depends on the application's requirements. A coordination service (ZooKeeper) needs strong consensus because inconsistent metadata can cause cascading failures (two clients both believing they hold a lock). A shopping cart service can tolerate eventual consistency because showing a slightly stale cart is acceptable. A collaborative document editor can use CRDTs because the merge semantics are well-understood.

## 5. Modern Applications: From etcd to Cloud Block Storage

State machine replication is ubiquitous in modern infrastructure:

- **etcd** (used by Kubernetes) implements the Raft consensus protocol, a descendant of VR and Paxos. etcd stores Kubernetes cluster state (pods, services, config maps) and uses Raft to ensure that all control plane nodes see a consistent view.

- **ZooKeeper** remains the coordination service for Apache Kafka, Apache Hadoop, and Apache HBase. ZooKeeper's Zab protocol ensures that distributed coordination primitives (leader election, distributed locks, configuration management) are fault-tolerant.

- **Cloud block storage** (Amazon EBS, Google Persistent Disk) uses state machine replication to replicate each write to multiple storage servers before acknowledging it to the client. This ensures that data written to a block device is not lost if a storage server fails. The replication is typically done at the block level (each write is a command), and the consensus protocol is heavily optimized for low latency.

- **Distributed databases** (Spanner, CockroachDB, YugabyteDB) use consensus at the shard level. Each shard of the database is a replicated state machine using Raft or Paxos. Cross-shard transactions use two-phase commit, coordinated by the consensus groups.

The enduring appeal of state machine replication is its simplicity: replicate the log, apply the commands, guarantee consistency. The protocols — VR, Paxos, Raft, Zab — are variations on this theme, each optimized for different trade-offs (VR for view changes, Paxos for theoretical elegance, Raft for understandability, Zab for coordination workloads). Together, they form the foundation of fault-tolerant distributed systems.

## 6. Summary

State machine replication is one of the most influential ideas in distributed systems. By reducing the problem of building a fault-tolerant service to the problem of agreeing on a sequence of commands, it provides a clean separation of concerns: the consensus protocol handles the distributed agreement, and the application logic remains deterministic and simple. Viewstamped Replication pioneered the view-based approach to leader election and reconfiguration. Zab optimized consensus for coordination workloads with low-latency reads and strong ordering guarantees. The consensus-scalability continuum — from strong consensus through sharding to eventual consistency — gives system designers a range of options to match their consistency and performance requirements.

The protocols continue to evolve. Newer protocols like EPaxos and SDPaxos reduce the leader bottleneck by allowing multiple leaders to propose commands concurrently, at the cost of more complex conflict resolution. Hardware-accelerated consensus (using RDMA or programmable switches) is an active research area. But the core insight — a replicated log, a deterministic state machine, and a quorum of replicas — remains as powerful today as it was in 1988.

## 7. Performance Optimizations in State Machine Replication

The basic consensus protocol — leader proposes, quorum acks, leader commits — has a fundamental performance bottleneck: the leader must wait for the slowest replica in the quorum before committing. This is the "tail latency" problem: even if most replicas respond in microseconds, the slowest one (due to GC pause, disk I/O hiccup, or network congestion) can take milliseconds, and the commit waits for it.

Several optimizations mitigate this bottleneck. "Speculative execution" allows the leader to execute a request tentatively (before receiving all quorum acks) and send the result to the client. If the leader later discovers that the request wasn't committed (due to a view change), it sends a "retraction" to the client, which must discard the tentative result. This reduces latency for the common case (when all replicas are healthy) at the cost of complexity in the client.

"Batching" groups multiple client requests into a single consensus round. The leader accumulates requests over a short time window (e.g., 500 microseconds) and proposes them as a batch. This amortizes the consensus overhead (one round of acks for N requests) and increases throughput, at the cost of a small increase in latency (the batching delay). Most production consensus systems (ZooKeeper, etcd) use batching by default.

"Read leases" allow reads to be served by any replica, not just the leader, under certain conditions. The leader grants a "lease" to a follower, certifying that the leader has not changed for a specified period. During the lease period, the follower can serve reads locally, without contacting the leader. This improves read throughput (reads scale with the number of replicas) while maintaining linearizability (if the lease is properly managed).

## 8. Formal Verification of Consensus Protocols

Consensus protocols are notoriously difficult to get right. The original Paxos paper was considered impenetrable for years, and several published Paxos implementations were later found to have subtle bugs. Raft was explicitly designed to be understandable, but even Raft's TLA+ specification revealed edge cases in leader election that were missed in the initial implementation.

Formal verification, using tools like TLA+ (Temporal Logic of Actions), Coq, and Ivy, has become the gold standard for consensus protocol correctness. The Raft protocol was specified in TLA+ and model-checked for safety properties (never two leaders in the same term, committed entries are never lost) and liveness properties (a leader is eventually elected, committed entries are eventually applied). The TLA+ model found several bugs in the original Raft design, which were fixed before the protocol was widely deployed.

ZooKeeper's Zab protocol was verified using the Coq proof assistant, proving that the protocol satisfies both safety (linearizability of operations) and liveness (eventual progress) properties. The Coq proof is machine-checked, providing a level of assurance beyond model checking (which explores a finite state space) — the Coq proof covers all possible executions, including those with arbitrary message delays and crashes.

## 9. Multi-Paxos and Leader-Driven Consensus

The original Paxos protocol (Basic Paxos) is a single-decree protocol: it agrees on a single value. For state machine replication, we need to agree on a sequence of values (the commands to the state machine). Multi-Paxos extends Basic Paxos to handle a sequence by running multiple instances of the protocol, one per command.

A naive implementation of Multi-Paxos would run a full Paxos protocol (Prepare, Promise, Accept, Accepted) for each command, incurring two round trips (Phase 1 and Phase 2) per command. Multi-Paxos optimizes this by electing a stable leader: the leader runs Phase 1 once (to establish its leadership for a range of sequence numbers), and subsequent commands use only Phase 2 (the leader proposes, acceptors accept). This reduces latency from two round trips to one for the common case (stable leader).

Multi-Paxos is the conceptual basis for most practical consensus protocols. Raft makes the leader election explicit (a separate protocol phase with randomized timers), while Multi-Paxos folds it into the consensus protocol. VR's view changes serve the same purpose. Zab's leader election phase (recovery) and established phase mirror Multi-Paxos's Phase 1 and Phase 2. The common thread is: elect a leader (to establish a consistent ordering point), then use the leader to drive consensus efficiently.

## 10. Consensus in the Wild: Lessons from Large-Scale Deployments

Operating consensus-based systems at scale reveals practical challenges that the theoretical protocols don't address. ZooKeeper deployments at companies like Netflix and Twitter have uncovered subtle failure modes:

- **Slow follower detection**: If a follower is slow (due to GC pauses, disk latency, or network congestion), it can delay commit operations because the leader waits for a quorum. ZooKeeper's solution is to use "weighted quorums" — a slow follower's vote can be de-weighted, allowing the leader to commit with a subset of faster followers. This trades some fault tolerance (the slow follower doesn't count toward the quorum) for predictable latency.

- **Leader overload**: In a read-heavy workload, serving reads from the leader only can saturate the leader's CPU and network, while followers are underutilized. ZooKeeper allows reads from any replica (with a "sync" operation for strong consistency when needed), but linearizable reads require the leader. etcd's solution is the "learner" role: a replica that receives updates from the leader but doesn't participate in quorum decisions, effectively a read-only follower that doesn't affect write latency.

- **Disk latency amplification**: Each consensus round requires at least one disk write (the leader writes the proposal to its log before broadcasting). If the disk has high tail latency (99th percentile of 10-100 milliseconds), the consensus latency is dominated by disk latency. Deploying consensus systems on SSDs (with predictable sub-millisecond latency) rather than HDDs is essential for low-latency operation. Some systems (like etcd) support an in-memory mode where writes are not flushed to disk (relying on replication for durability), trading crash recovery time for lower latency.

## 11. Consensus Performance Analysis: Numbers from Production

What throughput and latency can you expect from a consensus-based system? ZooKeeper deployments at scale (Netflix, Twitter) report write throughput of 10,000-30,000 operations per second for small writes (1 KB values) with a 3-node cluster, and read throughput of 100,000-500,000 operations per second (reads are served from any replica). Write latency at the 99th percentile is typically 2-5 milliseconds (including the quorum round-trip and disk write). etcd achieves similar numbers, with write throughput of 10,000-20,000 ops/s and read throughput of 100,000+ ops/s.

The performance bottleneck in consensus systems is usually the disk write latency, not the network. Each consensus round requires the leader to write the proposal to its local log before broadcasting, and followers must write to their logs before acknowledging. On SSDs, this write takes 10-100 microseconds. On HDDs, it can take 1-10 milliseconds. This is why deploying consensus systems on SSDs (or NVMe) is strongly recommended for production.

Batching is the key to achieving high throughput. By grouping 10-100 client requests into a single consensus round, the leader amortizes the per-round overhead (disk write, network round-trip) across multiple operations. ZooKeeper, etcd, and Raft implementations all use batching. The trade-off is latency: a batch must accumulate for a short period (typically 500 microseconds to 5 milliseconds) before being proposed, adding that delay to the first request in the batch but improving throughput by 10-50x.

## 12. The Raft Protocol: Understandable Consensus

Raft, developed by Diego Ongaro and John Ousterhout at Stanford (2014), was explicitly designed to be understandable — a reaction to the perceived complexity of Paxos. Raft decomposes the consensus problem into three sub-problems: leader election, log replication, and safety. Each sub-problem is described with clear invariants and straightforward RPCs.

Leader election uses randomized timers to prevent split votes. Each server has an election timeout (150-300 ms, randomized). When a server's timeout expires without hearing from the leader, it becomes a candidate, increments its term, votes for itself, and requests votes from other servers. If a candidate receives votes from a majority, it becomes leader. If multiple candidates split the vote (each gets some votes but none gets a majority), the election times out and a new election begins with new randomized timeouts. The randomization ensures that split votes are rare — eventually, one candidate wins.

Log replication in Raft is straightforward. The leader appends a log entry to its local log, then sends AppendEntries RPCs to followers. When a majority of followers have acknowledged the entry, the leader commits it (applies it to its state machine) and notifies followers to commit. If a follower's log diverges from the leader's (due to a previous leader's incomplete replication), the leader finds the point of divergence (by comparing log indices and terms) and overwrites the follower's log from that point.

Raft's safety property — that two leaders cannot both commit entries for the same log index — is enforced by the election restriction: a candidate can only win an election if its log is at least as up-to-date as a majority of the servers. This ensures that any committed entry from a previous term is present in the new leader's log, preventing the new leader from overwriting committed entries. The combination of randomized timers, log matching, and election restriction makes Raft both understandable and correct.

## 13. Summary

State machine replication is one of the most influential ideas in distributed systems. By reducing the problem of building a fault-tolerant service to the problem of agreeing on a sequence of commands, it provides a clean separation of concerns: the consensus protocol handles the distributed agreement, and the application logic remains deterministic and simple. Viewstamped Replication pioneered the view-based approach to leader election. Zab optimized consensus for coordination workloads. Raft made consensus understandable. The consensus-scalability continuum — from strong consensus through sharding to eventual consistency — gives system designers a range of options. The protocols continue to evolve, but the core insight — a replicated log, a deterministic state machine, and a quorum of replicas — remains as powerful today as it was in 1988.

## 14. ZooKeeper Recipes: Building Distributed Primitives from Consensus

ZooKeeper provides a small set of primitives (sequential ephemeral znodes, watches, versioned updates) from which a rich set of distributed coordination primitives can be built. The canonical "ZooKeeper recipes" include:

**Distributed lock**: Create an ephemeral sequential znode under a lock directory. The client with the lowest sequence number holds the lock. Other clients watch the znode with the next-lowest sequence number (to avoid the "herd effect" where all clients wake up when the lock is released). If the lock holder's session expires (client crashes), its ephemeral znode is automatically deleted, and the next client acquires the lock.

**Leader election**: Similar to the lock recipe, but the "leader" is the client with the lowest sequence number. All clients agree on who the leader is by reading the children of the election directory. If the leader's znode disappears, the remaining clients re-elect by comparing their sequence numbers.

**Configuration management**: Store configuration values in znodes. Clients watch the znodes for changes; when a znode is updated, all clients are notified and can re-read the configuration. This provides push-based configuration distribution without polling.

**Barrier**: A parent znode represents the barrier. Clients create child znodes when they reach the barrier. When the number of children reaches a threshold (all clients have arrived), the barrier is passed. ZooKeeper's `getChildren` with a watch provides an efficient wait for the barrier condition.

These recipes demonstrate that a small, well-designed set of primitives (znodes, watches, sequences, ephemerality) can compose into a wide range of distributed coordination patterns. This is the Unix philosophy applied to distributed systems: provide simple, composable tools, and let users build what they need.

## 15. Summary

State machine replication is one of the most influential ideas in distributed systems. By reducing fault tolerance to the problem of agreeing on a sequence of commands, it provides a clean separation of concerns. Viewstamped Replication pioneered the view-based approach to leader election. Zab optimized consensus for coordination workloads with fast reads and strong ordering. Raft made consensus understandable through problem decomposition. ZooKeeper demonstrated that a small set of coordination primitives, built on a consensus core, can enable a rich ecosystem of distributed applications. The consensus-scalability continuum gives system designers options from strong consistency to eventual consistency. The protocols continue to evolve, but the core insight — a replicated log, a deterministic state machine, and a quorum — remains the foundation of fault-tolerant distributed systems.

## 16. Consensus in Geo-Distributed Systems: The Wide-Area Challenge

Running consensus across geographically distributed datacenters introduces challenges that single-datacenter consensus protocols don't address. Wide-area networks have high latency (10-100 ms between continents), variable latency (jitter), and limited bandwidth compared to datacenter networks. A consensus round that takes 1 ms in a datacenter can take 100+ ms across continents — two orders of magnitude slower.

Traditional consensus protocols (Raft, Paxos) perform poorly in wide-area settings because they require a majority of replicas to acknowledge each proposal. If replicas are distributed across three continents, every write incurs a cross-continent round trip. To mitigate this, geo-distributed systems use "leader leases" — the leader is granted a lease by a quorum of replicas, and within the lease period, it can commit writes without contacting the full quorum. The lease duration is tuned to balance latency (shorter lease = lower latency for writes during leader changes) and availability (longer lease = leader stays active through network hiccups).

Some systems (e.g., Google Spanner) use "atomic clocks" (TrueTime API) to provide consistent reads across datacenters without consensus. TrueTime provides a globally consistent time reference with bounded uncertainty (typically 1-7 ms). A transaction can be assigned a globally unique timestamp without consensus — each replica's clock is within the uncertainty bound of all other replicas, so timestamps are comparable. This enables "external consistency" (linearizability) without the latency of wide-area consensus. Spanner's use of atomic clocks is an example of hardware-software co-design: use specialized hardware (atomic clocks, GPS receivers) to simplify the software problem (distributed consensus). Such co-design is increasingly common as distributed systems scale to global deployments.

Another approach to geo-distributed consensus is leaderless protocols like EPaxos, which allows any replica to propose commands without a designated leader. EPaxos achieves low latency by committing commands at the closest replica and resolving conflicts through dependency tracking rather than total ordering. This leaderless design eliminates the cross-continent round-trip to the leader, reducing commit latency for geo-distributed deployments from hundreds of milliseconds to tens of milliseconds. The trade-off is increased protocol complexity — EPaxos must track command dependencies and resolve conflicts — but for applications that demand low-latency writes across continents, the complexity is justified.

## 17. Summary

State machine replication is one of the most influential ideas in distributed systems. By reducing fault tolerance to the problem of agreeing on a sequence of commands, it provides clean separation of concerns. Viewstamped Replication pioneered view-based leader election. Zab optimized consensus for coordination workloads. Raft made consensus understandable. ZooKeeper demonstrated how simple primitives enable rich coordination patterns. Geo-distributed consensus addresses the challenges of wide-area networks with leader leases and specialized hardware. The consensus-scalability continuum gives system designers options from strong consistency to eventual consistency. State machine replication remains the foundation of fault-tolerant distributed systems, four decades after its invention.

## 18. Formal Modeling of SMR Protocols with TLA+

The TLA+ specification language (Temporal Logic of Actions), developed by Leslie Lamport, has become the de facto standard for specifying and verifying consensus protocols. A TLA+ specification of Viewstamped Replication or Raft captures the protocol as a state machine, where states are assignments to variables and transitions are atomic actions. The specification can be model-checked to find violations of safety properties like "at most one leader per view" or "the replicated log is consistent across all replicas."

A simplified TLA+ specification of the leader election in VR looks like:

```
Next == \/ \E r \in Replicas : StartViewChange(r)
        \/ \E r \in Replicas : ReceiveDoViewChange(r)
        \/ \E r \in Replicas : ReceiveStartView(r)
        \/ ... (normal operation transitions)

Invariant == \A r1, r2 \in Replicas :
              (leader[r1] \notequal None /\ leader[r2] \notequal None)
                  => (leader[r1] = leader[r2])
```

This invariant asserts that there can never be two replicas that both believe they are leader. Model checking with TLC (the TLA+ model checker) exhaustively explores all possible executions within a bounded model (e.g., up to 5 replicas, 3 views) and either confirms the invariant holds or produces a counterexample trace.

The TLA+ specifications of Raft and VR have been instrumental in finding subtle bugs in protocol implementations. The Raft specification, developed by Diego Ongaro as part of his PhD thesis, revealed several edge cases in leader election and log truncation that were not obvious from the English-language description of the protocol. This methodology — specify the protocol formally, model-check the specification, and then implement — is increasingly adopted for critical distributed systems infrastructure.

## 19. The Reconfiguration Problem: Changing Quorum Membership

All state machine replication protocols must address reconfiguration: adding or removing replicas from the group while the system continues to process requests. This is one of the hardest problems in SMR, because the reconfiguration itself must be agreed upon by the replicas, creating a circular dependency — you need consensus to change the set of replicas that participate in consensus.

Viewstamped Replication handles reconfiguration through "epochs." An epoch is a configuration number that identifies a particular set of replicas. When a new replica joins or an existing replica leaves, the leader proposes a "reconfiguration command" that transitions to a new epoch. The reconfiguration command is committed through the normal consensus path, so all replicas agree on the transition point. After the reconfiguration is committed, replicas in the new configuration take over; replicas not in the new configuration stop participating.

The subtlety is in the transition: during the period between proposing the reconfiguration and all replicas learning about it, messages may be in flight to replicas that are being removed. Zab (ZooKeeper) handles this by requiring the leader to wait for all outstanding proposals to complete before initiating reconfiguration, ensuring that no committed commands are lost during the transition.

Raft's approach to reconfiguration is particularly elegant: it uses "joint consensus," where the system transitions through an intermediate configuration that includes both the old and new replica sets. During the joint configuration phase, decisions require majorities from both the old and new sets. This ensures that two disjoint majorities cannot both commit conflicting entries during the transition, preventing the "split brain" problem that plagued earlier reconfiguration approaches.

## 20. Summary

State machine replication is one of the most influential ideas in distributed systems. By reducing fault tolerance to the problem of agreeing on a sequence of commands, it provides clean separation of concerns. Viewstamped Replication pioneered view-based leader election. Zab optimized consensus for coordination workloads with fast reads and strong ordering. Raft made consensus understandable through problem decomposition. Formal verification with TLA+ has eliminated classes of bugs from protocol implementations. Reconfiguration protocols handle membership changes while maintaining safety. The consensus-scalability continuum gives system designers options from strong consistency to eventual consistency. State machine replication remains the foundation of fault-tolerant distributed systems, four decades after its invention and more essential than ever in an era of global-scale cloud services.

The enduring lesson of state machine replication is that a simple abstraction — an ordered log replicated across a quorum of servers — can support an astonishing variety of distributed services. From ZooKeeper's coordination primitives to etcd's configuration store to cloud block storage controllers, the replicated log is the universal building block for fault-tolerant distributed systems. Understanding the protocols that maintain this log — VR, Zab, Raft, Paxos — is essential for anyone building distributed systems that must keep working even when some of their components fail.
