---
title: "Implementing A Distributed Key Value Store With Conflict Free Replicated Data Types (crdts)"
description: "A comprehensive technical exploration of implementing a distributed key value store with conflict free replicated data types (crdts), covering key concepts, practical implementations, and real-world applications."
date: "2025-04-01"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Implementing-A-Distributed-Key-Value-Store-With-Conflict-Free-Replicated-Data-Types-(crdts).png"
coverAlt: "Technical visualization representing implementing a distributed key value store with conflict free replicated data types (crdts)"
---

# The Conflict at the Edge: Why Your Database Can’t Handle the Real World (and How CRDTs Fix That)

_An in‑depth exploration of distributed consistency, conflict‑free replicated data types, and building a resilient key‑value store for the edge._

---

## 1. Introduction: The Illusion of a Single Truth

Imagine you are building the next great collaborative note‑taking app. A user in Tokyo is editing a document while a colleague in New York is simultaneously making changes to the same file. You want both of them to see each other’s updates in real‑time, without any flickering, lost keystrokes, or that frustrating “Version Conflict” dialog box. Now, imagine scaling this to millions of users, each with a device that might be offline, on a train, or connecting through a spotty cellular network. How do you ensure that everyone, eventually, sees the same correct, merged document? This is not just a UI challenge; it is a deep, fundamental problem in distributed systems. It is the problem of consistency in the face of network partitions, latency, and concurrent writes.

As developers, we have been trained for decades to think of databases as centralized, truth‑telling oracles. We write `UPDATE users SET name = ‘Alice’ WHERE id = 1` and trust that the database will handle the rest. We lean on transactions, locks, and linearizability—the bedrock ACID guarantees—to ensure that our data remains coherent. This model works beautifully when your entire application lives on a single server behind a single load balancer. But the internet is not a single server. It is a chaotic, asynchronous, and unreliable network of compute nodes. The moment you try to distribute this model—for high availability, low latency across global regions, or offline‑first mobile support—you run headfirst into the infamous CAP theorem.

The CAP theorem tells us a cold, hard truth: in the presence of a network partition (which is a certainty in any large‑scale system), you must choose between **C**onsistency and **A**vailability. If you choose consistency, you risk downtime during partitions; if you choose availability, you accept that different replicas may temporarily disagree on the state of the data. Most modern distributed systems—Amazon’s Dynamo, Cassandra, Riak—choose availability and eventual consistency. The price they pay is the **conflict**: two replicas may independently accept writes to the same key, and when they eventually communicate, they must somehow reconcile the diverging values.

The problem is that traditional databases give us no built‑in mechanism to handle these conflicts gracefully. The usual approach—last‑writer‑wins (LWW) based on a timestamp—is deceptively simple and often wrong. Clocks drift; network delays skew timestamps. The result is lost updates and angry users. What we need is a mathematical framework that allows replicas to accept writes independently and then merge them deterministically, without conflict, and without a central coordinator. This is exactly what **Conflict‑free Replicated Data Types (CRDTs)** provide.

In this post, we will first examine why conflict is inevitable in distributed systems, then dive deep into the theory and practice of CRDTs. We will build a minimal distributed key‑value store from the ground up, using CRDTs to ensure that every replica can accept writes and that all replicas converge to a consistent state—even under concurrent edits and network failures. Along the way, we’ll cover state‑based and operation‑based CRDTs, the famous G‑Counter, LWW‑Register, and the more complex data types needed for collaborative editing. By the end, you will have a solid understanding of how to tame the chaos of distributed state, and you’ll have the practical knowledge to start building your own edge‑native, conflict‑free systems.

---

## 2. The CAP Theorem and the Real World

### 2.1 The CAP Theorem Revisited

