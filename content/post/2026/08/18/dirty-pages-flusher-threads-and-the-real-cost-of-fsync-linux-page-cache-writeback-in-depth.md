---
title: "Dirty Pages, Flusher Threads, and the Real Cost of fsync: Linux Page Cache Writeback in Depth"
description: "How the Linux page cache accumulates dirty data, who decides when it reaches the device, why balance_dirty_pages throttles writers instead of blocking them, and why fsync latency is a property of the whole system rather than of your file."
date: "2026-08-18"
author: "Leonardo Benicio"
tags: ["linux","page-cache","writeback","fsync","storage","kernel","performance","durability"]
categories: ["Systems","Operating Systems","Storage"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/dirty-pages-flusher-threads-and-the-real-cost-of-fsync-linux-page-cache-writeback-in-depth-2026-08-18.jpg"
coverAlt: "Isometric diagram of dirty memory pages pooling behind a valve-like throttle, worker processes draining them through a pipe, and a storage device emitting a jagged latency waveform."
---

# Dirty Pages, Flusher Threads, and the Real Cost of fsync: Linux Page Cache Writeback in Depth

Ask a storage engineer which call in the POSIX surface is the most misleading and the answer is usually `write()`. A buffered write to a regular file copies bytes into the page cache and returns. It does not touch the device. It does not order your bytes against anything else on the system. It does not survive a power loss. What it *does* buy you is a guarantee that is strong and cheap at the same time: any subsequent `read()` through the same file — from any process on the machine — observes exactly the bytes you wrote, in order, because the page cache is the single source of truth for file contents until writeback replaces it.

Everything interesting about Linux storage performance follows from the fact that the kernel is running two clocks at once. One clock is the application's: nanoseconds, syscalls, cache-line-sized copies. The other is the device's: microseconds to milliseconds, sectors, queues, and a physical medium that may or may not be honest about when data is durable. The page cache exists to decouple those clocks. Writeback is the machinery that re-couples them, and `fsync()` is the point where an application volunteers to wait for the re-coupling to finish.

This article is about that machinery as a system: what state the kernel tracks, who makes decisions from it, which decisions are global and which are per-task, and where the design's trade-offs turn into tail latency in real services. It is deliberately not a sysctl cheat sheet — the tunables matter, but they only make sense once you know what is being controlled.

## Two clocks, one file

The buffered write path is short. `write()` descends into the filesystem's `write_iter`, which for most filesystems calls `generic_perform_write()`. That function walks the file in page-sized chunks, asks the page cache for the page covering the current offset (`grab_cache_page_write_begin()`), copies the user's bytes into it, marks it dirty, and moves on. When the last chunk is copied, the syscall returns. The page is now in the page cache, in the radix tree (an xarray, in current kernels) rooted at the inode's `address_space`, and flagged as needing writeback.

Two properties of that design are worth naming explicitly, because they explain most downstream behavior.

First, **the page cache is the authority, not the device**. A read that hits a dirty page is served from memory. A read that hits a page currently under writeback is also served from memory. The device is a backing store, not the source of truth, and the kernel never has to ask it for data it already has. This is why buffered I/O can look absurdly fast on a write-heavy workload: for a while, you are only writing to DRAM.

Second, **dirty pages are not reclaimable**. A clean page cache page can be dropped instantly when memory is needed; the data is still on the device. A dirty page cannot be dropped, because dropping it would lose the only copy. The kernel must write it out first. That single fact is why dirty page accounting is not just a performance concern but a progress concern: too many dirty pages, and the memory allocator itself starts stalling on I/O.

So the kernel has a finite, shared, non-reclaimable pool of deferred work, growing at whatever rate applications write. Something has to decide when that pool drains, at what rate, and who pays when it grows too fast. That something is the writeback subsystem.

## What the kernel means by dirty

The vocabulary matters, because a lot of confused performance discussion comes from collapsing three distinct states into one word.

A page cache page is in one of three relevant states:

- **Clean.** Contents match the device (or the kernel believes they do). Reclaimable at any time.
- **Dirty.** Contents are newer than the device. Not reclaimable. Counted in `NR_FILE_DIRTY`, exposed roughly as `nr_dirty` in per-node and per-cgroup statistics.
- **Under writeback.** A write request covering this page has been submitted to the block layer but has not completed. Counted in `NR_WRITEBACK`.

The distinction between dirty and under-writeback is not bookkeeping trivia. Throttling decisions and memory-reclaim behavior differ depending on how much of the backlog is in each state, and a page can transition backwards: if an application writes to a page while it is under writeback, the page is marked dirty again when the write completes, and the kernel schedules another pass. This is the source of the classic rewrite-amplification pattern, where a hot page that is modified faster than the device can retire it gets written over and over.

Dirty state is tracked at two levels, and the split is one of the more elegant parts of the design.

At the **inode** level, the kernel keeps flags in `i_state` — `I_DIRTY_PAGES` for page cache dirt, `I_DIRTY_SYNC` and `I_DIRTY_DATASYNC` for metadata that must reach the device for different strengths of durability, and `I_DIRTY_TIME` for timestamp updates that can be deferred. An inode that needs page writeback is placed on one of the per-writeback-context lists: `b_dirty`, `b_io`, `b_more_io`. The inode is the unit of scheduling; the page is the unit of I/O.

At the **global** level, the kernel maintains counters of dirty and under-writeback pages, aggregated per NUMA node, per memory cgroup, and per backing device. Those counters are what the throttling logic reads. They are approximate by construction — per-CPU counters batched and folded periodically — which is fine, because the decisions made from them are control decisions, not correctness decisions.

The separation between *the inode needs writing* and *these pages need writing* is what allows the writeback code to be both fair and efficient: it walks a list of inodes, and for each inode it asks the filesystem to write a bounded number of pages, using the filesystem's own `writepages` implementation. Ext4, XFS, and Btrfs each do something quite different inside that call — extent lookups, journal reservations, delayed allocation decisions — and none of that is visible to the generic layer.

## The dirty limits

The kernel's policy is built around two thresholds, both expressed by default as a percentage of dirtyable memory (roughly free memory plus reclaimable page cache, with adjustments for highmem and reserved pages):

- **`vm.dirty_background_ratio`** (traditionally 10). Above this, background writeback starts. Applications are not yet slowed down.
- **`vm.dirty_ratio`** (traditionally 20). Above this, applications that dirty pages are throttled — they sleep inside the write path until the backlog comes down.

Both have byte-based counterparts, `dirty_background_bytes` and `dirty_bytes`, which take precedence when set. The byte forms exist because percentage thresholds scale with machine size, and a twenty percent threshold on a 1 TiB machine is not a limit, it is a suggestion. On large-memory systems, byte limits are usually the right tool.

Two more knobs shape the *timing* rather than the *volume*:

- **`vm.dirty_expire_centisecs`** (traditionally 3000, i.e. 30 seconds). A page that has been dirty longer than this is eligible for periodic writeback regardless of how much dirty data exists.
- **`vm.dirty_writeback_centisecs`** (traditionally 500, i.e. 5 seconds). How often the periodic flusher wakes up to look for expired pages.

These are the writeback-for-its-own-sake settings. They exist to bound how long data can sit in memory un-written, which matters for two reasons: a crash loses everything that has not been written, and a long-dirty page is a page that has been accumulating rewrite amplification.

The two-threshold structure encodes a real trade-off. If the kernel started throttling writers as soon as the first dirty page appeared, it would serialize every write behind the device and destroy the batching that makes buffered I/O fast. If it never throttled, dirty pages would grow until the machine ran out of reclaimable memory and the allocator deadlocked waiting for writeback. The gap between the background threshold and the hard threshold is the slack the kernel uses to absorb bursts.

The thresholds are not purely global. With memory cgroups, dirty limits are applied against the cgroup's own dirtyable memory, so a container cannot exhaust the host's dirty budget — and, importantly, cannot be throttled by a noisy neighbor's dirty pages. That property is not automatic; it depends on the kernel being built with cgroup writeback support, on the filesystem cooperating, and on the writeback context being attached to the right cgroup at the time the page is dirtied.

## Throttling is a control loop, not a wall

The interesting part of the design is not the threshold. It is what happens when you cross it.

When a task dirties a page, the write path calls into the throttling logic (via `balance_dirty_pages_ratelimited()` in `generic_perform_write()` and its equivalents). That function keeps per-task counters of pages dirtied and pages written, and periodically — every so many pages, not every page — calls `balance_dirty_pages()`, which computes whether the task should pause and for how long.

The pause is not a fixed penalty. It is computed from the difference between the current dirty level and the threshold, the task's own recent dirtying rate, and the estimated write bandwidth of the backing device, and it is clamped to a maximum so that a task cannot be parked indefinitely in a single call. The effect is a proportional controller: a task writing faster than the device can absorb is slowed to roughly the device's rate, rather than being stopped and restarted.

Three consequences of this design are worth internalizing.

**The state is shared; the rate is per-task.** Dirty accounting is global (or per-cgroup), but the pause is applied to whichever task is dirtying pages right now. That means one application's dirty backlog can throttle another application's writes, even if the second application has barely written anything. On a shared host, this is a real and often surprising coupling.

**Throttling is not fairness.** The controller has no notion of which task deserves bandwidth. It has a notion of how much dirty data exists. Under contention, the tasks that happen to be dirtying pages after the threshold is crossed absorb the cost, and the tasks that dirtied pages earlier got their writes in cheaply.

**The pause is inside the syscall.** A throttled `write()` does not return an error, does not return early, and does not tell you it slept. It just takes longer. This is why write latency on a busy system is a distribution with a long tail that has nothing to do with the device's own latency: it is the queueing delay imposed by the controller.

For parallel workloads, the controller is the shared resource. A thread pool doing buffered writes to many files will find that its aggregate throughput is bounded not by the sum of per-thread rates but by the global dirty budget — and that adding threads past a certain point buys nothing, because the bottleneck has moved from the device to a shared accounting variable guarded by shared state. This is the same shape of problem as any other contended counter in a parallel system, with the added twist that the counter's value is a control input rather than a resource allocation.

## Who actually writes

Throttling controls the inflow. Something still has to do the outflow, and that something is deliberately not the writing application.

Writeback is organized per backing device. Each block device (and each filesystem mounted from it) has a writeback context that owns the inode lists and the statistics: how many pages are dirty, how many are under writeback, and an estimate of the device's write bandwidth, maintained by observing completed writeback. That bandwidth estimate is used to size the work. The writeback code does not submit an unbounded pile of I/O and hope; it submits a chunk, waits for completions to inform the next chunk, and adjusts.

The work is performed by a small number of kernel workers. In older kernels these were dedicated per-device threads with names like `flush-8:0`; in current kernels the periodic and background work is dispatched through a writeback workqueue, and you are more likely to see generic `kworker` threads doing the I/O. Either way, the model is the same: a bounded number of kernel contexts drain a queue that applications fill.

Two modes matter:

- **Background writeback** (`WB_SYNC_NONE`) is best-effort. It walks inodes, asks each filesystem to write some pages, and stops when it has done its quota. It does not wait for the pages to hit the device, and it is happy to be preempted. The periodic flusher that honors `dirty_expire_centisecs` runs in this mode.
- **Synchronous writeback** (`WB_SYNC_ALL`) is what `fsync()`, `fdatasync()`, `sync()`, and `syncfs()` use. It walks the same lists but waits for completion, and it must cover metadata as well as data.

The distinction explains a behavior that puzzles people the first time they see it: on an idle system, `fsync()` can be fast even for a large file, because the background flusher already wrote most of it. On a busy system, the same `fsync()` can be slow, because it is now competing for the same device queue that the background flusher is filling — and, worse, because the writeback code may have to do the work itself rather than finding it already done.

There is a third path into writeback that is easy to forget: **memory reclaim**. When the allocator needs pages and the clean page cache is exhausted, it calls into writeback to free dirty pages. This is the path where a machine that is merely busy writing turns into a machine that is stalled on I/O inside the allocator, and it is the reason dirty limits are a stability control, not just a performance tuning knob.

That is the asynchronous half of the story: a shared pool, two thresholds, a proportional controller, and a small pool of kernel workers draining inodes in bounded chunks.

The synchronous half — what `fsync()` actually asks the device to do, why the answer can be that nothing needs doing, why it can also be that you must wait for a cache flush on a device you do not control, and how the block layer's flush and FUA machinery turns a filesystem's durability request into a command the hardware understands — is where the interesting failure modes live. That is where we go next.

## The synchronous path: what `fsync()` actually waits for

When an application calls `fsync(fd)`, it enters the filesystem's `fsync` method through the VFS. The method's job is to ensure that all data and metadata for the file are on stable storage. But "stable storage" is a moving target, and the path from the syscall to the platter (or NAND) is layered.

The first question the filesystem asks is: what needs writing? For a file that has been written recently, there may be dirty pages in the page cache. For a file that was just created or renamed, there may be dirty inodes, directory entries, and journal transactions. The filesystem's `fsync` implementation walks the inode's dirty state and decides what to flush.

In ext4, `ext4_sync_file()` is the entry point. It handles three things: it flushes the file's dirty data pages if the file was opened with data integrity requirements (or if `fdatasync` is called, it flushes only the data needed to retrieve the file's contents), it forces the journal to commit any metadata changes, and it issues a flush to the underlying block device. The journal commit is the expensive part. Ext4's journal is a circular log; committing it means writing the transaction's descriptor and data blocks (in `data=journal` mode) or just the metadata (in `data=ordered` or `data=writeback`), then writing a commit record, then issuing a cache flush to ensure the log is durable. Only after the commit is durable can the filesystem consider the metadata safe.

