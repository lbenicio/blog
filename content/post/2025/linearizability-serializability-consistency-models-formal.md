---
title: "Linearizability and Serializability: A Formal Hierarchy of Consistency Models"
description: "Build a rigorous understanding of consistency models from linearizability to eventual consistency, with formal definitions, counterexamples, and the practical implications for distributed database design."
date: "2025-01-28"
author: "Leonardo Benicio"
tags: ["consistency", "distributed-systems", "linearizability", "serializability", "formal-methods", "concurrency"]
categories: ["theory", "distributed-systems"]
draft: false
cover: "/static/images/blog/linearizability-serializability-consistency-models-formal.png"
coverAlt: "A lattice of consistency models from strict serializability at the top to eventual consistency at the bottom, with formal definitions, history diagrams, and counterexample traces along each edge"
---

What does it mean for a distributed system to "behave correctly"? The question seems simple — it should do what the programmer expects. But expectations differ wildly. The programmer using a single-node SQLite database expects operations to appear atomic and isolated. The programmer using a multi-region DynamoDB table expects stale reads but eventual convergence. The programmer using Google Spanner expects transactions across continents to appear as though they ran one at a time on a single machine. Each of these expectations corresponds to a _consistency model_ — a formal contract that specifies which observable behaviors are permissible and which constitute violations.

Consistency models are the grammar of distributed systems. They tell you, with mathematical precision, what results your system may return and what guarantees it must uphold. Without a firm grasp on this grammar, you cannot reason about correctness, debug anomalies, or choose the right database for your workload. This post builds the hierarchy of consistency models from first principles, starting with the strongest — linearizability — and descending through serializability, causal consistency, session consistency, and eventual consistency. We provide formal definitions, counterexample histories that illustrate violations, and connections to real systems: Spanner's TrueTime, Cosmos DB's consistency spectrum, CRDTs, and more.

## 1. Histories, Operations, and the Formal Framework

Before defining any specific consistency model, we need a language to describe what a distributed system does. We adopt the formalism introduced by Herlihy and Wing in their seminal 1990 paper "Linearizability: A Correctness Condition for Concurrent Objects."

### 1.1 Operations, Invocations, and Responses

A distributed system exposes a set of **objects** (registers, keys, tables, queues) that clients access through **operations**. Each operation has:

- An **invocation event** \(inv(op)\) — the moment the client submits the operation.
- A **response event** \(resp(op)\) — the moment the client receives the result.
- An **operation type** (read, write, enqueue, dequeue, CAS, etc.) and **arguments**.
- A **return value** or exception.

The interval between invocation and response is the operation's **duration**. Two operations are **concurrent** if their durations overlap — neither invocation strictly precedes the other's response. Operations are **sequential** if one completes before the other begins. The **real-time precedence order**, denoted \(\prec\), is a strict partial order: \(op_1 \prec op_2\) if \(resp(op_1)\) occurs before \(inv(op_2)\).

A **history** \(H\) is a set of operation invocations and responses, along with the real-time order among them. If every operation in \(H\) has a matching response, \(H\) is **complete**. Otherwise, some operations are **pending** (invoked but not yet responded). We can always "complete" a history by either adding a response or removing the pending invocation — different consistency models handle pending operations differently.

### 1.2 Sequential Histories and Legal Histories

A history is **sequential** if it contains no concurrent operations — every invocation is immediately followed by its response before any other invocation begins. For a sequential history to be **legal**, every operation must return a value consistent with the sequential specification of the object. For a register, a read must return the value of the last preceding write (or the initial value if no write precedes it). For a queue, a dequeue must return the element that was enqueued earliest among those not yet dequeued.

The sequential specification defines the "ground truth" for a single-threaded execution. Consistency models are all about relating concurrent histories to legal sequential ones.

### 1.3 The Herlihy-Wing Formalism

Herlihy and Wing define linearizability through the concept of **linearization points**. Each operation is assigned a single instant — the linearization point — that lies within its duration. The sequence of operations ordered by their linearization points must form a legal sequential history that respects the object's sequential specification. Two key requirements:

1. **Real-time ordering:** If \(op_1 \prec op_2\) (op_1 completes before op_2 begins), then \(op_1\)'s linearization point must precede \(op_2\)'s.
2. **Sequential validity:** The sequence of operations in linearization-point order must be a legal sequential history.

This definition captures the intuitive notion of "the system behaves as if there were a single copy, and operations take effect atomically at some point between invocation and response."

## 2. Linearizability: The Strongest Single-Object Model

Linearizability is the gold standard for single-object consistency. When a key-value store claims "strong consistency on a per-key basis," it is promising linearizability for individual keys.

### 2.1 Formal Definition

A history \(H\) is **linearizable** if there exists a permutation \(\pi\) of all completed operations in \(H\) (the "linearization order"), possibly extended with some pending operations completed or removed, such that:

- \(\pi\) respects the real-time precedence order \(\prec\): if \(op_1 \prec op_2\) in \(H\), then \(op_1\) appears before \(op_2\) in \(\pi\).
- \(\pi\) is a legal sequential history of the object.

In other words, you can "stretch" or "compress" each operation's duration to a single point (the linearization point), and the resulting sequence looks like a correct sequential execution.

### 2.2 A Linearizable History (Example)

Consider a single register \(x\) initialized to 0, with three clients A, B, C:

```text
Time →

A:  write(1) ─────────────────────┐
                                   │
B:          read() → 0?  read() → 1?
                                   │
C:                    write(2) ────┘
```

If B's first read returns 0 (before any write completes) and B's second read returns 1 (after A's write completes but before C's), the history is linearizable. The linearization order could be: B.read→0, A.write(1), C.write(2), B.read→1. But wait — does this respect real-time order? B's first read completes before A's write begins, so it must appear before A's write. B's second read begins after A's write completes, but also before C's write completes. So B.read→1 could linearize before or after C's write. Both are valid, as long as the sequential semantics are satisfied (read returns value of last preceding write). The key is that some valid total order exists.

### 2.3 A Non-Linearizable History (Counterexample)

```text
Time →

A:  write(1) ─────────────────────┐
                                   │
B:          read() → 1             │
                                   │
C:                    read() → 0 ──┘
```

Here B reads 1 (so it must linearize after A's write), but C reads 0 (so it must linearize before A's write). Since B's read completes before C's read begins (\(B \prec C\) in real time), C must linearize after B. But C's return value (0) requires C to linearize before A's write. We have a cycle: C after B (by real-time order), B after A (by return value), A before C (by return value). No total order exists — the history is **not linearizable**. This is the classic "new value then old value" anomaly, and it is the most common linearizability violation in weakly consistent systems.

### 2.4 The Cost of Linearizability

Linearizability is expensive because it requires coordination. Every read must see the effect of all preceding writes, which in a distributed setting means either (a) reading from a majority quorum with write confirmation, or (b) routing all reads through a single leader. Both approaches limit throughput and increase latency. The ABD protocol (Attiya, Bar-Noy, Dolev) shows that linearizable shared memory requires at least one round-trip for reads and two for writes in the asynchronous model — and that's optimal.

Google Spanner achieves linearizability at global scale using TrueTime, which provides bounded clock uncertainty (\(\epsilon \approx 7\text{ms}\) per datacenter). Spanner's transactions wait out the uncertainty window before committing, effectively creating a globally synchronized clock. This is a brilliant engineering trade-off: pay a latency penalty (the commit wait) to achieve the strongest possible consistency guarantee.

## 3. Sequential Consistency: Weakening Real-Time

Sequential consistency, defined by Lamport in 1979, relaxes the real-time requirement of linearizability while retaining per-process ordering.

### 3.1 Formal Definition

A history \(H\) is **sequentially consistent** if there exists a permutation \(\pi\) of all operations such that:

- \(\pi\) respects **program order**: if a single process invokes \(op_1\) before \(op_2\), then \(op_1\) appears before \(op_2\) in \(\pi\).
- \(\pi\) is a legal sequential history.

Notice the difference: sequential consistency does **not** require \(\pi\) to respect real-time precedence across different processes. If process A completes a write before process B begins a read, sequential consistency allows the read to "miss" the write and see an older value, as long as A and B each see their own operations in order.

### 3.2 Example: Sequentially Consistent but Not Linearizable

