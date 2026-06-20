---
title: "From Sockets To Epoll: Building A Non Blocking Http Server In C"
description: "A comprehensive technical exploration of from sockets to epoll: building a non blocking http server in c, covering key concepts, practical implementations, and real-world applications."
date: "2025-05-27"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/From-Sockets-To-Epoll-Building-A-Non-Blocking-Http-Server-In-C.png"
coverAlt: "Technical visualization representing from sockets to epoll: building a non blocking http server in c"
---

## The Journey from Blocking I/O to Epoll: Building a Non-Blocking HTTP Server in C

### Introduction (provided)

The speed of light in a copper wire is roughly 200 million meters per second. When you hit a key on your keyboard, the electrical impulse travels from your fingers to a server potentially thousands of kilometers away in mere milliseconds. The physics is deterministic. The hardware is blazing fast. Yet, for decades, the software that managed the _waiting_—the idle loops, the blocking threads, the wasted CPU cycles burning electricity while doing absolutely nothing—remained stubbornly inefficient.

If you have ever built a web server, even a simple one, you have likely encountered this paradox. The hardware is ready to scream, but the software is holding it back, waiting, checking, and polling. This tension is the central drama in the life of a network engineer. It is the difference between a server that can handle ten connections and one that can handle ten thousand. It is the story of moving from **sockets** to **epoll**.

Why should you, a developer or engineer building systems in 2024, care about this journey? Because every major piece of infrastructure you rely on—from Nginx and HAProxy to Redis, Node.js, and even the database client libraries in your stack—solves this exact problem. They don't just handle I/O; they _master_ it. Understanding this evolution isn't just an academic exercise in operating system trivia. It is a fundamental rite of passage for any engineer who wants to move beyond “tutorial-level” code and write software that respects the machine, scales under load, and doesn’t collapse when a thousand clients decide to refresh their browsers simultaneously.

This post is that journey. We are going to write a non-blocking HTTP server in C from the ground up. But we aren't going to start in an ideal state. We are going to start where most tutorials start: in the dark ages of blocking I/O.

Imagine a simple barber shop. You walk in, sit down, and the barber works on you until you're done. No one else can get a haircut while you're in the chair. That's the blocking model. It's simple, but it's a disaster for scaling. Now, imagine a barber shop where customers take a number, sit in the waiting area, and the barber calls the next person the moment the previous one stands up. That's non-blocking I/O with a reactor pattern. The barber never waits; the barber works only when there is work to do. This is the story of how operating systems evolved to support that model, and how we, as engineers, can wield it to build servers that handle concurrency without needing a thread per connection.

Let's start at the beginning: the simplest possible server.

---

### Chapter 1: The Dark Ages – Blocking I/O and the One-Client-at-a-Time Server

Most networking tutorials for C begin with a `socket()`, `bind()`, `listen()`, and then an infinite loop that calls `accept()`. The `accept()` call itself is blocking: it waits until a client connects. Once a connection is accepted, the server reads from the socket using `read()`, which also blocks until data arrives. Then it sends a response with `write()`, which blocks until the data is sent. Finally, it closes the connection and loops back to `accept()`.

Here is the canonical example:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

