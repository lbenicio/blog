---
title: "Columnar Storage: Parquet Encoding, ORC Stripe Format, Apache Arrow In-Memory Columnar Format, Predicate Pushdown, and SIMD Scans"
description: "A deep exploration of columnar data formats — how Parquet and ORC organize data column-by-column for efficient analytics, Apache Arrow's in-memory representation for zero-copy data interchange, and the vectorized execution that makes modern query engines fast."
date: "2021-07-03"
author: "Leonardo Benicio"
tags: ["columnar-storage", "parquet", "orc", "apache-arrow", "olap", "analytics", "simd"]
categories: ["systems", "data-systems"]
draft: false
cover: "/static/assets/images/blog/columnar-storage-parquet-orc-apache-arrow.png"
coverAlt: "A stylized visualization contrasting row-oriented and column-oriented data layouts, with column chunks, stripes, and SIMD vectorized scans on compressed column data"
---

In 2010, Google published a paper on Dremel, an interactive query engine that could scan terabytes of data in seconds. The secret was a columnar storage format: instead of storing rows of data together (as traditional databases do), Dremel stored each column separately. A query that needed only two columns from a table with 100 columns could read just those two columns, reducing I/O by 50x. This insight — that analytical queries access only a subset of columns but scan most rows — launched the columnar storage revolution. Apache Parquet, Apache ORC, and Apache Arrow are the modern inheritors of this tradition, and together they power the analytical data infrastructure of virtually every large tech company. This post explores how columnar storage works, from the encoding formats that compress data to a fraction of its original size to the SIMD vectorized scans that process billions of values per second.

## 1. The Row vs Column Layout

In a row-oriented format (like PostgreSQL's heap storage or MySQL's InnoDB), all columns of a row are stored contiguously on disk. Row 1's id, name, age, and city are followed by Row 2's id, name, age, and city. This layout is efficient for transactional workloads (OLTP): fetching a single row by its primary key requires one disk read (or a few reads if the row spans multiple blocks), and inserting a new row is a simple append to the end of the table.

In a column-oriented format (like Parquet or ORC), each column is stored separately. All values of column "id" are stored together, followed by all values of column "name," and so on. This layout is efficient for analytical workloads (OLAP): a query that computes the average age of users in a city reads only the "age" and "city" columns, ignoring all other columns. The I/O savings are proportional to the fraction of columns accessed — a query accessing 2 of 100 columns reads only 2% of the data.

Columnar storage also enables better compression. Values within a column tend to be similar (the "city" column contains repeated values like "New York," "Los Angeles," "Chicago"), which enables run-length encoding, dictionary encoding, and delta encoding. Row-oriented storage mixes different data types within each row, which limits compression effectiveness.

## 2. Parquet: Dremel's Columnar Format, Open-Sourced

Apache Parquet, created by Twitter and Cloudera in 2013, is an open-source implementation of Google's Dremel columnar format. Parquet files are organized into "row groups" — horizontal partitions of the data, typically containing 10,000 to 1,000,000 rows. Within each row group, each column is stored as a "column chunk," which is divided into "pages" (typically 8 KB to 1 MB). Pages are the unit of compression and encoding.

Parquet's encoding schemes are its secret weapon. For each column chunk, Parquet chooses the most effective encoding based on the data's characteristics:

- **Dictionary encoding**: Build a dictionary of distinct values, and store dictionary indices instead of the values. If the "city" column has only 1,000 distinct values across a billion rows, each value can be encoded as a 2-byte index (instead of a 20-byte string), achieving 10x compression.

- **Run-length encoding (RLE)**: Store runs of repeated values as (value, count) pairs. If a column is sorted, runs can be very long, achieving near-perfect compression.

- **Delta encoding**: Store the difference between consecutive values. If a timestamp column increments by a few seconds per row, deltas are small integers that compress well.

- **Bit packing**: For boolean columns or low-cardinality integer columns, pack multiple values into a single byte or integer. A column of 32-bit integers with values only 0-7 can be stored as 3-bit values, achieving 10x compression.

