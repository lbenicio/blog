---
title: "Implementing A Non Volatile Memory Friendly Hash Table: Nvhtm With Failure Atomic Operations"
description: "A comprehensive technical exploration of implementing a non volatile memory friendly hash table: nvhtm with failure atomic operations, covering key concepts, practical implementations, and real-world applications."
date: "2023-12-18"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/implementing-a-non-volatile-memory-friendly-hash-table-nvhtm-with-failure-atomic-operations.png"
coverAlt: "Technical visualization representing implementing a non volatile memory friendly hash table: nvhtm with failure atomic operations"
---

## The Fallacy of Volatility: Why Non-Volatile Memory is Rewriting the Rules of System Design

### 1. The Crash That Shouldn’t Have Happened

The crash came without warning. One moment, a high-frequency trading platform was processing millions of orders per second against a massive in-memory hash table. The next, a power flicker. The servers stayed online thanks to battery backups, but the damage was done. The hash table, held in volatile DRAM, was gone. Not just corrupted—obliterated. The rebuild took forty-seven minutes. In that time, the firm lost an estimated $2.3 million in missed trades and had to manually reconcile another $800,000 worth of partially executed orders. The engineers had done everything right: they used proven algorithms, had redundant power supplies, and ran nightly backups. But they had built their system around an assumption that is now dangerously outdated—that memory is fast, cheap, and above all, volatile.

This scenario, or ones like it, is becoming increasingly common as data-intensive applications push against the fundamental limits of traditional system architectures. For decades, the memory hierarchy was simple: you had fast, volatile DRAM that forgot everything when power was lost, and you had slow, persistent storage on SSDs or HDDs that remembered everything but struggled to keep up with processing speeds. Engineers had to make an uncomfortable choice: accept the performance ceiling of disk-based storage, or accept the volatility of memory and spend enormous engineering effort on crash recovery, logging, and checkpointing. It was a binary tradeoff that constrained how we thought about data structures, algorithms, and entire system designs.

That binary is now breaking. The arrival of Non-Volatile Memory (NVM)—in the form of Intel Optane Persistent Memory and the broader class of byte-addressable persistent memory technologies—has fundamentally rewritten the rules. NVM sits directly on the memory bus, accessed at speeds approaching DRAM, yet retains data across power cycles. It offers byte-addressability, meaning you can read and write individual words rather than whole blocks like an SSD. For the first time, we can build data structures that are simultaneously fast and durable, in-place and crash-consistent. The implications are staggering: databases that never lose a committed transaction, key-value stores with sub-microsecond recovery, and algorithms that treat persistence as a natural property rather than an expensive afterthought.

But with great power comes great complexity. NVM is not just “slower DRAM that doesn’t forget.” It has its own quirks: asymmetric read/write speeds, limited write endurance, and a completely new programming model where a power failure can leave data structures in an inconsistent state if we naively modify them in place. The old abstraction of “write to disk when you must, keep it in RAM when you can” no longer applies. We need new data structures, new concurrency models, and a new mental model of what memory is.

In this post, we will explore the world of non-volatile memory from the ground up. We’ll start with the hardware characteristics that make NVM unique, then dive into the fundamental challenges of building crash-consistent data structures. Using a persistent hash table as our running example, we’ll walk through the implementation details, the pitfalls, and the design patterns that work. We’ll look at real-world applications like Redis, MongoDB, and Memcached that are adopting NVM, and we’ll peek into the future with CXL-based memory pooling. By the end, you will understand not just what NVM is, but how to think in a world where memory persists.

### 2. The Old Memory Hierarchy: A Tale of Two Extremes

To appreciate the revolution that NVM represents, we must first understand the hierarchy it replaces. For the last fifty years, computer memory has been organized in a pyramid: from tiny, ultrafast CPU registers at the top, down through L1/L2/L3 caches, then main memory (DRAM), then solid-state drives (SSDs), and finally spinning hard drives (HDDs). Each level is larger, slower, and cheaper per byte than the one above it. The key property that defined the two largest levels—DRAM and persistent storage—was volatility.

**Volatile DRAM** (Dynamic Random-Access Memory) is the workhorse of main memory. It is fast: access times of 50–100 nanoseconds, bandwidths of tens of gigabytes per second. It is byte-addressable: you can read or write a single 64-bit word with a single load/store instruction. But it requires constant power to refresh the capacitors that hold each bit. Lose power, and within milliseconds the data is gone. This volatility forced system designers to treat DRAM as a temporary workspace. If you wanted data to survive a crash, you had to copy it to a persistent medium—typically a disk—using explicit operations. That copying is slow, so you try to minimize it, leading to complex caching, write-ahead logging, and checkpointing schemes.

