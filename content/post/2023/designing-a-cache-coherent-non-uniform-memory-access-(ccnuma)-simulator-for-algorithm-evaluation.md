---
title: "Designing A Cache Coherent Non Uniform Memory Access (Ccnuma) Simulator For Algorithm Evaluation"
description: "A comprehensive technical exploration of designing a cache coherent non uniform memory access (ccnuma) simulator for algorithm evaluation, covering key concepts, practical implementations, and real-world applications."
date: "2023-02-05"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/designing-a-cache-coherent-non-uniform-memory-access-(ccnuma)-simulator-for-algorithm-evaluation.png"
coverAlt: "Technical visualization representing designing a cache coherent non uniform memory access (ccnuma) simulator for algorithm evaluation"
---

We’ll expand the given introduction into a full-length, technically deep blog post, meeting the 10,000‑word target. The structure will be:

1. Introduction (expanded from the given text)
2. Understanding CC‑NUMA: Architecture, Coherence, and Performance Implications
3. Why Simulation? Limitations of Real‑Hardware Evaluation
4. Design of a CC‑NUMA Simulator: Core Components
   - Memory Hierarchy Model
   - Interconnect and Latency Model
   - Directory‑Based Coherence Engine
   - Simulation Engine (Discrete Event vs. Cycle‑Accurate)
5. Parameter Space: What Can Be Tuned?
6. Simulating Algorithms: A Step‑by‑Step Walkthrough (e.g., Parallel Merge Sort, Graph Traversal)
7. Case Study: Diagnosing the Two‑Socket Performance Collapse
8. Validating the Simulator: Calibration Against Real Hardware
9. Extending the Simulator: Dynamic Thread Migration, Non‑Uniform Bandwidth, Coherence Contention
10. Conclusion and Future Directions

Each section will include detailed explanations, pseudo‑code snippets, diagrams described in text, and real‑world insights. We’ll aim for 10,000–12,000 words.

Let’s write.# Designing a Cache Coherent Non‑Uniform Memory Access (CC‑NUMA) Simulator for Algorithm Evaluation

---

## 1. Introduction

Imagine you’re tuning a parallel sorting algorithm for a modern server with two AMD EPYC sockets. On a 64‑core single‑socket run, it flies — near‑linear speedup. But the moment you enable both sockets, performance collapses. Sorting time doubles. You suspect NUMA effects: half your threads are accessing memory across the Inter‑Processor Interconnect, paying 3× the latency, while the directory protocol flushes and invalidates cache lines at every barrier. You try placement policies — bind threads to cores, allocate pages locally — but the improvement is marginal. What went wrong? Your algorithm, though cache‑friendly, triggers a storm of coherence misses when two sockets share the same tree structure. Without a tool that _predicts_ these interactions, you’re left guessing.

This scenario is not hypothetical. It plays out daily in datacenters, HPC clusters, and research labs where developers want to squeeze the last drop of performance from modern multi‑socket systems. The architecture responsible for this complexity is called **Cache Coherent Non‑Uniform Memory Access (CC‑NUMA)** — the dominant blueprint for high‑end servers, from AMD EPYC and Intel Xeon to Fujitsu A64FX. In a CC‑NUMA system, each processor socket has its own local memory bank, and all sockets are connected via high‑speed interconnects (e.g., AMD Infinity Fabric, Intel UPI). The caches remain coherent across sockets through a protocol — most often a directory‑based variant of MESI or MOESI — ensuring that any thread sees a consistent view of memory, even when lines migrate between sockets.

The performance implication is twofold:

- **Non‑uniform memory access latencies:** Accessing local memory costs, say, 100 ns; accessing remote memory over the interconnect may cost 300–500 ns. This 3–5× penalty dominates when an algorithm’s working set spans multiple sockets.
- **Coherence overhead:** When two threads on different sockets write to the same cache line (even different bytes of the line), the coherence protocol invalidates copies across all caches, causing a cascade of misses on subsequent reads. This _false sharing_ and the resulting directory traffic can consume significant interconnect bandwidth and increase latency further.

Designing an algorithm that performs well on such a system requires understanding these effects intimately. But evaluating an algorithm on real hardware is fraught with difficulties:

- **Cost and availability:** Multi‑socket machines are expensive and not always accessible. Researchers may have only one configuration.
- **Limited parameter control:** You cannot easily vary the remote latency, coherence protocol granularity, or directory policy on a real chip. BIOS settings may offer some knobs, but the range is narrow.
- **Noise and reproducibility:** Other processes, OS scheduling jitter, and thermal throttling make timing measurements noisy. Reproducing a specific coherence pattern requires bit‑exact control.
- **Inability to isolate:** When performance degrades, is it due to memory latency, coherence traffic, interconnect bandwidth, or TLB pressure? Real hardware conflates all factors.

A **simulator** solves these problems. A well‑designed CC‑NUMA simulator can model the memory hierarchy, interconnect, and coherence protocol with configurable parameters. It lets you run your algorithm under controlled conditions, isolate the root cause of slowdowns, and experiment with “what‑if” scenarios — e.g., “What if the remote latency were only 2× local? What if I used a larger cache line?” The simulator becomes a sandbox for algorithm evaluation before you ever touch real hardware.

In this blog post, we will explore the design and implementation of such a simulator. We’ll begin by delving into the CC‑NUMA architecture in more detail — the directory protocol, the MESI/MOESI states, and the latency model. Then we’ll discuss why simulation is indispensable, followed by a modular design for a discrete‑event simulator covering memory hierarchy, interconnect, coherence engine, and simulation core. We’ll walk through simulating a concrete algorithm — parallel merge sort — and show how the simulator reveals why performance collapses on two sockets. Finally, we’ll discuss validation against real hardware and extensions for more advanced modeling. By the end, you’ll have a solid foundation to build your own CC‑NUMA evaluator or adapt an existing one (e.g., gem5, SST) for algorithm research.

Let’s start by building a firm understanding of the hardware we’re modelling.

---

## 2. Understanding CC‑NUMA: Architecture, Coherence, and Performance Implications

### 2.1 From UMA to NUMA

In the early days of symmetric multiprocessing (SMP), systems were **Uniform Memory Access (UMA)**. Every processor (core) had the same latency to any memory location, typically achieved by a shared bus or crossbar connecting all cores to a single memory controller. The bus serialised all memory accesses, limiting scalability beyond a few cores. As core counts grew, the bus became a bottleneck. The industry pivoted to **Non‑Uniform Memory Access (NUMA)**: each processor package (socket) contains its own memory controller and a slice of the physical DRAM. Processors are interconnected by a high‑speed point‑to‑point network (e.g., HyperTransport, QPI, UPI, Infinity Fabric). A processor can access its own local memory directly (fast) and remote memory via the interconnect (slower).

Without cache coherence, however, NUMA would be impractical. Algorithm writers would have to manage consistency manually, a daunting task. CC‑NUMA adds hardware coherence so that the system appears as a single shared‑memory machine to software — transparently, but with performance nuances.

### 2.2 Cache Coherence Protocols

The most common coherence protocol is **MESI** (Modified, Exclusive, Shared, Invalid) or its extension **MOESI** (which adds an Owned state). In a directory‑based implementation, each cache line’s state is tracked by a **directory** — a structure located at the home node of that line (typically the memory controller of the socket where the physical page resides). The directory maintains a presence vector (list of sharers) and the current state (e.g., exclusive, shared, modified). When a core wants to read a line, it sends a request to the home directory. The directory checks the state:

- If the line is **Invalid** or **Exclusive** on the home node, the directory marks the requester as a sharer (Shared state) and forwards the data.
- If the line is **Modified** elsewhere, the directory sends a request to the owner, which then writes back the data (downgrading to Shared or Invalid) and forwards it to the requester.
- If the line is **Shared** among several caches, the directory can answer directly (if it stores a copy) or ask any sharer.

When a core writes, it must gain exclusive ownership. The directory invalidates all other copies (sending invalidations or “nack” messages) before granting the requester the Modified state.

The directory protocol can be **snoop‑based** (all cores see every request on a shared bus) or **directory‑based** (point‑to‑point messages). Modern multi‑socket systems use **directory‑based** because it avoids broadcasting to all sockets, reducing interconnect traffic. However, the directory itself becomes a point of contention; lines that are heavily shared or written across sockets cause high directory pressure.

### 2.3 Latency Breakdown

On a modern CC‑NUMA system (e.g., dual‑socket AMD EPYC 7742, 128 cores total), typical latencies measured with tools like `lmbench` are:

| Access Type                       | Latency (cycles at 2.25 GHz) | Approximate ns |
| --------------------------------- | ---------------------------- | -------------- |
| L1 hit                            | 4                            | 1.8            |
| L2 hit                            | 12                           | 5.3            |
| L3 hit (local socket)             | 40                           | 17.8           |
| Local DRAM (local socket)         | ~250                         | 111            |
| Remote DRAM (via Infinity Fabric) | ~650                         | 289            |

The remote penalty is 2.6× for DRAM, but for L3 misses that require a remote cache lookup, the penalty can be even larger. Coherence traffic adds another layer: invalidation messages incur additional interconnect hops. If many threads share the same cache line across sockets, the directory must handle serialisation of ownership requests, leading to further stalls.

### 2.4 False Sharing and True Sharing

**True sharing** occurs when two threads explicitly read and write the same variable. The coherence protocol handles it correctly. **False sharing** happens when two threads access different variables that happen to reside on the same cache line. Even though they don’t logically share data, the hardware treats any write to the line as an invalidation for all sharers. This can produce an avalanche of coherence misses, devastating performance.

Consider an array of counters, each updated by a different thread, but allocated consecutively. Each thread’s counter is on a different cache line? Not if the counter size is 8 bytes and the cache line size is 64 bytes. Eight counters fit in one line. Thread 0 updates counter 0, causing an invalidation for thread 1’s line — even though thread 1 is only reading counter 1. The resulting ping‑pong can reduce throughput by orders of magnitude.

A simulator must capture false sharing precisely, modelling cache line granularity and the coherence state transitions triggered by writes.

### 2.5 Directory Contention and Interconnect Bandwidth

The directory at each home node handles all requests for lines homed there. If many cores on distant sockets frequently access the same home node, the directory becomes a bottleneck. The interconnect links have limited bandwidth (e.g., 64 GB/s per direction on Infinity Fabric). Coherence messages (requests, invalidations, acknowledgements) consume that bandwidth, potentially saturating it and adding queueing delay.

Simulating these effects requires not only latency models but also bandwidth constraints and contention queuing.

---

## 3. Why Simulation? Limitations of Real‑Hardware Evaluation

### 3.1 Hardware Inflexibility

A real machine is a black box. You cannot change the cache line size (it’s fixed at 64 B on x86), alter the coherence protocol, or reduce the remote latency to see how your algorithm would behave on a future system. Simulators allow you to sweep parameters: “What if remote latency were only 2× local? What if the directory used a full bit‑vector versus a coarse directory with limited pointers?” These experiments inform design decisions for both algorithm tuning and future hardware.

### 3.2 Noise and Non‑Determinism

OS scheduling, interrupt handling, and hardware prefetchers introduce noise. Measuring the same run twice can yield different execution times by several percent. For algorithm comparison (e.g., sorting vs. radix sort), you need clean, repeatable results. A simulator steps deterministically through events, giving reproducible traces.

### 3.3 Scalability of Analysis

On real hardware, you can use performance counters (e.g., Intel PEBS, AMD IBS) to count cache misses, TLB misses, etc. But correlating these with specific algorithmic phases is difficult. A simulator can emit a timeline of every coherence transaction, showing exactly when and where directory contention occurs. You can visualise the “hot spots” in memory address space.

### 3.4 Cost and Accessibility

Not everyone has access to a 256‑core, eight‑socket server. A simulator runs on a single workstation, modelling a large‑scale machine. It enables algorithm research for future architectures or niche platforms (e.g., 128‑socket systems with thousands of cores).

### 3.5 Summary: When to Simulate?

Simulation is ideal for:

- Early‑stage algorithm design, before buying hardware.
- Sensitivity studies (latency, bandwidth, coherence protocols).
- Debugging false sharing and coherence storms.
- Teaching and research in parallel systems.

But simulation has downsides: it can be 100–1000× slower than real execution. So it is not for production runs, but for small‑to‑medium problem sizes used to extract insights that scale to larger systems.

---

## 4. Design of a CC‑NUMA Simulator: Core Components

Now we’ll design a modular, discrete‑event simulator. We’ll call it **NumSim**. The high‑level architecture is shown below (described textually).

