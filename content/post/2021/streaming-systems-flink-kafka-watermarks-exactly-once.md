---
title: "Streaming Systems: Apache Flink Checkpointing, Kafka Log Compaction, Watermarks and Event-Time Processing, and Exactly-Once Semantics"
description: "A deep exploration of streaming systems — how Flink's distributed checkpointing provides exactly-once state consistency, how Kafka's log compaction enables durable event storage, and how watermarks solve the event-time vs processing-time dilemma."
date: "2021-07-22"
author: "Leonardo Benicio"
tags: ["streaming", "flink", "kafka", "watermarks", "exactly-once", "distributed-systems"]
categories: ["systems", "streaming"]
draft: false
cover: "/static/assets/images/blog/streaming-systems-flink-kafka-watermarks-exactly-once.png"
coverAlt: "A stylized diagram showing Kafka topics feeding Flink streaming operators, with watermarks flowing through the DAG and checkpoint barriers triggering distributed snapshots"
---

In 2015, the Apache Flink project introduced a concept that changed how the industry thought about data processing: exactly-once state consistency. Before Flink, stream processing systems (Storm, Samza, early Spark Streaming) offered at-least-once semantics — in a failure, some data might be processed twice. For counting events or computing aggregates, this was acceptable. For financial transactions, billing systems, or any application where correctness demanded that every event be processed exactly once, it was a dealbreaker. Flink's innovation was a distributed checkpointing algorithm that captured the entire state of a streaming pipeline — all operators, all in-flight records, all buffer contents — in a consistent snapshot, without stopping the data flow. Combined with Kafka's durable, ordered log storage and a sophisticated event-time processing model based on watermarks, Flink established the foundations for modern stream processing. This post explores how these pieces fit together.

## 1. The Stream-Table Duality

Stream processing rests on a deep theoretical foundation: the stream-table duality. A stream is an infinite sequence of events, each with a timestamp and a value. A table is a snapshot of state at a point in time, derived by applying all events in the stream up to that point. The relationship is dual: you can turn a stream into a table through aggregation (the latest value for each key is the current state), and you can turn a table into a stream by capturing all changes to the table (the change data capture, or CDC, stream).

This duality gives streaming systems their power. A streaming query that computes "the count of events per user over the last hour" maintains a table (the counts) that is updated by each new event. If the system fails and restarts, it needs to recover the table — not by replaying all events from the beginning of time, but from the most recent checkpoint. The checkpoint captures the table at a specific point in the stream (a specific offset in each input partition), and replay from that point restores consistency.

## 2. Flink's Distributed Checkpointing: The Chandy-Lamport Algorithm in Practice

Flink's checkpointing algorithm is based on the Chandy-Lamport distributed snapshot algorithm from 1985. The key insight of Chandy-Lamport is that a consistent snapshot of a distributed system can be taken without stopping the system, by injecting "marker" messages into the data flow and having each process record its state when it first sees a marker.