XFS takes a different approach. It uses a log (journal) that records metadata changes. `xfs_file_fsync()` flushes the inode's data (if needed), then forces the log up to the current LSN (log sequence number), then flushes the inode's metadata. The log force is a synchronous operation that waits for the log I/O to complete. XFS is known for its efficient handling of concurrent fsyncs, partly because it can batch log forces: multiple fsyncs arriving close together can share a single log write.

Btrfs, being copy-on-write, has a transaction-based model. `btrfs_sync_file()` waits for the current transaction to commit, which involves writing out all dirty metadata and data for that transaction, then writing a superblock. The transaction commit is a global operation, so an fsync in Btrfs can be more expensive than in ext4 or XFS, especially under concurrent load.

The common thread is that `fsync` is not a single I/O. It is a sequence: flush data, flush metadata, flush device cache. The exact sequence depends on the filesystem and on the mount options.

`fdatasync` is a lighter-weight variant. POSIX says it need not flush metadata that is not required to retrieve the data — for example, the file's modification time or the inode's generation number. But it must still flush the file's size if the size changed, and it must flush any metadata needed to locate the data blocks. In practice, on ext4, `fdatasync` can skip the journal commit if the file's size and block mapping haven't changed, but if they have, it must commit the journal anyway. So the performance difference between `fsync` and `fdatasync` is workload-dependent: for a file that is overwritten in place, `fdatasync` can be significantly cheaper; for a file that is appended to, they may be identical.

