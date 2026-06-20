---
title: "Building A Distributed Actor Framework On Top Of Tcp: Messaging, Supervision, And Location Transparency"
description: "A comprehensive technical exploration of building a distributed actor framework on top of tcp: messaging, supervision, and location transparency, covering key concepts, practical implementations, and real-world applications."
date: "2023-04-01"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/building-a-distributed-actor-framework-on-top-of-tcp-messaging,-supervision,-and-location-transparency.png"
coverAlt: "Technical visualization representing building a distributed actor framework on top of tcp: messaging, supervision, and location transparency"
---

```text
This is the reality that motivated the actor model. Born from Carl Hewitt’s work in the 1970s and later refined by the Erlang community, the actor model offers a different mental model for concurrency and distribution: instead of shared state and locks, you have independent, encapsulated units — actors — that communicate exclusively through asynchronous messages. Each actor has a mailbox, a behavior, and the ability to spawn child actors. Crucially, actors are location‑transparent — an actor’s address carries no information about whether it resides in the same process, on the same machine, or across a continent. This abstraction decouples the *what* (the actor’s logic) from the *where* (its physical or network location). The result is a framework that tames the chaos of distributed computing by making failure part of the design, not an afterthought.

Yet, for all the elegance of the actor model, implementing a *distributed* actor system that works reliably over a network is a profoundly challenging engineering task. The actor model abstracts away the network, but the network does not abstract away its own realities. Packets are dropped, delayed, duplicated, or reordered. Connections fail, machines crash, and clocks drift. You cannot simply serialize an actor’s mailbox and ship it over TCP—the semantics of message delivery, ordering, and exactly‑once processing become murky the moment you leave a single address space. The clean, single‑node actor system collapses under the weight of network partitions, split‑brain scenarios, and the herculean effort of maintaining a consistent global state across unreliable links.

In this series, we will roll up our sleeves and build a distributed actor framework from scratch, using TCP as the bedrock transport layer. TCP offers a reliable, ordered, stream‑oriented connection — which simplifies some problems (no need to worry about packet reordering within a single connection) but introduces others (head‑of‑line blocking, stream boundaries, connection lifecycle). We will explore how to wrap TCP with an actor‑friendly protocol, how to handle remote actor references, how to implement supervision across machine boundaries, and how to test the whole thing under realistic failure conditions. By the end, you will have a deep understanding of the tradeoffs involved in building distributed systems, and a working prototype that you can extend for your own projects.

---

## 1. Core Actor Model Concepts – A Refresher

Before we dive into the network layer, we must have a solid grasp of the actor model as it exists on a single node. Many of the design decisions we make for distribution are driven by the desire to preserve the semantics that make actors appealing in the first place.

**Actors as fine‑grained units of computation.** An actor is an entity that encapsulates state and behavior. It has a mailbox — a queue of messages — and it processes those messages one at a time, in the order they are received (FIFO per actor). While processing a message, the actor can:
- Send messages to other actors (whose addresses it knows).
- Create new actors (child actors).
- Change its own behavior for subsequent messages.

Because actors are single‑threaded by design, you never need locks or mutexes inside an actor. This eliminates a huge class of concurrency bugs.

**Actor references and addresses.** In a single‑node system, an actor reference is often just a pointer or an integer ID. But for distribution, we need a globally unique address that includes information about the node where the actor lives. A common scheme is `actor://host:port/path/to/actor`. The address encodes the transport layer (TCP), the network endpoint, and a hierarchical path.

**Mailbox semantics.** On a single node, the mailbox is an in‑memory queue. When a message is sent to an actor, it is appended to the tail of the queue. The actor’s scheduler picks up the next message and runs the actor’s behavior on it. This is fast and deterministic. In a distributed setting, the mailbox is split: the sending side places the message into a network buffer; the receiving side deserializes and enqueues it into the local mailbox. The network introduces latency, possible reordering (if multiple connections are used), and the risk of message loss.

