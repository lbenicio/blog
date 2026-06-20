---
title: "Designing A Custom Network Protocol: Framing, Checksums, And Reliable Delivery Over Udp"
description: "A comprehensive technical exploration of designing a custom network protocol: framing, checksums, and reliable delivery over udp, covering key concepts, practical implementations, and real-world applications."
date: "2025-10-06"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/Designing-A-Custom-Network-Protocol-Framing,-Checksums,-And-Reliable-Delivery-Over-Udp.png"
coverAlt: "Technical visualization representing designing a custom network protocol: framing, checksums, and reliable delivery over udp"
---

## When TCP Fails: The Art of Building Your Own Network Protocol

**A Deep Dive into Why TCP Hurts Real‑Time Applications and How to Build Custom UDP‑Based Solutions**

---

### 1. Introduction: The Frozen Frame

Picture this: you’re in the final round of a competitive _Counter‑Strike_ match. You round a corner, scope in on the enemy – and then the screen freezes. Your crosshair is stuck mid‑swing. The “connection interrupted” icon flickers. When the world unfreezes, you find yourself dead, a killcam replay showing you standing perfectly still for a full second while the enemy lined up the shot.

What happened? TCP happened.

We’ve been taught that TCP is the gold standard for network communication. It’s reliable. It’s ordered. It “just works.” But beneath that dependability lurks a dark secret: TCP was designed in 1974 for a world of dial‑up modems, text‑based terminals, and networks where packet loss was catastrophic. For modern real‑time applications – multiplayer games, live video streaming, high‑frequency trading, autonomous vehicle telemetry, telemedicine – TCP isn’t just suboptimal. It’s actively destructive.

This blog post will show you exactly why TCP fails, what you can do about it, and how to design your own custom network protocol that delivers the right trade‑offs for your application. We’ll walk through concrete examples, code snippets, and design patterns that have been battle‑tested in production systems. By the end, you’ll understand the art of building a network protocol from scratch – and when it’s worth doing.

---

### 2. The TCP Trap: Why Reliable Ordered Delivery Hurts

#### 2.1 The Head‑of‑Line Blocking Problem

TCP guarantees that data arrives **in the exact order it was sent**, and that every byte is delivered. This is implemented through a sliding window mechanism. When a packet is lost, the receiver holds all subsequent received packets in a buffer, waiting for the lost packet to be retransmitted. Only after the missing packet arrives can the receiver pass the data to the application – all at once, in order.

This is head‑of‑line blocking (HOL blocking). It’s the direct reason your game froze.

Consider a game server sending position updates 60 times per second:

```
Packet 1: pos = (10, 20), timestamp = 1
Packet 2: pos = (11, 21), timestamp = 2
Packet 3: pos = (12, 22), timestamp = 3   ← lost
Packet 4: pos = (13, 23), timestamp = 4
Packet 5: pos = (14, 24), timestamp = 5
```

With TCP, packets 4 and 5 will sit in the receiver’s kernel buffer, **not delivered to the game client**, until packet 3 is retransmitted and acknowledged. The client has no idea that newer data has already arrived. It sees nothing – hence the freeze.

But does the client actually need packet 3? In a fast-paced game, packet 4 already contains a more recent position. Packet 5 is even newer. The lost packet’s information is obsolete. What the client really needs is the **latest** state, delivered as quickly as possible, even if that means skipping a few frames.

**Key Insight:** TCP’s “correct” ordered delivery is the wrong correctness model for real‑time data. Timeliness trumps completeness.

#### 2.2 Congestion Control and Latency Spikes

TCP’s congestion control algorithms – Reno, CUBIC, BBR – are designed to be _fair_ to other flows and to prevent network collapse. They achieve this by dynamically adjusting the sending rate based on packet loss or delay signals.

- **Loss‑based** algorithms (e.g., CUBIC) treat any packet loss as a sign of congestion and halve the congestion window. In a wireless or high‑loss environment, this causes dramatic throughput drops and latency spikes.
- **Delay‑based** algorithms (e.g., BBR) are better, but they still introduce variability. For real‑time audio or video, a sudden spike in queuing delay (bufferbloat) can ruin the experience.

In a high‑frequency trading system, a single congestion‑induced retransmission can cost millions. In a game, it causes rubber‑banding. In a teleoperation system controlling a surgical robot, it risks patient safety.

