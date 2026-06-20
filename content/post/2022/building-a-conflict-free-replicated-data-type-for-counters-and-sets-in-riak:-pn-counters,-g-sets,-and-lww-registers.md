---
title: "Building A Conflict Free Replicated Data Type For Counters And Sets In Riak: Pn Counters, G Sets, And Lww Registers"
description: "A comprehensive technical exploration of building a conflict free replicated data type for counters and sets in riak: pn counters, g sets, and lww registers, covering key concepts, practical implementations, and real-world applications."
date: "2022-08-09"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/building-a-conflict-free-replicated-data-type-for-counters-and-sets-in-riak-pn-counters,-g-sets,-and-lww-registers.png"
coverAlt: "Technical visualization representing building a conflict free replicated data type for counters and sets in riak: pn counters, g sets, and lww registers"
---

# The Tyranny of the Clock: Why “Last Write Wins” Is a Data Loss Engine and What to Do About It

## Introduction: The Server That Tickles Reality

The clock on the server next to your database ticks. It is 14:23:04.512. On the other side of the world, another server, connected only by a network that is inherently slow, unreliable, and sometimes completely severed, writes a value to the same key in your distributed database. It is 14:23:04.519.

Which write is correct?

In a single-machine system, this is a trivial question. The database's transaction log, the acid test of atomicity, orders operations with surgical precision. But the moment you step into the realm of distributed systems—the world of Riak, Cassandra, DynamoDB, and the global scale of modern applications—that simple question becomes the central, existential struggle of your data model. The answer is rarely found in a timestamp. The answer is found in the architecture of the conflict itself.

For years, the standard answer to this problem was "Last Write Wins" (LWW)—a brutal, efficient, and often catastrophically destructive approach. You look at the timestamp on two conflicting pieces of data, you pick the newest one, and you throw the other away. The data is lost. Not merged. Not reconciled. Vanished. For a use case like a simple key-value cache for a user's session token, this is acceptable. The session expires; the loss is temporary. But what if the data is a vote in an election? A quantity of money in a bank account? The list of members in a user group? LWW is a data loss engine.

We built distributed systems to survive failure—to be scalable, available, and fault-tolerant. But the fundamental theorem of distributed computing, the CAP theorem, tells us that when a network partition occurs (your "P"), we must choose between Consistency (everyone sees the same data at the same time) and Availability (the system keeps responding). We chose Availability. We built "eventually consistent" systems. The promise was beautiful: the system would heal itself given time. The execution, for decades, was a nightmare of tombstoned deletes, vector clock complexities, and application-level nightmares.

But is LWW truly our only option? And if we must accept some data loss, how can we minimize it? This blog post will dive deep into the mechanics of conflict resolution in distributed databases, explore why LWW is so seductive yet so dangerous, and present a spectrum of alternative strategies—from causal histories to CRDTs—each with their own trade-offs. By the end, you'll understand not just the "how" but the "why" behind the design decisions of systems like DynamoDB, Cassandra, and Riak, and be equipped to choose the right conflict resolution strategy for your own applications.

## Part I: The Architecture of Time in Distributed Systems

### The Illusion of Global Time

The core problem is that time is not absolute in a distributed system. Network latency, clock skew, and the sheer speed of light conspire to make it impossible for two nodes to agree on a single global ordering of events. You cannot simply look at a wall-clock timestamp and declare "this happened later." Why? Because the clocks on different machines drift. NTP (Network Time Protocol) helps but doesn't eliminate the problem. On AWS, even with NTP, clock skew between instances can be as high as several milliseconds, sometimes more. In a system that processes thousands of writes per second, those milliseconds represent thousands of possible order inversions.

Consider a concrete scenario: User A in Tokyo updates their profile photo on a social network. User B in New York simultaneously reads that profile. The write from Tokyo arrives at the database replica in New York after the read. If the system uses a simple wall-clock timestamp, the read might see the old photo because the write's timestamp is "in the future" according to the New York replica's clock. Or worse, two concurrent writes to the same key might both claim to be "last" because their timestamps are based on different local clocks.

