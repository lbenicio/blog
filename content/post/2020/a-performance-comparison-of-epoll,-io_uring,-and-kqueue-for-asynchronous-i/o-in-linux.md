---
title: "A Performance Comparison Of Epoll, Io_Uring, And Kqueue For Asynchronous I/O In Linux"
description: "A comprehensive technical exploration of a performance comparison of epoll, io_uring, and kqueue for asynchronous i/o in linux, covering key concepts, practical implementations, and real-world applications."
date: "2020-11-23"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/a-performance-comparison-of-epoll-io-uring-and-kqueue-for-asynchronous-io-in-linux.png"
coverAlt: "Technical visualization representing a performance comparison of epoll, io_uring, and kqueue for asynchronous i/o in linux"
---

# The Server in Your Hands: From `epoll` to `io_uring` – The Evolution of Asynchronous I/O on Linux

The server is in your hands. You’re holding a single, relatively mild-mannered Linux machine running a high-frequency trading application, a real-time multiplayer game server, or perhaps the backend for a social media feed that millions of people check every morning before they’ve even opened their eyes. The underlying hardware is solid—fast SSDs, plenty of RAM, and a modern multi-core processor. You’ve optimized your application’s memory layout, you’ve profiled your hot paths, and you’ve ruthlessly eliminated every unnecessary allocation. And yet, the server is struggling.

You watch the flame graphs, and the culprit doesn’t look like a slow algorithm or a memory leak. The culprit looks like the _waiting_. The kernel is spending more time managing the poll of file descriptors, or handling the completion of I/O requests, than your application is spending doing actual work. The CPU is spinning, but not on your code. It’s busy managing the mechanics of I/O—the bureaucracy of notifying the kernel that you’re ready, or asking the kernel if it’s finished moving data around. This isn’t a failure of hardware; it’s a failure of interface. And when your application hits this wall—the point where the kernel’s I/O subsystem becomes the bottleneck—every nanosecond you can shave off the wait translates directly into throughput.

This is the domain of asynchronous I/O on Linux. For nearly two decades, the dominant paradigm for handling high-concurrency network and file operations was the `epoll` system call, a powerful stateful event notification interface that is the engine behind `nginx`, `Node.js`, `libuv`, and virtually every high-performance network server on the modern internet. It replaced the older `select` and `poll` APIs, which didn't scale to tens of thousands of connections, and it has been the undisputed king of the Linux I/O hill for years. But the landscape is shifting. A new challenger has emerged from the kernel depths, one that represents a fundamental rethinking of the entire kernel-userspace I/O contract. Its name is `io_uring`, and it promises to make `epoll` as quaint as `select` seems today.

In this post, we’ll take a deep dive into both paradigms. We’ll understand why `epoll` was a revolution in its time, but also why it imposes fundamental limits on performance. We’ll explore the architecture of `io_uring`, how it sidesteps those limits, and how you can use it to write blazingly fast I/O-bound applications. We’ll look at real-world benchmarks, code examples, and even venture into the slightly-mad-science world of kernel-bypass tricks like `IORING_SETUP_SQPOLL`. By the end, you’ll see that the server in your hands doesn’t have to struggle—it just needs the right interface.

---

## Part 1: The Old King – Understanding `epoll`

Before we can appreciate the new, we must fully understand the old. `epoll` is an event notification mechanism introduced in Linux 2.5.44 (2002) and stabilized in 2.6. It was designed to solve the problems of its predecessors: `select()` and `poll()`.

### The Problems with `select` and `poll`

- **Scalability**: `select()` has a hard limit on the number of file descriptors it can monitor (traditionally `FD_SETSIZE = 1024`). `poll()` removed that limit but suffered from `O(n)` complexity for every call—the kernel must walk the entire array of file descriptors, even if none are ready.
- **Copying**: Both require the user to pass a full array of file descriptors to the kernel _every_ call. The kernel copies it from userspace, scans it, then copies back the results. For 100,000 connections, that’s a lot of memory bandwidth.
- **Reset behavior**: In `select()`, the set returned is a modified copy, so you must reconstruct the set each time.

These problems made `select`/`poll` unusable for web servers like Apache (which used process-per-connection with `select` and suffered from the C10K problem). Enter `epoll`.

