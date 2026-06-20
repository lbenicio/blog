---
title: "Building A Lightweight Database Sharding Proxy Using Consistent Hashing And Connection Pooling"
description: "A comprehensive technical exploration of building a lightweight database sharding proxy using consistent hashing and connection pooling, covering key concepts, practical implementations, and real-world applications."
date: "2023-10-16"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/building-a-lightweight-database-sharding-proxy-using-consistent-hashing-and-connection-pooling.png"
coverAlt: "Technical visualization representing building a lightweight database sharding proxy using consistent hashing and connection pooling"
---

# Building A Lightweight Database Sharding Proxy Using Consistent Hashing And Connection Pooling

## Introduction

The first time your database hits the ceiling is unforgettable. Maybe it’s a midnight pager alert—query latency spikes, connection timeouts pile up, and your carefully tuned master-replica setup starts gasping for breath. You throw more RAM at it, upgrade to a bigger instance, and the problem fades… for a few months. Then the data grows again, traffic doubles, and the same ceiling reappears, higher this time but just as brittle. You realize that vertical scaling is not a strategy; it’s a temporary patch. And as your user base expands across regions and your tables swell past hundreds of gigabytes, the question becomes not _if_ you need to shard, but _how_ to do it without rewriting your entire application.

This is the reality for many engineers building data-intensive applications. Sharding—splitting data across multiple database instances—is a proven horizontal scaling technique, yet it remains notoriously difficult to implement cleanly. The naive approach of hard-coding shard mappings into your application code leads to fragile, tightly coupled systems. Change a shard’s capacity, add a new node, or rebalance data, and you may need to redeploy or modify dozens of services. The more elegant solution is to offload the routing logic into a lightweight proxy: a transparent layer between your application and your databases that decides which shard receives each query.

In this post, I’ll walk you through designing and building exactly such a proxy—one that uses consistent hashing to distribute writes evenly across shards, and connection pooling to reuse database connections efficiently. We’ll keep it lightweight, meaning no heavy dependencies, no complex state management, and no need for a full-fledged orchestrator. The goal is to give you a practical, production-ready pattern you can adapt for your own stack.

But first, let’s unpack why a proxy is worth the effort—and why many teams avoid building one until it’s too late.

## Why a Database Proxy?

When you first start sharding, it’s tempting to embed the routing logic directly into your application. You write a utility function that takes a user ID, computes `id % num_shards`, and returns the database connection string. This works for a while. But as your system grows, several cracks appear:

- **Tight coupling**: Every microservice that accesses the user database must implement the same sharding logic. If you change the number of shards or the hash function, you have to update and redeploy every service.
- **Connection explosion**: Each service instance opens its own set of connections to every shard. With hundreds of instances and dozens of shards, the total number of connections can overwhelm the databases. Connection limits are hit, and performance degrades.
- **Rebalancing nightmares**: Adding or removing a shard requires a careful migration. You must drain connections, move data, and update configuration across all services—often with downtime or complex orchestration.
- **No central observability**: Without a proxy, it’s hard to get a unified view of query latency, error rates, or load distribution across shards. Debugging a slow shard becomes a detective game.

A proxy solves all these problems by inserting a dedicated layer between your application and your databases. The application sends every query to the proxy (using a single endpoint), and the proxy handles routing, connection reuse, health checks, and rebalancing. The application remains blissfully unaware of the underlying shard topology.

**Key benefits**:

- **Separation of concerns**: Application developers write standard SQL. The proxy handles all sharding complexity.
- **Connection pooling**: A single proxy can maintain a small, efficient pool of connections per shard, shared across many app instances.
- **Simplified scaling**: Adding or removing shards becomes a configuration change on the proxy, not a code change.
- **Observability**: The proxy can log, monitor, and trace every query, giving you deep insight into database performance.

