---
title: "Using Linearizability Checking Tools: How To Prove Your Concurrent Data Structure Is Correct"
description: "A comprehensive technical exploration of using linearizability checking tools: how to prove your concurrent data structure is correct, covering key concepts, practical implementations, and real-world applications."
date: "2025-05-03"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Using-Linearizability-Checking-Tools-How-To-Prove-Your-Concurrent-Data-Structure-Is-Correct.png"
coverAlt: "Technical visualization representing using linearizability checking tools: how to prove your concurrent data structure is correct"
---

# The Blinking Red Light: Why Your Concurrent Data Structure Needs a Polygraph

## Part 1 – The Nightmare of Unprovable Correctness (Expanded)

It’s 3:00 AM. You are staring at a terminal, watching a log file scroll by. The system is experiencing a "Heisenbug"—a bug that only appears in production, under load, and vanishes the moment you try to attach a debugger. Your distributed cache, the heart of your microservice architecture, is returning stale data. Not always. Just sometimes. Just enough to cause a cascade of downstream failures, billing errors, or inconsistent user sessions.

You’ve checked the locks. You’ve reviewed the code until your eyes burn. You’ve written unit tests that pass every time. But the production cluster is a chaotic, asynchronous universe where operations interleave in ways your single-threaded mind can never fully simulate. This is the nightmare of concurrent programming: not just getting it to work, but _proving_ it is impossible to break.

This is where we must leave the world of "testing" and enter the world of _verification_. And at the heart of that verification for modern distributed systems lies a single, deceptively simple concept: **Linearizability**.

### The Illusion of a Single Machine

Before we dive into the tools, we need to understand the property they are chasing. Imagine you have a simple integer variable in a single-threaded Java program. Operations are atomic: you read, you write, you increment. The history is a clean, linear sequence. You write 1, then you read 1.

Now, take that same variable and spread it across three different servers in three different data centers. Client A writes `x = 1` in New York. Client B writes `x = 2` in London. Client C reads `x` in Tokyo. What does Client C get?

In a purely asynchronous system, the answer could be: 0 (the initial value), 1, or 2. This ambiguity is the root of all concurrency evil.

**Linearizability** is the strongest consistency guarantee for concurrent operations on a shared object. It formalizes the intuition that every operation should appear to take effect instantaneously at some point between its invocation and its response. In other words, the entire system behaves as if there is a single, global, ordered timeline where all operations are atomic. This property was first precisely defined by Herlihy and Wing in their seminal 1990 paper _"Linearizability: A Correctness Condition for Concurrent Objects"_. The idea is simple but profound: no matter how many threads or nodes are involved, the observable results should be indistinguishable from a sequential execution that respects the real-time ordering of non-overlapping operations.

But linearizability is more than just a theoretical nicety. It is the foundation upon which we build databases (e.g., Spanner, etcd, ZooKeeper), distributed locking, and concurrent data structures. Without it, your system may appear to work in testing but silently produce incorrect results under concurrent stress. And as any veteran distributed systems engineer will tell you, those silent corruptions are the most dangerous bugs of all.

---

## Part 2 – A Formal Walk Through the Looking Glass

Let’s put a little mathematical flesh on the concept. A _history_ is a sequence of _invocation_ and _response_ events for operations on a set of objects. Each operation has an invocation time and a response time. Two operations are _concurrent_ if their intervals overlap in real time. A history is _linearizable_ if it can be extended (by adding empty operations or reordering concurrent ones) into a _legal sequential history_ that respects two constraints:

1. **Real-time order**: If operation A completes before operation B starts, then A must appear before B in the sequential order.
2. **Object semantics**: The sequential history must be legal according to the specification of the object (e.g., a read must return the last written value).

Herlihy and Wing proved that linearizability is a _local property_: a history is linearizable if and only if each individual object’s history is linearizable. This compositionality is crucial – it means we can build complex systems by composing linearizable objects, and the whole remains linearizable.

But the real power of linearizability lies in what it _prevents_. Consider the following classic example:

```go
// Shared register (initially 0)
Write(1)  // Thread A at time 0–2
Write(2)  // Thread B at time 1–3
Read()    // Thread C at time 2.5–3.5
```

A non-linearizable history might allow `Read()` to return 0, even though both writes completed before the read started? No, because real-time order would force the read to see at least the last write that finished before it started. But concurrent writes can lead to anomalies. If the read overlaps with writes, it could return 0, 1, or 2. Linearizability demands that there exists a point in the read’s interval where the value _becomes_ one of those. For example, if the system linearizes at time 2.8, then the read might see 1 if the first write was linearized before 2.8, and the second after. But the read must be consistent with a sequential, atomic snapshot.

