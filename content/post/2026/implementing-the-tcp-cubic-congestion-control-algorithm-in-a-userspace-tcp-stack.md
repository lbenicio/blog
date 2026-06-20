---
title: "Implementing The Tcp Cubic Congestion Control Algorithm In A Userspace Tcp Stack"
description: "A comprehensive technical exploration of implementing the tcp cubic congestion control algorithm in a userspace tcp stack, covering key concepts, practical implementations, and real-world applications."
date: "2026-05-05"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Implementing-The-Tcp-Cubic-Congestion-Control-Algorithm-In-A-Userspace-Tcp-Stack.png"
coverAlt: "Technical visualization representing implementing the tcp cubic congestion control algorithm in a userspace tcp stack"
---

# Introduction: Taming the Beast – Implementing TCP CUBIC Congestion Control in a Userspace TCP Stack

Imagine a world where every web page loads instantly, every video streams without buffering, and every cloud service responds as if the server is sitting on your desk. We’re not there yet, but the relentless march of networking innovation has brought us tantalisingly close. At the heart of this quest lies a seemingly simple question: how do you send data as fast as possible without drowning the network in packets? The answer, for decades, has been congestion control – the art of sharing limited bandwidth fairly among competing flows. And when it comes to high-bandwidth, long-delay networks, no algorithm has been more influential than TCP CUBIC.

But here’s the twist: modern applications are increasingly bypassing the operating system’s kernel network stack altogether. They’re building TCP stacks in **userspace** – running as ordinary processes – to achieve microsecond-level latency, custom logic, and unshackled performance. And that’s where CUBIC becomes a double‐edged sword. Implementing it correctly outside the kernel is far more than a simple translation of a few mathematical equations. It requires rethinking timers, event loops, memory ordering, and even the very notion of “time” when you no longer have the kernel’s jiffies or high-resolution timers handed to you on a silver platter.

In this post, I’ll walk you through the journey of implementing TCP CUBIC congestion control from scratch inside a userspace TCP stack. We’ll explore why CUBIC matters, why you’d want to run it in userspace, and – most importantly – the concrete steps and pitfalls you’ll encounter along the way. Buckle up: it’s going to be a deep dive, but one that will leave you with a rock-solid understanding of one of the most deployed congestion control algorithms in the world.

---

## Part 1: The Battle for Bandwidth – A Brief History of TCP Congestion Control

To appreciate CUBIC, we must first understand the problem it solves. The internet is a shared resource: millions of connections traverse the same links, routers, and switches. Without congestion control, a single aggressive flow could consume all available buffer space, causing packet loss for everyone else. The seminal work of Van Jacobson in 1988 introduced the first practical congestion control algorithm, TCP Tahoe, and with it the principles of **additive increase/multiplicative decrease (AIMD)**.

### From Tahoe to Reno

TCP Tahoe’s core insight was simple: a sender uses a congestion window (cwnd) to limit how many packets can be in flight. It starts with a small window, doubles it each round-trip time (slow start) until it detects a loss (three duplicate ACKs or a timeout), then cuts cwnd by half and enters congestion avoidance. In congestion avoidance, cwnd increases by one packet per RTT (additive increase). This works well for low-bandwidth, low-delay networks but fails spectacularly on high-bandwidth links – it can take hundreds of RTTs to recover after a loss.

TCP Reno improved on Tahoe by adding fast recovery, allowing the sender to avoid a timeout after a triple duplicate ACK. However, Reno still suffers from the same “square-root” throughput limitation: the average window size grows as the square root of the loss rate. On a 10 Gbps link with a 100 ms RTT, you need a loss rate below 10⁻⁸ to achieve full utilization – an unrealistic demand.

### The Birth of High-Speed TCP Variants

Researchers quickly realized that AIMD is fundamentally suboptimal for high-bandwidth, long-delay (high BDP) networks. Several proposals emerged: Scalable TCP (fixed increase), HighSpeed TCP (HSTCP), and BIC-TCP. The latter became the stepping stone to CUBIC.