Parquet also stores statistics for each column chunk: minimum and maximum values, null count, and (optionally) bloom filters. These statistics enable "predicate pushdown" — the query engine can skip entire row groups if the statistics show that no matching rows exist. If a query filters for `age > 65`, and a row group's maximum age is 50, that row group is skipped entirely, saving I/O and CPU.

## 3. ORC: The Hive-Optimized Columnar Format

Apache ORC (Optimized Row Columnar), developed by Hortonworks (now part of Cloudera) for Apache Hive, is another columnar format with a similar architecture but different design choices. ORC files are organized into "stripes" (typically 250 MB), each containing index data, row data, and a stripe footer with statistics.

ORC's key innovation is its lightweight indexing. Each stripe includes a set of "streams" (column-specific data streams), and each stream is divided into "index groups" (typically every 10,000 rows). The stripe footer contains min/max statistics for each index group, enabling fine-grained predicate pushdown. The query engine can skip individual index groups (not just entire stripes or row groups) based on the statistics.

ORC also supports ACID transactions on Hive tables. Each ORC file includes a "delta" directory that records insert, update, and delete operations. Readers merge the base data and the deltas at read time, providing snapshot isolation without rewriting the base files. This makes ORC suitable for slowly-changing dimension tables and streaming ingest workloads, not just static analytical datasets.

## 4. Apache Arrow: Columnar In-Memory for Zero-Copy Interchange

Apache Arrow, initiated by Wes McKinney (creator of pandas) in 2016, addresses a different problem: data interchange. Parquet and ORC are disk formats, optimized for storage efficiency. Arrow is an in-memory format, optimized for computation efficiency. The key insight is that every analytical system (pandas, Spark, Impala, Presto, Dremio) has its own internal memory representation. Moving data between systems requires serialization (converting from one format to another), which is a bottleneck — 80-90% of data processing time is often spent on serialization and deserialization.

Arrow defines a standardized in-memory columnar format that all systems can use directly. A DataFrame in pandas, a table in Spark, and a dataset in Dremio can all share the same Arrow buffers without conversion. This "zero-copy" data interchange eliminates serialization overhead and enables a new class of composable analytical systems.

Arrow's memory layout is carefully designed for SIMD (Single Instruction, Multiple Data) operations. Columns are stored as contiguous arrays of fixed-width values (for numeric types) or as arrays of offsets + variable-length data (for strings and binary data). The contiguous layout allows the CPU to load multiple values into SIMD registers (256-bit AVX2 or 512-bit AVX-512) and process them in parallel. A column of 32-bit integers can be summed with AVX2 instructions processing 8 values per instruction, achieving near-memory-bandwidth throughput.

Arrow also defines a "record batch" — a collection of equal-length column arrays that together represent a table. Record batches are the unit of data exchange between Arrow-based systems. They can be serialized over the network (Arrow Flight protocol, based on gRPC) or shared between processes via memory-mapped files (Arrow Plasma store).

## 5. Predicate Pushdown and Vectorized Execution

Columnar storage enables two key query optimization techniques: predicate pushdown and vectorized execution.

Predicate pushdown uses column statistics to skip data without reading it. When a query contains a filter (`WHERE city = 'NYC'`), the query engine checks the statistics for each row group or stripe. If the statistics show that the filter cannot match any row in that segment, the segment is skipped. This is "partition pruning" at the storage level — the query engine reads only the fraction of data that could contain matching rows.

Vectorized execution processes data in batches (typically 1,024 to 8,192 rows at a time) rather than row by row. Each operator (filter, project, aggregate) processes a batch of values at once, using tight loops that are cache-friendly and amenable to compiler auto-vectorization. The JIT compilers in modern query engines (like Impala's LLVM JIT or Spark's WholeStageCodeGen) can generate specialized machine code for each batch operation, achieving near-hand-written-assembly performance.

The combination of columnar storage, predicate pushdown, and vectorized execution enables modern query engines to scan terabytes of data in seconds. Google's BigQuery, Amazon Redshift, Snowflake, and Databricks all use columnar formats (Parquet or similar) with vectorized execution to achieve the performance that Dremel pioneered.

## 6. Summary

