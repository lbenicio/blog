---
title: "The Performance Of Distributed System Protocols Under Byzantine Failure: Pbft Vs. Hotstuff"
description: "A comprehensive technical exploration of the performance of distributed system protocols under byzantine failure: pbft vs. hotstuff, covering key concepts, practical implementations, and real-world applications."
date: "2024-10-12"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-performance-of-distributed-system-protocols-under-byzantine-failure-pbft-vs.-hotstuff.png"
coverAlt: "Technical visualization representing the performance of distributed system protocols under byzantine failure: pbft vs. hotstuff"
---

# The Ghost in the Machine: When Trust Fails, and Protocols Must Endure

Imagine you are a system architect. You have designed a robust, replicated state machine—a bank ledger, a stock exchange, a blockchain validator. Your code is clean, your network is provisioned, and your consensus protocol, perhaps a simple Paxos or Raft, hums along efficiently. You can handle a node crashing (fail-stop); you have backups. Life is good.

Then, the ghost appears.

A node begins to behave not just as a lifeless hunk of metal, but as a malevolent actor. It signs contradictory messages. It delays packets selectively. It colludes with other misbehaving nodes to lie about the state of the world. This is not a crash. This is the Byzantine Fault. It is the ultimate stress test for a distributed system—a scenario where a component can fail in any way imaginable, including outright deception. This is the world of Byzantine Fault Tolerance (BFT), a field that has moved from a 30-year-old thought experiment to the bedrock of modern decentralized finance, permissioned ledgers, and critical infrastructure.

For years, one protocol was the undisputed champion of practical BFT: **Practical Byzantine Fault Tolerance (PBFT)** . Published by Miguel Castro and Barbara Liskov in 1999, PBFT was the first system to demonstrate that Byzantine resilience could be achieved with acceptable latency and throughput for practical use. It solved the "Byzantine Generals Problem" not just in theory, but in a running system. It was the gold standard, the go-to for any architect building a Byzantine-resilient system.

But the world of distributed systems is a crucible of constant optimization. The demands for higher throughput, lower latency, and, critically, **scalability** (more nodes) have continued to escalate. The elegant, three-phase protocol of PBFT (Pre-Prepare, Prepare, Commit), while revolutionary, began to show its age. Its communication complexity—O(n²) messages per consensus round—becomes a severe bottleneck as the number of replicas grows. In a system with 100 nodes, each proposed block requires nearly 10,000 messages to be exchanged and verified. Latency balloons. Throughput tanks. The ghost, once exorcised, finds new ways to haunt you.

This blog post is a journey through the Byzantine landscape. We will start at the origin—the Byzantine Generals Problem itself—and then dissect PBFT in excruciating detail, revealing both its genius and its limitations. We will then explore the modern successors that have emerged to address PBFT’s scalability weaknesses: protocols like SBFT, HotStuff, HoneyBadgerBFT, and the DAG-based Narwhal & Tusk. Along the way, we will examine real-world deployments (Hyperledger Fabric, Diem/Libra, Cosmos/Tendermint) and distill the core trade-offs that every BFT system designer faces. By the end, you will understand not only how to banish the Byzantine ghost, but also how to build systems that thrive even when the ghost is determined to bring them down.

---

## Chapter 1: The Byzantine Generals Problem – A Formal Nightmare

Before we can appreciate PBFT, we must understand the problem it solves. The Byzantine Generals Problem (BGP) was introduced by Leslie Lamport, Robert Shostak, and Marshall Pease in their seminal 1982 paper, “The Byzantine Generals Problem.” The scenario is a military metaphor: Several divisions of the Byzantine army are camped outside an enemy city. Each division is commanded by a general. The generals must agree on a common plan: either attack or retreat. They communicate only by messenger. Some generals may be traitors, actively trying to sabotage the agreement. The loyal generals must nonetheless reach a consensus.

Formally, we have _n_ processes (generals), of which up to _f_ can be Byzantine (arbitrary faulty). The processes have a binary input (attack/retreat). We need a protocol that guarantees:

1. **Agreement**: All non-faulty processes decide on the same value.
2. **Validity**: If all non-faulty processes have the same input, that input is the decision.
3. **Termination**: All non-faulty processes eventually decide.

The paper proved a fundamental impossibility result: In a system with only oral messages (no signatures), consensus is possible if and only if _n > 3f_. In other words, you need at least 3f+1 nodes to tolerate f Byzantine faults. If you have only 3 nodes, you can tolerate 0 Byzantine faults (1 faulty would break consensus). With 4 nodes, you can tolerate 1 faulty. With 7 nodes, 2 faulty, and so on.

Why 3f+1? The intuition is that a Byzantine node can lie about everything, so a non-faulty node cannot distinguish between a faulty sender and a faulty network. In the worst case, the faulty nodes can create conflicting versions of reality, and the loyal nodes must have enough redundancy to outvote them. The classic proof uses a “three generals” scenario with one traitor to show impossibility when n=3.

**Signed messages** (digital signatures) change the game. With signatures, a Byzantine node cannot impersonate another, and a message that is signed is undeniable. The lower bound becomes _n > 2f_ for Byzantine consensus with signed messages (a simple majority suffices). However, the problem of deciding on a value still requires interactive consistency, and many practical BFT protocols rely on signatures or other cryptographic primitives (like threshold signatures or MACs) to reduce the number of messages.

PBFT, notably, does **not** use full public-key signatures for every message in its normal-case path (to save CPU time) but uses message authentication codes (MACs) for point-to-point authentication. However, during view changes, digital signatures are used to prove the authenticity of historical messages.

The Byzantine Generals Problem is more than a theoretical curiosity—it directly models the challenges faced by any distributed ledger or state machine that must operate in an untrusted environment. Every blockchain is a Byzantine generals system where miners/validators are the generals, and the block proposals are the orders.

---

## Chapter 2: The Practical Revolution – PBFT in All Its Glory

In 1999, Miguel Castro and Barbara Liskov published “Practical Byzantine Fault Tolerance” at the Symposium on Operating Systems Design and Implementation (OSDI). Before PBFT, Byzantine protocols were considered too expensive for real use: they required many rounds of communication and had high message complexity. PBFT demonstrated that with careful engineering (batching, state-transfer checkpoints, and view changes) Byzantine resilience could be achieved with performance comparable to crash-tolerant replication.

### 2.1 System Model

PBFT assumes a network of _n_ replicas, where _n = 3f + 1_. The system is **partially synchronous**: there is an unknown global stabilization time (GST) after which the network becomes synchronous (messages are delivered within a known bound). Before GST, messages may be arbitrarily delayed, reordered, or lost. This is a realistic model for the Internet.

Each replica has a unique identity and can sign messages (using digital signatures for view changes, and MACs for normal operations). The replicas maintain a sequence of operations (a log) that define the state machine. Clients send requests to be executed, and the replicas agree on a total order of requests.

### 2.2 The Magic Number: 3f+1

Why 3f+1 for PBFT? Because during normal operation, every message is sent to all replicas (including the faulty ones). The protocol requires a quorum of _2f+1_ replicas to agree on each step. With 3f+1 total, and up to f faulty, any two quorums of size 2f+1 intersect in at least f+1 replicas, guaranteeing that at least one honest replica is in both quorums. This ensures that decisions can be cross-checked and that no conflicting decisions can be made.

### 2.3 Protocol Phases (Normal Case)

The protocol runs in **views**. Each view has a designated **primary** (leader) replica, selected in a round-robin fashion. The primary is responsible for ordering client requests. The normal-case operation consists of three phases:

1. **Pre-Prepare**: The primary receives a client request _m_. It assigns a sequence number _n_ and sends a _Pre-Prepare_ message to all backups: `<<PRE-PREPARE, v, n, d>σ_p, m>`, where v is the view number, d is the digest of m, and the whole thing is signed by the primary.

2. **Prepare**: Each backup replica, upon receiving a valid Pre-Prepare, multicasts a _Prepare_ message to all other replicas: `<<PREPARE, v, n, d, i>σ_i>`. It also logs the Pre-Prepare. When a replica collects _2f+1_ Prepare messages (including its own) that match the view, sequence number, and digest, it enters the _Prepared_ state. That is, it knows that a quorum of replicas has committed to ordering request _m_ at sequence _n_ in view _v_.

