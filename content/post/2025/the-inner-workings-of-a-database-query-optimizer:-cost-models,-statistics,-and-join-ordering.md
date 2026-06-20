---
title: "The Inner Workings Of A Database Query Optimizer: Cost Models, Statistics, And Join Ordering"
description: "A comprehensive technical exploration of the inner workings of a database query optimizer: cost models, statistics, and join ordering, covering key concepts, practical implementations, and real-world applications."
date: "2025-05-28"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/The-Inner-Workings-Of-A-Database-Query-Optimizer-Cost-Models,-Statistics,-And-Join-Ordering.png"
coverAlt: "Technical visualization representing the inner workings of a database query optimizer: cost models, statistics, and join ordering"
---

# The Inner Workings Of A Database Query Optimizer: Cost Models, Statistics, And Join Ordering

## Introduction

Imagine you’ve just written what seems like a perfectly reasonable SQL query—a four-table join with a few `WHERE` clauses, some aggregation, and a touch of window functions. You run it. Seconds pass. Then minutes. Your coffee grows cold. Eventually, the DevOps engineer pings you: “Your query is killing the database.” Embarrassed, you start adding hints, rewriting subqueries, and desperately checking execution plans. The culprit? Not your logic, but the silently heroic—and occasionally fallible—piece of software at the heart of every modern relational database: the **query optimizer**.

The query optimizer is the brain behind the brawn of any SQL execution engine. It’s the component that takes a declarative, high-level statement—“I want these rows, combined in this way, filtered by those conditions”—and transforms it into a concrete, efficient execution plan. Without it, every database would require developers to hand-craft access paths, index strategies, and join algorithms, turning SQL from a declarative wonder into a procedural nightmare. Yet, despite its profound importance, the optimizer often remains a black box. Developers sprinkle `EXPLAIN` on their queries, squint at parallel lines and cost numbers, and pray. But understanding _why_ the optimizer chooses one plan over another—and more importantly, _how_ it arrives at that decision—is the key to writing performant queries, designing better schemas, and diagnosing production slowdowns.

In this post, we’ll open that black box, focusing on three interlocking pillars of query optimization: **cost models**, **statistics**, and **join ordering**. These are the gears that drive the optimizer’s decision-making engine. We’ll explore how the optimizer estimates the cost of different plans (spoiler: it’s a lot of weighted approximations), how it gathers and uses statistics to make those estimates accurate (or not), and how it navigates the combinatorial explosion of join orders to find a good-enough plan. By the end, you’ll not only understand the magic behind `EXPLAIN` but also be equipped with practical strategies to help your database optimizer—and avoid its pitfalls.

## 1. The Query Optimizer’s Role: From SQL to Execution Plan

Before diving into the three pillars, it’s worth understanding the full pipeline. When you issue a SQL query, it passes through several stages:

1. **Parsing** – The SQL text is converted into a parse tree.
2. **Binding / Semantic Analysis** – The parser resolves table names, column names, and checks for type correctness.
3. **Rewriting** – The query is transformed into an equivalent but more optimizable form (e.g., view expansion, subquery flattening, predicate pushdown).
4. **Optimization** – The optimizer generates alternative execution plans and selects the cheapest one.
5. **Execution** – The chosen plan is executed by the runtime engine.

The optimization stage is where the magic happens. The optimizer receives a logical query plan – a tree of relational operators (Scan, Join, Filter, Project, Aggregate) that describes _what_ to compute. It then generates a search space of physical plans, each specifying _how_ to compute it: which join algorithm (Nested Loop, Hash Join, Merge Join), which access method (Sequential Scan, Index Scan, Bitmap Scan), and in what order to combine tables. The optimizer assigns each plan a _cost_ (an estimate of resources consumed) and picks the lowest-cost plan.

This sounds straightforward, but the search space is enormous. For a query joining `n` tables, there are Catalan(n) possible join orders – roughly (2n)!/(n!(n+1)!) – and for each join order, you can choose different algorithms and access paths. For n=10, that’s over 16 million possibilities. Optimizers use clever algorithms to prune this space, but they rely critically on accurate cost estimates.

