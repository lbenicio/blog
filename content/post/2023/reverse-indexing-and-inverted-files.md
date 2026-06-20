---
title: "Reverse Indexing and Inverted Files: How Search Engines Fly"
date: 2023-07-19T10:00:00Z
description: "Tokenization, postings lists, skip pointers, and WAND: a tour of the data structures that make full‑text search fast."
tags: ["search", "information-retrieval", "indexes", "algorithms"]
categories: ["Engineering"]
draft: false
cover: "/static/images/blog/reverse-indexing-and-inverted-files.png"
coverAlt: "Inverted index diagram with vocabulary mapping to postings lists"
---

Full‑text search is a masterclass in practical data structures. The inverted index—also called a reverse index—maps terms to the list of documents in which they occur. Everything else in a production search engine is optimization: reducing bytes, minimizing random I/O, and avoiding work you don’t have to do.

In this deep dive we’ll build a complete mental model of inverted files and the techniques that make them fast:

- Parsing pipeline: tokenization, normalization, stemming/lemmatization, and multilingual realities
- Index structure: vocabulary, postings (doc IDs), term frequencies, and positions for phrase queries
- Compression: delta encoding, Variable‑Byte (VB), Simple‑8b, PForDelta, SIMD‑BP128, QMX, and how they trade space for CPU
- Skipping and acceleration: skip lists, block max indexes, WAND/BMW dynamic pruning
- Scoring: BM25, term and document statistics, field boosts, and normalization
- Updates and merges: segment architecture (Lucene‑style), in‑place deletes, and background compaction
- Caching and tiering: hot vs cold shards, result caching, and Bloom‑like structures
- Distributed search: sharding, replication, and query fan‑out under tail latency pressure
- Measuring and tuning: from recall/precision to p95 query time, heap usage, and GC pauses

By the end you’ll be able to reason about why each knob exists and which ones matter for your workload.

## 1) Parsing pipeline: from text to terms

Search begins with text, but indexes live on tokens. The pipeline typically includes:

- Tokenization: split on boundaries (whitespace, punctuation) but handle email addresses, URLs, camelCase, Unicode scripts, and languages without spaces. Regex tokenizers are fine for English; ICU or language‑aware segmenters help elsewhere.
- Normalization: case‑fold (lowercase), remove diacritics, standardize punctuation. Unicode normalization (NFKC/NFKD) avoids duplicate representations.
- Stemming vs lemmatization: stemming chops suffixes (jump → jump, jumping → jump); lemmatization maps inflected forms to dictionary lemmas. Stemming is cheap and noisy; lemmatization is cleaner but needs models.
- Stopwords: common words (“the”, “and”). Modern systems often keep them and let scoring down‑weight them; removing them can break phrase queries and proximity features.
- Token filters: synonyms (“USA” ≈ “United States”), de‑accenting, n‑grams for partial matches, and language detection to select pipelines per document.

Each field (title, body, tags) can run a different pipeline and produce separate postings with field boosts for scoring.

## 2) Inverted index structure

The vocabulary (a.k.a. dictionary) maps each unique term t to a postings list for that term. A postings list stores:

- Document IDs (docIDs) that contain t
- Term frequency tf(t, d): how many times t appears in document d
- Optional positions: the offsets of each occurrence, used for phrase/proximity queries
- Optional payloads: per‑occurrence data (e.g., offsets in original text for highlighting)

A minimal postings list may store only sorted docIDs. A richer one interleaves tf and positions. Because docIDs are sorted, delta encoding (storing gaps between IDs) shrinks space dramatically.

### Dictionary layout

Vocabularies are often stored as finite state transducers (FSTs) or prefix‑compressed tries (front‑coding), which allow fast term lookup and minimal memory. The FST also stores term metadata: total term frequency (ttf), document frequency (df), and pointers into the postings file.

## 3) Compression: the difference between fast and slow

Compression determines how many bytes you read and how much CPU you spend decoding. The classics:

- Variable‑Byte (VB): encode small integers in one byte, large ones in multiple bytes with continuation bits. Simple, branchy, popular.
- Simple‑8b: packs multiple small integers into a 64‑bit word using selector bits. Great for small gaps; branch‑light.
- PForDelta: pack most integers with a fixed bit width per block; store exceptions separately. Good balance for mixed distributions.
- SIMD‑BP128 / QMX: vectorized bit‑packing with 128‑int blocks; uses SIMD to decode many gaps at once. Outstanding throughput on modern CPUs.

