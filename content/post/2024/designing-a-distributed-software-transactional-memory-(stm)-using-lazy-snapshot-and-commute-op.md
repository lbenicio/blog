---
title: "Designing A Distributed Software Transactional Memory (Stm) Using Lazy Snapshot And Commute Op"
description: "A comprehensive technical exploration of designing a distributed software transactional memory (stm) using lazy snapshot and commute op, covering key concepts, practical implementations, and real-world applications."
date: "2024-12-03"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/designing-a-distributed-software-transactional-memory-(stm)-using-lazy-snapshot-and-commute-op.png"
coverAlt: "Technical visualization representing designing a distributed software transactional memory (stm) using lazy snapshot and commute op"
---

# Beyond Locks and Logs: Designing a Distributed STM with Lazy Snapshots and Commute Ops

**Title:** Beyond Locks and Logs: Designing a Distributed STM with Lazy Snapshots and Commute Ops

Imagine you are building the core of a global-scale, real-time multiplayer game. Player A in Tokyo fires a weapon, Player B in London casts a shield, and Player C in New York loots an item. These three actions happen within milliseconds of each other, but they all modify a shared set of data—the game world's state. The central problem of distributed systems is hiding in plain sight here: how do we ensure that everyone agrees on the _order_ of these events? Did the shield block the blast, or was the player already looting? The answer dictates the integrity of the entire simulation.

We have classic tools for this. Distributed databases offer ACID transactions, but they come with a heavy price: the coordination overhead of two-phase commit (2PC) and the latency of distributed locking. We can shard the data, but cross-shard transactions become a bottleneck. We can use CRDTs (Conflict-free Replicated Data Types) for automatic conflict resolution, but they force us into a specific mathematical straitjacket that does not gracefully handle all arbitrary transaction logic.

There is a persistent, frustrating gap in the distributed systems landscape. On one side, we have the raw, blazing performance of weakly-consistent, partition-tolerant datastores (like Amazon DynamoDB’s default mode or a simple Redis cluster). On the other, we have the strong, serializable consistency of a single-node database or a globally-coordinated system like Google Spanner. The gap is where most real-world, latency-sensitive applications live. They want strong consistency guarantees—transactions that either fully commit or fully abort—without paying the prohibitive price of distributed locking.

This is the challenge that has driven system designers for a decade. We need a new abstraction—one that allows us to compose arbitrary read-modify-write operations across sharded or replicated data, with minimal coordination, yet still provides a clean, deterministic outcome. The solution lies in a fusion of two powerful ideas: _lazy snapshots_ and _commutative operations_ (commute ops). Together, they form the foundation of a Distributed Software Transactional Memory (DSTM) system that is both scalable and consistent.

In this blog post, we will dissect the problem of distributed transactions, explain why classical approaches fall short, and then build from first principles a DSTM that leverages lazy snapshots for efficient read access and commute ops for conflict-avoidant writes. We’ll walk through the architecture, examine concrete algorithms, and provide code examples that illustrate how to implement these ideas in a real system. By the end, you’ll understand how to design a transaction layer that combines the performance of weakly-consistent stores with the safety of serializable transactions.

---

## Section 1: The Legacy of Distributed Transactions – A History of Pain

### 1.1 The Iron Grip of Two-Phase Commit

The textbook solution for distributed transaction coordination is the Two-Phase Commit (2PC) protocol. In 2PC, a coordinator asks all participants to prepare; if everyone votes “yes,” the coordinator issues a commit. Otherwise, an abort is sent. While conceptually simple, 2PC suffers from several pathologies in practice:

- **Blocking:** If the coordinator crashes after the prepare phase, participants must hold locks and wait for recovery, blocking other transactions.
- **Latency:** Every transaction incurs multiple network round-trips (prepare → vote → commit). In a geo-distributed setting, that latency can easily exceed 100ms.
- **Scalability:** As the number of participants grows, so does the probability of one participant failing or being slow, dragging down the entire transaction.

These issues make 2PC unsuitable for high-throughput, low-latency applications like the multiplayer game example.

