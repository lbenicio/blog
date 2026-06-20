---
title: "Building A Linearizability Tester For Distributed Systems: Monotonic Reads And Writes In Jetpack"
description: "A comprehensive technical exploration of building a linearizability tester for distributed systems: monotonic reads and writes in jetpack, covering key concepts, practical implementations, and real-world applications."
date: "2019-04-01"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/building-a-linearizability-tester-for-distributed-systems-monotonic-reads-and-writes-in-jetpack.png"
coverAlt: "Technical visualization representing building a linearizability tester for distributed systems: monotonic reads and writes in jetpack"
---

# Building A Linearizability Tester For Distributed Systems: Monotonic Reads And Writes In Jetpack

## Introduction: The Ghost in the Machine

You just hit “Save” on a critical draft. The UI spinner vanishes; a cheerful green banner confirms, “Document updated.” You sigh with relief, close the app, and open it again an hour later from a different device. The banner is gone. The old, unsaved version stares back at you. Your heart sinks. You didn’t misclick. You didn’t fail to sync. The system, in that moment, lied to you.

This isn’t a story about a fire-and-forget API call gone wrong. This is a story about **consistency**. More specifically, it is a story about the subtle, maddening failure of a system to honor a promise it never explicitly made, but that you, as a user, implicitly rely on: _If I see my write succeed, I should never later see the absence of that write._

For software engineers building distributed systems, this trust is the bedrock of usability. Yet, achieving it is deceptively hard. We abstract away the messy reality of geographically distributed databases, caching layers, load balancers, and eventually consistent replicas. We wrap them in clean APIs and reactive state managers. But under the hood, the ghost of stale state is always lurking.

This blog post is not just about distributed databases. It’s about the intersection of two worlds that often don’t talk to each other: **formal distributed systems verification** and **practical client-side state management**. We are going to build a tool to hunt that ghost. We will build a **linearizability tester** designed for the specific, and often overlooked, guarantees of **Monotonic Reads and Monotonic Writes**, and we will apply it to a real-world state management pattern in **Jetpack Compose**.

Why does this matter? Because the modern frontend developer is increasingly responsible for data consistency across a distributed system, without the tools to verify it. When your Android app communicates with a remote database via a REST API or a GraphQL endpoint, the state you see on screen is a local snapshot of a global, ever-changing reality. That snapshot can be stale, incomplete, or downright contradictory. If you update a user’s preferences on one device, you expect that change to be visible on another device—and to remain visible. Yet, without explicit guarantees, the system may present old data, erasing the update from the user’s perspective.

This is not a theoretical problem. Consider a collaborative editing app, a financial trading platform, or even a simple to-do list that syncs across devices. The “ghost” of stale state causes lost work, incorrect decisions, and eroded trust. And because these failures are transient and hard to reproduce, they often go untested until they manifest in production.

In this post, we will dissect the specific consistency models of **linearizability**, **monotonic reads**, and **monotonic writes**. We’ll design a deterministic tester that can simulate concurrent operations and verify whether a system satisfies these guarantees. Then, we’ll embed this tester into a Jetpack Compose state management pattern, demonstrating how to catch consistency violations before they reach users. By the end, you’ll have a practical framework for writing tests that go beyond unit tests and integration tests—you’ll be writing **consistency tests**.

Let’s begin with the foundation: what do these consistency models actually mean?

---

## Section 1: The Consistency Landscape

### 1.1 The CAP Theorem and the Trade-off Space

Before diving into monotonicity, it’s worth revisiting the CAP theorem. CAP states that a distributed data store can simultaneously provide at most two of three guarantees: **Consistency** (every read receives the most recent write or an error), **Availability** (every request receives a (non-error) response, without guarantee that it contains the most recent write), and **Partition tolerance** (the system continues to operate despite an arbitrary number of messages being dropped or delayed by the network).

In practice, partitions are inevitable, so we choose between CP and AP. Most modern distributed databases (like Cassandra, Riak, DynamoDB) lean toward AP, providing **eventual consistency**—a weak guarantee that, given enough time and no new updates, all replicas will eventually converge. But “eventually” can be milliseconds or hours. For user-facing applications, eventual consistency is often unacceptable.