For tf and positions, similar schemes apply; positions often compress well with d‑gaps (delta of positions within a doc). The right codec depends on your CPU budget and query mix. Vectorized codecs achieve eye‑watering decode speeds and reduce branch mispredicts.

## 4) Skipping and dynamic pruning

Even with tiny postings, scoring every candidate document is too slow. Two ideas save the day:

- Skip lists: every k postings, store a skip pointer with the docID at that point and a byte offset. You can “jump” ahead during conjunctive queries (AND) and phrase searches.
- Block Max Indexes (BMW): group postings into blocks; store the maximum term score for each block. If the max can’t beat the current top‑k threshold, skip the whole block.

### WAND and Block‑Max WAND

WAND (Weak AND) and its variants let you avoid scoring documents that can’t possibly enter the top‑k. Maintain an upper bound on each term’s contribution; for a candidate docID, if the sum of bounds of terms that can still match is below the k‑th best score so far, skip scoring. BMW refines this with per‑block bounds for tighter pruning. The result: orders of magnitude fewer full scores.

## 5) Scoring: BM25 and friends

At query time, a document receives a relevance score based on term matches. BM25 remains a strong baseline:

BM25(t, d) = idf(t) × (tf(t, d) × (k1 + 1)) / (tf(t, d) + k1 × (1 − b + b × |d|/avgdl))

Where idf(t) ≈ log((N − df + 0.5)/(df + 0.5) + 1), N is total docs, |d| is doc length, avgdl is average doc length, and k1, b are parameters.

Enhancements include field boosts (title > body), proximity features (terms appearing near each other), and learning‑to‑rank models that take BM25 as features. Whatever the stack, you still benefit from efficient postings, skipping, and tight upper bounds.

## 6) Updates, deletes, and segments

Real indexes change constantly. Lucene‑style engines maintain immutable segments to keep writes fast and readers simple. New documents go into a fresh segment; deletes record docIDs in a tombstone bitmap; periodic merges combine segments, applying deletes.

Benefits of segments:

- Immutable postings: safe concurrent reads with no locks.
- Background compaction: reclaim space and rewrite postings with better compression.
- Snapshotting: cheap consistent views for backups and replication.

Gotchas:

- Too many small segments hurt query speed (more seeks); too few cause long merge pauses.
- Deletes accumulate until merges; tombstone bitmaps must be checked during scoring.
- Hot updates to popular documents can fragment caches if merges churn.

## 7) Caching and tiering

Search engines mix multiple caches:

- Query result cache: memoize frequent queries (or parts of them).
- Filter caches/bitsets: store docID sets for common filters (authz, tenant, date ranges) to combine with term matches.
- Page cache and warm segments: keep hot postings in memory; cold shards spill to SSD/HDD.

Tiering places hot shards (recent data, popular languages) on fast nodes and cold shards on slower media. Precomputation (impact‑ordered lists) and soon‑to‑expire caches trade memory for CPU time.

## 8) Distributed search under tail pressure

In a cluster, a coordinator fans out a query to shard replicas, collects partial top‑k results, and merges them. Tails appear when one shard lags (GC, compaction, noisy neighbor). Mitigations:

- Hedged shard RPCs: send to a second replica after a short, adaptive delay; cancel the slower one.
- Early termination: retrieve slightly more than k results from fast shards and allow slow shards to contribute less when safe.
- Partition by popularity: keep hot terms and docs on overprovisioned hardware.
- Bound query budgets: if a shard can’t meet the deadline, return best‑effort results and degrade gracefully.

## 9) Measuring, debugging, and tuning

Track:

- p50/p95/p99 latency by query class and shard
- Cache hit rates (result and filter caches)
- GC time, segment counts, merge backlog
- Bytes read/decoded per query, WAND/BMW prune rates

Debug with per‑query traces that log which lists were touched, how many postings decoded, skips taken, and why a candidate was pruned or scored.

## 10) Practical recipes

- Use an FST for the dictionary; store df/ttf and pointers inline.
- Encode postings with SIMD‑friendly codecs; keep blocks aligned to cachelines.
- Build skip lists with per‑block max scores (BMW) to enable WAND.
- Segment writes; merge aggressively enough to cap segment count, but back off during peaks.
- Hedge shard requests after p95; cap extra load to a few percent.
- Keep a canary query set to catch regressions in pruning/decoding quickly.

Search feels like magic, but the magic is mostly mechanical sympathy: feed your CPU contiguous bytes, avoid branches, and skip the work you can prove won’t help. Inverted files give you the backbone; the rest is engineering taste.
