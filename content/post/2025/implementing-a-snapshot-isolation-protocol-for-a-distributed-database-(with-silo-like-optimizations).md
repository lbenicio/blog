---
title: "Implementing A Snapshot Isolation Protocol For A Distributed Database (with Silo Like Optimizations)"
description: "A comprehensive technical exploration of implementing a snapshot isolation protocol for a distributed database (with silo like optimizations), covering key concepts, practical implementations, and real-world applications."
date: "2025-06-07"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Implementing-A-Snapshot-Isolation-Protocol-For-A-Distributed-Database-(with-Silo-Like-Optimizations).png"
coverAlt: "Technical visualization representing implementing a snapshot isolation protocol for a distributed database (with silo like optimizations)"
---

# The Cost of Order: Why We Trade Serializability for Speed

_Imagine you are the architect of a global financial exchange. In your system, a single user action—say, a trader buying 10,000 shares of a volatile stock—triggers a cascade of side effects: deducting from a cash balance, updating a portfolio valuation, enqueuing a notification, and logging the trade for auditors. To the outside world, this sequence of operations must appear as if it happened in a single, indivisible instant. It must be serializable._

_Now, imagine that same system handling a billion requests a day. The naïve approach—locking every piece of data a transaction touches until it commits, or enforcing a strict global order of operations—is a performance catastrophe. It creates a bottleneck that transforms your low-latency database into a parking lot. This is the fundamental tension in distributed database design: how do you give application developers the illusion of a simple, single-threaded machine, while leveraging the raw parallelism of hundreds of CPU cores and dozens of servers?_

*For decades, the industry’s answer has been a pragmatic compromise. We don’t aim for perfect isolation. Instead, we aim for *good enough* isolation that can be implemented with breathtaking efficiency. And the most successful, elegant, and widely deployed of these compromises is **Snapshot Isolation (SI)** .*

*You have probably used it without knowing it. It is the default in Oracle, PostgreSQL (historically), Microsoft SQL Server, and countless other systems. SI is the workhorse of modern concurrency control. But implementing it correctly—especially in a *distributed* setting where there is no shared memory, no single clock, and the network is unreliable—is a brutal systems design problem.*

_In this post, we are going to tear down the problem and build it back up. We will leave the warmth and safety of a single-machine database and venture into the treacherous waters of distributed systems where clocks are unreliable and failures are the norm._

---

## 1. The Serializability Ideal and Its Cost

Before we embrace snapshot isolation, we need to fully understand what we are sacrificing. Serializability is the gold standard of transaction isolation. It guarantees that the outcome of executing multiple concurrent transactions is equivalent to some sequential (serial) execution of those same transactions. In other words, it makes the database behave as if transactions are run one after another, even though they may interleave internally.

### 1.1 Implementing Serializability

The classic implementation is **two-phase locking (2PL)** with locks held to commit (strict 2PL). Every transaction acquires shared locks on read data and exclusive locks on write data. All locks are released only after the transaction commits or aborts. This guarantees that no other transaction sees uncommitted data, and that write–write conflicts are prevented. However, locking is expensive:

- **Lock contention**: When many transactions want the same hot row (e.g., the latest tweet, a popular product), they queue up.
- **Distributed deadlocks**: In a multi-node system, locks are scattered across servers. Detecting deadlocks requires waiting graphs that may be stale or incomplete.
- **Two-phase commit (2PC)** : For distributed transactions, a coordinator ensures all participants commit or abort. 2PC introduces network round trips and blocking on failures.

Another approach is **Optimistic Concurrency Control (OCC)** , where transactions proceed without locks and validate at commit time. OCC works well when conflicts are rare but can cause expensive aborts under contention.

### 1.2 The Performance Problem

Let’s run the numbers. In a system processing 1 billion requests per day, that’s roughly 11,574 requests per second. If each request touches only three rows and each row spends 1 millisecond under a lock (holding it during computation and logging), the lock occupancy rate is 34.7% per row. With even moderate contention, the effective throughput collapses. This is the “parking lot” effect: concurrency stalls because the locks act as narrow gates.

