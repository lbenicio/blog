---
title: "The Performance Of Database Caching Strategies: Lru, Clock, Arc, And 2Q Under Real World Workloads"
description: "A comprehensive technical exploration of the performance of database caching strategies: lru, clock, arc, and 2q under real world workloads, covering key concepts, practical implementations, and real-world applications."
date: "2021-07-06"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-performance-of-database-caching-strategies-lru,-clock,-arc,-and-2q-under-real-world-workloads.png"
coverAlt: "Technical visualization representing the performance of database caching strategies: lru, clock, arc, and 2q under real world workloads"
---

The silence stretches for an agonizing three seconds. As a database administrator, you’ve felt that specific chill run down your spine—the moment a query that should be instantaneous crawls to a halt. You pull up your monitoring dashboard, and the story is written in stark red lines: the cache hit ratio has plummeted from 98% to 72%. Your database is thrashing. It is spending more time deciding what to evict than actually serving data. Your users are experiencing the digital equivalent of a shrug. The fix seems simple enough: get a better caching algorithm. But here’s the dirty secret of the database world: caching is less about raw memory capacity and more about the profound, often misunderstood art of predicting the future.

We often treat caching as a solved problem. We allocate memory, enable a policy, and walk away, assuming the hardware will do its magic. Yet, as any veteran systems engineer will tell you, a cache is only as good as its eviction strategy. The algorithm that decides what stays and what goes is the single most impactful software-level tuning knob for database performance, often dwarfing the gains from faster SSDs or additional CPU cores. A poorly chosen strategy can turn a terabyte of DRAM into an expensive paperweight. A brilliant one can make a modest server feel like a supercomputer. This isn't hyperbole; it is the cold, hard math of access patterns.

To understand why this matters so much, we must first acknowledge a painful truth about modern workloads. The era of the simple, uniform "read-old-data, write-new-data" application is dead. Today's databases serve a schizophrenic mix of traffic. There are bursts of viral popularity, where a single record (think the latest celebrity tweet or a hot product SKU) is hammered by millions of requests in seconds. There are seasonal scans, where a batch job reads a terabyte of cold data, polluting the cache with entries that will never be used again. There are long-tail queries, where users request data from the far fringes of history—a single row from a decade-old archive that must be served sub-second. This trinity of access patterns—Spike, Scan, and Ghost—defines the challenge. One algorithm cannot rule them all, and most defaults are built for a world that no longer exists.

### The Anatomy of a Miss: Why the Silence is so Loud

Before we solve the problem, we must fully feel its weight. Let’s analyze that three-second silence.

A single main memory access (DRAM) takes roughly 100 nanoseconds. A single random read from a modern NVMe SSD takes around 100,000 nanoseconds (0.1 milliseconds). A traditional spinning hard disk takes 10,000,000 nanoseconds (10 milliseconds). Now, imagine your application processes 10,000 queries per second (QPS). With a 98% cache hit ratio, you are serving 9,800 queries from memory (fast) and 200 from disk (slow). The 200 disk operations introduce perhaps 200ms of latency overhead worst-case, but a well-tuned system can parallelize this. Your average latency might still be sub-millisecond.

When that hit ratio drops to 72%, you are now serving 2,800 queries per second from disk. This is an order of magnitude increase in I/O. Those 200ms of extra latency balloon to seconds. The disk queue depth spikes. The CPU, waiting for data, becomes idle (seen as high `iowait`). The database mutexes guarding the buffer pool start to heat up. The entire machine locks. The _three seconds of silence_ is the sound of a universal stranglehold—a system perfectly balanced between compute and I/O has been pushed over the edge by a single algorithmic failure.

This phenomenon is formally known as **Thrashing**, a term coined in the seminal 1968 paper _The Working Set Model for Program Behavior_ by Peter Denning. Denning proved that every set of running processes has a _working set_—the set of pages (or cache lines) that the process needs in a given time window to make reasonable progress. If the physical memory allocated is smaller than this working set, the system spends all its time swapping pages in and out. It is no longer computing; it is only moving data. The cache is full of garbage, and every single request is a miss because the hot data is immediately evicted to make room for the next piece of cold data.

Your monitoring dashboard showed 72%. It was a death rattle, not just a metric.

### The Holy Grail: Belady's Optimal Algorithm

There is a theoretical upper bound for cache performance: **Belady's Optimal Algorithm (B0/CLOCK)**, described by Laszlo Belady in 1966. Belady's algorithm evicts the page that will be used furthest in the future.

