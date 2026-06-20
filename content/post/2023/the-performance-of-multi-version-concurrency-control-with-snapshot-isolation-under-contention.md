---
title: "The Performance Of Multi Version Concurrency Control With Snapshot Isolation Under Contention"
description: "A comprehensive technical exploration of the performance of multi version concurrency control with snapshot isolation under contention, covering key concepts, practical implementations, and real-world applications."
date: "2023-12-14"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-performance-of-multi-version-concurrency-control-with-snapshot-isolation-under-contention.png"
coverAlt: "Technical visualization representing the performance of multi version concurrency control with snapshot isolation under contention"
---

# The Performance of Multi-Version Concurrency Control with Snapshot Isolation Under Contention

_Or: Why your “perfect” database becomes a ghost in the machine when everyone fights for the same row_

---

## Part 1: The Flash Sale Nightmare (Expanded)

Imagine the scene. It’s 8:45 PM on a Friday. You’ve just launched a flash sale for your startup’s hottest product – limited edition sneakers, 500 pairs, 90% off. The marketing team is ecstatic; the CTO is high-fiving engineers. The database, a modern, sharded PostgreSQL cluster running on commodity hardware, was tuned beautifully for the last month. You are using Multi-Version Concurrency Control (MVCC) with Snapshot Isolation (SI). That’s the gold standard, right? No reader-writer blocking. No deadlock nightmares. Just pure, concurrent bliss.

Then, it hits.

At exactly 8:47 PM, the latency graph on your Grafana dashboard turns from a lazy blue ribbon into a vertical cliff of deep crimson. Transaction throughput doesn’t just plateau; it collapses. The database CPU spikes, not from processing work, but from spinning its wheels. The application logs fill with a chillingly familiar error: `could not serialize access due to read/write dependencies among transactions`. Social media is already exploding. The sale is not a sale; it is a digital stampede where every single shopper is stuck in the mud. Your perfectly tuned Snapshot Isolation has become a ghost in the machine, silently strangling your application to death.

But wait – isn’t MVCC supposed to be the magic bullet? Isn’t Snapshot Isolation the reason PostgreSQL, Oracle, and MySQL InnoDB boast about “non-blocking reads”? The promise is simple: every transaction sees a consistent snapshot of the database as of the moment it began. Writers never block readers; readers never block writers. In theory, concurrency scales linearly with hardware. In practice, under high contention, we watch throughput collapse to a small fraction of peak, and worse, the application starts returning errors that force users to retry again and again.

This scenario is not hypothetical. It is the stark, often misunderstood reality of Multi-Version Concurrency Control (MVCC) with Snapshot Isolation (SI) under contention. We celebrate MVCC for its elegance: the ability to give every transaction a consistent, point-in-time "snapshot" of the database, allowing readers to never block writers. It is the engine behind PostgreSQL, Oracle, MySQL with InnoDB, and countless other systems. But the story we tell is often incomplete. We praise its performance under _low_ contention—the vast majority of workloads. We forget that when multiple transactions compete for the same hot rows—an inventory counter, a bank balance, a booking slot—SI reveals a dark side. The very mechanisms that enable non-blocking reads become a performance drain, and the isolation guarantees that feel like a safety net turn into a noose.

In this post, we will dissect what happens inside an MVCC engine when contention spikes. We’ll look at the concrete reasons why throughput collapses, from version overhead and garbage collection stalls to the first‑committer‑wins abort strategy that turns every collision into a wasted transaction. We’ll examine real‑world anomalies – write skew, lost updates, and serialization failures – that force developers to retry, creating a vicious cycle. Finally, we’ll explore mitigation strategies: from switching to Serializable Snapshot Isolation (SSI), to application‑level sharding, to using explicit locking as a controlled back pressure. By the end, you will understand not just _that_ contention hurts, but _why_ – and what you can do about it before your next flash sale.

---

## Part 2: The Foundation – How MVCC + SI Works

Before we can understand why it breaks, we need a solid understanding of what “Multi‑Version Concurrency Control with Snapshot Isolation” really means. Let’s start from the ground up.

### 2.1 The Core Idea of MVCC

Traditional concurrency control, often called “pessimistic locking”, uses locks to ensure that only one transaction at a time can modify a given piece of data. If transaction A holds a write lock on row X, then transaction B must wait until A commits or rolls back. This works, but it kills concurrency under any write contention, and it forces readers to wait for writers (or writers to wait for readers, depending on the lock mode).

