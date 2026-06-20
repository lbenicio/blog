---
title: "Implementing A Distributed Transactional Key Value Store With Optimistic Concurrency Control"
description: "A comprehensive technical exploration of implementing a distributed transactional key value store with optimistic concurrency control, covering key concepts, practical implementations, and real-world applications."
date: "2019-04-10"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/implementing-a-distributed-transactional-key-value-store-with-optimistic-concurrency-control.png"
coverAlt: "Technical visualization representing implementing a distributed transactional key value store with optimistic concurrency control"
---

## The Coordination Paradox: Why Your Next Database Needs to Fail Faster

**_(Expanded Full Blog Post – Target ≈10,000 words)_**

Imagine you’re building the control plane for a fleet of autonomous delivery drones. A single order—say, a coffee delivery—triggers a cascade of events: deducting the customer’s balance, reserving the drone, updating the inventory at the cafe, and calculating the optimal route. Now, imagine that this process is served not by one monolithic database, but by a cluster of machines spread across three data centers, each holding a fragment of that data. The coffee balance is in `us-east-1`, the drone status is in `eu-west-2`, and the cafe’s inventory is in `ap-southeast-1`.

The drone needs an atomic snapshot of the world. It cannot take off if the coffee is paid for but the drone is already dispatched to another user. It cannot deliver if the cafe inventory decrements but the payment fails. This is the fundamental paradox of distributed systems: we want the illusion of a single, consistent machine, but we are building on a substrate of independent, fallible, and asynchronous computers.

We usually solve this with transactions. But in a distributed key-value store, the traditional solution—pessimistic locking—is a slow, brittle nightmare. If one node goes down holding a lock, the entire system stalls. Network latency balloons, and the cost of coordination explodes.

This is where **Optimistic Concurrency Control (OCC)** enters the stage—not as a silver bullet, but as a paradigm shift. This post is not a theoretical survey. It is a deep dive into the architecture, algorithms, and gritty implementation details of building a distributed, transactional key-value store using OCC. We will walk through why OCC is increasingly the weapon of choice for modern, high-throughput systems, how to handle the sticky problem of conflict resolution across shards, and exactly what happens when two transactions collide on the same key.

---

### The High Cost of Pessimism

Before we praise optimism, let’s understand the price of being pessimistic. Pessimistic concurrency control assumes the worst: that every transaction will conflict with every other transaction. Therefore, it locks resources before they are used and holds those locks until the transaction commits or aborts. This ensures serializability but at a steep cost.

**Lock Contention and Deadlocks**  
Consider a simple bank transfer: `Debit account A`, `Credit account B`. Under pessimistic locking, the transaction must acquire a write lock on A, then on B. If two concurrent transactions try to transfer between the same two accounts in opposite directions, a deadlock occurs. The system must detect and break the deadlock by aborting one transaction, wasting all the work done so far.

**Distributed Locking Overhead**  
In a distributed setting, lock managers become a bottleneck. Two-phase locking (2PL) requires that locks be obtained from a coordinator or a distributed lock service. Every lock acquisition adds a network round-trip. If the transaction touches five keys spread across three nodes, the latency multiplies. Worse, if a node holding a lock crashes, recovery protocols like timeout-based lock release are slow and uncertain.

**The “Coffin” Problem**  
Pessimistic locking also suffers from the “coffin” effect: a transaction that holds a lock while waiting for user input, a disk I/O, or a network response blocks all other transactions that need that resource. In high-contention workloads, throughput collapses.

These problems have driven the database community toward optimistic alternatives. But OCC is not without its own challenges, especially in a distributed environment where the “check” phase (validation) must itself be atomic and consistent across shards.

---

### Optimistic Concurrency Control Fundamentals

Optimistic Concurrency Control flips the script: instead of locking first, you execute the transaction assuming no conflicts will occur. Only at commit time do you check whether the assumptions were valid. The classic OCC protocol, proposed by Kung and Robinson in 1981, has three phases:

1. **Read Phase** – Execute reads and writes locally (in a private workspace).
2. **Validation Phase** – Check for conflicts against other concurrent transactions.
3. **Write Phase** – If validation passes, make writes visible globally.

In a single-node database, the validation can be done efficiently using timestamps or version numbers. In a distributed key-value store, validation becomes a distributed agreement problem. But before we jump to that, let’s anchor the concept with a concrete example.

#### Example: Drone Reservation

Suppose we have two concurrent transactions:

- **T1**: Reserve drone D1 for user U1 (update drone status to “reserved”), debit U1’s balance by $10.
- **T2**: Reserve drone D1 for user U2 (update drone status to “reserved”), debit U2’s balance by $10.

Both transactions start with the same initial state: drone D1 is available (`status=available`). Under OCC, both will read the current status, compute their private writes, and then attempt to commit. During validation, the system must detect that T1 and T2 conflict on key `drone:D1`. One will be allowed to commit, the other must abort and retry.

The key insight: OCC trades lock overhead for the cost of aborting and retrying. If conflicts are rare, OCC outperforms pessimistic locking dramatically. If conflicts are frequent, OCC can lead to thrashing (lots of aborts and retries). The art is in designing the validation mechanism to be fast and the conflict detection to be accurate.

---

### The Anatomy of an OCC Transaction in a Distributed KV Store

Let’s design a simplified distributed key-value store that supports OCC. We’ll call it **DroneKV**. The system consists of:

- **Shards**: Each shard holds a subset of key-value pairs, replicated for fault tolerance (e.g., using Raft).
- **Coordinator**: A stateless server that receives client transactions, orchestrates the read/validation/write phases, and returns results.
- **Clock**: A monotonically increasing timestamp service (e.g., a hybrid logical clock) to order transactions.

A transaction is a batch of read and write operations on a set of keys. The coordinator executes it as follows:

#### Read Phase

1. The client sends the transaction to the coordinator.
2. The coordinator sends read requests to the shards that own the keys.
3. Each shard returns the current value and a version number (e.g., a logical timestamp or a sequence number).
4. The coordinator stores the values in a private transaction context (not yet visible to others).

#### Validation Phase

This is the crux of OCC. The coordinator must check that all read values are still current and that no other transaction has concurrently committed writes to the same keys. Because writes are not yet applied, validation must check that the transaction’s read set is still valid. The standard approach is **timestamp-based validation**:

- The coordinator assigns a commit timestamp `T_commit` to the transaction (e.g., the current time from the clock service).
- It sends a validation request to each shard that holds a key in the transaction’s read or write set.
- Each shard checks whether any update to those keys has occurred with a timestamp greater than the transaction’s read timestamp (the time when it read the values). If yes, the transaction conflicts and must abort.

But a naïve per-shard check is insufficient because the validation itself can race with other commits. We need a two-phase commit (2PC) wrapper around validation and write phases to ensure atomicity.

#### Write Phase

If all shards confirm no conflict, the coordinator sends a commit message to each shard containing the writes and the commit timestamp. Each shard applies the writes, updates its version counter, and sends an acknowledgment. If any shard fails or aborts (e.g., due to a concurrent conflicting commit that arrived just before its own), the coordinator must abort the entire transaction.

This sounds like a simple extension of 2PC, but the devil is in the details of conflict detection across shards.

---

### Conflict Detection and Resolution in a Sharded Store

The critical challenge is that validation is a distributed operation. The transaction’s read set might span multiple shards. How do we ensure that no two transactions commit with overlapping write sets concurrently, and that read sets remain consistent?

One elegant solution is **OCC with commit-time conflict detection using a global commit timestamp order**, similar to the protocol used by Google’s Spanner (though Spanner uses pessimistic locking for writes and OCC-like read-only transactions). Another approach is **Calvin**, which uses deterministic ordering of transactions.

Let’s dissect a protocol that works for a sharded key-value store without a global lock manager. We’ll call it **OCC-2PC** for clarity.

#### Protocol Details

**Assumptions**:

- Each shard maintains a local version number (or timestamp) for each key.
- There is a central timestamp oracle (e.g., a fast logical clock) that hands out strictly increasing timestamps.
- The coordinator is reliable but can fail; the system uses classic 2PC recovery.

**Transaction Steps**:

1. **Read Phase**: Coordinator reads values from shards. It records the read timestamp `T_read` (the timestamp returned by the shard for each key; could be the shard’s local clock at the time of read).
2. **Validation**: Coordinator requests a commit timestamp `T_commit` from the oracle. It then sends a **prepare** message to **all** shards that are in the read set **or** write set. The prepare message includes:
   - `T_commit`
   - The transaction’s read set (keys and their read timestamps)
   - The write set (keys and new values)
   - A unique transaction ID

   **Each shard, upon receiving prepare, does**:
   - For each read-key: check if any committed write to that key has a timestamp > the read timestamp for that key. If yes, conflict → vote “abort”.
   - For each write-key: check if any _other_ prepared (but not yet committed) transaction has a conflicting write with a lower commit timestamp. This is tricky—you need to lock the key during prepare to prevent races (yes, we introduce a short-lived lock). Typically, the shard acquires a soft lock on the key for the duration of the prepare phase. If another transaction’s prepare holds the lock, the current transaction must wait or abort.
   - If both checks pass, the shard records the transaction’s write set as “prepared” (but not yet visible), and votes “commit”.

3. **Decision**: If all shards vote commit, the coordinator sends a **commit** message to all shards. Each shard then makes the writes visible (e.g., atomically bumps the version and updates the value) and releases the soft lock. If any shard votes abort, coordinator sends **abort** to all.

#### Conflict Example

Consider the drone scenario again. Coordinator for T1 gets `T_commit=100`. It sends prepare to shard containing drone D1 (shard A) and user balance shards. Shard A sees that drone D1 has current version `v=50` from T1’s read. No other transaction has prepared a write to D1 yet, so shard A locks D1, records T1’s write as prepared, and votes commit. T2 comes in later with `T_commit=101`. When T2’s prepare reaches shard A, shard A sees that D1 is locked by T1 (which has a lower timestamp). T2 must either wait for T1 to commit or abort. If T1 commits quickly, T2 can proceed with its own prepare and then commit. But if T1’s commit takes long, T2 may time out and abort. This is still a form of locking, but only during the brief prepare window, not for the entire transaction.

#### Handling Read-Only Transactions

Read-only transactions can skip the write phase entirely. OCC is particularly efficient for read-only transactions because they can be validated quickly: they just need to confirm that the version numbers of all read keys are still current up to a snapshot timestamp. In many systems, read-only transactions can be served from a consistent snapshot without any locking.

---

### Handling Distributed Transactions Across Shards: The Two-Phase Commit Problem

OCC-2PC described above is essentially a variant of the classic two-phase commit wrapped with optimistic validation. But 2PC itself is famous for its blocking problems: if the coordinator crashes after sending commit, participants must wait indefinitely unless they have a timeout and abort logic (which can cause inconsistency). In practice, distributed OCC systems often rely on a **replicated log** (via Paxos or Raft) to make the coordinator’s decision durable.

Another approach is **Calvin’s deterministic OCC** where transactions are totally ordered before execution. In that scheme, there is no validation phase: each shard executes transactions in the predetermined order, eliminating conflicts by design. This works well for workloads where the read/write sets are known ahead of time (which is true for many business logic transactions). However, Calvin requires that all shards agree on the order, imposing its own coordination cost.

For a more traditional KV store, OCC with 2PC remains a popular choice. Let’s explore how to make it robust.

#### Making 2PC Non-Blocking

To avoid blocking, each shard should **replicate** its prepared state using a consensus protocol. If the coordinator fails, a new coordinator can read the prepared state from a majority of participants and decide accordingly. This is the idea behind **Paxos Commit** or **Percolator’s** use of Bigtable rows as locks.