Columnar storage — Parquet on disk, Arrow in memory, ORC with ACID support — has transformed analytical data processing. The shift from row-oriented to column-oriented storage, driven by the observation that analytical queries access only a few columns but many rows, has yielded order-of-magnitude improvements in query performance and storage efficiency. Modern encoding techniques (dictionary encoding, run-length encoding, delta encoding) achieve compression ratios of 5-20x compared to uncompressed row storage. Predicate pushdown using column statistics eliminates I/O for irrelevant data. Vectorized execution exploits SIMD instructions to process billions of values per second per core.

The columnar ecosystem — Parquet for persistent storage, Arrow for in-memory computation, ORC for transactional Hive tables — has converged on a common set of principles: separate columns, compress aggressively, index lightly, and execute in batches. These principles, first articulated in Google's Dremel paper in 2010, now power virtually every cloud data warehouse, data lake query engine, and interactive analytics platform. Columnar storage is not just a format; it's the foundation of modern analytical data infrastructure.

## 7. The Dremel Record Shredding Algorithm

Google's Dremel paper introduced the "record shredding" algorithm for representing nested, repeated data in columnar format. Nested data (Protobuf messages with submessages, optional fields, and repeated fields) doesn't fit naturally into a flat columnar layout. Dremel's solution is to shred the nested structure into multiple columns, each storing the values at one level of the hierarchy, with "repetition levels" and "definition levels" to encode the nesting structure.

A repetition level indicates at which repeated field in the hierarchy a value repeats. For example, in a schema `message Document { repeated Sentence { required string word; } }`, a word that starts a new sentence has repetition level 1 (the Sentence field repeats); a word that continues the same sentence has repetition level 0 (the word field repeats within the same Sentence). The definition level indicates how many optional fields in the path are actually present (non-null).

Parquet implements a simplified version of the Dremel shredding algorithm. Nested fields are stored in separate column chunks, and the repetition and definition levels are encoded alongside the values. This allows analytical queries to efficiently project nested fields (e.g., extracting all words from all sentences in all documents) without reading the surrounding structure. The query engine can skip over fields that aren't needed, reading only the columns relevant to the query.

## 8. Integration with Query Engines: The Connector Pattern

Columnar formats achieve their full potential only when integrated with query engines that can exploit columnar access patterns. Modern query engines (Presto, Trino, Spark, Impala) use a "connector" model where the storage format is abstracted behind a common interface. A Parquet connector reads Parquet files, prunes row groups based on statistics, and feeds column batches to the query engine's execution layer. An Arrow connector (via Arrow Flight) streams Arrow record batches directly into the query engine's memory, avoiding serialization overhead.

The connector model has enabled a rich ecosystem of interoperable tools. A data pipeline can write data in Parquet format to a data lake (S3, HDFS), and multiple query engines (Spark for ETL, Presto for interactive queries, Dremio for data exploration) can read the same Parquet files, each exploiting columnar access patterns for their specific workload. The Parquet format serves as the "lingua franca" of data storage, decoupling the storage layer from the compute layer.

## 9. Compression in Columnar Formats: Beyond General-Purpose Algorithms

Columnar formats exploit the homogeneity of column data to achieve compression ratios far beyond what general-purpose algorithms (gzip, zstd, snappy) can achieve on row-oriented data. The key insight is that values within a column have a limited domain (e.g., the "country" column has perhaps 200 distinct values) and often exhibit patterns (sorted, sequential, repeated).

Parquet's encoding pipeline applies multiple encodings in sequence: dictionary encoding first (replace values with indices), then run-length encoding on the indices (if the data is sorted, the indices form long runs), then bit packing (store the RLE pairs in compact bit-aligned format), and finally general-purpose compression (snappy/gzip/zstd) on the encoded page. Each step exploits a different property of the data, and the combination achieves 5-20x compression for typical analytical datasets.

Delta encoding for timestamps is particularly effective. A column of timestamps at microsecond granularity (e.g., 2024-01-15 10:30:00.123456, 2024-01-15 10:30:01.234567, etc.) stored as 64-bit integers takes 8 bytes per value. Delta encoding stores the first value as a full 64-bit integer, then stores each subsequent value as the difference from the previous value. If the timestamps are roughly 1 second apart (1,000,000 microseconds), the deltas are around 1,000,000, which fit in 20 bits. Storing 20-bit values instead of 64-bit values achieves 3.2x compression even before applying general-purpose compression. Delta-of-delta encoding stores the difference between consecutive deltas (which are themselves small if the data is regularly spaced), achieving even better compression.

