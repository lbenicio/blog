---
title: "A Rigorous Proof Of The Abortable Consensus In A Crash Recovery Model Using Non Blocking Atomic Commit"
description: "A comprehensive technical exploration of a rigorous proof of the abortable consensus in a crash recovery model using non blocking atomic commit, covering key concepts, practical implementations, and real-world applications."
date: "2022-08-10"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/a-rigorous-proof-of-the-abortable-consensus-in-a-crash-recovery-model-using-non-blocking-atomic-commit.png"
coverAlt: "Technical visualization representing a rigorous proof of the abortable consensus in a crash recovery model using non blocking atomic commit"
---

# Abortable Consensus: When Distributed Systems Learn to Say "Never Mind"

## Introduction: The Unspoken Need for Abortable Consensus

Imagine you’re processing a complex financial transaction that spans multiple microservices—a transfer between two accounts in different banks, coupled with a trade settlement in a third system. Halfway through, the local database on one server crashes. When it recovers, parts of the transaction are committed, others are not. The system is inconsistent. You might have already seen this scenario: distributed systems fail, and when they do, the last thing you want is a permanent, irreversible partial decision. You need to _undo_ the parts that already happened or, at the very least, abort the whole operation cleanly. This is the fundamental tension between **consensus**—the ability to make all participants agree on a single value—and **recoverability**—the ability to undo an agreement when things go wrong.

Consensus is the bedrock of fault-tolerant distributed computing. From Paxos to Raft, from Byzantine fault tolerance to state machine replication, every system that promises high availability or linearizability relies on some form of consensus. But classic consensus has a hidden assumption: once a value is decided, it is final. There is no take-back. You cannot decide to abort a previously agreed-upon transaction. Yet in real industrial systems—especially those dealing with resource management, transaction processing, or multi-party coordination—the ability to abort is not just nice to have; it’s a requirement. Consider a cloud scheduler that allocates a cluster of virtual machines for a job, but then a higher‑priority task arrives. The scheduler must revoke the allocation. It needs to _undo_ a previously agreed-upon decision without blocking, without losing progress, and without leaving the system in a corrupted state. This is the problem of **abortable consensus**: a variant of consensus where processes can not only agree on a value but also later decide to abort that agreement, and the abort itself must be possible without disrupting ongoing or future operations.

The need for abortability arises in numerous distributed contexts. Consider a distributed lock manager: a process acquires a lock, performs some work, but then encounters a conflict. It must release the lock—that is, _abort_ the lock-holding state—while ensuring that other processes see a consistent view of the lock's history. Or consider a distributed transaction coordinator using Two-Phase Commit (2PC): when a coordinator crashes after sending "prepare" messages but before collecting all votes, participants are left in doubt. They cannot unilaterally abort because the coordinator might have committed, yet they cannot commit because the coordinator might have decided to abort. This is the infamous "blocking problem" of 2PC. Abortable consensus offers a way out: processes can agree to abort the transaction cleanly, even if the coordinator is unavailable, by using a consensus protocol that allows the abort decision itself to be a consensus value.

But why is this so hard? Traditional consensus protocols like Paxos and Raft are designed for a world where once a value is chosen, it is _chosen forever_. The safety properties of consensus—agreement, validity, and termination—all assume that decisions are immutable. Introducing abortability seems to violate this immutability. If we allow processes to later decide that a previously agreed-upon value should be undone, haven't we violated the agreement property? The answer is nuanced: we don't undo past decisions; instead, we make future decisions that _supersede_ or _override_ previous ones, but in a way that preserves consistency. This is akin to how a log-structured system might append a "delete" record after a "write" record—the write is not undone, but its effect is negated. However, the process of agreeing on an abort is itself a consensus problem, and it must be done without introducing new failure modes or violating the original agreement.

In this post, we will explore abortable consensus in depth. We'll start by revisiting the fundamentals of classical consensus and understanding why it is, by design, non-abortable. Then, we'll formalize the notion of abortability and present several models and protocols that achieve it. We'll look at the FLP impossibility result and see how abortable consensus circumvents it by relaxing the termination guarantee in a specific way. We'll examine practical implementations, including modifications to Paxos and Raft that support abortability, and discuss trade-offs in performance, fault tolerance, and complexity. By the end, you'll understand why abortable consensus is not just a theoretical curiosity but a practical tool for building robust, responsive distributed systems.

