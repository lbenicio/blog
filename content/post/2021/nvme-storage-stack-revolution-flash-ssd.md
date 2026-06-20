---
title: "NVMe and the Storage Stack: The NVMe Command Set, Submission/Completion Queues, SPDK, and the Death of the SCSI/SATA Bottleneck"
description: "A deep exploration of NVMe technology — how the command set and queue model eliminate the SCSI bottleneck, and why user-space storage via SPDK achieves microsecond-latency I/O on commodity flash."
date: "2021-05-31"
author: "Leonardo Benicio"
tags: ["nvme", "storage", "ssd", "spdk", "flash", "performance", "io"]
categories: ["systems", "storage"]
draft: false
cover: "/static/assets/images/blog/nvme-storage-stack-revolution-flash-ssd.png"
coverAlt: "A stylized diagram showing the NVMe storage stack with submission and completion queues, the controller processing commands in parallel across multiple flash channels"
---

In 2011, the NVM Express (NVMe) specification was published, and it fundamentally changed the relationship between storage and the rest of the computer. Before NVMe, solid-state drives (SSDs) had to pretend to be hard disk drives. They spoke SCSI or ATA, protocols designed for spinning rust with millisecond seek times and single-digit megabyte-per-second transfer rates. These protocols were serial — one command at a time — and required the operating system to manage a command queue in system memory because the drive could only handle one operation at a time. NVMe threw out all of this legacy. It was designed from scratch for non-volatile memory — flash, 3D XPoint, and future persistent memories — with microsecond latencies, massive parallelism, and a command set that maps directly to how flash memory actually works. The result is a storage stack that can achieve sub-10-microsecond read latencies and millions of IOPS on commodity hardware.

## 1. The SCSI/SATA Legacy: One Queue, One Command at a Time

To understand why NVMe matters, we need to understand what it replaced. SCSI (Small Computer System Interface) and ATA (Advanced Technology Attachment, later SATA) were designed for hard disk drives. A hard drive has a single actuator arm with read/write heads, and it can only read or write one location at a time. Therefore, the interface only needs to support one outstanding command at a time (or a small queue depth, in the case of Native Command Queuing in SATA, which supports up to 32 commands).

The SCSI command model reflects this serial nature. The host sends a command to the drive. The drive processes it (seeks, reads/writes, possibly retries on error). The drive sends a completion to the host. The host sends the next command. This works well for hard drives because the seek time (5-10 milliseconds) dominates the command overhead. Even if the command protocol is slow (hundreds of microseconds of overhead), it's negligible compared to the seek.

But SSDs are solid-state. They have no moving parts. A NAND flash page read takes about 50-100 microseconds. A flash page write takes about 200-500 microseconds. These latencies are two orders of magnitude smaller than hard drive seeks, which means command overhead matters. If the SCSI stack adds 20 microseconds of overhead to every I/O, and the flash itself takes 50 microseconds, the overhead is 40% of the total latency. That's unacceptable.

Moreover, SSDs are massively parallel internally. A modern NVMe SSD might have 8, 16, or 32 NAND flash chips ("dies"), each with multiple "planes" that can be accessed independently, each plane with thousands of "blocks" that can be read in parallel. The SSD controller can process dozens or hundreds of I/O operations simultaneously across these parallel resources. But the SCSI/SATA command model, with its single queue and low queue depth, starves this parallelism. The SSD is waiting for commands while the host queues them one at a time.

## 2. NVMe: Parallel Queues for Parallel Storage

NVMe solves the parallelism problem with a radically different queue model. Instead of a single command queue, NVMe supports up to 65,535 I/O Submission Queues (SQs), each paired with an I/O Completion Queue (CQ). Each SQ can hold up to 65,536 commands. The host and the NVMe controller communicate through these queues, which are allocated in host memory and mapped into both host and controller address spaces.

The command submission protocol is simple and efficient:

1. The host (the NVMe driver in the OS) builds a 64-byte Submission Queue Entry (SQE) in memory. The SQE contains the command opcode (read, write, flush, compare, etc.), the starting LBA (Logical Block Address), the number of blocks, a pointer to the data buffer (Physical Region Pages, or PRPs, or Scatter-Gather Lists, or SGLs), and a Command Identifier.

