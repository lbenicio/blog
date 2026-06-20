---
title: "Memory Allocators: From malloc to Modern Arena Allocators"
description: "A deep dive into memory allocation strategies, from the classic malloc implementations to modern arena allocators, jemalloc, tcmalloc, and custom allocators that power high-performance systems."
date: "2023-09-14"
author: "Leonardo Benicio"
tags: ["memory", "allocators", "malloc", "performance", "systems", "arena", "jemalloc"]
categories: ["systems", "performance"]
draft: false
cover: "/static/images/blog/memory-allocators-malloc-to-arena.png"
coverAlt: "Abstract visualization of memory blocks being allocated and freed in various patterns, with arenas shown as organized regions and fragmentation depicted as scattered puzzle pieces"
---

Memory allocation is one of those fundamental operations that most programmers take for granted. You call `malloc()`, memory appears; you call `free()`, it goes away. But beneath this simple interface lies a fascinating world of algorithms, trade-offs, and optimizations that can make or break your application's performance. This post explores memory allocation from first principles to modern high-performance allocators.

## 1. Why Memory Allocation Matters

Consider a web server handling thousands of requests per second. Each request might allocate dozens of objects: strings, buffers, data structures. If each allocation takes 1 microsecond, and a request needs 50 allocations, that's 50 microseconds just in allocation overhead—potentially more than the actual request processing time.

Memory allocation affects:

- **Latency:** Allocation time directly impacts response times
- **Throughput:** Contention on allocator locks limits parallelism
- **Memory efficiency:** Fragmentation wastes precious RAM
- **Cache performance:** Allocation patterns affect data locality
- **Predictability:** Allocation time variance affects tail latencies

Understanding allocators helps you choose the right one, configure it properly, or even build custom allocators for specific workloads.

## 2. The Allocator's Challenge

An allocator must solve several competing problems:

### 2.1 The Fundamental Operations

```c
void* malloc(size_t size);    // Allocate 'size' bytes
void free(void* ptr);          // Release memory
void* realloc(void* ptr, size_t size);  // Resize allocation
void* calloc(size_t n, size_t size);    // Allocate and zero
```

These operations seem simple, but consider the constraints:

- **Size variety:** Allocations range from 1 byte to gigabytes
- **Lifetime uncertainty:** Objects live milliseconds to hours
- **No compaction:** Unlike managed languages, C/C++ can't move objects
- **Thread safety:** Multiple threads allocate concurrently
- **Performance:** Both allocation and deallocation must be fast

### 2.2 Fragmentation: The Central Problem

Fragmentation is the allocator's nemesis. Two types exist:

**External fragmentation:** Free memory exists but is scattered in pieces too small to satisfy requests.

```text
Memory: [USED][FREE:8][USED][FREE:16][USED][FREE:8][USED]
Request: 32 bytes
Result: FAILURE (despite 32 free bytes total)
```

**Internal fragmentation:** Allocated blocks contain unused space due to alignment or size class rounding.

```text
Request: 17 bytes
Allocated: 32 bytes (next size class)
Waste: 15 bytes internal fragmentation
```

Every allocator design involves trade-offs between these fragmentation types, speed, and memory overhead.

## 3. Classic Algorithms

### 3.1 First-Fit

Search the free list for the first block large enough:

```c
Block* first_fit(size_t size) {
    Block* current = free_list;
    while (current) {
        if (current->size >= size) {
            return current;  // Found!
        }
        current = current->next;
    }
    return NULL;  // No fit
}
```

**Pros:** Simple, fast for small lists
**Cons:** Tends to fragment the beginning of memory; large allocations become slow

### 3.2 Best-Fit

Search for the smallest block that fits:

```c
Block* best_fit(size_t size) {
    Block* best = NULL;
    Block* current = free_list;
    while (current) {
        if (current->size >= size) {
            if (!best || current->size < best->size) {
                best = current;
            }
        }
        current = current->next;
    }
    return best;
}
```

**Pros:** Minimizes wasted space in each allocation
**Cons:** Slow (must scan entire list); creates many tiny unusable fragments

### 3.3 Worst-Fit

Allocate from the largest block:

```c
Block* worst_fit(size_t size) {
    Block* worst = NULL;
    Block* current = free_list;
    while (current) {
        if (current->size >= size) {
            if (!worst || current->size > worst->size) {
                worst = current;
            }
        }
        current = current->next;
    }
    return worst;
}
```

**Pros:** Leaves larger remaining fragments (potentially more useful)
**Cons:** Slow; fragments large blocks quickly

### 3.4 Next-Fit

Like first-fit, but start searching where the last search ended:

```c
static Block* search_start = NULL;

Block* next_fit(size_t size) {
    if (!search_start) search_start = free_list;
    Block* start = search_start;
    Block* current = start;

    do {
        if (current->size >= size) {
            search_start = current->next ? current->next : free_list;
            return current;
        }
        current = current->next ? current->next : free_list;
    } while (current != start);

    return NULL;
}
```

**Pros:** Spreads allocations across memory; better than first-fit for fragmentation
**Cons:** Still O(n) worst case

## 4. Free List Organizations

How you organize free blocks dramatically affects performance.

### 4.1 Implicit Free Lists

Store size in block headers; traverse all blocks (used and free):

```text
[Header:32|USED][Data...][Header:64|FREE][Data...][Header:16|USED]
```

```c
Block* next_block(Block* b) {
    return (Block*)((char*)b + sizeof(Header) + b->size);
}
```

**Pros:** Simple; no extra pointers
**Cons:** Must traverse used blocks to find free ones; slow

### 4.2 Explicit Free Lists

Link free blocks together:

```c
struct FreeBlock {
    size_t size;
    FreeBlock* next;
    FreeBlock* prev;
};
```

