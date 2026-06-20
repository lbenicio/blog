---
title: "A Deep Dive Into Corfu: A Distributed Shared Log With Object Storage And Multi Stripe Techniques"
description: "A comprehensive technical exploration of a deep dive into corfu: a distributed shared log with object storage and multi stripe techniques, covering key concepts, practical implementations, and real-world applications."
date: "2019-03-09"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/a-deep-dive-into-corfu-a-distributed-shared-log-with-object-storage-and-multi-stripe-techniques.png"
coverAlt: "Technical visualization representing a deep dive into corfu: a distributed shared log with object storage and multi stripe techniques"
---

# A Deep Dive Into Corfu: A Distributed Shared Log With Object Storage And Multi‑Stripe Techniques

Imagine you’re building a system that must process millions of events per second while guaranteeing that every event is seen by all consumers in exactly the same total order. You need to replicate state across multiple geographically distant data centers, and you must be able to recover from any single failure without losing a single record. Furthermore, your storage infrastructure is not a custom hardware cluster but a commodity object store like Amazon S3. This sounds like an impossible wishlist—unless you know about **Corfu**.

Distributed logs are the backbone of modern infrastructure. From Apache Kafka powering real-time data pipelines to Apache BookKeeper serving as the commit log for Apache Pulsar, the concept of an append-only, totally ordered sequence of records underpins replication, concurrency control, state machine replication, and event sourcing. Yet achieving a truly consistent, scalable, and fault-tolerant distributed shared log at cloud scale remains one of the hardest problems in distributed systems. Most systems sacrifice either throughput, strict ordering, or the ability to operate efficiently on cheap, elastic object storage. **Corfu**, a distributed shared log developed at VMware Research, takes a radically different approach. It combines a novel **multi‑stripe** layout with **object storage** to deliver linearizable appends, high throughput, and strong consistency—without relying on a centralized sequencer or expensive replicated state machines.

But why should you care? If you’ve ever struggled with the trade‑offs of leader‑based replication, worried about the cost of maintaining a quorum of powerful SSDs, or wished that your event‑sourcing platform could elastically scale storage without re‑shuffling partitions, Corfu’s ideas offer a fresh perspective. They demonstrate that you can build a log that is both fast and durable by treating object storage as a first‑class citizen, not a secondary tier. In this deep dive, we’ll explore Corfu’s architecture, its novel multi‑stripe technique, the role of a centralized sequencer, how reads and writes work under the hood, and how it compares to other distributed log systems. We’ll also walk through concrete examples, discuss trade‑offs, and consider real-world deployment scenarios. By the end, you’ll understand why Corfu is a hidden gem in distributed systems research and how its principles can inspire your next infrastructure design.

---

## 1. The Problem: Distributed Logs at Cloud Scale

### 1.1 What Is a Distributed Shared Log?

A distributed shared log is an append‑only, totally ordered sequence of records that is replicated across multiple machines. Every record has a unique, monotonically increasing index (often called a log position or sequence number). Producers append records to the tail, and consumers read records from any position. The guarantee of total order means that if record A is appended before record B, then every consumer sees A before B. This simple abstraction is astonishingly powerful:

- **State machine replication**: All replicas apply commands in the same order, ensuring deterministic state.
- **Event sourcing**: Applications store a sequence of events, not current state.
- **Database replication**: Change‑data‑capture (CDC) streams are essentially logs.
- **Consensus protocols**: Paxos and Raft use logs to track agreed‑upon proposals.

The challenge is to implement this abstraction at cloud scale: millions of appends per second, petabytes of storage, and strong consistency across failures. Most systems fall into two camps.

### 1.2 Leader‑Based Logs (e.g., Kafka, BookKeeper)

In leader‑based replication, one node (the leader) accepts all appends, assigns positions, and replicates to followers. This design is simple to reason about, but it has well‑known limitations:

- **Throughput bottleneck**: The leader’s network and disk I/O cap the write throughput.
- **Costly storage**: Leaders (and often followers) require fast SSDs to achieve low latency.
- **Scale‑out complexity**: Adding more brokers typically means re‑partitioning the log, which is expensive.
- **Failover overhead**: On leader failure, a new leader must be elected and catch up, delaying writes.

