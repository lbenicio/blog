---
title: "Implementing A Distributed Consensus Protocol From Scratch: Raft With Leader Election, Log Replication, Membership Changes, And Cluster Reconfiguration In Go"
description: "A comprehensive technical exploration of implementing a distributed consensus protocol from scratch: raft with leader election, log replication, membership changes, and cluster reconfiguration in go, covering key concepts, practical implementations, and real-world applications."
date: "2019-01-01"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/implementing-a-distributed-consensus-protocol-from-scratch-raft-with-leader-election,-log-replication,-membership-changes,-and-cluster-reconfiguration-in-go.png"
coverAlt: "Technical visualization representing implementing a distributed consensus protocol from scratch: raft with leader election, log replication, membership changes, and cluster reconfiguration in go"
---

# From Theory to Implementation: Building a Complete Raft Consensus Protocol in Go

## Introduction: Why Build a Consensus Protocol from Scratch?

Imagine you’re responsible for a critical service that must be available 24/7—a distributed database, a coordination system like etcd or Consul, or a replicated state machine that powers a bank’s transaction ledger. You have multiple servers, but any of them can crash, become unreachable, or suffer from network partitions. The challenge is to keep these servers in sync, even when failures happen. How do you ensure that all replicas agree on the same sequence of operations, that no two replicas decide different values for the same slot, and that the system continues to operate correctly despite a minority of nodes being down?

This is the essence of **distributed consensus**—one of the most fundamental and notoriously difficult problems in computer science. Without a correct consensus algorithm, distributed systems are prone to split-brain scenarios, data loss, and inconsistent states. The most famous family of algorithms that solves this problem is Paxos, but its reputation for being notoriously hard to understand and implement has driven the search for simpler alternatives. Enter **Raft**.

Raft was designed with a single, explicit goal: _understandability_. Published by Diego Ongaro and John Ousterhout in 2014, Raft decomposes the consensus problem into relatively independent subproblems—leader election, log replication, safety, and membership changes—and presents clear, modular mechanisms for each. Its practical success is undeniable: it powers the backbone of some of the most widely used distributed systems today, including etcd (Kubernetes’ key-value store), Consul, and many others.

But there’s a world of difference between _using_ a Raft implementation and _building_ one from scratch. This blog post is about that world. I’ll walk you through implementing a complete Raft consensus protocol in Go, covering not just the core mechanics, but also the often-ignored complexities of membership changes and the subtle interactions between cluster topology changes and existing consensus guarantees.

We’ll start with a minimal, working leader election and log replication engine, and then progressively layer in persistence, snapshotting, and dynamic cluster membership. By the end, you’ll have a production‑ready, single‑process Raft library that you can embed in your own distributed applications. Along the way, we’ll explore the design decisions, edge cases, and debugging techniques that separate a toy implementation from a robust one.

---

## 1. Raft in a Nutshell: Key Concepts and Terminology

Before diving into code, let’s refresh the core Raft concepts. Raft operates in **terms**—a monotonically increasing integer that acts as a logical clock. Each term begins with an **election** (or no election if the current leader continues to prove its liveness). Servers can be in one of three roles:

- **Leader**: handles all client requests, replicates log entries to followers, and manages the committed prefix.
- **Follower**: passively receives log entries and votes from the leader.
- **Candidate**: enters this state when a follower suspects the leader has failed; it asks for votes to become the new leader.

The **log** is a sequence of entries, each containing a term number and a command. Commands are applied to the state machine in commit order. **Commit** means that an entry is known to be safely replicated on a majority of servers.

Safety in Raft is guaranteed by the **Election Safety** property (at most one leader per term), **Leader Append-Only** (a leader never overwrites or deletes its own log), **Log Matching** (if two logs contain an entry with the same term and index, they are identical up to that point), and **Leader Completeness** (a leader must have all committed entries from previous terms).

