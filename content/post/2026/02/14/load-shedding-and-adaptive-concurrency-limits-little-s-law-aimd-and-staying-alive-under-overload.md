---
title: "Load Shedding and Adaptive Concurrency Limits: Little's Law, AIMD, and Staying Alive Under Overload"
description: "A systems-level treatment of admission control under overload: how Little's Law turns concurrency into a control variable, why latency collapses before capacity is exhausted, how retry storms create metastable failures, and how AIMD and gradient-based limiters actually behave in production."
date: "2026-02-14"
author: "Leonardo Benicio"
tags: ["distributed-systems","performance","reliability","queueing-theory","load-shedding","concurrency","backpressure"]
categories: ["Systems Design","Distributed Systems"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/load-shedding-and-adaptive-concurrency-limits-little-s-law-aimd-and-staying-alive-under-overload-2026-02-14.jpg"
coverAlt: "A dark technical illustration of a particle stream being admitted through a narrow gate into a calm region while excess particles are deflected into a discard channel, with a translucent funnel behind the gate representing growing queue depth and a steep curve rising toward the right."
---

# Load Shedding and Adaptive Concurrency Limits: Little's Law, AIMD, and Staying Alive Under Overload

## Overload is not a capacity problem you can autoscale away

Every service that survives contact with production eventually meets the same adversary: more concurrent work than it can complete at an acceptable latency. The reflexive response is to add capacity. Autoscaling helps, but it operates on a timescale of tens of seconds to minutes, and the failure it is meant to prevent happens in hundreds of milliseconds. Worse, the failure is often self-inflicted: the system does not run out of CPU, it runs out of *ordering*. Work arrives faster than it can be retired, queues grow, latency grows with them, and clients that were waiting on a deadline start retrying, which adds more work to the queue that is already too long. The system does not degrade gracefully. It falls off a cliff, and the cliff is a property of the queueing dynamics, not of the hardware.

This article is about the control layer that sits between clients and the work they want done: the component that decides, in real time, how much concurrent work to admit and what to reject when the answer is "less than you asked for." Two mechanisms are usually conflated and should not be:

- **Concurrency limiting (admission control).** A bound on the number of requests in flight against a resource — a thread pool, a connection pool, a downstream dependency, a database. It converts a latency problem into a throughput problem, deliberately.
- **Load shedding (rejection policy).** The rule that decides *which* work to drop when the bound is reached. The rule matters more than the bound, because a badly chosen rejection policy can consume nearly as much capacity as serving the request.

Both are distinct from **rate limiting**, which bounds arrivals per unit time. Rate limits assume requests have roughly uniform cost. Concurrency limits make no such assumption: they adapt automatically when service time changes, which is exactly the situation you care about, because service time is the thing that changes under load.

The argument proceeds in stages. First, the arithmetic that makes concurrency the right control variable. Second, why latency degrades long before utilization reaches one, and why the degradation is nonlinear. Third, the failure modes that turn a transient spike into a persistent outage. Later sections cover the specific algorithms — AIMD, gradient-based limiters, windowed-minimum RTT estimators, PID controllers — the mechanics of implementing them correctly, the design of shedding policies under deadlines and priorities, the interaction with distributed quotas and autoscaling, and how to test all of it without lying to yourself.

## Little's Law is the design equation, not a curiosity

Little's Law states that for any system in steady state, the long-run average number of items in the system equals the long-run average arrival rate multiplied by the long-run average time an item spends in the system:

```
L = λ · W
```

The assumptions are weaker than people expect. The system must be in steady state in the sense that the averages converge, items must not be created or destroyed inside the boundary, and the boundary must be drawn consistently. Nothing is assumed about arrival distributions, service distributions, scheduling discipline, or independence. That generality is why the law is useful as an engineering identity rather than a modelling exercise.

For a server handling requests, draw the boundary around the in-flight set — requests that have been admitted but not yet completed, including those queued and those executing. Then:

```
concurrency = throughput × latency
```

This single identity explains most of what happens under overload. Rearranged, `throughput = concurrency / latency`. If you fix concurrency at N and latency doubles, throughput halves. That is the entire reason a concurrency limit is a useful control: it does not prevent latency from rising, but it forces the system to pay for the rise in throughput rather than in unbounded queue growth.

The identity also clarifies what a limit is *not*. A concurrency limit is not a promise of low latency. It is a promise that the system will not accept more work than it can retire at the current service rate. If the service rate collapses — a downstream dependency slows from 5 ms to 500 ms — then a limit of 200 in-flight requests implies a throughput ceiling of roughly 400 requests per second, and no amount of tuning the limit changes that. The limit's job is to make the ceiling explicit and stable, so that the load balancer, the caller, and the retry logic all see a consistent, predictable failure mode instead of a random one.

There is a second, subtler use of the identity: it lets you *measure* concurrency rather than assume it. Instrument the in-flight count directly. If you cannot, you can derive it from throughput and latency, but only if both are measured over the same window at the same boundary. Mixing a server-side throughput counter with a client-side latency histogram produces a number that means nothing, and it is a common source of limiters that oscillate.

### The utilization law and the shape of the curve

A related identity, the utilization law, says that for a single resource, utilization equals arrival rate times mean service demand:

```
U = λ · S
```

where `S` is the mean service time per request. Combine this with the concurrency identity and you get the reason concurrency limits are conservative by nature: at utilization approaching one, the queueing delay dominates. For the simplest queueing model, M/M/1 — Poisson arrivals, exponential service, one server, FIFO — the mean time in system is:

```
W = S / (1 - ρ)
```

where `ρ = λ · S` is utilization. The ratio of response time to service time is `1 / (1 - ρ)`. At ρ = 0.5 the ratio is 2. At ρ = 0.9 it is 10. At ρ = 0.99 it is 100. The function is not merely steep; it is a hyperbola with a vertical asymptote at ρ = 1, and real systems approach that asymptote faster than the model suggests, because real service times are not exponential and real arrivals are not Poisson.

The M/G/1 result makes the variance explicit. The Pollaczek–Khinchine formula gives mean waiting time in queue as:

```
W_q = λ · E[S²] / (2 · (1 - ρ))
```

The second moment of service time appears in the numerator. A workload with occasional slow requests — a cache miss, a compaction, a lock held across a network call — has a much larger `E[S²]` than its mean service time suggests, and the queueing delay scales with it. This is the mathematical reason that p99 latency in a service is dominated by the *distribution* of service times rather than by the mean, and the reason that a single slow dependency can degrade every request that shares its queue.

### The knee, and why it moves

Practitioners talk about the "knee" of the latency-versus-load curve: the point where latency begins to rise faster than load. For latency-sensitive systems, the knee is typically somewhere in the 50–70% utilization range, and it moves. It moves *down* when service-time variance increases, when the arrival process becomes burstier, when the number of servers shrinks (fewer servers means less statistical multiplexing, so the same utilization produces more queueing), and when there are shared, serialized resources — a single database writer, a global lock, a hot shard — because those resources saturate at a utilization far below the fleet average.

The practical consequence is that you cannot pick a static concurrency limit by reasoning about the average. You have to pick it by measuring the knee, and then you have to keep re-measuring it, because the knee moves as the workload, the deployment, and the downstream dependencies change. This is the entire motivation for *adaptive* limits: a static limit is a snapshot of a curve that will not hold still.

## Why latency collapses before capacity is exhausted

It is worth being precise about what "overload" means, because the colloquial meaning hides three distinct regimes.

**Underload.** Concurrency is below the knee. Latency is roughly service time plus a small queueing term. Throughput scales linearly with offered load. Adding capacity helps; removing it hurts.

**Saturation.** Concurrency is near the knee. Latency rises superlinearly with load. Throughput is still increasing, but the marginal request adds more delay than it adds useful work. This is the regime where a concurrency limit has the most value, because it is the last point at which the system can be steered.

**Congestion collapse.** Concurrency is well past the knee. Throughput *decreases* as load increases. This is not a modelling artifact; it is what happens when the cost of managing work exceeds the value of completing it. Every additional queued request consumes memory, scheduler attention, cache footprint, and connection state, and the aggregate effect is that the system does less useful work per unit time than it did at lower load.

The transition from saturation to collapse is where most production incidents live. The mechanism is usually a positive feedback loop with a delay in it. A representative sequence:

1. A downstream dependency slows. Service time for the affected endpoint rises.
2. In-flight requests accumulate because the concurrency limit — if there is one — is set for the old service time, or because there is no limit at all and the thread pool simply grows.
3. Latency rises. Some fraction of requests now exceed their deadline.
4. Clients retry. Retries are additional arrivals, and they arrive *on top of* the original requests that are still in flight.
5. The queue grows further. Latency rises further. More requests exceed their deadline. More retries.

The loop is unstable because it has gain greater than one and a delay between cause and effect. The delay is what makes it hard to see in the moment: the retries caused by step 3 do not show up as extra load until step 5, by which point the operator is looking at a latency graph and not an arrival-rate graph.

### The economics of a queued request

A useful mental model: a request has value if and only if its response arrives before the caller stops caring. Under overload, the marginal request in the queue has a *negative* expected value, because it will likely be discarded by the client on timeout, and while it sits in the queue it consumes resources that could have been used to complete a request that would have been useful.

This is the argument for shedding over queueing. Blocking the caller — applying backpressure and making it wait — is the right answer when the caller has no deadline and there is a bounded queue with a bounded wait. It is the wrong answer when the caller has a deadline, because the wait is unbounded in the worst case and the work becomes worthless before it starts. Serving a request that will be timed out is strictly worse than rejecting it immediately: the client learns the same thing (failure) in less time, and the server frees the capacity for work that might succeed.

The corollary is that admission control should be **deadline-aware**. If a request has 40 ms of budget remaining and the current queueing delay is 200 ms, admitting it is a guaranteed waste. Rejecting it with an explicit, fast failure lets the caller fail over, degrade, or return a cached answer — all of which are better outcomes than a timeout.

## Retry storms and metastable failure

Retries are the single most common amplifier of overload, and the most common reason a transient spike becomes a sustained outage.

The arithmetic is unforgiving. If a client retries up to three times on failure, and the failure rate under overload is 50%, then the expected number of attempts per logical request is `1 + 0.5 + 0.25 + 0.125 ≈ 1.875`. The offered load nearly doubles precisely when the system has the least capacity to absorb it. If retries are issued by a fleet of clients with no coordination, the effect compounds: each client's retry schedule is independent, so the retry arrivals are not smooth but bursty, and the bursts align with the timeouts that triggered them.

The standard mitigations are well known but frequently implemented incompletely:

- **Retry budgets.** Cap retries as a fraction of total requests — for example, retries may not exceed 10% of the request rate. This bounds the amplification factor regardless of the failure rate. The budget must be enforced *globally* across the client fleet, or per caller with a shared token bucket, not per request.
- **Exponential backoff with jitter.** Without jitter, synchronized clients retry in lockstep and produce a thundering herd. Full jitter — a uniform random delay in `[0, min(cap, base · 2^attempt)]` — spreads the load. Decorrelated jitter is a reasonable alternative. The point is to avoid correlation, not to pick a specific distribution.
- **Retry only idempotent operations, and only when the failure is retryable.** A 503 from an overloaded dependency is retryable. A 400 is not. Retrying a non-idempotent write without an idempotency key is a correctness bug, not a resilience feature.
- **Circuit breakers.** Stop sending to a dependency that is failing, and probe it periodically. This converts a retry storm into a fast-fail, which is what you want when the dependency is genuinely down.

### Metastability

A **metastable failure** is a state in which the system is operating at low throughput, and remains there after the triggering condition is removed. The classic example is a retry storm that has filled a queue: even after the original spike ends, the queued retries keep the system saturated, which keeps latency high, which keeps clients timing out and retrying, which keeps the queue full. The system is in a self-sustaining low-throughput equilibrium.

Metastability is not limited to retries. Other mechanisms that create a self-sustaining degraded state include:

- **Cold caches.** A cache that is invalidated or evicted under memory pressure takes time to warm. During warming, every request is a miss, so service time is high, which increases concurrency, which increases memory pressure, which evicts more cache entries. The loop is stable in the bad state.
- **Connection pool exhaustion.** If connections are held for the duration of a slow request, a slow dependency monopolizes the pool. New requests queue for a connection, which adds latency, which lengthens the hold time, which further reduces pool availability.
- **Thread pool saturation with unbounded queues.** A fixed thread pool with an unbounded work queue will accept every request and never reject one. Latency grows without bound and memory grows with the queue. The system does not fail; it becomes useless, which is worse, because health checks may still pass and the load balancer may still route to it.
- **Health check flapping.** If the health check depends on the same saturated resource, instances cycle in and out of rotation, redistributing load in a way that prevents any instance from recovering.

The common structure is a resource whose availability depends on the rate at which it is consumed, plus a feedback loop that increases consumption when availability drops. Breaking the loop requires an explicit rejection path — something that refuses work even though it *could* accept it, because accepting it makes the state worse. That is what a concurrency limit is for, and it is why the limit must be enforced *before* the queue, not after it.

This is also why load shedding must be paired with a *recovery* mechanism. Shedding alone will hold the system at the limit, but the limit itself must be re-estimated as the system recovers, or the service will stay artificially throttled long after the trigger has passed. The next sections build the control loop that does this: what signal to measure, how to convert it into a limit, how to move the limit without oscillating, and how to decide which requests to drop when the limit binds.

## Measuring the right signal: latency, queueing delay, and the minimum RTT

The control loop for an adaptive concurrency limit needs a signal that indicates how close the system is to the knee. The most direct signal is latency, but not all latency measurements are equally useful. Average latency is a poor choice: it is heavily influenced by the bulk of requests that complete quickly, and it lags behind sudden changes. A service can have a stable average latency while its p99 latency is climbing, because the queue is filling with a small number of slow requests. By the time the average moves, the system is already deep into saturation.

A better signal is the **queueing delay** — the time a request spends waiting before it begins execution. If you can measure it directly (e.g., timestamp when the request enters the admission queue and when it starts executing), it is the cleanest indicator of congestion. But many systems do not have a separate queue; requests are dispatched immediately to a thread pool or event loop, and the "queueing" is implicit in the scheduler. In that case, you can approximate queueing delay by subtracting a baseline service time from the observed end-to-end latency.

The baseline service time is the latency the system would achieve with no queueing. You cannot measure it directly under load, but you can estimate it as the **minimum RTT** observed over a sliding window. The minimum is a robust estimator because it captures the fastest possible response, which occurs when there is no contention. In practice, you take the 1st or 5th percentile of latency over a window of, say, 10 seconds or 1000 requests, and treat that as the baseline. Then:


queueing_delay ≈ current_latency - min_latency


The ratio `queueing_delay / min_latency` is an estimate of how many requests are queued relative to the service capacity. If the ratio is 0, the system is idle. If it is 1, the queueing delay equals the service time, which corresponds to a utilization of roughly 50% in an M/M/1 queue. If it is 10, the system is heavily congested.

This is the same principle behind TCP Vegas, which uses the minimum round-trip time to estimate the number of packets in flight in excess of the network's capacity. For application-level concurrency, the analogy holds: the minimum latency is the "propagation delay" (service time), and the excess latency is the "queueing delay" caused by too many in-flight requests.

The minimum RTT estimator has two practical problems. First, it can be artificially low if the system experiences a period of very low load, and then the baseline becomes stale when the system's service time changes (e.g., after a deployment or a change in downstream dependencies). To handle this, you should decay the minimum over time or reset it periodically. A common approach is to keep a histogram of latencies over a long window (e.g., 1 minute) and take the 10th percentile as the baseline, which is less sensitive to outliers than the absolute minimum.

Second, the minimum RTT may not be achievable if the system is never truly idle. In a busy service, even the fastest requests may experience some queueing. In that case, the minimum RTT is an overestimate of the true service time, and the queueing delay is underestimated. This makes the controller less sensitive to congestion, which is safer than being too aggressive, but it can cause the limit to be set too high. You can compensate by using a target queueing delay ratio that is lower (e.g., 0.2 instead of 0.5).

An alternative signal is **concurrency itself**. If you know the throughput and the concurrency, Little's Law gives you the latency. But measuring concurrency directly is often easier than measuring latency: a simple atomic counter incremented on admission and decremented on completion. Then you can compute the average latency over a window as `concurrency / throughput`. This is useful if you cannot instrument latency precisely, but it is a derived signal and inherits the noise of both counters.

Finally, you can use **error rate** as a signal. If requests are timing out or failing with 5xx, the system is likely overloaded. But error rate is a lagging indicator: by the time errors appear, the system is already in trouble. It is better as a safety net — a hard limit that triggers a multiplicative decrease — than as the primary control signal.

## AIMD: simple, robust, and easy to get wrong

AIMD — additive increase, multiplicative decrease — is the workhorse of adaptive concurrency control. It was popularized by TCP congestion control, and it works for the same reasons: it converges to a fair share of capacity, it is robust to noise and heterogeneity, and it has a well-understood stability property.

The algorithm is simple. Maintain a limit `L`. On each successful request (or each measurement interval where the latency is below a target), increase `L` by a small constant `α` (typically 1). On each failure (or when latency exceeds the target), decrease `L` by a multiplicative factor `β` (typically 0.5 or 0.9):


if success:
    L = L + α
else:
    L = L * β


The choice of what constitutes "success" and "failure" is critical. If you use request completion (HTTP 2xx) as success, then any error — including client errors like 400 — will cause a decrease, which is wrong. You should only decrease on signals of overload: timeouts, 503s, or latency above a threshold. Similarly, you should only increase when the system is healthy: latency below the target and no errors.

The convergence properties of AIMD are well studied. In steady state, the limit oscillates around the knee. The amplitude of the oscillation depends on `α` and `β`. A smaller `α` gives finer control but slower adaptation. A larger `β` (closer to 1) gives a gentler decrease, which reduces oscillation but makes recovery from overload slower. Typical values are `α = 1` and `β = 0.5` for aggressive decrease, or `β = 0.9` for smoother behavior.

One common mistake is to apply the decrease on every failed request. If the system is overloaded and 50% of requests are failing, the limit will drop by a factor of `0.5^N` in a very short time, where `N` is the number of failures. This is too aggressive and can cause the limit to collapse to a very low value, leading to underutilization. The fix is to apply the decrease at most once per measurement interval (e.g., once per second), or to use a moving average of failures. Netflix's concurrency limits library, for example, updates the limit on a fixed schedule (e.g., every 100ms) based on the observed latency and the current limit.

Another mistake is to increase the limit without bound. You should cap the limit at a maximum value that represents the known capacity of the resource (e.g., the size of the thread pool or the maximum number of connections). This prevents the controller from overshooting during a period of artificially low latency (e.g., when the system is idle but a burst is about to arrive).

AIMD is also used in a distributed setting. If each instance runs its own AIMD controller, they will independently converge to a limit that is appropriate for their own load. But if the load balancer distributes requests unevenly, some instances may be overloaded while others are idle. A global AIMD controller, where the limit is shared across all instances, avoids this but requires coordination. A common compromise is to have each instance report its limit and load to a central coordinator, which computes a global limit and distributes it back. The coordinator can be a simple service that aggregates the limits and applies a global AIMD update. The communication overhead is small if the update interval is on the order of seconds.

## Gradient-based and PID limiters: using the shape of the curve

AIMD treats the system as a black box: it only knows whether the current limit is too high or too low. A gradient-based limiter goes further by estimating the slope of the latency-versus-concurrency curve. If the slope is near zero, the system is under the knee and the limit can be increased. If the slope is steep, the system is past the knee and the limit should be decreased.

The gradient is estimated from time-series data. At each measurement interval, record the current concurrency `C` and the observed latency `W`. Over a window of recent samples, fit a line (or use a simple difference) to estimate `dW/dC`. Then adjust the limit proportionally to the negative gradient:


L = L - γ * (dW/dC)


where `γ` is a step size. If the gradient is positive (latency increases with concurrency), decrease `L`. If the gradient is negative (which can happen due to noise), increase `L`. In practice, the gradient is noisy, so you need to smooth it. A simple exponential moving average of the gradient works well.

The advantage of gradient-based control is that it can react more quickly to changes in the knee. If the knee moves suddenly (e.g., a downstream dependency slows), the gradient will spike, and the limit will be reduced before latency becomes catastrophic. AIMD, by contrast, only reacts after latency exceeds a threshold, which may be too late.

The disadvantage is complexity and sensitivity to noise. Latency measurements are often heavy-tailed and non-stationary. A single outlier can produce a large gradient estimate and cause a wild swing in the limit. To mitigate this, you should use robust statistics: median instead of mean, or a trimmed mean. You should also bound the rate of change of the limit (e.g., no more than 10% per interval).

A PID controller is a generalization of this idea. The controller has three terms:

- **Proportional (P):** responds to the current error (target latency minus measured latency).
- **Integral (I):** responds to the accumulated error over time, eliminating steady-state offset.
- **Derivative (D):** responds to the rate of change of error, anticipating future error.

The output is the concurrency limit. PID controllers are used in many control systems, but they require tuning. The integral term can cause windup: if the system is saturated for a long time, the integral accumulates a large value, and when the error finally reverses, the controller overshoots. Anti-windup techniques (e.g., clamping the integral term) are necessary.

For most application-level concurrency limiters, a full PID is overkill. A proportional controller with a deadband (ignore small errors) and a derivative term (to dampen oscillations) is often sufficient. The key is to choose a target latency that corresponds to the knee. If you set the target too low, the limit will be conservative and throughput will suffer. If you set it too high, the system will oscillate around saturation.

A practical approach used by some systems is to combine AIMD with a gradient-based override. AIMD provides the baseline adaptation, and when the gradient exceeds a threshold (indicating a rapid change in the knee), the limit is multiplicatively decreased immediately. This hybrid gives both stability and responsiveness.

## Implementing the limiter: placement, distribution, and shedding policy

The limiter itself should be as simple and fast as possible. It sits in the request path, so every nanosecond counts. The core is an atomic counter that tracks the number of in-flight requests. On admission, if the counter is below the limit, increment and proceed. If not, reject immediately. On completion, decrement.

The limit is stored in an atomic variable that is updated by a background controller thread. The controller samples metrics (latency, throughput, error rate) every `T` milliseconds (e.g., 100ms) and computes a new limit. It then writes the new limit to the atomic variable. The request path only reads the limit, so there is no locking.

Rejection should be fast and cheap. Return a 503 Service Unavailable with a `Retry-After` header. Do not log at a high rate; use rate-limited logging or sample the rejections. The rejection should not allocate memory or perform I/O. If you are using a framework, use a middleware that can short-circuit the request before any business logic runs.

The shedding policy determines which requests to reject when the limit is reached. The simplest policy is first-come-first-served: if the limit is full, reject the new arrival. This is fair in the sense that it does not discriminate, but it can be suboptimal. If a high-priority request arrives while the limit is full of low-priority requests, it will be rejected. To handle this, you can implement priority-based shedding: assign each request a priority (e.g., based on the endpoint, the user tier, or the deadline). When the limit is reached, you can either reject the lowest-priority request in the queue (if you have a queue) or reject the incoming request if its priority is lower than the lowest-priority in-flight request. The latter requires tracking the priorities of in-flight requests, which adds overhead.

A more effective policy is deadline-based shedding. If a request's deadline is already impossible to meet given the current queueing delay, reject it immediately. This avoids wasting capacity on work that will be discarded. To implement this, you need to know the deadline of each request (e.g., from a header or a context) and the current queueing delay. If `deadline < now + queueing_delay + estimated_service_time`, reject. This is a form of admission control that is both fair and efficient.

In a distributed system, the limit should be global. If each instance has its own limit, a single slow instance can become a bottleneck while others are idle. A global limit can be implemented with a central coordinator that aggregates the in-flight counts from all instances and computes a global limit. The coordinator can be a simple service that receives periodic heartbeats from each instance. The heartbeats include the instance's current concurrency and latency. The coordinator then runs the control algorithm and broadcasts the new limit. The communication interval can be on the order of 100ms to 1s, depending on the required responsiveness.

Alternatively, you can use a token bucket in a shared store like Redis. Each instance acquires a token before admitting a request. The token bucket rate is adjusted by the controller. This is simpler but adds a network round-trip to the admission path, which may be unacceptable for low-latency services. A hybrid approach is to give each instance a local token bucket that is periodically refilled from a central bucket. This bounds the burstiness and reduces the coordination overhead.

Finally, the limiter must interact correctly with autoscaling. Autoscaling adds or removes instances based on load. If the limiter is per-instance, adding instances increases the total capacity, and the per-instance limit should be adjusted accordingly. If the limiter is global, the global limit should be increased when new instances are added. The controller should be aware of the number of instances and scale the limit proportionally. Otherwise, you can end up with a situation where the system has plenty of capacity but the limit is artificially low, or vice versa.

## Testing an adaptive limiter without lying to yourself

The hardest part of building an adaptive concurrency limiter is not the algorithm. It is constructing a test environment that exercises the same feedback loops the limiter will see in production. A unit test that feeds a fixed latency sequence into the controller proves that the controller is internally consistent. It does not prove that the limiter will help, because the limiter's behavior depends on the system's response to the limiter's own actions. This is a closed-loop control problem, and closed-loop systems cannot be validated with open-loop tests.

The first trap is using a load generator that does not model client behavior. A generator that sends a fixed number of requests per second and ignores timeouts will never produce a retry storm. It will happily keep sending at the same rate while the server collapses, and the limiter will look like it is working because the server's throughput stays roughly constant. To test the limiter, the generator must implement the same retry policy, deadlines, and concurrency limits as the real clients. If the real clients use a retry budget, the generator must use one too. If the real clients cancel requests on timeout, the generator must cancel them. Otherwise the test is measuring a different system.

The second trap is coordinated omission. If the load generator issues requests from a fixed set of threads and waits for each response before issuing the next, then when the server slows down, the generator slows down too. The latency it measures is not the latency a client would see, because the client would have kept sending requests at the same rate. The result is that the measured p99 is far lower than reality, and the limiter is tuned to a curve that does not exist. The fix is to use a generator that schedules requests according to a target arrival rate and measures the difference between the intended start time and the actual start time, adding that difference to the observed latency. This is sometimes called a constant-arrival-rate generator or a coordinated-omission-corrected generator.

The third trap is testing only the steady state. A limiter that is stable at a constant load may oscillate when the load changes. You need to test step changes, ramp changes, and spikes. A step change from 10% to 200% of capacity is a good test: the limiter should reduce the limit quickly, and it should recover when the load drops. A spike that lasts 100 ms is a different test: the limiter may not react at all, which is fine if the system can absorb the spike, but it must not be the cause of a collapse. You should also test the failure of the limiter itself: if the controller thread dies, the limit should remain at its last value, and the system should still shed load at that limit. A limiter that fails open is a limiter that will eventually fail.

Finally, test with the real dependency. A mock downstream that returns instantly will not reproduce the queueing behavior that the limiter is designed to manage. Use a test double that can simulate latency, errors, and capacity limits. Inject delays that follow a heavy-tailed distribution, not a constant. Inject failures that are correlated with load, because that is what overload looks like. The limiter should be able to hold the system at a stable operating point even when the dependency's service time triples.

## Observability for admission control

An adaptive limiter is a control system, and control systems need feedback. The feedback is the metrics you collect. Without them, the limiter is a black box that either works or does not, and you have no way to tell which.

The minimum set of metrics includes:

- **In-flight requests.** The current concurrency, sampled at the same boundary the limiter uses. If the limiter uses a different boundary than the metric, the two will disagree, and the disagreement will be largest under load.
- **Admission decisions.** The number of requests admitted, rejected, and dropped due to deadline. Rejections should be broken down by reason: limit exceeded, deadline exceeded, priority preemption, and so on.
- **Latency.** Not just the average. You need the distribution, and you need it at the same boundary as the limiter. A histogram with buckets that are fine-grained around the target latency is more useful than a histogram with a wide range.
- **Limit.** The current value of the limit, and the target latency or queueing delay ratio. Plot the limit over time against the offered load. If the limit is flat while the load is changing, the controller is not adapting.
- **Queueing delay.** The estimated queueing delay, which is the signal the controller uses. If you cannot measure it directly, plot the ratio of current latency to the minimum latency over a sliding window.
- **Errors.** The rate of 5xx responses, timeouts, and connection failures. These are the signals that should cause a multiplicative decrease. If they are not correlated with the limit, the controller is not reacting to the right thing.

The dashboards should show the limit and the load on the same axis. The most common failure mode is a limit that is too low: the system has capacity, but the limiter is rejecting work. This is easy to see if you plot the limit against the offered load and the utilization. If the limit is below the knee and the load is below the limit, the limiter is not the bottleneck. If the limit is at the knee and the load is above it, the limiter is doing its job. If the limit is below the knee and the load is above it, the limiter is too conservative.

Alerting should be based on the behavior of the system, not on the value of the limit. A limit of 10 is not alarming if the service only handles 10 concurrent requests. A limit of 1000 is not reassuring if the service is collapsing. Alert on the symptoms: latency above the target, error rate above the budget, and rejections above a threshold. Also alert on the limiter's own health: if the controller has not updated the limit in several intervals, or if the limit is pinned at the maximum or minimum, something is wrong.

Distributed tracing is invaluable. A trace that shows a request waiting in the admission queue, then being rejected, then being retried by the client, tells a story that no aggregate metric can. You should propagate the admission decision as a span attribute, so you can query for traces that were rejected and see what the client did next. If the client retried, the trace will show the retry, and you can measure the amplification factor.

## Rolling out and tuning

Never deploy an adaptive limiter in enforcement mode on the first day. Start in shadow mode: the limiter computes a limit and records what it would have done, but it does not reject any requests. Compare the computed limit to the actual concurrency. If the computed limit is consistently higher than the actual concurrency, the limiter is not needed. If it is consistently lower, the limiter would have rejected requests that the system was able to serve. Both are useful signals.

After shadow mode, move to a canary deployment: enforce the limit on a small fraction of traffic, for example 1% or one instance. Monitor the rejection rate, the latency, and the error rate. The canary should show a lower latency and a lower error rate than the control, because the limiter is protecting the system from overload. If the canary shows a higher error rate, the limiter is rejecting too much. If it shows no difference, the limiter is not binding, which may be fine if the system is not overloaded.

Tuning the limiter is an empirical exercise. The parameters that matter are the target latency or queueing delay ratio, the increase step, the decrease factor, and the measurement interval. A good starting point is to set the target queueing delay ratio to 0.5, the increase step to 1, and the decrease factor to 0.9. Then run a load test with a step increase and observe the limit's response. If the limit oscillates, reduce the increase step or increase the measurement interval. If the limit takes too long to recover, increase the decrease factor or reduce the measurement interval. If the limit collapses to a low value, you are applying the decrease too often; add a cooldown period.

The measurement interval should be long enough to collect a meaningful sample, but short enough to react to changes. A common choice is 100 ms to 1 s. If the service has a high request rate, 100 ms is plenty. If the service has a low request rate, you may need a longer interval or a request-count-based trigger. The controller should not update the limit more often than the measurement interval, because the samples will be correlated.

## Controller failure modes

The limiter itself can fail. The most common failure modes are oscillation, limit collapse, and stale baselines.

Oscillation happens when the controller overreacts to noise. The limit goes up, latency goes up, the limit goes down, latency goes down, and the cycle repeats. The amplitude of the oscillation can be large enough to cause periodic rejections even when the offered load is constant. The fix is to add damping: use a moving average of the signal, reduce the step size, or add a deadband. A deadband is a range of error where the controller does nothing. If the measured latency is within 10% of the target, do not change the limit. This prevents the controller from chasing noise.

Limit collapse happens when the controller decreases the limit too aggressively and then cannot recover. This can happen if the decrease is triggered by a transient error that is not caused by overload. For example, a single 5xx from a downstream dependency can cause a decrease, and if the downstream is still failing, the limit will keep decreasing until it reaches the minimum. The fix is to only decrease on sustained overload, not on a single error. Use a windowed error rate or a consecutive-failure count. Also, set a minimum limit that is high enough to allow the system to recover. A limit of 1 is almost never correct.

Stale baselines happen when the minimum RTT estimate is from a period of low load and no longer reflects the current service time. If the service time has increased, the controller will underestimate the queueing delay and set the limit too high. The fix is to decay the minimum RTT over time. For example, keep a histogram of latencies over a sliding window and use the 10th percentile. If the window is long enough, the baseline will adapt to gradual changes. For sudden changes, you can reset the baseline when the limit is at its minimum or when the error rate is high.

A fourth failure mode is coordinated omission in the controller itself. If the controller samples latency only from completed requests, it will miss the requests that are still in the queue. Under overload, the queue is full of slow requests that have not completed, so the completed requests are the fast ones. The controller sees a low latency and increases the limit, which makes the queue longer. The fix is to measure latency from the time the request is admitted, not from the time it is completed, and to include the queueing delay in the signal. If you cannot measure queueing delay, use the concurrency and throughput to derive it.

## Multi-tenant and fairness

In a multi-tenant system, a single concurrency limit for the whole service is not enough. A noisy tenant can consume the entire limit and starve the others. You need per-tenant limits, and you need a way to allocate the shared capacity fairly.

The simplest approach is a hierarchical limit. The total limit is divided among tenants according to a weight or a fair-share policy. Each tenant has its own limit, and the sum of the tenant limits is less than or equal to the total limit. When a tenant is idle, its unused capacity can be borrowed by other tenants, but the borrowing must be bounded to prevent a single tenant from monopolizing the service. This is similar to weighted fair queueing, but applied to concurrency rather than bandwidth.

A more dynamic approach is to use a separate adaptive limiter per tenant, with a shared controller that adjusts the total limit. The per-tenant limiters can be AIMD or gradient-based, and the shared controller can use a global signal to set the total. When a tenant exceeds its limit, it is rejected. When a tenant is below its limit, it can use the spare capacity. The shared controller must be careful not to let a single tenant's behavior drive the total limit down for everyone. One way to do this is to use a max-min fair allocation: the total limit is allocated such that no tenant can increase its share without decreasing the share of a tenant with a smaller allocation. This is the same principle used in TCP congestion control for fair bandwidth allocation.

The shedding policy also needs to be tenant-aware. If a tenant is over its limit, its requests should be rejected before other tenants' requests. If a tenant is under its limit, its requests should be admitted even if the total limit is reached, as long as the total limit is not exceeded. This requires a two-level admission check: first, check the tenant's limit; second, check the global limit. If the tenant is over its limit, reject immediately. If the global limit is reached, reject the request with the lowest priority, which may be a request from a tenant that is over its fair share.

Finally, consider the interaction with retries. A tenant that retries aggressively can amplify its load and consume more than its share. The retry budget should be enforced per tenant, not just per client. If a tenant exceeds its retry budget, its retries should be rejected at the edge, before they reach the service. This is a form of admission control at the tenant boundary.

## Deadlines are a control signal, not just a timeout value

A timeout configured as a client-side constant is a guess about how long a request should take. A deadline is a fact about when the answer stops being useful. The difference matters under overload because the server can use the deadline to decide whether admitting a request is worth the capacity it will consume. If a request has 30 ms of budget remaining and the current queueing delay is 200 ms, admitting it is not a judgment call. It is a guaranteed waste of a slot that could have served a request with a real chance of success.

Propagating deadlines requires an absolute timestamp, not a relative timeout. A relative timeout is meaningless once the request has crossed more than one hop, because each hop would have to subtract its own processing time and the arithmetic is error-prone. An absolute deadline, carried in a header or a request context, lets every hop compute the remaining budget independently. gRPC has this built into its deadline model. HTTP APIs can use a header such as `X-Request-Deadline` or a structured field. The ingress converts a relative timeout into an absolute deadline using a monotonic clock, and every downstream call receives the same absolute value.

Clock skew is a real problem for absolute deadlines. Two machines can disagree by milliseconds, and a deadline that is already in the past on one machine may appear valid on another. The practical fix is not to synchronize clocks perfectly, which is impossible, but to allow a small skew tolerance and to treat a deadline that is within the tolerance as expired. A more robust approach is to use a relative timeout for the first hop and to convert it to an absolute deadline only at the ingress, where the clock is trusted. Downstream hops then use the absolute deadline but subtract a safety margin that covers skew and network transit.

Cancellation is the other half of deadline management. When a caller disconnects or a deadline expires, the server should cancel the work it started on behalf of that caller. In Go, this is context cancellation. In Java, it is interruption or a cancellation token. In JavaScript, it is an `AbortSignal`. Cancellation is cooperative: a blocking call that does not check the cancellation signal will continue to run, and the server will continue to hold the concurrency slot. This is why every downstream call must have its own timeout that is shorter than the remaining budget. A request that has 100 ms of budget should not make a downstream call with a 5-second timeout. It should make the call with a timeout of 100 ms minus the estimated service time, and it should propagate cancellation if the caller goes away.

Orphaned work is the failure mode that cancellation is meant to prevent. If the client has timed out but the server keeps processing, the server is spending capacity on a response that no one will read. For idempotent reads, the fix is straightforward: cancel aggressively. For writes, cancellation is more delicate, because a partially applied write can leave inconsistent state. The design response is to make writes idempotent with an idempotency key and to use transactional boundaries that either commit or roll back. Then cancellation can be safe, because a retry with the same key will either complete the write or be recognized as a duplicate.

Deadline-aware admission control is a simple check: estimate the service time for the request, add the current queueing delay, and compare the sum to the remaining budget. If the sum exceeds the budget, reject immediately with a fast failure. The estimate does not need to be perfect. A recent p50 or p90 of successful requests for the same endpoint is enough. The important property is that the check happens before the request consumes a slot. A request that is admitted and then times out has consumed capacity twice: once while it was queued and once while it was being processed. A request that is rejected at admission consumes almost nothing.

## Queue discipline: sojourn time, not queue length

If the limiter has a queue behind it, the queue needs its own control policy. Queue length is a poor signal because service times vary. A queue of ten slow requests can be more congested than a queue of a hundred fast ones. The signal that matters is sojourn time: how long a request has been waiting since it was enqueued. Sojourn time is directly comparable to the request's deadline and directly convertible into a rejection decision.

The classic active queue management algorithm for this problem is CoDel. CoDel does not measure queue length. It measures the minimum sojourn time over a sliding interval. If the minimum sojourn time stays above a target for a full interval, the queue enters a dropping state and drops packets until the sojourn time falls below the target. The minimum is used instead of the average because it is robust to bursts: a short burst of fast requests should not trigger dropping, but a sustained increase in the fastest possible sojourn time indicates that the queue itself is the bottleneck.

The same idea applies to an application admission queue. Track the time each request spends waiting before it is dispatched. Over an interval, take the minimum sojourn time. If that minimum exceeds the target, start shedding. Drop from the head of the queue if the oldest requests are already past their deadlines. Drop from the tail if the queue is full and the newest request has no chance of completing in time. The choice depends on the workload. For deadline-driven work, dropping the oldest is usually correct, because the oldest requests have the least remaining budget. For work with no deadlines, dropping the newest is often better, because it preserves the progress of requests that have already waited.

A queue sorted by deadline, earliest deadline first, is optimal for meeting deadlines when all work is known in advance and preemption is free. In practice, preemption is not free, and EDF can starve long-running requests if short requests keep arriving. A hybrid policy works better: maintain a small number of priority classes, use EDF within each class, and age requests between classes so that a low-priority request eventually becomes high-priority. Aging prevents starvation without requiring a full EDF scheduler.

LIFO is a tempting policy under overload because the newest request has the most remaining deadline budget. If the queue is already full of requests that are likely to time out, serving the newest request first can increase the number of successful completions. The cost is starvation: older requests may never be served. LIFO is acceptable only when all requests have similar deadlines and the system is in a temporary overload that will clear quickly. It is not a general-purpose policy.

Every downstream dependency should have its own concurrency limit and its own queue. A single global limit allows one slow dependency to consume the entire capacity of the service. If the database is slow, requests that do not touch the database should not be blocked behind requests that do. The bulkhead pattern applies here: partition the concurrency budget by dependency, by endpoint, or by tenant, and enforce a separate limit for each partition. The sum of the partition limits can exceed the global limit, but the global limit still applies as a hard ceiling. This gives the controller two levers: it can reduce a single partition when one dependency degrades, and it can reduce the global limit when the whole service is saturated.

## Backpressure, shedding, and the limits of each

Backpressure and load shedding are often treated as synonyms. They are not. Backpressure is a signal to an upstream producer to reduce its rate. Load shedding is a decision to discard work. Backpressure works when the upstream can slow down and when the work has no hard deadline. Load shedding works when the upstream cannot or will not slow down, or when waiting would make the work worthless.

Transport-level backpressure is the most familiar form. TCP flow control uses a receive window to tell the sender to stop transmitting when the receiver's buffer is full. HTTP/2 and gRPC have flow control at the stream and connection level. Reactive streams have a pull-based protocol where the consumer requests a bounded number of items. These mechanisms are valuable, but they operate at the wrong granularity for application overload. They bound bytes or messages, not request concurrency. A slow consumer can apply backpressure to a fast producer, but if the producer is a client with a deadline, the client may time out and retry before the backpressure has any effect. The retry adds load, and the backpressure becomes part of the problem.

Application-level backpressure is more explicit. A service can return a `429 Too Many Requests` or a `503 Service Unavailable` with a `Retry-After` header. This tells the client to slow down. But it is still a rejection from the client's perspective. The difference is that the client is expected to honor the retry hint. If the client ignores it, the service must shed. In practice, a well-behaved client with a retry budget will reduce its rate when it sees a retry hint. A misbehaving client will not, and the service needs a hard limit to protect itself.

For streaming pipelines, backpressure is the natural mechanism. If a downstream stage is slow, the upstream stage should slow down. If the upstream cannot slow down, because it is reading from a sensor or a log, the system needs a durable buffer. A durable buffer moves the problem to disk. Disk has finite capacity, and when it fills, the system must shed. The choice between backpressure and shedding is therefore a function of the buffer's size and the consequences of dropping. If dropping is acceptable, shed early. If dropping is not acceptable, provision enough durable buffer to absorb the expected burst, and shed only when the buffer is full.

A useful hybrid is to apply backpressure until a bounded buffer is full, then shed. This is exactly what a bounded queue with a rejection policy does. The size of the buffer determines how long the system can absorb a burst. Little's Law gives the relationship: a buffer of size B and a service rate of μ has a maximum waiting time of B/μ. If that waiting time exceeds the deadline of the work, the buffer is too large. A large buffer does not improve resilience. It converts a fast failure into a slow failure, which is harder to diagnose and more likely to cause a retry storm.

## Coordinating limits across a fleet without a central bottleneck

A per-instance limiter is simple and fast, but it can be unfair. If the load balancer sends more traffic to one instance, that instance will hit its limit while others have spare capacity. A global limiter is accurate, but a central coordinator is a bottleneck and a single point of failure. The practical design is hierarchical: a local fast loop and a global slow loop.

Each instance runs its own limiter with a local limit. The local limiter reacts to local latency and local queueing delay on a short timescale, typically every 100 ms. A coordinator runs a global control loop on a slower timescale, typically every second. The coordinator collects aggregate metrics from all instances: total in-flight requests, total throughput, and a latency percentile. It computes a global limit and divides it among instances according to their share of traffic or their known capacity. Each instance receives a target limit and adjusts its local limit toward that target, but it can deviate within a bounded range to handle local bursts.

Leases are the mechanism that makes this safe. Instead of the coordinator pushing a limit to every instance, each instance requests a lease for a number of concurrency slots from a central token bucket. The lease is valid for a short period, such as five seconds. The instance can admit up to the leased number of requests without contacting the coordinator. When the lease expires, the instance must renew it. If the coordinator is unavailable, the instance can continue using its last lease until it expires, and then it must fall back to a conservative local limit. This bounds the total in-flight work across the fleet even if the coordinator fails.

The central token bucket rate is adjusted by the global controller. If the aggregate latency is above target, the controller reduces the bucket rate. If latency is below target and there is spare capacity, it increases the rate. The bucket rate is the global concurrency limit. The leases are the mechanism for distributing it. This is similar to distributed rate limiting, but the resource being limited is concurrency, not requests per second.

Safety requires that the global limit never exceeds the sum of the instance capacities. If the fleet autoscales, the coordinator must know the number of instances. A membership service or a simple registration protocol can provide this. When a new instance starts, it registers and receives a share. When an instance dies, its share is reclaimed after its lease expires. If the coordinator does not know about a new instance, that instance will use a local limit, and the global limit may be too low. The coordinator should therefore be conservative: it should assume that there may be unregistered instances and leave headroom in the global limit.

Tenant fairness adds another layer. A global limit for the whole service allows one tenant to consume all the capacity. A hierarchical tenant quota is better: the coordinator allocates a share of the global limit to each tenant, and each instance enforces a per-tenant limit locally. If a tenant is under its quota, it can borrow unused capacity from other tenants, but the borrowing is bounded by a lease. If a tenant exceeds its quota, its requests are rejected before they consume a global slot. This is max-min fair allocation applied to concurrency. It prevents a noisy tenant from causing a metastable failure for everyone else.

## Load shedding for background work and brownout

Background work is the silent cause of many overload incidents. Compaction, garbage collection, replication, cache warming, and batch jobs all compete with foreground traffic for the same CPU, memory, disk, and network. They are often scheduled without any awareness of foreground health. When the foreground is already saturated, background work makes the queueing delay worse, which increases the foreground concurrency, which increases the pressure on the shared resources. The loop is the same metastable failure pattern, but the trigger is internal.

The fix is to give background work its own concurrency limit and to make that limit a function of foreground health. When foreground queueing delay is below target, the background limit can be high. When foreground queueing delay rises above target, the background limit should be reduced, possibly to zero. This is a priority-based shedding policy: foreground work is admitted first, and background work is admitted only with the capacity that is left over. The controller for the background limit can be a simple AIMD loop that uses foreground latency as its signal. If foreground latency is high, decrease the background limit multiplicatively. If foreground latency is low, increase it additively. The background limit should never be allowed to starve foreground work, so it must be capped at a fraction of the total concurrency.

Brownout is a related technique that sheds work at the feature level rather than the request level. Instead of rejecting a request, the service degrades the response: it returns a cached value, skips a recommendation, reduces image resolution, omits a non-essential field, or uses an approximate algorithm. Brownout reduces the service time of each request, which reduces the concurrency required to sustain a given throughput. It is a form of load shedding that preserves the user's core interaction while dropping optional work.

A brownout controller monitors latency and error rate. When latency exceeds a target, it enters brownout level one, which disables the least important feature. If latency is still high after a cooldown, it enters level two, which disables the next feature. When latency falls below the target for a sustained period, it exits brownout levels in reverse order. Hysteresis is essential: without a deadband and a cooldown, the controller will flap between levels, which is worse than staying in a single degraded state. The features that are disabled must be chosen carefully. They should be non-essential for correctness, they should not be required for the user's primary task, and they should be cheap to disable at runtime.

Brownout depends on feature flags that can be toggled without a deployment. The flags must be propagated to all instances quickly, and the controller must be independent of the flag system. If the flag system itself depends on the overloaded service, the controller may not be able to disable features when it needs to. A separate control plane, or a local cache of the flags, avoids this circular dependency. The brownout paths must be tested regularly. A brownout feature that has not been exercised in months will not work when it is finally needed.

## The cost of rejection and the edge

Rejection is not free. If the rejection path performs TLS termination, authentication, request parsing, logging, and metrics, it can consume nearly as much CPU as the work it is rejecting. Under overload, the rejection path becomes part of the bottleneck. The limiter should be placed as early as possible in the request pipeline, before any expensive work. In a typical service, that means a middleware at the very front of the stack, or a filter at the load balancer. The rejection should not allocate memory, should not perform I/O, and should not log at a high rate. A static response body and a counter are enough. If the framework requires a dynamic response, generate it once and reuse it.

Edge shedding is the next step. A CDN or edge proxy can reject requests before they reach the origin. The edge needs a signal from the origin: the current limit, the current load, or a simple health score. The edge can maintain a local limit that is a fraction of the origin's limit, which absorbs bursts and reduces the load on the origin's network and CPU. Edge shedding is coarse because the edge does not know the deadline or the priority of each request. It should be used as a first line of defense, with the origin's limiter providing fine-grained control. If the edge rejects a request that the origin could have served, the user sees a failure that was avoidable. The edge limit should therefore be conservative and should be raised only when the origin reports spare capacity.

Rejection must be observable. Count rejections by reason: limit exceeded, deadline exceeded, priority preemption, and tenant quota exceeded. A high rejection rate is not necessarily bad if the system is protecting itself from a load spike. A rejection rate of zero while latency is high is a sign that the limiter is not binding, which means the system is absorbing work that it cannot complete. A high rejection rate while latency is low is a sign that the limit is too conservative. The dashboard should show the limit, the offered load, the admitted load, and the rejected load on the same axis. The story is in the gaps between those lines.