**Supervision and fault tolerance.** In Erlang/OTP and similar frameworks, actors are organized into a supervision tree. A supervisor actor monitors its child actors and restarts them if they fail. This creates a hierarchical error‑recovery mechanism: a failing leaf actor is restarted by its direct supervisor; if the supervisor itself crashes, its own supervisor takes action. This design isolates failures and prevents cascading crashes. Distributing supervision across machines is non‑trivial: how does a supervisor on node A know that an actor on node B has crashed? How does it restart it if node B is unreachable?

**Location transparency.** The promise of the actor model is that you can send a message to any actor without caring where it lives. The runtime handles routing. This means the same code that sends a message to a local actor should work unchanged when the target is on a remote node. Achieving this requires a unified addressing scheme and a transparent layer that decides whether to deliver the message locally or serialize it and push it over TCP.

With these concepts fresh in mind, we can now examine how TCP fits into the picture.

---

## 2. Why TCP? The Case for a Reliable Stream

When you think about building a distributed system, you have a spectrum of transport options: raw UDP, TCP, QUIC, SCTP, or even higher‑level messaging protocols like AMQP or MQTT. For our actor framework, we choose TCP as the foundation. Why?

**Reliability without reinventing the wheel.** TCP guarantees in‑order delivery of bytes, retransmits lost packets, and handles congestion control. Without TCP, we would have to implement our own acknowledgement and retry logic, sequence numbers, and flow control. That is an enormous amount of work that would distract from the core actor protocol. By standing on TCP’s shoulders, we can focus on the actor‑specific concerns: message framing, routing, and failure detection.

**Stream abstraction vs. message boundaries.** One of the first hurdles when using TCP for message‑oriented communication is that TCP is a stream protocol. It does not preserve message boundaries. If you send a 100‑byte message followed by a 200‑byte message, the receiver may read 150 bytes in one `recv()` call and 150 in the next. To use TCP for actors, we must implement a **frame protocol** — a way to delimit messages within the byte stream. Common approaches include:
- **Length‑prefixed framing:** write a fixed‑size integer (e.g., 4 bytes) that indicates the length of the following message, then the message bytes.
- **Delimiter‑based framing:** use a special byte sequence to mark the end of a message (e.g., newline for text‑based protocols).
- **Fixed‑size messages:** not practical for variable‑length data.

We will use length‑prefixed framing because it is efficient and works well with binary serialization.

**Connection lifecycle.** TCP requires connection establishment (three‑way handshake) and teardown. In a distributed actor system, we typically maintain persistent connections between nodes to avoid the overhead of repeated handshakes. However, connections can break due to network failures or timeouts. We need to detect broken connections, attempt reconnection, and handle the transient state where a node is unreachable but may come back.

**Head‑of‑line blocking.** Since TCP delivers bytes in order, all messages sent on the same connection are serialized. If a large message takes a long time to serialize or deserialize, it blocks subsequent smaller messages. This is a well‑known downside. We can mitigate it by using multiple connections between nodes, or by implementing a multiplexing layer on top of a single connection (like HTTP/2 does). For simplicity, we will start with a single connection and later discuss multiplexing.

**Nagle’s algorithm and buffering.** By default, TCP uses Nagle’s algorithm to coalesce small packets into larger ones, which can introduce latency for small messages. For an actor system where many small messages are common, we may want to disable Nagle (`TCP_NODELAY`) to reduce latency. We will make this configuration explicit.

Given these properties, TCP provides a solid but imperfect foundation. The imperfections (head‑of‑line blocking, stream boundaries) must be addressed by our application layer. Let’s now design a protocol that sits on top of TCP.

---

## 3. Designing the Actor Protocol on TCP

Our protocol must enable:
- Reliable, ordered delivery of actor messages between nodes.
- Identification of source and destination actors.
- Support for different message types (user data, system messages, heartbeats).
- Serialization and deserialization of messages.

We will define a simple binary packet format:

```

+----------------+----------------+----------------+----------------+
| Length (4 bytes)| Protocol ver | Msg type (1 B) | Reserved (2 B) |
+----------------+----------------+----------------+----------------+
| Dest actor ref (variable length) |
+----------------+----------------+----------------+----------------+
| Src actor ref (variable length) |
+----------------+----------------+----------------+----------------+
| Payload (variable length) |
+----------------+----------------+----------------+----------------+

````

- **Length:** total length of the packet (excluding the length field itself), so the receiver knows how many bytes to read for the rest.
- **Protocol version:** allows future protocol evolution.
- **Msg type:** distinguishes user data from control messages (heartbeat, acknowledgment, error, etc.).
- **Reserved:** for flags (e.g., priority, compression).
- **Dest actor ref** and **Src actor ref**: strings or binary IDs that uniquely identify the actor. We can use a URL‑like format like `actor://node_id/actor_path`.
- **Payload:** the serialized content of the actor message (e.g., JSON, Protocol Buffers, or a custom binary format).

**Serialization choices.** For demonstration, we will use a simple JSON‑based serialization for messages – it is easy to debug and implement. In production, you would likely use a more efficient binary format (Protobuf, MessagePack, Avro). The important thing is that the serialization is transparent to the actor code: the framework should handle it automatically.

**System messages.** Besides user messages, we need internal messages for the framework’s operation:
- `HEARTBEAT` – sent periodically to check if the remote node is alive.
- `ACK` – optional acknowledgment of message receipt (if we want reliable delivery).
- `ERROR` – error codes (e.g., unknown actor, deserialization failure).
- `MONITOR` – request to be notified if a remote actor terminates.
- `TERMINATE` – notification that an actor has stopped.

These system messages will have a specific msg type code, and the receiver’s framework will handle them transparently, not forwarding them to user‑defined behavior.

**Framing and parsing.** On the receiving side, we must read exactly the number of bytes specified by the length field. This requires reading from the TCP socket in a loop until we have the full packet. We will implement a state machine: read length (4 bytes), then read the remaining bytes. We buffer partial reads.

---

## 4. Implementing a Basic (Single‑Node) Actor System

Before we add networking, let’s implement a minimal actor system in a language of your choice. I’ll use Python for clarity, but the concepts translate to any language.

