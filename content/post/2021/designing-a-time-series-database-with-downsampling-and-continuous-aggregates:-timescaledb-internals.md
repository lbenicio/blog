---
title: "Designing A Time Series Database With Downsampling And Continuous Aggregates: Timescaledb Internals"
description: "A comprehensive technical exploration of designing a time series database with downsampling and continuous aggregates: timescaledb internals, covering key concepts, practical implementations, and real-world applications."
date: "2021-07-23"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/designing-a-time-series-database-with-downsampling-and-continuous-aggregates-timescaledb-internals.png"
coverAlt: "Technical visualization representing designing a time series database with downsampling and continuous aggregates: timescaledb internals"
---

# Designing A Time Series Database With Downsampling And Continuous Aggregates: TimescaleDB Internals

## Introduction

Imagine you are an engineer at a manufacturing plant. You have deployed 10,000 IoT sensors across the factory floor, each reporting temperature, vibration, and pressure at a frequency of 100 Hz. That is one million data points per second. Your task is simple: provide a real-time dashboard for the control room to spot imminent failures, and also allow a data scientist to query “What was the average temperature of machine #7 over the last year, bucketed by hour?”

This is the fundamental paradox of time-series data. The data is born hot, fast, and voluminous, but it must live a long, cold life of historical analysis. The volume required for real-time fidelity is the enemy of the long-range aggregate query. Database administrators have fought this war for decades using a blunt and brittle weapon: the materialized view.

The standard approach in a relational database (PostgreSQL, MySQL, etc.) is to ingest data into a raw table. When the table grows too large—say, beyond a few hundred million rows—queries against it become tragically slow. The classic solution is to write a cron job that runs every hour, aggregates the raw data into a summary table (e.g., hourly averages), and then deletes the raw data older than a week. This works, but it is a house of cards.

If the cron job fails, you lose data or suffer a resource crunch. If you need to change the aggregation function (e.g., from average to percentile), you must drop and rebuild the table. If a sensor malfunctions and you fix it a week later, you cannot backfill the aggregate without replaying all the deleted raw data. You are trading granularity for sanity, but you are losing control.

This is why the topic of this blog post—TimescaleDB’s internal architecture for downsampling and continuous aggregates—is not just an academic exercise. It is a practical survival guide for anyone building a real-world time-series system. TimescaleDB, an open-source time-series database built on PostgreSQL, solves these problems by rethinking the relational model from the ground up. It introduces hypertables, automatic chunking, and continuous aggregates that are refreshed incrementally and automatically. But how does it work under the hood? How does it manage to provide real-time inserts, efficient downsampling, and seamless backfilling without the brittleness of cron jobs?

In this deep dive, we will strip away the abstraction layer and examine the internal machinery. We’ll explore how TimescaleDB partitions data into chunks, how continuous aggregates are materialized and refreshed, how compression works to reduce storage, and how query planning is optimized for time-series workloads. We will walk through concrete examples, SQL code, and pseudo-algorithms to illustrate each concept. By the end, you will have a mental model of TimescaleDB’s internals that allows you to design better schemas, tune performance, and troubleshoot issues.

Let’s begin with the foundational concept that makes everything else possible: the hypertable.

---

## 1. The Challenge of Time-Series Data

Before we dive into TimescaleDB’s solutions, let’s formalize the problem. Time-series data has three defining characteristics:

- **High write volume**: Data arrives continuously and often at high velocity (thousands to millions of rows per second).
- **Append-mostly, but not write-once**: Inserts are append-heavy, but updates and deletes are rare. However, data can be backfilled or corrected.
- **Temporal locality**: Recent data is queried frequently (real-time dashboards), while older data is queried infrequently but at coarser granularity (historical trends).

Traditional relational databases are row-oriented and use B-tree indexes. While B-trees are excellent for point lookups and range scans on low-cardinality keys, they struggle with time-series workloads for several reasons:

- **Index bloat**: Each insert adds a new row, causing B-tree leaf splits and index maintenance. Over time, index size can exceed data size by 2–3x.
- **Write amplification**: Secondary indexes (e.g., on sensor_id + time) require updating multiple B-trees per insert.
- **Vacuum overhead**: PostgreSQL uses MVCC (Multi-Version Concurrency Control) to handle concurrency. Updates create dead tuples that must be cleaned by autovacuum. Even appends generate dead tuples when indexes are updated (HOT updates only work if no indexed columns change, but time columns are indexed). This leads to bloat and performance degradation.

The cron-job approach partially mitigates these issues by keeping the raw table small, but it introduces the problems we mentioned: brittleness, irrecoverable data loss after deletion, and inability to backfill.

TimescaleDB addresses all these pain points by turning PostgreSQL into a purpose-built time-series database without abandoning SQL or the PostgreSQL ecosystem. The key innovation is the _hypertable_.

---

## 2. Hypertables: The Foundation

A hypertable is a PostgreSQL table that is automatically partitioned by time and optionally by space (e.g., sensor*id, device_id). The user creates a hypertable by calling `create_hypertable()` on a regular table. From the user’s perspective, it’s just a table. You can insert, select, join, and create indexes. Behind the scenes, TimescaleDB transparently routes each row to a specific \_chunk* based on the time column.

### 2.1 Chunking

A chunk is a standard PostgreSQL table that stores a subset of the hypertable’s data. Each chunk covers a fixed time interval (e.g., one day, one hour). The interval is configurable and can be adjusted based on data volume. When a new row arrives, TimescaleDB determines which chunk it belongs to using the time value. If the chunk doesn’t exist (because it’s a new time period), TimescaleDB creates it on the fly.

This design has several benefits:

- **Write isolation**: Recent inserts go into the current chunk, which is small and fits in shared buffers. Older chunks are cold and may be compressed or stored on slower storage.
- **Index efficiency**: Each chunk has its own set of indexes. Since chunks are small, index maintenance is localized. When a chunk is older than a certain threshold, its indexes can be dropped or converted to a compressed format.
- **Parallelism**: Queries that span multiple chunks can be parallelized across CPUs. TimescaleDB’s chunk exclusion logic (detailed later) eliminates chunks that are not needed based on WHERE clauses.

### 2.2 Space Partitioning

In addition to time-based partitioning, TimescaleDB supports optional space partitioning. This means you can further subdivide chunks by a hash of another column (e.g., device_id). For example, if you have 1,000 sensors, you can partition by time (daily chunks) and also by sensor_id modulo 4. Each time interval then has up to 4 chunks (one per space partition). This reduces the size of each chunk even further, improving concurrency for high-cardinality workloads.

### 2.3 Chunk Lifetime

Chunks are created automatically as new time intervals are reached. They are also dropped automatically when data exceeds a retention policy (e.g., “keep raw data for 30 days”). TimescaleDB provides functions like `add_retention_policy()` that schedule chunk deletion. This is far safer than a cron job that runs `DELETE FROM raw_data WHERE time < now() - interval '30 days'`. A DELETE would generate massive dead tuples and vacuum overhead. Dropping an entire chunk is a metadata operation that is instantaneous and leaves no bloat.

### 2.4 Example: Creating a Hypertable

```sql
-- Create a normal PostgreSQL table
CREATE TABLE sensor_data (
    time TIMESTAMPTZ NOT NULL,
    sensor_id INTEGER NOT NULL,
    temperature DOUBLE PRECISION,
    vibration DOUBLE PRECISION,
    pressure DOUBLE PRECISION
);

-- Convert to hypertable, partitioned by time (1-day chunks)
SELECT create_hypertable('sensor_data', 'time', chunk_time_interval => INTERVAL '1 day');

-- Optionally space-partition by sensor_id (4 partitions)
SELECT add_dimension('sensor_data', 'sensor_id', number_partitions => 4);
```

Now, inserts are routed automatically:

```sql
INSERT INTO sensor_data VALUES (now(), 7, 23.5, 0.12, 101.3);
-- TimescaleDB routes to the chunk covering today and sensor_id hash partition.
```

Chunks are created invisibly. You can inspect them:

```sql
SELECT * FROM timescaledb_information.chunks WHERE hypertable_name = 'sensor_data';
```

