---
title: "Scheduling: Trading Latency for Throughput (and Back Again)"
date: 2025-02-12T10:00:00Z
description: "Queue disciplines, work stealing, and CPU affinity: how scheduler choices shape p50/p99, and when to bias for one over the other."
tags: ["scheduling", "latency", "throughput", "concurrency", "work-stealing"]
categories: ["Engineering"]
draft: false
cover: "/static/assets/images/blog/scheduling-latency-vs-throughput.png"
coverAlt: "Queueing diagram contrasting FIFO, priority, and work‑stealing schedulers"
---

Schedulers encode policy: who runs next, on which core, and for how long. Those choices shuffle latency and throughput. Let’s make the trade‑offs explicit.

## FIFO vs. priority vs. fair

- FIFO: simple, minimal overhead; tail prone under bursty arrivals.
- Priority: protects critical work; risks starvation without aging.
- Fair (CFQ‑like): shares CPU evenly; may underutilize when work is imbalanced.

## Work stealing

Great for irregular parallel workloads. Each worker has a deque; thieves steal from the tail. Pros: high utilization; Cons: cache locality losses and noisy tails under high contention.

## Affinity and locality

Pin hot threads; keep their working sets nearby. Migrating a thread mid‑burst swaps warm caches for cold ones.

## A pragmatic recipe

Pick a simple baseline; instrument p50/p95/p99; introduce priority lanes only where user pain exists; and keep a budget for stealing when queues skew.

## 1) Latency vs throughput: a queueing lens

A service is a queue with servers. When arrival rate λ approaches service rate μ, the utilization ρ=λ/(kμ) for k servers approaches 1 and latencies explode geometrically. Policies decide who waits and where variability ends up. If you optimize purely for throughput, you run hot (ρ≈1) and accept long tails. If you optimize for latency, you reserve slack and reduce variance, sacrificing peak throughput.

Key facts from M/M/1 intuition that hold surprisingly often:

- Mean response time grows like 1/(1−ρ). At ρ=0.9, you’ve already multiplied queueing delay by 10×.
- Variance is poison for tails. Even with the same mean service time, higher variance yields fatter tails.
- Shortest‑job‑first (SJF) or SRPT minimizes mean response time; prioritizing short requests helps everyone’s perceived latency when you can predict job sizes.

## 2) Designing scheduler queues for services

Practical server designs typically use:

- One queue per worker/core for cache locality.
- A fast lane for known‑short requests (health checks, reads) and a bulk lane for heavy CPU/IO tasks.
- Admission control: caps on in‑flight per endpoint/tenant to bound queue growth.
- Deadlines and budgets: each request carries a deadline; schedulers drop or downgrade work unlikely to meet its budget.

Two common patterns:

- Token buckets: each queue has tokens for CPU/time budget; short path refills faster.
- Deficit round robin (DRR): approximate weighted fair sharing with credit accumulation; combine with size estimates for SJF‑ish ordering.

## 3) Work stealing without tail regret

Work stealing shines when workloads are unbalanced, but you need guardrails:

- Steal thresholds: only steal if victim depth exceeds N; steal M tasks at once to amortize costs.
- NUMA‑aware stealing: prefer within‑socket steals; cross‑socket as a last resort.
- Size‑aware queues: tag tasks with coarse size classes; only steal from classes where your core can help.
- Backoff and jitter: avoid synchronized thief storms by randomizing victim selection and adding exponential backoff.

Implementation notes: lock‑free deques like Chase‑Lev are friendly to work stealing; use hazard pointers or epoch reclamation to avoid ABA issues. Measure with per‑thread steal counts and cache miss counters.

## 4) CPU affinity, IO pollers, and the memory hierarchy

If your scheduler ignores caches and NUMA, you’ll pay in p99. Pin long‑lived threads; assign memory by first touch; avoid bouncing hot threads. For network and disk IO, consider dedicated poller threads bound to cores with busy‑polling (io_uring) to reduce wakeup latency and jitter.

For JVM or GCed runtimes, isolate GC threads from latency‑sensitive workers; large STW pauses annihilate tails. For Go, partition goroutine pools by class; for Rust/C++, use per‑class executors.

## 5) OS schedulers in brief and how to work with them

- Linux CFS: fair by design; use cpusets and cgroups to create sandboxes where your user‑level scheduler can run without noisy neighbors.
- Real‑time policies (SCHED_FIFO/RR): powerful but dangerous; reserve for dedicated appliances with watchdogs.
- Priority inversion: mitigate with priority inheritance or by avoiding mutex contention in hot paths.

Expose scheduler state in metrics: run queue length per worker, context switches, migrations, and time spent runnable vs on‑CPU.