```python
import threading
import queue
import uuid

class ActorException(Exception):
    pass

class ActorRef:
    """Lightweight reference to an actor (local only for now)."""
    def __init__(self, actor_id, system):
        self.actor_id = actor_id
        self._system = system  # weak reference to the actor system

    def tell(self, message):
        self._system.send(self, message)

class Mailbox:
    def __init__(self):
        self.queue = queue.Queue()
        self._lock = threading.Lock()
        self._actor = None

    def attach(self, actor):
        self._actor = actor

    def enqueue(self, message):
        self.queue.put(message)

    def run(self):
        while True:
            msg = self.queue.get()
            if msg is None:  # poison pill
                break
            try:
                self._actor.on_message(msg)
            except Exception as e:
                # In a real system, we would invoke supervisor handling
                print(f"Actor {self._actor.actor_id} crashed: {e}")
                # For now, just stop
                break
        # cleanup

class Actor:
    def __init__(self, actor_id, system):
        self.actor_id = actor_id
        self.system = system
        self.mailbox = Mailbox()
        self.mailbox.attach(self)

    def on_message(self, message):
        raise NotImplementedError

class ActorSystem:
    def __init__(self):
        self._actors = {}
        self._lock = threading.Lock()

    def spawn(self, actor_class, *args, **kwargs):
        actor_id = str(uuid.uuid4())
        actor = actor_class(actor_id, self, *args, **kwargs)
        with self._lock:
            self._actors[actor_id] = actor
        t = threading.Thread(target=actor.mailbox.run)
        t.start()
        return ActorRef(actor_id, self)

    def send(self, ref, message):
        with self._lock:
            actor = self._actors.get(ref.actor_id)
        if actor:
            actor.mailbox.enqueue(message)
        else:
            raise ActorException(f"Actor {ref.actor_id} not found")

    def stop(self, ref):
        with self._lock:
            actor = self._actors.pop(ref.actor_id, None)
        if actor:
            actor.mailbox.enqueue(None)  # poison pill
````

This simple system creates actors in separate threads, each with its own mailbox. Messages are queued and processed in order. Now, let’s add the network layer.

---

## 5. Adding Distribution – Remote Actor References and the Node Layer

To extend our system across the network, we need a **Node** abstraction that manages TCP connections and translates local actor references to remote ones.

**RemoteActorRef** – a subclass of `ActorRef` that knows the remote node’s address. When `tell()` is called, it serializes the message and sends it over the TCP connection to that node.

**NodeManager** – a singleton (or per‑system object) that holds TCP connections to other nodes, listens for incoming connections, and dispatches incoming messages to the appropriate local actor.

Let’s design the NodeManager with the following components:

- **Listener** – a TCP server that accepts connections and creates a `RemoteNode` object for each peer.
- **Outgoing connections** – when we need to send a message to a remote actor, we check if a connection already exists; if not, we dial it.
- **Message router** – for each incoming packet, deserialize it, look up the destination actor in the local actor registry, and enqueue the message in its mailbox.

We must also handle **actor location**. Initially, we can use a simple **registry service** (or a centralized discovery node) where each node registers its actors. For simplicity, we will assume a static configuration: each node knows the addresses of all other nodes, and actors are created with a known path. In a real system, you would use a distributed hash table (like Akka’s cluster) or a gossip protocol.

**Addressing scheme.** We will use a string format: `actor://host:port/actor_id`. For local actors, we can still use a short ID; the NodeManager will interpret the URL and either handle locally or forward.

**Message flow for remote tell:**

1. User code calls `remote_ref.tell(msg)`.
2. `RemoteActorRef.tell()` calls `node_manager.send_to(remote_ref, msg)`.
3. NodeManager serializes the message into our binary packet format.
4. NodeManager looks up the TCP connection (or opens one) to the target node.
5. The packet is written to the TCP socket.
6. On the receiving side, a reading thread reads the full packet.
7. NodeManager deserializes it, obtains the destination actor ID.
8. NodeManager looks up the local actor and enqueues the message in its mailbox.

**Handling actor creation across nodes.** When a supervisor on node A wants to spawn a child actor on node B, we need a remote spawn request. We can send a system message `SPAWN` with the actor class name and arguments. Node B creates the actor locally and returns the new actor reference. The supervisor on node A then holds a remote reference.

**Code outline for RemoteActorRef:**

```python
class RemoteActorRef(ActorRef):
    def __init__(self, actor_id, node_manager, remote_node_host, remote_node_port):
        super().__init__(actor_id, node_manager)  # system is node_manager
        self.remote_node = (remote_node_host, remote_node_port)

    def tell(self, message):
        # Instead of local delivery, we ask node_manager to send over TCP
        self._system.send_remote(self, message)
```

And in NodeManager:

```python
class NodeManager:
    def __init__(self, local_host, local_port):
        self.local_host = local_host
        self.local_port = local_port
        self._connections = {}  # (host,port) -> TcpConnection
        self._local_actors = {}  # actor_id -> Actor
        self._listener = None

    def send_remote(self, ref, message):
        # Serialize
        data = serialize_message(ref.actor_id, message)
        target = ref.remote_node
        conn = self.get_connection(target)
        conn.send(data)

    def get_connection(self, addr):
        if addr not in self._connections:
            sock = socket.create_connection(addr)
            # Disable Nagle
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn = TcpConnection(sock)
            self._connections[addr] = conn
            # Start reading thread for this connection
            threading.Thread(target=self._reader, args=(conn,), daemon=True).start()
        return self._connections[addr]
```

