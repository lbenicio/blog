---
title: "Designing A Database Vacant Space Management: Bitmap, Free List, And B Tree Allocation"
description: "A comprehensive technical exploration of designing a database vacant space management: bitmap, free list, and b tree allocation, covering key concepts, practical implementations, and real-world applications."
date: "2026-04-29"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Designing-A-Database-Vacant-Space-Management-Bitmap,-Free-List,-And-B-Tree-Allocation.png"
coverAlt: "Technical visualization representing designing a database vacant space management: bitmap, free list, and b tree allocation"
---

## Designing a Database Vacant Space Management: Bitmap, Free List, and B‑Tree Allocation

### The Silent Killer of Database Performance (Expanded)

Imagine your database as a sprawling library. Every book (a record) sits on a shelf (a page). When a beloved novel is checked out and never returned, its spot becomes vacant. Now imagine the librarian, instead of marking that spot as available, simply leaves an empty hole. Over time, the shelves become riddled with gaps. New books arrive but cannot fit into those odd-sized cavities—they must be placed at the end of the shelf, growing the library ever outward. Soon, the room is a labyrinth of fragmented aisles, with books scattered far from where they logically belong. Searching for a single volume requires hiking through half the building.

This is the reality of a database without intelligent vacant space management—a system that fails to reclaim and reuse the gaps left by deleted or updated records. Most developers are intimately familiar with the symptoms: steadily growing storage footprints that seem impossible to shrink, intermittent performance cliffs, backup times that balloon, and inexplicable “out of disk space” errors even after purging gigabytes of data. The root cause? The database is drowning in its own empty space.

And yet, vacant space management remains one of the most underappreciated mechanisms in database architecture. While we obsess over query optimizers, indexing strategies, and replication topologies, the humble **free space tracker** silently determines whether your workload runs smoothly today—and whether your storage bill mutates into a fiscal nightmare tomorrow.

Consider a real-world example from a mid-sized e‑commerce platform. After a year of operation, the database held 500 GB of “live” data. Yet the total allocated file size was 2.1 TB. The extra 1.6 TB was empty pages—fragments from millions of order cancellations, product deletions, and customer address updates. The storage cost alone was an unnecessary $3,000 per month. Worse, the backup window had grown from 30 minutes to nearly 4 hours, because the system was backing up terabytes of emptiness. When the team finally performed a full re‑organization (a painful 48‑hour maintenance window), the database shrunk to 520 GB. That 400% bloat is not extreme; many production databases suffer 10x or more.

But the cost is not just dollars. Performance degrades in subtle ways. Sequential scans must traverse many more pages to find the same number of live records, increasing I/O. Indexes become deeper because they must reference scattered pages, causing more random reads. Concurrency suffers because free-space management itself becomes a bottleneck. The system might start thrashing when it desperately tries to recycle space while a wave of inserts arrives.

### Why This Topic Matters (Expanded)

The stakes are high. Consider a modern online transaction processing (OLTP) database handling an e‑commerce platform. Every order placement, cancellation, return, and refund generates a cascade of inserts and deletes. Without efficient vacant space reuse, each deletion leaves a tombstone. The active data might stabilise at 200 GB, but the storage continues to inflate. Similarly, in a high‑frequency trading system, order book updates create a storm of short‑lived records. If the database cannot quickly recycle those slots, the tail latency of insert operations can spike dramatically.

Vacant space management affects:

- **Storage costs** – Less bloat means less capacity, fewer disks, and lower cloud bills.
- **Cache efficiency** – Hot data is spread across fewer pages, improving buffer pool hit rates.
- **Write amplification** – Writes waste I/O when they fill an empty page instead of a partially‑full one.
- **Garbage collection overhead** – Systems like LSM trees rely on compaction; poor visibility of free space makes compaction less effective.
- **Index maintenance** – B‑tree indexes that point to freed pages must be cleaned up via “page merge” operations.
- **Backup and replication** – Less data to backup and transfer reduces both time and network load.
- **Operational pain** – Frequent vacuums, defragmentation scripts, and emergency disk expansions consume DBA cycles.

Despite this, the topic is often glossed over in database curriculum. The classic textbook _Database Management Systems_ (Ramakrishnan & Gehrke) devotes a few pages to “page organization and free space management” but rarely explores the trade‑offs deeply. Meanwhile, the major engines—PostgreSQL, MySQL, Oracle, SQL Server, DB2—all implement different strategies, each with profound implications.

Understanding how free space is tracked enables you to:

- Predict when a database will need maintenance.
- Choose the right engine for your workload.
- Tune parameters (like `fillfactor` in PostgreSQL) effectively.
- Debug performance issues that manifest as excessive bloat.