```text
Used blocks: [H|data][H|data][H|data]
Free list:   block1 <-> block2 <-> block3
```

**Pros:** Only traverse free blocks
**Cons:** Minimum block size (must fit pointers); extra pointer overhead

### 4.3 Segregated Free Lists

Multiple free lists, one per size class:

```text
Size class 16:   [16] -> [16] -> [16]
Size class 32:   [32] -> [32]
Size class 64:   [64] -> [64] -> [64] -> [64]
Size class 128:  [128]
```

```c
#define NUM_CLASSES 32
FreeBlock* free_lists[NUM_CLASSES];

int size_class(size_t size) {
    // Map size to class index
    if (size <= 16) return 0;
    if (size <= 32) return 1;
    // ... etc
}

void* malloc(size_t size) {
    int cls = size_class(size);
    if (free_lists[cls]) {
        return pop_from_list(cls);
    }
    // Try larger classes or get more memory
}
```

**Pros:** O(1) allocation for common sizes; good cache locality
**Cons:** Internal fragmentation from size class rounding

### 4.4 Buddy Allocators

Split memory into power-of-two blocks; merge adjacent "buddies" on free:

```text
Initial: [1024]
Alloc 100: Split -> [512][512] -> [256][256][512]
           Return first 256 (wastes 156 bytes)
Free:     Merge buddies back: [256][256] -> [512] -> [1024]
```

```c
void* buddy_alloc(size_t size) {
    int order = ceil_log2(size);  // Round up to power of 2

    // Find smallest available block >= order
    for (int i = order; i <= MAX_ORDER; i++) {
        if (free_lists[i]) {
            Block* block = pop_free_list(i);
            // Split if larger than needed
            while (i > order) {
                i--;
                Block* buddy = split(block);
                push_free_list(buddy, i);
            }
            return block;
        }
    }
    return NULL;
}
```

**Pros:** Fast coalescing (buddy address computed via XOR); bounded fragmentation
**Cons:** High internal fragmentation (50% worst case); only power-of-two sizes

## 5. Coalescing Strategies

When freeing memory, should we merge adjacent free blocks?

### 5.1 Immediate Coalescing

Merge free blocks as soon as they're freed:

```c
void free(void* ptr) {
    Block* block = get_block(ptr);
    block->free = true;

    // Check and merge with next block
    Block* next = next_block(block);
    if (next && next->free) {
        block->size += sizeof(Header) + next->size;
        remove_from_free_list(next);
    }

    // Check and merge with previous block
    Block* prev = prev_block(block);
    if (prev && prev->free) {
        prev->size += sizeof(Header) + block->size;
        block = prev;  // Merged into prev
    } else {
        add_to_free_list(block);
    }
}
```

**Pros:** Reduces fragmentation immediately
**Cons:** Expensive if allocation patterns cause repeated split/merge cycles

### 5.2 Deferred Coalescing

Delay merging until needed (e.g., when allocation fails):

```c
void* malloc(size_t size) {
    void* ptr = try_allocate(size);
    if (!ptr) {
        coalesce_all_free_blocks();
        ptr = try_allocate(size);
    }
    return ptr;
}
```

**Pros:** Avoids unnecessary coalescing; better for alloc/free patterns with similar sizes
**Cons:** May delay finding suitable blocks; sudden coalescing spikes

### 5.3 Boundary Tags

To coalesce with the previous block, we need to find it. Boundary tags store size at both ends:

```text
[Size|...data...|Size]
```

```c
Block* prev_block(Block* b) {
    size_t prev_size = *((size_t*)b - 1);  // Size at end of prev block
    return (Block*)((char*)b - prev_size - 2*sizeof(size_t));
}
```

This enables O(1) backward traversal at the cost of extra space per block.

## 6. Modern Allocator Design

Modern allocators combine multiple techniques to handle diverse workloads.

### 6.1 Size Classes and Slabs

Most allocations are small. Modern allocators optimize for this:

```c
// Size classes (typical):
// 8, 16, 32, 48, 64, 80, 96, 112, 128, 192, 256, ...

struct SizeClass {
    size_t size;
    FreeList* free_list;
    Slab* partial_slabs;
    Slab* full_slabs;
};

struct Slab {
    void* memory;       // Contiguous region
    Bitmap free_slots;  // Which slots are free
    int num_free;
    SizeClass* class;
};
```

Slabs are contiguous regions divided into fixed-size slots:

```text
Slab for 64-byte objects:
[slot0][slot1][slot2][slot3][slot4][slot5]...
  ^free  ^used  ^used  ^free  ^free  ^used
```

**Allocation:** Pop from free list or allocate from slab
**Deallocation:** Push to free list or return to slab

### 6.2 Thread Caching

Allocator lock contention kills multi-threaded performance. Solution: per-thread caches.

```c
thread_local struct {
    FreeList* caches[NUM_SIZE_CLASSES];
    int cache_sizes[NUM_SIZE_CLASSES];
} thread_cache;

void* malloc(size_t size) {
    int cls = size_class(size);

    // Fast path: thread-local cache
    if (thread_cache.caches[cls]) {
        return pop_from_cache(cls);
    }

    // Slow path: refill from central allocator
    refill_cache(cls);
    return pop_from_cache(cls);
}
```

**Trade-off:** Thread caches hold memory that other threads might need. Periodic rebalancing is required.

### 6.3 Central and Page Heaps

A multi-tier architecture:

```text
┌─────────────────────────────────────────────┐
│         Thread Cache (per-thread)           │
│   Fast, lock-free, small allocations        │
├─────────────────────────────────────────────┤
│         Central Free List (shared)          │
│   Batched transfers, locked                 │
├─────────────────────────────────────────────┤
│         Page Heap (large allocations)       │
│   Full pages, span management               │
├─────────────────────────────────────────────┤
│         OS (mmap, sbrk)                     │
│   Physical memory acquisition               │
└─────────────────────────────────────────────┘
```

