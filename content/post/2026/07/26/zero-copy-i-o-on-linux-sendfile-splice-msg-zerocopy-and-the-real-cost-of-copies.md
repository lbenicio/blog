---
title: "Zero-Copy I/O on Linux: sendfile, splice, MSG_ZEROCOPY, and the Real Cost of Copies"
description: "A systems-level accounting of what \"zero copy\" actually eliminates on Linux: the classic read/write path, sendfile and splice page stealing, MSG_ZEROCOPY pinning, io_uring SEND_ZC, AF_XDP, and the hidden costs of page pinning, completion notification, and copy-on-write interaction."
date: "2026-07-26"
author: "Leonardo Benicio"
tags: ["linux","kernel","io","networking","performance","systems-programming","memory"]
categories: ["Systems Design","Performance Engineering"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/zero-copy-i-o-on-linux-sendfile-splice-msg-zerocopy-and-the-real-cost-of-copies-2026-07-26.jpg"
coverAlt: "Dark isometric technical diagram showing two data paths between an NVMe drive and a network interface card: an upper amber path with four buffer stages and a lower cyan path that crosses the kernel boundary as a single continuous arrow carrying tethered page frames, with a memory bus band beneath."
---

Consider a caching proxy. A client asks for a 10 MB video segment, the segment is already sitting in the page cache on the proxy's NVMe drive, and the proxy needs to push those bytes down a TCP socket. The obvious implementation is a `read`/`write` loop with a 64 KB stack buffer. It works, it is portable, and on a modern server it will saturate a 10 GbE link without much trouble. It is also doing roughly four times the memory traffic that the problem strictly requires, and burning CPU cycles on `memcpy` that exist only because of an architectural boundary between user space and kernel space that the data never actually needs to cross.

The phrase "zero-copy I/O" gets used as though it describes a single feature you either have or don't. It doesn't. Linux exposes at least six distinct mechanisms that eliminate different copies in different parts of the path, each with its own preconditions, its own failure modes, and its own set of costs that the marketing term conveniently omits. `sendfile` and `splice` are twenty-year-old syscalls; `MSG_ZEROCOPY` and `io_uring`'s `SEND_ZC` are recent additions; `AF_XDP` and RDMA bypass the kernel network stack entirely. They do not compose freely, they do not all eliminate the same copy, and in several cases the copy they eliminate is cheaper than the machinery installed to avoid it.

This article is an attempt at a precise accounting. We will count the copies in the baseline path, identify which of them are CPU copies and which are DMA transfers, and then work through each mechanism in terms of exactly which copy it removes and what it charges in return.

## The baseline: what a read/write loop actually does

Start with the code everyone writes first:

```c
ssize_t n;
char buf[65536];

while ((n = read(file_fd, buf, sizeof buf)) > 0) {
    ssize_t off = 0;
    while (off < n) {
        ssize_t w = write(sock_fd, buf + off, n - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) { /* poll, then retry */ }
            else { /* real error */ }
        }
        off += w;
    }
}
```

For a single 64 KB chunk, the byte movements break down like this:

| # | Movement | Mechanism | Consumes CPU cycles? |
|---|----------|-----------|----------------------|
| 1 | Disk → page cache | DMA, block layer | No |
| 2 | Page cache → `buf` | `copy_to_user` | Yes |
| 3 | `buf` → socket send buffer | `copy_from_user` into `sk_buff` page frags | Yes |
| 4 | Socket buffer → NIC | DMA, TX descriptor ring | No |

Two of the four are DMA transfers initiated by hardware. Two are `memcpy`-class operations executed by the CPU, and both of them exist purely to move bytes across the user/kernel boundary. If the data is already in the page cache, movement 1 has already happened and is not repeated; movement 4 is deferred until the TCP window opens and the qdisc decides to transmit.

Alongside the copies there is a second cost: mode switches. Each `read` and each `write` crosses the user/kernel boundary twice — once on entry, once on return. That is four transitions per 64 KB chunk, so roughly 640 for the 10 MB transfer, plus the scheduler's involvement whenever the socket buffer is full and the writer must block or poll. With larger buffers the syscall count drops but the working set grows and the cache footprint of the staging buffer grows with it. There is no buffer size that makes both problems go away, because the buffer itself is the problem.

Movement 3 deserves a note about how modern kernels actually store socket data. A `sk_buff` does not carry a linear payload array in the general case. `tcp_sendmsg_locked` copies user data into page fragments drawn from the socket's `sk_page_frag` cache, and the `sk_buff` holds a `skb_shared_info` with an array of `skb_frag_t` descriptors pointing at those pages. This matters because it means the transmit path is already structured around *references to pages* rather than *contiguous bytes*. That structure is precisely what makes `sendfile` possible: if the payload is a list of page references, then a page from the page cache is as good a referent as a page the kernel just allocated.

## Why the copies are expensive even when they are fast

A `memcpy` of 64 KB is not slow in isolation. On a modern x86-64 core with AVX-512 and non-temporal stores it runs at tens of gigabytes per second, and the kernel's `copy_user_enhanced_fast_string` path is well-tuned. The cost is not the instruction count; it is the second-order effects.

First, the copy consumes memory bandwidth. A 10 GbE link moves about 1.25 GB/s of payload. Each CPU copy doubles the read and write traffic attributable to that payload, and each DMA transfer consumes bandwidth on the same memory controller. On a single-socket server with 100 GB/s of theoretical DRAM bandwidth this is invisible. On a 100 GbE link, or on a machine running many such connections concurrently, the arithmetic changes: the copies are competing with the application's own working set for the same resource, and memory bandwidth is the resource that most parallel workloads actually saturate.

Second, the staging buffer pollutes cache. The 64 KB buffer is read once and written once, and neither access has any reuse. It displaces lines that the application or another thread on the same core might have used. Non-temporal stores mitigate this for the write side but not for the read, and the kernel's copy routines are not generally tuned for streaming access patterns.

Third, and least obviously, the copy is a *serialization point*. The thread doing the copy is not doing anything else. In a thread-per-connection server that is fine. In an event loop or a work-stealing runtime, a 64 KB copy is a burst of work that cannot be interleaved with anything, and it shows up in tail latency measurements as a jitter source that has nothing to do with the network.

None of this argues that the baseline loop is wrong. It argues that the baseline loop pays for a boundary crossing that the data does not need, and that the price is proportional to the payload size. For a 200-byte JSON response the price is negligible and the loop is the right answer. For a 10 MB video segment it is not.

## The enabling condition: why page references are enough

Before walking through the mechanisms, it is worth being explicit about the hardware precondition that makes any of this work on the transmit side. Handing the NIC a set of page references instead of a contiguous buffer only avoids a CPU copy if the NIC can perform *scatter-gather DMA*: read from a list of physical addresses rather than one. Virtually every server NIC built this century can.

The second precondition is that the kernel must not need to touch the payload. TCP will compute a checksum over every byte it sends, and it will segment a large write into MSS-sized pieces. Both of those are CPU work over the payload, and both would force the kernel to read every byte — which is cheaper than copying it, but still not free. The escape hatch is offload: TCP Segmentation Offload (TSO) lets the kernel hand the NIC a single large descriptor covering many MSS, and the NIC performs the segmentation; checksum offload lets the NIC compute the checksum in hardware during transmission. With both enabled, the kernel can build a transmit descriptor that references page cache pages and never read a byte of them.

This is why "zero-copy" on the transmit path is really "zero-copy *given* TSO and checksum offload." Turn offloads off — as some virtualized environments and some security-hardened configurations do — and `sendfile` still avoids the user-space copy, but the kernel must now walk the payload to segment and checksum it. The copy is gone; the traversal is not.

## An inventory of mechanisms

Here is the landscape, with each entry characterized by the copy it removes:

- **`sendfile(2)`** — file descriptor to socket, entirely in kernel space. Removes copies 2 and 3 from the table above. Available since Linux 2.2; the Linux version is one-directional (file → socket), unlike the BSD original.
- **`splice(2)` / `tee(2)` / `vmsplice(2)`** — move pages between arbitrary file descriptors through an in-kernel pipe. Removes copies 2 and 3 and generalizes beyond file→socket. Added in 2.6.17 (`splice`, `tee`) and 2.6.23 (`vmsplice`).
- **`copy_file_range(2)`** — in-kernel copy between two files, potentially implemented as a reflink on filesystems that support it. Removes copies 2 and 3 for the file-to-file case.
- **`MSG_ZEROCOPY` on `sendmsg`** — removes copy 3 by pinning user pages and transmitting directly from them; the application supplies the buffer, so copy 2 never existed. Requires `SO_ZEROCOPY`, and requires completion notification so the application knows when the pages are free again.
- **`io_uring` `SEND_ZC`** — the same idea expressed as an asynchronous submission, with completion delivered through the ring rather than the socket error queue.
- **`AF_XDP` zero-copy** — removes the kernel network stack from the receive and transmit paths entirely, with the NIC DMAing into user-registered UMEM frames.
- **RDMA / `ibverbs`** — removes the kernel from the data path and moves the copy to the peer's memory over the fabric.
- **kTLS with hardware offload** — not a copy-avoidance mechanism per se, but the thing that lets `sendfile` be used for HTTPS, by moving record protection into the kernel or the NIC.

Each of these has a different notion of what "the data" is and who owns it. `sendfile` and `splice` borrow pages that the page cache already owns and will keep owning. `MSG_ZEROCOPY` borrows pages the application owns and must not modify. `AF_XDP` and RDMA use memory that has been registered with the hardware in advance. The ownership question determines the failure modes, and it is where the interesting engineering lives.

With that accounting in hand, we can take each mechanism in turn — starting with `sendfile`, the oldest, the most widely deployed, and the one whose limitations shaped everything that came after it.

## sendfile: the hidden pipe and the page cache borrow

`sendfile(2)` is the oldest and most widely deployed zero-copy primitive on Linux. Its interface is deceptively simple: `sendfile(out_fd, in_fd, offset, count)`, where `in_fd` is a file and `out_fd` is a socket. It removes copies 2 and 3 from the baseline table by never materializing the payload in user space. But the implementation is not a single straight-line kernel function; it is a composition of the splice machinery, and understanding its limits requires looking at the plumbing.

The Linux `sendfile` is implemented on top of `splice`. In `fs/splice.c`, `do_sendfile` calls `do_splice_direct`, which in turn calls `splice_direct_to_actor`. That function uses a per-task pipe, `current->splice_pipe`, allocated lazily on the first call. The operation proceeds in a loop: splice pages from the input file into the internal pipe, then splice them from the pipe to the output socket. The pipe is the staging area, but it does not hold copies of the data. It holds `struct pipe_buffer` entries that reference page cache pages, with the `page_cache_pipe_buf_ops` operations. Each buffer records the page, an offset, and a length.

The per-task pipe has a default capacity of 16 pages, or 64 KB. That is the maximum amount of data `sendfile` can have in flight per call. It is not a tunable through any user-visible interface; the internal pipe is created with `alloc_pipe_info()` and is not exposed as a file descriptor. This is a real throughput ceiling. For a 10 MB transfer, `sendfile` will loop roughly 160 times, each time filling the pipe with up to 64 KB and then draining it into the socket. The syscall overhead is amortized, but the pipeline depth is shallow. Some workloads increase throughput by using `splice` directly with a user-space pipe that can be resized via `fcntl(F_SETPIPE_SZ)`, which we will discuss in the next section. `sendfile` itself does not offer that control.

The pages themselves are borrowed from the page cache. When `sendfile` splices a file into the pipe, it calls `get_page` on each page, incrementing its reference count. The page is now pinned: it cannot be reclaimed or evicted while the reference is held. When the pipe is drained into the socket, the kernel attempts to transfer the page reference into the socket's transmit queue. A `sk_buff` does not carry a linear payload by default; it carries a `skb_shared_info` with an array of `skb_frag_t` descriptors, each pointing at a page and an offset. The page from the page cache can be used directly as a fragment. The socket's send path, `tcp_sendmsg_locked` or its splice-aware equivalent, attaches the page to the `sk_buff` and releases the pipe buffer's reference. The page remains pinned by the socket buffer until the data has been acknowledged and the `sk_buff` is freed.

This is the essence of the zero-copy claim: the page cache page is never copied. It is referenced by the pipe, then by the socket buffer, then DMA'd to the NIC. The CPU never touches the payload bytes. But the claim comes with several sharp edges.

The first is semantic. Because the socket transmits whatever is in the page at the time the NIC reads it, `sendfile` provides no atomicity. If the file is modified concurrently—by another thread, by a different process, or by a writeback—the receiver may see a mixture of old and new data. The `read`/`write` loop, by contrast, copies the data into a user buffer at a specific point in time, so each `read` returns a consistent snapshot of the requested range. For static content, this does not matter. For a file that is being appended to or rewritten, it does. This is a documented caveat, and it is the reason `sendfile` is not used for files that are actively being modified without external synchronization.

The second is the pinning cost. Every page in flight is pinned. The pipe limits the in-flight pages to 16, but the socket send buffer can hold many more. The amount of data that can be queued in the socket is bounded by `SO_SNDBUF`, which defaults to a few hundred kilobytes and can be tuned. For a fast sender and a slow receiver, the socket buffer fills, and `sendfile` blocks or returns `EAGAIN`. While the buffer is full, all those pages are pinned and cannot be reclaimed. On a server with thousands of connections, the aggregate pinned memory can be substantial. This is not a leak—the pages are released when the socket buffer drains—but it is memory pressure that the baseline `read`/`write` loop does not create, because the staging buffer is a fixed, small allocation.

The third is the interaction with offloads. As noted earlier, `sendfile` only avoids the CPU traversal of the payload if TSO and checksum offload are active. Without TSO, the kernel must segment the data into MSS-sized pieces, which means it must walk the page fragments and build multiple `sk_buff`s. That is not a copy, but it is a read of every byte. Without checksum offload, the kernel must compute the TCP checksum over the payload, which is another full traversal. In virtualized environments, offloads are often disabled or emulated by the hypervisor, and `sendfile` can lose much of its advantage. The copy is gone, but the CPU still spends cycles per byte.

The fourth is the input constraint. `sendfile` requires that `in_fd` be a file that supports the `splice_read` operation. Regular files on most filesystems do. But files opened with `O_DIRECT` do not; `sendfile` returns `EINVAL`. Pipes, sockets, and character devices are not valid inputs. This means `sendfile` cannot be used to forward data from one socket to another, which is a common proxy pattern. For that, you need `splice` with a user-space pipe, or `MSG_ZEROCOPY`.

Finally, there is the TLS problem. A proxy serving HTTPS cannot use `sendfile` on encrypted content, because the encryption must happen in user space. The kernel's `sendfile` would transmit plaintext. The solution is kTLS: the kernel TLS implementation can encrypt records in the kernel, either in software or with NIC offload. With software kTLS, `sendfile` can be used, but the kernel must read every byte to encrypt it, so the CPU still touches the payload. With NIC TLS offload, the NIC performs the encryption, and `sendfile` becomes truly zero-copy end to end. This is why kTLS is a prerequisite for high-performance HTTPS proxies that want to use `sendfile`.

In summary, `sendfile` is a powerful optimization for the specific case of sending a static file to a socket on a system with offloads enabled and no concurrent modification. It removes two CPU copies and the associated user/kernel mode switches. It does not remove the DMA transfers, and it introduces page pinning, a 64 KB in-flight limit, and weaker consistency semantics. It is not a general-purpose zero-copy primitive; it is a specialized one.

## splice: the general plumbing and its sharp edges

`splice(2)` is the general mechanism that `sendfile` uses internally. It moves pages between two file descriptors through a pipe, without copying the payload. The signature is `splice(fd_in, off_in, fd_out, off_out, len, flags)`. At least one of `fd_in` or `fd_out` must be a pipe. You cannot splice directly from a file to a socket; you must create a pipe, splice the file into it, and then splice the pipe into the socket. That two-step dance is exactly what `sendfile` does with its hidden per-task pipe, but exposing the pipe to user space gives you control.

The pipe is the central abstraction. It is a ring buffer of `struct pipe_buffer` entries, each holding a reference to a page, an offset, and a length. The default pipe capacity is 16 pages (64 KB), but you can change it with `fcntl(fd, F_SETPIPE_SZ, size)`. The maximum is governed by `/proc/sys/fs/pipe-max-size`, typically 1 MB, and unprivileged users can set it up to that limit. A larger pipe means more pages can be in flight between the two splice calls, which reduces syscall overhead and improves throughput. It also means more pinned memory and more latency. Tuning the pipe size is a classic trade-off.

The first splice, from a file to a pipe, calls the file's `splice_read` operation. For a regular file, this reads pages from the page cache into the pipe. If the page is not in the cache, it is read from disk first. The pipe buffer ops for page cache pages are `page_cache_pipe_buf_ops`. These ops include a `try_steal` method, which is the key to avoiding a copy on the second splice. When the second splice, from the pipe to the socket, is executed, the kernel calls the socket's `splice_write` operation. The generic `splice_from_pipe` helper iterates over the pipe buffers. For each buffer, it calls `pipe_buf_steal` to see if the page can be moved out of the pipe and into the destination without copying. If the steal succeeds, the page reference is transferred directly. If it fails, the kernel falls back to copying the data into the destination's buffer.

For a page cache page, `try_steal` checks whether the page is exclusively owned by the pipe. In practice, this means it checks whether the page is not mapped into any user process and not referenced elsewhere. If the file is mmap'd by another process, or if the page is shared for any reason, the steal fails and `splice` copies. This is an important and often overlooked point: **`splice` is not guaranteed to be zero-copy**. It attempts to steal the page, and if it cannot, it copies. The condition for stealing is that the page is not shared. For a static file that is not mmap'd, the page cache page is only referenced by the page cache and the pipe, so the steal can succeed. For a file that is being read by other processes via mmap, or for a page that is part of a shared library, the steal may fail. The kernel does not tell you which path it took. You can observe it indirectly through CPU usage: if `splice` is copying, the `memcpy` will show up in profiles.

The same logic applies to `vmsplice(2)`, which splices from user memory into a pipe. `vmsplice` takes a `struct iovec` array and pins the user pages, creating pipe buffers with `user_page_pipe_buf_ops`. These ops have `try_steal = NULL`, meaning the pages cannot be stolen. When you subsequently splice from that pipe to a socket, the kernel must copy the data out of the user pages into the socket buffer. So `vmsplice` is not a zero-copy send mechanism. It is a zero-copy *input* mechanism: it gets user pages into the splice pipeline without copying, but the final step to the socket still copies. The `SPLICE_F_GIFT` flag allows you to gift the pages to the kernel, but even then, the `user_page_pipe_buf_ops` do not support stealing, so the copy remains. This is a common source of confusion. If you want true zero-copy send from user memory, you need `MSG_ZEROCOPY`, which we will cover next.

For receive-side zero-copy, `splice` can move pages from a socket to a pipe, and then to a file. The socket's `splice_read` operation can attach the pages from the receive queue's `sk_buff` fragments to the pipe. Those pages were DMA'd into by the NIC, so they are already in kernel memory. If the pipe is then spliced to a file, the pages can be written to the page cache without a copy, provided the filesystem supports it and the pages can be stolen. This is used by some high-performance proxies to write incoming data to disk without a user-space copy. But the same caveats apply: the pages may be shared, and the steal may fail.

The pipe itself is a bottleneck. Every byte that goes through `splice` passes through the pipe, which means it is subject to the pipe's locking and the per-buffer overhead. The pipe is not a zero-cost abstraction. It is a kernel object with its own locks, and the `splice` calls must acquire and release them. For very high throughput, the pipe can become a contention point, especially if multiple threads share it. Each `splice` call also crosses the user/kernel boundary, so the syscall overhead is still present, albeit half as many as the `read`/`write` loop (two syscalls per chunk instead of two, but each handles more data). You can reduce the overhead by using large pipe buffers and large splice lengths, but you cannot eliminate it.

Another sharp edge is the interaction with `O_NONBLOCK`. `splice` can return `EAGAIN` if the pipe is full or the socket buffer is full. You must handle that with `poll` or `epoll`, just like the baseline loop. The difference is that the data is in kernel pages, not a user buffer, so you do not need to maintain a staging buffer. But you do need to manage the pipe's state. If you are splicing from a file to a socket, you must keep track of the file offset and the amount of data remaining. The `splice` call updates the file offset if `off_in` is NULL, but if you are using an explicit offset, you must manage it yourself.

Finally, `splice` does not compose with `sendfile` in a straightforward way. You cannot `sendfile` from a pipe. You cannot `splice` from a socket to another socket directly; you need a pipe in between, and the data will be copied if the pages cannot be stolen. The kernel's page stealing is opportunistic, and its success depends on the memory layout and sharing patterns of the pages involved. This makes `splice` a powerful but unpredictable tool. It can be zero-copy, but it can also silently degrade to a copy. The only way to know is to measure.

## MSG_ZEROCOPY: user pages on the wire

`MSG_ZEROCOPY` is the first mechanism that lets an application transmit from memory it already owns without the kernel copying it into a socket buffer. The setup is two flags: `setsockopt(fd, SOL_SOCKET, SO_ZEROCOPY, &one, sizeof one)` enables the feature on the socket, and each `sendmsg` call passes `MSG_ZEROCOPY` in `msg_flags`. If the kernel can honor the request, it pins the user pages backing the `iovec` array and builds `sk_buff` fragments that point at those pages. The `copy_from_user` that dominates the baseline path disappears.

The pinning is the first cost. The kernel calls `get_user_pages` (or its modern `pin_user_pages` variant) over the buffer. That walks the page tables, takes the `mmap_lock` in read mode, and increments the reference count on every page. For a 1 MB send that is 256 pages; for a 10 MB send it is 2560 pages. The walk is not free, and it scales with the number of pages rather than the number of bytes. A send of one 64 KB page is cheaper to pin than a send of 64 KB spread across 16 pages. This is the opposite of the copy path, where the cost is proportional to bytes. It means `MSG_ZEROCOPY` favors large, page-aligned, physically contiguous buffers, which is exactly what a well-designed application can provide but a generic one often cannot.

Once pinned, the pages are referenced by the socket's transmit queue. They remain pinned until the data has been acknowledged by the peer and the `sk_buff` is freed. For TCP, that means until the ACK covering the sequence number arrives. For UDP, it means until the packet has been handed to the NIC and the completion is processed. The application must not modify the buffer during this window. If it does, the receiver may see a torn mixture of old and new bytes. There is no kernel enforcement of this rule; it is a contract, and violating it produces silent corruption.

The completion problem is the second cost. The application needs to know when the pages are safe to reuse. `MSG_ZEROCOPY` delivers that information through the socket error queue. The application must poll for `EPOLLERR` and then call `recvmsg` with `MSG_ERRQUEUE` to dequeue `struct sock_extended_err` records. Each record carries an `ee_info` field that identifies the range of the send that has completed. The application tracks outstanding ranges and returns buffers to its pool when the corresponding completion arrives.

This is an awkward API for several reasons. The error queue is a shared control channel; it can also carry other socket errors, so the application must filter by `ee_origin == SO_EE_ORIGIN_ZEROCOPY`. The queue has a finite depth. If the application does not drain it fast enough, completions can be lost, and the send path may fall back to copying or fail. The notification is not a data-path event; it arrives on a different code path, often in a different thread or event-loop iteration. Integrating it into an epoll-based server requires adding the socket to the epoll set for `EPOLLERR` and handling a non-obvious read pattern. The syscall count is lower than the baseline loop, but the complexity is higher.

There is also a fallback path. If the kernel cannot pin the pages, or if the NIC or route does not support the necessary scatter-gather, `MSG_ZEROCOPY` may copy instead. The completion record indicates this with `SO_EE_CODE_ZEROCOPY_COPIED`. An application that ignores the flag may believe it is zero-copy when it is not. The flag is the only way to know.

## io_uring SEND_ZC: the same trade with a better completion channel

`io_uring` exposes the same zerocopy transmit capability as `IORING_OP_SEND_ZC`. The submission queue entry carries the buffer, length, and flags; the kernel performs the same pinning and builds the same page-referencing `sk_buff`s. The difference is the completion mechanism. Instead of the socket error queue, `SEND_ZC` posts two completion queue entries: the first when the send has been accepted and the bytes have been queued, and the second when the pages are safe to reuse. The second CQE has the `IORING_CQE_F_NOTIF` flag set.

This is a meaningful improvement for event-driven applications. The completion ring is already the place where I/O results are reaped, so there is no separate error-queue polling path. The application can batch submissions and reap completions in one `io_uring_enter` call. The notification is still asynchronous and still requires the application to track buffer lifetimes, but the bookkeeping is uniform with the rest of its I/O.

The costs that remain are the ones intrinsic to zerocopy. Pages are pinned. The buffer must remain immutable until the notification CQE arrives. The application must not return the buffer to a free pool on the first CQE; it must wait for the second. If the peer is slow to acknowledge, the notification is delayed, and a fixed-size buffer pool can be exhausted. This is a flow-control problem: the number of outstanding zerocopy sends is bounded by the number of buffers the application is willing to pin, not by the socket send buffer alone.

The two-CQE model also puts pressure on the completion ring. Each send produces two completions, so a ring sized for N operations must accommodate 2N completions in the worst case. If the ring overflows, the application must handle `IORING_SQ_NEED_WAKEUP` and drain more aggressively. The kernel may also coalesce notifications, but the application cannot rely on that.

`SEND_ZC` does not eliminate the need for offloads. TSO and checksum offload are still required for the kernel to avoid reading the payload. Without them, the kernel walks the pinned pages to segment and checksum, which is cheaper than copying but not free. In a virtualized guest with no TSO, `SEND_ZC` can be slower than a plain `write` because it adds pinning and completion overhead on top of the traversal.

## AF_XDP: moving the boundary to the driver

`AF_XDP` is a different kind of zero-copy. It does not optimize the path through the kernel network stack; it removes the kernel network stack from the data path for a specific queue on a specific NIC. The application creates an `AF_XDP` socket, registers a user memory area (`UMEM`) with the kernel, and exchanges descriptors through four rings: the fill ring, the receive ring, the transmit ring, and the completion ring.

In zero-copy mode, the NIC DMAs received frames directly into the UMEM frames that the application has published on the fill ring. The application reads descriptors from the receive ring, processes the frames in place, and either drops them or transmits them by putting descriptors on the transmit ring. The NIC reads the frames directly from UMEM and writes completion descriptors when the transmission is done. No `sk_buff` is allocated, no page is copied, and the kernel network stack is bypassed entirely.

The cost is that the application now owns the network stack. It sees Ethernet frames, not TCP streams. If it needs TCP, it must implement TCP in user space or use a user-space TCP stack. For UDP or custom protocols, this is feasible; for general-purpose TCP, it is a large undertaking. The kernel's TCP stack is not available on the AF_XDP path.

The other costs are operational. Zero-copy AF_XDP requires driver support and binds to a specific queue. The application must dedicate a CPU core to polling the rings, because the model is busy-polling, not interrupt-driven. That core cannot be shared with other work without introducing latency jitter. The UMEM frames are pinned for the lifetime of the socket, so the memory is not reclaimable. The fill ring must be replenished continuously; if it runs dry, the NIC drops packets. The transmit completion ring must be drained; if it fills, the application cannot submit more frames. These are all flow-control problems that the kernel stack normally handles for free.

AF_XDP is not a drop-in replacement for `sendfile` or `MSG_ZEROCOPY`. It is a different architecture, appropriate for specialized packet-processing workloads, not for a caching proxy that wants to push a file to a TCP socket.

## The hidden costs: pinning, completion, and copy-on-write

Across all of these mechanisms, the same three costs recur: page pinning, completion notification, and the interaction with copy-on-write.

Page pinning is the most concrete. A pinned page cannot be reclaimed, migrated, or swapped. It is removed from the kernel's ability to manage memory. On a system with many zerocopy sends in flight, the aggregate pinned memory can be large, and it is invisible to the usual memory-pressure metrics. It also fragments the physical address space, because pinned pages cannot be moved to make room for huge pages or contiguous allocations. The `get_user_pages` walk itself is expensive: it takes `mmap_lock`, walks page tables, and may split transparent huge pages if the buffer is not aligned. For a 10 MB buffer, the walk can cost more than the `memcpy` it replaces if the buffer is scattered across many small pages.

Completion notification is the second cost. The kernel must track which pages belong to which send and signal the application when they are free. That bookkeeping is per-range, not per-byte, but it still requires memory and CPU. The application must maintain a matching data structure. The notification path is asynchronous, so the application must handle the case where a completion arrives after the connection has been closed or the buffer pool has been resized. The completion can also be delayed indefinitely if the peer stops acknowledging, which means the pages remain pinned. There is no timeout in the kernel that will forcibly release them; the connection must be torn down.

Copy-on-write is the third cost, and it is the most subtle. When the kernel pins a user page for zerocopy transmit, it pins the current physical page. If the page is part of a private mapping and another process writes to it, the kernel performs a copy-on-write: the writer gets a new physical page, and the pinned page retains the old contents. The receiver sees the old data. This is safe but may be surprising. If the same process writes to the buffer after the send, it modifies the pinned page directly, and the receiver may see the new data. This is the contract violation that zerocopy APIs warn about. It is also why `fork()` interacts badly with zerocopy: a forked child shares the same physical pages until it writes, and a write in the child triggers COW, leaving the parent's pinned page unchanged. The child's write does not affect the send, but the parent's later write does.

The practical consequence is that zerocopy transmit is only safe with buffers that are exclusively owned, never written during the send, and ideally page-aligned and huge-page backed. That is a narrow set of conditions. When they are met, zerocopy removes a real cost. When they are not, it can add cost and complexity without removing the copy.

## Observing whether the copy actually disappeared

It is easy to write code that passes `MSG_ZEROCOPY` or `IORING_OP_SEND_ZC` and assume the copy is gone. The kernel will not always agree. The only reliable way to know is to measure.

On the transmit side, the baseline copy shows up in profiles as `copy_user_enhanced_fast_string`, `_copy_from_user`, `tcp_sendmsg_locked`, or `skb_copy_datagram_iter`. If a workload claims to be zero-copy but those symbols still dominate, the copy is still happening, either because the mechanism fell back or because another part of the path is copying. `perf top` and `perf record` are crude but effective for this. `bpftrace` can attach to `copy_user_enhanced_fast_string` and count call sites by stack, which distinguishes the application's own copies from the kernel's.

For `MSG_ZEROCOPY`, the `SO_EE_CODE_ZEROCOPY_COPIED` flag is authoritative. If it appears in the error queue, at least some sends were copied. For `sendfile` and `splice`, there is no equivalent flag. The only signal is the absence of copy symbols in the profile and the presence of page-stealing activity in the page cache. A `splice` that fails to steal pages will copy, and the profile will show `memcpy` or `copy_page_to_iter` in the splice path.

On the receive side, the situation is reversed. `AF_XDP` zero-copy is observable through the driver's statistics: the number of packets delivered to the XDP socket versus the number dropped because the fill ring was empty. A non-zero drop count means the application is not replenishing fast enough, which is a cost that the kernel stack would have absorbed invisibly. For `splice` from a socket to a file, the relevant signal is whether the receive pages are stolen into the pipe or copied. Again, the profile is the arbiter.

The absence of these symbols in a profile is the only reliable evidence that a copy has been eliminated. The presence of a zero-copy API call is not.

## Receive-side zero-copy is not the mirror image

Transmit zero-copy is easier to reason about because the kernel already owns the pages it is sending. A file in the page cache is a set of pages that the kernel can borrow, reference-count, and hand to the NIC. Receive is different. When a packet arrives, the NIC DMAs it into memory that the kernel allocated for the driver. That memory is typically held in page fragments attached to `sk_buff`s. To deliver it to the application without a copy, the kernel must either map those pages into the application's address space, or the application must have provided the memory in advance and the NIC must DMA into it directly.

`TCP_ZEROCOPY_RECEIVE` is the kernel's attempt at the first approach. The application calls `setsockopt` with `TCP_ZEROCOPY_RECEIVE`, passing a structure that describes a user address range. The kernel takes pages from the TCP receive queue and inserts them into the process's page tables with `vm_insert_page`. The application then reads the data from that address range. No `copy_to_user` occurs. But the details matter. The pages must be page-aligned and the receive queue must actually contain page fragments. If the NIC driver or the receive path produced a linear `sk_buff`, or if the data was coalesced into a single buffer, there are no pages to map. TLS, BPF socket filters, and other transformations can also force the data into a linear buffer. The result is that `TCP_ZEROCOPY_RECEIVE` works on some flows and not others, and the application must be prepared for the copy fallback. It also changes the lifetime of the pages: they are now mapped into user space, so the kernel must track the mapping and unmap it when the application is done. That unmapping can trigger TLB shootdowns, which are not free.

The second approach is AF_XDP, which we discussed earlier. It is not a receive optimization for TCP; it is a replacement for the kernel network stack. The application owns the UMEM, and the NIC DMAs directly into it. The application never sees a `sk_buff`. This is true zero-copy receive, but only for the protocols the application implements itself.

There is no `MSG_ZEROCOPY` equivalent for receive. The socket error queue mechanism is transmit-only. An application that wants zero-copy receive on TCP must use `TCP_ZEROCOPY_RECEIVE`, and an application that wants it for a custom protocol must use AF_XDP or RDMA. The asymmetry is not an accident. On transmit, the kernel can borrow pages that already exist and are immutable. On receive, the data does not exist until the NIC writes it, so either the kernel must own the buffer and map it, or the application must own the buffer and register it with the hardware. Both have costs.

## The page table becomes the bottleneck

When a copy is removed, the work does not vanish; it moves. In the baseline `read`/`write` path, the CPU spends cycles in `memcpy`. In a zero-copy path, the CPU spends cycles walking page tables, pinning pages, inserting mappings, and later tearing them down. On a modern CPU, a `memcpy` of a page-sized buffer is a few hundred cycles. A `get_user_pages` call over the same page is also a few hundred cycles, but it takes locks, touches page table entries, and may split huge pages. The arithmetic is not obviously in zero-copy's favor.

The page table walk is the first cost. `pin_user_pages` must find the `struct page` for each virtual address. That requires walking the radix tree or xarray of the process's page tables. If the pages are not present, it must fault them in. If the pages are part of a transparent huge page, it may split the huge page into 4 KB pages unless the entire range is aligned and covered. Splitting a huge page is expensive and has system-wide effects: it increases TLB pressure for every process that maps that memory. This is why zerocopy APIs often recommend huge-page-backed buffers. A 2 MB huge page can be pinned with a single page table entry, but only if the buffer is aligned to 2 MB and the underlying filesystem or `memfd` supports huge pages. Most application buffers do not meet that condition.

The TLB is the second cost. Pinning a page does not remove it from the TLB, but mapping a page into user space with `TCP_ZEROCOPY_RECEIVE` does add a mapping. When that mapping is removed, the kernel must invalidate the TLB entry on every CPU that might have it. On a large multi-socket system, that is an inter-processor interrupt to each core. A high-rate receive path that maps and unmaps pages continuously can spend a surprising amount of time in TLB shootdown. The kernel tries to batch shootdowns, but the cost is still there. It is invisible in a `memcpy` profile because it shows up as IPI and scheduler overhead, not as a copy function.

The third cost is accounting. Pinned pages are not on the LRU, so the kernel's reclaim logic cannot evict them. They still count against the process's memory, but they do not participate in page reclaim. A process that pins a large buffer and then blocks for a long time can cause the system to OOM even though it appears to have free memory. The kernel has mechanisms to detect long-term pins and to warn or fail, but the application still has to manage the lifetime. For `MSG_ZEROCOPY`, the lifetime is bounded by the peer's ACK. For `TCP_ZEROCOPY_RECEIVE`, the lifetime is bounded by the application's unmap. For AF_XDP, the lifetime is the socket. None of these are automatically tied to memory pressure.

## Zero-copy and the virtual memory subsystem

The virtual memory subsystem is where many of the hidden costs accumulate. `sendfile` and `splice` borrow page cache pages, which means they interact with the page cache's reclaim and writeback logic. If the file is mapped into a process with `mmap`, the page may be shared, and the page-stealing path in `splice` may fail. The kernel does not tell you when this happens; the operation silently falls back to a copy. The same file can be zero-copy for one process and copying for another, depending on whether any process has it mapped.

`MSG_ZEROCOPY` pins pages from the application's address space. If those pages are anonymous memory, the pin is straightforward but the pages are not reclaimable. If they are file-backed, the pin prevents writeback from relocating the page, and a write to the file can interact badly with the in-flight send. If they are `MAP_PRIVATE`, a write in the process triggers copy-on-write, leaving the pinned page with the old contents. The receiver sees the old data, which is safe but may be surprising. If they are `MAP_SHARED`, a write modifies the pinned page directly, and the receiver may see the new data. This is the contract violation that zerocopy APIs warn about.

A practical way to avoid many of these problems is to allocate zerocopy buffers with `memfd_create` and enable huge pages with `MFD_HUGETLB` or `MADV_HUGEPAGE`. The pages are then file-backed but private to the process, they can be huge, and they are not subject to ordinary writeback in a way that changes their contents. The buffer pool can be registered once and reused. The remaining cost is the pinning walk, which is cheaper when the pages are huge and aligned. This pattern is common in high-performance networking code for good reason.

`vmsplice` deserves a note in this context because it is often misunderstood. It splices user pages into a pipe, which sounds like a zero-copy send. But the pipe buffers created from user pages use `user_page_pipe_buf_ops`, and those operations do not support stealing. When the pipe is later spliced to a socket, the kernel must copy the data out of the user pages. The `SPLICE_F_GIFT` flag allows the application to give the pages to the kernel, but even then the copy remains on the socket side. `vmsplice` is useful for getting user pages into the splice pipeline without copying, but it is not a zero-copy transmit mechanism on its own. If you need zero-copy transmit from user memory, `MSG_ZEROCOPY` or `io_uring SEND_ZC` is the correct tool.

## Encryption, QUIC, and the copy you cannot remove

The most common reason a zero-copy path silently degrades is encryption. A file in the page cache is plaintext. A TCP socket carrying HTTPS must carry ciphertext. Something must transform one into the other. If that something is user-space code, the plaintext must be copied into a user buffer, encrypted, and then sent from the encrypted buffer. The copy from page cache to user buffer is unavoidable. `sendfile` cannot help, because `sendfile` would send the plaintext.

kTLS changes the equation, but only partially. With software kTLS, the kernel performs the encryption. `sendfile` can still be used because the kernel owns both the file pages and the socket. But the kernel must read every byte of plaintext to encrypt it. The CPU copy from page cache to socket buffer is replaced by a CPU read of the page cache and a write of ciphertext into the socket buffer. That is not zero-copy; it is a different copy, performed by the crypto code. The advantage is that it happens in the kernel, without a user/kernel boundary crossing, and it can use vectorized AES instructions. The disadvantage is that it still consumes memory bandwidth and CPU cycles proportional to the payload.

With NIC TLS offload, the NIC performs the encryption. The kernel can hand the NIC a descriptor that references page cache pages and a TLS record context. The NIC reads the plaintext, encrypts it, and transmits the ciphertext. The CPU never touches the payload. This is the only configuration where `sendfile` over HTTPS is truly zero-copy. It requires a NIC that supports TLS offload, a kernel that supports it, and a key schedule that the NIC can handle. It also requires that the connection's TLS record boundaries align with what the NIC expects. Not every TLS implementation or cipher suite is supported.

QUIC makes this harder. QUIC encrypts packets in user space by design, and its packet boundaries are not aligned with TCP segments. There is no `sendfile` for QUIC. An application that wants zero-copy QUIC transmit must use `MSG_ZEROCOPY` on the encrypted buffers, which means it has already paid the copy from plaintext to ciphertext. The zero-copy transmit removes the second copy, from ciphertext buffer to socket buffer, but the first copy remains. This is still a win, but it is not the same win as `sendfile` on a plaintext file.

The general rule is that zero-copy can only remove copies that are not semantically required. Encryption is semantically required. If the encryption happens above the kernel, the copy to user space is required. If it happens in the kernel, the kernel read is required unless hardware offload is available. No amount of API design changes that.

## The parts zero-copy does not skip

Even a perfect zero-copy transmit path still traverses most of the kernel network stack. The data must be framed into TCP segments, sequenced, checksummed, placed on the qdisc, and handed to the driver. `sendfile` and `MSG_ZEROCOPY` do not bypass TCP. They only change where the payload bytes live while TCP processes them. The CPU still spends cycles per packet and per segment, and those cycles can dominate on a fast link.

The qdisc is a frequent bottleneck. Every packet that leaves a socket passes through the queueing discipline unless the socket uses a bypass mechanism. On a 100 GbE link, the qdisc lock and the per-packet overhead can limit throughput to a fraction of line rate. The kernel has multiple queueing disciplines, some of which are lockless, and multiqueue NICs have per-CPU queues. But the default `pfifo_fast` or `fq_codel` still does work per packet. Zero-copy does not remove that work.

Netfilter and conntrack are another layer. If the system has iptables rules or connection tracking enabled, every packet traverses those hooks. Conntrack maintains a per-connection state table and can be a significant CPU consumer at high packet rates. `sendfile` and `MSG_ZEROCOPY` do not skip netfilter. AF_XDP does skip it, which is one reason AF_XDP can achieve higher packet rates, but it also means the application loses the firewall and NAT functionality that netfilter provides.

The driver and the NIC also do work. The driver must map the page fragments into DMA addresses. With `sendfile`, the pages come from the page cache and may not be contiguous. The driver must build a scatter-gather list. Modern NICs handle hundreds of descriptors, but the descriptor count scales with the number of pages, not the number of bytes. A 64 KB buffer backed by 16 pages requires 16 descriptors; a 64 KB buffer backed by one huge page requires one. This is another reason huge pages help zero-copy. It also means that zero-copy can increase descriptor pressure on the NIC, which can limit throughput if the descriptor ring is small.

On the receive side, the equivalent layers are NAPI, GRO, and the socket receive queue. GRO coalesces packets into larger `sk_buff`s, which reduces per-packet overhead but can also create linear buffers that defeat zero-copy mapping. If GRO coalesces across page boundaries, the resulting `sk_buff` may need a linear payload, which requires a copy. Some drivers can do GRO with page frags, but not all. The application has no control over this. It is a property of the driver, the NIC, and the kernel version.

## Workloads where zero-copy loses

Zero-copy is not a universal optimization. It loses in several common cases.

The first is small messages. Pinning a page costs more than copying a few hundred bytes. For a request/response protocol with 200-byte messages, `MSG_ZEROCOPY` will spend more time in `pin_user_pages` and completion processing than a `write` would spend in `copy_from_user`. The break-even point depends on the page size, the number of pages, and the CPU, but it is generally in the kilobytes, not bytes. If your messages are small, use the baseline loop.

The second is short-lived connections. The setup cost of `SO_ZEROCOPY`, the completion queue, and the buffer pool management must be amortized over the connection. A connection that sends one message and closes will not benefit. The same is true for `sendfile` if the file is small and the socket buffer is never filled; the per-call overhead of the hidden pipe and the page stealing may exceed the copy.

The third is buffers that are not page-aligned or are scattered. A 64 KB buffer that spans 17 pages instead of 16 costs more to pin. A buffer that is not page-aligned may require the kernel to handle partial pages, which can force a copy of the edges. Applications that use a single large ring buffer for many messages can suffer from this. The fix is to allocate page-aligned buffers and to keep messages aligned, but that is an application-level change.

The fourth is memory pressure. Pinned pages are not reclaimable. If the system is under memory pressure, pinning more pages can trigger OOM or force the kernel to reclaim other pages more aggressively. The application may see higher latency or failures. In a container with a memory limit, pinned pages count against the limit but cannot be swapped. A zerocopy application must budget for pinned memory separately from ordinary heap.

The fifth is debugging and observability. A copy is easy to see in a profile. A page pin is not. When a zerocopy application misbehaves, the symptoms can be subtle: occasional corruption because a buffer was reused too early, a slow memory leak because completions were lost, or a throughput cliff because the fill ring ran dry. The kernel provides some counters, but they are not as mature as the copy path's. Teams that adopt zero-copy need to invest in instrumentation.

## A decision table for transmit paths

The following table is a rough guide, not a prescription. It assumes a modern server NIC with TSO and checksum offload, a kernel recent enough to have the relevant features, and a workload that is already CPU-bound on copies.

| Workload | Recommended path | Main caveat |
|----------|------------------|-------------|
| Static file to TCP, plaintext | `sendfile` | Page cache consistency; 64 KB in-flight pipe |
| Static file to TCP, TLS | `sendfile` with kTLS and NIC TLS offload | Requires hardware and cipher support |
| Socket to socket proxy, plaintext | `splice` with a user pipe | Page stealing may fail; pipe size limit |
| Application-owned buffer to socket, large messages | `MSG_ZEROCOPY` or `io_uring SEND_ZC` | Pinning and completion overhead; buffer immutability |
| Application-owned buffer to socket, small messages | `write` | Zero-copy overhead exceeds copy |
| UDP or custom protocol, line-rate packet processing | AF_XDP zero-copy | Requires driver support; busy polling; user-space stack |
| TCP receive into application memory | `TCP_ZEROCOPY_RECEIVE` | Only when receive queue holds page frags; mapping cost |
| File to file copy | `copy_file_range` or reflink | Filesystem dependent |

The table hides the most important variable: the actual cost of the copy. On a CPU with abundant memory bandwidth and a workload that is not memory-bound, the baseline `read`/`write` loop may be perfectly adequate. Zero-copy is a specialization. It should be adopted when profiling shows that copy functions are a significant fraction of CPU time and when the workload's buffer ownership model matches the API's requirements. Otherwise, it adds complexity for a gain that may not materialize.

## Operational practices and instrumentation

If you do adopt a zero-copy path, measure it continuously. The first metric is CPU time per byte. Divide the process's CPU time by the bytes transferred. Compare it against the baseline on the same hardware. A zero-copy path that does not reduce CPU time per byte is not earning its complexity.

The second metric is the fallback rate. For `MSG_ZEROCOPY`, count `SO_EE_CODE_ZEROCOPY_COPIED` completions. For `sendfile` and `splice`, count the copy functions in `perf` profiles. For `TCP_ZEROCOPY_RECEIVE`, count how often the receive queue is linear. A fallback rate above a few percent means the path is not doing what you think.

The third metric is pinned memory. On modern kernels, `/proc/meminfo` has fields for unevictable and pinned memory, and `bpftrace` can trace `pin_user_pages` and `put_page` to see the live count. The pinned count should be bounded by the number of outstanding sends times the buffer size. If it grows without bound, completions are being lost or buffers are not being returned.

The fourth metric is completion latency. The time between a zerocopy send and its completion notification is the time the buffer is unavailable. If that latency is high, the application needs more buffers or a smaller send size. If it is unbounded, the peer is not acknowledging, and the connection should be closed.

The fifth metric is page faults and TLB activity. `perf stat` can report `dtlb_load_misses.walk_active` and `page-faults`. A zerocopy path that pins and unpins continuously will show elevated page table activity. If the buffers are huge-page backed, the activity should be low. If it is not, the buffers are being split or the alignment is wrong.

Finally, test the failure modes. Kill the peer in the middle of a zerocopy send and verify that buffers are eventually released. Fill the completion queue and verify that the application handles it. Run under memory pressure and verify that pinning does not trigger OOM. These are not edge cases; they are the normal operating conditions of a busy server.
