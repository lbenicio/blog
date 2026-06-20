---
title: "Persistent Memory Programming: DAX Mappings, PMDK Libraries, Crash Consistency Without Write-Ahead Logging, and the Optane Legacy"
description: "A deep exploration of persistent memory — how DAX enables direct byte-addressable access to non-volatile memory, how the PMDK libraries solve the crash consistency problem at the instruction level, and the lessons of Intel Optane."
date: "2021-06-14"
author: "Leonardo Benicio"
tags: ["persistent-memory", "pmem", "dax", "optane", "pmdk", "crash-consistency", "storage"]
categories: ["systems", "storage"]
draft: false
cover: "/static/images/blog/persistent-memory-programming-dax-pmdk-crash-consistency.png"
coverAlt: "A stylized diagram showing CPU instructions (stores, flushes, fences) reaching persistent memory through the cache hierarchy, with the persistence domain boundary highlighted"
---

In 2015, Intel and Micron announced 3D XPoint, a new class of non-volatile memory that was 1000x faster than NAND flash and 10x denser than DRAM. The first product, Intel Optane DC Persistent Memory, shipped in 2019 as NVDIMMs (Non-Volatile Dual In-line Memory Modules) that plugged into standard DDR4 slots. For the first time, programmers could access persistent storage using CPU load and store instructions. No block layer, no I/O scheduler, no page cache — just a `mov` instruction that could persist data across power cycles. This post explores the programming model for persistent memory: how DAX (Direct Access) mappings bypass the page cache, how the Persistent Memory Development Kit (PMDK) provides crash-consistent primitives, and why getting crash consistency right at the instruction level requires fundamentally new thinking.

## 1. The Persistent Memory Hierarchy

Persistent memory sits between DRAM and SSD in the memory hierarchy. Its latency is roughly 200-500 nanoseconds (compared to 50-100 nanoseconds for DRAM and 50-100 microseconds for SSD), and its bandwidth is roughly 30-40 GB/s (compared to 100 GB/s for DRAM and 3-5 GB/s for SSD). But its defining characteristic is persistence: data written to persistent memory survives power loss, just like data written to an SSD.

The processor's cache hierarchy complicates this picture. Modern CPUs have multiple levels of cache (L1, L2, L3), and stores to persistent memory may be held in volatile caches indefinitely unless explicitly flushed. The "persistence domain" — the point beyond which data is guaranteed to survive power loss — is typically the memory controller's write buffer (the asynchronous DRAM refresh boundary, or ADR). Data that has reached the persistence domain is safe; data still in the CPU caches is not.

This means that programming persistent memory requires explicit cache management. After storing data to persistent memory, the programmer must ensure the data has been flushed from all volatile caches and has reached the persistence domain before considering the store "durable." Intel's x86 instruction set provides several instructions for this purpose:

- `CLFLUSH`: Flush a specific cache line from all levels of the cache hierarchy. Old, slow, and serializing.

- `CLFLUSHOPT`: Optimized flush — non-serializing, allowing multiple flushes to be in flight simultaneously.

- `CLWB` (Cache Line Write Back): Write a cache line back to memory, but retain it in the cache in the shared state (so subsequent reads can still hit the cache). This is preferred over CLFLUSH for persistent memory because it doesn't invalidate the cache line.

- `SFENCE` (Store Fence): Ensure that all previous stores (and flushes) are globally visible before any subsequent stores. This is the ordering barrier that makes crash consistency possible.

The sequence for a durable store is: `store instruction → CLWB (or CLFLUSHOPT) → SFENCE`. The store writes data to the cache; CLWB writes it back to the persistence domain; SFENCE ensures the CLWB has completed before any subsequent stores become visible.

## 2. DAX: Bypassing the Page Cache

Traditional file I/O goes through the page cache: the kernel reads file data into DRAM pages, and applications read from and write to those pages via `read()` and `write()` system calls. For persistent memory, this is wasteful. The data is already in byte-addressable non-volatile memory — there's no need to copy it into volatile DRAM.