The reader thread reads framed packets and dispatches them to `_handle_incoming`:

```python
def _handle_incoming(self, packet):
    dest_id, src_ref, msg_type, payload = deserialize_packet(packet)
    if dest_id in self._local_actors:
        actor = self._local_actors[dest_id]
        # Create a sender ref (possibly remote)
        sender = RemoteActorRef(src_ref.actor_id, self, src_ref.host, src_ref.port)
        # Wrap in a system message envelope?
        actor.mailbox.enqueue((sender, payload))
    else:
        # Could forward? For now, log error
        print(f"Actor {dest_id} not found locally")
```

This is a minimal skeleton. In a full implementation, we must handle:

- **Connection failures and reconnection** – keep trying if a connection drops.
- **Heartbeats** – detect silent dead peers.
- **Framing and buffering** – careful with partial reads.
- **Thread safety** – mailboxes and connection lists.

---

## 6. Handling Failures and Supervision Across Nodes

One of the main selling points of the actor model is its fault‑tolerance story. On a single node, a supervisor restarts a crashed child. Across nodes, we need to extend this concept: a supervisor on node A should be able to monitor actors on node B and restart them if they fail.

**Local supervision recap.** In a single‑node system, the supervisor actor is just a regular actor that receives special system messages (`CHILD_CRASHED`, `CHILD_STARTED`). When a child crashes, its mailbox thread stops. The supervisor catches the exception (or the system sends a `TERMINATED` message to the monitor) and decides whether to restart the child. The restart creates a new actor with a fresh mailbox.

**Remote supervision challenges:**

- How does the supervisor know that a remote child has crashed? The remote node must send a notification.
- If the remote node itself goes down, all its actors are lost. The supervisor must decide whether to restart those actors on a different node or wait for the node to come back.
- Starting a new actor on a remote node requires a remote spawn request, which might fail if the remote node is in a bad state.

**Design for cross‑node supervision:**

1. **Monitors.** An actor can monitor another actor regardless of location. If the monitored actor terminates (cleanly or due to failure), a `TERMINATED` system message is sent to the monitoring actor. For cross‑node monitors, this message must travel over TCP.

2. **Heartbeat and node failure detection.** Each node is connected via TCP. We can use a heartbeat mechanism (e.g., send a small packet every second). If no heartbeat is received for a timeout period (e.g., 5 seconds), we consider the remote node dead. At that point, we can treat all its actors as terminated. The supervisor receives `TERMINATED` messages for all actors it monitored on that node.

3. **Remote spawn and restart.** When a supervisor decides to restart a remote child, it sends a `SPAWN` system message to the target node (or a new node). The node creates the actor and responds with a new `ActorRef`. The supervisor then updates its references.

4. **Supervision policies.** Policies (one‑for‑one, one‑for‑all, etc.) are local decisions. The supervisor logic remains the same; only the spawn and monitor actions go through the network.

**Implementation sketch for remote monitoring:**

```python
# In NodeManager, when an actor terminates:
def _actor_terminated(self, actor_id, reason):
    # Notify all monitors (local and remote)
    monitors = self._monitors.get(actor_id, [])
    for monitor_ref in monitors:
        if isinstance(monitor_ref, RemoteActorRef):
            # Send TERMINATED message over TCP
            self.send_remote(monitor_ref, ('TERMINATED', actor_id, reason))
        else:
            # Local delivery
            local_actor = self._local_actors[monitor_ref.actor_id]
            local_actor.mailbox.enqueue(('TERMINATED', actor_id, reason))
```

And for remote spawn:

```python
def remote_spawn(self, remote_node, class_name, args, parent_ref):
    # Send SPAWN system message
    spawn_msg = ('SPAWN', class_name, args, parent_ref)
    self.send_system(remote_node, spawn_msg)
    # We'll handle the response asynchronously; store a future for the new ref
```

This is still high‑level; a robust implementation would require acknowledgements and retries for the spawn request.

