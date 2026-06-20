---
title: "The Implementation Of A Log Structured Merge Tree (Lsm Tree) With Level Based Compaction In Rocksdb"
description: "A comprehensive technical exploration of the implementation of a log structured merge tree (lsm tree) with level based compaction in rocksdb, covering key concepts, practical implementations, and real-world applications."
date: "2019-07-02"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/the-implementation-of-a-log-structured-merge-tree-(lsm-tree)-with-level-based-compaction-in-rocksdb.png"
coverAlt: "Technical visualization representing the implementation of a log structured merge tree (lsm tree) with level based compaction in rocksdb"
---

# The Art of the Write: How RocksDB's LSM Tree Conquered the Storage Stack

## Introduction

There is a peculiar kind of tyranny in how we have traditionally built databases. For decades, the B-Tree ruled as the undisputed champion of data organization. It was elegant, predictable, and perfectly optimized for the hardware of the 1980s and 1990s: the spinning magnetic platter of the Hard Disk Drive (HDD). The B-Tree’s genius was its locality. It tried, with every fiber of its being, to keep related data physically close together on the disk. This minimized the painful, mechanical seek time of the actuator arm moving across the platter. The B-Tree was, in essence, a beautiful compromise, designed to make the agonizingly slow process of physical I/O bearable.

But the hardware gods have a wicked sense of humor. Just as software engineers perfected the art of the B-Tree, the foundations of computing shifted. The spinning platter began its long, slow goodbye. In its place came the silicon chasm of the Solid-State Drive (SSD). Suddenly, the old rules were broken. Seek time all but vanished. Random reads became nearly as fast as sequential reads. The bottleneck began to shift, moving from the mechanical latency of the disk to the raw throughput of the flash memory and the bus connecting it.

In this new world, the B-Tree’s precious locality became a liability. Its strength—the in-place update of data—turned into a performance nightmare. Every small write to a B-Tree could trigger a cascade of random I/O operations: reading a page, modifying it, and writing it back to a completely different location on the flash storage. This is a phenomenon known as **Write Amplification**, and it is the silent killer of performance on SSDs. Not only does it waste bandwidth, but it also prematurely wears out the finite number of write-erase cycles that NAND flash can endure.

Out of this dilemma emerged a challenger: the Log-Structured Merge Tree (LSM Tree). First formalized by Patrick O'Neil et al. in a 1996 paper, the LSM Tree flipped the database storage paradigm on its head. Instead of updating data in place, it embraced an append-only philosophy. All writes are first batched in memory, then flushed to disk as immutable sorted files, and later merged (compacted) in the background. This design dramatically reduces random writes, turning most I/O into large, sequential operations. It trades read complexity for write efficiency—a trade-off that fits SSD characteristics like a glove.

Among the many implementations of LSM Trees, one stands out as the de facto standard for modern infrastructure: **RocksDB**. Born from Facebook’s need for a high-performance embedded key-value store for its social graph and real-time systems, RocksDB has become the bedrock of countless databases, streaming platforms, and caching layers. It is the engine behind MySQL via MyRocks, the storage layer of CockroachDB (via Pebble), the foundation of Apache Kafka’s tiered storage, and the core of popular NoSQL systems like Cassandra and ScyllaDB.

In this post, we will embark on a deep technical journey. First, we’ll dissect why B-Trees struggle on SSDs and quantify write amplification. Then, we’ll explore the LSM Tree architecture in detail—its memtables, SSTables, compactions, and bloom filters. We’ll uncover the subtle trade-offs between write amplification, read amplification, and space amplification. Next, we’ll zoom into RocksDB’s specific engineering optimizations: everything from its concurrent skip-list memtable to its dynamic leveling strategy and partitioned bloom filters. We’ll walk through a practical example of building a time-series database with RocksDB, and we’ll survey how real-world systems (MyRocks, CockroachDB, Cassandra) leverage LSM semantics. Finally, we’ll look ahead to the future of storage engines and what lies beyond the classic LSM Tree.

By the end, you will understand why the LSM Tree—and RocksDB in particular—has conquered the storage stack, and why it remains the default choice for any system that values sustained write performance in the age of flash.

---

## The B-Tree Paradigm and Its Hidden Costs

### In-Place Updates: The Double-Edged Sword

