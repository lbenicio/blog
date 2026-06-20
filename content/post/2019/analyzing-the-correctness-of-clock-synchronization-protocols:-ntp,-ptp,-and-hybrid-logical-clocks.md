---
title: "Analyzing The Correctness Of Clock Synchronization Protocols: Ntp, Ptp, And Hybrid Logical Clocks"
description: "A comprehensive technical exploration of analyzing the correctness of clock synchronization protocols: ntp, ptp, and hybrid logical clocks, covering key concepts, practical implementations, and real-world applications."
date: "2019-06-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/analyzing-the-correctness-of-clock-synchronization-protocols-ntp,-ptp,-and-hybrid-logical-clocks.png"
coverAlt: "Technical visualization representing analyzing the correctness of clock synchronization protocols: ntp, ptp, and hybrid logical clocks"
---

Here is the expanded blog post, deepened with technical details, historical context, case studies, and practical code snippets to reach the requested depth and word count.

---

## The Conductor's Baton: Why a Millionth of a Second Can Topple an Empire

Imagine a symphony orchestra. Ninety musicians, spread across a stage, each staring at their own sheet music. The conductor raises her baton. The first violinist begins, followed a heartbeat later by the cellos, then the woodwinds. It is a moment of sublime, synchronized chaos—beautiful only because every single player, despite being separated by feet of air and the unique acoustics of the hall, experiences a shared, invisible heartbeat: the downbeat of the conductor.

Now, imagine that the violinist in the front row is using a watch that runs three seconds fast. The timpanist in the back is using a watch that runs two seconds slow. The conductor’s baton falls, but the strings start early, the brass starts late, and the percussion never quite lands with the harmony. The symphony collapses into cacophony. This is not merely an analogy for a poorly run IT department. This is the literal, existential problem faced by every distributed system operating at scale.

Our modern computational world is that orchestra, and it has no single conductor.

We have traded the mainframe—a single, all-powerful, centralized brain—for a sprawling network of independent servers, spread across continents, connected by fiber optic cables and undersea lines. This is the architecture of the cloud, of cryptocurrency blockchains, of global financial exchanges, and of the Internet of Things. Yet, for this distributed organism to function with any semblance of coherence, its constituent parts must agree on the time. They must march to the same, silent drum.

But time, as any physicist or philosopher will tell you, is a slippery thing. In the world of classical physics, Newton believed time was absolute, a river flowing uniformly for all observers. Einstein proved that view is a beautiful lie. Time is relative, warped by gravity and velocity. While we rarely have to account for relativistic time dilation in a data center—though Google’s Spanner database famously uses atomic clocks and GPS receivers to bound clock uncertainty to within a few microseconds, a process that must internally correct for both special and general relativity—we face a more mundane, yet equally devastating, enemy: **clock skew**.

Clock skew is the silent cancer of distributed systems. It is the reason a bank might credit a transaction twice, why a stock exchange might allow a trade that should have been rejected, and why a multiplayer game can feel like everyone is playing underwater. This essay is a deep dive into that problem. We will explore why absolute time is an unattainable illusion in a networked world, how we engineer approximate consensus on time, and what happens when our approximations fail.

### Section 1: The Physics of Time in the Datacenter

To understand the problem, we must first understand the hardware. Every computer has a clock, but not all clocks are created equal. The vast majority of servers rely on a **quartz crystal oscillator**. When you apply a voltage to a quartz crystal, it vibrates at a precise frequency (typically 32,768 Hz for a real-time clock, or higher for CPU clocks). This vibration is counted, and the counts are converted into seconds, minutes, and hours.

This is a remarkably elegant system, but it is physically imperfect. The frequency of a quartz crystal is a function of its temperature, age, and manufacturing tolerances. A cheap crystal might have a drift rate of ±100 parts per million (ppm). That doesn’t sound like much, but let’s do the math.

- **100 ppm** means the clock gains or loses 100 microseconds every second.
- Over one day, this translates to a drift of approximately **8.64 seconds**.
- Over a month, that is a drift of over **4 minutes**.

Now, consider two servers in the same rack. Server A is near the air intake, running cool at 20°C. Server B is a hot server near the exhaust, running at 45°C. Their quartz crystals are humming at different frequencies. After just a few hours, their internal clocks might differ by several seconds. The system administrator looks at the logs from both servers and sees the same event recorded with timestamps that are seconds apart. Which one is correct? The answer is: neither.