The cost estimate itself depends on two things: the _cardinality_ (number of rows) of intermediate results, and the _cost per operation_ (read/write, CPU). Cardinality estimation is the most difficult part and depends on database statistics.

## 2. Statistics – The Backbone of Estimation

The optimizer’s cost model is only as good as the inputs it receives. Those inputs are derived from **database statistics** – a set of metadata describing the distribution of data in each table and its indexes. Without accurate statistics, the optimizer is essentially guessing, often leading to disastrous plans.

### 2.1 How Statistics Are Collected

Modern databases like PostgreSQL, MySQL (InnoDB), SQL Server, and Oracle collect statistics automatically or via manual commands (`ANALYZE`, `UPDATE STATISTICS`). The process typically involves sampling a subset of rows (e.g., 300 \* default_statistics_target in PostgreSQL) and building data structures that summarize column values. For large tables, sampling is the only feasible approach – scanning the entire table would be too expensive. The sample size is a trade-off: too small yields inaccurate estimates; too large slows down statistics refresh.

### 2.2 Types of Statistics

Databases maintain a variety of statistics per column (and sometimes for column groups). Here are the most important:

- **Row Count (ntuples)** – Total number of rows in the table.
- **Null Fraction** – Fraction of rows where the column is NULL.
- **Number of Distinct Values (NDV)** – Estimated count of distinct values in the column.
- **Most Common Values (MCV)** – A list of the most frequently occurring values and their frequencies. This helps with equality predicates like `WHERE color = 'red'`.
- **Histograms** – Binned frequency distributions that approximate the data distribution. Used for range predicates (`WHERE age BETWEEN 20 AND 30`). Equi-depth histograms are common: each bucket contains approximately the same number of rows.
- **Correlation** – Some databases (PostgreSQL) track the correlation between a column’s physical order and its logical order. This helps estimate the effectiveness of index scans vs. sequential scans.
- **Column Group Statistics** – For queries with multiple correlated predicates (e.g., `WHERE make = 'Ford' AND model = 'Mustang'`), databases can collect statistics on combinations of columns to avoid assuming independence.

### 2.3 How Statistics Drive Cardinality Estimates

Let’s see a concrete example. Suppose we have a table `orders` with 1,000,000 rows. The column `status` has 3 distinct values: 'pending', 'shipped', 'cancelled'. If the MCV list shows 'pending' appears 600,000 times, 'shipped' 300,000, and 'cancelled' 100,000, then for the query:

```sql
SELECT * FROM orders WHERE status = 'pending';
```

The optimizer will estimate the result size as 600,000 rows. For a range query:

```sql
SELECT * FROM orders WHERE order_date >= '2024-01-01' AND order_date < '2024-02-01';
```

If `order_date` has an equi-depth histogram, the optimizer finds the bins covering that date range and sums the frequencies to estimate the row count. For example, if the histogram has 100 buckets each representing 10,000 rows, and the range spans 3 full buckets, the estimate is ~30,000 rows. However, if the range covers partial buckets, the optimizer assumes uniform distribution within each bucket, which can be inaccurate.

### 2.4 The Flaws of Uniformity and Independence Assumptions

Most classical optimizers make two simplifying assumptions that are often wrong:

- **Uniformity** – Data is evenly distributed across values within a bucket. In reality, data can be skewed (e.g., most orders are 'shipped', few are 'cancelled').
- **Independence** – The selectivity of multiple predicates is independent. For example, for `WHERE color = 'red' AND size = 'large'`, the optimizer assumes the fraction of rows satisfying both is `fraction(red) * fraction(large)`. If `red` and `large` are correlated (e.g., red items are usually large), this underestimates the result size, leading to poor plan choices.

Modern databases combat this with multi-column statistics (e.g., extended statistics in PostgreSQL, column-group statistics in SQL Server). For example, you can create:

```sql
CREATE STATISTICS color_size_stats ON inventory(color, size);
```

This collects joint MCV data, allowing the optimizer to see that 'red' + 'large' occurs 40% of the time, not 10%.

### 2.5 Statistics Maintenance: The Silent Killer