However, strong consistency (linearizability) imposes a heavy cost: latencies increase, availability drops in the presence of partitions, and throughput suffers. Many systems therefore relax consistency to something weaker but still useful, such as **causal consistency**, **monotonic reads**, or **monotonic writes**. These models lie on a spectrum between eventual and linearizable.

### 1.2 Linearizability: The Gold Standard

Linearizability, as formalized by Herlihy and Wing in 1990, requires that each operation appear to take effect atomically at some point between its invocation and its completion. More intuitively: after a write completes, all subsequent reads (in real-time order) must see that write. If two writes happen concurrently, the system must choose a total order that respects the real-time precedence of non-concurrent operations.

Linearizability is the strongest consistency model for single-object operations. It is what databases like Spanner, FaunaDB, and (with some caveats) Redis Cluster provide. But it’s expensive: it requires coordination via consensus protocols (Paxos, Raft) or synchronous replication.

### 1.3 The Gap: Practical Client-Side Needs

In a typical mobile app, the client holds a local cache of data from a remote server. The remote server might itself be a distributed database with only eventual consistency. The client performs reads and writes through an API. A write may be “optimistically” applied to the local cache while the server acknowledges it asynchronously. This pattern is called **optimistic concurrency control** or **stale-while-revalidate**.

The user’s expectation is that if they see the write succeed locally, they should not later see an older version of that data. This is precisely the **monotonic reads** guarantee: once a read has observed a particular value (say, after a write), all subsequent reads must see that value or a newer one. Similarly, **monotonic writes** ensures that if a write happens, any later write by the same client will be ordered after the earlier one—i.e., writes never go back in time.

Monotonic reads and writes are weaker than linearizability because they only require ordering relative to a single client’s perspective, not a global real-time order. But they are still strong enough to prevent the “ghost” problem described in the introduction.

### 1.4 Why Jetpack Compose?

Jetpack Compose is a modern declarative UI framework for Android. State is represented by observable objects (e.g., `mutableStateOf`, `StateFlow`). When the state changes, Compose re-renders only the affected components. This makes it an ideal test bed for consistency: we can instrument the state management layer, inject simulated operations, and observe the sequence of reads that the UI performs.

If the UI sees a write, then later (due to a network race or cache invalidation) sees an older value, the UI may display inconsistent information. In a collaborative app, this could lead to data loss. By building a linearizability tester specific to monotonic reads, we can catch such violations automatically in testing.

---

## Section 2: Monotonic Reads and Monotonic Writes – Formal Definitions

### 2.1 Monotonic Reads (MR)

**Definition:** A system provides monotonic reads if, for any single client, once the client has performed a read that returns a value **v**, any subsequent read performed by the same client will return a value **v'** such that **v' ≥ v** in the version order (assuming version numbers increase monotonically with each write). In other words, reads never go backward in version history.

This definition depends on a total order of writes (or at least a partial order). In a key-value store, each key may have its own version number. A monotonic reads guarantee means that if client C reads key K and sees version 5, then later reads key K again, it must see version 5 or 6, never 4.

**Real-world example:** You update your profile picture on your phone. The server assigns version 42 to that key. Later, on your tablet, you open the profile. If the system satisfies monotonic reads, you will see version 42 (or 43 if someone else updated it). You will never see version 41.

### 2.2 Monotonic Writes (MW)

**Definition:** A system provides monotonic writes if writes performed by a single client are applied in the order they were issued. That is, if client C issues write W1 (version n) and then write W2 (version m), the system must ensure that W1 takes effect before W2 in the global version order.

This prevents a scenario where a later write is accepted by one replica but an earlier write appears later due to network reordering. In a session-based system, monotonic writes are typically ensured by requiring all writes from a session to go through a single leader or by using timestamps that reflect causal order.

**Real-world example:** You add an item to your shopping cart, then remove it. If the “remove” operation is applied before the “add” (due to latency), the final state might still have the item. Monotonic writes prevent this from happening for the same client.

### 2.3 Combined Guarantee: MR+MW

