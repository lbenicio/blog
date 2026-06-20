---
title: "Building A Distributed Log Structured Storage Engine: Wiredtiger’S B Tree And Concurrency Control"
description: "A comprehensive technical exploration of building a distributed log structured storage engine: wiredtiger’s b tree and concurrency control, covering key concepts, practical implementations, and real-world applications."
date: "2021-06-19"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/building-a-distributed-log-structured-storage-engine-wiredtiger’s-b-tree-and-concurrency-control.png"
coverAlt: "Technical visualization representing building a distributed log structured storage engine: wiredtiger’s b tree and concurrency control"
---

# WiredTiger: The Storage Engine That Refuses to Choose Between B‑Trees and LSM Trees

**Word count target: 10,000+ words**  
_Tone: Technical, accessible to experienced engineers, with real‑world examples and architectural depth._

---

## Introduction: When the Database Doesn’t Just “Work”

The first time you hit a write‑heavy OLTP workload at scale—thousands of concurrent clients, each issuing inserts, updates, and deletes to a distributed document store—you quickly realize that the database won’t just _work_. The bottleneck isn’t the network or the CPU. It’s the storage engine. Traditional B‑trees, designed when disk was the only memory hierarchy and reads far outnumbered writes, choke under write amplification. The common alternative, a Log‑Structured Merge‑tree (LSM), solves write amplification but sacrifices read performance and introduces compaction storms that cascade into unpredictable latency.

Then along came WiredTiger.

Chosen by MongoDB as its default storage engine in version 3.2, WiredTiger doesn’t commit to either extreme. Instead, it architecturally _fuses_ a B‑tree with a log‑structured storage model, layering a sophisticated concurrency control mechanism that can support millions of transactions per second without sacrificing durability or isolation. This hybrid design is the engine behind one of the most widely deployed NoSQL systems in the world. Understanding how it works is not merely an academic exercise—it is a blueprint for anyone who builds, operates, or optimizes modern distributed storage infrastructure.

But why should you care about a single storage engine when the space is filled with RocksDB, LevelDB, LMDB, and others? Because WiredTiger’s choices represent a fundamental rethinking of the age‑old trade‑offs between read performance, write throughput, and concurrency. And because MongoDB’s scale—billions of documents, thousands of shards, global replication—forces WiredTiger to handle edge cases that would break a simpler design.

Consider a typical MongoDB deployment: a sharded cluster running on commodity hardware, handling real‑time analytics, session stores, or operational backends. Under the hood, each mongod process manages its own WiredTiger cache, its own write‑ahead log, and its own background eviction threads. The storage engine must deliver consistent single‑digit millisecond latencies for point reads, sustain tens of thousands of writes per second, and survive abrupt crashes—all while maintaining ACID transactions across multiple documents. No single data structure can do all of that without compromise. WiredTiger’s answer is to combine the best of two worlds, but to do so it had to invent new mechanisms for concurrency, memory management, and on‑disk layout.

In this deep dive, we’ll explore every layer of WiredTiger: from the page‑level structure on disk, through the transactional concurrency control, to the checkpoint and eviction subsystems that keep the tree healthy. We’ll compare it directly with the two dominant storage engine families—classic B‑trees (InnoDB, etc.) and LSM trees (RocksDB, LevelDB)—to understand where each shines and where it suffers. We’ll also examine real‑world performance patterns and tuning knobs that operators use to squeeze the most out of WiredTiger. By the end, you’ll have a mental model not just of one engine, but of the fundamental trade‑offs that every storage system must navigate.

---

## 1. The Tension Between B‑Trees and LSM Trees

To appreciate WiredTiger’s architecture, we first need to recall why the storage engine landscape is dominated by two families: B‑trees and LSM trees. Both are well‑proven, but they occupy opposite ends of a spectrum defined by write amplification, read performance, and space amplification. Let’s examine each in detail.

### 1.1 Classic B‑Trees: Optimized for Reads, Punished by Writes

A classic B‑tree stores data in fixed‑size pages (typically 4–16 KB) and updates them **in place**. When you insert a new row or modify an existing one, the database locates the page containing the relevant key, reads it into memory, modifies it, and writes it back. If the page is full, a split occurs, redistributing keys across two or three pages and updating parent pointers. Reads, both point lookups and range scans, are logarithmic in the number of keys and benefit from high fan‑out: a B‑tree with 4 KB pages and 1 KB keys can have hundreds of entries per internal node, so a tree storing billions of keys is only three or four levels deep.