The CAP theorem states that a distributed data store can provide at most two of three properties: **Consistency** (all replicas see the same data at the same time), **Availability** (every request receives a non‑error response, without guarantee that it contains the most recent write), and **Partition Tolerance** (the system continues to operate despite arbitrary message loss or network failure). Because network partitions are inevitable, designers must trade consistency for availability or vice versa.

Many developers interpret this as: “choose CP or AP.” But this is too binary. In practice, most systems relax consistency to achieve high availability. They become **eventually consistent**: given enough time without new updates, all replicas will converge to the same value. The central question becomes: _how_ do they converge?

### 2.2 Why Eventual Consistency Is Hard

Consider a simple key‑value store with two replicas. A write arrives at Replica A (`x = 1`), and simultaneously a write arrives at Replica B (`x = 2`). The network between them is temporarily split. Each replica accepts its write. When the partition heals, they must decide: is `x = 1` or `x = 2`? Or something else?

Traditional systems resolve this with a **conflict resolution policy**. The most common is last‑writer‑wins (LWW) using a wall‑clock timestamp. But wall clocks are unreliable: they drift, they are not synchronized across machines, and two events can have the same timestamp. With LWW, the write with the later timestamp wins; the other is lost. This can lead to **silent data loss**, especially in highly concurrent scenarios.

Another approach is **merge on read**: when a read occurs, the system fetches from multiple replicas and applies a deterministic merge. This is used by Amazon’s DynamoDB (with application‑level conflict handlers). But it adds complexity and latency to reads. And if two replicas have diverged in complex ways (e.g., a set with concurrent additions and deletions), the merge logic can become a nightmare to implement correctly.

### 2.3 The Dream: Conflict‑Free Operation

What if we could design a data structure such that concurrent operations _always_ commute? Then there is never a conflict to resolve; every replica can accept writes and the deterministic merge across replicas yields the same final state, provided no further writes occur. This is the essence of **Conflict‑free Replicated Data Types** (CRDTs).

CRDTs were first formalized by Shapiro et al. in 2011, though earlier examples existed in systems like Bayou (1994) and collaborative editing tools (e.g., WOOT). The key insight is that by carefully designing the merge semantics of the data type, we can ensure convergence without coordination. There are two main families:

- **State‑based CRDTs (CvRDTs):** Replicas periodically exchange their entire state (or a delta) and merge it using a monotonic join operation (a semilattice). Convergence is guaranteed if the merge function is commutative, associative, and idempotent.
- **Operation‑based CRDTs (CmRDTs):** Replicas broadcast the operations they apply, and each operation is designed to be commutative. Convergence requires causal delivery (every replica sees the same set of operations in the same order, respecting causal dependencies). This is more efficient in bandwidth but requires a reliable broadcast layer.

We will explore both families in detail, but first let’s examine a simple example: a counter that can only increase.

---

## 3. The Conflict Problem: A Simple Example

### 3.1 A Distributed Counter

Imagine a distributed counter used to count the number of “likes” on a post. Two replicas, R1 and R2. Initially both have `count = 0`. Two users like the post at nearly the same time. R1 receives an increment and becomes `1`. R2 also receives an increment and becomes `1`. When they sync, how should they combine? With LWW, one increment might be lost. The correct answer is `2`. But how do we achieve that without a coordinator?

A naive approach: each replica stores the total count. But then merging requires summing? No, because if R1 = 1 and R2 = 1, summing gives 2, which is correct. But what if an increment arrives at R1 after it has already synced with R2? Then R1's state becomes 2, and R2's state is 1. Merging by summing would give 3 (incorrect). So simple summation does not work because it does not account for duplicate counts.

We need a way to ensure that each increment is counted exactly once, even if it is observed by multiple replicas. This leads to the notion of **unique identifiers** for each operation, and a data structure that can combine contributions.