3. **Commit**: After entering the Prepared state, the replica multicasts a _Commit_ message: `<<COMMIT, v, n, d, i>σ_i>`. When it receives _2f+1_ Commit messages that match, it executes the request and sends the result to the client.

Why three phases? The Prepare phase ensures that even if the primary is faulty, replicas cannot commit conflicting orders. The Commit phase ensures that even if some replicas crash or are delayed after Prepare, the remaining replicas can still make progress. The third phase is crucial for the **view change** mechanism (more later).

### 2.4 Garbage Collection and Checkpoints

To manage storage, PBFT uses periodic **checkpoints**. A checkpoint is a snapshot of the state at a certain sequence number. When a replica has executed all requests up to sequence number _n_ and receives _2f+1_ checkpoint messages (proving that a quorum agrees on that state), it can discard the logs prior to that checkpoint. This also limits the amount of data that must be transferred during view changes.

### 2.5 View Changes

If the primary is suspected to be faulty (e.g., not sending a Pre-Prepare within a timeout), replicas initiate a **view change**. They send a `VIEW-CHANGE` message to the next designated primary (view v+1), containing the last stable checkpoint and a set of prepared certificates (proof of prepared messages). The new primary collects _2f+1_ view-change messages, then broadcasts a `NEW-VIEW` message that includes a set of valid requests to re-propose. The new primary “propagates” the sequence numbers from prior views to avoid gaps. This ensures liveness even if up to f replicas are faulty.

The view change protocol is O(n²) as well, but because it is only triggered on failure, it is tolerable in practice. However, in a system with high latency or many failures, view changes can become a bottleneck.

### 2.6 Complexity Analysis

The message complexity of PBFT’s normal case is **3n(n−1) messages**? Let's compute precisely: Each of the three phases involves a multicast from every replica to all others (O(n²) messages per phase). That is 3 broadcasts. In practice, the primary sends n-1 Pre-Prepares, then each of n replicas sends n-1 Prepares = n(n-1), and similarly for Commits. That totals about 3n² messages. For n=4, that's 48 messages. For n=100, it's 30,000 messages. Multiply by message size (digests, MACs, etc.) and network latency, and the overhead becomes significant.

PBFT also requires **O(n²) signature verifications** per replica (if using digital signatures). The original PBFT used MACs to reduce verification cost, but MACs require pairwise shared keys, leading to O(n²) symmetric key distribution and storage. For small n (< 20) this is acceptable; for large n it becomes unwieldy.

### 2.7 Real-World Performance

In the original paper, PBFT was implemented as a library with the BFT-REPLICAT and BFT-CLIENT library. On a network of 4 machines (3f+1 = 4, f=1), they achieved around 30,000 requests per second for small requests (like a null operation) and about 10,000 requests per second for larger requests (1KB). Latency was under a few milliseconds. This was orders of magnitude better than any previous Byzantine protocol.

---

## Chapter 3: PBFT in Practice – Deployment Stories

### 3.1 The First Deployments: Microsoft Research and Beyond

After publication, PBFT was deployed in several experimental systems at Microsoft Research, including the FARSITE distributed file system and the BFT-based state machine replication for Internet-scale services. It also influenced the design of the first generation of permissioned blockchains, such as **Hyperledger Fabric v0.6** (which used PBFT directly) and **ZooKeeper** (eventually replaced by Zab, a crash-tolerant protocol, but PBFT inspired some ideas).

### 3.2 PBFT and Blockchain

When Satoshi Nakamoto introduced Bitcoin in 2008, the Bitcoin consensus (proof-of-work) solved Byzantine agreement without a permissioned set of nodes, but at enormous energy cost and low throughput (7 tps). Permissioned blockchains, like those used in enterprise consortia, turned back to classical BFT protocols for higher performance. IBM’s Hyperledger Fabric initially adopted PBFT for ordering. However, as consortium size grew beyond 10–20 nodes, PBFT’s quadratic message complexity caused throughput to drop and latency to spike. Hyperledger Fabric v1.0 replaced PBFT with a pluggable consensus architecture, and most deployments now use Raft (crash-tolerant) or Kafka-based ordering, because trust assumptions in many enterprises allow a single trusted ordering service. But the need for full Byzantine resilience persists in hostile environments.