## 10. Query Optimization with Columnar Statistics

Column statistics — stored in Parquet file footers, ORC stripe footers, and Arrow schema metadata — enable the query optimizer to make informed decisions about how to execute a query. Min/max statistics enable "predicate pushdown": if a query filters for `age > 65`, and a row group's maximum age is 50, the entire row group can be skipped. Bloom filters (optional in Parquet) provide probabilistic set membership tests: a bloom filter for the "user_id" column can quickly answer "is user_id=12345 in this row group?" with a small probability of false positives.

Column cardinality statistics (number of distinct values) guide join order optimization. If the "orders" table has 1 billion rows but only 10,000 distinct customer IDs, while the "customers" table has 10,000 rows (one per customer), the optimizer knows that these tables are roughly the same size after filtering and can choose an appropriate join strategy (hash join on the customer ID). Without statistics, the optimizer might incorrectly estimate the join size and choose a suboptimal strategy.

Null count statistics help the optimizer avoid unnecessary work. If a query filters for `WHERE middle_name IS NOT NULL`, and the statistics show that 95% of rows have null middle names, the optimizer can estimate that only 5% of data needs to be read and adjust resource allocation accordingly. Modern query engines (Trino, Impala, Spark 3.x) make heavy use of column statistics for cost-based optimization.

## 11. The Parquet Community and Ecosystem

Apache Parquet has become the de facto standard for columnar storage in the big data ecosystem. It is supported by virtually every data processing engine: Apache Spark (native Parquet reader/writer), Apache Hive (via Parquet-Hive), Apache Impala (native Parquet support), Presto/Trino (high-performance Parquet reader), Apache Drill (schema-free Parquet queries), Dremio (Apache Arrow-based Parquet queries), DuckDB (embedded analytical database with excellent Parquet support), and pandas (Python data analysis with `pd.read_parquet`).

The Parquet format is governed by the Apache Parquet PMC (Project Management Committee), which oversees the specification and the reference implementations (parquet-java, parquet-cpp). The specification is stable (version 2.10 as of 2024), with new features added conservatively to maintain compatibility. The encoding layer is extensible: new encodings (e.g., delta encoding for strings, zstandard compression) can be added without changing the format version.

The Parquet ecosystem includes tools for schema evolution (adding/removing columns), file compaction (merging small files into larger files for query efficiency), and statistics collection (computing min/max/null counts for all columns in a dataset). These tools are essential for managing a "data lake" — a repository of Parquet files organized by date, topic, or source, queried by multiple engines.

## 12. The Future: Streaming Columnar and GPU-Accelerated Analytics

The columnar storage paradigm is expanding into streaming. Apache Arrow Flight SQL enables columnar data to be streamed from a database to a client using gRPC, with zero-copy Arrow record batches transported over the network. This enables interactive BI tools (Tableau, Power BI) to query databases and receive results in Arrow format, eliminating the serialization overhead of JSON or Protobuf.

GPU-accelerated analytics is another frontier. NVIDIA's RAPIDS project includes `cudf`, a GPU DataFrame library that operates on Arrow-format columnar data in GPU memory. A SQL query can be compiled to CUDA kernels that process Arrow columns in parallel on thousands of GPU cores, achieving 10-100x speedup for complex aggregations and joins. The Arrow format's contiguous memory layout is ideal for GPU processing, as it maps directly to GPU memory without transformation.

## 13. Parquet Page Encoding Internals: A Byte-Level View

Let's examine the byte-level encoding of a simple Parquet page to understand how the encodings work together. Consider a column of 1,000,000 values from the set {"New York", "Los Angeles", "Chicago", "Houston"} — four distinct city names repeated many times.

The dictionary encoding builds a dictionary of the 4 distinct values, each assigned an index (0-3). The page header stores the dictionary (4 variable-length byte arrays), and the page body stores the indices as packed integers. Each index requires 2 bits (since there are 4 values, and 2^2 = 4), so 1,000,000 indices require 250,000 bytes (2,000,000 bits / 8). Without encoding, the raw strings (average 10 characters each) would require about 10 MB. The dictionary encoding achieves 40x compression before applying general-purpose compression.