DAX (Direct Access) eliminates the page cache for files on persistent memory. When an application `mmap`s a file on a DAX-enabled filesystem (ext4-DAX, XFS-DAX), the kernel maps the persistent memory pages directly into the application's virtual address space. Loads and stores from the application go directly to the persistent memory, without copying through the page cache. No `read()` or `write()` system calls are needed — the application accesses the file as if it were a regular memory-mapped region.

DAX provides two key benefits:

1. **Zero-copy access**: The application reads and writes directly to persistent memory, avoiding the double-buffering of the page cache (data copied from PMem to DRAM page cache, then from page cache to application buffer).

2. **Byte-granularity access**: The application can read and write individual bytes, rather than being forced to read/write entire blocks (4 KB or 512 bytes). This enables persistent data structures that are updated in place at byte granularity, rather than requiring block-level read-modify-write cycles.

The trade-off is that the application is responsible for crash consistency. The page cache provides some crash consistency guarantees (via `fsync`), but with DAX, the application must ensure that its stores are properly flushed and ordered to survive crashes.

## 3. PMDK: Building Crash-Consistent Primitives

The Persistent Memory Development Kit (PMDK) is a set of open-source libraries that provide crash-consistent abstractions for persistent memory programming. PMDK's flagship library is libpmemobj, which provides a transactional object store on persistent memory.

libpmemobj's key data structure is the "persistent memory pool" — a file on a DAX filesystem that is mapped into the application's address space. Within the pool, the application allocates "persistent objects" using a `pmemobj_alloc` function (similar to `malloc` but returning a persistent memory pointer). The library maintains internal metadata (free lists, object headers) in the pool itself, so the allocator's state is also persistent across power cycles.

The crucial innovation in libpmemobj is its support for "fail-safe atomic transactions." A transaction wraps a sequence of stores to persistent memory and ensures that either all stores become visible (the transaction commits) or none do (the transaction aborts, and the pre-transaction state is restored). This is the persistent-memory equivalent of a database transaction, implemented at the instruction level.

The transaction mechanism uses undo logging. Before modifying a persistent memory location inside a transaction, libpmemobj saves the old value to an undo log (also in persistent memory). If the transaction commits, the undo log is discarded. If the transaction aborts (or if a crash occurs before commit), the undo log is replayed on recovery, restoring the pre-transaction state.

The performance of libpmemobj transactions is remarkable. A simple transaction that increments a persistent counter takes about 200-300 nanoseconds on Optane PMem — roughly 3-4x the cost of a volatile increment. The overhead comes from the undo log write (must be flushed to persistence) and the transaction begin/commit operations (which involve memory barriers and cache flushes).

## 4. Crash Consistency Without WAL

Traditional storage systems use write-ahead logging (WAL) for crash consistency: before modifying a data page, the system writes a log entry describing the modification. After a crash, the log is replayed to restore consistency. WAL is powerful and well-understood, but it's designed for block-oriented storage where each write must be a full block (4 KB or larger) and seeks are expensive.

Persistent memory enables a different approach: in-place updates with cache line granularity. Because persistent memory is byte-addressable, the application can modify individual fields of a data structure in place, and use cache flushes to ensure durability. There's no need to write a full-page before-image to a log; instead, the application writes only the bytes being changed, and uses atomic 8-byte stores (which are guaranteed to be tear-free on x86) for critical metadata updates.

This enables "failure-atomic" data structures — data structures that are always in a consistent state, even if a crash occurs mid-update. For example, a persistent linked list insertion can be made failure-atomic by:

1. Allocating the new node and initializing its fields (data, next pointer).
2. Flushing the new node to persistence (CLWB + SFENCE).
3. Atomically updating the previous node's next pointer to point to the new node (a single 8-byte store).
4. Flushing the updated next pointer.

After any crash, the list is always consistent: either the new node is linked in (if the crash occurred after step 3) or it isn't (if the crash occurred before step 3). There's no intermediate state where the list is corrupted. This is a fundamentally different programming model from block-based storage, where atomicity is achieved through logging or copy-on-write at the block level.