**Write amplification** is the hidden cost. Every update to a single row forces a full page rewrite—even if only one byte changes. That’s a write amplification factor of 4–16 (writes to storage per logical write). Moreover, page splits cascade upward, causing writes to multiple levels. For a write‑heavy workload, the B‑tree’s I/O pattern becomes random: because pages are scattered across disk, each logical write may require a separate disk seek. On spinning media this is catastrophic; on SSDs it’s still expensive due to write endurance and internal flash translation layer (FTL) overhead.

B‑trees also struggle with **concurrent updates**. Traditional implementations use page‑level locking, which creates contention on hot pages (e.g., the last page of an index for monotonically increasing keys). To mitigate this, databases like MySQL InnoDB use “adaptive hash indexes” and page‑level latches, but the fundamental serialization remains a bottleneck.

**Durability** requires a write‑ahead log (WAL) because pages are cached in memory and written back lazily. On crash, the WAL replays committed transactions. This adds another layer of write amplification and complexity.

Despite these drawbacks, B‑trees dominate in read‑heavy workloads and systems where predictable performance is critical. Their read path is simple: traverse a tree of pointers, read each page sequentially. There is no background compaction to stall queries.

### 1.2 LSM Trees: Swimming in Writes, Drowning in Reads

LSM trees, popularized by Bigtable and later by LevelDB, RocksDB, and Cassandra, take the opposite approach. Instead of updating in place, they **append** all mutations to a rolling set of sorted files (SSTables). A write becomes a sequential log append (to a write‑ahead log) and an insert into an in‑memory sorted structure (the memtable). Periodically, the memtable is flushed to disk as an immutable SSTable. Over time, multiple SSTables accumulate, and a background compaction process merges them into larger, sorted runs, discarding obsolete versions.

**Write amplification is dramatically reduced** in the steady state—a single row update may be written only once to the WAL and once to the memtable, then later rewritten during compaction. However, compaction itself is the double‑edged sword. To maintain a small number of sorted runs (and thus acceptable read performance), LSM trees must continuously merge overlapping SSTables. In a write‑heavy workload, compaction can consume 50–80% of total I/O bandwidth. Worse, it happens in bursts: when compaction falls behind, the number of SSTables grows, increasing read amplification. A “compaction storm” can cause latency spikes of seconds.

**Read performance** suffers because a point lookup must check multiple SSTables (and the memtable) until it finds the latest version. Bloom filters help prune unnecessary searches, but range scans are particularly expensive: each SSTable may contain overlapping key ranges, requiring merges from multiple sources. Reads also compete with compaction for I/O and CPU.

**Space amplification** is another concern: obsolete versions are not removed until compaction merges them away, so the database can temporarily use 2–3× the logical data size.

### 1.3 The Fundamental Trade‑Off

Classic B‑trees optimize reads at the cost of writes; LSM trees optimize writes at the cost of reads (and background compaction). Both suffer from amplification—write amplification in B‑trees, read amplification in LSMs. Neither is clearly superior for all workloads. The industry has long sought a hybrid that can approach the read performance of a B‑tree while maintaining the write throughput of an LSM tree—without the compaction storms.

Enter WiredTiger. Its creators, led by Michael Cahill and Alex Gorrod (formerly of Berkeley DB), decided that the way forward was not to pick a side but to _merge_ the two models. They would build a B‑tree on top of a log‑structured storage layer, using copy‑on‑write, multiversion concurrency control, and a novel checkpointing scheme to eliminate in‑place updates while still providing a single‑tree read path.

---

## 2. WiredTiger’s Hybrid Architecture: B‑Tree + Log‑Structured Under the Hood

WiredTiger calls its primary data structure a **Btree**—but that name is deceptive. Superficially, it looks like a balanced tree with pages containing sorted key‑value pairs. Internally, however, it operates in a fundamentally different way: **pages are never modified in place**. Instead, every modification creates a new version of the page (or a delta record), and the old version becomes garbage to be reclaimed later. This is a **copy‑on‑write (CoW) B‑tree**, and it is the essence of the hybrid.

### 2.1 Logical Tree, Immutable Pages, and the Checkpoint Cycle

Consider a WiredTiger Btree at rest on disk. It consists of a root page, internal pages, and leaf pages. All pages are of fixed size (default 4 KB for leaf pages, 8 KB for internal pages, but configurable). The tree is fully persistent: at any moment, there is a consistent snapshot on disk, and all updates since that snapshot are in memory (either as modifications to cached pages or as entries in the WAL).