Run-length encoding further compresses the indices. If the data is sorted by city (all New Yorks together, then Los Angeles, etc.), the indices form long runs: 300,000 zeros (New York), then 250,000 ones (Los Angeles), etc. RLE encodes each run as a (value, count) pair using variable-length integers (VLQ, variable-length quantity encoding). The entire column might be encoded as just 4 RLE pairs, occupying maybe 20 bytes. That's 500,000x compression — from 10 MB to 20 bytes — for this highly regular dataset.

Bit packing ensures that the run counts and values are stored compactly. VLQ encoding uses the high bit of each byte as a continuation flag: if the high bit is set, the next byte continues the value; if clear, this is the last byte. Small values (like run counts under 128) fit in one byte; larger values use multiple bytes. The combination of dictionary encoding, RLE, and bit packing is the secret sauce that makes Parquet files so compact for analytical data.

## 14. Summary

Columnar storage — Parquet on disk, Arrow in memory, ORC with ACID support — has transformed analytical data processing. The shift from row-oriented to column-oriented storage has yielded order-of-magnitude improvements in query performance and storage efficiency. Modern encoding techniques achieve compression ratios of 5-20x. Predicate pushdown eliminates I/O for irrelevant data. Vectorized execution exploits SIMD instructions to process billions of values per second. The columnar ecosystem has converged on a common set of principles: separate columns, compress aggressively, index lightly, and execute in batches. These principles now power virtually every cloud data warehouse, data lake query engine, and interactive analytics platform.

## 15. Apache Arrow Flight: Streaming Columnar Data at Wire Speed