Of course, a proxy also introduces a network hop and potential latency overhead. But in practice, the overhead is negligible (sub-millisecond) if the proxy is co-located with your application or uses a fast connection like Unix sockets. The benefits vastly outweigh the costs for any system that plans to scale beyond a single database.

## Core Concepts: Sharding, Consistent Hashing, and Connection Pooling

Before we dive into implementation, let’s solidify the three foundational concepts.

### Sharding Strategies

Sharding is the process of splitting a large dataset into smaller, independent databases (shards). There are several strategies for deciding which shard a particular row belongs to:

- **Range-based sharding**: Data is partitioned by ranges of a key (e.g., `user_id` 1–1000 in shard 0, 1001–2000 in shard 1). Simple but can lead to hot spots if keys are not uniformly distributed (e.g., most new users have high IDs).
- **Hash-based sharding**: A hash function is applied to the shard key (e.g., `hash(user_id) % num_shards`). This provides uniform distribution but makes adding/removing shards expensive because most keys are remapped.
- **Directory-based sharding**: A lookup table maps each key to a shard. Flexible but requires managing a central mapping service that can become a bottleneck.

For our proxy, we’ll use _consistent hashing_, a variant of hash-based sharding that dramatically reduces the number of keys that need to move when the number of shards changes.

### Consistent Hashing

Traditional hash-based sharding uses `hash(key) % N`, where `N` is the number of shards. If you increase `N` to `N+1`, almost every key is remapped to a different shard, causing a massive rebalancing storm. Consistent hashing solves this by arranging the hash space (e.g., 0 to 2³²-1) in a ring. Each shard is assigned one or more positions on the ring (usually via hashing the shard’s identifier multiple times to create “virtual nodes”). To locate a key, you hash the key and find the next shard position clockwise on the ring. When you add a new shard, it takes over responsibility for the keys between its position and the next shard’s position. On average, only `K/N` keys need to move, where `K` is the total number of keys and `N` is the total number of shards.

**Virtual nodes** are crucial for balancing load. Without them, if you have only a few shards, the hash ring can become lopsided. By assigning each physical shard, say, 100 virtual nodes scattered around the ring, you get a much more uniform distribution of keys. When a physical shard is added or removed, only its virtual nodes need to be adjusted.

### Connection Pooling

Each database connection involves a TCP handshake, authentication, and memory allocation. Opening a new connection for every query is expensive and can exhaust database resources. A connection pool is a cache of database connections maintained so that connections can be reused when the application needs to execute queries. Pools typically cap the number of connections (min and max), handle timeouts, and automatically close stale connections.

In our proxy, we’ll maintain one pool per shard. The proxy will be multi-threaded or asynchronous to handle many concurrent application requests, each picking a connection from the appropriate pool. This way, we can limit the total number of connections to each database to, say, 10–20, regardless of how many application instances are sending queries to the proxy.

## Designing the Proxy

Now let’s design the proxy architecture. Our goals:

- **Lightweight**: Minimal dependencies. We’ll implement it in Python using `asyncio` and `aiomysql` for async database access. (In production, you might prefer Go or Rust for performance, but Python is fine for demonstration and many workloads.)
- **Stateless**: The proxy does not store any data; it only routes queries. This allows us to run multiple proxy instances behind a load balancer.
- **Fast routing**: The consistent hash ring lookup should be O(log N) with a sorted list of virtual nodes.
- **Connection pooling**: We’ll use a simple custom pool (or wrap `aiomysql.pool`) that reuses connections per shard.
- **Graceful rebalancing**: When the shard topology changes (e.g., we add a shard), the proxy should update its ring without dropping existing connections.

### Architecture Overview

```
+-------------------+     +------------------------+
| Application       |     | Application            |
| (e.g., web server)|     | (e.g., batch job)      |
+--------+----------+     +----------+-------------+
          |                           |
           \                         /
            \                       /
             +---------------------+
             |   Proxy Instance    |
             |   (consistent hash) |
             |   (connection pools)|
             +----+---+----+------+
                  |   |    |
            +-----+   |    +-----+
            |           |          |
        +---+---+  +---+---+  +---+---+
        | Shard0 |  | Shard1 |  | Shard2 |
        |  DB    |  |  DB    |  |  DB    |
        +-------+  +-------+  +-------+
```

