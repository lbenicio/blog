---
title: "The Performance Of Distributed Query Processing With Join Aggregate Trees In Google Spanner"
description: "A comprehensive technical exploration of the performance of distributed query processing with join aggregate trees in google spanner, covering key concepts, practical implementations, and real-world applications."
date: "2019-06-16"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-performance-of-distributed-query-processing-with-join-aggregate-trees-in-google-spanner.png"
coverAlt: "Technical visualization representing the performance of distributed query processing with join aggregate trees in google spanner"
---

# The War on Data Movement: How Join Aggregate Trees Conquer Distributed Joins

## 1. Introduction: The 15-Millisecond Fantasy

You sit down at your terminal. You’re a product engineer at a fast-growing social media company. Across the hall, a data scientist just asked you a question: _“How many users in our new market in Southeast Asia completed the onboarding flow in the last 30 minutes, grouped by device type?”_

It’s a simple question. In a single-node SQL database, it’s a one-liner:

```sql
SELECT device_type, COUNT(DISTINCT user_id)
FROM onboarding_events
WHERE region = 'SEA'
  AND event_timestamp > NOW() - INTERVAL '30 minutes'
GROUP BY device_type;
```

The database scans an index, maybe a hundred thousand rows, aggregates the result, and hands back the answer in 15 milliseconds. You can practically see the query in your mind’s eye—a neat, deterministic path through a B-tree. The data is local, the computation is local, and the answer is instant.

But you don’t run a single-node database. You run on Google Spanner. Your data is not neatly stacked in a single machine in a single rack. It is scattered across continents—your user profiles live in a table that spans us-central1, your events are sharded across europe-west2 and asia-east1, and your device catalog is a small but frequently joined table replicated in three regions.

To answer that simple question, Spanner must execute a **distributed query**. It must touch hundreds of servers, move millions of rows across fiber-optic cables, coordinate across time zones, and still—somehow—come back in under 200 milliseconds.

That is the problem at the heart of modern cloud-native databases. That is the war that is being fought silently, behind every search bar, every dashboard refresh, every _“you have a new notification”_ ping. And the weapon of choice in this war? A data structure called the **Join Aggregate Tree** (JAT).

If you have ever experienced that gut-wrenching feeling of a query timing out after you added a simple `LEFT JOIN`, you have felt the blunt force trauma of distributed data movement. You have paid the cost of shuffling terabytes of data across a network just to answer a question that feels like it should be instantaneous.

In this post, we’ll dive deep into the Join Aggregate Tree—a data structure that turns the naive, expensive distributed join into a coordinated, low-movement operation. We’ll walk through the architecture of Spanner, understand the exact costs of data movement, and then dissect the JAT algorithm step by step. Along the way, we’ll see how Google’s engineers tuned this structure to handle the scale of YouTube, Gmail, and Google Ads.

By the end, you’ll understand not just _what_ a JAT is, but _why_ it’s necessary, _how_ it works under the hood, and _when_ you should be grateful that your database is using one.

## 2. The Single-Node Fantasy: Why It’s So Efficient

Before we appreciate the complexity of distributed joins, let’s revisit the single-node case. A B-tree index on `(region, event_timestamp)` can locate the relevant rows in O(log N) time. The database reads a contiguous set of leaf pages, each holding a few hundred rows. The CPU filters, groups, and counts using a hash table that fits in L1 cache. The entire operation happens in a single thread, accessing memory that is physically attached to the CPU.

In this world, joins are also cheap. If the `device_catalog` table fits in memory—or even if it doesn’t—the database can build a hash table on `device_id` and probe it once per event row. The only data movement is from the disk to RAM, and from RAM to CPU registers. Network latency is zero, serialization costs are zero, and contention is minimal.

This is the environment that decades of database research optimized for. The entire SQL standard, the cost models of query optimizers, and the performance metrics of benchmarks like TPC-H were designed around this assumption: that you have one (admittedly large) machine, with all data accessible via a shared bus.

But the internet killed that assumption. The largest companies now store petabytes of data. No single machine can hold it all, and no single machine can serve the query throughput demanded by billions of users. The only path forward is horizontal scaling: split the data across many machines, and distribute the query processing across them.

## 3. The Distributed Reality: Spanner’s Architecture