2. The host writes the SQE to the next free slot in the Submission Queue (a circular buffer in host memory).

3. The host writes the new SQ tail pointer to the controller's doorbell register (a memory-mapped I/O register on the PCIe BAR). This notifies the controller that new commands are available.

4. The controller fetches the SQE from host memory (via DMA), processes the command (reads/writes the flash), and when complete, writes a 16-byte Completion Queue Entry (CQE) into the Completion Queue in host memory. The CQE contains the command identifier, a status field (success or error code), and the SQ head pointer.

5. The controller generates an interrupt to notify the host of completion. Alternatively, the host can poll the CQ for completions (more efficient for high-IOPS workloads).

The beauty of this model is that it maps perfectly to multi-core systems. Each CPU core can have its own SQ/CQ pair, eliminating lock contention for queue access. Core 0 submits commands through SQ 0 and collects completions from CQ 0. Core 1 uses SQ 1 and CQ 1. No shared state between cores, no cache-line bouncing, no lock contention. This is the key to NVMe's scalability: as you add more cores, you get more IOPS, up to the limits of the flash controller.

## 3. The NVMe Command Set: Purpose-Built for Flash

NVMe's command set reflects its flash-native design. The core commands are:

- **Read**: Read data from the NVM (Non-Volatile Memory) into the host's buffer. Supports scatter-gather lists for flexible data placement.

- **Write**: Write data from the host's buffer to the NVM. Supports the same scatter-gather flexibility.

- **Flush**: Ensure that all previously written data is committed to non-volatile media. This is the equivalent of a cache flush — it forces the SSD's internal DRAM cache (if any) to be written to flash.

- **Compare**: Read data from the NVM and compare it against the host's buffer. If they differ, the command fails with a compare error. This enables efficient atomic compare-and-swap operations at the block level.

- **Write Uncorrectable**: Mark a range of LBAs as containing uncorrectable data. This is used for testing error recovery paths and for securely erasing data without overwriting it.

- **Dataset Management**: A family of commands for hinting about data usage: Trim (inform the SSD that a range of LBAs is no longer in use, allowing the SSD to reclaim the underlying flash blocks), and other hints for access frequency and latency tolerance.

NVMe also supports administrative commands for controller management: Create/Delete I/O Submission and Completion Queues, Identify (query controller and namespace capabilities), Get/Set Features (configure power management, interrupt coalescing, temperature thresholds), and Format NVM (low-level format of the flash, including secure erase options).

The command set is extensible through "vendor-specific" commands and "NVMe Management Interface" (NVMe-MI) commands for out-of-band management (e.g., over SMBus or PCIe VDM).

## 4. SPDK: User-Space NVMe for Microsecond Latency

While NVMe eliminates the hardware bottleneck, the operating system's storage stack remains a bottleneck. The Linux kernel's block layer, I/O scheduler, and file system add tens of microseconds of overhead to every I/O — overhead that's comparable to the flash access time itself.

The Storage Performance Development Kit (SPDK), an open-source project from Intel, moves the NVMe driver into user space, eliminating the kernel from the I/O path. SPDK applications link against a user-space NVMe driver library that maps the NVMe controller's PCI BARs into the application's address space, allocates the SQs and CQs in the application's memory, and polls the CQs directly — no system calls, no interrupts, no kernel involvement.

The SPDK NVMe driver achieves sub-10-microsecond 4 KB random read latency on modern NVMe SSDs. For comparison, the same SSD accessed through the Linux kernel's block layer (with `pread`) achieves about 80-100 microseconds. The 10x latency reduction comes entirely from eliminating kernel overhead.

SPDK achieves this performance through several design principles:

1. **Polling, not interrupts**: SPDK applications poll the Completion Queues in a tight loop, checking for new completions. Polling eliminates interrupt latency (1-5 microseconds) and context-switch overhead (2-5 microseconds). The trade-off is that a polling thread consumes 100% of a CPU core, even when idle. For storage workloads where the CPU is dedicated to I/O processing, this is a good trade.

2. **Lock-free data structures**: SPDK's I/O path uses lock-free ring buffers (the NVMe queues themselves) and per-thread data structures. There are no locks on the I/O fast path, which eliminates contention and improves scalability.