## 5. Failure-Atomic Data Structures: Correctness by Construction

The most profound consequence of byte-addressable persistence is the ability to build data structures that are always consistent — crash or no crash. This requires a disciplined approach to memory ordering and a clear understanding of the processor's persistence model.

### The 8-Byte Atomic Store Guarantee

On x86-64, aligned 8-byte stores are atomic with respect to power failure. The processor's memory controller guarantees that an aligned 8-byte store is either fully written to the persistence domain or not written at all — never partially written (torn). This guarantee is the foundation for failure-atomic data structures: if a critical metadata field (pointer, counter, flag) fits in 8 bytes and is aligned, updating it is inherently atomic.

This leads to a common pattern for persistent data structure mutation:

```c
// Pattern: Append to a persistent linked list
struct pnode {
    uint64_t data;
    struct pnode *next;  // 8-byte pointer, aligned
};

void pnode_append(struct pnode *head, uint64_t data) {
    // Step 1: Allocate and initialize new node in persistent memory
    struct pnode *new_node = pmemobj_alloc(pop, sizeof(*new_node));
    new_node->data = data;
    new_node->next = NULL;

    // Step 2: Persist the new node (CLWB is inside pmemobj_persist)
    pmemobj_persist(pop, new_node, sizeof(*new_node));

    // Step 3: Find tail - doesn't modify anything, no persistence needed
    struct pnode *tail = head;
    while (tail->next) tail = tail->next;

    // Step 4: Atomically link new node - single 8-byte store
    tail->next = new_node;

    // Step 5: Persist the link pointer
    pmemobj_persist(pop, &tail->next, sizeof(tail->next));
}
```

After any crash, the list is either in the old state (new_node not linked) or the new state (new_node linked). No intermediate states are possible because the linking store (step 4) is a single 8-byte write, and the new node is fully initialized and persisted before the link is created. The order of operations (initialize, persist, then link) is what guarantees consistency.

### The Ordering Invariant

Generalizing from the linked list example, the fundamental ordering invariant for failure-atomic data structures is:

**Before publishing a pointer to a persistent memory object, all fields of the object must be initialized and persisted. The publishing store must be an aligned 8-byte store, and it must be followed by a persistence fence.**

This is analogous to the "publish before pointing to" rule in concurrent programming (where you initialize an object before making it visible to other threads), but with persistence replacing thread visibility. The CLWB and SFENCE instructions play the role of memory barriers, ensuring that the initialization writes reach the persistence domain before the publishing write does.

### Failure-Atomic Multi-Field Updates

What if a logical update requires modifying multiple fields that don't all fit in 8 bytes? For example, inserting into a sorted doubly-linked list requires updating four pointers (two in the new node, one in the predecessor, one in the successor). A single 8-byte store is insufficient.

The solution is to use a "lock" or "validity flag" — an 8-byte field that indicates whether the surrounding data is consistent. The pattern:

```c
// Multi-field update with validity flag
struct complex_record {
    uint64_t valid;  // 0 = inconsistent, 1 = consistent
    uint64_t field_a;
    uint64_t field_b;
    char data[128];
};

void update_record(struct complex_record *rec, ...) {
    // Step 1: Mark invalid
    rec->valid = 0;
    pmemobj_persist(pop, &rec->valid, sizeof(rec->valid));

    // Step 2: Update all fields
    rec->field_a = new_a;
    rec->field_b = new_b;
    memcpy(rec->data, new_data, 128);
    pmemobj_persist(pop, rec, sizeof(*rec));

    // Step 3: Mark valid - single 8-byte store
    rec->valid = 1;
    pmemobj_persist(pop, &rec->valid, sizeof(rec->valid));
}
```

On recovery, the application checks `valid`: if 0, the record is in an intermediate state (the update was interrupted by a crash), and the application can discard or repair it. If 1, all fields are consistent. This is a simplified form of multi-version concurrency control (MVCC) adapted for persistence.