The classic solution is a **G‑Counter** (grow‑only counter). It is a state‑based CRDT. Each replica maintains a vector of counters, one per replica. For example, with two replicas, R1 holds `[c_1, c_2]` and R2 holds `[d_1, d_2]`. When R1 receives an increment, it increments only its own entry: `c_1 += 1`. When merging states, each element is taken as the maximum of the two replicas’ corresponding entries: `merge(R1, R2) = [max(c_1, d_1), max(c_2, d_2)]`. The total count is the sum of the vector.

Because only the owner increments its own entry, the merge is commutative, associative, and idempotent. Concurrent increments on different replicas are captured as distinct entries, so no lost updates. This is a beautiful example of a CRDT.

---

## 4. Introduction to CRDTs: The Math of Conflict‑Free Replication

### 4.1 The Formal Definition

A CRDT is a data structure replicated across multiple nodes that satisfies the following properties:

1. **Eventual Consistency**: If no new updates are made, all replicas eventually converge to the same state.
2. **Strong Eventual Consistency (SEC)**: Any two replicas that have received the same set of updates (in any order) will have the same state. This is a stronger property than eventual consistency—it means convergence does not depend on timing but only on the set of updates delivered.

For state‑based CRDTs, SEC is guaranteed if the merge operation forms a **bounded join‑semilattice**. That is, the set of possible states has a partial order (e.g., `state A ≤ state B` if B has “more” information), and the merge (`join`) is the least upper bound of two states. The state transitions (updates) must be **monotonic**; they can only move the state forward in the partial order.

### 4.2 The Lattice Abstraction

A lattice is a partially ordered set in which every pair of elements has a unique least upper bound (join) and greatest lower bound (meet). For CRDTs, we only care about the join. The join operation is commutative, associative, and idempotent. For example, the set of integers with the usual ordering and `max` as join forms a lattice (actually a totally ordered set). The set of all possible state vectors for a G‑Counter is also a lattice, where the join is element‑wise `max`.

This mathematical foundation allows us to reason about convergence: two replicas can exchange states, apply `join`, and both will advance to a state that is at least as “up‑to‑date” as both previous states. After enough exchanges, all replicas reach the least upper bound of all updates.

### 4.3 State‑Based vs Operation‑Based

- **State‑based (CvRDT):** Replicas periodically send their full state (or delta) to each other. The merge function combines them. Advantages: no need for reliable broadcast; even if messages are lost or duplicated, idempotence ensures correctness. Disadvantages: state size can grow unboundedly (e.g., the vector in a counter grows with number of replicas); sending full state is bandwidth‑heavy.
- **Operation‑based (CmRDT):** Replicas broadcast the operations (e.g., “increment counter for client 1”) and each replica applies them. The operations must be commutative. Causal delivery (using vector clocks) ensures that if operation A happens‑before operation B, then no replica applies B before A. Advantages: small message size (just the operation). Disadvantages: requires reliable, causal‑ordered broadcast; duplicates must be handled (often via unique IDs and idempotent application).

In practice, many systems use a hybrid: send deltas (changes) instead of full state, and use operation‑based CRDTs internally. We will focus mostly on state‑based for the key‑value store implementation because it is simpler to reason about and often used in real systems like Redis CRDTs (CRDT‑enabled Redis).

---

## 5. Core CRDT Data Types

Before building a key‑value store, we need a vocabulary of CRDT types that can serve as values. We will cover the most important ones: counters, registers, sets, and maps.

### 5.1 G‑Counter (Grow‑Only Counter)

As described earlier, a G‑Counter is a vector of non‑negative integers, one per replica. Each replica only increments its own entry. The merge is element‑wise `max`. The total count is the sum.

```python
class GCounter:
    def __init__(self, replica_id, num_replicas):
        self.replica_id = replica_id
        self.payload = [0] * num_replicas

    def increment(self):
        self.payload[self.replica_id] += 1

    def value(self):
        return sum(self.payload)

    def merge(self, other):
        # element-wise max
        for i in range(len(self.payload)):
            self.payload[i] = max(self.payload[i], other.payload[i])
```