This is not a theoretical problem. In 2012, researchers at Google published a paper on Spanner, their globally distributed database. Their key innovation was the TrueTime API, which uses GPS and atomic clocks to bound clock uncertainty. Spanner can provide external consistency—the illusion of a single global timeline—but only because it can wait out the clock uncertainty window. Most distributed databases cannot afford that luxury.

### The CAP Theorem Revisited

The CAP theorem states that in a distributed system, you can only have two of three properties: Consistency, Availability, and Partition Tolerance. When a network partition occurs (your "P"), you must choose between C and A. Most modern databases choose Availability: they continue to accept writes on both sides of the partition, knowing that when the partition heals, those writes may conflict.

This is the root cause of the problem. If you had chosen Consistency (i.e., stop accepting writes on one side of the partition), there would be no conflicts. But then your system would be unavailable during partitions—a showstopper for global applications that must serve users 24/7.

So we accept inconsistency. We accept that during a partition, two servers may believe they are the authoritative source for the same piece of data. When the partition heals, we must reconcile. That reconciliation is the subject of this article.

### Eventually Consistent Systems: The Promise and the Reality

Eventual consistency, the model popularized by Amazon's Dynamo paper, promises that if no new writes occur to a given object, all replicas will eventually converge to the same value. This convergence is achieved through a process called "conflict resolution." The simplest form of conflict resolution is, of course, Last Write Wins.

But the promise of "eventually consistent" is misleading. It suggests that given enough time, everything will be fine. In practice, "enough time" can be unbounded, and the final value may not be what any user intended. The system converges, yes, but to a value determined by a crude heuristic (the largest timestamp), not by application semantics.

## Part II: Last Write Wins – The Brutalist Solution

### How LWW Works

The algorithm is trivial:

1. Each write carries a timestamp (usually provided by the client or server).
2. When a replica receives a write, it stores the value and its timestamp.
3. When a read request arrives, or during anti-entropy replication (gossip), if two replicas have different values for the same key, the one with the highest timestamp wins. The other value is discarded.

That's it. No merging. No history. No reconciliation. The losing write is simply gone.

### The Temptation of LWW

Why would anyone use such a destructive strategy? The reasons are compelling:

- **Simplicity**: The code path for conflict resolution is a single comparison. No complex data structures, no vector clocks, no custom merge functions.
- **Performance**: LWW adds negligible overhead. Every write is a simple put; every read is a simple get. There's no need to track causal dependencies or store multiple versions.
- **Predictability**: The outcome is deterministic given the timestamps. Developers can reason about the system behavior.
- **Space efficiency**: Only one value per key needs to be stored. No version histories, no sibling lists.

These advantages make LWW the default for many distributed databases. Cassandra, for instance, uses LWW by default (though it also supports tunable consistency). DynamoDB uses LWW as the default conflict resolution mechanism in its global tables feature. Redis Cluster, while not strictly a distributed database, also uses a version of LWW in its replication.

### The Catastrophe: Real-World Data Loss

But the cost of LWW is the silent, irrevocable loss of writes. Let's look at some concrete examples:

#### Example 1: Counter Increments

Imagine a distributed counter for page views. Two server replicas both receive a "increment by 1" write at nearly the same time. Each writes the value "previous + 1" with its own timestamp. When they reconcile, the write with the later timestamp wins. The other increment is lost. The counter goes from, say, 100 to 101 instead of 102. The error is small. But for a counter that receives millions of increments, the accumulated loss can be enormous. This is why Cassandra's counter column type uses a different mechanism (though not without its own problems).

#### Example 2: Shopping Cart

A user has a shopping cart that is replicated across two data centers. In one data center, the user adds an item "A" to the cart. In the other data center, concurrently, the user adds item "B". LWW will pick one of these writes based on timestamp. The other item disappears from the cart. The user checks out, expecting both items, but only one arrives. Data loss with real-world financial consequences.