## 6. The ADR Platform and Power-Fail Safety

The persistence domain on Intel platforms is defined by the Asynchronous DRAM Refresh (ADR) feature. ADR guarantees that on a power failure, the memory controller will flush all pending writes from its write buffer to the DRAM chips, using residual capacitance in the power supply. Once data reaches the ADR-protected write buffer (the "ADR domain"), it is guaranteed to be written to the NVDIMMs before power is lost.

The exact persistence boundary varies by platform. On standard servers with Optane NVDIMMs, the ADR domain is the integrated memory controller (iMC) write buffer. Data written to the iMC's write buffer is protected by ADR; data still in the CPU caches (L1/L2/L3) is not. This is why CLWB + SFENCE is required: CLWB writes the cache line back to the iMC (entering the ADR domain), and SFENCE ensures the CLWB has completed.

On some high-end platforms, "eADR" (extended ADR) extends the persistence domain to include the CPU caches. With eADR, any store that reaches the L3 cache is guaranteed to be persisted on power failure — no explicit CLWB is needed. However, SFENCE is still required for ordering (ensuring that stores become persistent in the correct order). eADR dramatically simplifies persistent memory programming (no more CLWB), but it requires platform support that is not yet widely available.

Understanding the ADR boundary is essential for writing correct persistent memory programs. A common mistake is to assume that stores are persistent as soon as they execute. They are not — they may sit in the L1 cache indefinitely. Only after CLWB (or a write-back due to cache pressure) and SFENCE (to order the write-back) do they enter the ADR domain and become persistent.

### Power-Fail Interrupt Handling

The platform's power-fail interrupt (NMI) fires when the power supply voltage drops below a threshold, signaling that a power loss is imminent. The ADR hold-up time — typically 2-5 milliseconds — is the time between the NMI and the actual loss of power. During this window, ADR flushes the memory controller's write buffer to the NVDIMMs, but application-level code can also run. This creates an opportunity for "last gasp" persistence: the application can flush critical state to persistent memory in the NMI handler. However, the time window is very short (a few milliseconds), so only minimal state can be saved. The primary use of the power-fail NMI is to ensure that in-flight PMDK transactions are completed (committed or rolled back) before power is lost, minimizing the recovery work on the next boot.

## 7. The Optane Legacy

Intel announced the discontinuation of Optane in 2022, marking the end of the first generation of persistent memory products. Optane's failure to achieve widespread adoption had several causes: high cost per gigabyte (several times more expensive than SSD, though cheaper than DRAM), limited ecosystem support (few applications were rewritten to take advantage of persistence), and the complexity of persistent memory programming (which proved to be a significant barrier for most developers).

However, Optane's technical legacy is substantial. It proved that byte-addressable persistent memory was viable — that you could build NVDIMMs that plugged into standard DDR4 slots and delivered on the promise of load/store access to persistent data. It drove the development of the PMDK libraries, which are now mature, production-quality tools for persistent memory programming. And it established the DAX model in Linux, which provides a clean interface for future persistent memory technologies.

The lessons from Optane will inform the next generation of persistent memory. CXL (Compute Express Link) is emerging as the standard interface for next-generation persistent memory, replacing the DDR interface with a cache-coherent PCIe-based protocol. CXL-attached persistent memory will have different performance characteristics than Optane (higher latency due to the CXL link, but potentially higher capacity and lower cost), and the programming model will evolve accordingly.

## 6. Summary

Persistent memory programming represents a fundamental shift in how software interacts with storage. Instead of issuing I/O commands through a block layer, the application maps persistent memory into its address space and accesses it with ordinary loads and stores. The performance benefits — microsecond-latency access, byte granularity, no page cache overhead — are game-changing for data-intensive applications. The programming challenges — cache management, crash consistency at the instruction level, failure-atomic updates — require a new set of abstractions and a new mindset for developers accustomed to the block I/O model.