This will show chunks like `_hyper_1_1_chunk` (covering 2025-03-20), `_hyper_1_2_chunk` (2025-03-21), etc.

---

## 3. Continuous Aggregates: Real-Time Downsampling

Now we arrive at the heart of the post: continuous aggregates. If hypertables solve the problem of managing large volumes of raw data, continuous aggregates solve the problem of querying that data at coarser time granularities.

Continuous aggregates (caggs) are materialized views that are refreshed automatically and incrementally as new data arrives. Unlike traditional materialized views that require a full refresh (or a complex incremental mechanism), TimescaleDB’s caggs use a bookmark-based refresh strategy that is both efficient and transparent.

### 3.1 The Problem with Traditional Materialized Views

Consider a standard PostgreSQL materialized view that computes hourly averages:

```sql
CREATE MATERIALIZED VIEW hourly_avg AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    sensor_id,
    AVG(temperature) AS avg_temp,
    COUNT(*) AS num_readings
FROM sensor_data
GROUP BY bucket, sensor_id;
```

To refresh, you run:

```sql
REFRESH MATERIALIZED VIEW hourly_avg;
```

This locks the view and recomputes the entire aggregation from scratch. On a table with billions of rows, this could take hours and consume enormous resources. You cannot query the view while it’s refreshing (in most cases). And if you only want to add the latest hour’s data, you still have to scan everything.

### 3.2 How Continuous Aggregates Work

Continuous aggregates solve this by maintaining a **materialization hypertable** (the actual storage for the aggregated data) and a **watermark** that tracks how far the aggregation has been computed. The cagg is defined with a `time_bucket` (e.g., 1 hour) and one or more aggregation functions (e.g., avg, sum, count, min, max). TimescaleDB stores the result in chunks, just like a hypertable, but each chunk covers a time range that matches the bucket size.

The refresh process is incremental. TimescaleDB maintains a **refresh window** – a range of raw data that has been processed. When new raw data is inserted, a background worker periodically checks if there are new tuples beyond the watermark. It reads those tuples, aggregates them into buckets, and upserts the results into the cagg’s backing hypertable. This is called a **partial refresh** or **incremental refresh**.

Additionally, you can configure a **refresh lag** – a delay to allow late-arriving data (e.g., data that arrives a few minutes late). For example, you might refresh everything up to `now() - interval '10 minutes'` to avoid missing stragglers.

### 3.3 Defining a Continuous Aggregate

Here’s how you define a cagg that computes hourly averages:

```sql
CREATE MATERIALIZED VIEW hourly_avg
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    sensor_id,
    AVG(temperature) AS avg_temp,
    COUNT(*) AS num_readings
FROM sensor_data
GROUP BY bucket, sensor_id;
```

Note the `WITH (timescaledb.continuous)` clause. This tells TimescaleDB to treat this materialized view as a continuous aggregate. Under the hood, it creates a hidden hypertable (often named `_materialized_hypertable_<id>`) to store the aggregated data. You can query the view just like any other table:

```sql
SELECT * FROM hourly_avg
WHERE bucket >= now() - INTERVAL '7 days'
ORDER BY bucket, sensor_id;
```

### 3.4 Automatic Refresh Scheduling

By default, TimescaleDB sets up a background job that refreshes the cagg periodically (every few minutes). You can see and modify the policy:

```sql
SELECT add_continuous_aggregate_policy('hourly_avg',
    start_offset => INTERVAL '1 day',
    end_offset => INTERVAL '30 minutes',
    schedule_interval => INTERVAL '5 minutes');
```

- `start_offset`: How far back to refresh. Setting a small start_offset means you only refresh recent data. For a cagg that needs to be fully up-to-date, you might set start_offset to `NULL` (meaning refresh all data).
- `end_offset`: How far before now to stop refreshing (to avoid late-arriving data).
- `schedule_interval`: How often the refresh job runs.

The background worker tracks the watermark. When it wakes up, it computes the new raw data range `[min_new_time, max_new_time)` based on the watermark and inserts/updates the corresponding cagg buckets on the materialization hypertable.

### 3.5 Backfilling Historical Data