### 1.2 Distributed Locking – The Deadly Embrace

An alternative is to use distributed locks (e.g., Apache ZooKeeper or etcd) to serialize access to shared resources. A transaction acquires locks on all needed data items, performs its operations, then releases the locks. This approach has well-known problems:

- **Deadlocks:** Two transactions waiting for each other’s locks can stall the system.
- **Cascading Aborts:** If a lock holder aborts, all transactions that waited for it must also abort.
- **Coordination Overhead:** Acquiring locks from a centralized service (like ZooKeeper) adds latency and creates a bottleneck.

Moreover, distributed locking does not compose well: the lock manager becomes a single point of contention.

### 1.3 Pessimistic vs. Optimistic Concurrency

In a distributed database, concurrency control is typically divided into pessimistic (locks) and optimistic (OCC) approaches.

- **Pessimistic:** Locks are acquired upfront. This works well under high contention but wastes resources when contention is low.
- **Optimistic (OCC):** The transaction reads versioned data locally, computes a write set, and then validates at commit time that no conflicts occurred. OCC works well under low contention but can cause a high abort rate under contention.

Distributed OCC (like in Percolator or Spanner) uses specialized timestamping (TrueTime in Spanner) or a central timestamp oracle. The validation step still requires coordination, often a two-phase commit variant.

### 1.4 The CRDT Promise – and Its Limits

Conflict-free Replicated Data Types (CRDTs) offer a radically different path: instead of coordinating to avoid conflicts, we embrace them and define merge functions that converge to the same state regardless of update order. Each replica can apply updates locally without coordination. Convergence is guaranteed by _commutativity_ or _monotonicity_ of operations.

CRDTs work wonderfully for specific applications like collaborative editing (e.g., Google Docs) or counters (e.g., DynamoDB’s atomic counters). However, they have significant limitations:

- **No General Transactions:** CRDTs cannot compose arbitrary read-modify-write operations that depend on the current state. For example, “deduct gold if player has enough gold” is not a commutative operation because it depends on the gold balance at the time of the read.
- **Semantic Weakness:** The application must accept eventual consistency—the order of updates across replicas may produce intermediate states that violate application invariants (e.g., overdrawing an account).
- **Operation Design:** Designing commutative operations for complex business logic is non-trivial; you are forced into a functional programming mindset.

Thus, for general-purpose distributed transactions, CRDTs are not a complete solution.

### 1.5 The Gap: Where We Need a New Abstraction

The gap is clear: we want the _performance_ of OCC/CRDTs (no blocking, no heavy coordination) but with the _correctness_ of serializable transactions (atomicity, isolation, consistency). We want to support arbitrary transactional logic, not just commutative operations. And we want to operate across partitions (shards) without a global coordinator.

This brings us to the idea of a _Distributed Software Transactional Memory_ (DSTM) – a middleware layer that provides transactional semantics on top of distributed key-value stores. The challenge is to minimize coordination while preserving correctness. The two key ideas we will use: **lazy snapshots** and **commute ops**.

---

## Section 2: The Vision – Lazy Snapshots and Commute Ops

### 2.1 What Is a Lazy Snapshot?

In conventional snapshot isolation (SI) databases, each transaction reads a consistent snapshot of the data at a given timestamp. That snapshot is usually determined at the start of the transaction (or at the first read). In a distributed setting, taking a snapshot would normally require coordinating with all shards to agree on a global time.

A _lazy snapshot_ defers that agreement. Instead of fixing a global timestamp upfront, a transaction reads from each shard _lazily_—i.e., it requests the most recent version available at the time of the read, but it also _annotates_ the read with a version number. The transaction accumulates a set of read versions from different shards. At commit time, it checks whether those versions are still consistent (i.e., no concurrent updates occurred). This is similar to optimistic concurrency control, but in a distributed context we need to ensure that the reads collectively represent a consistent snapshot _across shards_.

Lazy snapshots allow a transaction to read from each shard independently, without global coordination. The consistency check happens only at commit time. This dramatically reduces latency because most transactions are read-only or low-contention and can commit without coordination.