In this article, we will dissect the three classical approaches—**bitmap**, **free list**, and **B‑tree allocation**—and show how they shape the behavior of modern databases. We will dive into implementation details, code snippets, and real‑world case studies. By the end, you will understand why your database sometimes behaves like a hoarder, and what you can do about it.

---

## The Anatomy of Vacant Space: Storage Hierarchies, Pages, and Slots

Before we can manage free space, we must understand the storage hierarchy inside a database. A typical row‑oriented engine organises data into:

1. **Tablespace or file** – The logical storage container, often a raw file or a partition.
2. **Segment** – A collection of extents allocated to a specific object (table, index, etc.).
3. **Extent** – A contiguous group of pages, typically 64 KB to 2 MB.
4. **Page (block)** – The unit of I/O, typically 8 KB (PostgreSQL, MySQL) or 4 KB (Oracle).
5. **Slot/tuple** – A record stored on a page.

Deleting a record does not immediately release the page. Instead, the slot is marked as free, and the page’s internal “free space” pointer is updated. But eventually, when enough slots are freed, the page may become entirely empty and should be returned to the global free space pool.

The challenge is to maintain a data structure that quickly answers two questions:

- **Where can I insert a new record of size S?** (Find a page with at least S bytes free.)
- **Where are completely empty pages that can be reused by any segment?** (Avoid expanding the file.)

The answer must be **fast** (microseconds per operation), **concurrent** (many transactions modifying free space simultaneously), and **space‑efficient** (the tracker itself must not consume too much storage).

A naïve approach would be to scan all pages to find free space—obviously too slow. Instead, databases maintain a meta‑index over pages: a **free space map** (FSM). In the following sections we examine three classical designs for that map.

---

## Tracking Free Space: The Three Classical Approaches

### 1. Bitmap

#### Definition and Data Structure

A bitmap is an array of bits, where each bit corresponds to a fixed‑sized allocation unit—typically a page or an extent. A 1 indicates that the unit is **free** (or has enough free space, depending on granularity), and a 0 indicates it is **full** (or occupied). More sophisticated bitmaps might use two bits: one for “empty”, one for “partially full”, and one for “full”.

#### How It Works

Assume we have an 8 KB page file. The bitmap itself resides in a special header page or a separate bitmap file. For a database of 1 million pages (8 GB), the bitmap would be 1 million bits = 125 KB—a trivial overhead. To find a free page, we scan the bitmap for a 1 bit, often using a hardware instruction like `BSF` (bit scan forward) or a lookup table. Because the bitmap fits in cache, this is extremely fast.

For partial‑page reuse, the bitmap might encode a free‑space percentage using multiple bits per page. For example, Oracle’s Automatic Storage Management (ASM) uses a bitmap that tracks four states: 0–25% full, 25–50%, 50–75%, 75–100%. But to avoid scanning linearly, the bitmap is often organized into a hierarchy: a coarse bitmap at the top indicates “some free space” for a group of pages, and a fine bitmap inside each group.

**Code Snippet (simplified bitmap in C):**

```c
// Assume page_count = total number of pages
uint8_t *bitmap = calloc((page_count + 7) / 8, 1);

// mark page_index as free (unused)
void mark_free(int page_idx) {
    int byte = page_idx / 8;
    int bit  = page_idx % 8;
    bitmap[byte] |= (1 << bit);
}

// find first free page (bit = 1)
int find_free() {
    for (int byte = 0; byte < (page_count+7)/8; byte++) {
        if (bitmap[byte] == 0) continue;          // no free bits
        // use built-in "find first set" bit instruction
        int bit = __builtin_ctz(bitmap[byte]);
        return byte * 8 + bit;
    }
    return -1; // no free space
}
```

This linear search can be optimised by keeping a pointer to the “last known free page” and starting from there (to avoid always scanning from the beginning). Alternatively, the bitmap can be complemented with a separate “free page stack” that remembers pages that were recently freed.

#### Real‑World Usage

- **Oracle’s Automatic Storage Management (ASM)** – Uses a two‑level bitmap for free space in disk groups. The coarse map indicates “free extent” and the fine map tracks individual allocation units.
- **MySQL InnoDB** – For the **FSP_HDR** (file space header) pages, InnoDB uses bitmap pages to track the state of each page within an extent. The bitmap uses 2 bits per page: 00 = free, 01 = clean, 11 = dirty.
- **SQL Server** – Uses Global Allocation Map (GAM) and Shared Global Allocation Map (SGAM) pages, which are essentially bitmaps indicating which extents are allocated and which are mixed extents with free pages.
- **PostgreSQL’s visibility map** – While not directly for free space, the visibility map uses a bitmap to indicate which pages contain only all‑visible tuples (for index‑only scans and vacuum). The actual free space map (FSM) is different.