One of the most powerful features of continuous aggregates is the ability to **backfill**. Suppose you had a cagg defined for hourly averages, but you later add a new aggregation (e.g., `MAX(pressure)`). Or suppose you fix a bug in a sensor that caused incorrect readings for the past week. You can re-refresh the cagg for any time range:

```sql
-- Refresh a specific range
CALL refresh_continuous_aggregate('hourly_avg', '2025-03-01', '2025-03-15');
```

This will scan the raw data in that range, recompute the aggregates, and upsert the results. The operation is efficient because it only touches the relevant chunks (both raw and materialized). And it does not require dropping the entire view.

---

## 4. Downsampling: From Seconds to Months

Downsampling is the process of converting high-frequency data into lower-frequency summaries. Continuous aggregates are the primary mechanism for this. But TimescaleDB supports multiple levels of downsampling. You can create a cascade:

- Raw table: 1-second resolution, retained for 7 days.
- Hourly aggregates: retained for 1 year.
- Daily aggregates: retained for 5 years.
- Monthly aggregates: retained indefinitely.

Each level is a continuous aggregate that queries the previous level (or directly the raw table). For example:

```sql
CREATE MATERIALIZED VIEW daily_avg
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', bucket) AS day_bucket,
    sensor_id,
    AVG(avg_temp) AS daily_avg_temp,
    SUM(num_readings) AS total_readings
FROM hourly_avg
GROUP BY day_bucket, sensor_id;
```

Note: Be careful when rolling up averages. If you average of averages, you need to weight by count. The correct approach is to store `sum` and `count` (as seen) and then compute the final average as `SUM(avg_temp * num_readings) / SUM(num_readings)`. TimescaleDB provides a `first`, `last`, and `last` aggregate to handle such cases. Also, you can use the `stats_agg` function for more complex statistics.

### 4.1 Policy for Downsampling with Retention

You can set up automatic policies to drop raw data after 7 days, hourly aggregates after 1 year, etc. The `add_retention_policy` works on any hypertable (including the backing hypertable of caggs). For example:

```sql
-- Keep raw data for 7 days
SELECT add_retention_policy('sensor_data', INTERVAL '7 days');

-- Keep hourly aggregates for 1 year (the cagg is also a hypertable)
SELECT add_retention_policy('hourly_avg', INTERVAL '1 year');
```

This creates background jobs that drop old chunks. Again, this is far more efficient than DELETE.

---

## 5. Internal Implementation: How Continuous Aggregates Work Under the Hood

Now let’s get into the nitty-gritty of the implementation. This section will cover the data structures, background workers, watermark management, and upsert logic.

### 5.1 Materialization Hypertable

When you create a continuous aggregate, TimescaleDB:

1. Creates a hypertable (the materialization hypertable) with columns: `time_bucket`, the grouping columns (e.g., sensor_id), and the aggregate columns (e.g., avg_temp, num_readings). The chunk interval is set to match the `time_bucket` interval.
2. Creates an index on `(time_bucket, grouping_columns)` to support efficient upserts and point queries.
3. Creates a watermark table (usually an entry in `_timescaledb_catalog.continuous_agg`) that tracks the maximum raw time processed.

The materialization hypertable is a normal hypertable in every sense. You can inspect its chunks, compression, etc.

### 5.2 Refresh Algorithm

The refresh job (background worker) follows these steps:

1. **Read watermark**: `SELECT watermark FROM _timescaledb_catalog.continuous_agg WHERE id = <cagg_id>`.
2. **Determine refresh window**: The window is [watermark, now() - end_offset). If `start_offset` is set, the window is limited to [watermark, max(watermark+something, now() - start_offset)]? Actually, the policy parameters specify the range to refresh. The watermark moves forward.
3. **Scan raw data**: Run a query on the raw hypertable that reads all rows where `time >= watermark AND time < now() - end_offset`, grouping by time bucket and group columns.
4. **Combine with existing data**: For each bucket+group that exists in the materialization hypertable, update the aggregate values (e.g., new average = weighted average of old and new, new count = old count + new count). For new buckets, insert.
5. **Advance watermark**: Set watermark to the maximum time processed (usually `now() - end_offset` if the refresh covered everything up to that point).

