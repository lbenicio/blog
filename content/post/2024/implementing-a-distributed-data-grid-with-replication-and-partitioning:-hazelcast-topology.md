---
title: "Implementing A Distributed Data Grid With Replication And Partitioning: Hazelcast Topology"
description: "A comprehensive technical exploration of implementing a distributed data grid with replication and partitioning: hazelcast topology, covering key concepts, practical implementations, and real-world applications."
date: "2024-12-09"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/implementing-a-distributed-data-grid-with-replication-and-partitioning-hazelcast-topology.png"
coverAlt: "Technical visualization representing implementing a distributed data grid with replication and partitioning: hazelcast topology"
---

## The Tyranny of the Single Point of Failure: Why Your Cache Needs a Topology

Imagine you’re the architect for a global e-commerce platform. It’s Black Friday. Your product catalog is massive, your session data is volatile, and your backend relational database is already sweating just thinking about the load. You know you need an in-memory cache to survive the avalanche of traffic. So, you deploy Redis on a single, powerful server. It works brilliantly for a month. You sleep soundly.

Then, at 2:00 AM on the busiest shopping day of the year, the server’s power supply fries. The server dies. Your cache is gone. Not just the data—but the _performance advantage_. Every single user request now slams directly into your already-overloaded database. Your site doesn’t just slow down; it crashes. Millions of dollars in revenue evaporate in minutes.

This scenario is the nightmare that every modern, high-availability system must avoid. The solution isn’t just “caching” anymore. It’s about building a **distributed data grid**—a system that treats memory not as a volatile, single-server resource, but as a cohesive, resilient, and scalable cluster.

Enter Hazelcast.

Hazelcast is a leading open-source in-memory data grid (IMDG) that offers a more sophisticated solution than a simple cache like Redis or Memcached. It’s not just a key-value store; it’s a distributed computing platform where your data and your application logic live _together_ in memory, physically distributed across multiple servers. But the real magic—and the most critical design decision you'll face—lies in its **topology**: the architectural blueprint that governs how your data is partitioned, replicated, and discovered across the cluster.

Many engineers jump into Hazelcast with a simple goal: “make my app faster.” They throw data at it, configure a few parameters, and hope for the best. That approach works for demos and small-scale tests, but in production—with hundreds of millions of keys, fluctuating node counts, and the constant threat of network partitions—topology decisions separate the robust systems from the ticking time bombs.

In this post, we will peel back the layers of Hazelcast’s architecture. We will explore how partitioning shapes the distribution of data, how replication ensures durability without sacrificing performance, and how discovery mechanisms keep a cluster alive through failures. Along the way, we’ll dive into real-world examples, configuration snippets, and practical trade-offs you’ll face when designing a data grid for mission-critical workloads.

---

## 1. The Distributed Data Grid: More Than “Distributed Cache”

Before we dive into topology, let’s clarify what a distributed data grid really is. A **distributed cache** (like Redis with replication or Memcached) stores key-value pairs across nodes but usually exposes a simple API with limited compute capabilities. A **distributed data grid** takes this further: it partitions data across nodes, replicates it for fault tolerance, and, crucially, allows you to run distributed computations (like map-reduce, aggregations, or entry processors) directly on the data without moving it to a client.

Hazelcast is an IMDG. It implements the Java `Map` interface (plus `Set`, `List`, `Queue`, etc.) but distributes the contents across the cluster. When you put a key-value pair, Hazelcast uses a partitioning algorithm to decide which node owns that key (the **primary partition**) and then, depending on your configuration, replicates it to one or more backup nodes. The client (or an embedded member) can then retrieve or modify the data from any node—the node transparently routes the request to the correct owner.

This design offers:

- **Elastic scalability**: add or remove nodes without restarting the cluster.
- **High availability**: if a node fails, its backup partitions are promoted.
- **Data locality**: run computations where the data resides, minimizing network overhead.

The topology—the way nodes connect, discover each other, and manage partition ownership—is the skeleton that supports all these features.

---

## 2. Hazelcast Topology: The Skeleton of Your Cluster

### 2.1 Members and Clusters

A Hazelcast node is called a **member**. Members can be started in an embedded mode (inside your application JVM) or as standalone server nodes. When multiple members start and discover each other, they form a **cluster**. The cluster is a single logical unit: any member can serve any request, and the data is evenly distributed.

Topology, in this context, refers to two things:

- **Logical topology**: how partitions are assigned to members and how replicas are placed.
- **Physical topology**: how members discover each other and communicate (e.g., over a LAN, across data centers, or in the cloud).

Let's explore both.

### 2.2 Partitioning: The Core of Distribution

Every Hazelcast distributed data structure (IMap, ICache, ISet, etc.) is split into **partitions**. By default, a cluster has 271 partitions (this number is configurable, but rarely changed). Each partition is a unit of storage and concurrency. The partition count must be a prime number to ensure even distribution when using consistent hashing—more on that in a moment.

When you `map.put("user123", userProfile)`, the key’s hash is computed, and the result modulo 271 determines the partition ID. That partition is assigned to one member (the primary owner) and possibly to other members (backup owners).

**Example:**

- Cluster with 3 members: A, B, C.
- Partition 0 → primary on A, backup on B.
- Partition 1 → primary on B, backup on C.
- Partition 2 → primary on C, backup on A.
- ... and so on.

The mapping from partition to member is stored in a **partition table** that is replicated to every member. When a member joins or leaves, the partition table is updated and propagated.

#### 2.2.1 Partition Groups

By default, Hazelcast spreads partitions as evenly as possible across all members. However, you can influence placement using **partition groups**. This is critical for physical topology awareness.

Imagine you run a cluster across three racks in a data center. Each rack has multiple members. If you don't configure partition groups, the system will treat all nodes equally, and a backup for a partition might end up on the same rack as its primary. If that rack loses power, both primary and backup are lost.

Partition groups allow you to specify that members belonging to the same group (e.g., rack) should never host both a primary and its backup for the same partition. This ensures fault tolerance at the rack level.

**Configuration (XML):**

```xml
<hazelcast>
  <partition-group enabled="true" group-type="CUSTOM">
    <member-group>
      <interface>10.0.0.1</interface>
      <interface>10.0.0.2</interface>
    </member-group>
    <member-group>
      <interface>10.0.0.3</interface>
      <interface>10.0.0.4</interface>
    </member-group>
  </partition-group>
</hazelcast>
```

Without this, your cluster is vulnerable to correlated failures.

#### 2.2.2 Backup Count and Sync vs Async Replication

Hazelcast supports multiple backups per partition. The default is 1. You can set `backup-count` to 0 (no backups—dangerous!), 1, 2, or more. More backups increase fault tolerance but consume more memory and network bandwidth.

Replication of updates to backups can be synchronous or asynchronous:

- **Synchronous (`async-backup-count=0`)**: The primary waits for an acknowledgment from the backup before returning success. This guarantees that after a `map.put(key, value)` returns, the entry is safe on at least two nodes. Latency increases.
- **Asynchronous (`async-backup-count>0`)**: The primary returns immediately after writing locally, and the backup is updated in the background. Higher throughput but risk of data loss if primary fails before backup is written.

**When to use each?** For session data where eventual consistency is acceptable, async backs ups can save milliseconds. For critical financial transactions, you want synchronous replication. Hazelcast allows mixing: you can have one synchronous backup and one async backup.

### 2.3 Consistent Hashing and Partition Assignment

Hazelcast uses **consistent hashing** to assign partitions to members. This is a technique that minimizes the number of partitions that need to be reassigned when a member joins or leaves. In a naive modulo scheme, adding a node would cause almost all keys to remap. With consistent hashing, only the partitions that were owned by the joining/leaving node are moved—typically around `1/N` of the total partitions where `N` is the number of members.

Hazelcast implements this by placing members on a hash ring. Each partition gets assigned to the nearest member in clockwise order. When a member leaves, its partition ownership is transferred to its neighbors; the rest remain untouched.

**Example:**
Suppose we have 2 members: A and B. A owns partitions 0-135, B owns 136-271. Now we add C. Consistent hashing will rebalance some partitions from A and B to C. Without consistent hashing, every partition would need a new owner.

This property is essential for production environments where you need to scale out without a massive data migration spike.

---

## 3. Discovery Mechanisms: How Nodes Find Each Other

Topology doesn’t exist without discovery. Hazelcast offers several ways for members to discover each other:

### 3.1 Multicast Discovery

The simplest approach: members broadcast a multicast message to a well-known address (e.g., `224.2.2.3` on port `54327`). Any member listening on that address can join the cluster. This works well in small, trusted LAN environments but is not recommended for production outside a VPN due to multicast being often blocked by network policies.

**Configuration (XML):**