**Persistent Storage** (SSDs and HDDs) is large (terabytes) and durable (data remains even when powered off). But it is orders of magnitude slower than DRAM. A typical NVMe SSD has access times around 10–20 microseconds—about 200 times slower than DRAM. And it operates on blocks, not bytes. To read or write a single byte, the operating system must read an entire 4KB page, modify it, and write it back. This block orientation makes in-place updates inefficient and forces a read-modify-write cycle. Moreover, storage is accessed through a complex software stack: system calls, file systems, block layers, device drivers. Even with direct I/O (O_DIRECT), you incur context switches and DMA transfers.

The performance gap between DRAM and persistent storage led to a fundamental design tension. You could keep your working dataset in DRAM and achieve incredible throughput, but you risked total data loss on crash. Or you could keep your data on disk and pay a 100x to 1000x performance penalty. Most systems chose a hybrid: keep a copy in DRAM for fast access, and write logs or snapshots to disk periodically. This is the approach taken by database systems like PostgreSQL (checkpointing, WAL), key-value stores like Redis (periodic snapshots and append-only files), and even operating systems (dirty page flushing). But these schemes are complex. They introduce latency spikes during checkpointing. They leave windows of vulnerability between flushes. And they consume enormous engineering effort to get right.

The tradeoff was accepted because there was no alternative. Engineers joked about the “memory wall” and the “I/O gap.” But the joke is no longer funny when a power flicker costs $3 million.

### 3. What is Non-Volatile Memory? A Technical Deep Dive

Non-Volatile Memory (NVM) is a class of computer memory that retains its contents even when power is removed. But not all NVM is created equal. The technology that has captured the industry’s attention—and that we will focus on here—is **byte-addressable persistent memory**, also known as Storage Class Memory (SCM). The most prominent commercial example is Intel’s Optane Persistent Memory (now discontinued, but the concepts live on in other technologies like Samsung’s Z-NAND, SK Hynix’s 3D XPoint variants, and the emerging CXL-attached memory modules).

Let’s break down its key characteristics:

**Byte-addressability.** Unlike an SSD, which must read and write in blocks (typically 4KB or larger), persistent memory can be accessed with CPU load and store instructions at the granularity of a single byte or word. This is the same interface as DRAM. The CPU issues a load from a virtual address, and the memory controller fetches the data from the NVM DIMM. This means we can manipulate data structures in place without serializing/deserializing to block buffers. It also means we can use existing CPU caches to accelerate reads and writes.

**Latency and Bandwidth.** Optane Persistent Memory has read latency around 300–400 nanoseconds, roughly 3–4 times slower than DRAM (which is ~80–100 ns). Write latency is higher, around 500–900 ns. Bandwidth is also lower: a single Optane module can deliver about 6–8 GB/s for reads and 2–3 GB/s for writes, compared to DDR4’s ~20 GB/s. So it is not a drop-in replacement for DRAM; it is a new tier between DRAM and SSD. But 300 ns is still 10–50x faster than the fastest NVMe SSD (10–20 µs). The order-of-magnitude difference is critical for data-intensive workloads.

**Persistence Model.** The most important and tricky aspect is that a write to persistent memory is not immediately durable. The data may sit in the CPU’s caches (L1, L2, L3) for hundreds of cycles before being evicted to the NVM device. If power is lost while data is still in the cache, it is lost. Therefore, to guarantee that a write has reached the NVM medium, the programmer must explicitly flush cache lines using the `CLFLUSH`, `CLFLUSHOPT`, or `CLWB` instructions, followed by a memory fence (`SFENCE`) to ensure ordering. This is a radical departure from DRAM programming, where you can write and forget. With NVM, you must reason about the hardware’s write-back buffers and the power-fail atomicity of stores.

**Write Endurance.** Like all flash-based memories, NVM cells wear out after a certain number of writes. Intel’s Optane modules are rated for about 1–2 million write cycles per cell (DRAM has effectively unlimited writes). This means you cannot blindly use NVM as a swap space for DRAM. Algorithms must be aware of write amplification and minimize unnecessary updates. In practice, the endurance is sufficient for most database and caching workloads, but pathological patterns (e.g., repeatedly updating a hot counter) can kill a module in months. Designs often use a small DRAM write cache to batch writes, or employ wear-leveling techniques at the hardware and software levels.