To make matters worse, serializability requires **strict ordering** of events. In a distributed system, achieving a global total order of transactions is expensive—it usually requires a leader or a distributed consensus algorithm (Paxos, Raft). While these are powerful tools, they add latency proportional to the number of participants.

### 1.3 When Serializability Is Non‑Negotiable

Serializability is not just a theoretical nicety. It is required for correctness in financial systems, inventory management (no double selling), and many other domains. For example, consider a flight booking system:

```sql
-- Transaction 1: Book seat 12A for Alice
UPDATE seats SET passenger = 'Alice', status = 'booked' WHERE seat = '12A';

-- Transaction 2: Book seat 12A for Bob (concurrent)
UPDATE seats SET passenger = 'Bob', status = 'booked' WHERE seat = '12A';
```

Under serializable isolation, only one transaction succeeds; the other aborts. Under weaker isolation, both might succeed, selling the same seat twice. That is a catastrophic bug.

Yet many applications can tolerate something less than full serializability. They accept occasional anomalies—as long as they are rare and well understood—in exchange for order-of-magnitude performance gains. Snapshot isolation is the sweet spot.

---

## 2. Snapshot Isolation: The Pragmatic Compromise

Snapshot Isolation (SI) was first formally described by Berenson et al. in 1995 (“A Critique of ANSI SQL Isolation Levels”). It provides **read consistency** and **prevention of dirty reads, non‑repeatable reads, and phantom reads**. But it allows a specific anomaly called **write skew**.

### 2.1 How SI Works

In a single‑machine database, snapshot isolation works as follows:

1. **Snapshot Start**: When a transaction begins, it receives a timestamp (or version). It sees a snapshot of the database consisting of all changes committed before that timestamp.
2. **Reads**: The transaction reads from its snapshot. It never sees uncommitted changes from other transactions—not even changes that commit later. This eliminates read phenomena.
3. **Write‑Write Conflicts**: When a transaction attempts to commit, the system checks if any data it wrote has been modified by another transaction that committed after the snapshot start. If so, the later transaction aborts. This is called the **First Committer Wins (FCW)** rule.
4. **Commit Timestamp**: If no conflict, the transaction commits and receives a timestamp after the snapshot start.

The key insight: **readers never block writers, and writers never block readers**. Write conflicts are resolved only at commit time, reducing contention dramatically.

### 2.2 An Example: Bank Transfer

```sql
-- Transaction A: Transfer $100 from savings (acct1) to checking (acct2)
BEGIN ISOLATION LEVEL SNAPSHOT;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;
```

If transaction B (simultaneously) moves money the other way, both may read the initial balances and both may compute updated values. At commit time, one will see that its updated rows have been changed by the other and will abort. The survivor sees a consistent snapshot.

**But**: If two transactions read the same snapshot and each only updates di**ﬀ**erent rows (say, A updates id=1, B updates id=2), both can commit, even though they may have observed an inconsistent global state. That’s write skew.

### 2.3 Write Skew: The Price of Concurrency

Write skew is the classic SI anomaly. It occurs when two transactions read overlapping sets of data and then write di**ﬀ**erent parts of the set, leading to a constraint violation that neither transaction alone would cause.

**Hospital shift scheduling**: Two on‑call doctors, Alice and Bob. A constraint says at least one must be on call at all times (i.e., the sum of on‑call statuses >= 1).

- Transaction 1 (Alice): Reads that both are on call. Decides to take herself o**ﬀ** call.
- Transaction 2 (Bob): Reads that both are on call. Decides to take himself o**ﬀ** call.
- Both commit under SI because they write di**ﬀ**erent rows. After commit, both are o**ﬀ** call—violation of the constraint.

This is not just a toy example. It happens in real‑world systems—inventory with quantity limits, room booking with capacity constraints, and more. With serializability, the database would detect the dependency and abort one.

