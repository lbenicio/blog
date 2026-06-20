---
title: "Implementing A B Tree From Scratch: Storage, Concurrency, And Recovery"
description: "A comprehensive technical exploration of implementing a b tree from scratch: storage, concurrency, and recovery, covering key concepts, practical implementations, and real-world applications."
date: "2025-04-20"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/Implementing-A-B-Tree-From-Scratch-Storage,-Concurrency,-And-Recovery.png"
coverAlt: "Technical visualization representing implementing a b tree from scratch: storage, concurrency, and recovery"
---

Here is a comprehensive introduction for your blog post.

---

### The Unreasonable Effectiveness of the B-Tree: Why You Should Build One From Scratch

Most developers will never need to write a B-tree from scratch. In fact, for the vast majority of software engineering tasks, doing so would be a catastrophic misallocation of time and energy. We have PostgreSQL, SQLite, MySQL, and a dozen other battle-tested databases that abstract away the brutal complexity of data storage and retrieval. We treat these systems as magical black boxes—we write a query, and somehow, instantly, the right rows appear. We rarely stop to ask _how_ the database finds a single record among billions in less time than it takes for light to travel across a silicon wafer.

The answer, in almost every case, is the B-tree.

This data structure is the unsung hero of the digital age. It underpins the transactional databases that power our bank accounts, the file systems that organize our operating systems, and the key-value stores that drive the world’s largest web applications. It is a masterpiece of theoretical computer science designed to solve a single, brutal problem: **the gap between the speed of the CPU and the speed of the disk.**

But knowing _that_ a B-tree is important is very different from understanding _why_ it works, _how_ it fails, and _what_ it sacrifices. Most university courses teach the B-tree as a purely logical construct. You learn about node splitting, key promotion, and the invariant of balanced height. You implement it in memory using Python or Java, insert a few thousand integers, and call it a day. You walk away thinking you understand it.

You don’t.

A B-tree in memory is a toy. It ignores the fundamental physics that makes the B-tree necessary in the first place. It ignores the fact that a disk page fault is a million times slower than a CPU cache miss. It ignores the fact that your program might crash halfway through a node split, leaving your data in an unrecoverable, corrupted state. It ignores the fact that two threads might try to insert into the tree at the same time, causing a race condition that silently destroys the structural integrity of your index.

This blog post is about bridging that gap. We are going to build a B-tree from scratch, but we are not building a toy. We are building a system that must survive. We will explore the three pillars of production-grade data structure implementation: **Storage**, **Concurrency**, and **Recovery**.

#### The Problem: The Tyranny of the Page

Before we write a single line of code, we have to understand the problem we are trying to solve. Why can't we just use a hash map or a balanced binary search tree?

The answer is locality of reference and the economics of I/O.

Modern storage hardware (SSDs and spinning disks) reads and writes data in blocks, not individual bytes. An SSD reads a page of 4KB at a time. A spinning disk might read a sector of 512 bytes. Even on a modern NVMe drive with microsecond latency, the cost of issuing a read request is dominated by the _overhead_ of the I/O operation itself. If you need to fetch one byte, you are still paying the cost of fetching an entire page.

Now, consider a standard binary search tree. Each node is usually a small object containing a key and two pointers. These nodes are allocated independently by the memory manager. They are scattered across the heap. If you are storing this tree on disk, each node traversal is likely a separate page read. To find a specific key, you might need to perform **log2(n)** random I/O operations. For a database with a billion records, that is roughly 30 random page reads. At 100 microseconds per read (optimistic for a high-end NVMe), that's 3 milliseconds—fast, but far too slow for a high-throughput system that is handling thousands of queries per second. On a spinning disk, at 10 milliseconds per seek, you are looking at a third of a second for a single lookup. Unacceptable.

The B-tree solves this by **maximizing the fan-out**. Instead of storing one key and two child pointers per node, a B-tree stores hundreds or even thousands of keys and pointers in a single node. This node is exactly sized to fit within a single disk page (e.g., 4KB or 16KB). The tree becomes short and wide. A four-level B-tree can easily store billions of records. A lookup requires traversing exactly _height_ nodes, meaning you read exactly _height_ pages from disk. For a billion-record tree, that is typically 3 or 4 page reads. This is not just an optimization; it is a fundamental shift in the performance profile. We have traded logical elegance (binary trees) for physical performance (B-trees).

#### Beyond the Textbook: The Three Pillars

Implementing a B-tree that just works in memory is a rite of passage. You implement `insert`, `split`, `delete`, and `merge`. You ensure the invariants hold. It feels good.

But when you decide to make this tree _persistent_—to write it to a file and read it back—you are immediately confronted with a new set of problems.

**1. Storage: The Art of Serialization and Pointer Translation**

In memory, pointers are virtual addresses. You access a node via a reference like `node->left_child`. On disk, there are no pointers in the traditional sense. You have file offsets. When you read a node from disk, you need to know _where_ it is stored. This means every child pointer in your in-memory node must be translated to a page ID or a file offset. This introduces the concept of a **page manager**.

The page manager is the arbiter of physical space on your disk. It allocates new pages, frees old ones, and provides a mapping from a logical page number to a physical offset in the file. It must also handle fragmentation. When you split a node, the new node needs a new page. When you merge nodes, you free pages. If you are not careful, your file will grow indefinitely, wasting space and hurting performance.

Furthermore, serialization is not trivial. The data inside your B-tree nodes—the keys and values—needs to be layed out in a specific way. You need to handle variable-length keys, endianness, and padding. A naive `memcpy` of your struct to disk will break the moment you switch operating systems or compilers.

**2. Concurrency: The Devil in the Weave**

A database index is rarely accessed by a single thread. In a production system, hundreds of clients are inserting, deleting, and reading concurrently. If a B-tree is implemented without concurrency controls, the results are catastrophic.

Consider the classic scenario: a node split. Thread A is inserting a key into node N. Node N is full. Thread A decides to split node N, creating a new node N'. It needs to push the median key up to the parent. While Thread A is in the middle of this operation, Thread B is reading node N. Thread B might see an inconsistent state. It might see a node that has half its keys moved, but the pointers haven't been updated yet. It might follow a child pointer that points to freed memory. The program crashes. Data is lost.

There are many strategies to handle this. The classic approach is **latch coupling** (or crabbing). You acquire a read or write latch on a node before you access it. You then "crab" your way down the tree, holding latches on multiple nodes to prevent split or merge operations from interfering with ongoing searches. This is a subtle and error-prone dance. If you are not careful, you can create deadlocks. If you are too aggressive with your locking, you serialize all access to the tree, destroying your performance.