A B-Tree organizes data into nodes (typically 4 KB to 16 KB in size) that are stored in fixed-size pages on disk. Each node contains a sorted array of keys and pointers to child nodes. When a new key is inserted, the database must locate the correct leaf page, read it into memory, insert the key (or overwrite an existing value), and write the entire page back to disk. This is an _in-place update_: the page’s location on disk does not change, but its contents are replaced.

On an HDD, this works beautifully. The disk head seeks to the page’s location once, reads it, and then writes it back at the same cylinder after a single revolution. The seek time is amortized over the page’s size. Locality ensures that related data (e.g., consecutive records) are on the same or adjacent pages, further reducing seeks.

On an SSD, the physical reality is different. Flash memory is organized in blocks (typically 128 KB to 4 MB) that can only be erased and rewritten after being written once. An SSD controller performs a complex read-modify-erase-write cycle to update a single page. An insertion into a B-Tree’s leaf page may cause the page to split, scattering previously contiguous data across multiple new pages. The result: a single logical write translates into multiple physical writes.

### Quantifying Write Amplification

Write Amplification Factor (WAF) is the ratio of bytes written to the storage device to the bytes written by the application. For a B-Tree with a page size of 8 KB, each insert likely triggers:

- One page read (to find the insertion point, even if not needed—B-Trees may read the leaf only if the path is cached).
- One page write (the modified leaf).
- Possibly additional reads/writes for page splits and node updates.

In a worst-case scenario with a full random insert workload into a B-Tree that fits in the cache, the database might still write two to four times the user data. But when the B-Tree is larger than memory, the random I/O pattern becomes catastrophic. Each insert requires reading a random page from disk (a 4 KB read) and then writing it back (another 4 KB write). With no sequential pattern, the SSD’s internal flash translation layer (FTL) must garbage-collect stale pages, further amplifying writes. Studies have shown that B-Trees on SSDs can exhibit a WAF of 10–20x under high update rates.

### The Hidden Cost: Garbage Collection and Wear

SSDs have a limited lifespan measured in program/erase (P/E) cycles. Consumer SSDs may endure around 1,000 P/E cycles for TLC NAND; enterprise drives can handle 30,000 or more for SLC/MLC. Every write to the SSD consumes a portion of a P/E cycle at the block level. High write amplification means that even a moderate write workload can wear out an SSD in months instead of years.

But the impact goes beyond endurance. Write amplification consumes bandwidth that could be used for read requests. When the SSD is busy performing compaction and erase operations, user-facing reads may be delayed. This is the **write cliff**: performance that initially looks good degrades sharply as the drive fills up and internal fragmentation rises.

### Why Not Just Use a Write-Optimized B-Tree?

There have been attempts to modify B-Trees for SSDs. For example, the **Bε-tree** (Be-tree) uses temporary buffers in interior nodes to batch updates, reducing random writes. **WiredTiger**, the storage engine behind MongoDB, uses a B-tree variant that writes in “pages” that are append-only and then garbage-collected. However, these approaches still involve random reads during compaction or lookup, and they never fully eliminate the write amplification problem. The LSM Tree takes a more radical approach.

---

## The LSM Tree: A Radical Rethink

### Origins and Philosophy

The Log-Structured Merge Tree was introduced by Patrick O'Neil, Edward Cheng, Dieter Gawlick, and Elizabeth O'Neil in their 1996 paper “The Log-Structured Merge-Tree (LSM-Tree).” The key insight was to convert random writes into sequential ones by batching writes in memory, flushing them as large immutable files, and merging those files in the background. The name “log-structured” comes from the idea that the database behaves like an append-only log: new data is written to the end, and outdated data is cleaned later.

### Architecture Overview

An LSM Tree consists of several components:

1. **Memtable**: an in-memory data structure (often a skip list) that holds the most recent writes. All writes go first to the memtable.
2. **Write-Ahead Log (WAL)**: an optional durability mechanism. Before applying a write to the memtable, the database writes it to a WAL on disk, allowing recovery after a crash.
3. **Immutable Memtables**: when the memtable reaches a threshold size, it is made read-only, and a new memtable is created. The immutable memtable is flushed to disk as a **Sorted String Table (SSTable)**.
4. **SSTables**: immutable files on disk that contain sorted key-value pairs. Each SSTable has a bloom filter, index blocks, and data blocks.
5. **Levels**: SSTables are organized into levels (L0, L1, L2, ...). The newest files are in L0; older ones are in deeper levels.
6. **Compaction**: a background process that merges SSTables from one level into the next, removing stale entries and tombstones.