**Asymmetric Performance.** Writes are generally slower and more expensive than reads. This asymmetry favors read-heavy workloads. Copy-on-write or log-structured approaches are often better than in-place updates.

**Capacity.** NVM modules can be dense. An Optane DIMM could hold 128 GB, 256 GB, or 512 GB in a single slot, while a DDR4 DIMM tops out at 64 GB (at the time). This makes it possible to have terabytes of persistent memory in a single server, far cheaper per GB than DRAM, though more expensive than SSD.

### 4. The Fundamental Challenge: Crash Consistency with NVM

The promise of NVM is that you can have data structures that are both fast and durable. But achieving that durability is surprisingly hard. The naive approach—just allocate a hash table in NVM and use it like DRAM—will fail catastrophically on a power failure. Why? Because modifying a data structure typically involves multiple writes: updating a pointer, adjusting a length field, writing the new value. If power is lost after the first write but before the last, the structure becomes inconsistent. This is the same problem that databases solve with write-ahead logging and atomic commit (ACID). But those mechanisms were designed for block storage. With NVM, we need lightweight, CPU-efficient atomicity.

Let’s illustrate with a simple example: inserting a key-value pair into a hash table with separate chaining (linked lists). The steps might be:

1. Allocate a new node in NVM.
2. Write the key and value into the node.
3. Write the node’s `next` pointer to point to the current head of the bucket’s list.
4. Update the bucket’s head pointer to point to the new node.

If a crash occurs after step 2 but before step 4, the new node is orphaned (no pointer to it from anywhere) and memory is leaked. If a crash occurs after step 3 but before step 4, then the head pointer still points to the old head, but the old head’s `next` pointer might still point to the rest of the list (depending on whether we updated that as well). Actually, in a typical linked list insertion at the head, you only modify the head pointer and the new node’s `next` pointer. The ordering between these two writes matters. If the head pointer is updated first, then the new node’s `next` is garbage (uninitialized), and the list is corrupted. If the new node’s `next` is written first, then the head pointer update is the final step, which is safer. But even then, if the head pointer write is not persisted (and the cache flush is not called), the list appears empty after reboot.

To make this atomic, we need a mechanism to ensure that either all updates happen, or none. This is the essence of **failure-atomicity**. The classic approach is to use a **logging** or **shadow-copy** technique. For in-place updates, we can use **persistent transactional memory**, where all modifications are recorded in an undo log before they are applied, or a redo log applied after all writes are buffered. The log itself must be written and flushed in a specific order.

Let’s look at a concrete example using the Intel Persistent Memory Development Kit (PMDK). PMDK provides a library, `libpmemobj`, that offers transactional operations on persistent memory. Here is a simplified snippet for inserting into a hash table using PMDK transactions:

```c
#include <libpmemobj.h>

POBJ_LAYOUT_BEGIN(hashtable);
POBJ_LAYOUT_ROOT(hashtable, struct hash_table);
POBJ_LAYOUT_TOID(hashtable, struct entry);
POBJ_LAYOUT_END(hashtable);

struct entry {
    char key[64];
    char value[256];
    PMEMoid next; // persistent object ID
};

struct hash_table {
    PMEMoid buckets[TABLE_SIZE];
};

int insert_entry(PMEMobjpool *pop, const char *key, const char *value)
{
    TX_BEGIN(pop) {
        // Allocate a new entry persistently
        PMEMoid new_entry_oid = TX_NEW(struct entry);
        struct entry *new_entry = pmemobj_direct(new_entry_oid);
        // Write key and value (within transaction, they are logged)
        TX_MEMCPY(new_entry->key, key, strlen(key)+1);
        TX_MEMCPY(new_entry->value, value, strlen(value)+1);

        // Get bucket index
        uint32_t bucket_idx = hash(key) % TABLE_SIZE;
        PMEMoid *bucket_ptr = &(pmemobj_direct(pmemobj_root(pop, sizeof(struct hash_table)))->buckets[bucket_idx]);

        // Make new entry point to current head
        new_entry->next = *bucket_ptr; // assign PMEMoid

        // Update bucket head to new entry
        TX_SET(*bucket_ptr, new_entry_oid); // atomic assignment
    } TX_END

    return 0;
}
```

This code uses `TX_BEGIN`/`TX_END` to define a transaction. Inside, any persistent allocations and memory copies are logged so that if a crash occurs, the transaction can be rolled back. The `TX_SET` macro records the old value of the bucket pointer and the new value, ensuring atomic update. On recovery, the PMDK library replays or undoes any incomplete transactions. The overhead of a transaction is small—a few hundred nanoseconds—but it is not zero.