Despite this, SI is immensely popular because write skew is often rare or acceptable. And for many applications, the performance gain is worth the risk. So how do we build it in a distributed environment?

---

## 3. Implementing SI on a Single Machine

To understand the distributed problem, we must first appreciate the elegance of single‑machine SI. The single machine has shared memory, a single clock (within one node), and deterministic state. The standard implementation is **Multiversion Concurrency Control (MVCC)** , which stores multiple versions of each data item.

### 3.1 MVCC Internals

In MVCC, every write creates a new version of the row, tagged with the writer’s transaction ID (or timestamp). A read operation sees only those versions that are visible according to the snapshot timestamp.

For example, in PostgreSQL:

- Each tuple has `xmin` (the transaction that created it) and `xmax` (the transaction that deleted or updated it).
- A snapshot is a list of currently active transactions and the global transaction ID (`xid`).
- Visibility rule: A tuple is visible if `xmin` is committed and is either `<= snapshot_xid` and not in the active list, and `xmax` is either null or not committed or `> snapshot_xid`.

Pseudo‑implementation of a visibility check:

```python
def is_visible(tuple, snapshot):
    if tuple.xmin == MY_TXN:  # own uncommitted
        return True
    if not is_committed(tuple.xmin):
        return False
    if tuple.xmin == snapshot.xmax_before:
        # committed before snapshot started
        return True
    if tuple.xmin in snapshot.active_before:
        # committed after snapshot started, visible only if not in active
        return False  # because we don't see it
    # ... more complex logic with xmax, etc.
    return True
```

### 3.2 Commit Protocol

For a transaction that writes, the commit protocol must obey the First Committer Wins rule. The database checks that for every row modified by the transaction, no other transaction that started after the snapshot has already committed a write to that same row. This is equivalent to checking that the tuple’s `xmax` (if it points to a committed transaction with timestamp > snapshot start) is not set.

### 3.3 Why It Works on a Single Machine

The single machine provides:

- **A single point of truth**: One clock, one memory space for the transaction log.
- **Atomic visibility**: When a transaction commits, its writes become visible atomically. There is no window where half the rows of a multi‑row transaction are visible.
- **Instant conflict detection**: The database can examine all modified rows in memory and compare timestamps instantly.

Now, remove shared memory and a reliable clock, and everything breaks.

---

## 4. The Distributed Challenge: No Shared Clock, No Shared Memory

When we move to a distributed database (sharded across multiple nodes, possibly in different data centers), we lose the fundamental assumptions that made MVCC simple.

### 4.1 Clock Skew

Servers do not have perfectly synchronized clocks. Even with NTP, there is a drift of a few milliseconds, sometimes more. A transaction starting on node A at `T_A` and a transaction on node B at `T_B` cannot be ordered correctly if `T_A` and `T_B` are from uncoordinated clocks. This breaks snapshot visibility.

**Example**: Node A’s clock is 10 ms ahead of Node B’s. A transaction starting on Node A at its local time 1000 will have a snapshot timestamp of 1000. A transaction starting on Node B at its local time 995 (which really corresponds to 985 in real time) will have snapshot time 995. The second transaction actually started after the first in real time, but its snapshot is earlier, so it may see changes from the first transaction (which committed at local time 1050) if the system uses physical timestamps—it would incorrectly see a later transaction.

**Consequence**: Without care, a distributed SI implementation can allow **backward visibility** (reading a snapshot that includes modifications from transactions that haven’t started yet) or **forward invisibility** (not seeing modifications that logically should be present). Both lead to isolation violations beyond write skew.

### 4.2 Distributed Commit

A transaction that updates rows on two shards requires a **distributed commit protocol**, typically two‑phase commit (2PC). 2PC adds:

- Prepare phase: Each shard votes yes/no.
- Commit phase: If all yes, coordinator tells all to commit.
- If a shard fails after preparing but before committing, the transaction remains in doubt until the coordinator recovers.

Distributed commit introduces **blocking**, but more critically, it creates a window where some shards have committed and others have not. If we want SI’s “snapshot” to be consistent across shards, we need to ensure that the snapshot start time is global and that writes become visible at a single global commit time.

