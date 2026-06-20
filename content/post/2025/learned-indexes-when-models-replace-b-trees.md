---
title: "Learned Indexes: When Models Replace B‑Trees"
date: 2025-10-04T10:00:00Z
description: "A practitioner's guide to learned indexes: how they work, when they beat classic data structures, and what it takes to ship them without getting paged."
tags: ["databases", "indexes", "machine-learning", "systems", "storage", "performance"]
categories: ["Engineering"]
draft: false
cover: "/static/images/blog/learned-indexes-when-models-replace-b-trees.png"
coverAlt: "Stylized index structure where a small neural model routes to sorted segments, replacing a traditional B‑tree"
---

If you’ve spent a career trusting B‑trees and hash tables, the idea of using a machine‑learned model as an index can feel like swapping a torque wrench for a Ouija board. But learned indexes aren’t a gimmick. They exploit a simple observation: real data isn’t uniformly random. It has shape—monotonic keys, skewed distributions, natural clusters—and a model can learn that shape to predict where a key lives in a sorted array. The payoff is smaller indexes, fewer cache misses, and—sometimes—dramatically faster lookups.

This post is a field guide to learned indexes that you can take beyond the whiteboard. We’ll cover how they work, when they win, the trade‑offs that bite, and a practical path to evaluating and deploying them next to (not instead of) your trusty structures.

- A three‑minute refresher on what an index actually does
- The core learned‑index recipe (prediction + error bounds + fallback)
- Models that work in practice (RMI, splines, piecewise linear, tiny MLPs)
- Writes, updates, and tail behavior under pressure
- On‑disk vs in‑memory, SSD realities, and compression
- Observability, failure modes, and a migration playbook

By the end, you’ll know whether your workload is a candidate and how to prove it with a weekend experiment.

## What an index really does (and why B‑trees are great)

An index is a function f that maps a key k to the location of its value—either directly (hash) or to a small neighborhood in a sorted order (tree). The work you pay for on a lookup is: pointer chasing, cache misses, and comparisons. B‑trees win because they minimize height and maximize fanout; each internal node fetch brings in a whole cache line of keys, and you descend O(log_B N) levels with good locality.

But B‑trees assume nothing about the data distribution. They’re worst‑case safe. If your keys are smooth and monotonic (timestamps, user IDs, metric offsets, lexicographically incremental strings), a model can often predict within a tiny window where a key should be in a sorted array—shrinking the index and the number of cache lines you touch.

Two consequences matter in production:

1. Space efficiency. Smaller metadata means more hot data in cache and fewer I/O operations on cold paths.
2. Latency shape. If predictions land within tight windows, you do minimal scanning. If they miss, you fall back to a binary search or a local miniature tree—but that tail risk must be bounded.

## The learned‑index recipe

At heart, learned indexes approximate the cumulative distribution function (CDF) of keys. Given sorted keys K[0..N‑1], define CDF(k) ≈ rank(k)/N. If you can learn g(k) ≈ CDF(k), then N·g(k) predicts the position of k in the array. You then search only a small neighborhood around that predicted position to confirm existence and retrieve the value.

The recipe looks like this:

1. Fit a model g(k) to approximate rank/N.
2. Measure the worst‑case absolute error ε across your training/validation keys.
3. At lookup, compute p = ⌊N · g(k)⌋ and search in [p‑ε, p+ε] (clamped to [0,N)).
4. If not found, use a fallback (binary search, or escalate to a secondary structure).

This is robust if ε is small and stable as data evolves. If ε drifts, you retrain or rebalance.

### A tiny sketch

```pseudo
function get(key):
  p = floor(N * g(key))             # model predicts approximate position
  lo = max(0, p - EPS)
  hi = min(N-1, p + EPS)
  # scan or binary search inside [lo, hi]
  i = binary_search_in_window(K, key, lo, hi)
  if i != NOT_FOUND:
    return V[i]
  # fallback if prediction failed badly
  return global_binary_search(K, key)
```

The whole game is choosing g and bounding EPS (ε). The less you scan, the better your cache behavior and the tighter your tail latency.

## Models that actually ship

Learned indexes don’t need huge neural networks. In shipped systems, the winning choices are boring:

- Piecewise linear models: Split key space into M segments; each segment gets a slope/intercept. Accurate, tiny, branch‑free.
- RMIs (Recursive Model Index): A two‑level (or few‑level) model: a root routes to a leaf model that predicts the position. Each leaf is simple (linear or spline).
- Splines: Monotone piecewise polynomials with continuity constraints—more accurate than pure linear, still cheap.
- Tiny MLPs: One or two hidden layers with ReLU or tanh. Useful when key distributions have bends. Use only if they fit in L1/L2 and vectorize well.