Modern B-trees (like the Bw-Tree from Microsoft Research or LMDB's B-tree) use lock-free or optimistic concurrency control to avoid these issues, but they introduce their own complexity, such as handling phantom reads and ensuring memory safety without locks.

**3. Recovery: The Atomicity Problem**

You have written a beautiful, concurrent B-tree. Data is safe on disk. The system is running. Then the power fails.

What happens to your B-tree when the file system flushes a partial write? You were in the middle of a complex node split. You wrote the new node to the file, but you didn't write the parent update. The tree is corrupted. The next time you start the database, it will try to read a node that points to a page that contains garbage, or it will try to navigate a broken parent-child relationship.

Recovery is about ensuring that a B-tree operation is **atomic**. Either the entire insert or delete operation happens, or it doesn't. There is no "half-written" state.

The standard solution is the **Write-Ahead Log (WAL)** . Before you make any modification to the B-tree page file, you first write a record of the intended change to a log file. This log contains enough information to redo the operation (if it partially succeeded) or undo it (if it failed). On restart, the database replays the log to bring the tree to a consistent state.

But the WAL introduces a host of new problems. How do you ensure that the WAL is written before the data page? (You need a cache flush, which is expensive). How do you organize the WAL for efficient replay? How do you handle checkpoints to prevent the log from growing infinitely? This is the domain of **ARIES** (Algorithms for Recovery and Isolation Exploiting Semantics), a textbook algorithm that is remarkably complex to implement correctly.

#### What This Post Will Cover

This is not a theoretical overview. Over the course of this blog post, we are going to walk through the concrete implementation of a B-tree that addresses all three of these pillars. We will use a simple but practical language (Python or C, depending on your preference for clarity vs. performance) to build:

1.  **A persistent page allocator** that manages free pages and translates between page IDs and file offsets.
2.  **A serialization layer** that can pack and unpack B-tree nodes into fixed-size pages that can be read and written atomically using `pread` and `pwrite`.
3.  **A rudimentary latch-coupling concurrency mechanism** that allows multiple readers and a single writer to navigate the tree safely without deadlocks.
4.  **A minimal Write-Ahead Log (WAL) and recovery system** that ensures a crash during a split or merge will leave the tree in a consistent state.

By the end of this post, you will not just understand B-trees. You will understand why they are the foundation of modern storage systems. You will have the mental models required to debug production database issues, design your own storage engines, and appreciate the incredible engineering that goes into making a simple data structure survive the real world.

Let's build it.

# The B-Tree: A Deep Dive into Storage, Concurrency, and Recovery

Every database engineer eventually faces the same question: what happens when you have more data than memory? The answer, in most modern systems, is some variant of the B-Tree. While you could use a hash table or a binary search tree, neither handles the realities of disk storage particularly well. The B-Tree was designed specifically for systems where data lives on spinning rust (or SSDs, for that matter), and the bottleneck is almost always the latency of fetching data from persistent storage.

What makes implementing a B-Tree _from scratch_ particularly fascinating—and particularly challenging—is the intersection of three distinct concerns. You need the storage layer to manage how nodes live on disk. You need the concurrency layer to let multiple threads and transactions operate simultaneously. And you need the recovery layer to ensure that when the power fails at exactly the wrong moment, your data survives intact. Each of these layers is a substantial engineering challenge on its own. Combining them correctly is what separates a toy implementation from something you'd trust with production data.

## The Foundation: How B-Trees Actually Work on Disk

Before we get into the engineering challenges, let's make sure we're on the same page about what a B-Tree is. A B-Tree is a self-balancing tree structure where every node can contain multiple keys and multiple children. The key invariant is that every leaf sits at the same depth, which guarantees logarithmic performance for all operations.

The specific parameters that matter during implementation are the order (sometimes called the branching factor) and the minimum degree. The order tells you how many children a node can have. The minimum degree tells you the lower bound—except for the root, every node must be at least half full. This "half-full" property is what keeps the tree balanced and ensures that random insertions don't degrade into a pathological state.

### The On-Disk Node Structure

When you're working in memory, you can get away with pointers and dynamic allocation. On disk, you need a fixed-size page layout that you can serialize and deserialize efficiently. Here's what a practical on-disk node looks like:

```c
#define PAGE_SIZE 4096
#define MAX_KEYS 256

typedef struct {
    int is_leaf;
    int num_keys;
    int keys[MAX_KEYS];
    union {
        // For leaf nodes: the actual data values
        int values[MAX_KEYS];
        // For internal nodes: child page numbers
        int children[MAX_KEYS + 1];
    };
    int next_leaf; // -1 if not a leaf or last leaf
    int lsn;       // Log sequence number for recovery
} btree_page;

typedef struct {
    int page_id;
    int is_dirty;
    int pin_count;
    btree_page page_data;
} page_handle;
```

The critical insight here is that `PAGE_SIZE` should match your operating system's block size. For most systems, 4096 bytes is the sweet spot. If your node is smaller than a page, you're wasting I/O bandwidth. If it's larger, you need to read multiple pages to access a single node, which complicates your buffer pool logic.

The `next_leaf` field is particularly important for range queries. When you need to scan through many adjacent keys, you don't want to traverse back up the tree for each sequential access. A linked list at the leaf level turns range scans into sequential I/O, which is dramatically faster than random access.

### Serialization and Deserialization

When you write a node to disk, you need to convert your in-memory structure into a byte stream. The naive approach—just memcpy the struct—works on simple systems but breaks when you deal with different endianness or want to support schema evolution.

A more robust approach uses explicit serialization:

```c
void serialize_page(page_handle *page, char *buffer) {
    btree_page *bp = &page->page_data;
    int offset = 0;

    // Write metadata
    memcpy(buffer + offset, &bp->is_leaf, sizeof(int));
    offset += sizeof(int);
    memcpy(buffer + offset, &bp->num_keys, sizeof(int));
    offset += sizeof(int);
    memcpy(buffer + offset, &bp->lsn, sizeof(int));
    offset += sizeof(int);

    // Write keys
    for (int i = 0; i < bp->num_keys; i++) {
        memcpy(buffer + offset, &bp->keys[i], sizeof(int));
        offset += sizeof(int);
    }

    // Write children or values
    if (bp->is_leaf) {
        for (int i = 0; i < bp->num_keys; i++) {
            memcpy(buffer + offset, &bp->values[i], sizeof(int));
            offset += sizeof(int);
        }
        memcpy(buffer + offset, &bp->next_leaf, sizeof(int));
        offset += sizeof(int);
    } else {
        for (int i = 0; i <= bp->num_keys; i++) {
            memcpy(buffer + offset, &bp->children[i], sizeof(int));
            offset += sizeof(int);
        }
    }
}
```

Why go through this effort instead of a simple struct dump? Because when you implement recovery (which we'll get to), you need precise control over what gets written and when. The serialization function becomes the single point of truth for your on-disk format, and you can add checksums, version numbers, and other metadata without changing every piece of code that reads pages.

## The Storage Layer: Buffer Pool Management

Your B-Tree nodes live on disk, but reading from disk on every access would be catastrophically slow. The solution is a buffer pool—a cache of recently used pages that stays in memory. The buffer pool is arguably the most important component of your storage engine because it directly determines your I/O pattern.

### Page Replacement Strategy

You need a strategy for deciding which pages to evict when the buffer pool is full. The classic approach is clock replacement (also called second-chance), which approximates LRU without the overhead of maintaining a linked list:

```c
typedef struct {
    page_handle *pages;
    int num_pages;
    int hand; // Clock hand position
    char *ref_bits; // Reference bit per page
} buffer_pool;

page_handle *evict_page(buffer_pool *pool) {
    while (1) {
        page_handle *candidate = &pool->pages[pool->hand];

        // Skip pinned pages
        if (candidate->pin_count > 0) {
            pool->hand = (pool->hand + 1) % pool->num_pages;
            continue;
        }

        if (pool->ref_bits[pool->hand] == 0) {
            // This page hasn't been referenced recently
            // Write it out if dirty
            if (candidate->is_dirty) {
                write_page_to_disk(candidate->page_id,
                                   &candidate->page_data);
                candidate->is_dirty = 0;
            }
            pool->hand = (pool->hand + 1) % pool->num_pages;
            return candidate;
        } else {
            // Give it a second chance
            pool->ref_bits[pool->hand] = 0;
            pool->hand = (pool->hand + 1) % pool->num_pages;
        }
    }
}
```

Every time a page is accessed, you set its reference bit to 1. The clock hand sweeps through the buffer pool, clearing reference bits as it goes. When it finds a page with its reference bit already cleared, that page hasn't been accessed recently and is a good candidate for eviction.

### Pinning and Unpinning

The buffer pool needs to handle the fact that you can't evict a page while it's being used. Every operation that reads or modifies a page must pin it first:

```c
page_handle *fetch_page(buffer_pool *pool, int page_id) {
    // Check if page is already in buffer pool
    for (int i = 0; i < pool->num_pages; i++) {
        if (pool->pages[i].page_id == page_id) {
            pool->pages[i].pin_count++;
            pool->ref_bits[i] = 1;
            return &pool->pages[i];
        }
    }

    // Need to read from disk
    page_handle *slot = find_free_slot(pool);
    if (slot == NULL) {
        slot = evict_page(pool);
    }

    read_page_from_disk(page_id, &slot->page_data);
    slot->page_id = page_id;
    slot->pin_count = 1;
    slot->is_dirty = 0;
    pool->ref_bits[slot - pool->pages] = 1;

    return slot;
}

void unpin_page(page_handle *page) {
    page->pin_count--;
}
```

The pin count prevents the eviction algorithm from throwing away a page that's currently in use. Every `fetch_page` must be matched with an `unpin_page`. Getting this wrong leads to either deadlocks (if you never unpin) or corruption (if you evict a page someone is still modifying).

## Algorithms: Search, Insert, and Delete

With the storage layer established, we can implement the actual B-Tree operations. Each operation needs to fetch pages from the buffer pool, modify them, and mark them as dirty so they eventually get written to disk.

### Search

Searching a B-Tree is the simplest operation because it never modifies the tree:

```c
int search_b_tree(buffer_pool *pool, int root_page_id, int key) {
    page_handle *current = fetch_page(pool, root_page_id);

    while (1) {
        btree_page *node = &current->page_data;
        int i = 0;

        // Binary search within the node
        while (i < node->num_keys && key > node->keys[i]) {
            i++;
        }

        if (i < node->num_keys && key == node->keys[i]) {
            // Found the key
            int value = node->values[i];
            unpin_page(current);
            return value;
        }

        if (node->is_leaf) {
            // Key not found
            unpin_page(current);
            return -1; // Not found
        }

        // Navigate to the appropriate child
        page_handle *child = fetch_page(pool, node->children[i]);
        unpin_page(current);
        current = child;
    }
}
```

The binary search within each node is important. With MAX_KEYS = 256, a linear search would cost up to 256 comparisons per node. Binary search brings that down to 8 comparisons. When you multiply this across the height of the tree, the savings are substantial.

### Insertion with Splitting

Insertion is where things get interesting. When you insert into a full node, you need to split it into two nodes and push the median key up to the parent. This split can propagate all the way to the root, which is how the tree grows in height:

```c
void insert_key(buffer_pool *pool, page_handle *node_handle,
                int key, int value) {
    btree_page *node = &node_handle->page_data;
    page_handle *parent_handle = NULL;

    // First, find the leaf where the key should go
    while (!node->is_leaf) {
        int i = 0;
        while (i < node->num_keys && key > node->keys[i]) {
            i++;
        }

        parent_handle = node_handle;
        node_handle = fetch_page(pool, node->children[i]);
        node = &node_handle->page_data;
    }

    // Insert into the leaf
    if (node->num_keys < MAX_KEYS) {
        // Simple case: room in the leaf
        int i = node->num_keys - 1;
        while (i >= 0 && key < node->keys[i]) {
            node->keys[i + 1] = node->keys[i];
            node->values[i + 1] = node->values[i];
            i--;
        }
        node->keys[i + 1] = key;
        node->values[i + 1] = value;
        node->num_keys++;
        node_handle->is_dirty = 1;
        unpin_page(node_handle);
        if (parent_handle) unpin_page(parent_handle);
        return;
    }

    // Node is full, need to split
    // This requires allocating a new page and redistributing keys
    page_handle *new_node_handle = allocate_new_page(pool);
    btree_page *new_node = &new_node_handle->page_data;
    new_node->is_leaf = 1;
    new_node->next_leaf = node->next_leaf;
    node->next_leaf = new_node_handle->page_id;

    // Create temporary array with all keys plus the new one
    int temp_keys[MAX_KEYS + 1];
    int temp_values[MAX_KEYS + 1];
    int i = 0, j = 0;

    // Merge existing keys and new key
    while (i < node->num_keys && node->keys[i] < key) {
        temp_keys[j] = node->keys[i];
        temp_values[j] = node->values[i];
        i++; j++;
    }
    temp_keys[j] = key;
    temp_values[j] = value;
    j++;
    while (i < node->num_keys) {
        temp_keys[j] = node->keys[i];
        temp_values[j] = node->values[i];
        i++; j++;
    }

    int mid = j / 2;
    node->num_keys = mid;
    for (i = 0; i < mid; i++) {
        node->keys[i] = temp_keys[i];
        node->values[i] = temp_values[i];
    }

    new_node->num_keys = j - mid - 1;
    for (i = 0; i < new_node->num_keys; i++) {
        new_node->keys[i] = temp_keys[mid + 1 + i];
        new_node->values[i] = temp_values[mid + 1 + i];
    }

    node_handle->is_dirty = 1;
    new_node_handle->is_dirty = 1;

    // Propagate median key up
    int median_key = temp_keys[mid];
    unpin_page(new_node_handle);
    unpin_page(node_handle);

    // Insert median key into parent (handle root split if necessary)
    insert_into_parent(pool, parent_handle, median_key,
                       node_handle->page_id, new_node_handle->page_id);
}
```

The split operation is where many bugs hide. The most common mistake is off-by-one errors in the key redistribution. Remember that the median key goes up to the parent, not into either child. The left child gets keys less than the median, the right child gets keys greater than the median.

### Deletion with Rebalancing

Deletion is the most complex operation because you need to maintain the half-full invariant. When a node falls below minimum occupancy, you either merge it with a sibling or redistribute keys from a sibling:

```c
void delete_key(buffer_pool *pool, page_handle *node_handle, int key) {
    btree_page *node = &node_handle->page_data;

    // Find the leaf containing the key
    if (!node->is_leaf) {
        // Navigate to the correct child
        int i = 0;
        while (i < node->num_keys && key > node->keys[i]) {
            i++;
        }

        if (i < node->num_keys && key == node->keys[i]) {
            // Key is in an internal node - this is the tricky case
            // Replace with successor or predecessor
            page_handle *successor = find_leaf_successor(pool,
                node->children[i + 1], key);
            int successor_key = successor->page_data.keys[0];
            int successor_value = successor->page_data.values[0];

            node->keys[i] = successor_key;
            // Need to store value somewhere or handle differently
            node_handle->is_dirty = 1;
            unpin_page(successor);

            // Now delete the successor key from the child
            page_handle *child = fetch_page(pool, node->children[i + 1]);
            unpin_page(node_handle);
            delete_key(pool, child, successor_key);
            return;
        }

        page_handle *child = fetch_page(pool, node->children[i]);
        unpin_page(node_handle);
        delete_key(pool, child, key);
        return;
    }

    // Found the leaf, remove the key
    int i = 0;
    while (i < node->num_keys && node->keys[i] != key) {
        i++;
    }

    if (i >= node->num_keys) {
        // Key not found
        unpin_page(node_handle);
        return;
    }

    // Shift keys down
    for (int j = i; j < node->num_keys - 1; j++) {
        node->keys[j] = node->keys[j + 1];
        node->values[j] = node->values[j + 1];
    }
    node->num_keys--;
    node_handle->is_dirty = 1;

    // Check if rebalancing is needed
    if (node->num_keys < MIN_KEYS && node_handle->page_id != root_id) {
        rebalance_leaf(pool, node_handle);
    }

    unpin_page(node_handle);
}
```

The rebalancing logic is intricate. When a node is under-full, you first try to borrow a key from a sibling (this is called rotation). If borrowing isn't possible because both siblings are at minimum occupancy, you merge the node with a sibling and pull the separator key down from the parent. This merge can propagate upward, potentially reducing the height of the tree.

## Concurrency: Latch Coupling and Fine-Grained Locking

The B-Tree operations we've discussed so far assume single-threaded access. In the real world, you need multiple threads reading and writing the tree simultaneously. The naive approach—a single mutex for the entire tree—destroys concurrency. A single mutex on the root gives only slightly better behavior. You need a strategy that allows multiple threads to operate on different parts of the tree concurrently.

### The Distinction Between Latches and Locks

Before going further, let's clarify terminology that often causes confusion. A _latch_ is a lightweight synchronization primitive that protects in-memory data structures. Latches are held for very short durations (microseconds). A _lock_ is a heavier primitive that protects logical database objects. Locks are typically held for the duration of a transaction (milliseconds or longer).

For B-Tree operations, we use latches to protect individual pages during traversals. The key insight is that we don't need to lock the entire tree—we just need to ensure that no thread modifies a page while another thread is reading it.

### Latch Coupling (Crabbing)

The standard technique for concurrent B-Tree traversal is called latch coupling. As you traverse down the tree, you latch the current page, then latch the child page, then release the parent. This ensures that no one can modify a page you're about to read:

```c
page_handle *search_with_coupling(buffer_pool *pool, int root_id, int key) {
    page_handle *current = fetch_and_latch(pool, root_id, LATCH_SHARED);

    while (1) {
        btree_page *node = &current->page_data;

        if (node->is_leaf) {
            // We've reached the leaf, keep it latched
            return current;
        }

        int i = 0;
        while (i < node->num_keys && key > node->keys[i]) {
            i++;
        }

        page_handle *child = fetch_and_latch(pool, node->children[i],
                                             LATCH_SHARED);
        unlatch_and_unpin(current);
        current = child;
    }
}
```

For reads, shared latches are sufficient. For writes, you need exclusive latches. The tricky part is handling splits. During insertion, you might need to split a node. If you're using simple latch coupling, you'll discover that the leaf is full only after you've released the parent's latch, and you can't safely modify the parent without causing inconsistencies.

### The B-Link Tree: Right Link for Concurrent Splits

The standard solution to this problem is the B-Link tree, introduced by Lehman and Yao in 1981. The idea is simple: each node maintains a "right link" to its sibling. When a node splits, the old node becomes the left half, and the right half is created as a new node. The parent might not be updated immediately, but the search algorithm can detect this and follow the right link:

```c
page_handle *b_link_search(buffer_pool *pool, int root_id, int key) {
    page_handle *current = fetch_and_latch(pool, root_id, LATCH_SHARED);

    while (1) {
        btree_page *node = &current->page_data;

        if (node->is_leaf) {
            // Check if we need to follow right link
            while (key > node->keys[node->num_keys - 1] &&
                   node->next_leaf != -1) {
                page_handle *right = fetch_and_latch(pool, node->next_leaf,
                                                     LATCH_SHARED);
                unlatch_and_unpin(current);
                current = right;
                node = &current->page_data;
            }
            return current;
        }

        int i = 0;
        while (i < node->num_keys && key > node->keys[i]) {
            i++;
        }

        page_handle *child = fetch_and_latch(pool, node->children[i],
                                             LATCH_SHARED);

        // Check for split that happened after we read parent
        btree_page *child_node = &child->page_data;
        if (child_node->is_leaf) {
            while (key > child_node->keys[child_node->num_keys - 1] &&
                   child_node->next_leaf != -1) {
                page_handle *right = fetch_and_latch(pool,
                    child_node->next_leaf, LATCH_SHARED);
                unlatch_and_unpin(child);
                child = right;
                child_node = &child->page_data;
            }
        }

        unlatch_and_unpin(current);
        current = child;
    }
}
```

The B-Link tree allows splits without holding parent latches. A split creates a new node and links it to the right of the old node. The parent update happens lazily. A search that encounters an old node simply follows the right link to find the correct location.

### Transaction-Level Isolation

Latches handle physical consistency. But you also need logical consistency for transactions. This is where locks come in. For a B-Tree index, you typically use predicate locks or key-range locks to prevent phantom reads:

```c
typedef struct {
    int key;
    int transaction_id;
    lock_mode mode; // SHARED or EXCLUSIVE
} lock_entry;

int acquire_lock(transaction *txn, int key, lock_mode mode) {
    // Check for conflicting locks
    // If no conflict, grant the lock
    // Otherwise, wait or abort
    // ...
}
```

The interaction between latches and locks is subtle. The general rule is: acquire locks before latches, and release latches before locks. This prevents deadlocks between the locking subsystem and the latching subsystem.

### MVCC and B-Trees

Most modern databases use Multi-Version Concurrency Control (MVCC) rather than the classic two-phase locking approach. In MVCC, writers don't block readers. Instead, each transaction sees a snapshot of the database as of a specific point in time.

Implementing MVCC with a B-Tree requires storing additional information in each key-value pair:

```c
typedef struct {
    int key;
    int value;
    int begin_txn;  // Transaction that created this version
    int end_txn;    // Transaction that deleted this version (or INFINITY)
} versioned_entry;
```

When a writer inserts a new version of a key, it doesn't overwrite the old version. Instead, it marks the old version as ended and inserts a new version with a new begin timestamp. Readers check the timestamps to determine which version they should see.

This means that a B-Tree update doesn't actually modify existing entries—it appends new ones. The tree grows monotonically, which simplifies recovery but complicates garbage collection (you need a process to reclaim old versions that no transaction can see).

## Recovery: Surviving Crashes

Your B-Tree is humming along, processing reads and writes concurrently. Then, without warning, the power fails. When the system comes back up, your data needs to be consistent. You can accept losing the last few milliseconds of completed transactions, but you cannot accept corruption.

### Write-Ahead Logging (WAL)

The fundamental principle of crash recovery is Write-Ahead Logging: before you modify any page, you must write a log record describing the modification. The log record must be on stable storage before the modified page is written to disk.

```c
typedef struct {
    int lsn;              // Log sequence number (monotonic)
    int transaction_id;
    log_type type;        // UPDATE, INSERT, DELETE, COMMIT, etc.
    int page_id;          // Page being modified
    int slot;             // Slot within the page
    char old_data[128];   // Before image
    char new_data[128];   // After image
    int prev_lsn;         // Previous LSN for this transaction
} log_record;
```

Every page stores the LSN of the last log record that modified it. This is crucial for recovery. When you're replaying the log during recovery, you need to know whether a page already contains a particular change. If the page's LSN is greater than or equal to the log record's LSN, the change is already applied. If not, you need to apply it.

### The Log Manager

The log manager writes log records sequentially to a log file. Sequential writes are dramatically faster than random writes, which is why the log is typically on a separate device from the data files:

```c
int append_log(log_record *record) {
    record->lsn = atomic_increment(&current_lsn);

    write_log_to_buffer(record);

    // Force log to disk if this is a commit record
    if (record->type == COMMIT) {
        flush_log_buffer();
    }

    return record->lsn;
}
```

The tricky part is managing the log buffer. You can batch multiple log records in memory and write them in one I/O operation. But at commit time, you must force the buffer to disk. This is the primary bottleneck in many database systems, which is why group commit (batching multiple commits) is a common optimization.

### The Dirty Page Table

During normal operation, the buffer pool keeps track of which pages have been modified but not yet written to disk. This is the dirty page table:

```c
typedef struct {
    int page_id;
    int recv_lsn;  // LSN of oldest log record that dirtied this page
} dirty_page_entry;
```

The `recv_lsn` is critical for recovery. When you start recovery, you need to know which pages might be dirty. The dirty page table gives you this information without having to check every page on disk.

### ARIES: The Standard Recovery Algorithm

ARIES (Algorithms for Recovery and Isolation Exploiting Semantics) is the most widely used recovery algorithm. It operates in three phases:

**Phase 1: Analysis**
Starting from the most recent checkpoint, scan the log forward. Rebuild the dirty page table and the set of active transactions:

```c
void analysis_pass(log_iterator *iter,
                   dirty_page_table *dpt,
                   transaction_table *txns) {
    log_record *record;

    while ((record = next_log(iter)) != NULL) {
        // Update transaction table
        transaction *txn = get_or_create(txns, record->transaction_id);

        if (record->type == BEGIN) {
            txn->state = ACTIVE;
            txn->last_lsn = record->lsn;
        } else if (record->type == COMMIT) {
            txn->state = COMMITTED;
            txn->last_lsn = record->lsn;
        } else if (record->type == ABORT) {
            txn->state = ABORTED;
            txn->last_lsn = record->lsn;
        } else {
            // Data record
            update_dirty_page_table(dpt, record->page_id, record->lsn);
            set_transaction_last_lsn(txn, record->lsn);
        }
    }
}
```

**Phase 2: Redo**
Scan the log forward from the minimum `recv_lsn` in the dirty page table. Reapply every change whose LSN is greater than the page's LSN:

```c
void redo_pass(log_iterator *iter, buffer_pool *pool,
               dirty_page_table *dpt) {
    log_record *record;

    while ((record = next_log(iter)) != NULL) {
        if (!page_exists(record->page_id)) {
            // Page might have been truncated or dropped
            continue;
        }

        page_handle *page = fetch_page(pool, record->page_id);

        if (page->page_data.lsn >= record->lsn) {
            // Change already applied
            unpin_page(page);
            continue;
        }

        // Apply the change
        apply_log_to_page(page, record);
        page->page_data.lsn = record->lsn;
        page->is_dirty = 1;
        unpin_page(page);
    }
}
```

**Phase 3: Undo**
After redo, the database is in the state it was at the moment of the crash. Uncommitted transactions might have written changes. The undo phase rolls back these changes:

```c
void undo_pass(transaction_table *txns, buffer_pool *pool) {
    // Collect all active (uncommitted) transactions
    // Sort them by last_lsn in descending order

    for each active transaction txn {
        log_record *record = fetch_log(txn->last_lsn);

        while (record != NULL) {
            if (is_data_record(record)) {
                // Write a compensation log record (CLR)
                log_record *clr = create_clr(record);
                append_log(clr);

                // Apply the undo to the page
                page_handle *page = fetch_page(pool, record->page_id);
                apply_undo_to_page(page, record);
                page->page_data.lsn = clr->lsn;
                page->is_dirty = 1;
                unpin_page(page);
            }

            record = fetch_log(record->prev_lsn);
        }

        // Write abort end record
        log_record *end = create_abort_end(txn->id);
        append_log(end);
    }
}
```

The compensation log record (CLR) is crucial. Normal undos can be redone if the system crashes during undo. But you don't want to undo an undo. CLRs tell the recovery algorithm that a particular undo was performed, allowing correct redo without re-undoing.

## Edge Cases and Implementation Pitfalls

After years of implementing and debugging B-Trees, I've learned that the devil is in the edge cases. Here are the ones that consistently cause problems:

### Duplicate Keys

What happens when you insert the same key twice? Some B-Tree implementations treat this as an error. Others allow duplicates by storing multiple values per key or by appending a unique suffix to each key. If you're implementing a secondary index, you almost certainly need to handle duplicates.

The simplest approach is to extend the key with a unique identifier:

```c
typedef struct {
    int key;
    int unique_id; // Monotonically increasing
} extended_key;
```

Both `key` and `unique_id` participate in comparison. This guarantees unique entries while still allowing range scans over the actual key.

### Variable-Length Keys

Our implementation assumed fixed-size integer keys. Real databases need variable-length keys (strings, for example). You have several options:

1. **Fixed-size key storage**: Truncate keys to a maximum length. Simple but can cause incorrect behavior for long keys.

2. **Key prefix compression**: Store only the prefix needed to distinguish adjacent keys. This saves space but complicates splitting.

3. **Separate key storage**: Store keys in a separate area and keep pointers in the node. This allows variable-length keys but increases indirection.

The key prefix compression approach is particularly elegant. In a B-Tree, adjacent keys often share a common prefix. By storing only the distinguishing suffix, you can fit more keys in each node, reducing tree height:

```c
typedef struct {
    int prefix_len;  // Length of prefix shared with previous key
    char suffix[];   // Variable-length suffix
} compressed_key;
```

But compression complicates every operation. Comparison requires reconstructing the full key from the prefix chain. Splitting requires careful handling of prefix boundaries.

### Concurrent Split During Recovery

Recovery assumes that the log provides a consistent view of all changes. But what if a B-Tree split is only partially logged? This can happen if the system crashes in the middle of writing split records.

The solution is to make splits atomic from the log's perspective. Either all log records for the split are written, or none are. This typically means flushing the log after each complete split operation, even if that seems expensive.

## Real-World Applications

The B-Tree with full storage, concurrency, and recovery support forms the backbone of most database systems.

### PostgreSQL: GiST and SP-GiST

PostgreSQL uses B-Trees extensively, but its pluggable index system also includes Generalized Search Trees (GiST) and Space-Partitioned GiST (SP-GiST). These are B-Tree variants adapted for geographic data and other complex types. PostgreSQL's B-Tree implementation uses a buffer pool that supports both sequential and bitmap scans, with WAL-based recovery.

### MySQL InnoDB: The Clustered Index

MySQL's InnoDB storage engine uses a B+ Tree (a B-Tree variant where only the leaves store data) as its primary data structure. The table itself is a clustered index, meaning the leaf pages contain the actual row data. Secondary indexes then store pointers to primary keys, which are looked up in the clustered index.

InnoDB's concurrency model uses latch coupling with a sophisticated adaptive hash index that accelerates point lookups. Its recovery system is ARIES-based with group commit for log writes.

### MongoDB WiredTiger

MongoDB's default storage engine, WiredTiger, uses a B-Tree with compressed pages and snapshots for concurrency control. WiredTiger was originally developed for Berkeley DB and has a particularly elegant concurrency model based on multi-version concurrency control and snapshot isolation.

### LevelDB and RocksDB: LSM-Trees

It's worth mentioning that not everyone uses B-Trees. LevelDB and RocksDB use Log-Structured Merge (LSM) Trees, which write data sequentially to immutable files and merge them in the background. LSM-Trees have different performance characteristics—they're better for write-heavy workloads but worse for point lookups.

The choice between B-Trees and LSM-Trees depends on your workload. B-Trees offer consistent read performance and efficient range scans. LSM-Trees offer superior write performance and compression.

## Implementation Roadmap

If you're implementing a B-Tree from scratch, here's the order I recommend:

1. **Fix the page layout and serialization**. Get this right first. Every other piece depends on it.

2. **Implement the buffer pool with clock replacement**. Test it thoroughly with simple read/write workloads.

3. **Build the search operation**. This is the foundation for everything else.

4. **Implement insertion with splitting**. Start without concurrency. Get the split logic absolutely correct.

5. **Add deletion with rebalancing**. This is the hardest part. Expect bugs.

6. **Integrate simple exclusive latching**. Use a global latch first, then move to latch coupling.

7. **Implement the B-Link tree variant for concurrent splits**.

8. **Build the WAL logger and implement the three ARIES phases**.

9. **Add MVCC support for transactional isolation**.

10. **Optimize with compression, bulk loading, and page-level statistics**.

## Conclusion

Implementing a B-Tree from scratch is one of the most informative projects you can undertake as a systems engineer. It forces you to confront the real constraints of physical hardware—the high cost of disk I/O, the subtleties of concurrent access, and the unforgiving nature of crash recovery.

The B-Tree has survived for over 50 years because it embodies a fundamental insight: in computer systems, the cost of data movement dominates the cost of computation. The B-Tree minimizes data movement by keeping nodes large enough to amortize the cost of reading from disk but small enough to keep the tree shallow. Every aspect of its design—the branching factor, the split logic, the right links for concurrency—flows from this single principle.

The next time you query a database and get results in milliseconds, remember the layers of engineering that made it possible: the buffer pool manager evicting pages with clock-sweep precision, the latch coupling code ensuring no thread reads a partially modified node, the ARIES recovery algorithm waiting patiently for a crash that might never come. And remember that at the center of it all is a data structure that was designed for a world of spinning disks and kilobyte-sized memory, but has proven adaptable enough to serve as the foundation for databases that handle petabytes of data with sub-millisecond latency.

# Beyond the Textbook: Building a Production-Grade B-Tree from Scratch

Every computer science student learns about B-Trees. Most can recite the fan-out formula, the split-and-merge rules, and the `O(log n)` search complexity. But there's a vast chasm between understanding B-Trees on paper and implementing one that survives concurrent access, disk crashes, and production workloads without corrupting data.

This post isn't about the basics. It's about the dirty details that textbooks conveniently skip—the edge cases that crash databases, the performance traps that kill latency, and the recovery mechanisms that separate toy implementations from systems that have been processing transactions for decades without data loss.

## The Storage Layer: Where the Metal Meets the Math

Before we write a single line of code, we need to confront the fundamental tension in B-Tree storage: our logical tree structure must map onto a physical device that thinks in blocks, not nodes.

### Page Layout That Doesn't Waste Your Cache Line

The most common beginner mistake is designing a page layout that looks clean in code but performs poorly on actual hardware. Your page struct should be cache-line aligned and sized to match your storage medium's block size—typically 4096 bytes for modern SSDs and file systems.

```
[PageHeader 24 bytes]
[CellPointers  N * 2 bytes]
[FreeSpace     ...       ]
[CellContent   growing upward]
```

The critical insight here is the direction of growth. By having cell pointers grow downward from the header and cell content grow upward from the end, you enable efficient defragmentation without moving everything. When a key-value pair is deleted, you mark its pointer as invalid and compact only when free space becomes fragmented beyond a threshold.

This brings us to one of the most common production bugs: **fragmentation-induced write amplification**. Consider this scenario:

```
Page A: [CP1, CP2, CP3, CP4] ---- [KV1, KV2, KV3, KV4]
After deleting KV2, KV4:
Page A: [CP1, X, CP3, X] ---- [KV1, KV3]
```

Your free space is now fragmented. If you insert a key-value pair that's too large for either gap but fits in the total free space, you face a choice: compact immediately (costly I/O) or find space elsewhere (potentially causing page splits). The solution is to maintain a free space bitmap within each page and compact only when a new insertion would force a split.

## Concurrency: The Devil in the Split

Concurrency in B-Trees is where theory meets its Waterloo. The classic "latch crabbing" algorithm described in textbooks works beautifully—until you need it to work at scale.

### The SMO Problem

Structure Modification Operations (SMOs) — splits and merges — are the bane of concurrent B-Tree implementations. Here's why: when a leaf node splits, you need to:

1. Lock the leaf exclusively
2. Allocate a new page
3. Distribute entries between old and new leaf
4. Insert the separator key into the parent
5. Release the leaf lock

But step 4 might cause the parent to split, which might cause _its_ parent to split. This cascading write lock propagation is a nightmare for concurrency.

The standard solution is **lock coupling** with a twist: when a leaf detects it needs to split during a write, it first checks whether its parent has room. If the parent is full, you need to pre-split the parent—a process called "safe restructuring."

```
Insert(key) {
    // Phase 1: Search and check safety
    path = []  // Stack of nodes visited
    node = root
    while not leaf(node) {
        push(node, path)
        if node.full() and parent_full(node)
            split(node)  // Preemptive split
        node = child(node, key)
    }

    // Phase 2: Insert into leaf
    lock_exclusive(leaf)
    if leaf.full()
        split_and_insert(leaf, key)
    else
        plain_insert(leaf, key)
    unlock(leaf)
}
```

The asymmetry is intentional: we release leaf locks before modifying parents, which means search operations pass through without waiting. The parent write lock is only held during the actual link update, which is a pointer copy—usually under a microsecond.

### The Phantom Problem in Range Queries

Range queries introduce a subtle concurrency bug that most implementations miss. Consider this scenario:

```
Thread A: SELECT * FROM BTree WHERE key > 50 AND key < 70
Thread B: INSERT key 55 (which goes to a new page created by a split)
```

Thread A traverses the original leaf, finds nothing between 50 and 70, and returns an empty result. But Thread B inserted key 55 into a new page that Thread A never visited. This is the classic "phantom read," and it violates isolation guarantees.

The fix is **next-key locking**: when scanning, you must lock the gap between keys, not just the keys themselves. In B-Tree terms, this means holding a latch on the leaf page for the entire scan and ensuring that page splits are serialized with respect to scans.

## Recovery: What Happens When Power Dies Mid-Update

Recovery is where most B-Tree implementations fail spectacularly. The problem is deceptively simple: if the system crashes between writing a split page and updating the parent pointer, you've corrupted your tree structure.

### Write-Ahead Logging with a Twist

The textbook approach is Write-Ahead Logging (WAL): log every modification before writing it to the page. But naive WAL for B-Trees suffers from **log amplification**—a single page split might generate 20KB of log entries for a single 4KB page.

The key optimization is **physiological logging**. Instead of logging the raw bytes of the page, log the operation and its parameters:

```
[LSN: 3421] [PageID: 7] [Operation: SPLIT] [Key: 42] [NewPageID: 15]
[LSN: 3422] [PageID: 3] [Operation: SET_POINTER] [OldPointer: 7->7] [NewPointer: 7->15, 42, 7]
```

This is 100 bytes instead of 8KB. During recovery, we replay operations rather than just applying raw page images. This means we can tolerate partial writes—if page 3 got flushed but page 7 didn't, we can still reconstruct the correct state.

### The ARIES Protocol

The ARIES (Algorithms for Recovery and Isolation Exploiting Semantics) protocol adds three critical pieces:

1. **Dirty Page Table**: During recovery, we only need to replay operations for pages that might have been dirty at crash time. Pages that were clean (all modifications flushed) are skipped.

2. **Log Sequence Numbers on every page**: Each page stores the LSN of the last log record that modified it. This allows us to skip redundant operations during recovery—if the page LSN is >= the log record LSN, we've already applied that change.

3. **Compensation Log Records (CLRs)**: If we crash _during_ recovery, we need to be able to undo our undos. CLRs record that we've undone a particular log record, making recovery idempotent.

### The Split/Combine Recovery Dilemma

Here's a nightmare scenario that has caused countless production outages:

A B-Tree leaf page splits. The new page is allocated and written. The parent is updated. Then the system crashes before the old page's "redirect" pointer is cleaned up.

_Before crash_: Leaf A points to {1, 5, 10, 15, 20}. After split, Leaf A has {1, 5}, Leaf B has {10, 15, 20}. Parent has [5->A, 10->B].

_After crash_: Parent's pointer to B is stale if B wasn't flushed. But the WAL entry says the split completed.

The solution is to use a **two-phase commit style protocol** for splits:

```
Phase 1: Write new page (Leaf B) with a "split pending" flag
Phase 2: Update parent with both old and new pointers (A still points to its keys, B has the overflow)
Phase 3: Clear the "split pending" flag on Leaf B
Phase 4: If the split was required because A overflowed, now clean A
```

During recovery, any page with a "split pending" flag indicates a split that might have partially completed. The recovery process can either complete or undo the split based on whether the parent was updated.

## Performance: Where Theory Meets Benchmarks

### The Fan-Out Fallacy

Textbooks recommend a fan-out of 200-500 for typical B-Trees. This assumes uniform key distribution. In practice, if you're indexing timestamps or auto-increment IDs, the right half of your tree will be constantly splitting because all new inserts go to the rightmost leaf.

The fix is **reverse B-Trees** for monotonically increasing keys: store the root at the rightmost position and grow leftward. Or, more practically, use a **buffered tree** that accumulates writes in memory and flushes them in batches to avoid the "hot spot" problem.

### Cache-Conscious Node Design

If your B-Tree nodes are larger than a cache line (usually 64 bytes), you're paying a penalty for every random access. But nodes smaller than a page size means more tree height and more random I/O.

The modern compromise is **fractal trees** or **LSM trees**, but if you're implementing a B-Tree, you can optimize by separating the "routing" and "storage" portions of each node. The routing part (separator keys and pointers) fits in L2 cache; the storage part (full key-value pairs) sits in main memory or on disk.

### Write Amplification Measurement

Here's a metric most engineers don't measure: **write amplification factor** = (bytes written to storage) / (bytes of user data inserted). For a naive B-Tree with 4KB pages and binary splits, every insert causes:

- 4KB write to the leaf (amortized)
- 4KB write to the WAL
- Potentially 4KB writes to parent nodes if splits cascade

That's 12KB of storage writes for a 100-byte insert—a 120x write amplification. With SSD wear and throughput in mind, you want this below 5-10x.

Techniques to reduce it:

- **Large nodes** (32KB pages) reduce split frequency but increase random read cost
- **Bulk loading** instead of incremental inserts for initial data
- **Compression** at the page level (dictionary compression for keys with common prefixes)

## Common Pitfalls That Will Haunt Your Production System

### 1. The "Almost Full" Split Decision

Splitting when a page is 100% full is correct but suboptimal. If you split at 100%, the two resulting pages are at ~50% utilization immediately. A single insertion might cause another split.

**Best practice**: Split at 80-90% utilization. The extra space absorbs bursts of inserts without immediate cascading splits. For delete-heavy workloads, merge at 30-40% utilization instead of 50% to avoid thrashing.

### 2. Pointer Arithmetic on Memory-Mapped Pages

Memory-mapped I/O is tempting for simplicity, but it introduces a subtle bug: if a garbage collector or compaction moves memory, your pointers become invalid. Use page-level offsets (relative to the page start) rather than absolute pointers.

### 3. The Not-So-Atomic Page Write

Single page writes are not atomic at the hardware level. If you write a page header followed by cell data, a crash between the two writes leaves you with a page that has a valid header but corrupted content.

**Solution**: Include a checksum in the page header that covers the entire page. Before reading a page from disk, verify the checksum. This also catches storage bit rot.

### 4. Concurrency Without Causal Consistency

Most B-Tree implementations use fine-grained locking that provides serializability for individual operations but fails to provide causal consistency for transactions. Consider:

```
Transaction T1: INSERT key 10, then INSERT key 20
Transaction T2: READ key range [10, 20]
```

If T2's scan interleaves with T1's inserts, T2 might see key 20 but not key 10—a causal consistency violation. The fix is to ensure that sibling links in leaf nodes are updated atomically with the parent pointers during splits.

## Conclusion: The Art of Pragmatic Engineering

Implementing a B-Tree from scratch isn't just an academic exercise—it's a master class in the engineering trade-offs that underpin every major database system. The choices you make about storage layout, concurrency control, and recovery mechanisms will ripple through every operation your data structure performs.

The best B-Tree implementation isn't the one with the most elegant code; it's the one that degrades gracefully under edge cases, recovers correctly from crashes, and maintains predictable performance across workloads. It respects the physical realities of storage hardware, acknowledges the non-determinism of concurrent execution, and treats the possibility of failure as a design constraint rather than an afterthought.

When you're debugging a corruption bug at 3 AM, running a production database at 10,000 queries per second, or scaling a storage engine to petabytes of data, you'll appreciate that the devil isn't in the details—the devil _is_ the details, and mastering them is what separates a demo from a database.

## Conclusion: The B‑Tree as a Microcosm of Systems Thinking

If you have followed along through the storage design, concurrency control, and recovery mechanisms, you have now seen one of the most enduring data structures not as a black‑box abstraction but as a living system of interacting layers. Implementing a B‑tree from scratch is equal parts humbling and rewarding. Humbling because every assumption you make—about page sizes, latch ordering, log semantics—will be tested by concurrent threads, unexpected crashes, and real‑world workloads. Rewarding because once you have wrestled with these details, you gain an intuition for databases, file systems, and key‑value stores that no amount of library usage can provide.

In this conclusion, I want to distill the key lessons we have uncovered, offer concrete takeaways that you can apply to your own implementations, point you toward resources that will deepen your understanding, and leave you with a perspective on why this journey matters beyond the code itself.

### Summary of the Core Ideas

**Storage: The B‑tree lives in a hostile world of disks and caches.** We began by designing a page‑oriented storage manager that treats the disk as an array of fixed‑size blocks. The central challenge was to map the logical tree structure (nodes with keys and pointers) into a compact, mutable serialization format. We made deliberate trade‑offs: variable‑length keys vs. fixed‑length interiors, page headers with metadata like sibling pointers for efficient scans, and careful handling of split/merge operations that must remain atomic at the page level. This layer alone teaches you why database systems obsess over disk I/O patterns—every split or balance operation can cascade into multiple page writes, and the layout of those writes dictates performance.

**Concurrency: The tree must be safely shared.** We introduced latching—the lightweight synchronization that protects individual pages during traversal and modification. The classic technique of _latch coupling_ (also known as crabbing) allowed multiple threads to navigate the tree without holding locks on the entire structure, but forced us to reason about edge cases: when do we need a write latch? How do we handle splits that propagate upward while other threads may be passing through? We contrasted coarse‑grained locking (simple, but poor concurrency) with fine‑grained latch coupling (excellent concurrency, complex proof of correctness). The key insight was that the tree’s height grows, but the number of latches held at any moment rarely exceeds the height plus one—a beautiful property that makes B‑trees scalable.

**Recovery: The tree must survive crashes.** No crash‑proof implementation is complete without a logging and recovery subsystem. We sketched a write‑ahead logging (WAL) protocol that records every mutation before it reaches the page on disk. Using redo/undo records plus a simple checkpoint mechanism, we showed how to bring the tree back to a consistent state after a failure. The deeper lesson here is that atomicity and durability are _emergent properties_ of carefully ordered writes and log records, not just features of a database product. Understanding how to implement a mini‑ARIES inspired logger demystifies terms like “log sequence number” and “the log is the truth.”

### Actionable Takeaways for Practitioners

Whether you are building a B‑tree for a course project, a research prototype, or a production‑grade storage engine, the following practices will save you from the most common pitfalls.

1. **Test with fault injection from day one.** It is tempting to delay crash recovery until the tree works perfectly in happy‑path scenarios. Resist that temptation. Write a tiny in‑memory logger early and use it to simulate crashes. Insert a random `SyscallKill()` at points where a page write is half‑done. You will uncover ordering bugs that would otherwise remain hidden for months.

2. **Separate the tree logic from the storage back end.** Define a `PageAccessor` interface that abstracts the buffer pool, disk writer, and log writer. This allows you to swap the storage backend (e.g., use an in‑memory array for unit tests, a memory‑mapped file for early integration, or a raw block device later) without rewriting the tree algorithm. It also simplifies logging: the tree calls a _log()_ method before every page write, and the logger is responsible for durability guarantees.

3. **Latch ordering is a contract.** Write down the rules for your latch protocol and enforce them with runtime assertions. For example: _“A write latch on a page must never be acquired while holding a read latch on a child page.”_ Use a latch checker that tracks latch ownership per thread and reports violations. This is overkill for a prototype, but if you are moving toward production, such assertions are worth their weight in gold.

4. **Plan for the split/merge corner cases.** When a node splits, the parent must be updated. That update might itself trigger a split, and so on until the root. You must decide whether to use a _recursive_ approach (which risks deep recursions and stack overflow) or an _iterative_ approach (which requires you to remember the ancestor path). Neither is wrong, but each interacts with concurrency differently. Many B‑tree implementations use a “safe‑split” technique: proactively split full pages as you descend, so that a subsequent insertion never has to split upward while holding a latch on a child.

5. **Recovery must be idempotent.** Reapplying the same log record during restart should not corrupt the tree. Design your redo operation to be re‑executable (e.g., check a page’s LSN before applying). Undo operations must also be idempotent, which often means using logical undo (undo the _effect_ of the operation) rather than physical undo (restore the exact bytes).

6. **Benchmark with realistic workloads.** A B‑tree that performs beautifully under sequential insertions may degrade horribly under random inserts due to page splits and poor fanout. Use tools like `fio`, `sysbench`, or a custom driver to generate key distributions (uniform, skewed, hotspot) and measure latency percentiles. Pay special attention to the 99th percentile and the “long tail” caused by page splits hitting the root.

### Further Reading and Next Steps

This post covered the essential skeleton, but the literature on B‑trees and their variants is vast and rewarding. Here are the next texts I recommend.

**Classic Papers**

- Douglas Comer, _The Ubiquitous B‑Tree_ (1979). An excellent survey that covers the original motivations and many variants.
- Rudolf Bayer and Edward McCreight, _Organization and Maintenance of Large Ordered Indexes_ (1972). The original paper that introduced B‑trees—still readable and insightful.
- Goetz Graefe, _Modern B‑Tree Techniques_ (2011). A comprehensive monograph that covers everything from cache‑conscious layouts to merge‑on‑write strategies. This is the single best resource for advanced practitioners.

**Concurrency and Recovery**

- Jim Gray and Andreas Reuter, _Transaction Processing: Concepts and Techniques_ (1993). The bible of transaction processing, with deep treatment of B‑tree concurrency and logging.
- C. Mohan et al., _ARIES: A Transaction Recovery Method Supporting Fine‑Granularity Locking and Partial Rollbacks_ (1992). The original ARIES paper. It is heavy, but reading it will forever change how you think about logs.
- _Database Systems: The Complete Book_ by Ullman, Widom, and Garcia‑Molina. Chapter on storage and indexing is a clear introduction.

**Implementations to Study**

- SQLite’s B‑tree implementation (`btree.c`) is remarkably readable and well‑commented. It handles concurrency differently (uses page locks and a single writer), but the page formatting and balancing logic are educational.
- LMDB’s copy‑on‑write B‑tree (MVCC) is a brilliant alternative to the latch‑heavy approach. Reading its source will show you how to avoid write‑ahead logging entirely by using copy‑on‑write tree updates.
- FoundationDB uses a B‑tree variant called _layered indexing_—the performance and correctness reasoning behind its design is documented in their engineering blogs.

**Next Implementation Steps**
If you want to extend your prototype, consider these natural progressions:

- **Add variable‑length keys and values.** The fixed‑key assumption is limiting. Implement a page format with slot arrays and indirection pointers.
- **Implement B+‑tree (data only in leaves).** The B‑tree we built stores data in all nodes; a B+‑tree stores data only in leaves, which improves range scan performance. The concurrency logic remains similar but splits and merges become simpler.
- **Add compression and prefix truncation.** Real databases compress common key prefixes to fit more keys per page. This is a major optimization for workloads with long keys.
- **Explore optimistic concurrency.** A different paradigm is to allow readers to use snapshots (like MVCC) and only lock writers. This avoids most latch contention, at the cost of additional space and garbage collection.
- **Build a simple query engine on top.** Use your B‑tree as the index for a toy SQL‑like interface that supports point lookups, range scans, and simple joins. This connects the data structure to actual user queries.

### Closing Thought: The B‑Tree as a Mirror

Why build a B‑tree from scratch when every programming language’s standard library offers `Map` or `Dictionary`? Because the B‑tree is a microcosm of systems engineering. It forces you to think about data as something that occupies physical space (pages), about time as a sequence of events that must be ordered (logs), and about correctness as a property that must hold despite a cascade of failures. The lessons you learn—trade‑offs between memory and I/O, the fragility of concurrent invariants, the unforgiving nature of crash recovery—apply to nearly every backend system, from the simplest key‑value store to the most sophisticated distributed database.

Building a B‑tree is a rite of passage. By completing this journey, you have come to understand that _performance is an illusion without correctness_, and _correctness is fragile without recovery_. The tree you wrote may never run in production, but the patterns of thought it inculcated—atomicity, isolation, durability in the face of concurrency—will serve you for the rest of your career. And the next time you see “B‑tree index” in an `EXPLAIN PLAN`, you will smile knowingly, because you have held the blueprint in your own hands.

Keep building. Keep writing logs. Keep splitting pages. And remember: the hardest problems are not the ones you know you don’t know, but the ones you think you already solved—until the data tells you otherwise.
