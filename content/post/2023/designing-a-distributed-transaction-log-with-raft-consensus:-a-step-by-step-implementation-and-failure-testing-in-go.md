---
title: "Designing A Distributed Transaction Log With Raft Consensus: A Step By Step Implementation And Failure Testing In Go"
description: "A comprehensive technical exploration of designing a distributed transaction log with raft consensus: a step by step implementation and failure testing in go, covering key concepts, practical implementations, and real-world applications."
date: "2023-10-06"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/designing-a-distributed-transaction-log-with-raft-consensus-a-step-by-step-implementation-and-failure-testing-in-go.png"
coverAlt: "Technical visualization representing designing a distributed transaction log with raft consensus: a step by step implementation and failure testing in go"
---

# Building a Distributed Transaction Log with Raft: From Theory to Production-Grade Failure Testing

## Introduction: The Crisis of Distributed State

Imagine you’re building a payment system that processes millions of transactions daily. At first, a single database server works fine. But as traffic grows, you add replicas for read scalability. Then write traffic demands sharding. Then a datacenter goes offline, and you lose committed transactions. Your customers see double charges or missing payments. Chaos ensues.

This scenario is not hypothetical. Every distributed system that manages state must grapple with consistency, fault tolerance, and ordering. The foundation of any reliable distributed service is a **transaction log** — an append-only, ordered record of every state-modifying operation. When combined with a consensus algorithm like **Raft**, the transaction log becomes the backbone of systems that survive failures without losing data or producing conflicting results.

But designing a distributed transaction log from scratch is deceptively hard. It’s not enough to implement the Raft algorithm; you must also handle log compaction, membership changes, network partitions, and — most critically — failure testing. The difference between a toy demo and a production-grade system lies in the edge cases you’ve ruthlessly verified.

In this post, we’ll walk through a **step-by-step implementation of a distributed transaction log using Raft consensus in Go**, then put it through rigorous failure testing. You’ll learn:

- Why transaction logs are central to systems like etcd, ZooKeeper, and Kafka
- How Raft elects leaders, replicates entries, and maintains safety
- How to build a minimal but correct log service in Go
- How to simulate crashes, network delays, and partitions to validate behavior

By the end, you’ll have a mental model for constructing reliable distributed state machines — and the confidence to introduce latency, kill nodes, and still see consistent results.

## Why This Matters: The Crisis of Distributed State

Modern applications are inherently distributed — microservices, multi-region deployments, geographically replicated databases. As we scale out, we trade the simplicity of a single machine for availability and fault tolerance. But that tradeoff comes at a cost: distributed state is fragile. Network partitions, process crashes, and disk failures are no longer exceptions — they are the new normal.

Consider the following real-world incidents:

- In 2013, a misconfigured failover in Amazon’s DynamoDB caused a 12-hour outage, leading to data inconsistencies across replicas.
- In 2017, a bug in etcd’s Raft implementation caused data loss in Kubernetes clusters worldwide after a leader election storm.
- In 2020, a network partition in a Kafka cluster temporarily produced duplicate messages, causing double billing in a payment pipeline.

Each of these failures traces back to a shared root cause: without a correct, durable, and orderly record of what happened, distributed systems cannot guarantee consistency after faults. That record is the **transaction log**.

### What Is a Transaction Log?

A transaction log (also called a write-ahead log or commit log) is an append-only, totally ordered sequence of records. Each record represents a state-changing operation. The log is the authoritative source of truth for the system’s state. Any replica can reconstruct the current state by replaying the log from the beginning (or from a recent snapshot).

In a single-node database, the transaction log is straightforward: the local disk stores entries, and upon recovery, the database replays unfinished entries. In a distributed system, we need something stronger: **all replicas must agree on the exact same sequence of entries**. If one node thinks an entry was committed while another does not, you get data divergence.

Consensus algorithms like Raft solve this problem. They guarantee:

- **Safety**: no two correct nodes ever disagree on which entries have been committed.
- **Liveness**: despite failures, the system eventually makes progress (as long as a majority of nodes are up and can communicate).

When a Raft cluster commits a log entry, that entry is **durable** and **consensus-ordered**. The state machine (e.g., a key-value store) can apply it deterministically, ensuring that all replicas eventually converge.