Statistics are not static. After large data modifications (INSERT, UPDATE, DELETE, TRUNCATE), statistics become stale. The optimizer may think a table has 1 million rows when it now has 10 million, or that a column has 100 distinct values when it now has 1,000. This can cause the optimizer to choose a Nested Loop join when a Hash Join would be better, or an index scan when a full table scan is faster.

Most databases have auto-analyze thresholds. For example, in PostgreSQL, `autovacuum` triggers `ANALYZE` after a certain percentage of rows change (configured by `autovacuum_analyze_scale_factor`). However, these thresholds may be too high for frequently updated tables. Developers should monitor the age of statistics using system views like `pg_stat_user_tables` and manually `ANALYZE` critical tables after large batch loads.

### 2.6 Practical Example: The Impact of Stale Statistics

Consider a query joining two tables, `customers` (10 million rows) and `orders` (20 million rows), with the predicate `customers.id = orders.customer_id` and a filter `customers.region = 'APAC'`. The region column originally had 4 regions: 'NA' (40%), 'EU' (30%), 'APAC' (20%), 'LATAM' (10%). The statistics say 'APAC' selectivity = 0.2, so the optimizer estimates 2 million customers, and then 2 million matching orders (assuming each customer has on average 2 orders). It chooses a Hash Join.

Now suppose the company’s business shifted: 80% of customers are now from APAC. But statistics were last collected before the shift. The optimizer still thinks 2 million customers will be filtered, but in reality it’s 8 million. The Hash Join was sized with work_mem for 2 million rows; it spills to disk, becomes incredibly slow, and the query times out. The root cause: stale statistics.

## 3. Cost Models – Turning Estimates into Dollars

Once cardinalities are estimated, the optimizer needs to assign a **cost** to each operation. The cost is a dimensionless number (usually in arbitrary units) that combines multiple resource consumption elements. The optimizer’s goal is to minimize the total cost of the plan.

### 3.1 Components of Cost

Different databases weigh different resources. The main components are:

- **Disk I/O** – Reading pages from disk (sequential vs. random). Sequential I/O is cheaper per page because of prefetching and lower seek times.
- **CPU** – Time to process tuples, evaluate predicates, perform comparisons, hash computations, etc.
- **Memory** – The amount of work_mem (or sort_mem) used. Running out of memory forces spill-to-disk, which adds I/O cost.
- **Network** – In distributed databases or parallel queries, transferring data between nodes.
- **Temp space** – Used for sorting or hash tables.

Most traditional databases (PostgreSQL, MySQL, older versions of Oracle) focus on I/O cost, because historically disk was the bottleneck. PostgreSQL’s cost model, for example, has four parameters:

- `seq_page_cost` – Cost of a sequential page read (default 1.0)
- `random_page_cost` – Cost of a random page read (default 4.0)
- `cpu_tuple_cost` – Cost of processing a tuple (default 0.01)
- `cpu_operator_cost` – Cost of evaluating a predicate or performing a comparison (default 0.0025)

These values are relative. If you have a fast SSD, `random_page_cost` should be lower (e.g., 1.1) because random reads are nearly as fast as sequential. Many performance issues stem from using defaults on modern hardware.

### 3.2 How Cost Is Computed for Basic Operations

Let’s walk through how PostgreSQL would estimate the cost of a sequential scan on a table `orders` with 1,000,000 rows, each row 200 bytes, stored in 8KB pages. The table’s total size is about 1,000,000 \* 200 ≈ 200 MB, which is 200 MB / 8 KB = 25,600 pages.

**Sequential Scan:**

- I/O cost: `pages * seq_page_cost` = 25,600 \* 1.0 = 25,600
- CPU cost: `rows * cpu_tuple_cost` = 1,000,000 \* 0.01 = 10,000
- Total cost = 35,600 startup cost (0) + 35,600 total.

**Index Scan** (using a B-tree on `order_id`):

Suppose we want `WHERE order_id = 5000`. The B-tree depth is, say, 3 (typical for large tables). The index has 200,000 leaf pages (assuming 50 entries per page). A single random page read at each of the 3 levels plus 1 leaf page = 4 random I/Os. Then we need to fetch the actual table row – that’s another random page read (if the table is not clustered). So total random I/Os = 5.