### How `epoll` Works

`epoll` is fundamentally different: it is **stateful**. You create an `epoll` instance, register file descriptors (FDs) of interest with it once, and from then on you only ask the kernel “what’s ready?” The kernel maintains an internal data structure (red-black tree + ready list) and only returns those FDs that have events. The overhead of building the list from scratch is eliminated.

Three system calls govern `epoll`:

1. **`epoll_create1()`** – Creates an `epoll` file descriptor (a context).
2. **`epoll_ctl()`** – Adds, modifies, or removes FDs from interest (with `EPOLL_CTL_ADD`, `EPOLL_CTL_MOD`, `EPOLL_CTL_DEL`). You can specify events like `EPOLLIN`, `EPOLLOUT`, `EPOLLERR`, and importantly edge-triggered (`EPOLLET`) vs level-triggered.
3. **`epoll_wait()`** – Blocks until events happen (or timeout). Returns a list of `struct epoll_event` structures.

#### Edge-Triggered vs Level-Triggered

This decision profoundly affects your event loop design:

- **Level-triggered (default)**: The event is reported as long as the condition holds. For a socket, `EPOLLIN` fires repeatedly until all data is read. This is simpler but can cause spurious wakeups if you don’t read everything (good for non-blocking daemons).
- **Edge-triggered (ET)**: The event is reported only once when the condition changes. For `EPOLLIN`, you get one notification when data arrives; you _must_ read all available data (usually in a loop) before the next notification. This reduces the number of system calls but requires careful programming to avoid missing data.

Most high-performance servers use edge-triggered mode to minimize `epoll_wait` calls. This is where the complexity begins.

### The Classic `epoll` Event Loop

A typical edge-triggered HTTP server event loop looks like this in C:

```c
int epoll_fd = epoll_create1(0);
struct epoll_event ev;
ev.events = EPOLLIN | EPOLLET;  // edge-triggered
ev.data.fd = listen_fd;
epoll_ctl(epoll_fd, EPOLL_CTL_ADD, listen_fd, &ev);

struct epoll_event events[MAX_EVENTS];
while(1) {
    int n = epoll_wait(epoll_fd, events, MAX_EVENTS, -1);
    for(int i = 0; i < n; i++) {
        int fd = events[i].data.fd;
        if(fd == listen_fd) {
            // Accept new connection, set nonblocking, add to epoll
        } else {
            // Read or write data from fd
            // Must handle EAGAIN and loop until done for ET
        }
    }
}
```

This works. But look carefully: every single iteration you call `epoll_wait`. That’s a system call, meaning a context switch from userspace to kernel and back. On modern CPUs, a system call costs 50-100 ns in the best case (with `sysenter`), but when you add the overhead of copying events and processing the ready list, it can be 500 ns or more. And you do this every time you want to wait for new events.

But that’s just the beginning. The real flaw is that **every I/O operation itself also requires a system call**. `read()`, `write()`, `accept()`, `connect()`, `sendfile()`, `splice()`, … each one is a separate trap into the kernel. In a high-throughput server, the ratio of system calls to actual work can be absurd. Consider:

- A request arrives (detected by `epoll_wait`).
- You `accept()` the connection (system call).
- You `epoll_ctl()` to add the new fd (system call).
- Later, `epoll_wait` fires for that fd.
- You `read()` the request (system call).
- You `write()` the response (system call).
- You close the connection (system call).

That’s **6+ system calls** (and at least 2 `epoll_wait` calls) per request, even for a trivial “hello world” server. For 100,000 requests per second, that’s 600,000 system calls per second. Each one steals CPU cycles that could be doing actual, meaningful work.

### The Hidden Costs of `epoll`

Beyond the raw number of system calls, there are more subtle penalties:

1. **Memory touches**: When you call `read()`, the kernel must copy data from kernel buffers to userspace. This involves cache misses and memory bandwidth. With many small I/Os, the overhead dominates.
2. **Locking**: The kernel’s network stack and file system are full of locks. Each system call acquires and releases multiple locks. Under high concurrency, this leads to contention and cache-line bouncing.
3. **Scheduling**: When `epoll_wait` returns, it triggers a wakeup for the calling thread. If you’re using a thread pool (e.g., Nginx in multi-process mode), the kernel must schedule the worker. Even with cooperative scheduling, there’s overhead.
4. **Statefulness**: `epoll` is great for sockets but terrible for regular files. File I/O is traditionally blocking. You can use `O_DIRECT` with `aio_read` (the old POSIX AIO / kernel AIO), but that interface is clunky and incomplete. `epoll` does not support file descriptors for regular files – they always appear ready. So `epoll` is essentially a network-only API.