3. **Zero-copy data paths**: SPDK applications can receive data directly into their processing buffers without intermediate copies. The NVMe controller DMAs data into memory that the application has pre-registered, and the application processes it in place.

4. **Userspace drivers**: SPDK includes user-space drivers for NVMe, NVMe-over-Fabrics (NVMe-oF), and several other storage protocols. These drivers bypass the kernel entirely, giving the application full control over I/O scheduling and completion processing.

SPDK is the foundation for several production storage systems, including Intel's own storage products, the SPDK-based vhost-user backends in QEMU/KVM, and the Ceph BlueStore backend's NVMe path.

## 5. NVMe-over-Fabrics: Disaggregating Storage

NVMe-over-Fabrics (NVMe-oF) extends the NVMe command set over a network, allowing a host to access a remote NVMe SSD as if it were locally attached. The NVMe-oF specification defines transport bindings for RDMA (InfiniBand, RoCE, iWARP), Fibre Channel, and TCP.

The architecture of NVMe-oF is elegant: the NVMe commands and completions are encapsulated in network messages and sent over the fabric. The remote NVMe controller processes the commands exactly as it would for a local submission, and the completions are sent back over the network. From the host's perspective, the remote SSD is indistinguishable from a local one — same command set, same queue model, same performance (minus network latency).

NVMe-oF over RDMA achieves remarkable performance. With RDMA (Remote Direct Memory Access), the host's NVMe driver can write SQEs directly into the remote controller's memory (via RDMA Write), and the remote controller can write CQEs directly into the host's memory. No CPU involvement on the target side for data movement — the RDMA NIC handles the DMA transfers. Latency overhead for NVMe-oF over RDMA is typically 10-20 microseconds on top of the SSD's local access latency, enabling remote SSDs with sub-50-microsecond access times.

NVMe-oF over TCP sacrifices some performance for universality (TCP works everywhere), but with the right optimizations (kernel bypass TCP stacks, polling-based completions), it can still achieve sub-100-microsecond remote access latencies.

## 6. Computational Storage and Future Directions

The NVMe specification is evolving to support computational storage — SSDs that can execute user-provided code directly on the drive, near the data. The NVMe Computational Storage specification defines commands for downloading and executing programs on the SSD controller, enabling use cases like database filter queries, compression/decompression, and encryption/decryption to be offloaded to the storage device.

NVMe 2.0 (2021) reorganized the specification into a family of modular standards, making it easier to add new features without revising the entire specification. It also added Zoned Namespaces (ZNS), which expose the flash's internal geometry to the host, allowing the host to manage data placement for improved performance and endurance. ZNS is particularly important for large-scale deployments where write amplification (the ratio of flash writes to host writes) directly impacts cost and drive lifetime.

The storage stack of the future will be increasingly software-defined and purpose-built for non-volatile memory. NVMe provides the hardware interface; SPDK and similar frameworks provide the low-latency software infrastructure; and computational storage pushes processing closer to the data. The era of treating storage as a dumb block device is ending. Storage is becoming programmable.

## 7. SPDK Internals: The User-Space NVMe Driver Architecture

SPDK achieves its microsecond latency by reimplementing the entire NVMe driver in user space, but the architecture is more sophisticated than simply mapping PCIe BARs. Let's trace the life of a 4 KB read request through the SPDK stack.

### Initialization

At startup, the SPDK application calls `spdk_env_init()` which initializes the Environment Abstraction Layer (EAL). The EAL allocates huge pages (2 MB or 1 GB) for DMA buffers, pins threads to CPU cores, and initializes lock-free memory pools. Then `spdk_nvme_probe()` enumerates NVMe devices on the PCIe bus, mapping each controller's BAR0 (the memory-mapped register space) into the application's virtual address space.

For each NVMe controller, SPDK:

1. Resets the controller (writes to the Controller Configuration register).
2. Configures the Admin Queue (SQ0/CQ0) — the single administrative queue pair used for controller management.
3. Sends an `Identify` command to discover the controller's capabilities (number of namespaces, supported queue depth, features).
4. Creates I/O Queue Pairs — typically one SQ/CQ pair per CPU core that will process I/O.
5. Allocates the SQ and CQ in huge-page-backed DMA memory.

