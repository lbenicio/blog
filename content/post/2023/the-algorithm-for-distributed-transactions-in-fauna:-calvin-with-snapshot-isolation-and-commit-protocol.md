---
title: "The Algorithm For Distributed Transactions In Fauna: Calvin With Snapshot Isolation And Commit Protocol"
description: "A comprehensive technical exploration of the algorithm for distributed transactions in fauna: calvin with snapshot isolation and commit protocol, covering key concepts, practical implementations, and real-world applications."
date: "2023-04-29"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-algorithm-for-distributed-transactions-in-fauna-calvin-with-snapshot-isolation-and-commit-protocol.png"
coverAlt: "Technical visualization representing the algorithm for distributed transactions in fauna: calvin with snapshot isolation and commit protocol"
---

# The Algorithm For Distributed Transactions In Fauna: Calvin With Snapshot Isolation And Commit Protocol

## Introduction

Imagine you are building the next great global application. A social platform, a financial trading system, or a real-time multiplayer game. Your users are everywhere—New York, Tokyo, London, São Paulo. They expect the data to be consistent. If Alice sends Bob $100, the balance should not appear as $100 in one data center and $0 in another ten seconds later. The data should be correct, always, everywhere. This is the promise of a distributed database.

But the path to this promise is fraught with peril. For decades, the conventional wisdom was that you had to choose. You could have a database that was perfectly consistent (ACID transactions) but only ran on a single machine, limiting your scale. Or, you could have a database that scaled globally (NoSQL) but forced you to sacrifice strong consistency, leaving you to deal with the terrifying complexity of “eventual consistency”—a world where data is wrong for an indefinite period, and you, the developer, are responsible for fixing it.

Distributed transactions, the ability to run atomic, isolated operations across multiple machines and data centers, are the holy grail. They offer the mental model of a single, reliable machine while giving you the power of a global cluster. But achieving this is a breathtakingly difficult computer science problem. The core tension is between the _coordination_ needed for correctness and the _latency_ induced by that coordination across a network.

This is where the story of Fauna becomes fascinating. Fauna is a distributed database that claims to offer full ACID transactions globally, with no performance cliffs, and without the dreaded “leader bottleneck” that plagues traditional systems. How is this possible? The secret lies not in a single algorithm, but in a carefully orchestrated combination of two fundamental ideas: a **deterministic transaction scheduling algorithm** known as Calvin, and a **commit protocol** that ensures snapshot isolation across a global cluster.

In this deep dive, we will peel back the layers of Fauna’s internals. We’ll start by understanding why traditional distributed transaction models struggle with latency. Then we’ll explore the Calvin algorithm—how it turns the conventional wisdom of “optimistic concurrency” on its head by pre-declaring reads and writes, thereby allowing the system to _reorder_ transactions deterministically. Next, we’ll see how Fauna adapts Calvin to provide snapshot isolation (SI), a consistency level that avoids read-write conflicts while still offering a serializable snapshot view. Finally, we’ll examine the commit protocol—a two-phase commit variant that leverages deterministic ordering to avoid unnecessary pauses and achieve high throughput even under heavy contention.

By the end, you will understand why Fauna can claim to deliver “ACID transactions with NoSQL performance” and how its architecture is fundamentally different from both traditional SQL databases and eventual consistency NoSQL stores.

## The Core Problem: Distributed Transactions and the Latency Wall

Let’s ground ourselves with a concrete scenario. Suppose you have a global application with replicas in three data centers: US East, Europe West, and Asia Southeast. A user in Tokyo (connected to Asia Southeast) wants to transfer credits to a user in London (connected to Europe West). The transfer involves two operations: debit the sender’s account and credit the receiver’s account. These two keys may be stored on different partitions, possibly in different data centers.

In a traditional single-node database, you could simply execute a BEGIN TRANSACTION, update both rows, and COMMIT. The database ensures atomicity and isolation using locks. In a distributed system, the database must coordinate across partitions and across replicas. The simplest approach is to use a distributed consensus protocol like Paxos or Raft to agree on the order of operations, then execute a two-phase commit to ensure all replicas apply the transaction atomically.

But here’s the catch: two-phase commit (2PC) requires a coordinator to ask each participant “Can you prepare?” and then wait for all responses before telling them to commit. If any participant is slow or unavailable, the coordinator blocks. Worse, in a geo-distributed setting, the round-trip time between data centers can be 100-300 milliseconds. For a single transaction, this latency is already high. Multiply that by the number of transactions competing for resources, and you get a system that either stalls under load or compromises on isolation.