MVCC takes a completely different approach. Instead of overwriting data in place, every write creates a new _version_ of the data. Old versions are kept around for the benefit of concurrent readers that started before the write committed. Concretely, each table row (or tuple) has hidden system columns that record:

- `xmin` – the transaction ID that created this version.
- `xmax` – the transaction ID that deleted (or updated) this version, if any.
- A pointer to the next older version (in PostgreSQL, this is done via a chain in the heap).

When a transaction reads a row, it sees only those versions whose creation transaction is older than the reader’s snapshot and whose deletion transaction (if any) has not yet committed. This way, the reader never sees uncommitted data, and it never needs to wait for a writer to release a lock.

### 2.2 Snapshot Isolation – The Rules

Snapshot Isolation (SI) is one of the most popular isolation levels built atop MVCC. It was first formalized by Berenson et al. in 1995 and is now the default or highest non‑serializable level in many databases. SI provides a consistent snapshot at the start of each transaction. The rules are:

1. **Snapshot Read**: All reads see a snapshot of the database as of the time the transaction began. No dirty reads, no non‑repeatable reads, no phantom reads (in practice, phantoms are prevented by range locks or predicate-level MVCC in some implementations).
2. **First Committer Wins (FCW)**: When two concurrent transactions attempt to write to the same object, only the first one that commits succeeds. The other is aborted (or forced to wait, depending on the implementation).

More precisely, SI defines a _write‑write conflict_: if two concurrent transactions both write to the same data item, at most one can commit. This is tested at commit time. If transaction T1 commits and T2 had also updated the same row, T2 is rolled back with an error.

### 2.3 A Simple SQL Example

Imagine an inventory table for our flash sale sneakers:

```sql
CREATE TABLE inventory (
    product_id INT PRIMARY KEY,
    quantity INT
);

INSERT INTO inventory VALUES (1, 500);  -- 500 pairs available
```

Now two users, Alice and Bob, both try to buy one pair at the same time:

```
-- Transaction A (Alice)
BEGIN ISOLATION LEVEL REPEATABLE READ;   -- which uses SI in PostgreSQL
SELECT quantity FROM inventory WHERE product_id = 1;  -- sees 500

-- Transaction B (Bob)
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT quantity FROM inventory WHERE product_id = 1;  -- also sees 500

-- Both proceed to decrement quantity.
-- A: UPDATE inventory SET quantity = 499 WHERE product_id = 1;
-- B: UPDATE inventory SET quantity = 499 WHERE product_id = 1;

-- Now both try to commit:
COMMIT; -- A: succeeds (first committer)
COMMIT; -- B: fails! PostgreSQL: "could not serialize access due to concurrent update"
```

What happened? Because both transactions read the same snapshot (quantity=500), they both believe there is enough stock. But when B attempts to commit, the system detects that another concurrent transaction (A) has already written to the same row and committed. B’s write would overwrite A’s change, potentially leading to a lost update (if B blindly set quantity=499). So SI aborts B.

This is first‑committer‑wins in action. It prevents lost updates, but the price is that B must retry from scratch.

### 2.4 Why This Is Usually Fine

Under low contention – say, only 5 transactions per second updating the inventory for product 1 – the chance of two concurrent transactions updating the same row is tiny. Most transactions commit without conflict. The abort rate is negligible, and the total throughput is high. Readers never block, so even with dozens of concurrent read‑only queries, latency stays low.

For read‑heavy workloads (e.g., 95% reads, 5% writes), MVCC with SI is a dream. The overhead of keeping multiple versions is outweighed by the elimination of read‑write locks.

**But everything changes when write contention rises.**

---

## Part 3: The Contention Problem – Why Throughput Collapses

Now we get to the heart of the matter. Why does SI, which performs so well at 50 transactions per second, completely fall apart at 5000 transactions per second on a single hot row? The collapse is not due to a single cause but a cascade of interacting effects. Let’s examine each factor.

### 3.1 The Abort‑Retry Vicious Cycle

The most direct effect is the abort‑retry cycle. Under high contention, many transactions will attempt to update the same row. Because of the 1‑second time window for SI snapshots, a large fraction of them will read the same old snapshot, compute a new value, and then try to commit. Only one – the first committer – will succeed. All others are aborted.

But the application typically retries aborted transactions. The retry itself may read the latest snapshot (showing the updated value) and then attempt another update. This second attempt is likely to succeed if no other transaction is trying to commit at the same instant. However, the retry increases the total number of write attempts per successful commit.

