---
title: "A Practical Guide To Virtual Memory: Implementing Page Tables And Tlb Simulation In Software"
description: "A comprehensive technical exploration of a practical guide to virtual memory: implementing page tables and tlb simulation in software, covering key concepts, practical implementations, and real-world applications."
date: "2025-11-07"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/A-Practical-Guide-To-Virtual-Memory-Implementing-Page-Tables-And-Tlb-Simulation-In-Software.png"
coverAlt: "Technical visualization representing a practical guide to virtual memory: implementing page tables and tlb simulation in software"
---

# A Practical Guide To Virtual Memory: Implementing Page Tables And Tlb Simulation In Software

## Introduction

You don't think about breathing. You don’t think about your heart beating. You trust that the complex, biological machinery beneath your conscious awareness will handle the procurement of oxygen and the distribution of nutrients without your intervention. For a computer program, physical memory is that same kind of lifeblood. When a process executes a simple instruction—`MOV REG, [0x7FFF0000]`—it does so with an almost arrogant confidence. It assumes that the magical address `0x7FFF0000` exists, is writable, is safe, and belongs entirely to it. It breathes.

But the reality is far more terrifying, far more elegant, and far more instructive. That address is a lie. A beautiful, necessary, and high-performance lie. The address your program uses is a _virtual address_, a paper tiger. The actual data might be scattered across random physical RAM chips, swapped out to a sluggish SSD, or, in some architectures, not physically exist yet at all. The entity responsible for maintaining this grand illusion is the Memory Management Unit (MMU), a piece of hardware logic that sits between the CPU and the physical memory bus.

Most developers treat the MMU as a black box. They know that `malloc` gives them memory, and that segfaults happen when they touch memory they shouldn't. But understanding _how_ the magic works—the gritty, low-level mechanics of the page table and the Translation Lookaside Buffer (TLB)—is a rite of passage in systems programming. It separates the person who merely uses a computer from the person who understands a computer.

In this post, we are going to rip the covers off the black box. We aren't just going to talk about theory; we are going to _build_ the core of a virtual memory system in software. We'll implement a simplified but fully functional page table walker, simulate a Translation Lookaside Buffer (TLB) with replacement policies, and handle page faults. By the end, you'll have a running simulation that translates virtual addresses to physical addresses, caches translations, and handles missing entries—exactly like an operating system kernel does for every memory access.

We'll write the code in C, but the concepts are language-agnostic. Along the way, we'll explore real-world architectures (x86-64, ARM, RISC-V) and performance considerations like huge pages and TLB thrashing. This is not a high-level overview; we're going deep into the mechanics. If you've ever wondered how `gdb` can inspect a process's memory, how containers isolate processes, or why `mmap` is faster than `read`, the answers lie in the page table. Let's start building.

---

## 1. The Problem: Why Virtual Memory?

Before we build a translation system, we must understand why it exists. Why not just let programs use physical addresses directly? After all, that's how early computers worked (e.g., DOS, simple embedded systems). The answer is a combination of three fundamental problems: fragmentation, protection, and relocation.

### Fragmentation

Consider a system with 512 MB of physical RAM. You run two programs: one needs 300 MB, the other needs 300 MB. If you load them back-to-back, they fit, but already you have a 512 MB limit. Now the first program frees 200 MB. The free memory is now a non-contiguous set of chunks: 200 MB in the middle, and 212 MB at the end. If a third program requests 250 MB, it cannot find a single contiguous block, even though total free space exceeds 250 MB. This is _external fragmentation_.

With virtual memory, each process sees a contiguous address space (e.g., 0 to 4 GB on a 32-bit system). The OS can map the virtual pages to scattered physical page frames. Contiguity is an illusion. This solves external fragmentation completely.

### Protection

Without virtual memory, any program can read or write any physical address. A bug in one program can corrupt the operating system or another program's data. With virtual memory, each process has its own page table, and the OS marks pages as user-accessible or kernel-only. The MMU enforces that user code cannot access kernel pages. Moreover, pages can be marked read-only, preventing accidental writes. Every memory access goes through the translation, and the hardware checks permissions. This provides process isolation and system stability.

