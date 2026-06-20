---
title: "Building A Simple State Machine Replication System With Raft And A Key Value Store"
description: "A comprehensive technical exploration of building a simple state machine replication system with raft and a key value store, covering key concepts, practical implementations, and real-world applications."
date: "2026-01-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/Building-A-Simple-State-Machine-Replication-System-With-Raft-And-A-Key-Value-Store.png"
coverAlt: "Technical visualization representing building a simple state machine replication system with raft and a key value store"
---

# The Day The Server Went Dark: A Distributed Systems Fairy Tale

Imagine you are the sole system administrator for a small, yet critical, application. Let’s call it "The Vault." It’s a simple key-value store that holds the configurations for every other service in your company. It’s reliable, it’s fast, and it lives on a single, trusted server under your desk. Life is good.

Then, one Tuesday afternoon, the server goes dark. The power supply fails. The Vault is gone. In the seconds that follow, every service that depended on it—the user authentication system, the billing pipeline, the internal dashboard—begins to fail. The phone rings. It’s your CTO. The company is losing money by the second.

You scramble, restore from the last backup (which was, of course, at 2 AM the previous night), and lose six hours of critical configuration changes. The post-mortem is brutal. The conclusion is inevitable: you need **redundancy**. You need the system to survive a crash, a power outage, or even an entire rack failure without losing a single write.

So, you buy three servers. You set them all up with instances of your key-value store. Now, how do you keep them synchronized? When a client updates the value for `api_rate_limit` from 100 to 200, how do you ensure _all three_ servers see that change, and that they see it in the same order? If a client connects to Server 2 and reads the value, does it get the old 100 or the new 200? And if a server crashes and comes back, how does it catch up without creating errors?

This is the fundamental, terrifying, and fascinating challenge of **distributed consensus**. It is the problem of getting a group of computers to agree on a single, undeniable version of the truth—even when some of them are unreliable or slow. And it is the problem we are about to solve.

## Why This Matters More Than You Think

Consensus is not an academic curiosity. It is the engine behind almost every fault‑tolerant distributed system you use daily. The domain name system (DNS) relies on consensus to propagate zone transfers reliably. Google’s Spanner uses the Paxos consensus algorithm to ensure global consistency across datacenters. The blockchain revolution is fundamentally a story about reaching consensus without a central authority. When you store a key in etcd or Consul, you are invoking the Raft consensus algorithm. When you use Apache Kafka with `min.insync.replicas > 1`, you are relying on a leader‑based replication protocol that shares many ideas with consensus.

Without consensus, your system is a fragile house of cards. With it, you can tolerate crashes, partitions, and even malicious faults (if you use Byzantine consensus, a whole other rabbit hole). In this blog post we will explore the Raft consensus algorithm in depth—a practical, understandable alternative to Paxos that has become the de‑facto standard for building replicated state machines. By the end, you will not only understand the theory, but also walk away with concrete code snippets and implementation patterns you can adapt for your own projects.

But before we dive into Raft’s beautiful mechanics, we must first define the problem formally.

## The Formal Problem of Consensus

A set of **n** processes (servers) must agree on a single value. Each process proposes a value (or a sequence of values, like log entries). The consensus algorithm must guarantee the following properties:

- **Agreement**: No two correct processes decide on different values.
- **Validity**: If a correct process decides on a value **v**, then **v** must have been proposed by some process.
- **Termination**: Every correct process eventually decides some value.
- **Integrity**: No process decides more than once.

These properties hold under a **partially synchronous** model: the network may be asynchronous (messages can be arbitrarily delayed) but eventually becomes synchronous for long enough to make progress. This is the standard model for real‑world systems like Raft and Paxos.

The famous **FLP impossibility result** (Fischer, Lynch, Paterson, 1985) proved that in a purely asynchronous system, no deterministic algorithm can guarantee consensus even with a single crash failure. Practical consensus algorithms circumvent this by using timeouts and leader election—making timing assumptions that allow termination in the common case while still guaranteeing safety even when messages are delayed.

## Raft in a Nutshell