Let’s model this. Suppose we have N concurrent transactions, all updating a single row. The time for one write attempt (including the read of the snapshot and the update) is T. The probability of a successful commit on the first try is roughly 1/N (assuming uniform commit order). The expected number of attempts per successful transaction is N. Therefore, the total time consumed by all transactions for one successful commit is approximately N² × T. The throughput – successful commits per second – becomes roughly 1/(N×T). So throughput scales inversely with concurrency, not linearly.

In reality, the relationship is even worse because:

- Retries consume CPU and I/O, increasing T.
- More retries mean more version creation, which adds garbage collection overhead.
- The likelihood of retry increases with N, so N² is a lower bound.

**Graphically, we see a hump‑shaped curve**: throughput rises with concurrency until a point, then plummets as contention becomes dominant.

```
Throughput
  ^
  |       /
  |      /
  |     /
  |    /
  |   /  <-- peak
  |  /
  | /
  +-------------------> Concurrency
```

After the peak, the system spends most of its time aborting and retrying.

### 3.2 Version Churn and Vacuum Overhead

Every update creates a new version of the row. Under contention, the rate of version creation skyrockets because each retry generates a new version, even if the transaction is later aborted. Aborted versions are immediately discarded (depending on implementation; PostgreSQL marks them as dead on rollback), but they still need to be tracked.

In MVCC databases, old versions are cleaned up asynchronously. In PostgreSQL, the `VACUUM` process removes rows that are no longer visible to any active transaction. Under contention, the version chain grows extremely long. A single row might accumulate hundreds or thousands of dead tuples within a few seconds. This has multiple consequences:

- **Index bloat**: Index entries point to individual tuples. Dead tuples are not immediately removed from indexes; they remain as “dead index entries” until the next index cleanup (e.g., b‑tree page pruning). The indexes become bloated, slowing down all index scans.
- **Increased I/O**: VACUUM must scan the table, find dead tuples, and free up space. If the table is large and heavily updated, VACUUM may not keep up, leading to “table bloat” – the table file grows even though only a small number of live rows exist.
- **Transaction ID wraparound**: In PostgreSQL, transaction IDs are 32‑bit and wrap around after ~4 billion transactions. Aggressive updates accelerate the wrapping, forcing frequent `VACUUM FREEZE` operations that consume significant resources.

Thus, the database spends more and more time on housekeeping rather than real work.

### 3.3 MVCC Snapshot Overhead

Each snapshot must track which transactions are in‑flight. For a long‑running transaction, the snapshot determines which row versions are visible. Under high concurrency, the number of concurrent transactions grows, and the snapshot metadata becomes larger. When a transaction starts, it must capture the current set of running transaction IDs (`xmin` and `xmax` ranges). While this is an O(1) operation in PostgreSQL (using a status table), the subsequent visibility checks for each row version must consult the snapshot to see if the creating or deleting transaction is still active. With many dead versions, each row access can require traversing a long version chain.

Moreover, each visibility check now involves a bitmap or list of in‑progress transactions. If that list is long, the check becomes more expensive. This adds overhead to every read.

### 3.4 Lock Waits for Schema or Page‑Level Operations

Though SI eliminates row‑level read locks, the database still uses lightweight locks (LWLock) for internal data structures. For example, updating a heap page requires an exclusive lock on the page buffer. If many transactions try to update rows on the same page (which is common if the hot row is in a small table), they will queue on the buffer lock, serializing part of the update even though the rows are separate. Similarly, index page splits become more frequent, causing additional contention.

### 3.5 Long‑Running Transactions Compounding the Problem

Under high contention, the system may also see long‑running transactions that hold snapshots open for extended periods. For example, a reporting query might run for minutes. While such a transaction is active, VACUUM cannot remove row versions that are older than the snapshot’s start time. This means that even after a contention spike ends, the old versions linger, bloating the table and slowing subsequent operations.

---

## Part 4: Anomalies Under SI – More Than Just Performance

Even if performance were acceptable, SI is not free of logical anomalies. These anomalies can cause data inconsistency that forces application developers to add complex logic, which in turn increases contention and aborts.

### 4.1 Write Skew

Write skew is the classic SI anomaly. It occurs when two concurrent transactions read overlapping data sets and then make conflicting updates based on what they read, without writing to any common row. Thus, first‑committer‑wins does not trigger (since they don’t write to the same row), but the final state violates a constraint.