A system that provides both monotonic reads and monotonic writes ensures that from the perspective of a single client, the history of reads and writes is sequentially consistent: there is a total order that respects the client’s program order and read values are consistent with that order. This combined guarantee is often called **session consistency** or **client-side consistency**.

Many real-world systems (like Cassandra with consistency level ONE for writes and reads) do _not_ provide this. A client may issue two writes to different replicas and observe a stale read from a third replica. Building a tester for MR+MW is therefore a practical necessity.

---

## Section 3: Building a Linearizability Checker

### 3.1 The History Model

To verify monotonicity, we need a formal model of the system’s behavior. We model the system as a set of **operations**, each with:

- A **client ID** (which client performed it)
- An **operation type** (read or write)
- A **key** (the object being accessed)
- A **value** (for reads, the observed value; for writes, the written value)
- A **version** (or timestamp) assigned by the system
- A **time interval** (invocation time and response time)

The history is a set of operations with partially ordered time intervals. For client-side monotonicity, we only care about the sequence of operations **as observed by each client**. But because the system may be distributed, the order in which read values are returned can violate monotonicity even if the client’s writes are properly ordered.

### 3.2 Violations of Monotonic Reads

A violation of monotonic reads occurs when a client observes a value **v1** at time **t1**, then later at **t2 > t1** observes a value **v2** such that **v2 < v1** in version order. This is a **decreasing read**.

**Example violation trace (client A):**

```
A: Write("x", 5) -> version 1
A: Read("x") -> returns 5 (version 1)
A: Read("x") -> returns 4 (version 0)   // VIOLATION: version decreased
```

Note: The write may have been performed by the same client or a different client. The violation is about reads going backwards.

### 3.3 Violations of Monotonic Writes

A violation of monotonic writes occurs when a client issues write W1 (version n) before write W2 (version m) in real time, but the system commits W2 before W1. This is a **write reorder**.

**Example violation trace (client A):**

```
A: Write("x", 0) -> version 1 (issued first)
A: Write("x", 1) -> version 0 (issued second) // reordered
A: Read("x") -> returns 1 (version 0)
// Later, the first write arrives, causing the system to assign version 1, but then the read sees version 0? Actually the violation is that the second write's version is lower than the first's.
```

Better example:

```
A: Write("x", "hello") -> version 2
A: Write("x", "world") -> version 1   // reordered
A: Read("x") -> returns "hello"? or "world"? If the system applies them in the order it receives them, it might apply "world" first (version 1), then "hello" (version 2). Then a read might see "hello" and later "world"? That's monotonic reads fine. The MW violation is that the second write was overwritten by the first.
```

To detect MW violations, we need to track the order of writes per client and ensure that the system’s version order respects that client order.

### 3.4 The Verification Algorithm

We can implement a checker that takes a trace (list of operations with timestamps and version numbers) and returns whether MR and MW hold. The algorithm is straightforward:

**For monotonic reads:**

- For each client, iterate through its operations in real-time order.
- Maintain for each key the maximum version observed by that client so far (per key).
- For each read, if the returned version is less than the stored maximum, flag a violation.

**For monotonic writes:**

- For each client, maintain a sequence of write versions per key in the order they were issued.
- Check that the system’s commit versions (or the version order assigned by the system) are non-decreasing with respect to issue order. That is, if write i was issued before write j, then the version assigned to i must be ≤ version assigned to j (or i must be able to be ordered before j in the system’s partial order).

In practice, versions are often monotonically increasing integers assigned by the server. If the system uses vector clocks or hybrid logical clocks, we need a partial order comparison.

### 3.5 Incorporating Concurrency

A key challenge is that our checker must handle concurrency: multiple clients may be active simultaneously, and operations may overlap. Our trace should include start and end times. For monotonic reads, we consider only the real-time order of completions. For monotonic writes, we consider the real-time order of invocations (since the client issues them in that order).

We also need to handle the case where a read returns an error or a write fails – these are not part of the consistency guarantee. Typically, we treat failed operations as non-observable.

---

## Section 4: Implementing the Tester

### 4.1 Choosing a Representation

Let’s implement a simple tester in Python that can be adapted to any language. We’ll define an `Operation` class:

```python
from dataclasses import dataclass
from enum import Enum

class OpType(Enum):
    READ = 1
    WRITE = 2

@dataclass
class Operation:
    client_id: str
    op_type: OpType
    key: str
    value: any          # for writes: written value; for reads: observed value
    version: int        # version assigned by system (for reads, observed version)
    start_time: float   # real-time or logical clock
    end_time: float
```

We assume that each write operation results in a unique, increasing version per key (monotonic on the server side). This is common in databases that use a global version counter per key.

### 4.2 Building The Checker

```python
def check_monotonic_reads(history: list[Operation]) -> list[str]:
    violations = []
    # Group by client
    from collections import defaultdict
    client_ops = defaultdict(list)
    for op in history:
        client_ops[op.client_id].append(op)

    for client, ops in client_ops.items():
        # Sort by end_time (read completion)
        ops_sorted = sorted(ops, key=lambda o: o.end_time)
        max_version_per_key = {}
        for op in ops_sorted:
            if op.op_type == OpType.READ:
                key = op.key
                ver = op.version
                if key in max_version_per_key:
                    if ver < max_version_per_key[key]:
                        violations.append(
                            f"MR violation: Client {client} read key {key} version {ver} "
                            f"after having read version {max_version_per_key[key]} at earlier time."
                        )
                # Update max (even if violation, we now have a new max for next checks)
                if key not in max_version_per_key or ver > max_version_per_key[key]:
                    max_version_per_key[key] = ver
            # Writes do not affect MR directly, but they set the max version for reads if the write is observed?
            # Actually, writes are not reads; they don't count as observing a version.
            # However, if the client itself performs a write, it "knows" that version.
            # So we should treat writes as creating a new max version for that key from the client's perspective.
            elif op.op_type == OpType.WRITE:
                key = op.key
                ver = op.version
                # The client has performed a write; it expects future reads to see at least this version.
                if key not in max_version_per_key or ver > max_version_per_key[key]:
                    max_version_per_key[key] = ver
    return violations
```

Note: Including writes as setting the max version is important. If a client writes value v5, then reads back v4, that’s a violation. Some definitions of monotonic reads only apply to reads, but in practice a write is an implicit observation that the client “sees” the result. We’ll assume that.

### 4.3 Monotonic Writes Checker

```python
def check_monotonic_writes(history: list[Operation]) -> list[str]:
    violations = []
    client_ops = defaultdict(list)
    for op in history:
        if op.op_type == OpType.WRITE:
            client_ops[op.client_id].append(op)

    for client, ops in client_ops.items():
        # Sort by start_time (when the client issued the write)
        ops_sorted = sorted(ops, key=lambda o: o.start_time)
        # Check that versions are non-decreasing per key
        # Actually monotonic writes is about order of writes to the same key or overall?
        # Definition: writes from a client are applied in the order issued. For different keys, order may not matter.
        # Typically per key; but if a client writes to key A then key B, the system should preserve that order globally? Usually MW is per-key or per-session.
        # We'll assume per-key.
        last_version_per_key = {}
        for op in ops_sorted:
            key = op.key
            ver = op.version
            if key in last_version_per_key:
                if ver < last_version_per_key[key]:
                    violations.append(
                        f"MW violation: Client {client} wrote to key {key} version {ver} "
                        f"after having written version {last_version_per_key[key]} earlier."
                    )
            last_version_per_key[key] = ver
    return violations
```

This is simplified. In a real distributed system, version ordering may not be a simple integer; we might need to use happened-before relations. But the principle stands.

### 4.4 Generating Histories for Testing

To use the checker, we need to generate valid histories that a system might produce. We can write a **model** of the system under test (SUT) that simulates possible execution interleavings. This is like a **software model checker** for consistency. We define:

- A set of clients, each with a list of operations (reads/writes) to execute.
- A distributed database with multiple replicas. Replicas may have different versions of data due to propagation delays.
- A scheduler that decides the order in which operations are applied to replicas and when reads return.

The tester then explores the space of possible schedules (bounded by time or depth) and checks each resulting history for monotonicity violations. This is similar to the approach taken by toolkits like **Jepsen** (for database testing) or **Porcupine** (for linearizability checking).