```xml
<network>
  <join>
    <multicast enabled="true">
      <multicast-group>224.2.2.3</multicast-group>
      <multicast-port>54327</multicast-port>
    </multicast>
  </join>
</network>
```

### 3.2 TCP/IP Discovery

More reliable: you provide a list of IP addresses (or hostnames) of known cluster members. A new member tries to connect to each address in order until it finds an existing cluster member and joins.

**Configuration:**

```xml
<network>
  <join>
    <tcp-ip enabled="true">
      <member>10.0.0.1:5701</member>
      <member>10.0.0.2:5701</member>
    </tcp-ip>
  </join>
</network>
```

You can also use a `members` file that is refreshed periodically. This is common in dynamic environments.

### 3.3 Cloud-Based Discovery: AWS, Kubernetes, and More

In cloud or containerized environments, you don't know IP addresses upfront. Hazelcast provides plugins for:

- **AWS EC2**: Uses the AWS API to query instances by security group, tags, or region.
- **Kubernetes**: Uses the Kubernetes API to discover pods within a namespace.
- **HashiCorp Consul, etcd, Zookeeper**: You can implement a custom discovery plugin or use built-in ones.

**AWS Example (XML):**

```xml
<network>
  <join>
    <aws enabled="true">
      <access-key>my-access-key</access-key>
      <secret-key>my-secret-key</secret-key>
      <region>us-west-1</region>
      <security-group>sg-12345678</security-group>
      <tag-key>hazelcast</tag-key>
      <tag-value>prod</tag-value>
    </aws>
  </join>
</network>
```

This allows your cluster to auto-scale: when a new instance with the tag `hazelcast=prod` spins up in the same security group, it automatically joins the cluster.

---

## 4. Replication In-Depth: From Writes to Split-Brain

### 4.1 The Write Path

When a client (or embedded member) calls `map.put(key, value)`, the following happens:

1. **Determine partition**: hash(key) % partitionCount.
2. **Get partition owner**: the member that holds the primary copy of that partition.
3. **Route request**: if the client is not the owner, it forwards the request (or the client library sends it directly if it knows the mapping).
4. **Primary writes** to local memory and replicates to backup(s).
5. **If sync backup** is configured, wait for acknowledgment.
6. **Return success** to caller.

**Clarification**: In Hazelcast clients (Java, .NET, Node.js, etc.), the client library maintains a copy of the partition table and can send the request directly to the primary owner, avoiding extra hops.

### 4.2 Read Path

Reads can be served from the primary or from a backup (if `read-backup-data="true"` is set). By default, reads go to the primary. Enabling reads from backups can spread load but increases the chance of reading stale data (because async backups may not have the latest value). For most applications, reads from primaries are fine.

### 4.3 Split-Brain and Merge Policies

A **split-brain** occurs when a network partition splits a cluster into two (or more) sub-clusters, each thinking the other is dead. This is one of the most dangerous scenarios in distributed systems. Without proper handling, both sub-clusters continue to accept writes, leading to data divergence.

Hazelcast addresses split-brain through a **merge policy**. When the network heals and the sub-clusters discover each other, they must merge. The merge policy decides which data to keep.

Common policies:

- `LatestUpdateMergePolicy`: the entry with the most recent timestamp wins.
- `PassThroughMergePolicy`: the entry from the destination map (the larger sub-cluster) wins.
- `HigherHitsMergePolicy`: the entry with more hits wins.
- Custom implementations.

To detect split-brain, Hazelcast uses a **heartbeat mechanism** and a **cluster version**. If a member does not receive heartbeats from the expected number of members for a configurable timeout, it suspects a split and may try to form its own cluster.

**Configuration (XML):**

```xml
<split-brain-protection enabled="true" minimum-cluster-size="3">
  <protect-on>READ_WRITE</protect-on>
</split-brain-protection>
```

This protects the cluster by requiring a minimum number of members for read/write operations. If the quorum is lost, the sub-cluster that has fewer than the minimum size will refuse operations, preventing divergence. This is a simpler alternative to complex merge policies; you never get into a split-brain situation that creates conflicts.

---

## 5. Data Affinity: Keeping Related Data Together

Sometimes you need to co-locate related data on the same member. For example, you might store a customer’s profile and their order history in different maps, but you want both to reside on the same node to reduce network hops when processing a transaction.

Hazelcast offers a **PartitionAware** interface. If your key implements `PartitionAware`, you can specify a partition key that determines the partition, separate from the actual key.

**Example:**