Raft was designed by Diego Ongaro and John Ousterhout at Stanford in 2013 with the explicit goal of being understandable. Paxos had a reputation for being notoriously hard to implement correctly. Raft breaks the consensus problem into three orthogonal sub‑problems:

1. **Leader Election**: A single server is elected Leader. It coordinates all decisions.
2. **Log Replication**: The Leader receives client commands, appends them to its log, and replicates them to Followers. A command is committed when a majority of servers have stored it.
3. **Safety**: Raft guarantees that the Leader at any given term has all committed log entries from previous terms. It also ensures that servers only vote for candidates with up‑to‑date logs.

The algorithm uses **terms** as logical clocks. Each term begins with an election, and at most one leader exists per term. Servers exchange messages via two RPCs: `RequestVote` (used during elections) and `AppendEntries` (used for replication and heartbeat). There is also an `InstallSnapshot` RPC for log compaction.

Raft is a **strong leader** algorithm: most decisions are made by the leader, and followers are passive. This simplifies reasoning about correctness compared to multi‑leader protocols.

## Leader Election in Detail

Let’s walk through an election step by step, with a concrete example of five servers: S1, S2, S3, S4, S5.

### Starting Up

When a server starts, it is a **Follower**. It expects periodic heartbeats from the current leader. If it receives no heartbeat within an **election timeout** (randomly chosen between, say, 150ms and 300ms), it assumes the leader has crashed and transitions to **Candidate**.

### Becoming a Candidate

1. The server increments its current **term** (e.g., from 0 to 1).
2. It votes for itself.
3. It sends `RequestVote` RPC messages to all other servers.

Each `RequestVote` includes the candidate’s term, the candidate’s ID, the index and term of its **last log entry**. This is crucial: followers will only grant a vote if the candidate’s log is at least as up‑to‑date as their own (more on this in the safety section).

### Receiving a Vote Request

A follower processes a `RequestVote` as follows:

- If `candidateTerm < currentTerm`, ignore the request (and optionally reply with its own term to help the candidate step down).
- If the follower has not voted in this term (recorded in `votedFor`), and the candidate’s log is at least as up‑to‑date, grant the vote. Otherwise, deny.

### Winning the Election

A candidate wins if it receives votes from a **majority** of the cluster. For five servers, that means at least three votes (including its own). If it wins, it becomes Leader and immediately sends `AppendEntries` heartbeats to all servers to establish its authority and suppress further elections.

### Split Votes – The Randomization Trick

If multiple candidates start an election at the same time, they might split the vote: each gets two votes out of five, no majority. In that case, the election times out and a new election begins. To make this unlikely, Raft randomizes the election timeout. Since each server picks a different random value, usually one candidate will time out first and start its election before the others, winning with a majority.

Here’s a simplified pseudo‑Go implementation of an election timeout loop:

```go
func (s *Server) runElectionTimer() {
    timeout := s.randomTimeout() // 150–300ms
    for {
        select {
        case <-time.After(timeout):
            if s.state != Leader && s.state != Candidate {
                s.startElection()
            }
        case heartbeat := <-s.heartbeatChan:
            s.resetElectionTimer()
        }
    }
}
```

### Example: A Crash in Action

Suppose S1 is the leader. It crashes. S2, S3, S4, S5 are followers. S3’s election timeout (200ms) elapses before the others (S2’s timeout is 280ms, S4’s 250ms, S5’s 310ms). S3 becomes candidate (term 2), sends `RequestVote` to all. S2 has not yet timed out, so it votes for S3 (provided S3’s log is up‑to‑date). S4 also votes for S3 before its own timeout fires. S5 eventually times out but receives a heartbeat from the new leader S3 before it can start an election.

Now S3 is leader. It sends heartbeats every 50ms (a fixed interval shorter than the typical election timeout). This ensures no other server times out.

## Log Replication

Once a leader is elected, it accepts client commands. Each command is appended to the leader’s own log as a **log entry**. The leader then replicates the entry to all followers.

### The AppendEntries RPC

The leader sends `AppendEntries` to each follower. The RPC contains:

- `term` (leader’s current term)
- `leaderId`
- `prevLogIndex` (index of the log entry immediately before the new one)
- `prevLogTerm` (term of that entry)
- `entries[]` (the new log entries to store)
- `leaderCommit` (the leader’s current commit index)

