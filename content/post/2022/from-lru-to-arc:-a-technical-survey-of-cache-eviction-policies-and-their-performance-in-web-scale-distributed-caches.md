---
title: "From Lru To Arc: A Technical Survey Of Cache Eviction Policies And Their Performance In Web Scale Distributed Caches"
description: "A comprehensive technical exploration of cache eviction policies, from LRU to ARC, covering their performance in web-scale distributed caches, key concepts, practical implementations, and real-world applications."
date: "2022-10-30"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/from-lru-to-arc-a-technical-survey-of-cache-eviction-policies-and-their-performance-in-web-scale-distributed-caches.png"
coverAlt: "Technical visualization representing cache eviction policies from LRU to ARC"
---

# The Eviction Algorithm is the Cache's Operating System

## A Deep Dive into the Algorithms That Keep Your Distributed Systems Alive

---

## Introduction: When Milliseconds Cost Millions

It is 8:47 PM on a Tuesday. You are the on-call principal engineer for one of the world's largest streaming platforms. A global music icon is about to perform a surprise concert exclusive to your service. The marketing team has been hyping this event for weeks. As the stream goes live, 15 million concurrent viewers attempt to refresh their dashboards, triggering a fetching frenzy for metadata—user avatars, chat history, stream quality profiles, and recommendation carousels.

Your monitoring dashboards, normally placid during quiet hours, begin screaming. The global request rate is climbing 2,000% per second. The database connection pool is spiking dangerously close to its cap, but it is the cache hit ratio that tells the real story. It is dropping. A 5% drop in your global cache hit ratio means 500,000 additional database queries _per second_. Each of those extra queries costs not just milliseconds, but significant CPU cycles on the database tier, which in turn fights for IO bandwidth and replication slots. The SRE team's pagers are going off. The business team is asking if you will survive the next ten minutes.

Now, a celebrity posts a controversial statement during a major sporting event. Within seconds, millions of users refresh their feeds, hammering the backend with requests for the same post, its comments, and related media. Your system survives not because of brute‑force database capacity, but because of a distributed cache—a memory layer spread across thousands of servers that keeps the hottest data instantly accessible. But here's the catch: every cache has a finite budget of RAM. When new data arrives, something must be evicted. The algorithm that decides which key to throw out is not an arcane academic footnote; it is the single most impactful lever you can pull to avoid a meltdown. The wrong policy can turn a 5‑millisecond cache hit into a 200‑millisecond database round‑trip, and at web scale, that latency gap translates directly into lost revenue, frustrated users, and even cascading failures.

Let's put a concrete dollar figure on this. At a major social media platform, every external request generates a fraction of a cent in ad revenue or protects user engagement. A well-publicized study from Amazon found that every 100ms of additional latency costs 1% in sales. Google discovered that an extra 0.5 seconds in search page generation time dropped traffic by 20%. If your platform serves 10 million views per day, with an average revenue per visit of $0.05, a 100ms latency increase caused purely by a poorly chosen eviction policy could cost you $500,000 per day. The cost of a bad algorithm is not hypothetical. It is a concrete line item on your quarterly earnings call. The eviction algorithm is the unsung hero or the silent villain of your entire infrastructure.

The problem of cache eviction is as old as computing itself. From the early days of virtual memory paging in the 1960s to the modern era of distributed key‑value stores spanning continents, engineers have wrestled with a fundamental trade‑off: should the cache favor recently accessed items (recency) or frequently accessed ones (frequency)? This question, deceptively simple on its surface, has spawned an entire subfield of computer science. It intersects with operating systems (page replacement), databases (buffer pool management), web infrastructure (CDNs and reverse proxies), and application architecture (Redis, Memcached, Caffeine).

The classic Least‑Recently‑Used (LRU) policy—evict the item that hasn't been touched in the longest time—is intuitive, lightweight, and works wonderfully under workloads with strong temporal locality. If users access the same photo album, the same set of API endpoints, or the same rows in a database table repeatedly in a short window, LRU shines. It requires minimal state (a doubly linked list and a hash map), is O(1) for every operation, and maps perfectly to the psychological model of "the stuff I haven't touched recently is the stuff I probably don't need anymore."

But web‑scale distributed caches face workloads that are far from textbook. They encounter scanning patterns (e.g., a batch job that streams through a large dataset, polluting the entire cache with one-hit-wonders), shifting popularity (a trending hashtag that explodes for thirty minutes and then fades into irrelevance), and high access skew combined with occasional bursts. LRU suffers catastrophically under all these scenarios. Imagine a cache of size 100 items. A background analytics job runs a scan over 10,000 distinct keys. Each key is accessed exactly once. LRU will admit every single one of these scanned keys into the cache, systematically evicting the 100 "popular" items that were actually being requested by real users. By the time the batch job finishes, the cache is a ghost town of dead keys. The hit ratio plummets to zero for real user traffic until the popular items slowly percolate back into the cache. This is the infamous _scan-resistance_ problem, and it is the single most common cause of production cache meltdowns.