BIC-TCP (Binary Increase Congestion control) treats the congestion window as a binary search space. After a loss, it sets the target window (W_max) to the current window, then searches for the new equilibrium between W_max and the window just after loss (W_max \* beta). The search is “binary”: it takes the midpoint and increases to it quickly, then slows down near the target. This provides rapid utilization recovery while maintaining stability. However, BIC’s growth function is piecewise linear and not elegant mathematically; it also suffers from RTT unfairness issues.

### Enter CUBIC

CUBIC (2005, by Injong Rhee and Lisong Xu) elegantly solves BIC’s issues by modeling the window growth as a cubic function of time. The key idea: after a loss, the sender remembers the window size at which loss occurred (W_max). It then tries to regain that window quickly (concave region), then slowly probe for more bandwidth (convex region). The cubic function ensures smooth, RTT-independent growth in the probing phase.

The core equation is:

```
W(t) = C * (t - K)^3 + W_max
```

Where:

- `t` is the time elapsed since the last loss event.
- `K = (W_max * (1 - β)/C)^(1/3)` is the time needed to reach W_max again.
- `C` is a scaling constant (default 0.4).
- `β` is the multiplicative decrease factor (0.2 in CUBIC).

This simple function produces a beautiful behavior: after a loss, the window grows rapidly (concave up) until it reaches W_max, then grows slowly (convex up) near and beyond W_max. The slow growth near W_max allows for stable equilibrium with other CUBIC flows. And because the growth is time-based, not RTT-based, CUBIC is much more fair to flows with different RTTs than BIC or HSTCP.

CUBIC has been the default congestion control algorithm in Linux since kernel 2.6.19 (2006). Today, it handles the vast majority of TCP traffic on the internet – from web servers to data center bulk transfers. Its success is a testament to its simplicity and effectiveness.

---

## Part 2: Why Userspace? The Rise of Kernel-Bypass Networking

The traditional network stack lives in the kernel. For decades, applications have relied on the Berkeley socket API (e.g., `socket()`, `accept()`, `read()`, `send()`) to handle TCP. The kernel manages flow control, retransmission, ACK processing, and congestion control in a monolithic, well-tested core. So why would anyone want to replicate all that complexity in userspace?

### The Performance Tax of the Kernel

Every network operation that passes through the kernel incurs overhead:

- System calls (context switches between user and kernel space).
- Data copies (from user buffers to kernel buffers, then to NIC).
- Spinlocks, interrupt handling, and softirq processing.
- The general-purpose design of the kernel stack, optimized for fairness over speed.

For low-latency applications (e.g., financial trading, high-frequency caching) or high-throughput workloads (e.g., 100 Gbps network), this overhead becomes prohibitive. Even with optimizations like `sendfile()` or `SO_RCVBUF`, the kernel can become a bottleneck.

### Kernel-Bypass Techniques

To eliminate these costs, several techniques emerged:

1. **DPDK (Data Plane Development Kit)** – Provides user-space drivers for NICs, allowing applications to poll directly from hardware queues, bypassing the kernel entirely. Packets are received as raw frames; the application must implement all protocol logic.

2. **RDMA (Remote Direct Memory Access)** – Hardware-supported zero-copy networking, but requires specialized NICs and typically uses InfiniBand or RoCE.

3. **Userspace TCP stacks** – Libraries like mTCP, F-Stack, VPP (Vector Packet Processing), and custom implementations that run TCP on top of DPDK or raw sockets. These stacks offer full control over packet processing, memory management, and algorithm selection.

A userspace TCP stack is essentially a multi-threaded (or event-loop-driven) application that:

- Opens a raw socket or DPDK port.
- Receives Ethernet frames, decodes IP/TCP headers.
- Maintains per-connection state: send/receive buffers, sequence numbers, round-trip time (RTT) estimator, and congestion controller.
- Processes incoming ACKs, triggers data retransmission, and advances the congestion window.
- Sends data packets via the raw interface, respecting pacing and window limits.

### The Challenge of Congestion Control in Userspace

In the kernel, the congestion controller runs in interrupt context or a bottom-half (softirq) – it has access to accurate, low-latency timers (jiffies, hrtimers) and can react to incoming ACKs in microseconds. In userspace, you must manage these primitives yourself:

- **Timers**: The kernel can schedule a timer callback that fires at microsecond granularity. In userspace, you rely on `timerfd`, `SETITIMER`, or polling loops with `clock_gettime()`. The precision is lower, and scheduling delays can be hundreds of microseconds.

