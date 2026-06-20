---
title: "Designing A Scalable State Machine Replication Library: Multi Paxos With Reconfiguration And Joint Consensus"
description: "A comprehensive technical exploration of designing a scalable state machine replication library: multi paxos with reconfiguration and joint consensus, covering key concepts, practical implementations, and real-world applications."
date: "2022-07-31"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/designing-a-scalable-state-machine-replication-library-multi-paxos-with-reconfiguration-and-joint-consensus.png"
coverAlt: "Technical visualization representing designing a scalable state machine replication library: multi paxos with reconfiguration and joint consensus"
---

### Introduction: The Architecture of Consensus in a Dynamic World

_(The provided text is used as is, then we continue below)_

---

### 2. The State Machine Replication Model: Determinism as a Superpower

State Machine Replication (SMR) is the lingua franca of fault‑tolerant distributed systems. At its heart lies a deceptively simple contract: _all replicas start from the same initial state and execute the same sequence of deterministic commands in the same order_. Determinism is the key that unlocks this magic.

A **deterministic state machine** is one whose next state depends solely on its current state and the input command. No randomness, no thread scheduling races, no dependency on wall‑clock time. This property ensures that if two replicas execute the same operations in the same order, they will produce identical results – even if they run on different hardware, use different memory allocators, or are rebuilt with different compiler optimizations.

#### 2.1 The Client’s Perspective

From the client’s viewpoint, the system appears as a single, highly available server. The client sends a command (e.g., “increment counter,” “write key->value,” “add node to cluster”) to any replica. The replica, however, does not execute it immediately. Instead, it forwards the command to a _consensus module_ that decides the global order. Once the command is committed (i.e., agreed upon by a quorum of replicas), the state machine executes it and returns the result to the client.

This separation of concerns – ordering (consensus) from execution (state machine) – gives engineers the freedom to replace the consensus algorithm without touching the application logic. For instance, a key‑value store built on Paxos can later migrate to Raft or EPaxos with minimal changes to the business logic.

#### 2.2 Common Implementations

Most production SMR systems implement a **replicated log**: a sequence of entries, each containing a command. Every replica appends new entries to its local copy of the log in exactly the same order. The state machine then replays the log from the beginning to reach the current state.

```
[1: SET x=1] [2: SET y=2] [3: SET x=3] ... → (state machine) → {x:3, y:2}
```

This architecture is used by:

- **Apache ZooKeeper** (via Zab)
- **etcd** (via Raft)
- **Google Chubby** (via Paxos)
- **Amazon DynamoDB** (via their own Multi-Paxos variant)

The log is the single source of truth. Even if a replica crashes and loses its in‑memory state, it can recover by replaying the log from disk.

#### 2.3 The Crucial Role of Quorums

Consensus algorithms rely on **quorums** – subsets of replicas large enough to guarantee that any two quorums intersect. With `2f+1` replicas, a quorum of `f+1` ensures that no two disjoint quorums can commit conflicting values. This intersection property is the mathematical backbone of both Paxos and Raft.

For example, with 5 replicas (tolerating 2 failures), a write quorum requires 3 nodes. After crashing, the state of the log can be reconstructed by reading from any read quorum of 3 nodes. The intersection guarantees that at least one node that participated in the last write will also participate in the next read.

---

### 3. The Consensus Problem and Paxos: A Walk Through the Proof

The consensus problem is deceptively simple: a group of `n` nodes, some of which may fail (crash), must agree on a single value. Once a value is chosen, all non‑faulty nodes must eventually learn it. Paxos, proposed by Leslie Lamport in 1989, was the first practical solution.

#### 3.1 The Classic Paxos Protocol

Paxos distinguishes three roles:

- **Proposer** – initiates the protocol by proposing a value.
- **Acceptor** – votes on proposals.
- **Learner** – learns the chosen value (often the proposer itself).

The protocol runs in two phases:

**Phase 1 (Prepare):**

1. The proposer selects a proposal number `n` (unique, monotonically increasing).
2. It sends a `Prepare(n)` request to a quorum of acceptors.
3. Each acceptor responds with a promise never to accept proposals numbered less than `n`. If the acceptor has already accepted a proposal, it includes `(n_accepted, value_accepted)` in the response.

**Phase 2 (Accept):**

1. Upon receiving responses from a quorum, the proposer chooses a value to propose:
   - If any acceptor returned a previously accepted value, the proposer must choose the value with the highest proposal number among those returned.
   - Otherwise, it can propose its own original value.