#### Advantages

- **Compact** – Extremely low overhead (1 bit per page).
- **Fast allocation** – With hardware support, scanning for a free bit is O(n/word) but with constant factors.
- **Good for uniform page sizes** – Works well when all pages are the same size.
- **Easy to store on disk** – Bitmaps can be written in bands and are trivially flushed.

#### Disadvantages

- **Stale data** – A bit may indicate “free” but the page might hold uncommitted data (recovery issues). Need to synchronise with transaction visibility.
- **Fragmentation of bitmap itself** – If pages are freed in a scattered pattern, finding a contiguous run of free pages is not straightforward.
- **Concurrency** – Updating a single bit while another transaction concurrently updates a bit in the same byte creates a write‑write conflict. Using atomic CPU instructions (CAS) helps, but contention on the bitmap page can become a problem.
- **Not good for variable allocation sizes** – If you want to allocate regions of different sizes (e.g., 2‑page extents vs. 1‑page), the bitmap becomes more complex (multiple bit layers).

#### When It Shines

Bitmaps are optimal for simple, single‑sized allocations where the goal is to quickly find any free page. They are common in file systems (Linux ext\* uses bitmaps for block groups) and in database engines that use a **uniform page size** and have a relatively small number of pages (e.g., per tablespace).

---

### 2. Free List

#### Definition and Structure

A **free list** (also called a freelist) is a linked list or a stack of free pages (or extents). Each node in the list points to the next free page identifier. The list is stored either as a separate system page or as a chain of pointers embedded in the page headers themselves.

#### How It Works

When a page becomes empty (all records deleted), it is “linked” into the free list. The head of the list resides in the tablespace header. To allocate a page, the system pops the head, reads the pointer to the next free page, and updates the head. This is an O(1) operation. To support concurrency, a compare‑and‑swap (CAS) on the head pointer can be used, or a latch protects the list.

For partially free pages, many engines maintain **multiple free lists**—one for fully empty pages, and one for pages with some free space. For example, Oracle’s **segment freelist** groups pages into “buckets” based on the amount of free space (e.g., 0–25%, 25–50%, etc.). Each bucket is a separate free list. A transaction that needs space for an insert first checks the appropriate bucket list.

**Code Snippet (pseudocode for a simple free list):**

```python
# global: free_list_head (integer page_id, or -1 for NIL)
def allocate_page():
    while True:
        old_head = free_list_head
        if old_head == -1:
            return -1   # no free pages, extend file
        # read the page to find the 'next' pointer (stored in page header)
        next_page = read_next_pointer(old_head)
        if CAS(free_list_head, old_head, next_page):
            return old_head

def deallocate_page(page_id):
    while True:
        old_head = free_list_head
        write_next_pointer(page_id, old_head)  # store old head in page
        if CAS(free_list_head, old_head, page_id):
            break
```

#### Real‑World Usage

- **Oracle Database** – Freelists are the traditional mechanism for managing free space in a segment. Each segment has a master freelist and one or more process freelists to reduce contention. Oracle also supports ASSM (Automatic Segment Space Management) which uses bitmaps instead.
- **MySQL InnoDB** – The **FSP** (file space) header maintains a linked list of free extents. Each extent header has a “free” list linking pages within that extent.
- **Berkeley DB** – Uses free lists for its page‑based storage engine.
- **PostgreSQL FSM** – While predominantly a B‑tree‑like structure (see next section), it also uses a free list internally for the FSM pages themselves (a chain of free FSM pages).

#### Advantages

- **Very fast allocation and deallocation** – O(1) with atomic head update.
- **Good for workloads with bursts of inserts and deletes** – The free list quickly returns recently freed pages.
- **Simple to implement and debug**.
- **Natural ordering** – If pages are freed and immediately re‑used, they stay in cache, improving buffer pool efficiency.

#### Disadvantages

- **Contention on the head pointer** – All concurrent transactions need to update the same CAS variable. This can become a severe bottleneck on multi‑core systems.
- **Head of line blocking** – The free list must be protected by a latch or spinlock. With many CPUs, the latency grows.
- **Fragmentation** – A free list tends to reuse the most recently freed pages, which may be physically scattered. If the database relies on sequential I/O, this can harm performance.
- **No partial free space sorting** – Without multiple lists, all partially free pages are lumped together; a page with 90% free and a page with 10% free are treated the same, leading to inefficient packing.
- **Page corruption risk** – If the freelist pointer inside a page is corrupted, the entire list can break, rendering many pages unreachable.