If you know the entire future sequence of requests, you can always make the perfect eviction decision. This results in the absolute minimum number of cache misses.

- **How it works:** Keep a list of pages in the cache. For each page, look at its _next access time_ in the future request trace. Evict the page whose next access time is the furthest away (or that will never be accessed again).
- **Why we can’t use it:** It requires clairvoyance. In a database, we cannot know which query will hit which row ten minutes from now. The workload is stochastic.
- **Why we study it:** It provides a rock-solid baseline. If a new algorithm achieves a hit ratio of 85% on a given trace, and Belady’s achieves 90%, we know there is a 5% theoretical gap to close. No algorithm can ever do better than Belady’s.

Because Belady’s is impossible, the history of database caching is a history of increasingly sophisticated approximations of the future.

### The Classics: The Graveyard of Idealized Policies

#### FIFO (First-In, First-Out)

The simplest strategy. Pages are brought into a queue. When the cache is full, the page at the tail (the oldest) is evicted. It is a queue.

- **Pros:** Incredibly simple, O(1) complexity, no per-access bookkeeping.
- **Cons:** It knows nothing about _importance_. A critical, frequently accessed page that has been in the cache for a long time will be evicted simply because it arrived first. A one-hit-wonder that arrived five seconds ago stays.
- **The Trap:** FIFO has no concept of frequency or recency. It is rarely used alone in databases but is the core building block for many modern algorithms (like S3-FIFO).

#### LRU (Least Recently Used)