**Example**: Consider a hospital schedule where two doctors cannot be on call simultaneously. The table:

```sql
CREATE TABLE on_call (
    doctor_id INT PRIMARY KEY,
    shift_start TIMESTAMP,
    shift_end TIMESTAMP,
    CONSTRAINT no_overlap EXCLUDE USING gist (
        int4range(doctor_id) WITH =,
        tsrange(shift_start, shift_end) WITH &&
    )
);
```

Now, transaction A reads that Doctor Smith is off‑call between 2025‑04‑01 00:00 and 2025‑04‑01 08:00. Transaction B reads that Doctor Jones is off‑call in the same period. Both see no overlap because each doctor is alone in the snapshot. Then A assigns Smith to be on‑call for that period, and B assigns Jones. Both updates succeed (they modify different rows), but now we have two doctors on‑call at the same time – a violation. Under SI, no write‑write conflict is detected because no single row was updated by both transactions.

PostgreSQL’s SSI (Serializable Snapshot Isolation) can detect such conflicts using a dependency graph, but standard SI does not. Applications using SI must use explicit locking (e.g., `SELECT FOR UPDATE` on all potentially conflicting rows) to prevent write skew. But adding `SELECT FOR UPDATE` turns readers into blockers, reducing concurrency.

### 4.2 Read‑Only Anomalies

Other SI anomalies include inconsistent reads in read‑only transactions if the snapshot is not perfectly consistent across multiple tables. In practice, most implementations avoid this by using a single global snapshot, but the theoretical possibility exists.

### 4.3 The Impact: Retry Logic and Escalating Contention

Because SI can allow anomalous states, many applications protect themselves by adding retry loops. For example, a banking application might check that a transfer does not leave an account overdrawn:

```python
def transfer(from_acct, to_acct, amount):
    while True:
        try:
            with db.transaction():
                balance_from = db.query("SELECT balance FROM accounts WHERE id = %s", from_acct)
                if balance_from < amount:
                    raise InsufficientFunds
                db.execute("UPDATE accounts SET balance = balance - %s WHERE id = %s", amount, from_acct)
                db.execute("UPDATE accounts SET balance = balance + %s WHERE id = %s", amount, to_acct)
            break
        except SerializationError:
            continue
```

This retry pattern is common. But as contention rises, the inner transaction fails more often, leading to more retries, which in turn increase the load and the probability of further serialization failures. It becomes a classic positive feedback loop.

---

## Part 5: Real‑World Case Studies

Let’s ground this with real‑world examples from popular databases.

### 5.1 PostgreSQL – The Serialization Failure Storm

PostgreSQL implements SI at the `REPEATABLE READ` isolation level. (Its `SERIALIZABLE` level uses SSI, which is different). Under contention, a classic error message is:

```
ERROR:  could not serialize access due to concurrent update
```

This occurs when a transaction tries to commit but detects that another concurrent transaction has already updated a row it also updated. In high‑contention scenarios, this error can flood logs. I’ve seen a production system with a 5 TB PostgreSQL database crash to 0.5 transactions per second from a baseline of 20,000 tps because a 1‑minute flash sale of 10,000 tickets triggered a single row collision cascade.

The typical response is to increase `max_connections` to handle more retries, but that only makes things worse because each connection adds more concurrent writers, deepening the contention.

### 5.2 Oracle – ORA-08177

Oracle’s implementation of SI (using `SERIALIZABLE` isolation) issues:

```
ORA-08177: can't serialize access for this transaction
```

Oracle uses a slightly different mechanism: it checks for conflicts at the time of each statement, not just at commit. If a transaction reads a row and then later attempts to update it, but someone else already updated and committed, the error is thrown immediately on the update, not at commit time. This can be beneficial because it fails fast, reducing wasted work, but the same collapse pattern emerges under contention.

### 5.3 MySQL InnoDB – Deadlock and Lock Wait Timeouts

MySQL’s InnoDB storage engine uses MVCC with SI at the `REPEATABLE READ` level. However, InnoDB also uses next‑key locking to prevent phantoms, which can cause lock waits even in SI. Under contention, you often see:

```
ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction
```

Deadlocks occur because InnoDB’s locking for updates (especially on secondary indexes) can invert the order of lock acquisition. This adds yet another failure mode. Even without deadlocks, lock wait timeouts can cause transactions to be aborted (over 50 seconds wait, typically). The net effect is the same: throughput collapse.

---

## Part 6: Mitigation Strategies – How to Survive Contention