#### When It Shines

Free lists are excellent for low‑concurrency environments or systems where the number of free pages is small. They are also used as the “fast path” for returning empty pages, often combined with other structures for more sophisticated searches. Many databases use a free list for the **fully empty pages** (the “cleanup” list) and a bitmap or B‑tree for partial reclamation.

---

### 3. B‑tree Allocation (FSM in PostgreSQL)

#### Definition and Structure

A **B‑tree for free space** is a tree where each leaf node corresponds to a page (or a group of pages) and stores the amount of free space on that page. Internal nodes store the maximum free space within their subtree. This allows efficient range queries: “find a page with at least **N** bytes free.” The tree can be searched in O(log n) time.

PostgreSQL calls this structure the **Free Space Map (FSM)**. The FSM is a low‑level B‑tree that lives in a specific fork of each relation (`_fsm` file). The tree uses a fixed‑depth algorithm: the first leaf level stores free‑space bytes for each page (capped at a maximum, e.g., `BLCKSZ - 32` for page header). Internal nodes contain the maximum free space of their children. The root node is small enough to fit in one 8 KB page (for large relations, the FSM can have multiple levels).

#### How It Works

When a transaction needs to insert a tuple, it consults the FSM to find a page with enough free space. The search starts at the root and descends to the leaf that has a value >= needed space. If multiple pages qualify (many leaves have similar free space), PostgreSQL typically picks the first one found (leftmost) but may randomize to avoid hot spots. After the insert, the page’s free space decreases; the FSM must be updated upward.

Deleting a tuple frees space. The FSM updates the leaf value accordingly, potentially increasing it, and propagates the maximum upward.

The FSM also tracks completely empty pages (free space = `BLCKSZ - 32`). These are reused preferentially.

**Code Snippet (simplified PostgreSQL FSM search – in C):**

```c
/* Search the FSM for a page with at least needed free space */
int fsm_search(FSM *fsm, Size needed) {
    int level = fsm->nlevels - 1; // start at root
    int nodeno = 0;               // root node index
    while (level > 0) {
        // Scan children of current node to find one with max >= needed
        int i;
        for (i = 0; i < MAX_CHILDREN; i++) {
            if (fsm->nodes[level][nodeno * MAX_CHILDREN + i] >= needed)
                break;
        }
        if (i == MAX_CHILDREN) return -1; // no page found
        nodeno = nodeno * MAX_CHILDREN + i;
        level--;
    }
    // leaf level: nodeno is the page number
    return nodeno;
}
```

#### Real‑World Usage

- **PostgreSQL** – The FSM is the primary free‑space manager. Every relation (table, index) has its own FSM file. It is updated eagerly on inserts and lazy (via background process) on deletes to avoid write amplification.
- **MySQL NDB Cluster** – Uses a similar tree structure for tracking free pages in the data nodes.
- **Some key‑value stores** – LevelDB and RocksDB use a B‑tree for their version of free space in the SST file manager.

#### Advantages

- **Supports partial reuse with any granularity** – can find a page with exactly N bytes free.
- **Efficient search** – O(log n) typical, and the tree depth is small (PostgreSQL uses fan‑out ~32, so depth ≤ 4 for billions of pages).
- **No single point of contention** – The tree is distributed; concurrent updates can happen on different branches.
- **Good for high‑concurrency** – PostgreSQL uses fine‑grained locking (page‑level latches) on the FSM tree.

#### Disadvantages

- **Update overhead** – On each insert or delete that changes free space, the leaf and potentially all ancestors must be updated. This write amplification can be significant in write‑heavy workloads.
- **Complexity** – The FSM must handle tree growth, splitting, and merging (though PostgreSQL’s FSM is fixed‑depth and uses a special search tree that avoids splits).
- **Memory consumption** – The FSM is stored as a separate file, adding small overhead (about 0.1% of relation size). But it must be read into memory, increasing cache pressure.
- **Lag in updating free space** – PostgreSQL does not update the FSM immediately after every deletion; instead, it marks the page as potentially having more free space (via `PageSetFreeSpace`) and lets a background process propagate the maxima. This can lead to outdated FSM entries, causing occasional scans of the entire relation (the “vacuum” process also rebuilds the FSM).

#### When It Shines

B‑tree allocation is ideal for workloads where free space varies widely and pages have differing amounts of room. It is the backbone of PostgreSQL’s ability to pack many small tuples into a page efficiently, even under heavy concurrent DML. However, it introduces non‑trivial overhead that may not suit extremely high‑Throughput insert‑only workloads (those are better served by other structures like freelists or LSM trees).

---