### 4.3 The Need for a Global Clock or a Logical Equivalent

To implement distributed SI, we need a way to assign **monotonic, globally comparable timestamps** to transactions. We also need to know when a timestamp is “safe” to read—i.e., no transactions with smaller timestamps will later commit a conflicting write.

This is the core architectural challenge. Solutions fall into three categories:

1. **Centralized timestamp oracle** (e.g., Google Spanner’s TrueTime, Percolator’s timestamp server).
2. **Hybrid logical clocks** (e.g., CockroachDB, which uses HLCs to achieve causal consistency).
3. **Logical clocks with careful ordering** (e.g., early research on Generalized Snapshot Isolation by Fekete et al., and implementations in systems like YugaByte DB).

Let’s examine each.

---

## 5. Distributed Snapshot Isolation: The Core Ideas

### 5.1 Centralized Timestamp Oracle

The simplest way to get globally monotonic timestamps is to have a single server (or a replicated fault‑tolerant service) that hands out unique, increasing timestamps. Every transaction asks this oracle for a start timestamp. The oracle guarantees that start timestamps are strictly increasing and that commit timestamps are greater than start timestamps and also strictly increasing.

**Example**: Google’s Percolator (used in Google Search indexing) uses a timestamp oracle built on top of Bigtable. Each transaction gets a start timestamp, reads data that is <= that timestamp, and upon commit obtains a commit timestamp > start. The data is written with the commit timestamp.

**Drawbacks**:

- The oracle becomes a scalability bottleneck under high transaction rates.
- Network latency for every transaction (two round trips if you need both start and commit timestamps).
- The oracle must be highly available and linearizable; failure blocks the whole system.

**Where it works**: Systems where transaction rates are medium and latency is less critical, or when the oracle can be replicated with consensus (e.g., using a Raft group, but that still has latency).

### 5.2 Hybrid Logical Clocks (HLC)

CockroachDB popularized the use of Hybrid Logical Clocks for distributed SI. An HLC combines physical wall time with a logical counter: `HLC_time = max(physical, logical)` and increments the logical component when physical time ties. The key property: HLC timestamps are monotonically increasing across nodes, and if event A happens before event B, then `HLC(A) < HLC(B)` (not guaranteed for concurrent events, but HLC gives a tight bound on clock uncertainty).

CockroachDB’s approach:

- Each node has an HLC that is periodically synchronized with peers.
- When a transaction reads, it uses the node’s current HLC as a “read timestamp”. It reads data with write timestamps <= read timestamp.
- When a transaction writes, it uses a timestamp obtained from the local HLC (or from a leaseholder) as the “write timestamp”.
- **Commit Wait**: To handle clock skew, before serving a read, the node may need to wait until it is certain that no write with a higher timestamp can be assigned to a transaction that started before the read. This is analogous to Spanner’s commit wait but uses HLC uncertainty intervals.

**Uncertainty Interval**: Suppose a node’s clock is known to be off by at most `ε` from real time. When a node sees a read timestamp `T` from another node (HLC value), it cannot trust that all writes with timestamps less than `T` have been committed. It must wait until its own clock passes `T + ε` (or until it hears from the leaseholder) before returning the read. This introduces extra latency but is manageable with low clock skew (e.g., using GPS or constant monitoring).

**Trade‑off**: Coarser synchronization (larger ε) increases read latency; tighter synchronization requires expensive hardware (e.g., dedicated NTP servers, GPS receivers).

### 5.3 Using Logical Clocks and Causal Ordering

Research on Generalized Snapshot Isolation (Fekete et al., 2005) showed that you can implement snapshot isolation using only logical clocks (Lamport clocks) and a careful commit rule that ensures one‑copy equivalence. The key is to model the database as a collection of items and treat each read and write as a **multiversion** store with a global ordering of versions.