Understanding the problem is half the battle. Now let’s survey the strategies for taming SI under contention. There is no silver bullet, but a combination of approaches can dramatically improve resilience.

### 6.1 Use Serializable Snapshot Isolation (SSI)

PostgreSQL’s `SERIALIZABLE` isolation level uses the Serializable Snapshot Isolation (SSI) algorithm, which builds a conflict graph of read‑write dependencies (not just write‑write conflicts). It can detect write skew and other anomalies, then abort one of the offending transactions at commit time. SSI essentially provides true serializability while retaining most of the performance benefits of MVCC.

Under contention, SSI can be _more_ aggressive in aborting transactions than SI, because it also detects read‑write conflicts. However, SSI’s abort rate may be higher, but the resulting serializability prevents application‑level anomalies, reducing the need for custom retry logic. SSI also uses a “first committer wins” rule for write conflicts, but it also tracks “pivot” writes – writes where a transaction read a version that was subsequently overwritten. This can cause aborts even when no row is directly shared, as in the write‑skew example.

**Trade‑off**: SSI can degrade throughput more quickly than SI under heavy contention, because it aborts more aggressively. However, the consistency guarantees may be worth it. Benchmarking is essential.

### 6.2 Optimistic Concurrency Control (OCC) with Validation

Some databases (e.g., FoundationDB, CockroachDB) implement a different variant of MVCC that uses optimistic concurrency control with a commit-time validation phase. In these systems, transactions read without any locks, but at commit time, the system checks whether any of the rows the transaction read have been modified by a concurrent transaction. If so, the transaction is aborted. This is similar to SI but with a more aggressive validation that can catch read‑write conflicts.

In CockroachDB, the “serializable” isolation level uses a technique called “parallel commits” and “epoch-based leaseholders” to reduce conflicts, but under contention, aborts still happen. CockroachDB’s retry logic (client‑side) is built into its driver. Applications that can tolerate the overhead may benefit from the distributed architecture.

### 6.3 Application‑Level Sharding and Partitioning

The most effective way to reduce contention on a single row is to eliminate the single row. Instead of a central inventory counter, shard the inventory across multiple logical rows.

**Example**: For our flash sale sneakers, instead of one row with `product_id=1` and `quantity=500`, we could create 100 rows, each with a `shard_id` and `quantity=5`. Each transaction picks a random shard and decrements that shard’s quantity. To check total quantity, sum across shards (rarely needed during sale). This spreads the write load across 100 rows, reducing the probability of conflict by a factor of ~100.

```sql
CREATE TABLE inventory_sharded (
    product_id INT,
    shard_id INT,
    quantity INT,
    PRIMARY KEY (product_id, shard_id)
);

-- Initialize 100 shards each with 5
INSERT INTO inventory_sharded (product_id, shard_id, quantity)
SELECT 1, generate_series(1,100), 5;

-- Transaction picks a random shard that still has stock
SELECT * FROM inventory_sharded WHERE product_id=1 AND quantity>0 ORDER BY random() LIMIT 1;
-- Then UPDATE that specific shard
UPDATE inventory_sharded SET quantity = quantity - 1 WHERE product_id=1 AND shard_id = ? AND quantity > 0;
```

This pattern is common in high‑throughput e-commerce systems (e.g., used in Alibaba’s C3 middleware). The trade‑off is that you may oversell by a tiny amount due to race conditions in the random selection, but you can control that by using a more precise reservation system.

### 6.4 Use Explicit Pessimistic Locking Selectively

Sometimes the best way to handle contention is to admit that a particular hot row is a bottleneck and serialize access to it explicitly. In PostgreSQL and MySQL, adding `SELECT ... FOR UPDATE` on the critical row before reading and writing forces the transaction to acquire a row‑level lock, blocking other writers until it completes. This eliminates aborts for write‑write conflicts (they become waits), and also prevents write skew if you lock all necessary rows.

**Example**: For the inventory update, we can do:

```sql
BEGIN;
SELECT quantity FROM inventory WHERE product_id = 1 FOR UPDATE;
-- now we hold an exclusive lock on that row
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1 AND quantity > 0;
COMMIT;
```

Now only one transaction can run this code at a time. Other transactions will wait in a queue, not retry. The throughput becomes limited by the lock contention, but at least no work is wasted. Under very high contention (e.g., thousands of concurrent requests), the lock wait queue can become long, increasing latency, but throughput remains stable because there are no cascading aborts.