### The Append-Only Write Path

When a write request arrives:

1. Optionally, the key-value pair is appended to the WAL.
2. The pair is inserted into the current memtable (ordered by key).
3. When the memtable is full, it becomes immutable, and a new memtable is created.
4. The immutable memtable is flushed to disk as an SSTable in level 0 (L0).

Notice that the write path is completely sequential. The WAL is a sequential file; the memtable is a memory-resident structure; the flush writes a large sorted file sequentially. There is no random I/O involved. The only exception is reading from the WAL during recovery, but that is rare.

### The Read Path: A Merge of Sorted Lists

Reading is where the LSM Tree pays the price. Because data may be spread across multiple SSTables and the memtable, a point lookup must search in:

- The current memtable (if bloom filter says key is present).
- The immutable memtable(s) still in memory.
- All SSTables in L0 (which may overlap in key range).
- SSTables in L1, L2, etc., but typically only one per level due to non-overlapping ranges.

To speed up reads, LSM trees use **bloom filters** per SSTable. The bloom filter can quickly tell if a key is _not_ in the file, avoiding expensive I/O. If the bloom filter says “maybe present,” the database reads the index block to locate the data block, then reads the data block. This yields a worst-case read amplification of `(number of levels) + 1` block reads. For a typical leveled LSM tree with 6–7 levels, that’s 7–8 random reads per point lookup. With caching and bloom filters, the average is often much lower.

For range scans, the situation is better: the database can open iterators over multiple SSTables and merge them like a merge sort, streaming results sequentially. Bloom filters are not helpful for range scans because they only check point existence.

### Compaction: The Background Housekeeper

Compaction is the heart of the LSM Tree’s write-performance trade-off. It serves two purposes:

- **Remove stale data**: when a key is updated, an older version still exists in an older SSTable. Compaction merges files so that only the latest version remains.
- **Reduce read amplification**: by merging many small SSTables into fewer, larger, sorted ones, the database reduces the number of files that must be consulted during a read.

There are two dominant compaction strategies:

#### Size-Tiered Compaction (STC)

Used by Cassandra’s default, HBase, and LevelDB’s initial design (though LevelDB later switched). In size-tiered compaction, when a level accumulates a certain number of similar-sized files, they are merged into a single larger file in the next level. This strategy produces a tree where each level contains files of roughly the same size, and the size grows exponentially (e.g., level 0: 4 MB files, level 1: 16 MB files, level 2: 64 MB files, etc.). Write amplification is moderate, but read amplification can be high because you might need to check many files at each level, especially for range scans.

#### Leveled Compaction (LC)

Introduced by Google’s LevelDB and refined by RocksDB, leveled compaction enforces a strict structure: each level (except L0) contains a single sorted run of SSTables with non-overlapping key ranges. The total size of level `i` is roughly `factor` times larger than level `i-1` (default factor = 10). For example, L1 is 10 MB, L2 is 100 MB, L3 is 1 GB, etc. When a SSTable is compacted from L0 to L1, it is merged into the single sorted run of L1. This keeps the number of files per level low (usually 1–10), minimizing read amplification. The cost is higher write amplification, because data may be rewritten many times as it descends through the levels.

RocksDB’s **dynamic leveling** adjusts the target sizes based on actual data volume, preventing the last level from being too small and reducing write amplification. We’ll discuss this later.

---

## The Great Compaction Trade-Off

### Write Amplification in LSM Trees

Write amplification in an LSM tree comes from two sources:

1. **Flush**: writing the memtable to L0 as an SSTable. This is a 1:1 ratio of user-data written to disk (ignoring WAL). Flush is cheap.
2. **Compaction**: merging SSTables from level `i` into level `i+1`. In leveled compaction, each SSTable is involved in one compaction per level until it reaches the last level. If there are `L` levels (excluding L0), a data point written once may be rewritten `L` times during compactions. For a typical factor of 10, with 7 levels (L0 through L6), write amplification can reach 10–20. In size-tiered, write amplification is lower (2–5) because files are merged only when a threshold is reached, and they stay in higher levels longer.