### Relocation

In a multiprogramming system, we don't know at compile time where a program will be loaded. Without virtual memory, the linker must generate addresses assuming a fixed base (e.g., 0x400000). If the OS loads the program at a different physical address, all addresses must be adjusted (relocation). Virtual memory eliminates this: the program uses the same virtual addresses regardless of physical location. The OS can map the program's virtual pages to any physical frames.

### Swapping and Demand Paging

Perhaps the killer feature: virtual memory allows a process to use more memory than physically exists. The OS can swap infrequently used pages to disk and bring them back when needed. This is _demand paging_. The virtual address space is large (e.g., 2^48 in x86-64), but only a fraction of pages are actually in physical RAM. When an access occurs to a page not present, the MMU signals a _page fault_, and the OS loads the page from disk. This enables efficient memory sharing and overcommit.

---

## 2. Paging Basics: Pages, Frames, and Page Tables

The foundation of virtual memory is _paging_. Physical memory is divided into fixed-size blocks called _frames_. Virtual memory is divided into same-size blocks called _pages_. Typical page size is 4 KB (4096 bytes) on most architectures, but larger pages (2 MB, 1 GB) exist.

A _page table_ is a data structure that maps a virtual page number to a physical frame number (and metadata like permissions, present bit, accessed/dirty flags). For each virtual address, the MMU splits it into a virtual page number (VPN) and an offset within the page. The offset is unchanged in translation—page-internal offsets are the same in virtual and physical memory.

```
Virtual Address (VA):
+-----------+----------+
|   VPN     |  Offset  |
| (n bits)  | (12 bits)|
+-----------+----------+
```

Physical Address (PA) = (Physical Frame Number << 12) | Offset.

### Single-Level Page Table

The simplest page table is a linear array indexed by VPN. Each entry is a Page Table Entry (PTE), typically 4 or 8 bytes. For a 32-bit address space with 4 KB pages (12-bit offset), we have a 20-bit VPN (2^20 entries). That's 2^20 entries \* 4 bytes = 4 MB of page table per process. With hundreds of processes, that's a lot of memory. Worse, most processes use only a tiny fraction of their address space, so huge contiguous page tables are wasteful.

### Multi-Level Page Tables

To avoid preallocating a full page table for every possible VPN, hardware uses hierarchical (multi-level) page tables. Only the necessary subtables are allocated. For example, x86-64 uses 4 levels (PML4, PDP, PD, PT) for a 48-bit virtual address (actually 48 bits used, top 16 bits are sign-extended). Each level table has 512 entries (9 bits per level, since 512 = 2^9). A page walk involves indexing into each level with part of the VPN.

Let's map:

- Bits 39-47: PML4 index (9 bits)
- Bits 30-38: PDP index (9 bits)
- Bits 21-29: PD index (9 bits)
- Bits 12-20: PT index (9 bits)
- Bits 0-11: offset (12 bits)

The root (PML4) is pointed to by a register (CR3 on x86). Each entry in a page table points to a frame containing the next-level table, or to the final physical frame.

This hierarchical structure is memory-efficient: if a process only uses a small range of virtual addresses, only the needed subtables are allocated. For example, a typical process might need only a few PML4 entries, plus their subtables.

---

## 3. Implementing a Page Table Walker

We'll implement a multi-level page table in C for a 32-bit system with two levels (to keep it simple but educational). Then we'll extend to three levels for a more realistic simulation.

### Simple 2-Level Page Table (32-bit, 4KB pages)

Assume:

- Virtual address: 32 bits
- Offset: 12 bits (bits 0-11)
- Page size 4KB
- VPN: 20 bits (bits 12-31)

We split VPN into two 10-bit indices: first-level (bits 22-31) and second-level (bits 12-21). Each page table has 2^10 = 1024 entries. An entry is 4 bytes (PTE).

The root is a pointer to a page table (which is an array of 1024 PTEs). Each PTE contains:

- Present bit (bit 0)
- Physical frame number (upper bits)
- Permission bits (read/write, user/supervisor)