Its cousin, Least‑Frequently‑Used (LFU), fares better against scan resistance by tracking how often an item is accessed. A key that has been touched 100 times is much harder to evict than a key touched once, even if the latter was touched more recently. However, LFU comes with its own fatal flaw: _aging_. If a key was extremely popular two hours ago—say, a viral video about a political debate—but is now irrelevant, its high frequency count keeps it alive in the cache, starving a new popular key that is just beginning its lifecycle. The cache becomes a museum of past popularity. To combat this, LFU implementations must implement complex decay mechanisms, periodic resets, or sliding windows, adding significant complexity and overhead.

This trade-off between recency and frequency creates a technological crux. Do we build a cache that favors the present (Recency) or the past (Frequency)? The answer, as it turns out, is much more nuanced than choosing one over the other. The ideal cache must be _adaptive_. It must recognize when the workload shifts from a steady-state of popular items to a burst of new items. It must be _scan-resistant_ to protect against adversarial or accidental sweeps. It must be _computationally cheap_ to run on every single get/set operation, often millions of times per second. And it must be _scalable_ in a concurrent or distributed context where multiple threads or nodes share the same memory pool.

This article will explore the entire universe of cache eviction policies. We will start with the theoretical optimal (Belady's MIN algorithm) to establish an upper bound on performance. Then, we will descend into the real world: the pragmatism of LRU, the mathematics of LFU, the adaptive brilliance of ARC, the modern elegance of TinyLFU (the engine behind Caffeine), and the latest wave of simple-but-brilliant algorithms like SIEVE and S3-FIFO that are redefining the throughput-horizon of caching. We will examine how Redis and Memcached implement these policies in production, and we will dissect case studies where choosing the wrong algorithm cost companies millions. Finally, we will peer into the future: learned caches, programmable eviction logic via eBPF, and the role of emerging memory technologies like CXL.

By the end of this post, you will not just understand the trade-offs between eviction algorithms—you will be able to look at your own workload telemetry, identify the pathological patterns that are hurting your hit ratio, and prescribe the exact algorithm that will keep your site online when the inevitable surge hits. The eviction algorithm is the operating system of your in-memory data store. It is time to understand how it truly works.

---

## Section 1: The Memory Hierarchy and the Economics of a Miss

Before we can understand _how_ to evict, we must understand _why_ eviction is so critical. It all comes down to the economics of the memory hierarchy.

### The Latency Gap

Modern computing systems exist on a spectrum of latency and capacity. The closer storage is to the CPU, the faster it is, and the more expensive it is per byte. The classic hierarchy looks something like this:

| Level           | Example        | Latency                 | Size      | Cost/GB |
| --------------- | -------------- | ----------------------- | --------- | ------- |
| L1 Cache        | SRAM           | ~1 ns                   | ~32 KB    | ~$1000  |
| L2 Cache        | SRAM           | ~4 ns                   | ~256 KB   | ~$500   |
| L3 Cache        | SRAM           | ~15 ns                  | ~8 MB     | ~$200   |
| Main Memory     | DRAM           | ~100 ns                 | ~64 GB    | ~$10    |
| SSD (NVMe)      | NAND Flash     | ~10,000 ns (10 us)      | ~1 TB     | ~$0.10  |
| HDD             | Magnetic Disk  | ~10,000,000 ns (10 ms)  | ~10 TB    | ~$0.02  |
| Remote Database | Network + Disk | ~10,000,000+ ns (10ms+) | Unlimited | ~$0.10+ |

A cache hit in Redis or Memcached—served directly from the DRAM of the cache server—typically takes between 500 microseconds and 1 millisecond. A cache miss that forces a query against a remote database like PostgreSQL or MySQL might take 10 to 50 milliseconds. That is a _two-order-of-magnitude_ difference. When you multiply that by millions of requests, the aggregate wall-clock time lost to misses becomes a liquidity crisis for your user experience.

### The Working Set

The concept of the "working set," formalized by Peter Denning in 1968, states that any program (or in our case, any workload) has a set of data items it references frequently over a given time window. If this working set fits entirely in the cache, the hit ratio can approach 100%. If the working set exceeds the cache size, the system begins to "thrash"—constantly evicting data that will be needed again, and pulling in data that will be evicted before it is reused.

The role of the eviction algorithm is not just to pick a victim; it is to _keep the working set in the cache_ as perfectly as possible. An optimal algorithm identifies the exact set of keys that constitutes the current working set and refuses to evict them, sacrificing the "free riders" (one-hit-wonders, expired popularity, scans).

### The Cost of Scans and Bursts

A scanning workload is the enemy of an improperly tuned cache. Consider a supermarket inventory system. A report runs every hour that scans through every product ID to generate analytics. If this scan runs against a cache backed by LRU, it can destroy the cache for the actual customer-facing application that is serving product details to shoppers. The scan isn't malicious; it's a legitimate business operation. But its access pattern (a sequential sweep) is the worst possible input for a policy that relies purely on recency.

Similarly, bursty traffic—like the celebrity tweet scenario—creates a sudden influx of new keys. If the cache cannot quickly adapt, it will evict the steady-state working set to make room for the burst, only to be left with a mostly empty cache when the burst fades.

### The Goal: Maximize Hit Ratio Under Constraint

The objective function for a cache eviction policy is simple: maximize the cache hit ratio (or equivalently, minimize the miss ratio) for a given cache size and workload.

`HitRatio = CacheHits / (CacheHits + CacheMisses)`

A 1% improvement in hit ratio at massive scale can represent millions of dollars saved in database infrastructure costs, not to mention the improvement in user-facing latency. This is why engineers have spent decades searching for the perfect eviction algorithm.

---

## Section 2: The Unattainable Ideal—Belady's MIN Algorithm

To evaluate any eviction algorithm, we must compare it against the theoretical optimum. In 1966, Laszlo Belady and colleagues at IBM Research published a paper describing the optimal offline algorithm for page replacement.

**Belady's MIN: "Evict the item that will be used farthest in the future."**

This algorithm is _clairvoyant_. It requires perfect knowledge of the entire future sequence of accesses. While impossible to implement in a real system (unless you have a time machine), it provides the upper bound on cache performance—the best possible hit ratio for any given cache size and access trace.

### How Belady's MIN Works

Given a fixed cache size C and an access trace of keys `k1, k2, k3, ..., kn`, the algorithm works as follows:

1. For each key accessed, check if it is in the cache.
2. If it is a miss, we must make room. For each key currently in the cache, look into the _future_ access trace. The key whose _next_ access is the furthest in the future is the optimal victim.
3. Evict that key and bring in the new one.

### Why It Matters

Belady's MIN gives us a benchmark. If an algorithm achieves a hit ratio of X% on a trace, but Belady's MIN achieves X+10%, there is a 10% gap in potential performance. An algorithm that can close this gap is fundamentally superior.

The practical implication is profound. It tells us that the optimal policy is _neither_ purely recency-based nor purely frequency-based. It is entirely _future-based_. The best we can do in a real system is to approximate the future using the past.

### The Gaps We Cannot Cross

The difficulty of approximating the future defines the challenges of cache design.

- **Shifting workloads:** The past is not always a good predictor of the future. A trending topic that fades breaks the assumption of frequency.
- **Cold start:** When a new key arrives, we have no history. Every algorithm must make a "cold" decision to admit it or not. Belady's MIN knows exactly how important it will be.
- **Periodicity:** Some workloads are highly periodic (e.g., daily cron jobs). A perfect algorithm would learn this period. Most real-world algorithms cannot.

Belady's MIN sets the stage. Every algorithm discussed below is an attempt to approximate this oracle. The best algorithms (TinyLFU, S3-FIFO) get within 1-3% of Belady's MIN on many standard traces. The worst algorithms (naive LRU) can be 20-50% worse.

---

## Section 3: Lineage of LRU—The Hammer and Its Fatal Flaws

Least Recently Used is the default eviction algorithm for good reason. It is intuitive to understand, simple to implement, and performs exceptionally well on workloads with strong temporal locality. If your workload is a classic 80/20 distribution—80% of accesses go to 20% of the keys—LRU is a star.

### The Implementation

The classic LRU implementation uses two data structures:

1. A **hashmap** (dictionary) mapping keys to nodes in a linked list.
2. A **doubly linked list** that maintains the order of access.

```
class LRUCache:
    def get(key):
        if key in cache:
            move_node_to_head(key)
            return value
        return -1

    def set(key, value):
        if cache is full:
            remove_tail_node()  # Evicts LRU item
        add_node_to_head(key, value)
```

This gives O(1) time complexity for both get and set operations. The hashmap provides fast lookup. The linked list provides fast reordering and eviction.

### Where LRU Succeeds

- **Temporal locality:** If you access item A, you are likely to access item A again soon. LRU keeps A at the head.
- **Simplicity:** The code is trivial to write and debug. There is no complex state to manage.
- **Overhead:** Requires only a few pointers per key (prev, next, hashmap entry). Memory overhead is minimal.

### Where LRU Fails Catastrophically

**The Scanning Problem (Pollution):**
This is the most famous failure mode of LRU. Consider a cache of size 100. A batch job scans 10,000 keys sequentially, accessing each key once.

1. The cache starts full of popular keys (A, B, C, …).
2. The scan accesses key 1. Miss. Evicts A. Admits 1.
3. The scan accesses key 2. Miss. Evicts B. Admits 2.
4. ...
5. By the time the scan reaches key 101, it has evicted all 100 popular keys.
6. At this point, the hit ratio for real user traffic drops to 0%.
7. The cache is now full of keys (1 through 100) that will _never_ be accessed again by real users.
8. Real users must now wait for database queries for every request.
9. The cache will slowly recover over many other requests, but the damage is done.

This is not just a theoretical problem. It is the single most common cause of production cache failures. Any background job, analytics pipeline, or migration script that touches keys sequentially can destroy your cache.

**The Dictator Problem (Recency Overrides Frequency):**
LRU has no memory of how many times a key has been accessed. A key accessed 1,000 times yesterday but not for 5 seconds can be evicted for a key accessed 1 time _right now_. The algorithm is a dictator that only sees the last access time. It ignores the lifetime value of an item.

**The Concurrency Problem:**
The doubly linked list is a global structure. In a highly concurrent environment (multi-threaded cache), every get and set operation requires a mutex lock on the list. This makes LRU a significant contention point. High-performance implementations in Java (ConcurrentHashMap + segmented LRU) and Go (sharded LRU) must work hard to mitigate this.

**Cyclic Workloads:**
If a workload accesses a set of keys slightly larger than the cache in a cyclic manner, LRU can degrade to nearly 0% hit rate. This is the "sequential flooding" pattern.

### The Variants: Segmented LRU (SLRU)

To mitigate some of LRU's weaknesses, engineers invented Segmented LRU. This splits the cache into two segments:

- **Probationary Segment (small, ~20%):** New items are placed here. They are on probation.
- **Protected Segment (large, ~80%):** If an item in the probationary segment is accessed again, it is promoted to the protected segment.

This provides some scan resistance. A scanned key is accessed once and placed in the probationary segment. It might be evicted before it can pollute the protected segment. However, if the scan is large enough to fill the probationary segment, it can still overflow and pollute the protected segment. Memcached and the Linux page cache both use variants of segmented LRU.

---

## Section 4: The Frequency Imperative—LFU and Its Burdens

Least Frequently Used takes the opposite approach. Instead of tracking _when_ an item was last accessed, it tracks _how often_ an item has been accessed. The principle is simple: evict the item with the lowest access frequency.

### Perfect LFU

A perfect LFU implementation requires:

- A frequency counter for every key in the cache.
- A priority queue (min-heap) or a sorted data structure to find the lowest frequency key quickly.
- On access: increment the frequency counter. O(log N).
- On eviction: pop the minimum frequency key. O(log N).

**Strengths:**

- **Scan Resistance:** A batch job that accesses each key once will have a frequency of 1 for every scanned key. The popular working set, with frequencies of 100+, is completely safe. Scanning cannot pollute an LFU cache.
- **Popularity Tracking:** Truly popular items stay in the cache as long as they remain popular.

**Weaknesses:**

- **The Aging Problem:** This is the fatal flaw of LFU. A video that was viral two weeks ago still has a frequency of, say, 10 million. A new video that just went viral has a frequency of 10,000. The old video will block the new video, even though the old video is now being accessed once an hour and the new video is being accessed a thousand times a second. The cache becomes a graveyard of stale popularity.
- **Memory Overhead:** Storing a frequency counter (integer) for every key in the cache adds significant overhead. For a cache of 10 million keys, that's 40MB of memory just for counters.
- **Aging Solutions:**
  - _Periodic Reset:_ Every hour, divide all frequencies by 2. This allows new items to compete. But it also throws away useful historical information.
  - _Sliding Window:_ Only count accesses within the last hour. This is expensive to implement perfectly.
  - _Decay on Insert:_ When a new item comes in, if the victim has a frequency higher than the new item, the new item is rejected.

### Approximate LFU (Count-Min Sketch)

Perfect LFU is expensive. To reduce memory and computational overhead, modern implementations use a probabilistic data structure called a **Count-Min Sketch**.

A Count-Min Sketch is a 2D array of counters. It uses multiple hash functions. To increment the frequency of a key, you hash the key with each hash function and increment the corresponding counters. To query the frequency of a key, you hash the key and take the _minimum_ of the counters.

This provides a space-efficient approximation of frequency with a known error bound. Sketch size can be tuned (e.g., 4 hash functions, 1024 columns = 4KB of counters). This is vastly more memory efficient than storing a full integer per key.

TinyLFU, the frequency oracle behind Caffeine, uses a Count-Min Sketch.

### Why LFU Alone is Not Enough

Pure LFU, even with aging, suffers from a "cold start" problem. A new, truly popular item has a low frequency, so it can be evicted quickly. LFU is too slow to react to bursts. It excels at protecting long-term popularity but fails at adapting to new trends. This is why the best algorithms combine frequency _and_ recency.

---

## Section 5: The Adaptive Revolution—ARC, 2Q, and LIRS

The insight from the 1990s and 2000s was that no single static policy could handle all workloads. The cache needed to _learn_ and _adapt_. This led to the development of "adaptive" algorithms.

### ARC (Adaptive Replacement Cache)

Developed by Nimrod Megiddo and Dharmendra S. Modha at IBM Almaden Research, ARC is perhaps the most famous adaptive algorithm. It was patented by IBM and used in their storage systems. It is the default eviction policy for the ZFS filesystem's ARC (Adjustable Replacement Cache).

**The Core Idea:**
ARC maintains four lists:

- **T1 (Recency):** Keys that have been accessed only once recently.
- **T2 (Frequency):** Keys that have been accessed more than once recently.
- **B1 (Ghost Recency):** Keys that were recently evicted from T1.
- **B2 (Ghost Frequency):** Keys that were recently evicted from T2.

The "ghost" lists store only the _keys_ (no values). Their purpose is to act as a memory of what was evicted. The real cache size is the sum of the sizes of T1 and T2.

**How Adaptation Works:**
ARC maintains a tuning parameter `p` that determines the balance between T1 and T2.

- On a cache miss, the algorithm tries to store the new key.
- If the evicted key causes a _ghost hit_ in B1 (meaning we evicted a "recency" item), the algorithm learns that the workload is recency-sensitive. It increases `p`, giving more space to T1.
- If the evicted key causes a _ghost hit_ in B2 (meaning we evicted a "frequency" item), the algorithm learns that the workload is frequency-sensitive. It decreases `p`, giving more space to T2.

**Why it is Brilliant:**
ARC dynamically adjusts to the workload. If a scan comes through, it fills T1, causes many ghosts in B1, but the workload is scanning, so there are no ghost hits. The algorithm learns to shrink T1. ARC is provably scan-resistant.

**The Downsides:**

- **Complexity:** Four lists to manage. The logic for balancing `p` is subtle and can oscillate.
- **Concurrency:** Managing four lists adds significant lock contention.
- **Patent Issues:** IBM's patent prevented widespread adoption in open-source projects for years (though it expired).
- **Memory Overhead:** Ghost lists store keys, which can be a significant memory overhead for keys with long names.

### 2Q (Two Queue)

A simpler alternative to ARC, developed by Johnson and Shasha. It is designed to be easier to implement while still providing good scan resistance.

**The Structure:**

- **A1in (FIFO Queue):** A small queue (e.g., 25% of cache size) that holds newly inserted items. If an item is accessed again while in A1in, it is promoted to Am.
- **A1out (Ghost FIFO):** Stores keys evicted from A1in. If a key is accessed and is found in A1out, it is a "re-access" and is promoted to Am.
- **Am (LRU Queue):** The main cache for frequently accessed items.

**Why it Works:**
2Q gives new items a probationary period in A1in. If a scan comes through, the scanned keys fill A1in and are evicted to A1out (ghosts). They are never promoted to Am. The main cache (Am) is protected.

**The Downsides:**

- **Static Sizing:** The size of A1in is a fixed fraction of the cache. This requires tuning. A workload with a very large scanning window might overflow A1in into Am.
- **Concurrency:** Still requires management of multiple queues.

### LIRS (Low Inter-reference Recency Set)

LIRS, proposed by Song Jiang and Xiaodong Zhang, takes a different theoretical approach. Instead of looking purely at recency (how long ago was the last access), it looks at _inter-reference recency_ (IRR)—how many other distinct items were accessed between two consecutive accesses of the same item.

A low IRR means an item is accessed very frequently relative to other items. A high IRR means it is accessed rarely.

LIRS maintains two sets:

- **LIR (Low IRR) Set:** The "hot" items that don't need to be protected heavily.
- **HIR (High IRR) Set:** The "cold" items.

LIRS is theoretically elegant and provably scan-resistant. It was adopted in some Java-based caching systems.

**The Downsides:**

- **Complexity:** The stack management for LIRS is notoriously complex. The "LIRS stack" has tricky invariants that must be maintained.
- **Implementation Difficulty:** Few developers can implement it correctly from scratch. This limited its adoption despite its excellent theoretical properties.

---

## Section 6: The Modern Monarch—TinyLFU and W-TinyLFU

In the 2010s, caching in the Java ecosystem was dominated by Guava's Cache and EHCache. Both used variants of LRU or segmented LRU. Then Ben Manes released **Caffeine**, a high-performance caching library for Java. Its eviction policy, W-TinyLFU (Window-TinyLFU), quickly became the gold standard.

### The Core Problem TinyLFU Solves

TinyLFU asks a simple question: "Should this new item be admitted to the cache at all?" Instead of only asking "Which item should I evict?", TinyLFF asks "Is this new item even worth caching?" This is an **admission policy** in addition to an eviction policy.

### The TinyLFU Sketch

TinyLFU uses a **Count-Min Sketch** to maintain a frequency histogram of items.

1. **Frequency Estimation:** Every access to a key increments a counter in the sketch.
2. **Reset Mechanism:** To handle aging, the sketch uses a sliding window. When the sketch's sample count (number of total accesses) reaches a threshold (e.g., 10x the cache size), the values of the sketch are halved. This ensures that old popularity decays and new items can compete.

### The "Doorkeeper"

TinyLFU includes a **Bloom Filter** called the "Doorkeeper". This filter tracks whether an item has been seen before. An item that is in the Doorkeeper gets its sketch count incremented. An item that is not in the Doorkeeper is added to it. This allows the sketch to effectively distinguish between "seen once" and "seen many times".

### The Admission Decision

When a new item arrives and the cache is full, TinyLFU compares the frequency estimate of the new item against the frequency estimate of the eviction candidate (the victim chosen by the underlying LRU/queue).

- `If Freq(new) >= Freq(victim)`: Admit the new item, evict the victim.
- `If Freq(new) < Freq(victim)`: Reject the new item (do not evict the victim).

This admission filter is the magic. A batch job scanning keys will bring keys that have a frequency of 1. The victim (a popular working set key) might have a frequency of 100. The new key is rejected. The working set is perfectly protected.

### W-TinyLFU: Adding a Window

Pure TinyLFU is heavily biased towards frequency. New items that will become popular in the future have a low initial frequency and can be rejected. This is the "cold start" problem.

To solve this, Caffeine adds a **small Window Cache** (the "W" in W-TinyLFU). This is a small LRU cache (usually 1% of total memory).

1. All new items are inserted into the Window Cache.
2. If an item in the Window Cache is accessed again, it is moved to the Main Cache.
3. The Main Cache uses TinyLFU for admission control (SlruStack: a Segmented LRU with a protected and probationary segment).

**Why it Works:**

- The Window Cache catches bursts of new popular items. A trending hashtag hits the window, gets re-accessed, and is promoted to the main cache.
- The TinyLFU filter protects the main cache from pollution.
- The Segmented LRU provides good temporal locality for the promoted items.

### Performance

W-TinyLFU achieves near-optimal hit ratios. On standard caching benchmarks (Wikipedia traces, web search traces), Caffeine's W-TinyLFU consistently achieves hit ratios within 1-2% of Belady's MIN. It is also extremely fast (tens of millions of operations per second on modern hardware).

Caffeine is now the de facto standard for Java caches, used by Spring Boot, Hibernate, and countless other frameworks.

---

## Section 7: The Simple Renaissance—SIEVE and S3-FIFO

In the 2020s, a new wave of thinking emerged. The complexity of ARC and LIRS was a burden for high-throughput concurrent systems. The question was asked: "Can we get 90% of the benefit of TinyLFU with much simpler code and higher throughput?"

The answer, surprisingly, is yes. Two algorithms from recent academic papers (SIEVE and S3-FIFO) are redefining the state of the art.

### SIEVE

SIEVE, developed by researchers at Carnegie Mellon University and Emory University, is brilliantly simple. It is designed for the specific workload of web caching where hit ratio is important, but throughput and scalability are paramount.

**The Algorithm:**
SIEVE manages a single linked list and a single "hand" pointer (like the CLOCK algorithm).

1. Every item has a "visited" bit.
2. On access: set the visited bit to 1.
3. On eviction (when space is needed):
   - The hand pointer scans the list.
   - If the item has its visited bit set to 1 (i.e., it was accessed recently), the visited bit is reset to 0, and the hand moves to the next item.
   - If the item has its visited bit set to 0 (i.e., it has not been accessed recently), it is evicted.

**What makes SIEVE special?**

- **Scan Resistance:** A batch job scanning keys will set the visited bit on each key once. It will then scan the cache looking for a victim. The unvisited items (the working set) are eventually evicted, but the scanned items are also evicted almost immediately when the hand wraps back around.
- **Low Overhead:** No frequency sketch, no ghost lists. Just a visited bit and a single pointer.
- **High Throughput:** The single pointer and simple operations make it incredibly fast, especially in concurrent settings. The cache line invalidation is minimal.
- **Hit Ratio:** In their benchmarks, SIEVE achieves hit ratios comparable to TinyLFU and significantly better than LRU, especially on scanning workloads.

SIEVE is already being adopted in production systems (e.g., the Vercel Edge Cache, some CDN implementations).

### S3-FIFO

S3-FIFO (Simple, Scalable, Scan-resistant FIFO) takes a different approach to simplicity. It uses three FIFO queues.

**The Structure:**

- **Small Queue (SQ):** A small FIFO queue (e.g., 10% of cache size).
- **Main Queue (MQ):** The main FIFO queue.
- **Ghost Queue (GQ):** A FIFO queue of eviction history.

**The Algorithm:**

1. **Insertion:** New items are always added to the Small Queue.
2. **Promotion:** If an item in the Small Queue is accessed again, it is "hit" and it is promoted to the tail of the Main Queue.
3. **Eviction from SQ:** When the Small Queue is full, the item at the head is evicted.
   - If that item was "hit" at least once while in SQ, its key is moved to the Ghost Queue, and the item (with value) is moved to the tail of the Main Queue.
   - If that item was _never_ hit while in SQ, it is simply discarded. It was a one-hit-wonder.
4. **Eviction from MQ:** When the Main Queue is full, the item at the head is evicted.
   - Its key is added to the Ghost Queue.
5. **Ghost Queue:** When the Ghost Queue is full, the oldest entry is evicted. If a key is accessed and found in the Ghost Queue, it is treated as a "hit" and promoted back to the Main Queue.

**Why S3-FIFO is Brilliant:**

- **Simplicity:** Three FIFO queues. No sorting, no linked list manipulations, no frequency sketches. FIFO queues can be implemented with a simple circular buffer and an index pointer. This makes them incredibly cache-friendly.
- **Scan Resistance:** The Small Queue acts as a perfect scan filter. A batch job will fill the Small Queue with scanned keys. Each scanned key is accessed once, so it is never promoted. It is evicted from the head of SQ and discarded. The scanned keys die instantly.
- **Concurrency:** FIFO queues are trivial to make lock-free or use very fine-grained locking. S3-FIFO can achieve significantly higher throughput than LRU or LIRS in multi-threaded environments.

**Performance:**
S3-FIFO achieves hit ratios very close to TinyLFU and ARC, often within 1-5%, while offering 2-3x the throughput in highly concurrent settings. It represents a stunning victory of simplicity over complexity.

### The Renaissance Message

The resurrection of simple algorithms (SIEVE, S3-FIFO) teaches a critical lesson: **complexity has a cost**. The best algorithm is not necessarily the one with the highest hit ratio in a single-threaded simulation. It is the one that achieves the best balance of hit ratio, throughput, and concurrency scaling in a real production system. For many modern workloads, S3-FIFO or SIEVE is the right choice.

---

## Section 8: Eviction in the Wild—Redis and Memcached

Understanding the theory is one thing. Understanding how it is applied in the standard tools of our industry is another.

### Redis

Redis offers multiple eviction policies configurable via the `maxmemory-policy` configuration directive:

- `noeviction`: Returns an error on write if memory limit is hit. (Default).
- `allkeys-lru`: Evicts the least recently used key across the entire keyspace.
- `allkeys-lfu`: Evicts the least frequently used key (added in Redis 4.0).
- `volatile-lru`: Evicts the least recently used key among keys with an expire set.
- `volatile-lfu`: Evicts the least frequently used key among keys with an expire set.
- `allkeys-random`: Evicts a random key.
- `volatile-ttl`: Evicts the key with the nearest expire time.

**Redis's LFU Implementation:**
Redis does not use a Count-Min Sketch for LFU. Instead, it uses a probablistic counter called the **Morris Counter**. This counter uses very few bits (e.g., 8 bits per key) to approximate a high dynamic range of frequencies (from 0 to millions). The counter is incremented with a logarithmically decreasing probability.

Redis also has two tuning parameters for LFU:

- `lfu-log-factor`: Controls how quickly the counter saturates for very hot keys.
- `lfu-decay-time`: Controls how quickly the counter decays if the key is not accessed. A value of 0 means no decay. A value of 1 means the counter decays by ~1 every minute.

**Why Redis's LFU Matters:**
For any production Redis cache under heavy user traffic, using `allkeys-lfu` with a reasonable decay time (e.g., `lfu-decay-time 1`) is almost always superior to `allkeys-lru`. It provides vastly superior scan resistance. If a batch job runs a `SCAN` or `KEYS` command, or if your application misbehaves, the LFU cache is far more resilient.

### Memcached

Memcached traditionally used a global LRU. This had well-documented problems with scans. To improve this, Memcached evolved:

- **Slab Automorphism:** Memcached groups items by size into "slabs". Each slab has its own LRU. This prevents one-size type from starving another, but can lead to unbalanced evictions.
- **Segmented LRU (SLRU):** Modern Memcached uses a segmented LRU (often called the "eviction queue") with a probationary and protected segment. This mitigates some scanning issues.
- **LRU Crawler:** A background thread (the LRU crawler) that proactively evicts expired items from the tail of the LRU, preventing the LRU from filling with dead data that can't be evicted until the cache is full.

**The Lesson from Memcached:**
The need for background crawlers and segmented LRUs shows the inherent flaws of pure LRU at scale. Memcached had to add significant complexity to make it work.

### CDN Caches (Varnish, Nginx, Cloudflare)

CDN caches represent a different set of challenges. They often use variants of LRU combined with explicit TTLs. The TTL is the primary eviction driver. The eviction algorithm is a secondary safety net for when the configured TTL exceeds the memory budget.

- **Varnish Cache:** Uses a byzantine LRU with a "TTL" and "grace" mode. It tends to evict large objects first to maximize the number of objects in cache.
- **Cloudflare / Fastly:** Use custom algorithms, often leaning towards SIEVE or heavily modified LRUs that are tuned for their workload of static assets vs. dynamic APIs.

---

## Section 9: The Future of Eviction—Learned Caches and Programmable Logic

The journey of cache eviction is not over. Two major trends are shaping the future.

### Learned Caches (ML for Caching)

The idea is simple: use machine learning to predict the next access time of an item, and evict the item with the furthest predicted access time—directly approximating Belady's MIN.

**How it works:**

1. A model (e.g., a neural network or a linear model) is trained on historical access traces.
2. The model takes a feature vector as input (last access time, frequency, key name entropy, object size, etc.).
3. The model outputs a "distance to next access" or a score.
4. The cache eviction policy uses this score to pick a victim.

**Examples:**

- **CacheSack:** A learned policy that uses a simple ensemble of features to score objects. Claims to outperform LRU and LFU significantly on some traces.
- **Learned Indexes for Caching:** Using a learned model to directly predict if an item will be accessed again, and if not, evict it immediately.

**The Challenges:**

- **Training Cost:** Training a model is expensive and must be done online (e.g., every 30 minutes) as the workload shifts.
- **Inference Latency:** Running a neural network on every cache get/set adds latency. This has to be incredibly fast (microseconds).
- **Cold Start:** The model must quickly adapt to new patterns.
- **Generalization:** A model trained on one workload often fails on another.

**Verdict:** Learned caches are promising for specific, very high-value, stable workloads (e.g., database buffer pools), but they are unlikely to replace TinyLFU or S3-FIFO in the general-purpose web cache space anytime soon.

### Programmable Caches (eBPF, Custom Hooks)

Instead of choosing a fixed algorithm, what if you could write your own eviction logic?

**eBPF (Extended Berkeley Packet Filter)** for Caching:

- Run custom eviction logic in the kernel's cache layer.
- Allows operators to write targeted policies for their specific workload.
- Example: "Evict any key that matches a specific regex and has a frequency below 10."
- Provides visibility into the cache's internal state (e.g., "why was this key evicted?").

**The Promise:**

- Unprecedented flexibility.
- Ability to combat adversarial patterns immediately.
- Better observability.

**The Risk:**

- Increased complexity. A bug in your eBPF eviction hook could crash the entire cache subsystem.
- Need for deep kernel expertise.

### Hybrid Memory Tiers (CXL)

The introduction of CXL (Compute Express Link) allows for memory tiering. A local DRAM cache is the L1, and a slightly slower remote DRAM (accessed over CXL) becomes the L2.

**The New Problem:**
The eviction algorithm must now decide:

1. Evict from local DRAM to remote DRAM?
2. Evict from remote DRAM to disk?

This creates a two-tier eviction problem. An item might be evicted from L1 to L2, and later from L2 to disk. This requires an algorithm that understands the cost of moving data between tiers, not just evicting to oblivion.

---

## Section 10: Conclusion—The Tuning is the Work

We started with a crisis. A celebrity post, a collapsing cache hit ratio, a potential million-dollar outage. We explored the entire landscape of cache eviction. We saw the theoretical optimum (Belady's MIN) that we cannot quite reach. We saw the simplicity of LRU and its fatal flaw (scannability). We saw the power of frequency (LFU) and its burden (aging). We saw the adaptive brilliance of ARC, the modern elegance of TinyLFU, and the new wave of simple, concurrent algorithms like SIEVE and S3-FIFO.

**What should you use today?**

- **Java Ecosystem:** **Caffeine (W-TinyLFU)**. It is the default for a reason. It offers the best balance of hit ratio, throughput, and maturity. Do not use Guava's cache for new projects.

- **Redis:** **`allkeys-lfu`** with a tuned `lfu-decay-time` (usually `1` or `5`). This provides built-in scan resistance. Test your workload with `allkeys-lru` vs `allkeys-lfu` using Redis's built-in `INFO` command to see the hit ratio difference.

- **High-Performance Systems (C++, Rust, Go):** **S3-FIFO** or **SIEVE**. They offer the best throughput and scalability. They are simple enough to implement yourself and will outperform LRU and LFU on real-world workloads. S3-FIFO's three FIFO queues are remarkably powerful.

- **When in doubt:** **Measure**. Measure your hit ratio at the policy level. Profile your access patterns. Are they cyclic? Are they scan-heavy? What is the object size distribution? The answer to "which algorithm should I use" is always "it depends on your workload."

### The Final Lesson

The eviction algorithm is not an academic curiosity. It is the operating system of your data in memory. It decides what lives and what dies. It is the silent guardian of your database, protecting it from the floods of user traffic. Getting it right means handling 10x traffic surges gracefully. Getting it wrong means a full-scale outage, a lost revenue report, and a post-mortem that everyone will read.

The next time you configure a cache, do not just accept the default. Look at the telemetry. Profile the workload. Choose your eviction policy with the same care you choose your database or your programming language. Your latency SLA, your infrastructure costs, and your users' patience all depend on it.

Choose wisely. The eviction algorithm is the CPU of your storage system, and you are the scheduler.