## Deep Dive: Comparison and Trade‑offs

| Feature                       | Bitmap                                                       | Free List                                           | B‑tree (FSM)                                                   |
| ----------------------------- | ------------------------------------------------------------ | --------------------------------------------------- | -------------------------------------------------------------- |
| **Time to find free page**    | O(n/word) – linear but fast HW                               | O(1)                                                | O(log n)                                                       |
| **Time to free a page**       | O(1) (set bit)                                               | O(1) (push to head)                                 | O(log n) (update leaf & up)                                    |
| **Space overhead**            | ~1 bit per page (0.0125%)                                    | ~8 bytes per page (pointer) but only for free pages | ~2 bytes per page (leaf value) + internal nodes (~4% overhead) |
| **Supports partial pages**    | Need multiple bits/state per page                            | Multiple freelists per %bucket                      | Native (store free space bytes)                                |
| **Concurrency**               | Hot bits cause CAS contention                                | Hot head pointer is a bottleneck                    | Better distribution, latches on tree nodes                     |
| **Fragmentation resistance**  | Low – first fit can scatter                                  | Low – LIFO re‑use increases scatter                 | Moderate – can be tuned with search order                      |
| **Implementation complexity** | Low                                                          | Low                                                 | High (tree maintenance)                                        |
| **Real‑world usage**          | MySQL InnoDB (bitmap per extent), Oracle ASM, SQL Server GAM | Oracle freelist, older MySQL                        | PostgreSQL FSM, Db2 V9+ (optional)                             |

### Performance Under OLTP vs. OLAP

- **OLTP (many short transactions with inserts/deletes):** Requires fast, low‑contention free space allocation. A simple free list can become a hot bottleneck (head pointer). Bitmaps with atomic operations can do well, but the linear scan for a free page may cause latency variability. PostgreSQL’s B‑tree spreads contention over many nodes, but update overhead (logging tree changes) adds to transaction cost.
- **OLAP (bulk loads, large scans, vacuum/compaction):** The free space manager is less critical because bulk inserts often allocate new extents. However, after large deletes, the system must reclaim bloat efficiently. Bitmaps are excellent for returning large regions (extent‑level free maps). Free lists may cause long chains if many pages are freed simultaneously.

### Concurrency Considerations

The free list head is a single point of serialization. Oracle’s classic freelist implementation was a notorious source of contention in high‑concurrency databases, leading to the development of multiple process freelists and eventually ASSM (bitmap). Bitmaps also have hot bits when many transactions compete for pages in the same byte. Both can be mitigated by partitioning: having many bitmaps per tablespace or many freelists per segment (e.g., 32 freelist groups in Oracle).

The B‑tree approach, while more complex, naturally partitions the tree into subtrees. Each leaf page update requires latching only that leaf page and its ancestors (which are shared among many leaves, but in practice, contention occurs only on high‑level nodes during peak “max updates”). PostgreSQL’s FSM uses a random search order to avoid repeated searching of the same leaf.

### Space Overhead

Bitmaps win hands‑down for large databases. A 10‑TB database with 8 KB pages has ~1.25 billion pages, requiring ~150 MB for a single‑bit bitmap. That’s negligible. A B‑tree storing 2‑byte free space values for the same pages would take ~2.5 GB for leaves alone, plus internal nodes (say 10% overhead), totaling ~2.75 GB. For an SSD array it’s acceptable, but for HDD or memory‑constrained systems it can matter.

Free lists have minimal persistent overhead: only the head pointer (and perhaps a counter). The pointers inside free pages are only temporary; the page is free, so storing a pointer there uses no extra permanent data. However, freeing a page requires updating its header, which is a write I/O.

### Fragmentation Resistance

Fragmentation manifests in two ways: **internal fragmentation** (wasted space within a page) and **external fragmentation** (free pages scattered across the file, preventing sequential I/O).

- **Bitmaps** with first‑fit allocation can lead to external fragmentation. If many small free groups exist, large requests (e.g., for a B‑tree split that needs a contiguous 64 KB) may fail, forcing an extent request.
- **Free lists** with LIFO (last‑in‑first‑out) reuse tend to keep free pages scattered across the file, making sequential scanning slower.
- **B‑tree** allocation can be designed to favour pages that are close to each other. PostgreSQL’s FSM does not guarantee locality, but if a relation is accessed sequentially, the pages are naturally ordered by file offset, so re‑using a page near the last inserted page can help.

---

## Case Studies: How Major Databases Handle Free Space

### PostgreSQL: The FSM and the Visibility Map