- I/O cost: `5 * random_page_cost` = 5 \* 4.0 = 20
- CPU cost: a few tuple/operator costs, say 0.01 per tuple, 1 tuple = 0.01
- Total cost ≈ 20.01

The index scan is much cheaper for a selective query.

**But what if the filter is not selective?** For `WHERE status = 'shipped'` (30% of rows = 300,000 rows), an index scan would require 300,000 random page reads (one per row) if the index is not covering. That would be 300,000 \* 4 = 1,200,000 in I/O cost alone – far worse than the sequential scan (35,600). The optimizer will correctly choose a sequential scan in that case, but only if the statistics reflect the 30% selectivity. If statistics are stale and overestimate selectivity, it might choose the wrong plan.

### 3.3 Join Cost Estimation

Joins are more complex. Costs depend on the join algorithm and the sizes of inputs.

**Nested Loop Join:**

For a nested loop join between an outer relation `R` (size `r` rows, cost `C_r` to get all rows) and an inner relation `S` (cost `C_s` per probe). The total cost is:

`C_total = C_r + r * (cost to probe S once)`

If the inner relation is indexed, each probe might be an index scan (e.g., `index_page_cost` \* depth + `cpu`). If sequential, each probe is a scan of `S` – that would be disastrous for large inner tables.

Optimizers usually only consider nested loop when the outer is small or the inner has an index.

**Hash Join:**

Build a hash table on the smaller input (build side), then scan the larger input (probe side). Cost:

- Build side: `C_build = cost of scanning build relation + cost of hashing tuples`
- Probe side: `C_probe = cost of scanning probe relation + cost of probing for each tuple`

Total: `C_build + C_probe + some memory cost`. If the hash table does not fit in memory, additional I/O for partitioning.

**Merge Join:**

Both inputs are sorted (or can be sorted). Cost:

- Sorting cost: `2 * N * log(N) * cpu_cost + I/O for temporary files`
- Merge pass: sequential scan of both sorted inputs.

Merge join is preferable when inputs are already sorted (e.g., by index) or when the join predicate is not equality.

### 3.4 Weighting and Tuning Cost Parameters

Database administrators can tune cost parameters to match hardware. For example, if you use NVMe SSDs, set `random_page_cost` to 1.1 and `seq_page_cost` to 1.0. On spinning disks, `random_page_cost` might be 4.0 or even higher (8.0 for ancient drives). But adjusting these parameters globally may have unintended consequences. Some databases (like PostgreSQL) allow per-table or per-index storage parameters. You can set the `storage_parameter` for a table to `autovacuum_enabled` or `fillfactor`, but not directly cost parameters. However, you can influence the optimizer by adjusting `effective_cache_size` (how much data is likely cached in OS buffers). A higher `effective_cache_size` reduces the cost of sequential scans (because more pages assumed in cache) and makes index scans relatively cheaper.

### 3.5 The Cost of Parallelism

Modern databases (PostgreSQL 9.6+, SQL Server, Oracle) can parallelize scans and joins. Parallel query adds an extra dimension: the cost model must divide work among workers but also account for overhead (gather nodes, coordination). In PostgreSQL, the optimizer estimates parallel scan cost using `parallel_tuple_cost` and `parallel_setup_cost`. If the table is large and parallel workers are available, parallel sequential scans may beat an index scan even for moderately selective queries. This adds further complexity to the optimizer’s decision.

## 4. Join Ordering – The NP-Hard Problem

Now we have cardinality estimates and per-operator costs. The optimizer must choose the order in which to join tables. This is the most intellectually challenging part of query optimization.

### 4.1 Why Join Order Matters

The result size of a join can vary dramatically based on order. Consider three tables: A (1000 rows), B (10,000 rows), C (1,000,000 rows). Suppose A joins to B with selectivity 0.1 (100 rows per A row?), actually let’s be precise: each A row matches 1 B row, and each B row matches 10 C rows. If we join (A ⨝ B) first, we get 1000 rows. Then join with C: 1000 _ 10 = 10,000 rows. If we join (B ⨝ C) first, we get 10,000 _ 10 = 100,000 rows. Then join with A: 100,000 rows (assuming one match per A). The first order yields 10,000 intermediate rows, the second yields 100,000. The cost of the operators (hash building, probing) scales with these intermediate sizes. So the join order directly impacts performance.

