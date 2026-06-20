---
title: "Exactly-Once in Streaming: What It Means and How Systems Achieve It"
description: "Disentangle marketing from mechanisms: idempotence, transactions, and state snapshots behind ‘exactly-once’."
date: "2025-01-22"
author: "Leonardo Benicio"
tags: ["streaming", "kafka", "flink", "semantics"]
categories: ["distributed systems", "stream processing"]
cover: "/static/assets/images/blog/exactly-once-semantics-streaming.png"
---

"Exactly-once" doesn’t mean an event packet traverses the network a single time. It means that in the _observable_ outputs (state, emitted records, external side effects) each logical input is reflected **at most once** and **at least once**—so exactly once—despite retries, replays, failovers, or speculative execution. It is an _end-to-end_ property requiring cooperation across producer, broker, processing engine, and sinks.

---

## 1. Taxonomy of Delivery & Processing Guarantees

| Term                      | Network Delivery     | Processing Attempts | External Effect Guarantee              | Typical Mechanisms                               |
| ------------------------- | -------------------- | ------------------- | -------------------------------------- | ------------------------------------------------ |
| At most once              | Messages may be lost | ≤1                  | Missing effects possible               | Fire-and-forget, no ack replay                   |
| At least once             | Redelivery possible  | ≥1                  | Duplicated effects if not idempotent   | Offsets/checkpoints + replay                     |
| Exactly once (processing) | Redelivery possible  | ≥1                  | Each logical record causes effect once | Idempotence + dedupe or transactions + snapshots |

Note the _processing_ dimension: we usually allow redelivery at the transport layer; the system masks duplicates before they become externally visible.

---

## 2. Building Blocks

### 2.1 Idempotent Writes

If applying the same event twice yields the same state as once, duplicates are harmless. Techniques:

1. Natural key upsert (primary key overwrite) in a database.
2. Commutative/associative aggregation (sums, max, HyperLogLog merges) with careful bounding.
3. Deduplication tables (store last processed sequence per key, ignore older/repeated).

### 2.2 Sequence Numbers & Producer Epochs

Kafka’s idempotent producer tags each batch with a monotonic sequence per partition + producer ID. Broker rejects out-of-order duplicates within retention. Crash & restart increments epoch, preventing stale inflight data from being accepted.

### 2.3 Transactions

Combine multiple writes (e.g., produce to output topics + commit consumer offsets) into an atomic unit. If transaction aborts, offsets aren't committed, so replay reprocesses _but_ earlier partial writes are aborted (invisible). Key idea: **atomic offset commit + output publish**.

### 2.4 State Snapshots / Checkpoints

Periodic capture of operator state + source position (offsets). After crash, restart from snapshot point and replay from saved input position, ensuring deterministic replay window.

### 2.5 Determinism & Side Effects

Non-deterministic operators (e.g., random numbers, system time) break repeatability unless controlled (seeded RNG, event-time derivations). External side effects (sending emails) must be coordinated (outbox pattern, idempotency tokens) or exactly-once claims degrade to at-least-once with disclaimers.

---

## 3. End-to-End Example: Kafka + Flink

Flow:

1. **Source** (Kafka consumer) reads partitions with offsets; includes offsets in barrier alignment snapshots.
2. **Barrier Injection**: JobManager triggers checkpoint N; sources emit barrier N downstream.
3. **Operator Alignment**: Each operator buffers upstream channels until receiving barrier N on all, then snapshots keyed state (e.g., RocksDB) + timers.
4. **Snapshot Storage**: State backend persists state + offset metadata (filesystem / object store).
5. **Commit**: Once all tasks ack, checkpoint becomes _completed_; transactional sinks commit their pending transactions for N.
6. **Failure & Recovery**: Restart tasks load last successful checkpoint, seek Kafka consumers to persisted offsets, reprocess from there only.

Diagram (conceptual):

```text
Kafka Partitions --> Source Tasks --barriers--> Map/KeyBy/Window --> Sink (2-phase txn)
             offsets & seq       snapshot(state+offsets)            pre-commit until barrier complete
```

### Consistency Window

