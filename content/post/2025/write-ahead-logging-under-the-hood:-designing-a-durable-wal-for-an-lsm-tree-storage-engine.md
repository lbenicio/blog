---
title: "Write Ahead Logging Under The Hood: Designing A Durable Wal For An Lsm Tree Storage Engine"
description: "A comprehensive technical exploration of write ahead logging under the hood: designing a durable wal for an lsm tree storage engine, covering key concepts, practical implementations, and real-world applications."
date: "2025-02-04"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/Write-Ahead-Logging-Under-The-Hood-Designing-A-Durable-Wal-For-An-Lsm-Tree-Storage-Engine.png"
coverAlt: "Technical visualization representing write ahead logging under the hood: designing a durable wal for an lsm tree storage engine"
---

# The Write-Ahead Log: The Unsung Hero of Modern Databases

The datacenter hums with the quiet, desperate hum of a million cooling fans. In one corner, a rack-mounted server has a sudden, catastrophic power failure—a surge, a breaker trip, and absolute, silent darkness. Three hundred thousand active user sessions vanish. In-memory data structures evaporate. The operating system’s page cache, filled with dirty blocks waiting to be written to disk, becomes an artifact of a universe that no longer exists.

When the backup generator kicks in and the server reboots, a single question determines whether this is a minor blip or a multi-million dollar data loss disaster: _Did the storage engine last flush commit?_

This is not a theoretical scenario. It is the daily reality for every distributed database engineer, every developer of a NoSQL system, and every operator of a modern data platform. At the heart of this reliability lies a deceptively simple piece of engineering: the Write-Ahead Log, or WAL.

We spend countless hours optimizing query performance, designing elegant schemas, and scaling clusters horizontally. Yet, the entire edifice of modern data infrastructure—Amazon DynamoDB, Cassandra, HBase, LevelDB, RocksDB—rests upon the humble, sequential, append-only log. It is the unsung hero of durability. Without it, the LSM Tree, the storage engine architecture that powers the world’s most write-intensive workloads, would be a fragile curiosity rather than the backbone of the internet.

In this post, we will peel back the layers of the WAL. We'll examine how it works under the hood, why it is indispensable for LSM-based systems, how it enables crash recovery at scale, and the engineering trade-offs that make it both a performance bottleneck and a safety net. We'll walk through real-world implementations in RocksDB, Cassandra, and Amazon DynamoDB, and we'll glimpse the future of write-ahead logging in disaggregated storage and cloud-native databases. By the end, you will understand why every serious database engineer treats the WAL with the reverence it deserves.

## The LSM Tree’s Dirty Secret

To understand why the WAL is so critical, we must first understand the architecture it serves. The Log-Structured Merge-Tree (LSM Tree), popularized by Google’s Bigtable and subsequently by Patrick O'Neil’s seminal papers, offers a radical trade-off: sacrifice some read performance for phenomenal write throughput.

An LSM engine doesn’t update data in place. Instead, it performs a relentless, highly efficient ballet:

1.  **MemTable:** All writes arrive at a small, in-memory sorted data structure (the MemTable). This is typically implemented as a balanced tree (e.g., a Red-Black tree or a Skip List) or a hash map. Because writing to memory is orders of magnitude faster than writing to disk, the MemTable can absorb bursts of writes with negligible latency.
2.  **Flush:** When the MemTable reaches a certain size (by default, a few megabytes), it is frozen and asynchronously flushed to disk as an immutable, sorted data file called an **SSTable** (Sorted String Table). A new empty MemTable takes its place. The flush operation is a bulk sequential write, which is far more efficient than many small random writes.
3.  **Compaction:** Over time, multiple SSTables accumulate on disk, each representing a snapshot of writes that arrived during a specific window. To keep read performance from degrading (since a read might need to merge results from many SSTables), a background process called compaction merges several SSTables into one, discarding obsolete entries (e.g., old versions of the same key) and producing a new, compacted SSTable. Compaction is the engine's housekeeping—it preserves the tree's log-structured nature.