```java
public class CustomerOrderKey implements PartitionAware<String> {
    private String customerId;
    private String orderId;

    // getters and setters

    @Override
    public String getPartitionKey() {
        return customerId; // ensures all keys with same customerId go to same partition
    }
}
```

Now, when you put an order with key `new CustomerOrderKey(customerId, orderId)`, its partition is based on `customerId`. The customer profile map can also use `customerId` as the partition key (e.g., by using a `PartitionAware` wrapper). This ensures both entries land in the same partition, thus on the same member.

Data affinity dramatically speeds up distributed operations like entry processors that need to read and modify multiple entries within the same transaction context.

---

## 6. Near Cache: Speed at the Cost of Consistency

For read-heavy workloads, accessing the primary owner across the network every time can introduce latency. Hazelcast’s **Near Cache** is a local (client-side or member-side) cache that stores recently accessed entries locally. It reduces network calls but introduces a trade-off: stale data.

Near Cache can be configured with:

- **Invalidation**: When an entry is updated on the primary, an invalidation event is sent to all near caches. However, if using async propagation, there is a window for stale reads.
- **Time-to-live (TTL)** and **Max size** to bound memory usage.
- **Eviction policies**: LRU, LFU, or random.

Near Cache is ideal for reference data that rarely changes, like a product catalog. For session data that changes often, it can cause inconsistencies.

**Configuration (Java API):**

```java
NearCacheConfig nearCacheConfig = new NearCacheConfig()
    .setInvalidateOnChange(true)
    .setTimeToLiveSeconds(60)
    .setMaxSize(10000)
    .setEvictionConfig(new EvictionConfig()
        .setEvictionPolicy(EvictionPolicy.LRU));
IMap<String, Product> productMap = hazelcastInstance.getMap("products");
productMap.addNearCacheConfig("products", nearCacheConfig);
```

---

## 7. Topology and Performance: Practical Trade-offs

### 7.1 Small vs Large Clusters

A 2-3 node cluster is easy to manage but offers limited fault tolerance (if you lose one node, you lose 33–50% of your data unless you have backups). With 3 nodes and backup-count=1, losing one node is fine. Losing two nodes simultaneously could cause data loss.

Large clusters (hundreds of nodes) introduce communication overhead: heartbeats, partition table propagation, and split-brain detection cost time. Hazelcast uses a gossip protocol to distribute membership changes, which scales to a few hundred nodes but degrades at extreme sizes. For very large clusters, consider a hierarchical topology (e.g., multiple Hazelcast clusters connected via WAN replication) or use Hazelcast Jet for streaming workloads that need high throughput.

### 7.2 Network Latency and Serialization

Every distributed operation involves serialization/deserialization of keys and values. Hazelcast uses its own binary protocol (Hazelcast Protocol Buffers) for internal communication, but you can also use Java Serialization, Jackson JSON, or custom serializers.

**Performance tip**: Use a fast serialization format like `DataSerializable` or `Portable` to minimize CPU overhead. Avoid Java serialization. For the highest throughput, use primitives or immutable objects.

**Example of custom DataSerializable:**

```java
public class Employee implements DataSerializable {
    private int id;
    private String name;

    public void writeData(ObjectDataOutput out) throws IOException {
        out.writeInt(id);
        out.writeUTF(name);
    }

    public void readData(ObjectDataInput in) throws IOException {
        id = in.readInt();
        name = in.readUTF();
    }
}
```

### 7.3 Memory Management and Eviction

Hazelcast stores data in the JVM heap. Without eviction, maps grow indefinitely and can cause OutOfMemoryErrors. Configure eviction policies:

- **LRU**: evict least recently used entries.
- **LFU**: evict least frequently used.
- **NONE**: only evict on size limit with max-size policy.
- **Custom**: implement `MapStore` for persistence.

You can set `max-size` (e.g., 10,000 entries) and `max-size-policy` (e.g., `PER_NODE` or `PER_PARTITION`). Also, use `time-to-live-seconds` and `max-idle-seconds` to expire entries.

### 7.4 Indexing for Query Performance

Hazelcast supports distributed queries on maps. Without indexes, queries require scanning every entry on every partition (full scan). Adding indexes speeds up predicates dramatically.

**Configure index:**

```java
map.addIndex("age", false, true); // ordered index on age field
```

Ordered index allows range queries; unordered index supports equality. Indexes consume memory, so be selective. For a map with 10 million entries, indexing a rarely-used field is wasteful.

---

## 8. Comparison: Hazelcast vs. Other Solutions