### 4.2 Left-Deep vs. Bushy Trees

Join trees can be:

- **Left-deep**: Each join’s left input is a base table; right input is the result of previous joins. This is common because it works well with pipelining (Nested Loop) and because the shape of the tree matches the typical iterator model.
- **Right-deep**: Mirror of left-deep.
- **Bushy**: Both inputs can be intermediate join results. Bushy plans can exploit parallelism but are harder to explore and may require more memory.

Most optimizers restrict the search space to left-deep trees to reduce complexity. For n tables, the number of left-deep trees is n! (since we permute the order of base tables). That’s still huge: 10! = 3.6 million. But with pruning, it’s manageable. Bushy trees have Catalan(n) possibilities, which is even larger.

### 4.3 Dynamic Programming (Selinger-style)

The classic approach, from System R (IBM), uses dynamic programming (DP). The idea: the cheapest plan to join a set of tables can be derived from the cheapest plans for its subsets. For each subset `S`, the DP stores the cheapest plan and its cost. The algorithm iterates over increasing subset sizes.

Pseudo:

```
for i = 1 to n:
    for each subset S of size i:
        for each table T in S:
            let S' = S \ {T}
            for each plan for S':
                cost = cost(S') + join_cost(S', T)
                keep cheapest plan for S
```

This explores n \* 2^(n-1) subsets, which is O(3^n) for left-deep trees (because each join adds a new base table). For n=10, 2^10=1024 subsets, manageable. But for n=20, 1 million subsets may still be feasible with pruning. Many databases cap the number of tables in DP to 12-15, then fall back to heuristics.

The DP approach can also accommodate different join algorithms and access paths. For each subset, it may store multiple interesting plans (e.g., best sorted, best unsorted) to allow merge joins later.

### 4.4 Heuristic and Greedy Approaches

When the number of tables is large, DP becomes too expensive. Optimizers use heuristic rules:

- **Join roughly in order of increasing table size** – small tables first.
- **Use a greedy algorithm**: start with the cheapest base table, then repeatedly join the cheapest remaining table, considering the current intermediate result.
- **Query optimization via exhaustive search with pruning** (e.g., PostgreSQL’s geqo_threshold): if number of tables exceeds `geqo_threshold` (default 12), PostgreSQL switches to the **Genetic Query Optimizer (GEQO)**.

### 4.5 Genetic and Randomized Algorithms

GEQO uses a genetic algorithm: encode join orders as chromosomes, evaluate fitness (cost), and evolve over generations. It’s not guaranteed to find the optimal plan but often finds a good one. The parameters (population size, number of generations) are configurable. Other databases use simulated annealing or random sampling.

Another technique: **iterative deepening** – first try DP for a limited number of tables, then use heuristics for the rest.

### 4.6 Practical Example: Four-Table Join

Let’s work through a concrete example with realistic numbers. Tables: `users` (10k), `orders` (100k), `payments` (500k), `reviews` (50k). Schema: `orders.user_id -> users.id`, `payments.order_id -> orders.id`, `reviews.user_id -> users.id`. Query: find all users who have made at least one order and written a review, with payment status ‘completed’. Filter on `payments.status = 'completed'` (selectivity 40%). No other filters.

Without indexes, the cardinalities:

- Filtered `payments`: 500k \* 0.4 = 200k rows.
- Join `payments` (filtered) with `orders`: assume each payment matches exactly one order (foreign key). Result = 200k rows.
- Join that with `users`: each order matches one user. Result = 200k rows (assuming all distinct users? Possibly duplicates if a user has multiple orders, but we’ll ignore for simplicity).
- Join with `reviews`: reviews.user*id matches user.id; each user on average has 2 reviews. Result = 200k * 2 = 400k rows if we do after users, or if we join reviews first with users (the base tables), we get 50k \_ ? Actually let's compute join orders:

**Plan A (start with small users):**