When a write transaction commits, WiredTiger does **not** write the modified page back to its original disk location. Instead, it marks the in‑memory page as “dirty” and logs the change to the WAL. Later, during a **checkpoint**, the entire dirty portion of the tree is written to new disk locations. The old pages become unreachable (except for recovery) and are eventually reused.

This checkpoint‑based approach is the log‑structured half of the hybrid. By batching all writes into periodic checkpoints, WiredTiger converts random writes into sequential writes—at checkpoint time, it writes new pages contiguously, similar to how an LSM tree flushes memtables. During normal operation, writes are logged sequentially to a circular WAL. The result is that **write amplification is significantly lower than a classic in‑place B‑tree** because pages are not rewritten until a checkpoint, and even then only those that changed.

But unlike an LSM tree, there is only **one** tree on disk. Reads never need to consult multiple SSTables. The checkpoint snapshot is a single, consistent view of the data at a point in time. To serve reads, a thread simply traverses a single B‑tree (starting at the root, which points to the latest checkpoint). If the requested page is in the cache, it is used; if not, it is read from disk. No merging of multiple runs, no Bloom filters, no range‑compaction interaction. This is the B‑tree half: read path simplicity and efficiency.

### 2.2 The Role of the Write‑Ahead Log (WAL)

WiredTiger’s WAL is a separate component, stored as a set of fixed‑size log files (typically 100 MB each) on disk. Every committed write transaction appends a record to the WAL before the transaction returns success. This is mandatory for durability, because the tree on disk might be a checkpoint from minutes ago. The WAL is truncated only when a checkpoint completes—i.e., when all committed transactions up to that point have been written to a new checkpoint file, the log files that are no longer needed are deleted.

The WAL is also used for crash recovery. On restart, WiredTiger reads the most recent checkpoint file (which describes the root page of the tree at that checkpoint) and then replays the WAL from the checkpoint time forward to restore the in‑memory state.

This design is similar to an LSM tree’s WAL, but with a crucial difference: because the checkpoint is a full, consistent tree (not a set of sorted runs), recovery is faster. There is no need to replay and merge multiple flushes. WiredTiger’s recovery simply replays log records in order and then applies them to the in‑memory tree.

### 2.3 In‑Memory Pages and Delta Records

Between checkpoints, pages are modified in memory. But instead of replacing the entire page content, WiredTiger stores a list of **delta records** attached to each page. A delta record represents a single operation (insert, update, delete) on a specific key within that page. When a read comes in for a key that resides in a page that is in cache, the thread checks the delta list (in reverse chronological order) and finds the latest version. If the page is evicted before the next checkpoint, it must be “reconciled”: the delta records are merged with the original page content to produce a new, compact page that is written to disk during the next checkpoint. This is analogous to an LSM compaction, but it happens only at the page level and only when necessary.

The benefit of delta records is that multiple writes to the same page can be accumulated without rewriting the page. For example, consider a document store where many users update a small sub‑document (e.g., increment a counter). Each update adds a delta to the same leaf page. Without deltas, each update would require reading the page, deserializing, modifying, and queuing a full page write. With deltas, the page data is left untouched, and only a few bytes per update are recorded. This dramatically reduces write amplification for workloads that exhibit write locality.

However, delta records consume memory. A page with many deltas becomes bloated and slows down reads (because the delta chain must be traversed). Therefore, WiredTiger enforces a **page‑eviction** policy that reconciles pages when the number of deltas or the total page size exceeds a threshold.

### 2.4 Checkpointing as the Heart of Durability and Consistency

WiredTiger checkpoints are **fuzzy**: they do not need to pause writes. The engine takes a snapshot of the tree by recording the root page pointer, then writes all dirty pages that were part of that snapshot to disk. While the checkpoint is in progress, new writes continue to modify pages in memory, creating a new version of the tree that diverges from the checkpoint snapshot. To handle this, WiredTiger uses a snapshot isolation mechanism: each checkpoint starts by noting the current transaction ID, and any modifications with a higher transaction ID are excluded from the checkpoint.

The checkpoint process writes pages in a specific order: leaf pages first, then internal pages, then the root page. If a crash occurs during checkpoint, the tree remains in the state of the previous checkpoint (which is always consistent). The partially written checkpoint is simply discarded on recovery.

Checkpoints are also used to reclaim space from the WAL. After a successful checkpoint, the engine can remove all log records that are older than the checkpoint’s transaction ID, because those changes are now fully reflected in the tree on disk.