### Real-World Pain Points

- **High-frequency trading**: Every microsecond counts. The `epoll` system call alone eats precious time. Some firms resort to busy-polling (spinning on `recv` with `MSG_DONTWAIT`) to avoid `epoll`, but that burns CPU.
- **Database engines**: InnoDB in MySQL or WiredTiger in MongoDB need to handle both network I/O and disk I/O. Mixing `epoll` for network with synchronous file I/O forces complex thread pooling.
- **Game servers**: Real-time games send and receive thousands of small packets per second. Each `recvfrom` is a syscall. Add in `sendto`, and overhead becomes a significant fraction of the budget.

The community has developed workarounds: **io_submit** (Linux AIO) for file I/O, **splice** and **sendfile** for zero-copy networking, **SO_ATTACH_FILTER** for socket filtering. But they are piecemeal. We needed a unified, high-performance, syscall-minimizing I/O model. That’s where `io_uring` enters.

---

## Part 2: Enter the New King – `io_uring` Architecture

`io_uring` was merged into the Linux kernel in version 5.1 (released May 2019), primarily authored by Jens Axboe (the maintainer of the block layer). It started as a replacement for the old `aio` interface, but quickly expanded to become a general-purpose asynchronous I/O framework. The key insight is radical: **instead of performing I/O via system calls, the kernel and userspace share two ring buffers in memory**. Userspace writes I/O requests into a Submission Queue (SQ), and the kernel consumes them. When done, the kernel writes completions into a Completion Queue (CQ), which userspace reads. No system calls needed for the actual I/O operations!

Only two system calls are typically required:

- **`io_uring_setup`** – Initializes the ring buffers and returns a file descriptor.
- **`io_uring_enter`** – Tells the kernel to process queued submissions (can be done with fewer calls using `SQPOLL`, as we’ll see).

Optionally, you can use `io_uring_register` for various setup operations (registering files, buffers, personality).

### The Subsystem Components

Let’s break down the architecture:

- **What is a "Ring"?** It’s a circular buffer of fixed-size entries, allocated in shared memory (mmap’d from the kernel). The head and tail pointers are stored in a shared `struct io_rings` structure, also mmap’d. Userspace and kernel communicate by modifying these pointers.
- **Submission Queue (SQ)**: An array of `struct io_uring_sqe` (Submission Queue Entry). Each SQE describes one I/O operation: the opcode (read, write, accept, etc.), file descriptor, offset, flags, and user_data (a pointer/tag for matching completions). Userspace writes new SQEs at the tail, then advances the tail pointer.
- **Completion Queue (CQ)**: An array of `struct io_uring_cqe` (Completion Queue Entry). Each CQE contains the result (like the return value of `read`), flags, and the user_data from the original SQE. The kernel writes at the tail, userspace reads from the head.

Because the buffers are shared, no memory copying is involved. The kernel accesses the SQ entries directly; userspace accesses CQ entries directly. The only synchronization required is memory ordering (using `smp_store_release` / `smp_load_acquire` or equivalent).

### A Tiny Example

Here’s a minimal example using the liburing library (which wraps the raw system calls with a more pleasant API). Suppose we want to read 4KB from a file descriptor `fd`:

```c
#include <liburing.h>

#define ENTRIES 64
int main() {
    struct io_uring ring;
    io_uring_queue_init(ENTRIES, &ring, 0);  // calls io_uring_setup

    char buf[4096];
    struct iovec iov = {
        .iov_base = buf,
        .iov_len = sizeof(buf),
    };

    // Prepare a readv operation
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_readv(sqe, fd, &iov, 1, 0);
    io_uring_sqe_set_data(sqe, (void*)1);  // arbitrary cookie

    // Submit the SQE(s)
    io_uring_submit(&ring);  // calls io_uring_enter

    // Wait for completion
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);  // blocks until one completion
    int ret = cqe->res;  // result from readv
    void *cookie = io_uring_cqe_get_data(cqe);
    printf("Read returned %d, cookie=%p\n", ret, cookie);
    io_uring_cqe_seen(&ring, cqe);

    io_uring_queue_exit(&ring);
}
```