### The I/O Fast Path

When the application issues a read request via `spdk_nvme_ns_cmd_read()`, the function:

```c
int spdk_nvme_ns_cmd_read(struct spdk_nvme_ns *ns,
                          struct spdk_nvme_qpair *qpair,
                          void *payload, uint64_t lba,
                          uint32_t lba_count,
                          spdk_nvme_cmd_cb cb_fn, void *cb_arg);
```

The driver constructs a 64-byte SQE in place on the submission queue:

```c
// Simplified SQE construction (actual code uses bitfield unions)
struct spdk_nvme_cmd cmd = {
    .opc = SPDK_NVME_OPC_READ,        // Opcode: Read
    .nsid = ns->id,                    // Namespace ID
    .cdw10 = (uint32_t)lba,           // Starting LBA (low 32 bits)
    .cdw11 = (uint32_t)(lba >> 32),   // Starting LBA (high 32 bits)
    .cdw12 = (uint16_t)(lba_count - 1), // Number of logical blocks - 1
    .dptr.prp.prp1 = payload_paddr,   // PRP1: physical address of data buffer
};
```

The SQE is written to the next slot in the circular SQ buffer. Then the driver rings the doorbell — a single MMIO write to the controller's SQyTDBL (Submission Queue y Tail Doorbell) register with the new tail value. On x86-64, an MMIO write is an uncacheable store that passes through the write-combining buffer; it takes about 40-80 ns to reach the PCIe device.

The NVMe controller fetches the SQE via a PCIe Memory Read TLP (Transaction Layer Packet), processes the command (reads the data from flash into its internal buffer), then DMAs the data directly to the host's payload buffer (the physical address specified in PRP1). Finally, the controller writes a 16-byte CQE to the completion queue and optionally sends an MSI-X interrupt.

### Completion Polling

The SPDK application polls for completions in a loop:

```c
while (running) {
    struct spdk_nvme_cpl cpl;
    while (spdk_nvme_qpair_process_completions(qpair, 64)) {
        // CQ entries are processed, callbacks are invoked
    }
    // Possibly process other work (network, timers)
}
```

`spdk_nvme_qpair_process_completions()` reads the CQ head pointer, iterates over completed entries, invokes the callback for each completion, and updates the CQ head doorbell (to release the CQ slots back to the controller). The entire path — from SQE write to callback invocation — takes approximately 5-8 microseconds on a modern NVMe SSD (Samsung PM9A3, Intel P5800X).

### Why This Is Faster Than Kernel I/O

The kernel path for the same 4 KB read involves: system call overhead (1-2 µs), block layer processing (1-2 µs), NVMe driver queuing and doorbell write (1 µs), interrupt delivery (2-5 µs), softirq context switch (1-2 µs), block layer completion (1-2 µs), and copy to user space (1 µs). Total: 8-15 µs just in kernel overhead. SPDK eliminates everything except the hardware latency (the flash read itself, ~50 µs) and the doorbell/MMIO overhead (~0.1 µs). The difference is 5-8 µs for SPDK vs 60-80 µs for kernel I/O — an order of magnitude.

## 8. Zoned Namespaces (ZNS): Exposing Flash Geometry to the Host

Zoned Namespaces introduce a fundamental change to the NVMe programming model: instead of the SSD controller managing the mapping between logical blocks and physical flash locations (the FTL), the host takes responsibility for data placement within "zones." This is crucial for reducing write amplification and improving predictable latency.

### Zone Model

A ZNS SSD is divided into zones, each typically sized to match the underlying flash erase block (e.g., 256 MB or the size of a NAND block aggregate). Each zone has a write pointer that indicates the next writeable LBA within the zone. Zones are written sequentially: the host appends data at the write pointer, and the write pointer advances. Zones cannot be overwritten — the host must reset a zone (erase the entire zone) before writing to it from the start.

Zone states are managed by the host:

- **Empty**: No valid data, write pointer at zone start.
- **Open**: Write pointer can be advanced by writes. Limited number of open zones (typically 14-128).
- **Full**: Write pointer at zone end, no more writes possible until reset.
- **Offline**: Zone is unavailable (typically due to an error).

The host uses the `Zone Management Send` and `Zone Management Receive` commands to open, close, finish, and reset zones, and to query zone state.