While Kafka mitigates some of these with multiple partitions (each partition has its own leader), total order across partitions is lost. To achieve global total order, you’d need a single partition, which brings back the bottleneck.

### 1.3 Quorum‑Based Logs (e.g., Raft, Paxos‑based logs)

Protocols like Raft and Multi‑Paxos allow a set of replicas to agree on an ordered sequence of entries using a quorum of nodes. They avoid a single leader bottleneck by allowing any node to propose (though typically there is a leader). However:

- **Write amplification**: A single append requires a majority of replicas to persist the entry, often requiring multiple network round trips.
- **Storage cost**: All replicas store the full log, or at least a prefix. With fast SSDs on every replica, cost grows linearly with replication factor.
- **Scalability tension**: Adding more replicas increases fault tolerance but also increases the quorum size, slowing writes.

### 1.4 The Object Storage Opportunity

Object stores like Amazon S3, Google Cloud Storage, and Azure Blob Storage offer nearly unlimited capacity, high durability (11‑nines), and low cost per gigabyte. They are the backbone of modern data lakes. Yet they are rarely used as the primary store for distributed logs because of their high latency (tens to hundreds of milliseconds per operation) and lack of atomic multi‑block writes. Most log systems assume fast local disk (NVMe SSDs) or at least network‑attached block storage (EBS). Can we design a distributed log that treats object storage not as a cold archive but as the primary, append‑only store? Corfu answers with a resounding **yes**.

---

## 2. Corfu’s Core Idea: Object Storage as a First‑Class Citizen

Corfu’s designers asked: “What if we could build a log where each record is stored as a separate object in an object store? Then we can scale storage horizontally by adding more objects, and we get high durability ‘for free’ from the underlying store.” But naïve implementation fails: writing one object per append would be far too slow (object stores have high per‑request overhead). The key insight is **batching** multiple logical appends into a single large object, which is then written to the object store. This object becomes a **unit of storage** that can hold hundreds or thousands of log entries.

But that introduces a new problem: how do we know which object contains which log positions? And how do we ensure that appends are linearizable—i.e., each append appears to happen atomically at a single point in time? Corfu solves this with two novel components:

1. **A centralized sequencer** that hands out strictly increasing, gap‑free tokens.
2. **A multi‑stripe layout** that distributes objects across multiple “stripes” to improve throughput and reduce tail latency.

Let’s explore each component in detail.

---

## 3. The Centralized Sequencer: Lightweight but Crucial

At the heart of Corfu is a simple but powerful service: the **sequencer**. The sequencer maintains a single 64‑bit counter. When a client wants to append a batch of records, it contacts the sequencer and asks for a range of log positions (tokens). The sequencer returns the next N available positions, for example [1000, 1001, …, 1000+N-1], and increments its counter by N. This guarantees that **no two clients ever get overlapping tokens**, and that tokens are assigned in monotonically increasing order. The sequencer is stateless except for its in‑memory counter; it does not store the records themselves.

### 3.1 Why a Sequencer Works Despite Being Centralized?

You might worry: “Isn’t a centralized sequencer a single point of failure and a throughput bottleneck?” In Corfu, the sequencer is designed to be extremely lightweight:

- It does **no I/O**. It only increments a counter and returns a range. This is a pure CPU operation.
- It can be replicated using a fault‑tolerant consensus protocol (e.g., Raft) for high availability, but its state is tiny (a single integer), so recovery is fast.
- The sequencer’s throughput is bounded only by network and CPU. With modern hardware, a single sequencer can hand out billions of tokens per second using efficient batching and zero‑copy networking.

In practice, Corfu’s sequencer can be made highly available with a hot standby, and failover involves simply replaying the token counter from the last persisted value (which can be checkpointed periodically). Because the sequencer does not touch storage, its latency is in the microsecond range—far less than the object store latency.

### 3.2 Gaps and Fills

The sequencer guarantees that tokens are issued without gaps. However, a client that receives a set of tokens might fail before writing the corresponding records. This would create a _hole_ in the log: a position that is assigned but never filled. Corfu handles holes by allowing later clients to “fill” them: a client writes a special tombstone record that marks the position as empty. The log is considered complete when every position up to the current tail has either a data record or a tombstone. The sequencer also provides a **trim** operation to advance the low‑water mark, allowing garbage collection of old objects.

