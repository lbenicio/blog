---
title: "From MapReduce to Spark: The Arc of Data-Parallel Systems"
description: "MapReduce taught fault-tolerant batch at scale; Spark generalized it with resilient distributed datasets (RDDs) and DAG scheduling."
date: "2025-05-19"
author: "Leonardo Benicio"
tags: ["spark", "mapreduce", "dataproc", "dag"]
categories: ["distributed systems", "data engineering"]
cover: "/static/assets/images/blog/mapreduce-to-spark-modern-data-parallel.png"
---

MapReduce popularized large-scale batch processing with a simple model (map, shuffle, reduce) and immutable intermediate state on HDFS. It optimized for throughput and fault tolerance via re-execution.

Spark expanded the model:

- RDDs: immutable, partitioned datasets with lineage, enabling recomputation on failure.
- DAG scheduler: plans multi-stage jobs, pipelining narrow transformations and materializing wide ones.
- In-memory caching: keeps hot datasets in RAM to accelerate iterative workloads.
- Higher-level APIs: DataFrames/Datasets and SQL, plus MLlib and Structured Streaming.

### Checkpointing and lineage

RDD lineage can grow large; Spark checkpoints to cut recomputation cost. For streaming, write-ahead logs plus checkpoints enable recovery.

### Skew and shuffle

Stragglers often come from data skew. Remedies: salting keys, custom partitioners, or adaptive query execution (AQE) which can coalesce partitions and optimize joins at runtime.

### Code sketch: word count with DataFrames

```python
from pyspark.sql import SparkSession
spark = SparkSession.builder.getOrCreate()
text = spark.read.text("s3://bucket/corpus/")
words = text.selectExpr("explode(split(lower(value), '\\W+')) as word")
counts = words.groupBy("word").count().orderBy("count", ascending=False)
counts.write.mode("overwrite").parquet("s3://bucket/out/")
```

The evolution continues: adaptive engines (AQE), vectorized execution, and lakehouse formats (Parquet, Delta) make modern data-parallel systems far more expressive than plain MapReduce.

---

## 1. MapReduce: Strengths and Structural Limits

### Strengths

1. **Deterministic fault tolerance**: Map outputs materialized to disk (local or HDFS) and can be re-fetched by failed reducers.
2. **Simplicity**: Two-phase API (map → shuffle → reduce) with a clear execution timeline.
3. **Data locality exploitation**: Schedulers place map tasks where HDFS blocks reside.

### Limitations

1. **Rigid two-stage boundary**: Complex pipelines become chains of MapReduce jobs, each incurring full materialization.
2. **Inefficient iterative workloads** (ML, graph): Re-reading data from disk each iteration.
3. **Limited optimization surface**: Without a global DAG, cross-job optimization is impossible.

Result: High reliability & scalability, but at cost of latency and iterative performance.

## 2. RDD Abstraction & Lineage

An RDD is a _logical_ dataset split into partitions; each partition knows how to recompute itself from parent partitions via a lineage graph of transformations (map, filter, union, join...). Fault tolerance arises from replaying only lost partitions instead of checkpointing every intermediate result.

### Narrow vs. Wide Dependencies

| Dependency Type | Parent → Child Mapping                                            | Shuffle Required | Example                       |
| --------------- | ----------------------------------------------------------------- | ---------------- | ----------------------------- |
| Narrow          | Each child partition reads a subset of specific parent partitions | No               | map, filter, mapPartitions    |
| Wide            | Child partition depends on many parent partitions                 | Yes              | groupByKey, reduceByKey, join |

The DAG scheduler groups narrow dependencies into _stages_, inserting shuffle boundaries for wide dependencies. Pipelines inside a stage avoid unnecessary materializations.

### Lineage Truncation

Long lineage chains increase recomputation cost after failure. Spark supports _checkpointing_ (persist to reliable storage) to truncate lineage for very deep or iterative graphs (e.g., PageRank after N iterations). Trade-off: extra I/O cost vs. faster recovery / bounded recompute time.

## 3. Caching & Persistence

RDD/DataFrame caching strategies:

1. **MEMORY_ONLY**: Fast but may evict partitions (recompute cost on eviction).
2. **MEMORY_AND_DISK**: Spills non-fit partitions to disk (prevents recompute storms).
3. **OFF_HEAP / Tachyon-era**: (Historical) external memory layers for sharing across applications.
4. **Serialized vs. deserialized**: Serialized saves memory, deserialized accelerates CPU-bound loops.

Guideline: Cache only if reused; measure the _reuse ratio_. Over-caching increases GC pressure, hurting performance.

## 4. From RDD to DataFrames & Catalyst Optimizer

### Motivation

RDD API is functionally rich but opaque to the optimizer (user functions are black boxes). Catalyst introduces a logical plan algebra enabling rule-based and cost-based transforms.

### Catalyst Phases (Conceptual)