```text
P1: write(x, 1) ────────────────── write(y, 1)
P2: read(y) → 1 ─── read(x) → 0
```

This history is sequentially consistent (P1's program order is preserved: write x then write y; P2's program order is preserved: read y then read x; and the interleaving write(x,1), read(y)→1, write(y,1), read(x)→0 is legal — P2 reads y after it's written but x before it's written). However, it is **not** linearizable because if P2's read(y)→1 completes before write(x,1) begins (in real time), the linearization must respect that — but P2 reading x→0 requires the write(x,1) to not have happened yet.

### 3.3 The Illusion of Global Order

Sequential consistency creates a fascinating illusion: all processes agree on a global order of operations, but that order may not align with wall-clock time. This is acceptable for applications where processes coordinate explicitly (e.g., through message passing or barriers) and don't rely on external real-time observations. But for systems that integrate with the physical world — financial trading, sensor networks, user-facing transactions — sequential consistency is usually too weak.

The canonical example of sequential consistency in practice is the memory model of older multiprocessors (pre-x86-TSO). Modern CPUs typically implement Total Store Order (TSO), which is stronger than sequential consistency in some ways (store buffers are FIFO) but weaker in others (loads can bypass stores). The hierarchy is nuanced — more on this when we discuss processor memory models.

## 4. Serializability: Transactions and Isolation

Where linearizability governs single-object operations, serializability governs multi-object transactions. The distinction is crucial and often confused.

### 4.1 Transactions as Composite Operations

A **transaction** is a sequence of operations (reads and writes over multiple objects) that is bracketed by a **begin** and a **commit** (or **abort**). Transactions are the unit of atomicity: either all operations in the transaction take effect, or none do. The goal of serializability is to make a set of concurrent transactions appear as though they executed one at a time, in some sequential order.

### 4.2 Formal Definition

A history of transactions is **serializable** if there exists a permutation of the committed transactions (the "serial order") such that executing them one at a time in that order, each against the state produced by the previous transactions, yields the same results as the original concurrent execution.

This is classically analyzed through **conflict graphs**. Two operations **conflict** if they access the same object and at least one is a write:

- Read-Write (RW) conflict: one transaction reads a value that another transaction writes.
- Write-Read (WR) conflict: one transaction writes a value that another transaction reads.
- Write-Write (WW) conflict: both transactions write the same object.

Build a directed graph where nodes are transactions and an edge \(T_i \rightarrow T_j\) indicates that \(T_i\) must precede \(T_j\) for correctness (because of a conflict). The history is serializable if and only if this **precedence graph** has **no cycles**.

### 4.3 Anomalies: What Serializability Prevents

Serializability prevents the classic transaction anomalies:

- **Dirty Read:** Reading uncommitted data. If \(T_1\) writes \(x := 1\) and \(T_2\) reads \(x \rightarrow 1\), but then \(T_1\) aborts — \(T_2\) has read a value that never "existed" in any serial execution.
- **Lost Update:** Two transactions read the same value, each modifies it, and both write back — one update is silently overwritten. This is a WW conflict without ordering.
- **Non-repeatable Read:** A transaction reads the same object twice and gets different values because another transaction committed a write in between.
- **Phantom Read:** A transaction executes a predicate query (e.g., `SELECT * WHERE age > 30`), another transaction inserts a matching row, and the first transaction re-executes the query and sees the new row.

Serializability eliminates all of these by ensuring an equivalent serial order exists.

### 4.4 The Gap Between Serializability and Linearizability

Here is a subtle point that trips up even experienced engineers: **serializability does not imply linearizability, and vice versa.** They operate at different granularities.