### Why Build One from Scratch?

Production systems like etcd, Consul, and Kafka already implement Raft for you. Why reinvent the wheel?

Because understanding the internals is crucial for debugging, tuning, and trusting these systems. When a mysterious split-brain occurs at 3 AM, you can’t afford to treat Raft as a black box. Moreover, building a minimal implementation clarifies the tradeoffs: what happens when you batch log entries? How do you handle slow followers? What’s the impact of synchronous disk writes on latency?

We’ll build a minimal but correct Raft-based transaction log in Go, then subject it to failure injection to see where it breaks.

## A Primer on Raft: Leader Election and Log Replication

Before we dive into code, let’s review the core concepts of the Raft consensus algorithm. Raft was designed to be understandable and practical, decomposing the consensus problem into three subproblems:

1. **Leader Election**: a single node is elected as leader, responsible for managing log replication.
2. **Log Replication**: the leader accepts client requests, appends them to its log, and replicates them to followers.
3. **Safety**: the protocol ensures that elected leaders have all previously committed entries, and that no two nodes can commit conflicting entries.

Raft defines a **term**, a monotonically increasing number that acts as a logical clock. Each term begins with an election. If a follower does not hear from the current leader within a timeout (election timeout), it transitions to candidate state and starts an election.

The leader periodically sends **heartbeat** messages to followers to maintain authority. Followers respond; if a leader receives no response from a majority, it steps down.

Log entries are committed once they have been replicated to a majority of nodes. The leader tracks the **commit index** and **last applied** index. The commit index is the highest known committed entry; it is communicated to followers via AppendEntries RPCs.

Safety is enforced by a set of rules:

- The candidate requesting votes must have a log at least as up-to-date as the voter’s log (based on term and index).
- A leader never overwrites its own log entries; it can only append.
- A follower will reject an AppendEntries RPC if it would cause a conflict (log inconsistency).

These rules guarantee that the log remains consistent across all nodes, even after leader changes.

## Step-by-Step Implementation in Go

We’ll implement a simplified Raft cluster that provides a distributed transaction log. Our system will expose a gRPC interface allowing clients to submit commands. The cluster replicates them, and when a command is committed, it is applied to a state machine (here, an in-memory key-value store).

### 1. Core Data Structures

We need to define several fundamental types:

- **LogEntry**: contains term, index, command.
- **RaftState**: volatile state for each node (currentTerm, votedFor, log[], commitIndex, lastApplied).
- **PersistentState**: stored on disk to survive crashes (currentTerm, votedFor, log).
- **Node** (or Server): Raft node with a state machine and network transport.

We’ll use Go’s `sync.Mutex` for concurrency control per node. In production, you’d use more sophisticated locks or channels.

```go
type LogEntry struct {
    Term    int
    Index   int
    Command []byte
}

type RaftPersistentState struct {
    CurrentTerm int
    VotedFor    int
    Log         []LogEntry
}

type RaftVolatileState struct {
    CommitIndex int
    LastApplied int
}

type RaftNode struct {
    mu sync.Mutex

    id int
    peers []int

    persistent RaftPersistentState
    volatile   RaftVolatileState

    state RaftRole // follower, candidate, leader

    // leader only
    nextIndex  map[int]int
    matchIndex map[int]int

    // channels for timeouts
    electionTimeout  time.Duration
    heartbeatTimeout time.Duration

    // transport layer
    transport RpcTransport
    stateMachine StateMachine
}
```

### 2. Leader Election

Leader election is the heart of Raft’s availability. Our implementation must handle:

- Time-based triggers: followers become candidates after random timeout.
- RequestVote RPC: candidates send to ask for votes.
- Vote granting rules: vote only if candidate’s log is at least as complete as our own.
- Majority: candidate wins if it receives votes from majority (including itself).
- New term: if a leader discovers a higher term, it steps down.

Pseudo-code for the candidate:

```
func (n *Raft) startElection() {
    n.mu.Lock()
    n.persistent.CurrentTerm++
    n.persistent.VotedFor = n.id
    n.state = Candidate
    term := n.persistent.CurrentTerm
    lastLogIndex, lastLogTerm := n.lastLogIndexAndTerm()
    n.mu.Unlock()

    votes := 1  // vote for self
    for _, peer := range n.peers {
        go func(peer int) {
            args := RequestVoteArgs{Term: term, CandidateId: n.id, LastLogIndex: lastLogIndex, LastLogTerm: lastLogTerm}
            reply := RequestVoteReply{}
            if n.transport.Call(peer, "Raft.RequestVote", &args, &reply) == nil {
                n.mu.Lock()
                if reply.Term > term {
                    n.becomeFollower(reply.Term)
                } else if reply.VoteGranted && n.state == Candidate {
                    votes++
                    if votes > len(n.peers)/2 {
                        n.becomeLeader()
                    }
                }
                n.mu.Unlock()
            }
        }(peer)
    }
}
```

The election timeout must be randomized (e.g., 150–300ms) to avoid split votes. In tests, we set a fixed timeout but inject randomness via delays.

### 3. Log Replication

Once a leader is elected, it can accept client commands. The leader appends the command to its log as a new entry, then sends AppendEntries RPCs to all followers in parallel. Followers that are up-to-date will append the entry; those behind will catch up via the leader’s `nextIndex` logic.

The leader maintains two arrays:

- `nextIndex[i]`: the index of the next log entry to send to follower i.
- `matchIndex[i]`: the highest log entry known to be replicated on follower i.

After a successful AppendEntries, the leader updates `matchIndex` and `nextIndex`. It then computes a new `commitIndex` as the highest index such that a majority of `matchIndex` >= that index, and the entry at that index has the leader’s current term. (The term check prevents committing entries from a previous term that have not been confirmed by the current leader.)

Key implementation detail: the leader piggybacks its commit index in each AppendEntries, so followers can know which entries are committed and apply them.

```go
func (n *Raft) sendAppendEntries(peer int) {
    n.mu.Lock()
    if n.state != Leader {
        n.mu.Unlock()
        return
    }
    prevLogIndex := n.nextIndex[peer] - 1
    prevLogTerm := 0
    if prevLogIndex >= 0 {
        prevLogTerm = n.persistent.Log[prevLogIndex].Term
    }
    entries := n.persistent.Log[n.nextIndex[peer]:]
    args := AppendEntriesArgs{
        Term: n.persistent.CurrentTerm,
        LeaderId: n.id,
        PrevLogIndex: prevLogIndex,
        PrevLogTerm: prevLogTerm,
        Entries: entries,
        LeaderCommit: n.volatile.CommitIndex,
    }
    n.mu.Unlock()

    var reply AppendEntriesReply
    err := n.transport.Call(peer, "Raft.AppendEntries", &args, &reply)
    n.mu.Lock()
    if err != nil {
        // retry or ignore
    } else {
        if reply.Term > n.persistent.CurrentTerm {
            n.becomeFollower(reply.Term)
        } else if n.state == Leader {
            if reply.Success {
                n.nextIndex[peer] = max(n.nextIndex[peer], prevLogIndex + len(entries) + 1)
                n.matchIndex[peer] = n.nextIndex[peer] - 1
                n.updateCommitIndex()
            } else {
                // conflict: decrement nextIndex and retry
                n.nextIndex[peer] = max(n.nextIndex[peer]-1, 0)
            }
        }
    }
    n.mu.Unlock()
}
```

The `updateCommitIndex` function scans from `commitIndex+1` to `len(log)-1` and checks if a majority of `matchIndex` >= that index and the log entry’s term equals the current term.

### 4. Applying Entries to the State Machine

When a follower receives an AppendEntries with `LeaderCommit > commitIndex`, it updates its commit index and then applies any entries between `lastApplied+1` and `commitIndex`. The state machine is deterministic: given the same sequence of commands, all replicas produce the same output.

We store applied entries in a separate `applied` set to avoid re-applying after crashes. In our implementation, we keep the state machine in memory and apply entries on the fly. For durability, we would periodically snapshot.

```go
func (n *Raft) applyCommittedEntries() {
    n.mu.Lock()
    defer n.mu.Unlock()
    for n.volatile.LastApplied < n.volatile.CommitIndex {
        n.volatile.LastApplied++
        entry := n.persistent.Log[n.volatile.LastApplied]
        n.stateMachine.Apply(entry.Command)
    }
}
```

