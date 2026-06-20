---
title: "Building A Distributed Transaction Log With Multi Version Concurrency Control (mvcc)"
description: "A comprehensive technical exploration of building a distributed transaction log with multi version concurrency control (mvcc), covering key concepts, practical implementations, and real-world applications."
date: "2025-12-13"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Building-A-Distributed-Transaction-Log-With-Multi-Version-Concurrency-Control-(mvcc).png"
coverAlt: "Technical visualization representing building a distributed transaction log with multi version concurrency control (mvcc)"
---

## Introduction: Building a Distributed Transaction Log with Multi-Version Concurrency Control

Imagine you are running a global e-commerce platform. Every second, thousands of customers browse products, add items to their carts, place orders, and update inventory. Behind the scenes, your database must handle a constant stream of read and write requests that overlap in time and space. If you lock a row every time someone reads it, writes will stall. If you lock on every write, reads will block. And if you replicate this data across multiple data centers to survive a regional outage, you now face the challenge of ensuring that every replica sees the same order of operations, even when clocks are unsynchronized, nodes crash, and network partitions occur.

This is the reality of modern distributed systems. The demand for high throughput, low latency, and strong consistency has pushed database architects to combine two powerful ideas: the **transaction log** (the backbone of durability and replication) and **multi-version concurrency control (MVCC)** (the key to non-blocking reads and snapshot isolation). When you build a distributed transaction log that implements MVCC, you get a system that can process millions of transactions per second while providing serializable isolation, fault tolerance, and the ability to scale horizontally. This is the foundation of systems like Google Spanner, CockroachDB, and FoundationDB — and it is increasingly the architecture of choice for mission-critical applications.

But why is this combination so important? And what does it really mean to build a distributed transaction log _with_ MVCC? Let’s start by unpacking each concept separately.

### The Role of the Transaction Log

At its heart, a transaction log is an append-only record of every operation that changes the database state. In a traditional single-node database, the log (often called the write-ahead log, or WAL) is the first place data is written before modifying the actual data pages. The log serves two critical purposes:

1. **Durability** – If the server crashes before data pages are flushed to disk, the log can be replayed to recover the committed state.
2. **Ordering** – The log defines a total order of all changes. This order is essential for replication: if replicas apply the same log entries in the same order, they will reach identical states.

But in a distributed system, the log becomes even more important. It is the single source of truth that all replicas must agree on. Achieving agreement on the order of entries across many nodes is the classic problem of **consensus** – usually solved by protocols like Paxos or Raft. The log entry becomes a "command" that every node must apply deterministically. In systems that support multi-key transactions, the log may contain entire transaction commit records, including all read and write sets.

The log must also handle **failures** gracefully. If a node that is the leader (the one currently appending to the log) crashes, a new leader must be elected. The new leader must ensure that no log entries are lost and that any partially committed transactions are either completed or aborted. This is why distributed logs are often replicated: a majority of nodes must confirm that an entry is safely stored before it is considered committed.

Now, how does MVCC fit into this picture? In a traditional database, a transaction log records only the latest value for each key after each transaction commits. But MVCC requires that we keep multiple versions of each key, so that a transaction sees a consistent snapshot of the database at a particular point in time. To support MVCC over a distributed log, we need to assign a global timestamp (or monotonic counter) to each transaction, and the log must carry not just the new value, but also the timestamp at which that version becomes visible. This is where the two concepts start to merge.

### Deep Dive into Multi-Version Concurrency Control (MVCC)

MVCC is an isolation technique used by most modern databases (PostgreSQL, Oracle, InnoDB, etc.). Instead of locking rows for readers, MVCC keeps old versions of data around for ongoing read transactions. When a write transaction modifies a row, it creates a new version. Readers continue to see the version that existed at the moment their transaction began (or at a specific snapshot timestamp). This gives a natural “snapshot isolation” where reads never block writes and writes never block reads.

#### Snapshot Isolation – The Promise and the Pitfalls

Snapshot isolation (SI) guarantees that a transaction sees a consistent view of the database as of the start of the transaction. If two concurrent transactions write to the same row, only one will succeed; the other will be aborted (write–write conflict). This is a huge improvement over serializable isolation in terms of performance, but SI is not fully serializable. There are known anomalies, such as write skew, that can occur under SI. Consider a scheduling application: two doctors, each with an on-call shift. The constraint is that at least one doctor must be on call at all times. Under SI, transaction A reads that both doctors are on call, then removes Doctor A’s shift. Transaction B concurrently reads the same initial state and removes Doctor B’s shift. Both transactions see two doctors on call (the snapshot at their start), so neither sees the other’s removal. Both commit, leaving zero doctors on call. This is a serializability violation.