### Consistency Check

The follower checks that its log contains an entry at `prevLogIndex` with term `prevLogTerm`. If not, it returns `false`, and the leader decrements `nextIndex` for that follower and retries. This is how Raft maintains consistency: the leader never overwrites its own log, and followers only accept entries that follow from a consistent prefix.

### Commit Point

A log entry is considered **committed** once it has been replicated to a majority of servers. The leader increments its `commitIndex` to that entry and then applies it to the state machine in order. The next `AppendEntries` heartbeat includes the updated `commitIndex`, so followers know they can safely apply the entry.

Here is a simplified `AppendEntries` handler on the follower side:

```go
func (s *Server) HandleAppendEntries(args AppendEntriesArgs) AppendEntriesReply {
    if args.Term < s.currentTerm {
        return AppendEntriesReply{Success: false, Term: s.currentTerm}
    }
    // Reset election timer
    s.resetElectionTimer()

    // Check consistency
    if args.PrevLogIndex > len(s.log) {
        return AppendEntriesReply{Success: false, Term: s.currentTerm}
    }
    if args.PrevLogIndex > 0 && s.log[args.PrevLogIndex-1].Term != args.PrevLogTerm {
        return AppendEntriesReply{Success: false, Term: s.currentTerm}
    }

    // Append new entries (delete conflicting entries if any)
    for i, entry := range args.Entries {
        if args.PrevLogIndex+1+i <= len(s.log) {
            if s.log[args.PrevLogIndex+i].Term != entry.Term {
                // Conflict: truncate log from here
                s.log = s.log[:args.PrevLogIndex+i]
                s.log = append(s.log, entry)
            }
            // else already consistent, skip
        } else {
            s.log = append(s.log, entry)
        }
    }

    // Update commitIndex
    if args.LeaderCommit > s.commitIndex {
        s.commitIndex = min(args.LeaderCommit, len(s.log))
    }

    return AppendEntriesReply{Success: true, Term: s.currentTerm}
}
```

### Example: Concurrent Writes

Clients send a write request to the leader. The leader appends it to its log, then replicates to followers. Suppose we have three servers: L (leader), F1, F2. L receives “set x=1”. It appends entry [term 3, index 5, command “set x=1”]. It sends `AppendEntries` to F1 and F2. F1 acknowledges, but F2 is temporarily partitioned. L has received a majority (L + F1 = 2 out of 3), so it commits entry 5 and replies to the client. When F2 recovers, L will notice that F2’s `nextIndex` is behind and send missing entries. F2 will eventually catch up.

### Network Partitions – The Flagpole Test

What happens if the network splits into two partitions? Suppose 5 servers split 3‑2. Only the partition with the majority (3) can elect a leader and commit entries. The minority partition (2) cannot elect a leader because it cannot get a majority of votes. Clients attempting to write to the minority partition will time out or get an error. When the partition heals, the minority’s leader (if any) will discover it has an outdated term and step down. The minority’s log will be overwritten by the new leader’s log to ensure consistency. This is safe: any uncommitted entries in the minority are thrown away. Committed entries are those that existed on a majority, which is always only in the majority partition.

## Safety and the Leader Completeness Property

Raft’s safety guarantees rest on a few key invariants.

### Election Restriction

A candidate can only win an election if its log is at least as up‑to‑date as a voting server’s log. “Up‑to‑date” is defined first by term of the last entry: the candidate with the higher last‑log‑term is more up‑to‑date. If terms are equal, the candidate with the longer log is more up‑to‑date. This ensures that a leader always contains all committed entries from previous terms.

Why? Suppose entry **e** is committed in term 2. That means a majority of servers have **e** in their logs. Any candidate that wins an election must receive votes from a majority, so it must intersect that majority. At least one server in the intersection has **e**. Because of the restriction, the candidate’s log is at least as up‑to‑date as that server’s log, so the candidate must also have **e**. Therefore the newly elected leader has **e** in its log.

### Log Matching Property

Raft guarantees that if two logs contain an entry with the same index and term, then they are identical for all entries up to that index. This follows from the consistency check in `AppendEntries`: the leader never inserts an entry without checking that the previous entry matches, and followers only accept entries that maintain a common prefix. This property makes recovery simple.