An important tuning parameter is `checkpoint=(wait=<seconds>)`. A shorter interval means less log replay on recovery but more checkpoint I/O. A longer interval reduces checkpoint overhead but increases the amount of data lost on crash (if not using journaling) and extends recovery time. In MongoDB, the default checkpoint interval is 60 seconds, which strikes a balance for most workloads.

---

## 3. On‑Disk Format: Pages, Cells, and Data Stores

WiredTiger supports two storage formats: **row‑store** (also called key‑value store) and **column‑store** (for aggregations and analytics). In this section, we focus on row‑store, which is the default for MongoDB document storage.

### 3.1 Page Structure

Every page in WiredTiger is a serialized block of bytes with a header and a set of **cells**. A cell is the smallest unit of storage, representing either a key, a value, or a key‑value pair. For internal pages, each cell contains a key (the separator) and a page reference (a pointer to a child page). For leaf pages, each cell contains a key and a value (the actual document or a portion thereof).

Pages are stored in a format that allows binary search within the page. Keys are compared using a configurable collator (default is lexicographic byte‑wise comparison). To speed up searches, WiredTiger also stores a small **prefix‑compression** block that remembers common prefixes among consecutive keys—similar to a prefix B‑tree but applied at the page level.

### 3.2 Data Stores: How MongoDB Documents Map to WiredTiger Rows

When MongoDB uses WiredTiger, each document is stored as a row in a WiredTiger table. The key is a compound of the collection’s namespace plus the document’s `_id`. For secondary indexes, MongoDB creates additional WiredTiger tables where the key is the indexed field value(s) and the value is a pointer (or the primary key). This separation is important: WiredTiger itself knows nothing about MongoDB’s document model; it sees only arbitrary binary keys and values.

Internally, WiredTiger organizes tables in a **Btree** per table. Each table has its own tree, its own cache allocation, and its own checkpoint cycle. This isolation allows MongoDB to manage multiple collections and indexes independently, and it enables fine‑grained concurrency: operations on different tables do not contend on the same B‑tree pages.

### 3.3 Column‑Store Tables

In addition to row‑store, WiredTiger offers a **column‑store** format where each column is stored in a separate array. This is used by MongoDB’s aggregation pipeline for operations that touch only a few fields, reducing I/O. The column‑store uses a different page format optimized for fixed‑width values and projection scans. However, the same core principles (copy‑on‑write, checkpoints, MVCC) apply.

---

## 4. Concurrency Control: MVCC, Locks, and Snapshot Isolation

WiredTiger is designed for high concurrency. It supports **multiversion concurrency control (MVCC)** to allow readers and writers not to block each other. Every modification creates a new version of the data (a delta record or a new page), and each reader sees a consistent snapshot based on a transaction ID.

### 4.1 Transaction IDs and Snapshots

Each transaction in WiredTiger is assigned a monotonically increasing transaction ID (TxnID) when it starts. Upon commit, the transaction’s changes become visible to later transactions. WiredTiger implements **snapshot isolation**: a transaction sees the state of the database as of the moment its snapshot was taken (typically at the first operation of the transaction). It does not see uncommitted changes from other transactions, nor does it see changes committed after its snapshot.

Snapshots are lightweight: they are just a copy of the current global “snapshot array” that contains the set of active (in‑progress) transaction IDs. A read operation compares the version of each cell (which records the TxnID of the transaction that created it) against the snapshot: only versions with a TxnID that is older than all active IDs are visible.

This is similar to PostgreSQL’s MVCC, but WiredTiger pushes the version information into the page cells themselves. Each cell stores the transaction ID and a commit timestamp (or a flag for aborted transactions). For delta records, the delta itself carries the TxnID.

### 4.2 Read‑Your‑Writes and Causal Consistency

Because readers can see their own writes (the transaction’s own uncommitted changes), WiredTiger supports read‑your‑writes consistency within a transaction. This is critical for MongoDB’s retryable writes and transactions.

### 4.3 Locking: Row‑Level vs. Page‑Level

WiredTiger uses **row‑level locking** for writes, but it implements it through a combination of page‑level latches and transaction‑level conflict detection. Here’s how it works:

- **Page latches** (mutexes) protect the internal consistency of a page (e.g., when adding a delta record). These are held for very short durations (microseconds).
- **Write locks** are recorded in a global lock manager, but WiredTiger uses a **lock‑free** protocol for many operations. Instead of acquiring a heavyweight lock on a key, it checks for conflicts at commit time using a “commit dependency” mechanism. If two concurrent transactions modify the same key, one will be aborted (or wait) when the conflict is detected. This is similar to an optimistic concurrency control (OCC) scheme.