This architecture has a beautiful property: all disk writes are sequential, which is extremely fast on spinning hard drives and even beneficial on SSDs (which prefer large contiguous writes). In contrast, B-Trees (used by MySQL's InnoDB, for example) perform random writes because they update pages in place. The LSM Tree's design makes it the go-to choice for write-heavy workloads: time-series data, event logs, IoT sensor streams, and mobile app metrics.

However, there is a dirty secret: the MemTable lives entirely in **volatile memory**. If the process crashes or the power fails, the MemTable’s contents—our most recent writes—are lost. And because the MemTable is the first stop for every write, losing it means losing data that the user considered committed. This is where the WAL enters.

## The WAL: A Minimal Guarantee

The Write-Ahead Log is a simple yet profound idea: **before applying any change to the in-memory state (the MemTable), append a record of that change to a sequential log on durable storage.** The log must be force-written (fsynced) to disk before the write is acknowledged to the client. After the log is safe, the engine can update the MemTable. If a crash occurs, the engine can replay the log to reconstruct the MemTable exactly as it was before the crash.

This principle is often summarized as “write-ahead” because the log entry precedes the actual data mutation. It is also known as a **redo log** (as opposed to an undo log in some database systems). The term “write-ahead” also hints at a fundamental ordering constraint: durability is only guaranteed if the log write is synchronized to persistent media before the operation is considered complete.

### How the WAL Works in an LSM Engine

Let’s trace a single `PUT(key, value)` operation through a typical LSM engine like RocksDB or LevelDB:

1. **Client Issues Write:** The client sends a `PUT` request to the database. The API call might be synchronous (wait for acknowledgment) or asynchronous (fire-and-forget).
2. **Log Entry Created:** The engine creates a log record containing the operation type (`PUT`), the key, the value, and possibly a sequence number and a checksum. The record is serialized into a binary format.
3. **Append to WAL Buffer:** The record is appended to an in-memory buffer that accumulates log entries. This buffer is typically a small, fixed-sized block (e.g., 4 KB or 8 KB). Batching multiple small writes into one buffer reduces the number of expensive fsync calls.
4. **Fsync to Disk:** When the buffer is full, or when the client explicitly requests a synchronous commit, the engine calls `fsync()` (or equivalent OS primitive) to flush the buffer to durable storage. On Linux, this ensures that the data has been written to the device's non-volatile cache (e.g., battery-backed RAID, SSD capacitor) or to the media itself.
5. **Update MemTable:** After the WAL write is acknowledged by the OS as durable, the engine inserts the key-value pair into the MemTable (the in-memory sorted structure). This step can fail if the WAL write failed—in that case, the write is rejected.
6. **Acknowledge Client:** Finally, the engine returns success to the client. The client now knows that its write is safe, even if the power fails immediately.

This sequence guarantees that any write reported as committed can be recovered. The WAL serves as a **reliable buffer** between the fast, volatile MemTable and the slower, permanent SSTable storage. It bridges the gap between memory speed and disk durability.

### The Role of Fsync

Fsync is the linchpin of durability. Without it, the WAL buffer might linger in the OS page cache, which is still volatile. If the power fails before the page cache is written to disk, the log entries are lost. The operating system typically writes dirty pages to disk after a few seconds (controlled by `dirty_expire_centisecs`), but that delay is unacceptable for a database that promises durability.

Calling `fsync()` after every single write would be prohibitively slow. On modern hardware, an fsync to an SSD can take 10–100 microseconds, and to a spinning disk it can take several milliseconds. For a database handling thousands of writes per second, this would limit throughput to a few hundred operations per second. The solution is **group commit**: accumulate multiple log records in a buffer, then fsync the entire buffer at once. The WAL is inherently append-only, so the buffer can be written sequentially with large I/Os, making the cost of fsync amortized over many records.

Group commit introduces a subtle trade-off: if the buffer is not full and a client requests a synchronous write, the engine must decide whether to wait for the buffer to fill (which delays the client) or to flush immediately (which wastes a potential batching opportunity). Many engines choose to flush after a short timeout (e.g., 1 ms) or when a minimum number of records are buffered. This is a classic latency-vs-throughput trade-off.

### Atomicity and Checksums

The WAL also enforces atomicity for individual writes. If only part of a log record is written to disk (due to a crash during the write), the record is corrupted. To detect this, each log record is appended with a checksum (e.g., CRC32 or xxHash). During recovery, the engine reads the log sequentially and verifies the checksum of each record. Any record that fails validation is considered incomplete and is ignored (or truncated). This ensures that partial writes never result in logically incomplete data.

Furthermore, the WAL guarantees that writes are recovered in the exact order they were applied. The log is a linear sequence of records, and during replay, the engine re-inserts them into the MemTable in the same order. This ordering is crucial for maintaining consistency in a system that supports operations like increments, compare-and-swap, or even simpler key overwrites.

## Anatomy of a Write Path: A Detailed Walkthrough

Let's dive deeper into the write path of a realistic LSM engine. We'll use pseudocode to illustrate the steps, but the principles apply to real implementations like RocksDB (written in C++) and LevelDB (also C++).

### Pseudocode for a Synchronous Write

```
function write(key, value, sync):
    // 1. Create log record
    record = { type: PUT, key: key, value: value, seq: next_seq() }
    serialized = serialize(record)

    // 2. Append to WAL buffer (in-memory)
    wal_buffer.append(serialized)

    // 3. If sync is required, flush the WAL buffer to disk
    if sync:
        wal_buffer.flush()        // write() system call
        fsync(wal_log_file_fd)    // force to disk

    // 4. Insert into MemTable
    mem_table.insert(key, value, seq)

    // 5. If MemTable is full, trigger a flush to SSTable
    if mem_table.size() >= memtable_size_threshold:
        trigger_background_flush()

    // 6. Return success
    return OK
```

### The Flush to SSTable

When the MemTable reaches its size limit, the engine must freeze it and create a new one. At this point, the MemTable's contents are both in the WAL and in memory. The engine creates an immutable snapshot of the MemTable and begins writing it to disk as an SSTable. During this flush, the engine must also **truncate the WAL**: because the flushed data is now safe in a durable SSTable, the log records corresponding to that data are no longer needed for recovery. However, the engine must be careful: the WAL may still contain records that have not yet been flushed (e.g., writes that arrived after the MemTable was frozen but are still in the current active MemTable). So the WAL is typically divided into segments: after a flush, the engine can recycle or delete the log segment that corresponded to the flushed MemTable.

This is a critical optimization: without it, the WAL would grow indefinitely, consuming disk space and making recovery slower. In practice, the WAL is a circular buffer of segments, each representing a period of writes. When a segment becomes fully flushed, it is reused.

### The Role of Sequence Numbers

Each write in an LSM engine is assigned a monotonically increasing sequence number (or timestamp). The sequence number allows the engine to:

- Order writes across multiple MemTables (the frozen one and the active one).
- Support snapshot isolation (read at a specific sequence number).
- Handle eventual consistency in distributed settings.

The WAL conveniently records the sequence number alongside each entry, so during recovery the engine can assign the same sequence numbers and maintain the same order of writes.

### Batching and Group Commit in Practice

In RocksDB, the default WAL implementation uses a `WriteBatch` to group multiple individual `Put` operations into a single log record. This batch is then written atomically. Group commit is configured via the `max_write_buffer_number` and `wal_bytes_per_sync` options. The engine also supports asynchronous commits (where the client does not wait for an fsync) and synchronous commits with a configurable timeout.

For example, in Cassandra (which also uses an LSM-like engine, but with its own storage model called the Log-Structured Merge tree with a commit log), the write path is:

1. Append to the commit log (the WAL).
2. Write to the memtable.
3. Periodically flush the memtable to an SSTable.
4. After flush, the commit log segment is marked for deletion.

Cassandra's commit log uses a pre-allocated fixed-size file called `CommitLogSegment`. Each segment has a header with metadata and a start position. The engine writes sequentially and rotates segments when one is full.

## Crash Recovery: The Moment of Truth

When a server reboots after an abrupt shutdown, the LSM engine must determine its state. The SSTables on disk are immutable and always consistent, but the last MemTable (which was not flushed) is gone. The only record of its contents is the WAL.

### Recovery Algorithm

1. **Locate WAL Segments:** The engine scans the WAL directory for segments that have not been deleted. Typically, there is a single active segment (the one being written to) and possibly some older segments that have not been fully flushed yet.
2. **Replay in Order:** For each segment, read the log entries sequentially from the beginning. Verify each entry's checksum. If a checksum fails, the entry and all subsequent entries in that segment are discarded (because the engine can't know if later entries are complete). This is a safe truncation.
3. **Rebuild MemTable:** For each valid entry, apply the operation to a new, empty MemTable. This includes inserting key-value pairs, increments, or deletes (which are represented as a special tombstone value). The sequence numbers from the WAL are used to maintain order.
4. **Finalize:** After all segments are replayed, the MemTable contains all the writes that were committed before the crash but had not yet been flushed to an SSTable. The engine then continues normal operation: the MemTable can be used for reads, and when it fills up, it will be flushed to an SSTable in the usual way. Any leftover WAL segments that are now exhausted (i.e., all their data is now either in the MemTable or already flushed) are deleted.