The application sends a query accompanied by a shard key (e.g., the user’s tenant ID). The proxy hashes the key, looks up the responsible shard on the ring, picks a connection from that shard’s pool, executes the query, and returns the result.

### Data Structures

We need:

- A sorted list of `(hash_value, shard_id)` pairs representing virtual nodes.
- A dictionary mapping `shard_id` to a connection pool object.
- A lock or mechanism to safely update the ring when shards are added/removed.

The ring can be represented as a Python list of `(hash, shard_id)` tuples sorted by `hash`. To look up a key, we compute its hash, then binary search for the first virtual node with hash >= key_hash (wrapping around if we reach the end).

## Implementation: Step by Step

We’ll implement our proxy in Python using `asyncio` and `aiomysql`. The full code is available in a companion repository; here we’ll focus on the critical components.

### 1. Consistent Hash Ring

First, let’s implement a `ConsistentHashRing` class.

```python
import hashlib
import bisect

class ConsistentHashRing:
    def __init__(self, nodes=None, replicas=100):
        self.replicas = replicas  # number of virtual nodes per physical node
        self.ring = []  # list of (hash, node) sorted
        self.nodes = {}  # mapping node -> set of hash positions
        if nodes:
            for node in nodes:
                self.add_node(node)

    def _hash(self, key):
        # Use SHA-256 for good distribution, truncate to 32 bits for ring
        return int(hashlib.sha256(key.encode()).hexdigest(), 16) % (2**32)

    def add_node(self, node):
        if node in self.nodes:
            raise Exception(f"Node {node} already exists")
        self.nodes[node] = set()
        for i in range(self.replicas):
            virtual_key = f"{node}:{i}"
            h = self._hash(virtual_key)
            self.nodes[node].add(h)
            bisect.insort(self.ring, (h, node))
        self.ring.sort(key=lambda x: x[0])

    def remove_node(self, node):
        if node not in self.nodes:
            raise Exception(f"Node {node} does not exist")
        for h in self.nodes[node]:
            self.ring.remove((h, node))
        del self.nodes[node]

    def get_node(self, key):
        if not self.ring:
            return None
        h = self._hash(key)
        # Binary search for first hash >= h
        idx = bisect.bisect_left(self.ring, (h, ""))
        if idx >= len(self.ring):
            idx = 0
        return self.ring[idx][1]
```

Key design decisions:

- We use SHA-256 (truncated) for the hash function; it’s cryptographically strong and distributes evenly.
- The `replicas` parameter controls virtual nodes. For a production system with few physical nodes (e.g., 4–10), use 100–200 replicas.
- `add_node` and `remove_node` rebuild the ring list. In a real system, you’d want to use a read-write lock so that lookups can continue while updating.

### 2. Connection Pool for Each Shard

We need to manage connections per shard. Python’s `aiomysql` provides a pool, but let’s build a minimal custom pool that wraps it for simplicity, allowing us to configure min/max connections per shard.

```python
import aiomysql
import asyncio

class ShardPool:
    def __init__(self, host, port, user, password, db, minsize=2, maxsize=10):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.db = db
        self.minsize = minsize
        self.maxsize = maxsize
        self._pool = None

    async def init(self):
        self._pool = await aiomysql.create_pool(
            host=self.host,
            port=self.port,
            user=self.user,
            password=self.password,
            db=self.db,
            minsize=self.minsize,
            maxsize=self.maxsize,
            autocommit=True
        )

    async def close(self):
        if self._pool:
            self._pool.close()
            await self._pool.wait_closed()

    async def execute(self, query, params=None):
        async with self._pool.acquire() as conn:
            async with conn.cursor() as cursor:
                await cursor.execute(query, params)
                return await cursor.fetchall()
```