State corresponds _exactly_ to offsets up to the last barrier. Records after that barrier may have been processed speculatively but their outputs held in pending transactions not yet committed, ensuring atomic visibility.

---

## 4. Failure Scenarios & Resolution

| Scenario                                                        | Without XA / Idempotence        | With Transactions & Checkpoints                               |
| --------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------- |
| Task crash after producing output but before committing offsets | Duplicate output on replay      | Uncommitted transaction discarded; outputs invisible          |
| Broker redelivers batch (network glitch)                        | Duplicate aggregation           | Sequence numbers dedupe / idempotent merge                    |
| Partial sink batch success                                      | Split output set                | Atomic commit or outbox ensures all-or-nothing                |
| Late-arriving event after watermark                             | Possibly ignored inconsistently | Unified watermark & allowed lateness, deterministic side-path |

---

## 5. Windowing, Watermarks & Exactly-Once

Event-time windows close based on _watermarks_ (monotonic progress markers). Exactly-once windowed aggregations require:

1. Deterministic assignment of events to windows.
2. Snapshot inclusion of partial window state + watermark value.
3. Reprocessing after failure reproduces same emission pattern (window triggers) before committing downstream.

Out-of-order handling (allowed lateness) adds potential retractions. Systems often implement _update_ semantics: a late event triggers recomputation and emission of an updated result (idempotent if downstream keyed by window). Ensure downstream sink overwrites (idempotent upsert) rather than append-only.

---

## 6. Sinks: Idempotent vs. Transactional

| Sink Type                             | Strategy                         | Pros                 | Cons                                           |
| ------------------------------------- | -------------------------------- | -------------------- | ---------------------------------------------- |
| Keyed DB (e.g., Cassandra)            | Upsert by primary key            | Simple, idempotent   | Last-write-wins may hide duplicates            |
| Object store (files)                  | Staging + atomic rename          | Avoid duplicates     | Small file proliferation, eventual consistency |
| Kafka topic                           | Transactions (produce + offsets) | End-to-end semantics | Longer commit latency                          |
| Elastic / Search                      | External idempotency key         | Dedup at index layer | Requires extra key management                  |
| Data warehouse (batch micro-batching) | Merge-on-read (Delta/Iceberg)    | ACID semantics       | Higher latency                                 |

---

## 7. Latency vs. Semantics Trade-offs

Lower checkpoint interval ⇒ more overhead (barrier alignment, state snapshot I/O) but less reprocessing on failure. Higher interval reduces steady latency cost but increases _rollback distance_ (amount of work to replay) and potential duplicate output risk if sinks are partially transactional.

Tuning axes:

1. **Checkpoint Interval**: start moderate (e.g., 1 min) then measure state size & throughput.
2. **State Backend**: In-memory backend low latency but volatile; RocksDB durable but adds serialization + compaction overhead.
3. **Async vs. Sync Commits**: Some sinks support asynchronous pre-commit overlapped with processing; measure end-to-end tail latency (p99) not just mean.
4. **Batching**: Larger transactional batches amortize overhead but increase recovery replay window.

---

## 8. Testing Exactly-Once Claims

Checklist:

1. Induce failures (SIGKILL task managers) mid-checkpoint; verify no duplicated sink rows.
2. Simulate network partitions / broker restarts; confirm sequence gaps not causing lost records.
3. Inject duplicate producer sends; ensure downstream aggregate stable.
4. Replay from older checkpoints intentionally; verify deterministic output reproduction.
5. Time-skew tests: deliver late events within allowed lateness; verify window updates idempotently replace prior results.
6. Chaos automation: schedule random process kills + network delays during stress load.

Metrics to watch: checkpoint duration, bytes snapshotted, barrier alignment time, end-to-end latency distribution, number of aborted vs. committed transactions.

---

## 9. Operational Pitfalls

| Pitfall                                                | Effect                   | Mitigation                                              |
| ------------------------------------------------------ | ------------------------ | ------------------------------------------------------- |
| Large RocksDB state compactions align with checkpoints | Latency spikes / timeout | Stagger compactions, increase incremental checkpointing |
| Slow sink flush extends checkpoint completion time     | Backpressure to sources  | Increase sink parallelism, tune batch size              |
| Unbounded dedupe tables                                | Memory blow-up           | TTL / probabilistic structures (Bloom + index)          |
| Mixed time semantics (processing vs event time misuse) | Nondeterministic replays | Normalize to event time early                           |
| Non-idempotent side-effects (emails)                   | Duplicate user impact    | Outbox pattern + idempotency keys                       |