Limitation: cannot decrease. For a counter that can go up and down, we need a PN‑Counter.

### 5.2 PN‑Counter (Positive‑Negative Counter)

A PN‑Counter uses two G‑Counters: one for increments (P) and one for decrements (N). The value is `sum(P) - sum(N)`. Merge is done by merging the two G‑Counters independently.

```python
class PNCounter:
    def __init__(self, replica_id, num_replicas):
        self.p = GCounter(replica_id, num_replicas)
        self.n = GCounter(replica_id, num_replicas)

    def increment(self):
        self.p.increment()

    def decrement(self):
        self.n.increment()

    def value(self):
        return self.p.value() - self.n.value()

    def merge(self, other):
        self.p.merge(other.p)
        self.n.merge(other.n)
```

This works because concurrent increments and decrements commute. However, the value can go negative, and the state size is double.

### 5.3 G‑Set (Grow‑Only Set) and 2P‑Set (Two‑Phase Set)

A **G‑Set** is a set where elements can only be added. The merge is set union. That’s trivial.

A **2P‑Set** supports both addition and removal, but once an element is removed, it can never be added again. It consists of two G‑Sets: an “add set” (A) and a “remove set” (R). An element is in the set if it is in A but not in R. The merge combines both A and R via union. This yields a monotonic state: an element moves from “added” to “removed” but cannot go back. This may be too restrictive for many uses.

### 5.4 LWW‑Register (Last‑Writer‑Wins Register)

An LWW‑Register associates a value with a timestamp (logical or physical). On write, the new value is stored with the current timestamp. On merge, the value with the highest timestamp wins. If timestamps are equal, some deterministic tie‑breaker (e.g., replica ID) is used.

```python
class LWWRegister:
    def __init__(self, value=None, timestamp=0):
        self.value = value
        self.timestamp = timestamp

    def write(self, new_value, timestamp):
        if timestamp > self.timestamp:
            self.value = new_value
            self.timestamp = timestamp

    def merge(self, other):
        if other.timestamp > self.timestamp:
            self.value = other.value
            self.timestamp = other.timestamp
        elif other.timestamp == self.timestamp and other.value != self.value:
            # tie-break: might pick based on replica ID, but we need external ID
            raise NotImplementedError("tie-breaking needed")
```

LWW is very simple but can cause lost updates if concurrent writes have the same timestamp (which is common with wall clocks). Using logical clocks (Lamport timestamps or vector clocks) improves accuracy but increases complexity.

### 5.5 MV‑Register (Multi‑Value Register)

An MV‑Register stores a set of concurrent values. When a write occurs, it creates a new pair (value, version vector). Concurrent writes (i.e., with no happens‑before relation) are stored as multiple values. When merging, the set is the union of both replicas’ concurrent values, but after discarding any values that have been superseded (by a later version that causally dominates them). This is the model used in Amazon Dynamo. Reads return all values for the application to resolve. MV‑Registers avoid lost updates but shift conflict resolution to the application.

### 5.6 Map (e.g., RGA, LWW‑Map) for Collaborative Editing

For collaborative text editing, we need an ordered sequence (a list) that supports insert and delete at arbitrary positions, with concurrent edits. This is a major application of CRDTs. The most popular algorithms are **RGA** (Replicated Growable Array) and **LWW‑Element‑Set** based maps. They assign each character a unique identifier (e.g., a (replica, sequence number) pair) and maintain a graph of causal relationships. When two users insert at the same position, the merge orders the inserts deterministically (e.g., by (replica_id, seq)). Deletions are marked with tombstones.

These are complex, and we won’t implement a full text‑editing CRDT here, but we note that they are built on the same lattice principles.

---

## 6. Building a Distributed Key‑Value Store with CRDTs

Now we will design and implement a toy distributed key‑value store where each key’s value is a CRDT. The store will have multiple replicas, each able to accept writes and reads locally. Replicas will periodically gossip to exchange state (or merge deltas).