RocksDB allows tuning compaction style per workload. For write-heavy workloads (e.g., time-series data), you might reduce the number of levels, increase the write buffer size, or use universal compaction (a variant of size-tiered). For read-heavy workloads, leveled compaction with a low factor (e.g., 5) provides excellent read performance.

### Read Amplification

Read amplification is the number of I/O operations (block reads) required to satisfy a point query. In leveled compaction with a bloom filter per SSTable, the worst-case read amplification is:

- Check bloom filter for each file in L0 (up to `max_open_files` parameter).
- For deeper levels, at most one file per level because key ranges are disjoint.
- If bloom filter says “maybe,” read index block (1 I/O) and data block (1 I/O).

Thus, read amplification ≈ `2 * (L0 files + number of levels)`. With 10 L0 files and 7 levels, that’s 34 block reads in the worst case. With a 1% false-positive rate on bloom filters, many lookups hit only a few files. Caching mitigates further.

For size-tiered compaction, read amplification can be much higher because you may need to check many files per level (e.g., 10 files per level, 7 levels = 70 possible files). This is why Cassandra recommends leveled compaction for read-heavy workloads despite its higher write amplification.

### Space Amplification: Tombstones and Stale Data

LSM trees do not update data in place; they write new versions and later clean them up. Until compaction runs, obsolete data and tombstones (deletion markers) occupy disk space. **Space amplification** is the ratio of disk space used to live data size. In a well-tuned LSM tree with frequent compaction, space amplification can be as low as 1.1 (10% overhead). In a lazy system, it can exceed 10x, especially if tombstones accumulate.

RocksDB has a **`max_space_amplification`** option that triggers forced compactions when the ratio exceeds a threshold. It also uses **range deletion** filters to quickly skip large ranges of deleted keys.

### The Unwritten Chapter: Compaction Throttling and I/O Scheduling

Compaction consumes CPU and I/O bandwidth. If it runs unchecked, it can degrade user-facing latency. Modern engines implement throttling:

- **Rate limiter**: RocksDB can limit compaction’s write rate to a configurable bytes-per-second.
- **Sub-compaction**: Large compaction jobs can be split into multiple sub-jobs that run in parallel, using multiple threads.
- **Priority scheduling**: Compactions of different priority (e.g., L0 → L1 is more urgent than L5 → L6) can be scheduled based on need.

RocksDB also supports **stalling** and **stopping** writes if compaction falls too far behind, preventing the memtable from growing unbounded.

---

## RocksDB's Secret Sauce: Engineering for Flash

RocksDB was born from the lessons learned with LevelDB and Google’s Bigtable. Facebook’s engineers (led by Dhruba Borthakur) improved upon LevelDB in almost every dimension: performance, configurability, and flash-awareness. Let’s examine the key features that make RocksDB the powerhouse of LSM storage.

### Concurrent Memtable: Skip Lists vs. Insert-Heavy Workloads

LevelDB uses a single sorted vector-based memtable protected by a mutex. This serializes all writes. RocksDB replaced this with a **concurrent skip list** (lock-free for reads, fine-grained locks for writes). Multiple threads can concurrently insert into the memtable without blocking each other, dramatically increasing write throughput on multi-core machines. The skip list also provides O(log n) read performance, comparable to a balanced tree but simpler to implement concurrently.

RocksDB also supports a **vector memtable** and a **hash-linked-list memtable** (now deprecated). The default is the skip list.

### Partitioned Bloom Filters

A bloom filter for a large SSTable (e.g., 2 GB) may be too large to fit in memory, and reading the entire filter on a lookup would waste I/O. RocksDB introduced **partitioned bloom filters**: the key range is divided into small partitions (e.g., 4 MB each), each with its own bloom filter. During a read, the database first reads only the relevant partition’s filter (one I/O). If the filter says “maybe,” it reads the data block. This reduces the memory overhead and the per-lookup I/O for large files.

### Block-Based Table (BBT) vs. Plain Table

RocksDB’s default SSTable format is the **Block-Based Table**. Data is compressed into blocks (default 4 KB, configurable). Each block is compressed using Snappy, ZSTD, LZ4, etc. The index block stores the first key of each block, allowing binary search over the index. The bloom filter is separate from the index.