Notice: We called `io_uring_submit` once, which may have called `io_uring_enter`. But we could have batched multiple SQEs before submitting. The `io_uring_wait_cqe` function involves a system call (if it needs to wait). But we can also use `io_uring_peek_cqe` to check non-blockingly, or use `IORING_SETUP_SQPOLL` to have the kernel poll the SQ automatically, eliminating the need for `io_uring_enter` entirely.

### Avoiding System Calls: The `SQPOLL` Trick

The most impressive feature of `io_uring` is the `IORING_SETUP_SQPOLL` flag. When you set this during `io_uring_setup`, the kernel spawns a kernel thread that busy-polls the SQ at regular intervals (configurable, default microsecond scale). As soon as userspace adds an SQE and updates the tail pointer, the kernel thread picks it up without any system call. Similarly, completions appear in the CQ, and userspace can read them via a simple load-acquire (no syscall). The only time a system call is needed is if the application must wait for a completion when none is available, in which case `io_uring_enter` with `IORING_ENTER_GETEVENTS` can block.

This means a typical I/O operation can become **entirely system-call-free** in the hot path! That’s a revolutionary reduction in overhead.

### What Operations Can `io_uring` Handle?

Initially, `io_uring` supported most file I/O operations: `read`, `write`, `readv`, `writev`, `fsync`, `fallocate`, `openat`, `close`, `statx`. Over subsequent kernel versions (5.6, 5.7, 5.8…), network operations were added:

- `IORING_OP_ACCEPT` – accept a new connection
- `IORING_OP_CONNECT` – connect to a remote address
- `IORING_OP_SEND`, `IORING_OP_RECV` – send/recv on sockets
- `IORING_OP_SENDMSG`, `IORING_OP_RECVMSG` – sendmsg/recvmsg
- `IORING_OP_EPOLL_CTL` – even emulate epoll! (though rarely needed)

Additionally, `io_uring` supports **buffer selection** (`IORING_OP_PROVIDE_BUFFERS`), where you can pre-register a group of buffers, and the kernel picks a free one for you when receiving data. This eliminates the need to allocate memory per I/O and reduces kernel memory overhead.

Another killer feature: **registered files and buffers**. You can pre-register a list of file descriptors and buffer memory with `io_uring_register`. The kernel then uses internal references (instead of the fd number) and pins the memory pages. This saves on reference counting, overhead of fget, and prevents pages from being swapped out. For long-lived connections (like in a database), this can significantly cut per-I/O cost.

### Comparison to `epoll` for Network I/O

Let’s sketch an `io_uring`-based echo server that accepts connections and echoes back data. This demonstrates the key pattern:

```c
#include <liburing.h>
#include <netinet/in.h>

#define ENTRIES 256
#define MAX_CONN 1000

struct conn_info {
    int fd;
    char buf[4096];
    bool reading;
};

int main() {
    int listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    // bind and listen...

    struct io_uring ring;
    io_uring_queue_init(ENTRIES, &ring, 0);

    struct conn_info *conns = calloc(MAX_CONN, sizeof(struct conn_info));

    // Register a buffer group (optional but efficient)
    // ... omitted for brevity

    // Initial accept SQE
    struct sockaddr_storage client_addr;
    socklen_t addrlen = sizeof(client_addr);
    {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
        io_uring_prep_accept(sqe, listen_fd, (struct sockaddr*)&client_addr, &addrlen, 0);
        // store pointer to conn_info? Use user_data
        io_uring_sqe_set_data(sqe, NULL); // no conn yet
    }
    io_uring_submit(&ring);

    while(1) {
        struct io_uring_cqe *cqe;
        int ret = io_uring_wait_cqe(&ring, &cqe);
        // handle completion
        int result = cqe->res;
        void *data = io_uring_cqe_get_data(cqe);
        io_uring_cqe_seen(&ring, cqe);

        if (data == NULL) {
            // This was an accept completion
            int client_fd = result;
            struct conn_info *c = &conns[client_fd]; // index by fd
            c->fd = client_fd;
            c->reading = true;
            // Submit a recv
            struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
            io_uring_prep_recv(sqe, client_fd, c->buf, sizeof(c->buf), 0);
            io_uring_sqe_set_data(sqe, c);
            // Also submit next accept
            sqe = io_uring_get_sqe(&ring);
            io_uring_prep_accept(sqe, listen_fd, ...);
            io_uring_sqe_set_data(sqe, NULL);
        } else {
            struct conn_info *c = (struct conn_info*)data;
            if (result <= 0) {
                // connection closed or error
                close(c->fd);
                // maybe clean up
            } else if (c->reading) {
                // echo back
                struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
                io_uring_prep_send(sqe, c->fd, c->buf, result, 0);
                io_uring_sqe_set_data(sqe, c);
                c->reading = false;
            } else {
                // write completed, now read next
                struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
                io_uring_prep_recv(sqe, c->fd, c->buf, sizeof(c->buf), 0);
                io_uring_sqe_set_data(sqe, c);
                c->reading = true;
            }
        }
        io_uring_submit(&ring);
    }
}
```

This code, while still simplified, shows the pattern: we chain operations by submitting new SQEs in the completion handler. The critical point: **no system calls to accept, read, write, or close are made directly**. All those operations become asynchronous entries in the SQ. Even `close` could be done via `IORING_OP_CLOSE`. This minimizes kernel transitions.

### Scaling Throughput: The Power of Batching

One of the most compelling advantages of `io_uring` is the ability to submit _batches_ of I/O operations with a single system call (or none with SQPOLL). In `epoll`, you can only wait for events; you still need to issue each `read`/`write` as a separate syscall. With `io_uring`, you can prepare dozens of SQEs, call `io_uring_submit` once (or not at all with SQPOLL), and then later collect all completions with a single `io_uring_wait_cqe` loop. This amortizes the cost of syscalls over many operations.

In practice, servers that use `io_uring` can see throughput increases of 2-10× over `epoll`-based implementations, especially when combined with registered files and buffers. A famous benchmark by Jens Axboe showed that a simple file-serving application could reach 2.1 million IOPS (4KB random reads) on a single core using `io_uring`, while the classic AIO interface would cap at around 600k. On network-heavy workloads, the gains are similarly impressive.

---

## Part 3: Benchmarks and Real-World Impact

Let’s move beyond talking points and look at numbers. These are approximate but based on published results and community experiences.

### Microbenchmark: TCP Echo Server

A simple echo server, running on a single CPU core, with 10,000 concurrent connections:

| Implementation                   | Throughput (echoes/sec) | Latency p99 (µs) | Syscalls/op |
| -------------------------------- | ----------------------- | ---------------- | ----------- |
| Non-blocking select              | 85,000                  | 350              | ~8          |
| epoll (edge-triggered)           | 520,000                 | 95               | ~6          |
| epoll + sendfile (zero-copy)     | 690,000                 | 80               | ~4          |
| io_uring (basic)                 | 920,000                 | 62               | ~1.5        |
| io_uring + SQPOLL                | 1,200,000               | 48               | ~1          |
| io_uring + registered files/bufs | 1,400,000               | 42               | ~1          |

The `io_uring` advantage grows as the CPU becomes the bottleneck. On multi-core systems, the gains are less dramatic due to lock contention in the kernel, but `io_uring` still outperforms by 30-50%.

### Real-World: Database Engines

- **RocksDB**: An `io_uring` integration for Storage Tier in MyRocks (Facebook) showed 30-40% reduction in read latency and 20% improvement in write throughput for random I/O workloads.
- **MongoDB**: The WiredTiger storage engine added `io_uring` support (kernel 5.6+). In benchmarks with NVMe SSDs, WiredTiger achieved 2x more operations per second for some transactional workloads.
- **Ceph**: The distributed storage system uses `io_uring` for its OSD backend, reporting 50% lower CPU usage under heavy load compared to `libaio`.

### web Servers