---

## Chapter 4: The Scalability Wall – Why PBFT Fails at Scale

### 4.1 The O(n²) Bottleneck

Let’s calculate the maximum number of nodes PBFT can handle before throughput collapses. Assume a 1 Gbps network with 100µs round-trip time. Each message carries a signature (64 bytes for ECDSA) and a payload. In a 100-node system, each Prepare phase sends ~10,000 messages. If each message takes 100µs to send (queuing delays ignored), the total time for one phase is 1 second. With three phases, that’s 3 seconds per request. Throughput might be 300 requests per second at best. Compare this to a crash-tolerant protocol like Raft, which uses O(n) messages (leader sends AppendEntries to all, they reply, 2n messages). Raft with 100 nodes can easily do thousands of requests per second. The gap widens with n.

### 4.2 The CPU and Key Management Burden

Each replica must verify MACs from all other replicas. If using MACs, each replica shares a symmetric key with every other replica, leading to O(n²) key storage. For n=1000, that’s ~500,000 keys. Key rotation becomes a nightmare. Digital signatures ease this (public keys are shareable), but signature verification costs are high (ECDSA verify ~1-2 ms on modern CPUs). Verifying 1000 signatures per round per replica is CPU-bound.

### 4.3 Memory and Storage Overhead

PBFT keeps logs of all messages until a checkpoint is established. With up to 2f+1 prepares and commits per sequence number, memory usage grows as n². For n=100, that’s tens of MB per node; for n=1000, it could be gigabytes.

### 4.4 View Change Amplification

When a primary fails, view change requires gathering O(n²) messages as well, and then the new primary must re-propose many sequence numbers. In a system with high churn or network instability (e.g., intermittent partitions), view changes can dominate execution time, leading to livelock.

### 4.5 The Asynchrony Trap

PBFT relies on timeouts to detect primary failure. In an asynchronous network, it’s impossible to distinguish a slow primary from a faulty one. Thus, PBFT can trigger view changes unnecessarily, wasting bandwidth. The original paper assumed enough synchrony for liveness, but in practice, Internet-scale deployment can suffer from false positives.

---

## Chapter 5: The Next Generation – Protocols That Break the O(n²) Curse

The quest for scalable BFT has produced several innovative protocols that reduce communication complexity, leverage cryptography cleverly, and pipeline steps to increase throughput. Let’s survey the landscape.

### 5.1 SBFT (Simplifying Byzantine Fault Tolerance)

Proposed in 2019 by Gueta et al., SBFT aims to reduce message complexity from O(n²) to O(n) in the optimistic case by introducing a **collector** (or “committer”) that aggregates signatures. SBFT uses a **threshold signature** scheme: once 2f+1 replicas have signed the same block, the collector combines these into a single short signature. This reduces the final commit message to one small packet. Additionally, SBFT introduces a **fast path** where only two communication steps are needed (Propose and Commit) if all replicas are honest. The protocol is designed to run efficiently for up to a few hundred replicas. However, the fast path still requires O(n) messages from replicas to collector.

### 5.2 HotStuff: Linear BFT with a Leader-Directed Pipeline

HotStuff, introduced by Yin et al. in 2019, is the protocol behind the **Diem** (formerly Libra) blockchain. It achieves **linear** message complexity (O(n) per round) by using a **leader-based** approach with a pipe of views. The leader proposes a block, replicas vote, and the leader collects 2f+1 votes into a **QC (Quorum Certificate)** . The QC is then included in the next proposal, forming a chain. Only the leader communicates with all replicas; replicas only send votes to the leader (O(n) total messages). HotStuff has three variants: classic (three phases), two-phase, and one-phase under optimistic conditions. The basic three-phase HotStuff still has O(n) votes per round, but the total communication per block is O(n) (plus the block itself broadcast). This is a dramatic improvement over PBFT’s O(n²). HotStuff also simplifies view changes: a new leader only needs a single round of communication to collect QCs from replicas. The protocol is synchronous in the sense that it uses timeouts, but it is designed to minimize the cost of view changes.