int main() {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    int addrlen = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(8080);
    bind(server_fd, (struct sockaddr *)&address, sizeof(address));
    listen(server_fd, 3);

    char buffer[1024] = {0};
    while (1) {
        int new_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen);
        // Block until a client connects
        read(new_socket, buffer, 1024);
        // Block until data is received
        char *response = "HTTP/1.1 200 OK\nContent-Length: 5\n\nHello";
        write(new_socket, response, strlen(response));
        // Block until all data is written
        close(new_socket);
    }
    return 0;
}
```

This works. It handles exactly one client at a time. If a second client tries to connect while the first is being served, that second client will be enqueued by the TCP stack (the backlog parameter in `listen()`), but the server won't call `accept()` until the first client is finished. This means the second client waits for potentially seconds, even if the first client is just sending a megabyte of data and then waiting for a response.

**Why is this bad?** Because the CPU is idle for most of the time. While `read()` is waiting for data from the network, the entire process is blocked. The operating system can schedule other processes, but if this is a dedicated server, that one process is wasting time. Worse, if you have many clients, you need many processes or threads—and each thread consumes stack memory (typically 1–8 MB), and context switching between them is expensive. This leads to a scalability wall. For a lightweight HTTP request like a REST API call, the ratio of time spent processing to time spent waiting is often 1:100 or worse.

In the barber shop analogy, this is a shop where the barber only cuts one person's hair at a time, and everyone else must wait outside until the first person is completely done. It's simple, but you can't serve a crowd.

### Chapter 2: The First Attempt – Forking and Multithreading

The naive solution to concurrency is to create a new process or thread for each incoming connection. This way, while one thread is blocked on `read()`, another thread can process a different client. This was the dominant model for many years (Apache's prefork MPM, for example).

Here's a threaded version using POSIX threads:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>

void *handle_client(void *arg) {
    int client_fd = *(int *)arg;
    free(arg);
    char buffer[1024] = {0};
    read(client_fd, buffer, 1024);
    char *response = "HTTP/1.1 200 OK\nContent-Length: 5\n\nHello";
    write(client_fd, response, strlen(response));
    close(client_fd);
    return NULL;
}

int main() {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    int addrlen = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(8080);
    bind(server_fd, (struct sockaddr *)&address, sizeof(address));
    listen(server_fd, 10);

    while (1) {
        int *client_fd = malloc(sizeof(int));
        *client_fd = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen);
        pthread_t thread;
        pthread_create(&thread, NULL, handle_client, client_fd);
        pthread_detach(thread); // don't need to join
    }
    return 0;
}
```

This works better. Now multiple clients can be served concurrently. However, each thread has overhead: creating a thread takes time and memory (typically 1–2 MB of virtual address space reserved for the stack, though only a fraction is used). For 10,000 concurrent connections, you would need 10,000 threads—which could consume 10–20 GB of RAM just for stacks. Context switching between that many threads also kills performance due to cache misses and kernel overhead. Additionally, threads share the same address space, so you have to be careful with synchronization. And if you use processes, the overhead is even greater (forking is expensive).

The barber shop analogy: now we have many barbers (threads), each cutting one customer's hair. But each barber needs their own chair and scissors (thread resources). You can only fit so many barbers in the shop before you run out of space and the cost of moving between customers becomes huge.

This thread-per-connection model was the norm for many years, but it doesn't scale beyond a few thousand connections. Modern web servers like Nginx and Node.js don't use it. They use a different approach: **event-driven, non-blocking I/O**.

### Chapter 3: The Concept of Non-Blocking Sockets and Polling

The key insight is that while a socket is waiting for data, the CPU could be doing something else. Instead of blocking the entire thread on a `read()`, we can set the socket to non-blocking mode using `fcntl()`:

```c
int flags = fcntl(socket_fd, F_GETFL, 0);
fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK);
```

Now, `read()` on that socket returns immediately, either with data or with an error code `EAGAIN` (or `EWOULDBLOCK`) if no data is available. The same applies to `write()` and `accept()`.

This allows us to write code that checks multiple sockets in a loop, polling each one for readability or writability. This is the old-school **busy polling** approach:

```c
while (1) {
    for each socket in list {
        data = nonblocking_read(socket);
        if (data) process(data);
    }
}
```

But busy polling consumes 100% CPU even when no sockets have data, which is wasteful. The OS provides system calls to let a thread sleep until one or more file descriptors become ready. The first such call was **`select()`**.

### Chapter 4: The Era of `select()` and `poll()`

#### `select()`

`select()` was introduced in BSD Unix and later standardized in POSIX. It allows a process to monitor a set of file descriptors for readability, writability, or exceptional conditions. The kernel puts the process to sleep and wakes it up when any of the monitored descriptors become ready.

The API is:

```c
int select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout);
```

You set bits in `fd_set` structures (which are bit arrays) for each descriptor you're interested in. After the call, the sets are modified to indicate which descriptors are ready.

Here's a simple event loop using `select()`:

```c
fd_set readfds;
FD_ZERO(&readfds);
FD_SET(server_fd, &readfds);
int max_fd = server_fd;

while (1) {
    fd_set tmp = readfds; // dupe because select modifies it
    int activity = select(max_fd + 1, &tmp, NULL, NULL, NULL);
    if (activity < 0) { perror("select"); exit(1); }

    if (FD_ISSET(server_fd, &tmp)) {
        // new connection
        int client = accept(server_fd, ...);
        FD_SET(client, &readfds);
        if (client > max_fd) max_fd = client;
    }

    for (int i = 0; i <= max_fd; i++) {
        if (i == server_fd) continue;
        if (FD_ISSET(i, &tmp)) {
            // data available on socket i
            read(i, buffer, sizeof(buffer));
            // process request, write response, close
            FD_CLR(i, &readfds);
        }
    }
}
```

This works, but `select()` has several limitations:

1. **FD_SETSIZE limit**: The `fd_set` structure is typically fixed size (default 1024 in many implementations). You can't monitor more than that many file descriptors easily. You can recompile the kernel with a larger value, but it's not portable.
2. **Linear scanning**: After `select()` returns, you must iterate through all possible file descriptors from 0 to `max_fd` to find which ones are ready. This is O(n) per event, where n is the total number of descriptors monitored. If you have 10,000 connections and only one is active, you waste time checking 9,999 inactive ones.
3. **Modifying the set**: The kernel modifies the `fd_set` in place, so you need to copy it before each call (as we did with `tmp`).
4. **Not scalable**: The performance degrades as the number of monitored descriptors grows large.

#### `poll()`

`poll()` was introduced as a better alternative. Instead of using bit arrays, it uses an array of `struct pollfd`:

```c
struct pollfd {
    int   fd;         /* file descriptor */
    short events;     /* requested events */
    short revents;    /* returned events */
};
```

You allocate an array of these structures, one per descriptor, and call `poll()`. The kernel fills in the `revents` field for any descriptors that became ready.

```c
struct pollfd fds[MAX_CONNECTIONS];
// initialize...

while (1) {
    int ret = poll(fds, nfds, -1);
    if (ret < 0) { perror("poll"); exit(1); }

    for (int i = 0; i < nfds; i++) {
        if (fds[i].revents & POLLIN) {
            // data available on fds[i].fd
        }
    }
}
```

`poll()` solves the FD_SETSIZE limit and doesn't require copying. However, it still suffers from linear scanning: after `poll()` returns, you must iterate through the entire array to find which descriptors are ready. For thousands of connections, this becomes a performance bottleneck. Also, each call to `poll()` requires copying the entire array from user space to kernel space and back, which is expensive for large numbers of descriptors.

Both `select()` and `poll()` are O(n) per event, where n is the number of monitored descriptors. This is unacceptable for high-concurrency servers. The industry needed a new approach.

### Chapter 5: The Linux Revolution – `epoll`

In 2002, Linux introduced `epoll` as a scalable I/O event notification mechanism. Its key innovation: the kernel maintains an interest list of file descriptors, and when an event occurs, it adds that descriptor to a ready list. The user-space application can then retrieve **only the ready descriptors** using `epoll_wait()`. This reduces the amount of data copied and eliminates the linear scan.

`epoll` provides three main system calls:

- `epoll_create()`: Creates an epoll instance (returns a file descriptor).
- `epoll_ctl()`: Controls interest list: add, modify, or remove a file descriptor.
- `epoll_wait()`: Waits for events, returning only the ready descriptors.

Unlike `select()`/`poll()`, `epoll` can be used in two modes:

- **Level-triggered (LT)**: The default. `epoll_wait()` returns a descriptor as ready as long as there is data to read or space to write. This is similar to `poll()`.
- **Edge-triggered (ET)**: The descriptor is reported as ready **once** when it transitions from not-ready to ready. After that, you must read/write until `EAGAIN`. This reduces the number of wakeups but requires careful handling.

The real power of epoll, however, is that it doesn't require iterating over all descriptors. The `epoll_event` array returned by `epoll_wait()` contains only the events that occurred.

Here's the basic usage:

```c
int epoll_fd = epoll_create1(0); // or epoll_create(1) with size hint (ignored)

struct epoll_event ev, events[MAX_EVENTS];
ev.events = EPOLLIN; // level-triggered by default
ev.data.fd = server_fd;
epoll_ctl(epoll_fd, EPOLL_CTL_ADD, server_fd, &ev);

while (1) {
    int nfds = epoll_wait(epoll_fd, events, MAX_EVENTS, -1);
    for (int i = 0; i < nfds; i++) {
        if (events[i].data.fd == server_fd) {
            // new connection
            int client = accept(server_fd, ...);
            // set client socket non-blocking
            ev.events = EPOLLIN | EPOLLET; // edge-triggered for efficiency
            ev.data.fd = client;
            epoll_ctl(epoll_fd, EPOLL_CTL_ADD, client, &ev);
        } else {
            // data available on client socket
            int client = events[i].data.fd;
            // read until EAGAIN
            read(client, buffer, sizeof(buffer));
            // process and reply, etc.
        }
    }
}
```

The benefits are enormous:

- **Only returns ready descriptors** – no scanning.
- **O(1) per event** – constant time to get the next event, regardless of total number of monitored descriptors.
- **No copying of interest lists** – kernel keeps the list; you only pass a small array for results.
- **Scales to tens of thousands of file descriptors** (and more) with linear performance in number of active connections, not total connections.

This is the model used by Nginx, HAProxy, Node.js (libuv), Redis, and many other high-performance servers.

The barber shop analogy transforms: now we have a single barber (single thread) who can serve many customers. Customers sit in a waiting room; the barber wears a headset that notifies them only when a specific customer is ready (e.g., "Customer #42 has finished filling out the form"). The barber doesn't poll each customer—they wait for a page. That's epoll.

### Chapter 6: Building a Full Non-Blocking HTTP Server with epoll (Edge-Triggered)

Let's build a complete, minimal HTTP server in C using epoll in edge-triggered mode. We'll keep it simple: serve a static response for any request. But we'll handle multiple connections concurrently without threads.

**Step 1: Set up the server socket**

Create a listening socket, set it to non-blocking, bind, listen.

```c
int server_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(8080), .sin_addr.s_addr = INADDR_ANY };
bind(server_fd, (struct sockaddr*)&addr, sizeof(addr));
listen(server_fd, SOMAXCONN);
```

**Step 2: Create epoll instance and add server_fd**

```c
int epoll_fd = epoll_create1(0);
struct epoll_event ev = { .events = EPOLLIN | EPOLLET, .data.fd = server_fd };
epoll_ctl(epoll_fd, EPOLL_CTL_ADD, server_fd, &ev);
```

**Step 3: Event loop**

```c
#define MAX_EVENTS 64
struct epoll_event events[MAX_EVENTS];

while (1) {
    int n = epoll_wait(epoll_fd, events, MAX_EVENTS, -1);
    for (int i = 0; i < n; i++) {
        int fd = events[i].data.fd;
        uint32_t evflags = events[i].events;

        if (fd == server_fd) {
            // Accept all pending connections (edge-triggered requires loop)
            while (1) {
                struct sockaddr_in client_addr;
                socklen_t client_len = sizeof(client_addr);
                int client_fd = accept4(server_fd, (struct sockaddr*)&client_addr, &client_len, SOCK_NONBLOCK);
                if (client_fd == -1) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) break; // no more connections
                    else { perror("accept"); break; }
                }
                // Add client fd to epoll for read events (edge-triggered)
                struct epoll_event cli_ev = { .events = EPOLLIN | EPOLLET, .data.fd = client_fd };
                epoll_ctl(epoll_fd, EPOLL_CTL_ADD, client_fd, &cli_ev);
            }
        } else {
            // Client socket has data (or error)
            if (evflags & EPOLLIN) {
                // Read as much as possible until EAGAIN
                char buf[4096];
                ssize_t nread;
                while ((nread = read(fd, buf, sizeof(buf))) > 0) {
                    // accumulate data or process partial request
                }
                if (nread == -1 && errno != EAGAIN) {
                    perror("read");
                    close(fd);
                    continue;
                }
                // Process request (for simplicity, we assume full request is in buffer)
                // In real server, would need to handle partial reads and buffer
                const char *response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
                // Write response - careful with non-blocking writes!!
                // We'll write in a loop (non-blocking) until all sent or EAGAIN
                // Here we cheat and assume it goes through
                write(fd, response, strlen(response));
                // After writing, we might want to close (for HTTP/1.0) or wait for next request
                // For simplicity, close
                close(fd);
                // In real server, you'd add the fd to epoll for EPOLLOUT and manage state.
            }
            if (evflags & (EPOLLERR | EPOLLHUP)) {
                close(fd);
            }
        }
    }
}
```