### 6.1 Architecture Overview

- **Replica**: A node that holds a local map from keys to CRDT instances.
- **Client API**: `get(key)`, `put(key, crdt_op)` where `crdt_op` is an operation specific to the CRDT (e.g., `Increment`, `Write` with value and timestamp).
- **Gossip protocol**: Each replica periodically selects a random neighbor and sends its entire local state (or delta). The neighbor merges the received state into its own.
- **Merge function**: For each key, the CRDT merge operation is applied.

We will implement a simplified version in Python, using a hypothetical network layer (just function calls for simulation).

### 6.2 Defining CRDT Interfaces

We first define an abstract base class for all CRDTs:

```python
from abc import ABC, abstractmethod

class CRDT(ABC):
    @abstractmethod
    def merge(self, other: 'CRDT') -> None:
        pass

    @abstractmethod
    def state(self) -> bytes:
        # serialize for network transfer
        pass

    @classmethod
    def from_state(cls, data: bytes) -> 'CRDT':
        pass
```

### 6.3 A Generic Key‑Value Replica

```python
class KVReplica:
    def __init__(self, replica_id, known_peers):
        self.replica_id = replica_id
        self.data = {}  # key -> CRDT instance
        self.peers = known_peers

    def local_put(self, key, crdt_value: CRDT):
        # directly store or merge if key exists
        if key in self.data:
            # for simplicity, assume operation is a merge of a new CRDT
            # but typically we apply a mutation on the existing CRDT
            # This method is for initial assignment or complete replacement?
            # Better: define operations as functions on CRDTs.
            # For this demo, we'll have a separate apply method.
            pass
        else:
            self.data[key] = crdt_value

    def apply(self, key, operation, *args):
        # operation is a string like 'increment', 'write'
        crdt = self.data.get(key)
        if crdt is None:
            # create a default CRDT based on type? Not easy.
            raise KeyError(f"No CRDT for key {key}")
        # dispatch to the method (simplified)
        getattr(crdt, operation)(*args)

    def read(self, key):
        return self.data.get(key)

    def merge_state_from(self, remote_state: dict):
        for key, remote_crdt in remote_state.items():
            if key in self.data:
                self.data[key].merge(remote_crdt)
            else:
                self.data[key] = remote_crdt

    def get_full_state(self):
        return dict(self.data)  # shallow copy

    def gossip(self):
        # select a random peer (simulate)
        import random
        peer = random.choice(self.peers)
        state = self.get_full_state()
        peer.merge_state_from(state)
```

### 6.4 Example: Distributed Counter Service

Let’s use `PNCounter` as the value type for a key `"likes"`. Two replicas, each can increment or decrement locally.

```python
# Setup
r1 = KVReplica(0, [])
r2 = KVReplica(1, [])
r1.peers = [r2]
r2.peers = [r1]

# Initialize "likes" with a PNCounter for each replica
initial_pnc1 = PNCounter(0, 2)  # replica_id=0, num_replicas=2
initial_pnc2 = PNCounter(1, 2)  # replica_id=1, num_replicas=2

r1.data["likes"] = initial_pnc1
r2.data["likes"] = initial_pnc2

# Two users concurrently increment on different replicas
r1.apply("likes", "increment")   # r1: count=1
r2.apply("likes", "increment")   # r2: count=1

# Sync
r1.gossip()  # r2 merges from r1
r2.gossip()  # r1 merges from r2 (now both should have total 2)

print(r1.read("likes").value())  # 2
print(r2.read("likes").value())  # 2
```

### 6.5 Handling Deletions: Tombstones

What if we want to delete a key? In a CRDT‑based store, deletion is not straightforward because the state is monotonic (we only add information). To support deletion, we can use a **Tombstone** approach: keep a separate set of deleted keys. When a key is deleted, we move its state to a tombstone but remember it so that if a replica later receives a stale insert, it knows the key was already deleted. Alternatively, we can use an LWW‑Register with a special “tombstone” value and let LWW overwrite it. However, this does not reduce state size; the tombstone persists forever.