PostgreSQL’s free space management is remarkably well documented. Each relation (table or index) has a **fork** – a secondary file with suffix `_fsm`. The FSM is a binary tree (with fan‑out 32) that stores free space as a single byte per page (capped at 2 bytes for large page sizes). The tree is built lazily: new pages start as empty (value 0), and are only inserted into the FSM when the first tuple is inserted (the FSM is updated during VACUUM or on‑the‑fly). Deleted space is not immediately reflected in the FSM; instead, an `ItemId` array is cleaned, and the page’s free space value is set during the next visit by a backend or by `VACUUM`. This delay protects against write amplification: updating the FSM on every tuple deletion would be too expensive. The trade‑off is that between VACUUMs, the FSM may overstate the free space, leading to occasional “page too full” errors that force another search (PostgreSQL then steps through pages sequentially in a fallback routine).

Additionally, PostgreSQL maintains a **visibility map** (a bitmap of pages where all tuples are visible to all transactions) to optimise index‑only scans and VACUUM skipping. This is a separate bitmap, not for free space, but it interacts with the FSM: VACUUM scans the visibility map to find pages to clean, and after cleaning, it updates the FSM.

Impact on performance: For a write‑heavy workload, the FSM can become a bottleneck because every insert must traverse the tree. In PostgreSQL 16, the FSM search was improved by using the “remaining free space value” from the leaf to avoid repeated updates (if an insert uses exactly the needed space, the update is skipped). But the write amplification remains a concern.

### MySQL InnoDB: The Free List and Bitmap Hybrid

InnoDB manages space at two levels: **tablespace** and **segment**. Each segment (a table or index) has its own free list of pages. The free list is a simple linked list where each page in the list contains an offset to the next free page. This list is protected by the **segment mutex**. When a page becomes empty (no records), it is added to the end of the segment’s free list. To allocate a page, InnoDB typically pops from the head of the list. If the free list is empty, InnoDB allocates a new extent (64 consecutive pages) from the tablespace, which uses a bitmap file (`FSP_HDR`) to track which extents are free.

Internally, InnoDB uses a **bitmap** (the “page bitmap”) inside each extent’s first page (`XDES` entry) to track the state of the 64 pages: free, clean, dirty, etc. This bitmap is used for flushing and checkpointing decisions but not directly for free space search. For partial free space, InnoDB examines pages individually by reading the page header (via the “free space” field in the page). This is expensive; to optimise, InnoDB caches free space information in the **buf_pool** for each page, but that cache is only for in‑memory pages.

The net result is that InnoDB’s free space management is relatively simple: a free list for fully empty pages, and a per‑page brute‑force check for partial reuse. This works well for workloads that generate many full‑page deletes (e.g., temporary tables) but can lead to fragmentation for random updates.

InnoDB also uses a **doublewrite buffer** to ensure consistency of the free list updates: when a page is freed, the pointer changed is written to the doublewrite buffer before modifying the page.

### Oracle: From Freelist to ASSM (Bitmap)

Oracle’s classic architecture uses per‑segment freelists. Each segment has a **segment header** page that contains the head of the freelist and a list of “holes” (partially free pages). This approach was simple and fast for low‑concurrency, but became a bottleneck on modern CPUs. Starting with Oracle 9i, **Automatic Segment Space Management (ASSM)** was introduced. ASSM replaces freelists with a bitmap that tracks free space at multiple granularities: **blocks** (pages) within an **extent**, and **extents** within a segment. The bitmap uses 2 bits per block for space fullness (0–25%, 25–50%, 50–75%, 75–100%) and a higher‑level bitmap to locate extents with free space.

The ASSM bitmap is stored in special **bitmap blocks** (e.g., `BMB` blocks). These bitmap blocks are themselves managed in a B‑tree structure for efficient search. This is essentially a combination of a bitmap and a tree: the leaves are bitmap pages covering a range of data blocks, and the internal tree indexes the free space summary of each leaf. Oracle’s implementation is proprietary but well studied: it provides high concurrency and avoids the hot‑head problem of freelists. However, the tree and bitmaps add overhead; for small tables, the old freelist could be faster.

The trade‑off: ASSM is now the default for most Oracle workloads, indicating that the complexity is worth it for scalability.

### SQL Server: GAM/SGAM/ PFS

SQL Server uses a multi‑layer free space tracking system:

- **Global Allocation Map (GAM)** – A bitmap where each bit represents an **extent** (8 pages). 1 = extent is free, 0 = allocated.
- **Shared Global Allocation Map (SGAM)** – A bitmap for mixed extents (extents that contain pages from multiple objects). Each bit indicates whether the extent is a mixed extent with at least one free page.
- **Page Free Space (PFS)** – A byte per page (stored in PFS pages, one per ~8000 pages) that indicates the free space percentage (0%, 1–50%, 51–80%, 81–95%, >95%). PFS is used to quickly find pages with enough space for row allocation.