### Write Amplification Factor (WAF) Reduction

In a conventional SSD, the FTL performs garbage collection: when the host overwrites an LBA, the FTL writes the new data to a new physical location, marks the old location invalid, and later copies still-valid pages from partially-invalidated blocks to new blocks. This "write amplification" — the ratio of physical NAND writes to host writes — is typically 2-4x for consumer workloads and can exceed 10x for write-heavy enterprise workloads.

With ZNS, the host controls data placement. A log-structured filesystem (like F2FS with ZNS support) or a RocksDB LSM-tree engine can write data sequentially within zones, never over-writing. When data is no longer needed, the host resets the entire zone, which corresponds to a single flash erase operation. There is no garbage collection — the host's data management (e.g., LSM-tree compaction, file deletion) directly drives zone resets. The write amplification factor approaches 1.0 (the theoretical minimum), which doubles effective flash endurance and halves power consumption compared to a conventional SSD with WAF of 2x.

### The ZNS Software Stack

The Linux kernel supports ZNS through the `zonefs` filesystem (a simple filesystem that exposes zones as files) and the ZBD (Zoned Block Device) subsystem, which provides a zone-aware block interface. Applications can use `libzbd` to manage zones directly, or use filesystems (F2FS, Btrfs with ZNS patches) that provide POSIX interfaces on top of zones.

For key-value stores, the RocksDB community has developed ZenFS, a ZNS-aware storage backend. ZenFS maps RocksDB's SST files to zones: each SST file is written sequentially within a zone, and when the SST file is deleted (during LSM-tree compaction), its zone is reset. This eliminates the FTL completely, giving RocksDB direct control over flash management. Benchmarks show 2-3x improvement in write throughput and 30-50% reduction in tail latency compared to RocksDB on a conventional NVMe SSD.

## 9. Summary

NVMe transformed the storage landscape by replacing the serial, single-queue SCSI/SATA model with a massively parallel, multi-queue model designed for flash memory. The 64-byte command format, the paired SQ/CQ architecture, and the flash-native command set eliminate the protocol bottlenecks that made SSDs underperform their potential. SPDK takes this further by moving the NVMe driver into user space, eliminating kernel overhead and achieving microsecond-latency I/O on commodity hardware. NVMe-over-Fabrics extends the model across the network, enabling disaggregated storage architectures with near-local performance.

The revolution is not over. As storage-class memories (SCM) like Intel Optane (3D XPoint) and future persistent memory technologies close the gap between storage and memory, the software stack must evolve further. NVMe provides the hardware foundation; the next challenge is building storage systems that can fully exploit the performance of persistent memory, where byte-addressable access and sub-microsecond latencies demand a fundamental rethinking of the storage hierarchy.

## 8. NVMe Specifications Evolution: From 1.0 to 2.0 and Beyond

The NVMe specification has evolved dramatically since version 1.0 (2011). NVMe 1.2 (2014) added support for NVMe over Fabrics and controller virtualization (SR-IOV for NVMe). NVMe 1.3 (2017) added sanitize (cryptographic erase), directives (hints for data placement), and virtualization enhancements. NVMe 1.4 (2019) added persistent event log, asymmetric namespace access, and IO determinism (predictable latency for real-time workloads). NVMe 2.0 (2021) restructured the specification into modular "technical proposals," making it easier to add new features without rewriting the entire specification.

Key features added in NVMe 2.0 include Zoned Namespaces (ZNS), which expose the flash's internal erase-block geometry to the host, allowing the host to manage data placement for improved write amplification and endurance. Key-Value (KV) command set, which replaces the block interface with a key-value interface, simplifying host software by eliminating the FTL (Flash Translation Layer) translation between logical blocks and physical flash locations. Computational Storage, which enables offloading computation (filtering, compression, encryption) to the SSD controller, reducing data movement and host CPU utilization.

## 9. Linux NVMe Driver Architecture and the Multi-Queue Block Layer

The Linux kernel's NVMe driver is a showcase for the multi-queue block layer (blk-mq), which was designed to support the parallelism of NVMe devices. The blk-mq layer maps I/O requests to hardware queues, with each queue pair mapped to a CPU core. This eliminates the single-queue bottleneck of the legacy block layer and enables NVMe's parallelism to be fully utilized.