A more practical approach is to use an **Observed‑Remove Set** (OR‑Set) which we won't detail here – it allows removal without tombstones for the elements, but tombstones are still needed for the per‑element metadata.

For simplicity, we will not implement key deletion in our toy store.

### 6.6 A More Realistic Implementation: Using Deltas

Sending full state on every gossip is expensive. **Delta‑CRDTs** allow replicas to send only the changes (deltas) that have occurred since the last sync. The delta is itself a CRDT state that can be merged. This is implemented by storing a **delta‑state** and sending it along with a **version vector** indicating which updates were already delivered.

We won’t implement delta‑CRDTs here, but the concept is important for production systems.

---

## 7. Advanced Considerations and Challenges

### 7.1 Causal Consistency and Vector Clocks

CRDTs do not, by themselves, guarantee causal consistency. For state‑based CRDTs, merging is commutative, so causality is irrelevant – all replicas converge regardless of order. However, for operation‑based CRDTs, causal delivery is required; otherwise a replica might apply an operation before its cause, leading to an invalid state. Causal delivery can be implemented using vector clocks.

### 7.2 Garbage Collection and Tombstones

Many CRDTs accumulate metadata (e.g., vector entries, tombstones for removed elements) that grows with the number of replicas or operations. For a long‑running system, this is unsustainable. Techniques include:

- **Garbage collection**: Once all replicas have observed an update, the metadata for that update can be pruned. This requires a distributed agreement on which updates are “globally known”.
- **Compaction**: In LWW‑Registers, we can discard overwritten values. In counters, we can periodically reset the vector by synchronizing all replicas and then converting to a single integer (e.g., using a consensus round).

### 7.3 Performance Overhead

CRDTs add computational and storage overhead. For a simple counter, the state is a vector of size N (number of replicas). In a system with thousands of replicas, this becomes prohibitive. Solutions:

- Use a **counters with a single integer plus a vector of pending increments**? No, that breaks commutativity.
- Use a **two‑layer CRDT**: a per‑replica counter is combined with a global sum that is periodically consolidated using a consensus algorithm (like Raft). This hybrid approach reduces metadata size while maintaining availability.

### 7.4 Deterministic Merge and Application Semantics

The merge function must be deterministic across all replicas. This is usually guaranteed by mathematical design, but when combining different CRDT types (e.g., a map of sets), the interaction must be carefully defined.

One common pitfall: using wall‑clock timestamps in LWW‑Registers leads to non‑deterministic ties. Always use a logical clock (Lamport timestamp + replica ID) to break ties deterministically.

### 7.5 Real‑World Systems

- **Redis CRDTs**: Redis 7.0 introduced an active‑active geo‑replication model using CRDTs for certain data types (strings with LWW, sets with observed‑remove, etc.). This allows writes on any replica without conflict.
- **Riak**: The Riak distributed database uses CRDTs for a variety of data types (counters, sets, maps) to provide eventually consistent conflict resolution.
- **Automerge** and **Yjs**: JavaScript libraries for collaborative editing that implement RGA and LWW‑Map CRDTs, powering tools like Microsoft Loop and others.
- **DynamoDB**: Uses a form of MV‑Register (with vector clocks) and application‑level conflict resolution; not a pure CRDT but similar principles.

---

## 8. Practical Use Cases

### 8.1 Collaborative Document Editing

The classic use case. Each character is an element in a CRDT list (e.g., RGA). Concurrent insertions are merged deterministically; concurrent deletions are handled with tombstones. Libraries like Automerge allow offline editing; when devices reconnect, they merge their CRDT states without conflict.

### 8.2 Offline‑First Mobile Apps