But before diving into the deep end, let's ground ourselves with a concrete scenario. Consider a distributed key-value store that supports transactions. A client begins a transaction that reads keys A, B, and C, and then writes to D. Under the hood, the store uses a consensus-based replication layer to ensure that all replicas agree on the order of operations. But what if, after reading A and B, the client discovers that C is locked by another transaction? The transaction cannot proceed. The client must abort. However, the reads of A and B have already been observed by the replicas; they are visible to other clients. Aborting means that the effects of those reads must be rolled back, or at least the system must ensure that no later operation depends on them. In a classic consensus system, once a read operation is committed to the log, it is there forever. To support abortability, we need a mechanism by which a group of processes can agree to mark a range of log entries as "aborted" or "invalidated," effectively erasing their effects from the system's observable state.

Another motivating example is in cloud computing resource management. A cluster scheduler uses a consensus protocol to decide which job gets which resources. Suppose the scheduler allocates 100 VMs to a long-running batch job. A few seconds later, a latency-critical web service requires those same VMs to handle a sudden spike in traffic. The scheduler needs to _preempt_ the batch job—that is, abort its resource allocation and reassign the VMs. In a simple consensus model, the allocation decision is final; the only way to release resources is to wait for the batch job to finish or to kill it, which is a form of abort but not one that is coordinated through the consensus protocol. Abortable consensus allows the scheduler to propose an abort decision that, once agreed upon, supersedes the original allocation. The batch job then sees the abort and can clean up its state, rather than being abruptly terminated.

These examples highlight a key insight: abortable consensus is not about changing the past; it's about agreeing on a _new_ decision that renders the old one irrelevant, while ensuring that all processes observe a consistent ordering of decisions. In the log-structured view, we append an "abort" entry that logically deletes the previous allocation entry. The consensus mechanism ensures that all replicas agree on this new entry and its position relative to others. The challenge is to design protocols that allow such aborts without blocking, without requiring a centralized coordinator, and without sacrificing the fault tolerance properties that make consensus valuable in the first place.

## The Foundations: Classical Consensus and Its Immutability

To understand abortable consensus, we must first understand what it means to _agree_ in a distributed system. Classical consensus is defined by three properties, typically phrased for a set of processes that each propose a value:

1. **Agreement:** No two correct processes decide on different values.
2. **Validity:** If all correct processes propose the same value \(v\), then any correct process that decides must decide \(v\).
3. **Termination:** Every correct process eventually decides some value.

These properties together ensure that despite message delays, crashes, and network partitions, a set of processes can converge on a single value that is consistent with the proposals. The "decide" action is terminal: once a process decides, it never changes its mind. This immutability is crucial for building state machines that replay a log of commands: each command must be uniquely determined and applied exactly once.

The most famous implementation of consensus is the Paxos protocol, proposed by Leslie Lamport in 1989. Paxos operates in rounds, where a leader proposes a value and attempts to get it accepted by a majority of acceptors. The key safety property is that once a value is chosen (accepted by a majority), it remains chosen forever, even if multiple leaders conflict. Paxos achieves this through the use of ballot numbers: higher-numbered ballots can overwrite lower-numbered ones, but only if the new value is consistent with any previously chosen value. This mechanism ensures that once a value is decided, no later ballot can decide a different value. Thus, Paxos explicitly prevents abortability: you cannot "un-choose" a value without violating the protocol's invariants.

Raft, invented by Ongaro and Ousterhout in 2013, is a more approachable consensus protocol that is widely used in modern systems like etcd, Consul, and MongoDB. Raft also ensures immutability through its leader election and log replication mechanisms. Once a log entry is committed (replicated to a majority of servers), it is never removed or overwritten. The leader can only append new entries; it cannot delete or modify committed ones. This append-only log model is the foundation of state machine replication, where each command is deterministic and must be applied in exactly the same order on all replicas.