### State Machine Safety

If a server has applied a log entry at a given index to its state machine, no other server will ever apply a different entry at the same index. This holds because committed entries are fixed forever. Once a majority has an entry, that entry can never be overwritten. The leader’s election restriction ensures continuity.

## Cluster Membership Changes

In a real system, servers will fail and need to be replaced, or you may want to add capacity. Changing the set of servers while ensuring safety is notoriously tricky. Raft uses a **joint consensus** approach, transitioning through an intermediate configuration.

### The Basic Idea

Suppose we currently have configuration **Cold** (set of servers {A,B,C}) and we want to change to **Cnew** ({A,B,D,E}). Raft does not jump directly. Instead:

1. The leader logs a **joint configuration** entry **Cold,new** that includes both sets.
2. The leader replicates **Cold,new** under the rules of **Cold** (majority of Cold).
3. The cluster now operates under the joint configuration: all decisions require a majority of **both** Cold and Cnew. For example, to commit an entry, you need a majority in Cold and a majority in Cnew.
4. Once **Cold,new** is committed, the leader logs **Cnew** and replicates it under the rules of the joint configuration.
5. When **Cnew** is committed, the cluster uses only Cnew.

This ensures that, during the transition, no two separate majorities can make conflicting decisions. The old and new servers are both involved, preventing split‑brain scenarios.

### Adding a New Server: A Step‑by‑Step Walkthrough

We have a 3‑node cluster {S1, S2, S3}. We want to add S4.

1. Operator sends the configuration change to the leader (S1).
2. S1 appends entry `{Cold: {S1,S2,S3}, Cnew: {S1,S2,S3,S4}}` (the joint config).
3. S1 replicates this to S2, S3, S4. Note that S4 must receive the entry; even though S4 is not yet part of the old configuration, it receives the joint config as a normal log entry. S4 follows all the rules.
4. S1 commits the joint config when a majority of Cold (e.g., S1 and S2) and a majority of Cnew (S1 and S3) have it. Because S4 is in Cnew but not Cold, its acknowledgement does not count toward the Cold majority—that’s fine.
5. Now the cluster operates under joint configuration. Any subsequent `AppendEntries` or `RequestVote` requires both majorities.
6. S1 logs the final configuration `Cnew: {S1,S2,S3,S4}`.
7. This is replicated under the joint configuration rules.
8. Once committed, the cluster switches to the final configuration.

### Removing a Server

Removing a server (especially the leader itself) requires extra care. If the leader is being removed, it steps down after committing the configuration change, leaving the cluster leaderless for a brief moment—a new election will pick a leader from the remaining servers.

## Log Compaction and Snapshots

Raft logs grow without bound. To prevent infinite disk usage, the system must periodically compact the log. The standard approach is **snapshotting**: take a snapshot of the current state machine, discard all log entries before a certain index, and store the snapshot.

### Snapshot Creation

The leader (or each server independently) takes a snapshot when the log exceeds a threshold size. The snapshot includes:

- The last included index (the index of the last entry applied to the state machine)
- The last included term
- The state machine state (e.g., the entire key‑value map)

The server then truncates its log up to that index. It retains the snapshot and the log entries after the snapshot.

### InstallSnapshot RPC

If a follower falls far behind—e.g., because it was down for a long time—the leader may no longer have the log entries needed to bring it up to date. In that case, the leader sends an `InstallSnapshot` RPC containing the snapshot. The follower saves the snapshot, truncates its log to the last included index, and then continues receiving log entries from after that index.

The `InstallSnapshot` RPC works similarly to `AppendEntries`: the leader sends the snapshot in chunks (to avoid network timeouts), and the follower acknowledges each chunk. When the entire snapshot is received, the follower installs it and resets its log.

### Performance Considerations

Snapshots are both a blessing and a curse. They reduce recovery time (no need to replay thousands of log entries) and save disk space. However, they can be expensive to generate (copying the entire state machine, encoding it). Many implementations perform snapshots on a background goroutine, using copy‑on‑write techniques or incremental copy. Also, too‑frequent snapshots waste CPU; too‑infrequent ones waste disk and recovery time.