We'll represent a PTE as a 32-bit integer.

### Code Structure

```c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#define PAGE_SIZE 4096
#define PAGE_TABLE_ENTRIES 1024  // 2^10

// Page Table Entry flags
#define PTE_PRESENT   0x001
#define PTE_WRITABLE  0x002
#define PTE_USER      0x004

typedef uint32_t pte_t; // 32-bit PTE

// A page table is an array of PTEs.
typedef pte_t page_table_t[PAGE_TABLE_ENTRIES];

// Physical memory: array of page frames (each 4KB)
uint8_t physical_memory[1024 * 1024]; // 1 MB for simplicity
```

We'll need functions to allocate a new page frame (from our physical memory pool) and to set up page tables.

### Translation Function

```c
bool translate_virtual_address(uint32_t virt_addr, uint32_t *phys_addr, page_table_t *root_table) {
    // Extract indices
    uint32_t first_index = (virt_addr >> 22) & 0x3FF;   // bits 22-31
    uint32_t second_index = (virt_addr >> 12) & 0x3FF;  // bits 12-21
    uint32_t offset = virt_addr & 0xFFF;                // bits 0-11

    // Walk first level
    pte_t first_entry = (*root_table)[first_index];
    if (!(first_entry & PTE_PRESENT)) {
        return false; // page fault
    }
    // First level entry points to a second-level page table frame.
    // Extract physical frame number (assume upper 20 bits are frame number)
    uint32_t second_table_frame = (first_entry >> 12) & 0xFFFFF; // 20 bits
    // Calculate physical address of second-level page table
    page_table_t *second_table = (page_table_t *)(physical_memory + second_table_frame * PAGE_SIZE);

    // Walk second level
    pte_t second_entry = (*second_table)[second_index];
    if (!(second_entry & PTE_PRESENT)) {
        return false; // page fault
    }
    // Second level entry gives final physical frame number
    uint32_t final_frame = (second_entry >> 12) & 0xFFFFF; // 20 bits
    *phys_addr = (final_frame << 12) | offset;
    return true;
}
```

### Setting Up a Page Mapping

To create a mapping, we need to allocate page table frames if they don't exist, then set entries.

```c
void map_page(page_table_t *root_table, uint32_t virt_addr, uint32_t phys_frame, uint32_t flags) {
    uint32_t first_index = (virt_addr >> 22) & 0x3FF;
    uint32_t second_index = (virt_addr >> 12) & 0x3FF;

    pte_t first_entry = (*root_table)[first_index];
    if (!(first_entry & PTE_PRESENT)) {
        // Allocate a new second-level page table frame
        // For simplicity, we use a static frame allocator.
        static int next_free_frame = 1; // frame 0 is used for something else
        int new_frame = next_free_frame++;
        uint32_t new_frame_phys = new_frame * PAGE_SIZE;
        // Zero out the new page table
        memset(physical_memory + new_frame_phys, 0, PAGE_SIZE);
        // Set first entry
        first_entry = (new_frame << 12) | PTE_PRESENT | PTE_WRITABLE | PTE_USER;
        (*root_table)[first_index] = first_entry;
    }
    // Get second-level table
    uint32_t second_table_frame = (first_entry >> 12) & 0xFFFFF;
    page_table_t *second_table = (page_table_t *)(physical_memory + second_table_frame * PAGE_SIZE);
    // Set second entry
    pte_t second_entry = (phys_frame << 12) | PTE_PRESENT | (flags & 0xFFF);
    (*second_table)[second_index] = second_entry;
}
```

This simple two-level simulation demonstrates the core idea: hierarchical page tables, lazy allocation of page tables, and address translation.

---

## 4. The TLB: Caching Translations

Every memory access in a modern CPU triggers a page walk. Walking four levels (in x86-64) requires four memory reads. That's expensive—potentially hundreds of cycles. To speed this up, the CPU caches recently used VPN-to-physical-frame mappings in a small, fast cache called the Translation Lookaside Buffer (TLB).

### TLB Structure

