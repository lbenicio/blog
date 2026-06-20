---
title: "Flp Impossibility Distributed Consensus Foundations"
date: 2019-07-04
draft: false
cover: "/static/assets/images/blog/flp-impossibility-distributed-consensus-foundations.png"
tags: ["technical", "computer-science"]
---

# FLP Impossibility: The Fundamental Barrier to Distributed Consensus

## Introduction: Why Consensus Matters and Why It’s Shocking

Distributed systems are the backbone of modern computing. From cloud databases that replicate your data across continents to blockchains that secure digital currencies, the ability for multiple independent machines to agree on a single value—the consensus problem—is paramount. Without consensus, we cannot have reliable banking systems, coordinated server updates, or fault-tolerant state machines. Yet, buried deep in the theoretical foundations of distributed computing lies a result so surprising and so profound that it reshaped the entire field: the FLP impossibility.

In 1985, Michael Fischer, Nancy Lynch, and Michael Paterson published a paper titled "Impossibility of Distributed Consensus with One Faulty Process." The core result is stark: in an asynchronous distributed system where even a single process can fail by crashing, no deterministic algorithm can guarantee that all non-faulty processes will agree on a common value. This is not a limitation of a specific algorithm or a particular set of assumptions—it is a fundamental, mathematical impossibility.

Why is this shocking? Because intuitively, consensus seems achievable. If we have two computers connected by a network, we can simply exchange messages and agree. But the FLP result reveals that the combination of asynchrony (no bounds on message delays or process speeds) and the possibility of a crash creates a scenario where an adversary can always keep the system indecisive, introducing a lingering uncertainty that no deterministic algorithm can resolve. This impossibility has profound implications: it tells us that any practical consensus algorithm must weaken the problem—by adding synchrony assumptions, randomization, or failure detectors—to become viable.

In this blog post, we will dive deep into the FLP impossibility result. We will start with the necessary background on distributed systems and consensus, then walk through the formal model and the proof step by step. We will examine the implications, show how real-world systems circumvent the impossibility, and provide detailed code examples to illustrate the subtle dynamics. By the end, you will understand not only why consensus is impossible in the pure asynchronous model, but also how engineers have built robust systems that live within the boundaries of that impossibility. This is a journey into the heart of distributed computing theory—one that every serious practitioner must take.

---

## Background: The Consensus Problem and Distributed System Models

Before we can appreciate the FLP result, we need to ground ourselves in the fundamental concepts of distributed consensus and the system models under which it is studied.

### What is Consensus?

Consensus is the problem of having a set of processes (often called nodes or participants) each propose a value, and then agree on one of those values as the final decision. Formally, a consensus algorithm must satisfy three properties:

- **Agreement**: All non-faulty processes must decide on the same value.
- **Validity**: If all processes propose the same value, then any non-faulty process must decide that value.
- **Termination**: Every non-faulty process eventually decides some value.

These properties seem simple, but achieving them in a distributed system is notoriously difficult because of failures and unpredictable delays.

### System Models: Synchronous vs. Asynchronous

The behavior of a distributed system is characterized by assumptions about process speeds and message delivery times. Two primary models are studied:

1. **Synchronous Model**: There is a known upper bound on message delivery time and on the relative speed of processes. Processes operate in rounds; in each round, they send messages and receive all messages that were sent in that round. This model makes consensus solvable with simple algorithms (e.g., a coordinator-based approach). However, the real world is rarely synchronous—network delays are unbounded, and processes can be arbitrarily slow.

2. **Asynchronous Model**: There is no upper bound on message delivery time, and processes can operate at arbitrary speeds. Messages may be delayed arbitrarily (but are eventually delivered). This is a more realistic model for large-scale, open networks like the Internet. The FLP impossibility applies to this model.

### Failure Models: Crash Failures

In the FLP paper, the only failure considered is a **crash failure**: a process stops executing its algorithm and sends no further messages. Once a process crashes, it never recovers. This is the weakest failure model—no malicious behavior (Byzantine) is assumed. Yet even this simple fault makes consensus impossible in an asynchronous environment.