Because the B‑tree pages are immutable between checkpoints (except for delta records), writes to different keys on the same page do not block each other at the page level—they simply append deltas. This dramatically reduces contention compared to in‑place B‑trees, where any write to a page requires an exclusive page latch.

### 4.4 Commit and Durability Options

WiredTiger allows configuring the durability guarantee per transaction. In MongoDB, the default is `writeConcern: majority`, which writes to the journal and waits for acknowledgment from the majority of replica set members. At the storage engine level, WiredTiger offers:

- **No sync**: The WAL is written but not flushed to disk. The transaction commits as soon as the log record is in the OS buffer. (Fast, but unsafe on crash.)
- **Fsync**: The WAL is flushed to disk before the commit returns. (Safe, but slower.)
- **Group commit**: Multiple transactions’ log records are batched and flushed together, improving throughput.

MongoDB uses group commit by default, with a sync interval of 100 ms (configurable).

---

## 5. Eviction and Reconciliation: Keeping the Cache Healthy

WiredTiger’s in‑memory cache is the key to performance. It stores recently accessed pages, plus delta records for dirty pages. The cache size defaults to 50% of physical RAM (capped at 256 GB), but is configurable in MongoDB via `wiredTigerCacheSizeGB`.

### 5.1 Eviction Policy

WiredTiger uses a **least‑recently‑used (LRU)** like algorithm, but with special handling for dirty pages. When the cache usage exceeds a high‑watermark (default 80%), a background eviction thread begins to evict clean pages (i.e., pages that have been flushed to disk in the most recent checkpoint). Dirty pages are only evicted when they have been reconciled and written to disk.

The eviction thread also prioritizes pages that are “cold,” meaning they haven’t been accessed recently. However, WiredTiger implements a technique called **hazard pointers** to prevent a page from being freed while it is still in use by a reader thread. Hazard pointers are a lock‑free memory reclamation scheme borrowed from concurrent data structure research.

### 5.2 Reconciliation: From Dirty Pages to Disk

When a dirty page is evicted (or when the checkpoint happens), it must be **reconciled**: the delta records are merged with the original page data to produce a new, self‑contained page. This process is expensive, because it involves deserializing the original page, applying all deltas in order, and serializing a new page. To amortize this cost, WiredTiger uses a **page‑merge** heuristic: if a page has many deltas (more than a threshold, e.g., 100), it is reconciled early. If it has few, it remains dirty in memory until checkpoint.

Reconciliation is not a full compaction of the tree—it only affects a single page. Therefore, over time, the tree can accumulate “fragmentation” as pages are written to new locations. This fragmentation is resolved by occasional **tree compaction** (also called “review” or “rebalance”), which is triggered when the tree height becomes too deep or when a significant number of pages are nearly empty. Tree compaction is another background process, but it is much rarer than LSM compaction—only when structural imbalance occurs.

### 5.3 Cache Eviction and Latency

Because eviction of dirty pages involves I/O (writing the reconciled page to disk), it can increase latency. WiredTiger uses a **two‑pass** eviction: first, it tries to evict clean pages; only when the cache is still above the high watermark does it start evicting dirty pages (which triggers reconciliation and writes). This approach reduces the probability that a user thread will stall waiting for eviction.

Another clever mechanism is **connection‑level eviction**. In a multi‑threaded environment, each worker thread can participate in eviction by handing a “eviction request” to the background eviction thread. However, if the background thread is overloaded, worker threads may pause to help with eviction. This is controlled by parameters like `eviction_target`, `eviction_trigger`, and `eviction_dirty_target`.

---

## 6. Checkpointing in Depth: How WiredTiger Creates Consistent Snapshots

Checkpointing is the glue that makes WiredTiger’s hybrid architecture work. Let’s walk through the steps in more detail.

### 6.1 Checkpoint Initiation

A checkpoint can be initiated periodically, upon explicit user command, or when the WAL grows too large (e.g., 2 GB). The checkpoint starts by taking a global lock briefly to record the current transaction ID and to freeze the root page pointer. After that, the checkpoint thread works **asynchronously** with ongoing writes.

### 6.2 Traversal and Writing

The checkpoint thread performs a depth‑first traversal of the tree starting from the root page as of the checkpoint snapshot. For each page:

- If the page is clean (has not been modified since the last checkpoint), it is already on disk and does not need rewriting.
- If the page is dirty, the checkpoint thread reconciles it (merges deltas) and writes the resulting page to a new location in the data file. The old location remains valid for any readers that still hold a reference to the previous checkpoint.

Because the tree uses copy‑on‑write, the next checkpoint will again write new versions of pages that changed after this checkpoint. Over time, the data file grows as new pages are appended. To reclaim space, unused pages (those that are no longer referenced by any checkpoint) are tracked in a free list and reused by subsequent writes.

### 6.3 Fuzzy Checkpoint vs. Hard Checkpoint

WiredTiger supports two checkpoint modes:

- **Fuzzy checkpoint** (default): The checkpoint does not wait for all in‑memory modifications to be flushed. It takes a snapshot of the tree at a point in time, but pages that are still being modified (higher transaction IDs) are excluded. This means the checkpoint may not contain the very latest data, but it is consistent as of the snapshot time. The WAL contains all changes after that snapshot.
- **Hard checkpoint** (rare): The engine pauses writes, flushes all dirty pages, and writes a fully up‑to‑date checkpoint. This is used for clean shutdown.

Fuzzy checkpoints are critical for availability: they allow the database to take a consistent checkpoint without blocking reads or writes.

### 6.4 Checkpoint and Recovery

On restart, WiredTiger reads the last checkpoint file (which contains the root page location). It loads that root page and uses it as the base for the in‑memory tree. Then it replays the WAL from the checkpoint’s end timestamp. During replay, it applies each log record to the appropriate page. Because the WAL contains only sequential writes, recovery is purely sequential and thus very fast—typically a few seconds per GB of log.

---

## 7. Comparison with LSM Trees (RocksDB) and Classic B‑Trees (InnoDB)

Now that we’ve dissected WiredTiger, let’s compare it head‑to‑head with its two main competitors.

| Feature                          | WiredTiger                                               | RocksDB (LSM)                                   | InnoDB (B‑tree)                                                             |
| -------------------------------- | -------------------------------------------------------- | ----------------------------------------------- | --------------------------------------------------------------------------- |
| **Write amplification**          | Low (CoW, deltas, checkpoints)                           | Medium‑high (compaction)                        | High (page splits, in‑place writes)                                         |
| **Read amplification**           | Low (single tree, no merging)                            | High (multi‑SSTable, Bloom filters)             | Low (single tree)                                                           |
| **Space amplification**          | Low‑medium (free list reuse)                             | Medium‑high (temporary <2×)                     | Low                                                                         |
| **Compaction overhead**          | Background reconciliation + tree compaction (infrequent) | Continuous, heavy compaction                    | None (except page splits)                                                   |
| **Concurrency**                  | Non‑blocking reads via MVCC, row‑level OCC               | Row‑level locks, but snapshots supported (MVCC) | Page‑level latches (InnoDB uses row locks but still page latches for index) |
| **Recovery time**                | Fast (sequential WAL replay)                             | Fast (WAL replay + flush level)                 | Medium (re‑do log + undo log)                                               |
| **Range scan performance**       | Fast (single tree, sequential I/O)                       | Slower (merge multiple SSTables)                | Fast (single tree, sequential I/O)                                          |
| **Write throughput (high load)** | Very high (sequential log + batched checkpoints)         | Very high (sequential log + memtable)           | Moderate (random page writes)                                               |

### 7.1 When RocksDB Beats WiredTiger

RocksDB excels in write‑only workloads where bursting writes are acceptable and read latency is secondary. For example, in a time‑series database recording sensor data, where queries are rare or can tolerate second‑level latency, RocksDB’s write throughput can exceed that of WiredTiger because it doesn’t need the checkpointing overhead. Also, RocksDB’s compaction can be throttled (via `rate_limiter`) to smooth out I/O.

RocksDB also has richer compaction strategies (level, tiered, universal) that can be tuned for specific access patterns. WiredTiger’s tree is more rigid.

### 7.2 When InnoDB Beats WiredTiger

For read‑heavy OLTP workloads with many point lookups and small ranges, and where writes are relatively few, InnoDB’s classic B‑tree can be simpler and faster because there is no reconciliation or checkpoint overhead. InnoDB’s adaptive hash index can also accelerate point queries. However, InnoDB suffers from page‑level contention on hot spots (like auto‑increment primary keys), while WiredTiger’s delta‑based writes avoid that.

### 7.3 WiredTiger’s Sweet Spot