This is a working core, but it's incomplete: we read data but we may not have the full HTTP request in one read. We need to buffer data and handle HTTP parsing across multiple reads. Also, after sending the response, we should not close the connection immediately if the client expects keep-alive. But for demonstration, it works.

To make it production-grade, we need to implement a state machine for each connection: reading headers, reading body, writing response, possibly reusing the connection. Each connection would have a buffer and state, stored in a structure, and we'd associate that structure with the file descriptor via `epoll_event.data.ptr` (instead of `.fd`). That's how Nginx does it.

### Chapter 7: Why Edge-Triggered vs Level-Triggered Matters

In the code above, we used `EPOLLET`. Edge-triggered means you get only one notification per state change. For example, when data arrives on a socket, epoll returns that descriptor once. If you don't read all the data, you won't be notified again unless new data arrives. This forces you to read until `EAGAIN` (i.e., exhaust the kernel buffer). That's why we had the `while` loop for `read()` and for `accept()`.

Level-triggered (the default) would repeatedly give you the same descriptor as long as data remains. That's simpler to code (you don't need to loop), but it can cause more `epoll_wait()` returns, especially if you have many connections with a little data each. Both are accepted, but for high-efficiency servers, edge-triggered reduces unnecessary wakeups.

**Edge-triggered pitfalls**: If you miss reading all data (e.g., because your user-space buffer is full), you may lose data or cause a hang. This requires careful buffer management. Many servers use a hybrid: they add the fd back to epoll with `EPOLLET` but also keep a flag indicating they are still reading. For simplicity, many libraries (like libuv) use level-triggered for readability but edge-triggered for acceptability.

### Chapter 8: Comparing Performance – Threads vs epoll

Let's write a quick benchmark. We'll simulate 10,000 concurrent clients sending small HTTP requests to a server. We'll compare:

- **Thread-per-connection** (using pthreads, each thread handles one request and exits)
- **Fork-per-connection** (processes)
- **epoll-based single-threaded**

Assume each request takes 1 ms of CPU (parsing and formatting) and 5 ms of network I/O waiting. With blocking threads, each thread is idle for 5 ms out of 6 ms, so CPU utilization is ~16%. With 10,000 threads, we have huge memory overhead (10,000 \* 1 MB = 10 GB just for thread stacks) and context-switching overhead. The system will degrade rapidly.

With epoll, a single thread can handle all 10,000 connections. The CPU is only busy when there is actual work (1 ms per request). Since I/O waiting does not consume CPU, the thread can process many requests per second. The throughput is limited only by CPU processing capacity, not by thread count. Real-world numbers: Nginx can handle 10k+ concurrent connections on a modest machine with low CPU usage.

But does a single-threaded epoll server use only one core? Yes, but you can scale by running multiple worker processes (each with its own epoll instance) bound to different cores, like Nginx does. This still avoids the thread-per-connection overhead.

### Chapter 9: Real-World Implementation Details

Writing a robust HTTP server from scratch is far more complex. Here are some challenges:

- **Partial reads**: As mentioned, you must buffer data until you have a complete request header (ending with `\r\n\r\n`). Then parse the method, path, headers, content-length, etc. Then read the body.
- **Non-blocking writes**: Writing a response may not complete in one `write()`. The kernel buffer might be full. You must track how much was written, and when `write()` returns `EAGAIN`, you must wait for the socket to become writable by re-adding it to epoll with `EPOLLOUT`. Then continue writing when notified. This adds state complexity.
- **Timeouts**: Connections that are idle for too long should be closed. You need a timer mechanism, either by periodically checking a timestamp per connection or using `timerfd` with epoll.
- **Keep-Alive**: HTTP/1.1 persistent connections allow reusing the socket for multiple requests. After sending a response, you don't close the socket; you reset the state and wait for the next request. You must be careful to not confuse data from a previous request.
- **Buffer management**: You need to allocate per-connection buffers efficiently. Using dynamic buffers with static pools avoids mallocs in hot paths.
- **Event demuxing**: Besides reading and writing, you may have signals, timers, and other file descriptors (like listening on multiple ports). Everything goes through the same epoll instance.

**Example: using `epoll_event.data.ptr` to store state**

Instead of just using `.fd`, we can allocate a per-connection structure and point to it:

```c
typedef struct conn {
    int fd;
    int state; // READING_HEADERS, READING_BODY, WRITING_RESPONSE
    char *read_buf;
    size_t read_len;
    char *write_buf;
    size_t write_offset;
    size_t write_len;
    // ...
} conn_t;

// When adding a new client:
conn_t *c = malloc(sizeof(conn_t));
c->fd = client_fd;
// init...
struct epoll_event ev;
ev.events = EPOLLIN | EPOLLET;
ev.data.ptr = c;
epoll_ctl(epoll_fd, EPOLL_CTL_ADD, client_fd, &ev);
```

Then in the event loop, we cast `events[i].data.ptr` to `conn_t*`. This avoids needing a map from fd to state.

### Chapter 10: The Bigger Picture – I/O Models Across Platforms

Linux has epoll. But what about other operating systems?

- **FreeBSD / macOS**: `kqueue` – similar to epoll, but more flexible (can monitor signals, processes, etc.). Many consider it even better designed.
- **Windows**: IOCP (I/O Completion Ports) – a fundamentally different model, asynchronous I/O where the kernel notifies you on completion, not readiness. This is more powerful but harder to program.
- **Solaris**: `event ports` (port_get, port_associate).

High-level libraries like **libuv** (used by Node.js), **libevent**, and **libev** abstract over these platform-specific APIs, providing a unified event loop. For example, libuv uses epoll on Linux, kqueue on macOS, and IOCP on Windows.

Understanding epoll, therefore, gives you insight into how these libraries work under the hood.

### Chapter 11: Beyond HTTP – Other Use Cases

The non-blocking I/O model isn't just for web servers. Any network application benefits:

- **Proxy servers** (Nginx, HAProxy, Squid)
- **Redis**: single-threaded, uses epoll/kqueue to handle thousands of clients.
- **Messaging systems** (RabbitMQ, ZeroMQ)
- **Game servers**: handle many simultaneous players.
- **Real-time data pipelines**: Kafka brokers use a network layer built on top of epoll.
- **Database clients**: libpq (PostgreSQL's client library) can be set to non-blocking to enable async queries.

The principle extends to file I/O too. Traditionally, disk I/O is blocking, but Linux provides `io_uring` (since kernel 5.1) which allows async file I/O, similar to IOCP. That's the next evolutionary step.

### Chapter 12: Conclusion and Call to Action

We started with a barber shop where only one customer could be served at a time. We evolved to a shop with dozens of barbers (threads) but hit resource limits. Finally, we discovered an efficient notification system (epoll) where one barber can serve an entire waiting room, always knowing exactly who needs attention, without wasting time checking every seat.

The journey from blocking I/O to epoll is more than a historical curiosity. It is a paradigm shift in how we think about concurrency: instead of assigning a thread to each task, we assign a task to each event. This event-driven model is the foundation of modern, high-performance servers.

If you are a developer, I urge you to try implementing a small non-blocking server in C using epoll. It will deepen your understanding of how operating systems work, how to design state machines, and why frameworks like Node.js and Nginx perform as they do.

Take the code snippets in this post, build upon them, add proper HTTP parsing, implement keep-alive, and run a benchmark against a simple threaded server. The difference will be striking. You will see for yourself that the hardware is ready to scream, and now you know how to let it.

The barber shop is waiting. Go build something that doesn't wait.