In the **Percolator** system (used for Google’s web indexing), each key has a primary lock. When a transaction commits, it first writes its commit timestamp to the primary lock (which acts as the coordinator decision). If the coordinator crashes, other transactions can check the primary lock’s state to determine whether to commit or abort. This avoids a separate coordinator failure scenario.

#### Code Sketch: Percolator-Inspired OCC

Let’s write a simplified Python-like pseudocode for a sharded key-value store using Percolator-style OCC.

```python
class Transaction:
    def __init__(self, start_ts):
        self.start_ts = start_ts  # read timestamp
        self.buffer = {}  # private writes
        self.primary_key = None

    def read(self, key):
        if key in self.buffer:
            return self.buffer[key]
        else:
            # Read from the latest committed version <= start_ts
            value, version = kv_store.get(key, max_version=self.start_ts)
            self.buffer[key] = value
            return value

    def write(self, key, value):
        self.buffer[key] = value

    def commit(self):
        # Choose a primary key to break ties
        self.primary_key = next(iter(self.buffer.keys()))
        commit_ts = timestamp_oracle.next()

        # Phase 1: Prewrite (lock) all keys
        for key, value in self.buffer.items():
            is_primary = (key == self.primary_key)
            success = kv_store.prewrite(key, value, commit_ts, self.start_ts, is_primary)
            if not success:
                self._rollback_prewrites()
                return False

        # Phase 2: Commit primary (makes transaction visible)
        kv_store.commit(self.primary_key, commit_ts)

        # Phase 3: (async) Commit secondary keys
        for key in self.buffer:
            if key != self.primary_key:
                kv_store.commit(key, commit_ts)

        return True

    def _rollback_prewrites(self):
        for key in self.buffer:
            kv_store.prewrite_rollback(key, self.start_ts)
```

Each `prewrite` operation checks for conflicts: if the key has a newer lock (another transaction’s prewrite with a later start timestamp) or a committed write with a timestamp greater than the transaction’s start timestamp, the prewrite fails. This is a distributed OCC protocol that avoids 2PC and is non-blocking as long as the primary key’s location is stable.

---

### Implementation Details and Code Examples (Expanded)

Now let’s dive deeper into the actual implementation of the shard-side logic. We’ll assume each shard stores data in a local sorted map (like LevelDB) and maintains two special columns per key: **lock** and **write**.

#### Data Model per Key

Each key has:

- `write:timestamp -> value` (multiple versions, but only the latest committed is visible)
- `lock:timestamp -> (transaction_id, value)` (one lock per key, for the prepare phase)

A read operation returns the latest committed write with timestamp ≤ `start_ts`.

A prewrite operation:

1. Check if key is locked by a transaction with a lock timestamp ≥ `start_ts`. If yes, conflict (abort).
2. Check if there is a committed write with timestamp in range (`start_ts`, commit_ts]. If yes, conflict (another transaction already wrote after our read).
3. If no conflict, write the lock entry with timestamp = `commit_ts` and store the value.

A commit operation for the primary: delete the lock entry, write a `write:commit_ts` entry with the value, and make it visible.

#### Handling Failures: Recovery

If a transaction fails after prewriting some keys (e.g., coordinator crashes), we need a way to clean up. In Percolator, if a lock is encountered by another transaction, the transaction can check the primary lock. If the primary lock exists and its commit timestamp is set, then the transaction is committed; otherwise, it is aborted. The secondary transaction can then roll back the locks.

This avoids a centralized coordinator failure. However, it adds latency for the lock cleanup.

#### Performance Optimizations

- **Batching**: Group multiple transactions’ prewrites into a single RPC to each shard.
- **Two-phase commit with a single shard**: If all keys reside in the same shard, skip the 2PC and use a local transaction.
- **Async commit of secondaries**: After committing the primary, secondary commits can be done asynchronously. The transaction is considered committed immediately after primary commit, so clients can see the result quickly.

---

### Performance Considerations and Trade-offs

OCC is not a free lunch. Its performance depends heavily on the workload.