Apache Arrow Flight is a high-performance data transport protocol built on gRPC and the Arrow columnar format. Traditional data transport (JDBC/ODBC over TCP) serializes query results to row-oriented wire formats (e.g., PostgreSQL's text protocol), which the client must parse and convert to its internal representation. Arrow Flight eliminates this overhead by streaming Arrow record batches directly over the network — the same binary format that the server uses in memory is streamed to the client, where it can be used without deserialization.

Flight achieves throughput of 10-50 GB/s on a 100 Gbps network, compared to 1-5 GB/s for traditional JDBC/ODBC transports. The key to this performance is "zero-copy" throughout the stack: the database produces Arrow record batches in memory, Flight serializes them to gRPC messages without copying, the network transmits them, and the client reads them directly into its own Arrow buffers. No parsing, no conversion, no memory allocation — just pointer exchange and DMA.

Flight SQL extends Flight with a standard SQL interface, allowing BI tools (Tableau, Power BI) and data science environments (Jupyter, RStudio) to query databases and receive results in Arrow format. Flight SQL defines gRPC services for query submission (`ExecuteSql`), result retrieval (`FetchResults`), and metadata discovery (`GetCatalogs`, `GetSchemas`, `GetTables`). The combination of Arrow's columnar efficiency and Flight's streaming transport makes interactive analytics on billion-row datasets practical on standard hardware.

## 16. Summary

Columnar storage — Parquet on disk, Arrow in memory, ORC with ACID support — has transformed analytical data processing. The shift from row-oriented to column-oriented storage has yielded order-of-magnitude improvements in query performance and storage efficiency. Arrow Flight extends these benefits to data transport, enabling zero-copy data streaming between systems. The columnar ecosystem is now the foundation of modern analytical data infrastructure, from data lakes (Parquet on S3) to data warehouses (BigQuery, Redshift) to interactive notebooks (Jupyter with Arrow). The principles — separate columns, compress aggressively, execute in batches, stream without copies — have become industry standards. Columnar storage is the foundation of modern analytics.

## 17. The Parquet Rust Implementation and the Next Generation of Data Tools

The Rust ecosystem is producing a new generation of high-performance Parquet tools. The `parquet` crate (Apache Arrow Rust implementation) provides a pure-Rust Parquet reader and writer that is competitive with the C++ and Java implementations. The Rust implementation takes advantage of Rust's zero-cost abstractions and memory safety to achieve both high performance and safety — no buffer overflows, no use-after-free, no data races in the Parquet codec.

The `datafusion` query engine (also part of Apache Arrow Rust) uses the Rust Parquet reader to execute SQL queries directly on Parquet files, with vectorized execution and SIMD acceleration. DataFusion can scan Parquet files at 5-10 GB/s per core on modern hardware, competitive with C++ query engines like Impala. The combination of the Rust Parquet reader, DataFusion execution engine, and Arrow in-memory format provides a complete analytical stack in a safe, modern language.

The emergence of Rust-based data tools is significant because it demonstrates that memory safety and high performance are not mutually exclusive in the data infrastructure space. Historically, data infrastructure was written in C++ (Impala, Spark's C++ core) or Java (Hadoop, Hive, Presto), trading performance for safety or vice versa. Rust offers both — and the data ecosystem is taking notice.

## 18. SIMD Vectorized Execution: From Theory to Hardware

The contiguous memory layout of Arrow and Parquet column chunks is designed for SIMD (Single Instruction, Multiple Data) processing. Modern CPUs can process multiple data elements simultaneously using wide vector registers: 128-bit SSE (4×32-bit integers), 256-bit AVX2 (8×32-bit integers), or 512-bit AVX-512 (16×32-bit integers). A column of 32-bit floats can be summed 16 values at a time with a single AVX-512 instruction, achieving 16× throughput over scalar processing.

### The Scan Pipeline

Consider a typical analytical query: `SELECT city, AVG(age) FROM users WHERE age > 30 GROUP BY city`. The execution pipeline for this query in a vectorized engine proceeds as follows. First, the scan operator reads the "age" column in batches of 8,192 values. The predicate `age > 30` is evaluated using a SIMD comparison instruction that compares 16 ages at once, producing a bitmask where each bit indicates whether the corresponding age exceeds 30. This bitmask is then used to filter the "city" column — only cities whose corresponding age passed the filter are retained. The filtered cities and ages are passed to the aggregation operator, which performs a SIMD-accelerated group-by using hash tables or sort-based grouping.

This entire pipeline operates on column batches that fit in L1 or L2 cache. The scan reads from memory in sequential, predictable patterns (contiguous column chunks), maximizing memory bandwidth. The SIMD operations process multiple values per cycle, maximizing compute throughput. The combination of cache-friendly access patterns and SIMD parallel processing is what enables modern query engines to scan billions of rows per second on a single core.

### Auto-Vectorization and JIT Compilation

Modern query engines (Impala, Spark with WholeStageCodeGen, DataFusion) use JIT compilation to generate specialized machine code for each query. The JIT compiler (LLVM for Impala, DataFusion's built-in JIT, Spark's Janino) takes the query plan and emits code that: (1) loads column batches into SIMD registers, (2) applies predicates using SIMD comparisons, (3) performs arithmetic using SIMD operations, and (4) stores results back to memory. The generated code is specialized for the specific data types (e.g., 32-bit integers vs. 64-bit floats) and the specific operations in the query, eliminating the overhead of generic, type-dispatching code.

For example, a filter `WHERE age > 30 AND salary > 50000` on columns of type INT32 and FLOAT64 would generate different SIMD instructions for each column: AVX2 packed 32-bit integer comparison for age, and AVX2 packed 64-bit double comparison for salary. The JIT compiler knows the exact data types at code generation time, so it can emit the optimal instruction sequence without any runtime type checking. This specialization is what makes vectorized query engines 5-100× faster than traditional row-at-a-time interpreted query execution.

### Bit-Packed Encoding and SIMD Decoding

Beyond the scan pipeline itself, SIMD instructions accelerate the decompression of encoded column data. Parquet's bit-packed encoding stores values in a compact bit-aligned format that would traditionally require expensive bit-shifting operations to decode. With SIMD, these operations can be parallelized using shuffle, permute, and bit-manipulation instructions. For example, decoding a bit-packed column where each value occupies 9 bits requires extracting 9-bit chunks from a byte stream — a task that involves shifting, masking, and combining bytes. AVX2 provides the `_mm256_shuffle_epi8` instruction (PSHUFB) that can arbitrarily permute bytes within a 256-bit register, and the `_mm256_sllv_epi32` instruction for variable shifts. These instructions allow decoding multiple 9-bit values per cycle, achieving near-scalar throughput. Modern Parquet readers in C++ (Arrow C++, Impala) and Rust (DataFusion) use hand-tuned SIMD intrinsics for the hot decoding paths, and the performance difference is substantial — SIMD-accelerated decoding can be 3-5× faster than scalar decoding for bit-packed and dictionary-encoded columns.

### The Importance of Null Bitmaps

Arrow and Parquet use "null bitmaps" — densely packed bit arrays where each bit indicates whether the corresponding value is null. A 1 indicates a present value; a 0 indicates null. Null bitmaps enable branch-free processing of nullable columns. Instead of checking each value for null with an `if` statement (which causes branch mispredictions when nulls are scattered), the query engine can process all values unconditionally and use the bitmap to mask out null results at the end. SIMD instructions make this even more efficient: a single `_mm256_testz_si256` instruction can check 32 values for nulls simultaneously, and a `_mm256_blendv_epi8` instruction can selectively replace null values with a default based on the bitmap. The combination of null bitmaps and SIMD enables vectorized engines to handle nullable columns with minimal overhead, which is critical because most real-world datasets have nullable columns from missing values, optional fields, or outer join results.

## 19. The Data Lakehouse: Unifying Data Lakes and Data Warehouses

The columnar storage revolution has enabled a new architectural pattern: the "data lakehouse." A data lakehouse combines the flexibility of a data lake (store everything in open formats like Parquet on cheap object storage) with the reliability and performance of a data warehouse (ACID transactions, schema enforcement, optimized query execution). The key enabling technologies are:

- **Delta Lake** (open-sourced by Databricks): Adds a transaction log to a Parquet-based data lake. Each write creates a new Parquet file and records it in a transaction log (a JSON file or a set of JSON files). Reads consult the transaction log to determine which files constitute the current table state. The transaction log enables ACID transactions (atomic writes, snapshot isolation), time travel (query the table as of a past version), and schema evolution (add or remove columns without rewriting all files).

- **Apache Iceberg** (open-sourced by Netflix): Provides a similar transaction log for Parquet (or ORC or Avro) files, with a focus on performance at scale. Iceberg's metadata layer tracks file-level statistics (min/max per column, null counts) enabling fine-grained predicate pushdown and data skipping. Iceberg also supports "hidden partitioning" — the partition scheme is stored in metadata and automatically applied by the query engine, eliminating the need for users to specify partition columns in queries.

- **Apache Hudi** (open-sourced by Uber): Focuses on streaming data ingestion with upserts (update or insert) and deletes. Hudi manages a timeline of commits on Parquet files and supports incremental queries (read only the data that changed since the last query). Hudi is commonly used for streaming ETL pipelines that ingest data from Kafka into a data lake and make it queryable within minutes.

The lakehouse architecture represents the maturation of the columnar ecosystem. Instead of choosing between a data lake (cheap, flexible, but lacking transactions and performance) and a data warehouse (fast, transactional, but expensive and proprietary), organizations can store data in open Parquet format on cheap object storage and get warehouse-like features through transaction logs and query optimization. The lakehouse is the logical endpoint of the columnar revolution: columnar storage plus transactional metadata plus vectorized execution equals a modern analytical platform that is both cost-effective and high-performance.

## 20. Summary

Columnar storage has transformed analytical data processing. Parquet provides the on-disk format with dictionary encoding, RLE, and predicate pushdown. Arrow provides the in-memory format with SIMD-friendly layout and zero-copy interchange. ORC adds ACID transactions for Hive workloads. Arrow Flight enables wire-speed data transport. SIMD vectorized execution exploits modern CPU architectures to process billions of values per second per core. The Rust ecosystem brings memory safety to data infrastructure without sacrificing performance. The data lakehouse combines the flexibility of open formats with the reliability of transactional metadata. Together, these technologies form the foundation of modern data analytics, from data lakes to data warehouses to interactive notebooks. Columnar storage is not just a format — it's the architectural foundation of how the world analyzes data.