There is also `sync_file_range()`, which allows an application to request writeback of a range of pages without waiting for metadata or issuing a device flush. It is a hint, not a durability guarantee. Databases use it to push data out in the background while keeping the expensive fsync for commit points. But it is dangerous: it does not provide ordering guarantees, and it can be a no-op on some filesystems. Its existence is a reminder that the kernel's writeback interface is not a single knob but a small family of operations with different strengths.

## The block layer's flush and FUA machinery

Once the filesystem has decided what to write, it submits bios to the block layer. For durability, it must ensure that the data reaches the device's persistent media, not just the device's volatile write cache. Modern storage devices — from consumer SSDs to enterprise arrays — have write caches. Some are battery-backed or capacitor-backed and are considered non-volatile; most are not. The kernel cannot know for sure, so it assumes the worst and uses explicit cache flushes.

The block layer provides two mechanisms for this: `REQ_PREFLUSH` and `REQ_FUA`. A bio with `REQ_PREFLUSH` set tells the block layer to issue a cache flush to the device *before* the bio's data is written. A bio with `REQ_FUA` set tells the device to write the data with "Force Unit Access" semantics: the data must be on stable media before the write is reported complete. FUA is a per-write guarantee; preflush is a barrier that orders the write after a flush.

The block layer translates these flags into device commands. For SCSI devices, a preflush becomes a `SYNCHRONIZE CACHE` command, and FUA becomes a write with the FUA bit set in the CDB. For ATA devices, it's `FLUSH CACHE` and `WRITE FUA EXT` (if supported). For NVMe, it's a `Flush` command and a write with the FUA bit set in the command. If the device does not support FUA, the kernel emulates it by issuing a preflush before the write and a postflush after — which is expensive, because it serializes the write behind two cache flushes.