One of the most common misunderstandings is that linearizability is the same as **sequential consistency**. They are not. Sequential consistency (also defined by Lamport) requires that operations of each processor appear in program order, but it does _not_ require that operations are ever visible to others in real-time order. In a sequentially consistent system, a write that completed before another process’s read can still be invisible to that read, as long as there is some global interleaving that respects per-process program order. Linearizability adds the real-time clock constraint, making it strictly stronger. This extra tightness is what makes it so valuable for reasoning about distributed systems: it gives clients a strong intuitive model akin to a single server.

---

## Part 3 – When Systems Fail: The Taxonomy of Broken Guarantees

Why should a practicing engineer care about the formal distinction? Because the real world is full of systems that _claim_ to provide strong consistency but actually offer something weaker under load. Let’s examine a few concrete failure modes.

### Stale Reads in Eventually Consistent Databases

Dynamo-style databases like Cassandra or Riak offer _eventual consistency_ by default. Under normal operation, a read might return a value that is several seconds out of date. This is not a bug; it’s a design choice. But if you write code that assumes linearizability (e.g., a compare-and-swap lock), you will get nasty surprises. A classic example: “read your writes” – if you write a key and immediately read it back from a different replica, you might not see your own write. Linearizability guarantees a read always sees the most recent write that completed before the read started. Without it, you need explicit quorum settings (e.g., `CONSISTENCY ALL`) to force linearizability, at the cost of latency and availability.

### Lost Updates in Concurrent Counters

Consider a distributed counter implemented with three replicas. Client A reads the counter (value 0), increments it locally, and writes 1. Client B reads the counter (value 0), increments, and writes 1. Both writes succeed, but the final value is 1, not 2. This is a _lost update_. In a linearizable system, write operations would be serialized, and the second write would see the first’s result, producing 2. Without linearizability, you need a compare-and-swap or a distributed lock.

### Phantom Writes and Causal Violations

In a microservice architecture, services communicate asynchronously via message queues. A typical anti-pattern: Service A writes a record to database X, then sends an event to Service B. Service B reads the event and then reads from database X, expecting to see the record. If the database is not linearizable, the read might miss the write, causing a _causality violation_. Linearizability ensures that if the event is received after the write completes, any subsequent read will see the write.

These failures are not hypothetical. The MongoDB team discovered that their pre-2.6 “safe” write concern was not actually linearizable under certain partitioning scenarios, leading to lost acknowledged writes. The Jepsen project, maintained by Kyle Kingsbury, has catalogued dozens of such bugs in widely used systems (etcd, Redis, PostgreSQL, etc.). In every case, the root cause was a subtle violation of linearizability.

---

## Part 4 – How to Test for Linearizability: A Practical Guide

You can’t just _assert_ linearizability; you need to verify it. But how do you test for a property that requires reasoning about all possible interleavings? There are two broad approaches: **model checking** and **statistical testing**.

### Model Checking with TLA+ or Alloy

The gold standard for proving linearizability of an algorithm is to write a formal specification in a language like TLA+ (Temporal Logic of Actions) or Alloy. The model checker exhaustively explores all possible state transitions and finds violations. For example, the Raft consensus algorithm’s safety was verified using TLA+ before it was deployed. However, model checking is expensive – the state space explodes exponentially with the number of nodes and operations. It is best suited for small numbers of replicas and short histories.

### Statistical Testing with Jepsen

Jepsen is a library and framework for testing distributed systems by generating concurrent operations and checking whether the resulting history is linearizable. It works as follows:

- A control node sends a sequence of operations (reads, writes, compares) to the system under test.
- Each operation is timestamped with a logical clock (or wall clock, though this is fragile).
- The system returns responses, and Jepsen records the history.
- After the test, Jepsen uses a _linearizability checker_ (like Knossos, a Go library for verifying linearizability of small histories) to see if there exists a legal sequential order that respects the real-time order of non-overlapping operations.

Knossos is based on the Wing-Gong algorithm, which reduces the problem to checking whether a set of operations can be linearized. It’s efficient for hundreds of operations, but not for millions. For larger tests, Jepsen sometimes uses a _statistical_ approach: it checks only a sample of histories, or uses a _saturation_ test (e.g., run many concurrent operations and look for anomalies like stale reads).

Here is a simplified example of a Jepsen test for a key-value store:

```clojure
(defn test-linearizability [test]
  (let [history (atom [])]
    (with-threads [threads (for [i (range 10)]
                             (thread (dotimes [_ 100]
                                       (let [op (rand-nth [:read :write])
                                             k (rand-int 10)
                                             v (rand-int 100)]
                                         (swap! history conj
                                                {:type :invoke, :value v, :key k}
                                                {:type (if (= op :read) :ok :ok)
                                                 :value v}
                                                )))))]
      (await-threads threads)
      (is (linearizable? @history test)))))
```