## Performance Optimizations in Practice

Raft in its basic form is correct but not always fast. Production implementations (etcd, CockroachDB, Consul) incorporate several optimizations:

### Batching and Pipelining

Instead of sending one `AppendEntries` RPC per entry, the leader accumulates several entries and sends them in a single batch. This reduces RPC overhead. Furthermore, the leader can pipeline requests: send the next batch before receiving acknowledgements for the previous one, up to a window size.

### Parallel Replication

The leader replicates to followers in parallel. Each follower has its own `nextIndex` and `matchIndex`. The leader tracks them independently. However, the commit rule requires that a majority of followers have replicated an entry, so the leader must wait for the slowest of the majority. To avoid blocking on slow followers, some implementations use **asynchronous writes**: the leader commits as soon as the quorum acknowledges, even if other followers are lagging. The lagging followers catch up later.

### Read‑Only Queries

Raft’s strong consistency can hurt read performance because the leader must handle every read to guarantee fresh data. Some systems optimize by allowing followers to serve reads if they are known to be up‑to‑date (e.g., by periodically receiving the leader’s commit index). However, this requires careful handling: the leader must ensure it is still leader (heartbeat check) and that the follower’s log is sufficiently current. This is often done via the **ReadIndex** optimization: the leader records its commit index, confirms it is still leader via a quorum heartbeat, and then sends that index to followers, which can serve reads as long as their `commitIndex` >= that index.

### Leader Leases and Clock Synchronization

In systems where clock skew is bounded (e.g., using NTP with strict thresholds), a leader can assume it remains leader for a "lease" period after its last successful heartbeat. This allows the leader to serve read requests without contacting followers, improving throughput. However, using leases requires trust in the underlying clock synchronization, which is not safe in arbitrary asynchronous networks.

## Real‑World Implementations and Case Studies

Raft is not just academic; it powers many critical systems:

- **etcd** (CoreOS) – a distributed key‑value store used by Kubernetes for cluster state. Etcd uses an optimized Raft implementation with pipelining, batching, and snapshotting. It is the canonical Go implementation of Raft.
- **Consul** (HashiCorp) – uses Raft for service discovery and configuration. Consul’s Raft implementation is written in Go as well, with added support for WAN‑optimized replication across datacenters.
- **TiKV** – a distributed transactional key‑value store that uses Raft for replication and consensus. TiKV adapts Raft with a multi‑raft group approach for scalability.
- **CockroachDB** – a distributed SQL database that uses Raft for range replication. Each range (a shard) runs its own Raft group, and a separate meta‑range tracks the shards. It integrates Raft with distributed transactions and clock synchronization (Hybrid Logical Clocks).
- **MongoDB** – before version 3.4, MongoDB used a custom protocol; it later adopted a Raft‑based replication set protocol.

All of these implementations have had to handle edge cases that the original paper only briefly mentions: cluster membership changes in progress, read‑only quorums, handling of stale leaders, and so on. The success of Raft in practice is a testament to its comprehensible design.

## Conclusion: From Fairy Tale to Production Reality

We started with a single server under a desk, vulnerable to a power spike. After this deep dive, you now understand the machinery that turns that fragile setup into a resilient, fault‑tolerant cluster. Raft gives us a way to agree in the face of uncertainty: on leaders, on logs, on the truth itself.

The algorithm is elegant because it decomposes a hard problem into smaller, manageable parts: leader election via random timeouts, log replication with consistency checks, and safety through careful election restrictions. Its strength is not just in its formal correctness, but in its understandability. That’s why it has become the go‑to solution for building replicated state machines.

But reading about Raft is only the first step. The real magic happens when you implement it, when you debug a corner case where an old leader’s term is behind, or when you watch your cluster gracefully survive the crash of a node. You will then appreciate the beauty of the consensus algorithm that keeps your system alive while the world keeps demanding progress.

So, next time you deploy a three‑node etcd cluster, or you fire up a Consul datacenter, remember the power of the algorithm underneath. And maybe, just maybe, you’ll smile knowing that even if a server goes dark, your distributed system will not.

_Now go build something that survives._