Why is immutability so important? Consider the implications if a committed entry could later be aborted: the state machine could diverge. Replica A might have already applied the entry and updated its state, while Replica B, which was slow, might never apply it because the abort decision arrived first. To maintain consistency, we would need a mechanism to roll back applied entries, which is complex and error-prone. Classic consensus avoids this complexity by simply forbidding rollbacks.

However, this rigidity is a limitation in many real-world applications. Systems often need to _change their mind_: a transaction that was thought to be valid might later be found invalid due to a conflict; a resource allocation might need to be revoked; a decision might become stale because new information arrives. In these cases, the system needs a way to reach a new consensus that invalidates the old one, without disrupting the fundamental properties of the consensus protocol.

Enter abortable consensus. The idea is to extend the definition of consensus to allow processes to decide not only a value but also a _status_ that can be "aborted" or "committed." More generally, we can think of each consensus instance as having two phases: a voting phase where processes tentatively agree on a value, and a finalization phase where they either commit or abort. The key is that the abort decision itself must be made through a consensus process: all processes must agree that an abort has occurred, and they must agree on which previously decided value is being aborted.

One way to model this is to imagine the consensus log as a sequence of "records" where each record can be in one of three states: `PENDING`, `COMMITTED`, or `ABORTED`. Initially, a record is `PENDING`. A process proposes a value and the protocol tries to move the record to `COMMITTED`. However, before it is committed, another process can propose an abort, and if a majority agrees, the record becomes `ABORTED`. Once `COMMITTED` or `ABORTED`, the record is final. The challenge is to ensure that at most one of commit or abort can succeed, and that all processes see the same final state for each record.

This is similar to the abstraction of _conditional consensus_ or _two-phase decision making_, but it differs from classic Two-Phase Commit (2PC) in that it does not rely on a single coordinator. In 2PC, the coordinator is a single point of failure and can block the protocol if it crashes. In abortable consensus, the abort decision is distributed and can be made by any process that detects a need to abort, as long as it can gather a majority of votes. This makes the protocol more resilient and non-blocking.

## The FLP Barrier and How Abortable Consensus Circumvents It

In 1985, Fischer, Lynch, and Paterson proved a landmark result: in an asynchronous distributed system where processes can crash, no deterministic consensus protocol can guarantee both safety and liveness. Specifically, they showed that if messages can be arbitrarily delayed and processes can fail, there is always a scenario where the protocol cannot decide. This is the famous FLP impossibility result. It means that any consensus protocol must make some trade-off: either it weakens the termination guarantee (allowing the possibility of indecision) or it uses some form of synchrony (like timeouts or failure detectors) to make progress.

Classic consensus protocols like Paxos and Raft circumvent FLP by using a _leader_ and _failure detectors_ that provide eventual accuracy. Under normal conditions, the leader drives the protocol to completion. If the leader crashes, a new leader is elected, and eventually a decision is reached. However, FLP still applies: in pathological scenarios (e.g., a constantly fluctuating network), the protocol might never terminate, but such scenarios are rare in practice.

Abortable consensus faces a similar barrier. The ability to abort introduces a new dimension of nondeterminism: processes can propose either a value or an abort. The protocol must decide whether to commit the value or abort it. This is essentially a binary consensus problem (commit vs. abort) layered on top of the value consensus. The FLP result implies that, under asynchronous assumptions, no deterministic protocol can guarantee that a decision (commit or abort) is always reached. However, we can trade off one type of liveness for another.

One approach is to use a _randomized_ algorithm for the commit/abort decision. Randomized consensus algorithms, like Ben-Or's protocol, can achieve termination with probability 1, even in asynchronous systems. These protocols use randomization to break symmetry and avoid the deterministic deadlocks that FLP exploits. Another approach is to use a _failure detector_ that can detect when a process has crashed or become unreachable, and then trigger an abort. This is analogous to how leader election works in Paxos: a timeout triggers the election of a new leader, which then tries to make progress.