The critical lesson: **you cannot just treat NVM like DRAM**. Every data structure that needs to survive crashes must be designed with ordering and atomicity in mind. Fortunately, many common structures—hash tables, B-trees, queues—have well-known persistent variants. Let’s explore a few.

### 5. Persistent Data Structures: From Theory to Practice

#### 5.1 Persistent Hash Tables

The hash table is the quintessential in-memory data structure: fast lookups, inserts, and deletes in amortized O(1). For NVM, we need a version that handles failures without corruption. The example above uses transactional allocation and updates. Another popular approach is **path-hashing** or **cuckoo hashing** adapted for persistence. But the most robust design for NVM is the **B-tree**-inspired hash table used by Intel’s own PMDK examples, or the **Level Hashing** technique proposed by researchers.

A simpler method for small systems is to use an **append-only log** for key-value pairs, and rebuild the hash table on restart. But that loses the benefit of in-memory access. A better way: use a **two-level structure** where the hash table itself is in DRAM as a volatile index, and the actual key-value data resides in NVM. On crash, the NVM data is intact, and the volatile index can be rebuilt by scanning the NVM log. This hybrid approach combines the speed of DRAM indexing with NVM durability. Redis’s `Redis on Flash` technology uses a similar idea.

#### 5.2 Persistent B-Trees

B-trees are the backbone of database indexes (like B+ trees). In a persistent B-tree, every node modification (split, merge, update) must be atomic. A classic design is **P-CLHT** (Persistent Concurrent Linked Hash Table) but for trees, **NV-Tree** and **wB+Tree** are notable. The key insight: instead of in-place updates, use **log-structured** writes. When a leaf node is updated, write a new version of the leaf to a free slot, update the parent pointer atomically, and eventually garbage-collect the old version. This avoids write amplification and provides a natural undo/redo mechanism.

#### 5.3 Persistent Queues (Ring Buffers)

A producer-consumer queue is a classic pattern. In NVM, you can implement a lock-free ring buffer using atomic operations on indices. But to make it persistent, you must flush each write in order. A common approach: write the data first, then flush, then update the write index with a store followed by flush. On recovery, you iterate from the last known write index to find partially written entries. This is similar to a write-ahead log.

#### 5.4 Code Example: A Simple Persistent Log

Let’s implement a minimal persistent write-ahead log (WAL) used for crash recovery. This is the foundation of many databases.

```c
#include <libpmem.h>

#define LOG_SIZE (1024 * 1024) // 1 MB

struct log_entry {
    size_t size;   // number of bytes of data
    char data[];   // flexible array
};

struct wal_log {
    size_t write_offset; // in NVM
    size_t flush_offset; // last flushed
    char buffer[];       // rest is NVM mapped
};

int wal_append(struct wal_log *log, const char *data, size_t len)
{
    // Check space
    if (log->write_offset + sizeof(struct log_entry) + len > LOG_SIZE)
        return -1; // need to wrap or resize

    // Compute address of new entry
    struct log_entry *entry = (struct log_entry *)(log->buffer + log->write_offset);
    entry->size = len;
    memcpy(entry->data, data, len);

    // Flush the entire entry to NVM
    size_t entry_size = sizeof(struct log_entry) + len;
    pmem_persist(entry, entry_size); // includes cache line flush + fence

    // Update write offset (this store is also persisted)
    log->write_offset += entry_size;
    pmem_persist(&log->write_offset, sizeof(log->write_offset));

    // Now the entry is durable
    return 0;
}

void wal_recover(struct wal_log *log, void (*replay)(const char *data, size_t len))
{
    size_t offset = 0;
    while (offset < log->write_offset) {
        struct log_entry *entry = (struct log_entry *)(log->buffer + offset);
        if (entry->size == 0xFFFFFFFF) {
            // corrupted? maybe incomplete write
            break;
        }
        replay(entry->data, entry->size);
        offset += sizeof(struct log_entry) + entry->size;
    }
}
```

Note: In production, you would also handle the case where a crash occurred during the writing of entry->size itself. That’s why we write the size last (or use checksums). But this gives a flavor.

### 6. Case Study: Rebuilding the High-Frequency Trading Engine

Let’s return to our opening crash scenario. The trading firm had a hash table of order books, each keyed by symbol and containing a tree of price levels. The entire table was in DRAM. After the crash, they spent 47 minutes rebuilding from nightly backups and partially replaying network logs.