PMDK provides the foundational abstractions: persistent memory pools, transactional updates with undo logging, and failure-atomic primitives. These libraries encapsulate the complexity of cache management and ordering, allowing application developers to focus on data structure design rather than instruction-level correctness. As CXL-attached persistent memory becomes available, the PMDK model — possibly adapted for the different performance characteristics of CXL — will be the starting point for the next generation of persistent memory applications.

The Optane era may have ended, but the idea of persistent memory — byte-addressable, non-volatile, directly accessible by the CPU — is not going away. It's too powerful an idea to abandon. The hardware will evolve, the interfaces will standardize, and the programming models will mature. Persistent memory is the future of storage; it just arrived a decade early.

## 7. CXL and the Next Generation of Persistent Memory

The Compute Express Link (CXL) standard, built on PCIe 5.0/6.0 physical layers, is emerging as the dominant interface for next-generation persistent memory. Unlike DDR-attached PMem (Optane), CXL-attached memory sits on the PCIe bus and communicates using cache-coherent protocols (CXL.cache, CXL.mem). This has several implications for performance and programming.

CXL-attached persistent memory will have higher latency than DDR-attached PMem because PCIe round-trips add 50-100 nanoseconds of overhead. However, CXL supports much higher capacities (terabytes per device), hot-plug (add/remove without rebooting), and multi-host sharing (multiple servers can access the same CXL device). These properties make CXL-attached PMem ideal for tiered memory architectures (DRAM as a cache for larger PMem pools) and disaggregated memory (memory pools shared across a rack of servers).

The programming model for CXL-attached PMem will likely be similar to Optane — DAX mappings, persistent memory pools, transactional updates — but with adaptations for the higher latency. Prefetching becomes more important to hide the CXL latency. Batching writes into larger transactions amortizes the flush and fence overhead across more operations. And tiered memory management (automatically migrating hot pages to DRAM and cold pages to PMem) will be essential for achieving good performance without manual tuning.

## 8. Persistent Memory Data Structures: Beyond the Linked List

The failure-atomic linked list insertion described earlier is just the beginning. Persistent memory enables a rich set of data structures that combine the performance of in-memory data structures with the durability of disk-based storage.

Persistent B-trees are a natural fit for persistent memory. A B-tree node can be updated in place (no need to write an entire page to a log before modifying it), and node splits can be made failure-atomic using the same undo-logging or copy-on-write techniques. The PMDK provides a `pmemobj` B-tree implementation (`TOID(struct btree)`) that is crash-consistent and optimized for PMem's byte-addressable access.

Persistent hash tables are another key data structure. A hash table implemented on persistent memory can grow incrementally (add buckets without rewriting the entire table) and survive crashes without corruption. The key challenge is that the hash table's metadata (bucket pointers, occupancy counts) must be updated atomically with the data. PMDK's transactions handle this by grouping multiple writes into a single atomic unit.

## 9. Debugging Persistent Memory Programs

Debugging a persistent memory program is substantially harder than debugging a volatile one. A bug that corrupts the persistent data structures will persist across reboots — you can't just restart the process to get a clean slate. The data structures must be repaired, which requires tooling that understands the persistent layout.

PMDK provides `pmempool` tools for inspecting and repairing persistent memory pools. `pmempool info` prints the pool's header information (layout, size, UUID). `pmempool check` validates the pool's internal consistency (are all objects reachable? are the free lists correct?). `pmempool sync` flushes all pending writes to persistence. These tools are essential for development and for production recovery.

Valgrind and AddressSanitizer have been extended to detect persistent memory errors: stores to persistent memory that are not followed by a flush, flushes that are not ordered by a fence, and memory leaks of persistent allocations. These tools use the PMDK's instrumentation hooks to track persistent memory operations and detect violations of the persistence model.

## 10. Persistent Memory Allocation: The `libpmemobj` Allocator Internals

The persistent memory allocator in `libpmemobj` is a marvel of crash-consistent design. Unlike a volatile allocator (like `malloc`, which only needs to maintain a consistent free list in memory), the persistent allocator must maintain its metadata in persistent memory and ensure that allocations and deallocations are crash-consistent.