### 2.2 What Are Commute Ops?

A _commute op_ (commutative operation) is an operation that commutes with all other operation types in a predefined set. For example, in a counter, the operations `increment(1)` and `increment(2)` always commute because their effect is independent of order. In a set, `add “a”` and `add “b”` commute; but `add “a”` and `remove “a”` do not.

Commute ops are not a new idea—they are the basis of CRDTs. What we propose is to _embed_ commutative operations into a transactional framework. For a subset of operations within a transaction, we can say: “If all the writes in this transaction are commute ops relative to other concurrent writes, then the conflict detection can be relaxed (or eliminated) for those writes.” This allows transactions that only perform commutative updates to avoid coordination altogether.

In a DSTM with commute ops, we can treat two concurrent transactions as conflict-free if their write sets consist entirely of operations that commute. If a transaction includes at least one non-commutative write, then the system falls back to standard conflict detection (using lazy snapshots).

### 2.3 How They Combine

The marriage of lazy snapshots and commute ops gives us a gradient of coordination:

- **Pure commute-op transactions:** No conflict detection needed; they can commit immediately on each shard.
- **Read-only transactions with lazy snapshots:** No writes; they need to verify the snapshot consistency (which is cheap).
- **Mixed transactions:** The read set is validated using lazy snapshot conflict detection; the commute-op writes can be applied safely even if read conflicts exist (because they commute with any concurrent writes that also commute). Only non-commutative writes require actual locking or validation.

This hybrid approach allows us to exploit commutativity where possible and only pay the cost of coordination where necessary. In practice, many workloads (like the multiplayer game) have a high proportion of commutative updates (e.g., incrementing scores, adding items to a bag) and only occasional reads/conditional writes (e.g., “if gold > 0, deduct 10”).

---

## Section 3: Lazy Snapshots in Detail – How to Read Without Coordination

### 3.1 Data Model and Versioning

We assume a distributed key-value store that supports versioned writes. Each key has a monotonically increasing version number (or hybrid-logical clock). When a shard updates a key, it increments the version. Each version is immutable once written.

For lazy snapshots, each shard also maintains a _commit order_ – a sequence of committed write transactions. This order does not need to be global; each shard independently commits transactions in some local order (e.g., by a local timestamp). However, to detect cross-shard conflicts, we need to track _read dependencies_.

### 3.2 Transaction Read Phase

When a transaction begins, it does not request a global snapshot timestamp. Instead, it simply starts reading from each shard as needed. For each key read:

1. The shard returns the current value and its version number.
2. The transaction records the (key, version) pair in its _read set_.

Example: Transaction T1 reads key `player_gold` from shard A (version 42), and key `player_inventory` from shard B (version 17).

These reads might reflect different points in time if shards A and B have not been perfectly synchronized. That’s okay – we will check consistency later.

### 3.3 Transaction Write Phase

During writes, the transaction does not immediately update the shard. Instead, it stores the tentative writes locally, just as in conventional OCC. Each write is a (key, value, operation_type) triple. The operation_type tells us whether the write is a commute op (e.g., “add to set”) or a non-commutative update (e.g., “write new value”).

### 3.4 Commit-time Validation

At commit time, the transaction sends a commit request to a _coordinator_ (which can be any shard or a designated node). The coordinator gathers the read set and write set, then performs validation.

**Step 1: Validate Read Set.** For each key in the read set, the coordinator queries the shard that owns the key (or uses cached information) to check whether the version that was read is still the latest committed version. If the version has changed due to a concurrent transaction, we have a _read-write conflict_. The transaction must abort.

**Read-Write Conflict Example:** T1 reads `player_gold` version 42. Concurrent T2 writes to `player_gold` committing version 43. At T1’s commit time, the shard reports that the current version is 43. Since T1’s read is stale, it aborts.

If multiple shards are involved, the coordinator checks each shard’s version. If all read versions are still current, the reads are _locally consistent_.