This algorithm is O(N) where N is the number of new rows since last refresh. It does not require scanning old raw data that has already been processed.

### 5.3 Handling Partial Aggregates

TimescaleDB stores partial aggregates that allow combining. For `AVG`, it actually stores `SUM(temperature)` and `COUNT(*)` separately. When merging a new aggregate with an existing one, it adds the sums and counts. For `MIN`/`MAX`, it takes the min/max of the values. For `STDDEV`, it uses a more complex accumulator (Welford’s algorithm). This is why you often see the internal naming like `_timescaledb_functions.avg` – they are custom aggregate functions that support partial aggregation.

### 5.4 Chunk Exclusion in Queries

When you query a continuous aggregate with a WHERE clause on the time column (bucket), TimescaleDB applies the same chunk exclusion logic as for regular hypertables. Since the materialization hypertable is partitioned by `time_bucket`, the planner can quickly eliminate chunks that fall outside the query range. This makes queries on caggs extremely fast, even on terabyte-scale datasets.

Additionally, if you query the raw hypertable, TimescaleDB can use the watermark to optimize: if the query range is entirely within the region that has been materialized? Not directly, but the planner can leverage statistics.

---

## 6. Compression: Reducing Storage Footprint

Time-series data is regularly compressed because of its repetitive nature. TimescaleDB offers native compression that works on individual chunks. When a chunk is older than a certain threshold (e.g., 7 days), it can be compressed. Compression can reduce storage by 90–95% for many real-world datasets.

### 6.1 How Compression Works

TimescaleDB uses a columnar compression algorithm. It does not use PostgreSQL’s built-in TOAST compression (which is row-based). Instead, it reorders data within a chunk into columns and applies various compression techniques:

- **Delta-of-delta encoding** for timestamps (since they are monotonically increasing).
- **Run-length encoding** for low-cardinality columns (e.g., sensor_id, tags).
- **XOR compression** for floating-point numbers (similar to Gorilla encoding from Facebook’s Gorilla TSDB).
- **Dictionary compression** for strings.

The compressed data is stored in a special format within the table’s pages. Additionally, indexes are dropped on compressed chunks (or converted to minimal bitmap indexes). This further saves space.

### 6.2 Enabling Compression

To enable compression on a hypertable:

```sql
ALTER TABLE sensor_data SET (timescaledb.compress, timescaledb.compress_segmentby = 'sensor_id', timescaledb.compress_orderby = 'time DESC');
```

Then you create a compression policy:

```sql
SELECT add_compression_policy('sensor_data', INTERVAL '7 days');
```

This will compress all chunks older than 7 days. You can also manually compress:

```sql
SELECT compress_chunk('_hyper_1_1_chunk');
```

### 6.3 Impact on Queries

Compressed chunks can still be queried transparently. TimescaleDB decompresses the required data on the fly. However, queries on compressed chunks may be slightly slower due to decompression overhead. In practice, the reduction in I/O far outweighs the CPU cost for large scans. For point queries (e.g., get last hour’s data), the recent uncompressed chunk is used.

### 6.4 Downsampling + Compression

Continuous aggregates themselves can also be compressed. For example, the hourly_avg cagg can have its own compression policy, retaining detailed aggregates for a few months and compressing older ones. This allows a tiered storage strategy:

- **Hot tier**: Raw data (uncompressed, 7 days).
- **Warm tier**: Hourly aggregates (uncompressed, 30 days).
- **Cold tier**: Hourly aggregates (compressed, 1 year).
- **Frozen tier**: Daily aggregates (compressed, 5 years).

TimescaleDB’s chunk-based approach makes this straightforward: each tier is a separate hypertable (or cagg) with its own retention and compression policies.

---

## 7. Query Performance: How TimescaleDB Optimizes

Beyond chunk exclusion, TimescaleDB employs several optimizations for time-series queries.

### 7.1 Constraint Exclusion