The allocator divides the persistent memory pool into "chunks" (typically 256 KB) and "runs" (smaller subdivisions within chunks). A chunk is the unit of allocation for large objects; runs are used for smaller objects (via a slab allocator). The allocator's metadata — a bitmap indicating which chunks and runs are free — is stored in persistent memory, and all updates to the metadata are performed inside PMDK transactions.

When the application calls `pmemobj_alloc`, the allocator: (1) finds a free chunk or run of appropriate size, (2) within a PMDK transaction, marks the chunk/run as allocated in the bitmap, (3) writes the object's header (type, size, flags) to the allocated memory, (4) flushes the bitmap and header to persistence, and (5) commits the transaction. If a crash occurs during allocation, the transaction's undo log ensures that the bitmap is restored to its pre-allocation state.

The allocator also handles persistent fragmentation. Unlike a volatile allocator, which can compact the heap by moving objects and updating pointers (as a GC does), the persistent allocator must update pointers in persistent memory, which is expensive. The `libpmemobj` allocator uses a "best-fit" strategy that minimizes fragmentation by choosing the smallest free chunk that fits the requested size, and it periodically coalesces adjacent free chunks. For applications that allocate and deallocate many small objects, the pool can be "compacted" offline using the `pmempool transform` tool, which rewrites the pool with optimal layout.

## 11. Persistent Memory and Databases: The Promise of Instant Recovery

Database systems stand to benefit enormously from persistent memory. A traditional database (like PostgreSQL or MySQL) writes data to disk pages (8-16 KB) and uses a write-ahead log (WAL) for crash recovery. On restart, the database replays the WAL to bring the data pages to a consistent state. For a database with a large buffer pool and a long checkpoint interval, WAL replay can take minutes — during which the database is unavailable.

With persistent memory, the database can store its buffer pool directly on persistent memory (using DAX mappings). There is no WAL, no checkpoint, no recovery — the buffer pool is always consistent because all updates are to persistent memory with proper flush and fence ordering. On restart, the database maps the persistent memory pool and resumes operation immediately. Recovery time drops from minutes to milliseconds.