Most real-world distributed databases that support ACID transactions (like Google Spanner, CockroachDB, or YugabyteDB) use some form of **two-phase locking** or **optimistic concurrency control** with a global clock (TrueTime in Spanner, hybrid logical clocks in CockroachDB). These approaches introduce overhead: Spanner uses TrueTime with a bounded uncertainty window (typically 7 ms) and requires waiting for that window to elapse before committing a read-write transaction. CockroachDB uses a serializable snapshot isolation protocol that may retry transactions on conflicts.

The common thread: these systems treat the distributed transaction problem as a **coordination problem**—they must ensure that every transaction sees a consistent global order, and that order must be the same across all replicas. The cost of coordination is latency proportional to the geographic distance.

## Calvin: A Different Paradigm – Determinism to the Rescue

Calvin, introduced by a team at Yahoo! Research in 2012 (Hellerstein et al., “Calvin: Fast Distributed Transactions for Partitioned Database Systems”), takes a radically different approach. Instead of trying to order transactions _after_ they arrive, Calvin forces transactions to declare all their read and write sets _before_ execution. This is called **deterministic transaction scheduling**.

The key insight is simple: if you know in advance all the keys a transaction will touch, you can assign a global total order to transactions before they execute. Once ordered, transactions can be executed in that order across all replicas without needing expensive coordination (like 2PC) _during_ execution. Each replica independently executes the same deterministic schedule, and because the input is known, they all produce the same output.

In Calvin, a transaction is divided into two phases:

1. **Sequencing Phase**: Transactions are collected by a sequencing layer (typically a replicated state machine using Paxos/Raft). The sequencer assigns each transaction a deterministic order (a sequence number). The sequencer also extracts the read set and write set from the transaction’s declaration.

2. **Execution Phase**: Each partition (or replica) receives the ordered stream of transactions and processes them locally. Because the order is deterministic, and the read/write sets are known, a partition can use a simple lock-based scheduler: it acquires locks on the needed keys in a deterministic order (e.g., sorted by key), executes the transaction, and releases locks. No cross-partition coordination is needed during execution—except for transactions that touch multiple partitions. For multi-partition transactions, Calvin uses a **deterministic locking** approach: the sequencer ensures that the order of conflicting transactions across partitions is consistent.

The beauty of Calvin is that the execution phase **does not require consensus**. All replicas already agree on the order from the sequencer. So the execution can proceed at local memory speed, without waiting for network round trips between partitions.

But Calvin has a constraint: it requires the application to declare the read/write sets upfront. This is feasible for many workloads (e.g., financial transfers know the two account IDs) but impossible for dynamic queries or read-only transactions that need to scan an unknown number of keys.

## Fauna’s Adaptation: Calvin with Snapshot Isolation

Fauna, originally named FaunaDB, took the Calvin algorithm and extended it to provide **snapshot isolation** (SI) for read-only transactions and a modified commit protocol for read-write transactions. Snapshot isolation is a weaker consistency level than serializability but is still strong: a transaction sees a snapshot of the database as of the time it started, and write conflicts between concurrent transactions are detected (first-committer-wins rule). Snapshot isolation avoids many of the performance penalties of serializable isolation (e.g., phantom reads are prevented, but not write-skew anomalies).

How does Fauna merge Calvin with SI? In Calvin, every transaction (including reads) must be sequenced and go through the deterministic lock scheduler. That adds latency even for simple point reads. Fauna instead separates transactions into two categories:

- **Read-only transactions**: These can be served from any replica without going through the sequencer, provided that replica has a snapshot of the database that is consistent with the global order. Fauna uses a **timestamp-based snapshot isolation** scheme: each transaction is assigned a timestamp from a global clock (or a logical timestamp from the sequencer). Read-only transactions can be executed against a local replica’s snapshot as long as that snapshot is >= the transaction’s timestamp. This avoids any network coordination for reads.

- **Read-write transactions**: These follow the Calvin model: the client must declare the read and write sets (the keys it will access) before execution. The transaction is sent to a sequencer (part of a Raft group) that assigns a deterministic order and a commit timestamp. Then the transaction is executed deterministically across all partitions, using a locking protocol that respects the predetermined order.

The key innovation in Fauna is the **commit protocol** that integrates the Calvin sequencer with a two-phase commit variant optimized for deterministic ordering.

## The Commit Protocol: Two-Phase Commit with Deterministic Ordering

Let’s dive into the details of Fauna’s commit protocol for a read-write transaction. Consider a transaction that updates two keys: k1 (in partition P1) and k2 (in partition P2). The steps are:

1. **Declaration and Sequencing**: The client sends the transaction with declared read/write sets to the nearest sequencer replica. The sequencer uses Raft to replicate the transaction to a log. Once the log entry is committed (i.e., a majority of sequencer replicas acknowledge), the sequencer assigns a global sequence number (which also serves as the commit timestamp). The transaction is now _ordered_ among all other transactions.

2. **Preparation Phase**: The sequencer sends a “prepare” message to each partition that owns one or more keys in the write set (or read set, if the transaction reads from those partitions). The prepare message includes the sequence number and the transaction details. Because the order is deterministic, each partition knows the exact order of all transactions that touch its keys. The partition can then attempt to lock the required keys in that deterministic order. If a key is already locked by an earlier transaction (with a lower sequence number), the partition waits for that earlier transaction to complete. This is a form of **deterministic locking**—there are no deadlocks because all partitions acquire locks in the same order (sorted by key, or by sequence number as a tiebreaker). Once locks are acquired, the partition executes the transaction’s read operations (to validate any read conditions) and then applies the writes to a temporary log. It then sends an “ack” back to the sequencer, indicating it is prepared to commit.

3. **Commit Phase**: The sequencer waits for acks from all involved partitions. Because the ordering is deterministic and locks are acquired in that order, there is no possibility of conflict that would require an abort (except for the first committer wins rule for snapshot isolation). Once all acks are received, the sequencer sends a “commit” message to all partitions. The partitions then finalize the writes (make them visible to future snapshots) and release locks. The sequencer also records the transaction as committed in its log.

This looks like standard two-phase commit, but there are critical differences:

- The sequencer is not a single point of failure (it’s a Raft group), so it’s highly available.
- The prepare phase does not require waiting for a _global_ clock or for replicas in other data centers to acknowledge. Since all partitions are within the same logical cluster (they are co-located or communicate via direct connections), the network latency between partitions is typically low (within the same data center or region). Fauna’s architecture places partition replicas in multiple data centers, but the sequencer and the partitions are aware of the geo-distribution. However, Fauna optimizes by having **active replicas** in each region; the prepare/commit messages can go to the nearest replica that holds the partition.
- The deterministic locking eliminates the need for abort/retry due to conflicts with transactions that have a lower sequence number. Conflicts only occur with transactions that have a _higher_ sequence number; those will wait. This is akin to a **sequential execution** but with parallelism across non-conflicting keys.

## Snapshot Isolation in Fauna: Reads Without Locks

For read-only transactions, Fauna offers a much faster path. Every partition maintains a multi-versioned store (similar to MVCC). Writes are applied with a commitment timestamp (the sequence number). A read-only transaction receives a **snapshot timestamp**—either from a local clock (for causally consistent reads) or from the sequencer (for stronger consistency). The transaction then reads the latest version of each key that has a commit timestamp ≤ the snapshot timestamp. Because the database is multi-versioned, the read can proceed without acquiring locks, even if a concurrent write transaction is modifying the same key.

This is the standard snapshot isolation model. But Fauna adds a twist: to ensure that the snapshot is globally consistent, the snapshots must be “causally consistent” with the write order. Fauna achieves this through a **hybrid logical clock (HLC)** that combines physical time with logical counters. The HLC ensures that if a write transaction commits at time T, any subsequent read transaction will see a snapshot with timestamp ≥ T (assuming the read uses a later HLC value). This is similar to CockroachDB’s approach.

For read-only transactions that require **serializable snapshot isolation** (i.e., the read must reflect all committed writes before the transaction started, including those that may not yet be replicated to the local replica), Fauna can optionally wait until the local replica’s state catches up to the snapshot timestamp. This is analogous to Spanner’s TrueTime wait. However, Fauna minimizes this wait by streaming the sequencer log aggressively to all replicas.

## Concurrency Control: Deterministic Locking and Read-Write Conflicts

One of the biggest challenges in distributed databases is handling **hot keys**—keys that are frequently accessed by many concurrent transactions. In a traditional lock-based system, these keys become bottlenecks. In Calvin, deterministic ordering ensures that all transactions are serialized in a global order. So if two transactions both write to the same hot key, they will be executed in sequence, one after the other, according to their order in the sequencer. This is essentially a **serial queue** for that key, but it avoids the overhead of distributed locking: the partitions just apply a local lock.