To prevent such anomalies, some databases (like PostgreSQL with `REPEATABLE READ`) implement “Serializable Snapshot Isolation” (SSI) which tracks read–write dependencies and can detect cycles. In a distributed system, the challenge becomes detecting these conflicts across nodes. That leads us back to the need for a global ordering mechanism.

#### Version Chains and Garbage Collection

Under MVCC, each row maintains a chain of versions. Each version is tagged with a timestamp (or transaction ID) that indicates when it was created and, optionally, when it was deleted (or made obsolete by a newer version). A read transaction looks at its own snapshot timestamp and walks the version chain backward until it finds a version that was committed before that timestamp and has not been deleted by a later version that is also visible to the snapshot. This lookup is O(number of versions) but is typically efficient because most rows have only a few active versions.

However, over time, old versions accumulate and must be cleaned up. This is the job of **vacuum** or **garbage collection**. In a distributed database, garbage collection is more complex because old versions may be needed by long-running read transactions that are executing on other nodes. The system must track the oldest active transaction across all nodes to determine which versions are safe to delete. This is often done by periodically computing a global “low watermark” – all versions with timestamps older than that watermark can be removed.

Now, let’s put these pieces together: we want a distributed transaction log that preserves multiple versions of each key, assigned with globally unique timestamps, and that supports efficient garbage collection across replicas.

### The Marriage: Distributed Transaction Log + MVCC

To build a distributed transaction log with MVCC, we need three fundamental components:

1. **Global timestamp assignment** – Every transaction must receive a timestamp that is unique and monotonic across all nodes. This could be a hybrid logical clock (HLC) that combines physical time with a logical counter to avoid drift, or it could be a centralized sequencer (as in Google Spanner, which uses TrueTime with bounded clock uncertainty). The timestamp defines the “version” of the database state that the transaction will read from and write to.
2. **Distributed consensus for log entries** – When a transaction commits, its changes (including the timestamp and the new values) must be appended to a replicated log. The consensus protocol ensures that all nodes agree on the order of commits. Raft and Paxos are standard choices. Some systems use a less strict ordering: for example, CockroachDB uses a two-phase commit protocol over a replicated write-ahead log as part of its “parallel commits” optimization.
3. **Version-aware storage engine** – Each node’s local store (typically an LSM-tree like in RocksDB or a B+ tree) must be able to store multiple versions per key, indexed by the global timestamp. Reads must efficiently locate the correct version without scanning all prior versions.

But there is a subtlety: in a distributed system, a transaction may span multiple partitions (shards). The commit process must ensure that all partitions atomically record the transaction’s effects, and that the global timestamp is consistent across partitions. This is the classic **atomic commit problem** over a distributed database. The standard solution is **Paxos commit** or **two-phase commit (2PC)** with a coordinator. However, 2PC is blocking and can lead to hangs if the coordinator fails. Modern distributed databases often combine 2PC with consensus: for example, each partition’s log is managed by a Raft group, and the transaction coordinator uses the logs to guarantee atomicity.

#### Example: A Simple Distributed Key-Value Store with MVCC Log

Let’s sketch a minimal design. Suppose we have a key-value store sharded across three nodes. Each node runs a Raft consensus group that replicates its shard’s log to two other nodes. We also have a global timestamp oracle (a single logical counter, but can be made fault-tolerant via Raft). When a transaction writes keys `a` and `b` (which live on shards 1 and 2), the following steps occur:

1. The client contacts a coordinator node (or the application library).
2. The coordinator obtains a global timestamp `T` from the timestamp oracle.
3. The coordinator sends a **prepare** request to each shard that contains a key in the write set. The prepare includes the key, the new value, and the timestamp `T`.
4. Each shard node appends a “prepare entry” to its local Raft log. The node responds to the coordinator only after the entry has been committed to its Raft group (i.e., a majority of replicas have stored it).
5. If all shards respond successfully, the coordinator sends a **commit** request to each shard. The shards then append a “commit entry” (or simply flag the prepare entry as committed) to their log.
6. After commit, the new version is visible. The shard updates its local storage: it writes the new version with timestamp `T` and marks the previous version as “obsolete” at timestamp `T` (unless that previous version is still needed by an ongoing read transaction with a snapshot timestamp older than `T`).