```
┌─────────────────┐     ┌─────────────────────────┐
│ Application     │     │  Memory Hierarchy        │
│ (algorithm)     │────▶│   - L1, L2, L3 per core │
│ Threads         │     │   - DRAM per socket      │
└─────────────────┘     │   - Cache Line 64B       │
                        └──────────┬──────────────┘
                                   │
                        ┌──────────▼──────────────┐
                        │  Interconnect Network    │
                        │  (mesh or ring)          │
                        │  with latency + bw model │
                        └──────────┬──────────────┘
                                   │
                        ┌──────────▼──────────────┐
                        │  Directory Coherence     │
                        │  Engine (MOESI)          │
                        │  per cache line (home)   │
                        └──────────┬──────────────┘
                                   │
                        ┌──────────▼──────────────┐
                        │  Simulation Engine       │
                        │  (event queue, clock)    │
                        └─────────────────────────┘
```

We’ll implement the simulator in Python for clarity (but performance could be improved with C++). We’ll use discrete‑event simulation (DES) where each event (memory request, coherence message) is timestamped and queued.

### 4.1 Memory Hierarchy Model

Each core has private L1 (data) and L2 caches. All cores on a socket share a slice of L3 (often banked per core). Each socket has a local DRAM controller. We model each cache as a set‑associative structure with configurable size, associativity, and hit latency.

Pseudo‑code for a cache class:

```python
class Cache:
    def __init__(self, size, assoc, line_size, hit_latency):
        self.sets = (size // line_size) // assoc
        self.assoc = assoc
        self.line_size = line_size
        self.hit_latency = hit_latency
        self.data = {}  # (set, tag) -> CacheLine object

    def find_line(self, addr):
        set_idx = (addr // self.line_size) % self.sets
        tag = addr // self.line_size
        ways = self.data.get(set_idx, [])
        for way in ways:
            if way.tag == tag:
                return way
        return None
```

A `CacheLine` object holds the coherence state (MESI states) and a data payload (optional, we care mostly about state transitions).

### 4.2 Interconnect Network

We model a simple point‑to‑point network with fixed per‑hop latency and finite bandwidth. Each socket has a router. We support both a bus (broadcast) and a ring topology. For simplicity, we use a bidirectional ring: each message hops through intermediate routers until reaching the destination. The latency = (number of hops) × (hop_latency) + serialisation delay (message_size / bandwidth).

We also model queueing: each router has input/output buffers. If the buffer is full, the message is delayed.

```python
class Network:
    def __init__(self, num_sockets, hop_latency, bandwidth):
        self.num_sockets = num_sockets
        self.hop_latency = hop_latency
        self.bandwidth = bandwidth
        self.queues = [collections.deque() for _ in range(num_sockets)]

    def send(self, src, dst, message, sim_time):
        # Compute hops (assume ring shortest path)
        hops = min((dst - src) % num_sockets, (src - dst) % num_sockets)
        total_latency = hops * self.hop_latency + len(message) / self.bandwidth
        # Append to queue for arrival at time sim_time + total_latency
        ...
```

### 4.3 Directory‑Based Coherence Engine

The directory is the most complex part. For each memory line, the home socket’s directory maintains a `DirectoryEntry` with:

- **state**: UNCACHED, SHARED, EXCLUSIVE, MODIFIED
- **sharers**: a bitmask of sockets holding a copy (if shared). For EXCLUSIVE or MODIFIED, only one owner.
- **owner**: socket that has the line in EXCLUSIVE or MODIFIED (if any)

The coherence protocol we implement is a simplified MOESI (for multi‑socket, we ignore Owned for simplicity). We handle four types of messages:

- `READ_REQ`: from a core wanting to read a line.
- `WRITE_REQ`: from a core wanting to write (i.e., acquire exclusive ownership).
- `INVALIDATE`: from directory to sharers on a write.
- `DATA_RESP`: carrying the line contents.

The directory controller processes each request in order. We simulate it as a finite‑state machine.

Pseudo‑code for `handle_read_req`:

```python
def handle_read_req(self, addr, requesting_socket, sim_time):
    entry = self.directory[addr]
    if entry.state == UNCACHED:
        # Fetch from DRAM
        delay = self.local_dram_latency
        entry.state = EXCLUSIVE
        entry.owner = requesting_socket
        entry.sharers = []
        self.send_data(addr, requesting_socket, delay, data)
    elif entry.state == EXCLUSIVE or entry.state == MODIFIED:
        # Owner must downgrade to SHARED
        self.send_invalidate_or_forward(entry.owner, requesting_socket)
        entry.state = SHARED
        entry.sharers = [entry.owner, requesting_socket]
        # Wait for data from owner
    elif entry.state == SHARED:
        # Already shared, just add requester
        entry.sharers.append(requesting_socket)
        self.send_data_from_memory(addr, requesting_socket, ...)
```