### Handling Partial Writes

A common challenge is that the last few bytes of a WAL segment may have been written incompletely if the crash occurred during a `write()` system call. The checksum of the last record will be wrong, and the engine will truncate it. However, if the record itself was only partially written, the engine must decide where to cut: it might read until a valid record boundary. Many implementations use a length-prefixed record format: each record starts with a 4-byte length field. If the engine reads past the end of the file, it knows the last record is incomplete and discards it.

### The Cost of Recovery

Recovery time is proportional to the size of the unreplayed WAL segments. In a busy system, the WAL can accumulate gigabytes of data if memtable flushes are slow or if the engine is not configured to recycle segments quickly. To mitigate this, engines often allow the WAL to be flushed eagerly: even if the MemTable hasn't hit its size limit, the engine can periodically force a MemTable flush (e.g., every few seconds) to keep the WAL small. However, this increases write amplification because small SSTables are created more frequently. The trade-off is between recovery time and steady-state write performance.

In practice, many databases also support **checkpointing**: a periodic snapshot of the entire MemTable (or the entire database state) that allows recovery to start from a known point, reducing the WAL replay window. This is common in systems like MySQL's InnoDB (which uses a redo log and a separate undo log) and PostgreSQL (which uses a WAL and periodic full-page writes).

## Beyond the Single Node: Distributed WALs