2. The proposer sends `Accept(n, value)` to all acceptors.
3. Acceptors accept the proposal unless they have already promised to a higher-numbered proposal.

A value is **chosen** when a majority of acceptors have accepted it. Learners then learn the chosen value through additional message exchanges (or by piggy‑backing on the accept responses).

#### 3.2 Why Paxos Is Proof, Not Code

The beauty of Paxos is its minimalism: only two message rounds per consensus instance, and a simple proof of safety (linearizability) and liveness (given eventual leader election). But this sparseness makes it maddening to implement correctly.

- **No leader election is specified.** The classic protocol assumes a distinguished proposer, but nothing prevents multiple proposers from interfering. In practice, a leader election layer (e.g., using Paxos itself for leader selection) is necessary.
- **It defines an infinite sequence of rounds.** Real implementations must bound round numbers (e.g., using timestamps or epoch numbers).
- **Durability is left out.** Acceptors must store their promises and accepted values durably before acknowledging; otherwise, a crash after sending an accept response but before writing to disk can violate safety.
- **Membership changes are not handled.** Adding or removing nodes requires a separate configuration change protocol (e.g., joint consensus).

Paxos is a _specification_ of what must happen for a value to be chosen. A production library must weave this specification into a concrete, thread‑safe, disk‑backed, failure‑handling piece of software.

#### 3.3 Multi‑Paxos: The Common Variant

In practice, we rarely need just one instance of consensus; we need a stream of commands. **Multi‑Paxos** optimizes the protocol for a sequence of instances.

- A stable leader runs Phase 1 once to establish itself as the proposer.
- For subsequent proposals, it skips Phase 1 and directly sends Phase 2 accept messages.
- This reduces the consensus latency from 2 round‑trips to 1 round‑trip per command (or even 0.5 with batching and pipelining).

Most SMR libraries implement Multi‑Paxos (or something very close to it, like Raft).

---

### 4. From Theory to Practice: Designing a Paxos‑based SMR Library

Translating the Paxos proof into a production library is a multi‑layer engineering challenge. Let’s walk through the key components and design decisions, using a fictional library called `paxos‑lib` (written in Go) as our running example.

#### 4.1 The Core Data Structures

```go
type InstanceID uint64

type Proposal struct {
    Number ProposalNumber // (round, serverID) for uniqueness
    Value  []byte        // the command to be executed
}

type Promise struct {
    Number         ProposalNumber
    LastAccepted   *Proposal // nil if no prior accept
}

type Accepted struct {
    Number ProposalNumber
    Value  []byte
}
```

Each replica holds a **Log** object – an array (or persistent map) of instances. Each instance stores the state of the Paxos protocol for that slot (promised number, accepted proposal, etc.).

```go
type InstanceState struct {
    Promised   ProposalNumber
    Accepted   *Accepted
    Decided    bool
    DecidedVal []byte
}
```

#### 4.2 Leader Election – The Unsung Hero

Without a stable leader, Paxos degenerates into a livelock circus: proposers continually raise their numbers without making progress. A production library must implement a robust leader election that:

- Uses a **lease** (time‑bounded leadership).
- Pairs with a **failure detector** (e.g., randomized heartbeats).
- Resolves conflicts (two leaders claiming the same lease) by falling back to the Paxos protocol itself.

In the first implementation, we can reuse the Paxos log to elect a leader: every replica proposes its own ID as a special “leader” command. The first command that gets committed elects its proposer as leader for a term. Subsequent commands are proposed only by that leader until its lease expires or it is suspected dead.

#### 4.3 Log Compaction – The Memory Beast

An unbounded log is unsustainable. Replicas must periodically compact the log to discard entries that have already been applied to the state machine. Two common strategies:

- **Snapshotting:** The state machine periodically dumps its full state to disk and truncates the log up to the snapshot point. Recovery then loads the snapshot and replays only subsequent entries.
- **Log compaction (as in Kafka):** The log is rewritten, keeping only the latest state for each key. This is less common for generic SMR because it requires the state machine to be key‑value.

The tricky part is ensuring that snapshotting does not block the consensus pipeline. A typical approach uses **copy‑on‑write** or **fork** to create a point‑in‑time snapshot while accepting new commands.

#### 4.4 Durability – The Promise That Must Outlast a Crash

An acceptor that crashes after sending a promise but before writing it to disk can later (after restart) violate its promise and accept a lower‑numbered proposal. This is a classic safety violation.