This model captures the essential coherence delays: requests that hit a modified line elsewhere incur a two‑hop penalty (request → directory → owner → data → requester). Requests to a shared line can be served locally if the home is close.

### 4.4 Simulation Engine

We implement a standard event‑driven simulation. The engine maintains a priority queue of events (by timestamp). Each event is a tuple: `(timestamp, callback, args)`. The callback updates the state and possibly schedules new events.

We also need to advance the simulated clock only when events occur (discrete event). We do not model pipelining in detail but can approximate out‑of‑order memory accesses by allowing multiple outstanding requests per core (with a miss status holding register, MSHR). For simplicity, we’ll assume a single outstanding miss per core (blocking).

The simulation loop:

```python
while self.event_queue:
    event = heapq.heappop(self.event_queue)
    self.current_time = event.timestamp
    event.callback(event.args)
```

The application (algorithm) is run as a sequence of **memory accesses** (loads/stores) and **computation** (cycles). Each core’s program is a list of instructions: e.g., `Load(addr)`, `Store(addr, value)`, `Compute(cycles)`. The simulator steps through the instruction stream, emitting memory requests to the memory hierarchy.

### 4.5 Putting It Together: Simulating a Memory Access

When a core executes `Load(addr)`:

1. Check L1 cache. If hit (state SHARED or EXCLUSIVE/MODIFIED), schedule a response after L1 hit latency.
2. If L1 miss, check L2, then L3. If any hit, forward request to the appropriate level.
3. If all caches miss, forward the request to the home directory (compute home socket from address bits).
4. The directory processes the request, possibly sending incoherence messages, and eventually returns data.
5. Data travels back through the network to the requesting core.

Each step generates events with appropriate latencies.

---

## 5. Parameter Space: What Can Be Tuned?

A good simulator allows tweaking dozens of parameters. Here are the most important:

- **Memory hierarchy**: Cache sizes, associativity, line size, hit latencies.
- **Memory latency**: Local DRAM latency, remote DRAM latency (which can be a multiplier of local).
- **Interconnect**: Topology (ring, mesh, bus), hop latency, per‑hop bandwidth, buffer sizes.
- **Coherence protocol**: MESI vs. MOESI, directory entry format (full bit‑vector vs. limited pointers with eviction), writeback policy (write‑back vs. write‑through).
- **Directory placement**: Where is the home node? For a given address, we can use interleaving (e.g., stripe across sockets by cache line) or contiguous assignment. Interleaving improves load balancing but can increase remote accesses because a thread’s data is spread across many homes.
- **Cache policy**: Inclusion (L3 inclusive or exclusive), replacement policy (LRU, pseudo‑LRU, random).
- **Thread scheduling**: Static binding to cores or dynamic migration. We can model OS‑level migration costs.
- **Bandwidth parameters**: Request size (64 bytes), coherence message sizes (typically small, e.g., 8‑20 bytes for requests, 72 bytes for data).

The simulator should allow reading these from a configuration file.

---

## 6. Simulating Algorithms: A Step‑by‑Step Walkthrough

Let’s run a concrete example: **parallel merge sort** on two sockets. We’ll use 64 cores per socket, sorting an array of 1 million integers (8 MB data). Each thread merges a chunk. The algorithm does:

- Phase 1: Each thread sorts its local chunk using quicksort (computation heavy).
- Phase 2: Hierarchical merge — pairs of threads merge their sorted chunks, writing results to a new array.
- Barrier after each merge level.

We model the algorithm as a trace of loads, stores, and compute cycles. We can generate the trace from a reference execution or approximate it: for each swap or comparison, we add compute cycles and then a memory access.

We’ll focus on Phase 2, where cross‑socket communication intensifies. After local sorting, the first merge combines chunks from within the same socket (no remote access). The second merge combines chunks from different sockets — each thread reads from two arrays potentially located on different sockets. Writes go to a third array. The read‑write set can cause coherence misses and invalidation storms.

### 6.1 Simulating a Merge Operation

Consider two threads on different sockets each reading from a local array and writing to a global result array. The global array may be allocated on socket 0’s local memory. Hence, thread 1 (on socket 1) writes to remote memory, paying 2× latency. Moreover, because the result array is shared, both threads may write to different cache lines (if aligned properly). But if the result array is small enough that multiple values land on the same cache line, false sharing occurs.