- **Nginx** (unofficial patch): A modified nginx using `io_uring` for the event loop and file serving showed 2.5x requests per second for static file serving over TLS (where encryption costs are also reduced because less CPU is wasted on I/O overhead).
- **Lighttpd** : Adopted `io_uring` natively in version 1.4.60, saw 15% higher throughput for mixed workloads.

It’s important to note that in many applications, the bottleneck shifts from I/O to other parts (e.g., application logic, TLS). But `io_uring` reduces the I/O tax so drastically that other optimizations become more noticeable.

### The Hidden Tax: CPU Cache Efficiency

`io_uring` also improves CPU cache behavior. With `epoll`, every `epoll_wait` call and subsequent `read`/`write` involves traversing kernel data structures that may not be cached. The shared rings of `io_uring` are often hot in L2/L3 cache because they are small and frequently accessed. Moreover, registered buffers are pinned and can be mapped into the same userspace pages repeatedly, reducing TLB misses.

---

## Part 4: Migration from `epoll` – Is It Worth It?

Given the clear advantages, you might be tempted to switch all your I/O-heavy applications to `io_uring` tomorrow. But there are real ecosystem considerations:

### 1. Kernel Version Requirements

`io_uring` was added in Linux 5.1, but network operations (accept, recv, send) didn't arrive until 5.6-5.8. Advanced features like `IORING_SETUP_SQPOLL` work, but may have had bugs in early versions. The current production-recommended baseline is **kernel 5.10 or newer** (LTS). Many enterprise systems still run 4.18 (RHEL 8) or even 3.10. If you're on a long-term stable distribution, you may not have access. Fortunately, some distros backport `io_uring` (e.g., Ubuntu 20.04 with HWE kernel, RHEL 9). Check before committing.

### 2. Library Support

The raw `io_uring` system calls are manageable but arcane. You'll want a wrapper library:

- **liburing** (official) – Provides a higher-level API (what we’ve used above). Stable and well-documented.
- **mio** (Rust) – Rust’s `mio` v0.8 supports `io_uring` via `IoUring` struct.
- **libuv** (node.js, Luvit) – Experimental support.
- **Seastar** (ScyllaDB) – Already uses its own `smp` event loop, but could adopt `io_uring` for I/O.
- **Tokio** (Rust’s async runtime) – Has an `io_uring`-based driver (`tokio-uring`) for file I/O.

If you're writing in C/C++ or Rust, integration is straightforward. For higher-level languages (Python, Go, Java), the story is mixed. Go’s runtime uses epoll; there are ongoing discussions to add `io_uring` support. Java’s `NIO` does not use `io_uring` yet. So the benefits are most immediate for lower-level systems.

### 3. Complexity of Code

`io_uring` requires managing two rings and careful memory ordering. While liburing hides much of the complexity, you still need to think about:

- Buffer lifetimes: The kernel may be reading/writing into your buffer while you're using it. You must ensure buffers are not reused until the completion is seen.
- Ordering: Operations within a single submission are generally scheduled in order, but completions can be out of order depending on device concurrency. You must be prepared to handle completions in any order.
- Error handling: `cqe->res` can be negative (Linux errno). Not all errors are graceful.

The `epoll` codebase is battle-tested and simple to reason about. Migrating to `io_uring` can introduce subtle concurrency bugs if not done carefully. However, for greenfield projects, `io_uring` is the obvious choice.

### 4. Performance When Not Stressed

If your server handles only a few thousand connections with moderate throughput, the overhead of `epoll` vs `io_uring` is negligible. The system call cost is a few hundred nanoseconds; your application logic probably consumes microseconds. In such cases, the simplicity of `epoll` may be preferable. `io_uring` shines when you are I/O-bound and trying to squeeze every last drop from hardware.

### 5. The Future is `io_uring`

Despite the adoption hurdles, the kernel community is investing heavily in `io_uring`. New features appear every release:

- Linux 5.15: `IORING_OP_URING_CMD` for driver-specific commands (e.g., NVMe passthrough)
- Linux 5.19: Multi-shot accept (accept multiple connections in one submission)
- Linux 6.0: `IORING_RECVSEND` flags for better networking
- Linux 6.1: `IORING_SETUP_COOP_TASKRUN` for cooperative task management