For the purpose of this post, we’ll focus on the checker itself. In practice, you would hook it into your test framework.

---

## Section 5: Applying to Jetpack Compose State Management

### 5.1 The Problem: Optimistic Updates and Stale Caches

In Jetpack Compose, state is typically held in `ViewModel`s using `mutableStateOf` or `StateFlow`. A common pattern for network operations is:

1. User performs an action (e.g., toggle a switch).
2. ViewModel immediately updates the local state (optimistic update) so the UI reflects the change instantly.
3. ViewModel sends a network request to the server.
4. Upon success, the local state is either already correct or updated with the server’s response.
5. Upon failure, the local state is reverted to the previous value.

This pattern provides a responsive UI, but it introduces consistency challenges. For example:

- Multiple devices update the same resource concurrently. The server may accept one write and reject another. The optimistic local state may become stale when the server’s response arrives.
- The local state is a cache of the “source of truth.” If the cache is not properly invalidated, subsequent reads might see old values.

In Jetpack Compose, the UI re-renders reactively whenever the state changes. If the state changes from a new value back to an old value (due to a revert or stale cache), the UI may show inconsistent information. This is a **monotonic reads violation**: the UI observed the new value, then later observed an older value.

### 5.2 Designing a Consistency Test for Compose

We want to write tests that simulate multiple clients (simulated devices) performing reads and writes on shared state, and then verify that the Compose UI’s observed state (through `collectAsState()` or `mutableStateOf`) obeys monotonic reads and writes.

We can do this by:

1. **Mocking the remote server** with a controllable delay and ordering.
2. **Using a test dispatcher** to control the timing of coroutines.
3. **Observing the state changes** in the ViewModel or Composable using a `StateFlow` and recording each observation with a timestamp and version.
4. **Feeding the recorded operations** into our checker.

### 5.3 Example: A Counter App with Optimistic Updates

Consider a simple counter that syncs with a server. The ViewModel holds `counter: MutableStateFlow<Int>`. When increment button is pressed, the ViewModel immediately increments locally, then sends an HTTP POST. The server returns the authoritative counter value. If the server’s value is higher (due to another client), the local value is updated to that. If the server’s value is lower (due to race condition), the local value might be overwritten to a lower number.

This overwrite to a lower number violates monotonic reads: the UI saw, say, 5, then later sees 4. Let’s write a test for this.

```kotlin
class MonotonicCounterViewModel(private val repository: CounterRepository) : ViewModel() {
    private val _counter = MutableStateFlow(0)
    val counter: StateFlow<Int> = _counter.asStateFlow()

    fun increment() {
        val current = _counter.value
        _counter.value = current + 1  // optimistic update
        viewModelScope.launch {
            val serverValue = repository.increment()  // returns authoritative value
            // If server value is less than current, this is a non-monotonic change!
            if (serverValue != null) {
                _counter.value = serverValue
            }
        }
    }
}

// Test code using turbines or similar
@Test
fun `test monotonic reads for counter`() = runTest {
    val repo = FakeCounterRepository(delay = 100.milliseconds)
    val viewModel = MonotonicCounterViewModel(repo)
    val recorded = mutableListOf<Operation>()

    // Observe state changes
    val job = launch {
        viewModel.counter.drop(1).collect { value ->
            recorded.add(
                Operation(
                    clientId = "test",
                    opType = OpType.READ,
                    key = "counter",
                    value = value,
                    version = value, // assuming version equals value here
                    startTime = currentTime.time,
                    endTime = currentTime.time
                )
            )
        }
    }

    // Perform increment
    viewModel.increment()
    advanceTimeBy(50.milliseconds)  // before server response
    // At this point, local state should be 1
    advanceTimeBy(100.milliseconds)  // server responds with, say, 0 (if another client decremented?)
    // The server response may cause a new read of 0 (monotonic violation)

    job.cancel()

    // Run checker
    val violations = checkMonotonicReads(recorded)
    assertTrue(violations.isEmpty(), "Monotonic reads violated: $violations")
}
```

In this test, if the repository returns a value lower than the optimistic update, the recorded history will show a read of 1, then later a read of 0. The checker will flag it.

### 5.4 Handling Versioning