1. Scan users (10k)
2. Join with reviews (50k) on user_id → estimated rows per user 2 → 20k (if each user has exactly 2 reviews, but some users have 0). Actually if we filter only users with reviews, we need inner join. Assume 80% of users have at least one review → 8k users. Join result 50k (each review matches a user, so we get 50k rows).
3. Join that with orders (100k) on user_id: each user has on average 10 orders → 8k users \* 10 = 80k rows.
4. Join with payments (200k after filter) on order_id: each order has 2 payments on average → 160k rows.

**Plan B (start with filtered payments):**

1. Filter payments (200k)
2. Join with orders (100k) on order_id (1:1) → 200k rows
3. Join with users (10k) on user_id: each order belongs to one user, but many orders per user → 200k rows (still same count)
4. Join with reviews (50k) on user_id: each user may have many reviews, so 200k \* average reviews per user (say 2) = 400k.

Intermediate sizes: Plan A (20k → 80k → 160k); Plan B (200k → 200k → 400k). The cost of building hash tables and scanning is higher in Plan B. The optimizer will prefer Plan A if it can estimate correctly.

But the optimizer needs to know the selectivity of the join conditions. If we have histogram on `users.id` and `orders.user_id`, it can estimate the number of matching rows. Without proper statistics, it might misestimate. For example, if statistics on `reviews` are not updated and show 5k rows instead of 50k, the optimizer might think joining reviews early is cheap, then later realize it’s huge.

## 5. Interplay Between Statistics, Cost, and Join Order

The three pillars are deeply interconnected. A poor cardinality estimate from stale statistics leads to bad cost estimates, which in turn can cause the optimizer to choose a terrible join order. Conversely, even with perfect statistics, the cost model might not accurately reflect hardware (e.g., random_page_cost too high on SSD), leading to suboptimal plans.

### 5.1 The Cascading Failure

Consider a query with five tables. The optimizer executes DP and picks a join order based on cost. It trusts the estimated cardinalities. If one estimate is off by a factor of 10, the cost of joining that intermediate result with the next table might be over- or under-estimated, causing a chain reaction. The final plan might be thousands of times slower than the true optimal.

### 5.2 Example: A Real-World Horror Story

A production database had a table `logs` with 2 billion rows. A query joining `logs` with `users` on `user_id` and filtering on `logs.created_at > '2023-01-01'`. The statistics for `created_at` were built a month ago, showing the max date as ‘2023-01-15’. The actual max date was ‘2023-07-15’. The filter was thought to include 50% of rows (because the range from 2023-01-01 to max date was half the total range). In reality, it included only 10% (because recent dates were sparse). The optimizer chose a Merge Join (expecting 1 billion rows), but the actual result was 200 million rows, and the merge join was fine – but wait, because it misestimated, it actually chose a plan that was still okay? Actually the problem was that it chose a Nested Loop with an index on `logs.user_id`, expecting 1 billion lookups (10 billion I/O) – it was catastrophic. After updating statistics, the optimizer chose a Hash Join and the query finished in seconds.

### 5.3 Adaptive Query Optimization (AQO)

To mitigate such issues, some databases (Microsoft SQL Server, Oracle, and recently PostgreSQL with extensions like pg_plan_hint and auto_explain) use adaptive query optimization. They might:

- **Re-optimize at runtime** if cardinality estimates differ significantly from actual.
- **Use feedback loops** from previous executions.
- **Maintain multiple plans** and pick the best based on parameters (parameter-sensitive plans).

PostgreSQL 14+ introduced a limited form: the planner can now use a “generic plan” for prepared statements if the custom plan’s cost is high relative to generic. But true adaptive optimization is not yet mainstream in open-source databases.

## 6. Advanced Topics in Query Optimization

### 6.1 Parallel Query Optimization

When parallelism is available, the optimizer must decide the degree of parallelism (DOP) and how to partition work. The cost model includes setup costs, communication overhead, and skew. Too many workers can hurt due to contention; too few leaves performance on the table. Optimizers often use heuristics: parallel scan if the table is larger than `min_parallel_table_scan_size` and DOP proportional to size.

### 6.2 Machine Learning for Optimization