In distributed databases, the WAL takes on an even more critical role. It becomes the backbone of replication, consensus, and fault tolerance. Think of a system like Apache Cassandra, Amazon DynamoDB, or Apache Kafka. In these systems, the WAL is not just a local durability mechanism—it is a means to **broadcast** writes to multiple nodes.

### Replication via Log Shipping

In a typical distributed LSM database, each node has its own WAL and its own local SSTables. For replication, the node that receives the client write (the coordinator) writes the operation to its own WAL first, then sends the operation to replicas. The replicas may also write to their own WALs before acknowledging back. This is known as **log shipping**. The protocol ensures that a write is durable on multiple nodes before the client gets a success.

Cassandra uses a variant of this: the coordinator writes to its commit log, then sends a message to the replicas. The replicas write to their own commit logs and memtables, and then respond. The consistency level (e.g., QUORUM, ONE, ALL) determines how many replicas must acknowledge before the coordinator returns success. If a replica crashes, the coordinator can replay any missed writes from its own WAL or from a repair process.

### Consensus Protocols and the WAL

Systems like Google’s Spanner, etcd, and Apache ZooKeeper use consensus algorithms (Paxos or Raft) to achieve agreement across nodes. In Raft, for example, each node maintains a **log** of commands (the Raft log). This log is the authoritative record of the state machine's operations. A command is committed only after it has been replicated to a majority of nodes and each node has fsynced it to its local WAL.