This architecture, called "instant recovery," has been prototyped in several research systems (Microsoft's Siberia, the Peloton database, and the PMDK-based pmemkv key-value store). The key challenge is ensuring that all writes to the persistent buffer pool are crash-consistent — the database must use PMDK transactions or failure-atomic updates for all state modifications. But the payoff — millisecond recovery from any crash — is transformative for high-availability systems.

The economic implications of instant recovery are significant. For a financial trading system where every second of downtime costs millions in lost transactions, reducing recovery from minutes to milliseconds changes the availability calculus. A traditional database might achieve 99.99% availability (52 minutes of downtime per year) due to crash recovery overhead. With instant recovery on persistent memory, the same database can approach 99.9999% (30 seconds of downtime per year), with crashes contributing negligible downtime. This level of availability, previously achievable only with complex replicated architectures (hot standbys, distributed consensus), becomes achievable with a single-node database on persistent memory. The simplification of the architecture — no replication lag, no failover logic, no split-brain concerns — reduces operational complexity and its associated risk of operator error, which is itself a leading cause of outages.

## 12. Persistent Memory and the Linux Kernel: DAX, KMEM, and fsdax

The Linux kernel supports persistent memory through three modes: DAX (direct access, bypassing the page cache), KMEM (kernel memory, using PMem as additional volatile memory), and fsdax (DAX on a filesystem). DAX is the most common mode for persistent memory programming, allowing applications to map PMem files directly into their address space.

The DAX subsystem in the kernel (`fs/dax.c`) manages the mapping between file offsets and physical persistent memory pages. When an application `mmap`s a file on a DAX filesystem, the kernel creates page table entries that point directly to the persistent memory pages, bypassing the page cache entirely. Reads and writes through the mapping go directly to persistent memory with no kernel involvement (after the initial page fault).

The KMEM mode (also called "memory mode" in Optane terminology) treats persistent memory as volatile DRAM. The kernel adds the PMem regions to the memory allocator, and applications allocate from them just like regular DRAM. This mode sacrifices persistence for capacity — a server with 512 GB of DRAM and 2 TB of Optane in KMEM mode sees 2.5 TB of volatile memory. KMEM is useful for memory-capacity-bound workloads (in-memory databases, caches, large simulations) that don't need persistence.

The fsdax mode combines DAX with a filesystem (ext4 or XFS with the `-o dax` mount option). Files are stored directly on persistent memory, and `mmap`-ing a file gives DAX access. But the filesystem also provides namespace management (directories, file names, permissions) and file metadata (size, timestamps, ownership) that a raw PMem pool doesn't. fsdax is the recommended mode for most persistent memory applications.

## 13. Persistent Memory and Filesystem Design: NOVA and SplitFS

Persistent memory has motivated new filesystem designs that depart from the traditional block-oriented model. The NOVA filesystem (Non-Volatile memory Accelerated, developed at UC San Diego) is a log-structured filesystem designed specifically for persistent memory. NOVA maintains per-inode logs (each file has its own log), avoiding the centralized journal bottleneck of traditional filesystems. Log entries are 4 KB pages linked into a chain, and garbage collection is performed incrementally by a background thread.

NOVA's key innovation is its use of DAX for metadata as well as data. In traditional filesystems, metadata updates (inode modifications, directory entry creation) go through the journal, which is a bottleneck. In NOVA, metadata is stored in persistent memory logs and updated in place using atomic 8-byte stores. A file creation, for example, involves atomically updating the directory's log with the new entry and the new file's inode with the initial metadata — no journal, no checkpoint, just carefully ordered persistent stores.

SplitFS (developed at UT Austin and VMware Research) takes a different approach: it splits the filesystem into a user-space component (handling data operations via DAX) and a kernel component (handling metadata operations via a traditional filesystem like ext4). The user-space library intercepts `read` and `write` system calls and performs them directly on persistent memory via DAX, bypassing the kernel for the data path. Metadata operations (open, create, unlink) still go through the kernel, maintaining compatibility with existing filesystem semantics. SplitFS achieves near-raw-DAX performance for data operations while leveraging the kernel's mature filesystem for metadata.

## 14. Summary

Persistent memory programming represents a fundamental shift in how software interacts with storage. Instead of issuing I/O commands through a block layer, the application maps persistent memory into its address space and accesses it with ordinary loads and stores. PMDK provides the foundational abstractions: persistent memory pools, transactional updates, and failure-atomic primitives. The DAX model eliminates the page cache, enabling byte-granularity, sub-microsecond access to persistent data.

The Optane products may have been discontinued, but the persistent memory paradigm survives. CXL-attached memory will bring byte-addressable persistence to a new generation of hardware, and the PMDK libraries (with adaptations for CXL's higher latency) will be the starting point for programming it. The vision — storage that you access with `mov` instructions rather than `read()` system calls — is too powerful to abandon. Persistent memory is the future of storage; the hardware just needs to catch up to the software.

## 15. Undo Logging vs Redo Logging for Persistent Memory

PMDK's transaction model uses undo logging: before modifying a persistent memory location, the old value is saved to an undo log. On commit, the undo log is discarded (the new values are already in place). On abort, the undo log is replayed, restoring the old values. This is different from the redo logging (write-ahead logging, WAL) used by traditional databases, where modifications are written to a log and later applied to the data pages.

Why undo logging for persistent memory? The key reason is that undo logging performs better for in-place updates on byte-addressable storage. With redo logging, every modification requires two writes: one to the log (sequential, fast) and one to the data page (random, slower). With undo logging, the modification is written directly to the data page (the "new value"), and only the old value goes to the log. If the transaction commits (the common case), the undo log can be discarded without reading it. The data pages already contain the new values — no "redo" pass is needed.

The trade-off is that undo logging requires the data pages to be directly accessible and byte-addressable, which is true for persistent memory (DAX) but not for block storage. For block storage, redo logging is necessary because the data page must be read from disk, modified in memory, and written back. The log serves as the "durable" copy until the data page is written back. As persistent memory blurs the line between memory and storage, undo logging becomes increasingly attractive for its simplicity and performance.

## 16. Persistent Memory Benchmarking: Why Traditional Metrics Don't Apply

Benchmarking persistent memory requires new metrics that capture its unique position between DRAM and SSD. Traditional storage benchmarks (IOPS, throughput, latency percentiles) don't capture the byte-addressable nature of PMem — a single 8-byte store to PMem is a valid operation, but no storage benchmark measures sub-block-sized writes. Traditional memory benchmarks (bandwidth, latency) don't capture the persistence aspect — the benchmark must include cache flushes and fences to be meaningful for persistent use cases.

The pmembench suite (part of PMDK) measures: (1) persistent write latency — the time from a store instruction to the point where the data is durable (after CLWB + SFENCE), typically 200-500 ns for Optane; (2) persistent bandwidth — the rate at which data can be made durable, typically 3-5 GB/s per Optane DIMM (a fraction of the raw 30-40 GB/s read bandwidth, because writes must go through the cache flush path); (3) transaction throughput — the number of PMDK transactions per second, typically 2-5 million tx/s for simple counter increments. These metrics reflect real application performance more accurately than traditional storage IOPS.

The most surprising result from persistent memory benchmarks is that PMem's write latency (200-500 ns) is closer to DRAM (50-100 ns) than to SSD (50,000-100,000 ns). This two-order-of-magnitude gap between PMem and SSD is what makes persistent memory programming fundamentally different from storage programming — the latency is low enough that you can afford to do byte-granularity, synchronous writes, rather than batching writes into large blocks.

## 17. Summary

Persistent memory programming represents a fundamental shift in how software interacts with storage. By mapping persistent memory into the application's address space, developers can access persistent data with ordinary loads and stores, achieving microsecond-latency, byte-granularity access. PMDK provides the abstractions — persistent memory pools, fail-safe transactions, failure-atomic updates — that make this model safe and productive. The Optane products have been discontinued, but the persistent memory paradigm survives through CXL-attached memory and new non-volatile memory technologies. The vision — storage that you program like memory — is too powerful to abandon.

## 18. Persistent Memory and the Linux Memory Management Subsystem

The Linux kernel's memory management (MM) subsystem has been significantly extended to support persistent memory. The `ZONE_DEVICE` zone type, introduced for DAX, represents memory that is not managed by the kernel's page allocator (it's "device memory," like GPU memory or persistent memory). Pages in `ZONE_DEVICE` are not swappable, not migratable, and not subject to the normal LRU reclaim logic. They are mapped directly into user-space page tables when an application `mmap`s a DAX file.

The `get_user_pages` (GUP) function, which pins user-space pages for DMA or kernel access, has been extended to handle DAX pages. DAX pages have a special `page->pgmap` pointer to the `dev_pagemap` structure that describes the persistent memory region. The kernel uses this to look up the persistent memory driver that owns the page, enabling operations like cache flushing (for the `dax_flush` and `dax_copy_from/to_iter` functions). This integration of persistent memory into the core MM subsystem is what makes DAX transparent to applications — `mmap` works the same for persistent memory files as for regular files, even though the underlying implementation is fundamentally different.

## 19. Summary

Persistent memory programming represents a fundamental shift in how software interacts with storage. Instead of issuing I/O commands, applications map persistent memory into their address space and access it with loads and stores. PMDK provides the abstractions — persistent pools, transactions, failure-atomic updates — that make this model safe. The Linux kernel's DAX and MM support make it transparent. While Optane products have been discontinued, the persistent memory paradigm survives through CXL and new memory technologies. The vision — storage you program like memory — is being realized, one generation of hardware at a time.