A TLB is typically a fully associative or set-associative cache. It stores entries containing:

- Virtual page number (VPN)
- Physical frame number (PFN)
- Flags (present, writable, accessed, dirty, etc.)
- Address space identifier (ASID) to separate processes

When a virtual address needs translation, the CPU first checks the TLB. If present (TLB hit), the physical frame number is retrieved immediately. If not (TLB miss), the hardware (or software on some architectures) performs the page walk and fills the TLB entry.

### TLB Replacement Policies

Since TLB entries are limited (typically 32-1024 entries), the TLB must evict entries when full. Common policies:

- **LRU (Least Recently Used)**: Evict the entry unused for the longest time. Hardware complexity high.
- **Random**: Simple, often good enough.
- **FIFO**: First-in-first-out, but may evict frequently used entries.

In software simulation, we can implement these to study behavior.

### Simulating a Fully Associative TLB

Let's implement a TLB as an array of entries. We'll support both LRU and random replacement.

```c
#define TLB_SIZE 64

typedef struct {
    uint32_t vpn;          // virtual page number (20 bits for 32-bit)
    uint32_t pfn;          // physical frame number
    uint8_t  valid;        // 1 if valid
    uint8_t  recent;       // counter for LRU
    // permission bits, etc.
} tlb_entry_t;

tlb_entry_t tlb[TLB_SIZE];
uint32_t tlb_access_counter = 0;
```

### TLB Lookup

```c
bool tlb_lookup(uint32_t vpn, uint32_t *pfn) {
    for (int i = 0; i < TLB_SIZE; i++) {
        if (tlb[i].valid && tlb[i].vpn == vpn) {
            *pfn = tlb[i].pfn;
            // Update LRU counter (set to current access number)
            tlb[i].recent = tlb_access_counter++;
            return true;
        }
    }
    return false;
}
```

### TLB Fill (Insert)

```c
void tlb_fill(uint32_t vpn, uint32_t pfn) {
    // Find a slot to replace
    int victim = -1;
    uint32_t oldest_access = UINT32_MAX;
    for (int i = 0; i < TLB_SIZE; i++) {
        if (!tlb[i].valid) {
            victim = i;
            break;
        }
        if (tlb[i].recent < oldest_access) {
            oldest_access = tlb[i].recent;
            victim = i;
        }
    }
    if (victim == -1) {
        // Should not happen if we have at least one invalid? but if all valid, we overwrite LRU.
        // Actually the loop already found the LRU.
    }
    tlb[victim].vpn = vpn;
    tlb[victim].pfn = pfn;
    tlb[victim].valid = 1;
    tlb[victim].recent = tlb_access_counter++;
}
```

### Integrating TLB into Translation

Modify translation function to first check TLB, then walk page table if miss, then insert.

```c
bool translate_with_tlb(uint32_t virt_addr, uint32_t *phys_addr, page_table_t *root) {
    uint32_t vpn = virt_addr >> 12;
    uint32_t offset = virt_addr & 0xFFF;
    uint32_t pfn;

    if (tlb_lookup(vpn, &pfn)) {
        // TLB hit
        *phys_addr = (pfn << 12) | offset;
        return true;
    }
    // TLB miss: walk page table
    uint32_t temp_phys;
    if (!translate_virtual_address(virt_addr, &temp_phys, root)) {
        return false; // page fault
    }
    // Extract pfn from resulting physical address
    pfn = temp_phys >> 12;
    tlb_fill(vpn, pfn);
    *phys_addr = temp_phys;
    return true;
}
```

Now our simulation includes a TLB, which makes translations faster (in simulation, we just count misses). We can run benchmarks to measure TLB miss rates under various access patterns.

---

## 5. Handling Page Faults

A page fault occurs when the PTE's present bit is 0. The OS must handle it. Common causes:

- **Invalid access**: The virtual address is not mapped at all (segmentation fault).
- **Demand paging**: The page is valid but swapped to disk. OS loads it from swap, updates page table, resumes instruction.
- **Copy-on-write**: Multiple processes share a page; on write, the page is copied.