Small allocations stay in thread caches. Medium allocations use central free lists. Large allocations go directly to the page heap or OS.

## 7. jemalloc Deep Dive

jemalloc (Jason Evans malloc) is used by Firefox, Facebook, Redis, and many others. Let's examine its design.

### 7.1 Architecture Overview

```text
┌─────────────────────────────────────────────┐
│              Thread Cache                    │
│   Per-thread bins for small sizes           │
├─────────────────────────────────────────────┤
│              Arenas (multiple)              │
│   Thread-to-arena assignment                │
├─────────────────────────────────────────────┤
│              Bins (per arena)               │
│   Size-class-specific regions               │
├─────────────────────────────────────────────┤
│              Runs and Pages                 │
│   Contiguous page runs                      │
└─────────────────────────────────────────────┘
```

### 7.2 Size Classes

jemalloc uses carefully chosen size classes to minimize internal fragmentation:

```text
Small (< 14 KiB): 8, 16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, ...
Large (>= 14 KiB): Multiple of page size
```

The spacing between classes is designed to limit internal fragmentation to about 20%:

```c
// Size class spacing
// Tiny: 8-byte spacing (8, 16, 24, 32, ...)
// Quantum: 16-byte spacing for sizes 128-256
// Sub-page: Geometric spacing
```

### 7.3 Thread-to-Arena Assignment

Rather than one arena per thread (memory waste) or one global arena (contention), jemalloc assigns threads to arenas in a round-robin fashion:

```c
// Typically: num_arenas = 4 * num_cpus
Arena* get_arena() {
    thread_local Arena* cached_arena = NULL;
    if (!cached_arena) {
        cached_arena = arenas[next_arena_index++ % num_arenas];
    }
    return cached_arena;
}
```

This balances contention against memory efficiency.

### 7.4 Extent-Based Management

jemalloc 5.0 introduced extents—variable-sized virtual memory regions:

```c
struct Extent {
    void* addr;
    size_t size;
    Arena* arena;
    ExtentState state;  // active, dirty, muzzy, retained
};
```

**States:**

- **Active:** Currently in use
- **Dirty:** Recently freed, pages still in memory
- **Muzzy:** Advised to OS (MADV_FREE) but not returned
- **Retained:** Virtual address space held but pages released

This enables efficient memory return to the OS while maintaining address space.

### 7.5 Decay-Based Purging

Rather than immediately returning memory to the OS (expensive) or never returning it (wasteful), jemalloc uses time-based decay:

```c
// Dirty pages decay to muzzy after dirty_decay_ms
// Muzzy pages decay to clean after muzzy_decay_ms
// Default: 10 seconds dirty, 10 seconds muzzy
```

This smooths out memory usage patterns and reduces system call overhead.

## 8. tcmalloc Deep Dive

Google's tcmalloc (thread-caching malloc) is another major allocator, used in Chrome and many Google services.

### 8.1 Architecture

```text
┌─────────────────────────────────────────────┐
│        Front-end (per-thread cache)         │
│   Lock-free allocation for common sizes     │
├─────────────────────────────────────────────┤
│        Middle-end (transfer cache)          │
│   Batched transfers between front/back      │
├─────────────────────────────────────────────┤
│        Back-end (page heap)                 │
│   Page-level management, OS interaction     │
└─────────────────────────────────────────────┘
```

### 8.2 Size Classes

tcmalloc's size classes are tuned for Google's workloads:

```text
// Small: 8 to 256 KiB
8, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 256, ...

// Large: > 256 KiB, directly from page heap
```

### 8.3 Per-CPU Caches (tcmalloc v2)

Modern tcmalloc uses per-CPU caches instead of per-thread:

```c
struct PerCpuCache {
    void* objects[NUM_SIZE_CLASSES][MAX_CACHED];
    int sizes[NUM_SIZE_CLASSES];
};

// Access current CPU's cache
// Using restartable sequences (rseq) for atomicity
void* malloc(size_t size) {
    int cpu = current_cpu();
    int cls = size_class(size);

    if (per_cpu_cache[cpu].sizes[cls] > 0) {
        return pop_from_cpu_cache(cpu, cls);
    }
    // ... slow path
}
```

Per-CPU caches reduce memory overhead (threads >> CPUs) and improve cache locality.

### 8.4 Huge Pages

tcmalloc supports transparent huge pages for large allocations:

```c
void* allocate_large(size_t size) {
    // Round up to huge page boundary (2 MiB)
    size = round_up(size, HUGE_PAGE_SIZE);

    void* ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);

    if (ptr == MAP_FAILED) {
        // Fall back to regular pages
        ptr = mmap(NULL, size, ...);
    }
    return ptr;
}
```

Huge pages reduce TLB misses for large allocations.

## 9. Arena Allocators

For specific workloads, custom arena allocators can dramatically outperform general-purpose allocators.

### 9.1 Basic Linear Allocator

The simplest arena: bump pointer allocation, no individual frees:

```c
struct LinearArena {
    char* base;
    char* current;
    char* end;
};

void* arena_alloc(LinearArena* arena, size_t size) {
    size = align_up(size, 16);  // Alignment

    if (arena->current + size > arena->end) {
        return NULL;  // Out of memory
    }

    void* ptr = arena->current;
    arena->current += size;
    return ptr;
}

void arena_reset(LinearArena* arena) {
    arena->current = arena->base;  // "Free" everything at once
}
```

**Use case:** Per-request allocations in servers, per-frame allocations in games.