For a deeper theoretical treatment, refer to the original [Raft paper](https://raft.github.io/raft.pdf). Here, we focus on what you need to implement.

---

## 2. Setting the Stage: A Minimal Raft Implementation in Go

We’ll implement Raft as a Go struct that communicates with peers via gRPC (or a simple message‑passing API). To keep the first iteration manageable, we’ll assume a fixed cluster size of `3` or `5` nodes, perfect networking, and no client interactions. The core types are:

```go
type LogEntry struct {
    Term    uint64
    Command []byte
}

type Raft struct {
    mu          sync.Mutex
    id          int
    peers       []int
    state       Follower | Candidate | Leader
    currentTerm uint64
    votedFor    int   // -1 means null
    log         []LogEntry
    commitIndex uint64
    lastApplied uint64
    // Leader-only state
    nextIndex  []uint64
    matchIndex []uint64
    // Election timers
    electionTimeout   time.Duration
    heartbeatInterval time.Duration
}
```

The election timer is randomized per node per term (e.g., between 150 ms and 300 ms) to reduce split votes. The leader sends heartbeats to reset followers’ timers. In the next sections we’ll implement the core RPCs: `RequestVote` and `AppendEntries`.

---

## 3. The Heart of the Protocol: Leader Election and Log Replication

### 3.1 RequestVote RPC

A candidate begins an election by incrementing its term, voting for itself, and sending `RequestVote` to all other servers. The receiver grants its vote only if:

- The candidate’s term is at least as large as its own term.
- Its own `votedFor` is either null or the candidate’s ID.
- The candidate’s log is at least as up‑to‑date as its own (compare last log term first, then index).

Implementation sketch:

```go
func (rf *Raft) RequestVote(args *RequestVoteArgs, reply *RequestVoteReply) {
    rf.mu.Lock()
    defer rf.mu.Unlock()

    if args.Term < rf.currentTerm {
        reply.Term = rf.currentTerm
        reply.VoteGranted = false
        return
    }
    if args.Term > rf.currentTerm {
        rf.currentTerm = args.Term
        rf.state = Follower
        rf.votedFor = -1
    }
    if (rf.votedFor == -1 || rf.votedFor == args.CandidateID) &&
        rf.logIsMoreUpToDate(args.LastLogTerm, args.LastLogIndex) {
        rf.votedFor = args.CandidateID
        reply.VoteGranted = true
    }
    reply.Term = rf.currentTerm
}
```

Note the `logIsMoreUpToDate` helper: returns `true` if the candidate’s log is at least as up‑to‑date as the receiver’s. This ensures that the leader with the most complete log is elected.

### 3.2 AppendEntries RPC (Heartbeats and Log Replication)

The leader sends `AppendEntries` to each follower periodically (heartbeats) and after each new client request (log replication). The RPC carries the leader’s term, the previous log index and term (for consistency checking), and one or more new entries.

The follower’s handler implements the **Log Matching** property:

```go
func (rf *Raft) AppendEntries(args *AppendEntriesArgs, reply *AppendEntriesReply) {
    rf.mu.Lock()
    defer rf.mu.Unlock()

    if args.Term < rf.currentTerm {
        reply.Term = rf.currentTerm
        reply.Success = false
        return
    }
    // Reset election timer (we’ll handle this via goroutine later)
    rf.resetElectionTimer()

    if args.Term > rf.currentTerm {
        rf.currentTerm = args.Term
        rf.state = Follower
        rf.votedFor = -1
    }

    // Verify previous log entry
    if args.PrevLogIndex > rf.lastLogIndex() {
        reply.Success = false
        reply.ConflictTerm = -1
        reply.ConflictIndex = rf.lastLogIndex() + 1
        return
    }
    if rf.log[args.PrevLogIndex].Term != args.PrevLogTerm {
        // Conflict at PrevLogIndex, compute the first index of that term
        conflictTerm := rf.log[args.PrevLogIndex].Term
        i := args.PrevLogIndex
        for i > 0 && rf.log[i].Term == conflictTerm {
            i--
        }
        reply.ConflictTerm = conflictTerm
        reply.ConflictIndex = i + 1
        reply.Success = false
        return
    }

    // Append new entries (truncate if needed)
    rf.log = rf.log[:args.PrevLogIndex+1]
    rf.log = append(rf.log, args.Entries...)
    // Update commit index
    if args.LeaderCommit > rf.commitIndex {
        rf.commitIndex = min(args.LeaderCommit, rf.lastLogIndex())
    }
    reply.Success = true
}
```

The leader processes replies: if a follower reports `Success == false`, the leader decrements `nextIndex` for that follower and retries. This is the **back‑off** mechanism that efficiently brings followers up to date.

### 3.3 Leader’s Commit Rule

The leader commits an entry when it has been replicated to a majority of the cluster. Crucially, it never commits an entry from a previous term by counting replicas of that entry alone; instead it waits for a majority to have a later entry from its current term. This rule, often called **commitment by induction**, is a linchpin of Raft’s safety.

```go
// Called after processing a successful AppendEntries reply
func (rf *Raft) updateCommitIndex() {
    for n := rf.commitIndex + 1; n <= rf.lastLogIndex(); n++ {
        if rf.log[n].Term == rf.currentTerm {
            count := 0
            for _, peer := range rf.peers {
                if rf.matchIndex[peer] >= n {
                    count++
                }
            }
            if count > len(rf.peers)/2 {
                rf.commitIndex = n
            }
        }
    }
}
```

---

## 4. Persistence: Surviving Crashes

A correct Raft implementation must persist critical state across restarts: `currentTerm`, `votedFor`, and the log. Without persistence, a restarted follower could grant a vote for an older term and cause a leader to be deposed incorrectly.

We’ll write these values to a simple file (or use a key‑value store like BoltDB) in a dedicated goroutine:

```go
type PersistentState struct {
    CurrentTerm uint64
    VotedFor    int
    Log         []LogEntry
}

func (rf *Raft) persist() {
    data, _ := rf.encoder.Encode(rf.currentTerm, rf.votedFor, rf.log)
    ioutil.WriteFile(rf.persistPath, data, 0644)
}
```

And restore on startup:

```go
func (rf *Raft) readPersist(state []byte) error {
    if state == nil {
        return nil
    }
    return rf.decoder.Decode(state, &rf.currentTerm, &rf.votedFor, &rf.log)
}
```

In a real system you would also include checksums and atomic writes.

---

## 5. Membership Changes: The Challenge of Dynamic Clusters

So far we’ve assumed a fixed set of servers. In production, you need to add or remove nodes without stopping the cluster—a process known as **cluster membership changes**. It is notoriously tricky because naive transitions can violate safety.

### 5.1 The Joint Consensus Approach (Raft’s Original Solution)

Raft uses a two‑phase protocol: first, the leader proposes a **joint consensus** configuration that includes both the old and new sets of servers (`Cold_new`). The joint configuration is committed as a special log entry, and once committed, the leader can propose the new configuration alone (`Cnew`). During the joint phase, both majorities must agree on log replication and elections.

### 5.2 Single‑Server Changes (Simpler Alternative)

The Raft paper later proposed a simpler method: add or remove only one server at a time. With a single server change, the cluster can safely transition by enlisting the new server (or decommissioning the old) as a normal Raft log entry, using the same commitment rules as regular log entries. This avoids the complexity of joint consensus.

We’ll implement the single‑server approach. The leader appends a configuration entry to its log:

```go
type ConfigChangeEntry struct {
    Op    string // "AddServer" or "RemoveServer"
    Peer  int
    Term  uint64
}
```

When a follower receives this entry, it updates its peer list. The leader must wait until the entry is committed (by majority of the new configuration) before applying it.

### 5.3 Edge Cases to Watch

- **Adding a follower that is far behind**: The new server’s log may be empty. The leader must be careful not to commit entries that depend on a majority that includes the new server until it has caught up sufficiently. The single‑server method avoids this because the new server is not part of the majority until the configuration is committed.
- **Removing the leader**: If a leader is removed, it should step down once the new configuration is committed (or when it hears from a higher‑term leader). In practice, the removed leader will simply stop receiving votes and eventually a new leader will be elected.
- **Concurrent changes**: Only one change can be in progress at a time. The leader must reject new configuration requests while one is pending.

A robust implementation maintains a `pendingConf` flag and serializes all membership operations.

---

## 6. Log Compaction: Snapshots to Keep the Log Manageable

As time goes on, a Raft log grows without bound. To control disk usage and speed up recovery for slow followers, we implement **snapshotting**. The leader or follower can take a snapshot of the state machine at a given `lastIncludedIndex` and `lastIncludedTerm`, then discard all log entries up to that point.

When sending `AppendEntries` or `InstallSnapshot` (a separate RPC) to a follower that is far behind, the leader may have already discarded entries the follower needs. In that case, the leader sends an `InstallSnapshot` RPC that contains the snapshot data plus the last included index and term.

The follower’s snapshot handler updates its state machine and log accordingly:

```go
func (rf *Raft) InstallSnapshot(args *InstallSnapshotArgs, reply *InstallSnapshotReply) {
    rf.mu.Lock()
    defer rf.mu.Unlock()
    if args.Term < rf.currentTerm {
        reply.Term = rf.currentTerm
        return
    }
    // Reset election timer, update term...
    // Apply snapshot if it is newer
    if args.LastIncludedIndex > rf.lastApplied {
        // Apply all commands up to LastIncludedIndex (or simply store snapshot)
        rf.applySnapshot(args.Data)
        rf.log = trimLog(rf.log, args.LastIncludedIndex)
        rf.commitIndex = args.LastIncludedIndex
        rf.lastApplied = args.LastIncludedIndex
    }
    reply.Term = rf.currentTerm
}
```

Note that after snapshotting, the first log entry’s index is no longer 1. All indices in the implementation must be relative to the snapshot’s base index.

---

## 7. Client Interaction: Consistency Guarantees

Clients talk to the leader. They send a command, which the leader appends to its log and replicates. Once the entry is committed, the leader executes it against its state machine and returns the result.

But what about linearizability? If the leader crashes after replying, the client might not see its update if the new leader has not yet committed the entry. To guarantee **linearizable reads**, Raft leaders must implement the **ReadIndex** algorithm:

1. Commit a no‑op entry at the start of the term (many implementations do this automatically as part of leader election).
2. For each read request, record the leader’s current commit index.
3. Send a heartbeat to confirm the leader is still the leader.
4. Wait until `lastApplied >=` that commit index, then apply the read to the state machine.

This ensures that a stale leader does not return outdated data.

```go
func (rf *Raft) Read(query interface{}) (result interface{}, err error) {
    // Step 1: Serialize with log (ensure leader)
    rf.mu.Lock()
    if rf.state != Leader {
        rf.mu.Unlock()
        return nil, errors.New("not leader")
    }
    commitIdx := rf.commitIndex
    rf.mu.Unlock()

    // Step 2: Send heartbeat to all followers
    rf.broadcastHeartbeat()

    // Step 3: Wait until applied
    for {
        rf.mu.Lock()
        if rf.lastApplied >= commitIdx {
            result = rf.stateMachine.Read(query)
            rf.mu.Unlock()
            return
        }
        rf.mu.Unlock()
        time.Sleep(10 * time.Millisecond)
    }
}
```

This pattern is simpler than Raft’s full linearizable read (which requires a quorum read similar to a write), but it provides strong consistency in practice for many workloads.

---

## 8. Testing and Verification

“Raft implementations are notoriously tricky to get right.” A thorough test suite is essential. We’ll build:

- **Unit tests** for each RPC handler and helper function.
- **Integration tests** that spin up a cluster of in‑process Raft nodes, inject network partitions, node crashes, and client requests.
- **Model checking** via a simple simulation: encode the Raft state machine and enumerate reachable states for small clusters to catch violations of safety properties.

A minimal integration test skeleton:

```go
func TestBasicAgreement(t *testing.T) {
    servers := make([]*Raft, 3)
    for i := 0; i < 3; i++ {
        servers[i] = MakeRaft(servers, i)
    }
    defer func() {
        for _, s := range servers {
            s.Kill()
        }
    }()

    op := servers[0].Start([]byte("store 42"))
    time.Sleep(1 * time.Second)
    for _, s := range servers {
        if s.lastApplied < op.Index {
            t.Errorf("server %d did not apply op index %d", s.id, op.Index)
        }
    }
}
```

For serious verification consider using the **Porcupine** linearizability checker or model‑based testing with **TLA+** (the Raft paper includes a TLA+ specification).

---

## 9. Beyond the Basics: Optimizations and Production Considerations

A production Raft implementation requires several enhancements:

- **Batching**: Combine multiple log entries in a single `AppendEntries` RPC.
- **Pipelining**: Send the next `AppendEntries` to a follower without waiting for the previous one to complete (the leader can have multiple outstanding RPCs per follower).
- **Leader Transfer**: Gracefully hand over leadership to a specific follower for maintenance.
- **Pre‑Vote phase**: Avoid disrupting a healthy leader when a partitioned node starts an election with a higher term after reconnecting.
- **Checkpointing snapshots**: Use periodic snapshots and allow followers to request them efficiently.
- **Rate limiting**: Protect the cluster from bursts of client requests.

In code, these translate to careful management of concurrent goroutines, timeouts, and back‑off retries.

---

## 10. Conclusion: What We Learned and Where to Go Next

Building a Raft consensus protocol from scratch is a rite of passage for distributed systems engineers. In this blog post we’ve covered:

- The core leader election and log replication loops.
- Safety guarantees via term comparisons and commit rules.
- Persistence for crash recovery.
- Dynamic membership changes (single‑server approach).
- Log compaction via snapshots.
- Client interaction for linearizable reads.
- Testing strategies.

Now that you understand the internals, you can confidently use Raft‑based tools like etcd or Consul, and you can extend this implementation with advanced features like multi‑Raft groups (e.g., for sharding) or integration into a distributed database.

The complete source code for this implementation is available on [GitHub](https://github.com/yourname/raft-from-scratch). I encourage you to clone it, run the tests, and experiment with fault injection. The best way to truly master Raft is to break it and fix it yourself.

Distributed consensus is not magic—it’s a beautifully crafted set of rules that a computer can follow to achieve agreement despite failures. And now, you have built those rules yourself.

---

_This article is part of the series “Distributed Systems from Scratch”. Next up: “Implementing the Replicated State Machine — From Raft to a Scalable Key‑Value Store”._