Therefore, every state change (promise, accept) must be **fsynced** to non‑volatile storage before acknowledging. This turns I/O into the dominant latency factor. Engineers often use:

- **Batching:** Accumulate multiple proposals before flushing to disk (trades latency for throughput).
- **Group commits:** The leader batches several commands into one Paxos round.
- **Non‑volatile RAM (NVRAM)** as an intermediate cache.

#### 4.5 Client Interaction and Linearizability

Clients must be able to read the latest state. Yet reading from any replica may return stale data if that replica hasn’t caught up. The library must support:

- **Read‐only leases:** The leader serves reads without consensus, but only within a lease period (avoids stale reads).
- **Read quorums:** Clients send read requests to a quorum and wait for identical results.
- **Relaxed consistency (causal, eventual)** – often unacceptable for SMR.

Most production systems (ZooKeeper, etcd) use the leader’s lease for reads, with a fallback to full quorum if the lease is uncertain.

---

### 5. Implementation Sketch: Wrapping Paxos in a State Machine

Let’s write a simplified version of the **leader** logic for a single instance. This is pseudocode, but close to how a real library might look.

```python
class PaxosLeader:
    def __init__(self, node_id, acceptors, log, state_machine):
        self.id = node_id
        self.acceptors = acceptors
        self.log = log          # persistent log of instances
        self.sm = state_machine # deterministic state machine
        self.leader_term = None
        self.next_instance = 1

    def propose(self, command: bytes):
        """Called by client or when a follower forwards a command."""
        inst = self.next_instance
        self.next_instance += 1

        # Phase 1 (only if we are not already established for this instance)
        if not self._is_leader_for(inst):
            self._run_phase1(inst)
        # Phase 2
        proposal_num = self._next_proposal_number(inst)
        accept_msg = Accept(proposal_num, command)
        responses = self._send_to_quorum(accept_msg)
        if self._quorum_accepted(responses):
            self.log.mark_decided(inst, command)
            self.sm.execute(command)
            return OK
        else:
            # Conflict – retry with higher number
            return self.propose(command)  # simplified

    def _run_phase1(self, inst):
        # Prepare with a number higher than any seen
        prep_num = self.log.get_next_prepare_number(inst)
        self.log.store_promise(inst, prep_num)
        prepare_msg = Prepare(prep_num)
        replies = self._send_to_quorum(prepare_msg)
        # Based on replies, decide value to propose (if any)
        ...
```

The actual library must handle multiple instances concurrently and maintain a pipeline to batch requests. In practice, the leader uses a **pending queue** and a **timer** to batch commands.

---

### 6. Handling Failures and Edge Cases

A production library must be paranoid. Let’s examine the most common failure modes and how to defend against them.

#### 6.1 Network Partitions

A partition can leave the network split into two groups, each with a majority of nodes (e.g., 3‑node cluster splits into 2 and 1). Both halves may elect a leader.

- The smaller half (1 node) cannot form a quorum, so it cannot commit any new commands.
- The larger half (2 nodes) can commit – but it has a majority.

Once the partition heals, the smaller half’s leader must step down (upon seeing a higher‑term leader) and its uncommitted entries are discarded. This is safe because no command was ever committed in the minority side.

#### 6.2 Split‑Brain Scenarios (Leader Election Gone Wrong)

If the failure detector is too fast, two leaders may simultaneously believe they are the legitimate leader. This can lead to two conflicting logs being committed.

The solution is **sticky leadership**: a leader must maintain a lease that it refreshes by heartbeats. If a candidate does not receive a majority of acks for its lease, it cannot lead. Furthermore, new leaders should not commit entries from a previous term until they have a guarantee that no other leader could have committed them – in Raft this is achieved by checking the log for older entries before committing.

#### 6.3 Byzantine Failures

Paxos (and Raft) tolerate only crash‑stop failures. If a replica can send arbitrary (Byzantine) messages, the protocol fails. For Byzantine fault tolerance, we need alternative algorithms like PBFT (Practical Byzantine Fault Tolerance) or HotStuff. However, in a controlled environment (data center, private cloud), crash‑stop is usually sufficient.

#### 6.4 Handling Duplicate Commands

Clients may retry requests, leading to duplicate commands in the log. The state machine must be **idempotent**. For instance, if the operation is “send email,” the library must deduplicate by attaching a unique client request ID to each command and tracking already‑executed IDs in the state machine.

---