---

## 7. Building a Distributed Chat Application – A Complete Example

To solidify the concepts, we will build a simple distributed chat room. Users connect to any node, send messages, and all other users across nodes receive them.

**Architecture:**

- Each node runs our actor system.
- A `ChatRoom` actor lives on a designated “room leader” node (or we could replicate).
- `UserSession` actors are created on the node where the user connects (local or remote).
- When a user sends a message, their `UserSession` sends it to the `ChatRoom` actor.
- The `ChatRoom` actor broadcasts the message to all registered `UserSession` actors (some may be on other nodes).

**Implementation steps:**

1. Define messages: `Join(username)`, `Leave`, `ChatMessage(text)`.
2. `UserSession` actor: connects to the chat room upon creation, listens for incoming messages (prints to console), sends user input to room.
3. `ChatRoom` actor: maintains a set of `UserSession` refs; on `Join`, adds ref; on `ChatMessage`, sends to all refs.
4. Deploy two nodes: node A (192.168.1.1:9000) and node B (192.168.1.2:9000).
5. Start the chat room on node A.
6. Connect a user to node B – the user’s session is created on node B, and it sends a `Join` message to the room on node A (remote ref).
7. The room broadcasts to all sessions, including the remote one on node B – the message travels back to node B.

**Testing failure:** Kill the chat room actor process on node A. The remote sessions should get a `TERMINATED` message. We can then have a supervisor on node B restart the chat room on node B itself (or on a new node). This demonstrates resilience.

**Code snippet for ChatRoom actor:**

```python
class ChatRoom(Actor):
    def __init__(self, actor_id, system):
        super().__init__(actor_id, system)
        self.subscribers = set()

    def on_message(self, sender, msg):
        if msg['type'] == 'Join':
            self.subscribers.add(sender)
            print(f"User joined: {msg['username']}")
        elif msg['type'] == 'Leave':
            self.subscribers.discard(sender)
        elif msg['type'] == 'ChatMessage':
            broadcast = {'from': msg['username'], 'text': msg['text']}
            for sub in self.subscribers:
                sub.tell(broadcast)
```

This code is unchanged whether the sender is local or remote – the framework handles the serialization.

**Dealing with network partitions during broadcast.** If the room sends to a remote subscriber whose connection is broken, the room should handle the failure (e.g., remove that subscriber). We can integrate monitoring: the room monitors all subscribers, and when it receives a `TERMINATED` notice, it removes them.

---

## 8. Advanced Topics: Backpressure, Delivery Guarantees, and Cluster Membership

Our prototype works for a small cluster, but real‑world systems need more. Let’s discuss a few important extensions.

**Backpressure.** If a remote node is slow to consume messages, the sending node’s TCP send buffer will fill up, eventually blocking the sender. In an actor system, you don’t want a slow remote actor to block a local actor that is trying to send to it. Solutions:

- Use a bounded mailbox with a high‑water mark and a mechanism to pause sending (e.g., send a `PAUSE` system message).
- Implement a credit‑based flow control where the receiver grants credits to the sender.
- Offload network sending to a separate thread pool so that the sending actor is not blocked.

**Delivery guarantees.** TCP ensures that bytes are delivered in order and without loss _within a single connection_. But what if the connection drops after the bytes are written but before they are received? The sender does not know if the message arrived. Options:

- **At‑most‑once:** no acknowledgment; simple but can lose messages during crashes.
- **At‑least‑once:** sender waits for an ACK from the receiver; if not received, retransmits. This requires deduplication on the receiver side (since retransmission can cause duplicates).
- **Exactly‑once:** the Holy Grail – requires distributed transactions or idempotent message processing. Over TCP, exactly‑once is extremely hard to achieve without a consensus protocol.

For our framework, we can implement at‑least‑once for important system messages (spawn, monitor) and at‑most‑once for user messages unless the application demands more. Using TCP’s own reliability already gives us at‑least‑once semantics _if the connection remains open_. But after a crash, we lose the state of unacknowledged messages.