---

## 4. Multi‑Stripe Layout: The Secret Sauce

If we stored all log entries sequentially in a single chain of objects, we would still face a bottleneck: each object store write has high latency, and a single stream of writes would be limited to the throughput of one S3 bucket prefix (roughly 5,500 requests per second for PUT operations). Corfu solves this by using **multiple stripes**.

### 4.1 How Striping Works

Corfu divides the logical log into a fixed number of **stripes**, say K=32. Each stripe corresponds to a distinct “unit” (like a prefix in S3 or a different bucket). The logical log positions are mapped to stripes using a simple modulo operation:

```plaintext
stripe_id = log_position % K
```

For example, with K=32, position 0 goes to stripe 0, position 32 to stripe 0 again, position 1 to stripe 1, etc. Each stripe maintains its own sequence of **objects** (called **log units** in Corfu). Each object contains a contiguous range of positions that belong to that stripe. For instance, stripe 0 might have an object covering positions 0 to 31, then another object covering 32 to 63, etc.

### 4.2 Why Stripes Improve Throughput

When a client appends a batch of records, it first gets a token range from the sequencer. Then it splits that range across stripes: each record goes to one stripe (based on modulo). The client bundles multiple records for the same stripe into a single **write batch**. Because different stripes are independent, the client can issue parallel writes to multiple stripes (and thus to multiple S3 prefixes) simultaneously. This multiplies the effective write throughput:

- With K stripes, the client can perform up to K concurrent object‑store writes (assuming it has enough records in the batch).
- Object stores like S3 have per‑prefix limits, but with K distinct prefixes, you effectively get K times the bandwidth.
- Reads also benefit: multiple clients can read from different stripes in parallel without contention.

The number of stripes K is a configuration parameter. A higher K increases parallelism but also increases metadata overhead (more objects to manage). Corfu typically uses K = 32 or 64, which is enough to saturate a typical client’s network bandwidth.

### 4.3 Stripes Reduce Tail Latency

Object store latencies are variable—a single PUT can take 10 ms while another takes 200 ms due to network jitter or server load. In a single‑stream log, the slowest write would block the entire pipeline. With stripes, the client issues many concurrent writes; a slow write to one stripe does not block writes to other stripes. The client can continue to append new tokens while waiting for the slow stripe, as long as it doesn’t need those particular positions to be filled. But careful: because positions are interleaved across stripes, a later position might belong to a faster stripe and be written before an earlier position in a slower stripe. Yet the log still maintains total order because the **token assignment** is sequential—the positions themselves define the order, not the write completion time. A reader that sees a gap (a missing position) must wait until that position is filled (or a tombstone appears). This is exactly the same situation as any distributed log with out‑of‑order writes (Kafka’s segments are also written out of order, but the order is defined by offsets).

---

## 5. Read and Write Protocols: A Walkthrough

### 5.1 Writing a Batch of Records

Let’s walk through a concrete example. Suppose a client wants to append three records (A, B, C). The client sends a request to the sequencer for three tokens and receives back positions [42, 43, 44] (the sequencer atomically increments its counter from 42 to 45). Now the client decides on a batch size (say, records per object = 100). Since it only has 3 records, it will write them into a single object per stripe? No—each record belongs to a stripe based on modulo K. Assume K=4:

- position 42 → stripe 42 % 4 = 2
- position 43 → stripe 3
- position 44 → stripe 0

Each stripe will get at most one record (for this tiny batch). For each stripe that has at least one record, the client creates a **filler object** containing the record(s) for that stripe. The object is named after the stripe and the highest position it covers (or a unique ID). The client writes these objects to S3 (or the corresponding object store) in parallel. After the writes complete, the log is considered filled for those positions.

But what if the client crashes before writing all three objects? Positions 42, 43, 44 are now allocated but not yet filled. A subsequent reader or another client will see a hole. Corfu deals with holes through a **fill‑in** mechanism: any client (or the system’s garbage collector) can detect a hole and write a tombstone record. The sequencer can be queried to find the highest filled position; a gap between the lowest unfilled position and the highest filled one indicates a hole.

### 5.2 Reading from the Log

To read the entire log from the beginning (position 0), a reader must reconstruct the sequence from objects spread across all stripes. The reader can:

1. **Fetch the metadata about objects** for each stripe. Corfu maintains a **metadata service** (e.g., a key‑value store like ZooKeeper or etcd) that records the list of objects per stripe and their coverage ranges.
2. **Read objects in parallel** from each stripe. Because objects are stored in S3, reads can be issued concurrently.
3. **Reassemble positions in order** by merging the objects from all stripes based on the positions they contain.

This process is essentially a **merge‑join** over sorted streams of positions. Since each stripe’s objects are internally sorted by position (by construction), the merge is straightforward. The reader can also read a specific range of positions by computing which stripes and objects cover that range, and reading only those objects.

### 5.3 Handling Out‑of‑Order Writes

Consider a scenario: Client 1 gets tokens [0,1,2]; Client 2 gets tokens [3,4,5]. Both write concurrently. Suppose Client 2 finishes its writes to S3 faster than Client 1 because its objects were smaller. Then a reader attempting to read from position 0 will find that position 0 is missing (Client 1 hasn’t written yet). The reader must either busy‑wait or back off. How does this affect performance?

Corfu’s design explicitly tolerates out‑of‑order writes. The reader can use a **fill‑hint** from the sequencer: the sequencer knows the highest token issued (say, 5) but not which tokens have been filled. However, the sequencer can also track the highest **filled** token by receiving acknowledgments from clients after writes. Alternatively, the reader can detect a missing position and assume a hole until a timeout, then write a tombstone. In practice, Corfu’s clients try to write the objects quickly and in a timely fashion, so holes are rare. The sequencer also provides a **tail** operation that returns the highest filled position, which readers can use to safely advance their read cursors.

---

## 6. Comparison with Kafka and BookKeeper

### 6.1 Apache Kafka

Kafka organizes a log into partitions, each with a leader. The leader maintains in‑memory indices and appends to disk segments. While Kafka can handle millions of events per second across many partitions, strict global ordering requires a single partition—which becomes a bottleneck. Kafka’s storage is local SSDs, replicated with ISR (in‑sync replicas). This is expensive at scale.

Corfu offers **global ordering by design** without a single bottleneck, because the sequencer is lightweight and storage is distributed across stripes. However, Corfu’s read latency is higher (due to object store latency) unless the data is cached. For applications that need sub‑millisecond reads, Corfu is not a replacement; Kafka’s in‑memory caching gives it an edge.

### 6.2 Apache BookKeeper

BookKeeper is a distributed write‑ahead log used by Pulsar. It stores entries in ledgers, which are replicated across bookies using a quorum protocol. BookKeeper provides low write latency (single‑digit ms) but requires fast disks on every bookie. It also has a complex recovery protocol when a bookie fails.

Corfu’s use of object storage means writes are slower (tens of ms) but storage is virtually unlimited and cheap. For workloads that can tolerate a few hundred millisecond write latency (e.g., batch data pipelines, audit logs, event sourcing), Corfu is more cost‑effective. Also, Corfu’s multi‑stripe design allows elastic storage scaling: adding a new stripe is as simple as adding a new S3 bucket prefix, whereas adding bookies requires rebalancing.

---

## 7. Real‑World Deployments and Use Cases

Corfu has been used in production at VMware for internal services, and its ideas have influenced other systems. Two interesting use cases:

### 7.1 Metadata Service for Cloud Infrastructure

VMware’s SDDC (Software‑Defined Data Center) uses Corfu as the **metadata store** for virtual machine state. The metadata log must be totally ordered to ensure deterministic VM migrations. Using Corfu, they can store this metadata on S3 (or object storage) which is cheaper than a replicated DB like ZooKeeper (which requires many fast disks). The write throughput is sufficient (tens of thousands of metadata updates per second), and the durability of S3 ensures no data loss even in catastrophic failures.

### 7.2 Stream Processing Backend

Consider a system that ingests sensor data from millions of IoT devices. Each sensor produces a small record (100 bytes). The system must preserve the exact order of events from all sensors combined. A Kafka cluster with a single partition would be overwhelmed. Instead, a Corfu log can scale horizontally by increasing the number of stripes and batching records into large objects (e.g., 16 MB per object). The object store cost is low, and the global ordering allows downstream stream processors (e.g., Flink) to exactly once semantics without extra coordination.

---