Implementations like **YugaByte DB** (now part of YugabyteDB) use a concept of **Hybrid Time** plus a distributed transaction protocol that relies on a **global transaction order** managed by a leader (similar to 2PC with a replicated commit log). They achieve SI by ensuring that commit timestamps are assigned after all transaction participants agree that no conflicts exist, using a logical timestamp associated with the transaction.

### 5.4 Summary of Approaches

| Approach              | Clock/Time Source     | Read Latency              | Write Latency        | Complexity | Example Systems                                               |
| --------------------- | --------------------- | ------------------------- | -------------------- | ---------- | ------------------------------------------------------------- |
| Centralized Oracle    | Dedicated server      | Low (one RPC)             | Low (one RPC)        | Medium     | Percolator (Oracle), Amazon DynamoDB? (has timestamp service) |
| Hybrid Logical Clocks | Local + bounded skew  | Medium (uncertainty wait) | Low                  | High       | CockroachDB, TiDB                                             |
| Logical Clocks        | Local + communication | Low (no wait)             | Medium (coordinated) | Very High  | Research prototypes, YugabyteDB (variant)                     |

Each approach trades simplicity for latency or throughput. The most battle‑tested distributed SI systems are CockroachDB and Google Spanner (which actually provides external consistency, stronger than SI, but used similar concepts). Let’s examine them in depth.

---

## 6. Case Study: Google Spanner

Google Spanner is not exactly a snapshot isolation system; it provides **external consistency** (which is stronger than SI and equivalent to strict serializability) and **linearizable** reads. However, its design uses snapshot reads as a foundation, and TrueTime is the key innovation that enables globally consistent snapshots.

### 6.1 TrueTime: GPS + Atomic Clocks

Spanner’s TrueTime API provides a time interval `[earliest, latest]` with a bound on clock uncertainty (usually 1–7 ms). Every Spanner node has a local atomic clock and GPS receiver; the uncertainty is precisely measured. The API returns `TT.now()` = `[T_earliest, T_latest]`.

### 6.2 Distributed Transactions with TrueTime

A transaction that writes:

1. **Acquire locks** on all involved Paxos groups (Spanner’s unit of replication).
2. **Assign a commit timestamp** `s` from `TT.now().latest + d` where `d` is a fixed delay (commit wait). Wait until `TT.now().earliest > s`. This ensures that any later transaction will have a timestamp exceeding `s`, even considering clock skew.
3. **Commit** all groups with the same timestamp `s`. Because of the wait, no future transaction can have a smaller timestamp, so reads that start after the wait will see the update (if they read at that timestamp).

**Snapshot reads**: A read can be executed at a timestamp `t`. The system reads from replicas that have applied up to `t`. If the replica is not up to date, it waits.

### 6.3 Why Spanner Is Not “Simple SI”

Spanner actually provides **serializable** isolation (plus external consistency) because it prevents write skew and other anomalies. However, its snapshot reads are a tool; the key is that every transaction has a globally meaningful timestamp. Spanner used TrueTime to avoid the complexity of a centralized timestamp oracle while still guaranteeing correctness.

**Performance**: Spanner is used by Google’s massive applications (e.g., Google Ads). Despite the commit wait (typically a few milliseconds), the system achieves high throughput because the wait is small relative to the network latency and the lock holding times.

**Lessons**: If you can afford specialized hardware (GPS, atomic clocks) or can rely on a tightly synchronized cluster (e.g., within a single datacenter with NTP), you can build a stronger isolation level with the performance of SI. But for most deployments, physical clock skew must be managed at the software level.

---

## 7. Case Study: CockroachDB

CockroachDB is a distributed SQL database that aims for **strong consistency** (serializable snapshot isolation, or SSI) by default, but it also supports a “snapshot isolation” mode (historically, it used SI, then switched to SSI). Its architecture is a great example of distributed SI.

### 7.1 Hybrid Logical Clocks (HLC)

CockroachDB uses HLCs to assign timestamps to transactions. Each node broadcasts its HLC with gossip; the maximum HLC is propagated. This provides monotonicity and a bound on uncertainty.