### 9.2 Stack Allocator

Like linear, but supports LIFO deallocation:

```c
struct StackArena {
    char* base;
    char* current;
    char* end;
};

struct StackMarker {
    char* position;
};

StackMarker arena_mark(StackArena* arena) {
    return (StackMarker){arena->current};
}

void arena_restore(StackArena* arena, StackMarker marker) {
    arena->current = marker.position;
}
```

**Use case:** Recursive algorithms, nested scopes.

### 9.3 Pool Allocator

Fixed-size blocks, O(1) alloc and free:

```c
struct PoolArena {
    size_t block_size;
    void* free_list;
    char* memory;
};

void pool_init(PoolArena* pool, size_t block_size, size_t count) {
    pool->block_size = align_up(block_size, 8);
    pool->memory = mmap(NULL, pool->block_size * count, ...);

    // Build free list
    pool->free_list = NULL;
    for (size_t i = 0; i < count; i++) {
        void* block = pool->memory + i * pool->block_size;
        *(void**)block = pool->free_list;
        pool->free_list = block;
    }
}

void* pool_alloc(PoolArena* pool) {
    if (!pool->free_list) return NULL;

    void* block = pool->free_list;
    pool->free_list = *(void**)block;
    return block;
}

void pool_free(PoolArena* pool, void* ptr) {
    *(void**)ptr = pool->free_list;
    pool->free_list = ptr;
}
```

**Use case:** Game entities, network packets, any fixed-size object.

### 9.4 Growing Arenas

Arenas that grow by allocating new blocks:

```c
struct GrowingArena {
    struct Block {
        char* data;
        size_t size;
        size_t used;
        Block* next;
    }* current_block;
    size_t min_block_size;
};

void* growing_arena_alloc(GrowingArena* arena, size_t size) {
    size = align_up(size, 16);

    // Check current block
    if (arena->current_block &&
        arena->current_block->used + size <= arena->current_block->size) {
        void* ptr = arena->current_block->data + arena->current_block->used;
        arena->current_block->used += size;
        return ptr;
    }

    // Allocate new block
    size_t block_size = max(arena->min_block_size, size);
    Block* new_block = malloc(sizeof(Block));
    new_block->data = mmap(NULL, block_size, ...);
    new_block->size = block_size;
    new_block->used = size;
    new_block->next = arena->current_block;
    arena->current_block = new_block;

    return new_block->data;
}

void growing_arena_free_all(GrowingArena* arena) {
    Block* block = arena->current_block;
    while (block) {
        Block* next = block->next;
        munmap(block->data, block->size);
        free(block);
        block = next;
    }
    arena->current_block = NULL;
}
```

## 10. Memory Allocation in Practice

### 10.1 Choosing an Allocator

| Workload              | Recommended Allocator              |
| --------------------- | ---------------------------------- |
| General purpose       | System malloc or jemalloc          |
| Multi-threaded server | tcmalloc or jemalloc               |
| Memory-constrained    | mimalloc or custom                 |
| Real-time             | Pool allocators, no general malloc |
| Single-threaded batch | Arena allocators                   |
| Game engine           | Custom arena + pool hierarchy      |

### 10.2 Profiling Allocation

Before optimizing, measure:

```bash
# On Linux with jemalloc
MALLOC_CONF=prof:true,prof_prefix:jeprof ./myapp
jeprof --pdf ./myapp jeprof.*.heap > heap.pdf

# With heaptrack
heaptrack ./myapp
heaptrack_gui heaptrack.myapp.*.gz
```

Look for:

- Allocation hotspots (which call sites allocate most?)
- Fragmentation (ratio of RSS to actual used memory)
- Temporary allocations (high alloc rate with short lifetimes)

### 10.3 Common Optimizations

**Object pooling:**

```c
// Instead of malloc/free per request
Request* req = malloc(sizeof(Request));
// ... use ...
free(req);

// Use a pool
Request* req = pool_get(&request_pool);
// ... use ...
pool_return(&request_pool, req);
```

**Arena allocation for request handling:**

```c
void handle_request(Request* req) {
    Arena arena = arena_create(64 * 1024);  // 64 KiB

    // All allocations from arena
    char* buffer = arena_alloc(&arena, buffer_size);
    ParsedData* data = arena_alloc(&arena, sizeof(ParsedData));
    // ... process ...

    arena_destroy(&arena);  // Free everything at once
}
```

**Slab allocators for kernel objects:**

```c
// Linux kernel style
struct kmem_cache *task_cache;

task_cache = kmem_cache_create("task_struct",
                               sizeof(struct task_struct),
                               0, SLAB_HWCACHE_ALIGN, NULL);

struct task_struct *task = kmem_cache_alloc(task_cache, GFP_KERNEL);
// ... use ...
kmem_cache_free(task_cache, task);
```

## 11. Memory Safety Considerations

Modern allocators incorporate safety features.

### 11.1 Guard Pages

Detect buffer overflows by placing inaccessible pages:

```c
void* safe_alloc(size_t size) {
    // Allocate extra pages
    size_t total = round_up(size, PAGE_SIZE) + PAGE_SIZE;
    char* base = mmap(NULL, total, PROT_READ | PROT_WRITE, ...);

    // Make last page inaccessible
    mprotect(base + total - PAGE_SIZE, PAGE_SIZE, PROT_NONE);

    // Return pointer near the guard page
    return base + (total - PAGE_SIZE - size);
}
```

Overflow triggers SIGSEGV immediately.

### 11.2 Red Zones

Fill boundaries with known patterns:

```c
#define REDZONE_SIZE 16
#define REDZONE_PATTERN 0xFE

void* debug_alloc(size_t size) {
    char* ptr = malloc(size + 2 * REDZONE_SIZE);
    memset(ptr, REDZONE_PATTERN, REDZONE_SIZE);
    memset(ptr + REDZONE_SIZE + size, REDZONE_PATTERN, REDZONE_SIZE);
    return ptr + REDZONE_SIZE;
}

void debug_free(void* ptr) {
    char* base = (char*)ptr - REDZONE_SIZE;
    // Check red zones
    for (int i = 0; i < REDZONE_SIZE; i++) {
        if (base[i] != REDZONE_PATTERN) {
            report_underflow(ptr);
        }
    }
    // Check after...
    free(base);
}
```

### 11.3 Use-After-Free Detection

Quarantine freed memory:

```c
struct QuarantineEntry {
    void* ptr;
    size_t size;
    time_t freed_at;
};

void quarantine_free(void* ptr, size_t size) {
    // Fill with pattern
    memset(ptr, 0xDD, size);

    // Add to quarantine
    quarantine_add(ptr, size);

    // Actually free old entries
    while (quarantine_size > MAX_QUARANTINE) {
        QuarantineEntry entry = quarantine_pop_oldest();
        actual_free(entry.ptr);
    }
}
```

### 11.4 ASLR Integration

Modern allocators randomize layout:

```c
void* mmap_random(size_t size) {
    // Add random offset
    uintptr_t random_offset = (random() & 0xFFFFFF) * PAGE_SIZE;
    void* hint = (void*)(BASE_ADDRESS + random_offset);
    return mmap(hint, size, ...);
}
```

This makes exploitation harder by unpredictable addresses.

## 12. Emerging Trends

### 12.1 mimalloc

Microsoft's mimalloc offers excellent performance with a simple design:

```text
Key features:
- Free lists per page (no size classes!)
- Immediate memory return to OS
- First-class huge page support
- Excellent fragmentation behavior
```

mimalloc achieves near-jemalloc performance with significantly simpler code.

### 12.2 Hardened Allocators

Security-focused allocators like OpenBSD's malloc and GrapheneOS's hardened_malloc:

```text
Features:
- Isolated metadata (can't be overwritten via buffer overflow)
- Strong randomization
- Immediate use-after-free detection
- Guard pages on all allocations
```

Trade performance for security.

### 12.3 Memory Tagging

ARM's Memory Tagging Extension (MTE) enables hardware-assisted safety:

```c
// Each pointer has a 4-bit tag in high bits
// Memory has corresponding tag
// Hardware checks tags on access

void* tagged_alloc(size_t size) {
    void* ptr = malloc(size);
    int tag = random() & 0xF;
    set_memory_tag(ptr, size, tag);
    return add_pointer_tag(ptr, tag);
}

void tagged_free(void* ptr) {
    int new_tag = (get_pointer_tag(ptr) + 1) & 0xF;
    set_memory_tag(ptr, size, new_tag);  // Invalidate old tag
    free(remove_pointer_tag(ptr));
}
```

Use-after-free and buffer overflow are detected by hardware.

### 12.4 Persistent Memory Allocators

NVM (Non-Volatile Memory) requires special allocators:

```c
// PMDK library
PMEMobjpool *pop = pmemobj_open(path, "mypool");

TX_BEGIN(pop) {
    PMEMoid oid = pmemobj_tx_alloc(sizeof(MyStruct), TYPE_NUM);
    // Allocation is transactional
} TX_END

// Memory persists across restarts
```

Challenges:

- Ensuring consistency on crash
- Managing persistent pointers
- Handling capacity vs. performance trade-offs

## 13. Implementing a Simple Allocator

Let's build a working allocator to solidify concepts.

### 13.1 Design Goals

- Support small allocations (< 4 KiB) efficiently
- Thread-safe with per-thread caching
- Reasonable fragmentation
- Simple enough to understand

### 13.2 Size Classes

```c
#define NUM_SIZE_CLASSES 8
static const size_t size_classes[NUM_SIZE_CLASSES] = {
    16, 32, 64, 128, 256, 512, 1024, 2048
};

int get_size_class(size_t size) {
    for (int i = 0; i < NUM_SIZE_CLASSES; i++) {
        if (size <= size_classes[i]) return i;
    }
    return -1;  // Too large, use mmap directly
}
```

### 13.3 Slab Structure

```c
#define SLAB_SIZE (64 * 1024)  // 64 KiB slabs

struct Slab {
    struct Slab* next;
    size_t object_size;
    int num_objects;
    int num_free;
    void* free_list;
    char data[];
};

Slab* slab_create(size_t object_size) {
    Slab* slab = mmap(NULL, SLAB_SIZE, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

    slab->object_size = object_size;
    slab->num_objects = (SLAB_SIZE - sizeof(Slab)) / object_size;
    slab->num_free = slab->num_objects;
    slab->free_list = NULL;
    slab->next = NULL;

    // Build free list
    for (int i = slab->num_objects - 1; i >= 0; i--) {
        void* obj = slab->data + i * object_size;
        *(void**)obj = slab->free_list;
        slab->free_list = obj;
    }

    return slab;
}
```

### 13.4 Thread Cache

```c
#define CACHE_SIZE 32

struct ThreadCache {
    void* cached[NUM_SIZE_CLASSES][CACHE_SIZE];
    int count[NUM_SIZE_CLASSES];
};

thread_local ThreadCache thread_cache = {0};

void* cache_alloc(int cls) {
    if (thread_cache.count[cls] > 0) {
        return thread_cache.cached[cls][--thread_cache.count[cls]];
    }
    return NULL;
}

void cache_free(int cls, void* ptr) {
    if (thread_cache.count[cls] < CACHE_SIZE) {
        thread_cache.cached[cls][thread_cache.count[cls]++] = ptr;
    } else {
        central_free(cls, ptr);
    }
}
```