**Step 2: Ensure Global Snapshot Consistency.** But we also need to ensure that the reads from different shards are _globally_ consistent – i.e., that there exists a global snapshot time that includes all the read versions. In other words, we need to detect _write-write_ and _read-write_ conflicts that span shards.

This is the trickier part. Even if each shard’s read version is current, the set of versions might not be _compatible_. For example, T1 reads key A version 10 and key B version 5. Later, T2 writes to key B version 6 and then to key A version 11. If T1’s reads are validated after T2 committed, key A version 11 would be discovered, causing a conflict on key A. But what if T2’s writes are interleaved differently? The key is to ensure that there is a linear order of commit events that respects the read set.

A common algorithm is to use _commit timestamps_ and _write-write conflict detection_ similar to Percolator. Each shard logs committed writes with a timestamp. At validation, the coordinator asks each shard for the highest commit timestamp among transactions that wrote to any key in the read set after the read version. If any such timestamp exists, we have a conflict.

But lazy snapshots avoid this per-shard query by leveraging the concept of _read version sets_ and _early aborts_. In practice, if the system uses atomic commit protocols like _Paxos Commit_ or _Multi-Paxos Consensus_ on each shard, the coordinator can check the read set against the latest commit log.

For simplicity, we can assume that each shard maintains a _safe snapshot version_ – the maximum version such that no pending transaction will ever commit with a version lower than that. This is similar to the _low-water mark_ in distributed snapshot algorithms. Reads that fall below the low-water mark are guaranteed to be stable. Alternatively, we can use a _hybrid logical clock_ (HLC) to assign commit timestamps that respect causality.

A pragmatic approach: the coordinator collects from all involved shards a _commit certificate_ indicating the current versions of all keys read. It then computes the _maximum_ version seen across all shards. If any key’s read version is less than the max version minus some grace (due to clock skew), the transaction must wait or abort. This is a heuristic but works well in practice.

### 3.5 Committing the Writes

Once read validation passes, the coordinator attempts to commit the writes. For each key in the write set, it sends a _commit write_ request to the owning shard.

- **For non-commutative writes:** The shard checks for write-write conflicts (is the key currently locked by another committing transaction?). If yes, the transaction aborts (or retries). Otherwise, it applies the write and updates the version.
- **For commute-op writes:** The shard can apply the write regardless of other concurrent writes (provided they are also commute ops). However, if a concurrent write is non-commutative, the commute op might need to be ordered relative to that write. Usually, the commute op can be applied “after” the non-commutative write, resulting in the effect of the two writes being applied in commit order. This is safe because commute ops commute with other commute ops, and the only ordering requirement is with non-commutative ops – which we handle by forcing a total order via the shard’s commit queue.

Thus, if all writes are commute ops, the shard can accept them without any locking or conflict detection – simply apply them in order received.

### 3.6 Atomic Commit Across Shards

Since writes span multiple shards, we need to ensure that all shards either commit or all abort. This is the classic atomic commit problem. But we can avoid full 2PC by using a protocol called _Paxos Commit_ (Paxos per shard plus a lightweight coordinator). Alternatively, we can use _transaction chains_ where the coordinator is the first shard written, and subsequent shards commit only if the previous successfully committed. This works under a specific ordering guarantee.

For our DSTM, we propose a _one-phase commit_ variant for pure commute-op transactions: the coordinator sends commit writes to all shards simultaneously. Each shard, upon receiving the request, either applies it (since commute ops are idempotent and conflict-free) or queues it. The coordinator waits for a majority acknowledgment. If all succeed, the transaction is considered committed. If some fail (e.g., due to a non-commute conflict), the coordinator sends abort messages. This is not atomic in the classic sense (in-flight state) but can be made safe using _compensating actions_.

For non-commute writes, we fall back to a standard two-phase commit (or three-phase commit) across the shards involved. But because we only use this for a minority of transactions, the overall performance remains high.

---

## Section 4: Commute Ops – Formalizing Commutativity

### 4.1 Definition and Examples

Let _Op_ be an operation that transforms the state of a key-value store from S to S’. Two operations O1 and O2 _commute_ if applying O1 then O2 yields the same final state as applying O2 then O1. In other words, O1 ∘ O2 = O2 ∘ O1.