For read-heavy workloads with small values, RocksDB offers the **Plain Table** format, which stores keys and values uncompressed in a sorted array. This trades compression for faster reads because data can be binary-searched directly without decompressing blocks. Plain table is less common but useful for certain in-memory use cases.

### Direct I/O and O_DIRECT

By default, RocksDB uses the operating system’s page cache for reads and writes. However, the page cache can cause double buffering (one in the RocksDB block cache, one in OS cache). To avoid this, RocksDB supports **Direct I/O** (O_DIRECT) for SSTable reads and writes. When enabled, data bypasses the OS cache, reducing CPU overhead and giving RocksDB full control over caching via its own block cache (LRU or clock-based). Direct I/O is especially beneficial for large, long-lived instances where the page cache is redundant.

### Write-Ahead Log (WAL) and Durability Tuning

RocksDB’s WAL is a sequential file that records all modifications. By default, after each write, `sync` is called on the WAL to ensure durability. This can be a bottleneck. RocksDB provides several options:

- **`sync = false`**: batch WAL syncs periodically (e.g., every 1 microsecond). Increases throughput at the risk of losing the last few writes.
- **Manual WAL** management: the user can call `FlushWAL()` explicitly, or disable WAL entirely for non-durable use cases (e.g., temporary state, caches).
- **WAL recycling**: instead of creating a new WAL after each flush, RocksDB can recycle the old WAL file, reducing file system overhead.

### Merge Operators

One of RocksDB’s most innovative features is the **Merge Operator**. Often, an application needs to update a value incrementally—for example, incrementing a counter, appending to a list, or updating a JSON field. Without a merge operator, you would read the old value, apply the change, and write the new value (read-modify-write). This adds a read to every write.

With a merge operator, you define a function that takes an existing value and a partial update (the “merge operand”) and produces a new value. The write path becomes: write the operand as a “merge record” to the memtable. The read path applies all successive merge records in order. During compaction, merge records can be combined or applied to the base value, reducing I/O. For example, a counter increment becomes a single small write (e.g., `+1`), and the read sees the accumulated result.

Merge operators are powerful but require careful design to avoid performance pitfalls. RocksDB provides built-in merge operators for integers (AssociativeMergeOperator) and strings (StringAppendOperator). User-defined operators can be registered.

### Compression and Dictionary Training

RocksDB supports multiple compression algorithms at the data block level and at the SSTable level (via the `compression_per_level` option). For deeper levels (which are less frequently read), stronger compression (ZSTD, LZ4) is advisable to save space. RocksDB also allows **compression dictionary training**: you can provide a sample of data to build a dictionary that improves compression ratios for small values.

### Write Batch and Group Commit

RocksDB supports **WriteBatch**, a container for multiple atomic writes. A batch can contain puts, deletes, and merges. When applied, the entire batch is written to the WAL and inserted into memtable atomically. Internally, RocksDB can group multiple small write batches from different threads into a single `sync` call (**group commit**), significantly reducing the number of disk fsyncs.

### Performance Tuning Parameters

RocksDB has hundreds of options, but a few are critical:

- `write_buffer_size`: size of each memtable (default 64 MB). Larger memtables reduce flush frequency and compaction overhead but increase memory usage and potential write stall during flush.
- `max_write_buffer_number`: number of memtables kept in memory before stalling writes (default 2). Increasing this can smooth out bursts of writes.
- `min_write_buffer_number_to_merge`: number of memtables to merge before flushing (default 1; set to 2 to trigger a merge flush which produces larger, more efficient SSTables).
- `level0_file_num_compaction_trigger`: number of L0 files that trigger a compaction to L1 (default 4). Lower values keep read amplification low but increase compaction frequency.
- `target_file_size_base` and `target_file_size_multiplier`: control the size of SSTables at each level.
- `max_bytes_for_level_base` and `max_bytes_for_level_multiplier`: set the total size of each level (default 256 MB for L1, multiplier 10).
- `bloom_locality`: number of bloom filter partitions per SSTable (default 0 = one global filter).

---

## Practical Example: Building a Time-Series Database with RocksDB