The NVMe driver creates one I/O submission queue per CPU core (or one per interrupt vector, depending on configuration). When an application submits an I/O request, the blk-mq layer routes it to the appropriate queue (based on the submitting CPU), and the NVMe driver writes the SQE directly to the submission queue — no locking required, because the queue is single-writer (the submitting CPU owns it). This per-CPU queue model is the key to blk-mq's scalability: adding more CPU cores increases I/O throughput linearly, limited only by the NVMe controller's ability to process commands.

## 10. The Death of the SCSI/SATA Bottleneck: A Quantitative Analysis

Let's quantify the performance improvement from NVMe over SCSI/SATA. A modern NVMe SSD (Samsung 990 Pro, WD Black SN850X) achieves approximately 1,000,000 random 4 KB read IOPS and 7,000 MB/s sequential read throughput. A SATA SSD (Samsung 870 EVO) achieves approximately 98,000 IOPS and 560 MB/s. The NVMe drive is 10x faster in IOPS and 12.5x faster in throughput. The difference is almost entirely due to the interface: the NAND flash inside both drives is similar, but the SATA interface (with its AHCI command protocol and 6 Gbps link) bottlenecks the flash.

The NVMe advantage grows with each PCIe generation. PCIe 4.0 doubles the per-lane bandwidth from 1 GB/s to 2 GB/s. PCIe 5.0 doubles it again to 4 GB/s. A 4-lane PCIe 5.0 NVMe drive can achieve 16 GB/s of sequential throughput — comparable to DRAM bandwidth just a decade ago. The storage hierarchy is compressing: NVMe SSDs are approaching the performance of memory, while persistent memory (Optane) approached the latency of SSDs. The convergence of storage and memory is the defining trend of the next decade of systems design.

## 11. NAND Flash Internals: Pages, Blocks, and the FTL

To understand NVMe's design, we need to understand the flash memory it manages. NAND flash is organized into "dies" (chips), each containing multiple "planes" (independently accessible regions), each plane containing thousands of "blocks" (the erase unit, typically 256 KB to 16 MB), and each block containing hundreds of "pages" (the read/write unit, typically 4 KB to 16 KB).

The fundamental constraint of NAND flash is that pages must be erased before they can be written, and erases operate on entire blocks, not individual pages. This means that updating a single page in a block requires: (1) reading all valid pages from the block and writing them to a new block, (2) writing the new page to the new block, (3) erasing the old block. This process, called garbage collection, is managed by the Flash Translation Layer (FTL) firmware running on the SSD controller.