Research is growing in using ML to improve cardinality estimation (e.g., using deep learning models for selectivity). Commercial databases like Oracle have introduced ML-based advisors. However, production adoption is slow due to robustness concerns. The problem: ML models can be unpredictably wrong outside their training distribution, and databases require deterministic behavior for correctness. Hybrid approaches (like using ML to tune cost parameters) are more common.

### 6.3 Approximate Query Processing (AQP)

For aggregated queries with tolerances for error, optimizers may choose to sample data instead of scanning everything. This blurs the line between optimization and execution.

## 7. How Developers Can Help the Optimizer

Understanding the inner workings empowers you to write faster queries and design better databases. Here are practical tips:

### 7.1 Keep Statistics Fresh

Run `ANALYZE` after bulk loads and when the data distribution changes significantly. Monitor the `last_analyze` timestamp in `pg_stat_user_tables` (PostgreSQL) or `STATS_DATE` (SQL Server). In MySQL, use `ANALYZE TABLE` for InnoDB.

### 7.2 Create Multi-Column Statistics

If you have queries with correlated columns (e.g., `state` and `city`), create extended statistics. In PostgreSQL:

```sql
CREATE STATISTICS s_state_city (dependencies) ON state, city FROM addresses;
```

Or use MCV lists:

```sql
CREATE STATISTICS s_state_city_mcv (mcv) ON state, city FROM addresses;
```

### 7.3 Write SARGable Queries

Avoid wrapping columns in functions: `WHERE DATE(order_date) = '2024-01-01'` prevents index usage. Instead write `WHERE order_date >= '2024-01-01' AND order_date < '2024-01-02'`. The optimizer can better estimate ranges using histograms.

### 7.4 Use Indexes Wisely

- Index columns used in `WHERE` clauses with high selectivity (distinct values / total rows).
- For join columns, indexes on foreign keys help nested loop joins.
- Covering indexes (include all columns needed) can turn index scans into index-only scans, reducing I/O.

### 7.5 Consider Cluster or Ordering

Some databases support clustering a table on an index (e.g., `CLUSTER` in PostgreSQL). This can help merge joins and range scans.

### 7.6 Test with Realistic Data

Optimizer behavior on a small development database can be misleading. Use production-like data volumes and distributions in test environments.

### 7.7 Use Hints Sparingly

Hints can override the optimizer, but they are a double-edged sword. They may work for today’s data but fail tomorrow when data changes. Only hint as a last resort, and document why.

### 7.8 Read Execution Plans

Learn to read `EXPLAIN (ANALYZE, BUFFERS)` output. Look for mismatches between estimated and actual rows. A large discrepancy indicates stale statistics or a misestimate. Also look for expensive operations like nested loops with many rows, or sort operations that spill to disk.

## Conclusion

The query optimizer is a marvel of software engineering, balancing mathematical elegance with practical approximations. It relies on three interlocking pillars: **statistics** to guess row counts, **cost models** to translate those guesses into resource consumption, and **join ordering** to navigate an exponential search space. Each pillar has its weaknesses: statistics can be stale or assume independence; cost models are based on simplified I/O models that may not reflect modern hardware; join ordering is NP-hard and often solved heuristically.

Understanding these internals demystifies why your query sometimes runs 10x slower than expected and gives you the tools to fix it. Always keep statistics up to date, provide the optimizer with multi-column statistics when needed, and write queries that help the optimizer make good estimates. And when you see an execution plan that looks crazy, remember: the optimizer is only as good as the information it has. By providing better information, you turn the black box into a trusty partner in performance.

Now go ahead, run `EXPLAIN ANALYZE` on your slowest query, and see if you can spot where the optimizer is making a mistake. With the knowledge from this post, you’ll not only understand what you’re looking at – you’ll know exactly how to fix it.

---

_Additional Reading:_

- “Database System Concepts” by Silberschatz, Korth, Sudarshan (Chapters on Query Optimization)
- PostgreSQL Documentation: Chapter 14 – Performance Tuning, Chapter 70 – How the Planner Uses Statistics
- “Optimizing SQL Queries: A Guide for Developers” by various authors (many online resources)

_About the Author:_ [Your Name] is a database performance engineer with 15 years of experience tuning SQL at scale. They have contributed to PostgreSQL and written extensively on query optimization.
