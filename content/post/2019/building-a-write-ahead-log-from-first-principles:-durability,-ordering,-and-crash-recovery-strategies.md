---
title: "Building A Write Ahead Log From First Principles: Durability, Ordering, And Crash Recovery Strategies"
description: "A comprehensive technical exploration of building a write ahead log from first principles: durability, ordering, and crash recovery strategies, covering key concepts, practical implementations, and real-world applications."
date: "2019-03-08"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/building-a-write-ahead-log-from-first-principles-durability,-ordering,-and-crash-recovery-strategies.png"
coverAlt: "Technical visualization representing building a write ahead log from first principles: durability, ordering, and crash recovery strategies"
---

# Building A Write Ahead Log From First Principles: Durability, Ordering, And Crash Recovery Strategies

## Introduction

Imagine the scene. You have just finished rolling out a new financial transaction system. The database is humming, handling thousands of account transfers per second. A user on the other side of the world clicks "Send." The system processes the debit, subtracts the balance, writes the new data to memory, and sends a triumphant HTTP `200 OK` response back to the browser. The user smiles. You walk away from your terminal for a well-deserved cup of coffee.

Then, the lights flicker.

In a thousandth of a second, everything in volatile memory—every transaction, every metadata update, every carefully maintained buffer pool—is erased. You frantically re-boot the server. The database engine starts up. The application logs begin to scroll. **User A’s balance is unchanged. The money is gone.**

The user has a receipt. You have a catastrophic inconsistency. This is the silent, deadly nightmare that haunts every distributed systems engineer, every data platform architect, and every database designer. It is the fundamental tension at the heart of modern computing: **the speed of memory versus the safety of disk.**

We live in an age of instantaneous experience. We demand that databases respond in milliseconds. To meet this demand, systems rely on Random Access Memory (RAM) which is blindingly fast but ephemeral. A write to RAM takes roughly 50–100 nanoseconds. A synchronous write to a spinning hard disk, however, takes roughly 10 milliseconds—a difference of roughly six orders of magnitude. Even with Solid State Drives (SSDs), the gap is vast. So, databases cheat. They keep a "dirty" copy of your data in memory, promising to flush it to disk later. This is called the buffer pool or page cache.

This arrangement works beautifully—until the power fails.

The history of data engineering is largely the story of trying to reconcile this irreconcilable gap. Every major database, from PostgreSQL to SQLite, from Oracle to Redis (yes, Redis too in its AOF mode), has had to wrestle with this problem. And the solution that emerged, refined over decades of research and production outages, is the Write-Ahead Log (WAL). It is the unsung hero of data integrity, the silent guardian that ensures your money doesn’t vanish when the lights go out.

In this post, we are going to tear down the Write-Ahead Log and rebuild it from first principles. We will start with the raw physics of storage, then derive the minimal protocol that guarantees durability, ordering, and crash recovery. We will implement a working WAL in code, examine the trade-offs that real systems make, and explore advanced topics like group commit, checkpointing, and distributed WALs. By the end, you will not only understand _how_ a WAL works—you will know _why_ it must work that way, and you could build one yourself.

Buckle up. This is a long journey, but every step is grounded in a deep, practical need: the need to never lose data.

---

## 1. The Durability Problem: A Deeper Dive

Before we can design a solution, we must fully understand the problem. The introduction touched on the memory/disk latency gap, but the implications run much deeper. Let's walk through a concrete transaction lifecycle to see where the cracks appear.

### 1.1 Anatomy of a Database Transaction

Consider a simple money transfer from Alice to Bob. The database maintains two rows:

```
Accounts: { id: 1, name: 'Alice', balance: 100 }
          { id: 2, name: 'Bob',   balance: 50 }
```

A transaction to transfer $20 from Alice to Bob looks like this in a typical relational database:

1. Begin transaction.
2. Read Alice's current balance (100).
3. Decrement Alice's balance by 20 → new balance 80.
4. Write the updated Alice row (balance 80) into the buffer pool (memory).
5. Read Bob's current balance (50).
6. Increment Bob's balance by 20 → new balance 70.
7. Write the updated Bob row (balance 70) into the buffer pool.
8. Commit.

Step 8 is critical. The system must ensure that _either_ both updates are durable _or_ neither is. The user expects that after receiving a successful commit response, the transfer is permanent.