It is important to note that the FLP result assumes at most one process can crash. If more could crash, the impossibility only becomes stronger. Also, the system is assumed to have reliable communication channels (messages are not lost, duplicated, or corrupted). Despite these idealized conditions, the impossibility stands.

### Deterministic Algorithms

The FLP impossibility is about deterministic algorithms. That is, the algorithm's actions at each step are fully determined by its previous state and the messages received. Randomization (coin flips) can break the impossibility, as can failure detectors that provide hints about failures, but these are workarounds that weaken the model.

---

## The FLP Model: Formal Definitions

To prove impossibility, we must define the system with mathematical precision. The FLP model uses an asynchronous system of processes that communicate by sending messages. Let's formalize the key components.

### Processes

There are \( n \geq 2 \) processes (often called \( P_1, P_2, \dots, P_n \)). Each process runs a deterministic algorithm. Initially, each process has an input value (usually 0 or 1 for binary consensus). A process can perform three types of actions:

- Send a message to another process.
- Receive a message from another process.
- Perform local computation (including deciding a value and halting).

### Configuration and Events

A **configuration** is a global snapshot of the system: the internal state of each process (including its input, decision status, and message buffer), plus the set of messages in transit. The system evolves through **events**, where an event is a pair \((p, m)\) meaning process \(p\) receives message \(m\). When this event occurs, the process's state changes according to its algorithm, and it may send new messages (which are appended to the message buffer). Note that the model assumes **reliable FIFO channels**: messages are not lost, and if \(p\) sends \(m\) to \(q\), then \(m\) will eventually be delivered at \(q\), but with unknown delay.

### Schedules and Runs

A **schedule** is a finite or infinite sequence of events. A **run** from a starting configuration is the sequence of configurations obtained by applying each event in order. Because the system is asynchronous, any schedule that respects the causal order (i.e., no event happens before its prerequisite sends) is admissible. An adversarial **scheduler** (often called an adversary) can choose which events occur next, with the only constraint being that if a non-faulty process has pending messages, it will eventually receive one (fairness). The adversary can crash a process at any time; after a crash, that process stops taking steps.

### Decision and Valency

A process is said to **decide** if it transitions to a decision state—a state where its decision is irrevocable. After deciding, it may continue to communicate or halt.

A configuration is **univalent** if all runs from that configuration lead to the same decision value (either all 0 or all 1). A configuration is **bivalent** if there exist runs from that configuration that lead to a decision of 0 and runs that lead to a decision of 1. The FLP proof shows that in any consensus algorithm that purports to work in an asynchronous system with crash failures, there must be an initial bivalent configuration. Then, it shows that from a bivalent configuration, one can always avoid reaching a univalent configuration indefinitely—meaning termination cannot be guaranteed.

### The Adversary

The adversary (scheduler) controls the order of message deliveries and can decide when to crash a process (up to one crash). The adversary knows the algorithm and can adaptively choose events to prevent agreement. The crucial point is that in an asynchronous system, the adversary can delay messages arbitrarily, making it impossible to distinguish a crashed process from a slow one. This uncertainty is central to the impossibility.

---

## The Impossibility Proof: Step-by-Step

The FLP proof is elegant yet subtle. It proceeds in two major lemmas and then the main theorem. We'll walk through each step with careful reasoning.

### Statement to Prove

_No deterministic algorithm can solve consensus in an asynchronous distributed system with reliable channels if at least one process may crash._

We assume (by contradiction) that there exists such an algorithm \(A\) that guarantees agreement, validity, and termination with at most one crash. The proof constructs an infinite run that never decides, violating termination.

### Lemma 1: There is an initial bivalent configuration

**Proof**:

Assume, to the contrary, that all initial configurations are univalent. That means every initial configuration leads to a unique decision value. Consider two initial configurations that differ only in the input of a single process. For example, \(C_0\) where process 1 has input 0 and all others have 0, and \(C_1\) where process 1 has input 1 and all others have 0. Since all inputs are identical except one, by validity, \(C_0\) must eventually decide 0 (because all inputs are 0 in that configuration?), wait—validity says: if all processes propose the same value v, then any non-faulty process must decide v. In \(C_0\), all processes propose 0, so the only possible decision is 0. Similarly, in \(C_1\), process 1 proposes 1, but others propose 0; validity does not force a particular value because inputs are not all equal. However, we assumed all configurations are univalent. So \(C_1\) must have a commitment to either 0 or 1. Without loss of generality, suppose \(C_1\) is 1-valent (leads to decision 1). Now consider a chain of configurations where we flip the input of process 1 from 0 to 1 step by step, while keeping all other inputs constant. By the pigeonhole principle, there must be a pair of adjacent configurations in this chain where one is 0-valent and the other is 1-valent. This pair differs only in the input of a single process. Let that process be \(p\), and let the two configurations be \(C\) (0-valent) and \(C'\) (1-valent), where \(C'\) is obtained from \(C\) by changing \(p\)'s input from some value \(a\) to \(b\) ( \(a \neq b\) ).