### 13.5 Central Allocator

```c
struct CentralAllocator {
    pthread_mutex_t lock;
    Slab* partial_slabs[NUM_SIZE_CLASSES];
    Slab* full_slabs[NUM_SIZE_CLASSES];
};

CentralAllocator central = {PTHREAD_MUTEX_INITIALIZER};

void* central_alloc(int cls) {
    pthread_mutex_lock(&central.lock);

    Slab* slab = central.partial_slabs[cls];
    if (!slab) {
        slab = slab_create(size_classes[cls]);
        central.partial_slabs[cls] = slab;
    }

    void* obj = slab->free_list;
    slab->free_list = *(void**)obj;
    slab->num_free--;

    if (slab->num_free == 0) {
        // Move to full list
        central.partial_slabs[cls] = slab->next;
        slab->next = central.full_slabs[cls];
        central.full_slabs[cls] = slab;
    }

    pthread_mutex_unlock(&central.lock);
    return obj;
}
```

### 13.6 Public Interface

```c
void* my_malloc(size_t size) {
    int cls = get_size_class(size);

    if (cls < 0) {
        // Large allocation: mmap directly
        return mmap(NULL, size, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    }

    void* ptr = cache_alloc(cls);
    if (!ptr) {
        ptr = central_alloc(cls);
    }
    return ptr;
}

void my_free(void* ptr) {
    if (!ptr) return;

    // Find containing slab (in real implementation, use radix tree or similar)
    Slab* slab = find_slab(ptr);
    if (!slab) {
        // Large allocation
        munmap(ptr, /* need to track size */);
        return;
    }

    int cls = get_size_class(slab->object_size);
    cache_free(cls, ptr);
}
```

## 14. Debugging Allocation Issues

### 14.1 Memory Leaks

```bash
# Valgrind
valgrind --leak-check=full ./myapp

# AddressSanitizer
clang -fsanitize=address ./myapp.c -o myapp
./myapp
```

### 14.2 Heap Corruption

```bash
# Electric Fence - crashes on overflow
LD_PRELOAD=/usr/lib/libefence.so ./myapp

# ASan with more checks
ASAN_OPTIONS=detect_stack_use_after_return=1:check_initialization_order=1 ./myapp
```

### 14.3 Fragmentation Analysis

```c
// jemalloc statistics
#include <jemalloc/jemalloc.h>

void print_stats() {
    malloc_stats_print(NULL, NULL, "gm");
}
```

Look for:

- `mapped` vs `active` (fragmentation)
- `allocated` vs `resident` (overhead)
- Per-size-class statistics

### 14.4 Custom Allocator Debugging

Add instrumentation to your allocator:

```c
struct AllocStats {
    atomic_uint64_t total_allocs;
    atomic_uint64_t total_frees;
    atomic_uint64_t allocs_per_class[NUM_SIZE_CLASSES];
    atomic_uint64_t cache_hits;
    atomic_uint64_t cache_misses;
};

AllocStats stats = {0};

void* my_malloc_instrumented(size_t size) {
    atomic_fetch_add(&stats.total_allocs, 1);

    int cls = get_size_class(size);
    if (cls >= 0) {
        atomic_fetch_add(&stats.allocs_per_class[cls], 1);
    }

    void* ptr = cache_alloc(cls);
    if (ptr) {
        atomic_fetch_add(&stats.cache_hits, 1);
    } else {
        atomic_fetch_add(&stats.cache_misses, 1);
        ptr = central_alloc(cls);
    }
    return ptr;
}
```

## 15. Real-World Performance Comparisons

### 15.1 Benchmark Results

Typical results from allocation benchmarks (allocations per second, higher is better):

| Allocator    | Single-thread | 8 threads | 64 threads |
| ------------ | ------------- | --------- | ---------- |
| glibc malloc | 8M            | 15M       | 20M        |
| jemalloc     | 12M           | 80M       | 150M       |
| tcmalloc     | 15M           | 90M       | 180M       |
| mimalloc     | 14M           | 85M       | 170M       |

### 15.2 Memory Efficiency

Memory overhead varies significantly:

| Allocator | Overhead (small objects) | Fragmentation |
| --------- | ------------------------ | ------------- |
| glibc     | 8-16 bytes               | High          |
| jemalloc  | 0-8 bytes                | Low           |
| tcmalloc  | 0-16 bytes               | Medium        |
| mimalloc  | 0-8 bytes                | Very Low      |

### 15.3 Latency Distribution

For latency-sensitive applications, tail latency matters:

| Allocator | p50  | p99   | p99.9 |
| --------- | ---- | ----- | ----- |
| glibc     | 50ns | 2µs   | 50µs  |
| jemalloc  | 40ns | 200ns | 5µs   |
| tcmalloc  | 35ns | 150ns | 3µs   |
| Arena     | 5ns  | 10ns  | 20ns  |

Arena allocators excel at tail latency by avoiding complex free operations.

## 16. Summary

Memory allocation is a rich field balancing multiple constraints:

- **Speed:** Thread caching, size classes, and fast paths enable O(1) common-case allocation
- **Space:** Careful size class selection and coalescing minimize fragmentation
- **Safety:** Guard pages, red zones, and quarantine catch bugs early
- **Scalability:** Per-CPU caches and arena sharding reduce contention

Key takeaways:

1. **Understand your workload:** General-purpose allocators are good defaults, but specific patterns (arena-friendly, fixed-size objects) enable dramatic optimizations
2. **Measure before optimizing:** Use profiling tools to find allocation hotspots
3. **Consider custom allocators:** For critical paths, arena and pool allocators can be 10-100x faster
4. **Safety has costs:** Debug allocators are slower but catch bugs; production allocators balance safety and speed