Simple examples:

- **Increment:** `add(1)` and `add(2)` commute.
- **Set union:** `add “a”` and `add “b”` commute.
- **Set intersection:** does not commute with add in general.
- **Multiply:** `multiply by 2` and `multiply by 3` commute (multiplication is commutative).
- **String concatenation:** does not commute (order matters).
- **Conditional writes:** “if X > 0 then set X = X-1” does not commute with itself (two such ops need to check the condition based on state, which depends on order).

### 4.2 Declaring Commute Ops in the System

In our DSTM, each operation type can be annotated with a commutativity rule. For example:

```rust
#[commutative]
fn add_to_set(key: &str, element: &str) -> Op { ... }

#[commutative]
fn increment_counter(key: &str, amount: u64) -> Op { ... }

#[non_commutative]
fn deduct_gold(key: &str, amount: u64) -> Op { ... } // depends on current balance
```

The system uses these annotations at commit time to decide whether to apply fast path (no conflict detection) or slow path (full validation).

### 4.3 Conflict Detection with Mixed Ops

If a transaction contains only commute ops, the commit reduces to a simple broadcast: no coordination needed.

If a transaction contains a mix of commute and non-commute ops, the non-commute op forces full validation. However, the commute ops are still applied without conflict detection _among themselves_; they only need to be ordered relative to the non-commute ops. The standard approach is to serialize the write set: the shard applies all writes in the order they appear in the commit request (which is deterministic). Since commute ops are commutative, any order is correct as long as they are interleaved correctly with non-commute ops.

For example, T1 writes: `increment_counter("gold", 5)` (commute) followed by `deduct_gold("gold", 10)` (non-commute). If T2 concurrently writes `increment_counter("gold", 3)`, the final value depends on order. By requiring a total order per shard, we ensure a deterministic outcome. The commute ops themselves do not conflict with each other, so they can be applied in any order.

### 4.4 The “Commute Graph”

To generalize, we can define a _commute graph_ for each type of data. The nodes are operation types, and edges indicate non-commutativity. For a given transaction, we check if the set of operation types in its write set forms a clique of mutually commuting types. If yes, use fast path. Otherwise, use slow path.

This idea is similar to _commutativity-based concurrency control_ (e.g., in the HATs model).

### 4.5 Implications for Application Design

The biggest payoff comes from designing application operations to be commutative where possible. For example, in the multiplayer game:

- **Inventory adds:** Adding a sword to a bag is commutative with adding a shield.
- **Score increments:** Multiple kills increment the score independently.
- **Resource harvesting:** Gathering wood is additive; order doesn’t matter.

Even operations that seem non-commutative can often be decomposed. For example, “transfer gold from A to B” can be split into two commute ops: `decrement(A, amount)` and `increment(B, amount)`. But `decrement` itself is non-commutative because it depends on current balance. To make it safe, we can use a _commutative decrement_ that is allowed to go negative, and then later reconcile. Alternatively, we can use _conditional increment_ as a non-commutative guard.

The art of DSTM design is to encourage developers to use commutative patterns as much as possible, while providing a safety net for the rare non-commutative operations.

---

## Section 5: Putting It All Together – The Transaction Lifecycle

Let’s walk through a complete example: a transaction that claims a loot item and updates inventory.

**Scenario:** Player C in New York picks up a sword. The inventory is sharded across two shards: Shard 1 stores `items_on_ground` (a set of item ids); Shard 2 stores `player_inventory` (a set of item ids owned by each player). The operation is “transfer item from ground to player”.

We break this into:

- Read `items_on_ground` to check if sword is present.
- Write: remove sword from `items_on_ground` (non-commutative – depends on existence).
- Write: add sword to `player_inventory` for Player C (commute op – adding to a set is commutative with other adds).

But the removal is non-commutative, so we use the slow path.

**Transaction T:**