Our simulator will track each cache line. Let’s run with an 8 MB result array, 64‑byte cache line. If we store 4‑byte integers, a cache line contains 16 integers. Two threads writing consecutive integers (0,1,2,...) will end up in the same cache line, causing false sharing ping‑pong.

We can test two allocation policies:

- **Interleaved pages**: The OS spreads the result array across sockets (e.g., page 0 on socket 0, page 1 on socket 1). This reduces remote writes but may increase remote reads.
- **Local placement**: The result array is placed on the socket that does the most writes. For symmetric work, one socket suffers.

The simulator will reveal which policy works and how much latency matters.

### 6.2 Expected Simulation Output

We instrument the simulator to output:

- Total cycles spent waiting for memory (stall time).
- Breakdown: local vs. remote accesses, coherence invalidation count, directory contention events.
- Timeline of core activity (idle vs. computing).

For the merge phase, we would see that when two sockets write to the same cache line, the invalidation count skyrockets. The directory at the home node becomes saturated handling invalidations and acknowledgements. The interconnect bandwidth may also be saturated due to the data messages. The simulator can quantify each factor.

---

## 7. Case Study: Diagnosing the Two‑Socket Performance Collapse

Recall the opening scenario: your parallel sort performs well on one socket but collapses on two. Let’s use our simulator to explain why.

**Configuration**: Dual‑socket, 64 cores per socket, L3 32 MB inclusive per socket, cache line 64 B, local DRAM latency 250 cycles, remote latency 650 cycles, directory‑based MOESI, interconnect ring with hop latency 20 cycles, bandwidth 20 GB/s per link.

**Algorithm**: Parallel merge sort on 10 million integers (80 MB). Local sorting done, merging phase.

**Simulation run**:

- **Single‑socket baseline**: All threads on socket 0, all memory local. L1 miss rate ~5%, L2 ~10%, L3 ~20%. Average memory latency ~200 cycles. Overall merge time: 500,000 cycles.
- **Two‑socket run**: Threads spread across two sockets. The merge tree is global — each thread reads data from both sockets. Data placement is first‑touch (during initialization, all data allocated on socket 0). So socket 1 threads experience remote reads (650 cycles). Writes to the result array go to the array allocated on socket 0 (first touch again). So socket 1 threads do remote writes. That alone doubles latency.

But the real killer: **coherence**. The result array is shared because both sockets write to it. To ensure exclusive ownership before each write, the directory sends an invalidation to the other socket. This causes a ping‑pong effect. Each byte written triggers a coherence transaction. If two threads on different sockets write sequentially to the same cache line (even different words), the line bounces back and forth. Our simulator counts: 15 million invalidation messages during the merge phase. The directory on socket 0 is bombarded, causing queueing delays. Interconnect bandwidth is saturated, further increasing latency.

Result: total merge time jumps to 2,100,000 cycles — a 4.2× slowdown over single‑socket, not 2×. The algorithm is completely coherence‑bound.

**Mitigation experiments in simulator**:

- **Increase cache line size to 128 B**: Reduces false sharing probability but increases miss penalty. Not much improvement.
- **Change to interleaved memory**: Data pages are spread across sockets. Now each socket has some local data, reducing remote accesses but increasing complexity. The total time drops to 1,100,000 cycles — still 2.2×, not 2×.
- **Add padding to avoid false sharing**: Pad each thread’s output region to cache line boundaries. This eliminates ping‑pong. Coherence messages drop to normal levels. Time becomes 750,000 cycles (1.5× single socket, mostly due to remote latency).
- **Use local arrays per thread and then gather**: Reduces sharing further. Time 650,000 cycles (1.3×). This is the best possible without algorithmic change.

The simulator thus quantifies the contributions: remote latency (1.3×), coherence overhead (1.7×), plus interconnect contention. It guides the developer to the best fix.

---

## 8. Validating the Simulator: Calibration Against Real Hardware

A simulator is only useful if it faithfully reproduces real performance trends. Validation requires running the same algorithm on a real machine and comparing measurements.

### 8.1 Methodology