Modern allocators like jemalloc and tcmalloc represent decades of research and engineering. Understanding their design helps you use them effectively and know when custom solutions are worthwhile. Whether you're building a game engine, a database, or a web server, memory allocation is a fundamental skill that rewards deep understanding.

The allocator is often the most-called code in your application. Make it count.

## 17. Language-Specific Allocation Patterns

Different programming languages present unique allocation challenges and opportunities. Understanding these patterns helps you optimize across the stack.

### 17.1 C++ Allocators and the Standard Library

C++ allows custom allocators for standard containers:

```cpp
template<typename T>
class PoolAllocator {
    static MemoryPool pool;
public:
    using value_type = T;

    T* allocate(size_t n) {
        return static_cast<T*>(pool.alloc(n * sizeof(T)));
    }

    void deallocate(T* p, size_t n) {
        pool.free(p, n * sizeof(T));
    }
};

// Use with containers
std::vector<int, PoolAllocator<int>> vec;
std::map<int, std::string, std::less<int>,
         PoolAllocator<std::pair<const int, std::string>>> map;
```

C++17 introduced polymorphic memory resources (PMR):

```cpp
#include <memory_resource>

std::array<std::byte, 1024> buffer;
std::pmr::monotonic_buffer_resource pool{buffer.data(), buffer.size()};

std::pmr::vector<int> vec{&pool};  // Uses our buffer
vec.push_back(1);
vec.push_back(2);
// No heap allocation until buffer exhausted
```

PMR separates allocation policy from container type, enabling runtime allocator selection.

### 17.2 Rust's Ownership and Allocation

Rust's ownership model enables compile-time allocation analysis:

```rust
// Stack allocation - no heap involvement
let x: [i32; 1000] = [0; 1000];

// Heap allocation with Box
let boxed: Box<[i32; 1000]> = Box::new([0; 1000]);

// Custom allocators (nightly feature)
#![feature(allocator_api)]
use std::alloc::{Allocator, Global, Layout};

struct BumpAllocator { /* ... */ }

impl Allocator for BumpAllocator {
    fn allocate(&self, layout: Layout) -> Result<NonNull<[u8]>, AllocError> {
        // Bump pointer allocation
    }

    unsafe fn deallocate(&self, ptr: NonNull<u8>, layout: Layout) {
        // No-op for bump allocator
    }
}
```

Rust's `Vec<T, A>` allows allocator-parameterized collections, similar to C++.

### 17.3 Go's Escape Analysis

Go's compiler determines whether allocations can stay on the stack:

```go
func stackAlloc() int {
    x := 42  // Stays on stack
    return x
}

func heapAlloc() *int {
    x := 42  // Escapes to heap - returned pointer outlives function
    return &x
}
```

Check escape analysis with:

```bash
go build -gcflags="-m" main.go
# Output shows which allocations escape to heap
```

Go's runtime includes a sophisticated allocator based on tcmalloc, with:

- Per-P (processor) caches for small objects
- Size-class-based allocation
- Concurrent garbage collection integration

### 17.4 JVM Allocation and TLAB

The JVM uses Thread-Local Allocation Buffers (TLABs):

```text
┌─────────────────────────────────────────────┐
│              Eden Space                      │
│  ┌────────┐  ┌────────┐  ┌────────┐        │
│  │ TLAB 1 │  │ TLAB 2 │  │ TLAB 3 │  ...   │
│  │Thread 1│  │Thread 2│  │Thread 3│        │
│  └────────┘  └────────┘  └────────┘        │
└─────────────────────────────────────────────┘
```

Each thread gets a TLAB from Eden. Allocation is just a pointer bump:

```java
// JVM internal (conceptual)
Object allocate(int size) {
    if (tlab.pointer + size <= tlab.end) {
        Object obj = tlab.pointer;
        tlab.pointer += size;
        return obj;
    }
    return slowPathAlloc(size);
}
```

This makes most JVM allocations extremely fast—often faster than malloc.

## 18. Virtual Memory and the Allocator

Allocators work with virtual memory, not physical memory. Understanding this relationship is crucial.

### 18.1 The mmap Interface

Modern allocators use `mmap` for large allocations:

```c
void* large_alloc(size_t size) {
    void* ptr = mmap(NULL, size,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS,
                     -1, 0);
    if (ptr == MAP_FAILED) return NULL;
    return ptr;
}

void large_free(void* ptr, size_t size) {
    munmap(ptr, size);
}
```

`mmap` advantages:

- Immediate return to OS (unlike `brk`/`sbrk`)
- Address space isolation
- Huge page support
- Memory protection granularity

### 18.2 Overcommit and OOM

Linux overcommits memory by default:

```c
// This succeeds even without 1 TiB RAM
void* ptr = mmap(NULL, 1ULL << 40, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
// Fails only when you access pages beyond physical memory
```

This enables:

- Sparse data structures (only touched pages consume RAM)
- Copy-on-write fork efficiency
- Lazy initialization

But leads to the OOM killer when physical memory is exhausted.

### 18.3 Memory Advising

Allocators can hint to the kernel about memory usage patterns:

```c
// Mark memory as not needed soon
madvise(ptr, size, MADV_DONTNEED);  // Pages can be reclaimed

// Hint that memory will be needed
madvise(ptr, size, MADV_WILLNEED);  // Prefetch pages

// Mark as sequential access
madvise(ptr, size, MADV_SEQUENTIAL);  // Optimize readahead

// Mark as random access
madvise(ptr, size, MADV_RANDOM);  // Disable readahead
```

jemalloc uses `MADV_DONTNEED` and `MADV_FREE` to return memory without unmapping.

### 18.4 Transparent Huge Pages