This is the **physical clock problem**. We cannot rely on the hardware. We must build software that constantly corrects for this drift.

#### The Gardener and the Pendulum

There is a famous historical parallel. In the 17th century, John Harrison, a humble Yorkshire carpenter, solved the "Longitude Problem." Ships could not determine their east-west position because they had no accurate clock. A pendulum clock, perfect on land, was useless on a rolling ship. Harrison spent decades building a "marine chronometer" that could keep time to within a few seconds over a months-long voyage.

We are all John Harrison now. Every data center manager is trying to build a chronometer, except our ship is a global network of millions of servers, and our "seconds" must align to within microseconds for High-Frequency Trading (HFT) or within milliseconds for most web services.

### Section 2: The Network Time Protocol (NTP) – The First Line of Defense

Enter the Network Time Protocol. NTP is arguably one of the oldest and most widely used protocols on the internet (first deployed in 1985 by Dave Mills). It is the default way most machines synchronize their clocks. NTP works by having a client query one or more servers for the current time.

The core of NTP is a hierarchical model:

1.  **Stratum 0:** These are the high-precision timekeeping devices themselves: atomic clocks, GPS receivers (which get their time from the atomic clocks on GPS satellites), or radio clocks (like WWVB in the US).
2.  **Stratum 1:** These are computers directly connected to a Stratum 0 device. They are the primary time servers for the network.
3.  **Stratum 2, 3, 4, etc.:** These are servers that synchronize with the stratum above them. The further down the hierarchy, the less precise the time becomes, but the more scalable the system is.

When your laptop queries `pool.ntp.org`, it is likely talking to a Stratum 2 or Stratum 3 server.

#### The NTP Dance: How it Works

NTP does not just ask "What time is it?" and set the clock. That would be vulnerable to network latency (the time it takes for the request to travel). Instead, NTP measures the round-trip time.

Here is the simplified algorithm:

1.  Client timestamps its request ($T_1$).
2.  Server receives the request and timestamps it immediately ($T_2$).
3.  Server sends a reply with its current timestamp ($T_3$), along with $T_1$ and $T_2$.
4.  Client receives the reply and timestamps it ($T_4$).

The client now has four timestamps. Using these, it can calculate two variables:

- **Round-trip delay ($\delta$):** `(T4 - T1) - (T3 - T2)`. This is the total time the packet spent in the network.
- **Offset ($\theta$):** `((T2 - T1) + (T3 - T4)) / 2`. This is the estimated time difference between the client's clock and the server's clock.

The critical assumption is that the network latency is symmetric—the travel time from client to server is the same as from server to client. This is almost never true, but it is a good enough approximation for the vast majority of use cases. NTP then uses a complex suite of algorithms (selecting the best servers, filtering out outliers, and adjusting the clock gradually using a phase-locked loop) to slowly slew the clock into alignment.

**The Pitfall:** NTP can be fooled. A "NTP flood" (DDoS attack on NTP servers) can cause a client to lose synchronization. A "man-in-the-middle attack" can inject fake time data. More commonly, a poorly configured firewall or a saturated network link can cause asymmetric latency, leading to a wildly inaccurate offset calculation.

**Real-World Example:** In 2017, an AWS outage that took down S3 for several hours was traced back to a simple human error: a typo in a command that took a larger set of servers offline than intended. The recovery was hampered by database synchronization issues. While not a pure "time" failure, the chaos that ensued was a direct consequence of systems relying on implicit time-based ordering that had become inconsistent.

### Section 3: The Clock Inevitability Problem

Even with NTP, absolute synchronization is impossible. This is a physical and mathematical certainty.

- **Resolution:** NTP runs, at best, every few seconds or minutes. Between polls, your local quartz crystal is drifting. Even with the best NTP implementations, you can expect an offset of **1-10 milliseconds** on a local network and **10-100 milliseconds** across the internet. For most web applications, this is fine. For stock trading, it is a disaster.
- **Leap Seconds:** The Earth’s rotation is slowing down. To keep Coordinated Universal Time (UTC) in sync with astronomical time, a "leap second" is added (or subtracted) every few years. This is done by inserting an extra second (23:59:60) into the clock. In 2012, this caused widespread outages. Reddit, LinkedIn, and Qantas Airlines all reported crashes. Why? Because many software systems did not know how to handle a minute with 61 seconds. The `ntpd` daemon would notice a "jump" of a second and, depending on configuration, might step the clock backward, causing timestamps to be duplicated, data to be corrupted, and services to fail.