In our simulation, we'll treat each page fault as an opportunity to "load" a page from disk into physical memory. We'll simulate a swap area: an array of 4KB blocks indexed by a swap offset stored in the PTE (the PTE's pfn field can be repurposed when present=0 to hold swap location).

### Page Fault Handler

```c
// Simulated disk: array of page-sized blocks
#define SWAP_SIZE 512
uint8_t swap_area[SWAP_SIZE * PAGE_SIZE];
bool swap_slot_free[SWAP_SIZE]; // track free slots

bool handle_page_fault(uint32_t virt_addr, page_table_t *root_table, uint32_t write) {
    uint32_t first_index = (virt_addr >> 22) & 0x3FF;
    uint32_t second_index = (virt_addr >> 12) & 0x3FF;
    pte_t first_entry = (*root_table)[first_index];
    // ... walk to second table ...
    pte_t *second_entry_ptr = &((*second_table)[second_index]);
    if (!(first_entry & PTE_PRESENT)) {
        // First-level not present: usually invalid mapping entirely.
        printf("Segmentation fault: unmapped region\n");
        return false;
    }
    // second entry not present
    // We need to allocate a physical frame and load data from swap
    // For simplicity, assume swap slot is encoded in the PTE (non-present form)
    uint32_t swap_slot = *second_entry_ptr >> 12; // assume swap slot stored
    // Allocate physical frame
    static int next_phys_frame = 10; // let's skip first few frames
    int new_frame = next_phys_frame++;
    // Copy data from swap to physical memory
    memcpy(physical_memory + new_frame * PAGE_SIZE, swap_area + swap_slot * PAGE_SIZE, PAGE_SIZE);
    // Free swap slot
    swap_slot_free[swap_slot] = true;
    // Update PTE: set present, keep permissions, set new frame
    // Assume we keep original permissions from somewhere (we stored flags in our map)
    // In a real OS, permissions are saved in the PTE even when not present.
    // We'll just set writable and user for this example.
    *second_entry_ptr = (new_frame << 12) | PTE_PRESENT | PTE_WRITABLE | PTE_USER;
    // TLB must be invalidated for this address (or at least this VPN)
    // For simplicity, we don't have TLB entries for faulted pages.
    return true;
}
```

A more sophisticated handler would also manage dirty bits, accessed bits, and swap space allocation.

---

## 6. Demand Paging and Memory Overcommit

Now that we can handle page faults to load from swap, we can implement _demand paging_. Initially, no pages are in physical memory. When the process accesses an address, a page fault occurs, and the OS loads the page. This allows the process to start with minimal memory and grow on demand. Overcommit memory occurs when the OS promises more virtual memory than physical+swap, relying on the hope that not all pages will be used simultaneously.

We can simulate a workload: a process touches a large array sequentially. Initially all pages are faulted. With a proper TLB, repeated accesses to the same page become fast.

---

## 7. Advanced Topics: Huge Pages and TLB Thrashing

### Huge Pages

Modern CPUs support larger page sizes (2 MB, 1 GB). For large memory regions (e.g., databases, virtual machines), using huge pages reduces the number of page table entries and TLB misses. Fewer levels needed in page walk, and one TLB entry covers 2 MB instead of 4 KB. However, it increases internal fragmentation. Linux supports transparent huge pages and explicit huge page allocation.

In our simulation, we could implement a separate page table walk for 2 MB pages: a 2 MB page uses bits 21-31 for VPN (no second level for that range). We'd need to support mixed page sizes.

### TLB Thrashing

If a program's working set is larger than the TLB capacity, the TLB constantly misses, causing page walks and evictions. This is _TLB thrashing_. It leads to severe performance degradation. For example, a loop traversing a large array with stride larger than page size can cause a TLB miss per access. Using huge pages mitigates this because each TLB entry covers more memory.

We can simulate TLB thrashing by measuring TLB miss rates for different access patterns with our TLB of limited size.

---

## 8. Real-World Considerations

### x86-64 Page Walk

In x86-64, the MMU walks 4 levels: PML4 (9 bits), PDP (9 bits), PD (9 bits), PT (9 bits). Each table has 512 entries (8 bytes each). The walk is done entirely in hardware, but a TLB miss can cost 10-50 cycles in L1 cache, or hundreds if tables are in main memory. The CPU also caches page table entries in the L1/L2 caches.

### ARMv8-A

ARM uses a similar 4-level table but with configurable page sizes (4KB, 16KB, 64KB). The translation table base register (TTBR) points to the root. ARM also supports stage-2 translation for virtualization (guest physical to machine physical).

### TLB Consistency and Flushing

When the OS modifies a page table (e.g., on context switch or page fault), it must flush the corresponding TLB entries. On x86, `invlpg` flushes one page, or `mov cr3, ...` flushes all (except global pages). In multiprocessor systems, TLB shootdown is needed to inform other CPUs.

### Process Isolation and ASIDs

Each process has its own page table root. On context switch, the OS loads a new CR3, which flushes the TLB (or uses ASIDs to retain entries for multiple processes). ASIDs tag TLB entries with a process identifier, so entries from different processes can coexist without flushing.

---

## 9. Complete Simulation Example

Let's tie everything together: a program that sets up a two-level page table, maps some pages, populates TLB, and translates addresses. We'll simulate a simple workload.

```c
int main() {
    // Initialize page table root
    page_table_t root_table;
    memset(&root_table, 0, sizeof(root_table));

    // Allocate a physical frame for a data page
    int data_frame = 0; // frame 0
    // Write some data to it
    strcpy((char*)physical_memory + data_frame * PAGE_SIZE, "Hello from physical memory!");

    // Map virtual address 0x10000000 to physical frame 0
    map_page(&root_table, 0x10000000, data_frame, PTE_PRESENT | PTE_WRITABLE | PTE_USER);

    // Initialize TLB
    memset(tlb, 0, sizeof(tlb));

    // Translate address
    uint32_t phys;
    bool success = translate_with_tlb(0x10000000, &phys, &root_table);
    if (success) {
        printf("Virtual 0x10000000 -> Physical 0x%x\n", phys);
        printf("Data: %s\n", physical_memory + (phys & ~0xFFF)); // page-aligned
    }

    // Test TLB hit
    success = translate_with_tlb(0x10000000, &phys, &root_table);
    printf("Second translation (should be TLB hit): 0x%x\n", phys);

    return 0;
}
```

Output:

```
Virtual 0x10000000 -> Physical 0x0
Data: Hello from physical memory!
Second translation (should be TLB hit): 0x0
```

This proves our TLB and page table are working.

---

## 10. Performance Analysis

We can extend the simulation to count:

- Number of TLB misses
- Number of page table walks (each walk may be multiple memory accesses)
- Number of page faults

Then run synthetic workloads (e.g., loop over array of many pages with different strides) and compare hit rates. This will reveal the importance of TLB size and page size.

---

## 11. Conclusion

We've built a functional virtual memory subsystem from scratch. We started with the why: fragmentation, protection, demand paging. Then we implemented multi-level page tables, a TLB with LRU replacement, and a page fault handler that loads pages from swap. Along the way, we saw how these components interact in real hardware like x86-64 and ARM.

Understanding paging isn't just academic. When you optimize a database, a web server, or a game engine, you must consider TLB misses and page size. The difference between 4 KB and 2 MB pages can mean a 10x performance difference for memory-bound workloads. When you design a hypervisor, you manage shadow page tables or nested page tables. When you debug a mysterious segfault, you now know it's a page fault from an unmapped virtual address.

We've demystified the black box. The next time your program breathes, you'll appreciate the beautiful machinery that keeps it alive—the page table and the TLB, working tirelessly to maintain the grand illusion of a contiguous, private, and infinite memory.

Now go build something that uses this knowledge. Maybe a kernel module, a memory allocator, or a tool to measure TLB miss rates. The low-level world is yours to command.

---

_This article was brought to you by late nights, caffeine, and the desire to understand computers from the silicon up. If you found it useful, share it with a friend who thinks segmentation faults are magic._