2 MiB huge pages reduce TLB pressure:

```c
// Request huge page backing
madvise(ptr, size, MADV_HUGEPAGE);

// Or allocate huge pages directly
void* ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
                 -1, 0);
```

Trade-offs:

- Pro: Fewer TLB misses (1 entry covers 2 MiB vs 4 KiB)
- Con: Internal fragmentation (smallest unit is 2 MiB)
- Con: Allocation latency (finding contiguous physical memory)

## 19. Allocation in Distributed Systems

Distributed systems face unique allocation challenges.

### 19.1 Shared-Nothing Memory

In shared-nothing architectures, each node manages its own memory:

```text
Node 1                    Node 2                    Node 3
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Local allocator  │     │ Local allocator  │     │ Local allocator  │
│ Serialization    │────▶│ Deserialization  │────▶│ Local copy       │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

Serialization/deserialization overhead often dominates. Strategies:

- **Zero-copy serialization:** Formats like FlatBuffers, Cap'n Proto
- **Object pooling:** Reuse buffers for network I/O
- **Arena allocation:** Per-request arenas freed in bulk

### 19.2 RDMA and Remote Memory

Remote Direct Memory Access changes the allocation picture:

```c
// Register memory for RDMA
struct ibv_mr* mr = ibv_reg_mr(pd, buffer, size,
                                IBV_ACCESS_LOCAL_WRITE |
                                IBV_ACCESS_REMOTE_WRITE |
                                IBV_ACCESS_REMOTE_READ);

// Remote read (no CPU involvement at remote end)
ibv_post_send(qp, &read_wr, &bad_wr);
```

RDMA-aware allocators must:

- Pin memory (prevent page-out)
- Register memory regions with the NIC
- Handle registration caching
- Balance registration overhead against memory efficiency

### 19.3 Persistent Memory in Distributed Systems

NVM adds durability requirements to distributed allocation:

```c
// Intel PMDK distributed pattern
PMEMobjpool* pop = pmemobj_open(path, layout);

// Transactional allocation
TX_BEGIN(pop) {
    PMEMoid oid = pmemobj_tx_alloc(size, type_num);
    // If crash here, allocation is rolled back
    pmemobj_tx_add_range(oid, 0, size);
    // Initialize object
} TX_END
// Durably committed
```

Distributed consensus (like Raft) combined with persistent allocators enables durable distributed data structures.

## 20. Future Directions in Memory Allocation

### 20.1 Hardware Memory Tagging

ARM MTE and similar technologies enable hardware-assisted memory safety:

```text
┌─────────────────────────────────────────────┐
│ Pointer: [Tag:4][Address:60]                │
│ Memory:  Each 16 bytes has 4-bit tag        │
│ Access:  Hardware checks tag match          │
└─────────────────────────────────────────────┘
```

Future allocators will manage tags:

- Different tag per allocation
- Change tag on free (detects use-after-free)
- Bound checking via adjacent tags

### 20.2 CXL and Disaggregated Memory

Compute Express Link enables memory disaggregation:

```text
┌─────────┐     CXL      ┌─────────────────┐
│ CPU 1   │◀────────────▶│ Memory Pool     │
│ Local   │              │ (shared)        │
│ DRAM    │◀────────────▶│ - Hot data      │
└─────────┘              │ - Cold data     │
                         │ - Persistent    │
┌─────────┐              └─────────────────┘
│ CPU 2   │◀────────────────────┘
└─────────┘
```

CXL-aware allocators will:

- Manage memory tiers (local DRAM, CXL-attached, NVM)
- Optimize placement based on access patterns
- Handle heterogeneous latency/bandwidth

### 20.3 ML-Guided Allocation

Machine learning can optimize allocation decisions:

- Predict allocation lifetimes for better placement
- Learn size class distributions for specific workloads
- Detect anomalous allocation patterns (memory leaks, attacks)

Research prototypes show promising results:

```python
# Conceptual ML allocator
class MLAllocator:
    def __init__(self):
        self.model = load_model("allocation_predictor.h5")

    def allocate(self, size, context):
        lifetime = self.model.predict([size, context])
        if lifetime < SHORT_THRESHOLD:
            return self.arena_alloc(size)
        elif lifetime < MEDIUM_THRESHOLD:
            return self.pool_alloc(size)
        else:
            return self.general_alloc(size)
```

### 20.4 Verified Allocators

Formal verification ensures allocator correctness:

- seL4's verified allocator (capability-based)
- CompCert's verified C allocator
- Rust's type system as lightweight verification

As systems become more critical (autonomous vehicles, medical devices), verified allocators will become essential.

## 21. Summary

Memory allocation is a rich field balancing multiple constraints:

- **Speed:** Thread caching, size classes, and fast paths enable O(1) common-case allocation
- **Space:** Careful size class selection and coalescing minimize fragmentation
- **Safety:** Guard pages, red zones, and quarantine catch bugs early
- **Scalability:** Per-CPU caches and arena sharding reduce contention

Key takeaways:

1. **Understand your workload:** General-purpose allocators are good defaults, but specific patterns (arena-friendly, fixed-size objects) enable dramatic optimizations
2. **Measure before optimizing:** Use profiling tools to find allocation hotspots
3. **Consider custom allocators:** For critical paths, arena and pool allocators can be 10-100x faster
4. **Safety has costs:** Debug allocators are slower but catch bugs; production allocators balance safety and speed

Modern allocators like jemalloc and tcmalloc represent decades of research and engineering. Understanding their design helps you use them effectively and know when custom solutions are worthwhile. Whether you're building a game engine, a database, or a web server, memory allocation is a fundamental skill that rewards deep understanding.

The allocator is often the most-called code in your application. Make it count.
