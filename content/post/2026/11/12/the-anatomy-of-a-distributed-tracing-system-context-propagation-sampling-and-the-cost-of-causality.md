---
title: "The Anatomy of a Distributed Tracing System: Context Propagation, Sampling, and the Cost of Causality"
description: "A deep dive into how distributed tracing actually works: the span DAG model, W3C Trace Context and B3 propagation, baggage, clock skew and the limits of timestamps, consistent sampling, collector pipelines, and the engineering trade-offs behind observability at scale."
date: "2026-11-12"
author: "Leonardo Benicio"
tags: ["distributed-systems","observability","distributed-tracing","opentelemetry","context-propagation","sampling","systems-design"]
categories: ["Distributed Systems","Observability"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/the-anatomy-of-a-distributed-tracing-system-context-propagation-sampling-and-the-cost-of-causality-2026-11-12.jpg"
coverAlt: "A dark technical illustration showing a glowing directed acyclic graph of connected nodes hovering above server racks, with branching and converging light filaments and faint vertical time grid lines behind it, suggesting a distributed trace with slight timing misalignment."
---

# The Anatomy of a Distributed Tracing System: Context Propagation, Sampling, and the Cost of Causality

A single user request in a modern backend can touch a load balancer, an API gateway, a dozen services, three caches, two message brokers, and a database. When that request is slow, the logs from each of those components are individually correct and collectively useless: they share no identifier, no ordering, and no notion of who called whom. Distributed tracing exists to reconstruct that causal graph.

It is tempting to think of tracing as "logging with a request ID". That framing hides almost all of the engineering. A tracing system is a distributed system in its own right, with its own consistency problems (causal ordering across machines with unsynchronized clocks), its own data-plane concerns (high-cardinality, high-volume, write-heavy telemetry), and its own coordination problems (who decides what to sample, and how do you make that decision consistently across processes that never talk to each other?).

This article walks through the anatomy of such a system: the data model, the propagation contract that stitches spans together across process boundaries, the clock-skew problem that makes timestamps unreliable, the sampling machinery that keeps the whole thing affordable, the collector pipeline that moves data from applications to storage, and the query and retention layer at the end. Along the way we will look at the specific standards — W3C Trace Context, W3C Baggage, the OpenTelemetry span model — that have converged over the last several years, and at the trade-offs that remain genuinely unsettled.

## The span model

The atomic unit of a trace is a **span**: a named, timed operation with a start and an end. Everything else in the system is either metadata attached to spans or machinery for moving them around.

A span carries:

- **Identity.** A `trace_id` shared by every span in the same trace, and a `span_id` unique within that trace. The OpenTelemetry and W3C conventions are 16 bytes (128 bits) and 8 bytes (64 bits) respectively, hex-encoded in headers. The widths are not arbitrary: a 128-bit trace ID is wide enough that random generation is safe at very high rates, and 64 bits is wide enough for span IDs within a single trace while staying compact in headers and storage keys.
- **Causality.** A `parent_span_id` (absent for the root) that places the span in the trace's graph.
- **Timing.** Start and end timestamps, conventionally wall-clock nanoseconds since the Unix epoch.
- **Kind.** OpenTelemetry defines `INTERNAL`, `SERVER`, `CLIENT`, `PRODUCER`, and `CONSUMER`. The kind is what lets a backend pair a client span in service A with the server span in service B, and what lets a UI distinguish "time spent waiting on the network" from "time spent inside the callee".
- **Attributes.** Arbitrary key-value pairs: HTTP method, status code, database statement, peer address, and so on.
- **Events.** Timestamped annotations within the span's lifetime, with their own attributes. An event is a point in time; a span is an interval.
- **Links.** References to other spans that are causally related but not parent-child.
- **Status.** Whether the operation succeeded, failed, or is unset.

The word "tree" is used loosely; the correct structure is a **directed acyclic graph**. Three common cases break the tree assumption:

1. **Batch consumers.** One Kafka consumer processes a batch of messages produced by many independent producers. A single server span has many parents. This is what links are for: the consumer span carries one link per producer span, and the trace becomes a DAG with a fan-in node.
2. **Fan-out with joins.** A service issues N parallel RPCs and waits for all of them. The children are siblings, which is still a tree, but the "critical path" is not the sum of the children's durations, and naive waterfall rendering misleads.
3. **Retries and re-drives.** A retried request may reuse the trace ID but create a new span tree, or may be linked to the original attempt.

The practical consequence is that a trace backend must store and query a DAG, not a tree, and that "duration of the trace" is a derived quantity (the length of the critical path, or simply `max(end) - min(start)`), not a stored field.

### Events versus child spans

A frequent design question is whether a sub-operation deserves a child span or an event on the parent. Child spans give you independent timing, independent attributes, and the ability to be sampled or filtered separately; they also cost an allocation, a context switch, and — if they cross a process boundary — header bytes on the wire. Events are cheap and stay within the parent's lifetime, but they cannot express duration.

A useful rule: if the operation has a meaningful duration and could fail independently, make it a span. If it is a point-in-time annotation ("cache miss", "retry scheduled", "exception thrown"), make it an event. The cost difference is not small; in hot loops, span creation dominates the tracing overhead.

### The cardinality trap

Attributes are where tracing systems get expensive. A span with `http.route=/users/{id}` is low cardinality and cheap to index. A span with `http.url=/users/12345?session=abc` is high cardinality: every span is unique, indexes blow up, and any aggregation over that attribute degenerates into a scan. This is the same problem that makes metrics with unbounded label sets dangerous, and the mitigation is the same: define a small set of well-known attributes, treat the rest as payload rather than index keys, and enforce limits at the SDK (attribute count, value length, total span size) rather than at the collector, where the cost has already been paid on the network.

## Context propagation

A span is only useful if the process that creates it knows which trace it belongs to. That knowledge is called the **span context**, and moving it across process and thread boundaries is **propagation**. Propagation is where most tracing bugs live.

### In-process propagation

Inside a single process, the context must travel from the code that receives a request to every function that wants to create a span. Two strategies exist:

- **Explicit passing.** Every function that might create a span takes a context parameter. This is what Go's `context.Context` and Rust's tracing span guards do. It is verbose but unambiguous, testable, and friendly to static analysis.
- **Implicit/ambient passing.** A thread-local or async-local variable holds the current context. This is what Java's `ThreadLocal`, Python's `contextvars`, and .NET's `AsyncLocal` provide. It is ergonomic but fragile: the context is invisible in signatures, and it silently does the wrong thing at every concurrency boundary.

The failure modes of ambient context are worth naming, because they are the source of the classic "my traces are crossed" bug reports:

- **Thread pools.** A worker thread picks up a task and inherits whatever context was left in its thread-local by the previous task. The fix is to capture the context at submission time and install it at execution time, and to clear it on completion — in a `finally` block, not on the happy path.
- **Async runtimes.** In a runtime with work-stealing schedulers, a logical task can resume on a different OS thread than it started on. Thread-locals are the wrong storage; you need storage attached to the task (futures, coroutines, `contextvars`).
- **Callbacks and event loops.** A timer callback registered inside request A may fire while request B is executing. If the callback creates spans, it must restore the context captured at registration.
- **Lazy initialization.** A span created eagerly at the top of a function but ended after an `await` may have its parent changed by an unrelated operation in between if the context is ambient and mutable.

The general principle: **capture context at the boundary where you know the causal relationship, and restore it explicitly where you resume.** Anything else is a heuristic.

### Cross-process propagation

Across a network hop, the context must be serialized into whatever metadata the transport supports: HTTP headers, gRPC metadata, Kafka record headers, AMQP properties, or a custom envelope. Two formats dominate.

**W3C Trace Context** defines two headers:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
tracestate:  rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

`traceparent` is a fixed-shape field: a 2-hex-digit version, a 32-hex-digit trace ID, a 16-hex-digit parent span ID, and 2 hex digits of flags. Bit 0 of the flags is the sampled bit. The fixed shape matters: it makes the header cheap to parse, cheap to validate, and impossible to confuse with a vendor-specific extension.

`tracestate` is the extension mechanism: an ordered list of `key=value` pairs, where each vendor owns its own key and may only modify its own entry. The ordering is meaningful — the most recently updated entry goes first — and the list is bounded (at most 32 members), which prevents a long chain of services from growing headers without limit. A vendor that receives a `tracestate` it does not understand must pass it through unchanged.

**B3** (from Zipkin) predates the W3C work and remains widely deployed. It comes in two shapes: a multi-header form (`X-B3-TraceId`, `X-B3-SpanId`, `X-B3-ParentSpanId`, `X-B3-Sampled`, `X-B3-Flags`) and a single-header form (`b3: traceid-spanid-samplingstate-parentspanid`). The single-header form exists because some proxies and message systems impose header count limits, and because fewer headers means fewer round trips through header-parsing code.

The practical reality is that a large system speaks both, plus whatever legacy format a decade-old service uses. Propagation therefore requires **translators** at the edges: a component that reads any supported format, normalizes to an internal representation, and writes the formats its peers expect. Getting this wrong produces the most common symptom in tracing: **broken traces**, where a trace appears to terminate at a service that actually called three more.

### Baggage

Baggage is the mechanism for propagating arbitrary application key-value pairs alongside the trace context. It is useful for things like tenant ID, feature flag cohort, or a canary marker — data that many downstream services want but that no single service owns.

Baggage is also a footgun. It is untyped, it is visible to every service in the path (including third parties), and it is transmitted on every hop. The W3C Baggage specification bounds it (limits on entry count and total size) precisely because an unbounded baggage header is a denial-of-service vector and a data-leak vector. The rule of thumb: baggage should carry identifiers, not payloads, and never credentials or personal data.

### The propagation contract

Propagation is a contract between two parties that may never have been tested together. The contract has four obligations:

1. **Extract** the incoming context, tolerating absent, malformed, and unknown-version headers.
2. **Validate** it — a trace ID of all zeros is invalid per the W3C spec, and a malformed header must be ignored rather than rejected.
3. **Create** a new span whose parent is the extracted span ID.
4. **Inject** the new context into every outgoing call.

Obligation 4 is the one that fails silently. A service that extracts correctly but forgets to inject on one code path produces traces that are correct everywhere except after that call, and the failure looks like missing instrumentation rather than a propagation bug. This is why mature tracing SDKs make injection the default behavior of the HTTP client and message producer, rather than something the application author must remember.

## Clock skew and the cost of causality

Here is the uncomfortable truth at the center of distributed tracing: **the timestamps in your spans come from different clocks, and those clocks disagree.**

Every span's start and end times are wall-clock readings taken on the machine that produced the span. Those machines synchronize via NTP (typically within a few milliseconds on a well-run network) or PTP with hardware timestamping (sub-microsecond on a LAN, but requiring infrastructure most organizations do not have). Neither gives you a global order.

The consequences are visible in any large trace:

- A child span whose start time precedes its parent's start time.
- A span with a negative duration, if the clock stepped backwards between start and end (a leap-second smear, an NTP correction, a VM migration).
- A waterfall that shows a service "waiting" for 40 ms on a call that the callee reports took 5 ms, because the two clocks are 35 ms apart.
- A critical-path computation that is simply wrong, because it compares incomparable numbers.

There are three defensible responses, and most systems use all three:

1. **Trust structure over timestamps.** The parent-child relationship is ground truth: if span B is a child of span A, then B happened during A, regardless of what the timestamps say. A correct trace viewer clamps child intervals to the parent's interval and renders the hierarchy, not a raw time axis.
2. **Measure and expose skew.** The difference between a client span's duration and the corresponding server span's duration is an estimate of the round-trip time plus skew. Tracking that difference per host pair turns an invisible problem into an observable one.
3. **Use monotonic clocks for durations.** Within a process, `CLOCK_MONOTONIC` never steps backwards, so a duration measured with it is trustworthy. The catch is that monotonic clocks have arbitrary epochs and are not comparable across hosts, so you still need wall-clock timestamps for cross-host correlation. The pragmatic design is to record both: a monotonic-derived duration for accuracy, and wall-clock start/end for placement.

The deeper point is that **causality in a trace is established by propagation, not by time.** The timestamps are annotations that make the DAG renderable. A system that treats them as a total order will produce analyses that are subtly, systematically wrong — and wrong in a way that is hard to notice, because the errors are small and the charts look plausible.

With the data model and the propagation contract in place, the next question is the one that determines whether any of this is affordable: which traces do you keep? That is the sampling problem, and it is where the most interesting engineering trade-offs in tracing live.

## Sampling: the decision that makes tracing affordable

A trace of a single request can contain hundreds or thousands of spans. At ten thousand requests per second, with twenty spans per request, a system produces two hundred thousand spans per second. At roughly a kilobyte per span after encoding, that is two hundred megabytes per second, or more than seventeen terabytes per day. No organization stores all of it. Sampling is the mechanism that reduces this volume while preserving the traces that matter.

The tension is fundamental: a complete trace is the most useful artifact for debugging, but completeness is exactly what makes it expensive. Every sampling strategy is a bet about which incompleteness you can tolerate.

### Head-based sampling

Head-based sampling makes the decision at the root of the trace, before any spans are created. The root service generates a trace ID, applies a sampler, and sets the sampled flag in the outgoing context. Every downstream service reads that flag and either records spans or does not. The advantage is that the decision is made once, propagated cheaply, and requires no coordination between services.

The simplest head sampler is probabilistic: sample if a hash of the trace ID falls below a threshold. Because the trace ID is already random, hashing it gives a uniform distribution, and every service that sees the same trace ID can compute the same decision without talking to anyone. This is **consistent sampling**. If all services use the same threshold, they agree perfectly. If they use different thresholds, they can still agree if the decision is expressed as a probability in the context, but the W3C sampled flag is only one bit. It says whether the trace is sampled, not at what rate. That is why consistent probability sampling often carries an additional threshold in `tracestate`, so downstream services can adjust their own behavior without contradicting the upstream decision.

A second head strategy is **parent-based sampling**. The sampler checks whether the incoming context already contains a sampling decision. If it does, the child inherits it. If it does not, the service is the root and applies its own rule. This is the default in most SDKs because it guarantees that a trace is either fully kept or fully dropped. Without parent-based behavior, a service could decide to sample a child of a dropped parent, producing an orphaned fragment that is useless for causal analysis.

Head sampling is cheap. The decision happens in the SDK, so unsampled spans never leave the process. There is no collector state, no buffering, and no extra network traffic. The cost is that the decision is made before the outcome is known. A request that fails with a rare error, or that takes ten times the normal latency, is dropped with the same probability as a boring successful request. If you sample at one percent, you keep one percent of your incidents. For high-volume services, that may still be enough. For low-volume services, it may mean you have no traces of the failure you are trying to debug.

### Tail-based sampling

Tail-based sampling moves the decision to the collector, after the trace is complete. The collector receives all spans, groups them by trace ID, waits for a trace timeout, evaluates a set of policies, and then decides whether to keep or drop the entire trace. Policies are typically expressed as rules: keep all traces with an error, keep all traces slower than a latency threshold, keep all traces for a specific tenant, and probabilistically sample the rest.

The appeal is obvious. You keep the traces you care about, regardless of how rare they are. The cost is equally obvious: to decide after the fact, you must first receive everything. Tail sampling does not reduce network traffic from applications to collectors; it reduces storage and indexing costs. It also introduces state. The collector must hold spans in memory for the duration of the trace timeout, which means memory usage scales with traffic and timeout. A long timeout catches late spans but increases memory; a short timeout drops them and produces partial traces.

Tail sampling also requires that all spans of a trace arrive at the same collector. If spans are load-balanced across a fleet of collectors by round-robin, no single collector sees the whole trace, and the decision is made on a fragment. The standard solution is to route by trace ID: a consistent hash of the trace ID determines the collector. This keeps all spans of a trace together, but it creates hot spots if the hash is uneven or if one tenant dominates traffic. It also complicates scaling, because adding a collector reshuffles ownership and can cause in-flight traces to be split across old and new owners.

A common compromise is **two-tier sampling**: a head sampler in the SDK drops most traffic, and a tail sampler in the collector applies fine-grained policies to what remains. This reduces the volume reaching the collector while still allowing error-based retention. The trade-off is that the head sampler cannot know which traces will error, so it may drop the very traces the tail sampler would have kept. To avoid that, some systems use a high head rate for services where errors are rare and important, and a low head rate for high-volume, low-signal services.

### Adaptive sampling

Adaptive sampling adjusts the sampling rate in response to traffic. A service might target a fixed number of spans per second, or a fixed fraction of total traffic, and increase or decrease the rate as load changes. This is useful for keeping observability costs predictable. It is also a control loop, and control loops oscillate. If every service independently adjusts its rate based on its own throughput, the aggregate behavior can be unstable. The safer design is to set rates centrally, or to use a feedback signal that is smoothed over a long window.

### Sampling and metrics

Sampling has a subtle effect on any metric derived from spans. If you compute a p99 latency from sampled traces, you are computing it from a biased sample unless you weight each span by the inverse of its sampling probability. Consistent sampling makes this possible: if a span represents one in a hundred requests, it carries a weight of one hundred. But many systems do not propagate the weight, and the resulting span-derived metrics are quietly wrong. The robust approach is to keep metrics and traces separate: use metrics for aggregate latency and error rates, and use traces for individual requests. Span metrics connectors can generate metrics from spans, but they should be treated as a convenience, not a replacement for properly instrumented metrics.

## Collector pipelines: from SDK to storage

Once a span is created and sampled, it must travel from the application to a backend that can store and query it. That path is the collector pipeline, and it is where the theoretical model meets operational reality.

### The pipeline abstraction

Most modern tracing systems use a pipeline abstraction with three stages: receivers, processors, and exporters. A receiver accepts data in a specific protocol. A processor transforms, filters, batches, or enriches data. An exporter sends data to a destination. Pipelines are composed of these stages, and a single collector can run multiple pipelines for different data types or tenants.

The OpenTelemetry Collector is the canonical example. Its receivers speak OTLP over gRPC or HTTP, and often also Jaeger, Zipkin, and other legacy protocols. Its processors include batch, memory limiter, attributes, resource detection, and tail sampling. Its exporters write to OTLP endpoints, Jaeger, Kafka, or object storage. The design is intentionally pluggable, because no single backend is right for every organization.

The pipeline is also where backpressure is handled. Applications should never block on telemetry. The SDK batches spans and exports them asynchronously. If the collector is slow or unavailable, the SDK queue fills and then drops data. Dropping is usually the correct behavior: tracing is diagnostic, and losing traces is preferable to slowing down the request path. The collector applies the same logic with its own queues and memory limiter. When memory pressure is high, it refuses new data rather than crashing.

### Stateful processing and routing

Most processors are stateless: they transform each span independently. Tail sampling is the exception. It requires state keyed by trace ID, and that state must be visible to every span of the trace. This is why routing by trace ID is a first-class concern in any collector fleet that does tail sampling. The load-balancing exporter uses a consistent hash ring over trace IDs, so all spans of a trace go to the same collector. The ring must be shared across the fleet, and membership changes must be handled carefully to avoid splitting traces.

Even with perfect routing, tail sampling has edge cases. A trace may never complete because a service crashed, a message was lost, or a timeout expired. The collector must eventually evict incomplete traces, and the eviction policy determines whether late spans are appended to a kept trace or create a new partial trace. Links from batch consumers complicate this further: a consumer span may be linked to producers that are sampled independently, so the trace graph can have multiple roots and no single completion point.

### Enrichment and redaction

Collectors are a convenient place to enrich spans with metadata that the application does not know. A Kubernetes attributes processor can add pod name, namespace, node, and deployment to every span. A resource detection processor can add cloud region and instance type. This enrichment is valuable because it is consistent and does not require application changes.

Collectors are also a convenient place to redact sensitive data. A database statement may contain a credit card number; an HTTP header may contain an authorization token. Redaction at the collector is a safety net, but it is not a substitute for not recording sensitive data in the first place. The collector sees data after it has left the application, so any leak has already traversed the network. The correct posture is to redact at the SDK, and to use the collector as a second line of defense.

### Storage and query

The final stage is storage. Tracing backends are write-heavy, append-only systems optimized for two access patterns: point lookup by trace ID, and search by attributes over a time range. Point lookup is easy to shard: hash the trace ID and route to a shard. Attribute search is harder, because it requires an index. The index is where cost accumulates. Indexing every attribute is prohibitively expensive, so most systems index a small set of well-known attributes and store the rest as payload. Queries over unindexed attributes degenerate into scans, which is why high-cardinality attributes are dangerous.

Retention is another cost lever. Hot storage keeps recent traces in a fast, indexed store for hours or days. Cold storage keeps older traces in object storage, often in a columnar format, where they can be queried with higher latency. The boundary between hot and cold is a policy decision: how far back do you need to debug? Most incidents are investigated within hours, but some compliance requirements demand months. The cost difference between the two tiers is large enough that most organizations sample aggressively at the hot tier and store a smaller, aggregated summary in the cold tier.

The collector pipeline is therefore not just plumbing. It is the place where sampling policies are enforced, where metadata is attached, where sensitive data is scrubbed, and where the cost of causality is finally paid. Every stage adds latency, memory, and failure modes. A well-designed pipeline makes those trade-offs explicit, and a poorly designed one hides them until the first traffic spike.

## The query and analysis layer

Storing spans is necessary but not sufficient. The value of tracing is realized in the queries and analyses that run over the stored data. A tracing backend must support two fundamentally different access patterns: **retrieval by trace ID** and **search by attributes**. Retrieval by trace ID is a point lookup: given a trace ID, return all spans in that trace, ordered by causality. Search by attributes is a range query: find traces where `service.name = checkout` and `http.status_code = 500` and `duration > 2s`, within a time window. These two patterns have opposite performance characteristics and often require different storage engines.

Trace ID lookup is easy to scale. The trace ID is a high-entropy key, so a hash-based shard distributes load evenly. The backend can store spans in a wide-column store keyed by `(trace_id, span_id)`, and a single partition scan returns the entire trace. This is the design of Jaeger's Cassandra schema, Tempo's block storage, and many proprietary backends. The query is fast, predictable, and cheap.

Attribute search is where cost explodes. To find traces by service name, status code, or duration, the backend needs an index. Indexing every attribute is impossible: the cardinality is unbounded, and the write amplification would dwarf the cost of storing the spans themselves. The standard compromise is to index a small, fixed set of "well-known" attributes — service name, operation name, status, duration, and a few resource attributes — and to store everything else as opaque payload. Queries over unindexed attributes either fail, or fall back to a scan, which is slow and expensive.

This is the **cardinality trap** again, now at the query layer. A team that adds a `user.id` attribute to every span and then tries to filter by it will either get no results or a query that scans terabytes. The mitigation is to treat high-cardinality attributes as payload for trace retrieval, not as index keys for search. If you need to search by user ID, the right tool is usually a log or a metric with a bounded label set, not a trace attribute.

Duration search deserves special mention because it is the most common query in incident response. "Show me all traces slower than 5 seconds in the last hour" is the first thing an on-call engineer asks. Duration is a derived field — it is `max(end) - min(start)` over the trace's spans — so it cannot be indexed at write time unless the backend computes it during ingestion. Some backends do exactly that: they maintain a "trace summary" record with the root span's duration, error status, and service count, and index that summary. The summary is small and cheap to index, and it answers the majority of search queries without touching the span data. The full span tree is only fetched when the engineer clicks into a specific trace.

### Critical path analysis

Once a trace is retrieved, the most valuable analysis is the **critical path**: the sequence of spans that determines the trace's total duration. In a simple tree, the critical path is the longest path from root to leaf, where the weight of each edge is the child's duration. In a DAG with fan-in and fan-out, the computation is more subtle: parallel siblings contribute their maximum, not their sum, and a join node's duration is determined by the slowest incoming path.

Computing the critical path correctly requires respecting the parent-child structure and ignoring wall-clock timestamps where they conflict with causality. A span that appears to start before its parent is clamped to the parent's interval; a span with a negative duration is treated as a data error and excluded from the analysis. The output is a list of spans with their contribution to the total latency, which lets an engineer see, for example, that 80% of a 10-second request was spent in a single database call, and that the call was retried three times.

Critical path analysis also exposes the difference between **self time** and **total time**. A span's total time is its duration; its self time is its duration minus the durations of its children (clamped to zero). A service that takes 500 ms but spends 490 ms waiting on a downstream call has a self time of 10 ms; the bottleneck is downstream. Aggregating self time across many traces produces a service-level latency attribution that is far more actionable than raw span durations.

### Service maps and dependency graphs

Traces are a natural source of service dependency data. Every parent-child edge across a process boundary is a call from one service to another. Aggregating these edges over a time window produces a **service map**: a graph of services and their call relationships, annotated with request rates, error rates, and latency percentiles. Service maps are valuable for capacity planning, for understanding blast radius during an incident, and for detecting architectural drift — a new dependency that appears in the map but not in the design document.

The challenge is that service maps are derived from sampled data, so the request rates are estimates, not counts. If sampling is inconsistent across services, the map can show phantom edges or miss real ones. The robust approach is to generate service maps from metrics (which are complete) and use traces to enrich them with example traces and detailed latency breakdowns. This is another instance of the general principle: use traces for depth, metrics for breadth.

## The economics of tracing

Tracing is not free, and the costs are not only storage. A complete cost model includes:

- **Instrumentation cost.** Developer time to add spans, maintain propagation, and fix broken traces. This is usually the largest cost in the first year.
- **Runtime cost.** CPU and memory overhead in the application: span allocation, context propagation, serialization, and background export. A well-tuned SDK adds single-digit microseconds per span, but a hot loop with thousands of spans per request can add milliseconds.
- **Network cost.** Sending spans from applications to collectors. At high volume, this can saturate links or incur egress charges in cloud environments.
- **Collector cost.** Running a fleet of collectors with enough CPU, memory, and network bandwidth to receive, process, and forward spans. Tail sampling increases memory requirements significantly.
- **Storage cost.** The dominant long-term cost. Hot storage (indexed, fast) is expensive; cold storage (object storage, columnar) is cheaper but slower. Retention policies determine the bill.
- **Query cost.** Running searches over large datasets consumes CPU and I/O. Unindexed queries can be surprisingly expensive.

The levers for controlling cost are sampling rate, retention period, indexed attribute count, and span size. Each lever trades fidelity for money. A 1% sampling rate reduces storage by 100x but may miss rare errors. A 7-day retention reduces storage by 4x compared to 30 days but limits historical analysis. Indexing 10 attributes instead of 100 reduces index size by an order of magnitude but makes some queries impossible.

The most important economic insight is that **sampling is not a binary choice**. A tiered strategy — head sampling at 10%, tail sampling to keep all errors and slow traces, and a 1% random sample for baseline — can retain the traces that matter at a fraction of the cost of keeping everything. The key is to make the sampling policy explicit, measurable, and adjustable. A sampling policy that is not instrumented is a cost center that nobody understands.

## Integration with logs and metrics

Traces do not exist in isolation. The three pillars of observability — metrics, logs, and traces — are complementary, and the value of each increases when they are correlated.

**Exemplars** are the bridge from metrics to traces. An exemplar is a sample data point attached to a metric histogram bucket, carrying a trace ID. When a latency histogram shows a spike in the 99th percentile, the exemplar lets you jump directly to a trace that contributed to that bucket. This turns a metric alert into an investigation path without manual correlation.

**Log correlation** is the bridge from traces to logs. If every log line includes the current `trace_id` and `span_id`, then a trace viewer can show the logs emitted during a specific span, and a log search can link back to the trace. The implementation requires that the logging library reads the active span context, which is straightforward if the tracing SDK and logging library share the same context mechanism. The harder part is ensuring that logs are emitted with the correct context in asynchronous code, where the active span may change between log calls.

**Span metrics** are the bridge from traces to metrics. A span metrics processor in the collector aggregates spans by service, operation, and status, producing request rate, error rate, and latency histograms. This is useful for services that are instrumented with tracing but not with metrics, and it provides a consistent view of latency across all services. The caveat is sampling bias: span metrics are derived from sampled traces, so they are only accurate if the sampling is consistent and the weights are applied. For critical SLOs, dedicated metrics are still the safer choice.

The unified observability model — where a single SDK produces all three signals and a single backend stores and correlates them — is the direction most vendors are moving. OpenTelemetry is the standardization force behind this, defining a common data model and a common context for all signals. The practical benefit is a single agent, a single configuration, and a single correlation ID across logs, metrics, and traces. The risk is vendor lock-in at the SDK level, but the open standard mitigates that.

## Multi-tenancy and security

A tracing backend often serves many teams, and sometimes many external customers. Multi-tenancy introduces requirements that a single-tenant system can ignore:

- **Isolation.** One tenant's traffic must not affect another's. This applies to ingestion (rate limits per tenant), storage (separate indexes or partitions), and query (resource quotas).
- **Access control.** Traces contain sensitive data: URLs, database statements, user IDs, and sometimes payloads. Access must be scoped so that a developer can see traces for their own service but not for a service they do not own. This is often implemented as attribute-based access control, where a tenant can only query spans with a matching `tenant.id` attribute.
- **Data residency.** Some regulations require that data stays within a geographic region. A multi-region tracing deployment must route spans to the correct region and ensure that queries do not cross regional boundaries.
- **PII redaction.** Even with access control, traces may contain personal data. Redaction at the SDK is the first line of defense; collector-side redaction is a safety net. The challenge is that redaction rules are application-specific and change over time, so the system must support dynamic rule updates without restarting collectors.

Security also applies to the tracing infrastructure itself. The collector is a network service that accepts data from many applications. It must authenticate clients, validate input, and resist denial-of-service attacks. A malformed span should not crash the collector; a flood of spans should be rate-limited. The OpenTelemetry Collector provides some of this, but operators must configure TLS, authentication, and resource limits explicitly.

## Open problems and future directions

Distributed tracing has matured rapidly, but several problems remain unsolved or only partially solved.

**Sampling consistency across vendors.** W3C Trace Context defines a sampled bit, but not a sampling rate. Consistent probability sampling requires propagating a threshold, which is being addressed in the W3C Trace Context Level 2 specification, but adoption is uneven. Until it is universal, cross-vendor sampling will remain approximate.

**Clock skew.** There is no widely deployed solution for accurate cross-host timestamps without expensive infrastructure. The structural approach — trusting the DAG over timestamps — works for trace rendering, but it does not help when you need to correlate traces with metrics or logs from different hosts. A global clock service, or better use of PTP, may be the long-term answer, but it is not yet practical for most.

**Trace analysis at scale.** Critical path analysis is computationally expensive on large traces. Doing it interactively for thousands of traces requires precomputation or approximation. Machine learning approaches — clustering traces by shape, detecting anomalies in span durations, predicting the root cause of latency — are promising but not yet reliable enough for production incident response.

**eBPF and auto-instrumentation.** eBPF allows tracing without code changes by intercepting system calls and network traffic. It can produce spans for HTTP, gRPC, and database calls automatically, which reduces instrumentation cost dramatically. The limitations are that eBPF spans lack application context (you cannot see business logic), and the overhead can be significant if not carefully tuned. The likely future is a hybrid: eBPF for infrastructure-level spans, SDK instrumentation for application-level spans, merged into a single trace.

**Continuous profiling.** Profiling data (CPU, memory, locks) can be correlated with traces to answer "why is this span slow?" rather than just "which span is slow?" OpenTelemetry is working on a profiling signal, and vendors are integrating profiles into trace views. The challenge is the volume of profiling data and the difficulty of correlating samples with spans without high overhead.

**Cost-effective long-term retention.** Object storage is cheap, but querying it is slow. Columnar formats like Parquet help, but they still require scanning. The ideal is an index that is cheap to store and fast to query, which is an open research problem. Some systems use a sketch-based index that trades accuracy for size, but the trade-offs are not well understood.

These open problems are not blockers; they are the frontier. The core architecture of a distributed tracing system — spans, context propagation, sampling, and a collector pipeline — is stable and well-understood. The remaining work is in making it cheaper, more accurate, and more automatic. As systems grow more distributed, the cost of causality will only increase, and the engineering trade-offs will only get more interesting.

## Inside the SDK: the life of a span

It is worth following a single span from creation to wire, because the SDK is where most of the cost and most of the silent failures live. The span model is simple; the machinery that turns it into bytes is not.

Creation begins with a context lookup and two clock reads. The SDK asks the active context for a parent, allocates a span ID from a random or counter-based source, and captures a start timestamp. Everything the application does after that point is bookkeeping against a fixed set of limits: maximum attribute count, maximum attribute value length, maximum event count, maximum link count. These limits are enforced at creation time, not at export time, because a span that is rejected at export has already cost the application the allocation, the string formatting, and the garbage collection.

The interesting design decision is **ordering**. A well-built SDK checks the sampler *before* doing any of the expensive work. If the trace is not sampled, it returns a non-recording span — an object that satisfies the API but stores nothing, allocates no attribute maps, and drops events on the floor. This is why "we instrumented everything and saw no overhead" and "we instrumented everything and our p99 doubled" can both be true: the difference is whether the no-op path was actually taken.

From there the span goes to a **span processor**, which is the SDK's internal pipeline. The simplest processor forwards each ended span directly to the exporter, synchronously or on a dedicated thread. Production SDKs use a batching processor instead: spans are appended to a bounded queue, a background thread drains the queue on a size or time trigger, and the exporter serializes the batch. The queue is bounded for a reason. An unbounded queue turns a slow backend into an out-of-memory kill, and an OOM kill in the request path is a far worse outcome than dropped telemetry. When the queue is full, the processor drops — but *what* it drops matters. Dropping the oldest spans preserves recent behavior; dropping the newest preserves the beginning of the trace. Most SDKs drop the newest, which means a burst of traffic can leave you with traces that start cleanly and end in nothing, which is exactly the shape of a trace you cannot debug.

The exporter is the last stage before the network. In OpenTelemetry, this is typically OTLP over gRPC or HTTP, carrying protobuf-encoded `ResourceSpans` → `ScopeSpans` → `Span` messages. The encoding is deliberately boring: fixed-width IDs, interned string tables per batch, repeated key-value lists. Two protocol details matter operationally. First, gRPC streaming keeps a persistent connection, which amortizes TLS handshakes and gives you flow control, but it also means a single broken connection can back up an entire batch pipeline. Second, OTLP defines a `partial_success` response: an exporter that receives it must not retry the whole batch, because some spans were accepted and retrying duplicates them. Teams that treat any non-error response as "all good" end up with silent data loss; teams that retry everything end up with duplicate spans in storage.

Shutdown is the part everyone forgets. A process that exits without flushing its batch queue loses the last few seconds of spans — which, during an incident, is precisely the window you care about. The correct pattern is an explicit flush on `SIGTERM`, wired into the framework's shutdown hook, and in Kubernetes a `preStop` delay long enough for the flush to complete before `SIGKILL`. Serverless runtimes make this worse: the execution environment is frozen after the handler returns, so a background exporter thread may never get scheduled. The workaround is to flush synchronously at the end of the invocation, which is why tracing in Lambda-style environments is often more expensive and less complete than tracing in long-lived services.

## Trace assembly: reconstructing a DAG from unordered spans

A tracing backend does not receive traces. It receives spans, one at a time, from many processes, over many connections, possibly out of order, possibly with gaps. The trace object that a UI renders is a reconstruction, and the reconstruction algorithm is a policy decision with visible consequences.

The first step is grouping: all spans with the same trace ID belong together. If storage is keyed by trace ID, this is free. If storage is keyed by time (as some columnar designs are), assembly requires an index lookup per trace, which is why trace-ID-keyed storage remains the default for the write path.

The second step is ordering, and this is where the DAG bites. A tree can be reconstructed by walking from the root down. A DAG cannot: a span may have multiple parents, a parent may never arrive, or a span may reference a parent that was sampled out upstream. Backends handle this with a few heuristics, and it is worth knowing which one yours uses:

- **Orphan promotion.** A span whose parent is missing is attached to the root, usually flagged as incomplete. The trace still renders, but the latency attribution is wrong: an orphaned child's duration appears as self time on the root.
- **Synthetic roots.** Some backends synthesize a placeholder span to keep the hierarchy honest. This is more accurate and more confusing to read, since the placeholder is not a real operation.
- **Drop-on-incomplete.** Some backends refuse to index traces with missing roots. This keeps the data clean at the cost of hiding exactly the traces where something went wrong with propagation — the ones you most want to see.

Duplicate spans are the other assembly hazard. Retried exports, at-least-once delivery from a message queue, and dual instrumentation (an SDK span plus an eBPF-generated span for the same request) all produce spans that share an ID but disagree on details. An idempotent backend keys by `(trace_id, span_id)` and keeps the first or the last; a naive one renders both, and the waterfall shows a phantom child that inflates the trace duration. Because span IDs are randomly generated per process, this is rare — but it becomes common when an instrumentation library reuses IDs across retries.

Finally, the backend must decide **when a trace is complete**. There is no completion marker in the protocol. The practical signal is the presence of a root span — a span with no parent — plus a grace period for stragglers. Traces that never produce a root (because the entry service crashed, or its spans were dropped by the batching queue) sit in a "pending" state until a timeout evicts them. Query layers usually show these as partial, and a good UI should say so explicitly rather than drawing a waterfall that looks complete. The single most misleading artifact in tracing is a partial trace rendered without an incompleteness marker: the engineer concludes the slow call is the last visible span, when in fact the missing 90% of the latency is simply not there.

## Propagation at the edges

Most propagation documentation describes the happy path: a service receives a header, extracts it, creates a span, injects the header, calls the next service. Real systems have edges where that path breaks, and each edge has a characteristic failure.

**Proxies and header rewriting.** Load balancers, CDNs, and service meshes routinely strip, reorder, or duplicate headers. A proxy that normalizes header casing is harmless; a proxy that drops `tracestate` because it is not on an allowlist silently destroys vendor-specific sampling state while leaving `traceparent` intact, producing traces that are structurally correct but sampled at the wrong rate. Header size limits are the other constraint: `traceparent` is tiny, but a `tracestate` with thirty-two entries plus baggage can push a request over a proxy's limit, and the failure mode is a 431, not a missing trace.

**CORS and browser clients.** A browser will not send custom headers cross-origin unless the server explicitly allows them, and `traceparent` is a custom header. Getting end-to-end traces from a web frontend requires adding `traceparent` and `tracestate` to `Access-Control-Allow-Headers`, and preflight requests themselves must be traced or excluded deliberately. Server-side rendering and edge workers add another hop where the header must be re-injected.

**Message queues.** A queue decouples producer and consumer in time, which is exactly what makes propagation hard. The producer injects the context into record headers; the consumer extracts it and creates a span with the producer's span as parent — or, for batch consumption, as a link. The batch case is the interesting one: a consumer processing a hundred records has a hundred potential parents and no single causal parent of its own. Creating a hundred child spans under one consumer span is the pragmatic answer, but it means the consumer span's duration is the batch duration, and the per-record latency is only visible on the children. Systems that insist on strict parent-child semantics end up with either a hundred disconnected roots or a lie.

**Async boundaries inside a process.** The context has to survive a thread pool handoff, a reactive operator chain, a coroutine suspension, and a callback registration. Each framework has its own storage primitive, and each one has a known way to lose the context. The reliable pattern is to capture the context at submission and wrap the task so that it installs and clears the context around execution — and to make the wrapper the *only* way tasks are submitted, because a single unwrapped submission in a shared pool is enough to corrupt the context of every subsequent task on that thread.

**Deferred export.** Some SDKs support a variant where a service records spans locally but only exports them if a downstream response carries a "keep" signal. This lets a tail decision be made by the service that actually knows the outcome — the entry point — without centralizing all spans in a stateful collector. The cost is that every intermediate service must buffer, and the buffer must be bounded by trace size, not just time, or a single pathological request can pin memory across the fleet.

## Sampling arithmetic: adjusted counts and the bias trap

Sampling is usually described as a ratio, but the ratio is not enough information. To compute anything unbiased from sampled data, the backend must know the probability with which each span was kept, and it must be able to reconstruct that probability from the trace itself rather than from a configuration file that may have changed since.

This is what consistent sampling solves. The trace ID is already uniformly random, so a sampler can define the decision as "keep if the trace ID's low-order bits, interpreted as a number, are below a threshold." Every service that knows the threshold makes the identical decision without coordination. Downstream, the threshold is recoverable from the trace ID itself, which means the *adjusted count* — the number of real requests each sampled trace represents — is computable at query time. With 128-bit trace IDs there is ample room for this; but the W3C sampled flag is one bit and carries no threshold, which is why the Level 2 work on a randomness value exists. Without it, a backend that sees a sampled trace has to guess the rate from configuration, and a guess that is wrong by a factor of ten produces latency percentiles that are wrong by a factor of ten.

The bias trap is subtler than it looks. Suppose you keep all error traces and 1% of the rest. Your trace store now contains a wildly unrepresentative sample, and any metric derived from it inherits the distortion. Errors correlate with latency, so an error-biased sample over-represents slow requests; a p99 computed over kept traces will read much worse than reality. The same applies to tail sampling policies built on latency thresholds: keeping "all traces slower than two seconds" means every duration in your store above two seconds is fully represented while everything below is sparse, and a histogram built from that data has a discontinuity at the threshold that is an artifact of the policy, not the system.

The mitigation is to carry the sampling weight explicitly through the pipeline and to compute aggregates with weighted counts, or — more practically — to compute aggregate metrics from a complete source and use traces only for individual investigation. Sampling is a policy about which *examples* you retain. It is a poor foundation for population statistics, and systems that blur the two end up with dashboards that are confidently wrong in exactly the situations where being wrong is most expensive.

## Semantic conventions and the problem of stable meaning

The span model is deliberately loose: attributes are arbitrary key-value pairs. That looseness makes tracing adaptable, and it makes large trace datasets hard to query. Two services can emit `http.status_code` and `http.status` for the same field; one can report milliseconds and another seconds; one can put `service.name` on the span and another on the resource. The data is present, but the join is missing.

Semantic conventions are the contract that fixes meaning. OpenTelemetry publishes conventions for HTTP, databases, messaging, RPC, and resources, and the conventions are versioned. The versioning is not bureaucratic. An attribute's type, unit, or allowed values can change between versions, and a backend that indexes old and new data together must either normalize at ingestion or maintain parallel indexes. Normalization is the usual answer: a collector processor rewrites deprecated keys to their replacements, converts units, and fills defaults. The cost is that the rewrite is a semantic decision made by infrastructure rather than the service owner, and a bad mapping silently corrupts data. A strict backend that rejects unknown keys is worse: instrumentation upgrades would break ingestion.

The stable core is smaller than the full convention set. Service name, operation name, status, and duration are the fields every query and service map needs, and they should be treated as schema, not optional attributes. Everything else is enrichment. Teams that enforce this split get searchable traces and a service map that survives instrumentation churn. Teams that let every library choose its own keys get a data lake of spans that is complete and practically unqueryable.

Schema also affects retention and migration. Renaming an attribute is cheap in the SDK and expensive in storage: old spans keep the old key, dashboards split into two series, and queries must union both. The practical fix is dual-writing during a migration window and teaching the query layer to resolve aliases. It is unglamorous work, but it separates a tracing system that compounds in value from one that decays as instrumentation drifts.

The same discipline applies to resource attributes. `host.name`, `k8s.pod.name`, and `cloud.region` describe where a span ran, not what it did, and they should be populated once per process rather than repeated per span. When resource attributes are consistent, a query can slice latency by deployment without any application change; when they are ad hoc, every new question becomes a new instrumentation project.