- **Event loops**: Most userspace stacks are single-threaded (or per-core) with epoll/poll loops. ACK processing must be interleaved with sending and application logic. If your loop stalls (e.g., due to garbage collection), RTT estimation and window updates are delayed.

- **Memory ordering**: In the kernel, locking is straightforward because only one CPU core may be processing packets for a given flow at a time (via receive-side scaling). In multithreaded userspace stacks, you must carefully use atomic operations or per-flow locking – a subtle source of bugs.

- **Accurate RTT measurement**: The kernel samples RTT on each ACK using timestamps taken at the moment the packet was sent. In userspace, you have to record your own timestamps (e.g., `clock_gettime(CLOCK_MONOTONIC, ...)`) and correlate them with the outgoing packet’s sequence number. A mis-step leads to wild RTT estimates and flawed congestion window calculations.

- **Pacing**: CUBIC is defined as a window-based algorithm: you can send up to `cwnd` packets per RTT. But sending them in a burst causes microburst congestion and increases packet loss. Modern stacks use pacing to spread the burst over the RTT. In the kernel, the pacing is integrated with the TCP transmit scheduler. In userspace, you must implement a pacing layer, often using a high-resolution timer or a token bucket.

These challenges transform a seemingly simple mathematical formula into a complex engineering puzzle. But once solved, the rewards are enormous: you can achieve 10-20 Gbps per core, with latencies under 10 microseconds, while running your own congestion control logic.

---

## Part 3: Implementing TCP CUBIC – Step by Step

Let’s now dive into the actual implementation. We’ll assume you have a basic userspace TCP stack that can send and receive raw TCP segments, maintain per-connection state, and process ACKs. We’ll focus on the congestion control module.

### 3.1 Data Structures

At a minimum, we need:

```c
struct cubic {
    // Congestion window (in packets or bytes)
    uint32_t cwnd;          // current window
    uint32_t ssthresh;      // slow start threshold
    uint32_t w_max;         // window size at last loss event
    uint64_t last_time;     // time (in us) of last loss event
    float C;                // cubic constant (0.4)
    float beta;             // multiplicative decrease factor (0.2)
    uint32_t fast_recovery; // flag: are we in fast recovery?
};
```

We also need a per-connection RTT estimator (usually a structure containing smoothed RTT, RTT variance, and an estimate of the minimum RTT – but for CUBIC we only need the smoothed RTT). The RTT is used to convert between window and sending rate, but CUBIC’s window growth is independent of RTT except during the initial slow start.

### 3.2 Slow Start and Congestion Avoidance

TCP CUBIC follows the standard TCP states:

- **Slow start**: cwnd starts at 1 MSS (maximum segment size). For each ACK received, cwnd increases by 1 MSS (exponential growth). When cwnd reaches ssthresh, we switch to congestion avoidance.

- **Congestion avoidance**: This is where CUBIC diverges from standard Reno. Instead of linear increase of 1 MSS per RTT, we compute the cubic function.

### 3.3 The Cubic Function

The core logic in congestion avoidance:

```c
uint32_t cubic_update(struct cubic *c, uint64_t now_us, uint32_t rtt_us) {
    if (c->fast_recovery) {
        // During fast recovery, cwnd is set to ssthresh + number of dupacks
        // We'll handle that separately.
        return c->cwnd;
    }

    // Time since last loss (in seconds, but we use microseconds for precision)
    uint64_t delta_us = now_us - c->last_time;
    double t = (double)delta_us / 1000000.0; // seconds

    // Compute K
    double w_max = (double)c->w_max;
    double K = pow(w_max * (1.0 - c->beta) / c->C, 1.0/3.0);

    // Cubic window in packets (assuming MSS is constant)
    double cubic_window = c->C * pow(t - K, 3.0) + w_max;

    // Ensure we don't grow too slowly; also include standard Reno as a lower bound
    // The original CUBIC also checks against a linear "Reno-friendly" window.
    uint32_t target_cwnd = (uint32_t) round(cubic_window);
    if (target_cwnd < c->cwnd + 1) {
        target_cwnd = c->cwnd + 1; // at least 1 MSS per RTT
    }

    // Clamp to avoid overflow
    if (target_cwnd > MAX_CWND) target_cwnd = MAX_CWND;

    return target_cwnd;
}
```

