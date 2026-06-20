---
title: "Designing A Non Volatile Memory (Nvm) File System: Dax, Pmdk, And Fault Tolerance For Persistent Heaps"
description: "A comprehensive technical exploration of designing a non volatile memory (nvm) file system: dax, pmdk, and fault tolerance for persistent heaps, covering key concepts, practical implementations, and real-world applications."
date: "2020-11-07"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/designing-a-non-volatile-memory-(nvm)-file-system-dax,-pmdk,-and-fault-tolerance-for-persistent-heaps.png"
coverAlt: "Technical visualization representing designing a non volatile memory (nvm) file system: dax, pmdk, and fault tolerance for persistent heaps"
---

# The Persistent Memory Revolution: Rewriting the Rules of Data Storage

## Introduction: The End of the Memory-Storage Divide

The gap between volatile memory and persistent storage has defined computing architecture for decades. We build systems on the assumption that data must be shuttled between two fundamentally different worlds: a fast, ephemeral DRAM that forgets everything at power loss, and a slow, durable block device that remembers everything but forces us to wait, often for milliseconds. This binary model has shaped everything from operating system design to application programming—forcing us to accept performance trade-offs that, until recently, seemed immutable.

But non-volatile memory (NVM) shatters that binary. Imagine a memory that retains its contents after a crash, yet can be accessed at nanosecond latencies through standard load/store instructions. That is not a futuristic fantasy; it is the reality of today’s hardware, embodied in products like Intel® Optane™ Persistent Memory, which sits on the memory bus, recognized by the CPU as a special type of memory module. This technology, often referred to as persistent memory (PMem), blurs the line between memory and storage, and in doing so, forces us to rethink the very foundations of how we store, organize, and recover data.

Why does this matter? Because the universe of applications that desperately need both speed and durability is vast and growing. Consider a financial trading system that must log millions of transactions per second. With traditional architectures, every transaction must be written to an SSD or NVMe drive—incurring latencies measured in tens of microseconds, at best—or batched and risk losing recent data in a crash. With NVM, that same transaction can be committed to persistent memory with a simple store instruction and a memory fence, cutting latency by two orders of magnitude. Similarly, in-memory databases like Redis or Memcached traditionally rely on periodic snapshots or replication to survive failures, trading performance for durability. NVM offers the best of both worlds: memory-speed data structures that survive power outages without sacrificing performance.

This blog post will take you on a deep dive into persistent memory: from the hardware that makes it possible, through the programming models that harness it, to the real-world applications already transforming industries. We’ll examine the challenges—cache coherence, concurrency, wear leveling—and the elegant solutions that researchers and engineers have devised. By the end, you’ll understand not only why persistent memory matters, but how you can start using it to build faster, more reliable systems.

## The Memory Hierarchy: A Brief History of Pain

To appreciate the disruptive nature of NVM, we must first understand the hierarchy it disrupts. Traditional computer architecture arranges storage in a pyramid:

- **CPU registers** (small, sub-nanosecond)
- **L1/L2/L3 cache** (several nanoseconds, volatile)
- **DRAM** (main memory, ~100 ns, volatile)
- **SSD / NVMe** (persistent, ~10–100 microseconds)
- **HDD** (persistent, ~10 ms)

Every time data must survive a crash, it must travel all the way down to the persistent tier and back. This journey incurs a latency penalty of several orders of magnitude compared to a simple memory access. Meanwhile, the gap between CPU speed and storage latency, known as the “I/O gap,” has only widened as processors get faster and storage media lag behind.

The consequence is a system design that revolves around batching and caching. Write-ahead logging, checkpointing, and replication are all workarounds to hide the cost of persistence. But they come with complexity: log truncation, crash recovery, memory pressure, and the constant risk of data loss if a failure strikes between flushes.

Persistent memory eliminates the need for this shuttle. By placing durable storage on the memory bus, it offers load/store access to non-volatile data at DRAM-like speeds (typically 200–400 ns read latency, 100–200 ns write latency after cache flush). This is not as fast as DRAM, but it is **10,000 times faster** than the fastest SSDs. For the first time, we can have our cake and eat it too: durable data without the I/O tax.

## The Hardware: What Makes Persistent Memory Tick

### Intel Optane Persistent Memory: A Case Study