---

## 10. Alternative Approaches & Emerging Trends

1. **Change Data Capture (CDC) with Upsert Logs**: Instead of stream processor enforcing exactly-once, downstream warehouse merges logs transactionally, shifting complexity.
2. **Streaming Lakehouse Tables**: Formats like Delta / Iceberg + streaming writers use snapshot isolation + atomic manifest commits to approximate exactly-once ingestion, assuming deterministic partitioning.
3. **Versioned State Stores**: Multi-version concurrency control (MVCC) in streaming databases enabling rollback consistent with checkpoint snapshots.
4. **Deterministic Replay Engines**: Systems recording input order (totally ordered logs) + deterministic operator execution can rebuild state _precisely_ without intermediate snapshots (higher storage, lower snapshot overhead).
5. **Transactional Message Queues**: Some brokers incorporate per-message idempotency tokens reducing need for engine-level dedupe.

---

## 11. Cost & Resource Considerations

Exactly-once has _taxes_:

1. Extra bytes for sequence numbers / transactional markers.
2. Increased I/O for frequent snapshots (state size × frequency).
3. Latency added by barrier alignment (slow partitions drag all).
4. Storage for retained checkpoints and changelogs.
5. CPU for serialization / RocksDB compactions.

Estimate snapshot overhead:
$$ Overhead = \frac{StateSize}{Interval} $$ (bytes/sec). Use this to budget I/O bandwidth; ensure it remains a small fraction (<10%) of disk or network capacity.

---

## 12. Putting It Together: Mini Scenario

Use case: Real-time fraud scoring. Requirements: <500 ms p95 latency, exactly-once updates to a feature store + notifications topic.

Architecture:

1. Kafka topics ingest transactions.
2. Flink job performs keyed aggregations (rolling risk scores) stored in RocksDB state.
3. Every 30s checkpoint with incremental snapshotting; transactional sink writes scores + commits consumer offsets.
4. Notification sink uses idempotent put with (user_id, window_end) key.

Failure drill: kill a TaskManager mid-window; on restart, state restored, replay re-applies late events; dedupe prevents double notifications. Latency budget preserved because checkpoint duration <1s and incremental diffs small vs. base state.

Outcome: Verified by chaos tests (24h run) zero duplicate notifications, stable resource usage.

---

## 13. Checklist

1. Do sources support replay starting from a precise offset/sequence? (Needed.)
2. Are all sink writes idempotent _or_ wrapped in an atomic commit with source offsets?
3. Is operator logic deterministic given the same input order & watermark progression?
4. Are late event policies consistent under replay (same allowed lateness)?
5. Are state + offsets part of the same durability boundary (checkpoint / snapshot)?
6. Do you have automated failure injection tests asserting no duplicate side-effects?
7. Are metrics & alerts in place for aborted transactions rising above baseline?

---

## 14. Further Reading (Titles)

- "Set Processing Semantics in Stream Processing" (concept overviews)
- "Exactly-Once Semantics in Apache Flink" (whitepaper style articles)
- "Idempotent and Transactional Producers in Apache Kafka" (mechanism descriptions)
- "Incremental Checkpointing in State Backends" (performance impact)
- "Watermarks and Event Time Semantics" (window correctness)
- Vendor & project blogs on transactional sinks and state backends

---

## 15. Summary

Exactly-once semantics emerge from _coordinated components_: deterministic replay, atomic publication with offset progression, idempotent or transactional sinks, and bounded state snapshots. Marketing phrasing aside, it’s an engineering contract: tolerate replays internally while exposing a clean, single-effect external view. Evaluate the cost (I/O, latency, complexity) versus business impact of duplicates; sometimes _effectively-once_ (idempotent sinks, at-least-once transport) is sufficient. Where correctness demands strict guarantees (finance, compliance), invest in full transactional + checkpointed pipelines and continuously test their failure modes.