Wait – there’s a subtlety. The above computes the target window based solely on time. But in real CUBIC, the actual increase per ACK is not simply setting cwnd to `target_cwnd`; rather, CUBIC computes the increase **per ACK** based on the time elapsed since the last ACK. The original paper defines the window growth as:

```
W(t) = C * (t - K)^3 + W_max
```

And then, on each ACK, the sender increases cwnd by `delta_cwnd = (W(t_now) - W(t_last_ack))`. This ensures the growth is truly time-dependent, not RTT-dependent. The formula for `delta_cwnd` is:

```
delta_cwnd = (W(t + Δt) - W(t)) / (cwnd * MSS)
```

Where Δt is the time between the current ACK and the previous ACK. But in practice, many implementations (including Linux) use a simpler per-ACK increment:

```
cwnd_increment = (target_cwnd - current_cwnd) * (ack_data / cwnd)
```

Or even just:

```
if (cwnd < target_cwnd)
    cwnd += 1 / cwnd; // fractional increase per ACK
```

Linux’s CUBIC implementation actually does a more elegant computation: it calculates the target window at the current time, then adjusts cwnd to approach that target at the rate of `1 MSS per RTT`. However, the key point is that the target grows smoothly over time.

For simplicity in a userspace stack, we can adopt the following approach:

- Maintain a `cubic_state` that stores `last_cwnd_update_time`.
- On each ACK, compute `now = current_time`, `delta_t = now - last_cwnd_update_time`.
- Compute the target window `W_t = C * (t - K)^3 + W_max` at `t = now - loss_time`.
- Compute `W_target_at_last_update` similarly.
- The increase we need to add to cwnd is: `increase = (W_t - w_target_last) / w_target_last * cwnd` (very roughly). Actually, a common derivation is:

```
cwnd_increment = (target_cwnd - cwnd) / cwnd
```

But that can cause sawtooth. Let’s look at the Linux kernel source (`net/ipv4/tcp_cubic.c`) for inspiration.

The critical function is `tcp_cubic_cong_control()` which uses:

```c
target = cubic_root(w_last * (1 - beta) / C) ... etc.
```

But for userspace, a more robust method is to use a token-bucket or pacing-based approach: maintain a “target cwnd” from the cubic function, and when cwnd < target, increase it as a fraction of 1 MSS per ACK. The exact path isn’t critical as long as the window growth over time approximates the cubic curve.

**Practical tip**: In a userspace stack, you don’t have per-ACK interrupts. Instead, your event loop processes batches of ACKs. So you should accumulate the increase over the batch:

```c
uint32_t num_acks = batch_size;
while (num_acks--) {
    if (cwnd < target_cwnd) {
        cwnd += 1.0 / cwnd; // fractional packet per ACK
    }
}
```

This works well for moderate batch sizes (< 64). For super high-speed (100 Gbps), batch sizes could be thousands, and you might need a smoother approach: `cwnd += batch_size / cwnd`.

### 3.4 Packet Loss Detection and Recovery

CUBIC uses standard TCP loss detection: triple duplicate ACKs or timeout. When a loss is detected (i.e., three dupacks), we set:

```
w_max = cwnd;                          // remember the window before loss
ssthresh = cwnd * beta;                // 0.8 reduction
cwnd = ssthresh;                       // enter fast recovery
last_time = now;                       // record time of loss
```

Then we retransmit the lost segment and wait for partial ACKs (which ACK new data) to finally exit fast recovery.

During fast recovery, the CUBIC algorithm does not apply the cubic function. Instead, it follows the standard TCP NewReno behavior: for each duplicate ACK, cwnd inflates by 1 MSS (to allow new data to be sent), and upon the first partial ACK, it deflates to ssthresh.

**Important**: In a userspace stack, you must also handle retransmission timers (RTO). CUBIC does not change the RTO calculation (it uses Karn’s algorithm on the smoothed RTT). But ensure your RTO is not too coarse – many vanilla implementations use 1-second granularity, which is unacceptable for high-speed.

### 3.5 RTT Estimation and Time Management