The queue limits exposed by the device (`/sys/block/<dev>/queue/fua`, `flush`) tell the kernel what the device can do. If a device claims to support FUA but actually doesn't (a disturbingly common firmware bug), durability is compromised. This is why some filesystems and storage stacks default to using preflush-only, or why administrators disable write caches on devices that cannot be trusted.

The ordering semantics are enforced by the block layer's request queue. A flush request is not just another I/O; it is a barrier. The queue must not dispatch any write that was submitted after the flush until the flush completes. This is implemented by the I/O scheduler and the block layer's flush state machine. In practice, a flush can stall the entire device queue, which is why a single `fsync` on a busy device can cause a latency spike for all other I/O.

The cost of a flush is highly device-dependent. On a spinning disk with a write cache, a flush forces the disk to write its cache to platters, which can take tens of milliseconds. On an SSD, a flush may be a no-op if the device has a power-loss-protected cache, or it may force the SSD's controller to write its mapping table and data from DRAM to NAND, which can take milliseconds and cause write amplification. On NVMe, a flush is a command that the controller may implement efficiently, but it still involves a round trip and can be a bottleneck under high queue depths.

## Why `fsync` latency is a property of the whole system

The latency of a single `fsync` is not a property of the file, the filesystem, or even the device alone. It is the sum of several delays, any of which can dominate:

1. **Writeback of dirty pages.** If the file's data is still dirty in the page cache, the `fsync` must write it out. The time depends on how much data is dirty, how fragmented the file is on disk, and how busy the device is. If the background flusher has already written the data, this cost is zero.
2. **Metadata writeback.** The filesystem may need to update inodes, extent maps, directory entries, and journals. This can involve multiple dependent I/Os. A journal commit, in particular, is a serialized operation that may wait for other transactions to complete.
3. **Device cache flush.** The filesystem issues a flush to ensure the data is durable. This flush competes with all other I/O on the device. If the device's queue is deep, the flush may wait behind many other requests.
4. **Queueing delay.** The `fsync` request itself is queued in the block layer. Under load, it may wait behind other writes, reads, and flushes. The I/O scheduler's decisions affect this delay.
5. **Throttling.** If the system is over the dirty threshold, the `fsync` may be throttled by `balance_dirty_pages` as it writes out dirty pages. This is not a fixed sleep; it is a rate-limiting pause that can be tens of milliseconds.

Because these delays are shared, `fsync` latency is a system-wide property. A process that calls `fsync` on a small file can be delayed by another process that is writing a large file, or by the background flusher draining a huge dirty backlog, or by a single slow flush on the device. This is the "noisy neighbor" problem at the storage layer.

The effect is amplified by concurrency. When many threads call `fsync` simultaneously, they all submit flushes to the same device. The device's queue fills with flush commands, each of which may serialize the queue. The result is a "fsync storm": throughput collapses, and latency for all I/O spikes. Databases that use group commit — batching multiple transactions into a single `fsync` — do so precisely to avoid this.

The block layer's writeback bandwidth estimation also plays a role. The kernel estimates the device's write bandwidth by observing completed writeback. If the estimate is too low, the kernel writes too slowly, and dirty pages accumulate. If it is too high, the kernel submits too much I/O, and the queue fills. The estimate is dynamic, and it can be wrong during transient load, leading to oscillations in writeback rate and in `fsync` latency.

## Journaling, ordered mode, and the cost of consistency

Filesystems use journals to avoid full filesystem checks after a crash. The journal records metadata changes in a log, and the filesystem replays the log on mount. But the journal itself must be durable, and that durability is enforced by flushes.

Ext4's default `data=ordered` mode provides a middle ground: data blocks are written to their final locations before the metadata that points to them is committed to the journal. This ensures that after a crash, the file's metadata never points to uninitialized data. The cost is that `fsync` must wait for data writes to complete before the journal commit. In `data=writeback` mode, data writes are not ordered, so a crash can leave a file with stale data in newly allocated blocks. This is faster but less safe. In `data=journal` mode, data is written to the journal first, then to its final location — twice the write traffic, but with strong consistency.

XFS uses a similar ordered approach by default, with its log recording metadata and some data (for delayed allocation). The log force on `fsync` ensures that the log is on stable storage. XFS also has a concept of "log covers" — the log must be flushed up to the LSN of the transaction that the `fsync` depends on.

Btrfs's copy-on-write design means that a `fsync` may need to wait for a transaction commit, which writes a new superblock. The superblock write is itself a flush point. Btrfs is known for its fast `fsync` in some workloads (because it can write data and metadata in large sequential chunks) and slow `fsync` in others (because transaction commits are global).

The key insight is that `fsync` is not just about data. It is about the filesystem's consistency model. The journal, the ordered mode, and the transaction system all impose ordering constraints that translate into flushes and waits. Tuning these modes is a trade-off between performance and the guarantees you get after a crash.

## Fsync in the real world

Applications that care about durability — databases, mail servers, configuration management tools — call `fsync` at critical points. PostgreSQL, for example, calls `fsync` on its WAL (write-ahead log) after every commit (unless `synchronous_commit` is off). SQLite calls `fsync` on its journal or WAL depending on the journal mode. The performance of these applications is often dominated by `fsync` latency, and their tuning guides are full of advice about `fsync` batching, `commit_delay`, and storage configuration.