What you avoid: heavyweight models, dynamic control flow, or anything that inflates prediction latency more than it saves on search.

### Capacity planning for the model

Let’s say you have 100M keys. A classic B‑tree might consume ~8–16 bytes per key in overhead (fanout, pointers, node headers), often more on disk. A learned index might fit in ~0.5–2 bytes per key of model parameters if the distribution is friendly. Even a 5× reduction turns into a different cache profile.

The key is the ε you can guarantee. If a model predicts positions with ε ≤ 64, your windowed binary search costs at most 7 comparisons (log2(129) ≈ 7) instead of a cross‑node walk. Multiply by fan‑out and cacheline effects, and you’ll feel it.

## Writes, updates, and reality

Everything above sounds neat until you start mutating data.

- Appends. If keys are mostly increasing (time series), you can maintain a learned index with periodic incremental retraining or by reserving a “delta buffer” that’s merged when it gets large.
- In‑place updates. Changing a value doesn’t move a key; no problem.
- Inserts (out‑of‑order keys). Inserts into the middle shift ranks; your ε bound can drift. Solutions: segmented structures (per‑segment models), indirection layers (a pointer array), or a small B‑tree overlay for recent inserts that you periodically fold into base storage.
- Deletes. Tombstone then compact; compaction triggers retrain or local segment refits.

Two patterns dominate deployed systems:

1. LSM‑style layering: Base data is sorted arrays with learned indexes; a mutable memtable (tree or skiplist) takes writes. Background compaction merges and retrains segment models as needed.
2. Segmented arrays: Key space is partitioned into chunks (e.g., by top bits or by equal‑count buckets). Each segment has its own tiny model and error bound. Insertions only affect local segments; hot segments can be re‑fit.

### Tail behavior under churn

Even when median costs drop, you must protect the tail. Choose one or more:

- Bound scan windows conservatively: track ε as a high percentile plus slack (e.g., P99 + margin) and use that as your window.
- Time budgets and fallbacks: if the in‑window search exceeds a micro‑budget, jump straight to a conventional index.
- Versioned models: route lookups based on a version tag so that in‑flight queries don’t straddle an update with different ε.

## On‑disk vs in‑memory and SSD realities

In memory, learned indexes shine when cachelines are precious. On SSD, it’s more nuanced:

- Sequential scans are cheap; random reads are expensive. A learned index that narrows the search range to a few adjacent pages is valuable, but only if you don’t add extra random reads for the model itself.
- Page layouts dominate. Keep model parameters co‑located with data pages or resident in memory. Avoid a second random read to fetch model state.
- Compression helps more than you think. Sorted arrays compress fantastically with delta coding and variable‑byte schemes. A learned index plus compressed arrays can drastically reduce I/O.

### Hybrid: model + fence pointers

A pragmatic on‑disk design: store sparse fence pointers (every Nth key with its page offset). Use a learned model to jump near the right fence, then a minibsearch among fences, then one or two page reads and a local search. Space stays small, and you bound random I/O.

## Memory, SIMD, and branch prediction

To make this fast on CPUs:

- Keep models tiny and contiguous. A two‑level RMI where the leaf table fits in L1 can outperform anything larger that spills to L3.
- Favor linear pieces and splines that compile to fused multiply‑add (FMA) without branches.
- Use SIMD binary search for the in‑window probe (galloping search or small unrolled comparisons).
- Align arrays, remove bounds checks in hot loops, and prefetch the predicted window.

On GPUs, learned indexes can batch lookups and exploit massive parallel search. But unless your workload naturally batches, hovering on CPU with cache‑friendly models is often better.

## When learned indexes win (and when they don’t)

They win when:

- Keys are monotone or near‑monotone and the CDF is smooth (timestamps, IDs, lexicographic prefixes that grow in practice).
- Read‑heavy workloads with high locality; write rates are moderate or append‑dominated.
- Memory pressure is real; shrinking the index frees RAM for the working set.

They don’t when:

- Keys are adversarial or highly irregular (cryptographic hashes, uniformly random keys).
- The distribution shifts rapidly; retraining cost or ε drift dominates.
- Write‑heavy workloads where compaction or segment refitting will thrash.

## Observability and SLOs

Treat a learned index like a cache: it must earn its keep and have strong guardrails.