## 6) Service‑level controls trump kernel policies

Kernel schedulers don’t know your SLAs or request classes. Add service‑level controls:

- Rate limiters at ingress to shape traffic and avoid overload cascades.
- Circuit breakers and bulkheads to prevent failures from spreading across queues.
- Retries with jitter and budgets; ensure clients don’t generate retry storms that double load in the worst moments.
- Deadline propagation in distributed traces; if a caller has 200 ms left, pass that down and abandon work past that budget.

## 7) Experiments that expose scheduler truths

Run these in staging with realistic traffic:

- Size‑based lanes: split small vs large requests by a rough size estimator (bytes, rows, predicted CPU). Observe p95/p99.
- Work stealing on/off: compare tail variance at different utilization; verify that NUMA‑local stealing helps.
- Affinity: pin workers and pollers; measure L3 miss rates and p99.
- Background isolation: move compaction/GC/indexing into a separate cgroup; watch foreground tails improve.

## 8) A concrete playbook

1. Start with per‑core queues, FIFO, bounded.
2. Add a short‑request lane with reserved capacity; route using a simple heuristic (payload size, endpoint allowlist).
3. Implement admission control: per‑endpoint inflight caps and per‑tenant quotas.
4. Add deadlines to requests; cancel work past deadline and prefer preemption for long jobs.
5. Enable work stealing with thresholds and NUMA awareness.
6. Pin hot threads and IO pollers; validate with perf and numastat.
7. Instrument relentlessly; review scheduler dashboards alongside error budgets weekly.

## 9) Anti‑patterns and failure modes

- One global queue with no bounds; head‑of‑line blocking causes “traffic jams.”
- Retrying everything without budgets; clients amplify tails and overload.
- Ignoring memory hierarchy; threads migrate freely, obliterating caches.
- Treating fair as good enough; fair is a policy choice, not an SLA tool.

## 10) The principle to remember

Schedulers can only move pain around. To protect p99, you must isolate and prioritize short, user‑visible work, and cap the rest. To maximize throughput, you keep cores busy and minimize contention, accepting that some requests will wait. Build systems that can switch modes—automatically when SLOs slip or during peak events.

## 11) Worked examples: seeing the math

Example 1: Single queue vs two lanes. Assume arrivals are a mix: 80% short jobs (mean 2 ms), 20% long jobs (mean 20 ms), one core. In a single FIFO, long jobs sit at the head and block many short ones—p95 explodes. With two lanes and 30% reserved capacity for short jobs, p95 for short requests drops dramatically even though overall utilization is unchanged. The reason is SRPT‑like behavior: short jobs don’t get stuck behind long ones.

Example 2: Work stealing thresholds. With four cores and skewed arrivals, allowing steals only when victim depth > 8 and stealing 4 at a time reduces lock traffic by ~50% in practice while maintaining balanced queues. Cross‑socket steals without thresholds increase cache misses and p99 by 10–30% in many microbenchmarks.

## 12) Case studies

- Web API under burst: moving from one global queue to per‑core queues + fast lane cut p99 by 40% at the same throughput; adding admission control prevented the retry storm from spiraling.
- Analytics batch: disabling work stealing improved throughput by 5% due to better locality; tails were irrelevant, so the scheduler favored CPU cache alignment over fairness.
- KV store: pinning IO pollers and enabling busy‑poll reduced tail latency jitter; NUMA‑aware stealing avoided remote memory hits during spikes.

## 13) Concrete configs to try

- Per‑core queues length‑bounded at 1024; drop with 503 when full.
- Fast lane: reserve 30% threads; promote/demote based on observed service time thresholds.
- Stealing: threshold 8, batch 4, prefer within‑socket.
- Deadlines: read 200 ms, write 1 s; abandon when budget < 25 ms.
- Backpressure: per‑tenant caps to isolate noisy neighbors.
- Observability: dashboards for queue depth distributions and per‑class p95/p99.

## 14) What to automate

- Auto‑tuning lane sizes based on observed tail targets and current mix.
- Auto‑suspend stealing during IO storms; re‑enable as bursts pass.
- Auto‑throttle background compaction when foreground p99 > SLO.
- Auto‑promotion of endpoints to fast lane when their observed median < threshold and tail criticality is high.

## 15) Closing checklist

- [ ] Separate queues by class (short vs bulk)
- [ ] Admission control and per‑tenant caps
- [ ] NUMA‑aware work stealing with thresholds
- [ ] CPU and IO affinity for hot threads
- [ ] Deadlines and cancellation wired through
- [ ] Tail‑biased tracing and dashboards
- [ ] Runbooks for mode switching and overload