If they had used NVM, the recovery would be nearly instantaneous. Here’s how:

**Design A: Full NVM Hash Table.** Use a persistent hash table (like the one with PMDK transactions) to store the order books. When a power failure occurs and servers come back, the hash table is already in NVM, consistent. They just need to re-open the PMEM pool. With mmap-based access, the process can resume execution almost immediately. The only missing data would be the in-flight orders that had not yet been flushed to the table. But since the trading engine would be designed to persist each order before acknowledging it to the network (using our WAL), no orders are lost. Recovery time: less than a second.

**Design B: Hybrid DRAM + NVM.** Keep the hot index in DRAM for speed, but store the actual order book data in NVM. Use a write-ahead log in NVM to record every mutation. On restart, replay the log to rebuild the DRAM index. This is faster than full persistence because DRAM writes are fast. With a compact log, replay of a few million transactions might take a few seconds, still far less than 47 minutes. The firm would have saved millions.

The key is to design the system so that the **critical path** (acknowledgment to the client) includes a guarantee that data is in NVM. In trading, every microsecond counts, so the latency overhead of flushing must be minimized. Intel’s `CLWB` instruction (cache line write back) can be used in conjunction with `SFENCE` to flush only the necessary cache lines, not the entire cache. With careful batching, the overhead can be kept under 100 nanoseconds.

### 7. Performance Considerations and Tradeoffs

Is NVM a silver bullet? No. It introduces new performance tradeoffs:

- **Write vs. Read.** Writes to NVM are slower and consume endurance. If your workload is write-heavy, you might better off with a small DRAM write cache and periodic flushes.
- **Cache efficiency.** Since the CPU caches are volatile, you must flush to NVM to guarantee persistence. Flushing destroys cache locality and can degrade performance if done too frequently.
- **Memory bandwidth contention.** NVM modules share the memory bus with DRAM. Mixing DRAM and NVM on the same channels can reduce bandwidth available to DRAM.
- **Cost per GB.** NVM is cheaper than DRAM but more expensive than SSD. For read-mostly, large datasets, SSD plus DRAM caching may still be more cost-effective.

Nevertheless, for many workloads—especially those requiring fast crash recovery and high availability—NVM is transformative.

### 8. Real-World Adoption: Databases, Key-Value Stores, and More

**Oracle Database** has supported NVM since version 19c, allowing the Database Smart Flash Cache to be replaced by persistent memory. **SQL Server 2019** introduced support for NVDIMM-N (non-volatile dual in-line memory module) to accelerate transaction log writes. **Redis** has experimental support for NVM through the `redis-pmem` fork, which stores datasets in persistent memory to avoid snapshotting. **MongoDB**’s WiredTiger storage engine can use NVM for the journal and cache. **Memcached** has patches to store data in NVM, reducing cold-start times.

In the cloud, AWS offers "persistent memory" instances (i3en.metal, etc.) that allow customers to use NVM for high-performance databases. Google Cloud and Azure are also exploring similar offerings.

### 9. The Future: CXL and Memory Pooling

The discontinuation of Intel Optane does not mean the end of NVM. New technologies like **CXL** (Compute Express Link) enable memory pooling across servers, and NVDIMMs can be attached via CXL. Samsung and others are developing CXL-attached memory expanders that could provide terabytes of persistent memory at low latency. These fabrics will allow disaggregated memory pools where a server can borrow NVM from a remote node with cache-coherent access. This opens possibilities for fault-tolerant distributed data structures.

### 10. Conclusion: Rethinking the Memory Abstraction

The crash story that opened this post is a cautionary tale of outdated assumptions. We built our software stack around volatile DRAM and slow disks, and we paid the price in complexity and vulnerability. NVM does not just add a new tier; it changes the fundamental performance characteristics of memory. With careful design, we can build systems that are both fast and durable, without the Byzantine crash-recovery code.

But embracing NVM requires a shift in thinking. Persistent memory programming is not just "mmap a file and go." It demands meticulous attention to ordering, atomicity, and flushing. New tools like PMDK, libpmem, and persistent memory libraries for Rust and Go are making this easier, but the underlying principles remain the same.

As we move toward exascale computing, AI inference at the edge, and real-time financial systems, the ability to retain data in memory across failures becomes not just a convenience but a necessity. The future of computing is persistent, byte-addressable, and fast. It’s time to rewrite the rules.

_Author’s note: All code examples are simplified for illustration. Real production systems should be thoroughly tested with fault injection._