As mentioned, in userspace you control the clock. Use `clock_gettime(CLOCK_MONOTONIC_RAW, ...)` for precise timestamps (avoid `CLOCK_REALTIME` as it can jump). Record the send time of each packet (or just the last packet sent) to compute RTT when the corresponding ACK arrives.

A simple RTT estimator:

```c
void cubic_update_rtt(struct cubic *c, uint32_t sample_us) {
    // Use Jacobson's estimator
    static const float alpha = 0.125;
    static const float beta = 0.25;
    if (c->srtt == 0) {
        c->srtt = sample_us;
        c->rttvar = sample_us / 2;
    } else {
        c->rttvar = (1 - beta) * c->rttvar + beta * abs(c->srtt - sample_us);
        c->srtt = (1 - alpha) * c->srtt + alpha * sample_us;
    }
}
```

Then `tcp_cubic_cong_control()` uses `srtt` to convert between packets and time only for pacing. The cubic target itself uses absolute time (`last_time`), not RTT.

### 3.6 Pacing Implementation

Even with a correct cwnd, sending all packets back-to-back causes bursts. CUBIC in the Linux kernel uses pacing via a high-resolution timer or TCP Small Queues. In userspace, you can implement a simple pacing mechanism:

- Compute the allowed sending rate: `rate = cwnd * MSS / srtt` (packets per second).
- Maintain a token bucket: each time you send a packet, deduct `MSS` tokens. Tokens are refilled at the rate `rate` over time.
- When tokens are insufficient, you must wait (e.g., by setting a timer or yielding in the event loop).

Better yet, many userspace stacks (like mTCP) implement a “transmission scheduler” that splits the cwnd into evenly spaced slots within the RTT.

Because CUBIC is window-based, not rate-based, strict pacing can underutilize the link if the RTT is larger than the inter-packet delay. The standard approach is to pace at `cwnd / srtt` but allow a small burst (e.g., 3 \* MSS) to handle ACK clocking. See the Linux kernel’s `tcp_pace.c`.

### 3.7 Handling ECN and Other Features

CUBIC can also respond to Explicit Congestion Notification (ECN). When a packet is marked with ECN Congestion Experienced (CE), the sender treats it like a loss: it reduces cwnd and records w_max. In userspace, you need to parse the IP ECN field in incoming packets and act accordingly.

---

## Part 4: Pitfalls and Practical Considerations

Despite its mathematical elegance, implementing CUBIC in userspace bites you in many unexpected ways.

### 4.1 Clock Granularity and Timer Drift

The entire cubic curve hinges on the “time since last loss”. If your clock jumps (e.g., due to NTP adjustment or sleep/wake cycles), the window will wildly oscillate. Always use `CLOCK_MONOTONIC` (or `CLOCK_MONOTONIC_RAW` to avoid NTP corrections). Even then, sampling the clock via system calls can be expensive – call it once per event loop iteration and use an offset.

Another issue: your event loop may not run immediately after a loss event. If there is a processing delay of 50μs, your `last_time` will be slightly off. Over many RTTs, this accumulates. The solution is to record time **at the moment you detect the loss** – i.e., when you decide to retransmit – not when you enter the `cubic_update()` function.

### 4.2 Memory Ordering and Multithreading

If your userspace stack uses multiple threads sharing a connection’s state (e.g., a send thread and a receive thread), you must synchronize access to `cwnd`, `w_max`, etc. The simplest is to use a spinlock or an atomic store/load for each field. However, for performance, many stacks assign each connection to a single CPU core (receive-side scaling) so no locking is needed. Ensure your design avoids data races.

### 4.3 Interaction with Other Flows

CUBIC is known to be less fair to flows with very small RTT (e.g., within the same data center). Because its growth is time-based, a flow with a 200μs RTT will grow its window to the same level as a flow with 20ms RTT within the same time, meaning the short-RTT flow becomes extremely aggressive. This is why modern data center stacks often use DCTCP or similar.

For internet deployments, this is usually acceptable, but if your userspace stack is used in a mixed environment, consider using CUBIC’s “Reno-friendly” mode: if the cubic window is less than a Reno window given the same loss rate, use Reno instead. This prevents CUBIC from starving Reno flows.

### 4.4 Burst Losses and Fast Recovery