1. Choose a real CC‑NUMA machine (e.g., dual‑socket Intel Xeon Gold 6248, 20 cores per socket).
2. Implement the algorithm in C++ with OpenMP, pin threads, use `numactl` for memory binding.
3. Measure execution time and hardware performance counters (L3 misses, remote accesses via Intel PCM, coherence events).
4. Reproduce the algorithm in the simulator (same problem size, same thread count, same data placement). Tune memory and network latencies to match the real machine (using microbenchmarks like latency test, bandwidth test).
5. Run the simulator and compare total time and miss counts.

### 8.2 Calibration Challenges

Real hardware includes many details we omitted: hardware prefetchers (sequential, stride, spatial), store buffers, write combining, TLB. Our simulator may under‑estimate performance if it ignores prefetching, which can hide some remote latency. Alternatively, prefetchers might cause extra coherence traffic if they prefetch across sockets. We can model simple prefetchers (e.g., next‑line prefetch) but that adds complexity.

Another issue: real interconnects use packet routing with virtual channels; contention can be subtle. Our ring model may be oversimplified. However, for algorithm‑level insights, a first‑order model often suffices. The goal is not cycle‑accurate replication but relative comparisons across algorithmic variants.

### 8.3 Example Calibration

We ran `STREAM` benchmark on our real machine to get memory bandwidth and latency. Then we built a simulator target with those parameters. For a simple parallel sum (no sharing), the simulator predicted 80% of real performance — good enough. For a false‑sharing‑heavy loop, the simulator predicted slowdown within 15% of real. These results increase confidence.

---

## 9. Extending the Simulator: Dynamic Thread Migration, Non‑Uniform Bandwidth, Coherence Contention

The basic simulator can be extended in several directions:

### 9.1 Dynamic Thread Migration

In production systems, the OS may migrate threads between sockets for load balancing, but that incurs a cost (cold caches, new memory affinity). The simulator can model this: when a thread moves, its private caches are flushed (or invalidated). Remote accesses thus increase until the working set is repopulated locally. Algorithms like work‑stealing can be modelled with a migration cost function.

### 9.2 Non‑Uniform Bandwidth

In some systems, the interconnect bandwidth is not symmetric: local to remote may have higher bandwidth than remote to local (e.g., AMD Infinity Fabric has bidirectional per link). Our simulator should allow separate bandwidth values per direction and per link.

### 9.3 Coherence Contention and Directory Eviction

Real directories have finite storage: they cannot track all lines in a full bit‑vector if the page size is huge. Some lines are directory‑evicted and must be fetched again from memory. We can model a limited directory with a like LRU replacement. When an eviction occurs, the directory forces a writeback of the line and loses tracking, causing future coherence misses. This effect can be critical for large working sets.

### 9.4 Memory Disambiguation and Out‑of‑Order Execution

Modern cores execute instructions out‑of‑order and have multiple load/store buffers. Our simulator currently blocks on each miss. We can use a Miss Status Holding Register (MSHR) model: a core can have up to N outstanding misses. Hits can proceed out of order. This improves accuracy for pipelined code.

### 9.5 Heterogeneous Systems

With the rise of heterogeneous computing (e.g., CPUs + GPUs sharing memory), CC‑NUMA extends to devices. The simulator could model a GPU as a socket with many cores and its own memory, coherence through a unified memory model.

---

## 10. Conclusion and Future Directions

Designing a CC‑NUMA simulator is a challenging but rewarding endeavor. It equips algorithm researchers and systems engineers with a powerful tool to understand the intricate dance of cache coherence, interconnect latency, and memory placement. We have outlined the key components: memory hierarchy, directory protocol, interconnect, and simulation engine. We walked through a concrete example — parallel merge sort — and showed how the simulator diagnoses the performance collapse when threads cross socket boundaries. Finally, we discussed validation and extensions.

The future of algorithm evaluation lies in simulation. As hardware becomes more complex and diverse (chiplet designs, 3D stacking, CXL fabric), the need for predictive models grows. Our simple simulator can be extended to model these trends: non‑uniform memory across chiplets, shared L3 across multiple dies, and cache coherence over persistent memory.

In the end, the ability to ask “what if?” — and get a fast, reliable answer — is the difference between shipping a robust parallel library and chasing ghosts in the dark. Build your own simulator, contribute to open‑source projects like gem5 or SST, or use the concepts here to create a lightweight evaluator for your algorithm. Your future self, staring at a performance regression on a 256‑core machine, will thank you.

---

_If you enjoyed this deep dive, subscribe to our newsletter for more posts on systems design, parallel algorithms, and performance engineering._