The Raft log is essentially a distributed WAL. It provides both durability (via local fsync) and replication (via network consensus). When a new leader is elected, it reads its own log and ensures that all followers have consistent logs. The state machine (which could be an LSM tree) applies commands from the committed prefix of the log.

This combination of a distributed consensus log and a local storage engine is the foundation of many modern distributed databases. For instance, CockroachDB uses Raft for replication, and each replica stores its data in a RocksDB LSM engine. The RocksDB WAL serves as the local durability layer for the Raft log entries.

### The DynamoDB Story

Amazon DynamoDB uses a proprietary storage engine that also relies on a WAL. In the original Dynamo paper, the system uses a log-structured storage with an in-memory buffer (like a MemTable) and a commit log. The commit log is replicated across three data centers. When a write arrives at a coordinator, it is written to the local commit log and then asynchronously propagated to other replicas using a gossip protocol. The commit log ensures that the write is durable even if the coordinator fails before the data is propagated.

DynamoDB’s WAL also enables efficient incremental backups and point-in-time recovery. By replaying the log from a certain timestamp, the system can recreate the state at any point.

## Trade-offs and Engineering Challenges

While the WAL is a lifesaver, it is not free. Every database engineer must navigate several trade-offs to prevent the WAL from becoming a performance bottleneck.

### I/O Amplification

Every write to the database is written at least twice: once to the WAL and once to the SSTable (when the MemTable is flushed). Some systems also write to multiple replicas. This is known as **I/O amplification** (or write amplification in the context of LSM trees). On SSDs, which have limited write endurance (measured in drive writes per day), amplification shortens the lifespan of the hardware. Therefore, minimizing WAL writes is a key optimization.

Strategy 1: **Batching and group commit** — as discussed, this reduces the number of fsync calls. With group commit, the effective fsync cost per write can be reduced to a microsecond or less if the batch is large enough.

Strategy 2: **WAL compression** — compress the binary log records before writing to disk. This reduces the bytes written, at the cost of CPU overhead for compression/decompression. RocksDB supports `CompressionType::kSnappyCompression` for WAL files.

Strategy 3: **WAL recycling** — instead of allocating new files for each log segment, reuse old segments. This reduces file system metadata operations.

### Latency Under Load

The WAL is a sequential bottleneck. All writes must pass through it in order. In a single-threaded engine, this is natural. But in a concurrent engine (like RocksDB, which supports multiple writer threads), the WAL becomes a point of contention. Multiple threads must synchronize to append to the log buffer and to wait for the fsync.

RocksDB’s solution is to use a **group commit** mechanism with a leader-follower pattern: one thread becomes the leader and writes the entire batch to the WAL, while other threads wait for the leader to finish. This design reduces contention but can cause tail latency spikes if the leader is slow.

On the hardware side, using an NVMe SSD with a dedicated IO-priority can reduce the latency of fsync. Some databases also store the WAL on a separate disk or partition to avoid interference from other I/O, such as SSTable flushes.

### Memory Pressure

The WAL buffer is an in-memory data structure. If the engine cannot flush it fast enough (e.g., because the disk is slow), the buffer can grow and consume memory that could be used for the MemTable or cache. This can lead to Out-of-Memory (OOM) conditions. To mitigate, the WAL flush rate must be matched to the incoming write rate. Dynamic throttling is often used.

### WAL Full

If the WAL runs out of disk space, the database must stop accepting writes. This is a safety mechanism: the database would rather fail writes than lose durability. Monitoring disk space and alerting is essential.

## Real-World Implementations

We've touched on some examples; let's deep-dive into three major ones.

### RocksDB

RocksDB is a Facebook-forked version of LevelDB. Its WAL is highly configurable. Key parameters:

- `wal_bytes_per_sync`: controls how often the WAL is synced to disk (in bytes). Default is 0 (no intermediate sync, only at group commit).
- `WAL_ttl_seconds` and `WAL_size_limit_MB`: control automatic deletion of old WAL segments after a MemTable flush.
- `WAL_filter`: a custom filter to skip certain entries during recovery (rarely used).
- `WriteOptions::sync`: per-write sync flag; set to true for synchronous durability.

RocksDB also supports **single WAL across multiple column families**, which is a powerful feature: multiple logical databases can share one WAL file, reducing sync overhead and simplifying recovery.

### Cassandra

Cassandra's commit log is similar but has its own quirks. It uses a fixed buffer size per segment (default 32 MB). The commit log is written to a separate disk (configurable) to reduce I/O contention. During startup, Cassandra replays the commit log segments to reconstruct the memtables, which are then flushed.

One key difference: Cassandra does not have a single MemTable per instance; it has one per column family (table). The commit log is shared among all tables. Recovery involves replaying all segments and splitting entries by table.

### Amazon DynamoDB (via the DynamoDB Accelerator DAX)

While the internals are proprietary, the publicly known design of DynamoDB uses a log-structured storage layer with a commit log. The commit log is replicated across three Availability Zones. Writes are acknowledged once the commit log is written durably in a quorum of AZs. This ensures strong durability. The in-memory buffer (like a MemTable) is flushed to SSTables asynchronously. The commit log also serves for point-in-time recovery, allowing the database to be restored to any second within the retention window by replaying logs up to that timestamp.

## The Future: WAL in Modern Systems

The WAL is far from obsolete. As hardware evolves, new opportunities and challenges arise.

### NVMe and Persistent Memory

NVMe SSDs offer extremely low latency (single-digit microseconds) and high IOPS. This makes each fsync much cheaper, reducing the need for aggressive batching. Some databases now provide "adaptive WAL sync" that dynamically adjusts the fsync frequency based on latency and throughput.

Persistent memory (e.g., Intel Optane) blurs the line between memory and disk. In a system with persistent memory, the WAL could be written to a region of byte-addressable memory that survives power loss. This eliminates the need for a traditional fsync (since writes are directly persistent). However, standard interfaces like `pmem_memcpy_persist()` still require flushing CPU caches. This is an area of active research: some engines, like RocksDB with "pmem WAL", leverage persistent memory to achieve near-zero latency for log writes.

### Disaggregated Storage

In cloud-native databases, storage is often disaggregated from compute. For example, Amazon Aurora uses a shared storage layer. In such architectures, the WAL may be written to a remote storage service (e.g., Amazon EBS, or a shared log service like Apache BookKeeper). The engine must tolerate network latency and possible overload. Techniques like asynchronous WAL replication with ordering have been developed.

### WAL-less Storage?

Some research has questioned the necessity of the WAL in LSM trees. For instance, the **WiscKey** design (from FAST 2016) proposes separating keys and values: keys are stored in the LSM tree, and values are stored in a separate log. This reduces write amplification, but the WAL is not eliminated; it's just renamed and repurposed. In practice, a durability log remains essential.

Another approach is **write-optimized B-trees** (like Bε-trees) that use a buffer in memory and flush to nodes. These still require a log for recovery.

## Conclusion

The Write-Ahead Log is the quiet workhorse of the database world. It is a simple sequential file, yet it enables the extraordinary write throughput of LSM trees, the consensus of distributed systems, and the durability guarantees that let us sleep at night. Every time a social media post is made, a sensor reading is stored, or a payment is processed, a WAL is being written somewhere.

Understanding the WAL is essential for any engineer who works with databases at scale. It is not just a component—it is a philosophy: **write first, think later, but make sure you can recover.** The next time you tune a RocksDB configuration or debug a Cassandra commit log issue, you'll appreciate the elegance and the complexity of this unsung hero.

The datacenter hums on. The generators are ready. And the WAL stands guard, ready to replay the story of every write that was ever committed.