One notorious issue is `fsync` error handling. In older kernels, an error during writeback could be lost: `fsync` might return success even though the data never reached the device, because the error was cleared from the page cache. This was fixed in later kernels (the "fsyncgate" patches), but it highlights the fact that durability is a chain of promises, and any broken link can invalidate the whole chain.

Modern applications can use `io_uring` to submit `fsync` operations asynchronously, or use `sync_file_range` to push data out early. But the fundamental cost remains: a durable write must wait for the device to confirm that the data is on stable media. There is no free lunch.

## Observability: what to measure

To understand `fsync` latency, you need to measure more than just the syscall time. The kernel exposes a wealth of counters and tracepoints.

- `/proc/meminfo` shows `Dirty` and `Writeback` in kilobytes. These are the global dirty and under-writeback totals.
- `/proc/vmstat` has `nr_dirty`, `nr_writeback`, `nr_dirty_threshold`, `nr_dirty_background_threshold`. The thresholds are useful for seeing how close you are to throttling.
- Per-cgroup stats under `/sys/fs/cgroup/memory/<cgroup>/memory.stat` include `file_dirty` and `file_writeback`.
- Per-device stats in `/sys/block/<dev>/stat` show I/O counts and times, including flush requests.
- `blktrace` and `bpftrace` can trace individual bios, including flush and FUA flags. This is how you see the actual device commands.
- eBPF tools like `biolatency` and `biosnoop` can show the latency distribution of block I/O, separating flushes from reads and writes.
- Filesystem-specific tracepoints (e.g., `ext4:ext4_sync_file_enter`, `xfs:xfs_file_fsync`) can show how long the filesystem's `fsync` implementation takes and what it is waiting for.

The most useful measurement is a histogram of `fsync` latency, correlated with dirty page counts and device queue depth. If you see a bimodal distribution — fast for files that are already clean, slow for files that require writeback — you are seeing the background flusher's work paying off. If you see a long tail that correlates with device queue depth, you are seeing queueing delay. If you see throttling, you will see `fsync` times that are suspiciously uniform and tied to the dirty ratio.

The takeaway is that `fsync` latency is not a single number. It is a function of the system's state, and the only way to improve it is to understand which part of the chain is the bottleneck.

## Inside a writeback pass

The generic writeback loop is `wb_writeback()`. It does not simply walk every dirty page. It builds a `struct writeback_control` for the pass, and that structure is the contract between the generic layer and the filesystem. Its fields decide what the filesystem is allowed to skip, how much it should write, and whether it must wait.

The important fields are `sync_mode`, `nr_to_write`, `range_cyclic`, `range_start`, `range_end`, `for_background`, `for_kupdate`, `for_sync`, `older_than_this`, and `nonblocking`. A periodic background pass sets `for_kupdate` and `older_than_this` to the expiry cutoff. A memory-reclaim pass sets `for_reclaim` and may set `nonblocking` so that the filesystem does not block on locks. An `fsync` pass sets `sync_mode = WB_SYNC_ALL`, `for_sync = 1`, and `nr_to_write = LONG_MAX`. That last value is why `fsync` does not stop after a fixed quota: it must cover every dirty page and every piece of metadata the filesystem considers necessary.

The loop first checks whether the backing device has dirty inodes at all. If it does, it moves inodes from `b_dirty` to `b_io` and calls `writeback_sb_inodes()`. That function walks `b_io` and, for each inode, calls the filesystem's `writepages` method. The inode is not written in one shot. The filesystem returns after writing some pages, and the generic layer decides what to do next. If the inode still has dirty pages and the pass has quota left, it may stay on `b_io`. If the pass is out of quota, the inode moves to `b_more_io` for the next round. If the filesystem reported skipped pages — because it could not get a lock, or because the page was already under writeback — the inode is requeued with `requeue_io()` and tried again later.

The inode's `writeback_index` is a cursor into the file. Filesystems use it to avoid starting at offset zero on every pass. With `range_cyclic` set, the filesystem wraps around when it reaches the end of the file. This is how a large file can be written in bounded chunks without starving the rest of the file. It also explains a subtle behavior: an `fsync` on a file whose dirty pages are spread across a wide range may cause multiple `writepages` calls, because the generic layer and the filesystem are both trying to bound the work per call.

What happens inside `writepages` is filesystem-specific, and that is where the real cost lives. Ext4's `ext4_writepages()` uses the mpage infrastructure to map pages to blocks, start a journal handle, reserve blocks for delayed allocation, and submit bios. XFS's `xfs_vm_writepages()` walks the page cache, calls `xfs_map_blocks()` to resolve extents, and builds I/O end structures that are submitted through `xfs_submit_ioend()`. Btrfs's `extent_write_cache_pages()` writes pages as ordered extents, which are the unit of data integrity in its transaction model. The generic layer only sees the return value: how many pages were written, how many were skipped, and whether the inode still needs attention.

Completion is asynchronous. When a bio finishes, its end_io handler clears the `PG_writeback` flag on each page, decrements `NR_WRITEBACK`, and wakes any task waiting on the page. If the application dirtied the page again while it was under writeback, the page is left dirty, and the next writeback pass will write it again. That is the rewrite-amplification loop in its simplest form: a hot page modified faster than the device can retire it is written repeatedly, and each write consumes device bandwidth that could have gone to other data.

`fsync` ultimately waits on this machinery in two ways. For data pages, it waits for `PG_writeback` to clear, either by calling `wait_on_page_writeback()` directly or by having the filesystem's `writepages` call with `WB_SYNC_ALL` wait for the I/O it submitted. For metadata, it waits on the filesystem's own synchronization primitives: a journal commit, a log force, or a transaction commit. The generic writeback layer does not know which of those is expensive. It only knows that `WB_SYNC_ALL` means the filesystem must not skip pages and must not return until the requested state is durable.