But what about read-write conflicts? In snapshot isolation, a read transaction should not block writes, and a write transaction should not block reads (except when a write tries to commit after a concurrent read has seen an older version – the first committer wins rule). Fauna handles this by using **multi-version concurrency control (MVCC)**. Writes create new versions; reads see the version based on snapshot timestamp. Conflicts only occur when two concurrent _write_ transactions touch the same key. In that case, one of them (the one with the later sequence number) may need to abort if the earlier one has already committed. However, because deterministic ordering ensures that all transactions are totally ordered, there is no true “concurrency” in the execution phase—transactions are executed in the order they were sequenced. So a write transaction that is preceded by another write transaction to the same key will simply wait until the earlier one finishes. There is no abort except in the case of optimistic concurrency control where the write set intersects with the read set of a previously committed transaction (a common SI anomaly called write skew). Fauna’s deterministic ordering also prevents write skew because all transactions are serialized in a single order; if the scheduler detects a dependency that would cause a cycle, the later transaction is aborted. But because the order is known upfront, such cycles are rare.

## Fault Tolerance and Recovery: Using a Replicated State Machine

Fauna’s entire system is built on a **replicated state machine (RSM)** using Raft. The sequencer is a Raft group that replicates the transaction log. Additionally, each partition is itself a Raft group (or multiple groups for small partitions) that replicates the state of that partition across multiple nodes in different data centers. This means that even if an entire data center fails, the partition’s data is still available in other data centers.

When a sequencer fails, Raft elects a new leader, and the log is still intact. The new leader continues to sequence transactions from where the old leader left off. Partitions that miss any transactions from the log will fetch them from the sequencer’s replicated log (since all sequencer replicas have the log).

For partitions, if a replica fails, the partition’s Raft group will elect a new leader from among the surviving replicas. The new leader will have the most up-to-date state (since Raft ensures state machine consistency). Write transactions that were in the prepare phase but not yet committed are handled specially: because the sequencer has the commit decision in its log, it can re-send commit/abort messages to the new partition leader after recovery. This ensures that no transaction is lost.

## Performance Characteristics: How Fauna Achieves Low Latency Globally

The combination of deterministic scheduling, snapshot isolation for reads, and a streamlined commit protocol yields impressive performance numbers:

- **Read latency**: For a single point read that is cache-friendly, Fauna can return results in under 5 ms, even when the read is served from a replica in a different data center (because the snapshot can be served locally after a small wait for consistency). This rivals NoSQL databases like Cassandra or DynamoDB.

- **Write latency**: For a single-partition write transaction, the latency is determined by the sequencer’s Raft commit (typically 2-10 ms within a region) plus the local partition execution (microseconds). For multi-partition writes, the extra prepare/commit round trip adds maybe 1-5 ms within a data center. Cross-data-center writes are slower (50-200 ms) because the sequencer and partitions may be in different regions, but Fauna allows applications to choose **affinity** (e.g., all data for a user group can be co-located in one region, so most transactions remain local).

- **Throughput**: Because the sequencer can batch many transactions into a single Raft entry, and partitions can execute transactions in parallel across non-conflicting keys, Fauna can achieve hundreds of thousands of transactions per second per partition. The deterministic ordering allows the system to exploit parallelism without sacrificing correctness.

## Comparison with Other Systems

Let’s contrast Fauna with three prominent distributed databases that also offer ACID transactions:

**Google Spanner**: Spanner uses TrueTime, a global clock with bounded uncertainty. It provides **external consistency** (linearizability) for transactions. However, Spanner requires a commit wait of ± the uncertainty window (typically 7 ms) for read-write transactions. Fauna does not need such a wait because it uses logical timestamps from the sequencer. Fauna’s consistency is slightly weaker (snapshot isolation vs. external consistency) but offers lower latency for most workloads.

**CockroachDB**: CockroachDB uses hybrid logical clocks and optimistic concurrency control with retries. It also provides serializable snapshot isolation. For write-heavy hot key workloads, CockroachDB can suffer from high abort rates and retries. Fauna’s deterministic ordering avoids retries entirely—transactions execute in the agreed order, so there are no conflicts to abort (except for write skew, which is rare). This gives Fauna a performance advantage under contention.

**YugabyteDB**: YugabyteDB uses a combination of Raft and two-phase locking (occasionally with optimistic concurrency). Its architecture is similar to Spanner but with a less precise clock. It also offers serializable and snapshot isolation. It tends to have higher latency for multi-partition transactions due to the lock-based approach and clock synchronization.