When you query a hypertable with a WHERE clause on the time column, TimescaleDB inspects the chunk constraints (min_time, max_time). If a chunk does not overlap the query range, it is excluded from the query plan. This is similar to PostgreSQL’s inheritance constraint exclusion, but implemented more efficiently.

### 7.2 Parallelized Chunk Scans

For queries that need to scan many chunks, TimescaleDB can use PostgreSQL’s parallel query capabilities. Each chunk can be scanned by a separate worker. The number of workers is limited by `max_parallel_workers_per_gather`, but TimescaleDB can schedule scans across multiple chunks on different processes.

### 7.3 Custom Index Types

Time-series queries often benefit from BRIN (Block Range INdex) indexes rather than B-tree. BRIN indexes are lightweight and ideal for append-only data because they maintain min/max per block range. TimescaleDB recommends using B-tree for primary keys (e.g., sensor_id) and BRIN for time columns. Example:

```sql
CREATE INDEX idx_time_brin ON sensor_data USING BRIN (time);
CREATE INDEX idx_sensor_btree ON sensor_data USING BTREE (sensor_id, time);
```

### 7.4 Sequential Scans on Compressed Data

When a chunk is compressed, TimescaleDB’s custom scan node can decompress only the columns needed. This reduces memory bandwidth. Also, because compression is columnar, it can apply filters before decompressing (e.g., skip a compressed column entirely if not needed).

### 7.5 Aggregation Pushdown

For queries that compute aggregates (like AVG, SUM) over a time range, TimescaleDB can push the aggregation down to the compressed or raw chunks. If the chunk is compressed, it can compute the aggregate directly on the compressed representation (if the compression algorithm supports it – currently not fully, but partial aggregates from caggs are already precomputed). This is why using continuous aggregates is so much faster: the aggregation is already done.

---

## 8. Advanced Features: Gapfilling, Last Point, and More

TimescaleDB provides several convenience functions for time-series analysis.

### 8.1 Gapfilling

Time-series data often has irregular timestamps. TimescaleDB’s `time_bucket_gapfill` function allows you to fill in missing time buckets with interpolated or constant values. For example:

```sql
SELECT
    time_bucket_gapfill('1 hour', time) AS bucket,
    LOCF(AVG(temperature)) AS avg_temp
FROM sensor_data
WHERE time >= '2025-03-01' AND time < '2025-03-02'
GROUP BY bucket
ORDER BY bucket;
```

`LOCF` (Last Observation Carried Forward) fills gaps with the last non-null value. Other options include linear interpolation.

### 8.2 Last Observation per Unique

The `last()` and `first()` aggregates (and `timevector` functions) allow you to get the most recent value for each sensor, which is common for dashboards.

### 8.3 Hyperfunctions

TimescaleDB 2.x+ includes a set of custom functions called _hyperfunctions_ that are optimized for time-series: `stats_agg`, `rollup`, `approx_percentile`, `time_bucket`, etc. These are implemented as PostgreSQL aggregates and can be used in continuous aggregates.

---

## 9. Real-World Example: End-to-End Pipeline

Let’s put everything together in a concrete scenario. We’ll design a full pipeline for the factory IoT system.

### 9.1 Schema Design

```sql
-- Raw table
CREATE TABLE sensor_data (
    time TIMESTAMPTZ NOT NULL,
    sensor_id INTEGER NOT NULL,
    temperature DOUBLE PRECISION,
    vibration DOUBLE PRECISION,
    pressure DOUBLE PRECISION
);

-- Convert to hypertable, 1-day chunks, 4 space partitions
SELECT create_hypertable('sensor_data', 'time', chunk_time_interval => INTERVAL '1 day');
SELECT add_dimension('sensor_data', 'sensor_id', number_partitions => 4);

-- Indexes: BRIN on time, B-tree on sensor_id + time for point lookups
CREATE INDEX idx_sensor_data_time ON sensor_data USING BRIN (time);
CREATE INDEX idx_sensor_data_sensor_time ON sensor_data USING BTREE (sensor_id, time DESC);
```

### 9.2 Continuous Aggregates for Hourly and Daily