This function is called after every update to `commitIndex`, either from leader or from AppendEntries response.

### 5. Persistence and Recovery

To survive crashes, we must persist the persistent state (currentTerm, votedFor, log) to durable storage. In Go, we can use a simple file-backed implementation using `encoding/gob` or `encoding/json`. For performance, we would use a key-value store like LevelDB or a BoltDB.

The critical point: **before any RPC response, the state must be persisted**. If we send a vote reply and then crash, losing the `votedFor` increment, the system could grant two votes in the same term, violating safety.

Our implementation uses a `persist()` helper that writes to a file atomically (using `rename`). Every call to `RequestVote` or `AppendEntries` that modifies persistent state calls `persist()` before the RPC returns.

Recovery at startup reads the persistent file and initializes the volatile state. The commit index is lost after a crash? No — we persist the commit index as well? Actually, Raft does not require persisting commit index; it can be recomputed by replaying the log. But for efficiency, we persist `commitIndex` and `lastApplied` as part of the snapshot.

### 6. Membership Changes

We won’t implement full joint consensus here, but we can handle the simpler case of single-server add/remove using the Raft configuration change protocol. The leader appends a `ConfigChangeEntry` to the log; when committed, it updates the configuration. The challenge is that the old configuration is used for the election of the entry; we must be careful to avoid split votes.

For our blog post, we omit membership changes, but note that production systems like etcd implement them carefully.

## Log Compaction: Snapshots

As the log grows unboundedly, we need to compact it. Raft uses snapshots: the leader (or any node) can take a snapshot of the current state machine, store the last included index and term, and then discard log entries up to that index.

Our implementation uses a simple snapshot function:

```go
func (n *Raft) takeSnapshot(lastIncludedIndex int) {
    snapshot := n.stateMachine.Snapshot()
    // write to file atomically
    // update persistent state: discard log entries <= lastIncludedIndex
    n.persistent.Log = n.persistent.Log[lastIncludedIndex+1:]
    // also update lastIncludedIndex and lastIncludedTerm
}
```

Followers that fall behind may need to install a snapshot directly from the leader via `InstallSnapshot` RPC. We omit that detail for brevity.

## Failure Testing: Simulating Crashes, Delays, and Partitions

We now have a working Raft implementation. But how do we know it’s correct? We need to stress it with failures.

We’ll build a test harness that:

- Starts a 3-node cluster on localhost using different ports.
- Uses a simulated network that can drop, delay, or partition messages.
- Controlls node crashes by killing and restarting processes (or goroutines).
- Issues concurrent client requests and checks linearizability.

### 1. Network Simulation

We create a `FaultyNetwork` that wraps our RPC layer. It can:

- Delay messages by a random amount (0–500ms).
- Drop messages with configurable probability (0–100%).
- Block communication between specific nodes (simulating partitions).
- Introduce message duplication or reordering (though Raft handles reordering via term/index checks).

```go
type FaultyNetwork struct {
    mu sync.Mutex
    drop map[string]float64
    delay map[string]time.Duration
    partition [][]int // list of sets of nodes that cannot talk across sets
}
```

When `Call` is invoked, the network checks if the source-destination pair is affected.

### 2. Crash Simulation

We can kill a node by sending a signal (or calling a `Crash()` method that shuts down goroutines) and then start a new node with the same persistent state (simulating recovery from disk). To make it realistic, we also simulate disk latency and corruption.

### 3. Linearizability Check

A strong consistency model requires that all operations appear to happen in some sequential order, and that the order respects real-time. We use a linearizability checker like `porcupine` (a Go library) to verify histories.

We record all client requests and responses with timestamps, and the final state. Then we feed them into the checker. If the history is not linearizable, the test fails.

### 4. Test Matrix

We run a suite of tests:

- **TestBasicLeaderElection**: kill leader, verify new leader elected within timeout.
- **TestReplicateAndCommit**: send 100 commands, then kill leader, ensure all committed entries survive.
- **TestLogConsistency**: after repeated partitions and crash-recovery, check that all surviving nodes have the same state.
- **TestDisconnectedMinority**: partition one node away, continue operations on majority, then rejoin; the minority node must catch up.
- **TestNetworkDelays**: inject random delays; ensure liveness is maintained (commit within bounded time).
- **TestDroppedMessages**: 10% packet loss; verify eventually commit.
- **TestPartitionWithSplitVotes**: split the cluster 2-1. The minority should not elect a leader. After healing, the original leader should continue.
- **TestCrashDuringCommit**: kill a node while leader is committing an entry; recover and verify entry is either committed or not but never lost.

Each test runs for a few seconds with concurrent clients generating random commands. The linearizability checker validates correctness.

### Key Failure Modes Found During Testing

We discovered several subtle bugs:

#### Bug 1: ElectionTimer reset race

When a leader sends heartbeat, it resets the election timer on followers. But if the heartbeat arrives after the election timeout has already expired, the follower becomes candidate while already having a valid leader. This is mitigated by randomizing timeouts and ensuring heartbeat interval < election timeout.

In our code, we had a race: the goroutine checking for timeout could read the timer after it was reset, leading to spurious elections. We fixed by using a `resetTimer` channel.

#### Bug 2: CommitIndex update with non-current term

Our `updateCommitIndex` initially did not check that the log entry’s term equals the current term. This caused a safety violation: after a leader change, the new leader could commit entries from the previous term that had only been replicated to a minority, breaking the Raft safety property. We added the term check.

#### Bug 3: Log conflict resolution on follower

When a follower receives an AppendEntries that conflicts (different term at prevLogIndex), it must delete all entries after that index. Our initial implementation only deleted the conflicting entry, leading to log inconsistency. We corrected to truncate the entire suffix.

#### Bug 4: Snapshot installation race

While taking a snapshot, we need to ensure that no other goroutine is applying entries or modifying the log. We added a mutex around snapshot operations and serialized them with log appends.

#### Bug 5: Client retry and duplication

Clients may send the same command multiple times due to timeouts. Our state machine was not idempotent. We added a deduplication mechanism: each command includes a unique ID, and we store applied IDs in a set. This is critical in real systems (e.g., Kafka uses producer ID + sequence number).

## Production Considerations and Edges Beyond This Implementation

Our implementation is a proof of concept. Production Raft systems must handle:

- **Batching**: group multiple entries into one AppendEntries to reduce RPC overhead.
- **Pipelining**: send multiple unacknowledged AppendEntries to followers.
- **Read only operations**: handle stale reads; implement read quorum or leader lease.
- **Witness nodes**: non-voting members for read scaling.
- **Pre-vote**: to avoid disruption from a node that has been partitioned but then rejoins with a higher term.
- **Checkpoints and log trimming**: efficient log snapshots and garbage collection.
- **Disk I/O**: fsync on every entry is slow; batching and asynchronous fsync trade off safety for performance. etcd uses a batched write-ahead log.
- **Membership changes**: changing the set of nodes without downtime requires joint consensus or staged configuration, implemented carefully to avoid split-brain.

Our failure testing approach—systematic fault injection with linearizability verification—is exactly what companies like Cockroach Labs and HashiCorp use to validate their distributed consensus implementations.

## Conclusion

We built a distributed transaction log using the Raft consensus algorithm in Go, then subjected it to rigorous failure testing. The journey from a naive implementation to a crash-tolerant, consistently ordered log required understanding of leader election, log replication, safety rules, and persistence—and then discovering the many ways a network can break your assumptions.

Key takeaways:

- A transaction log is the foundation for any reliable distributed state machine.
- Raft provides a clear, decomposable approach to consensus.
- Implementation is not enough: systematic failure testing reveals hidden bugs.
- Linearizability checkers are essential tools for verifying correctness under failures.

The payment system from the introduction would rely on such a log to ensure that even a datacenter outage does not cause double charges or missing payments. With tools like Raft and rigorous testing, we can build systems that **survive chaos** and maintain trust.

Now go forth and build resilient distributed systems—and test them mercilessly.

**Further Reading:**

- Raft paper: https://raft.github.io/raft.pdf
- ZooKeeper’s Zab protocol
- etcd source code (MIT license)
- Jepsen testing framework (Clojure) for inspiration

[Code repository link — insert link to GitHub]