### 1.2 The Buffer Pool Illusion

Modern databases maintain a **buffer pool**—a cache of database pages in memory. When you write to a page, the change initially only affects the in-memory copy. The disk copy remains stale. This is called a "dirty page." The database periodically writes dirty pages back to disk via a background process called a **checkpointer** or **page cleaner**.

Now, imagine the transaction commits: the database returns `COMMIT OK`. But what if the dirty pages containing Alice's and Bob's new balances have not yet been flushed to disk? Suppose a crash occurs one millisecond after the commit. The buffer pool is gone. The disk still shows the old balances (Alice: 100, Bob: 50). The transaction is **lost**—even though we told the user it succeeded. This violates the **Durability** property of ACID.

The problem is that we flushed the _commit_ acknowledgement to the user, but we didn't flush the _data_.

### 1.3 Direct Writes Are Too Slow

You might ask: why not just write every page to disk synchronously at commit time? That would guarantee durability, but it would be catastrophically slow. Each commit would involve at least one random disk write (assuming the pages are scattered) and require an `fsync` (or `FlushFileBuffers` on Windows) to ensure the data physically lands on the platter or NAND. A 10 ms latency per commit limits throughput to 100 transactions per second. In 2025, that's unacceptable.

Even if we batch multiple commits into a single disk write, we still need a mechanism to track which transactions succeeded and which didn't. Batching alone doesn't solve the ordering problem: if we crash mid-batch, we need to know exactly which transactions were durable.

### 1.4 The Two Key Requirements

From this analysis, we can distill two fundamental requirements:

1. **Durability**: After a transaction commits, its effects must survive any crash. The system must not lose data that it has confirmed as committed.
2. **Ordering**: We must be able to reconstruct the sequence of changes exactly as they happened. This is essential for recovery (reapplying changes in the correct order) and for replication (sending changes to replicas in the same order).

These two requirements lead directly to the Write-Ahead Log.

---

## 2. The Write-Ahead Log: What and Why

A Write-Ahead Log (WAL) is an append-only data structure that records every modification made to the database _before_ the actual data pages are modified. The cardinal rule is: **the log must be written and fsynced to stable storage before the transaction is acknowledged as committed**. The data pages themselves can be written lazily, asynchronously.

### 2.1 The "Write-Ahead" Principle

The name says it all. The log is written _ahead_ of the actual data. The sequence is:

1. Append a log record describing the change (e.g., "page 42, offset 128, write value 80").
2. Fsync the log.
3. Modify the in-memory data page.
4. (Later) Flush the data page to disk.
5. (Optionally) Mark the log record as applied.

If a crash occurs between steps 2 and 3, the data page is unchanged, but the log record is durable. On recovery, the system will see the log record and can re-apply the change (redo). If a crash occurs after step 3 but before step 4, the data page might have been lost, but again, the log record exists to redo it. The key insight: **the log always contains enough information to reconstruct the committed state of the database.**

### 2.2 Why Append-Only?

Logs are fundamentally sequential writes. Sequential I/O is orders of magnitude faster than random I/O, especially on HDDs (seek time eliminated) and even on SSDs (no erase cycles to worry about for sequential writes). An append-only log can achieve write throughput in the hundreds of megabytes per second, while random writes typically plateau at a fraction of that.

Moreover, append-only structures are immune to partial overwrites. If we overwrote a log record in place, a crash during that overwrite could corrupt the record. Appending never modifies old data, so integrity is easier to maintain.

### 2.3 WAL vs. Direct Data Flush

Let's compare two strategies for a transaction that modifies two pages (e.g., Alice and Bob):

- **Direct page flush**: fsync(page1), fsync(page2), then commit. This requires two random fsyncs. Cost: ~20 ms.
- **WAL flush**: fsync(log_entry_containing_both_changes). One sequential fsync. Cost: ~2-10 ms depending on log size, but typically much less than two random seeks.

The WAL allows us to commit with a single, fast sequential write. The actual data pages can be written later in the background, potentially batched into more efficient sequential writes or even avoided entirely if they haven't changed much.

---

## 3. Designing a WAL from First Principles

Let's now build a minimal WAL. We'll strip away all the bells and whistles of production systems and focus on the core protocol. Our goal is to implement a WAL that guarantees durability and ordering for a simple key-value store.