A third approach, often used in practice, is to weaken the termination guarantee for abort decisions. For example, we might guarantee that if a value has been proposed and no abort is ever proposed, then eventually the value will be committed. But if an abort is proposed, we guarantee that eventually either the abort succeeds or the value is committed (i.e., the protocol does not remain stuck in a pending state forever). This is similar to the _validity_ property in classical consensus, but extended to handle two possible outcomes.

The FLP barrier also manifests in the interplay between commit and abort. Consider a scenario where two processes simultaneously propose different values, and a third process proposes an abort. The protocol must decide which of the three proposals to act upon. Without additional assumptions, it's possible to construct an execution where no value commandeers enough votes to become committed, and no abort commandeers enough votes to succeed, leading to a livelock. This is exactly the kind of scenario FLP warns about.

To avoid this, protocols often impose a priority scheme: commit attempts have higher priority than abort attempts, or vice versa. For example, in some distributed transaction systems, a prepared transaction can only be aborted by a coordinator that holds a special "abort token." This token can be transferred between processes, but only one process can hold it at a time. This reduces the problem to a leader election, which is a well-studied consensus variant.

Another technique is to use _epochs_ or _round numbers_. Each attempt to commit or abort is assigned a round number, and the protocol only considers the highest-numbered round. This is exactly how Paxos handles multiple proposals: a higher-numbered ballot can override a lower-numbered one, but only if the new proposal is consistent with any previously chosen value. In the abortable context, a higher-numbered abort proposal can abort a lower-numbered tentative commit, but once a value is committed in a given round, it cannot be aborted by a lower-numbered round. This ensures that if a value is committed in a high round, it remains committed even if a later abort proposal appears with an even higher round—unless that abort proposal is itself decided.

## From Theory to Practice: Designing an Abortable Consensus Protocol

Let's design a concrete abortable consensus protocol from the ground up. We'll build on the structure of Paxos, but extend it to support abort decisions. We'll call this protocol **Abortable Paxos** (or APaxos for short). The goal is to allow a set of processes to agree on a sequence of decisions, each of which can be either a _commit_ of a proposed value or an _abort_ of a previously committed value (more precisely, a decision that supersedes a previous commitment).

Our system model consists of three roles: **proposers**, **acceptors**, and **learners**. Proposers propose either a value or an abort. Acceptors vote on proposals, and a decision is reached when a majority of acceptors accept a proposal. Learners observe the decisions and apply them to the state machine.

To handle conflicts and ensure safety, we use _ballot numbers_ (or _round numbers_). Each proposer has a unique identifier and a sequence number. A proposal is a tuple (ballot, type, payload), where type is either `COMMIT` or `ABORT`. For `COMMIT` proposals, the payload is the value to be committed. For `ABORT` proposals, the payload is a reference to a previously committed value (or a range of values) that should be invalidated.

The protocol proceeds in phases, similar to the classic Paxos prepare and accept phases:

**Phase 1 (Prepare):** A proposer selects a ballot number \(b\) (higher than any it has seen before) and sends a `Prepare(b)` message to a quorum of acceptors. Each acceptor responds with a promise to not accept any proposal with a ballot number less than \(b\). The acceptor also includes information about any proposal it has already accepted (the highest ballot number and its value). This phase is identical to Paxos.

