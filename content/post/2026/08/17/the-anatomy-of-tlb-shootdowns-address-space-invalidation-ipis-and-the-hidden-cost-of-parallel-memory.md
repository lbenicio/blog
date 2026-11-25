---
title: "The Anatomy of TLB Shootdowns: Address-Space Invalidation, IPIs, and the Hidden Cost of Parallel Memory Management"
description: "A deep dive into how operating systems keep translation caches coherent across cores: the hardware invalidation primitives, the IPI rendezvous, Linux's batching and lazy-TLB machinery, and why address-space changes scale so badly."
date: "2026-08-17"
author: "Leonardo Benicio"
tags: ["operating systems","parallel computing","virtual memory","x86-64","ARM64","linux kernel","performance engineering","memory management"]
categories: ["Systems","Parallel Computing"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/the-anatomy-of-tlb-shootdowns-address-space-invalidation-ipis-and-the-hidden-cost-of-parallel-memory-2026-08-17.jpg"
coverAlt: "Isometric illustration of a multi-core processor with one core broadcasting amber signal lines to all the others, above a translucent blue multi-level page-table diagram with a few entries marked as invalidated."
---

# The Anatomy of TLB Shootdowns: Address-Space Invalidation, IPIs, and the Hidden Cost of Parallel Memory Management

## A workload that gets slower as you add cores

Consider a service that runs on a 96-core machine. It has a hot path that periodically releases a large slab of scratch memory — tens of megabytes at a time — and then re-acquires it from the allocator. It uses `madvise(MADV_DONTNEED)` on a shared mapping, or `munmap` on a large region, or it runs a garbage collector that unmaps and remaps a heap arena. Single-threaded, the workload is fine. As you pin more threads to more cores and increase the release rate, throughput does not plateau — it *falls*. Wall-clock time per operation grows superlinearly with core count. The CPU utilization counters look unremarkable. The profiler attributes almost nothing to user code. The kernel shows up as a thin smear of `flush_tlb_mm_range`, `native_flush_tlb_others`, and `apic_timer_interrupt`-adjacent frames that no single sample dominates.

This is the signature of a TLB shootdown storm. It is one of the few costs in modern systems that gets *worse* as you add parallelism, that is invisible to most profilers, and that sits at the intersection of three things engineers usually reason about separately: the hardware translation cache, the operating system's memory-management bookkeeping, and inter-processor communication.

A TLB shootdown is the mechanism by which one CPU forces other CPUs to discard cached virtual-to-physical translations. It is not optional. It is not an optimization. It is a correctness requirement that falls out of the fact that the page table is a shared data structure and the TLB is a per-core cache of it. And because it is a *rendezvous* — a synchronous, all-targets-must-acknowledge event — its cost does not decompose the way most parallel work does.

This article is about the whole mechanism: the hardware primitives that make invalidation possible, the software protocol that coordinates it, the batching and filtering tricks that keep it tolerable, and the places in a modern kernel where it becomes the bottleneck. Along the way we will look at why x86 and ARM took different architectural paths, why `mm_cpumask` exists, why `INVLPG` is not a cheap instruction, and why the design of your allocator, your GC, and your runtime's thread model all show up in the shootdown statistics.

## Why a translation cache can be wrong

Every memory access on a modern processor goes through address translation. The page table is a radix tree — four or five levels on x86-64, three or four on ARM64 — that maps a virtual page number to a physical frame number plus permission bits. Walking that tree costs multiple dependent memory accesses. The TLB exists to avoid that cost: it is a small, fully associative or set-associative cache of recent translations, indexed by virtual page number (and, on many architectures, tagged by an address-space identifier).

The TLB is a cache, and caches are only sound if invalidation works. If the kernel changes a page table entry — remaps a page, revokes write permission, unmaps a region, migrates a page to a different physical frame — any TLB entry that still holds the old translation is *stale*, and a load or store that hits it will access the wrong physical memory or bypass a permission check. That is not a performance bug. It is a silent correctness violation, and it is exactly the class of bug that produces the worst kind of field report: a process reading another process's data, or a write landing in a page that was supposed to be read-only.

So the rule is absolute: **before a page table entry is reused for a different purpose, every TLB entry derived from the old value must be gone.** The kernel can achieve this in one of two ways. It can make the stale entry unreachable — for example by never reusing a physical frame or a virtual address — or it can explicitly invalidate it. In practice, systems do a mixture: the kernel keeps a small pool of "global" mappings that never change, and invalidates everything else.

The interesting engineering is entirely in the second option, because invalidation has to happen on *every* core that might hold the entry, and the kernel has no cheap way to know which ones those are.

## The two halves of invalidation

It helps to split the problem cleanly.

**Local invalidation** is the easy half. A core that is about to change a PTE can invalidate its own TLB entries directly, with an instruction. The cost is bounded and known.

**Remote invalidation** is the hard half. Other cores may have loaded translations from the same page table at some earlier point. They are running their own code, possibly with interrupts disabled, possibly in a tight loop, possibly in a hypervisor. The kernel must get them to invalidate, and it must know when they have finished, because the page table entry cannot be reused until they have.

The asymmetry is what makes TLB shootdowns interesting. Local invalidation is a few instructions. Remote invalidation is a distributed protocol with a rendezvous, a latency determined by the slowest participant, and a cost that grows with the number of participants. Everything that follows — the hardware primitives, the kernel's batching logic, the filtering heuristics — exists to shrink either the number of remote invalidations or the number of cores that have to participate in each one.

## Hardware primitives: what each architecture gives you

The instruction set determines the shape of the software protocol. Three families matter in practice.

### x86-64: local, explicit, and historically broadcast-free

x86-64 gives you two invalidation instructions and a side effect.

`INVLPG m` invalidates the TLB entry for the linear address `m` in the current address space. It is a local operation: it affects only the logical processor that executes it. It does invalidate global entries for that specific page (the `G` bit in the PTE does not protect a page from `INVLPG`), which is a detail that matters when you are reasoning about kernel mappings. `INVLPG` is also not cheap in the way a register write is cheap. On many microarchitectures it is a serializing-ish operation with a cost in the tens to low hundreds of cycles, and its cost depends on the state of the page-walk caches and the microarchitecture's TLB organization. Microbenchmark numbers vary enough across generations that the useful takeaway is qualitative: `INVLPG` is a real instruction with a real cost, and issuing one per page over a large range is a poor strategy.

Writing `CR3` is the blunt instrument. Historically, loading `CR3` flushes all non-global TLB entries, which makes address-space switches and full-range invalidations cheap to express but expensive to execute. Two architectural features changed that:

- **Global pages** (enabled by `CR4.PGE`) survive a `CR3` write. This is why the kernel's own mappings can stay resident across context switches, and why a user-space flush does not have to touch kernel translations.
- **PCID** (Process Context Identifier, enabled by `CR4.PCIDE`) tags TLB entries with a 12-bit identifier taken from the low bits of `CR3`. With PCID enabled, a `CR3` write does *not* flush by default; bit 63 of the value written to `CR3` is a "no flush" hint, and the processor keeps entries for other PCIDs live. This is what makes fast address-space switching possible, and it is also what makes `INVPCID` necessary: you now need a way to say "invalidate everything tagged with PCID 0x2A."

`INVPCID` takes a type operand that selects the granularity: individual address within a PCID, all entries for a single PCID, all entries including globals, and all entries excluding globals. Note the arithmetic consequence of PCID under KPTI-style page-table isolation: if you need two PCIDs per process (one for the user page table, one for the kernel page table), a 12-bit space covers roughly 2048 processes before you have to recycle identifiers — and recycling an identifier requires a flush.

Crucially, **none of these x86 instructions are broadcast.** A core that executes `INVLPG` changes only its own TLB. Remote invalidation on x86 has always been a software problem, solved with inter-processor interrupts. AMD has documented `INVLPGB`/`TLBSYNC` — a broadcast invalidation pair that lets a CPU invalidate translations on other CPUs in a domain without an IPI — and Linux support for it has been posted and is gradually landing, but the IPI path remains the baseline for the overwhelming majority of deployed x86 systems.

### ARM64: broadcast is in the ISA

ARM64 took the opposite approach. Its `TLBI` instructions carry a *domain* suffix. `TLBI VAE1IS, Xt` invalidates the translation for the virtual address in `Xt` and the current ASID, across the **inner shareable domain** — every processing element that shares the coherency domain, which in practice means every core in the socket or cluster. `TLBI VMALLE1IS` is the full-flush equivalent. The hardware does the broadcast; the kernel does not send IPIs.

That does not make invalidation free. It makes it *cheaper and more uniform*, and it changes the failure modes. A broadcast `TLBI` is still a synchronization event with ordering requirements — you need a `DSB ISH` on either side to get the memory-ordering semantics right — and issuing one per page over a large range is still a bad idea. ARMv8.4 added range-based invalidation (`TLBI RVAE1IS` and friends) with a scale field, which lets a single instruction cover a power-of-two-sized range of pages. That is a genuinely different design point from x86, where the kernel has to decide between one `INVLPG` per page and a full `CR3` reload.

ARM64 also tags TLB entries with an ASID, so a context switch between two address spaces does not inherently require a flush — the same idea as PCID, arrived at independently.

### RISC-V: explicit, minimal, and extensible

RISC-V's base privileged specification provides `SFENCE.VMA rs1, rs2`, where `rs1` is a virtual address and `rs2` is an ASID. Setting `rs1` to `x0` means "all addresses," and setting `rs2` to `x0` means "all ASIDs," so the single instruction covers the full range from one page to the entire TLB. Whether the invalidation propagates to other harts is left to the implementation and the platform's memory model; `SFENCE.VMA` is ordered with respect to the executing hart's subsequent accesses, and the platform specification defines what other harts observe.

The `Svinval` extension adds finer-grained control: `SINVAL.VMA` performs the invalidation without the full ordering fence, and `SFENCE.W.INVAL` / `SFENCE.INVAL.IR` let software batch a sequence of invalidations and pay the ordering cost once. This is the same idea as x86's batching heuristics, but exposed as an architectural primitive rather than implemented as a kernel policy.

### The shape of the difference

The table below summarizes the design space. The important column is the last one: whether the architecture can invalidate remote cores without software intervention.

| Architecture | Per-page | Full flush | Address-space tag | Remote broadcast |
|---|---|---|---|---|
| x86-64 | `INVLPG` | `CR3` write, `INVPCID` | PCID (12-bit) | No (IPI); AMD `INVLPGB` |
| ARM64 | `TLBI VAE1IS` | `TLBI VMALLE1IS` | ASID | Yes, inner shareable domain |
| RISC-V | `SFENCE.VMA` | `SFENCE.VMA x0, x0` | ASID | Platform-dependent |

This single architectural difference explains a lot of divergence in kernel memory-management code. On ARM64, the shootdown path is mostly about deciding *what* to invalidate. On x86, it is mostly about deciding *whom* to interrupt and how to avoid interrupting them at all.

## The rendezvous problem

Suppose the kernel has decided that a range of pages must be invalidated on every core that might have them cached. On x86, the sequence looks roughly like this:

1. The initiating core updates the page table entries.
2. It invalidates its own TLB entries for the range.
3. It determines the set of target cores.
4. It sends an inter-processor interrupt to each target.
5. Each target enters an interrupt handler, invalidates its own entries for the range, and acknowledges.
6. The initiator waits until every target has acknowledged.
7. Only now can the old physical frames be reused.

Step 6 is the rendezvous, and it is where the cost lives. The initiator is blocked — or at least spinning — until the *slowest* target responds. If one core is in a long interrupt-disabled region, or is handling a nested interrupt, or is running a real-time thread that has masked interrupts, the entire operation waits for it. The latency is not the average of the per-core costs; it is the maximum, plus the IPI delivery latency, plus the acknowledgment path.

This has three consequences that are easy to underestimate.

**First, shootdowns serialize otherwise independent work.** Two threads on two different cores that both want to unmap memory will contend, and their shootdowns will interleave with each other's IPIs. The kernel uses locks here — `mmap_lock`, the page-table locks, and the `tlbstate` bookkeeping — and those locks are held across the rendezvous in some paths.

**Second, shootdowns punish interrupt latency.** Any code that disables interrupts for a long time makes every other core's shootdown slower. This is why you see shootdown latency spikes correlate with driver bugs, long `spin_lock_irqsave` regions, and hypervisor exits.

**Third, shootdowns get worse with core count, not better.** The set of target cores is the set of cores that have ever run the address space. On a 96-core machine running a thread-per-core server, that set is essentially all 96 cores, and it will be all 96 cores for every invalidation. The work per operation scales linearly with the machine, and the latency scales with the tail of the interrupt-response distribution.

## A first cost model

Before going further into the kernel's implementation, it is worth writing down what we are trying to minimize.

The cost of a shootdown operation is approximately:

```
cost ≈ C_local × pages_invalidated
     + C_ipi_send × targets
     + max_over_targets( C_ipi_deliver + C_remote_invalidate × pages_invalidated + C_ack )
     + C_sync
```

where `C_local` and `C_remote_invalidate` are per-page invalidation costs, `C_ipi_send` is the cost of issuing an interrupt, and `C_sync` is the cost of the acknowledgment and wakeup path. The `max_over_targets` term is the dominant one and the one that resists optimization: it is a tail statistic, not a mean.

Every optimization in the kernel targets one of these terms:

- Reduce `pages_invalidated` by batching and by range-based invalidation.
- Reduce `targets` by tracking which cores actually have entries — the job of `mm_cpumask` and the lazy-TLB machinery.
- Reduce `C_remote_invalidate` by choosing a full flush over a per-page loop when the range is large enough.
- Reduce `C_sync` by avoiding the rendezvous entirely when possible, using address-space tags (PCID, ASID) that make a flush unnecessary.
- Eliminate the term altogether when the hardware can broadcast.

What follows is how Linux actually does each of these, and where the design gets uncomfortable.

## Who actually has this address space mapped?

The cost model above says the dominant term is `targets` — the number of cores that must be interrupted. So the first question any kernel has to answer is: which cores could possibly hold a TLB entry for this address space?

The naive answer is "all of them," and for a long time that was effectively the implementation. The modern answer is a per-`mm_struct` cpumask called `mm_cpumask`. It is a bitmap with one bit per possible CPU, and its invariant is: a CPU's bit is set if that CPU might hold TLB entries derived from this mm's page tables.

The bit is set in `switch_mm_irqs_off`, the function that installs a new address space on a CPU. After the CR3 write (or the PCID selection), the kernel does `cpumask_set_cpu(cpu, mm_cpumask(next))`. The bit is cleared only in narrow circumstances — notably when a CPU goes offline, and in the `leave_mm` path on the architectures that still use one.

The asymmetry matters. Bits are set eagerly and cleared rarely. A freshly forked process starts with exactly one bit set — the CPU that called `fork` — so the first shootdown after a fork touches one core. A thread-per-core server that has run on all 96 cores has all 96 bits set, and every subsequent shootdown touches all 96. The mask is a high-water mark of where the address space has *been*, not a census of where it is right now.

That is deliberate, because the alternative is worse. If you cleared the bit when a CPU stopped running the address space, you would have to flush that CPU's TLB entries at that moment — and you cannot, because the CPU is busy doing something else and you would need an IPI to make it happen. You would have converted a cheap bookkeeping update into a shootdown. So the kernel keeps the bit and accepts that it will interrupt CPUs that no longer care.

### Lazy TLB and the kernel thread problem

The hardest case is a CPU running a kernel thread. A kernel thread has no user address space (`current->mm == NULL`), so it does not need any user TLB entries. The obvious move is to switch to a kernel-only page table and clear the bit.

Linux does not do that on x86. Instead, a CPU entering a kernel thread keeps the previous process's page tables loaded and records the previous `mm` as `active_mm`. It sets a per-CPU flag, `cpu_tlbstate.is_lazy`, to mark that it is in "lazy TLB" mode. The `mm_cpumask` bit is left set.

The reason is the cost of coming back. If the CPU had switched to a kernel page table, returning to the original process would require reloading CR3, and — depending on the PCID state — potentially flushing the TLB. By keeping the address space loaded, the return is free. The price is that the CPU remains a shootdown target for an address space it is not using.

The handler knows this. `flush_tlb_func` checks `is_lazy` early and, if it is set, asserts that the local generation is already current and returns without doing a range walk. So the interrupt is still delivered, the CPU still takes the trap, and the initiator still waits for it — but the work inside is nearly zero. You pay the IPI latency and the rendezvous, not the invalidation.

This is a recurring theme: the kernel's TLB machinery is full of cases where the *correct* thing to do is cheap but the *coordination* around it is not.

### The mask is not free either

`mm_cpumask` is a `cpumask_t`, sized by `CONFIG_NR_CPUS`. On a distribution kernel built for 8192 CPUs that is a kilobyte; on a kernel built for 32768 it is four kilobytes. Every context switch writes to it, and every shootdown reads it. On a machine with many threads migrating between cores, that bitmap becomes a shared cache line that every CPU writes to — a scalability hazard that has nothing to do with the TLB itself. There have been repeated attempts to make the mask smaller or to replace it with a different structure, and they run into the same problem: the mask's whole job is to be a conservative over-approximation, and conservative over-approximations are hard to shrink without introducing correctness bugs.

## The x86 shootdown path, end to end

With `mm_cpumask` in hand, we can trace a single invalidation.

The entry point for most things is `flush_tlb_mm_range(mm, start, end, stride_shift, freed_tables)`. Everything about the signature is a hint about the design.

`start` and `end` are the virtual range. `stride_shift` is the log2 of the page size being invalidated, minus `PAGE_SHIFT`; it exists so that a range of transparent huge pages is counted as a range of huge pages rather than as 512× as many base pages. `freed_tables` says whether page-table pages are being released, which forces a full flush — a per-page invalidation cannot remove a stale intermediate-level entry, and a stale PMD entry is just as dangerous as a stale PTE.

The first decision is granularity. x86 has no range invalidation instruction, so the kernel has to choose between looping `INVLPG` and reloading CR3. The heuristic is a threshold, `tlb_single_page_flush_ceiling`, exposed for tuning under `/sys/kernel/debug/x86/` and defaulting to 33. Below the threshold, the kernel issues one `INVLPG` per page. Above it, it does a full flush — either a `CR3` reload or `INVPCID` with a whole-PCID type — on every target, because at that point one expensive instruction beats hundreds of cheap ones.

That threshold is a microarchitectural bet. It assumes `INVLPG` costs roughly a fixed amount and that a full flush costs roughly a fixed amount, and it picks the crossover. Both assumptions are only approximately true, and the crossover has moved as microarchitectures changed the relative costs of page-walk-cache invalidation and full-flush serialization. The default has been adjusted more than once; it is not a constant of nature.

The second decision is whether to send IPIs at all. The kernel checks whether any CPU other than the current one has a bit in `mm_cpumask`. If not — a single-threaded process, or one whose threads have not migrated — the whole operation collapses to a local flush and a couple of instructions. This is the path that makes single-threaded workloads look free.

If there are remote targets, the kernel increments a generation counter: `mm->context.tlb_gen`. This counter is the mechanism that makes the rendezvous tolerable.

### The generation counter

Each CPU records, for the address space it currently has loaded, the value of `mm->context.tlb_gen` that it observed at load time. The record lives in a per-CPU array indexed by ASID, alongside the ASID's context ID. When an invalidation happens, the initiator bumps the generation and sends the IPI. The handler reads the loaded mm's current generation and compares it against the value it recorded.

If they match, the CPU has already flushed past this point and the handler returns immediately. If they differ, the handler performs the flush and updates its record.

This turns the shootdown into an idempotent, level-triggered operation rather than an edge-triggered one. Two threads invalidating overlapping ranges on different cores do not have to coordinate their IPIs; each bump makes the other's flush redundant, and the redundant one is detected and skipped. It also means a CPU that was interrupted, flushed, and then re-interrupted for the same generation does no work the second time.

The generation counter only helps when the flush has already happened. It does not reduce the number of IPIs sent — the initiator still has to wake every target to find out whether it needs the flush. Reducing the *number of targets* requires the mask, and reducing the *number of IPI rounds* requires batching.

### The handler

The handler itself is short, and its structure is the whole design in miniature:

- If the loaded mm is `init_mm`, return. The kernel's own mappings are not tracked this way.
- If the CPU is in lazy TLB mode, verify the generation and return.
- If the generation matches, return.
- Otherwise, choose granularity from the range and the threshold, flush, and update the generation record.

Note what is *not* in there: no lock acquisition, no page-table walk, no allocation. The handler must be safe to run at any point, including inside another interrupt handler's critical section, and it must never block. That constraint is why invalidation has to be expressed as a range plus an address space, rather than as "invalidate whatever changed" — the handler has no way to discover what changed without taking locks the interrupted context might already hold.

That constraint also explains why `freed_tables` forces a full flush rather than a range flush. The handler cannot safely walk the page tables to figure out which intermediate entries went away, because from its point of view the page tables may be in an inconsistent state. It can only be told a range and a granularity.

## Batching: deferring the flush to make it bigger and rarer

The cost model says cost grows with the number of IPI rounds. So the obvious optimization is to do fewer, larger flushes.

Linux has a mechanism for exactly this, enabled by `CONFIG_ARCH_WANT_BATCHED_UNMAP_TLB_FLUSH`. It is used by the reverse-mapping code — the path that walks page tables to find and update PTEs for a physical page, which is what reclaim, migration, and `madvise` all exercise.

The idea is that a single logical operation, such as reclaiming a page that is mapped into a process on many cores, may need to clear many PTEs. If each PTE clear triggered its own shootdown, the operation would send one IPI per PTE. Instead, the rmap code adds the mm to a per-CPU batch with `arch_tlbbatch_add_mm`, records that the mm has pending flushes via a counter (`tlb_flush_pending` in the `mm_struct`), and clears PTEs with the non-flushing variant (`ptep_get_and_clear` rather than `ptep_clear_flush`). At the end of the operation, `arch_tlbbatch_flush` issues one flush covering everything.

The counter is what makes this safe. While it is non-zero, the mm is known to have flushes in flight, and any code that would otherwise skip a flush has to be careful. The helper `mm_tlb_flush_nested` exists to detect the case where a flush is already pending and the current operation can therefore rely on the batch's flush rather than issuing its own. This is a genuinely subtle piece of reasoning: the code is deciding *not* to flush because it knows someone else will, and it has to be right about the ordering.

The payoff is large. Reclaiming a page mapped into 96 processes on 96 cores can go from 96 shootdown rounds to one. The cost is that the flush, when it finally happens, covers a range that no longer corresponds to any single operation, and the latency of the invalidation is decoupled from the operation that caused it. If the batch is flushed too late, a stale translation can survive longer than a caller expects; if it is flushed too eagerly, the batching buys nothing. The `tlb_flush_pending` counter is the guard rail that keeps the window bounded.

There is a second-order effect worth noting. Batching makes the *number* of shootdowns smaller but makes each one cover more pages. Since the granularity heuristic compares the page count against a threshold, a batched flush is much more likely to cross the threshold and become a full flush. That is usually the right outcome — one full flush is cheaper than hundreds of `INVLPG`s — but it means batching can convert a targeted invalidation into a machine-wide TLB reset, which is a much bigger hammer than the caller asked for.

## ASID and PCID recycling: the hidden cliff

Everything above assumes that a flush is a choice. Sometimes it is not.

Both PCID on x86 and ASID on ARM64 are finite. x86 gives you 12 bits, and with KPTI-style page-table isolation you need two identifiers per process — one for the user page table, one for the kernel page table — which halves the effective space to roughly 2048 processes. ARM64's ASID width is implementation-defined, commonly 8 or 16 bits.

When the space runs out, the kernel bumps a global generation and invalidates *everything*. On x86 this lives in `arch/x86/mm/tlb.c` as `asid_generation`; when a new ASID is allocated and the generation has advanced past what a CPU has seen, that CPU performs a full TLB flush before using any ASID. Every process on the machine pays.

The practical consequence is that the cost of address-space switching is not constant. It is cheap for a while, and then a process-creation storm — a fork bomb, a container-churn workload, a language runtime that spawns threads with their own address spaces — pushes the allocator past the end of the identifier space and triggers a machine-wide flush. The latency shows up as a spike with no obvious correlation to the workload that caused it, because the cause is a global resource that no single workload owns.

This is the same failure mode as the shootdown storm, one level up. The kernel is trying to use a small hardware tag to avoid a rendezvous, and when the tag space is exhausted it falls back to the rendezvous it was trying to avoid. The mitigation is to recycle identifiers intelligently — prefer to evict an ASID that is not currently loaded on any CPU — but the underlying resource is finite, and there is no way to make it infinite.

## The hypervisor tax: shootdowns under nested paging

In a virtual machine, the guest kernel's view of CPUs is a set of vCPUs. When the guest sends a TLB shootdown IPI, it is not writing to an APIC that directly interrupts a physical core. It is asking the hypervisor to inject a virtual interrupt into another vCPU. Whether that vCPU is running is a scheduling question the guest cannot see. If the target vCPU is currently descheduled — because the host has oversubscribed physical cores, or because the vCPU is in a halt state, or because the host scheduler simply chose another task — the interrupt remains pending until the vCPU is scheduled again. The initiator, spinning in the guest kernel waiting for acknowledgments, has no way to yield to the vCPU it is waiting for. It can burn its entire timeslice while the target vCPU waits in the host runqueue. This is the lock-holder preemption problem applied to TLB shootdowns, and its latency is measured in scheduler timeslices, not cycles.

The problem compounds with nested paging. Under Intel EPT or AMD NPT, the guest's virtual address is translated first to a guest-physical address using the guest page tables, and then to a host-physical address using the hypervisor's second-level tables. Hardware may cache the combined translation, or cache the two levels separately. Either way, there are now two page-table hierarchies that can be invalidated, and they are owned by different software layers. A guest `INVLPG` or `TLBI` invalidates guest translations. It does not necessarily invalidate the host's second-level mappings, because those did not change. But when the host changes its second-level mappings — for memory ballooning, live migration dirty logging, page poisoning, or host reclaim — it must invalidate the nested translations on every vCPU that might have them. That is a host-side shootdown, triggered by host memory management, and it can land on a guest that is doing nothing related to memory at all. The guest experiences it as an unexplained latency spike.

Paravirtualization can remove some of the IPI traffic. KVM and Xen expose interfaces that let a guest request a remote TLB flush with a single hypercall or MSR write instead of one virtual IPI per vCPU. The hypervisor can then use a hardware broadcast instruction if the physical CPU supports one, or send host IPIs on the guest's behalf, or batch the flush with other work. The rendezvous still exists — the guest typically waits for the hypercall to return, and the hypervisor waits for the target vCPUs to acknowledge — but the per-target software overhead is lower and the hypervisor has more freedom to schedule the flush. Some implementations also allow the guest to defer the flush, recording a generation and letting the hypervisor flush lazily when a target vCPU is next scheduled. That trades correctness risk for latency, and it is only safe when the hypervisor can guarantee the flush happens before any stale translation can be used.

Live migration dirty logging is the pathological case. To track writes during migration, the hypervisor write-protects guest memory in the second-level page tables. Every guest write to a protected page causes an EPT or NPT violation, which the hypervisor handles by marking the page dirty and restoring write permission. Restoring permission requires invalidating the nested TLB entry for that page on every vCPU that has it. Without hardware assistance, that is a shootdown per page per vCPU. Intel's Page Modification Logging and AMD's equivalent let the hardware record dirty pages without trapping every write, but enabling or disabling logging still requires a global invalidation. Migration of a large VM can therefore generate a shootdown storm that is invisible to the guest's own TLB statistics.

## Real-time and isolated cores: when an IPI is a deadline miss

For a real-time thread, a TLB shootdown IPI is not a performance counter. It is an asynchronous event that can arrive at any instruction boundary, and it must be handled before the interrupted context resumes. The handler itself is short, but the interrupt latency it adds is not bounded by the handler's length. It is bounded by the longest interrupt-disabled region in the system, because the IPI cannot be delivered while interrupts are masked. A driver that holds interrupts off for a hundred microseconds makes every shootdown in the system wait a hundred microseconds. If the real-time thread is the target, it suffers the interrupt latency directly. If the real-time thread is the initiator — because it called `munmap`, or triggered reclaim, or caused a page migration — it blocks until every target has acknowledged, including targets that may be lower-priority threads sitting in long critical sections. There is no priority inheritance for TLB shootdowns. A high-priority thread can be delayed by a low-priority thread that has interrupts disabled.

CPU isolation helps only partially. `isolcpus`, `nohz_full`, and `rcu_nocbs` keep the scheduler tick and RCU callbacks off a core, but they do not remove the core from `mm_cpumask`. If an isolated core has ever run the address space, it remains a shootdown target. If it is running a real-time thread in that address space, an unmap on a housekeeping core will interrupt it. The only way to avoid that is to avoid sharing the address space. A real-time thread in its own process has its own `mm`, and its `mm_cpumask` contains only the cores that have run that process. If it is pinned to one isolated core, shootdowns for its address space are local. Shared memory does not change this: `mmap(MAP_SHARED)` creates a separate PTE in each process, and `madvise(MADV_DONTNEED)` or `munmap` in one process affects only that process's page tables. The file pages remain in the page cache and other processes' mappings are untouched. Process-per-core is therefore a real-time isolation technique, not just a scalability one.

When a real-time core does have to be a shootdown target, lazy TLB mode is the kernel's mitigation. If the core is running a kernel thread, the handler detects `is_lazy`, checks the generation, and returns without walking the range. The IPI is still delivered and the initiator still waits, but the target does almost no work. That is better than a full flush, but it does not eliminate the interrupt. Some configurations go further and drop the mm from `mm_cpumask` when a CPU goes idle, at the cost of reloading CR3 and potentially flushing on wakeup. That trade — pay a local flush on wakeup to avoid being a remote target while idle — is the right one for isolated cores that spend most of their time in an idle loop, and the wrong one for cores that alternate rapidly between idle and running.

PREEMPT_RT changes the locking model but not the rendezvous. TLB shootdown IPIs are still hard interrupts on most configurations, and the initiator still waits for acknowledgments. The real-time kernel reduces the length of interrupt-disabled regions, which reduces the tail of the shootdown latency distribution, but it cannot make the operation asynchronous. For a deadline-driven system, the practical guidance is to keep dynamic memory management off the real-time cores entirely: pre-fault and `mlock` the working set, use huge pages to reduce TLB pressure, avoid `munmap` and `madvise` in the real-time path, and perform any required address-space changes on a housekeeping core. If the real-time thread must share an address space with a non-real-time thread, the shootdown risk is structural, and no tuning will remove it.

## Seeing the invisible: measuring shootdowns

The first problem with shootdowns is that they do not show up in the usual places. They are not user time. They are not system time in the sense of a syscall that can be attributed to a caller. They are interrupt time, and on a busy machine they are spread thinly across cores and across operations. You need instrumentation that is specific to the mechanism.

The kernel provides a tracepoint, `tlb:tlb_flush`, that fires on both local and remote flushes. It records a reason code and a page count, and it is cheap enough to leave enabled during a measurement run. `perf record -e tlb:tlb_flush -a` will collect the events system-wide; `perf script` or `perf report` will show the distribution. A `bpftrace` one-liner is often faster to iterate: `tracepoint:tlb:tlb_flush { @[args->reason] = count(); }` gives you a breakdown by flush type, and `hist(args->pages)` shows whether you are issuing many small flushes or a few large ones. If you want latency rather than frequency, attach a kprobe to the entry of `native_flush_tlb_others` and a kretprobe to its return. The duration of that function includes the IPI send, the remote handler execution, and the acknowledgment wait, so its tail is the rendezvous tail you care about. A histogram of that duration, bucketed by the number of targets, will tell you whether the cost is per-page invalidation or per-target coordination.

`/proc/interrupts` is the blunt instrument. On x86, the TLB shootdown IPI appears as a `TLB` line, with a per-CPU count. A core with a much higher TLB count than its peers is being targeted disproportionately, which usually means it has run many address spaces or is the home of a thread that migrates. The count is cumulative, so you need to sample it over time to get a rate. `mpstat -I SUM` gives a similar view at a coarser granularity. Neither tells you which address space or which operation caused the interrupt, but they are enough to confirm that shootdowns are happening and to identify the targets.

For attribution, you need to correlate the tracepoint with the operation. The `tlb_flush` tracepoint includes the mm, so you can group by process if you capture the mm identifier and map it back to a PID. `perf script` can print the comm if the event is associated with a task context, but remote flushes are not in the target's context. A more practical approach is to bracket the suspected operation — a `munmap`, a `madvise`, a GC pause — with markers in `ftrace` or with `perf` events, and then look at the shootdown activity inside the bracket. If the activity is high, the operation is the cause. If it is low, the latency is coming from somewhere else, possibly the hypervisor or the scheduler.

Finally, measure the latency directly. `cyclictest` or `oslat` on an isolated core, with and without a memory-churn workload on the housekeeping cores, will show the real-time impact. `hwlatdetect` can detect hardware-induced latency, but it will not see IPI latency. If the isolated core's worst-case latency jumps when the housekeeping cores start unmapping memory, you have found the shootdown. The fix is architectural, not a tuning parameter.

## Designing around the rendezvous

The most effective way to reduce shootdown cost is to reduce the number of cores that share an address space. A process with 96 threads has an `mm_cpumask` that converges on all 96 cores, and every unmap or reclaim event becomes a machine-wide rendezvous. A process-per-core design gives each core its own `mm`, so a shootdown is local. Shared memory can still be used: `mmap(MAP_SHARED)` creates a separate PTE in each process, and `madvise(MADV_DONTNEED)` or `munmap` in one process invalidates only that process's translations. The file pages remain in the page cache, and other processes' mappings are unaffected. The cost is IPC, more page tables, more ASIDs or PCIDs, and more context switches. For workloads that do frequent large unmaps, it is often a net win.

Allocator design matters just as much. Returning memory to the OS is the operation that triggers shootdowns. A thread-local cache that never returns memory avoids them entirely, at the cost of a larger RSS. If memory must be returned, batch it. `madvise(MADV_FREE)` marks pages as reclaimable without immediately unmapping them, which decouples the shootdown from the operation that freed the memory. The kernel will reclaim the pages later under memory pressure, and the shootdown will happen then. That is good for the latency of the freeing operation and bad for predictability, because the reclaim can happen at an arbitrary later time on an arbitrary core. `MADV_DONTNEED` is immediate and synchronous, which is better for predictability and worse for latency. The choice depends on whether you can tolerate a spike later or need to bound the spike now.

Huge pages cut the number of TLB entries that must be invalidated. Unmapping a 2 MB region backed by a single huge page invalidates one entry; the same region backed by 4 KB pages invalidates 512. But huge pages have a sharp edge: splitting a huge page to unmap a small part of it requires invalidating the huge entry and installing many small entries, which is a shootdown of its own. Transparent Huge Pages can therefore help or hurt depending on the access pattern. Stable, long-lived mappings benefit. Regions that are frequently partially unmapped do not. `MADV_NOHUGEPAGE` on the latter and `MADV_HUGEPAGE` on the former is a reasonable default. `khugepaged` and `MADV_COLLAPSE` can also introduce shootdowns when they collapse small pages into a huge page, so latency-sensitive workloads often disable them or set THP to `madvise` mode.

Kernel samepage merging is another source of write-protect shootdowns. KSM scans pages, compares them, and write-protects candidates before merging. Every write-protect is a PTE change that must be propagated. `MADV_UNMERGEABLE` on latency-sensitive regions, or disabling KSM entirely, removes that source. NUMA balancing has the same character: it scans and migrates pages, and migration requires unmapping the old page and remapping the new one, both of which trigger shootdowns. `kernel.numa_balancing=0` is a common first step when tuning for latency. Memory cgroup reclaim is similar. A cgroup that is near its limit will reclaim pages, and reclaim unmaps PTEs. `memory.min` and `memory.low` can protect a working set from reclaim, but the only complete protection is to keep the working set resident and locked.

## The direction of the hardware

The architectural trend is toward removing the software rendezvous. AMD's `INVLPGB` and `TLBSYNC` are the clearest example on x86: a CPU can broadcast an invalidation for a range of pages to other CPUs in a domain, and `TLBSYNC` waits for completion. The kernel no longer has to send an IPI per target or maintain a per-target acknowledgment path. The hardware still has to synchronize, so the operation is not free, but the cost is no longer dominated by software interrupt delivery and the initiator's spin loop. Linux support for these instructions has been progressing, and on hardware that implements them they can replace the IPI path for many flushes. The catch is that the domain is finite. On a large machine with multiple sockets or NUMA nodes, a broadcast may not reach every core that has the translation, so the kernel still needs a fallback. The result is a hybrid: hardware broadcast where it works, IPIs where it does not.

ARM64 already has broadcast invalidation in the base architecture, and ARMv8.4 added range-based forms with a scale field. That lets a single instruction cover a power-of-two range of pages, which is a better fit for the kernel's batching than a per-page loop. RISC-V's `Svinval` extension separates the invalidation from the ordering fence, so software can issue a sequence of invalidations and pay the ordering cost once. These are all variations on the same theme: move the broadcast and the synchronization into the ISA, and leave the kernel to decide what to invalidate rather than whom to interrupt.

More identifier bits would help at the margins. PCID on x86 is 12 bits, and with KPTI it is effectively halved. ASID on ARM64 is implementation-defined and often 8 or 16 bits. When the space is exhausted, the kernel falls back to a global flush, which is exactly the rendezvous it was trying to avoid. Wider identifiers would push that cliff further out, but they would not eliminate it. The same is true of larger pages: 1 GB pages reduce TLB pressure and the number of entries to invalidate, but they make partial unmapping more expensive because the page must be split. There is no single hardware feature that makes shootdowns disappear. The realistic goal is to make the common case a hardware broadcast, the uncommon case a batched IPI, and the pathological case — a shared address space with frequent fine-grained unmaps across many cores — visible enough that software can avoid it.

Whether software can keep up with the hardware's new invalidation primitives, or whether the next generation of runtimes will simply learn to avoid shared address spaces, is an open question.

## The mmu_gather API: batching from the caller's side

The generation counter and the rmap batch described earlier are not the only batching mechanisms in the kernel. The core VM funnels every unmap path through a lower-level abstraction called `mmu_gather`, and understanding it explains why some shootdowns are unavoidable, why the kernel sometimes chooses a full flush when a range would do, and why page-table freeing is a synchronization problem in its own right.

A `struct mmu_gather` is a per-operation accumulator. It is initialized by `tlb_gather_mmu(mm, fullmm)` or `tlb_gather_mmu_fullmm(mm)` and destroyed by `tlb_finish_mmu(&tlb)`. Between those calls, the caller walks page tables and reports what it is removing: `tlb_remove_tlb_entry` for a PTE, `tlb_remove_page` for a page that will be freed, and `tlb_remove_table` for a page-table page. The gather structure records the range and the pages, but it does not issue any invalidation until `tlb_finish_mmu`. This is the batching that makes a large `munmap` or a process teardown tolerable: one flush at the end instead of one per PTE.

The `fullmm` flag is the first important optimization. When a process exits, or when `execve` replaces its address space, the entire mm is going away. There is no point in tracking a range, because every translation derived from this mm is about to become invalid. The kernel sets `fullmm`, and the gather records that a full flush is needed. On x86, that becomes a CR3 reload or an `INVPCID` for the whole PCID; on ARM64, a `TLBI VMALLE1IS`. It is the cheapest possible invalidation per page, because it is not per page at all. The same logic applies to `tlb_gather_mmu_fullmm`, which is used when the caller knows the entire address space is being torn down and the gather can skip range tracking entirely.

For a partial unmap, the gather tracks a range. The range is not necessarily contiguous. `tlb_start_vma` and `tlb_end_vma` bracket each VMA, and the gather can accumulate multiple disjoint ranges. On architectures with range invalidation, like ARM64 with `TLBI RVAE1IS`, the gather can emit one instruction per range. On x86, which lacks range invalidation, the gather has to choose between a loop of `INVLPG` and a full flush, using the same threshold heuristic described earlier. The gather does not make that decision itself; it hands the range to `flush_tlb_mm_range`, which applies the heuristic. The gather's job is to make the range as large and as few as possible before that decision is made.

The second important optimization is the split between the TLB flush and the page free. `tlb_finish_mmu` calls `tlb_flush_mmu`, which does two things in order: `tlb_flush_mmu_tlbonly` performs the invalidation, and `tlb_flush_mmu_free` releases the pages. The split matters because the pages cannot be reused until the invalidation is complete, but the invalidation does not need to wait for the pages to be freed. More importantly, the split lets the kernel batch page frees across multiple operations. The pages are held on a per-CPU list and freed later, which amortizes the cost of returning them to the allocator. On a workload that unmaps many small regions, this is the difference between a page-free storm and a steady trickle.

Page-table pages are a special case. A PTE page can be freed only after every CPU has stopped using it — not just its translations, but the page itself. If a CPU is in the middle of a page walk when the page is freed and reallocated, it can walk into a page that now belongs to something else. The kernel handles this with `tlb_remove_table`, which defers the actual free until after the TLB flush and, on some configurations, until after an RCU grace period. `CONFIG_MMU_GATHER_TABLE_FREE` enables the deferral; `CONFIG_MMU_GATHER_RCU_TABLE_FREE` adds the RCU grace period. The RCU variant exists because a page walk can be in progress without any lock, and the only way to be sure it has finished is to wait for a grace period. That is a shootdown-adjacent cost: the grace period is not an IPI, but it is a synchronization point that can delay the free by milliseconds.

The `tlb_remove_table` path also has a callback, `__tlb_remove_table`, which the architecture can override. On x86 with `CONFIG_MMU_GATHER_RCU_TABLE_FREE`, the callback batches table frees and uses `tlb_remove_table_sync_one` to wait for the RCU grace period on the current CPU. The details are architecture-specific, but the pattern is general: freeing page tables is expensive because it requires proving that no CPU is walking them, and proving that is a distributed problem. It is the same class of problem as the TLB shootdown, solved with a different synchronization primitive.

This is why `freed_tables` appears in the `flush_tlb_mm_range` signature. When the gather has freed page-table pages, a per-page invalidation is not enough. A stale PMD or PUD entry can point to a page that is no longer a page table, and the CPU that holds it will not necessarily fault — it may simply translate through it. The only safe response is a full flush, which is why `freed_tables` forces the full-flush path regardless of the range size. The gather knows whether it freed tables, and it passes that information down so the flush code can make the right choice.

The `mmu_gather` API also explains a common source of confusion in profiling. If you see a large number of `tlb_flush` tracepoints with small page counts, the caller is using the gather inefficiently — perhaps calling `tlb_finish_mmu` too often. If you see a few tracepoints with huge page counts, the gather is working, but the flush is large. The ideal is a small number of flushes with moderate page counts, which is what the threshold heuristic is trying to achieve. The gather is the layer that makes that ideal reachable.

## Secondary MMUs and the mmu_notifier rendezvous

The TLB is not the only translation cache that can hold a stale entry. A device MMU — an IOMMU, a GPU's MMU, a SmartNIC's translation cache — can cache translations derived from the same page tables. KVM, running a virtual machine, maintains nested page tables that map guest-physical to host-physical addresses, and those are derived from the host's page tables. When the host changes a PTE, every secondary MMU that has cached a translation from it must be invalidated too. The kernel cannot send an IPI to a GPU. Instead, it uses the `mmu_notifier` API.

An `mmu_notifier` is a callback registered against an `mm`. When the core VM is about to change a range of PTEs, it calls `mmu_notifier_invalidate_range_start(mm, start, end)`, and when it has finished, `mmu_notifier_invalidate_range_end(mm, start, end)`. The callbacks are responsible for invalidating whatever secondary translations they own. For KVM, that means flushing the guest's TLB entries on every vCPU that has the guest's address space loaded, which is itself a shootdown — this time of virtual CPUs rather than physical cores. For an IOMMU driver, it means issuing an invalidation command to the IOMMU's queue and waiting for completion. For a GPU driver, it means invalidating the GPU's own TLB and possibly waiting for in-flight GPU work to drain.

The `mmu_notifier` path is not a replacement for the TLB shootdown; it is an additional rendezvous that runs alongside it. A single `munmap` of a large region can trigger a local TLB flush on the calling CPU, a remote TLB shootdown on every CPU in `mm_cpumask`, an `mmu_notifier_invalidate_range_start` call that flushes every vCPU in every KVM guest that has the mm mapped, an IOMMU invalidation for every device that has the mm mapped, and an `mmu_notifier_invalidate_range_end` call that may block. The cost model from earlier now has more terms, and the `max_over_targets` term includes targets that are not CPUs at all.

The ordering is important. `invalidate_range_start` must complete before the PTE is changed, because a secondary MMU that is still translating through the old PTE could access a page that is about to be freed. `invalidate_range_end` runs after the PTE change and after the primary TLB flush, and it is where drivers can release resources that they allocated to block new translations during the window. The window between start and end is a critical section, and it can be long. The kernel has to be careful not to allocate memory inside it in a way that could recurse into reclaim, because reclaim can itself call `mmu_notifier_invalidate_range_start`. The `GFP_KERNEL` versus `GFP_ATOMIC` distinction matters here, and the `mmu_notifier` code has grown a set of flags and retry loops to handle the recursion.

The `mmu_notifier` also has a sequence counter, `mmu_notifier_seq`, that is used by the fast GUP path. `get_user_pages_fast` tries to pin a page without taking `mmap_lock`. It reads the PTE, and then checks `mmu_notifier_retry` to see whether an invalidation started while it was reading. If it did, the fast path fails and falls back to the slow path, which takes the lock and retries. This is the same pattern as the TLB generation counter: a monotonically increasing number that lets a reader detect that the world changed underneath it. The cost is that every `mmu_notifier_invalidate_range_start` must increment the counter, which is a shared cache line that every CPU writes to. On a machine with many threads doing GUP and many invalidations, that counter is a scalability bottleneck in its own right. It is the same class of problem as `mm_cpumask`: a conservative over-approximation that is cheap to update in the common case and expensive when it becomes a contended cache line.

The `mmu_interval_notifier` is a newer variant for device memory and HMM. Instead of invalidating a range on every change, a driver registers an interval and gets a callback only when that interval is affected. This reduces the number of callbacks for sparse mappings, but it does not remove the rendezvous. The driver still has to invalidate its device TLB before the callback returns, and the kernel still has to wait for it. The interval notifier also has to handle the case where the interval is split or merged, which adds its own bookkeeping cost.

The practical consequence is that the cost of a shootdown in a virtualized or device-attached environment is not just the cost of the IPI. It is the cost of every secondary MMU invalidation that the operation triggers. A workload that looks fine on bare metal can fall apart in a VM or with a GPU attached, and the profiler will show the same thin smear of kernel frames — plus a new one, `mmu_notifier_invalidate_range_start`, which is where the time actually goes. The fix is the same as for the primary TLB: reduce the number of operations that change address-space mappings, batch them, and avoid sharing an address space across cores or devices that do not need to share it. The `mmu_notifier` API makes the secondary MMUs correct, but it does not make them free, and on a machine with many devices and many vCPUs the rendezvous can be wider and slower than the TLB shootdown it accompanies.