- Export ε metrics per segment and per model version. Track P50/P95/P99 and max.
- Record window sizes, fallback hit rates, and latency distributions for model predictions vs. fallback.
- Emit a “budget overrun” counter when in‑window searches exceed micro‑budgets so you can tighten windows or retrain.

If ε balloons or fallbacks spike, roll back to a classic index. Feature‑flag the learned path behind a router so you can dial traffic.

## Migration playbook

Here’s a safe, incremental approach:

1. Shadow mode: Build a read‑only learned index next to your existing structure. On a fraction of read requests, compute predictions and log the implied window size and hypothetical steps; don’t serve from it.
2. Offline evaluation: Using logs, compute what ε would have been and what fraction of queries would have fallen back. Estimate RAM wins and I/O savings.
3. Canary serve: Route 1% of get() calls through the learned path with tight budgets and immediate fallback on miss. Compare SLOs.
4. Expand or roll back: If medians improve and tails hold, increase traffic. If ε drifts, retrain or tighten windows. Keep a kill switch.
5. Writes: Add a small write buffer (memtable) and a background task to reconcile with the base arrays and refresh segment models.

## A worked example: piecewise linear on timestamps

Imagine a log store indexed by event time. Keys are nearly monotone but have small out‑of‑order inserts (late arrivals). The distribution over a day looks like a gentle slope with lunchtime spikes.

Design:

- Partition the day into M segments such that each segment has ~N/M keys.
- Fit a line y = ax + b per segment that maps timestamps to rank.
- Measure ε per segment on a validation set; store ε as P99 + safety margin.
- At lookup, compute segment from a top‑level router (either by time range or a tiny model), then do windowed search inside the segment.
- Maintain a memtable for late inserts and merge hourly; adjust only the affected segments.

Outcomes you should expect to measure:

- Index footprint drops by ~5–10× vs B‑tree fanout overhead.
- Median lookup improves thanks to fewer cache lines touched.
- Tail stays controlled if ε bounds are conservative; fallbacks rarely trip.
- Write cost increases modestly due to segment refresh, but remains amortized.

## Correctness and guarantees

Learned indexes don’t change correctness criteria—only how you locate candidates to compare. If your in‑window search and fallback logic are correct, you never return an incorrect value; at worst you pay extra steps to find the key. The risk is purely performance: if ε was underestimated, tails suffer. That’s why per‑segment ε metrics and fallbacks exist.

If your workload needs strict worst‑case bounds, pair the learned index with a small auxiliary structure that catches long tails:

- A tiny B‑tree or skiplist per segment that only stores keys which exceeded the window in the last X minutes (an “exception table”).
- A capped fallback budget: after Y steps, jump to the classic index regardless.

## Variants you’ll encounter

- ALEX: Adaptive learned index that organizes data into dynamic model‑guided nodes; good for mixed read/write.
- PGM Index: A succinct structure based on piecewise linear models with provable bounds on ε; great practical baseline.
- SOSD benchmarks: Standard suite to compare learned and classic indexes across datasets and hardware.

If you’re prototyping, start with PGM. It’s simple, fast, and comes with strong guarantees.

## Frequently asked questions

• What about composite keys?  
Map the composite key to a comparable scalar (e.g., lexicographic mapping, feature hashing that preserves order for components that matter). Or build a learned router that chooses sub‑indexes per prefix.

• What if my distribution shifts daily?  
Version models by day (or hour) and keep a small ensemble. Route lookups to the appropriate version by a cheap heuristic, and garbage‑collect old ones.

• Can I combine with Bloom filters?  
Yes. A Bloom filter catches negative lookups cheaply, reducing wasted window scans for absent keys.

• Do I need GPUs?  
No. The models used here are tiny and run in a handful of CPU cycles. Spend your budget on layout and cache behavior.

## A minimal evaluation plan you can run this week

1. Export a sample of 100M keys from production (or a representative environment). Keep them sorted.
2. Split into train/validation (e.g., 80/20). Fit a PGM or piecewise‑linear model.
3. Measure ε on validation, distribution of window sizes, and compare to B‑tree search steps.
4. Microbench: pin CPU frequency, warm caches, and measure predicted‑window search vs B‑tree.
5. End‑to‑end: replace only the get() path on a read‑heavy service and route 1% traffic behind a flag. Track medians and tails for a week.

If you don’t see a clear win (RAM saved, medians down, tails flat), don’t ship it. Learned indexes must earn their keep like any optimization.

## The fine print: pitfalls to avoid