This is a toy example. Real Jepsen tests involve complex setup and tear-down of clusters, network partitions, and clock skew injection.

### Porcupine: A Modern Linearizability Checker

A more recent tool is Porcupine, a Go library for testing linearizability of concurrent objects. It can handle larger histories than Knossos by using a smarter search algorithm. Porcupine is used by Cockroach Labs and others to verify correctness of their distributed transaction protocols.

```go
import "github.com/anishathalye/porcupine"

// Define the operation types: read, write, cas
type op struct {
    typ string // "read", "write", "cas"
    key string
    val int
}

// Model of a key-value store
func registerModel(ops []op) porcupine.Model {
    state := make(map[string]int)
    return porcupine.Model{
        Init: func() interface{} { return state },
        Step: func(state interface{}, input interface{}, output interface{}) bool {
            // ...
            return true // or false if illegal
        },
    }
}
```

The checker returns `true` if the history is linearizable, `false` otherwise, and can provide a counterexample trace.

### When Testing Is Not Enough

One crucial insight: linearizability testing is **NP-complete** in general. The number of possible orderings grows factorially with the number of operations. Therefore, real-world checkers can only handle small histories (typically < 500 operations). For production systems, we rely on a combination of:

- Formal verification of the underlying consensus algorithm.
- Exhaustive simulation for small configurations.
- Integration tests with Jepsen for moderate histories.
- Runtime invariants (e.g., monotonic clocks, version vectors).

Even then, bugs can escape. The 2014 MongoDB disaster happened after extensive testing because the bug only manifested under a specific partition scenario and a precise interleaving of operations.

---

## Part 5 – Building Linearizable Systems: Consensus and Beyond

Now that we understand what linearizability is and how to test for it, let’s examine how to _build_ a linearizable storage system. The core technique is **distributed consensus** – an algorithm that allows a set of nodes to agree on a total order of operations. The most famous consensus algorithms are Paxos, Raft, and Zab (used by ZooKeeper). They all provide linearizable updates.

### Raft’s Linearizable Reads

Raft ensures that every write is committed to a majority of nodes, and all nodes see the same log order. Reads can be performed in two ways:

1. **Leader-based reads**: The leader reads its own state. This is safe because the leader has the most up-to-date committed entries. However, a stale leader might serve outdated data if it has been partitioned but still thinks it’s leader. To prevent this, Raft requires the leader to contact a majority before serving a read (a _heartbeat check_). This is called **linearizable reads** in Raft.

2. **Follower reads**: Follower nodes may be behind the leader. To achieve linearizability from a follower, the follower must verify that its state is at least as recent as the leader’s committed index. This is done by the follower asking the leader for a _commit index_ and waiting until its own log has that entry.

The etcd implementation of Raft provides a `serializable` mode for reads (fast but not linearizable) and a `linearizable` mode (slower but correct). Choosing the wrong mode can lead to the stale read problems described earlier.

### The Cost of Linearizability: Latency and Availability

Linearizability comes at a price. In a geo-distributed system, a linearizable write must be acknowledged by a majority of nodes, which can incur high latency (e.g., 200 ms cross-continent). Furthermore, during a network partition, a linearizable system might become unavailable on one side of the partition because a majority cannot be formed. This is the CAP theorem: consistency (linearizability) and availability are traded off when partitions occur.

Many modern systems offer _configurable consistency_: you can choose linearizable for critical operations (e.g., leader election, banking transactions) and eventually consistent for read-heavy workloads (e.g., product catalog).

### Alternatives to Linearizability

Not every problem needs linearizability. **Causal consistency** is a weaker model that still prevents causal violations but allows concurrent operations to be seen in different orders by different nodes. **Snapshot isolation** (used in databases like PostgreSQL with MVCC) offers a consistent snapshot but allows write skew. **Serializability** is even stronger than linearizability (it includes multi-object transactions), but is more expensive. The choice depends on your application’s tolerance for inconsistency.

---

## Part 6 – Case Study: The MongoDB 2.6 Bug

In 2014, MongoDB released version 2.6, which introduced a new “write concern” called `w: "majority"`. The intention was to provide strong consistency: a write would only be acknowledged after a majority of replicas had committed it. However, Jepsen testing revealed that under a network partition that isolated the primary from a subset of secondaries, MongoDB could acknowledge a write that later disappeared.

The root cause was a complicated interaction between the election algorithm and the write concern implementation. In particular:

- The primary wrote the data to its own storage and to the secondaries.
- If the primary was partitioned, a new primary could be elected that had not received the write.
- The original primary, when it reconnected, would roll back its “acknowledged” writes, making them vanish.

This violated linearizability because a client that received an acknowledgment believed the write was durable, but later reads could not see it. The bug was eventually fixed in MongoDB 3.0 by introducing a _commit quorum_ that requires a majority of voting members to persist the write before acknowledging.

This story highlights a critical point: **just because you use consensus doesn’t guarantee linearizability**. Implementation details matter immensely. The only way to be sure is rigorous testing – and Jepsen’s linearizability checker was what exposed the flaw.

---

## Part 7 – Implementation Insights: Building Your Own Linearizable Object

Suppose you want to build a linearizable distributed counter (or any shared mutable state) from scratch. How would you do it? The simplest approach is to run a single server (a _sequencer_) that handles all operations atomically. This is linearizable by construction, but it’s a single point of failure and bottleneck.

Alternatively, you can use **state machine replication** (SMR) with a consensus layer. Each replica runs the same deterministic state machine. Operations are submitted to the consensus module, which orders them and delivers them to all replicas in the same order. Because the state machine is deterministic, all replicas converge to the same state. Clients can read from any replica that has applied the most recent operation, but they must ensure they read the latest committed state.

Here is a simplified Go-like pseudocode for a linearizable register using Raft:

```go
type LinearizableRegister struct {
    raft *RaftNode
    state int
    mu    sync.Mutex
}

func (r *LinearizableRegister) Write(val int) error {
    cmd := &WriteCommand{Value: val}
    // Propose to Raft; blocks until committed and applied
    response := r.raft.Propose(cmd)
    return response.Err
}

func (r *LinearizableRegister) Read() (int, error) {
    // Linearizable read: ask leader to confirm it's still leader
    r.mu.Lock()
    defer r.mu.Unlock()
    if !r.raft.IsLeader() {
        return 0, errors.New("not leader")
    }
    // Leader sends a no-op to majority to ensure up-to-date
    if err := r.raft.Heartbeat(); err != nil {
        return 0, err
    }
    return r.state, nil
}
```

Note that the read operation must still go through a round of communication with a majority to guarantee linearizability. This is why linearizable reads are expensive.

---

## Part 8 – The Future: Linearizability in Serverless and Edge Computing

As systems move toward serverless architectures and edge computing, the need for linearizability becomes more acute – and harder to achieve. Functions are ephemeral, state is distributed, and network latency is high. Companies like Amazon (with AWS Lambda and DynamoDB) and Google (with Cloud Spanner) have invested heavily in providing linearizable operations, but they come with constraints.

Spanner uses TrueTime, a globally synchronized clock, to assign commit timestamps and guarantee external consistency (a form of linearizability across transactions). This requires special hardware (GPS clocks and atomic clocks in each datacenter). Most applications cannot afford such infrastructure.

The alternative is to avoid the need for linearizability altogether by designing systems that tolerate weaker consistency. For example, using **conflict-free replicated data types** (CRDTs) allows concurrent updates to merge without coordination, sacrificing linearizability for availability. However, CRDTs are limited in expressiveness (e.g., no atomic compare-and-swap over multiple keys).

I believe we will see a spectrum: linearizability for small, critical state (like leader leases, metadata, tokens) and weaker models for bulk data.

---

## Part 9 – Conclusion: The Polygraph Test

The blinking red light in your production logs is a sign that your concurrent data structure needs a polygraph – a formal verification of its claims to correctness. Linearizability is the gold standard for that verification. It transforms the vague notion of "consistency" into a testable, provable property.

But remember: linearizability is not a magic bullet. It is expensive, hard to achieve, and often unnecessary. The key is to identify which parts of your system _must_ be linearizable – the critical sections where concurrent operations could cause irreparable harm – and apply the tools (consensus, formal verification, Jepsen testing) accordingly.

The next time you stare at a 3 AM log file, ask yourself: “Is this operation linearizable?” If you can’t answer confidently, it’s time to bring in the polygraph.

---

## Further Reading

- _Linearizability: A Correctness Condition for Concurrent Objects_ – Maurice Herlihy and Jeannette Wing, 1990.
- _Jepsen: Distributed Systems Safety Analysis_ – Kyle Kingsbury.
- _Raft: In Search of an Understandable Consensus Algorithm_ – Diego Ongaro and John Ousterhout.
- _Porcupine: A Fast Linearizability Checker_ – Anish Athalye.
- _Consensus: Bridging Theory and Practice_ – Diego Ongaro (PhD thesis).

_Thanks to the distributed systems community for making correctness a first-class concern._