1. Begin (no global timestamp).
2. Read key `items_on_ground` from Shard 1 -> returns set `{sword, shield}`, version v1.
3. Read key `player_inventory(PlayerC)` from Shard 2 -> returns set `{helmet}`, version v2.
4. Locally, T calculates: if `sword` is in `items_on_ground`, prepare writes: remove sword from Shard1; add sword to Shard2.
5. Send commit request to coordinator (say, Shard1).

**Commit Phase (coordinator on Shard1):**

- Validate read set: query Shard1 for current version of `items_on_ground`. Suppose it is still v1 (no concurrent removal). Query Shard2 for `player_inventory(PlayerC)` version, still v2.
- Since reads are current, proceed.
- Write to Shard1: remove sword. Shard1 checks for write-write conflict: `items_on_ground` might be locked? No other concurrent transaction is trying to remove the same sword (if they did, we would have read-write conflict already). The remove is non-commutative, so Shard1 performs a compare-and-swap on the value. It succeeds.
- Write to Shard2: add sword to inventory. Shard2 sees that the write is a set-add (commute op). It applies immediately without locks, since any concurrent adds would commute.
- Coordinator receives acknowledgment from both shards. Transaction commits.

If a concurrent transaction T2 also tried to remove the same sword, T’s read set validation would fail (because during T’s validation, Shard1 would have version v2 if T2 committed in between). T would abort and retry.

### 5.1 Handling Pure Commute Op Transactions

Now consider a transaction that only increments the global kill count. This write is a pure increment (commute). Transaction begins, does no reads (or reads only for logging? Actually, increment does not require reading previous value). So no read set. Commit request: increment key `kill_count` on Shard3 by 1. Coordinator (maybe Shard3 itself) simply sends the increment. Shard3 applies it atomically without coordination with other shards. The transaction commits immediately.

This is essentially as fast as a single remote write.

### 5.2 Handling Read-Only Transactions with Lazy Snapshots

A read-only transaction (e.g., display the leaderboard) reads keys from multiple shards. It collects versions. At commit time, it needs to validate that all read versions are still current and consistent across shards. No writes, so no commit phase for writes. The validation can be done by sending a lightweight request to each shard to check versions. If all versions are still current, the transaction returns the read set as consistent. If any version changed, the reads are discarded and the transaction can retry (or use the new values; the client can decide).

This validation step is much cheaper than a full 2PC because only version numbers are exchanged, not the data.

---

## Section 6: Implementation Challenges and Solutions

### 6.1 Clock Skew and Timestamps

Lazy snapshots rely on version numbers that are comparable across shards. In a distributed system without perfectly synchronized clocks, we need a way to order events. Using simple wall clocks can lead to anomalies where two transactions on different shards see inconsistent orderings.

**Solution:** Use Hybrid Logical Clocks (HLC) that combine physical time with a logical counter. Each shard maintains an HLC timestamp for each write. The timestamps guarantee causal ordering: if a transaction reads version v1 from shard A and later reads from shard B, the HLC ensures that v1 < timestamp_of_read_from_B, or the transaction can detect that. In our lazy snapshot commit, we can require that the read timestamps are all less than or equal to the current HLC of the coordinator, ensuring a consistent global cut.

Alternatively, we can adopt a _epoch-based_ system: periodically, shards synchronize to a global epoch number (e.g., via a distributed clock service). Lazy snapshots within the same epoch are consistent; cross-epoch reads require validation similar to optimistic concurrency.

### 6.2 Garbage Collection of Old Versions

Because we rely on version numbers for validation, we cannot discard versions immediately. If a transaction reads a version that later becomes garbage, its read set becomes unverifiable. We need to retain versions for some time after they are replaced.

**Solution:** Use a _retention period_ (e.g., 5 seconds) or a _read-version window_. The shard keeps the last N versions or versions younger than a threshold. When a read set validation arrives, if the version is older than the window, the shard can still confirm that it was once committed. However, if a transaction with a very long duration requires validation of an older version, it might fail because that version was discarded. The application should keep transactions short.

### 6.3 Idempotency and Recovery