WiredTiger shines in **mixed workloads** with both high write throughput and low read latency requirements. The classic example is MongoDB: a real‑time operational database supporting a web application. Users expect sub‑100 ms response times for reads while writes arrive at thousands per second. WiredTiger delivers this by batching writes into checkpoints (sequential I/O) and providing fast single‑tree reads. It also handles bursty write spikes better than InnoDB because it does not require page‐level in‑place updates.

---

## 8. MongoDB Integration: How WiredTiger Powers the World’s Most Popular NoSQL Database

MongoDB adopted WiredTiger as its default storage engine in version 3.2. The integration is deep: every collection and index is backed by a WiredTiger table, and MongoDB’s document‑level locking maps to WiredTiger’s row‑level concurrency.

### 8.1 Document‑Level Concurrency in Practice

Before WiredTiger, MongoDB used MMAPv1, which locked the entire database for writes. With WiredTiger, multiple operations on different documents can proceed simultaneously, even within the same collection. This dramatically improved throughput for multi‑document operations and enabled features such as `updateMany` to run in parallel.

### 8.2 Transactions and Snapshot Isolation

Starting with MongoDB 4.0, multi‑document ACID transactions are supported across replica sets. Under the hood, each transaction in MongoDB is mapped to a WiredTiger transaction, with snapshot isolation. The `readConcern` controls the snapshot visibility (local, majority, linearizable). WiredTiger provides the MVCC infrastructure to support these semantics.

### 8.3 Storage Engine Options: InMemory and Encrypted In addition to the default row‑store, WiredTiger offers an **in‑memory** variant (no data persistence) and an **encrypted** variant (transparent encryption at rest). MongoDB exposes these as separate engines.

### 8.4 Monitoring and Tuning in MongoDB

MongoDB exposes many WiredTiger statistics via the `db.serverStatus().wiredTiger` command. Operators can monitor:

- **Cache usage**: `cache` section shows bytes currently in cache, dirty bytes, and eviction activity.
- **Checkpoint timing**: `checkpoint` section shows the last checkpoint duration and count.
- **Log throughput**: `log` section shows bytes written and sync times.

Common tuning knobs include:

- `wiredTigerCacheSizeGB`: Percentage of RAM used for the cache. Too small → frequent evictions; too large → memory pressure for other processes.
- `wiredTigerCheckpointDelaySec` (in earlier versions, now `checkpoint=(wait=...)`): Interval between checkpoints.
- `wiredTigerLogFileSizeMB`: Size of each WAL file. Larger files reduce log switches but increase recovery time.

---

## 9. Performance Characteristics and Real‑World Examples

### 9.1 A Write‑Heavy Benchmark

Consider a workload of 10,000 writes/second with an average document size of 512 bytes. Under a classic B‑tree (InnoDB), each update touches a leaf page of 16 KB, leading to 160 MB/s write I/O (10k \* 16 KB). With WiredTiger, each update adds a delta record of maybe 64 bytes plus a WAL entry. Assuming a checkpoint every 60 seconds, the checkpoint writes only the dirty pages (which may be many, but each page is written once). The steady‑state write I/O is roughly:

- WAL: 10k \* (512 bytes + overhead) ≈ 5 MB/s
- Checkpoint writes: number of dirty pages per checkpoint × page size. If the working set is 10 GB and 50% is dirty, that’s 5 GB written every 60 seconds ≈ 85 MB/s average. This is higher than the WAL alone, but still less than InnoDB’s continuous 160 MB/s. Moreover, checkpoint writes are sequential (appending to the data file), so they benefit from disk bandwidth.

### 9.2 Read Performance Under Heavy Writes

In the same workload, a read that hits a cached page is nearly instantaneous. If the page is not in cache, it must be read from the checkpoint file. Because the tree is single, a point lookup reads at most 3–4 pages (root, internal, leaf). With SSDs, this is about 0.1 ms per page read, so total 0.4 ms. In RocksDB, a point lookup might need to check 3 SSTables (each with a Bloom filter miss) plus a memtable, leading to up to 6 I/Os if the block cache misses. WiredTiger’s read path is generally more predictable.

### 9.3 Compaction Storm Mitigation

WiredTiger does not have true compaction storms because it does not merge runs. Its background reconciliation is per‑page and is throttled by the eviction thread. However, a sudden large write spike can dirty many pages, causing the next checkpoint to become a bottleneck (since it must write many new pages). This can cause latency spikes during the checkpoint. MongoDB mitigates this by allowing checkpoints to be background‑friendly, and by using a “checkpoint thread” that runs at a lower priority. In production, operators often see that checkpoint I/O spikes to 500 MB/s for a few seconds, then returns to normal. This is far less disruptive than the multi‑minute compaction storms that can occur in RocksDB.