## The dirty throttling math, without the folklore

The throttling logic is often described as a simple rule: if dirty pages exceed `dirty_ratio`, slow down. The actual controller is more interesting, and understanding it explains why write latency is not a step function at the threshold.

Each backing device's writeback context maintains a `dirty_ratelimit`, an estimate of how many pages per second the device can absorb. That estimate is not a static property read from the device. It is learned from completed writeback. When writeback completes, the kernel observes how many pages were written and how long they took, and it adjusts `dirty_ratelimit` toward the observed rate. If the device is fast, the estimate rises. If the device is slow or the queue is congested, the estimate falls.

When a task calls `balance_dirty_pages()`, the kernel computes a `pos_ratio` from the current dirty level. The ratio is not linear. It is designed to be close to 1 when dirty pages are near the background threshold, and to fall toward 0 as dirty pages approach the hard threshold. The task's allowed rate is then `task_ratelimit = dirty_ratelimit * pos_ratio`, with fixed-point scaling. If the task has been dirtying pages faster than `task_ratelimit`, it sleeps for a computed pause. The pause is proportional to the excess: a task that is slightly over its rate sleeps briefly; a task that is far over sleeps longer, up to a maximum.

The maximum pause matters for tail latency. In many kernels it is on the order of 200 milliseconds. A single `write()` call can therefore sleep for up to that long inside the syscall, with no error and no indication that it was throttled. When many threads are writing, the aggregate rate is bounded by the device's estimated bandwidth, but individual calls can see pauses that look like device stalls. They are not device stalls; they are the controller holding the writers back so that the dirty pool does not overflow.

The controller is not fair, and it does not try to be. It has no per-task notion of priority or entitlement. It only knows that the current task is dirtying pages and that the system is over its budget. The task that happens to be dirtying pages when the threshold is crossed pays the pause. A task that dirtied pages earlier got its data into the cache cheaply and may never see a pause at all. On a shared host, this means one application's dirty backlog can slow another application's writes even if the second application is writing to a different file on the same filesystem.

The per-cgroup version of the controller changes the scope but not the shape. With cgroup writeback, each memory cgroup has its own writeback context and its own `dirty_ratelimit`. The dirty level is measured against the cgroup's own dirtyable memory, so a container that writes heavily is throttled against its own budget rather than the host's. That is a real isolation improvement, but it depends on the page being attributed to the correct cgroup at the time it is dirtied. If the attribution is wrong, the throttling is wrong, and the isolation is only nominal.

The controller also has a sampling rate. It is not invoked on every page. The write path calls `balance_dirty_pages_ratelimited()`, which uses a per-CPU counter to decide when to call the full controller. The counter is set so that the controller runs every `ratelimit_pages` pages, where `ratelimit_pages` scales with the background threshold and the number of CPUs. This batching keeps the controller from becoming a bottleneck itself, but it also means the controller reacts with a delay. A burst of writes can push the dirty level well past the background threshold before the controller notices.

## Delayed allocation, extents, and the cost of a commit

Delayed allocation is one of the most important performance features in modern Linux filesystems, and it is also one of the reasons `fsync` can be surprisingly expensive. In ext4, XFS, and Btrfs, a buffered write does not immediately assign disk blocks. The page is marked dirty, and the filesystem waits. When writeback finally happens, the filesystem can see a large contiguous range of dirty pages and allocate a single large extent for them. That produces better on-disk layout, fewer extents, and less metadata.

The cost is shifted to the writeback and `fsync` paths. For ext4, `ext4_writepages()` must start a journal handle, reserve blocks, and map each page to a block before submitting I/O. If the file is large and was written quickly, that mapping work can be substantial. The journal handle may need to reserve space in the journal, and if the journal is full, the task can block waiting for a commit. The `fsync` caller may therefore spend time doing allocation work that could have been done in the background, simply because the filesystem deferred it to get a better layout.

XFS has a similar model with speculative preallocation. It may reserve more space than the current write needs, which reduces fragmentation but can leave unused extents if the file does not grow as expected. The log force on `fsync` is the durability point. XFS can batch log forces: if several `fsync` calls arrive while a log write is already in progress, they can share the same log flush. This is why XFS is often good under concurrent `fsync` load. The batching is not free; it increases the latency of the first `fsync` in the batch and reduces the marginal cost of the others.

Btrfs takes a different path. Its transaction commit is a global operation. When `btrfs_sync_file()` runs, it waits for the current transaction to commit, which writes all dirty metadata and data for that transaction and then writes a new superblock. The superblock write is itself a flush point. Because the commit is global, a single `fsync` can wait for data that has nothing to do with the file being synced. Under concurrent load, Btrfs can batch many `fsync` calls into one transaction commit, which is efficient, but the latency of an individual `fsync` depends on when it arrives relative to the transaction timer.

The journal commit in ext4 is worth examining because it is a common source of `fsync` latency. The journal is a circular log. A commit writes descriptor blocks, the metadata blocks (and data blocks in `data=journal` mode), and a commit record. It then issues a cache flush to make the commit durable. The commit is serialized: only one transaction can be committing at a time. Multiple `fsync` calls that need the same transaction wait on `jbd2_log_wait_commit()` for the transaction's tid to be committed. If the commit thread is slow — because the device is busy, because the journal is large, or because a flush is slow — every waiting `fsync` is slow.

`fdatasync` can skip some of this work, but only when the file's metadata does not need to be updated for data retrieval. If the file size changed, or if delayed allocation assigned new blocks, the metadata must be committed, and `fdatasync` becomes nearly as expensive as `fsync`. The POSIX distinction is real, but the filesystem's implementation determines how much it saves.