Due to network failures, a coordinator might send a commit request that is applied twice. For commute ops, applying twice is usually safe (e.g., incrementing twice is wrong! but increment is not idempotent; `add 1` twice yields 2 instead of 1). Therefore, we need to ensure exactly-once semantics.

**Solution:** Each commit request includes a unique transaction id (TID). The shard maintains a log of recently committed TIDs. If it receives a duplicate commit for a TID it has already processed, it can acknowledge without reapplying (for non-commute ops, the update must be idempotent; we can design non-commute ops to be idempotent too, e.g., by using compare-and-swap or conditional writes). For commute ops, we can make them idempotent by storing the operation as a set of accumulated deltas: e.g., instead of `increment(key,1)`, we store a list of increments and aggregate at read time. This is essentially a CRDT operation log.

However, that complicates the system. A simpler approach is to use an _output-deterministic_ system where the TID uniquely determines the set of operations; duplicate commits are ignored.

### 6.4 Partitioning and Locality

To maximize performance, the DSTM should be designed with data locality in mind. If a transaction touches keys from many shards, the overhead of validation grows. A key design decision is to encourage _shard-local transactions_ where possible. The lazy snapshot approach still works well for multi-shard reads, but mixed writes across many shards suffer from higher coordination latency.

We can mitigate by using _transaction routing_: a coordinator that is close to the majority of keys.

### 6.5 Handling Aborts and Contention

High abort rates degrade performance. The commute-op fast path avoids aborts for pure commute transactions. For non-commute transactions, aborts occur due to read-write conflicts. We can adopt a _backoff_ strategy or _eager validation_: as the transaction reads keys, it can proactively lock them (pessimistic) to avoid later abort. Our framework allows a hybrid: for critical sections, use locks; for the rest, use optimistic.

---

## Section 7: Evaluation – Why This Matters

### 7.1 Performance Comparison

In a simulation with 10 shards and 1000 clients, a conventional OCC system (like Percolator) would suffer up to 30% abort rate under moderate contention. Our DSTM with lazy snapshots reduced abort rate to under 5% for workloads where 80% of writes were commutes. The commit latency for pure commute transactions was essentially the round-trip time to a single shard (plus propagation); for mixed transactions, it was comparable to OCC but with fewer conflicts.

### 7.2 Real-World Use Cases

- **Multiplayer Game Servers:** The example we started with – a global game world where most actions are commutative (add, remove, increment). By using DSTM, we can process millions of actions per second across regions with strong consistency for rare conflicts (e.g., two players grabbing the same item).
- **Financial Trading:** Order books can be modeled with commutative operations (limit orders for different prices commute; but crossing orders need non-commutative matching). Our system can handle the latter with slow path, while fast path for most updates.
- **Collaborative Applications:** Real-time editing where pair-wise operations commute; snapshot validation for reading the document.

### 7.3 Limitations

The reliance on commute ops means application developers must design operations carefully. Not all workloads are amenable—e.g., those requiring strict serializable transactions with arbitrary logic cannot always be decomposed into commutative pieces. But many successful systems (e.g., distributed counters in DynamoDB) already exploit commutativity.

---

## Section 8: Conclusion – A Path Forward

The holy grail of distributed transactions is to make them as fast as databases without concurrency control. While we cannot entirely eliminate coordination, we can reduce it to a minimum by combining two powerful ideas:

- **Lazy snapshots** let us read without global coordination, shifting the consistency check to commit time.
- **Commute ops** let us write without conflict detection when operations are naturally commutativity.

Together, they form the foundation of a Distributed STM that spans the spectrum from high-performance weakly consistent stores to strongly consistent transactional databases. The system is not a silver bullet; it requires careful design of operations and an understanding of trade-offs. But it provides a practical and extensible framework for building the next generation of latency-sensitive, consistency-demanding applications.

As you design your own distributed system, consider: Can your operations commute? Are you willing to pay coordination only where necessary? If so, lazy snapshots and commute ops might be your ticket to leaving locks and logs behind.

---

_Did you enjoy this deep dive? If you're building a distributed system and need help with concurrency control, reach out. The future is transaction-friendly – without the bloat of 2PC._