### 7.2 Transaction Execution

A transaction can be **implicit** (single-statement) or **explicit** (multi‑statement). CockroachDB uses a **two‑phase commit** protocol tailored for SI:

1. The coordinator (the node that receives the transaction) picks a transaction ID and a **read timestamp** equal to the current HLC of that node.
2. All reads use this read timestamp, reading data with write timestamps <= read timestamp.
3. When the transaction writes, it obtains a **write timestamp** (usually same as read timestamp, but may increase due to conflicts).
4. The coordinator sends operations to the leases (range leaders). Each participant attempts to **lock the written key** (latch) and verify that no other transaction with a higher write timestamp has already written.
5. If conflict, the transaction may be retried with a newer timestamp.
6. **Commit**: The coordinator executes a two‑phase commit among the range leaders, then assigns a commit timestamp `c >= current HLC` and commits the write intent.

### 7.3 Handling Clock Skew

CockroachDB uses the concept of **max clock offset** (default 500 ms). When a node receives a read request with a timestamp `t`, it must ensure that all writes with timestamps <= `t` are visible. Because of clock skew, a write that originated on another node might have a timestamp `<= t` but not yet be committed or visible. The node must **wait** until it is certain that no such writes exist. This is the **uncertainty interval**:

```
max_offset = 500 ms
wait_until = t + max_offset
```

If the node’s clock is `now < wait_until`, it sleeps until `wait_until`. This ensures that if a write timestamp was assigned by a node whose clock was at most `max_offset` ahead, the write will be committed and visible. This wait is a source of latency. However, for many workloads, the uncertainty interval is rarely triggered because reads are served from the leaseholder, which is consistent.

### 7.4 Network Partitions and Clock Skew

Under a network partition, nodes may stop gossiping HLC updates, leading to clock divergence beyond `max_offset`. CockroachDB will then prevent certain operations (like serving reads) until the clock uncertainty is resolved. This is a safety measure to avoid anomalous reads.

### 7.5 Comparison with Spanner

- Spanner uses hardware to shrink `max_offset` to single ms; CockroachDB relies on software and NTP, leading to 500 ms uncertainty.
- CockroachDB’s commit protocol is more complex due to retry handling and timestamp bumps (to break deadlocks), but it ensures SSI.
- Both use a form of “commit wait” (Spanner’s TrueTime wait, CockroachDB’s uncertainty wait) to guarantee read freshness.

CockroachDB proves that distributed SI can be built with commodity hardware, albeit with higher latency under clock skew. Many users find that tolerable.

---

## 8. Case Study: PostgreSQL with Distributed Extensions

PostgreSQL is the poster child for single‑machine SI. Its MVCC is mature and well‑tuned. But when people try to scale PostgreSQL horizontally (sharding), they face the distributed challenge. Two notable attempts: Postgres‑XC (now part of Postgres‑XL) and Citus (now a distributed PostgreSQL extension).

### 8.1 Postgres‑XC / Postgres‑XL

Postgres‑XC (eXtreme Cluster) was a multi‑master PostgreSQL variant that used a **Global Transaction Manager (GTM)** to assign transaction IDs and timestamps. The GTM is a central coordinator that hands out monotonically increasing `xid`s. This is similar to the timestamp oracle approach.

- **Pros**: Simpler to reason about; transactions behave like single‑node PostgreSQL.
- **Cons**: GTM is a single point of failure and a bottleneck. Network latency to GTM adds overhead.
- **SI violations**: If a transaction reads from one node and then writes to another, the GTM ensures the snapshot is consistent because the xid ordering is global. However, the system still suffers from the performance issues of centralized orchestration.

### 8.2 Citus (and other sharded PostgreSQL)

Citus takes a different approach: it shards tables and does **not** support distributed transactions across shards by default (or only with coordinator‑based 2PC). Snapshot isolation is provided within each shard via PostgreSQL’s MVCC, but across shards there is no global snapshot. Transactions that span shards must use **two‑phase commit** and rely on the coordinator to enforce ordering, but because each shard has its own snapshot and local timestamps, cross‑shard SI is not guaranteed.