In the real world, the server would assign monotonic versions. We can augment our test by reading the version from the server response and embedding it in the `Operation`. This way, the checker uses versions, not raw values. For instance, if the server’s value is 5 but the internal version is 10, we compare versions.

We can also simulate concurrent clients by running multiple `ViewModel`s in parallel with different `clientId`s, each with their own state flows.

### 5.5 Advanced: Multi-Key Transactions

In more complex apps, a single UI update might involve multiple keys (e.g., user profile and settings). Monotonicity across keys is not guaranteed, but within a key it should hold. Our checker can handle per-key checks.

---

## Section 6: Testing Patterns and Results

### 6.1 Common Failure Modes

Using our tester, we can uncover several classes of failures:

1. **Optimistic update revert due to conflict resolution**: As shown, if the server uses last-write-wins (LWW) and the client rewrite loses, the UI sees a rollback.

2. **Stale cache after invalidation**: If a cache invalidation event (e.g., push notification) arrives after an optimistic update, the cache might replace the new value with an older value fetched from the server.

3. **Concurrent writes from different sessions**: A client may write from device A, then read from device B through a different session. If sessions are not tied to a consistent version order, may cause monotonic reads violation.

4. **Network retries causing duplicate writes**: If a client sends a write that is applied twice, the version number may advance but the value might revert (if the second write is the old value). That can cause read to go backward in value.

### 6.2 Integrating into CI/CD

The tester can be integrated into the build pipeline as part of a test suite. Because it is deterministic (using controlled virtual time), it is fast and reproducible. We can generate many possible schedules by randomizing the order of server responses and delays.

### 6.3 Performance Considerations

Our checker is O(n log n) for n operations, which is acceptable. However, if we explore all possible interleavings (state space explosion), we may need to use a model checker. For practical purposes, we can only simulate a few interleavings per test case, which still catches many common bugs.

---

## Section 7: Implications and Future Work

### 7.1 Beyond Monotonicity

Our tester focuses on monotonic reads and writes. But the same framework can be extended to other consistency models, such as **causal consistency** (which requires tracking happened-before relations across clients) or **regular registers** (non-atomic). The key is to plug in a different checker algorithm.

### 7.2 Real-Time Linearizability

For systems that promise linearizability, we need a different checker: one that verifies that the observed history can be linearized (i.e., there exists a total order that respects real-time and value ordering). Tools like Porcupine use the Wing & Gong algorithm or the Axo algorithm. We could adapt ours by using a generic linearizability checker that takes a specification.

### 7.3 Client-Side vs Server-Side

Our approach is client-side: we instrument the UI framework. But the same tester can be used to test server-side databases by injecting requests from a test client and recording responses. The challenges are similar.

### 7.4 The Ghost Hunted?

In the introduction, we described the ghost of stale state. With this tester, we can systematically confront that ghost. By writing consistency tests, we transform a vague fear into a concrete, checkable property. The next time your UI flips back to an old state, you’ll have a test that catches it before it ships.

---

## Conclusion

Building distributed systems is hard. Building correct client-side layers on top of them is even harder. The gap between the consistency guarantees of the backend and the expectations of the user is filled with invisible races. Monotonic reads and monotonic writes are simple, intuitive guarantees that prevent the most jarring failure: seeing old data after you’ve seen the new.

In this post, we designed and implemented a linearizability tester specifically for these monotonicity models. We wrote a lightweight checker that can work on any system that provides version numbers. Then we demonstrated how to embed it into a Jetpack Compose state management architecture, catching consistency violations during testing rather than in production.

The code we’ve written is just the start. You can adapt it to your own state management patterns (Redux, MobX, Riverpod) and your own backend (Firebase, DynamoDB, Postgres). The crucial point is to **measure your consistency** explicitly. Don’t assume your system is correct; prove it with tests.

And next time you hit save and close the app, you can do so with a little more confidence—knowing that the ghost has been exorcised by a deterministic checker.

---

_If you enjoyed this post, consider sharing it with a friend who builds distributed systems or mobile apps. The code examples are available on GitHub at [link]. Leave a comment if you’ve encountered a consistency ghost in your own projects—I’d love to hear your war stories._