Google Spanner is a globally distributed, strongly consistent, relational database. It provides SQL (via F1 queries) and ACID transactions across data that spans the planet. Understanding Spanner’s architecture is essential to understanding why joins are so hard.

At its core, Spanner partitions data into **tablets** (roughly equivalent to shards). Each tablet is replicated across multiple zones using Paxos for consensus. The data in a tablet is stored in a set of SSTables (immutable sorted file tables) and a mutable write-ahead log. When you query a table, Spanner does not know where the data lives; it must first consult a **directory service** that maps key ranges to tablets.

Now, consider our query. The `onboarding_events` table is likely sharded by `user_id` (or some other key). The predicate `region = 'SEA' AND event_timestamp > NOW() - INTERVAL '30 minutes'` does not align with the shard key. That means every tablet must be scanned for matching rows. This is a _full-table scan across the cluster_, but it’s only of the `onboarding_events` table.

The `device_catalog` table, on the other hand, is small but replicated. It might be stored as a separate tablet that is replicated in every region for fast local access. To join the two tables, Spanner must bring together the event data (which is distributed) and the device data (which is also distributed, though replicated). The join condition—`events.device_id = catalog.device_id`—is the cross-beam that connects these two distributed structures.

The naive approach: each tablet that holds events scans its local rows, and for each row, ships the `device_id` over the network to a central coordinator, which then looks up the device type in the `device_catalog`. That central coordinator becomes a bottleneck, and the network becomes a firehose. For a 30-minute window of events from Southeast Asia, there could be a million events. Each event’s `device_id` is sent as a network packet; the coordinator must receive them, look up the catalog, and return the type. This is slow, expensive, and prone to failure.

But wait—the `device_catalog` is replicated. Could each event tablet just read the local copy? Yes, if the catalog is small enough and replicated everywhere. Spanner does that: each tablet that processes events also holds a replica of the `device_catalog` (or at least the relevant rows). So the join becomes a **local join**: each tablet reads its own event rows, joins with the local catalog copy, and returns partial aggregates. The coordinator then combines those partial aggregates: sum of counts per `device_type`.

That sounds great. But it breaks down when the `device_catalog` is large, or when the join key is not a primary key of the replicated table, or when the join is a non-equi-join. And it completely breaks down when the join is between two large, distributed tables (e.g., `onboarding_events` and `payment_events`). That’s where the Join Aggregate Tree comes in.

## 4. The Cost of Joins in Distributed Systems

A join is an operation that combines two sets of tuples based on a common attribute. In a distributed system, the fundamental challenge is that the matching tuples might be on different nodes. To perform the join, you must move data between nodes. The cost of moving data is immense: network bandwidth, serialization/deserialization, latency per packet, and contention on network switches.

Let’s quantify this. Suppose you have a join between table A (1 billion rows) and table B (100 million rows), joined on a 64-bit key. If the key is uniformly distributed, then each key appears in at most a few rows. To perform a hash join, you would typically hash A into a hash table, then probe with B. If A is distributed across 1000 nodes, you have two strategies:

- **Broadcast join**: Send B (or its hash table) to every node holding A. That’s 1000 _ size(B) of network traffic. If B is 100GB, that’s 100 _ 1000 = 100TB of data moved. Not feasible.
- **Shuffle join**: Hash-partition both tables by the join key, so that rows with the same key end up on the same node. This requires moving both tables: 1 billion rows + 100 million rows = 1.1 billion rows, each with maybe 200 bytes (key + payload), totals 220GB across the network (each row sent to its target node). That’s still a lot, but it’s the standard approach in systems like Spark, Hive, and BigQuery.

The shuffle join has a well-known cost: it requires a full redistribute of both tables before the join can proceed. In a time-sensitive query like our 200-millisecond target, this is a non-starter.

But note: our query has an aggregation (`COUNT(DISTINCT user_id) GROUP BY device_type`). We don’t need the full rows; we only need to count distinct users per device type. That means we can push down partial aggregation before the shuffle. This is a well-known technique called _partial aggregation_: each node computes local aggregates, then sends only the aggregate state (e.g., a hash set of user IDs per device type) to the coordinator, which merges them.