- Overfitting ε. A pretty validation ε can blow up on production skew or seasonality. Track it live; cap windows.
- Model drift during compaction. Don’t swap models mid‑query; use versioned routes.
- Hidden random reads. If your model lives off‑page on SSD, you defeat the purpose. Keep it in memory and colocated.
- Microbranching. A fancy model that introduces unpredictable branches can murder branch predictors. Linear pieces avoid that.
- Ignoring concurrency. Parallel lookups contend for shared structures; test under load to catch tail regressions.

## Closing: modern indexes are interfaces, not idols

A learned index is not a religion, it’s an interface with two interchangeable parts: a predictor and a verifier. When your data has shape, a compact predictor can shrink the search and make caches happy. When the shape shifts, a verifier with fallbacks keeps you correct. Ship both. Measure both. And keep the kill switch within reach.

The real win isn’t novelty; it’s choice. You can keep B‑trees where they shine and layer learned predictors where they pay—mixing tools to fit your workload’s contours. That’s systems engineering.

## Production case studies (what wins and where it hurts)

To make this concrete, here are anonymized patterns from real deployments:

- Time‑series metrics store (billions of points/day). Keys are (tenant, metric, timestamp). The CDF per (tenant, metric) is nearly linear with lunch‑time spikes. Piecewise linear segments with per‑segment ε tracked at P99 + 10% reduced index RAM ~8×. Median gets improved ~1.6×; tails stayed flat with a strict in‑window budget and fallback to a sparse fence pointer index. Retraining hourly for hot tenants, daily for cold, avoided drift. The main operational risk was segment hotspots after a tenant’s surprise cardinality explosion; auto‑splitting segments based on ε growth fixed it.
- Read‑mostly KV cache with lexicographic keys. A two‑level RMI with 256 leaf models fit in L2. Under steady traffic, lookups dropped to 2–3 cachelines on average from 6–8 in the legacy B‑tree. However, a quarterly key rollover changed prefixes and bent the CDF badly. Versioned models (old+new) with a 14‑day dual‑read period made the shift safe; then old models were retired.
- SSD‑backed object directory. A hybrid learned+fence index cut random reads by ~30%. The surprise cost: during compaction, re‑writing segment metadata caused tail bumps. Gating compaction to off‑peak windows and making model pages memory‑resident addressed the regression.

## Anti‑patterns (smells to catch in review)

- Model lives on SSD. Any design that requires random reads to fetch model parameters defeats the point. Keep parameters in RAM; co‑locate per‑segment parameters with the data page they index.
- Tiny improvements, huge complexity. If the learned path only trims 1–2 comparisons over a mature B‑tree, the extra operational risk may not be worth it. Demand a budget: RAM saved, medians improved, tails flat.
- Single global ε. Different regions of keyspace bend differently. Track ε per segment and route with a tiny root model; using one global bound turns into scanning.
- Retrain in place. Swap models under active traffic without versioning and you’ll have probes using mismatched ε. Always version, route by version, then GC.

## A readiness checklist (pre‑ship)

- [ ] Per‑segment ε metrics exported (P50/P95/P99/max)
- [ ] Fallback hit‑rate monitored and alert thresholds defined
- [ ] Budget timers for in‑window probes (micro‑budgets)
- [ ] Versioned routing, canary flag, and kill switch
- [ ] Model build pipeline with deterministic artifacts (hashes)
- [ ] Backfill tooling to rebuild models from snapshots
- [ ] Scale test including write bursts and compactions
- [ ] Runbook for drift (what to tighten, when to retrain, how to roll back)

## Beyond point lookups: ranges, composite keys, and secondary structures

Learned indexes are excellent at point predictions, but many workloads rely on range scans and complex predicates.

- Ranges. Predict start position and either predict end or scan until the predicate fails. Keep page‑level fence pointers to jump page boundaries without per‑row checks.
- Composite keys. Routable prefixes at the root, then leaf models per suffix; or learn a projection (e.g., a monotone mapping) that preserves ordering. Avoid hash‑based projections if you need order.
- Secondary structures. Pair the learned predictor with a Bloom filter for negative lookups and a tiny exception table catching keys that exceeded window budgets recently. The exception table doubles as drift telemetry.

## Where this heads next

Three promising directions:

1. CPU specialization. SVE/AVX‑512 make small vector models cheaper; expect more vectorized leaf predictors.
2. Learned routers for LSM compactions. Route keys into compaction tiers that match their observed drift; keep ε stable under churn.
3. Hybrid vector search. Use a learned index to route high‑recall candidate retrieval for vector ANN structures (HNSW/IVF), cutting the candidate set and memory traffic.

If you treat the predictor as a cacheable hint with guardrails, you can adopt learned indexes incrementally and widen their scope as evidence accumulates.