LRU is the default for nearly every buffer pool on the planet (including MySQL InnoDB's default for the young sublist). It evicts the object that was accessed furthest in the past.

- **Mechanism:** A doubly linked list plus a hash map. On every hit, the page is moved to the head of the list. On eviction, the page at the tail is dropped. This gives O(1) operations.
- **The "Stack Property":** LRU has a beautiful mathematical property. If you simulate a cache of size _n_, you can derive the hit ratio for any cache size _m < n_. The tail of the LRU list for size _n_ is the perfectly ordered list of the next eviction candidates. This allows for _stack simulation_ without re-running the trace.
- **The Scan Problem (The Fatal Flaw):** This is why three seconds of silence happens.
  - Imagine a cache of 100 pages, perfectly populated with hot data (Pages A1 to A100).
  - A sequential scan of 2000 pages arrives (Pages B1 to B2000).
  - On access to B1, it is a miss. B1 goes to the head of the list. A100 is evicted.
  - On access to B2, it is a miss. B2 goes to the head. A99 is evicted.
  - This continues. After 100 accesses to the scan, the cache is now entirely populated with B1-B100. All the useful hot data (A1-A100) has been evicted.
  - The scan continues. It reads B101, evicts B1. B1 is no longer needed.
  - The scan finishes. Now, a user wants A1. **Cache Miss!** A1 must be read from disk again. The entire buffer pool has been _polluted_ by a single sequential read.
  - **The Loop Problem:** If a working set is just 101 items, and your cache is 100 items, LRU will generate a miss on _every single access_ (Thrashing state).
- **Code Snippet (LRU Simulation):**

```python
from collections import OrderedDict

class LRUCache:
    def __init__(self, capacity):
        self.cache = OrderedDict()
        self.capacity = capacity
        self.hits = 0
        self.misses = 0

    def access(self, key):
        if key in self.cache:
            self.hits += 1
            self.cache.move_to_end(key)  # Recent
        else:
            self.misses += 1
            if len(self.cache) >= self.capacity:
                # Evict LRU (first inserted)
                self.cache.popitem(last=False)
            self.cache[key] = True  # Dummy value
```

#### LFU (Least Frequently Used)

Instead of recency, LFU tracks the _number of accesses_. It evicts the item with the smallest frequency count.

- **Mechanism:** A priority queue (min-heap) of frequency counters. On access, frequency is incremented.
- **The Pollution Problem (Stale Frequency):** A page that was popular exactly a month ago (Page A, hit 10,000 times) still has a high frequency. A new page that is extremely popular _right now_ (Page B, hit 100 times in the last second) will be evicted first because its absolute count is lower.
- **The Overhead:** Maintaining a perfect frequency for every item in a large cache is expensive. Using a min-heap requires O(log N) eviction.
- **The Fix (Aging):** Some LFU implementations (like Redis's `volatile-lfu` and `allkeys-lfu`) use _frequency decay_. Redis uses a Morris counter (a probabilistic counter) with a logarithmic increment and a periodic decimation (halving) of all counters. This allows it to gradually "forget" old hits.
- **Code Snippet (Redis LFU Decay Logic):**

```c
// Simplified from Redis source
uint8_t LFULogIncr(uint8_t counter) {
    if (counter == 255) return 255; // Max
    double r = (double)rand() / RAND_MAX;
    double base = 255 - counter;
    if (r < base / 255) return counter + 1;
    return counter;
}
// Counter is decremented (decayed) on access based on time.
```

### The Hybrid Revolution: ARC and 2Q

In the early 2000s, IBM researchers realized that neither pure Recency nor pure Frequency was sufficient. The key was _adaptation_.

#### 2Q (Two Queue Algorithm)

Proposed by Johnson and Shasha in 1994, 2Q separates the cache into three logical areas:

1.  **A1in:** A FIFO queue for the first access of an item.
2.  **A1out:** A ghost queue (keys only) for items evicted from A1in.
3.  **Am:** An LRU queue for "hot" items.

- **Mechanism:**
  - A miss brings the item to A1in.
  - If an item is accessed again while in A1in, it _promotes_ to Am.
  - If an item is evicted from A1in, its key goes to A1out.
  - A miss that finds its key in A1out means the item was _recently_ evicted. It is immediately considered "hot" and placed into Am.
- **Why it helps:** Scans populate A1in, but the items are evicted before they can enter Am. Only items accessed _twice_ (or evicted and re-requested) enter the real "hot" cache.
- **Problem:** The parameters (size of A1in, Am) are static. A workload with huge bursts needs a bigger A1in.

#### ARC (Adaptive Replacement Cache)

Invented by Nimrod Megiddo and Dharmendra Modha at IBM Almaden Research Center (2003). For a decade, this was the undisputed king of production caching.

- **The Philosophy:** Dynamically balance the space between "Recency" (LRU) and "Frequency" (LFU/2Q style).
- **The Data Structures:**
  - **T1:** Recent items. (True LRU list).
  - **T2:** Frequent items. (True LRU list, but only items that have been accessed _at least twice_ within the recent window).
  - **B1:** Ghost list for items evicted from T1.
  - **B2:** Ghost list for items evicted from T2.
- **The Magic (Adaptation Parameter _p_):**
  ARC has a control parameter `p` which dictates the target size of T1.
  - Initially, `p = 0` (full frequency bias) or initial guess.
  - **B1 Hit:** If a page is found in the ghost list B1, it means the workload is showing _Recency_ bias (items are being re-accessed immediately after eviction from T1). ARC increases `p`, shrinking T2 and growing T1.
  - **B2 Hit:** If a page is found in B2, it means the workload is showing _Frequency_ bias (stable hot items being evicted from T2). ARC decreases `p`, shrinking T1 and growing T2.
- **Code Snippet (ARC Core Logic):**

```python
class ARCCache:
    def __init__(self, capacity):
        self.c = capacity
        self.p = 0
        self.t1 = OrderedDict()
        self.t2 = OrderedDict()
        self.b1 = OrderedDict()
        self.b2 = OrderedDict()

    def _replace(self, key_in_b2):
        # Decide which list to evict from
        if (self.t1 and
            ((key_in_b2 and len(self.t1) == self.p) or
             (not key_in_b2 and len(self.t1) < self.p))):
            # Evict from T1, move to B1
            victim, _ = self.t1.popitem(last=False)
            self.b1[victim] = True
            if len(self.b1) > self.c:
                self.b1.popitem(last=False)
        else:
            # Evict from T2, move to B2
            victim, _ = self.t2.popitem(last=False)
            self.b2[victim] = True
            if len(self.b2) > self.c:
                self.b2.popitem(last=False)

    def access(self, key):
        if key in self.t1 or key in self.t2:
            # Cache Hit
            # Move to MRU of T2
        else:
            # Cache Miss
            if key in self.b1:
                # Adapt p (increase recency bias)
                delta = max(1, len(self.b2) // len(self.b1))
                self.p = min(self.c, self.p + delta)
                # Remove from B1, insert into T2
                del self.b1[key]
                self._replace(key_in_b2=False)
                self.t2[key] = True
            elif key in self.b2:
                # Adapt p (increase frequency bias)
                delta = max(1, len(self.b1) // len(self.b2))
                self.p = max(0, self.p - delta)
                # Remove from B2, insert into T2
                del self.b2[key]
                self._replace(key_in_b2=True)
                self.t2[key] = True
            else:
                # Brand new item
                if len(self.t1) + len(self.t2) >= self.c:
                    # Evict something
                    self._replace(key_in_b2=False)
                # Insert into T1
                self.t1[key] = True
```

- **Why ARC is great:** It is self-tuning. It automatically handles the "Scan vs. Loop" problem by sacrificing the recency cache to scans and preserving the frequency cache.
- **The Downfall of ARC:** Complexity and patents. The dual ghost lists require significant bookkeeping. It is heavier than simpler alternatives.

### The Modern Masters: TinyLFU and Window-TinyLFU

The next breakthrough came from Gil Einziger and colleagues in 2017, focusing on _Admission Control_ rather than just _Eviction_. Why let the scan into the cache in the first place?

#### TinyLFU (Tiny Least Frequently Used)

TinyLFU is not a full cache; it is an _admission filter_. It answers the question: "Should this new item be allowed into the cache?"

- **The Frequency Sketch:** To track frequency without consuming O(N) memory, TinyLFU uses a **Count-Min Sketch**. This is a probabilistic data structure (a 2D array of counters) that can estimate the frequency of a key with a bounded error. It is incredibly space efficient.
- **The Reset Mechanism (Sliding Window):** To solve the "stale frequency" problem of classic LFU, TinyLFU performs a _reset_ every ~N items (the window size). All counters in the sketch are halved (or decremented). This creates a decaying frequency window. Items that were hot 10,000 accesses ago are forgotten; items hot _now_ dominate.
- **How it works:** A new item `x` arrives. The current victim `y` is identified (the item about to be evicted). TinyLFU estimates `Freq(x)` and `Freq(y)` from the sketch. If `Freq(x) > Freq(y)`, admit `x` (and evict `y`). Otherwise, reject `x` and keep `y`.

#### W-TinyLFU (Window TinyLFU)

TinyLFU is brilliant for stable workloads but reacts slowly to sudden _bursts_. A video goes viral. It gets a few thousand hits in one second. Its frequency in the sketch is still low compared to the steady-state popular items.

- **The Solution: The Window Cache.**
  - W-TinyLFU splits the physical cache into two parts:
    1.  **Window Cache (LRU):** A small fraction of the total cache (usually ~1% in Caffeine, but adaptive).
    2.  **Main Cache (SLRU):** The majority of the cache, controlled by the TinyLFU admission policy.
  - **The Flow:**
    1.  A miss brings the item into the **Window Cache** (pure LRU).
    2.  If the item is hit again in the window, it is promoted to the **Main Cache**.
    3.  To enter the Main Cache, you must pass the **TinyLFU filter**. If admitted, you go to the _Probation_ segment of the Main (SLRU) cache.
    4.  If you survive a further eviction attempt from Probation, you go to _Protected_.
- **Why it rules:** The Window Cache handles the _burst_. TinyLFU handles the _long-tail stability_.
  - **Scans:** Enter the tiny Window Cache, get evicted immediately, never pollute the Main Cache.
  - **Viral Spikes:** Start in the Window Cache, get promoted to Main before they are evicted, pass the TinyLFU test due to their high recent frequency.
  - **Steady State:** Protected segment dominates.

**Caffeine** (Java) is the canonical implementation of W-TinyLFU. It is considered the state-of-the-art for in-process caching. It uses advanced techniques like _Hill Climbing_ to dynamically adjust the size of the Window Cache based on real-time hit rate monitoring.

### The FIFO Renaissance: S3-FIFO

Just when we thought the world belonged to complex adaptive algorithms and probabilistic sketches, the 2023 USENIX ATC paper "S3-FIFO: A Scalable and Space-Efficient FIFO-based Cache Algorithm" threw a wrench in the works.

The authors (Yang, Jiang, etc.) showed that a simple **FIFO** based cache could outperform LRU, ARC, and even W-TinyLFU in many workloads, especially those involving heavy high-frequency scans (typical in CDNs like Cloudflare).

- **The Architecture:**
  1.  **Small Cache (S-cache):** A tiny FIFO queue (10% of total capacity).
  2.  **Main Cache (M-cache):** A Space-Efficient FIFO queue.
  3.  **Ghost Cache (G-cache):** A FIFO queue of keys.
- **Mechanism:**
  - **Miss:** Insert item into S-cache. S-cache is FIFO.
  - **Hit in S-cache:** The item is _marked_ (a single flag).
  - **Eviction from S-cache (FIFO):** Evicts the oldest item in S-cache.
    - If the item was **unmarked** (never hit again), it is a _one-hit-wonder_. Its key goes to the **Ghost Cache**. It is dead.
    - If the item was **marked** (hit at least once), it is promoted to the **M-cache**.
  - **M-cache eviction:** M-cache also uses FIFO, but items can be re-inserted if they are found in the Ghost Cache.
  - **Ghost Cache:** Tracks the keys of recently evicted one-hit-wonders. If a key is found here on a miss, it is re-inserted into the Main Cache.
- **Why it works so well:**
  1.  **Scan Resistance:** A scan of 1M items hits the S-cache (10% of memory). Every item is evicted _before_ it can be hit again. They all go straight to the Ghost (unmarked) and are discarded. The Main Cache remains pristine.
  2.  **Burst Absorption:** A bursty item hits S-cache multiple times. It gets marked. It is promoted to Main.
  3.  **Frequency Tracking:** The Ghost Cache acts as a lightweight, implicit frequency sketch. An item that is repeatedly evicted and re-requested will always be re-inserted into Main.
- **Code Snippet (S3-FIFO Simulation):**

```python
from collections import deque

class S3FIFO:
    def __init__(self, total_cap):
        self.small_cap = total_cap * 0.1
        self.main_cap = total_cap - self.small_cap
        self.small = deque()
        self.main = deque()
        self.small_set = set()
        self.main_set = set()
        self.marked_small = set()
        self.ghost = deque()
        self.ghost_set = set()

    def _evict_small(self):
        key = self.small.popleft()
        self.small_set.discard(key)
        if key in self.marked_small:
            self.marked_small.discard(key)
            # Promote to Main
            if len(self.main_set) >= self.main_cap:
                # Evict from Main
                m_key = self.main.popleft()
                self.main_set.discard(m_key)
                # Move to Ghost
                self.ghost.append(m_key)
                self.ghost_set.add(m_key)
            self.main.append(key)
            self.main_set.add(key)
        else:
            # One-hit-wonder
            self.ghost.append(key)
            self.ghost_set.add(key)

    def access(self, key):
        if key in self.main_set or key in self.small_set:
            if key in self.small_set:
                self.marked_small.add(key)
            return  # Hit
        # Miss
        if key in self.ghost_set:
            # Re-insert into Main
            if len(self.main_set) >= self.main_cap:
                m_key = self.main.popleft()
                self.main_set.discard(m_key)
            self.main.append(key)
            self.main_set.add(key)
            return
        # Brand new
        if len(self.small_set) >= self.small_cap:
            self._evict_small()
        self.small.append(key)
        self.small_set.add(key)
```

- **Performance Results:** S3-FIFO achieves similar or better hit ratios than W-TinyLFU while being significantly simpler (no sketches, no hill-climbing) and often more cache-friendly due to its lack of random memory accesses (Bloom filters access many memory cells).

### Production Reality: Tuning the Unseen

You do not need to implement these algorithms from scratch. You need to know how to _choose_ them.

#### MySQL / InnoDB

- **Default:** LRU with a scan-resistant sublist.
- **The Tuning Knob:** `innodb_old_blocks_time`.
  - The buffer pool is split into a Young sublist (LRU) and an Old sublist.
  - New pages are inserted into the _middle_ of the LRU list (the head of the Old sublist).
  - They only move to the Young sublist if they survive for `innodb_old_blocks_time` milliseconds (default 1000ms).
  - **Why this helps scans:** A sequential scan reads pages quickly. They enter the Old sublist. If the scan is faster than the page's survival time, the pages are evicted from the Old sublist _before_ reaching the Young sublist. The real hot data stays in the Young sublist.
  - **Scenario:** Set `innodb_old_blocks_time = 0` for OLTP workloads that need immediate promotion. Set it higher (e.g., 2000ms) if you have heavy report scans.

#### Redis

- **Maxmemory Policy:**
  - `noeviction`: Return errors on writes when maxmemory is reached. (Safe but dangerous).
  - `allkeys-lru` / `volatile-lru`: Evict keys from the entire set / only those with TTL. Uses LRU approximation. **The trap:** Scans loop over lots of keys, evicting hot keys.
  - `allkeys-lfu` / `volatile-lfu` (Redis 4.0+): Uses the Morris counter LFU with aging. **Best for most modern workloads.** Handles scans much better than LRU because a one-hit-wonder scan will have a low frequency and be evicted immediately.
  - `allkeys-random`: Surprisingly good for some cases where workloads are very uniform.
  - **Tuning:** `OBJECT freq <key>` shows LFU counter. `lfu-decay-time` and `lfu-log-factor` control the aging and increment rate.

#### Memcached

- **The Facebook Problem:** Facebook (Meta) runs the largest Memcached deployment. They found LRU was terrible for their workload (flash crowds of photos, mixed with long tail).
- **The Fix:** They used a **Modified LRU with Dynamic Sizing**.
  - They added the **LRU Maintainer Thread** which crawls the LRU tail constantly, looking for expired items.
  - They added **Transparent Huge Pages** to reduce TLB misses.
  - They implemented a form of **Admission Control** where new items are not immediately inserted to the head of LRU if the tail contains items with very low recent access frequency (a primitive TinyLFU-like idea).

#### Caffeine (Java)

- **Setting:** `Caffeine.newBuilder().maximumSize(n).build()`
- **It uses W-TinyLFU.** You literally do not need to tune it for eviction.
- **Tuning:** The only knob is `initialCapacity` and `maximumSize`. The _Hill Climbing_ adaptively tunes the Window Cache size based on real-time hit ratio changes. It is the fire-and-forget champion of the JVM ecosystem.

### The Future of Caching: CXL, AI, and the Quantum Leap

The landscape is shifting again.

#### Tiered Memory (CXL)

Compute Express Link (CXL) allows for shared memory pools over a PCIe link. Your database might have a 100GB local DRAM cache (fast, expensive) and a 512GB CXL-attached memory cache (slower, cheaper).

- **Challenge:** How do we manage a multi-tier cache?
- **Possible Solution:** Use a fast algorithm (e.g., W-TinyLFU) for the local tier. Use a larger, scan-tolerant algorithm (e.g., S3-FIFO or 2Q) for the CXL tier. A miss in local DRAM does not go to disk; it goes to CXL. Eviction from CXL goes to disk. This is a three-tier hierarchy. The algorithm must now balance cost-latency curves.

#### KV-Cache (Large Language Models)

In LLM inference, the KV-Cache is the biggest memory bottleneck. It stores the Key and Value tensors for previous tokens.

- **Access Pattern:** Access is sequential and monotonically increasing. The cache size is tied to sequence length. Eviction is currently brute force (drop the oldest tokens or drop the highest sequence).
- **Future:** Adaptive KV-Cache eviction (e.g., "Heavy Hitter" eviction, keeping only the most attended tokens) is an active area of research. This is a specific, highly constrained caching problem that might yield to a custom algorithm.

#### Learned Caching

- **The Promise:** Instead of heuristics (recent, frequent), use a machine learning model (a small RNN or transformer) to predict the _probability_ that a specific item will be accessed again in the next N seconds.
- **The Reality (DeepMind's approach):** They built a model that can predict cache behavior better than LRU for some traces. The problem is latency. Running an inference on every single access adds microseconds. For an in-memory cache where a hit takes 100ns, this is an unacceptable 1000x slowdown.
- **The Niche:** Learned caching makes sense for _large object caches_ (e.g., CDNs, video caches) where a miss costs 100ms. The few microseconds of inference are negligible compared to the miss penalty.

### Conclusion: The Art of Controlled Amnesia

That three seconds of silence. It was not a hardware failure. It was an _algorithmic failure_. Your cache forgot the wrong things.

The dirty secret of the database world is that memory is worthless without a great eviction strategy. You must look at your workload.

- **Are you scanning a lot?** You need Scan Resistance (2Q, ARC, LIRS, S3-FIFO, or strict LFU).
- **Are you seeing bursts?** You need a Window (W-TinyLFU) or a promoted list (S3-FIFO).
- **Do you have a stable, long-tail distribution?** Pure LFU with aging (Redis) or W-TinyLFU (Caffeine) is perfect.

The days of setting `innodb_buffer_pool_size = 10G` and walking away are over. You must become a soothsayer of access patterns. You must choose the form of forgetting that best serves your data.

The database that remembers too much (the scans) will choke. The database that forgets too quickly (the hot items) will crawl. The perfect cache is not the one with the most memory; it is the one that executes the most perfect act of controlled amnesia.

Go look at your hit ratio. Is it telling a story of prediction, or a dirge of thrashing? The silence isn't an ending—it's a wake-up call. The algorithm is waiting for you to choose wisely.