#### The Madness of `time_after()` and `time_before()`

Consider the humble `time_t` type in C. It is often a signed 32-bit integer representing seconds since January 1, 1970. The "Year 2038 problem" (Y2K38) is well known, but there is a more immediate concern. If you compare two timestamps using simple integer logic:

```c
if (time1 < time2) {
    // time1 is before time2
}
```

What happens if `time1` is near the maximum value? A single tick forward makes it wrap to a negative number. Suddenly, a time in the far future appears to be in the past. This is a classic time-of-day clock bug. Modern systems use `clock_gettime(CLOCK_MONOTONIC, ...)` to avoid this. The monotonic clock never jumps backward, but it has no relation to "wall clock" time—it only measures elapsed time since boot. This is the only sane way to measure durations and timeouts.

### Section 4: Logical Time – A Philosophical Workaround

If we cannot perfectly align clocks, how can we build a consistent distributed system? We cheat. We abandon the concept of "real" time and invent our own.

This is the genius of Leslie Lamport, one of the giants of distributed systems. In his seminal 1978 paper, "Time, Clocks, and the Ordering of Events in a Distributed System," Lamport argued that for many problems, we do not care what time it is in Greenwich. We only care about the order of events within our system.

This is the foundation of **Logical Clocks**.

#### The "Happened-Before" Relation

Lamport defined a simple partial order:

1.  If two events occur on the same process, the one that happens later in that process's local execution order happens after.
2.  If a process sends a message, the event of sending the message happens before the event of receiving the message.
3.  The relation is transitive (if A happens before B, and B happens before C, then A happens before C).

This allows us to define causality. Event A causally affects event B if A happened before B.

#### Lamport Timestamps

A Lamport timestamp is a simple counter.

- Each process has a counter, starting at 0.
- On every event (internal, send, receive), the process increments its counter.
- When a process sends a message, it includes its current counter value.
- When a process receives a message, it sets its own counter to `max(local_counter, received_counter) + 1`.

This gives us a Total Order of events (every event has a unique timestamp if we break ties by process ID). But there is a fatal flaw: **Lamport timestamps are not causal**.

You can look at two Lamport timestamps, say (5) and (7), and know that event (7) might have happened after (5). But you cannot know if they are causally related or if they are concurrent. This is where **Vector Clocks** come in.

#### Vector Clocks: The Smoking Gun

A vector clock is a list of counters, one per process in the system. For a system with 3 processes (A, B, C):

- Process A's vector clock starts as `[A:0, B:0, C:0]`.
- On an event, A increments its own component: `[A:1, B:0, C:0]`.
- When A sends a message, it sends this vector.
- When B receives the message, B increments its own component (`B:1`) and then merges the vector: for each component `i`, `B[i] = max(B[i], received[i])`.

Now, the magic: To compare two events, we compare their vectors.

- **Event V1 < Event V2 (V1 happened before V2):** If for all processes `i`, `V1[i] <= V2[i]`, and for at least one process `j`, `V1[j] < V2[j]`.
- **Concurrent Events:** If `V1[i] > V2[i]` for some `i`, and `V1[j] < V2[j]` for some `j` (i.e., neither is less than the other), the events are concurrent. There is no causality between them.

This is powerful. In a distributed database like Amazon Dynamo (or the open-source Riak), vector clocks are used to resolve conflicts. If two users write to the same record at the same time (concurrent updates), the system keeps both versions (a "conflict") and expects the application to merge them later. The vector clock tells the system that the two versions are branches in the causal history, not a simple overwrite.

#### Code Example: A Simple Vector Clock in Python