**Cluster membership and failure detection.** A static configuration of nodes is limited. A production system needs dynamic cluster membership: nodes can join and leave. This is usually implemented with a gossip protocol (e.g., SWIM) that disseminates membership changes and failure suspicions. Each node maintains a list of alive nodes and exchanges it periodically. When a node is suspected dead, the cluster updates the routing tables. Extending our framework to support gossip would be a natural next step.

**Split‑brain scenarios.** If a network partition separates the cluster into two groups, each may independently start operating, leading to inconsistent state. The actor model does not inherently solve this; you need a strategy like:

- Quorum‑based decisions: a group with less than a majority becomes passive.
- CRDTs (Conflict‑free Replicated Data Types) for data that can tolerate eventual consistency.
- Using a consensus algorithm (Raft, Paxos) for critical decisions (e.g., which node is the chat room leader).

None of these are trivial, but they are the reality of building resilient distributed systems.

---

## 9. Testing the Distributed Framework

Distributed systems are notoriously hard to test because failures are rare and non‑deterministic. We can use the following approaches:

- **Unit tests** for serialization, framing, mailbox logic (single node).
- **Integration tests** with two nodes running in separate processes (or threads) on the same machine, simulating network conditions using tools like `tc` (traffic control) or `toxiproxy` to inject delays, packet loss, and connection failures.
- **Chaos engineering** – randomly kill processes, drop connections, and verify that the system recovers (supervision restarts actors, messages are not lost).

We can write Python tests using `subprocess` to start multiple instances of our node, connect them, and run a scenario.

Example test: start two nodes, create an actor on node1, send a message from node2, assert it arrives.

```python
def test_remote_message():
    node1 = start_node('127.0.0.1', 9001)
    node2 = start_node('127.0.0.1', 9002)
    # Register node2 as peer of node1
    node1.connect_peer('127.0.0.1', 9002)
    node2.connect_peer('127.0.0.1', 9001)
    # Spawn echo actor on node1
    ref = node1.spawn(EchoActor)
    # Send from node2
    remote_ref = RemoteActorRef(ref.actor_id, node2, '127.0.0.1', 9001)
    remote_ref.tell("hello")
    time.sleep(0.5)
    assert node1.received_messages == ["hello"]  # some global state
```

In practice, you would use message queues and timeouts carefully to avoid flaky tests.

---

## 10. Conclusion and Next Steps

We have walked through the design and implementation of a distributed actor framework on top of TCP. Starting from the motivations of distributed systems, we reviewed the actor model, chose TCP as our transport, designed a simple binary protocol, and built a minimal actor runtime. We added remote actor references, cross‑node message delivery, and remote supervision. We illustrated the concepts with a chat application and discussed advanced topics like backpressure and cluster membership.

The framework we built is intentionally simple – it lacks many features of mature systems like Akka, Orleans, or Erlang/OTP. However, you now understand the core tradeoffs: TCP gives us reliability but requires framing; location transparency is beautiful but must be implemented carefully; supervision across nodes demands heartbeats and failure detection; and exactly‑once delivery is a myth for most practical purposes.

If you wish to continue this project, you could:

- Replace JSON serialization with Protobuf for performance.
- Implement a gossip‑based cluster membership.
- Add a cluster‑aware router that can send messages to the nearest actor.
- Build a web dashboard to visualize actors and connections.

The actor model, combined with a careful layer of networking, provides a powerful paradigm for building resilient, scalable distributed systems. And by building it yourself, you earn a deep respect for the engineering challenges that lie beneath the simple abstraction of a message. Happy coding!

---

_Author’s note: This blog post is an excerpt from a longer series on distributed systems. In the next article, we will replace our ad‑hoc network layer with a more robust message transport based on QUIC, and explore how to implement backpressure using a token‑bucket algorithm. Stay tuned._

```

```
