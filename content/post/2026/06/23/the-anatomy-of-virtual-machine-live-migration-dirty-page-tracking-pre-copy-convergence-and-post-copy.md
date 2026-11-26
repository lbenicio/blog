---
title: "The Anatomy of Virtual Machine Live Migration: Dirty-Page Tracking, Pre-Copy Convergence, and Post-Copy Demand Faulting"
description: "A deep dive into how hypervisors move running virtual machines between hosts: what state must be transferred, how dirty-page tracking works from shadow page tables to EPT dirty bits and PML, why pre-copy converges or fails to, and how post-copy trades failure semantics for downtime."
date: "2026-06-23"
author: "Leonardo Benicio"
tags: ["virtualization","live migration","KVM","QEMU","memory management","systems design","concurrency"]
categories: ["Systems","Virtualization"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/the-anatomy-of-virtual-machine-live-migration-dirty-page-tracking-pre-copy-convergence-and-post-copy-2026-06-23.jpg"
coverAlt: "Isometric technical illustration showing a virtual machine migrating between two servers, with memory pages streaming across a network boundary in repeated rounds that shrink over time, ending in a short final pause."
---

# The Anatomy of Virtual Machine Live Migration: Dirty-Page Tracking, Pre-Copy Convergence, and Post-Copy Demand Faulting

## Introduction

Live migration is the operation of relocating a running virtual machine — its CPU state, its memory, its device state, and its identity on the network — from one physical host to another while the guest continues to execute and its clients continue to receive service. It is one of the few features of modern virtualization that is simultaneously a distributed-systems problem, a memory-management problem, and a scheduling problem, and it is the substrate on which a great deal of cloud operational machinery rests: hardware maintenance, bin-packing and consolidation, power management, hardware refresh, and failure evacuation all reduce to the same primitive — *move this VM somewhere else without breaking it*.

The reason live migration is interesting rather than merely useful is that it is a race. The guest is mutating its own state — writing memory, advancing the instruction pointer, updating device registers — while the hypervisor is trying to serialize and transmit that state. The guest is not cooperating. It does not know it is being moved, and the entire design of migration is about making that ignorance survivable. Every technique in this space is a variation on one of three ideas: copy state early and re-copy what changed, stop the guest for as short a time as possible, or let the destination pull state lazily after the guest has already resumed there.

This article uses KVM and QEMU as the concrete reference implementation, because it is open, widely deployed, and its design decisions are visible in the source. The concepts generalize. Xen, Hyper-V, and ESXi all solve the same problems with different primitives, and the trade-offs they encounter are structurally identical.

The organizing question throughout is this: *what can be moved while the guest is running, what must be moved while it is stopped, and how do you shrink the second category?* Everything else — dirty bitmaps, page modification logging, userfaultfd, virtio state serialization, TSC offsets — is machinery in service of that question.

## What Actually Has to Move

It is tempting to think of a virtual machine as "a disk and some RAM," but the migratable state of a VM is more layered than that, and the layers have very different transfer characteristics.

**CPU architectural state.** This is small — on the order of a few kilobytes to a few tens of kilobytes per vCPU. It includes the general-purpose registers, control registers, segment descriptors, the floating-point and SIMD register file (which is the bulk of it on modern x86-64), debug registers, model-specific registers (MSRs), and the state of the local APIC. It is small enough that transferring it is never the bottleneck, but it is *not* trivial to capture correctly: MSRs include performance counters, machine-check state, and the syscall entry/exit MSRs that a guest kernel may have configured. Getting this wrong produces a guest that resumes with subtly wrong behavior rather than one that crashes outright.

**Memory.** This is the dominant term, and it is the reason live migration is a hard problem at all. A VM may have anywhere from a few hundred megabytes to multiple terabytes of guest-physical memory. The hypervisor must transfer the *contents* of that memory, and the contents change continuously.

**Device state.** Emulated devices have internal state that must be reconstructed on the destination: virtio ring base addresses, queue sizes, feature negotiation results, and the state of in-flight descriptors; the internal registers of an emulated NIC or storage controller; interrupt controller routing tables. For *emulated* devices this state lives in the hypervisor and can be serialized directly. For *passthrough* devices — a physical NIC or GPU assigned to the guest via VFIO — the state lives in hardware, and whether it can be captured at all depends on the device and the platform.

**External state.** The VM's identity on the network (its MAC address, its IP address, its position in the L2 topology) and its attachment to storage. Storage is usually handled by the fact that both source and destination can reach the same shared volume, so nothing needs to move. Network identity is handled by re-announcing the MAC at the destination — typically a gratuitous ARP or its IPv6 equivalent — so that switches relearn the forwarding path. This is not a hypervisor mechanism so much as a coordination protocol between the hypervisor and the network fabric, and it is where many real-world migration outages originate.

**Time.** The guest's notion of time must be continuous across the migration. The timestamp counter (TSC), the various timer devices, and the wall-clock offset all need attention. If the destination CPU has a different TSC frequency or an unsynchronized TSC epoch, the hypervisor must either scale and offset the TSC presented to the guest or fall back to a paravirtualized clock. A guest that observes time going backwards can deadlock in its own timer subsystem, so this is a correctness requirement rather than an optimization.

The practical consequence of this breakdown is that essentially all migration engineering effort goes into memory, with a secondary amount going into device and time state, and almost none into CPU registers.

## The Downtime Budget and the Stop-and-Copy Baseline

Before examining the clever techniques, it is worth establishing the naive baseline, because every refinement is measured against it.

*Stop-and-copy* migration works exactly as it sounds. The hypervisor pauses the VM, copies its entire memory image and all device and CPU state to the destination, and resumes execution there. The downtime is:

```
downtime_stop_and_copy = M / B + state_transfer
```

where `M` is the resident memory footprint and `B` is the effective bandwidth of the transfer path. For a 64 GiB VM on a 10 Gbit/s link, the memory term alone is on the order of a minute — far beyond any interactive service's tolerance. Even on a 100 Gbit/s link, tens of gigabytes take seconds to move. Stop-and-copy is only viable for small VMs or extremely fast interconnects.

The operational metric that matters is not total migration time but **downtime** — the interval during which the guest is not executing. Total migration time affects how long the source host must reserve resources and how long the operation is exposed to failure; downtime affects whether clients time out. These two objectives are in tension, and the pre-copy and post-copy families sit at different points on that trade-off curve.

A useful way to frame the whole design space is as a spectrum:

| Strategy | Downtime | Total time | Failure semantics |
|---|---|---|---|
| Stop-and-copy | `M / B` | `M / B` | Clean rollback |
| Pre-copy | Small, if convergent | Large, unbounded if not | Clean rollback until commit |
| Post-copy | Near-constant | Small | Source failure is fatal |
| Hybrid | Tunable | Tunable | Depends on switch point |

The rest of the article is largely an elaboration of that table.

## Pre-Copy: Iterative Transfer Under a Running Guest

Pre-copy migration, introduced for process migration in the 1990s and adapted to VMs in the 2000s, exploits a simple observation: most of a VM's memory does not change during any given interval. Copy all of it once while the guest runs, then figure out which pages changed during the copy, and copy only those. Repeat until the set of changed pages is small enough that copying it takes less time than the acceptable downtime.

The algorithm, in its idealized form:

1. Start the guest on the source.
2. Enable dirty-page tracking.
3. Copy the entire memory image to the destination (the *bulk round*).
4. Read and clear the dirty bitmap, which now describes pages written since the previous round began.
5. Copy those pages.
6. If the dirty set is below a threshold, or a round limit has been reached, go to step 7. Otherwise go to step 4.
7. Pause the guest, copy the remaining dirty pages, transfer CPU and device state, resume on the destination, and release the source.

Step 7 is the *stop-and-copy phase*, and its duration is the downtime. The final dirty set is small because the guest was paused before it was computed, so no new dirty pages can appear during the transfer.

### Convergence and the Dirty-Rate Problem

The critical property of pre-copy is that it converges only under a condition on the guest's write rate. Let `R` be the rate at which the guest dirties memory (bytes per second) and `B` the transfer bandwidth. Suppose round `i` transfers `D_i` bytes. The guest dirties roughly `R * (D_i / B)` bytes during that transfer, so:

```
D_{i+1} ≈ R * D_i / B = (R/B) * D_i
```

The dirty set shrinks geometrically when `R < B` and grows when `R > B`. This is the whole story. A guest whose write rate exceeds the available bandwidth will never converge; the migration will run forever, transferring the same pages repeatedly, until a round limit forces a stop-and-copy with a correspondingly enormous downtime — or until the operator gives up and aborts.

The total bytes transferred in the convergent case is a geometric series:

```
total ≈ M * B / (B - R)
```

which is a useful mental model: as `R` approaches `B` from below, total traffic blows up even though the migration technically converges. A migration where `R = 0.9 B` moves ten times the VM's memory footprint.

This has an important operational implication: **the interesting variable is not the size of the VM, it is the ratio of its write rate to the migration bandwidth.** A 512 GiB database that is mostly read from cache may migrate faster than a 4 GiB in-memory cache server that is being hammered by writes. Capacity planning for migration is really capacity planning for dirty rates.

### When Convergence Fails

There are three responses to a non-convergent guest, and real hypervisors combine all three.

**Throttle the guest.** If the vCPUs are forced to run less often — via scheduler throttling, or by reducing the guest's CPU share — the dirty rate falls. QEMU exposes this as `downtime-limit` combined with `cpu-throttle-initial` and `cpu-throttle-increment`: when a round fails to reduce the dirty set by a sufficient factor, the vCPUs are throttled by a percentage, and the throttle is increased on each subsequent failure. This is effective but it is a direct tax on the guest's throughput, and for a latency-sensitive workload it can be worse than the migration itself.

**Increase the bandwidth.** More parallel sockets, RDMA instead of TCP, or simply a faster link. This attacks the denominator of `R/B` and is usually the cheapest fix when the fabric allows it.

**Give up on pre-copy.** Switch to post-copy, which does not require the dirty rate to be below the bandwidth at all. This is the escape hatch, and it is why post-copy has become the default in several production systems despite its less forgiving failure semantics.

### Where the Dirty Information Comes From

None of the above works without an accurate and cheap answer to "which pages did the guest write?" This is the part of live migration that has changed the most over the last fifteen years, and it is worth understanding the progression, because each step removed a different bottleneck.

**Shadow page tables with write protection.** The original approach, used by Xen and early KVM, was to maintain shadow page tables that map guest-virtual to host-physical addresses, mark them read-only, and take a page fault on the first write to each page. The fault handler marks the page dirty in a bitmap, makes the page writable in the shadow table, and resumes the guest. This works, but it requires the hypervisor to be in the address-translation path for every guest page table modification, and it costs a trap per *first write* to each page per round. On a workload that touches many pages, the trap rate is enormous.

**Hardware-assisted dirty bits.** With Intel's EPT and AMD's NPT, the guest's page tables are used directly and the hardware walks a second-level table that the hypervisor controls. Both architectures provide access and dirty bits in the second-level entries. To track dirty pages, the hypervisor clears the write permission from the EPT entries for the range being tracked and enables dirty logging. A guest write then causes an EPT violation — a VM exit — and the handler marks the page dirty in a bitmap and restores write permission. This eliminates the shadow-page-table maintenance cost but retains the per-page, per-round VM exit.

**Page Modification Logging (PML).** Intel added PML to reduce the exit count. When enabled, the processor writes the guest-physical address of a modified page into a buffer in host memory rather than exiting immediately, and only exits when the buffer fills. The hypervisor drains the buffer in bulk. This converts a per-page exit into a per-buffer exit, which is a substantial reduction in VM exit pressure for write-heavy guests.

**The dirty ring.** The bitmap itself became a bottleneck. A bitmap covering a terabyte of guest memory at 4 KiB granularity is 256 MiB, and the hypervisor must scan and clear it every round — a cost that is pure overhead and scales with VM size rather than with change volume. KVM's `KVM_DIRTY_RING` interface replaces the bitmap with a ring buffer of dirty page addresses that the kernel writes and userspace consumes, which removes the scan and makes the per-round cost proportional to the number of dirty pages rather than the size of the address space.

Each of these steps is a response to a specific measurement: traps, then exits, then bitmap scanning. The pattern is common in systems work — the mechanism that makes the feature possible becomes the bottleneck once the feature is made fast.

### What the Guest Sees

Throughout the pre-copy rounds, the guest runs normally on the source. It has no visibility into the fact that its pages are being copied, with one exception: the write-protection required for dirty tracking causes EPT violations that are transparent to the guest but not free. The guest's throughput drops during migration, sometimes substantially, and the drop is workload-dependent in ways that are hard to predict from VM size alone. A guest that writes to a large working set will experience more violations than one that writes to a small one, even if their total write volumes are identical.

This is the first place where the interaction between migration and the guest's own performance becomes visible, and it sets up the central tension of the post-copy approach: the mechanisms that reduce downtime tend to increase the guest's observed cost, either during the migration or after it.

## Post-Copy: Inverting the Direction of State Transfer

Pre-copy migration assumes the destination is a passive sink: it receives pages, acknowledges them, and does nothing with the guest until the source says the final round is complete. Post-copy reverses that relationship. The destination becomes active before all memory has arrived, and the source remains alive as a page server. At the switch, the source pauses the guest, transfers CPU state, device state, and enough metadata to identify every missing page, and then the destination resumes the guest. Remaining guest-physical pages are marked not-present in the destination's second-level page tables. When a vCPU touches a missing page, the destination takes a fault, requests the page from the source over the migration channel, installs it, and resumes the vCPU.

The appeal is straightforward. Neither downtime nor total migration time depends on the guest's write rate in the way pre-copy does. Downtime is the time to transfer CPU and device state plus the time to establish fault handling; memory size affects total transfer time only insofar as pages are actually touched. A large VM running a small working set can resume in milliseconds and then fetch a few hundred megabytes over the following minutes. This is the opposite of pre-copy's convergence condition: post-copy does not require `R < B`, because pages are not copied until they are demanded. But it converts a bandwidth problem into a latency problem, and it gives up the clean rollback that makes pre-copy operationally forgiving.

### The Resume-Before-Transfer Contract

The switch is more delicate than pre-copy's final stop-and-copy phase because the destination must be able to handle faults immediately after it resumes. The source must quiesce the guest, capture vCPU and device state, and hand the destination enough metadata to identify every missing page. Then the destination starts the vCPUs. Any memory access to a page that has not yet arrived must trap into the hypervisor and then, typically, into userspace.

In KVM and QEMU this is commonly implemented with `userfaultfd`. QEMU registers the guest RAM region with `userfaultfd` before resuming. Pages that have not arrived are left unmapped, or mappings are removed and the range is registered. When the guest accesses a missing page, KVM exits to QEMU. QEMU determines that the address belongs to a registered range and blocks the vCPU thread until the page is supplied. It sends a page request on the migration stream; the source reads the page from its copy of guest memory and returns it; QEMU installs the page with `UFFDIO_COPY`; the vCPU resumes. The fault is transparent to the guest, but it is not free.

The contract has sharp edges. Device state cannot be demand-paged in the same way. An emulated NIC's ring pointers and in-flight descriptors must be present when the guest resumes; virtio queues must be reconstructed; interrupt state must be correct before the first interrupt is delivered. Passthrough devices complicate the picture because their state lives in hardware that the source cannot serve page-by-page. CPU state is always transferred before resume. Time state must be established before the first instruction. Post-copy is therefore not lazy everything; it is lazy guest RAM and eager everything else.

### Fault Cost, Fault Storms, and Amplification

Each demand fault costs a VM exit, a userspace wakeup, a request-response round trip over the network, and a page installation. If the guest touches pages sequentially at a high rate, a vCPU can spend most of its time waiting. Multiple vCPUs faulting at once can queue requests and turn the fault path into a concurrency bottleneck. Page granularity matters as well: 4 KiB pages mean that a 2 MiB huge page's worth of data requires 512 faults if the transfer is not coalesced. Hypervisors try to preserve huge pages where possible or prefetch adjacent pages to avoid this amplification.

Write faults are not fundamentally different from read faults in demand paging. The destination must fetch the page before the write can complete, because it cannot allocate a zero page and discard the source's contents. A workload that performs many scattered writes across a large memory footprint can therefore generate nearly one network round trip per page touched. The source page server must sustain that request rate while its guest is stopped, and it must do so without starving the migration control path.

### Prefetching and the Page Server

To hide latency, the destination prefetches. A simple policy fetches pages adjacent to the faulting page, or tracks fault history and fetches pages from the same region. Prefetching must avoid wasting bandwidth on pages that will never be touched, and it must handle races: a prefetched page may arrive after the guest has already faulted on the same page. The destination needs to deduplicate in-flight requests and ignore duplicate responses. Once a page is present, the guest may write it, making the source's copy stale. The protocol must ensure that the source never sends a later version that overwrites the destination's newer page. Since the source guest is stopped after the switch, source memory is frozen; the destination is the only writer. Once a page is on the destination, it is authoritative, and requests for already-present pages can be satisfied locally or dropped.

The source acts as a page server: it answers requests for arbitrary guest-physical addresses, usually by reading from its copy of guest RAM and sending the page over the migration stream. It may keep a bitmap of pages already sent to avoid duplicate transfers, though duplicate transfers are correctness-safe if the destination ignores stale copies. The migration stream becomes bidirectional: the destination sends requests, and the source sends pages. Flow control is required so that the destination does not overrun the source or the network, and some implementations use a separate fault channel rather than multiplexing requests onto the main migration stream.

### Failure Semantics: The Irreversibility Cost

Post-copy's central drawback is failure semantics. Before the switch, pre-copy can abort and the source resumes. After the switch and after the destination has resumed, the source cannot simply resume because the destination may have modified pages; the source's memory image is stale for those pages. If the source fails, the destination may be missing pages that only the source had, causing an unrecoverable guest stall or crash. If the destination fails, the source may still have most pages but lacks the destination-modified pages; resuming the source would lose writes and could corrupt the guest. There is no clean rollback unless the system maintains a checkpoint or replicates memory.

This changes operational assumptions. Post-copy migration should be attempted only when the source is expected to remain healthy and reachable for the duration, the network is reliable, and the destination has enough capacity. In cloud environments with redundant network paths and short migration windows, that is often acceptable. In environments with unreliable hosts or long transfers, it can be dangerous. Some systems mitigate the risk by keeping the source alive as a hot standby until migration completes, but that does not solve the split-write problem unless destination writes are logged or source memory is kept coherent.

The failure model also affects orchestration. A pre-copy failure is usually a non-event: abort, clean up the destination, and continue. A post-copy failure may require killing the VM and restarting it from disk, losing in-memory state. SLAs must account for that. The trade-off is explicit: post-copy buys bounded downtime and bounded total time by giving up rollback.

### Hybrid Migration and the Switch Point

Most production systems do not choose pure post-copy; they use a hybrid. Pre-copy runs first, transferring bulk memory and reducing the dirty set while the guest runs. If pre-copy converges, the migration finishes with a normal stop-and-copy. If the dirty rate remains high after a configured number of rounds, the system switches to post-copy: it pauses the guest, transfers CPU and device state plus remaining memory metadata, resumes the destination, and lets it demand-fault the rest. This retains a rollback window during pre-copy and bounds total time when convergence fails.

The switch point is a policy decision. Too early, and post-copy faults dominate the migration's cost. Too late, and pre-copy has already wasted time and bandwidth on a dirty set that will not shrink. Heuristics include the size of the dirty set, the number of rounds, the measured dirty rate versus bandwidth, and the guest's latency sensitivity. Hybrid also allows a prefetch phase after the switch: the destination can fetch pages from the source in the background while handling faults, reducing average fault latency. The migration is still post-copy for failure purposes once the guest resumes, but the pre-copy phase may have already transferred most pages, shrinking the window of irreversibility.

### Device and Time State at the Switch

Because only RAM is demand-paged, all non-memory state must be transferred at the switch. Emulated device state includes virtio queue addresses, available and used indices, feature bits, and in-flight descriptor state. Interrupt controller state includes pending interrupts and routing. If the guest resumes and an interrupt is delivered before the corresponding device state is present, it may observe impossible conditions. The hypervisor must order the switch carefully: stop the guest, quiesce devices, serialize state, transfer it, restore it, and resume the vCPUs with interrupts masked until the state is complete. Device DMA is a special concern. A device may write to guest memory while migration is switching. The hypervisor must stop DMA or track it; otherwise a page may be modified at the source after the destination has resumed, violating the frozen-source assumption. This is one reason passthrough devices are usually excluded from post-copy.

Time state must also be handled before the first instruction. The destination's TSC must be adjusted to match the guest's expected epoch, or the guest must use a paravirtualized clock. If the guest reads the TSC before adjustment, it may see time jump backwards or forwards and break its timer subsystem. The hypervisor typically records a TSC offset at the switch and applies it. Post-copy does not make this easier; it makes it more urgent, because the guest may resume before memory is fully available, so any early time-based operation must not fault on missing pages unnecessarily.

## The Migration Stream as a Protocol

A live migration is not a single `memcpy` with a network socket attached. It is a small distributed protocol with its own framing, version negotiation, state serialization, flow control, and failure paths. QEMU's migration stream is a useful concrete example because it exposes the layers that other hypervisors also need, even when their wire formats differ.

At a high level, the stream begins with a handshake. The source and destination agree on the transport, the migration capabilities that both sides support, and the machine type and device model versions that will be instantiated on the destination. This compatibility negotiation is not incidental. A guest that was running on a particular virtual chipset, a particular CPU model, and a particular set of virtio feature bits must resume on a destination that presents the same virtual hardware. If the destination negotiates a newer device feature or a different CPU model, the guest may observe a hardware change across what is supposed to be an invisible relocation. Production systems therefore pin migration compatibility to a machine type and a CPU model, and they treat changes to either as a guest-visible event that requires a reboot or a cold migration.

After the handshake, the stream is organized into sections. Each section describes a piece of state: the migration header, the configuration, CPU state, RAM, device state, and a terminating marker. Sections are framed with a type and a length so that the receiver can skip or reject state it does not understand. Versioning is handled at the section level and at the device level. The `VMState` descriptions used by QEMU devices are essentially schema definitions: they declare the fields, their sizes, and the versions in which those fields appeared. When a device gains a new register or a new field, the schema gains a version, and the migration code decides whether the field is present based on the negotiated version. This is why live migration across QEMU releases is possible at all, and why it is bounded: the further apart the versions, the more compatibility shims are required.

The RAM portion of the stream is where most of the bytes go, and it is usually the most optimized part. Pages that are all zero can be represented compactly rather than transmitted in full. Pages that compress well can be compressed, at the cost of CPU time on both ends. The stream can be encrypted with TLS, which protects guest memory in transit but adds framing and cryptographic overhead that reduces effective bandwidth. Transport selection matters: TCP over a routable network is the default, but RDMA and shared-memory transports are used where the fabric supports them, and multiple parallel channels are used to overcome the single-flow throughput limits of TCP.

That last point deserves emphasis. A single TCP flow often cannot saturate a fast link because of window limits, congestion control, and per-flow CPU costs. QEMU's multifd capability splits RAM transfer across several sockets, each with its own thread, so that the aggregate throughput scales with the number of channels. The dirty bitmap or dirty ring is partitioned accordingly, and each channel is responsible for a subset of the guest-physical address space. This changes the concurrency model of migration: the source must coordinate multiple senders, the destination must reassemble pages from multiple receivers, and flow control must operate across all of them rather than on one socket.

Post-copy adds a second logical channel. The main migration stream carries the bulk pages, while a fault channel carries page requests from the destination back to the source. Some implementations multiplex requests onto the main stream; others use a separate connection. Either way, the protocol becomes bidirectional, and the source must be able to serve requests for arbitrary guest-physical pages while also finishing the bulk transfer. Flow control is required so that a fault storm on the destination does not overwhelm the source's page server or starve the control path that reports migration progress.

## Huge Pages, Granularity, and the Cost of Tracking

Dirty tracking is usually described at 4 KiB granularity, but modern guests and hypervisors prefer larger mappings. A 2 MiB huge page reduces TLB pressure, reduces page-table walk depth, and improves memory throughput for workloads with large working sets. The same large mapping complicates migration, because the tracking mechanism and the transfer mechanism may not operate at the same granularity.

Hardware dirty bits are set at the granularity of the second-level page-table entry. If that entry maps a 2 MiB page, a single write anywhere in the page marks the whole 2 MiB region dirty. The hypervisor can either transfer the whole huge page or split it into 4 KiB pages so that only the written subpages move. Splitting is expensive: it requires allocating lower-level page tables, invalidating translations, and potentially breaking a mapping that the guest was benefiting from. Not splitting is simpler but can inflate the dirty set by a factor of 512 when the guest touches only a few bytes in each huge page. The right choice depends on the workload. A sparse writer benefits from splitting; a sequential writer that touches most of each huge page does not.

Page Modification Logging and the dirty ring both record guest-physical addresses. PML records the address of the modified page, but the granularity is still the architectural page size used by the translation. The dirty ring accepts entries from both hardware-assisted tracking and software paths, and it can coalesce or filter entries before userspace consumes them. Neither mechanism eliminates the fundamental trade-off: larger pages are cheaper to map and transfer but coarser to track.

Post-copy makes granularity visible in a different way. A demand fault is taken at the page size that the destination has mapped. If the destination installs a 4 KiB page because only that subpage was requested, it loses the benefit of a huge mapping for that region. If it installs a 2 MiB huge page, it must fetch the entire 2 MiB before the faulting instruction can retire, which increases fault latency but reduces the number of faults. Prefetching adjacent pages is the usual compromise: fetch a small cluster around the fault, install it as small pages, and let the guest's own behavior determine whether the region is later promoted to a huge page. Some systems attempt to reconstruct huge pages after the migration completes, using `MADV_HUGEPAGE` or explicit huge-page backing, but that is a background optimization rather than part of the fault path.

Memory sources matter as well. Anonymous memory backed by transparent huge pages behaves differently from memory backed by `hugetlbfs`, and both differ from a file-backed mapping. Hugetlbfs pages are reserved before the guest starts, so the destination must have a matching reservation or the migration cannot complete. File-backed memory can sometimes be reconstructed from the shared storage rather than transferred, but only if the destination can reach the same file and the guest has not modified private copies. The migration code has to know which pages are authoritative in RAM and which can be dropped or re-read.

## Consistency at the Edge: DMA, Ballooning, and Guest Cooperation

Pre-copy and post-copy both assume that the hypervisor can observe every write to guest memory. For vCPU writes, the second-level page tables provide that observation. For device DMA, the picture is less uniform. An emulated device that writes through QEMU is easy to instrument: the write goes through QEMU's address space, and the migration code can mark the page dirty. A passthrough device that writes directly to guest memory bypasses the hypervisor entirely. The IOMMU may be able to log or fault on those writes, but support varies by platform and by device. This is one reason passthrough devices are usually excluded from post-copy and are handled carefully even in pre-copy. If a device can write a page after the source has been frozen, the destination's copy may be stale, and no amount of page-table dirty tracking will catch it.

The guest can also participate, deliberately or accidentally. The virtio balloon driver tells the guest to inflate or deflate its memory footprint, and the pages it releases are not necessarily dirty in a way that matters. Free page reporting is similar: the guest reports pages that contain no useful data, and the hypervisor can avoid transferring them. These hints reduce migration traffic, but they are advisory. The guest may report a page as free and then reuse it immediately, and the hypervisor must handle the race. The safe pattern is to treat the hint as an optimization only after the page has been isolated or the guest has acknowledged the transfer.

Memory hotplug adds another edge case. If the guest's memory size can change during migration, the source and destination must agree on the final size before the stream is finalized. A hot-add that races with the migration may produce a page that exists on one side but not the other. Orchestrators usually quiesce memory hotplug during migration for this reason, or they serialize it through the same control plane that initiates the migration.

## NUMA, Topology, and Placement

The destination is not just a memory sink; it is a particular machine with a particular topology. A guest that was running on a two-socket host with memory interleaved across NUMA nodes may perform poorly if it resumes on a single socket with all memory local to one node. The hypervisor can present a virtual NUMA topology that matches the source, but the destination's physical topology may not match it. If the guest has been tuned for its vNUMA layout, the mismatch is visible as increased remote-memory access latency after migration.

CPU compatibility is the other half of placement. The destination must expose a CPU model that the guest can tolerate. Features that the guest has already detected and used must remain available, and features that the guest has not seen must not suddenly appear in a way that changes its behavior. The timestamp counter is especially sensitive. If the destination's TSC frequency differs, the hypervisor must scale the TSC or switch the guest to a paravirtualized clock. If the TSC epochs are unsynchronized, the hypervisor must apply an offset that preserves monotonicity from the guest's perspective. These adjustments are small in code but large in consequence: a guest that sees time move backwards can hang in its own timer subsystem.

## Observability and Failure Diagnosis

Live migration is easy to operate when it works and difficult to diagnose when it does not, because the interesting behavior is spread across the guest, the hypervisor, the network, and the destination's memory allocator. Useful observability starts with a small set of counters: the number of pre-copy rounds, the dirty rate per round, the bytes transferred per round, the number of pages skipped as zero or free, the downtime of the final stop, the total migration time, and the number of post-copy faults. These counters turn a vague report that migration is slow into a specific claim about whether the dirty set is shrinking, whether the network is saturated, or whether the destination is spending time allocating pages.

Tracepoints at the page-tracking layer are valuable because they expose the cost that the guest is paying. A spike in EPT violations during pre-copy suggests that the working set is large or that the write-protection granularity is too fine. A spike in post-copy fault latency suggests that the source page server is overloaded, that the network round-trip time is high, or that the destination is prefetching too aggressively and competing with demand faults. A migration that completes but leaves the guest with poor performance afterward may have lost huge pages, failed to restore NUMA affinity, or left the destination's memory fragmented.

Failure modes have signatures. Non-convergence shows a dirty set that stays flat or grows across rounds while total bytes transferred climbs. A bandwidth problem shows full send queues and long round times. A destination capacity problem shows allocation failures or swapping during page installation. A compatibility problem shows the migration failing during the configuration or device-state section rather than during RAM transfer. Distinguishing these signatures is the difference between an operator who can fix the migration and one who can only retry it.

## Security and Trust Boundaries in the Migration Channel

A live migration stream is one of the most sensitive data flows in a virtualized environment. It carries the guest's entire memory image, including cryptographic keys, session tokens, application data, and the contents of any in-memory database. It also carries CPU state, device state, and enough configuration to reconstruct the guest on the destination. An unencrypted migration stream on a shared network is therefore a data exfiltration path that bypasses every access control inside the guest. The guest cannot observe it, cannot encrypt it, and cannot refuse it.

The first line of defense is network isolation. Production deployments typically dedicate a separate VLAN or a point-to-point link for migration traffic, and they firewall it so that only hypervisors participating in the migration domain can reach the migration port. This reduces exposure but does not eliminate it: a compromised hypervisor on the same segment can still inject or intercept traffic. The second line is transport encryption. QEMU supports TLS on the migration stream, with certificate-based authentication of both endpoints. TLS protects confidentiality and integrity in transit, but it adds framing and cryptographic overhead, and it does not protect against a malicious destination that is authorized to receive the stream. Authorization is a policy question: the orchestrator must decide which hosts are allowed to receive which guests, and the destination must enforce that decision rather than trusting the source.

Post-copy makes the trust model more complex because the stream becomes bidirectional. The destination sends page requests to the source, and the source responds with pages. A malicious or compromised destination can request arbitrary guest-physical pages, including pages it was not supposed to receive, and the source page server will happily serve them unless it validates requests against the migration's metadata. The source must therefore authenticate the destination and bind the fault channel to the same session as the main stream. It must also rate-limit requests so that a fault storm cannot be used as a denial-of-service vector against the source.

Confidential computing raises the stakes further. With AMD SEV, Intel TDX, or similar technologies, guest memory is encrypted with a key that the hypervisor does not possess. The hypervisor can still schedule the guest and handle exits, but it cannot read guest memory. Live migration of such a guest requires the destination to be attested and to receive the encryption context through a secure channel. The migration stream may carry ciphertext, but the destination must be able to decrypt it, which means the key management and attestation infrastructure becomes part of the migration protocol. Dirty tracking still works because the hardware tracks writes at the second-level page table, but the hypervisor cannot inspect page contents to compress them, detect zero pages, or deduplicate them. Migration of confidential VMs is therefore less optimizable and more dependent on hardware support for encrypted state transfer.

## Storage Migration and the Shared-Storage Assumption

The earlier discussion assumed that source and destination can both reach the same storage volume. That assumption holds in many cloud and data-center deployments, where VM disks live on NFS, iSCSI, Ceph, or a SAN. It does not hold when the VM uses local disks, when the storage is replicated per host, or when the migration crosses a storage failure domain. In those cases, the disk image must move as well, and block migration becomes a second live-transfer problem layered on top of memory migration.

Block migration tracks writes to the virtual disk in much the same way that memory migration tracks writes to guest RAM. The source creates a mirror of the disk on the destination, copies the existing blocks, and then copies only the blocks that the guest writes during the copy. QEMU's block mirror job does this with a dirty bitmap at the block layer. The guest's writes are intercepted, recorded, and forwarded to both the source and destination copies until the mirror is complete. Once the disk is synchronized, the destination can take over as the authoritative copy.

The interaction between memory migration and block migration is subtle. If the disk is migrated first, the guest may continue writing to it, so the block mirror must remain active until the final switch. If memory migration finishes first, the guest resumes on the destination and may write to the disk before the block mirror has completed; the destination must be able to serve those writes while the mirror catches up. The safest ordering is to complete both migrations as close to the same switch point as possible, but that requires coordinating two independent dirty-tracking loops. In practice, orchestrators often perform storage migration as a separate, earlier phase, or they require shared storage for live migration and fall back to cold migration when it is unavailable.

Storage migration also changes the failure semantics. If the destination fails after the disk mirror has been established but before the final switch, the source can continue running on its original disk, but the mirror may have diverged. The source must be able to discard the mirror and resume normal operation. If the source fails, the destination may have a partially mirrored disk that is not a consistent point-in-time image. Block mirroring therefore needs its own checkpoints and rollback logic, and it can be the dominant cost of a migration when the disk is large and the guest is write-heavy.

Network identity is the third piece of external state. After the guest resumes on the destination, the network fabric must learn that the guest's MAC address is now reachable through a different switch port. The destination typically sends a gratuitous ARP or an IPv6 neighbor advertisement, and the switches update their forwarding tables. In a software-defined network, the orchestrator may instead update the control plane directly. If this step is missed or delayed, the guest may be running but unreachable, which is a common cause of migration-related outages. The migration is not complete until the network has converged.

## Migration with Accelerators and Passthrough Devices

Accelerators break the clean separation between migratable and non-migratable state. A GPU, FPGA, or smart NIC assigned to a guest has internal state that lives in hardware, not in the hypervisor's memory. Some of that state can be serialized through a vendor driver, but much of it cannot be captured without stopping the device and draining its queues. Live migration of a guest with a passthrough device is therefore either impossible or limited to devices that explicitly support it.

SR-IOV virtual functions are a common middle ground. The virtual function is assigned to the guest, but the physical function remains under the hypervisor's control. Some platforms provide IOMMU-based dirty tracking for DMA writes, which allows the hypervisor to know which pages the device has modified. This makes pre-copy migration possible in principle, because the hypervisor can include device-dirtied pages in the dirty set. In practice, support is uneven, and the device state at the switch must still be quiesced and restored. Post-copy is generally not possible with passthrough devices because the destination cannot serve a demand fault for a page that the device is about to DMA into.

Mediated devices and vendor-specific live migration solutions attempt to solve this by virtualizing the accelerator's state. The vendor driver intercepts device commands, maintains a software model of the device's state, and can serialize that state at the switch. The guest sees a virtual accelerator that supports migration, while the physical hardware is managed by the host. This works for some GPUs and some networking devices, but it adds a translation layer that can reduce performance and complicate the driver model. It also ties migration compatibility to a specific vendor and driver version.

The practical guidance in most production environments is to treat passthrough devices as non-migratable. VMs that need them are pinned to hosts, evacuated only with cold migration, and excluded from the live-migration pool. This is a scheduling constraint as much as a technical one: the orchestrator must know which VMs can move live and which cannot, and it must plan maintenance and failure evacuation accordingly.

## Benchmarking and Workload Characterization

Because migration performance depends on the guest's write behavior, benchmarking it with a single workload is misleading. A migration benchmark should measure at least four things: the guest's dirty rate under the workload, the effective migration bandwidth, the downtime of the final switch, and the guest's performance during and after the migration. The first two determine whether pre-copy converges. The third determines whether clients time out. The fourth determines whether the migration is operationally acceptable even if it completes.

Useful workloads span the space of memory behavior. An idle VM establishes the floor: almost no dirty pages, fast convergence, minimal downtime. A web server with a small working set and moderate write rate tests the common case. A database with a large buffer pool and a high write rate tests convergence limits. An in-memory cache with a huge working set and random writes tests the dirty-rate-to-bandwidth ratio directly. A VM running a memory bandwidth benchmark tests the tracking overhead itself, because it writes to a large fraction of its pages in every round.

The measurements should include the guest's own counters, not just hypervisor counters. A migration that reports a short downtime but causes the guest's application to miss its latency SLO has not succeeded. Tail latency is especially important: a post-copy fault can add hundreds of microseconds or milliseconds to a single memory access, and if that access is on a critical path, the application will notice. Pre-copy can also cause latency spikes because write-protection faults and vCPU throttling slow the guest during the rounds.

Benchmarking should also vary the migration parameters. The downtime limit, the number of pre-copy rounds, the switch-to-post-copy threshold, the number of multifd channels, and the compression settings all change the outcome. A migration configuration that works for one workload may fail for another, and the only way to know is to measure. The most useful output of a migration benchmark is not a single number but a curve: downtime as a function of dirty rate, total time as a function of memory size, and fault rate as a function of working-set size.

## The Orchestrator's View: Scheduling, Quotas, and Policy

The hypervisor provides the mechanism; the orchestrator provides the policy. It decides when a migration should happen, where the guest should go, and what constraints must be satisfied. A migration request is an admission-control problem: the destination must have enough free memory, compatible CPU features, matching storage access, and sufficient network bandwidth. If any of these is missing, the migration should be rejected before it starts rather than failing halfway through.

CPU compatibility is usually enforced by a cluster-wide CPU model. All hosts in a migration domain present the same virtual CPU features to guests, even if their physical CPUs differ. This is achieved by masking features that are not universally available. The cost is that guests cannot use newer instructions on hosts that support them, but the benefit is that any guest can move to any host. Some systems allow per-VM CPU models or a compatibility level that can be raised during a maintenance window.

Memory and NUMA constraints are next. The destination must have enough free memory to hold the guest, and ideally it should place that memory on the same NUMA nodes that the guest's vCPUs will use. If the guest has a virtual NUMA topology, the destination should map it to a physical topology with similar latency characteristics. Failing that, the orchestrator may accept a performance penalty, but it should record the decision so that operators can correlate migration events with later performance changes.

Bandwidth is the most dynamic constraint. A single migration can consume a large fraction of a host's network capacity, and several concurrent migrations can saturate a rack uplink. Orchestrators therefore limit the number of concurrent migrations per host and per network path, and they may reserve bandwidth for migration traffic. They also need to handle migration storms: a maintenance event that evacuates many VMs at once can create a thundering herd of migrations, each competing for the same bandwidth. Rate limiting and staggered scheduling are the usual mitigations.

Finally, the orchestrator must manage the lifecycle of a migration as a state machine. A migration can be pending, running, paused, failed, or completed. The source and destination must agree on the state, and the orchestrator must be able to clean up after a failure without leaving orphaned resources. If the migration is post-copy, the source must not be deallocated until the destination has all the pages it needs, and the orchestrator must keep the source reachable until the migration is formally complete. This is a distributed-systems problem in its own right, and it is where many operational bugs live.

## Live Migration at Scale: Fleet-Level Concerns

At fleet scale, live migration is not a rare event; it is a continuous background process. Hosts are drained for upgrades, VMs are rebalanced for power or performance, and failed hosts are evacuated. The aggregate effect is a steady stream of migrations that must be scheduled without disrupting the guests or overwhelming the network. This changes the design priorities. Individual migration latency matters less than the system's ability to make progress under load, and the orchestrator must be able to prioritize critical workloads over best-effort ones.

Fleet-level migration also exposes correlated risks. If a rack loses power, every VM on that rack must be evacuated, and the remaining hosts may not have enough capacity or bandwidth. If a network link fails during a migration, the source and destination may both believe they are responsible for the guest. The orchestrator needs a consensus mechanism or a lease to decide which side is authoritative. This is the same problem as split-brain in any distributed system, and it is solved with the same tools: quorum, fencing, and idempotent recovery.

Version compatibility becomes a fleet-wide concern during upgrades. A cluster may run multiple hypervisor versions, and a migration from an older source to a newer destination must preserve the guest's virtual hardware. Machine types and device versions are pinned to maintain compatibility, and upgrades are staged so that the migration domain is homogeneous. This is one reason live migration is often described as a compatibility problem disguised as a performance problem: the mechanism is fast, but the policy around it is conservative.

## Emerging Hardware and the Future of Dirty Tracking

The trajectory of dirty tracking is toward less hypervisor involvement and finer-grained hardware support. Intel's PML and AMD's equivalent mechanisms reduce VM exits by logging modified pages in a buffer. ARM's stage-2 translation tables include hardware dirty bits, and the architecture defines ways to manage them without trapping on every first write. RISC-V's hypervisor extension is following a similar path. The common goal is to let the hardware record writes at full speed and let the hypervisor consume the record in bulk.

The next step may be memory-side or fabric-side tracking. CXL and other coherent interconnects allow memory to be attached to a host through a switch, and they define protocols for cache coherence and error handling. If dirty tracking can be performed at the memory controller or the fabric, the hypervisor may not need to write-protect pages at all. That would eliminate the guest-visible overhead of pre-copy and make post-copy prefetching more efficient. It would also raise new questions about where the dirty information lives, how it is secured, and how it is synchronized across hosts.

Smart NICs and DPUs are another vector. They can offload the migration data path, encrypting and compressing pages, and they can maintain their own dirty bitmaps for device DMA. If the DPU also handles the network identity update and the storage mirror, then the hypervisor's migration logic becomes a control-plane problem rather than a data-plane one. This is attractive for scale, but it moves the trust boundary: the DPU must be trusted with guest memory, and its firmware becomes part of the migration's correctness surface.

Confidential computing will continue to shape the design space. Encrypted guests cannot be inspected by the hypervisor, so optimizations like zero-page detection, compression, and deduplication are unavailable unless the guest cooperates. Migration of confidential VMs therefore depends on hardware support for encrypted state transfer, attestation of the destination, and key management that does not expose guest secrets to the hypervisor. The dirty-tracking mechanisms remain the same, but the data path is opaque, and the performance model is different.

Persistent memory and CXL-attached memory add another layer. A guest may have memory-mapped persistent regions that are not ordinary RAM, and those regions may have their own coherence and flush semantics. Migrating such a guest requires either moving the persistent state or ensuring that the destination can attach to the same backing store. Dirty tracking for persistent memory is not the same as dirty tracking for anonymous RAM, because a write may need to be flushed before it is durable. The hypervisor must understand the memory type of each region and apply the appropriate migration policy. This is an active area of work, and it is likely to produce new primitives that do not look like the page-table-based tracking we have today.