**Trade-off**: The leader bears a heavy load (sending to all, verifying all votes). To avoid leader bottleneck, HotStuff rotates the leader every block. This is fine for blockchain contexts but can be suboptimal in WAN settings where leaders are far away.

### 5.3 HoneyBadgerBFT – Asynchronous BFT without Timers

What if we want to tolerate network asynchronicity entirely? HoneyBadgerBFT (Miller et al., 2016) is an asynchronous protocol that achieves consensus with optimal resilience (n > 3f) using a **randomized** approach. It uses a threshold encryption scheme and a common coin (via threshold signatures) to break ties. It has expected O(n²) communication per block but works even under adversarial network delays. It’s the basis for the **Dusk** blockchain and several other projects. However, the high overhead (due to asynchronous common coin) limits throughput to a few thousand tps for small n.

### 5.4 Narwhal & Tusk – DAG-Based BFT

A breakthrough in scalability came with Narwhal & Tusk (Danezis et al., 2021), which layer a communication-efficient mempool (Narwhal) on top of a DAG-based consensus (Tusk). Narwhal disseminates blocks in a **Directed Acyclic Graph** structure, where each replica broadcasts its block to all others and references the previous blocks it has seen. This spreads the communication load; no single peer is overburdened. Tusk then runs a simple round-based consensus on the DAG: each round, a random leader is selected via common coin, and its block (and its predecessors) become the next committed block. This achieves O(n) messages per block (each replica sends one block per round) and high throughput (over 80,000 tps in geo-distributed settings with 50 nodes). The system is now deployed in **Sui** (by Mysten Labs) and **Mysten**’s other projects.

The DAG structure also enables parallel execution (once ordering is determined) and efficient recovery.

### 5.5 Comparison of Modern BFT Protocols

| Protocol     | Message Complexity (normal)    | Resilience | Crypto Use           | Suitable For                    |
| ------------ | ------------------------------ | ---------- | -------------------- | ------------------------------- |
| PBFT         | O(n²)                          | n=3f+1     | MACs + signatures    | Small consortia (<20 nodes)     |
| SBFT         | O(n) (fast path), O(n²) (slow) | n=3f+1     | Threshold signatures | Medium (50-100 nodes)           |
| HotStuff     | O(n)                           | n=3f+1     | BLS signatures       | Permissioned blockchains (Diem) |
| HoneyBadger  | O(n²) expected                 | n=3f+1     | Threshold encryption | Asynchronous settings           |
| Narwhal+Tusk | O(n) per round (DAG)           | n=3f+1     | BLS signatures       | High-throughput blockchains     |

---

## Chapter 6: The Cryptographic Toolbox

To build modern BFT, you need more than just clever networking. Cryptography is the multiplier that turns O(n²) into O(n). The key primitives are:

- **Threshold Signatures**: A group of signers (size ≥ t) can produce a single short signature that validates as a collective signature. In BFT, a quorum of 2f+1 replicas can produce a threshold signature for a block, reducing the certificate to one signature. This eliminates the need to send 2f+1 individual signatures.
- **Boneh–Lynn–Shacham (BLS) Signatures**: A special pairing-based signature that supports aggregation. Used in HotStuff and Narwhal. It’s signature and verification cost is higher than ECDSA, but aggregation makes it worthwhile.
- **Verifiable Secret Sharing (VSS)**: Used for generating common coins reliably, as in HoneyBadgerBFT.
- **Threshold Encryption**: Allows sending a message encrypted to a group such that any t members can decrypt. Used in HoneyBadgerBFT to hide proposals until a common coin is revealed.

Using these tools, modern BFT protocols can operate with hundreds of nodes efficiently.

---

## Chapter 7: Real-World Lessons – Deploying BFT at Scale

### 7.1 Diem (Libra) and HotStuff