1. **Parsing**: Convert SQL / DSL to unresolved logical plan.
2. **Analysis**: Resolve attributes using catalog (tables, columns, types).
3. **Logical Optimization**: Apply rules (predicate pushdown, constant folding, projection pruning, null propagation).
4. **Physical Planning**: Enumerate candidates (broadcast hash join, sort-merge join, shuffle hash join) with cost estimation.
5. **Code Generation**: Whole-stage codegen merges operators into single Java functions, reducing virtual function / iterator overhead.

### Example Transformation

SQL: `SELECT user, SUM(bytes) FROM logs WHERE day='2025-09-12' GROUP BY user ORDER BY SUM(bytes) DESC LIMIT 10`

1. Filter pushdown partitions only day='2025-09-12'.
2. Projection prunes unused columns.
3. Aggregation planned as hash aggregate (if fits) or sort aggregate.
4. ORDER BY + LIMIT may trigger partial top-K then global merge.

## 5. Tungsten & Whole-Stage Code Generation

Tungsten project delivered memory & CPU efficiency improvements:

1. **Off-heap binary row format**: Minimizes Java object overhead & GC.
2. **Cache-conscious layout**: Sequential memory access improves CPU cache utilization.
3. **Whole-stage codegen**: Fuses operators (filter → project → aggregate) into tight loops; reduces virtual calls & improves branch prediction.
4. **Vectorized readers**: Batch decode of Parquet/ORC into columnar batches lowers per-tuple overhead; SIMD-friendly.

Performance benefit: Significant reduction in CPU time for analytic queries, making Spark competitive with MPP databases for many workloads.

## 6. Shuffle Evolution

Early Spark shuffle wrote map outputs as many small files per reducer—scaling poorly. External shuffle service & consolidated files improved scalability. AQE adds _dynamic partition coalescing_ and _skew join handling_ at runtime:

1. Detect skewed reduce partitions (data size above threshold).
2. Split skewed partition & replicate the smaller side of join for better balance.
3. Coalesce many tiny post-shuffle partitions to reduce scheduling overhead.

Result: Lower straggler tail latency and improved cluster utilization.

## 7. Adaptive Query Execution (AQE)

AQE defers some physical plan decisions until runtime statistics (shuffle file sizes, row counts) are known. Adjustments:

1. Dynamic join strategy selection (switch to broadcast on small dimension table discovered at runtime).
2. Skew partition splitting (as above).
3. Coalesce shuffle partitions (reduce scheduler/coordination overhead).

AQE is particularly impactful for SQL workloads with data skew or unpredictable filters.

## 8. Structured Streaming Internals

Structured Streaming treats a streaming query as an incremental execution of a _static_ logical plan plus stateful updates. Two primary modes:

1. **Micro-batch**: Triggers every N ms; each batch is a mini DataFrame job. Provides natural batch semantics (checkpoint per batch).
2. **Continuous (experimental/limited)**: Low-latency processing with continuous operator execution.

### State Store

Holds aggregates / joins keyed by grouping keys. Backed by local RocksDB or in-memory hash maps; supports checkpointed commit logs. Watermarks prune old state (event-time based) reclaiming memory.

### Exactly-Once Sink Semantics

Achieved via _idempotent sink writing_ (e.g., file sink with atomic commits per batch) or transactional logs (Delta). Offsets + batch IDs recorded in checkpoint dir, ensuring retry safety.

## 9. Lakehouse Integration (Delta / Iceberg / Hudi)

Modern “lakehouse” formats add ACID transactions, schema evolution, and time travel to object stores:

1. **Delta Lake**: Transaction log JSON + Parquet data files; checkpoint compaction of log for fast listing.
2. **Iceberg**: Manifest & snapshot metadata tree; hidden partitioning & equality deletes.
3. **Hudi**: Copy-on-write & merge-on-read tables; delta commit timeline; indexing for upserts.

Spark leverages these to unify batch & streaming: Structured Streaming writes incremental Parquet & atomic metadata updates, enabling exactly-once ingestion semantics.

## 10. Performance Tuning Playbook

| Area               | Symptom                   | Diagnostic                              | Action                                                   |
| ------------------ | ------------------------- | --------------------------------------- | -------------------------------------------------------- |
| Shuffle            | Long tail tasks           | Spark UI stage detail (bytes/task skew) | Salting keys, AQE skew split                             |
| Join Strategy      | Memory pressure / spills  | Task metrics: spill bytes               | Broadcast small side, adjust autoBroadcastJoinThreshold  |
| GC Overhead        | High executor time in GC  | GC logs, Spark UI                       | Increase executor memory, tune memoryFraction, off-heap  |
| Serialization      | High CPU in serialization | Profiler / flame graph                  | Use Kryo, custom serializers, avoid nested small objects |
| Caching            | Recompute of reused DF    | UI shows repeated jobs                  | `persist()` appropriate storage level                    |
| File Listing       | Slow job start            | Driver thread dumps                     | Enable metadata cache, use partition pruning             |
| Small Files        | Many tiny output files    | Object store listing time               | Coalesce/repartition before write, optimize table        |
| Skewed Aggregation | Single hot reducer        | Stage bytes skew metric                 | Pre-aggregate, map-side combine, partial aggregation     |