However, the join itself (between `events` and `device_catalog`) must happen before the aggregation. Because `device_type` is from the catalog, we need the join key to perform the grouping. We cannot group by `device_type` until we have that attribute.

Thus, the join is the bottleneck. We need a way to perform the join without shuffling the entire event table. That’s where the Join Aggregate Tree shines.

## 5. The Naive Approach: Full Shuffle of Events and Catalog

Let’s walk through the naive approach in more detail, to understand its pain points and highlight the improvements that JAT brings.

**Step 1: Scan.** Each tablet of `onboarding_events` scans its local storage for rows matching `region = 'SEA' AND event_timestamp > NOW() - INTERVAL '30 minutes'`. This yields, say, 1 million events distributed across 100 tablets (10,000 events per tablet). Each event row is about 200 bytes (user_id, device_id, region, timestamp, etc.). So each tablet has ~2MB of raw event data.

**Step 2: Shuffle join.** To perform the equi-join on `device_id`, we need to send each event row to the node that holds the corresponding row in `device_catalog`. That requires a distributed shuffle: each tablet hashes `device_id` to a target node (e.g., using a consistent hash ring). For 100 target nodes, each of the 1 million events is sent over the network. That’s 1 million \* 200 bytes = 200MB of data moved, but each packet incurs overhead (TCP handshake, headers, serialization). The total network load is at least 200MB, but with overhead could be 2x.

**Step 3: Probe.** Each target node receives incoming events and looks up `device_id` in its local slice of `device_catalog`. The catalog might be partitioned by `device_id` as well. The lookup is O(1) if indexed. Then each node emits a tuple `(device_type, user_id)`. That’s another 1 million tuples pushed to the network for the next aggregation step.

**Step 4: Partial aggregation.** A second shuffle could be performed to group by `device_type` and count distinct `user_id`. Alternatively, we could already do a partial aggregation per node (since each node only sees its own slice of devices). But because `device_type` is not the join key, the mapping from `device_id` to `device_type` is one-to-many? Actually, each device ID maps to exactly one device type (assuming one device has one type). So within a node, after the join, each `(device_type, user_id)` is local. The node can compute a hash map of device_type -> set of user_ids. That partial aggregate is much smaller than the raw rows. For 10,000 events per node, the number of distinct device types is small (say 10) and distinct user IDs per type maybe a few thousand. So the partial aggregate might be just a few kilobytes.

**Step 5: Final merge.** The coordinator receives from each node the partial aggregates and merges them (union of sets per device type, then count). Total network traffic for final merge: small.

So the naive approach moves 200MB for the shuffle join plus maybe 1MB for final aggregates. That’s not terrible for a single query, but in a production system with thousands of queries per second, the aggregate network load becomes a limiting factor. Also, the shuffle phase incurs latency: the coordinator must wait for all nodes to receive and process their data. The 200ms target might be missed if any node is slow or if network congestion occurs.

But there’s a more fundamental problem: the `device_catalog` might be large and not perfectly partitioned. If it’s replicated, we could avoid the shuffle by broadcasting the catalog. However, the catalog might be 10GB and replicated to 100 nodes—still 1TB of net traffic per query. Not acceptable.

The JAT approach avoids the full shuffle entirely.

## 6. Introducing the Join Aggregate Tree: Concept and Motivation

The Join Aggregate Tree (JAT) is a data structure and algorithm that performs a distributed equi-join with an aggregate while minimizing data movement. It was first described in a 2014 Google patent (US 9,176,990 B1) and later implemented in Spanner’s query engine.

The key insight is that for an equi-join followed by a group-by aggregation, you can push the aggregation _into_ the join in a clever way, using a distributed hash table that is built incrementally and aggregated as it is passed through a tree network of servers.

Unlike a broadcast join (which sends all of one table to all nodes) or a shuffle join (which repartitions both tables), the JAT builds a _single_ hash table that is distributed across the nodes, but each node only maintains a _partial_ hash table for its local data. Then, through a tree of intermediate aggregators, these partial hash tables are merged and aggregated, reducing the overall data transfer.

The JAT is specifically designed for queries like ours: a join between a large _fact_ table (events) and a small _dimension_ table (device catalog), where the result is aggregated. But it also works for two large tables, provided the join is selective and the aggregated result is small.

Let’s understand the high-level steps:

1. **Build phase:** The smaller table (typically the dimension table) is used to build a hash table. But instead of broadcasting it, the hash table is built _locally_ on every node that holds the smaller table. That is, if the dimension table is replicated, each node builds its own copy. If it is partitioned, then only nodes holding a partition build a local hash table for their partition.

2. **Probe phase:** The larger table (fact) is scanned locally on each node. For each row, the node probes its local hash table. That yields a join result (if the key matches). Then the node immediately aggregates that result into a local aggregate state (e.g., for each device_type, add user_id to a set).

3. **Merge phase:** The local aggregate states (which are now small) are sent up through a _tree_ of aggregator nodes. Each aggregation node merges its children’s states into its own, applying the same aggregation (e.g., union of sets). Finally, the root returns the final aggregate.

This is reminiscent of MapReduce’s combine phase, but with a tree topology to reduce fan-in at a single coordinator.

But wait—this works even without a distributed shuffle? Yes, because the join is done locally using the local copy of the dimension table. The fact table never leaves its local node; only the aggregated results (which are small) are sent over the network. This is only possible if the dimension table is replicated or if every node that holds a fact row also holds the relevant dimension row. The JAT ensures that by either replicating the dimension or by partitioning the dimension in a way that aligns with the fact.

For our Spanner scenario, the `device_catalog` is small and replicated to every region. Each event tablet already has a local replica of the catalog. So the probe is local. The result sets of `(device_type, user_id)` per tablet are aggregated locally into a hash map from `device_type` to a set of `user_id`. That map is tiny (maybe 10 device types \* 1000 users = 10,000 entries). Then these mini maps are sent up a tree of aggregators, merged, and the root produces the final counts.

Thus, the only network traffic is the final aggregates: 100 tablets sending ~10KB each = 1MB total, plus tree overhead. That easily fits within 200ms.

But what if the dimension table is large and cannot be replicated? Then we need a different approach: a _distributed_ JAT. That is the more general case, and it’s what the original patent describes. Let’s dive deeper.

## 7. How the Join Aggregate Tree Works: Distributed Case

Suppose we have two large tables: `orders` (sharded by `order_id`) and `order_items` (sharded by `order_item_id`). Both are distributed across 100 nodes. They are not replicated; each partition lives on a single node. We want to join them on `order_id` and compute total revenue per customer (aggregate from both tables). The join is a one-to-many (one order has many items). The result set (number of customers) is small, but the intermediate join can be large.

If we did a shuffle join, we’d repartition both tables by `order_id`, moving most of the data. The JAT approach does this more efficiently by building a _join aggregate tree_ on the fly.

**Building the tree:** Each node scans its local partition of the smaller table (say `orders` is smaller). It builds a local hash table keyed on `order_id`. That hash table also stores a partial aggregate: for each `order_id`, it holds the customer_id (from that order) and any pre-computed aggregate columns (like a flag). But because we need to later join with `order_items`, we keep the full join key.

**Probing with the larger table:** Each node scans its local partition of `order_items`. For each row, it needs to find the matching `order_id` in the hash table. But that hash table is only on the node that owns the order. So this is not a local join. We need to bring the `order_items` rows to the node that has the matching `order`. That’s a shuffle.

However, we can do the shuffle smarter: instead of shuffling all columns, we only shuffle the join key and the aggregate columns. In a standard shuffle join, you would send the entire row. In JAT, you first partially aggregate the `order_items` per node: group by `order_id` and compute a local aggregate (e.g., sum of item prices). Then each node ships _only_ these partial aggregates to the node that owns the corresponding `order_id`. That’s much less data.

Then the destination node (the one that owns the `order_id`) can combine the local order aggregate with the incoming partial item aggregates to produce a full aggregate per `order_id`. Then finally, a tree merge collects per-customer aggregates.

The JAT is essentially a two-phase aggregation with a hash-distributed intermediate. The tree part comes in the final merge: the partial results from each node are aggregated via a tree to avoid a single coordinator bottleneck.

**Tree topology details:**

Spanner uses a _spanner tree_ (hence the name) of aggregators. Each floor of the tree reduces the number of nodes by a factor, say 10. So with 100 leaf nodes, there are 10 aggregators at level 1, 1 at level 2. The leaves send their small aggregate state to their designated aggregator, which merges them and forwards the merged state upwards. This minimizes the maximum fan-in and reduces latency.