#### 2.3 The Three‑Way Handshake and Tail Latency

Every TCP connection begins with a three‑way handshake (SYN, SYN‑ACK, ACK). That’s one round‑trip time (RTT) before any data can be sent. For a real‑time application that needs to react instantly, that initial latency is intolerable.

Moreover, TCP’s retransmission timer (RTO) is typically coarse – often 200 ms or more in the kernel. If a packet is lost, the sender may wait that long before retransmitting, even if the receiver could have used a newer packet.

#### 2.4 Real‑World Examples of TCP Failures

| Application                     | TCP Behavior                                                 | Result                              |
| ------------------------------- | ------------------------------------------------------------ | ----------------------------------- |
| Multiplayer game (60 fps)       | HOL blocking during packet loss                              | Player freezes, warps               |
| Video conferencing (Zoom)       | TCP retransmits old video frame; new frames stuck            | Frozen screen, audio‑video desync   |
| Stock exchange feed             | Loss of one order packet delays all subsequent orders        | Missed trading opportunities        |
| Live sports streaming           | TCP tries to deliver every segment, increasing startup delay | Buffering spinner every few seconds |
| IoT sensor network (RTT 500 ms) | TCP congestion window collapses on loss                      | Long gaps in data stream            |

These aren’t hypotheticals. They’re everyday problems in production systems.

---

### 3. Enter UDP: The Raw Canvas

UDP (User Datagram Protocol) is the bare‑bones transport protocol. It provides:

- **Best‑effort delivery**: packets may be lost.
- **No ordering**: packets may arrive out of sequence.
- **No congestion control**: you can send as fast as you want (until you saturate the link).
- **No connection setup**: just send datagrams to an IP:port.

To many engineers, UDP sounds terrifying. “No reliability? That’s unusable!” But that’s a misunderstanding. UDP is a _tool_. It gives you control. Instead of TCP’s one‑size‑fits‑all rules, you write _your own rules_.

Think of it this way:

- TCP is a taxi. It takes you exactly where you want to go, but you have to follow the driver’s route and schedule.
- UDP is a set of skateboard parts. You can build a unicycle, a roller skate, or a rocket‑powered board, depending on what you need.

The art of building your own protocol is about deciding which guarantees to add on top of UDP and which to omit.

---

### 4. Building Blocks of a Custom Protocol

Before we dive into design patterns, let’s establish the fundamental building blocks you can use to build a reliable (or partially reliable) protocol over UDP.

#### 4.1 Sequence Numbers and Acknowledgements

Every packet you send should carry a monotonically increasing sequence number (e.g., a 16‑bit integer, wrapping around). The receiver sends back acknowledgements (ACKs) indicating which sequence numbers it has received.

Basic ACK formats:

- **Acks with cumulative sequence**: “I have received everything up to seq 42.”
- **Selective ACKs (SACKs)**: “I have received seq 42, 44, 45, but not 43.”

SACKs are critical for high‑loss links, because they tell the sender exactly which packets to retransmit.

#### 4.2 Retransmission Strategies

You have several choices for when and how to retransmit:

| Strategy         | Description                                                                              | Best for                                            |
| ---------------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------- |
| Stop‑and‑Wait    | Send one packet, wait for ACK, then send next. Simple but low throughput.                | Very low bandwidth, high latency tolerance          |
| Go‑Back‑N        | Send multiple packets; on loss, retransmit all unacked packets from the lost one onward. | Wastes bandwidth if loss rates are high             |
| Selective Repeat | Only retransmit lost packets (requires SACKs).                                           | High‑efficiency, most modern reliable‑UDP protocols |

**Timer‑based retransmission**: set a timeout (RTO) per segment. If no ACK arrives within RTO, retransmit. Adaptive RTO estimation (like TCP’s Jacobson algorithm) works well but adds complexity.

**Negative ACK (NACK) based**: The receiver sends a NACK for any missing packet. This can reduce feedback traffic in lossy environments.

#### 4.3 Flow Control and Congestion Control

Do you need flow control? (Preventing sender from overrunning receiver’s buffer.) In many real‑time apps, the receiver processes data at a fixed rate (e.g., render 60 fps), so flow control may be unnecessary – just drop old packets.

Congestion control is trickier. Without it, you’re a “jerk” on the network – you might saturate links and cause packet loss for everyone. For local or dedicated networks (e.g., game server LAN), it’s often fine to skip. For the public internet, you need some form of rate limiting. Options:

- TCP‑friendly rate control (TFRC): a formula‑based approach that mimics TCP’s long‑term throughput without its latency spikes.
- BBR‑like pacing.
- Simple static rate limiting (e.g., no more than 1 Mbps).

#### 4.4 Connection Management

UDP is connectionless, but your application likely needs to know when a peer is alive. You can implement:

- **Heartbeats**: periodic ping‑pong messages to detect dead peers.
- **Connection IDs**: embed a random identifier in each packet to route to the correct session state.
- **Handshake**: you might still want a two‑way initial exchange to exchange keys or capabilities.

#### 4.5 Fragmentation and MTU Handling

UDP datagrams have a maximum size of 65535 bytes, but the network path’s MTU (maximum transmission unit) is usually 1500 bytes. Sending larger than the path MTU causes IP fragmentation – which is inefficient and can lead to packet drops. Best practice: probe the path MTU (e.g., using Path MTU Discovery) or limit payload to ~1400 bytes per UDP packet. If you need larger messages, implement your own segmentation and reassembly.

---

### 5. Protocol Design Patterns for Different Domains

Now we get to the fun part: applying these building blocks to specific real‑time applications.

#### 5.1 Real‑Time Multiplayer Games

**Requirements:** low latency (under 100 ms), high update rate (10–60 Hz), tolerance of occasional packet loss, but need for eventual state consistency.

**Typical design:**

- Use UDP directly, no reliability for position updates.
- Use **delta compression** – send only changes from last known state.
- **Client‑side prediction** (client moves locally without waiting for server) + **server reconciliation** (server sends authoritative state every few updates).
- **Input‑based** protocols (e.g., _Valve_’s Source engine) send player inputs (key presses) rather than positions; server simulates and sends back the result.
- **Reliable channels** only for critical events (e.g., weapon pickups, damage messages) – usually via a separate reliable‑UDP stream with selective retransmission.

**Example: Quake 3’s protocol**  
UDP packets contain a header with sequence numbers, then a series of messages (e.g., “player 5 moved to x=100”, “player 5 fired weapon”). Loss of a movement update is ignored – the next one contains the latest position. Loss of the “fire weapon” message is retransmitted because it has a game‑state effect.