Intel’s Optane Persistent Memory, launched in 2019, is the most widely available NVM technology. It uses 3D XPoint memory cells—a fundamentally different material than the floating-gate transistors used in NAND flash. Instead of storing charge, 3D XPoint relies on a phase-change mechanism: a chalcogenide glass can be switched between amorphous and crystalline states, representing 0 and 1. This allows individual bytes to be addressed and overwritten without requiring block erase cycles, unlike NAND.

Key characteristics of Intel Optane PMem:

- **Capacity**: Up to 512 GB per DIMM (compared to 128–256 GB typical for DRAM)
- **Latency**: Read ~200–300 ns, write (after CPU cache flush) ~100–200 ns (but note that write latency is asymmetric: the store itself is fast, but ensuring persistence requires an explicit flush instruction that can take 100–200 ns)
- **Bandwidth**: ~30–40 GB/s on a dual-channel system (significantly lower than DRAM’s 100+ GB/s)
- **Endurance**: Write endurance is limited (like NAND) but far higher than expected for a memory technology—typically petabytes of writes per DIMM. Still, must be managed through wear leveling and minimizing writes.
- **Power failure atomicity**: Writes smaller than 64 bytes are atomic on power failure (cache-line granularity). Larger writes require log-based mechanisms.

Optane PMem operates in two modes: **Memory Mode** and **App Direct Mode**. In Memory Mode, it acts as volatile memory with a DRAM cache; data is lost on reboot. That’s not what we’re interested in. App Direct Mode exposes persistent capacity directly to the application, allowing byte-addressable load/store access. This is the mode that unlocks the new programming paradigm.

### How Does the CPU See Persistent Memory?

Physically, Optane DIMMs plug into the same memory slots as DRAM (DDR4-T). The memory controller treats them as special memory regions. The CPU can issue standard MOV instructions to addresses in the persistent memory range. However, the CPU’s caches (L1, L2, L3) are volatile. Hence, a store to persistent memory may sit in the cache hierarchy and not be flushed to the DIMM for milliseconds. To guarantee persistence after a crash, the application must explicitly flush the cache lines (using `CLFLUSH`, `CLWB`, or `CLFLUSHOPT` instructions) and then issue a memory fence (`SFENCE`) to order the flushes.

Intel’s Persistent Memory Development Kit (PMDK) provides libraries that abstract these low-level instructions, along with transaction support, allocation, and recovery.

Before Intel, other NVM technologies existed (battery-backed DRAM, NVDIMM-N, etc.), but Optane was the first to deliver byte-addressable persistence at scale without requiring a backup battery. However, in 2022, Intel announced the discontinuation of Optane, leaving a gap. Other vendors are working on next-generation NVM (e.g., using MRAM, ReRAM, or CXL-attached persistent memory), but as of 2025, the ecosystem is in flux. Nevertheless, the programming models and concepts remain valid for any future persistent memory technology.

## Programming for Persistence: A Paradigm Shift

### The Naive Approach (and Why It Fails)

Suppose we want to store a simple counter in persistent memory and increment it atomically:

```c
struct counter {
    int value;
} __attribute__((packed));
struct counter *p_counter = /* pointer to PMem */;

// Increment
p_counter->value++;
```

This code runs, but after a crash, `p_counter->value` might have an old value, or a partially updated value, or even a garbage value. Why? Because:

1. The store to `p_counter->value` may not have reached the PMem DIMM before the power fails, even if the program counter advanced.
2. The CPU may reorder the store relative to other stores.
3. Even if the store reaches the memory controller, it may be buffered and not yet committed to the NVM cell.

To guarantee persistence, we must:

- **Flush the cache line** containing the counter so it is written to the memory controller.
- **Wait for the flush to complete** (via fence) so that subsequent operations see the durable state.

The corrected code:

```c
p_counter->value++;
// Flush the cache line containing the counter
_clwb(&p_counter->value, sizeof(p_counter->value));
// Ensure the flush is complete before proceeding
_sfence();
```

Even this is not sufficient for crash consistency if multiple writes are involved (e.g., a complex data structure). If you update two counters and a crash occurs after the first flush but before the second, the system is in an inconsistent state. This brings us to the heart of persistent memory programming: **crash consistency**.

### Transactions and Logging