Fauna’s main trade-off is the requirement to declare read/write sets upfront. This is a burden for applications that use interactive queries (e.g., “find all users with balance > 100”) within a transaction. However, Fauna allows “stored procedures” (user-defined functions in its query language, FQL) that can be executed deterministically on the server, where the read set can be discovered as the transaction runs (but still must be declared before execution? Actually, Fauna’s model allows a transaction to perform multiple reads and writes, but the client must specify the keys it will touch beforehand in a “transaction declaration”. This can be cumbersome for dynamic workloads. Fauna mitigates this by supporting **incremental declare** within a stored procedure, but the declaration must still be known at the start.

## Practical Examples: Transactions in FQL

To make this concrete, let’s look at how a developer would write a cross-key transfer using Fauna’s query language (FQL). FQL is a functional query language that runs on the server.

```fql
// Declare the transaction boundaries
Transaction(
  Let('sender_ref', Ref('accounts', 'alice')),
  Let('receiver_ref', Ref('accounts', 'bob')),
  Let('amount', 100),

  // Check sender balance
  Let('sender_doc', Get(Var('sender_ref'))),
  Let('sender_balance', Select(['data', 'balance'], Var('sender_doc'))),
  If(LTE(100, Var('sender_balance')),
    // If sufficient funds, update both
    Let('new_sender_balance', Subtract(Var('sender_balance'), Var('amount'))),
    Do(
      Update(Var('sender_ref'), { data: { balance: Var('new_sender_balance') } }),
      Update(Var('receiver_ref'), { data: { balance: Add(
        Select(['data', 'balance'], Get(Var('receiver_ref'))),
        Var('amount')
      ) } })
    ),
    // Else abort
    Abort('Insufficient funds')
  )
)
```

Note that in this FQL snippet, the read set (the two account references) is known at the start because we explicitly Get them inside the Transaction. In Fauna’s implementation, the server can analyze the transaction’s data access pattern before execution (since it’s a deterministic function). The server then extracts the keys (the refs) and sends them to the sequencer as part of the transaction declaration.

For read-only queries, you can simply perform a Get or Paginate without a Transaction wrapper; these operations automatically use a consistent snapshot.

## The Commit Protocol in Depth: Handling Failures and Timeouts

We touched on the commit protocol earlier, but let’s explore its failure modes. Suppose a partition does not respond to the prepare message within a timeout. The sequencer can proceed to commit only if it has received a majority of prepare acks? No, in Fauna’s design, the sequencer must receive prepare acks from **all** partitions that the transaction touches. If a partition is slow or unreachable, the sequencer cannot commit the transaction. This seems like a classic blocking problem in 2PC.

Fauna solves this by ensuring that the partitions are highly available and that the sequencer uses a **lease-based** mechanism to detect failures quickly. If a partition fails, its Raft group will elect a new leader (within a few hundred milliseconds). The sequencer can retry the prepare message to the new leader. The transaction will not be blocked indefinitely because the sequencer can abort the transaction if a partition is down for too long. The abort decision is also deterministic and logged.

In practice, Fauna’s architecture ensures that within a data center, partitions are replicated and fail over quickly. Cross-data-center transactions are more delicate, but Fauna recommends using **region-local data** when possible, or accepting that cross-region latency will be high.

## Snapshot Isolation and the Read-Only Path: More Details

For read-only transactions, Fauna avoids the sequencer entirely. A client can do:

```fql
// Read-only: no Transaction wrapper needed
Get(Ref('accounts', 'alice'))
```

The client’s request is routed to any replica that is sufficiently up-to-date. Fauna’s replicas maintain a **consistency timestamp** – the timestamp of the last committed transaction they have applied. The replica will respond if its consistency timestamp is ≥ the snapshot timestamp requested (which is the current HLC time). If not, the replica waits (usually a very short time because the sequencer streams the log continuously) or the request is forwarded to a replica that is ahead.

Fauna also supports **causal consistency**: if a client writes and then immediately reads, the read will see the write because the client’s read request carries the HLC timestamp of its last write. The replica will block until it has applied that write. This is standard for followers in many distributed databases.

## Conclusion

Fauna’s distributed transaction algorithm is a masterful synthesis of two powerful ideas: **deterministic scheduling** (Calvin) and **snapshot isolation**. By forcing read-write transactions to declare their data access patterns upfront, Fauna can order transactions in a global log before they execute. This eliminates the need for distributed locking and complex conflict resolution during execution. For read-only transactions, snapshot isolation allows lock-free reads from local replicas, providing low latency. The commit protocol, while reminiscent of two-phase commit, is much more efficient because it operates within a deterministic ordering context, avoiding the blocking scenarios that plague classic 2PC.

The result is a database that offers ACID semantics globally, with performance that often exceeds both traditional SQL and NoSQL systems. The trade-off—the need to declare reads and writes—is a fair price for developers who want the peace of mind that comes with strong consistency without the latency hit.

As distributed systems continue to power the global economy, algorithms like the one in Fauna show that you don’t have to choose between consistency and performance. With clever design, you can have both. The next time you build an application that needs to handle money, tickets, or inventory across the world, you can reach for Fauna and trust that your transactions are safe, fast, and correct—no matter where your users are.