**Example anomaly**: A transaction T1 on shard A and shard B updates rows. On shard A, it sees snapshot S1. On shard B, it might see a snapshot S2 that is later than S1, because timestamps are not coordinated. This can lead to non‑repeatable reads across shards.

Citus solves this by either serializable isolation at the coordinator level (using locking) or by recommending that you avoid distributed transactions. This is a common trade‑off: many distributed databases offer SI only on a per‑shard basis, not globally.

---

## 9. Anomalies in Distributed SI: Write Skew and Beyond

We already introduced write skew. But distributed SI introduces subtler anomalies due to clock skew and non‑atomic visibility.

### 9.1 Read Skew (Distortion Due to Partial Visibility)

In a single‑machine SI, when a transaction commits, its writes become visible atomically. In a distributed system, a transaction may write to multiple nodes. After commit, there is a window where some nodes have applied the write and others have not. A subsequent transaction that has a snapshot between those two times may see an inconsistent cross‑shard view.

**Example**: T1 moves money from account A (on node1) to account B (on node2). After T1 commits, a snapshot that starts after the commit on node1 but before the commit on node2 could see the debit on A but not the credit on B. This is a violation of snapshot isolation (which expects a consistent point‑in‑time snapshot).

To prevent this, the system must ensure that either the snapshot timestamp is after all writes are visible (by using commit wait) or that reads wait until the snapshot timestamp is “safe” (as CockroachDB does with uncertainty). If not done, the system provides **partitioned** SI (per‑shard SI), not global SI.

### 9.2 Long‑Running Transactions and Stale Snapshots

If a transaction runs for a long time, its snapshot becomes increasingly stale. Under local SI, visibility is based on timestamps; under distributed SI, the snapshot’s timestamp may be so old that it sees a state that no longer exists physically (due to garbage collection). This is a problem for MVCC: old versions must be kept for open transactions. In a distributed system, garbage collection must be coordinated across nodes to avoid deleted versions that a long‑running snapshot might still require.

### 9.3 The “Snapshot Isolation” vs “Repeatable Read” Confusion

In standard SQL, `REPEATABLE READ` often means “no non‑repeatable reads” but allows phantoms. In PostgreSQL, `REPEATABLE READ` is actually snapshot isolation. But in distributed databases, vendors sometimes blur the lines. It’s important to read the fine print: does the system provide **global** snapshot isolation, or just per‑node? This distinction defines the guarantees for your application.

---

## 10. Trade‑offs and Alternatives

Given the complexity of distributed SI, why not just implement serializable isolation using other techniques? The trade‑off is performance vs. correctness.

### 10.1 Serializable Snapshot Isolation (SSI)

Discovered by Michael Cahill et al. in 2008, SSI adds conflict detection to SI to prevent write skew and other non‑serializable anomalies. PostgreSQL implemented SSI starting in version 9.1. The idea: track **read‑write conflicts** (if a transaction reads a row that later another transaction writes, mark dangerous). When a transaction is in a dangerous structure (a cycle of conflicts), abort it.

**Distributed SSI**: This is even harder. CockroachDB implements SSI by applying a variant of the SSI algorithm using a **global conflict detection** mechanism: it checks for write‑write and write‑read conflicts across nodes, using a combination of locking and timestamp ordering. The result is serializable isolation with performance close to SI (for low‑contention workloads).

**Cost**: SSI adds overhead for conflict tracking and may cause more aborts under high contention. For many applications, the extra overhead is worth it to avoid anomalies.

### 10.2 Deterministic Databases (Calvin, Fauna)

Another approach is to process transactions in a deterministic order. Calvin (from H. Zhang et al., Yale) uses a sequencing layer that orders all transactions and then replays them in a single‑threaded fashion on each node. This eliminates distributed concurrency control altogether but requires deterministic logic (no random numbers) and can limit throughput on the sequencer.