**Code snippet: unreliable movement packet (pseudo‑C#)**

```csharp
struct MovementPacket {
    uint sequence;
    uint playerId;
    float posX, posY, posZ;
    byte yaw, pitch;
    // No ACK expected. Duplicates are ignored based on sequence.
}
```

#### 5.2 Video Streaming and Conferencing

**Requirements:** very high throughput, low startup delay, tolerance of occasional packet loss for non‑key frames, but key frames must be received.

**Common protocols:**

- **WebRTC** uses **DTLS** for encryption and **SCTP** over UDP for data channels, plus custom RTP/RTCP for media.
- Many proprietary streaming systems implement **FEC (Forward Error Correction)** – e.g., Reed‑Solomon codes or XOR parity packets. FEC allows recovery of lost packets without retransmission, critical for low‑latency video.
- **Adaptive bitrate**: the sender adjusts stream quality based on observed loss and delay.

**Reliability‑ordering trade‑off:**  
Video frames are often encoded with inter‑frame dependencies (P‑frames depend on I‑frames). You need to guarantee delivery of I‑frames, but P‑frames can be skipped if lost. This is exactly the kind of selective reliability that TCP cannot provide.

#### 5.3 High‑Frequency Trading (HFT)

**Requirements:** extremely low latency (microseconds), zero loss, perfect ordering, but also fairness.

**Approach:**

- Many HFT firms run on dedicated fiber and use **hardware‑accelerated** UDP stacks (FPGA, ASIC) that bypass the OS kernel.
- They implement a **Go‑Back‑N** or **selective repeat** protocol in hardware, with very tight timeouts (e.g., 1 ms RTO).
- **Multicast** is common for market data feeds (e.g., NASDAQ’s ITCH protocol over UDP multicast). Each packet contains a sequence number; missing packets are requested via TCP or retransmission server.

**Key challenge:** The protocol must be fair – you can’t monopolize the wire. Often, firms use a fixed‑rate inter‑packet gap (pacing) regardless of loss.

#### 5.4 IoT and Sensor Networks

**Requirements:** low power, intermittent connectivity, small packet sizes, sometimes high loss (e.g., LoRaWAN).

**Design patterns:**

- **Minimal headers** – 4‑byte sequence number + 1‑byte message type.
- **No retransmission** for sensor readings – the next sample is more valuable.
- **Cumulative ACKs** with piggybacked data to reduce overhead.
- **Store‑and‑forward** at the gateway for config commands.

**Example: MQTT‑SN** (MQTT for Sensor Networks) runs over UDP and uses topic‑based publish/subscribe with minimal reliability.

---

### 6. Case Study: Building a Simple Reliable‑Unordered Protocol in Python

Let’s build a minimal protocol that provides **reliable delivery without ordering** – exactly what many games need. We’ll use UDP with selective retransmission. The sender can transmit packets, and the receiver will deliver them as soon as they arrive – out of order if necessary.

#### 6.1 Protocol Design

- Packet structure: `[sequence:4 bytes][data: variable]`
- Receiver sends ACKs for every received packet: `[ack_sequence:4 bytes]`
- Sender maintains a list of unacked sequence numbers. On receiving an ACK, remove that sequence from the list.
- Sender runs a timer every, say, 50 ms. For any sequence that hasn’t been acked within 200 ms, retransmit.
- Receiver has a hash set of received sequences to ignore duplicates.

This is a simplified version of KCP (see later), but without flow control.

#### 6.2 Sender Code (Python with asyncio)

```python
import asyncio
import struct
import time
from collections import defaultdict

class ReliableUnorderedSender:
    def __init__(self, transport, addr, rto=0.2, interval=0.05):
        self.transport = transport
        self.addr = addr
        self.rto = rto
        self.interval = interval
        self._seq = 0
        self._unacked = {}  # seq -> (data, timestamp)
        self._lock = asyncio.Lock()
        asyncio.ensure_future(self._retransmit_loop())

    def send(self, data: bytes):
        seq = self._seq
        self._seq += 1
        packet = struct.pack('>I', seq) + data
        self.transport.sendto(packet, self.addr)
        self._unacked[seq] = (packet, time.monotonic())

    def receive_ack(self, ack_seq: int):
        self._unacked.pop(ack_seq, None)

    async def _retransmit_loop(self):
        while True:
            await asyncio.sleep(self.interval)
            now = time.monotonic()
            to_retransmit = []
            async with self._lock:
                for seq, (packet, sent_at) in list(self._unacked.items()):
                    if now - sent_at > self.rto:
                        to_retransmit.append((seq, packet))
                for seq, packet in to_retransmit:
                    self.transport.sendto(packet, self.addr)
                    self._unacked[seq] = (packet, now)  # update sent time
```

#### 6.3 Receiver Code

```python
class ReliableUnorderedReceiver:
    def __init__(self, callback):
        self.callback = callback
        self._seen = set()  # set of received sequence numbers

    def process_packet(self, data: bytes, addr):
        seq = struct.unpack('>I', data[:4])[0]
        payload = data[4:]
        if seq in self._seen:
            # Duplicate; just ACK and discard
            self._send_ack(seq, addr)
            return
        self._seen.add(seq)
        # Deliver to application immediately (unordered)
        self.callback(payload)
        self._send_ack(seq, addr)

    def _send_ack(self, seq, addr):
        # Assumes transport is available from context
        ack_packet = struct.pack('>I', seq)
        transport.sendto(ack_packet, addr)
```

#### 6.4 Discussion

This protocol is simple but powerful. It delivers data as soon as it arrives, even if earlier packets are still missing. If a packet is lost, it will be retransmitted – but if a newer packet arrives first, the application gets it immediately.

**Caveats:**

- No flow control: the sender can overwhelm the receiver if the receiver processes slowly. For games, this is rarely an issue because the game loop runs at a fixed rate.
- No congestion control: on the public internet, you should add rate limiting or use a TCP‑friendly algorithm.
- Sequence number wraparound: with 4‑byte sequence numbers (2^32), wraparound takes a long time at 60 Hz (over 800 days). For high‑speed streams, use 64‑bit or implement wraparound detection.

---

### 7. Advanced Topics: Existing Libraries and QUIC

Before you build your own, consider using an existing reliable‑UDP library. They save months of debugging.

| Library                               | Language         | Key Features                                                                            |
| ------------------------------------- | ---------------- | --------------------------------------------------------------------------------------- |
| **KCP**                               | C, ports in many | Fast, configurable retransmit, flow control. Used in games (e.g., _League of Legends_). |
| **ENET**                              | C                | Connection management, reliable and unreliable channels, packet fragmentation.          |
| **UDT**                               | C++              | Reliable UDP with congestion control, supports large data transfers.                    |
| **libwebsockets** (reliable‑UDP mode) | C                | Integrates with WebSocket‑like API.                                                     |
| **Netcode.io**                        | Go, C#           | Purpose‑built for games; includes encryption, NAT traversal.                            |

**QUIC (HTTP/3)** is the big newcomer. It runs over UDP, provides TLS encryption, multiplexed streams, and customizable reliability. QUIC’s streams avoid HOL blocking across streams – you can have a reliable stream for chat and an unreliable stream for position data within the same connection. QUIC is complex but becoming the standard for modern web traffic.

**When to build your own:**

- You need extreme performance (microsecond latency).
- You have unusual constraints (e.g., FPGA implementation).
- You want to learn or you need a very specific trade‑off (e.g., no _any_ retransmission, ever).

Most of the time, a library like KCP or ENET will serve you well.

---

### 8. Pitfalls and Challenges

#### 8.1 NAT Traversal and Firewalls

UDP is often blocked by corporate firewalls or home routers. You may need:

- **STUN / TURN** servers for NAT traversal.
- **Port prediction** techniques.
- **Fallback to TCP** (using a library like uTP that emulates TCP over UDP for better NAT traversal, e.g., BitTorrent’s protocol).

#### 8.2 MTU Discovery and IP Fragmentation

IP fragmentation is inefficient and can be dropped by middleboxes. Always set the DF (Don’t Fragment) flag and use Path MTU Discovery:

- Start with 1400‑byte payload.
- If you receive ICMP “Fragmentation Needed” messages, reduce payload size. (Note: ICMP is often blocked on the internet; fallback to a conservative MTU like 1200 bytes.)

#### 8.3 Fairness and Being a “Good Citizen”

If you skip congestion control, you may starve other traffic on a shared link. For public internet, implement:

- **Bandwidth estimation** (e.g., measure ACK rate).
- **TCP‑friendly rate control** (TFRC) – mimics TCP’s average throughput without its sawtooth.
- **Pacing** – send evenly spaced packets rather than bursts.

#### 8.4 RTT Estimation and RTO Tuning

Using a fixed RTO (e.g., 200 ms) is too aggressive for high‑loss environments and too conservative for low‑latency ones. Implement an adaptive estimator similar to TCP:

```
srtt = (1 - α) × srtt + α × RTT_sample
rttvar = (1 - β) × rttvar + β × |RTT_sample - srtt|
RTO = srtt + 4 × rttvar
```

Typical α = 0.125, β = 0.25.

#### 8.5 Security

UDP has no built‑in encryption or authentication. You must add:

- **Per‑packet encryption** (e.g., AES‑GCM) to prevent eavesdropping.
- **Message authentication** (MAC) to prevent spoofed packets.
- **Replay protection**: include a timestamp or a counter in the packet header.

If security is a concern, consider using DTLS (Datagram TLS) or a library like libsodium’s `crypto_secretbox`.

---

### 9. Conclusion: When to Abandon TCP

TCP is not evil. It’s the right choice for:

- Bulk data transfer (file downloads, email).
- Applications where every byte matters (banking transactions, database replication).
- Scenarios where latency is not critical.

But for real‑time applications, TCP’s guarantees are a liability. By moving to UDP and building your own protocol, you gain the freedom to:

- Skip ordering when data is time‑sensitive.
- Accept occasional loss for lower latency.
- Tune retransmission strategies to your exact needs.
- Use multiple channels with different reliability profiles.

The future is moving in this direction: QUIC is essentially a custom protocol over UDP, standardized by the IETF. More and more applications are abandoning TCP for the flexibility of UDP.

**Final thought:** The art of building your own network protocol is about understanding the **semantics of your data**. Does missing a single position update matter? Then don’t retransmit it. Does a lost weapon‑fire command ruin the game? Then use reliable delivery for that channel. TCP treats all data equally; you shouldn’t.

So next time your game freezes, know that you have the power to fix it. Roll up your sleeves, grab UDP, and start building.

---

_This blog post is a living document. For code snippets, library comparisons, and additional case studies, check the companion repository._