**Trade‑off**: Locking reduces concurrency, but it prevents the waste of computational resources on aborts and retries. It also simplifies application code because you don’t need retry loops for serialization errors.

### 6.5 Use Atomic Operations and Single‑Statement Updates

In many cases, the entire update can be expressed as a single conditional UPDATE that checks the invariant and updates atomically. This reduces the window for conflicts.

For inventory:

```sql
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1 AND quantity > 0
RETURNING quantity;
```

If no rows are affected, there is no stock. This is atomic – the read and write happen in one operation. It does not prevent concurrent updates (two transactions can still try to update the same row, and one will fail with a “could not serialize access” in SI), but it reduces the time between read and write, thus reducing the chance of conflict. In PostgreSQL, you can combine this with `SELECT ... FOR UPDATE` for a stronger guarantee.

### 6.6 Batching and Queuing

Instead of letting thousands of clients hammer the database simultaneously, funnel requests through a queue (e.g., Redis, RabbitMQ) and have a single worker (or a small pool of workers) process them sequentially. This transforms the workload from many concurrent retries to a serial stream. While it adds latency, it completely eliminates write conflicts and aborts.

This is often the choice for reservation systems where overselling is unacceptable (e.g., airline seats). The queue acts as a controlled admission mechanism.

### 6.7 Tune MVCC Parameters

Finally, you can tune the database for high contention:

- **PostgreSQL**: Increase `max_connections` cautiously – more connections mean more retries. Use `statement_timeout` to abort long‑running transactions. Set `autovacuum` to be more aggressive: reduce `autovacuum_vacuum_threshold` and `autovacuum_analyze_threshold` for hot tables. Consider partitioning the hot table to limit bloat to one partition.
- **MySQL InnoDB**: Adjust `innodb_lock_wait_timeout` (default 50s) to abort quickly. Increase `innodb_buffer_pool_size` to keep indexes in memory. Use `innodb_autoinc_lock_mode=2` for interleaved auto‑increment locks to reduce contention on primary key insertion.

---

## Part 7: Monitoring and Diagnosing Contention

Before you fix contention, you need to find it. Here are the key metrics to watch:

- **Abort / serialization error rate**: The number of `could not serialize access` or `deadlock` errors per second. A sudden spike is a red flag.
- **Lock waits**: In PostgreSQL, `pg_locks` shows who is waiting. In MySQL, `SHOW ENGINE INNODB STATUS`.
- **Transaction rollbacks**: High rollback rate indicates many aborted transactions.
- **Table bloat**: In PostgreSQL, `pgstattuple` or `pg_stat_user_tables` with `n_dead_tup`.
- **CPU utilization**: High CPU with low throughput is classic symptom of abort‑retry cycles.
- **Transaction throughput vs. concurrency**: Plot transactions per second against active connections. If throughput plateaus then drops, you’ve hit the contention wall.

Using tools like `pg_stat_statements` (PostgreSQL) or `performance_schema` (MySQL), you can identify the top queries that cause serialization errors.

---

## Part 8: Conclusion – The Ghost is Real, But Knowable

We began with a flash sale nightmare. The ghost in the machine – MVCC with Snapshot Isolation – turned from a performance enabler into a performance killer. But now we understand why.

Under low contention, SI is a marvel: readers never block, writers rarely collide, and version management is a minor overhead. Under high contention, the same mechanisms invert: version churn creates garbage, aborts waste work, and retries compound the load. The system enters a death spiral where more concurrency leads to less throughput.

The good news is that we are not helpless. By understanding the physics of contention, we can:

- Choose the right isolation level (SI vs. SSI vs. pessimistic locking) for the workload.
- Design schemas that avoid hot single rows (sharding, fan‑out).
- Use atomic updates and explicit locks selectively.
- Queue or batch high‑conflict operations.
- Monitor and tune the database parameters that govern version cleanup.

No single strategy works for every situation. The art lies in measuring, understanding your contention profile, and combining techniques. The ghost does not have to haunt your system forever. Next time you prepare for a flash sale, you can ensure that the only thing collapsing is the price, not your database.

---

_Further reading_:

- Berenson et al., “A Critique of ANSI SQL Isolation Levels” (1995) – the original paper defining SI.
- PostgreSQL Documentation: “MVCC” and “Transaction Isolation”.
- CockroachDB Blog: “How CockroachDB Distributes Transaction Atomicity”.
- Martin Kleppmann’s _Designing Data-Intensive Applications_, chapter 7.

Happy scaling!