We’ll have a dictionary mapping shard IDs to `ShardPool` instances.

### 3. Proxy Core: Receive and Route Queries

Now we build the proxy server using `asyncio`. We’ll support a simple protocol: the application sends a JSON-like request with a `shard_key` and `query`. The proxy looks up the shard, executes the query, and returns results.

We’ll use an HTTP server for simplicity (e.g., `aiohttp`). In production, you might use a custom binary protocol for lower latency.

```python
from aiohttp import web
import json

class ShardProxy:
    def __init__(self, config):
        self.ring = ConsistentHashRing()
        self.pools = {}
        # config: list of shard configs {shard_id, host, port, user, password, db}
        for shard in config['shards']:
            sid = shard['shard_id']
            self.ring.add_node(sid)
            self.pools[sid] = ShardPool(
                host=shard['host'],
                port=shard['port'],
                user=shard['user'],
                password=shard['password'],
                db=shard['db']
            )

    async def init_pools(self):
        for pool in self.pools.values():
            await pool.init()

    async def close_pools(self):
        for pool in self.pools.values():
            await pool.close()

    async def handle_query(self, request):
        try:
            data = await request.json()
            shard_key = data['shard_key']
            query = data['query']
            params = data.get('params', None)
        except (KeyError, json.JSONDecodeError) as e:
            return web.json_response({'error': str(e)}, status=400)

        shard_id = self.ring.get_node(shard_key)
        pool = self.pools[shard_id]
        try:
            result = await pool.execute(query, params)
            return web.json_response({'result': result})
        except Exception as e:
            return web.json_response({'error': str(e)}, status=500)

    async def add_shard(self, request):
        # Admin endpoint to add a shard dynamically
        data = await request.json()
        sid = data['shard_id']
        self.ring.add_node(sid)
        new_pool = ShardPool(
            host=data['host'],
            port=data['port'],
            user=data['user'],
            password=data['password'],
            db=data['db']
        )
        await new_pool.init()
        self.pools[sid] = new_pool
        return web.json_response({'status': 'added'})

    async def remove_shard(self, request):
        data = await request.json()
        sid = data['shard_id']
        old_pool = self.pools.pop(sid, None)
        self.ring.remove_node(sid)
        if old_pool:
            await old_pool.close()
        return web.json_response({'status': 'removed'})
```

Then we set up the app:

```python
async def main():
    config = {
        "shards": [
            {"shard_id": "shard0", "host": "127.0.0.1", "port": 3306, "user": "root", "password": "", "db": "shard0"},
            {"shard_id": "shard1", "host": "127.0.0.1", "port": 3307, "user": "root", "password": "", "db": "shard1"},
        ]
    }

    proxy = ShardProxy(config)
    await proxy.init_pools()

    app = web.Application()
    app.router.add_post('/query', proxy.handle_query)
    app.router.add_post('/add_shard', proxy.add_shard)
    app.router.add_post('/remove_shard', proxy.remove_shard)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, '0.0.0.0', 8080)
    await site.start()

    print("Proxy running on 0.0.0.0:8080")
    await asyncio.Event().wait()  # run forever

if __name__ == '__main__':
    asyncio.run(main())
```

### 4. Testing the Proxy

Let’s simulate a scenario. Suppose we have two MySQL instances running locally on ports 3306 (shard0) and 3307 (shard1), each with a table `users`. We’ll send a query to insert a user with `user_id=12345`.

```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"shard_key": "user_12345", "query": "INSERT INTO users (id, name) VALUES (12345, 'Alice')"}'
```

The proxy hashes `"user_12345"` and routes it to either shard0 or shard1. Consistent hashing ensures that the same key always goes to the same shard (unless we change the ring).

## Handling Shard Rebalancing