#### Example 3: User Profile Update

Alice and Bob are administrators for a shared social media account. Alice changes the profile description to "We are hiring!" at 10:00:00 UTC. Bob, not seeing the update yet (due to replication lag), changes it to "Check our new product!" at 10:00:01 UTC. If Bob's timestamp is later, Alice's update is lost. The message "We are hiring!" never appears. Even if Alice's update was the intended final result, it's gone.

#### Example 4: Write-After-Delete

A particularly insidious case: a user deletes a file. Later, a stale write (one that was queued before the delete) arrives. Because the delete has an earlier timestamp, the stale write wins, resurrecting the deleted file. This is called "zombie data." To prevent this, systems must use tombstone markers with carefully crafted timestamps, adding complexity.

### Why Timestamps Are Not Causal

The deeper issue is that wall-clock timestamps do not capture causality. Just because event B has a later timestamp than event A doesn't mean B happened after A in the causal sense. Network delays, clock skew, and concurrent operations can all invert the causal order. LWW assumes a total order where none exists. It imposes a spurious ordering that may violate the user's intent.

### The Case for LWW: When Is It Acceptable?

Despite its flaws, LWW is not always bad. It's acceptable when:

- The data is ephemeral (e.g., session caches, rate limiter state).
- The data is immutable (e.g., time-series data where each write is a new point, not an update).
- Application-level idempotency is guaranteed (e.g., a voting system where each vote is a separate key, not an overwrite).
- The cost of data loss is low (e.g., non-critical analytics counters where minor inaccuracy is tolerable).

But for critical state—money, inventory, user permissions, group membership—LWW is a ticking time bomb.

## Part III: Beyond LWW – Alternative Conflict Resolution Strategies

### The Spectrum of Correctness

When we reject LWW, we enter a world of richer conflict resolution. The central idea is to preserve enough information to allow meaningful merging. The trade-off is complexity, storage, and performance. Here is a spectrum, from least to most sophisticated:

1. **LWW** – discard all but the latest.
2. **Last Write Wins with Clock Skew Detection** – reject writes with timestamps too far in the future.
3. **Client-Provided Timestamps** – let the client supply the timestamp (dangerous but used sometimes).
4. **Vector Clocks** – track causal relationships explicitly.
5. **Dotted Version Vectors** – an optimization of vector clocks.
6. **Conflict-Free Replicated Data Types (CRDTs)** – data structures designed for automatic merge.
7. **Application-Level Reconciliation** – store all conflicting versions and let the application decide.
8. **Quorum-Based Synchronous Replication** – avoid conflicts entirely by ensuring consistent writes (falls into CP side of CAP).

We'll explore the most important ones.

### Vector Clocks: Causality Over Time

Vector clocks are the classic solution for tracking causality in distributed systems. The idea is simple: each node maintains a vector of counters, one per node. When a node performs a write, it increments its own counter in the vector. The vector is attached to the write. When two writes conflict, we compare their vector clocks:

- If one vector clock is strictly greater in all counters (i.e., every counter is >= the other's and at least one is >), then it is causally _descendant_ and wins.
- If neither dominates the other, the writes are _concurrent_ and a conflict exists.

Concurrent writes are stored as "siblings." The system must either merge them automatically (via CRDTs) or present them to the application for manual reconciliation.

Vector clocks were popularized by Amazon's Dynamo paper and used in Riak (call it "vector clocks" or "version vectors"). However, they have a critical problem: unbounded growth. Each new node adds an entry to the vector. Over time, the vector can become huge. To prevent this, Riak uses a technique called "clock pruning" where periodically old entries are aged out, but this can cause false conflicts (i.e., treating causally-related writes as concurrent).

#### Example: Vector Clocks in Action

Nodes A, B, C. The initial state: key "x" = 0 with vector clock `(A:0, B:0, C:0)`.

- Write from A: increments A's counter, becomes `(A:1, B:0, C:0)`, value = "Alice".
- Write from B: increments B's counter, becomes `(A:0, B:1, C:0)`, value = "Bob".
  These are concurrent (neither dominates). Both values are stored as siblings.

Now a read from C sees both siblings. The application must resolve them (e.g., merge texts: "Alice and Bob" or pick one manually).

Later, a write from A that is aware of both siblings (because the application fetched them and chose a merged value) can include both counter increments in its vector clock. For example, if the application merges as "Alice and Bob", the new write could have vector clock `(A:2, B:1, C:0)` (A incremented, but B's counter remains at 1 because the merged value incorporated B's write). This clock is now strictly greater than both original clocks, so it dominates them. The siblings collapse into one value.

#### The Vector Clock Bloat Problem

In a system with thousands of nodes, the vector can have thousands of entries. Worse, when nodes are decommissioned or fail, their entries may remain forever, causing steady growth. Riak attempted to solve this with a limit on the vector size. When the limit is reached, the vector is "pruned" by dropping the oldest entries. But pruning can turn a causally descendant write into a concurrent one, introducing artificial conflicts.

Amazon's DynamoDB uses a similar concept called "version vectors" but with optimizations: they store only the nodes that have written to a key, and they use a bloom filter to bound growth. Still, vector clocks are considered heavy for general use.

### CRDTs: The Mathemagic of Automatic Convergence

Conflict-Free Replicated Data Types (CRDTs) are data structures designed such that when any two replicas merge their states (using a commutative, associative, idempotent merge operation), they converge to the same result without requiring consensus or timestamps. CRDTs come in two flavors:

- **State-based (CvRDTs)**: Each replica holds the entire state, and merges by taking the least upper bound (e.g., set union for a grow-only set).
- **Operation-based (CmRDTs)**: Operations are broadcast to all replicas, and the operations must be commutative.

CRDTs solve the conflict resolution problem at the data structure level. For example:

- **G-Counter (Grow-only Counter)**: Each node maintains its own count; total is the sum. When merging, you take the max for each node's count and sum.
- **PN-Counter (Positive-Negative Counter)**: Two G-Counters: one for increments, one for decrements. Merge separately.
- **G-Set (Grow-only Set)**: Add elements, never remove. Merge by union.
- **OR-Set (Observed-Remove Set)**: Add and remove elements. Uses tags (unique IDs) to track which adds were removed. Removes only apply to adds that have been "observed" (i.e., the replica knows about any concurrent adds). This avoids the "add after remove" conflict.
- **LWW-Register**: A register that uses timestamps but without data loss—the timestamp is part of the merge (almost like LWW but with CRDT semantics, e.g., the merge is "value with highest timestamp wins" but it still preserves the monotonicity of merges).

CRDTs are used in practice: Riak supports CRDTs (counters, sets, maps) via its "Riak Data Types" feature. Redis also offers CRDT-based replication in Redis Enterprise (CRDB). SoundCloud uses CRDTs for their system. The collaborative editing tool (like Google Docs) is essentially a CRDT at its core.

#### Example: OR-Set for a Shopping Cart

Add "item A" with tag T1 (unique). Add "item B" with tag T2. Remove "item A" by adding T1 to the tombstones set. Now merge with another replica that added "item C" with tag T3. The merged set is {B, C} because A was removed (its tag is in the tombstone set) and C is new. No data loss.

However, if two replicas both add and remove the same item concurrently, tags help: the remove only applies to the specific add operation that was observed. CRDTs guarantee convergence, but the semantics may surprise application developers. For instance, an OR-Set may resurrect a deleted element if a concurrent add happened before the delete was communicated. This is actually correct from a causal perspective but can be confusing.

### Application-Level Reconciliation: The Absolute Safety Net

Sometimes the best approach is to let the application decide. The system stores all conflicting versions (siblings) and returns them to the client on read. The client (or application logic) then merges them and writes back a resolved value. This is the approach used by Riak in its default "allow_mult" mode.

This gives maximum flexibility: the application developer can implement domain-specific merge logic (e.g., bank transactions: sum the amounts; user profiles: apply a three-way merge; etc.). But it also places a heavy burden on the application. Every read must be prepared to handle multiple values. The application code becomes more complex.

#### Example: Banking Application

A bank account has a balance stored as a key in a distributed key-value store. Two transactions debit $10 and $20 concurrently from different data centers. Without reconciliation, LWW would cause one transaction to be lost. With sibling storage, the application receives both balances: e.g., balance after debit1 = $90, balance after debit2 = $80. The application must determine that the initial balance was $100, apply both debits, and write back $70. This is a correct outcome, but it requires the application to know the initial state. This leads to "read-modify-write" patterns that can be slow and error-prone under contention.

### Causal Consistency and Hybrid Logical Clocks

A middle ground between LWW and full causal tracking is to use hybrid logical clocks (HLC). HLC combines a physical clock with a logical counter to provide causal ordering while staying close to wall-clock time. It avoids the unbounded growth of vector clocks because the whole system can be represented by a single timestamp that is monotonically increasing. However, HLC alone doesn't solve concurrent writes; it only ensures that causally related writes are ordered. Concurrent writes must still be handled, but at least they won't be falsely ordered.

## Part IV: How Major Systems Handle Conflicts

### Amazon DynamoDB

DynamoDB is the successor to the Dynamo paper. It uses a multi-master replication model in global tables. By default, DynamoDB uses LWW with timestamps provided by the client (or server if the client doesn't supply one). However, it also supports a "Developer Guide for Conflict Resolution" that recommends using CRDTs for certain data types, and it provides a "Conflict Resolution" feature that allows you to write a custom Lambda function to resolve conflicts when they occur.

The default LWW behavior means that if you have a global table spanning US and EU, concurrent updates to the same item will result in data loss. DynamoDB's documentation acknowledges this: "Last writer wins is the default conflict resolution strategy. If your workload requires conflict-free replication, you can use conflict resolution settings to customize the behavior."

### Apache Cassandra

Cassandra uses LWW for its standard column updates. Each cell has a timestamp set by the client (or generated by the system). When two columns have the same key and column name, the one with the highest timestamp wins. This is a fundamental part of Cassandra's design. However, Cassandra also offers "lightweight transactions" using Paxos for linearizability (i.e., compare-and-set). These can be used for critical updates, but they come with a performance penalty. For most operations, LWW is the rule.

Cassandra also has a built-in conflict resolution for its counter columns that uses a different algorithm: each replica maintains a separate count, and reads sum them. This avoids the LWW problem for counters but introduces potential read inconsistency (the sum may not reflect all increments if the replica hasn't heard about them).

### Riak

Riak was originally built with vector clocks and sibling storage as its default. Developers could choose to use LWW for specific buckets. Later, Riak introduced "Riak Data Types" (CRDTs) for counters, sets, and maps, which eliminate the need for sibling handling for those types. Riak remains the most flexible system for conflict resolution, allowing you to choose between LWW, vector clocks, and CRDTs per bucket.

### Google Spanner

Spanner takes a different approach: it eschews eventual consistency entirely. It uses TrueTime to enforce external consistency, meaning that all writes are globally ordered. There are no conflicts because there is never a partition where writes are accepted independently. The cost is that Spanner must commit to a strong consistency model, which can reduce availability during network partition (though Google's network is extremely reliable). Spanner is not an eventually consistent system; it's a strongly consistent one that pays the cost with clock synchronization and two-phase commit.

## Part V: Choosing Your Poison – A Decision Framework

So, faced with a distributed system design, how do you choose the right conflict resolution strategy? Here is a step-by-step guide.

### Step 1: Determine Acceptable Data Loss

- **Zero data loss acceptable?** You need strong consistency (choose Spanner, or use Paxos/Raft for linearizable writes). Accept some unavailability or latency.
- **Some data loss tolerable?** LWW might be okay for transient data. But measure the cost: each conflicting write will be lost. If your write rate is high, the accumulated loss may be significant.
- **No data loss acceptable, but availability is paramount?** You must use richer conflict resolution: vector clocks (with application reconciliation) or CRDTs.

### Step 2: Identify the Data Structure

- **Simple register (last value wins semantics)?** LWW is actually correct if the semantics are that the last write should win. But note: "last" must be defined causally, not by clock. Use CRDT LWW-Register (with DVV or HLC) for correct behavior.
- **Counter?** Use a CRDT counter (PN-Counter) or a specialized counter implementation.
- **Set?** Use CRDT OR-Set.
- **Map (like a JSON document)?** Use a CRDT map (e.g., Riak Maps). Or use a vector clock with per-field tracking.

### Step 3: Evaluate Complexity Budget

- **Team skill level**: Can your developers handle reading siblings and writing custom merge functions? If not, CRDTs offer automatic merge but limited flexibility. LWW is simplest but destructive.
- **Operational overhead**: Storing siblings increases storage. Vector clocks grow. CRDTs can have overhead from tombstones (especially in OR-Sets). Estimate costs.

### Step 4: Consider Consistency Guarantees Needed

- **Read-after-write consistency?** You may need to read from a quorum or use read-repair. Conflict resolution doesn't help if you read stale data.
- **Monotonic reads?** If a user reads their own profile after updating, they should see the update. This requires consistency at the session level, often achieved by sticky sessions or read-your-writes guarantees.

### Step 5: Test in Production

- Simulate network partitions and concurrent writes. Measure conflict rates. Compare data loss percentages. Use tools like Jepsen to test your system's behavior under stress.

## Part VI: The Future of Conflict Resolution

The trend in modern distributed databases is towards CRDTs. They offer mathematical guarantees of convergence without requiring synchronous coordination. As the cost of storage and compute continues to drop, the overhead of CRDTs becomes more acceptable. Systems like Redis Enterprise CRDB, CouchDB (with its multi-version concurrency control), and FoundationDB (with its transactional model) are pushing the boundaries.

But CRDTs are not a silver bullet. They require careful design to avoid unbounded metadata growth (e.g., tombstone accumulation in OR-Sets). Some CRDTs, like maps with nested structures, become complex. Also, CRDTs only provide convergence, not consistency: they ensure replicas will agree on the final state, but that final state might not match any user's expectation (e.g., a shopping cart might contain items that were deleted by one user and added by another, due to concurrent operations).

Another direction is the use of hybrid systems that employ lightweight transactions for critical paths and eventually consistent updates for non-critical paths. This is the pattern used in many modern applications: use a strongly consistent database (like PostgreSQL) for transactional data and a distributed cache (like Redis) for ephemeral data, with careful synchronization.

## Conclusion: The Clock Is Not the Author of Truth

We began with two servers writing to the same key, their clocks only 7 milliseconds apart. In a distributed system, that 7 milliseconds is an eternity—time enough for a network partition, clock skew, and concurrent operations to turn a simple timestamp into a lie. LWW assumes that time is the universal arbiter of truth. It is not. Truth is determined by human intent, causal relationships, and domain-specific logic.

The best distributed systems don't rely on clocks to decide which write is correct. They either avoid conflicts by using strong consistency (Spanner), or they embrace conflicts and resolve them with rich semantics (CRDTs, vector clocks, application reconciliation). The choice between these approaches is a trade-off between simplicity, availability, and data correctness. As builders of distributed systems, we must understand this trade-off deeply and not default to LWW just because it's easy.

Next time you reach for a distributed database and see "Last Write Wins" as the default, pause. Think about the data you are storing. Is it a simple cache that can afford to lose writes? Or is it the digital fabric of your users' lives—their accounts, their votes, their shopping carts? The clock says it's 14:23:04.519. But the truth is, the correct write is not the one with the later timestamp. It's the one that preserves the intended state of the world. And that requires more than a clock.

---

_This blog post is part of a series on building reliable distributed systems. Next up: "Vector Clocks in Practice: Implementing Causal Consistency in Python." Subscribe to the newsletter to stay updated._