To ensure atomic updates to multiple locations, we use transactional mechanisms, typically **undo logging** or **redo logging**. The PMDK provides `libpmemobj`, which implements a persistent transactional memory system. Here’s a simplified example:

```c
#include <libpmemobj.h>

TOID(struct my_root) root;
POBJ_NEW(pop, &root, struct my_root, NULL);

// Start a transaction
TX_BEGIN(pop) {
    TX_ADD(root); // snapshot current state (undo log)
    D_RW(root)->counter++;
} TX_END
```

Under the hood, PMDK records the old values of modified memory regions in an undo log (stored in PMem). On success, the log is cleared. On crash, the recovery process replays the undone changes, rolling back partial updates.

For performance-critical code, you can build custom logging. A common pattern is the **persistent pointer with epoch** or **versioned data**. The idea: store a generation number next to the data, increment it atomically after a consistent update, and on recovery, check the generation to decide validity.

### The Cost of Flushing

Cache flushes are not free. Each `CLWB` instruction takes about 50–150 ns, and when you have many stores, the cumulative flush overhead can dominate. The key optimization is to batch flushes: write a batch of data, then flush the entire range, then fence. This reduces the number of flushes and fences.

Another technique: use **non-temporal stores** (e.g., `MOVNTI`), which bypass the cache and write directly to memory. However, they require alignment and are only available for store instructions; reads still go through cache. Non-temporal stores are useful for bulk write workloads (e.g., logging), but for random access, they may be slower due to lack of caching.

## Data Structures for Persistent Memory

### Persistent Linked Lists

A linked list in DRAM is trivial: each node contains a pointer to the next. In persistent memory, a crash can leave a dangling pointer if the node is written but the prior node’s next pointer is not yet updated. The typical solution is to use **pointer reversal** or a **write-ahead log**.

Consider a doubly linked list insertion. Without persistence, we update the new node’s `next` and `prev`, and then the adjacent nodes’ pointers. To make this atomic, we can:

1. Allocate a small log entry recording the intended changes.
2. Write the log entry and flush it.
3. Perform the actual pointer updates, flushing each changed cache line.
4. After all flushes complete, invalidate the log.

On recovery, if the log exists, we apply the pending changes; if not, the data is consistent.

This approach is cumbersome. Consequently, many practical persistent data structures avoid dynamic memory allocation in critical paths, using pre-allocated pools or B-tree-like structures with fixed-size pages.

### Persistent B-Trees

Databases and file systems love B-trees. In DRAM, an in-memory B-tree is fast but volatile. A persistent B-tree (e.g., the one used in Intel’s PMDK `libpmemobj` B-tree, or the WiredTiger engine used in MongoDB) must ensure that splits and merges are crash-atomic. The common strategy is **shadow paging**: when modifying a node, write a new copy of the node (in a pre-allocated space), flush it, then atomically update the parent’s pointer to point to the new node. The old node becomes garbage. This avoids in-place updates.

Alternatively, **in-place with logging** can be used, but it requires careful ordering. For performance, persistent B-trees often use **tail logs** to batch small updates.

### Hash Tables

Persistent hash tables are simpler because inserts and updates often affect a single bucket. If the bucket fits in one cache line (64 bytes), a single cache-line flush suffices for atomicity (since PMem guarantees 64-byte power-fail atomicity). However, hash collisions (chaining) require linked list structures, which reintroduce complexity.

A popular design is **Linear Hashing** combined with a **free-list** stored in PMem. The free-list itself must be crash-consistent.

### Persistent Memory Allocators

Allocating and deallocating memory in PMem is non-trivial. A crash during allocation could leak memory or corrupt the heap. PMDK’s `libpmemobj` includes a transaction-aware allocator (`pmemalloc`) that uses undo logging for metadata. There are also more efficient allocators like `Ralloc` or `NVHeaps` that minimize logging overhead.

## Case Study: Redis on Persistent Memory

Redis, the popular in-memory key-value store, is a classic candidate for NVM. Its default persistence model uses **RDB snapshots** (periodic full dump) and **AOF** (append-only file). Both involve disk I/O, limiting throughput to tens of thousands of operations per second when persistence is required.

With persistent memory, Redis can be configured to store data in a file system on a PMem device (e.g., mounted with DAX - Direct Access, which allows direct load/store to the file without page cache). The `aof-use-rdb-preamble` approach can be replaced by **persistent in-memory structures**.