---

## 10. Edge Cases and Complexities

No storage engine is perfect. WiredTiger has its own set of edge cases that can surprise engineers.

### 10.1 Tree Bloat Due to Long‑Lived Snapshots

Because WiredTiger retains old versions of pages to serve old snapshots, long‑running read transactions (or secondary reads that use a stale snapshot via `secondaryPreferred` in MongoDB) can prevent page reclaim. If a reader holds a snapshot for minutes, the engine cannot free any page that was modified after that snapshot. This can cause the cache to fill with obsolete delta records, leading to `Cache pressure` warnings and eviction storms. The solution is to keep transactions short and to use `readConcern: majority` or `linearizable` for consistency, which do not hold snapshots indefinitely.

### 10.2 Large Objects and Overflow Pages

Documents larger than a page (default 4 KB) are stored in overflow records. WiredTiger stores a pointer to overflow pages in the leaf cell. This adds an extra indirection and overhead. In MongoDB, it is recommended to avoid documents larger than 16 MB (MongoDB’s limit), but even 1 MB documents can cause overhead. For such workloads, consider using GridFS or splitting documents.

### 10.3 Performance on Rotational Disks

While WiredTiger’s checkpoint‑based writes are more sequential than classic B‑trees, they are still far from ideal for HDDs. The random reads during page lookups (especially for indexes) can be slow. MongoDB recommends SSDs for production.

### 10.4 Lock Waits Under Heavy Contention

Even with optimistic concurrency, extremely hot keys (e.g., a single document updated 100k times/second) can cause transaction conflicts and retries. WiredTiger will eventually resort to waiting for locks, which introduces latency. In such cases, MongoDB’s sharding can help by distributing hot keys across shards.

---

## 11. Lessons for System Design

WiredTiger’s architecture offers several lessons for anyone building distributed storage systems:

1. **Don’t commit to a single data structure.** The best design is often a hybrid that exploits the strengths of both families.
2. **Make writes sequential and lazy.** Batching writes into periodic checkpoints converts random I/O to sequential I/O, improving throughput and endurance on SSDs.
3. **Use copy‑on‑write to eliminate in‑place updates.** This reduces write amplification and enables MVCC naturally.
4. **Separate the read path from the write path.** Readers see a consistent snapshot; writers append changes. Locks are only needed for rare conflicts.
5. **Amortize expensive operations.** Reconciliation and checkpointing are done in the background, not inline with reads or writes.
6. **Choose the right granularity for concurrency.** Row‑level (or document‑level) locking with OCC works well for most workloads; page‑level locks are a bottleneck.
7. **Provide knobs but guard against misuse.** Tuning WiredTiger requires understanding cache size, checkpoint intervals, and eviction thresholds. Operators must monitor and adjust.

---

## 12. Conclusion

WiredTiger stands as a testament to the fact that storage engine design is not a binary choice between B‑trees and LSM trees. By fusing a copy‑on‑write B‑tree with log‑structured checkpointing, it achieves a balance that serves the needs of a modern distributed database like MongoDB. Write amplification is controlled, read performance is predictable, and concurrency scales to millions of transactions per second.

Understanding WiredTiger is not just a matter of academic curiosity—it directly impacts how you operate and tune one of the most widely deployed databases in the world. When you see `WT_CACHE_EVICTION_STRAIN` in your MongoDB logs, you now know that the cache is under pressure and that you might need to increase cache size or reduce write intensity. When you observe checkpoint spikes, you understand the trade‑off between durability and latency.

More broadly, WiredTiger’s design philosophy—_evolve the B‑tree to handle writes, rather than switching to an LSM tree_—is an inspiration for future storage systems. As hardware evolves (persistent memory, faster SSDs, disaggregated storage), the exact algorithms may change, but the principles of amortized writes, MVCC, and background reconciliation will remain.

So the next time you issue an `insert` into a MongoDB cluster, remember: the storage engine isn’t just “working”—it’s performing a carefully choreographed dance between memory, disk, and logs, balancing the age‑old tension between reads and writes. And it does so beautifully.

---

_This deep dive was written for engineers who want to understand the internals of one of the most sophisticated storage engines in production today. For further reading, consult the [WiredTiger documentation](https://source.wiredtiger.com/), the MongoDB source code, and the original [WiredTiger research paper](https://www.wiredtiger.com/pdf/wiredtiger.pdf)._