Now consider a read transaction. The read transaction obtains a snapshot timestamp `S` from the timestamp oracle. It then reads each key by locating the version with the largest timestamp ≤ `S` that is committed. If a read hits a key that has a prepare entry with timestamp > `S`, the read might need to wait or check whether that prepare has been committed. This is where **lock-free reads** become tricky: a read that arrives between prepare and commit could see an inconsistency if it sees some shards committed and others not. To prevent that, the system must enforce that the timestamp oracle guarantees monotonicity: after a read obtains snapshot `S`, any write that commits with timestamp > `S` will not be visible. But if a write with timestamp `T < S` is still pending (prepared but not committed), the read might or might not see it. The common solution is to **block reads** until the pending transaction’s fate is known, or to assign timestamps in such a way that pending writes always have timestamps larger than any ongoing snapshot (e.g., by ensuring that snapshot timestamps are always less than the smallest prepared timestamp). CockroachDB uses a technique called “read refreshing” to handle write intents (prepares) by checking if they are still pending.

#### Handling Clocks in Distributed Timestamping

One of the hardest problems in distributed MVCC is generating globally monotonic timestamps without a centralized bottleneck. Google Spanner uses **TrueTime**, which is a combination of GPS and atomic clocks that provides a bounded uncertainty bound: each timestamp is actually an interval `[earliest, latest]` such that the real time is guaranteed to be within that interval. Spanner then uses this uncertainty to guarantee linearizability: writes are assigned a timestamp that is guaranteed to be larger than any subsequent read’s timestamp, by waiting out the clock uncertainty.

CockroachDB, on the other hand, uses **Hybrid Logical Clocks (HLC)**. Each node maintains a clock that combines physical time (wall clock) with a logical counter. When a node receives a message, it updates its clock to be at least the maximum of its own clock and the sender’s clock. The result is a timestamp that is monotonic even if physical clocks drift. Because HLCs are not as precise as TrueTime, CockroachDB relies on a “commit wait” mechanism when transactions commit near the boundary of clock uncertainty. It also uses a transaction priority system to resolve conflicts.

### Real-World Systems: Case Studies

Let’s examine three prominent distributed databases that combine a transaction log with MVCC.

#### Google Spanner

Spanner is a globally distributed, strongly consistent database that uses TrueTime clocks. It stores data in a tree of tablets, each replicated via Paxos. The transaction log is the Paxos replication log. For reads, Spanner provides snapshot reads (with a timestamp) or reads that must see the latest data (by using a “safe time” that is the maximum timestamp at which all previous writes have been applied). MVCC is implemented by storing multiple versions per key, with timestamps derived from TrueTime. Garbage collection removes versions older than the oldest active transaction across the globe.

Spanner’s key innovation is that it can perform **geographically distributed commits** using a two-phase commit with a coordinator that leverages Paxos. The coordinator sends out prepare messages to participants, and each participant replicates its prepare decision via its local Paxos group. Because TrueTime ensures that timestamps are globally meaningful, Spanner can achieve external consistency: if transaction A commits before transaction B starts (in real time), then A’s timestamp is less than B’s timestamp. This is the gold standard for globally distributed databases.

#### CockroachDB

CockroachDB is an open-source distributed SQL database inspired by Spanner but without TrueTime. Instead, it uses HLCs. The transaction log is replicated using Raft per range (the shard unit). CockroachDB’s MVCC storage layer is built on top of RocksDB. Each key can have multiple versions, stored as separate key-value entries with timestamps appended to the key. As part of a transaction, writes are first written as **write intents** – these are provisional entries that include the timestamp and a pointer to the transaction record. The transaction record itself is a special key stored in the first range of the cluster that holds the transaction’s status (pending, committed, aborted). Read requests encountering a write intent must then check the transaction record: if the transaction is committed, the read can see the intent as the latest value; if pending, the read might wait or do a conflicting resolution.

CockroachDB uses a technique called **parallel commits** to reduce latency: the coordinator can finalize the transaction (making it committed) on the transaction record before all intents have been replicated locally. This reduces the window of vulnerability but requires careful handling during crashes.

#### FoundationDB