## Queue depth, tags, and the latency of a flush

Below the filesystem, the block layer has its own queueing model. Modern Linux uses blk-mq, which gives each CPU a software queue and each device a set of hardware dispatch queues. Each in-flight request consumes a tag. The number of tags is the device's queue depth. For NVMe, that can be thousands per queue. For SATA, it is 32. For a single spinning disk, it is effectively 1 unless NCQ is in use.

A flush request is not an ordinary request. It is a barrier. The block layer's flush state machine ensures that writes submitted after a flush do not reach the device until the flush completes. On a device with a deep queue, this can drain the queue: the device may have many writes in flight, but the flush must wait for them to complete, and subsequent writes must wait for the flush. The result is a bubble in the device's utilization and a latency spike for every I/O that is behind the flush. This is why a single `fsync` can cause a latency spike for unrelated reads and writes on the same device.

FUA writes are an alternative to preflush. A write with `REQ_FUA` tells the device to commit that write to stable media before reporting completion. If the device supports FUA natively, this avoids a separate flush command. If it does not, the kernel emulates FUA with a preflush and a postflush, which is worse than a single flush. Many consumer devices claim FUA support but implement it poorly, which is why some storage stacks prefer explicit flushes.

The I/O scheduler sits between the block layer and the device driver. For NVMe, the scheduler is often `none` because the device has its own internal scheduling. For SATA and spinning disks, `mq-deadline` or `bfq` may reorder requests to reduce seek time. A flush request is typically not reordered; it is a fence. The scheduler may still prioritize reads over writes, which can delay a flush behind a stream of reads. This is another way that `fsync` latency becomes a property of the whole system rather than of the file.

SSDs add another layer of queueing inside the device. The drive's controller has its own queue, its own garbage collection, and its own write cache. A flush may force the controller to write its flash translation layer mapping table and pending data from DRAM to NAND. That can take milliseconds, and it can be delayed by internal garbage collection. Under sustained write load, the SSD may enter a state where writes are much slower than its advertised peak. A flush during that state can take far longer than the nominal latency. The kernel's writeback bandwidth estimate may have been learned during the fast period, so it may continue to submit I/O at a rate the device can no longer sustain. The dirty pool grows, throttling kicks in, and `fsync` latency becomes both high and variable.

## What applications can control, and what they cannot

Applications cannot change the fact that a durable write must wait for the device to confirm that the data is on stable media. They can change how often they pay that cost and how much other work is in flight when they pay it.

The most effective technique is batching. Group commit takes many logical transactions and turns them into one `fsync`. The flush cost is amortized across the batch, and the device sees fewer barriers. The trade-off is that each transaction waits longer for its own commit, and a crash loses the whole batch. Databases tune this with a commit delay: wait a short time to see if more transactions arrive, then commit them together. The optimal delay depends on the arrival rate and the flush latency, which is exactly the kind of system property that changes under load.

A second technique is to separate the durability-critical writes from the bulk writes. Putting the write-ahead log on a different device from the data files isolates the flush traffic. If the log device has a power-loss-protected cache, the flush may be cheap. If it does not, the log device becomes the bottleneck. The separation only helps if the two devices do not share a controller, a cache, or a queue.

A third technique is to preallocate. `fallocate()` reserves blocks so that `fsync` does not have to allocate them. That removes the allocation work from the commit path and reduces fragmentation. It does not remove the need to write the data or flush the device, but it can turn a slow `fsync` into a faster one by moving work earlier.

A fourth technique is to use `sync_file_range()` to push data out before the commit point. The call asks the kernel to write a range of pages without waiting for metadata or issuing a device flush. It is a hint, and it is not portable across filesystems. It can reduce the amount of dirty data that `fsync` must handle, but it does not provide durability or ordering. Used carefully, it can smooth out writeback and reduce the burst of I/O at commit time.

A fifth technique is to use `io_uring` to submit `fsync` operations asynchronously. This does not make the device faster, but it allows an application to have many `fsync` operations in flight without tying up a thread per operation. The kernel still queues them, and the device still serializes flushes. The benefit is in application concurrency, not in device throughput.

What applications cannot control is the device's internal behavior, the firmware's interpretation of flush and FUA, the kernel's writeback bandwidth estimate, and the dirty backlog created by other processes on the same device. Those are system properties. The only way to improve them is to change the system: tune the dirty limits, isolate workloads with cgroups, choose devices that implement durability honestly, and measure the actual latency distribution rather than the average.

The remaining question is not whether to batch, but how to size the batch against the device's real flush latency under load. That is a measurement problem, and it is where the next layer of observability — per-request tracing of flushes and FUA writes — becomes necessary.

## Tracing a flush from bio to device command

The block layer tracepoints are the only place where the abstraction stops hiding the flush. `block:block_bio_queue`, `block:block_rq_issue`, and `block:block_rq_complete` each carry the operation flags. For a flush, the operation is not `REQ_OP_WRITE`; it is `REQ_OP_FLUSH`, or a write with `REQ_FUA`. In `blktrace` output, a flush appears as an `F` action, and an FUA write appears as a `W` with the FUA flag. If you only watch filesystem tracepoints, you see the fsync enter and exit; you do not see whether the cost was a journal commit, a data write, or a device flush. The block tracepoints separate those.

A minimal bpftrace script can count flush completions and their latencies:

```
kprobe:blk_account_io_done
{
  if (arg0->cmd_flags & 0x100) { @flush_ns = hist(nsecs - arg0->start_time_ns); }
}
```