FaunaDB uses a Calvin‑inspired design and provides serializable isolation globally. It achieves high performance by batching and partitioning the sequencing load. However, the deterministic requirement can be restrictive for some applications (e.g., using GUIDs as primary keys, which are deterministic; using `UUID` generation that relies on system time may need care).

### 10.3 RAMP Transactions

RAMP (**R**ead**‑A**tomic **M**ulti‑partition) transactions, proposed by Bailis et al., provide atomic visibility for multi‑shard reads without expensive coordination. They don’t provide snapshot isolation, but they guarantee that a reader sees either all or none of the effects of a multi‑shard write. This is a weaker isolation (avoiding partial cross‑shard updates) while being fast.

### 10.4 When to Use Which

- **Use serializable (SSI) or strict serializability** when correctness is critical (financial transactions, inventory, booking systems). Accept lower concurrency.
- **Use snapshot isolation** when reads are frequent and writes are rare, or when occasional write skew is acceptable (analytics dashboards, content management, most web apps).
- **Use read‑committed or even read‑uncommitted** for high‑throughput, low‑consistency needs (logging, real‑time counters).
- **Use deterministic databases** when you can tolerate deterministic application logic and need strong guarantees with high throughput.

---

## 11. Conclusion: The Cost of Order Revisited

We set out to understand the trade‑off between serializability and speed. Snapshot isolation is the embodiment of that trade‑off: it throws away the global serial order and pays the price of write skew, but in exchange it delivers read‑without‑blocking and high concurrency. In distributed systems, the cost of achieving even snapshot isolation rises dramatically: we must contend with clock skew, distributed commit, and partial visibility.

We examined several paths:

- Centralized timestamp oracle (Percolator) – simple but a bottleneck.
- Hybrid logical clocks with uncertainty handling (CockroachDB) – scalable but adds latency.
- TrueTime (Spanner) – nearly eliminates latency due to clock skew but requires special hardware.
- Deterministic databases (Calvin, Fauna) – sidestep the clock issue entirely by ordering globally.

There is no free lunch. Every system chooses where to incur the cost: in latency, throughput, hardware, or complexity. The best choice depends on your workload and correctness requirements.

As a systems architect, you must ask: what isolation does my application truly need? If it can tolerate occasional anomalies, snapshot isolation may give you the performance you need. If correctness is paramount, you must be willing to accept the overhead of serializability—or invest in the technology (Spanner, CockroachDB SSI, or a deterministic store) that provides it efficiently.

The future is likely a spectrum: we will see more systems that offer **configurable isolation** per transaction (e.g., Google Spanner allows snapshot reads for non‑critical queries, full serializable for critical ones). We will also see hardware‑assisted clock synchronization become cheaper (e.g., GPS receivers in server racks, or IEEE 1588 PTP), narrowing the uncertainty gap.

Ultimately, the cost of order is a price we negotiate with the laws of physics and the constraints of distributed algorithms. Understanding that negotiation is what makes a great architect. And now, you have the tools to choose wisely.

---

## Further Reading

1. Berenson, H., et al. “A Critique of ANSI SQL Isolation Levels.” SIGMOD 1995.
2. Fekete, A., et al. “Generalized Snapshot Isolation.” ICDE 2005.
3. Corbett, J. C., et al. “Spanner: Google’s Globally‑Distributed Database.” OSDI 2012.
4. Taft, R., et al. “CockroachDB: The Resilient Geo‑Distributed SQL Database.” SIGMOD 2020.
5. Cahill, M., et al. “Serializable Isolation for Snapshot Databases.” TODS 2009.
6. Bailis, P., et al. “Read‑Atomic Multi‑Partition Transactions with RAMP.” SOCC 2013.
7. Stonebraker, M., et al. “The End of an Architectural Era (It’s Time for a Complete Rewrite).” VLDB 2007.

_Thank you for reading! If you found this post valuable, please share it with your colleagues. Have questions or want to share your experience with snapshot isolation? Leave a comment below._