One of the main advantages of consistent hashing is that adding or removing a shard affects only a fraction of keys. Let’s see how our proxy handles it.

When we add a new shard (say, shard2), we call the `/add_shard` endpoint. The proxy:

1. Adds virtual nodes for shard2 to the ring.
2. Initializes a connection pool for shard2.
3. From now on, new keys that hash into the range claimed by shard2 will be routed to it.

Keys that were previously assigned to other shards remain there. But what about data migration? The proxy does not automatically migrate existing data; that is the responsibility of an external migration process. However, the proxy’s consistent hashing ensures that only `K/N_new` keys will be repointed to the new shard—much less than the `K * (N_new-1)/N_new` that would happen with `mod N` hashing.

**Example**: Suppose we have 3 old shards and we add a 4th. With naive `hash % 4`, roughly 75% of keys would be reassigned. With consistent hashing, only about 25% of keys are reassigned (the ones that fall into the new shard’s coverage around the ring). This dramatically reduces the volume of data that needs to be moved.

To support migration, you might implement a “double-read” pattern: when a key is retrieved, if it’s not found on the new shard, fall back to the old shard (based on the previous ring). Over time, you can move data and then switch to the new mapping exclusively. This is beyond the scope of our simple proxy, but the ring structure allows for such advanced strategies.

## Production Considerations

Our current proxy is functional but far from production-ready. Here are critical enhancements:

- **Health checks**: The proxy should periodically check that each shard is reachable and that the pool is healthy. If a shard goes down, we might want to temporarily route its keys to a backup or return an error.
- **Circuit breakers**: If connection attempts to a shard fail repeatedly, the proxy should stop sending queries to it and fail fast, rather than hanging.
- **Backpressure**: When all connections in a pool are busy, the proxy should either queue requests or reject them with a `503 Service Unavailable`. Unbounded queuing will lead to memory exhaustion.
- **Authentication and TLS**: The proxy should authenticate its clients (e.g., via tokens or client certificates) and encrypt traffic to databases.
- **Monitoring**: Export metrics (queries per second, latency per shard, pool utilization) to Prometheus or similar.
- **Idempotency and retries**: For safe query execution, the proxy might need to retry queries on transient failures, but must be careful with non-idempotent writes.

## Comparison with Existing Solutions

You might wonder: why build a custom proxy when solutions like Vitess, ProxySQL, or MySQL Router exist?

- **Vitess**: A full-fledged database clustering system built on top of MySQL, offering sharding, replication, and automatic failover. It’s powerful but heavy—requires deploying a sidecar, a topology manager, and often a large operational investment. Our proxy is a fraction of the complexity.
- **ProxySQL**: A high-performance proxy that can do query routing, connection pooling, and even query rewriting. However, it doesn’t natively support consistent hashing for shard routing; you’d have to configure query rules manually, which is less flexible for dynamic sharding.
- **MySQL Router**: Official Oracle product that supports simple load balancing but not sharding.

Our lightweight proxy is best for teams that want a simple, controllable shard router without the overhead of a full orchestration system. It’s particularly well-suited for microservice architectures where each service has its own database and you want to shard a few of them.

## Conclusion

Database sharding doesn’t have to be a terrifying architecture shift. By building a lightweight proxy that combines consistent hashing and connection pooling, you can scale your databases horizontally with minimal changes to your application code. The proxy acts as a transparent routing layer, allowing you to add or remove shards on the fly, reuse connections efficiently, and centralize observability.

We’ve only scratched the surface of what’s possible. The code presented here is a starting point—a skeleton you can extend with health checks, TLS, and more sophisticated query routing (e.g., read replicas, statement-aware routing). But even in its simple form, it solves the core pain points of sharding: coupling, connection explosion, and rebalancing.

The next time your database hits the ceiling, you’ll have a tool that doesn’t just patch the problem—it reframes it. You’ll think in terms of horizontal scale, and you’ll know how to build the glue that makes it work.