The Redis community and Intel have developed **Memory-Disaggregated Redis** variants. However, the simplest way to use PMem with Redis is to enable the **AOF** write to a PMem-backed file system. Because writes to a DAX file are direct cache flushes, the latency drops from ~50 µs (NVMe) to ~1 µs. But Redis still uses the kernel’s file operations (write, fsync), which add context switches.

A deeper integration involves replacing Redis’s internal hashtable with a PMem-native hashtable (like **RedisRaft** with persistent storage). This eliminates all serialization and deserialization overhead. Benchmarks from Intel show a 10x throughput improvement for write-heavy workloads when using `pmem-redis` (a fork that uses PMDK directly).

### Example Workload: Financial Order Book

An order book needs to maintain a sorted set of buy and sell orders, and must persist every change to survive crashes. Traditional approaches use a combination of in-memory trees and a log on SSD. The log becomes a bottleneck.

On PMem, the order book tree itself can be stored persistently. Each order insertion/removal updates the tree with a few cache-line flushes. The result: latency drops from ~50 µs to <1 µs, and throughput increases from 50,000 operations/sec to over 2 million operations/sec.

## Performance Characteristics: A Deeper Dive

### Read Latency vs Write Latency

One of the most misunderstood aspects of PMem is the asymmetry. Reads are fast (200–300 ns), but writes require a flush. The flush instruction adds about 100 ns. However, the store instruction itself completes quickly (10–20 ns) because it writes to the cache. The flush then pushes the dirty cache line to the memory controller. The total write latency experienced by the application (from the moment the store instruction is considered complete from coherence perspective) is around 100–200 ns for a sequential write, but can be much higher if the flush must wait for previous flushes.

A key insight: **write bandwidth** is limited by the flush rate. Each `CLWB` can flush one cache line (64 bytes) per ~100 ns, yielding a theoretical bandwidth of 640 MB/s per core. In practice, multiple cores can flush concurrently, and the memory controller can handle multiple requests, so aggregate bandwidth can reach 30–40 GB/s.

### Caching Effects and Write Combining

Because stores go first to the CPU cache, they benefit from write combining. If you write multiple consecutive words to the same cache line, only one flush is needed for the entire cache line. This is hugely important: organizing data structures to pack related fields into the same cache line reduces flush overhead.

For example, a B-tree node of size 256 bytes (4 cache lines) requires up to 4 flushes. If you update multiple nodes, you can flush them in a batch.

### Endurance and Wear Leveling

Intel Optane PMem has a write endurance of around 10^7 to 10^8 writes per cell, which is lower than DRAM (which is unlimited). But because writes are cache-aligned and the controller performs wear leveling at the cell level, in practice, a 128 GB Optane DIMM can sustain about 2.5 million full device writes per day over 5 years. That’s roughly 32 GB/s sustained writes—far beyond typical workloads. However, **write amplification** (e.g., from metadata updates or logging) can reduce effective endurance. Good programming practices minimize unnecessary writes.

## Crash Consistency and Recovery Protocols

Making data structures crash-consistent is the central challenge. The problem resembles that of database atomicity, but at a lower level.

### The Persistent Pipeline

A typical write path:

1. **Allocate** space in PMem (using a persistent allocator).
2. **Write data** (store instructions) – data is in CPU cache.
3. **Flush** cache lines that are dirty.
4. **Memory fence** to ensure flush order.
5. **Commit** by updating a pointer or version (another store+flush+fence).

The commit step must be atomic. The smallest atomic write unit in PMem is 64 bytes (cache line). If your commit is larger than that, you need a log.

### The Undo Log System (PMDK Approach)

PMDK’s `libpmemobj` uses an undo log stored in PMem. When a transaction starts, it records the old values of memory regions that will be modified. The log itself is a linked list of entries. On transaction commit, the log is cleared (by setting a flag). On crash recovery, the library scans for incomplete transactions and rolls back by copying saved old values back.

This approach is robust but incurs overhead for every transaction (at least one log entry write + flush). For high performance, you can use **redo logs**: write new values to a separate log, then atomically update a pointer to switch to the new data. That is the approach used in persistent B-tree shadow paging.