CUBIC’s fast recovery is identical to TCP NewReno. However, if multiple losses occur in the same window (burst loss), the recovery can be extremely slow. Some implementations use SACK (Selective ACK) to recover faster. Incorporating SACK into your userspace stack is a major effort but vastly improves performance. Without SACK, CUBIC might take many round trips to recover from a single loss event.

### 4.5 Pacing Accuracy

Pacing with low latency is tricky. In a 10 Gbps link, the inter-packet gap is 12 ns (for 1500-byte packets). No userspace software timer can hit that precision. Hence, you must rely on the NIC’s hardware pacing (if available) or batch packets and send in bursts, accepting some microbursts. The trade-off is inevitable; CUBIC’s window algorithm expects bursts to be absorbed by buffers, but too many microbursts cause loss.

---

## Part 5: Testing and Validation

You cannot trust a userspace CUBIC implementation without rigorous testing. Here are essential steps:

### 5.1 Simulation

Use a simple packet-level simulator (you can write one in Python quickly) to verify the window evolution. Feed in a constant RTT and a loss model. Plot cwnd over time. The shape should be a classic CUBIC sawtooth: concave up after a loss, then convex.

### 5.2 Mininet

Run your userspace stack inside a Mininet topology with emulated delays and bandwidths. Use iPerf3 traffic generators. Measure throughput and verify that multiple CUBIC flows converge to fairness.

### 5.3 Real Hardware

Test on a pair of machines with high-speed NICs (10G/40G). Run your stack on one machine and a standard Linux CUBIC on the other. Compare throughput and fairness. Use `tcpdump` to capture packet traces and analyze window sizes and retransmissions.

### 5.4 Edge Cases

- **Timeout recovery**: Simulate a prolonged packet drop. Check that RTO computation works and that after timeout your `w_max` is reset correctly (Linux does not reset w_max on timeout, only on triple dupacks with fast recovery; but be careful).
- **Small windows**: When cwnd is 1 or 2, the cubic function should not cause insane growth.
- **Zero window**: If the receiver advertises zero window, pause sending.

### 5.5 Tools

- **Wireshark** for packet-level analysis.
- **ss/tcpdump** for kernel-side monitoring (if you mix stacks).
- **perf/oprofile** for profiling your userspace stack.

---

## Part 6: Future Directions and Alternatives

CUBIC has been a workhorse for nearly two decades, but it’s not the end of the story. Google’s BBR (Bottleneck Bandwidth and Round-trip propagation time) aims to model the network path more directly, avoiding packet loss as a congestion signal. BBR uses pacing and a rate-based approach. In userspace, BBR is simpler to implement because it doesn’t require per-ACK window updates – you simply adjust the sending rate. However, BBR has its own issues with fairness and retransmissions.

Another interesting alternative is **Copa**, which uses a delay-based approach. For data center environments, **DCTCP** is prevalent.

Despite these newcomers, CUBIC remains essential because of its wide deployment and interoperability. If your userspace stack needs to connect to the public internet, you must implement CUBIC; otherwise, you will aggressively push your traffic at the expense of legacy Reno flows. So while exploring new algorithms, ensure you have a working CUBIC implementation as a fallback.

---

## Conclusion

Implementing TCP CUBIC congestion control in a userspace TCP stack is an exercise in blending theory with reality. The cubic equation is beautiful – a simple polynomial that produces stable, efficient network utilization. But turning that equation into working code that runs reliably at wire speed requires you to rebuild the entire timekeeping and event infrastructure that the kernel provides for free.

We’ve walked through the why and how: the history of congestion control, the motivation for userspace stacks, the step-by-step implementation of CUBIC with code snippets, and the treacherous pitfalls of timer precision, memory ordering, and pacing. By now, you should have a solid foundation to roll up your sleeves and start coding.

But remember: a userspace stack is not just a toy – it’s a serious piece of infrastructure. Test ruthlessly, profile relentlessly, and always question your assumptions. The network is a wild, unpredictable beast, and taming it with a cubic function is only the first step. The journey continues.

---

_Have you implemented CUBIC in userspace? What challenges did you face? Share your story in the comments below. And if you enjoyed this deep dive, consider checking out my other posts on TCP optimization and kernel-bypass techniques._