But the flag constants vary by kernel version, and the request structure is opaque. A more robust approach is to use `bpftrace` with `tracepoint:block:block_rq_issue` and filter on `args->rwbs` containing `F`. The `rwbs` field is a string like `F`, `W`, `WS`, `WFS`, where `F` means flush, `S` means sync, and `M` means metadata. That string is stable enough for interactive work. For production, use `blktrace` with `-a flush` or `bpftrace` with a BTF-aware program that reads `req_op` and `req->cmd_flags`.

The tracepoint gives you the device, the sector, the length, and the command flags. It does not give you the filesystem or the file. To connect a flush to an application, you need to correlate by time and by queue. If the device is dedicated to one workload, that is enough. If it is shared, you need a stack trace. `bpftrace` can capture `kstack` at `block_rq_issue`, and the stack will show whether the flush came from `jbd2` (ext4 journal), from `xlog` (XFS log), from `btrfs_commit_transaction`, or from the writeback worker. That stack is the difference between the device is slow and the journal commit is slow because it is waiting for data writes.

## Latency histograms and the shape of the tail

Averages are useless for fsync. The distribution is usually bimodal or heavy-tailed, and the mean is a number that no individual call experiences. The first mode is the fast path: the file's data is already clean, the metadata is already committed, and the only cost is the device flush. The second mode is the slow path: the fsync must write data, allocate blocks, commit a journal transaction, and then flush.

A histogram of `fsync` latency collected with `bpftrace` or `perf` will show the two modes. If you correlate the slow mode with `nr_dirty` from `/proc/vmstat`, you will see that the slow calls happen when the dirty count is high. If you correlate with `block_rq_issue` flush counts, you will see that the slow calls happen when flushes are queued behind other I/O. If you correlate with `jbd2` tracepoints, you will see that the slow calls happen when a journal commit is in progress.

The tail is what matters for service-level objectives. A database that commits every transaction will see the 99th percentile of fsync latency, not the mean. If the tail is caused by queueing behind a large writeback burst, the fix is to reduce the burst: lower `dirty_background_ratio`, increase `dirty_expire_centisecs` so that background writeback spreads the work, or isolate the log device. If the tail is caused by the device's own garbage collection, no kernel tunable will fix it. The histogram tells you which.

## The writeback context as a shared object

Each backing device has a `struct bdi_writeback`. It owns the inode lists, the dirty counters, the bandwidth estimate, and the work items. When a filesystem is mounted, it creates a writeback context for the block device. When cgroup writeback is enabled, each memory cgroup that has dirty pages on that device gets its own `bdi_writeback`. The generic writeback code then iterates over the contexts, not just the device.

This is why cgroup writeback is not free. Every additional context adds a set of inode lists and counters, and the writeback worker must walk them. The isolation benefit is real: a container that writes heavily is throttled against its own dirty budget, and its writeback does not force other containers to wait. But the accounting must be correct. A page dirtied by a process in cgroup A must be attributed to cgroup A's writeback context. If the page is later written by a worker in cgroup B, the I/O may be charged to B unless the kernel preserves the original context. The kernel does preserve it for the common case, but there are edge cases: pages dirtied by kernel threads, pages from filesystems that do not support cgroup writeback, and pages that are migrated between cgroups.

The practical consequence is that cgroup writeback is an isolation mechanism that works best when the workload is well-behaved and the kernel is configured correctly. It is not a substitute for device-level isolation. If two containers share a device, they still share the device's queue, its cache, and its flush latency. Cgroup writeback controls the dirty budget, not the device's service time.

## When the device lies

The kernel's flush and FUA machinery assumes that the device honors the commands. That assumption is sometimes false. A device may report that a write is complete before the data is on stable media. It may accept a flush command and return success without actually flushing its cache. It may claim FUA support and ignore the FUA bit. These are firmware bugs, and they are not rare in consumer storage.

The kernel cannot detect a lying device from the outside. It can only observe that the device's reported latencies are suspiciously low. Some storage stacks add a verification layer: after a flush, they read back a known sector and compare. That is expensive and rarely done in production. The more common response is to disable the device's write cache entirely, which forces every write to stable media and makes flush unnecessary. That costs performance but buys honesty.

For applications that cannot tolerate a lying device, the only reliable approach is to use storage that is certified for the durability semantics you need, or to replicate across independent devices so that a single device's lie does not lose data. The kernel's writeback path can only be as durable as the device's weakest link.

## Measuring the cost of a commit under concurrency

The final measurement problem is concurrency. A single fsync on an idle system is not representative. The interesting number is the fsync latency when N threads are committing. As N grows, the flushes serialize, the queue fills, and the latency curve bends upward. The bend point is the device's effective flush throughput.

To measure it, run a synthetic workload that opens a file, writes a small record, calls fsync, and repeats. Vary the number of threads. Collect a histogram per thread count. You will typically see that throughput rises until the device's flush queue is saturated, then flattens or falls. The latency histogram shifts right and grows a tail. The optimal thread count for group commit is the point just before the bend, and it depends on the device's flush latency, not on the filesystem.

That bend point is also where the kernel's writeback bandwidth estimate matters. If the estimate is optimistic, the kernel submits more dirty pages than the device can absorb, the queue fills, and fsync latency spikes. If the estimate is pessimistic, the kernel writes too slowly, dirty pages accumulate, and throttling slows the writers. The estimate is learned, so it adapts, but it adapts with a delay. Under a step change in load, there is a window where it is wrong.

The next step is to look at how those measurements change when the writeback context is shared across cgroups, and what the kernel does when the device's queue depth is smaller than the number of concurrent commits.
