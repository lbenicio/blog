---
title: "Raft Fast‑Commit and PreVote in Practice"
date: 2020-11-09T10:00:00Z
description: "What fast‑commit and PreVote actually change in Raft, how they affect availability during leader changes, and where the footguns are."
tags: ["distributed-systems", "raft", "consensus", "availability"]
categories: ["Engineering"]
draft: false
cover: "static/images/blog/raft-fast-commit-and-pre-vote-in-practice.png"
coverAlt: "Raft timeline showing PreVote rounds and a shortened commit path"
---

Raft’s original paper optimizes for understandability. Production clusters optimize for availability and mean‑time‑to‑recovery. Two common extensions—PreVote and fast‑commit—reduce needless disruptions and trim the time it takes to make progress. Let’s unpack them without hand‑waving.

## The pain: disruptive elections and long commit paths

- Without PreVote, a partitioned follower may increment term and trigger elections on rejoin, ousting a healthy leader.
- Without fast‑commit, clients wait for the full round‑trip alignment even when a quorum already holds the entry durably.

## PreVote

PreVote adds a “dry‑run” phase: before incrementing term, a candidate asks peers if they’d vote. Peers reject if their logs are more up‑to‑date.

Effects:

- Prevents disruptive elections from stale nodes reappearing after partitions.
- Keeps leaders in place when they’re healthiest (recently active, up‑to‑date logs).
- Slight extra message cost, negligible under steady state.

Gotchas:

- Implementation must not let PreVote reset election timers or terms.
- Ensure RPC authentication—PreVote can be abused to map cluster health.

## Fast‑commit (a.k.a. leader‑lease or commit on append to quorum)

Idea: if an entry is already replicated to a majority when the leader appends it, you can treat it as committed earlier, overlapping the replication and commit decisions.

Use cases:

- Write bursts where followers are caught up; the extra round trip is redundant.
- Low‑latency clusters where client p99 matters more than strict staging.

Safety constraints:

- The leader must be current (no clock skew illusions). Typically combined with leader leases (bounded clock error).
- Disallow commit under ambiguous leadership (dual leaders).
- On leader change, fall back to canonical commit rules until leases re‑establish.

## Observability and rollback plan

- Metrics: election attempts, PreVote rejections, commit latency distribution, out‑of‑date follower count.
- On anomalies (spurious elections, commit regressions), disable fast‑commit via a flag and capture traces.

## When to ship

PreVote is nearly always a free win. Fast‑commit is a tactical knob—turn it on in clusters with stable leaders, fast networks, and strong time sync; leave it off in heterogeneous or flaky networks.

## A refresher: Raft’s commit rules in brief

In standard Raft, a leader appends a log entry, replicates it to followers, and considers the entry committed when a majority (quorum) acknowledges that entry in the leader’s current term. Followers apply entries to their state machine only once they’re committed. This ensures linearizability and the Leader Completeness property: once an entry is committed, all future leaders must contain it.

The “extra round trip” people complain about is the strict separation between replicate and commit visibility. Even if the leader observes that a majority wrote the entry, it won’t present it as committed until the commit index advances in a subsequent heartbeat/append round. In low latency clusters, that extra heartbeat can dominate tail latencies for small writes.

## PreVote in detail: messages and timers

PreVote adds a preliminary phase before a node becomes a candidate. Timelines:

1. Follower’s election timer fires.
2. Instead of incrementing term and becoming a candidate immediately, the node sends PreVoteRequest(term'=current_term+1, lastLogIndex, lastLogTerm) to peers.
3. Peers reply PreVoteResponse(granted=true/false) depending on log up‑to‑dateness and their current leader lease.
4. If the would‑be candidate collects a majority of PreVote grants, it proceeds to increment term, transition to Candidate, and start the real RequestVote RPCs. Otherwise, it resets its election timer and stays follower.

Crucially, PreVote does not disturb term numbers or reset peers’ election timers. That’s the heart of its safety: a partitioned or slow follower doesn’t force the cluster to thrash terms when it comes back.

Common pitfalls and fixes:

- Accidentally resetting timers on PreVote receipt. Fix: PreVote is advisory; don’t touch election timers.
- Allowing PreVote to “discover” a leader and then resetting to a longer timeout; this can create oscillations. Keep election timers independent of PreVote.
- Ignoring log up‑to‑dateness in PreVote. You must apply the same lastLogIndex/lastLogTerm checks you use for RequestVote.

## Fast‑commit: leases, clocks, and the commit index

“Fast‑commit” is an umbrella for techniques that allow the leader to consider an entry committed as soon as it observes a quorum has durably appended it—often in the same RPC round—without waiting for an extra heartbeat.

Two common flavors:

- Leader leases: if the leader can prove exclusive leadership during a lease window (bounded by clock skew ε), then it can safely conclude that if a majority acknowledges an append in its term, no other leader could have committed a conflicting entry.
- Piggybacked commit: the leader advances its commit index immediately upon receiving enough AppendEntries acks for the tip entry of its current term, and includes the updated commit index in the next acks/heartbeats (sometimes in the same batch).

What makes this safe? The essence is that quorum intersection plus term scoping guarantees that future leaders must contain the entry. Leases strengthen the “no dual leaders” assumption: if the leader’s lease is valid, peers won’t vote for others, preventing ambiguous leadership during commit.

Clock considerations:

- Require NTP/Chrony with tight bounds and track worst‑case skew in metrics.
- Pick ε such that leaseDuration > worstNetworkDelay + worstSkew; renew leases conservatively.
- On detecting skew or missed renewals, disable fast‑commit and fall back to standard commit.

## Failure scenarios and how these features help (or hurt)

Scenario A: A follower pauses (GC) then resumes. Without PreVote, it might trigger an election upon resume and unseat a healthy leader, causing a brief write unavailability. With PreVote, it asks around first, sees that peers are happy with the leader, and stays quiet. Fewer useless elections; happier clients.

Scenario B: Network hiccup drops a few packets. A leader replicates an entry to a majority, but the heartbeat that would advance the commit index is delayed. With fast‑commit, the leader marks the entry committed as soon as the quorum acks land; the client sees lower p99 for writes.

Scenario C: Partition splits cluster 2–1. The minority “leader” might think it’s still in charge if leases aren’t properly implemented; fast‑commit without a lease could lead to incorrect commits. The fix is explicit leader leases tied to term and quorum contact, and falling back when ambiguous.

Scenario D: Disk stalls on a follower. PreVote does nothing; fast‑commit still works if you can reach a quorum without the slow disk. Monitor follower lag to avoid piling up unbounded in‑flight entries.

## Implementation blueprint

PreVote:

- Add PreVoteRequest/Response RPCs mirroring RequestVote but without term changes.
- Gate candidacy on collecting a majority of PreVote grants; add backoff if denied.
- Keep election timers and terms untouched by PreVote messages.

Fast‑commit:

- Track per‑term leader lease with expiry; renew on successful quorum contact.
- Advance commit index immediately upon observing quorum acks for entries in the current term.
- Include the updated commit index in outgoing AppendEntries to followers.
- Disable fast‑commit when lease is ambiguous or after leadership change until stability returns.

## Testing: from unit to Jepsen

- Unit tests: PreVote logic for up‑to‑date checks; commit index advancement only for current‑term entries; lease handling under skew.
- Integration: pause/resume followers, drop and delay packets, simulate partitions (2–1, 1–2), and verify no spurious leadership changes and no regressions in commit safety.
- Jepsen/Jepsen‑like chaos: test under clock skew and network partitions; assert linearizability and no lost updates.

## Metrics that matter

- Elections per hour, by reason (timer, PreVote denied, heartbeat loss).
- Time to leader after failure (MTTR); distribution not just mean.
- Commit latency p50/p95/p99 for writes, with and without fast‑commit.
- Follower lag (entries/bytes) and catch‑up time.
- Lease validity percentage and skew estimates.
- Term churn rate; high churn often means timers too aggressive or hearts missed.

## Configuration guidance

- Election timeout: base it on heartbeats × a factor (e.g., 3–5× the heartbeat interval), with jitter. Longer in geographically distributed clusters.
- Heartbeat interval: small enough to keep commit latency acceptable; too small wastes CPU/network.
- PreVote enable: on by default.
- Fast‑commit enable: guarded by feature flag; on only when time sync is verified and monitoring is in place.
- Quorum sizes: consider 5‑node clusters for higher availability; fast‑commit still works with larger quorums but lease windows may need adjustment.

## Operational playbook

Rollout steps:

1. Enable PreVote across the cluster; verify election rate drops and no regressions.
2. Enable leader leases without fast‑commit; validate lease metrics and skew bounds.
3. Enable fast‑commit on a subset (canary); compare commit latencies and correctness.
4. Roll out broadly; keep a kill switch to disable fast‑commit instantly on anomalies.

Runbooks:

- Spurious elections: check PreVote rejections, network packet loss, and follower liveness. Extend election timeouts if heartbeats are noisy.
- Commit regressions: check lease validity; if lease invalid or skew high, disable fast‑commit automatically.
- Stuck followers: snapshot/install to catch up; investigate disk/IO saturation.

## Interactions with snapshots and membership changes

Snapshots: fast‑commit doesn’t change snapshot logic; ensure commit index advances before cutting a snapshot. Followers lagging behind must install snapshots as usual.

Membership changes (joint consensus): be conservative; disable fast‑commit during reconfiguration or restrict it to entries in the joint config’s term once both quorums overlap safely. PreVote continues to help stabilize elections during churn.

## What about other optimizations?

- Batching: combine multiple client writes into a single AppendEntries; fast‑commit then commits a batch at once.
- Pipeline replication: send new appends before previous acks arrive; coordinate with commit index advancement carefully.
- Lease‑based reads: once you have leader leases, you can serve linearizable reads without round trips by ensuring the lease is valid.

## Summary

PreVote cuts pointless leadership flaps; fast‑commit trims the last millisecond‑scale bumps from write latency. Together, they make Raft clusters feel calmer and snappier—provided you respect the invariants: don’t disturb terms with PreVote; don’t pretend leadership without leases; and never commit outside the current term. Ship them with feature flags, tight observability, and a rollback plan, and you’ll buy both reliability and speed.