Time-series data is a perfect use case for LSM trees. Writes are append-heavy (new metrics arrive continuously), while reads are typically recent-data queries or range scans. Write amplification matters less because data is rarely updated in place; each new data point is a new key. Let’s walk through building a simple timeseries store using RocksDB.

### Design Considerations

We’ll store measurements as `(metric_name, timestamp) -> value`. The key format is a concatenation of the metric name (string) and a big-endian timestamp (e.g., 64-bit integer). Using big-endian ensures that sorting by key orders by metric then by time, enabling efficient range scans over a time window.

We want to avoid tombstones because deletions are rare. Compaction will naturally clean up older data if we configure time-to-live (TTL) or use a prefix extractor to drop entire metric groups.

### Code Example

```python
import rocksdb

# Open database with optimizations for write-heavy workload
opts = rocksdb.Options()
opts.create_if_missing = True
opts.max_open_files = 300000
opts.write_buffer_size = 64 * 1024 * 1024      # 64 MB memtable
opts.max_write_buffer_number = 3
opts.target_file_size_base = 64 * 1024 * 1024  # 64 MB SSTable base
opts.compression = rocksdb.CompressionType.zstd_compression
opts.level0_file_num_compaction_trigger = 4
opts.max_bytes_for_level_base = 512 * 1024 * 1024  # 512 MB L1

# Use leveled compaction
opts.compaction_style = rocksdb.CompactionStyle.level_compaction

db = rocksdb.DB("timeseries_db", opts)

def put_metric(metric, timestamp, value):
    key = metric.encode() + timestamp.to_bytes(8, 'big')
    db.put(key, value)

def get_metric(metric, timestamp):
    key = metric.encode() + timestamp.to_bytes(8, 'big')
    return db.get(key)

# Write 1 million points
import time, random
start = time.time()
for i in range(1_000_000):
    ts = int(time.time() * 1000)  # millisecond accurate
    put_metric("cpu_util", ts, random.random())
print(f"Wrote 1M points in {time.time()-start:.2f}s")

# Range scan: read last hour of cpu_util
prefix = b"cpu_util"
start_key = prefix + (0).to_bytes(8, 'big')
end_key = prefix + b'\xff' * 8  # max key

it = db.itervalues()
it.seek(start_key)
count = 0
for v in it:
    if it.key().startswith(end_key[:len(prefix)]):
        break
    count += 1
print(f"Scanned {count} values")
```

This simple example writes millions of points per second on modern hardware. In practice, you would batch writes using WriteBatch for higher throughput:

```python
batch = rocksdb.WriteBatch()
for ts, value in new_data:
    key = metric.encode() + ts.to_bytes(8, 'big')
    batch.put(key, value)
db.write(batch)
```

### Performance Tuning for Time-Series

Time-series workloads often have a “hot” recent window and “cold” older data. To reduce compaction overhead for old data, consider:

- **TTL**: use `db.compact_range()` periodically, or enable compaction filter to drop keys older than a threshold.
- **Separate database per time bucket**: store data in daily or hourly RocksDB instances. When a bucket is no longer written, close it and only serve reads.
- **Use prefix bloom filter**: if you frequently query by metric prefix (e.g., “cpu_util”), RocksDB can use a prefix bloom filter to skip scanning SSTables that don’t contain the prefix, significantly speeding up range scans.

---

## LSM in the Wild: Case Studies

### MyRocks: MySQL on RocksDB

Facebook’s MyRocks replaced InnoDB’s B-tree with RocksDB for some MySQL deployments. The motivation was to reduce write amplification for their user-facing workloads (feed stories, likes, notifications). MyRocks achieved 2–3x less storage space and eliminated write stalls caused by InnoDB’s doublewrite buffer and flushing. It also brought faster replication due to smaller transaction logs.

Key MyRocks optimizations:

- **Secondary indexes**: stored as separate column families (RocksDB’s partitioning mechanism).
- **Bloom filters on indexes**: enable fast point lookups for unique key constraints.
- **Compression**: ZSTD at level 3 reduced storage by 2x for their data.

### CockroachDB and Pebble

CockroachDB, a distributed SQL database, originally used a LevelDB-derived engine, then switched to a RocksDB port, and finally built its own LSM engine: **Pebble**. Pebble is a Go implementation of an LSM tree, designed specifically for CockroachDB’s needs: lower memory footprint, deterministic compaction behavior, and better performance under concurrent workloads. Pebble’s compaction scheduler is tuned for multi-tenant, multi-node deployments where balancing I/O across all replicas is critical.