The interface is actively evolving. Long-term, `io_uring` is positioned to become the universal I/O backend for Linux, potentially replacing `epoll`, `aio`, and even `select`/`poll` in the kernel.

---

## Part 5: Advanced Tricks and Quirks

For the truly performance-obsessed, `io_uring` offers several advanced features that push the envelope even further.

### Zero-Copy Networking with `IORING_OP_SEND_ZC`

Introduced in Linux 5.19 (`IORING_OP_SEND_ZC`), this operation allows you to send data from a buffer without copying from userspace to kernel space. By registering a buffer with `IORING_OP_PROVIDE_BUFFERS` and then using `SEND_ZC`, the kernel can directly DMA the data from your buffer to the NIC, provided the buffer is page-aligned and the driver supports it. This is a game-changer for fast packet processing.

### Atomic Operations and Networking

You can even perform `cmpxchg` on shared rings (via `IORING_OP_ASYNC_CANCEL` and `IORING_OP_URING_CMD`), enabling lock-free coordination between userspace and the kernel.

### Multi-Shot Accept

Instead of submitting an accept SQE, waiting for completion, then submitting another, you can use `IORING_ACCEPT_MULTISHOT` to have the kernel keep accepting connections and generate multiple CQEs. This reduces the number of submission operations.

### Personality and Credentials

With `IORING_REGISTER_PERSONALITY`, you can change user/group IDs for the duration of a set of operations, useful for multitenant systems.

### Debugging

Debugging `io_uring` applications can be tricky because system calls are rare. The kernel provides `/sys/kernel/debug/tracing/events/io_uring/` tracepoints. You can use `perf` to monitor ring activity:

```bash
perf record -e io_uring:io_uring_create,io_uring_enter,io_uring_submit
```

Also, `strace` will show the `io_uring_setup` and `io_uring_enter` calls, but not individual SQEs. There’s a tool `io_uring_trace` (from liburing) to decode SQEs.

---

## Part 6: Does Your Application Need `io_uring`?

Let’s summarize the decision matrix.

**Use `io_uring` if:**

- You are writing a new I/O-intensive service (database, proxy, game server, trading engine).
- Your infrastructure runs on modern kernels (5.10+).
- You need to maximize throughput on a limited number of cores.
- You handle tens of thousands of concurrent connections or more.
- You want to unify network and file I/O under one framework.
- You are comfortable with a more complex programming model.

**Stick with `epoll` if:**

- Your codebase is stable and uses `epoll` already (migration effort outweighs benefits).
- You target older kernels (RHEL 7, CentOS 7, etc.).
- You have simple I/O patterns with low concurrency (< 10,000 connections).
- You use a runtime that does not support `io_uring` (e.g., Node.js, Python asyncio) and cannot drop in a replacement.
- You value simplicity and ecosystem maturity.

---

## Conclusion: The Server is No Longer Struggling

Remember the server in your hands? The one that was fighting the kernel’s I/O bureaucracy? With `io_uring`, the story changes. Instead of making system calls to ask permission for every read, write, accept, or connect, you simply drop your intention into a shared ring buffer, and the kernel picks it up at its leisure, delivering results moments later. There is no waiting—just relentless forward progress.

The evolution from `select` to `epoll` was a leap in scalability; the evolution from `epoll` to `io_uring` is a leap in efficiency. For the first time in Linux history, we have an I/O API that can approach the theoretical limits of hardware, where the overhead of being in kernel mode is practically eliminated. The CPU cycles that were once spent on managing I/O can now be redirected to your application—processing trades, rendering game states, or serving cat pictures to the world.

The server in your hands is no longer struggling. It’s singing. And if you listen closely, you can hear the quiet hum of a million I/O operations per second, all flowing through a pair of rings, with no system calls in between.

Now go write the future of I/O. The kernel is ready for it.

---

_Further reading:_

- [Official kernel documentation for io_uring](https://kernel.dk/io_uring.pdf) by Jens Axboe
- [Lord of the io_uring](https://unixism.net/2020/04/io-uring-by-example-article-series/) (blog series with examples)
- [Linux I/O deep dive](https://youtu.be/ohJcOj9K6OI) (Kernel Recipes 2020, by Jens Axboe)
- `man 7 io_uring` – man page in kernel 5.10+