When allocating a new page for a table, SQL Server first consults the PFS for a page with sufficient free space. If none found, it consults the SGAM for a mixed extent with a free page. If that fails, the GAM is consulted for a free uniform extent (8 contiguous pages). This layered approach combines the speed of bitmaps (for extent allocation) with byte‑based free space for partial pages.

The PFS bytes are stored in a fixed structure, which is essentially a compact array. Searching it can be done efficiently because each PFS page covers many data pages; SQL Server scans the PFS page linearly but uses in‑memory data structures after initial load.

This design is highly scalable and has been refined for decades. It avoids the drawbacks of a single freelist by distributing free space information across many pages.

### NoSQL Systems: MongoDB and Cassandra

NoSQL databases often use **write‑ahead log (WAL)** and **append‑only** files, which sidestep many vacant space issues. However, they still need to manage space.

- **MongoDB** – Uses a wiredTiger storage engine that supports **tiered storage** where free space is reused via a free list of extents. WiredTiger also uses B‑trees for its internal pages; each B‑tree page has a “free list” of free space chunks within that page. The global extent free list is protected by a mutex, which can be a bottleneck under high concurrent allocations. To mitigate, WiredTiger uses “page reconciliation” that defers freeing.

- **Cassandra** – Uses LSM trees with compaction. Vacant space is not directly tracked per page; instead, SSTables are immutable and space is reclaimed when an SSTable is compacted. The free space manager is the **compaction strategy** (SizeTiered, Leveled, etc.) which merges files to produce dense ones and deletes the old files. There is no per‑row free space map; the entire SSTable is either live or deleted.

---

## Advanced Topics: Vacuum, Compaction, and Defragmentation

No matter how efficient the free space tracker, bloat can still accumulate due to:

- **MVCC** – In PostgreSQL, old row versions remain until a VACUUM removes them.
- **Update patterns** – In‑place updates (like in InnoDB) may move a row to a new page if it doesn’t fit, leaving a hole.
- **Index splits** – B‑tree splits often create pages that are 50% empty.
- **Bulk deletes** – Deleting many rows may leave many pages nearly empty.

Therefore, databases provide **background processes** to reorganise pages and reclaim space:

- **PostgreSQL VACUUM** – Scans pages, removes dead tuples, updates the FSM, and optionally rebuilds the index (VACUUM FULL). It also updates the visibility map.
- **InnoDB Purge** – Removes old versions that are no longer visible, then updates page free space. InnoDB also has **optimize table** which rebuilds the table.
- **Oracle Segment Shrink** – Moves rows within a segment to pack pages, and updates the bitmap (ASSM).
- **SQL Server Index Rebuild** – Clusters the index, filling pages to a target fill factor, and releases empty pages to the free pool.

A good free space tracker can dramatically reduce the need for these operations. If free space is quickly and accurately tracked, new inserts will reuse empty slots before the file grows. Conversely, an inaccurate tracker (like PostgreSQL’s delayed FSM update) can cause the database to grow even though free space exists, forcing a VACUUM to correct the map.

### OID Recycling and Page Reuse

In PostgreSQL, when a page becomes completely empty, it is added to the FSM and can be reused by any new row in the same relation. However, the page’s **page header** includes a `pd_prune_xid` and other metadata that are not cleaned. VACUUM will eventually reset these. The critical aspect is that the **page ID** is not reused across relations—each page is uniquely identified by its offset within a relation file. So a page that becomes free is not “deallocated” back to the operating system unless VACUUM FULL or a block‑level discard (`discard`) happens. This is why table files rarely shrink.

### Online vs. Offline Defragmentation

Offline operations (e.g., `REINDEX`, `CLUSTER`, full vacuum) lock the table and rebuild it entirely. They are expensive but produce optimal packing. Online operations (e.g., `VACUUM` without `FULL`, `OPTIMIZE` with online DDL) try to free space without blocking reads/writes. They rely heavily on the free space tracker to know which pages can be consolidated. A bitmap‑ or B‑tree‑based tracker can quickly identify candidate pages.

---

## Code Snippets: Implementing a Simple Free Space Manager

To solidify the concepts, let's implement a minimalist free space manager in Python that combines a bitmap (for fully free pages) and a B‑tree (for partial space). This is not production‑ready but illustrates the core logic.