FoundationDB (FDB) takes a different approach: it provides a key-value store with a global transaction log that is completely independent of the storage layer. FDB uses a deterministic simulation engine to test correctness. The log is an ordered sequence of transaction commit records. Each record contains the read set (to check conflicts) and write set (key-value pairs). The storage servers (called “processes”) apply these records to their local B-tree. MVCC is implemented by storing a version for each key: the log includes the version number (a global monotonically increasing 64-bit integer). FDB does not actually keep multiple versions for reads; instead, it uses a “versioned read” that reads the entire database state as of a specific version. The storage layer can efficiently return a snapshot of a subset of keys at a given version by storing a copy-on-write B-tree (the FDB “Redwood” storage engine). This is a form of MVCC but with a different underlying implementation – the log is the primary ordering mechanism and each commit creates a new version of the entire database.

### Performance Considerations and Trade-offs

Combining a distributed log with MVCC brings both benefits and costs.

#### Write Amplification

Every write transaction must be appended to the log (multiple replicas) and also lead to a new version in the storage engine. That means each write generates at least two writes: the log entry and the new version. Additionally, garbage collection of old versions adds more write load. In systems like CockroachDB, the LSM-tree compaction (from RocksDB) can lead to high write amplification (up to 10x or more). Tuning the compression and version retention policy is crucial.

#### Read Amplification

Reads that need to find the correct version may need to traverse multiple versions. With an LSM-tree, the read may also need to merge data from multiple SSTables. To mitigate this, many systems keep a bloom filter per SSTable and also use a “read cache” that holds the latest version for hot keys. Some systems (like FDB) avoid read amplification for point lookups by using a B-tree with versioned nodes.

#### Conflict Detection Overhead

Distributed conflict detection requires communication. When a transaction reads a key, it needs to check if there is a pending write intent with a timestamp within its snapshot. That check may involve a network round trip to the shard’s leader. In high contention scenarios, the overhead can be significant. CockroachDB mitigates this by “store-level” conflict resolution and by pushing cached transaction records.

#### Garbage Collection Coordination

Coordinating garbage collection across nodes requires knowing the oldest transaction timestamp across the entire cluster. This is usually done via a periodic background process that queries all local transaction stores. In Spanner, the “safe time” is advanced using a distributed gossiping protocol. In CockroachDB, each node maintains a “low water mark” and these are exchanged periodically. The cost is that old versions cannot be cleaned up until all nodes have acknowledged a certain timestamp, which can increase storage usage.

#### Clock Precision and Safety

If clocks are not well synchronized, a transaction might be assigned a timestamp that is “in the future” relative to another node. This can lead to read anomalies – a read might fail to see a write that physically happened before it. To prevent this, systems either wait (as Spanner does with TrueTime) or use more complex commit protocols (as CockroachDB does with commit waits). Waiting increases latency, especially in geo-distributed setups where inter-datacenter round trips can be 100ms.

### Detailed Implementation Sketch: A Minimal Distributed MVCC Log

Let’s try to implement a toy version of such a system in pseudocode. We’ll assume a key-value store with a global timestamp oracle (a single incrementing counter, replicated for fault tolerance). Each shard has a Raft group.

**Data structures on each node:**

- A log: an append-only sequence of entries. Each entry has a type (PREPARE, COMMIT, ABORT), a transaction ID, a timestamp, and a list of key-value pairs.
- A version store: a map from key to a sorted list of version records. Each version record has a timestamp, a value, and a status (pending, committed, aborted). For simplicity, we store versions in a B-tree keyed by (key, timestamp).
- A transaction table: map from transaction ID to status (pending, committed, aborted) and timestamp.

**Read operation (Snapshot read at time S):**

```
def read(key, S):
    # Find the greatest committed version with timestamp <= S
    versions = store.get_versions(key)
    for v in versions in descending timestamp order:
        if v.timestamp <= S and v.status == COMMITTED:
            return v.value
    return None
```

But this naive approach does not handle uncommitted intents. In a real system, we must either wait or handle them. Let’s assume we use a write-intent approach: when a write occurs, we mark the version as pending. A read encountering a pending version with timestamp <= S must check the transaction table to see if the transaction has committed. If it has, we can treat it as committed. If it is still pending, the read must either block or abort the pending transaction (if the read has higher priority). For simplicity, we block.

**Write:**