The FTL implements a log-structured storage system internally. Host writes are appended to a "write buffer" (usually in the SSD's DRAM or SLC cache), then written sequentially to free flash blocks. The FTL maintains a mapping table (L2P, logical-to-physical) that translates the host's logical block addresses (LBAs) to the flash's physical page addresses. When the host overwrites an LBA, the FTL writes the new data to a new physical page, updates the L2P table, and marks the old physical page as invalid. Garbage collection later reclaims blocks with many invalid pages, copying still-valid pages to new blocks and erasing the old blocks.

NVMe's command set supports this internal architecture explicitly. The `Dataset Management` command with the `Trim` attribute tells the FTL that a range of LBAs is no longer in use (e.g., the file system deleted a file). The FTL can immediately mark the corresponding physical pages as invalid and include them in garbage collection, improving write amplification (the ratio of physical writes to host writes). Good Trim hygiene is essential for SSD performance and endurance.

## 12. The NVMe-MI Management Interface

NVMe-MI (Management Interface) is a companion specification to NVMe that defines out-of-band management commands. While NVMe commands travel over the PCIe bus (in-band), NVMe-MI commands can travel over SMBus, I2C, or PCIe VDM (Vendor Defined Messages), providing a management channel that works even when the PCIe link is down or the NVMe controller is non-functional.

NVMe-MI enables several important management functions. Enclosure management: the NVMe device can report its physical location (slot number, chassis serial), temperature sensors, and power consumption. Firmware updates: the device can be updated without going through the PCIe NVMe driver. Health monitoring: the device can report SMART-like health data (wear level, spare capacity, error logs) even when the host OS is not loaded. These capabilities are essential for hyperscale datacenter operators who manage millions of SSDs across thousands of servers.

The NVMe-MI specification also defines a "management endpoint" that can be shared by multiple hosts in a multi-host configuration (e.g., a PCIe switch connecting multiple servers to a single SSD). The management endpoint provides a unified interface for all hosts to query device status, avoiding conflicts that could arise if multiple hosts tried to send in-band NVMe admin commands simultaneously.

## 13. NVMe and the Linux Block Layer: The blk-mq Architecture

The Linux kernel's block layer was redesigned from scratch (blk-mq, multi-queue block layer) to support NVMe's parallelism. The legacy block layer had a single request queue with a single lock, which became a bottleneck at NVMe IOPS levels. blk-mq replaces this with a two-level queue architecture: software staging queues (one per CPU core or per application) and hardware dispatch queues (mapped to NVMe submission queues).

When an application submits an I/O request (via `pread`, `pwrite`, or `io_uring`), the request is placed on the submitting CPU's software staging queue. No lock is needed because each CPU has its own queue. A block layer thread (or the submitting thread itself, in polling mode) drains the staging queue and dispatches requests to the appropriate hardware queue (NVMe submission queue), again without locking because each hardware queue has a single producer. This lock-free design enables the block layer to handle millions of IOPS without contention.

The blk-mq layer also supports I/O scheduling policies (mq-deadline, kyber, bfq) that make trade-offs between throughput and latency. For NVMe devices, the scheduler is typically "none" (no scheduling, direct dispatch) because the device's internal parallelism handles request reordering better than any software scheduler could. The scheduler is more useful for slower devices (SATA SSDs, HDDs) where request merging and reordering can significantly improve throughput.

The introduction of `io_uring` in Linux 5.1 (2019) further improved NVMe I/O efficiency by eliminating the system call overhead entirely for submission and completion. With `io_uring`, the application shares two ring buffers with the kernel: a submission queue (SQ) for I/O requests and a completion queue (CQ) for results. The application writes a Submission Queue Entry (SQE) directly to the SQ ring buffer and, optionally, rings a doorbell (or the kernel polls the SQ). The kernel processes the request through blk-mq and NVMe, and writes a Completion Queue Entry (CQE) to the CQ. No system calls are needed on the fast path — the application can submit and complete I/O entirely through shared memory. `io_uring` with NVMe achieves near-SPDK performance (within 10-20%) while retaining kernel-mediated security and device management, making it the preferred high-performance I/O interface for applications that cannot adopt SPDK's full kernel bypass model. The combination of blk-mq's per-CPU queues and `io_uring`'s shared-memory rings creates an I/O path where data movement is DMA, command submission is a memory write, and completion polling is a memory read — no context switches, no interrupts, no system calls.

## 14. Summary

NVMe transformed the storage landscape by replacing the serial, single-queue SCSI/SATA model with a massively parallel, multi-queue model designed for flash memory. The 64-byte command format, the paired SQ/CQ architecture, and the flash-native command set eliminate the protocol bottlenecks that made SSDs underperform. SPDK takes this further by moving the NVMe driver into user space, achieving microsecond-latency I/O on commodity hardware. NVMe-over-Fabrics extends the model across the network, enabling disaggregated storage with near-local performance. As storage-class memories and CXL-attached devices close the gap between storage and memory, NVMe's flexible, high-performance command interface will continue to be the foundation of the storage hierarchy for years to come.

## 15. The NVMe Computational Storage Command Set

The NVMe Computational Storage specification enables SSDs to execute user-provided code directly on the drive, near the data. Instead of transferring data over the PCIe bus to the host CPU, processing it, and writing the results back, the host sends a "compute" command to the SSD with a pointer to the program and the data. The SSD controller executes the program on its embedded processors (typically ARM cores), accessing the data locally on the flash, and returns only the results. This reduces data movement dramatically — for a database query that filters 99% of rows, only 1% of the data traverses the PCIe bus.

The computational storage command set defines a standard interface for downloading programs to the drive, invoking them on specified data ranges, and retrieving results. Programs can be pre-compiled binaries (e.g., eBPF bytecode, WebAssembly modules, or native ARM binaries) that are signed and verified by the SSD controller for security. The drive provides a sandboxed execution environment (similar to eBPF's verifier) that prevents the program from accessing data outside its designated range or from interfering with other drive operations.

Use cases for computational storage include: database acceleration (filtering rows, evaluating WHERE clauses on the drive), video transcoding (decoding and re-encoding video streams on the drive, reducing host CPU and PCIe bandwidth), and AI inference (running neural network models on the drive to classify or transform data before it reaches the host). Computational storage is still in its early stages, with NVMe 2.0 providing the standard and early products (Samsung SmartSSD, ScaleFlux CSD) demonstrating the concept. It represents a shift from "dumb block storage" to "programmable storage" — the same shift that user-space networking brought to packet processing.

## 16. The NVMe Key-Value Command Set

The NVMe Key-Value (KV) command set, introduced in NVMe 2.0, replaces the block-based interface (read block 5, write block 12) with a key-value interface (get "user123", put "user123" = <data>). The KV command set maps naturally to how applications think about data (objects identified by keys) and eliminates the need for the host to manage block allocation and garbage collection. The SSD controller handles these tasks internally, using its knowledge of the flash geometry to optimize data placement.

The KV commands include: `Store` (write a key-value pair), `Retrieve` (read the value for a key), `Delete` (remove a key), `Exists` (check if a key exists), and `List` (enumerate keys). Keys are variable-length byte strings (up to 64 KB). Values are variable-length (up to the drive capacity). The SSD controller maintains an internal index (typically an LSM-tree or B-tree) mapping keys to physical flash locations, similar to how a filesystem maps file names to blocks.

KV SSDs simplify host software dramatically. A database that currently maps SQL rows to pages using a B-tree can offload the key-value mapping to the SSD. The database sends `Store` with the row key and the serialized row data; the SSD handles placement, wear leveling, and garbage collection. The database's storage engine becomes a thin layer that translates SQL queries to KV operations. This "computational storage" model — pushing data management into the storage device — is the logical endpoint of the NVMe philosophy: move intelligence closer to the data.

## 17. Summary

NVMe transformed the storage landscape by replacing the serial, single-queue SCSI/SATA model with a parallel, multi-queue model designed for flash. The NVMe command set, the SQ/CQ architecture, and flash-native features like Trim and ZNS enable SSDs to achieve their full performance potential. SPDK moves the NVMe driver to user space for microsecond-latency I/O. NVMe-over-Fabrics extends the model across the network. Computational storage and KV commands push intelligence into the drive. NVMe is not just a faster SCSI — it's a fundamentally different way of thinking about storage, built for the era of non-volatile memory.

## 18. NVMe and CXL: The Convergence of Storage and Memory

NVMe is converging with CXL (Compute Express Link) to create a unified interface for storage and memory. CXL.mem allows processors to access storage-class memory (like Optane or future persistent memory) via load/store instructions, with cache coherence maintained by the CXL protocol. NVMe over CXL (NVMe/CXL) defines how NVMe commands can be transported over CXL.io (the CXL I/O protocol), combining NVMe's rich command set with CXL's low-latency, cache-coherent transport.

The convergence of NVMe and CXL blurs the line between storage and memory. A CXL-attached device can serve as both a block device (accessed via NVMe commands) and a memory region (accessed via load/store). Applications can choose the access model that best fits their data: large, sequential data (video, logs) via NVMe commands; small, random data (indexes, metadata) via load/store. This flexibility is the culmination of the NVMe vision: storage and memory are points on a continuum, and the interface should adapt to the data's position on that continuum.

## 19. Summary

NVMe transformed the storage landscape by replacing the serial SCSI/SATA model with a parallel, multi-queue model designed for flash. The NVMe ecosystem — from hardware (NVMe SSDs, NVMe-oF fabrics) to software (SPDK, blk-mq) to emerging standards (computational storage, KV commands) — provides a comprehensive storage architecture for the era of non-volatile memory. As NVMe and CXL converge, the distinction between storage and memory becomes increasingly artificial. The future is a unified memory-storage hierarchy, accessed through NVMe commands or load/store instructions as the application requires. NVMe is not just a faster SCSI — it's the foundation of the next-generation storage architecture.