When Facebook announced the Libra cryptocurrency in 2019, they used a permissioned BFT protocol based on HotStuff. The LibraBFT variant improved liveness by using a round-robin leader and a mechanism for fast view changes. The network initially consisted of around 100 validator nodes. HotStuff was chosen precisely because of its linear communication and robustness against primary failures. The protocol was running on a testnet achieving several thousand transactions per second. Diem’s eventual shutdown was due to regulatory pressure, not technical failure.

### 7.2 Sui and Narwhal/Tusk

Sui, a Layer 1 blockchain from Mysten Labs (founded by former Diem engineers), uses Narwhal & Tusk as its mempool and consensus layer. In benchmarks with 100 validators deployed across five continents, Sui achieved over 120,000 tps with sub-second finality. The key is that the DAG-based mempool decouples data dissemination from ordering, allowing parallel broadcasting without a leader bottleneck. Sui also uses object-centric execution, but the consensus layer is pure BFT.

### 7.3 Cosmos/Tendermint – Classic BFT with a Twist

Tendermint, used in Cosmos, is a variant of PBFT with a rotating leader and a simplified view change (called round change). It uses a **blockchain** structure: each round proposes a block, and if successful, it’s appended to the chain. Tendermint achieves O(n²) messages per round (like PBFT), but it’s designed for the specific case of a public, permissioned set of validators (up to ~100). Tendermint has been proven secure and is widely deployed.

### 7.4 Hyperledger Fabric’s Journey

Hyperledger Fabric started with PBFT (v0.6) but quickly discovered its limitations. The v1.0 architecture introduced a pluggable ordering service; most deployments now use Raft or Kafka because they trust the ordering nodes (a single organization). However, for truly Byzantine environments, Fabric offers the **BFTSmart** library (a successor to PBFT) and **Mir-BFT** (a permissioned BFT protocol that also uses a DAG-like structure). The lesson: pick your trust assumption carefully—BFT is expensive, don’t pay for it if you don’t need it.

---

## Chapter 8: The Future – Beyond 3f+1, Beyond Signatures

Even linear BFT protocols have limitations. The leader still must broadcast the block to all replicas (O(n) bytes). If the block is large (e.g., 10 MB for a high-throughput blockchain), the leader’s egress bandwidth becomes a bottleneck. Solutions include **erasure coding** (e.g., DispersedLedger) to split blocks across replicas and **network coding**.

Another frontier is **asynchronous BFT** with optimal resilience and O(n) throughput. **Dumbo** (Gao et al., 2020) and **Streamlet** (improved asynchrony version) are recent proposals. There is also the promise of **information-theoretic BFT** (no cryptography) under certain network assumptions, but with higher message complexity.

Finally, **byzantine fault tolerance with mobile adversaries** (where an attacker can compromise different nodes over time) forces protocols to refresh keys and use proactive secret sharing.

---

## Conclusion: The Ghost Exorcised, but Never Banished

The Byzantine fault remains the ultimate adversary in distributed computing. PBFT showed us that we could defeat it in practice, but at the cost of quadratic communication—an affliction that worsens as systems scale. Modern BFT protocols have turned the tide by using threshold cryptography, pipelining, and DAG structures to achieve linear message complexity, enabling networks of hundreds of replicas with thousands of transactions per second.

Yet, the ghost is cunning. Every optimization opens new attack surfaces: leader monopolization, network congestion, eclipse attacks, and side-channel leaks. There is no silver bullet; Byzantine resilience is a continuous game of cat and mouse.

For the system architect, the takeaway is twofold. First, understand your threat model: Do you need full Byzantine tolerance, or is crash tolerance sufficient? Second, if you must fight the ghost, choose a protocol that matches your scale. For small, static consortia, PBFT or its direct descendants (Tendermint) are battle-tested. For larger, dynamic networks, consider HotStuff or Narwhal/Tusk. And always plan for the unexpected—because the ghost is always watching, waiting for the moment trust fails.

---

_This article was written for [Your Blog Name]. For further reading, see the original PBFT paper (Castro & Liskov, 1999), the HotStuff paper (Yin et al., 2019), and the Narwhal & Tusk paper (Danezis et al., 2021)._