```
def begin_transaction():
    ts = timestamp_oracle.allocate()  # global unique
    tx_id = generate_tx_id()
    return (tx_id, ts)

def write(tx, key, value):
    # Write locally (or buffer) – the actual write will be applied on commit
    tx.buffer[key] = value

def commit(tx):
    coordinator = select_coordinator(tx)
    # Phase 1: prepare
    for each shard that contains a key in tx.buffer:
        send_prepare(shard, tx.id, tx.timestamp, {key: value for key in that shard})
        shard receives:
            append PREPARE entry to its Raft log: (tx.id, timestamp, key-values)
            when committed in Raft, add version records to store with status PENDING
            respond OK to coordinator
    # If all OK:
    # Phase 2: commit
    for each shard:
        send_commit(shard, tx.id)
        shard receives:
            append COMMIT entry: (tx.id)
            when committed, change version records status to COMMITTED
            respond OK
    # Transaction committed
```

This is a classic two-phase commit over distributed logs. The bottleneck is the coordinator. To improve throughput, CockroachDB uses a non-blocking commit with a transaction record that can be updated while intents are being replicated.

**Garbage collection:**

A garbage collector periodically determines the oldest active snapshot timestamp across the cluster. Any version with timestamp older than that can be removed. In a distributed system, we need a global low-watermark. One approach: each node tracks the minimum timestamp among all currently running transactions that have started on that node (or that have read from that node). These minima are broadcast via gossip. The global low-watermark is the min over all nodes. Versions older than that can be deleted.

### Advanced Topics and Future Directions

#### Serializable Snapshot Isolation in Distributed Systems

To achieve full serializability under snapshot isolation, distributed databases must detect write skew and other anomalies. This requires tracking read–write conflicts across nodes. One technique is to have each transaction record not only its write set but also its read set. The commit coordinator then checks if any other concurrent transaction has written to a key that the current transaction read, and if the timestamps overlap in a way that could produce a cycle. This is the basis of the Serializable Snapshot Isolation (SSI) algorithm used by PostgreSQL. Implemented in a distributed system, it adds significant communication overhead.

#### Hybrid Approaches – Deterministic Databases

Some newer systems, like **Calvin** (from the H-Store project) and **FaunaDB**, use a deterministic transaction processing model. Instead of MVCC with conflict detection, they pre-order all transactions and execute them in a deterministic order on all replicas, usually by having a global sequencer that defines a total order. The storage can be a versioned key-value store (MVCC) but the isolation is serializable by construction. This eliminates the need for two-phase commit and locks, but it restricts transaction latency because all operations must wait for the sequencer.

#### Time-ordered Log and Eventual Consistency

Some systems sacrifice strong consistency for performance. For example, Amazon DynamoDB uses a distributed log with version vectors for conflict resolution (last-writer-wins). They do not implement MVCC in the full sense – they keep a single version per key plus a timestamp for conflict resolution. Reads see the latest version that has been propagated to the replica they contact. This is a form of eventual consistency. The trade-off is simplicity and lower write latency (no consensus needed for every write) at the cost of potential data loss or stale reads.

#### Cloud-Native and Serverless

Modern cloud databases like **Amazon Aurora** separate the log from storage: the database engine writes only a redo log to a distributed storage service, which then materializes pages. This allows for fast writes (log is small) and reads from cached pages. Aurora uses MVCC to support multiple versions for concurrent transactions. The distributed storage layer ensures durability and consistency across availability zones. This architecture is becoming the standard for cloud RDS.

### Conclusion

Building a distributed transaction log with multi-version concurrency control is a compelling but challenging design. It provides the best of both worlds: the durability, ordering, and replication guarantees of a write-ahead log, combined with the non-blocking reads and snapshot isolation of MVCC. However, the complexity of global timestamp assignment, distributed conflict detection, and coordinated garbage collection is non-trivial. Each system – Spanner, CockroachDB, FoundationDB – makes different trade-offs along the axes of clock precision, consistency level, write latency, and throughput.

As applications demand ever-higher scalability and geo-distribution, the importance of this foundation only grows. Newer research on deterministic databases, hybrid clock protocols, and scalable consensus (like EPaxos) promises to push the envelope further. For engineers building the next generation of distributed databases, understanding how to marry the transaction log with MVCC is an essential skill.

The journey from a simple single-node WAL to a globally distributed MVCC log is a story of clever compromises and deep theoretical insights. And the story is far from over.