### Lightweight Approaches: Versioning and Epochs

For simple data structures, you can use a version number. Maintain two copies of a data structure (A and B). Write updates to copy B, flush, then increment a global version pointer to point to B. On crash, the version pointer tells which copy is consistent. This doubles memory usage but eliminates logging overhead.

## Real-World Impact and Adoption

### In-Memory Databases

VoltDB, Redis, and Aerospike have all experimented with PMem. Aerospike’s persistent memory support allowed them to reduce DRAM requirements while retaining performance. Microsoft SQL Server and Oracle also support PMem for buffer pool extension.

### File Systems and Storage Systems

The Linux kernel has supported PMem since version 4.0 via the **DAX** (Direct Access) feature, which allows files to be memory-mapped directly from PMem without going through the page cache. File systems like ext4 and XFS have DAX support. This enables conventional applications to benefit from PMem with minimal modification—just mmap and flush.

Storage systems like SPDK and NVMe-oF are also adapting to manage PMem as a fast tier.

### High-Frequency Trading

In HFT, every microsecond counts. PMem allows order books and risk calculation to be persisted with near-zero latency overhead. Several exchanges have deployed Optane-based systems for clearing and settlement.

## Programming Challenges and Pitfalls

### Memory Ordering

The CPU can reorder stores to PMem arbitrarily. To guarantee order, you must use `SFENCE` (or `MFENCE`) after flushes. For performance, you can rely on the fact that `CLWB` orders with respect to itself only if you fence. Over-fencing kills performance; under-fencing risks corruption.

### Read-Wrong Phenomenon

Because PMem reads are slower than DRAM, and caches can cause stale reads, you must ensure that when you read a PMem location after a flush (by another thread), you see the latest version. This requires proper memory barriers for both writes and reads.

### Memory Leak Detection

A crash during allocation can leave unclaimed memory. The PMDK’s transaction-based allocator reduces this risk, but leaks are still possible if application code bypasses the library.

### Mixing DRAM and PMem

In many systems, DRAM is used for hot data and PMem for cold or persistent data. However, pointers from DRAM to PMem must survive reboots, so you need to either store relative offsets or use a persistent pool identifier. PMDK uses a global pool UUID and offsets.

## The Future: Beyond Optane

With Intel’s exit from the Optane market, the future of NVM is uncertain but not bleak. Several technologies are in development:

- **MRAM** (Magnetoresistive RAM): Already used as persistent storage in some embedded systems. It offers near-DRAM speed and high endurance, but capacity is limited (currently up to 256 Mb chips).
- **ReRAM** (Resistive RAM): Similar to 3D XPoint but with different materials. Companies like Crossbar and Weebit Nano are developing ReRAM for persistent memory.
- **FeFET** (Ferroelectric FET): A promising candidate for high-density, low-latency NVM.
- **CXL-attached persistent memory**: The Compute Express Link protocol allows memory expanders to be connected via PCIe. Several vendors are working on CXL PMem modules that can be pooled across servers.

All these technologies retain the same fundamental property: byte-addressable persistence on the memory bus. The programming models we’ve discussed will remain relevant.

## Conclusion: A New Era for Data Systems

Persistent memory is not a minor tweak to existing architecture—it is a paradigm shift. It forces us to reconsider decades of assumptions about the boundary between memory and storage. The applications that embrace this shift—by redesigning data structures to be crash-consistent with minimal flush overhead—will unlock performance gains of one to two orders of magnitude.

The cost is complexity. Programming for persistence requires understanding of cache coherence, atomicity, and recovery protocols. But the tools (PMDK, DAX, persistent languages) are maturing rapidly. For developers willing to invest, the rewards are immense.

As we look ahead, the adoption of persistent memory will accelerate, especially as cloud providers offer PMem instances (e.g., AWS Nitro with local NVM). The next era of computing may not have a memory-storage divide at all—just a single, fast, durable memory continuum.

_Do you have experience with persistent memory? Share your thoughts and code in the comments. And if you’re building a system that needs both speed and durability, consider starting with the PMDK and a small-scale prototype. The future is persistent._

---

_This blog post was expanded from an original outline. For further reading, see Intel’s Persistent Memory Programming Guide, the PMDK documentation, and research papers from FAST, ATC, and OSDI._