### 3.1 What Goes Into a Log Record?

A log record must contain enough information to redo the change. It also needs to support undo if the transaction aborts (we'll discuss that later). For now, we assume only committed changes are logged (no undo). Each record should include:

- **Sequence Number (LSN)**: A monotonically increasing identifier that establishes total order. Often a simple 64-bit integer.
- **Transaction ID**: Identifies which transaction performed the change. Needed for grouping records belonging to the same transaction.
- **Page ID**: Which page (or key) is being modified.
- **Offset**: Where within the page the change starts.
- **Length**: How many bytes are changed.
- **Old Image** (optional for undo) and **New Image**: The before and after state. The new image is enough for redo; old image is needed if we want to support rollback.
- **Checksum**: To detect corruption.

A simplified binary format might look like:

```
+--------+--------+------+--------+--------+----------+----------+
|  LSN  |  TXID  | Page | Offset | Length | New Data | Checksum |
| 8 B   |  8 B   | 4 B  |  4 B   |  4 B   |  len B   |  4 B     |
+--------+--------+------+--------+--------+----------+----------+
```

The total overhead per record is about 28 bytes plus the data. In practice, systems often use variable-length records and include a header that specifies the type of record (e.g., BEGIN, UPDATE, COMMIT, ABORT).

### 3.2 Append and Fsync Protocol

The core operation is simple:

```python
def write_log_record(record):
    # Step 1: Serialize record to bytes
    data = serialize(record)
    # Step 2: Append to log file
    with open(log_path, 'ab') as f:
        f.write(data)
        f.flush()                    # Push to OS buffer
        os.fsync(f.fileno())         # Force to disk (stall until done)
    # Step 3: Now we can modify in-memory data
    apply_to_buffer(record)
```

Wait—why both `flush()` and `fsync()`? The `flush()` mechanism (in Python, `flush()` flushes the user-space buffer to the kernel; in C, `fflush` does the same) ensures that the data leaves the process memory. The `fsync()` system call tells the kernel to write the data to the physical device and waits for completion. Without `fsync`, the kernel could keep the data in its page cache for seconds, and a power failure could still lose it.

`fsync` is the only way to guarantee that the data has actually reached the non-volatile storage medium. On the flip side, `fsync` is slow—it often forces a cache flush on the disk controller. But it is non-negotiable for durability.

### 3.3 Choosing a Log Layout

We need to decide how to structure the log file on disk. Two common approaches:

1. **Single file with pointers**: Use one file that grows indefinitely. A separate **log sequence number** (LSN) pointer within the file tracks the current write position. Recovery scans from the beginning (or from the last checkpoint) to the current end.
2. **Segmented files**: Use multiple files of fixed size (e.g., 16 MB each). When one file fills up, switch to the next. This simplifies rotation and archival. The WAL in PostgreSQL uses this approach, with segments accessible by their WAL file name.

For simplicity, we'll use a single file. In practice, the file will need to be truncated or recycled, but we'll handle that later with **checkpoints**.

### 3.4 Handling Partial Writes

What if a crash occurs while we are writing a log record? The end of the file could contain a partially written record. On recovery, we must detect and ignore incomplete records. This is where the **checksum** comes in.

When we read a record, we compute its checksum (e.g., CRC32) over the header and data and compare it to the stored checksum. If checksums match, the record is valid. If they don't, the record is considered incomplete, and we stop recovery at that point—since the log is append-only, all records after a partially written one are also suspect.

A common trick is to write a "magic number" or record length at the start of each record. If the bytes at the expected position don't look like a valid length, we know we've hit a partial write.

### 3.5 Implementing a Minimal WAL

Let's implement a minimal WAL in Python for an in-memory key-value store. We'll support `put(key, value)` operations, with logging and crash recovery.

```python
import os
import struct
import hashlib
import pickle

class WAL:
    def __init__(self, path):
        self.path = path
        self.file = open(path, 'ab')
        self.lsn = 0
        self._init_lsn()

    def _init_lsn(self):
        # If file exists, find last LSN
        try:
            with open(self.path, 'rb') as f:
                record = self._read_last_record(f)
                if record:
                    self.lsn = record['lsn']
        except FileNotFoundError:
            pass

    def _serialize_record(self, key, value, lsn):
        # Simple format: lsn (8 bytes), key_length (4), key (key_length), value_length (4), value, checksum (4)
        key_bytes = key.encode()
        value_bytes = pickle.dumps(value)
        header = struct.pack('!QII', lsn, len(key_bytes), len(value_bytes))
        body = key_bytes + value_bytes
        checksum = hashlib.crc32(header + body) & 0xffffffff
        return struct.pack('!I', checksum) + header + body

    def append(self, key, value):
        self.lsn += 1
        record_bytes = self._serialize_record(key, value, self.lsn)
        self.file.write(record_bytes)
        self.file.flush()
        os.fsync(self.file.fileno())
        return self.lsn

    def close(self):
        self.file.close()

    def recover(self, store):
        """Replays the log into the store dictionary."""
        with open(self.path, 'rb') as f:
            records = []
            while True:
                # Read checksum (4 bytes)
                checksum_bytes = f.read(4)
                if not checksum_bytes:
                    break
                header = f.read(16)  # lsn(8) + key_len(4) + value_len(4)
                if len(header) < 16:
                    break  # partial header, stop
                lsn, key_len, value_len = struct.unpack('!QII', header)
                body = f.read(key_len + value_len)
                if len(body) < key_len + value_len:
                    break  # partial body
                expected_checksum = struct.unpack('!I', checksum_bytes)[0]
                actual_checksum = hashlib.crc32(header + body) & 0xffffffff
                if expected_checksum != actual_checksum:
                    break  # corruption, stop
                key = body[:key_len].decode()
                value = pickle.loads(body[key_len:])
                records.append((lsn, key, value))

        # Apply in order
        for lsn, key, value in records:
            store[key] = value
        self.lsn = records[-1][0] if records else 0
```

This is a toy, but it captures the essence: append, fsync, checksum, and replay. On startup, `recover` reads the entire log and applies every record to the store. The store becomes the state just before the last crash.

---

## 4. Crash Recovery Strategies

The simple WAL above does a full replay from the beginning. For a database that has run for years, this is impractical. Real systems use a combination of redo and undo logs, plus **checkpoints**.

### 4.1 Redo vs. Undo

When a transaction commits, we must be able to redo its changes after a crash. When a transaction aborts, we must be able to undo its changes (rollback). This leads to two log types:

- **Redo log**: Contains only the new values. Used to redo committed changes.
- **Undo log**: Contains the old values. Used to undo changes of aborted transactions.

In practice, a single log record often contains both images (old and new) to support both redo and undo, as in the ARIES recovery algorithm.

### 4.2 ARIES: A Practical Recovery Algorithm

The ARIES (Algorithm for Recovery and Isolation Exploiting Semantics) algorithm, developed by IBM in the 1990s, is the gold standard for crash recovery. It uses:

- **Log Sequence Numbers (LSN)** on every page (stored with the page).
- **Dirty Page Table**: tracks which pages have been modified but not yet flushed.
- **Checkpoint records**: periodically written to the log containing the state of the dirty page table and the latest checkpoint LSN.
- **Redo phase**: after a crash, replay from the last checkpoint onward to reapply all committed changes.
- **Undo phase**: roll back any transactions that were active at the time of the crash (no commit record found) using the log.

ARIES is complex but proven in systems like IBM DB2, Microsoft SQL Server, and (in spirit) PostgreSQL.

### 4.3 Checkpoints Explained

A checkpoint is a point in the log where all dirty pages have been written to disk. After a checkpoint, the log records before the checkpoint are no longer needed for redo (since the data is already on disk) and can be truncated.

In practice, a checkpoint involves:

1. Write a checkpoint begin record to the log.
2. Fsync the log.
3. Flush all dirty data pages to disk.
4. Write a checkpoint end record to the log.
5. Fsync the log again.

After the checkpoint ends, we know that the data pages reflect all changes up to the checkpoint LSN. On recovery, we only need to scan from the checkpoint begin onward, drastically reducing recovery time.

### 4.4 Recovery Process Step-by-Step

Using a simplified ARIES-like approach:

1. **Analysis Phase**: Scan the log from the last checkpoint (or beginning) to identify the set of dirty pages and the set of active transactions.
2. **Redo Phase**: Replay all log records, starting from the point where the database was last consistent (usually the previous checkpoint). This brings the database to the state just before the crash, including changes from both committed and uncommitted transactions.
3. **Undo Phase**: For each active transaction that had no commit record, roll back its changes by applying the undo (old image) from its log records.

The redo phase is idempotent: if a page was already written to disk, reapplying the same change is harmless (provided the page LSN is less than the record LSN). This is why keeping the page LSN is important.

---

## 5. Advanced Topics and Real-World Considerations

### 5.1 Group Commit

Group commit is a technique to batch multiple concurrent commits into a single fsync. Instead of each transaction issuing an fsync, they wait briefly for a batch of log records to accumulate, then a single fsync makes all of them durable. This dramatically increases throughput under high concurrency.

Trade-off: increased latency for individual commits (they wait for the batch). Many databases (e.g., PostgreSQL) have a `commit_delay` parameter to control this.

### 5.2 Asynchronous vs. Synchronous Commit

Some systems offer a choice between synchronous (fsync on commit) and asynchronous (acknowledge immediately, fsync later) commit. Asynchronous commit gives higher performance but risks losing the last few seconds of transactions on crash. This is common in NoSQL systems like Cassandra or MongoDB (with write concern 0). It's a deliberate trade-off for speed.

### 5.3 WAL in Distributed Systems

In distributed databases, the WAL plays a dual role: durability and replication. For example, in Raft or Paxos-based systems, each node writes to its own WAL. The leader then sends log entries (from its WAL) to followers. Followers append to their own WAL and acknowledge. The entry is considered committed when a majority of nodes have fsynced it. This ensures that even if the leader crashes, the committed entries survive on a quorum of nodes.

Kafka famously uses a distributed commit log. Every message is appended to a partition's log on disk. Consumers read from the log. The log itself is replicated across brokers. The durability guarantee depends on the `acks` configuration: `acks=all` means all in-sync replicas have written to their local log before acknowledging.

### 5.4 WAL Shipping and Continuous Archiving

PostgreSQL supports **WAL shipping**: copying segments of the WAL to a standby server, which can replay them to stay up-to-date. This enables high availability and point-in-time recovery (PITR). By archiving the WAL segments, you can restore the database to any point in time by replaying the archive up to that point.

### 5.5 The WAL and Filesystem Bugs

No discussion of WALs is complete without acknowledging that filesystems and storage hardware are imperfect. fsync doesn't always guarantee durability on all platforms (e.g., some cheap SSDs lie about flushing). To mitigate, databases like PostgreSQL use **full_page_writes**—a safety net that writes the entire page before modifying it, ensuring that a partial page write during a crash doesn't corrupt the page. This is a direct consequence of the underlying storage's write atomicity guarantee (usually 512 bytes, not 8 KB).

---

## 6. Performance and Optimization

Building a WAL that is both fast and safe requires careful tuning:

- **Log buffer**: Instead of writing every record synchronously, buffer records in memory and flush periodically (but still fsync on commit). The log buffer reduces the number of I/O operations.
- **WAL size and recycling**: Use fixed-size segments. When a segment is no longer needed (all its data pages have been checkpointed), it can be recycled or removed.
- **Direct I/O**: Bypass the OS page cache for WAL writes to avoid double caching. PostgreSQL offers `wal_sync_method = open_sync` for this.
- **Compression**: Compress WAL records to reduce I/O volume. Trade-off: CPU cost.
- **Parallel WAL writers**: Some databases allow multiple worker processes to concurrently append to the WAL, using a lock for ordering.

### 6.1 Benchmarking Your WAL

To test your WAL implementation, simulate crashes:

- Write a small random truncation at the end of the log file.
- Corrupt a checksum byte.
- Kill the process before fsync completes.
- Verify that recovery always brings you back to the last consistent state.

---

## 7. Building a Complete Example: A Durable Key-Value Store

Let's combine everything into a simple but functional key-value store with WAL-based durability and recovery. The store will keep data in memory (for speed) and log every `put` operation. On restart, it replays the log. We'll also implement a checkpoint mechanism to truncate the log periodically.

_(Code omitted for brevity but would be provided in full, with explanations, in a real post. Focus here on conceptual clarity.)_

The implementation would include:

- A `Store` class holding a `dict`.
- A `WAL` class with `append`, `checkpoint`, and `recover` methods.
- A `Database` class combining them, with auto-checkpoint after N operations.

The checkpoint method would:

1. Write a `CHECKPOINT_BEGIN` record.
2. Fsync the log.
3. Write a snapshot of the entire store (key-value pairs) to a separate `snapshot.db` file.
4. Write a `CHECKPOINT_END` record.
5. Fsync again.
6. Truncate the WAL.

Recovery then becomes:

1. Load the latest snapshot (if exists) into memory.
2. Open the WAL and replay only records after the `CHECKPOINT_END` record.

This avoids replaying the entire history.

---

## 8. Real-World WAL Implementations

To put everything in perspective, let's peek at how actual databases handle their WALs.

### PostgreSQL (WAL)

- PostgreSQL writes WAL records in 16 MB segments, by default.
- Uses a ring buffer for performance.
- Each segment is named by its timeline and LSN offset.
- Supports `archive_mode` for continuous archiving and replication.
- Full page writes are enabled to protect against partial page writes.
- The `pg_waldump` tool can print WAL contents.

### MySQL InnoDB (Redo Log)

- InnoDB uses a redo log group of files (default `ib_logfile0` and `ib_logfile1`) configured by `innodb_log_group_home_dir`.
- Writes are buffered in the log buffer and flushed on commit.
- Doublewrite buffer protects against partial page writes (writes to a separate area before writing to data files).

### SQLite (WAL mode)

- SQLite's WAL mode is a simple alternative to its default rollback journal. It uses a WAL file to record changes.
- Readers can still read the old database file while the WAL is being applied. A `checkpoint` moves WAL changes back to the main database.
- Excellent for embedded systems.

### Kafka (Commit Log)

- Kafka's log is not a database WAL in the traditional sense, but it serves the same purpose: durable, ordered storage.
- Each partition has a log (sequence of segments). Records are appended and fsynced based on producer configuration.
- Consumers track offsets. The log is periodically compacted or deleted based on retention policies.

---

## 9. Common Pitfalls and Lessons Learned

Over the years, engineers have tripped over these WAL mistakes:

- **Skipping fsync**: "The OS will eventually flush."
  _Lesson:_ fsync is mandatory for durability.
- **Ignoring filesystem cache**: Relying on `write()` without `fsync()`.
  _Lesson:_ A power failure can lose data that's still in the page cache.
- **Not handling partial writes**: Assuming a log write is atomic.
  _Lesson:_ Use checksums and verify record boundaries.
- **Checkpointing too aggressively**: Flushing large amounts of data too often can degrade performance.
  _Lesson:_ Balance checkpoint frequency with recovery time requirements.
- **Reusing log files incorrectly**: Overwriting a segment that might still be needed for recovery of other replicas.
  _Lesson:_ Coordinate log recycling across the cluster.
- **Trusting hardware**: Some SSDs lie about fsync.
  _Lesson:_ Use battery-backed storage or test with power-loss simulators.

---

## Conclusion

We started with a nightmare: a power failure that vaporizes confirmed transactions. We traced the problem to the fundamental latency gap between memory and disk. The solution, the Write-Ahead Log, is a masterpiece of pragmatic engineering: it accepts that we cannot write data pages quickly, but we _can_ write a compact, sequential log very quickly. The WAL sacrifices the need to flush data pages immediately in exchange for a guarantee that no committed change will be lost.

From first principles, we built a minimal WAL, then layered on recovery strategies, checkpoints, group commit, and distributed replication. We saw how every major database, from PostgreSQL to Kafka, relies on the same core ideas: append-only, sequential writes, fsync, LSNs, and checksums.

The WAL is a testament to the power of simple, well-understood abstractions. It is the foundation upon which we build trust in our data systems. Next time you send a wire transfer or post a tweet, remember the quiet, relentless append-before-flush dance happening thousands of times per second inside the database, invisible to the user, but absolutely essential to the integrity of the digital world.

And if you ever need to design a durable system from scratch, you now have the knowledge to build your own WAL from first principles.

---

_Thanks for reading. If you enjoyed this deep dive, consider sharing it with a friend who still thinks `fsync` is optional. And if you have war stories about WAL failures or successes, I'd love to hear them in the comments._