```python
import bisect

class FreeSpaceMap:
    def __init__(self, num_pages, page_size=8192, header_overhead=32):
        self.page_size = page_size
        self.header_overhead = header_overhead
        self.free_bytes = [page_size - header_overhead] * num_pages  # initial all empty
        # For fully empty pages we also maintain a bitmap for O(1) search.
        # We'll store a set of empty page IDs for simplicity.
        self.empty_pages = set(range(num_pages))
        # For B‑tree: we build a simple list sorted by free_bytes?
        # Not efficient, but for demonstration.

    def allocate(self, needed):
        # First, try to find a page with at least needed free bytes.
        # For efficiency we would use the B‑tree; here linear scan:
        for pid in range(len(self.free_bytes)):
            if self.free_bytes[pid] >= needed:
                # mark as used – update free_bytes
                self.free_bytes[pid] -= needed
                self.empty_pages.discard(pid)
                return pid
        return None  # no suitable page

    def deallocate(self, pid, freed_bytes):
        self.free_bytes[pid] += freed_bytes
        if self.free_bytes[pid] >= self.page_size - self.header_overhead:
            self.empty_pages.add(pid)

    def get_empty_count(self):
        return len(self.empty_pages)
```

This is simplistic. Real implementations would use a structure like a binary heap or a B‑tree to avoid the O(n) loop. However, it shows the core: after each operation, we update the free space value and manage the empty page set.

For a more advanced free list variant in C, we can use lock‑free techniques:

```c
// Global head pointer, atomic
_Atomic uint32_t free_list_head = -1;

uint32_t allocate_page(void) {
    uint32_t expected, new_head;
    do {
        expected = atomic_load(&free_list_head);
        if (expected == (uint32_t)-1) return -1;
        // read next pointer from the page (assume page is in buffer pool)
        uint32_t next = page_header_get_next(expected);
        new_head = next;
    } while (!atomic_compare_exchange_weak(&free_list_head, &expected, new_head));
    return expected;
}
```

This uses a CAS loop. For multi‑producer concurrency, it works well but may livelock under extreme contention.

---

## The Future: LSM Trees and Log‑Structured Storage

The classical approaches (bitmap, free list, B‑tree) assume a **page‑structured, in‑place update** engine. But the rise of LSM‑tree based databases (RocksDB, LevelDB, Apache Cassandra, ScyllaDB) challenges this paradigm. In LSM trees, data is written to immutable sorted string tables (SSTables) and then compacted (merged) in the background. Free space management shifts from per‑page tracking to **file‑level garbage collection**. The system tracks which SSTable files are completely obsolete and can be deleted, reclaiming whole file regions at once. Within a file, there is no need for a free space map because files are never updated; they are only read and overwritten via compaction.

However, even LSM trees must handle **write‑ahead logs (WAL)** and **memtables**. WALs are often circular: they reuse blocks by overwriting. For that, a simple free list of WAL blocks works well. Memtables are flushed entirely, so no free space tracking is needed.

For systems that combine both (e.g., a columnar database with in‑place updates on hot rows), hybrid approaches appear. The future likely holds a convergence: **learned free space management** using machine learning to predict which pages will be freed soon, and **hybrid structures** that dynamically switch between bitmap, free list, and B‑tree depending on workload patterns.

### Conclusion

Vacant space management is not glamorous; it is the unsung hero that determines whether your database runs lean and fast or bloats and slows. The three classical methods—bitmap, free list, and B‑tree—each excel in different contexts.

- **Bitmap** is the minimalist, great for uniform page sizes and low write amplification (e.g., extent allocation). It is used by MySQL InnoDB, SQL Server GAM/SGAM, and Oracle ASM.
- **Free list** offers O(1) allocation and deallocation, but suffers from contention and fragmentation. It remains in use for simple systems and as a complement to other methods (e.g., empty page recycling in PostgreSQL FSM).
- **B‑tree (FSM)** provides flexible search by free space amount, enabling efficient packing. PostgreSQL adopts this approach, and despite its overhead, it scales well under concurrency.

Understanding these mechanisms helps you choose the right database and tune it appropriately. If you run a write‑heavy OLTP system on PostgreSQL, you may need to adjust `fillfactor`, schedule VACUUM more aggressively, or consider partitioning to reduce FSM contention. If you use MySQL, be aware that the free list and per‑page search can cause bloat under heavy update workloads; a periodic `OPTIMIZE TABLE` is your friend. If you use Oracle, understand when ASSM is beneficial vs. classic freelists (e.g., for high‑concurrency RAC environments).

The next time your database inexplicably doubles in size overnight, resist the urge to blame the application. Instead, look at the free space map—it might be silently suffocating.

_Do you have war stories about database bloat? Share them in the comments. If you found this deep dive useful, consider sharing it with a fellow DBA who still thinks database growth is just "how it works."_