```python
class VectorClock:
    def __init__(self, process_id):
        self.clock = {}
        self.process_id = process_id
        self.clock[process_id] = 0

    def increment(self):
        self.clock[self.process_id] += 1
        return self.clock

    def send_message(self):
        self.increment()
        return dict(self.clock)  # Return a copy

    def receive_message(self, received_clock):
        # Merge received clock with local
        for pid, ts in received_clock.items():
            self.clock[pid] = max(self.clock.get(pid, 0), ts)
        self.increment() # This is the event of receiving

    @staticmethod
    def is_before(v1, v2):
        # Returns True if v1 happened before v2
        less = False
        for pid, ts in v1.items():
            if ts > v2.get(pid, 0):
                return False
            if ts < v2.get(pid, 0):
                less = True
        return less

    @staticmethod
    def is_concurrent(v1, v2):
        return not VectorClock.is_before(v1, v2) and not VectorClock.is_before(v2, v1)

# Example: Two processes
alice = VectorClock("A")
bob = VectorClock("B")

# Alice increments and sends
msg_a = alice.send_message()
print(f"Alice sends: {msg_a}")

# Bob receives
bob.receive_message(msg_a)
print(f"Bob's clock after receive: {bob.clock}")

# Meanwhile, Alice does another event
alice.increment()
print(f"Alice's clock after second event: {alice.clock}")

# Bob increments and sends
msg_b = bob.send_message()
print(f"Bob sends: {msg_b}")

# Are Alice's second event and Bob's second event concurrent?
print(f"Concurrent? {VectorClock.is_concurrent(alice.clock, bob.clock)}")
# Output likely True, because Alice's second event happened without knowing
# about Bob's second event, and vice versa.
```

**The Limitation:** The size of a vector clock grows linearly with the number of processes. For a system with 10,000 servers, a vector clock is a massive list of counters. This is impractical. Engineers use techniques like "dot clocks" (single vectors with version stamps) or "interval tree clocks" (ITC) to compress this data, but the fundamental principle remains.

### Section 5: The Synchronization Taboo: Distributed Consensus

We have logical time to order events. But what if we need to agree on a single, global, totally ordered sequence of operations? This is the problem of **Distributed Consensus**. This is the beating heart of systems like **ZooKeeper**, **etcd**, and **Chubby** (used by Google for GFS and Bigtable).

Consider a configuration service. It holds a simple key: `leader_ip = 192.168.1.1`. There are three servers. If one server crashes and a new one takes over, it needs to update this key. But if two servers simultaneously think they are the new leader and both try to write, we have a split-brain—a duel for the crown.

We need a protocol that guarantees that only one value is chosen, even if servers crash, messages are lost, or the network partitions.

#### Paxos: The Original Masterpiece

Leslie Lamport’s Paxos is the foundational algorithm. It is notoriously difficult to understand (Lamport himself struggled to explain it). But the core idea is elegant.

Paxos involves three roles (which can be combined in a single process):

1.  **Proposers:** They propose a value.
2.  **Acceptors:** They vote on proposals.
3.  **Learners:** They learn the result.

The protocol has two phases:

- **Phase 1 (Prepare):** A proposer chooses a proposal number $N$ (a unique, monotonically increasing number). It sends a `Prepare(N)` request to a majority of acceptors. Each acceptor promises to ignore any future proposals with a number less than $N$. If the acceptor has already accepted a proposal, it replies with the value it accepted and its proposal number.
- **Phase 2 (Accept):** If the proposer receives a majority of responses, it can now propose a value. If any acceptor returned a value (from a previous attempt), the proposer must use that value. Otherwise, it can choose its own value. It sends an `Accept(N, value)` request to the same acceptors. The acceptors check if they have promised a higher number. If not, they accept the value.

Paxos guarantees **Safety** (only one value is chosen) but not necessarily **Liveness** (it can get stuck in a loop of high-numbered proposals if multiple proposers keep trying).

#### Raft: The Practical Successor

For years, Paxos was the gold standard, but it was so complex that most implementations were buggy. In 2013, Diego Ongaro and John Ousterhout published the **Raft** consensus algorithm. Its goal was clarity above all else.

Raft decomposes the consensus problem into three sub-problems:

1.  **Leader Election:** Servers can be in three states: Follower, Candidate, or Leader. The Leader is the single authority. If a Follower does not hear from a Leader for a certain time (election timeout), it becomes a Candidate and starts a new election. It requests votes from other servers. A candidate wins if it gets a majority of votes. The winning server then becomes the Leader.
2.  **Log Replication:** The Leader accepts client commands (e.g., `SET key=value`). It appends the command to its own log. Then it sends `AppendEntries` messages to all followers. Followers append the command to their logs. The Leader waits for a majority to confirm. Once a majority confirms, the command is "committed" and applied to the state machine. The Leader then informs the followers that it was committed.
3.  **Safety:** Raft uses a few clever rules to prevent problems. The most important is the **Log Matching Property**: If two logs have an entry with the same index and term, they are identical for all preceding entries. This prevents a stale leader from overwriting committed entries.