Flink adapts Chandy-Lamport for streaming pipelines. The JobManager (Flink's coordinator) periodically injects "checkpoint barriers" into the source operators. A checkpoint barrier is a special record that flows through the DAG of operators alongside normal data records. When an operator receives a checkpoint barrier on one of its input channels, it:

1. Stops processing records from that channel (it "aligns" on the barrier).
2. Waits for barriers to arrive on all other input channels.
3. When all barriers have arrived, takes a snapshot of its current state (its in-memory data structures, counters, partial aggregations).
4. Writes the snapshot to durable storage (typically a distributed file system like HDFS or S3).
5. Forwards the barrier to its downstream operators.
6. Resumes processing on all channels.

This algorithm guarantees that the snapshot is consistent: for every record, either the record is included in the snapshot (it was processed before the barrier arrived) or it's not included but will be replayed after recovery (it arrived after the barrier). The snapshot captures exactly the state that would result from processing all records before the barrier and none after — an "exactly-once" cut through the stream.

The checkpoint barrier alignment is the key to consistency, but it can introduce latency. An operator that has received a barrier on channel A but is waiting for the barrier on channel B is blocked — it can't process records from channel A (because that would violate the snapshot consistency), and it can't process records from channel B (because the barrier hasn't arrived yet). For pipelines with high throughput and low latency requirements, this blocking is unacceptable.

Flink addresses this with "unaligned checkpoints" (introduced in Flink 1.11). Instead of waiting for alignment, the operator takes a snapshot of its in-flight buffers (the records that have been received but not yet processed) as part of the checkpoint. The barrier flows through without waiting, eliminating the alignment delay. The price is that the snapshot includes in-flight records, which must be replayed after recovery — but the barrier flow is not blocked, preserving low latency.

## 3. Kafka: The Durable, Ordered Event Log

Apache Kafka provides the durable storage layer that streaming systems depend on. Kafka's architecture is deceptively simple: it's a distributed append-only log, partitioned by key, with configurable retention. Producers append records to the end of a partition; consumers read records sequentially from a partition; and Kafka guarantees that records within a partition are delivered in order.

Kafka's durability comes from replication. Each partition has a leader replica and multiple follower replicas. Producers write to the leader, which appends to its log and replicates to followers. If the leader fails, one of the in-sync followers takes over. Kafka guarantees that records committed to the leader (acknowledged by all in-sync replicas) are not lost even if the leader fails.

Kafka's log compaction feature is particularly important for streaming state recovery. Log compaction ensures that for each key, the latest value is always retained, even if older values are deleted. This allows Kafka to serve as a "source of truth" for keyed state: a streaming application that maintains the latest profile for each user can store those profiles in a compacted Kafka topic, and on restart, read the compacted topic to restore its state. The compacted topic contains exactly one record per key (the latest), so the recovery read is efficient.

Kafka's offset management enables exactly-once consumption. Each consumer records its position (the offset of the last record it processed) in a Kafka topic. On restart, the consumer reads the offset and resumes from that point. Combined with Flink's checkpointing (which stores offsets as part of the checkpoint), this provides end-to-end exactly-once semantics: Flink checkpoints the consumer offsets, and on recovery, resets the Kafka consumer to the checkpointed offsets, replaying any records that were processed after the checkpoint but not included in it.

## 4. Watermarks and Event-Time Processing

One of the hardest problems in stream processing is handling out-of-order events. Events can arrive late due to network delays, clock skew, or upstream batching. If you're computing "the number of events in the last hour," and an event from 59 minutes ago arrives now, it should be counted — but how long should you wait for late events before declaring the window complete and emitting the result?

Watermarks are Flink's answer. A watermark is a special record that flows through the stream alongside data records, carrying a timestamp. The watermark asserts: "all events with timestamps earlier than T have been observed." When an operator receives a watermark with timestamp T, it knows that no more events with timestamps < T will arrive (on that input channel), and it can complete and emit any windows that end at or before T.

Watermarks are generated at the source (or at the first operator after the source). The source tracks the maximum timestamp it has seen so far, and periodically emits a watermark equal to `max_timestamp - allowed_lateness`. The "allowed lateness" is a configurable bound: if you're willing to wait up to 5 seconds for late events, the watermark lags behind the maximum observed timestamp by 5 seconds. If an event arrives later than the allowed lateness, it's considered "late" and may be dropped or processed separately (as a "side output").

The trade-off is between completeness and latency. A small allowed lateness produces results quickly but may miss some events. A large allowed lateness captures more events but delays results. Flink allows per-window configuration of lateness bounds, giving developers fine-grained control over this trade-off.

## 5. Exactly-Once End-to-End

Flink's exactly-once guarantees extend beyond state recovery to end-to-end processing. A streaming pipeline that reads from Kafka, processes events, and writes results to a database can maintain exactly-once semantics even across failures, provided the sink supports idempotent or transactional writes.

Flink's two-phase commit protocol for sinks ensures that sink writes are included in the checkpoint transactionally. When a checkpoint completes, Flink "commits" the checkpoint, notifying all sinks that the checkpointed state is durable. The sink can then make its writes visible (e.g., commit a database transaction). If the job fails before the commit completes, the sink's writes are rolled back, and on recovery, the job replays from the previous checkpoint, re-executing the writes — exactly once.

Kafka's transactions feature (introduced in Kafka 0.11) integrates with Flink's checkpointing to provide exactly-once output to Kafka topics. Flink's Kafka producer registers with Kafka's transaction coordinator, and each checkpoint corresponds to a Kafka transaction. If the job fails, the transaction is aborted, and consumers see nothing. If the job succeeds, the transaction is committed, and consumers see all the output records exactly once.

This end-to-end exactly-once guarantee — from Kafka input through Flink processing to Kafka output — is the gold standard of stream processing. It enables applications that were previously the domain of batch processing (billing, reconciliation, financial settlement) to run as low-latency streaming pipelines.

## 6. Summary

The combination of Apache Flink and Apache Kafka has defined the modern stream processing stack. Flink's distributed checkpointing, based on Chandy-Lamport snapshots, provides exactly-once state consistency without stopping the data flow. Kafka's durable, ordered, partitioned log provides fault-tolerant event storage that survives machine failures and enables efficient replay. Watermarks solve the event-time vs processing-time dilemma, enabling accurate windowed computations on out-of-order data.

The stream-table duality underpins the entire architecture. Streams are the continuous input; tables are the derived state; checkpoints are the mechanism that keeps them consistent. This duality, made operational by Flink and Kafka, enables applications that process millions of events per second with exactly-once guarantees, sub-second latency, and fault tolerance that survives machine failures without data loss.

Streaming has moved from a niche technology for real-time analytics to the default processing model for new applications. The batch-vs-streaming debate is over: batch is a special case of streaming (processing a bounded stream), and streaming is the general case. Flink and Kafka, working together, have made this vision practical.

## 7. State Backend Architecture in Flink

Flink's state backends determine where and how operator state is stored. The three backends offer different trade-offs:

The `HashMapStateBackend` (formerly `FsStateBackend`) stores working state as objects on the Java heap, and checkpoints the state to a distributed file system (HDFS, S3). This is the default backend and works well for most applications. The in-heap state provides fast access (no deserialization on every read), and the file-based checkpoints are durable. However, the heap-based state is limited by the JVM heap size, and large states can cause GC pressure.

The `EmbeddedRocksDBStateBackend` stores working state in an embedded RocksDB instance (on local disk or SSD), with checkpoints written to a distributed file system. RocksDB is an LSM-tree-based key-value store optimized for fast writes and efficient range scans. This backend can handle very large state (terabytes) that doesn't fit in memory, because the working state is on disk. The trade-off is that every state access requires deserialization from RocksDB's on-disk format, adding latency.

The `HeapStateBackend` (legacy, being deprecated) stores both working state and checkpoints on the Java heap. This is the fastest backend (no serialization, no disk I/O) but the least durable (state is lost on JobManager failure) and limited in size (heap size constraints). It's suitable for stateless or small-state jobs where durability is not critical.

## 8. Kafka Streams: Streaming Without a Separate Cluster

While Flink requires a dedicated cluster of TaskManagers, Kafka Streams takes a different architectural approach: it's a Java library that embeds stream processing directly into the application. A Kafka Streams application is a normal Java application that links against the Kafka Streams library and uses Kafka for both input/output and state storage. There is no separate processing cluster to manage — the application's instances (which can be scaled horizontally) coordinate via Kafka's consumer group protocol.

Kafka Streams implements exactly-once semantics using Kafka's transactions, similar to Flink's Kafka sink integration. State is stored in local RocksDB instances, and state changes are replicated to a changelog Kafka topic for fault tolerance. On restart, the application reads the changelog topic to restore its state, then resumes processing from the last committed offset.

The trade-off between Flink and Kafka Streams is operational simplicity vs expressive power. Kafka Streams is simpler to deploy (no separate cluster) but has fewer advanced features (no event-time watermarks as sophisticated as Flink's, no batch-stream unification, fewer window types). For simple stream processing (filter, map, aggregate, join), Kafka Streams is often sufficient. For complex event-time processing with out-of-order data, Flink's watermark model is more robust.

## 9. Flink SQL and the Stream-Batch Unification

Flink's most ambitious feature is its SQL interface, which provides a unified API for both streaming and batch processing. The same SQL query can run on a bounded stream (a batch file, producing a final result) or an unbounded stream (a Kafka topic, producing continuously updated results). This "stream-batch unification" is possible because Flink's underlying runtime treats batch as a special case of streaming (a stream with a finite end).

A Flink SQL query like `SELECT user_id, COUNT(*) FROM clicks GROUP BY user_id` compiles to a streaming execution plan: a source operator reads from the `clicks` topic, a key-by operator partitions events by `user_id`, a window or aggregate operator maintains per-user counters, and a sink operator writes results. If the `clicks` table is a Kafka topic, the query runs continuously. If it's a file (e.g., Parquet on S3), the query processes the entire file and terminates.

Flink SQL supports a rich set of streaming-specific constructs. `TUMBLE`, `HOP`, and `SESSION` windows define how events are grouped into time-based windows. `MATCH_RECOGNIZE` enables pattern matching over event sequences (complex event processing, or CEP). `OVER` windows enable running aggregates (moving averages, cumulative sums). Temporal table joins enable joining a stream with a slowly-changing dimension table (e.g., enriching click events with the user's current profile).

The optimizer for Flink SQL is cost-based, using statistics (cardinality, selectivity) to choose join strategies (hash join, sort-merge join, broadcast join) and to determine operator parallelism. The same optimizer handles both streaming and batch queries, applying different cost models for the two execution modes.

## 10. Scaling Kafka: Partitions, Consumer Groups, and Rebalancing

Kafka's partition model is the key to its scalability. A topic is divided into partitions, each of which is an ordered, immutable log. Partitions are distributed across Kafka brokers (servers), with each partition having a designated leader broker that handles all reads and writes. A producer can write to any partition (round-robin, key-based, or custom partitioner). A consumer reads from one or more partitions.

Consumer groups enable parallel consumption. Each partition in a topic is assigned to exactly one consumer in a consumer group. If a topic has 8 partitions and the consumer group has 4 consumers, each consumer handles 2 partitions. If the group has 8 consumers, each handles 1 partition. If the group has 16 consumers, 8 are idle (each partition can be consumed by only one consumer). This model provides both parallelism (more consumers = more throughput, up to the partition count) and ordering (events within a partition are processed in order by a single consumer).

Partition rebalancing — redistributing partitions among consumers when the group membership changes — is a delicate operation. During a rebalance, consumers briefly stop processing, the group coordinator (a Kafka broker) reassigns partitions, and consumers resume processing from their last committed offsets. Kafka's incremental cooperative rebalancing (introduced in Kafka 2.4) minimizes the disruption: instead of stopping all consumers, only the partitions that need to move are reassigned, and other partitions continue processing uninterrupted.

## 11. The Dataflow Model and Its Influence

Flink's programming model is deeply influenced by the Dataflow model, described in a 2015 paper by Google engineers. The Dataflow model unifies batch and streaming processing by treating both as pipelines over "PCollections" (potentially unbounded collections of elements), with windowing, triggering, and accumulation modes that are the same for both.

The key concepts from the Dataflow model that Flink implements are: event time (the time when an event occurred, distinct from processing time when the event is observed), windows (logical groupings of events by time or count), triggers (conditions that cause window results to be emitted — watermark progress, processing time timers, element counts), and accumulation modes (discarding — emit only the delta with each trigger; accumulating — emit the cumulative result; accumulating and retracting — emit the cumulative result and retract the previous value, for downstream correctness).

The Dataflow model paper is essential reading for understanding modern stream processing. It formalizes concepts that had been ad-hoc in earlier systems (Storm, Spark Streaming) and provides a rigorous framework for reasoning about out-of-order processing. Flink is the open-source implementation that most closely follows the Dataflow model, which is why Flink's event-time processing is more robust than many alternatives.

## 12. Flink's Network Stack: Credit-Based Flow Control

Flink's network stack implements a credit-based flow control mechanism to prevent slow consumers from being overwhelmed by fast producers. Each input channel at a downstream operator has a limited number of "buffers" (exclusive floating buffers). The upstream operator can send data only when it has "credits" — tokens that the downstream operator grants when it has free buffers. This prevents head-of-line blocking and ensures that backpressure propagates through the pipeline without dropping records.

The credit-based protocol works as follows. The downstream operator initially grants a fixed number of credits to each upstream operator (e.g., 2 buffers). The upstream operator can send up to 2 buffers of data, then must wait for more credits. When the downstream operator processes a buffer and frees it, it grants a new credit to the upstream operator. This creates a self-regulating flow: if the downstream operator is slow, it grants credits slowly, and the upstream operator naturally slows down. If the downstream operator is fast, it grants credits quickly, and the upstream operator can send at full speed.

The credit-based protocol runs entirely within Flink's network layer (Netty-based, using TCP connections between TaskManagers). It is transparent to the application — the developer doesn't need to configure buffer sizes or credit counts. The protocol automatically adapts to processing speed differences between operators, which is essential for handling skewed workloads (e.g., one key receiving 90% of the data) without dropping records or exhausting memory.

## 13. Summary

The combination of Apache Flink and Apache Kafka has defined the modern stream processing stack. Flink's distributed checkpointing, based on Chandy-Lamport snapshots, provides exactly-once state consistency without stopping the data flow. Kafka's durable, ordered, partitioned log provides fault-tolerant event storage. Watermarks solve the event-time vs processing-time dilemma. The stream-table duality underpins the entire architecture: streams are continuous input, tables are derived state, checkpoints keep them consistent. Streaming has moved from a niche technology to the default processing model for new applications. Batch is a special case of streaming; streaming is the general case.

## 14. Flink State TTL and the Challenge of Unbounded State

In an unbounded stream, state can grow without bound if every event adds new keys. A stream that computes "count of orders per user" will accumulate state for every user who ever placed an order — and users never expire. Over years of operation, the state grows to billions of keys, requiring terabytes of RocksDB storage and slowing checkpointing to unacceptable durations. Flink addresses this with State TTL (Time-To-Live): state entries that haven't been accessed for a configurable duration are automatically expired and removed.

State TTL is configured per state descriptor: `StateTtlConfig.newBuilder(Time.days(30)).setUpdateType(UpdateType.OnCreateAndWrite).build()`. The update type determines when the TTL timer is reset: `OnCreateAndWrite` resets on both creation and modification; `OnReadAndWrite` also resets on access (which can keep state alive indefinitely if frequently accessed; useful for caches). Expired state is removed lazily — a background thread periodically scans state and removes expired entries, and access to expired state returns null (as if the state never existed).

State TTL transforms unbounded state into bounded state at the cost of eventual completeness. After the TTL expires, events for a given user will be treated as if the user is new, and historical counts are lost. This trade-off is acceptable for many streaming applications (e.g., fraud detection that only needs recent activity, or real-time analytics that prioritize recency over completeness). The alternative — retaining all state forever — is unsustainable for long-running streaming jobs.

## 15. Summary

The combination of Apache Flink and Apache Kafka has defined the modern stream processing stack. Flink's distributed checkpointing provides exactly-once state consistency. Kafka's durable log provides fault-tolerant event storage. Watermarks enable accurate event-time processing on out-of-order data. State TTL bounds the growth of state over unbounded time. The stream-table duality unifies batch and streaming, making batch a special case of streaming. Streaming is now the default processing model for new applications, and Flink and Kafka are the tools that made it practical.

## 16. The Evolution from Lambda to Kappa Architecture

Stream processing has driven an architectural evolution from Lambda to Kappa architectures. The Lambda architecture (coined by Nathan Marz in 2011) maintained two parallel systems: a batch layer (Hadoop/Spark) for accurate, comprehensive results, and a speed layer (Storm/Samza) for low-latency approximate results. The two layers were reconciled periodically, with the batch layer's results serving as the source of truth. This architecture was complex to operate (two codebases, two clusters, two sets of monitoring) and introduced latency in the reconciliation process.

The Kappa architecture (proposed by Jay Kreps, Kafka's co-creator, in 2014) eliminates the batch layer entirely. All data is processed as a stream, with the stream processing system (Flink/Kafka Streams) providing both real-time and historical results. Historical data is simply the stream from the beginning of time, replayed on demand. This simplification is possible because modern stream processors (Flink) provide the same correctness guarantees as batch processors (exactly-once, event-time windows, stateful processing). The Kappa architecture reduces operational complexity, unifies the codebase, and eliminates reconciliation latency.

The Kappa architecture has been adopted by companies like Uber (their streaming platform processes trillions of events per day using Flink and Kafka) and Netflix (their data pipeline is built on Kafka Streams and Flink). The Lambda-to-Kappa evolution mirrors the broader trend of stream processing absorbing the capabilities of batch processing, with batch becoming a special case of streaming rather than a separate paradigm.

## 17. Flink Savepoints and State Evolution

Beyond checkpoints (which are automatic and periodic), Flink supports "savepoints" — manually triggered, named checkpoints that support state evolution and job upgrades. A savepoint is a consistent snapshot of the entire job state, written to a durable location (HDFS, S3), that can be used to restart the job later with a different topology or parallelism.

Savepoints enable several critical operational workflows. **Job upgrades**: deploy a new version of the job logic (e.g., adding a new field to the output, changing the window size) and resume from a savepoint, preserving all accumulated state. **Parallelism changes**: stop the job, take a savepoint, and restart with a different parallelism — the savepoint contains state partitioned by the old parallelism, and Flink redistributes it to match the new parallelism on restart. **Cluster migration**: move a job from one Flink cluster to another (e.g., from on-premises to cloud) by taking a savepoint on the old cluster and restoring it on the new cluster. **A/B testing**: take a savepoint, restart twice with different job versions, and compare results for the same input.

The savepoint format is self-describing: it includes a manifest that lists all operators, their state types, and the data in each state descriptor. This allows Flink to perform state migration — when the job code changes and the state schema changes (e.g., a new field is added to a POJO), Flink can automatically migrate the old state to the new schema using serializer evolution (Avro, Protobuf, or Flink's own TypeSerializer evolution). This is essential for long-running streaming jobs that must evolve without losing accumulated state. Savepoints differ from checkpoints in that they are never automatically deleted — they persist until manually removed, serving as named recovery points for operational procedures.

## 18. Kafka's Exactly-Once Semantics: The Idempotent Producer and Transactions

Kafka's exactly-once support (introduced in Kafka 0.11) is implemented through two complementary mechanisms: the idempotent producer and transactions. The idempotent producer ensures that each message is written exactly once to a single partition, even if the producer retries due to network errors. The producer assigns a sequence number to each message within a producer session, and the broker deduplicates messages by sequence number — if a message with a sequence number already committed is received again, the broker silently ignores it.

The transactional producer extends idempotency across multiple partitions. A producer can begin a transaction, write to multiple partitions (potentially across multiple topics), and then commit or abort the transaction. All messages in the transaction become visible atomically — consumers in read-committed mode see either none of the transaction's messages or all of them, never a partial set. The transaction coordinator (a Kafka broker service) manages the transaction state, ensuring that either all partitions commit or all abort, providing the atomicity guarantee across partitions.

Flink's Kafka sink integrates with Kafka transactions by mapping each Flink checkpoint to a Kafka transaction. When a checkpoint completes, Flink commits the corresponding Kafka transaction. If the job fails between checkpoints, the uncommitted transaction is aborted, and consumers see nothing — exactly-once from Flink's perspective. If the job recovers and replays, the new execution produces a new transaction, and consumers eventually see the correct output exactly once. This integration requires Kafka brokers 0.11+ and consumers in read-committed mode, but it provides the strongest exactly-once guarantee available in the streaming ecosystem today.

Under the hood, the Kafka transaction coordinator runs on one of the Kafka brokers (elected via the controller) and manages a transaction log — a compacted internal Kafka topic that stores the state of every ongoing and committed transaction. When a producer begins a transaction, the coordinator assigns a transactional ID and records the transaction start. Each partition write is tagged with the transactional ID and sequence number. On commit, the coordinator writes a commit marker to each partition involved in the transaction; on abort, it writes an abort marker. Consumers in read-committed mode filter messages by checking these markers — messages from aborted transactions are skipped, and messages from ongoing transactions are buffered until the commit marker arrives. This design allows Kafka to provide transactional guarantees without a centralized database: the transaction state is stored in Kafka's own log, replicated like any other topic, and survived by Kafka's built-in leader failover. The transaction coordinator is a replicated service (built on Kafka's own consensus layer, based on KRaft as of Kafka 3.3), meaning there is no single point of failure for transaction management.

## 19. Watermark Propagation and Idleness Detection

Watermarks propagate through the Flink DAG from sources to sinks, but the propagation rules are subtle, especially for operators with multiple inputs. For an operator with two input streams (e.g., a join), the watermark for the operator is the minimum of the watermarks on all inputs. This is correct because the operator must not emit results for time T until it has seen all events with timestamps less than T on all inputs. If one input has a watermark at T=100 and another at T=50, the operator's watermark is 50 — it must wait for the slower input to catch up.

This minimum watermark policy has an important consequence: if one input is idle (no events, no watermarks), the operator's watermark never advances, and windows never complete. Flink addresses this with "idleness detection": if an input stream produces no events and no watermarks for a configurable duration (the "idle timeout"), Flink marks that input as idle and excludes it from the watermark computation. The operator's watermark then advances based on the remaining active inputs. When the idle input resumes, it rejoins the watermark computation from its current watermark value.

Idleness detection is essential for streaming pipelines that join multiple Kafka topics where some topics may have sparse data (e.g., a "user-registrations" topic with few events per hour joined against a "clicks" topic with millions of events per hour). Without idleness detection, the sparse topic would stall the entire pipeline. With idleness detection, the pipeline processes the clicks stream continuously and joins against the latest known user registrations.

## 20. Summary

The combination of Apache Flink and Apache Kafka has defined modern stream processing. Flink's distributed checkpointing, based on Chandy-Lamport snapshots, provides exactly-once state consistency without stopping the data flow. Kafka's durable, ordered, partitioned log provides fault-tolerant event storage. Watermarks solve the event-time vs processing-time dilemma, enabling accurate windowed computations on out-of-order data. Savepoints enable state evolution, schema migration, and operational flexibility. Kafka's transactions and idempotent producer provide the exactly-once sink integration that makes end-to-end correctness possible. The stream-table duality unifies batch and streaming, making batch a special case of the more general streaming paradigm. Streaming is now the default processing model for new applications, and Flink and Kafka are the tools that made it practical at massive scale.

Flink's architecture embodies a broader principle in distributed systems design: separate the concerns of state management, event ordering, and fault tolerance into orthogonal mechanisms, then compose them through well-defined interfaces. The checkpointing protocol handles fault tolerance independently of the watermark mechanism, which handles event-time ordering independently of the Kafka integration, which handles exactly-once sink semantics. This separation of concerns allows each mechanism to be optimized independently while the composition preserves end-to-end correctness. It is a design philosophy that has proven remarkably durable, and it explains why Flink and Kafka, as a combined stack, continue to dominate the streaming landscape even as newer systems emerge.