A system can be serializable but not linearizable if it allows the serial order to violate real-time precedence. Suppose \(T_1\) writes \(x := 1\) and commits at time \(t_1\), and then \(T_2\) begins at time \(t_2 > t_1\) and reads \(x\). If the serial order places \(T_2\) before \(T_1\), \(T_2\) might read the old value of \(x\). This is serializable (a valid serial order exists: \(T_2, T_1\)) but not linearizable (real-time precedence is violated — \(T_2\) started after \(T_1\) committed and should see \(T_1\)'s writes).

Conversely, a system can be linearizable per-object but not serializable across objects. If each object is linearizable but transactions span multiple objects without coordination, cross-object invariants can break. This is why snapshot isolation (used by PostgreSQL, Oracle, and many others) is not serializable — it allows the write-skew anomaly even though individual reads and writes are linearizable.

## 5. Strict Serializability: The Union of Both

**Strict serializability** combines serializability and linearizability: transactions appear to execute one at a time in some total order, and that total order respects real-time precedence. Formally, a history is strictly serializable if there exists a serial order \(\pi\) of transactions such that:

- \(\pi\) respects real-time precedence: if \(T_1\) commits before \(T_2\) begins, \(T_1\) precedes \(T_2\) in \(\pi\).
- The sequential execution of transactions in \(\pi\) order is legal.

Strict serializability is the transactional equivalent of linearizability. Spanner provides strict serializability (which Google calls "external consistency"). CockroachDB provides serializability by default, but you must opt in to strict serializability (via `SERIALIZABLE` isolation with clock uncertainty bounds).

### 5.1 Implementing Strict Serializability

The canonical implementation uses **two-phase locking (2PL)** with **strict 2PL** (locks held until commit) plus a commit protocol that ensures total order (often two-phase commit orchestrated by a global timestamp authority, or TrueTime in Spanner). The cost is significant: locking reduces concurrency; distributed commit adds latency. But for applications that require it — financial ledgers, inventory management, identity systems — strict serializability is the only model that provides intuitive, "single-machine" semantics across a distributed database.

## 6. Causal Consistency: Preserving Happens-Before

Causal consistency relaxes serializability by preserving only causal relationships between operations. It is the strongest model that can be implemented without coordination in an eventually consistent system.

### 6.1 The Happens-Before Relation

Define the **happens-before** relation \(\leadsto\) as the transitive closure of:

1. **Program order:** If a process executes \(op_1\) before \(op_2\), then \(op_1 \leadsto op_2\).
2. **Reads-from:** If \(op_1\) is a write and \(op_2\) is a read that returns the value written by \(op_1\), then \(op_1 \leadsto op_2\).

A history is **causally consistent** if there exists a legal sequential history that respects \(\leadsto\): operations that are causally related appear in that order. Operations that are **concurrent** (neither happens-before the other) can appear in either order — different replicas may see them differently, and that is allowed.

### 6.2 Causal Consistency in Practice

Causal consistency is appealing because it can be implemented with **vector clocks** or **dependency matrices**, piggybacked on messages. When a process sends a message, it attaches its current vector clock. The recipient merges the clock and knows which writes must be visible before processing the message. This is the mechanism behind:

- **Amazon DynamoDB's** causally consistent reads (the `ConsistentRead` parameter for GetItem).
- **Riak's** causal context with dotted version vectors.
- **MongoDB's** causally consistent sessions.
- **CRDTs** (Conflict-free Replicated Data Types), which ensure convergent merge results for concurrent operations.

Causal consistency is also the default model for **client-centric consistency** in many distributed databases: a client that performs a write and then a read (in program order) will always see its own write, even if other clients may not.

### 6.3 Causal Consistency vs. Parallel Snapshot Isolation

An important point of reference is **Parallel Snapshot Isolation (PSI)**, introduced by Sovran et al. (2011) in the Walter system. PSI guarantees that each replica applies transactions in some total order that respects causality, but different replicas may choose different total orders for concurrent transactions. This is weaker than full serializability (since concurrent transactions may appear in different orders at different replicas) but stronger than causal consistency (since within each replica, transactions are totally ordered). PSI sits at an interesting point in the design space: it enables geo-replication without global coordination while providing stronger semantics than eventual consistency. Systems like CockroachDB's multi-region deployments and YugabyteDB implement variants of PSI.

### 6.4 The Logical Clock Zoo

Implementing causal consistency requires tracking causality. The tools of choice:

- **Lamport clocks (scalar):** Each process maintains a counter incremented per local event. Piggybacked on messages, they establish a partial order. Limitation: they cannot distinguish concurrency from causality (if \(L(a) < L(b)\), we cannot conclude \(a \leadsto b\) — only the converse: if \(a \leadsto b\), then \(L(a) < L(b)\)).
- **Vector clocks:** Each process maintains a vector of length \(N\), where entry \(i\) is the number of events known from process \(i\). Vector clocks provide an exact characterization: \(V(a) < V(b)\) (pointwise less, with at least one strict) if and only if \(a \leadsto b\). This precision comes at the cost of \(O(N)\) storage and communication overhead.
- **Dotted version vectors:** An optimization that compresses vector clocks for systems with server-client topologies.

## 7. Session Consistency and Monotonic Guarantees

Between causal consistency and eventual consistency lie several **session guarantees** — weaker than full causal consistency but stronger than random eventual consistency. Terry et al. (1994) codified four session guarantees for the Bayou system:

1. **Read Your Writes (RYW):** If you write a value, subsequent reads (in the same session) must reflect that write. This is a special case of causal consistency restricted to a single session.
2. **Monotonic Reads:** If you read a value, subsequent reads will never return an older version. Reads advance monotonically — you never "go backward in time."
3. **Writes Follow Reads (WFR):** If you read a value and then write based on what you read, the write must be ordered after the version you read. This prevents a scenario where your write is lost because it was applied to an older snapshot.
4. **Monotonic Writes:** Your writes must be applied in the order you issued them.

These guarantees are typically implemented by having clients maintain **session tokens** (opaque bookmarks representing their position in the replication stream) and servers check that the client has seen all relevant updates before servicing a request. Azure Cosmos DB and AWS DynamoDB expose session consistency as a configurable option alongside stronger and weaker models.

## 8. Eventual Consistency: Convergence in the Limit

Eventual consistency is the weakest useful model. The guarantee: if no new updates are made to an object, eventually all accesses will return the last updated value. "Eventually" is intentionally vague — it could be milliseconds or hours. In practice, eventual consistency is paired with **conflict resolution** mechanisms (last-writer-wins, CRDT merge, application-level reconciliation) to handle concurrent writes.

### 8.1 The CAP Theorem Connection

Eventual consistency is the classic "AP" (Available and Partition-tolerant) choice from the CAP theorem framing. During a network partition, an AP system accepts writes on both sides and resolves conflicts later. The cost is that reads may see inconsistent states — different sides of the partition may show different values for the same key, and applications must handle this.

### 8.2 Conflict-Free Replicated Data Types (CRDTs)

CRDTs are a breakthrough for eventual consistency: they are data structures (counters, sets, maps, graphs, sequences) that guarantee **strong eventual consistency** — replicas that have seen the same set of updates will have identical state, regardless of the order in which they applied the updates. CRDTs achieve this by ensuring that concurrent operations **commute**: the merge function is associative, commutative, and idempotent.

State-based CRDTs (CvRDTs) send their entire state to peers; operation-based CRDTs (CmRDTs) send only the operation. The choice trades communication cost against storage and merge complexity. CRDTs are used in Riak (the `riak_dt` library), Redis Enterprise's Active-Active replication, and the collaborative editing engine behind tools like Teletype for Atom.

### 8.3 The Cost of Weak Consistency

The attraction of eventual consistency is performance: writes and reads can be served locally without cross-datacenter round-trips. But the cost is complexity — application developers must write code that handles stale reads, conflicting writes, and reconciliation. Over the past decade, the pendulum has swung back toward stronger consistency models as operational experience accumulated. The "eventual consistency is fine for everything" enthusiasm of the late 2000s has been tempered by the recognition that many applications — even ones that seem tolerant of staleness — contain subtle correctness requirements that weaker models violate.

## 9. The Consistency Spectrum in Real Systems

Real databases rarely implement a single consistency model. Instead, they offer a spectrum — a dial the application developer can turn to trade consistency for performance at different granularities.

### 9.1 Google Spanner: Strict Serializability via TrueTime

Spanner provides strict serializability (external consistency) across global deployments. Its innovation is TrueTime, an API that provides `[earliest, latest]` bounds on the current absolute time. By having transactions wait out the uncertainty window before committing, Spanner guarantees that the commit timestamp lies within the transaction's real-time duration, enabling a total order that respects real time. This is perhaps the most impressive engineering achievement in the consistency space: strong consistency at global scale without a single-point bottleneck (the timestamp authority is distributed via atomic clocks and GPS).

### 9.2 Azure Cosmos DB: The Consistency Dial

Cosmos DB offers five consistency levels, each precisely defined:

1. **Strong:** Linearizable reads (reads always see the latest committed write).
2. **Bounded Staleness:** Reads may lag by at most \(K\) versions or \(T\) seconds. This is a time/version-bounded weakening of linearizability.
3. **Session:** Session consistency (Read Your Writes, Monotonic Reads, Writes Follow Reads, Monotonic Writes).
4. **Consistent Prefix:** Reads never see out-of-order writes (if writes A, B, C occur in that order, a reader sees some prefix: A, or A,B, or A,B,C — never B,A or C,A).
5. **Eventual:** Eventual consistency with no ordering guarantees.

This spectrum, while impressive, can be confusing — developers must understand the formal definitions to choose appropriately. The Cosmos DB team published detailed TLA+ specifications for each level, a practice every consistency-sensitive database should follow.

### 9.3 Amazon DynamoDB: Per-Operation Consistency

DynamoDB takes a different approach: consistency is a property of each read operation, not of the database as a whole. A `GetItem` with `ConsistentRead=true` performs a strongly consistent read (linearizable) by going through a quorum. A `GetItem` with `ConsistentRead=false` (the default) performs an eventually consistent read. Writes are always strongly consistent with each other (via quorum), but an eventually consistent read may see stale data. This per-operation granularity gives developers fine control: use strong consistency for the 5% of reads that need it and eventual consistency for the 95% that don't.

## 10. Implementation Patterns for Consistency Models

Understanding the formal definitions is necessary but not sufficient. Building systems that implement these models requires mastering a repertoire of implementation patterns.

### 10.1 Quorum-Based Linearizability

The most common pattern for linearizable reads and writes uses **quorum intersection**. For a system with \(N\) replicas, a write to a quorum \(W\) and a read from a quorum \(R\) such that \(W + R > N\) guarantees that every read observes the latest write (because the read and write quorums must intersect at at least one replica). DynamoDB, Cassandra (with `LOCAL_QUORUM`), and Riak use this pattern.

The performance implication: a linearizable read requires contacting \(R\) replicas and waiting for responses. In a multi-datacenter deployment, this means cross-region round-trips. This is why systems like DynamoDB default to eventually consistent reads — a single-replica read is an order of magnitude faster than a quorum read.

### 10.2 Total Order Broadcast and State Machine Replication

For serializability, the canonical implementation pattern is **State Machine Replication (SMR)** built on **Total Order Broadcast** (also called atomic broadcast). The idea: all replicas receive the same sequence of transactions in the same order, execute them deterministically, and thus maintain identical state. The total order primitive is typically implemented via consensus (Paxos, Raft).

The key insight is that total order broadcast is equivalent to consensus in the sense that each can implement the other. A system that has solved consensus (e.g., a Raft cluster) can implement serializability by ordering all transactions through the Raft log. Conversely, serializability implies a total order of transactions, which can be used to solve consensus. This equivalence, proved by Chandra and Toueg (1996), connects the two fundamental problems of distributed systems.

### 10.3 Optimistic Concurrency Control and Certification

Many modern serializable databases (FoundationDB, Calvin, FaunaDB) use **optimistic concurrency control (OCC)** rather than two-phase locking. In OCC, transactions execute without acquiring locks, buffering their writes locally. At commit time, the transaction is **certified**: the system checks whether the transaction's read set overlaps with any concurrent transaction's write set. If there is a conflict, the transaction aborts and retries. If there is no conflict, the transaction commits and its writes become visible.

OCC can achieve higher throughput than locking when conflicts are rare (the common case in many applications). However, under high contention, OCC degenerates into repeated aborts and retries, a phenomenon known as **thrashing**. Systems like FoundationDB mitigate this by queuing conflicting transactions and executing them sequentially, gracefully degrading from optimistic to pessimistic behavior as contention increases.

### 10.4 Clock-Bound Ordering and TrueTime

Spanner's strict serializability relies on **clock-bound ordering** rather than consensus for every transaction. The idea: assign each transaction a timestamp from a GPS-synchronized clock with bounded uncertainty. Because the uncertainty is bounded (typically 1-7ms), Spanner can guarantee that if transaction \(T_1\) commits before transaction \(T_2\) begins, and the wall-clock gap between them exceeds the uncertainty, then \(T_1\)'s timestamp is less than \(T_2\)'s timestamp with certainty. The commit-wait protocol (waiting for the uncertainty window to pass) ensures this gap.

This is a masterful piece of systems engineering: it uses physical clocks not as unreliable time sources but as bounded-error instruments, converting a physics problem (clock synchronization) into a deterministic guarantee (causal and real-time ordering).

## 11. Formal Verification of Consistency Models

Consistency models are mathematical objects, and as such, they can be specified and verified formally. This is increasingly important as databases grow in complexity.

### 11.1 TLA+ and the Specification of Consistency

TLA+ (Temporal Logic of Actions), developed by Leslie Lamport, is the tool of choice for specifying consistency models. A TLA+ specification defines the set of all legal behaviors — histories that satisfy the model. For linearizability, the spec says: "there exists a serialization of operations respecting real-time order such that each read returns the value of the most recent write." The spec is declarative; it does not describe how to implement linearizability, only what it means.

Tools like the TLA+ model checker (TLC) can verify that a specific algorithm (e.g., a consensus protocol) implements a consistency model by checking that every behavior of the algorithm is a behavior of the specification. This is the gold standard for correctness.

### 11.2 Jepsen and the Empirical Testing of Consistency

While TLA+ verifies designs, Jepsen (Kyle Kingsbury's testing framework) verifies implementations. Jepsen subjects real databases to network partitions, process crashes, clock skew, and other faults, then analyzes the resulting histories against formal consistency models. A Jepsen analysis typically includes:

- **Linearizability checkers:** Knossos (Jepsen's checker) uses the Wing & Gong algorithm to determine whether a history is linearizable.
- **Serializability checkers:** Elle (a newer Jepsen checker) builds dependency graphs from transaction histories and checks for cycles.
- **Anomaly detection:** Dirty reads, lost updates, read skew, write skew — each mapped to a specific cycle pattern in the dependency graph.

Jepsen has found consistency violations in nearly every distributed database it has tested, including MongoDB, CockroachDB, Redis, PostgreSQL, and Zookeeper. The fact that even mature systems have bugs underscores the difficulty of implementing consistency correctly — and the value of formal models for detecting regressions.

### 11.3 Monotonic Decomposition and Proof Techniques

A powerful proof technique for consistency models is **monotonic decomposition**. Many consistencies can be expressed as conjunctions of monotonic predicates over histories. For example, causal consistency = session consistency + transitive closure of reads-from. By decomposing a complex model into simpler, composable parts, we can build modular proofs: if each component of a system preserves a predicate, the composition does too. This technique underpins the correctness proofs of systems like COPS (a causally consistent geo-replicated key-value store) and Eiger (a causally consistent database from Princeton).

## 12. Summary

Consistency models form a rich hierarchy, from the ironclad guarantees of strict serializability down to the airy promises of eventual consistency. Each step down the hierarchy trades safety for performance, coordination for availability. The key to navigating this hierarchy is to understand the formal definitions — not as academic abstractions, but as precise contracts that determine what your application can and cannot assume about the system.

Linearizability and serializability address different concerns (single-object vs. multi-object atomicity), and only strict serializability combines both. Causal consistency preserves the most important ordering relationships while allowing concurrent operations to diverge. Session guarantees provide practical, client-centric consistency without full causal tracking. Eventual consistency offers maximum availability at the cost of application complexity.

The lesson from Spanner, Cosmos DB, DynamoDB, and CRDTs is clear: there is no single "right" consistency model. The right model depends on your application's correctness requirements, your latency budget, and your tolerance for operational complexity. But whatever model you choose, you should be able to state it formally — because a guarantee you cannot define is a guarantee you cannot verify, and a guarantee you cannot verify is one you do not have.

The consistency hierarchy is not just theory. It is the architecture of trust in distributed systems. Every read you issue, every transaction you commit, every merge conflict you resolve — you are operating somewhere on this map. Know where you stand.