**Low Contention**: OCC shines. No lock overhead, high concurrency. Throughput can exceed pessimistic locking by an order of magnitude.

**High Contention**: OCC suffers. Transactions abort frequently, wasting work. The wasted work grows quadratically as contention increases. At some point, throughput collapses (thrashing). Pessimistic locking may perform better under high contention because it serializes access, avoiding aborts.

**Hybrid Approaches**: Some systems (e.g., Hekaton, HyPer) use OCC for read-heavy transactions and locking for write-heavy ones. Or they use OCC with an adaptive lock escalation.

**Distributed Overhead**: Every transaction requires at least two rounds of communication per shard (read + prewrite). For a transaction touching many shards, the cost can be high. But the same is true for distributed locking. The difference is that OCC’s read phase can be done in parallel, while locking typically requires sequential lock acquisition.

**Conflict Detection Granularity**: Fine-grained (per-key) vs. coarse-grained (per-shard). Per-key reduces false conflicts but increases metadata overhead. Per-shard is simpler but can cause unnecessary aborts if two transactions touch different keys on the same shard.

**Commit Latency**: OCC adds an extra round trip for prewrite and commit compared to a single-phase commit. However, the prewrite round trip can often be piggybacked with the read phase (if we read and prewrite in the same RPC). In many implementations, the read phase and prewrite are combined: you read and immediately lock the key. This reduces the number of phases from three to two.

---

### Real-World Systems: How the Giants Do It

- **Google Spanner**: Spanner uses pessimistic locking (2PL) for writes, but it also relies on a global clock (TrueTime) to support snapshot reads (OCC-like for read-only). Writes go through a deterministic commit protocol that ensures external consistency.

- **Percolator (Google)**: As described, Percolator uses OCC with a primary key and per-key locks. It is designed for incremental processing of large web crawls, where conflicts are rare.

- **FaRM (Microsoft)**: FaRM is a distributed in-memory key-value store that uses OCC with a two-phase commit over RDMA. It achieves extremely low latency by using one-sided RDMA writes for prewrite and commit.

- **Calvin (Yale)**: Calvin uses deterministic transaction ordering to avoid OCC entirely. It requires that all inputs be known before execution, making it suitable for some OLTP workloads but not for interactive clients.

- **CockroachDB**: CockroachDB uses a hybrid: it employs OCC for concurrent transactions but falls back to lock-free reads via multiversion concurrency control (MVCC). It uses a distributed timestamp order to detect conflicts, similar to Spanner’s TrueTime but with a HLC.

Each of these systems has made different trade-offs between consistency, latency, and throughput. The common thread is that OCC, when combined with careful protocol design, enables phenomenal performance in distributed environments—provided you accept the possibility of aborts.

---

### Conclusion: Embracing Failure

The paradox of distributed coordination is that to achieve the illusion of a single, consistent system, you must embrace the possibility of failure—not just of nodes, but of transactions. Optimistic Concurrency Control forces you to design your system to handle aborts gracefully. This is not a weakness; it is a strength.

By failing fast and retrying, your system can avoid the heavy cost of pessimistic locking and achieve higher throughput under normal operation. The key is to understand your workload’s contention profile, choose the right validation mechanism, and build robust recovery procedures.

The drone delivery example we started with is a perfect case for OCC: conflicts are rare (drones are usually idle, and customer balances don’t collide often). The overhead of locking every key for the duration of a transaction would kill performance. With OCC, the drone can start its journey after a fast commit, and if an abort occurs (e.g., the drone is already reserved), the system retries with a fresh snapshot. The drone never sees a stale world.

So, should your next database “fail faster”? Yes, if by “fail” you mean “abort transactions quickly under contention and retry”. OCC is not the answer for every problem, but for modern, high-throughput distributed systems, it is often the right answer. And now you have the tools to implement it.

---

_This post is part of a series on distributed transaction protocols. Next: “The Entropy of Consistency: How to Implement Serializable Snapshot Isolation in a Distributed Key-Value Store.”_