## 11. Code Generation & UDF Considerations

User Defined Functions (UDFs) can _block optimization_ because Catalyst treats them as black boxes (except for simple Python/Pandas UDF vectorization cases). Alternatives:

1. Express logic in Spark SQL functions (built-ins benefit from codegen).
2. Use SQL expressions with CASE / WHEN for branching.
3. For performance-critical custom code, consider Scala typed Dataset operations enabling some optimization retention.

Pandas UDF (vectorized) reduces serialization overhead but may still underperform pure SQL when scalar operations dominate.

## 12. Resource Management & Scheduling

Cluster managers (YARN, Kubernetes, Standalone) allocate executors; dynamic allocation scales executors based on backlog. Considerations:

1. **Executor sizing**: Too large → long GC pauses; too small → excessive shuffle spill (per-executor memory fragmentation).
2. **Task parallelism**: `spark.default.parallelism` and source partition counts drive initial stage partitioning; tune to balance overhead vs. parallelism.
3. **Locality wait**: Adjust `spark.locality.wait` if tasks spend time waiting for node-local data.
4. **Fair vs. FIFO scheduling**: Multi-tenant clusters may use pools to isolate latency-sensitive jobs.

## 13. Monitoring & Observability

Key metrics:

1. Input rows/sec & processing time (streaming).
2. Shuffle read/write sizes & spill metrics.
3. Executor CPU utilization, JVM heap usage, GC time ratio.
4. Stage failure counts & retried tasks.
5. Metadata ops (table refresh time, catalog latency) for lakehouse heavy workloads.

Tools: Spark UI, History Server, Structured Streaming progress logs (JSON), external APM (OpenTelemetry exporters emerging).

## 14. Case Study (Mini)

Workload: Sessionization + user feature aggregation + join with product dimension + write to Delta nightly + continuous incremental updates hourly.

Problems observed:

1. Long tail reducers during dimension join.
2. Many tiny files (hourly micro-batches) hurting query planning time.
3. High GC in large executors.

Interventions:

1. Enabled AQE skew join splitting; tail 95th percentile task time dropped 40%.
2. Added `OPTIMIZE` (Delta file compaction) daily; planning time -60%.
3. Reduced executor heap size, increased executor count; GC time ratio from 18% → 6%.
4. Migrated Python UDF to SQL built-in expression; stage runtime -25%.

Outcome: SLA latency met (p95 < 8 min), compute cost reduced ~20%.

## 15. Future Directions

Emerging themes:

1. **Query acceleration via GPU**: RAPIDS Accelerator for Spark offloads SQL/DataFrame ops to GPUs (columnar batches + cudf). Bottlenecks shift to shuffle & CPU↔GPU transfers.
2. **Incremental materialized views**: Maintaining pre-computed aggregates with minimal recomputation (Delta Live Tables, Iceberg rewrite plans).
3. **Unified batch + streaming semantic layers**: Continuous tables, streaming joins with snapshot isolation.
4. **Distributed cost-based optimizers**: Sharing runtime stats across stages/jobs for better initial planning.
5. **Data-aware scheduling**: Co-optimizing placement based on column subset usage patterns.

## 16. Further Reading (Titles)

- "Learning Spark: Lightning-Fast Data Analytics" by Holden Karau, Andy Konwinski, Patrick Wendell, Matei Zaharia
- "High Performance Spark" by Holden Karau, Rachel Warren
- "Spark: The Definitive Guide" by Bill Chambers, Matei Zaharia
- "Designing Data-Intensive Applications" by Martin Kleppmann (for broader data architecture & consistency patterns)
- "The Art of Scalability" by Martin L. Abbott, Michael T. Fisher (for distributed systems organizational & scaling principles)

---

## 17. Summary

Spark generalized MapReduce’s batch reliability model into a DAG-based, memory-conscious analytics engine supporting iterative, interactive, and streaming workloads. RDD lineage enabled fine-grained recomputation, while Catalyst + Tungsten closed performance gaps with MPP databases. Modern extensions (AQE, lakehouse formats, structured streaming) continue to blur boundaries between batch and real-time. The strategic shift: treat data processing as an evolving graph with adaptive runtime feedback rather than a fixed two-phase pipeline—unlocking richer optimization and lower latency.

## 17. Summary

Spark generalized MapReduce’s batch reliability model into a DAG-based, memory-conscious analytics engine supporting iterative, interactive, and streaming workloads. RDD lineage enabled fine-grained recomputation, while Catalyst + Tungsten closed performance gaps with MPP databases. Modern extensions (AQE, lakehouse formats, structured streaming) continue to blur boundaries between batch and real-time. The strategic shift: treat data processing as an evolving graph with adaptive runtime feedback rather than a fixed two-phase pipeline—unlocking richer optimization and lower latency.