A note‑taking app where users can add, delete, and reorder notes on a phone even without internet. When connectivity returns, the app syncs with the server using CRDTs. The server is just another replica. No conflict dialogs; the merge is automatic.

### 8.3 Distributed Leaderboards

A game with global leaderboard scores. Each player’s score is a PN‑Counter on multiple regional servers. Players can update their score on any server; the counters will converge.

### 8.4 IoT Sensor Aggregation

Sensors send readings to edge gateways. Multiple gateways may receive the same sensor data due to network redundancy. Using a G‑Counter, the total count of events can be correctly aggregated despite duplicates, if each sensor uses a unique replica ID and increments only its own counter.

---

## 9. Challenges and Pitfalls

### 9.1 Complexity of Merge Semantics

When combining different CRDT types (e.g., a register inside a map), the merge logic becomes nested. It’s easy to introduce subtle bugs where merges are not idempotent or commutative. Formal verification or using well‑studied libraries is recommended.

### 9.2 Performance Overhead of Metadata

As discussed, tombstones and vector entries grow. In a long‑running collaborative editing session, the metadata may exceed the actual text content. Recent research on “compressible CRDTs” and “delta‑state” helps, but it’s still a work in progress.

### 9.3 Network Overhead of State Transfer

In state‑based CRDTs, sending full state is expensive. Even with deltas, the average delta size can be large if many changes happen concurrently. Using a gossip protocol with epidemic spread can reduce bandwidth but increases latency.

### 9.4 Deterministic Merge Requirement

Any non‑determinism in the merge (e.g., using random numbers) will break convergence. The system must have a deterministic algorithm that all replicas follow.

### 9.5 Lack of Causality for LWW

Last‑writer‑wins ignores causality: a later‑timestamped write might overwrite an earlier write that was causally related but had a smaller timestamp. This can lead to semantic surprises. For example, a user edits a field to “A”, then later edits to “B”, but due to clock skew, another user’s concurrent edit to “C” might have a later timestamp and overwrite “B”. The user’s intended final value “B” is lost. This is why many practitioners prefer MV‑Registers or CRDTs that preserve causal history.

---

## 10. Conclusion: Embracing the Chaos

We started with the painful reality that distributed systems cannot behave like a single database. Network partitions, high latency, and concurrent updates force us to choose between consistency and availability. The traditional approach of centralized transaction processing breaks down at the edge.

CRDTs offer a principled way out of this dilemma. By designing data structures that are monotonic and commutative, we can achieve strong eventual consistency without coordination. Each replica can accept writes independently; the system converges automatically when replicas exchange state.

We built a simple distributed key‑value store around CRDTs, using counters, registers, and sets. We saw that the approach is elegant for data types that fit the lattice model—counters, sets with add‑only or add‑remove with tombstones, and registers with version vectors. For more complex structures like collaborative text, specialized CRDTs like RGA work in production.

The challenges remain: handling large metadata, reliable causal delivery for operation‑based CRDTs, and efficient delta transfers. But the field is active, and production systems like Redis and Yjs prove that CRDTs are not just academic curiosity—they are a viable architecture for building global‑scale, offline‑first applications.

The next time you plan a system that requires high availability, global replication, or offline mode, consider using CRDTs. They won’t solve every problem (you still need to think about garbage collection, and some data types are inherently anti‑commutative), but they will free you from the tyranny of conflict dialogs and lost updates.

**Further Reading:**

- Shapiro, M., Preguiça, N., Baquero, C., & Zawirski, M. (2011). _Conflict‑Free Replicated Data Types_.
- Letia, M., Preguiça, N., & Shapiro, M. (2009). _CRDTs: Consistency without Concurrency Control_.
- Automerge (https://automerge.org/)
- Redis CRDTs documentation (https://redis.io/docs/latest/operate/oss_and_stack/stack-with-enterprise/active-active/)
- Yjs (https://yjs.dev/)

_Now go build something that doesn’t break under partition._