**Phase 2 (Accept):** Upon receiving responses from a majority, the proposer constructs an accept message. The rule for choosing the value is critical: if any acceptor reported a previously accepted proposal with ballot number \(b' < b\), the proposer must reuse the value from the highest such ballot (this is the classic Paxos safety rule). Otherwise, the proposer is free to choose its own value. This ensures that once a value is chosen (i.e., accepted by a majority in some ballot), no later ballot can choose a different value.

Now, here's where abortability comes in. We need to extend the rule to handle `ABORT` proposals. Suppose a proposer wants to abort a previously committed value \(v\). It cannot simply propose an `ABORT` with \(v\) as the payload, because classic Paxos would force it to reuse any previously accepted value from a lower ballot, which might be a `COMMIT` proposal. Instead, we need to distinguish between two types of decisions: "commit decisions" and "abort decisions." The key insight is that an abort decision is itself a new decision that logically overrides a previous commit decision. We can think of the log as a sequence of slots, and each slot can be in one of three states: empty, committed (with a value), or aborted. The protocol ensures that a slot can only be committed or aborted once, and that once committed, it cannot be aborted except by a subsequent decision in a _different_ slot that effectively cancels it out. But this is more complex.

A simpler approach is to use a _two-phase finalization_: we treat each consensus instance as having two sub-decisions: first, a _tentative_ agreement on a value (like a "prepare" vote in 2PC), and second, a _finalization_ phase where the value is either committed or aborted. However, this reintroduces the blocking problem of 2PC if a coordinator crashes during finalization.

Better: we can model the abortable consensus as a sequence of _atomic_ decisions where each decision is either `commit(v)` or `abort`. The protocol must ensure that for any two decisions, they are consistent: you cannot have both a commit and an abort on the same value; you cannot have two different commits in the same slot; and so on. This is essentially a linearizable register with two operations: write (which commits) and abort (which invalidates an earlier write). The challenge is to implement this register in a fault-tolerant, distributed manner.

One elegant solution is to use _paper consensus_ but with a twist: each acceptor maintains a _last-committed_ and a _last-aborted_ pointer. An accept message for a `COMMIT` must specify the value and the slot number. An accept message for an `ABORT` must specify the slot number and the previous commit that it is aborting. Acceptors track dependencies: they will only accept an `ABORT` if they have already accepted the corresponding `COMMIT` (or have evidence that a majority has accepted it). This ensures causal consistency.

To make progress, we need a leader that can order proposals. The leader can be elected using a standard failure detector (like in Raft). The leader collects tentative commits from clients and decides which to finalize (commit or abort). It then proposes the final decisions to the acceptors. If the leader crashes, a new leader is elected and can recover the state from the acceptors, then continue.

However, this design still has a central coordinator, which is a bottleneck. Fully decentralized abortable consensus protocols exist, such as the _Abortable Consensus_ algorithm by Guerraoui and Raynal, or the _Consensus with Abort_ by Mostéfaoui et al. These protocols use round-based voting and quorums to allow any process to propose an abort, and they guarantee that only one outcome (commit or abort) can be decided per slot.

## Comparing Abortable Consensus with Related Concepts

Abortable consensus should not be confused with other related concepts in distributed computing. Let's clarify the distinctions:

- **Byzantine Fault Tolerance (BFT):** BFT protocols deal with malicious actors who may send arbitrary messages. Abortable consensus assumes benign failures (crashes, omissions) but adds the ability to abort. Some BFT protocols, like PBFT, support state machine replication with view changes, but they do not natively support aborting committed decisions. However, you can layer abortability on top of BFT by introducing a "reconfiguration" command that changes the state machine's behavior.

- **Two-Phase Commit (2PC) and Three-Phase Commit (3PC):** These are transaction commit protocols, not consensus protocols. 2PC is blocking in the presence of coordinator failures. 3PC reduces blocking but still requires a coordinator. Abortable consensus is inherently non-blocking because it uses quorums to make decisions. Also, 2PC/3PC decide between commit and abort for a _single_ transaction; abortable consensus can handle multiple independent decisions in a sequence.

- **Multi-Paxos and Raft:** These are classical consensus protocols. They do not support abortability. However, you can simulate abortability using _compensation transactions_ or _sagas_: for each committed operation, you later commit a compensating operation that undoes its effect. This works but requires careful management of dependencies and can lead to cascading compensations. Abortable consensus provides a more direct and atomic mechanism.

- **Distributed Locking and Lease-Based Systems:** Distributed locks (e.g., ZooKeeper, Etcd) allow processes to acquire and release locks. The release is analogous to an abort. However, locks are not consensus decisions; they are more like reading and writing a register with ephemeral nodes. Abortable consensus provides a stronger consistency model, where the _act of aborting_ is itself a consensus decision that all processes agree upon.

- **Atomic Commitment:** This is the problem of getting multiple processes to agree on whether a transaction should commit or abort. Classic atomic commitment (like 2PC) requires a coordinator. Abortable consensus can implement atomic commitment without a coordinator by treating the commit/abort decision as a consensus problem. In fact, the _Application of Abortable Consensus to Atomic Commitment_ is a well-known result.

## Real-World Implications and Use Cases

Abortable consensus is not just an academic exercise; it has practical significance in several domains. Let's explore some use cases in depth.

### 1. Distributed Transaction Processing

Modern microservice architectures often use the Saga pattern for long-lived transactions. Each step in a saga has a compensating action that undoes its effects. However, compensations are typically executed asynchronously and may fail. If multiple steps commit and then the saga needs to be aborted, coordinating the compensations can be complex and error-prone. Abortable consensus could simplify this: each step is a tentative decision that can be aborted at any time before finalization. The final decision to commit or abort is made via consensus, ensuring that all services see the same outcome.

For example, consider an e-commerce platform that processes an order: it involves inventory deduction, payment processing, and shipment scheduling. If inventory is available and payment succeeds, the order is committed. But if payment fails, the inventory deduction must be rolled back. In a classical saga, the inventory service would have a compensating action (add the item back to inventory). However, if the inventory service has already shipped the item (due to a race condition), the compensation might fail. Abortable consensus ensures that no service commits its part until the entire set of services agrees on the final outcome. This is similar to distributed atomic commitment but without a single coordinator.

In such a system, the consensus protocol would manage a _transaction log_ where each transaction is assigned a unique identifier. Participants (services) propose either `commit` or `abort` for that transaction. The consensus protocol decides the final outcome. This eliminates the need for external orchestrators and provides a deterministic, consistent outcome.

### 2. Cloud Resource Management

As mentioned earlier, cloud schedulers benefit from abortable consensus. In large-scale data centers, resources like CPU cores, memory, and network bandwidth are allocated to jobs. Preemption is common: a lower-priority job may be evicted to make room for a higher-priority one. Current systems often handle this by killing the low-priority job (hard preemption) or by relying on the job's cooperation (nice preemption). Neither is ideal: hard preemption can corrupt state, and nice preemption is not always feasible.

With abortable consensus, a scheduler can make a tentative resource allocation decision. If a higher-priority job arrives, the scheduler proposes an abort for the previous allocation. The consensus protocol ensures that all nodes agree on the abort before the low-priority job is evicted. The low-priority job can then clean up its state gracefully. This is particularly useful for stateful workloads (e.g., databases, in-memory caches) where abrupt termination can cause data loss.

### 3. Multi-Agent Coordination and Planning

In artificial intelligence and robotics, multiple agents may need to coordinate on a joint plan. For example, a fleet of drones may agree on a flight path to avoid collisions. If one drone detects an obstacle, it may need to abort the current plan and propose a new one. Abortable consensus allows the group to agree on the abort atomically, ensuring that all drones switch to the new plan simultaneously. This avoids the scenario where some drones are executing the old plan while others are executing the new one, leading to collisions.

### 4. Blockchain and Smart Contracts

Blockchain networks rely on consensus to agree on the order of transactions. In permissioned blockchains (like Hyperledger Fabric), transaction endorsement and ordering are decoupled. A transaction can be endorsed by peers but later found to be invalid (e.g., duplicate spending). Instead of appending an invalidation transaction, which clogs the ledger, the ordering service could support abortable consensus: it can decide to abort a previously ordered transaction and remove it from the chain before it is committed to the ledger. This would require modifications to the blockchain's validation protocol, but it could improve throughput and reduce ledger bloat.

## Implementation Considerations and Challenges

Building an abortable consensus protocol in a real system requires careful attention to several details. Let's explore the main challenges.

### State Management

How do acceptors and learners track the state of decisions? They need to know which decisions are committed, which are aborted, and which are still tentative (pending). The state can be represented as an array of slots, each slot having a (ballot, value, status) tuple, where status is one of `PENDING`, `COMMITTED`, or `ABORTED`. However, this data structure can grow large over time. Garbage collection is necessary: once a slot is committed and its value has been applied to the state machine, the slot can be reclaimed (if no further aborts are possible). But aborts can only target previously committed slots, so we need to keep enough history to ensure that an abort can be validated.

One approach is to use a _log-structured merge tree_ (LSM-tree) or an append-only log with compaction. Another is to maintain a _checkpoint_: a point in the log before which all decisions are final and no more aborts can happen. Periodically, the system takes a snapshot and truncates the log.

### Liveness and Termination

Ensuring that the protocol eventually terminates is tricky, especially under contention. Multiple proposers may simultaneously attempt to commit and abort, leading to ballot number contention. Classic Paxos handles this with randomized backoff and leader election. In abortable consensus, we need to ensure that if many processes are trying to abort a specific decision, they don't all fail due to conflicting ballot numbers. A common technique is to use a _lease_-based or _token_-based mechanism: only the holder of a "commit token" can commit, and only the holder of an "abort token" can abort. This reduces contention but introduces a bottleneck.

Alternatively, the protocol can prioritize commits over aborts, or vice versa. For example, we can design the protocol so that a commit proposal can only be overridden by a higher-numbered commit proposal, not by an abort proposal. Aborts would be handled in a separate log or a separate consensus instance that maps to the same state. This is the approach taken by systems like _RAMP transactions_ (Read Atomic Multi-Partition).

### Fault Tolerance

Crashes during the abort process must be handled gracefully. Suppose an acceptor crashes after accepting a commit but before the commit is finalized. The protocol must ensure that the commit is not lost and that an abort is not erroneously declared without the proper context. Using quorums and ballot-based ordering, we can ensure that even if an acceptor crashes, the remaining acceptors can still make progress. The recovery protocol for a crashed acceptor involves replaying any missed decisions from the other acceptors or from a persistent log.

### Performance Overhead

Adding abortability increases the number of messages and rounds. Each decision now has two phases (commit and potential abort). Furthermore, abort proposals must be synchronized with commit proposals to avoid conflicts. To mitigate this, we can batch abort operations: instead of aborting a single commitment, we can abort a range of slots, or we can combine multiple aborts into a single proposal. Also, we can leverage the fact that in many systems, aborts are rare compared to commits. The protocol can be optimized for the common case (commit) and have a slower, less optimized path for aborts.

## Conclusion

Abortable consensus bridges the gap between the need for irreversible agreement in distributed systems and the practical reality that decisions sometimes need to be undone. By extending classical consensus protocols like Paxos and Raft with the ability to agree on an abort decision, we can build systems that are more flexible, responsive, and resilient.

We've seen that abortable consensus is not about changing the past but about agreeing on a new future that supersedes the old one. The FLP impossibility result applies, but we circumvent it using techniques like failure detectors, randomization, and round-based ordering. We've examined design principles for an abortable consensus protocol, including quorum-based voting and priority schemes.

In practice, abortable consensus has applications ranging from distributed transactions and resource management to multi-agent coordination and blockchain. The challenges of state management, liveness, and performance are significant but tractable, and several research contributions have shown feasibility.

The next time you design a distributed system that needs to handle rollbacks, preemptions, or cancellations, consider whether abortable consensus could provide a clean, principled foundation. Instead of ad-hoc compensation logic or fragile coordinator-based approaches, you can leverage the power of proven consensus techniques to achieve both agreement and recoverability.

---

_Further Reading:_

- Mostéfaoui, A., Rajsbaum, S., Raynal, M., & Travers, C. (2003). _Abortable Consensus and Its Application to Atomic Commitment_. IEEE Transactions on Parallel and Distributed Systems.
- Guerraoui, R., & Raynal, M. (2002). _The Information Structure of Indulgent Consensus_. In _Proceedings of the 21st Annual ACM Symposium on Principles of Distributed Computing_.
- Lamport, L. (1998). _The Part-Time Parliament_. ACM Transactions on Computer Systems.
- Ongaro, D., & Ousterhout, J. (2014). _In Search of an Understandable Consensus Algorithm_. In _USENIX ATC 2014_.
- Fischer, M. J., Lynch, N. A., & Paterson, M. S. (1985). _Impossibility of Distributed Consensus with One Faulty Process_. Journal of the ACM.