**The Role of Time in Raft:** Raft relies on timeouts, specifically the **election timeout**. This is usually a value between 150ms and 300ms, randomized per server. This randomization is critical. It prevents multiple servers from starting an election at the same time, which would lead to a split vote and a stalemate. If the network is slow, the leader might time out even if it is healthy, triggering a needless election. If the timeouts are too short, the system spends more time electing leaders than serving requests.

**Real-World Failure:** In 2016, a major cloud provider experienced a cascading failure because of a bug in their use of etcd (a Raft-based key-value store). A network partition split the cluster. The majority partition elected a new leader. The minority partition, unable to reach the leader, also tried to elect a leader but failed repeatedly. This caused a "split-brain state" where both partitions thought they were the leader, but only the majority was functional. The system was designed to handle this, but the recovery logic relied on a manual operator intervention, which took hours.

### Section 6: Byzantine Fault Tolerance and the Limits of Synchrony

So far, we have assumed that servers follow the protocol. What if a server is malicious? This is the **Byzantine Generals Problem**.

Imagine a group of generals surrounding a city. They can only communicate by messenger. They must agree on a plan of attack or retreat. But one or more of the generals might be traitors, sending conflicting messages. A loyal general might receive "Attack" from one messenger and "Retreat" from another. How do they decide?

The classic solution, the **Practical Byzantine Fault Tolerance (PBFT)** algorithm, requires $3f + 1$ replicas to tolerate $f$ faulty replicas. It involves a multi-phase message exchange (pre-prepare, prepare, commit) that guarantees that if a majority of non-faulty nodes agree, the decision is final, even if Byzantine nodes try to sabotage the process.

**Blockchains and Time:** Bitcoin and Ethereum are Byzantine Fault Tolerant systems. They solve the double-spending problem without any central authority. But they do so in a fundamentally different way.

Bitcoin’s **Proof-of-Work** is a purely asynchronous system. There is no concept of "time" in the protocol itself. Two miners might find a valid block at the same time, leading to a "fork." The network resolves this using a simple rule: the longest chain wins. If a malicious actor tries to double-spend, they must outpace the entire honest network's mining power for multiple blocks. This is a probabilistic guarantee, not a deterministic one.

The "time" in Bitcoin is entirely synthetic. The block timestamp is a field, but it is not validated strictly (a node will reject a block if the timestamp is too far in the future or in the past, but the tolerance is several hours). Satoshi Nakamoto cleverly avoided the entire problem of clock synchronization by relying on computational effort instead.

### Section 7: Case Studies in Broken Time

Let's look at a few catastrophic failures that were, at their root, failures of time.

#### The Knight Capital Crash (2012)

In 45 minutes, Knight Capital Group, a high-frequency trading firm, lost $440 million and nearly collapsed. The root cause was a deployment error. A server was running old, retired code for a trading algorithm. This code had a flag that was supposed to be disabled. When the trading day started, the dead code was activated.

The old code started placing millions of orders. The new code tried to cancel them. The system was overwhelmed. But why did it matter? Because the orders were being timestamped by the exchange. The exchange uses an incredibly precise ordering system (often using a global clock like GPS). When two orders for the same stock arrive within microseconds, the exchange processes them in the order of arrival. The buggy algorithm essentially created a feedback loop that saturated the market. The time-based ordering made the feedback loop deterministic and deadly. If the market had been more "fuzzy," Knight might have survived. But in the world of HFT, a microsecond is the difference between profit and oblivion.

#### The 2015 New York Stock Exchange Flash Freeze

For nearly four hours, the NYSE halted trading. The official explanation was a "technical issue" related to a software upgrade. The unofficial details (later confirmed) pointed to a time synchronization problem. The exchange uses a specialized "Securities Information Processor" (SIP) that consolidates quotes and trades. The SIP runs on multiple servers. One of these servers had a clock that drifted by a few milliseconds. The system, designed to ensure consistency, detected the anomaly and shut itself down. The cost of preventing a potential collapse (a minor error) was an immediate, massive halt.