## 8. Implementation Details and Trade‑offs

### 8.1 Object Naming and Metadata

Each object in a stripe must have a unique name that encodes the stripe ID and the range of positions it covers. A typical naming scheme: `stripe_X/startPos` or `stripe_X/highestPos`. Corfu also maintains a **metadata store** (e.g., etcd) that maps each stripe to the list of objects it contains, along with their start and end positions. This metadata is updated atomically after an object is written. Because the metadata store is only updated on object creation (not on every record), the load is low.

### 8.2 Garbage Collection

Old objects need to be trimmed when all positions they contain have been read and are no longer needed (e.g., after a checkpoint). Corfu exposes a `trim(position)` operation that advances the log’s low‑water mark. The garbage collector can then delete objects entirely below that mark. However, because positions are interleaved across stripes, trimming is not trivial: an object may contain positions partly above and partly below the trim point. Corfu solves this by rewriting a sparse object—splitting objects at trim boundaries.

### 8.3 Consistency Guarantees

Corfu provides **linearizability** for individual appends: once an append returns to the client, the record is immediately visible to all subsequent reads. This is achieved because:

- The sequencer issues unique positions atomically.
- The client writes the record to the object store, which is consistent (object store provides read‑after‑write consistency).
- As long as the client acknowledges to the sequencer after the write, the system knows the position is filled.

However, there is a subtlety: if the sequencer’s token counter is not persisted synchronously, a crash could cause token reuse. Corfu handles this by periodically checkpointing the sequencer’s state to object storage.

### 8.4 Performance Benchmarks

In published measurements, Corfu achieves ~1 GB/s write throughput on a single client using 64 stripes and 16 MB objects. Latency per‑record (including batching) is about 50ms for writes, and reads vary from 10ms to 200ms depending on object size and cache. These numbers are not competitive with Kafka’s single‑digit ms latency, but for throughput‑oriented use cases, Corfu excels.

---

## 9. Extensions and Alternatives

### 9.1 Corfu with Local Caching

To reduce read latency, Corfu can be combined with a local SSD cache. Frequently read objects are cached, while the authoritative copy remains in object storage. This hybrid approach bridges the gap between Kafka’s speed and Corfu’s cost efficiency.

### 9.2 Erasure Coding Instead of Multi‑Stripe

Corfu’s multi‑stripe layout is essentially a form of **data striping** akin to RAID 0 (with no redundancy). For durability, the object store itself provides replication (e.g., S3 replicates data across three AZs). Some designs use erasure coding across stripes to further reduce storage overhead while tolerating stripe failures. However, that adds complexity.

### 9.3 Other Distributed Logs on Object Storage

Since Corfu’s publication, similar ideas have appeared: **Delta Lake** and **Apache Iceberg** use object storage for log‑structured tables, but they are not distributed shared logs—they are table formats. **Apache Pulsar** uses BookKeeper but can optionally tier data to object storage via **tiered storage**. Corfu is unique in treating object storage as the primary store, not a secondary tier.

---

## 10. Conclusion

Corfu shows us that a distributed shared log does not need to be built on expensive, custom hardware. By cleverly combining a centralized but lightweight sequencer with a multi‑stripe layout over commodity object storage, it achieves strong consistency, high throughput, and elastic scalability. Its design challenges the assumption that object stores are too slow for real‑time logging. For applications where global total order is more important than sub‑millisecond latency, Corfu offers a compelling, cost‑effective solution.

The lessons from Corfu extend beyond the log itself: they remind us that distributed systems can innovate by embracing the characteristics of underlying infrastructure—like object storage’s high durability but high latency—rather than working against them. Whether you’re building a metadata store, an event sourcing platform, or a stream processing backend, Corfu’s architecture provides a blueprint for thinking differently about ordering, storage, and consistency.

If you ever find yourself weighing the trade‑offs between Kafka’s throughput and BookKeeper’s durability, consider Corfu. It might just be the missing piece in your distributed systems toolkit.

---

_Further Reading:_

- “Corfu: A Distributed Shared Log” (OSDI 2012)
- “Tiered Storage for Apache Pulsar” (Pulsar documentation)
- “Amazon S3 Performance Guidelines”

_Note: The original Corfu paper proposes a more generic architecture; this article covers its core ideas with modern interpretations._
