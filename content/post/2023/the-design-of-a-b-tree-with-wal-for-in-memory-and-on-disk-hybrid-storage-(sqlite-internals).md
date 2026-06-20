---
title: "The Design Of A B Tree With Wal For In Memory And On Disk Hybrid Storage (Sqlite Internals)"
description: "A comprehensive technical exploration of the design of a b tree with wal for in memory and on disk hybrid storage (sqlite internals), covering key concepts, practical implementations, and real-world applications."
date: "2023-10-20"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-design-of-a-b-tree-with-wal-for-in-memory-and-on-disk-hybrid-storage-(sqlite-internals).png"
coverAlt: "Technical visualization representing the design of a b tree with wal for in memory and on disk hybrid storage (sqlite internals)"
---

# The Art of the Middle Ground: How SQLite’s B‑Tree and WAL Defy the “One Size Fits All” Database Trap

_Technical depth, practical examples, and the engineering miracle that powers billions of devices._

---

## Introduction

Imagine you are building a system that must never forget. Every single keystroke, every state change, every transaction must be preserved exactly as it happened, no matter if the power cord gets ripped from the wall at the worst possible moment. This is the domain of the database—the fortress of data durability. Now, imagine that same system must also be as fast as a caffeinated cheetah. Queries must return in microseconds, not milliseconds. Updates must feel instantaneous. This is the domain of the in-memory cache—the reckless, volatile speed demon.

These two worlds—the glacial safety of the disk and the fiery speed of RAM—have historically been enemies. To get one, you generally had to sacrifice the other. We built our systems with a clear, hard wall between them: the disk-based OLTP database for truth and the in-memory cache (like Redis or Memcached) for speed. But what if you could have both in a single, elegant, lightweight file? What if you could design a data structure that lives in the liminal space between the spinning platter and the silicon transistor, moving data back and forth not as a frantic cache-miss fire drill, but as a graceful, predictable, and atomic dance?

This is not a theoretical fancy. It is the exact, brilliant, and often undervalued technical miracle that powers SQLite.