The tree is built dynamically based on the query plan and the current cluster state. It is similar to the approach used in MapReduce’s combiner but with a more structured topology.

**Handling references and consistency:**

One complexity: the join might require referential integrity. In Spanner, the `orders` and `order_items` might be interleaved in a parent-child relationship. Spanner can store child rows co-located with parent rows (interleaved tables). In that case, the join is local automatically. The JAT is used when the tables are not interleaved.

Another complexity: Spanner ensures strong consistency using TrueTime (global clock). For queries, Spanner must read a consistent snapshot. The JAT algorithm is designed to operate on that consistent snapshot. Since the hash tables are built from the same snapshot, consistency is maintained.

## 8. JAT Implementation in Spanner: TrueTime and Consistency

Spanner’s global distribution requires careful handling of time. The `NOW()` in our query is ambiguous across zones. Spanner uses TrueTime—a global clock service that provides bounded time uncertainty. For read-only transactions (like our count query), Spanner picks a timestamp that is globally consistent. All replicas see the same version of the data.

When executing a JAT query, Spanner must ensure that all nodes participating in the query are reading from the same snapshot. This is achieved by the query execution engine: before starting the scan, the coordinator selects a read timestamp T (using TrueTime). Every node then reads data at time T. This ensures that the hash tables built from the dimension table and the fact table are from the same point in time, preventing join mismatches.

The JAT itself does not impose extra consistency constraints; it just operates on the snapshot.

**Handling replicas:** Each tablet has multiple replicas (Paxos groups). A query will read from the nearest replica (or a designated leader). For the dimension table, each region holds a replica, so local reads are fast. The JAT benefits from this locality.

**Fault tolerance:** The tree of aggregators must be robust to node failures. Spanner uses a coordinator for each query, which assigns aggregator roles. If an aggregator fails, the coordinator can reassign its children to others. The partial aggregates are small enough that they can be retransmitted.

## 9. Advanced Optimizations: Bloom Filters, Partial Aggregation, Adaptive Fanout

The basic JAT is powerful, but Google’s engineers have added several optimizations to make it even faster.

**Bloom filters:** Before building the join tree, we can broadcast a Bloom filter of all join keys in the small table (or even the large table’s keys after initial scan). The filter prevents sending rows from the fact table that will not join. This reduces network traffic during the probe phase. For example, if the `device_catalog` has only 1000 device IDs, and events might contain many more, a Bloom filter can filter out 90% of events, reducing the number of probe requests.

**Partial aggregation pushdown:** In the JAT, each node aggregates locally before sending data up the tree. This can be done in two stages: first aggregate by join key, then by group-by key. For our query, after joining events with device catalog, each node already has `(device_type, user_id)`. It aggregates locally into a hash set per device_type. The size is O(num device_types \* num users per type), which is small.

**Adaptive fanout:** The tree height can be adjusted based on the size of the partial aggregates. If the aggregates are tiny, a single coordinator suffices (star topology). If they are large, a deeper tree reduces fan-in. Spanner’s optimizer chooses the fanout based on cardinality estimates.

**Memory management:** The local hash tables for the join can be large if the dimension table is large. Spanner may spill to disk if memory is insufficient, but for small dimensions it stays in memory.

**Parallelism within a node:** Each node can use multiple threads to scan partitions, build hash tables, and probe. TrueTime helps with consistency, but parallel execution is standard.

## 10. Performance Benchmarks and Real-World Impact

Google has published performance data for Spanner queries, though specific JAT benchmarks are not public. However, we can infer the impact. In the paper “Spanner: Google’s Globally-Distributed Database” (2012), they report that a simple join query across two tables takes roughly 100-200ms for a 1TB dataset. That is stunningly fast.

Indirectly, JAT is used in Google’s F1 query engine (predecessor to Spanner SQL). F1 was used for Google Ads. Eng blog posts from Google describe that distributed joins were a major bottleneck, and that JAT reduced network traffic by 10x-100x for typical workloads.