#### The AWS Kinesis and DynamoDB Incident (2018)

In November 2018, a major AWS region experienced a multi-hour outage of Kinesis (a real-time streaming service) and DynamoDB (a NoSQL database). The root cause was a cascading failure triggered by a scaling event. The operational team tried to add capacity. But a subtle bug in the fine-grained logging system caused a massive spike in load on the control plane. This spike triggered a "thundering herd" of recovery requests. Crucially, the recovery logic depended on **lease timestamps**. A lease is a time-limited lock. When the control plane was overwhelmed, it could not renew its leases. Other nodes saw the expired leases and tried to take over, creating an even bigger storm. The system was oscillating between nodes fighting for leases based on stale or expired time-based credentials.

The lesson? Time is a resource, and like any resource, it can be exhausted or poisoned. Leases are a classic technique, but they require the system to have a bounded, reliable clock. When the clock fails (or the network fails to deliver the renewal message), the lease mechanism becomes the attacker.

### Section 8: The Future – Precision Time Protocol (PTP) and Beyond

NTP is good, but for the most demanding applications (finance, 5G networks, industrial robotics), it is not good enough. We need sub-microsecond precision. Enter **Precision Time Protocol (PTP)**, defined in IEEE 1588.

PTP is like NTP on steroids.

- **Hardware Timestamping:** Standard NTP does timestamping in software (the OS kernel), which introduces variable latency. PTP uses specialized hardware (Network Interface Cards with built-in timestamping) that marks the packet the exact moment it leaves the wire. This eliminates the latency jitter.
- **Transparent Clocks:** In a PTP network, switches and routers can be "transparent clocks." They measure the time a packet spends in the switch and correct the timestamp accordingly. This accounts for queuing delays.
- **Grandmaster Clock:** The network uses a single "Grandmaster" (often a GPS-synchronized atomic clock). All other devices are "slaves" that are precisely slaved to the master.

With PTP, it is possible to get clock synchronization within **100 nanoseconds** or better over a local area network.

This is the backbone of **Google's Spanner**. Spanner is a globally distributed SQL database. It does not try to pretend all clocks are synchronized. Instead, it embraces the uncertainty. Every server has a GPS clock or an atomic clock. Each clock has a bounded "error interval" (e.g., `[current_time - 7ms, current_time + 7ms]`). This interval is called **TrueTime**.

When a transaction happens, Spanner assigns it a timestamp. But it doesn't assign a single point; it assigns an interval. The database can then use this interval to enforce **external consistency** (serializability). It can prove that transaction A happened before transaction B by ensuring that A's interval does not overlap with B's interval. If they overlap, Spanner waits (sleeps) until it is certain that the overlapping interval has passed. This is a direct acknowledgment that we cannot know the exact time, but we can know the _uncertainty_ and engineer around it.

### Conclusion: The Art of the Downbeat

We began with a symphony. The conductor’s baton gives the downbeat. In a distributed system, that downbeat is a fiction. It is an agreement, a consensus born of imperfect hardware, probabilistic network delays, and mathematical compromises.

We have learned that:

- **Physical clocks are unreliable.** Quartz crystals drift, and even GPS is susceptible to leap seconds and noise.
- **NTP is a first-order approximation.** It is good enough for most web applications but a liability for finance, telecoms, and databases.
- **Logical time solves the ordering problem.** Lamport and Vector clocks allow us to establish causality without needing wall-clock time.
- **Consensus algorithms (Paxos, Raft) provide deterministic safety.** They use timeouts as a heuristic, not as a source of truth. They are the gold standard for state machine replication.
- **Byzantine Fault Tolerance and Blockchains rely on probabilistic guarantees.** Bitcoin’s longest chain rule is a pure, clock-less algorithm.
- **Precision Time Protocol and TrueTime are the next generation.** They accept uncertainty and engineer around it.

The next time you double-click a web page and it loads instantly, remember the silent war being fought beneath your fingertips. It is a war against entropy, against the fundamental slipperiness of time. It is a war that is won, daily, by a confluence of brilliant algorithms, careful engineering, and a humble acceptance that we can never truly grasp the present moment. We can only, like a rowing crew blindfolded, strain to hear the faint, shared rhythm of the coxswain.

The orchestra plays on. The conductor’s baton may not be real, but the music is.