### Cassandra and ScyllaDB

Apache Cassandra is a wide-column NoSQL database. Its LSM implementation (via SSTables) offers configurable compaction strategies:

- **SizeTieredCompactionStrategy (STCS)**: default, good for write-heavy workloads with low read requirements.
- **LeveledCompactionStrategy (LCS)**: lower read amplification, used for read-heavy or latency-sensitive applications.
- **TimeWindowCompactionStrategy (TWCS)**: designed for time-series data, where data is strictly ordered by write time. TWCS divides time into windows and compacts only within a window, drastically reducing compaction overhead.

ScyllaDB, a C++ rewrite of Cassandra, uses a shared-nothing architecture and has further optimized LSM compaction with **incremental compaction** (streaming merge) to avoid full disk thrashing.

### Apache Kafka Tiered Storage

Kafka 3.0 introduced tiered storage using remote object stores (S3, GCS) with a local cache. The local cache uses an LSM-ish structure (RocksDB) to store recent data indexed by offset and partition, enabling low-latency reads without fetching from the cloud.

---

## Beyond LSM: Future Directions

### WiredTiger’s Hybrid Approach

MongoDB’s WiredTiger storage engine uses a B-tree variant (called LSM-like) that features **log-structured** semantics for writes: updates are written to a concurrent tree in memory and later consolidated. It also includes a “page version” system that can revert to older versions for snapshot isolation. It’s a hybrid that balances the trade-offs.

### Computational Storage and Offloading

The next frontier is to move compaction and bloom filter filtering into the SSD controller itself. Computational storage drives (e.g., Samsung’s SmartSSD, NGD Systems) allow running custom code on the drive’s ARM processor. This could reduce host CPU usage and network I/O. RocksDB could offload compaction filtering to the drive, making the tree even more efficient.

### Persistent Memory

Intel Optane (now discontinued) offered byte-addressable persistent memory with latency closer to DRAM than NAND. LSM trees could benefit immensely: the memtable could be made persistent directly in Optane, eliminating the WAL entirely. Compaction could become a simple pointer swap. However, Optane’s limited capacity and cost prevented widespread adoption. With CXL-attached memory, we may see a resurgence of tiered memory where part of the LSM tree lives in a slower, persistent tier.

### Simpler Trees: LSM + B-Tree Hybrid

Research continues into combining the two philosophies. The **LSM-Tree with Buffered Perturbation** or **Be-tree** adds intermediate buffers in B-tree nodes. The **BuzzTree** uses a write-optimized B-tree with a memory buffer. These may replace classical LSM for certain workloads where read latency is paramount.

---

## Conclusion: The Art of the Write Revisited

The LSM Tree emerged from a simple observation: the most expensive operation in modern storage is random I/O. By batching writes, converting random updates into sequential flushes, and organizing data into immutable sorted files, the LSM Tree turned the weakness of the B-tree into a strength. RocksDB then added a decade of engineering refinement: concurrent memtables, partitioned bloom filters, merge operators, dynamic leveling, and tuning knobs that let experts carve out the optimal trade-off space for any workload.

Today, the LSM Tree, in the form of RocksDB (or its derivatives Pebble, LevelDB, ScyllaDB’s engine), is the backbone of the modern data infrastructure stack. It powers the write-heavy workloads of social networks, real-time analytics, IoT, and streaming. It has conquered the storage stack not by being a perfect solution for every case, but by being the best compromise for the era of flash storage.

Yet the art of the write is never finished. As hardware evolves—new types of non-volatile memory, computational storage, disaggregated architectures—the next generation of storage engines will again challenge our assumptions. But the lessons of RocksDB will remain: understand your hardware’s bottleneck, embrace sequential I/O, and never stop questioning the tyranny of past designs.

The B-Tree is not dead. It still excels at point queries on efficiently cached data. But for the relentless flood of writes that defines today’s applications, the LSM Tree remains the ultimate artist of the write.

---

_If you enjoyed this deep dive, consider subscribing to our newsletter. Next up: “Reading Between the Lines: A Practical Guide to RocksDB Block Cache and Bloom Filter Tuning.”_