### 8.1 Redis (Standalone or Cluster)

- **Data model**: Key-value (plus data structures like lists, sets).
- **Topology**: Redis Cluster uses hash slots (16384) with manual failover or Redis Sentinel for HA. No built-in partition groups.
- **Computation**: No distributed entry processors; you must use Lua scripts (limited).
- **Consistency**: Strong on single node; eventual in cluster.
- **Use case**: Simple caching, pub/sub, session store. Not ideal for heavy computations or multi-key transactions across partitions.

### 8.2 Apache Ignite

- Open source IMDG similar to Hazelcast.
- **Topology**: Partitioning similar, but also supports SQL queries with indexes, ACID transactions across partitions.
- **Use case**: When you need SQL-like querying of in-memory data and transactional support.
- **Complexity**: Heavier than Hazelcast, more configuration options.

### 8.3 Memcached

- Simple distributed cache, no replication built-in (requires client-side consistent hashing).
- No backups, no data grid capabilities.

**Hazelcast’s sweet spot**: When you need a lightweight, embeddable data grid with Java semantics, distributed computing, and fast failover. It’s often used in microservices architectures as a sidecar or embedded in applications.

---

## 9. Real-World Scenario: E-Commerce Platform Redesign

Let’s revisit the Black Friday nightmare. How would a Hazelcast cluster with proper topology have prevented the crash?

**Design:**

- 3 members in cluster (could be more for larger load).
- `backup-count=1` synchronized (critical data: session, cart).
- `partition-group` configured to separate members across three availability zones in AWS.
- Discovery via AWS plugin.
- Near Cache for product catalog (TTL=5 minutes, invalidate on change).
- Quorum set to 2 (minimum 2 members for reads/writes) to prevent split-brain.
- Map `sessions` and `carts` use `PartitionAware` (partition key = customer ID) to co-locate session and cart data.

When one server’s power supply fails, the member is detected as dead within seconds. Partition ownership shifts: backup partitions become primaries. The remaining two nodes continue serving all requests. No downtime, no data loss. The database remains protected.

During Black Friday peak, we add two more EC2 instances to the auto-scaling group. They automatically join the Hazelcast cluster. Partitions rebalance gradually, and the cluster handles 2x the traffic without manual intervention.

---

## 10. Monitoring and Production Best Practices

### 10.1 Hazelcast Management Center

Management Center (Enterprise or Open Source) provides a web UI for cluster monitoring: partition distribution, memory usage, operation rates, slow operations. It’s invaluable for debugging topology issues.

### 10.2 JMX Metrics

Enable JMX to expose heap usage, partition counts, backup counts, thread pool status. Integrate with Prometheus/Grafana for alerting.

### 10.3 Logging

Hazelcast uses SLF4J. Set log level to `INFO` in production; `DEBUG` for troubleshooting topology changes.

### 10.4 Configuration Checklist

- **Partition count**: Keep default 271 unless you have 1000+ nodes.
- **Backup count**: 1 is usually enough; 2 for critical data.
- **Replication**: Use synchronous for important writes.
- **Network**: Use TCP/IP with a known seed list, not multicast.
- **Split-brain protection**: Enable quorum with `minimum-cluster-size` > 1.
- **Serialization**: Implement `DataSerializable` or `Portable`.
- **Eviction**: Set `time-to-live` and `max-size` to prevent memory leaks.
- **Indexes**: Add only for queried fields.
- **Near Cache**: Only for read-heavy, rarely updated data.

---

## 11. Conclusion: Topology Is Your Foundation

We began with a cautionary tale of a cacheless disaster. The real lesson is that simply adding a cache isn't enough—you must architect it with a topology that anticipates failure, scales gracefully, and aligns with your application’s data access patterns.

Hazelcast gives you the tools: consistent hashing, partition groups, multiple discovery options, replication control, and split-brain prevention. But these tools are only as good as the decisions you make when configuring them.

- Understand your network environment (cloud, on-premises, hybrid).
- Model your data access patterns (read-heavy vs write-heavy, locality requirements).
- Test failure scenarios (kill a node, simulate a network partition).
- Monitor and adjust partition count, backup count, and near cache settings.

A well-tuned distributed data grid is invisible to the application—it just works, fast and reliable. A poorly tuned one becomes a source of inconsistency, latency, and late-night incident calls.

Now that you understand the tyranny of the single point of failure and how topology defeats it, go forth and build clusters that survive Black Friday—and beyond.