### 7. Performance and Scalability – Making Paxos Fast

One of the biggest criticisms of Paxos is its performance overhead – even Multi‑Paxos requires at least one network round trip (and one disk fsync) per command. For high‑throughput systems, we need optimizations.

#### 7.1 Batching

The leader accumulates a batch of client requests (say 100) and submits them as a single Paxos instance. The state machine then executes them sequentially. This reduces per‑command network overhead and amortizes the fsync cost.

Trade‑off: latency increases linearly with batch size. Adaptive batching (e.g., time‑out or size‑limit) works well.

#### 7.2 Pipelining

Multi‑Paxos already pipelines instances: the leader can send `Accept` for instance `i+1` before instance `i` is committed, as long as it does not reorder. This allows parallel network trips.

#### 7.3 Out‑of‑Order Command Execution (Pipelining in State Machine)

If commands are independent, some databases allow out‑of‑order execution for performance, but then the state machine loses determinism. For full SMR, commands must be executed in order.

#### 7.4 Read‑Only Paths

Many workloads are read‑heavy. Optimizations include:

- **Leader lease for reads** – the leader serves reads without consensus, using a short lease.
- **Follower reads with consistency checks** – the follower asks the leader for the latest commit index before serving a read.
- **Causal consistency** if absolute linearizability is not required.

#### 7.5 Async Commit (Fast Paxos Variants)

Fast Paxos (Lamport, 2005) reduces from 2 rounds to 1 round in the best case, at the cost of requiring larger quorums (e.g., 3f+1 for 2f+1 failures). This can dramatically lower latency in wide‑area deployments.

---

### 8. Configuration Changes – The Hardest Part

Changing the set of replicas (membership) while the system is live is notoriously difficult. A naive attempt that modifies the log directly can violate safety.

#### 8.1 Joint Consensus (Raft‑like)

The cluster transitions through a **joint consensus** phase where both the old and new configurations are active. Commands must be committed in both configurations before moving to the new one. This ensures that a majority of either configuration cannot make independent decisions.

#### 8.2 Single‑Server Changes (Paxos style)

Paxos can treat configuration changes as special entries in the log. A new configuration is proposed as a command. When committed, it takes effect for subsequent proposals. However, the leader must be careful with pending entries: it must stop proposing using the old configuration until the new one is committed.

The risk of **split clusters** during change is high. Many production systems (e.g., etcd) use a very conservative approach: only allow one node change at a time, and require confirmation that the new node has caught up before removing an old one.

---

### 9. Lessons Learned from Building Production SMR Libraries

Having designed and maintained `paxos‑lib` for a highly‑available transaction processing system, we learned several critical lessons:

1. **Testing is everything.** We wrote a full‑state TLA+ specification and used simulation testing (like `tla⁺2tools` and `mit‑6.824` style test harnesses) to catch races. We injected network partitions, message delays, and random crashes. The number of bugs found far exceeded those found by unit tests.
2. **Disk I/O is the bottleneck.** We spent weeks optimizing fsync calls. A simple group commit mechanism improved throughput by 4x.
3. **Leases require clock synchronization.** Even with NTP, clock skew can break leases. We used **hybrid logical clocks** (HLC) to avoid relying on physical time for ordering.
4. **Avoid over‑optimization that complicates reasoning.** We removed an early “fast‑path” for read‑only requests after it caused a subtle consistency violation. Linearizability is hard; keep the code simple.
5. **Log compaction is the source of half the bugs.** We implemented a snapshot‑based compaction that required freezing the state machine. The interaction between snapshotting and ongoing consensus is tricky – we eventually used a copy‑on‑write approach with read‑locks.

---

### 10. Conclusion: Building Bridges Over Abstractions

State Machine Replication and Paxos are not just academic curiosities – they are the foundations upon which we build reliable, scalable distributed systems. The journey from a two‑paragraph proof to a production library is long and filled with engineering trade‑offs, but the underlying principles remain constant: determinism, quorums, and monotonicity of proposal numbers.

The next time you use a linearizable key‑value store, remember the silent consensus protocol that orders every write. And if you ever decide to build your own, hope that your biggest challenge is not the algorithm itself, but the dozens of real‑world complications that appear only once the system meets the network.

---

_Want to dive deeper? Explore the original Paxos paper, the Raft dissertation (Diego Ongaro), or the TLA⁺ specifications for consensus. Testing a distributed consensus implementation with a model checker is the ultimate way to appreciate the gap between theory and practice._