```sql
-- Hourly aggregates (retain 1 year)
CREATE MATERIALIZED VIEW hourly_avg
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    sensor_id,
    AVG(temperature) AS avg_temp,
    MAX(temperature) AS max_temp,
    MIN(temperature) AS min_temp,
    AVG(vibration) AS avg_vibration,
    COUNT(*) AS num_readings
FROM sensor_data
GROUP BY bucket, sensor_id;

-- Daily aggregates (retain 5 years)
CREATE MATERIALIZED VIEW daily_avg
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', bucket) AS day_bucket,
    sensor_id,
    AVG(avg_temp) AS avg_temp,
    MAX(max_temp) AS max_temp,
    MIN(min_temp) AS min_temp,
    AVG(avg_vibration) AS avg_vibration,
    SUM(num_readings) AS total_readings
FROM hourly_avg
GROUP BY day_bucket, sensor_id;
```

### 9.3 Policies

```sql
-- Retention policies
SELECT add_retention_policy('sensor_data', INTERVAL '7 days');
SELECT add_retention_policy('hourly_avg', INTERVAL '365 days');
SELECT add_retention_policy('daily_avg', INTERVAL '1825 days');

-- Compression policies (compress raw after 2 days, hourly after 30 days)
SELECT add_compression_policy('sensor_data', INTERVAL '2 days');
SELECT add_compression_policy('hourly_avg', INTERVAL '30 days');
SELECT add_compression_policy('daily_avg', INTERVAL '365 days');

-- Refresh policies for caggs (every 5 minutes, with 10-minute lag)
SELECT add_continuous_aggregate_policy('hourly_avg',
    start_offset => NULL,
    end_offset => INTERVAL '10 minutes',
    schedule_interval => INTERVAL '5 minutes');
SELECT add_continuous_aggregate_policy('daily_avg',
    start_offset => NULL,
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes');
```

### 9.4 Querying

A real-time dashboard pulls last 15 minutes of raw data:

```sql
SELECT * FROM sensor_data
WHERE time > now() - INTERVAL '15 minutes'
ORDER BY time DESC;
```

A data scientist queries average temperature over last year by day:

```sql
SELECT day_bucket, sensor_id, avg_temp, max_temp
FROM daily_avg
WHERE day_bucket >= now() - INTERVAL '365 days'
  AND sensor_id = 7
ORDER BY day_bucket;
```

This query hits only the daily_avg cagg, which may be compressed and in a small number of chunks. It returns results in milliseconds.

---

## 10. Conclusion

The manufacturing plant engineer’s paradox – real-time fidelity versus long-range historical analysis – is no longer a trade-off that must be managed with brittle cron jobs and manual data deletion. TimescaleDB’s internal architecture, built on hypertables, continuous aggregates, compression, and intelligent chunk management, provides a robust, declarative, and performant solution.

We have seen how hypertables automatically partition data into manageable chunks, enabling high write throughput and efficient retention. Continuous aggregates allow you to define downsampling pipelines that are refreshed incrementally, without the overhead of full materialized view refreshes and without losing the ability to backfill. Compression reduces storage costs dramatically, while chunk exclusion and parallel scans keep queries fast. And all of this is achieved with standard PostgreSQL SQL, preserving the rich ecosystem of tools, drivers, and extensions.

The key takeaway is this: time-series databases like TimescaleDB are not simply “PostgreSQL with an index tuned for time.” They are a fundamental rethinking of how relational storage and query execution can be optimized for the unique characteristics of time-stamped data. By understanding the internals – the chunk creation, the watermark advancing, the upsert merging, the columnar compression – you gain the ability to design efficient schemas, tune performance, and troubleshoot issues that would otherwise remain mysterious.

Whether you are monitoring IoT sensors, tracking financial markets, or analyzing application logs, the principles discussed here apply universally. TimescaleDB’s design serves as a case study in building a domain-specific database that leverages the power of a general-purpose engine while adding specialized extensions. For any engineer dealing with time-series data at scale, understanding these internals is not just nice to have – it’s essential.

Now go forth, create hypertables, define continuous aggregates, and let the background workers handle the rest. Your dashboard will thank you, and your data scientist will finally get that year-long hourly average in seconds.