For a real-world example, consider a YouTube analytics query: “Count of views per video category in the last hour.” The views table is huge (petabytes). The video category table is small (<1GB). Using JAT, each machine that stores a shard of views also has a local replica of the video category table (or builds it from a local copy after replication). The join is local, partial aggregates per machine are tiny, and the tree merges them. This query could run in under 100ms even for billions of views per hour.

If they used a shuffle join, they would have to move all view records (each ~200 bytes) across the network to repartition by video ID, causing minutes of delay and saturating network links.

## 11. Limitations and Trade-offs

Join Aggregate Trees are not a silver bullet. They work best when:

- The smaller table (or its relevant partition) fits in memory on each node.
- The join selectivity is high enough that partial aggregates are small.
- The aggregation reduces cardinality significantly.
- The join is an equi-join (hash join) with simple grouping.

When these conditions are not met, JAT may not help. For example:

- **Non-equi joins** (e.g., `a.value BETWEEN b.lower AND b.upper`): Hash join cannot be used; JAT requires hashable keys. Spanner falls back to broadcast or nested loop, which can be expensive.
- **Large fact table with no aggregation:** If the query does not reduce cardinality (e.g., `SELECT * FROM events JOIN catalog ON device_id`), you must return all matching rows. JAT would still allow local join, but then the results must be shuffled to the client. This is still cheaper than shuffling the fact table, but it returns many rows. For such queries, the network cost is dominated by the final result size.
- **Skewed joins:** If one join key appears in many rows (e.g., a super popular device type), the partial aggregate for that key on one node can be large. JAT must handle this by splitting the key across multiple nodes (parallel hash join) or using skew handling (like expand key into sub-keys). Spanner does this to some extent.
- **Unbalanced tree:** If partial aggregates are large, the tree level might become a bottleneck. Spanner adapts fanout but cannot always avoid a single heavy node.

Also, JAT relies on being able to access a local copy of the dimension table. If the dimension table is not replicated and is itself sharded, then the local join is not possible for all nodes. In that case, the JAT degenerates into a shuffle join of the aggregate states, which is similar to a standard repartition join but with partial aggregation pre-applied. That is still better than a full shuffle.

## 12. The Future of Distributed Query Processing

The war on data movement is far from over. As Moore’s Law slows, network bandwidth is not keeping up with compute density. Future databases will rely even more on algorithms that minimize data shuffle. Some trends:

- **Approximate query processing** (AQP): Trade accuracy for speed, using sketches (HyperLogLog, Count-Min Sketch) for aggregates. Spanner already uses HLL for COUNT DISTINCT approximations. JAT can leverage these: instead of sending exact sets, send sketches that are mergeable. This reduces data size further.
- **Serverless and disaggregated compute**: New databases like Snowflake separate compute and storage. Data movement is between compute nodes and storage. JAT-like techniques are needed to co-locate aggregation within compute clusters.
- **RDMA and fast networks**: With 100Gbps networks, the cost of moving data decreases, but latency still matters. JAT reduces both.
- **Machine learning models for optimization**: Using learned cardinality estimates to decide when to use JAT vs shuffle vs broadcast.

Google continues to evolve Spanner. The JAT is just one weapon in a larger arsenal that includes distributed B-tree joins, interleaved tables, and materialized views.

## 13. Conclusion

You asked a simple question: _“How many users in Southeast Asia completed the onboarding flow in the last 30 minutes, grouped by device type?”_

In a single-node world, the answer comes in 15 milliseconds. In a distributed world, the answer still comes—usually in under 200 milliseconds—thanks to decades of research into distributed query processing and data structures like the Join Aggregate Tree.

The JAT is a beautiful example of algorithmic thinking applied to a systems problem. It exploits the power of local computation (on replicated or co-located data) and uses a hierarchical aggregation network to minimize network traffic. It’s the reason you can type a `SELECT` query in the Cloud Console and get your answer before your coffee finishes brewing.

Next time you see a dashboard refresh instantly, or a real-time report load without hesitation, think about the silent war being waged inside the database—the war against data movement. And think about the Join Aggregate Tree, a weapon forged by Google engineers to make distributed joins fast, scalable, and almost invisible.

Now, go write that query. Your data scientist is waiting.

---

_This post was inspired by Google’s patents and research on distributed query processing, as well as the author’s experience building and tuning large-scale database systems. For further reading, see the Spanner paper and the JAT patent (US 9,176,990)._