If you have ever used a smartphone, a browser, or virtually any embedded system, you have relied on the decisions made by the SQLite development team regarding this hybrid duality. But most developers treat SQLite as a "black box"—a simple `sqlite3_open` call that somehow "just works" and never crashes (unless you're running on a bad SD card). That simplicity is itself a triumph of engineering.

Yet beneath the surface lies a carefully engineered interplay between two of computer science’s most elegant data structures: the **B‑Tree** (used for persistent, sorted storage) and the **Write-Ahead Log** (WAL) (used for high‑performance, crash‑safe transaction logging). This blog post will pull back the curtain, exploring every detail of how SQLite balances the conflicting demands of durability, performance, concurrency, and simplicity.

---

## 1. The Two Worlds: Disk Durability vs. RAM Speed

### The Fundamental Trade‑off

Data storage devices fall into two broad categories: volatile (RAM) and non‑volatile (disk, SSD, flash). RAM is orders of magnitude faster but loses its content on power loss. Disks and SSDs are slow (relative to CPU clocks) but persistent. A CPU can access a register in about 0.3 nanoseconds; main memory takes ~100 ns; a solid‑state drive (SSD) around 100,000 ns; a mechanical hard drive can take 10,000,000 ns. That’s a factor of **five orders of magnitude** between RAM and HDD.

Database systems must bridge this gap. They must ensure that once a transaction is committed, even a sudden power failure will not lose or corrupt data. That forces writes to reach the storage medium—flushing caches, forcing the disk to commit bits to platter or flash. Those forced writes are the enemy of performance.

### The Classic Architecture: Cache + Database

Most large‑scale systems adopt a tiered approach: a fast in‑memory cache (Redis, Memcached) in front of a slower, durable database (PostgreSQL, MySQL, Oracle). The cache holds hot data; the database holds the ground truth. This works, but it adds complexity: cache invalidation, consistency between cache and database, and the overhead of two separate systems. And for many embedded or client‑side applications, running a separate cache server is impossible.

### The Embedded Alternative

SQLite takes a different path: it is an embedded relational database that lives in a single file on disk, yet it can deliver performance close to that of a memory‑backed system—provided you use the right write‑ahead logging and page‑cache configuration. The magic happens not through separate layers, but through a single, well‑orchestrated data structure: the **B‑Tree** combined with a **WAL**.

---

## 2. The Database Dilemma: ACID vs. Performance

### ACID Properties

A database that never loses data must satisfy the **ACID** properties:

- **Atomicity**: Each transaction is all‑or‑nothing.
- **Consistency**: Transactions leave the database in a valid state.
- **Isolation**: Concurrent transactions do not interfere.
- **Durability**: Once committed, the transaction survives crashes.

Durability is the most costly. To guarantee a write survives a power loss, the operating system must flush write buffers to the actual storage medium (e.g., via `fsync()` or `sync()`). A single `fsync()` can take tens of milliseconds. If every INSERT or UPDATE requires an `fsync()`, throughput plummets.

### The Need for a Write-Ahead Log

A common technique to amortize the cost of `fsync()` is to use a **Write-Ahead Log** (WAL). Instead of writing directly to the main database file, modifications are appended to a sequential log file. Because appending is sequential (and thus much faster than random writes), and because the log can be flushed less frequently, performance improves dramatically. Meanwhile, the actual database file is updated later, in a process called **checkpointing**.

SQLite’s WAL is the star of this show. Before version 3.7.0 (2010), SQLite used a simpler **rollback journal** approach that required copying pages before modification, which hurt concurrent reads. The WAL mode changed everything.

---

## 3. SQLite’s Design Philosophy: Embedded, Zero-Configuration, Serverless

Before diving into the B‑Tree and WAL, it is important to understand the constraints that shaped SQLite’s design.

- **Embedded**: SQLite is not a client‑server engine. It runs in the same process as your application. No network overhead, no authentication, no separate process.
- **Zero‑configuration**: There is no configuration file, no tuning parameters (well, there are pragmas, but defaults work for most cases). You just open a file.
- **Serverless**: No separate database server process. This reduces complexity, but it also means SQLite must handle its own locking, caching, and concurrency without help from an external daemon.
- **Single‑file database**: Everything—tables, indexes, schemas, data—lives in one ordinary file. This makes backup and portability trivial.

Because SQLite is embedded, it must be extremely robust. It cannot assume a high‑end server with battery‑backed RAID controllers. It must work on cheap SD cards, flash drives, and old spinning hard drives. It must handle abrupt power loss at any microsecond. That is why the B‑Tree and WAL are designed with rigorous crash safety.

---

## 4. The B‑Tree: The Core Data Structure of SQLite

### Anatomy of a B‑Tree

A B‑Tree is a balanced tree data structure that keeps data sorted and allows searches, insertions, deletions, and sequential access in logarithmic time. SQLite uses a **B+Tree** variant: all actual data is stored in leaf nodes, while internal nodes store keys used for routing.

Each node in SQLite’s tree corresponds to a **page** on disk. The default page size is 4096 bytes (adjustable from 512 to 65536). The page is the unit of I/O: SQLite reads or writes whole pages.

#### Page Types

- **Internal pages**: Contain a header and an array of pointers (page numbers) and separator keys. The number of keys per page is limited by page size.
- **Leaf pages**: Contain the actual row data. In SQLite’s table B‑Tree, leaves store complete rows; in index B‑Trees, leaves store the key and a pointer to the table row (rowid).
- **Overflow pages**: When a single row (or BLOB) exceeds the page size, additional pages are linked as overflow.

### Page Header Structure

Every page begins with a 8‑byte header (for table leaf pages) or a 100‑byte header for the first page (page 1, which holds the database header). The header includes:

- The database page size.
- The file change counter.
- The schema format version.
- The page number of the root page of each B‑Tree.

The rest of the page uses a **cell array**: a sorted list of variable‑length cells. Each cell contains the key (rowid) and the data (for leaves) or the key and a child page pointer (for internals).

### Balancing and Splitting

When a new row is inserted, SQLite traverses the tree from root to leaf. At the leaf, it inserts the row in sorted order. If the leaf page is full, it splits into two pages, distributing the rows. This split may propagate up the tree, possibly increasing tree height. Because B‑Trees are balanced, the height grows very slowly: a 4096‑byte page can hold hundreds of keys, so a database with billions of rows has a tree height of only 3 or 4.

#### Example: Inserting into a Table B‑Tree

Consider a table with an integer primary key (the rowid). Suppose we have three pages: root and two leaves. The root page (internal) has two keys: 500 and 1000. It points to leaves L1 (rows 1–500) and L2 (rows 501–1000). Now we insert rowid 600.

1. Traverse: root sees 600 > 500, so go to child pointer to L1? Wait, careful: internal node keys are separators. The key 500 in the root means all rows ≤500 go to left child, rows >500 go to right child. So rowid 600 goes to right child (L2).
2. Insert into L2. If L2 is not full, just place the new row in sorted order.
3. If L2 is full, split: create a new page L2b, redistribute rows, and add a new separator key (say 750) to the root. The root may then split, etc.

This process ensures the tree stays balanced.

### B‑Tree Variants: SQLite’s B+Tree

SQLite’s B‑Tree is actually a B+Tree: only leaf nodes contain data; internal nodes hold keys and pointers. This allows internal nodes to hold many keys (since no data), reducing height. Additionally, leaf nodes are linked together in a forward (and sometimes backward) direction to support fast range scans (e.g., `BETWEEN`, `ORDER BY`). That linked list is implemented via a “next leaf page” pointer stored in the leaf page header.

### B‑Tree Operations and Crash Safety

Writing to a B‑Tree directly on disk is risky: if the power fails while writing a page, you could get a half‑written page with a mix of old and new data. SQLite solves this with the **journal** (rollback or WAL) and with atomic writes (e.g., using `fallocate` with overwrite, or rollback). With WAL, the B‑Tree is never modified in place during a transaction; only the WAL is appended to. This is the key to crash safety.

---

## 5. The Write-Ahead Log (WAL): Bridging the Gap

### How WAL Works

In WAL mode, instead of writing modifications directly to the main database file, SQLite appends them to a separate file, the `.db-wal`. Each entry in the WAL is a frame that contains:

- A page number.
- The new content of that page.
- A commit record indicating the transaction committed.

The main database file remains unchanged during the transaction. Readers see a consistent snapshot by looking at both the database file and the WAL. When they need a page, they first check the WAL for that page; if found, they use the WAL version; otherwise, they use the database file version.

#### The WAL Format (Simplified)

```
| Page_Number | Page_Data (4096 bytes) | Checksum |
| Page_Number | Page_Data (4096 bytes) | Checksum |
...
| Commit_Record (magic number, transaction ID) |
```

The WAL grows as modifications accumulate. Periodically, SQLite **checkpoints** the WAL: it merges all pending changes into the main database file and truncates the WAL. The checkpoint can be automatic (triggered by a threshold) or manual (`PRAGMA wal_checkpoint`).

### WAL vs. Traditional Rollback Journal

Before WAL (pre‑3.7.0), SQLite used a **rollback journal** (`-journal`). The mechanism:

1. Before modifying a page, SQLite copies the original page to the journal.
2. Then it modifies the page in the database file.
3. On commit, the journal is deleted.
4. If crash occurs before commit, the journal is used to roll back partial changes.

This approach had a major drawback: **writers block readers**. During a write transaction, the database is locked exclusively. So no reads can happen concurrently. WAL mode, on the other hand, allows multiple readers to read while a single writer writes (the writer appends to the WAL). This is a huge win for concurrency.

#### Performance Comparison

| Aspect              | Rollback Journal               | WAL                                   |
| ------------------- | ------------------------------ | ------------------------------------- |
| Write throughput    | Slower (writes to db directly) | Faster (sequential append)            |
| Read concurrency    | None during write              | Multiple readers allowed              |
| Memory usage        | Low                            | Slightly higher (WAL frames in cache) |
| Write amplification | Moderate (need to copy pages)  | Low (append only)                     |
| Recovery on crash   | Replay journal → roll back     | Rebuild from WAL → roll forward       |

### Checkpointing

The checkpoint operation is when the WAL is merged into the main database. SQLite offers three checkpoint modes:

- **Passive**: Wait for all readers to finish, then checkpoint. Non‑blocking but can be delayed.
- **Full**: Checkpoint immediately, blocking new readers.
- **Restart**: Same as full, plus truncate the WAL.

Checkpointing is a critical operation: it prevents the WAL from growing indefinitely. In high‑write scenarios, an aggressive checkpoint policy can improve performance (by keeping the WAL small) but at the cost of occasional pauses when the checkpoint runs.

#### Example: Setting Checkpoint Mode

```sql
PRAGMA journal_mode=WAL;
PRAGMA wal_autocheckpoint=1000;  -- pages
```

### Concurrency with WAL

The WAL mode allows:

- **Multiple concurrent readers** at all times. Each reader sees a consistent snapshot based on the WAL state at the time the read began.
- **One writer at a time**. While a writer is appending to the WAL, readers can still access the database (they see older snapshots). The writer must wait for no other writer, but readers do not block the writer.
- **No readers block writers**, and no writers block readers (except during checkpoint in full/restart mode).

This is a revolutionary improvement over the rollback journal, making SQLite usable for more complex applications with heavy read concurrency (e.g., web browsers, mobile apps).

---

## 6. The Hybrid Dance: B‑Tree + WAL in Practice

### Atomic Commit

How does SQLite achieve atomicity in WAL mode? The key is the **commit record**. After all changes are appended to the WAL, SQLite flushes and fsyncs the WAL (if `PRAGMA synchronous=FULL`), then writes a commit record. The commit record marks the transaction as committed. If a crash occurs before the commit record, the transaction is ignored. If after, it is replayed during recovery.

Because the WAL is append‑only, the commit record is always written after the data frames. The database itself is untouched until checkpoint. So atomicity is guaranteed by the sequential nature of the WAL and the crash‑safe write of the commit record (which is a small, atomic write if the page size is large enough, but SQLite uses a separate checksum and magic value to detect incomplete writes).

### Crash Recovery

When SQLite opens a database with a WAL, it performs recovery if the WAL is present:

1. Read the WAL from beginning to end.
2. Verify checksums.
3. Identify committed transactions (by commit records).
4. Replay these changes into a new version of the database (to be used for subsequent reads).
5. Optionally checkpoint.

Recovery is fast because it’s just scanning and replaying a sequential log.

### Performance Characteristics

The performance of SQLite in WAL mode is impressive for an embedded database:

- **Read throughput** is limited only by disk I/O and cache. With `PRAGMA mmap_size=...`, you can memory‑map the database file, turning reads into simple memory accesses.
- **Write throughput** is bottlenecked by the speed of appending to the WAL and the checkpoint frequency. In many mobile apps, writes are small and infrequent, so WAL mode feels instantaneous.
- **WAL growth**: In heavy write workloads, the WAL can grow large (hundreds of MB) if checkpoints are not triggered often enough. The default threshold is 1000 pages (~4 MB), which is fine for most applications.

#### Benchmark Example: Inserting 1 Million Rows

On a modern SSD, using SQLite with WAL mode and synchronous=FULL, inserting 1 million rows in a single transaction (batch insert) takes a few seconds. With synchronous=OFF (risk of data loss on crash), it can be sub‑second. Compare to rollback journal mode: batch insert takes 2–3x longer due to page copy overhead.

---

## 7. Advanced Topics: Concurrency, Locking, and Performance Tuning

### SQLite’s Locking Model

SQLite uses a variety of locks to control concurrent access to the database file. Even in WAL mode, there is a lightweight locking protocol.

The locks are:

- **NONE**: No lock held.
- **SHARED**: Allows reading. Multiple readers can hold SHARED locks.
- **RESERVED**: Allows a writer to prepare (read pages, plan modifications) but not yet write to the file. Multiple RESERVED locks can coexist with SHARED.
- **PENDING**: Writer waiting to upgrade to EXCLUSIVE. Prevents new SHARED locks.
- **EXCLUSIVE**: Exclusive write lock. No other reader or writer. Only one writer at a time.

In WAL mode, the EXCLUSIVE lock is only needed during checkpoint (in full/restart modes) and during commit‑time operation. Readers only require SHARED. This reduces lock contention.

### WAL Mode: Improved Concurrency

Because readers do not block writers, and vice versa, applications see much better concurrency. For example, a web browser’s SQLite‑backed cookie store can be read by multiple tabs while a background timer updates the database, all without serialization.

### Synchronous Flags

The `PRAGMA synchronous` setting controls the durability‑vs‑performance trade‑off.

- **FULL** (default): Issues an fsync after every commit. Guarantees that even on power loss, the transaction is durable. The WAL is flushed to disk before the commit record.
- **NORMAL**: Issues an fsync only at critical points (e.g., before checkpoint). With NORMAL, a power loss could cause a transaction to be rolled back but not corrupt the database.
- **OFF**: No fsyncs at all. The operating system may buffer writes for seconds. A power loss could lose committed transactions or even corrupt the database. Only use this for temporary or read‑only databases.

#### Example: Setting Synchronous for Performance

```sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
```

This combination gives good performance with a good safety profile. Most embedded devices use NORMAL.

### Memory‑Mapped I/O (mmap)

SQLite can map the database file directly into the process’s virtual memory using `PRAGMA mmap_size`. When enabled, SQLite reads pages via memory loads rather than explicit `pread()` syscalls. The OS handles paging and caching. This dramatically reduces read latency.

However, writes still go through the WAL and must be flushed to disk. mmap is used only for reading.

#### Example: Enabling mmap

```c
sqlite3_exec(db, "PRAGMA mmap_size=268435456", 0, 0, 0);  // 256 MB
```

---

## 8. Real-World Examples: Use Cases and Benchmarks

### Embedded Systems (IoT, Mobile)

SQLite is the default storage engine for Android and iOS. Every app that stores structured data uses SQLite under the hood. In IoT devices (smart home hubs, sensors), SQLite provides a reliable ACID‑compliant storage in a tiny footprint (~600 KB compiled size). The WAL mode allows a sensor to write temperature readings while the user interface reads the latest data, all without locking.

### High-Availability Scenarios: Unexpected Power Loss

Consider a GPS tracker running on a battery‑powered device. The device writes a position every second. Say the battery dies mid‑write. With WAL mode and synchronous=FULL, the last transaction is either entirely recorded (if the WAL had been flushed) or entirely discarded. The database remains consistent. With rollback journal, there is a risk of partial page writes.

SQLite has been extensively tested under power failure (by using fault injection). The developers estimate that the probability of database corruption in WAL mode is far lower than the rate of hardware failures.

### Comparison with Other Embedded DBs

| Feature             | SQLite (WAL)             | LevelDB              | RocksDB                | LMDB                            |
| ------------------- | ------------------------ | -------------------- | ---------------------- | ------------------------------- |
| Transaction support | Full ACID                | Single‑put atomicity | Multi‑key transactions | Multi‑key transactions (MVCC)   |
| Concurrency         | Many readers, one writer | Simple (one writer)  | Multiple writers       | Many readers, one writer (MVCC) |
| Performance         | Excellent for read‑heavy | Excellent for writes | Excellent for writes   | Excellent for reads             |
| Disk format         | Single file + WAL        | Multiple SST files   | Multiple SST files     | Single file (mmap)              |
| Complexity          | Simple API               | No SQL               | No SQL                 | No SQL                          |

For applications that need SQL, ACID, and simplicity, SQLite is the clear choice. For massive write throughput (hundreds of thousands of writes per second), RocksDB or LevelDB may be better. For read‑only or read‑mostly workloads with extreme speed, LMDB is attractive.

### Benchmark: SQLite vs. Redis (Using Disk Persistence)

A common misconception is that Redis (with AOF or RDB persistence) is always faster than SQLite. While Redis is far faster for in‑memory operations, its disk persistence options are less robust. For example, Redis’s AOF sync policy `everysec` loses at most one second of data on crash; SQLite’s WAL with synchronous=FULL loses nothing. In terms of raw throughput, for simple key‑value patterns, SQLite with WAL can achieve 100k writes/second on an SSD, which is competitive with many use cases.

---

## 9. The Engineering Miracle: Why SQLite’s Approach Matters

The B‑Tree and WAL combination is not unique to SQLite—many databases use similar methods. What makes SQLite special is the extreme **engineering** and **testing** that go into making these structures work reliably on unreliable hardware.

- **Meticulous crash testing**: The SQLite developers test with simulated power loss (e.g., using `faultsim`), injecting I/O errors, crashes at every instruction, and filesystem corruption. They have published the results of million‑test runs.
- **Portability**: SQLite runs on every major OS, from ancient Unix to modern embedded RTOS. The WAL and B‑Tree code is pure C and highly portable.
- **Minimal dependencies**: No external libraries, no threads, no complex build system.

### The Unseen: The Page Cache

An often‑overlooked component is the **page cache**. When SQLite reads a page (either from the database file or from the WAL), it stores it in an LRU cache. Subsequent accesses are served from memory. The cache size is controlled by `PRAGMA cache_size`. In WAL mode, the cache holds both database pages and WAL frames. The interplay between the cache, the WAL, and checkpointing is where the performance magic happens.

Without the cache, every query would involve a disk read. With a cache of, say, 2000 pages (default for 4096‑byte pages = 8 MB), a table of 100,000 rows might fit entirely in memory. Reads become instant.

---

## 10. Conclusion: The Art of the Middle Ground

SQLite demonstrates that you do not need separate layers for speed and safety. By combining a B‑Tree for sorted, persistent storage with a Write-Ahead Log for high‑performance, atomic writes, SQLite achieves a balance that is close to ideal for embedded and client‑side applications.

The B‑Tree provides:

- Logarithmic search and update times.
- Sorted output for range queries.
- A compact, page‑oriented disk format.

The WAL provides:

- Append‑only writes for high throughput.
- Non‑blocking readers for concurrency.
- Crash safety through replayable logs.

Together, they form a system that “just works” for billions of devices. The next time you run a query on your phone, remember the intricate dance happening inside that tiny `.db` file—a dance that defies the old dichotomy between disk and RAM.

---

### Further Reading

- SQLite Documentation: <https://sqlite.org/atomiccommit.html> (an excellent discussion of atomic commit)
- D. Richard Hipp, “SQLite: Architecture and Design” (talks available on YouTube)
- “The B‑Tree and its Variants” – traditional textbooks (Korth, Silberschatz)

---

_Thank you for reading. If you found this deep dive helpful, share it with a fellow engineer. The art of the middle ground is worth celebrating._