Now consider a run that is identical in both configurations except that process \(p\) might crash immediately after the start. If \(p\) crashes, then the rest of the system cannot distinguish between \(C\) and \(C'\) because the only difference is \(p\)'s input, which is lost. Therefore, from the perspective of the other processes, runs from \(C\) and from \(C'\) are indistinguishable if \(p\) crashes before sending any messages. Hence, the decision in both runs must be the same (since the algorithm is deterministic). But then that would force both \(C\) and \(C'\) to be the same valent, a contradiction. So the assumption that all initial configurations are univalent is false—there must exist at least one bivalent initial configuration.

This step uses the fact that a single crash can make the initial input of that process invisible to the rest. The adversary can force the system into a bivalent state right at the start.

### Lemma 2: From a bivalent configuration, it is always possible to avoid reaching a univalent configuration

This is the heart of the proof. We need to show that in any bivalent configuration \(G\), there is always a run (a schedule of events) that leads to another bivalent configuration, thus allowing the system to remain indecisive indefinitely.

We consider a **critical state**: a bivalent configuration where executing any single event (receiving a pending message) leads to a univalent configuration. If we can show that no such critical state exists (i.e., from any bivalent configuration, we can always execute a step and remain bivalent), then we can keep extending the run forever without deciding.

So, suppose (for contradiction) that there exists a critical configuration \(C\). That is, \(C\) is bivalent, but for every pending message event \(e\), the configuration \(C' = e(C)\) is univalent (either 0-valent or 1-valent). Since \(C\) is bivalent, there must be at least two events that lead to different valencies (otherwise all would lead to the same valent, and \(C\) would be univalent). Let \(e_1\) and \(e_2\) be two events that lead to 0-valent and 1-valent configurations respectively. Now, note that these two events involve possibly different processes. There are two cases:

1. **The two events involve the same process \(p\)**. That means \(C\) has two pending messages for \(p\), say \(m_1\) and \(m_2\). If we apply \(e_1\) then later apply \(e_2\), we get some configuration; the order might matter. But since \(p\) is deterministic, after \(e_1\) it may or may not have changed its state such that \(e_2\) is no longer applicable? Actually, events are defined as receiving a specific message. After \(p\) receives \(m_1\), its state changes and it may send new messages. The other pending message \(m_2\) remains in the message buffer. So we can consider a schedule: first apply \(e_1\), then later apply \(e_2\). Because \(e_1\) leads to a 0-valent configuration, all runs from that configuration decide 0. However, if we apply \(e_2\) after \(e_1\), we are in a subrun from a 0-valent configuration, so the decision will still be 0. But from \(C\), we could also apply \(e_2\) first. That leads to a 1-valent configuration. Now consider the schedule where we apply \(e_2\), but then immediately crash process \(p\) (if it hasn't already crashed). After \(p\) crashes, the system cannot distinguish between the schedule that applied \(e_1\) before \(e_2\) and the schedule that applied \(e_2\) before \(e_1\) with \(p\) crashed. Why? Because in both cases, \(p\) has received one message and then stopped; the order of the two messages is not observable by other processes. This indistinguishability leads to a contradiction because the two schedules would have to lead to the same decision (since the rest of the system sees the same events in a different order but cannot tell), but one leads to 0 and the other to 1. Thus this case is impossible.

2. **The two events involve different processes \(p\) and \(q\)**. Since events are independent (they involve receiving messages by different processes), the order of these two events from \(C\) gives the same resulting configuration regardless of order (because the processes don't interact in that step). Specifically, let \(C*{pq}\) be the configuration after applying both events in either order. Then both \(C*{pq}\) is reachable from both the 0-valent and 1-valent configurations. If we start from the configuration after \(e*1\) (0-valent), then applying \(e_2\) leads to \(C*{pq}\) which must be 0-valent (since all runs from a 0-valent configuration decide 0). Similarly, starting from \(e*2\) (1-valent) and applying \(e_1\) also leads to \(C*{pq}\), which would then be 1-valent. But \(C\_{pq}\) cannot be both 0- and 1-valent—contradiction. Therefore, the assumption that a critical configuration exists is false.

Thus, from any bivalent configuration, there is always at least one event that keeps the system bivalent. The adversary can choose that event.

### Main Theorem: An infinite run that never decides

Now we combine the two lemmas. Start from an initial bivalent configuration (Lemma 1). From that configuration, by Lemma 2, there is a schedule that keeps the system bivalent forever. But the algorithm must guarantee that from every reachable configuration, if all non-faulty processes continue to receive messages, they eventually decide. However, the schedule constructed does not crash any process (or crashes at most one? Actually, the adversary can also crash one process to help maintain bivalence, but the proof shows we can always avoid deadlock without necessarily crashing anyone. In fact, the schedule can be infinite with all processes alive, but simply by ordering messages cleverly, the system remains bivalent indefinitely. This run violates termination—non-faulty processes never decide.

Therefore, no deterministic consensus algorithm exists in the asynchronous model with even one crash. This completes the proof.

### Subtleties and Clarifications

The proof relies on the fact that the adversary can delay messages arbitrarily. In a synchronous system, delays have a known bound, so you can eventually timeout and decide—this is why consensus is solvable synchronously. Also, the proof assumes the algorithm is deterministic. Randomized algorithms can break the bivalence by using coin flips to eventually (with probability 1) break symmetry.

Another nuance: the FLP result does not say that consensus is impossible in all asynchronous systems—it says that it's impossible to guarantee termination under all possible runs. In practice, the probability of the adversarial schedule that keeps the system bivalent forever is zero if randomness is used. But for deterministic algorithms, the adversary can always construct that pathological run.

---

## Implications and Consequences: What FLP Means for System Design

The FLP impossibility result is a fundamental negative result, but it is not a death sentence for distributed systems. Instead, it informs us about the necessary trade-offs. To make consensus practical, we must relax at least one assumption of the FLP model. The three main relaxations are:

1. **Partial Synchrony**: Assume the system is mostly synchronous (with some unknown global stabilization time) or that there are known bounds but they are not guaranteed initially. Algorithms like Paxos and Raft assume a partially synchronous model where timeouts can detect failures, but the bounds are unknown or large.

2. **Failure Detectors**: Introduce a failure detector that provides (possibly unreliable) hints about which processes have crashed. The weakest failure detector needed for consensus is \(\Omega\) (eventual leader election), which is equivalent to knowing a single leader that is eventually stable. With such a failure detector, consensus becomes solvable even in asynchronous systems.

3. **Randomization**: Allow processes to flip coins. Randomized consensus algorithms (e.g., Ben-Or's algorithm) can guarantee probabilistic termination with probability 1. They rely on the fact that with random choices, the chance of staying bivalent forever is zero.

4. **Restrict Inputs or Outputs**: For example, if we only require agreement on values that are already known (like using a pre-elected leader), the problem becomes easier.

### Practical Consensus Algorithms

- **Paxos**: Uses a leader-based approach with phases (prepare/promise, accept/accepted). It assumes that failures are eventually detectable through timeouts—this is a partial synchrony assumption. Paxos is the backbone of many distributed databases like Google Spanner and Apache ZooKeeper.

- **Raft**: A more understandable alternative to Paxos, also using leader election and log replication. It relies on timeouts to detect leader failures and assumes that network delays are bounded enough to allow repeated leader elections.

- **Ben-Or's Algorithm**: A randomized consensus algorithm that works in asynchronous systems. Each round, processes propose values and use coin flips to break ties. It terminates with probability 1, but the expected number of rounds is exponential in the number of processes.

- **Practical Byzantine Fault Tolerance (PBFT)**: Handles Byzantine (malicious) failures, but also relies on partial synchrony (or a view-change mechanism with timeouts).

### The CAP Theorem Connection

The CAP theorem (Brewer's theorem) states that in a distributed system, you can have at most two of: Consistency, Availability, and Partition Tolerance. Consensuses is closely related to consistency—strong consistency requires consensus across all replicas. During a network partition (asynchrony extended over time), achieving consensus becomes impossible (FLP), so systems must choose between availability (allowing responses even if inconsistent) or consistency (blocking until partition heals). The FLP result provides a deeper theoretical underpinning for CAP.

---

## Practical Insights: How to Circumvent the Impossibility in Code

Let's get our hands dirty with actual code examples that demonstrate the impossibility and then show how adding assumptions solves it.

### Example 1: A Naive Asynchronous Consensus Algorithm (That Fails)

Consider a simple deterministic algorithm: each process broadcasts its proposal, then waits for \(n\) messages, and then decides on the majority value. In an asynchronous system with a possible crash, this fails because of the classic "coordinator crash" scenario.

We'll simulate this in Python-like pseudocode.

```python
# Naive asynchronous consensus
import random
from collections import deque

class Process:
    def __init__(self, pid, proposal):
        self.pid = pid
        self.proposal = proposal
        self.decided = None
        self.messages_received = []
        self.message_queue = deque()  # pending incoming messages

    def run(self, scheduler):
        # Each process sends its proposal to all others
        for other in scheduler.processes:
            if other != self:
                scheduler.send_message(self, other, self.proposal)

        # Then it loops receiving messages until it receives n-1 messages
        while len(self.messages_received) < len(scheduler.processes) - 1:
            # yield control to scheduler to deliver a message to this process
            # This is a simplified event loop
            scheduler.deliver_next_for(self)

        # Decide majority
        zeros = sum(1 for v in self.messages_received if v == 0)
        ones = len(self.messages_received) - zeros
        self.decided = 0 if zeros > ones else 1
        print(f"Process {self.pid} decided {self.decided}")

class Scheduler:
    def __init__(self, processes):
        self.processes = processes
        self.in_transit = []  # list of (sender, receiver, message, delay)
        self.crashed = set()

    def send_message(self, sender, receiver, message):
        # In asynchronous system, message may be delayed arbitrarily
        delay = random.randint(0, 100)  # uniform delay for demo
        self.in_transit.append((sender, receiver, message, delay))

    def deliver_next_for(self, process):
        # Deliver the next message to process, else block
        # In reality, scheduler can schedule other processes first
        # We simulate by picking a message for that process with smallest delay
        eligible = [m for m in self.in_transit if m[1] == process and process not in self.crashed]
        if not eligible:
            # No messages; this would cause deadlock in real async
            raise Exception("Deadlock")
        # For simplicity, just deliver the first eligible
        msg = eligible[0]
        self.in_transit.remove(msg)
        process.messages_received.append(msg[2])
        # Also process may send more messages (but in naive algorithm, no)
```

In this naive algorithm, if a process crashes before sending its message, the others can wait indefinitely because they only know they need \(n-1\) messages. If they try to detect timeouts, that's a synchrony assumption.

But even if we add a timeout, the FLP impossibility shows there is a scenario where the algorithm either violates agreement or never terminates. For instance, consider two processes with proposals 0 and 1, and one message gets delayed so long that the other process times out and unilaterally decides 0, but then later the delayed message arrives and the first process decides 1—agreement violated.

### Example 2: Simulating a Bivalent Configuration

Let's manually construct a bivalent configuration for two processes with proposals 0 and 1. We'll use a simplified state machine.

We have two processes \(P_a\) (proposal 0) and \(P_b\) (proposal 1). Each process has a variable `state` that can be `undecided`, `decided0`, or `decided1`. The algorithm: each sends its proposal, then waits for the other's message. If both receive each other's message, they both decide on the other's value (if they are different, they pick a predetermined rule like majority, but there is no majority with two). But to show bivalence, we need a state where from that state, either decision is possible depending on future message delivery.

Consider the configuration just after both messages have been sent but before either is delivered. At this point, no process has received anything. This configuration is bivalent for the following reason: if the adversary delivers the message to \(P_a\) first, \(P_a\) will see 1, then maybe decide 1 (depending on algorithm). If then \(P_b\) receives 0, it might decide 0—agreement fails. But a correct algorithm would not do that. Let's design a simple consensus algorithm for two processes that attempts termination:

**Algorithm** (from the FLP paper): Each process \(p\):

- Broadcast its initial value.
- Upon receiving a value \(v\) from the other, if \(v \neq p.init\) then broadcast \(v\) again? No.

Actually, the standard impossibility proof uses a specific algorithm to show the existence of bivalence. But we can simulate a generic algorithm that obeys the properties of consensus (if one existed). The point is to see that from a bivalent configuration, we can always step to another bivalent configuration.

To illustrate, suppose \(C_0\) is the initial configuration with inputs (0,1). This is bivalent because all runs that lead to agreement are possible. Without loss of generality, assume there is a run that decides 0 and a run that decides 1. The adversary can construct a schedule that alternates delivering messages to each process in a way that keeps the system in a state where either decision is still possible.

We can simulate this in Python with a state machine that tracks the 'valency':

```python
# Simulate valency transitions for a hypothetical algorithm
class Config:
    def __init__(self, states):
        self.states = states  # dict pid -> (input, state, msg_buf)
        self.pending = []

    def apply_event(self, event):
        # event = (pid, message)
        # return new config after deterministic processing
        pass  # placeholder

def is_bivalent(config):
    # Returns True if there exist runs leading to decide 0 and decide 1
    # Real simulation would explore all possible schedules (not feasible)
    # But for pedagogical purposes, we assume the initial is bivalent.
    return True
```

The key insight is that the adversary can always find a message to deliver that keeps the configuration bivalent, as long as there is at least one message still in transit and no process has crashed. In an ongoing system, the adversary can also delay a crash to maintain bivalence.

### Code Example: Ben-Or's Randomized Algorithm

To show a working consensus algorithm that circumvents FLP, let's implement Ben-Or's algorithm (binary case). This algorithm uses randomization and works in an asynchronous system with crash failures. It does not guarantee deterministic termination, but with probability 1, all correct processes decide.

```python
import random

class BenOrProcess:
    def __init__(self, pid, n, initial_value):
        self.pid = pid
        self.n = n
        self.value = initial_value
        self.round = 0
        self.decided = None

    def run(self, scheduler):
        # Main loop
        while self.decided is None:
            self.round += 1
            # Phase 1: Broadcast my value
            scheduler.broadcast(self, f"PHASE1:{self.round}:{self.value}")
            # Wait for n - f messages? Actually, we need n - 1 (since at most 1 crash)
            # Wait until receive n-1 phase1 messages
            phase1_msgs = []
            while len(phase1_msgs) < self.n - 1:
                msg = scheduler.receive(self, timeout=None)  # blocking
                if msg.startswith(f"PHASE1:{self.round}:"):
                    phase1_msgs.append(int(msg[-1]))  # extract value
            # Count values
            zeros = sum(1 for v in phase1_msgs if v == 0)
            ones = len(phase1_msgs) - zeros

            # Decision condition
            if zeros > self.n/2:
                self.value = 0
            elif ones > self.n/2:
                self.value = 1
            else:
                # no majority, flip coin
                self.value = random.randint(0,1)

            # Phase 2: Broadcast this phase's value
            scheduler.broadcast(self, f"PHASE2:{self.round}:{self.value}")
            # Wait for n-1 phase2 messages
            phase2_msgs = []
            while len(phase2_msgs) < self.n - 1:
                msg = scheduler.receive(self)
                if msg.startswith(f"PHASE2:{self.round}:"):
                    phase2_msgs.append(int(msg[-1]))
            # Check if all phase2 messages agree
            if all(v == phase2_msgs[0] for v in phase2_msgs):
                self.decided = phase2_msgs[0]
                break
            # else, go to next round with updated value from phase2 majority (if any)
            zeros2 = sum(1 for v in phase2_msgs if v == 0)
            ones2 = len(phase2_msgs) - zeros2
            if zeros2 > self.n/2:
                self.value = 0
            elif ones2 > self.n/2:
                self.value = 1
            # else remain same
```

This algorithm relies on the fact that if all processes see the same majority in Phase 2, they can decide. Randomization breaks the symmetry when no majority exists. With probability 1, after finite rounds, a majority will appear and consensus is achieved.

Note that this algorithm assumes reliable communication and at most 1 crash (but can be extended to f < n/2). It does not require synchrony—messages can be delayed arbitrarily, but eventually they arrive. The only issue is that if a process crashes after sending Phase1 but before Phase2, the others might wait indefinitely. However, they can timeout? No, because they can't distinguish between a crash and a delay. In practice, we use timeouts (partial synchrony) to handle that—but strictly speaking, to remain in the asynchronous model, we need another mechanism. Actually, Ben-Or's original algorithm assumes that all processes are correct (no crashes) or uses a failure detector. Wait, Ben-Or's algorithm does handle crash failures? The original work by Ben-Or in 1983 showed that randomized consensus is possible even with crash failures, as long as the number of faulty processes is less than n/2. The algorithm assumes that non-faulty processes eventually receive messages from other non-faulty processes (i.e., messages are not lost). The adversary cannot delay messages forever—if a process is alive, it will eventually receive its messages. But if a process crashes, it stops sending. The other processes must not wait for messages from the crashed process. So the algorithm must know a bound on the number of failures (f) and wait for only n-f messages. That is exactly what we did: wait for n-1 (since at most 1 crash). So it works in an asynchronous model with crash failures.

However, the adversary could crash a process at a strategic time to cause the algorithm to loop many rounds? But the algorithm terminates with probability 1.

---

## Real-World Applications: Where FLP Matters

The FLP impossibility isn't just a theoretical curiosity; it has direct implications for the design of real systems.

### Blockchain and Cryptocurrencies

In Bitcoin, the consensus problem is solved using Proof of Work (PoW) and a synchronous-like assumption (block intervals are long enough to propagate). But in an asynchronous network (like the Internet), Bitcoin operates under partial synchronicity: blocks are assumed to propagate within a certain timeframe, but if there is a network partition, the system can fork. The FLP result contributes to understanding why blockchain consensus cannot provide deterministic guarantees in asynchronous networks—they rely on probabilistic finality.

### Distributed Databases (Spanner, Cassandra, etc.)

Google Spanner uses TrueTime (GPS clocks) to provide external consistency, making it effectively synchronous. They essentially bypass FLP by having synchronized clocks that bound message delays. Similarly, many systems use consensus protocols like Paxos or Raft that assume partial synchrony (timeouts) and thus cannot guarantee termination in all asynchronous scenarios but work well in practice.

### Cloud Infrastructure (ZooKeeper, etcd)

ZooKeeper uses Zab (ZooKeeper Atomic Broadcast) which is a consensus protocol similar to Paxos. It relies on leader election with timeouts. Under normal conditions, it achieves consensus quickly, but during a long network partition, it may become unavailable (lose quorum) to maintain consistency. This is a direct trade-off dictated by the FLP result: during asynchrony (partition) you cannot guarantee both liveness (termination) and safety (agreement).

### Eventual Consistency

Some systems, like Amazon DynamoDB, choose eventual consistency, essentially giving up on strong consensus. They tolerate that replicas may temporarily disagree, and they use techniques like CRDTs (Conflict-free Replicated Data Types) to merge updates automatically. This avoids the FLP problem by not requiring agreement on a single value at all times—they allow divergence and later convergence.

---

## Extended Discussion: Deep Dives and Recent Developments

### Relationship with Byzantine Generals Problem

The Byzantine Generals Problem is another famous impossibility result: with three or more generals, if one is traitor, consensus is solvable only if less than one-third are traitors. The FLP result is different—it deals with crash failures (much simpler) but in an asynchronous model. The Byzantine problem assumes synchronous communication. Both results highlight the fragility of consensus.

### The Role of Failure Detectors

Chandra and Toueg introduced failure detectors as a way to circumvent FLP. The weakest failure detector for consensus is \(\Omega\) (eventual leader election). With \(\Omega\), there is a deterministic algorithm (Chandra-Toueg) that solves consensus in asynchronous systems with crash failures. This shows that the impossibility is due to the lack of information about failures—if you can eventually know who is alive, you can make progress.

### Randomization and Asynchronous Consensus

Although Ben-Or's algorithm solves consensus with probability 1, it has exponential expected message complexity in the worst case. Later algorithms like that of Canetti and Rabin (1993) achieve polynomial expected complexity. This is still an active area of research.

### Extended FLP to Byzantine Failures

The FLP result has been extended to Byzantine failures: in an asynchronous system, consensus is impossible even if only one process is Byzantine (malicious). This is even stronger—no deterministic algorithm can tolerate even a single corrupt process in an asynchronous network. This underscores the need for Byzantine fault tolerance algorithms to rely on synchrony assumptions (e.g., PBFT uses view changes with timeouts).

### Implementations in Real Systems

- **Paxos**: Used in Google's Chubby lock service, Cassandra's light-weight transactions, and many others.
- **Raft**: Used in etcd (Kubernetes), Consul, and MongoDB replication.
- **Zab**: Used in ZooKeeper.

All of these assume eventual synchrony—they rely on timeouts to detect leader failures and assume that after a timeout, enough correct processes can communicate to make progress. Under a sustained network partition, these systems may halt (to preserve safety) or choose availability over consistency (like in Partition Tolerance of CAP).

### The Triumph of Practical Engineering

Despite the FLP impossibility, engineers have built astonishingly reliable distributed systems. The key is that the worst-case adversarial scenario (infinite delays and perfectly timed crashes) is extremely unlikely in practice. By using timeouts, randomized failure detection, and careful state management, we can achieve consensus with very high probability. The theoretical limitation informs us about the need for these practical mechanisms.

---

## Conclusion: Living with Impossibility

The FLP impossibility result is one of the most beautiful and humbling results in computer science. It tells us that in the purest model of distributed computing—asynchronous, no bounds, and only crash failures—consensus cannot be solved deterministically. Yet, the world runs on consensus. The resolution is that we never operate in such a pure model; we add practical assumptions like timeouts, failure detectors, or randomness.

As distributed systems practitioners, we must internalize this result to avoid designing algorithms that are doomed to fail. We must understand the trade-offs we make: by assuming synchrony (timeouts) we may compromise liveness during partitions; by using randomness we may have low probability but not guarantee; by using failure detectors we rely on external mechanisms.

The FLP result also teaches us about the adversarial nature of distributed systems. An adversary can always exploit uncertainty (indistinguishability) to cause harm. The proof is a powerful example of how to reason about such adversarial schedules.

Finally, the FLP impossibility is a foundation upon which we build more advanced results. It forced the community to define new models (partial synchrony, failure detectors, randomized algorithms) and to develop practical algorithms that are now the backbone of modern computing. Understanding FLP is essential for anyone designing or debugging distributed systems.

Takeaway: Embrace impossibility. It guides your design choices. When building consensus, always ask: "What assumption am I making to circumvent FLP?" If you don't know, the adversary will.

---

## Further Reading and References

- Fischer, M.J., Lynch, N.A., Paterson, M.S. (1985). "Impossibility of distributed consensus with one faulty process". Journal of the ACM.
- Lynch, N.A. (1996). _Distributed Algorithms_. Morgan Kaufmann.
- Chandra, T.D., Toueg, S. (1996). "Unreliable failure detectors for reliable distributed systems". Journal of the ACM.
- Lamport, L. (1998). "The Part-Time Parliament". ACM Transactions on Computer Systems.
- Ongaro, D., Ousterhout, J. (2014). "In Search of an Understandable Consensus Algorithm". USENIX ATC.

---

_This blog post was written for the Curious Engineer community. For more deep dives into distributed systems theory, subscribe to our newsletter._
