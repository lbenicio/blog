---
title: "The Anatomy of Time-Series Compression: Delta-of-Delta Timestamps, XOR-Encoded Floats, and the Cost of Decoding at Scale"
description: "A deep technical tour of the codec layer inside time-series databases: why delta-of-delta timestamp encoding and XOR float encoding look the way they do, where they break, and how ratio, decode throughput, and random-access granularity trade against each other."
date: "2026-08-16"
author: "Leonardo Benicio"
tags: ["time-series","compression","storage-engines","encoding","systems-design","databases"]
categories: ["Systems Design","Databases"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/the-anatomy-of-time-series-compression-delta-of-delta-timestamps-xor-encoded-floats-and-the-cost-of-d-2026-08-16.jpg"
coverAlt: "An abstract technical illustration showing sparse vertical columns of floating-point data on the left compressing into a dense, glowing ribbon of interlocking bit-blocks in cyan, amber, and magenta, ending in neatly stacked rectangular columnar blocks on the right, all on a deep indigo background."
---

Time-series databases are, at their core, compression engines with a query language bolted on. Everything that makes them fast — the retention windows measured in months, the sub-second dashboard refreshes over millions of series, the ability to keep a year of high-resolution metrics in memory — comes down to how efficiently a stream of (timestamp, value) pairs can be turned into bits and turned back again.

Metrics systems compress well for reasons that have almost nothing to do with the entropy of the numbers themselves and almost everything to do with the structure of how those numbers are produced. A scrape loop fires every fifteen seconds; a counter increments monotonically; a gauge drifts. That regularity is the raw material, and the encodings that exploit it are surprisingly specific.

This article is about the codec layer of a time-series store: how timestamps and values are turned into bits, why the popular schemes look the way they do, where they break, and what you give up when you pick one. It is not about query planning, retention policies, or downsampling, except where those interact with the encoding.

## The shape of the data

A time series is a triple: a series identity (a metric name plus a set of label pairs), a timestamp, and a value. The identity is usually stored once, in an index, and the stream is stored as a sequence of (timestamp, value) pairs. That sequence is what we compress.

Four structural properties matter.

**Timestamps are monotonic and nearly periodic.** Within a series, timestamps almost always increase. They usually arrive at a fixed interval — 10s, 15s, 60s — with small jitter from scheduling and network delay. The absolute value is large (milliseconds since epoch, on the order of 1.7x10^12 today) but the *differences* are tiny and nearly constant. Storing the absolute value wastes most of a 64-bit integer per point.

**Values are correlated with their predecessors.** Gauges — CPU utilization, queue depth, temperature — change slowly relative to the sampling rate. Counters increase by small amounts. The IEEE 754 double representation of two nearby values shares a sign bit, an exponent, and most of the mantissa's high bits. The low mantissa bits are where the noise lives.

**Per-series point counts are modest, but series counts are enormous.** A single host might emit a few thousand series; a fleet emits millions. Each series might hold a few thousand points per day. This inverts the usual assumption of a compression codec: you rarely get a multi-megabyte contiguous run per series, so per-stream dictionary state has limited payoff, and per-block overhead is amortized over a small number of points.

**The query pattern is range scans over recent time.** Dashboards ask for the last hour at full resolution, the last week at coarse resolution. A compression scheme that requires decoding an entire series from the beginning to answer a query about the last five minutes is unusable regardless of its ratio.

Those four properties push the design in a direction that looks nothing like gzip.

## Four numbers that matter

Compression discussions tend to collapse into a single number — the ratio — and that is a mistake. For a time-series store, at least four quantities trade against each other.

**Ratio.** Bytes on disk (or in memory) per point. This determines retention: how many months of data fit on the disk you bought.

**Decode throughput.** Bytes per second of decoded output, or better, points per second. This determines query latency and how much CPU a dashboard refresh costs. It is frequently the binding constraint. A codec that halves your storage but triples the CPU per scan is a bad trade in a system that is CPU-bound and I/O-idle.

**Encode throughput.** Points per second on the ingest path. Ingest is usually cheaper than query because it happens once, but a codec with a branchy, unpredictable encoder can still become the bottleneck at high cardinality.

**Random-access granularity.** The smallest unit you can decode without touching the rest of the stream. If your unit is a 4 KiB block of 500 points, a query for 10 points decodes 500. If your unit is the whole series, you have a problem.

There is a fifth, less discussed property: **the worst-case bound.** A variable-length encoding that is excellent on typical data can expand pathological input. Timestamps that arrive out of order, a gauge that oscillates across many orders of magnitude, or a counter that resets every sample can all push a clever codec past its raw representation. Production codecs need a fallback path, and the fallback needs to be cheap to detect.

These numbers are not independent. Delta-of-delta timestamp encoding is cheap to decode and gives a large ratio win, so it is nearly universal. XOR float encoding gives a large ratio win but costs a data-dependent number of bits and a branchy decoder, so it is common but not universal. Frame-of-reference bit packing is fast and predictable in both directions but assumes bounded ranges, which real metrics violate.

## Why general-purpose codecs are the wrong tool

The obvious first attempt is to serialize points as text or binary rows and hand the result to LZ4, zstd, or Snappy. This works, in the sense that it produces a smaller file. It is usually the wrong answer for three reasons.

First, **the redundancy is not byte-aligned**. LZ-style compressors find repeated byte sequences. Two consecutive float64 values that differ only in their low 20 mantissa bits share their first five bytes and differ in the rest; a byte-oriented matcher sees a five-byte match and then a mismatch. The gain is real but partial, and it degrades exactly where time-series data is most compressible — in the low mantissa bits, which are noise.

Second, **the entropy coder is the wrong model**. Huffman and FSE-style entropy coders model symbol frequency. Time-series values are not drawn from a stationary symbol distribution; they are a smooth function plus noise. The right model is a predictor plus a residual, and the right residual encoding is bit-packing or variable-length integer coding, not symbol coding.

Third, **the block structure fights random access**. Generic codecs compress fixed-size blocks (zstd's default is 128 KiB) and require the whole block to decompress. For a 15-second scrape interval, a 128 KiB block holds tens of thousands of points, so answering a query for a few hundred points decodes all of them. zstd does allow smaller blocks and has a seekable format with skippable frames, but you then pay per-block dictionary overhead on a small number of points.

None of this means generic codecs are useless in a time-series system. They are excellent for the label index, for WAL segments, and for cold, rarely-queried historical data where decode throughput does not matter. They are simply the wrong layer for the hot path.

## Timestamps: delta, then delta-of-delta

The first-order fix is trivial. Store the first timestamp in full, then store differences:

```
t0 = 1700000000000
d1 = 15000
d2 = 15000
d3 = 15001
```

If the scrape interval is fixed, every delta is the same number, and the second-order differences — delta-of-delta, or DoD — are zero. That is the observation the Gorilla encoding exploits: encode DoD with a variable-length prefix, spending a single bit when the interval is exactly regular.

Gorilla's specific scheme uses a prefix code over the DoD value:

| Prefix | Meaning | Payload bits |
|---|---|---|
| `0` | DoD == 0 | 0 |
| `10` | DoD in [-63, 64] | 7 |
| `110` | DoD in [-255, 256] | 9 |
| `1110` | DoD in [-2047, 2048] | 12 |
| `1111` | anything else | 32 |

The asymmetric ranges are deliberate: they account for the sign bit without spending one, so the small-range cases cover 128 and 512 distinct values respectively.

The economics are stark. A perfectly regular series costs one bit per point — 0.125 bytes, against 8 bytes for a raw int64. A series with a few milliseconds of jitter typically lands in the 7-bit bucket, costing about a byte per point. Only genuinely irregular timestamps — event streams, sparse sensors, out-of-order writes — fall through to the 36-bit worst case, which is *worse* than storing the raw delta.

That worst case is the design's main liability, and it is why production implementations rarely use the Gorilla prefix code verbatim. Three common adaptations:

**Bound the damage with a block-level fallback.** Encode a block with the variable-length scheme; if the result exceeds the raw size, discard it and store the block's timestamps as a plain bit-packed array of deltas with a per-block base. The check is cheap and the fallback is predictable.

**Use frame-of-reference bit packing instead.** For each block, compute the minimum delta, subtract it, and bit-pack the residuals at a width determined by the block maximum. This is O(1) per point to encode and decode, SIMD-friendly, and has a hard worst-case bound of `ceil(log2(range))` bits per point. It gives up the 1-bit case for perfectly regular data but avoids the 36-bit case entirely.

**Exploit the interval explicitly.** If a series is known to be regular — the writer declares a step — store the step once and store exceptions as (index, timestamp) pairs. This is the approach taken by several columnar time-series formats, and it makes the common case free.

The choice between these hinges on how much you trust the writer. Declared intervals are the cheapest encoding and the most fragile: a single late sample forces an exception record, and a writer that lies about its interval produces a pathological stream.

## Values: XOR encoding and the leading/trailing-zero window

Timestamps have an obvious predictor — the previous timestamp plus the interval. Values do not, but they have something almost as good: the previous value.

Gorilla's value encoding XORs each value with its predecessor and encodes the result. The insight is that for a slowly varying double, the XOR has long runs of leading zeros (the sign, exponent, and high mantissa bits that agree) and long runs of trailing zeros (the low mantissa bits that happen to agree). You only need to store the bits in between.

The encoding, per point:

- If `xor == 0`, emit a single `0` bit. The value is unchanged.
- Otherwise emit `1`, then a control bit.
  - Control bit `0`: reuse the leading-zero and trailing-zero counts from the previous non-zero XOR, and write only the "meaningful" bits.
  - Control bit `1`: write 5 bits of leading-zero count, 6 bits of meaningful-bit length, then the meaningful bits.

The reuse case is where the ratio comes from. Consecutive samples of a gauge typically share the same window — the same exponent, the same high mantissa bits — so after the first sample in a run, each point costs 2 bits of control plus the meaningful bits. A float that changes by one part in 2^20 needs about 20 meaningful bits, so roughly 22 bits per point, or 2.75 bytes. The Gorilla design paper reports an average of roughly 1.4 bytes per point across Facebook's production metrics, which implies that in practice many points fall into the 1-bit unchanged case or a narrow window.

Two details matter for correctness.

**Signed zero.** `+0.0` and `-0.0` are distinct bit patterns with the same numeric value. XORing them yields a non-zero result, so the "unchanged" fast path misses. This is harmless for correctness if you compare bit patterns consistently, but it breaks the assumption that numerically equal values encode identically.

**NaN.** NaN has many bit patterns. A payload-carrying NaN compared to itself is not equal, so any encoder that uses `==` to detect the unchanged case will treat a stable NaN as changing every sample. Compare bit patterns, not values.

The XOR scheme also degrades gracefully into "not much better than raw" rather than into expansion: the worst case is 1 + 1 + 5 + 6 + 64 = 77 bits, which is worse than 64 but not catastrophic, and it only occurs when consecutive values share no leading or trailing bits at all.

## Bit-level mechanics

Both encodings are bit-oriented, and that has consequences for implementation. A bit-at-a-time writer with a branch per bit is simple and slow; in practice the encoder accumulates into a 64-bit word and flushes when it fills, and the decoder maintains a bit position and reads with shifts and masks. The control flow is the interesting part: the decoder's branch on the control bit is data-dependent and therefore unpredictable on mixed workloads, which is why decoder throughput varies so much with the shape of the data. A block of steady gauges decodes at a very different rate than a block of jittery latency samples, even though the code path is identical.

That variability is the reason the next sections matter. Once you have a bit-level codec, you have to decide what a "block" is, how you index into it, and how you keep the decoder's branch predictor from destroying your query throughput.

## Blocks, chunks, and the unit of random access

A bit-level codec that encodes an entire series as one continuous bitstream is a compression win and an operational disaster. To decode point 10,000 you must decode points 0 through 9,999. The fix is to partition the stream into independently decodable blocks. This is the single most consequential structural decision in the codec, because it sets the floor on both storage overhead and query cost.

A block is a contiguous run of points that shares a header and can be decoded without reference to any other block. The header must contain enough state to start decoding: the first timestamp, the first value, and any per-block parameters. For timestamp delta-of-delta, the first two deltas are needed to reconstruct the first DoD. For value XOR, the first value is needed as the XOR predecessor. If the block uses frame-of-reference bit packing, the header carries the base timestamp, the base value, and the bit widths.

The header is pure overhead. A minimal header might be 8 bytes for the first timestamp, 8 bytes for the first value, 8 bytes for two deltas, and a few bytes for lengths and flags. Call it 32 bytes. If a block holds 120 points, that is 0.27 bytes per point — comparable to the entire compressed payload of a regular timestamp stream. If a block holds 1,024 points, the header cost drops to 0.03 bytes per point, but the random-access granularity becomes coarse: a query for 10 points decodes 1,024.

The tradeoff is not linear. Block size affects four things at once:

- **Header amortization.** Larger blocks reduce per-point header overhead.
- **Random-access amplification.** Larger blocks force more decoding per query.
- **Index size.** Each block needs an entry in the sparse index: minimum timestamp, maximum timestamp, file offset, and compressed length. That entry might be 24 bytes. At 120 points per block, the index costs 0.2 bytes per point; at 1,024 points, it costs 0.023 bytes per point.
- **Cache behavior.** Decoding a block touches its compressed bytes and writes decoded values. A block that fits in L1 or L2 is much cheaper than one that streams through memory.

There is no universal answer. The right block size depends on the query granularity the system promises. If dashboards routinely ask for five-minute windows, a block that spans two hours is wrong. If queries are analytical scans over days, small blocks waste CPU on headers and index lookups. A common compromise is a block that holds between 120 and 512 points, which at a 15-second scrape interval spans 30 minutes to 2 hours. Systems that support high-resolution ad-hoc queries tend toward smaller blocks; systems optimized for long-range aggregation tend toward larger ones.

The block boundary also determines what happens when a series is irregular. If a series has gaps — a scrape failure, a host reboot — the encoder can either emit a block with a large delta-of-delta or start a new block. Starting a new block resets the delta state and pays the header cost, but it prevents one outlier from poisoning the rest of the block. Many implementations cap the DoD range and start a new block when the gap exceeds it. The result is that the block size is not fixed; it is a maximum, and the actual number of points per block varies with the data.

This variability complicates the index. If every block has exactly 1,024 points, the index can be implicit: block *i* starts at point *i* × 1,024. If blocks are variable, the index must store the first timestamp of each block, and the query planner binary-searches on those timestamps. The index itself becomes a compressed structure, often delta-encoded and bit-packed, because it is read on every query. An uncompressed index of 24 bytes per block can easily exceed the size of the data for short series.

Short series are the pathological case. A series with 20 points cannot amortize a 32-byte header. If the system stores millions of such series — ephemeral containers, short-lived jobs — the per-series overhead dominates. Some systems solve this by inlining very short series directly into the index, storing the points uncompressed or with a simplified encoding. Others group multiple series into a shared block, which complicates random access but amortizes the header. The choice depends on how much of the workload is short-lived. In a Kubernetes cluster where pods restart frequently, short series are the norm, not the exception.

## The decoder's branch problem and the serial dependency of XOR

Once the block structure is fixed, the decoder's inner loop determines throughput. Both DoD and XOR decoding are bit-oriented and data-dependent, and that combination is hostile to modern CPUs.

Consider the DoD prefix decoder. It reads a few bits, looks at the prefix, and branches to one of five cases. The branch is predictable when the data is regular — a steady scrape interval always takes the same path — but a mixed workload of regular and irregular series will mispredict. Each misprediction costs 10 to 20 cycles. If the decoder processes one point per branch, that is a large fraction of the total cost.

The standard mitigation is a lookup table. Read the next 4 bits, index into a table that returns the prefix length and the value's bit width, then read the payload. This replaces a branch chain with a table lookup and a shift. The table is small enough to stay in L1. The same trick applies to the XOR control bit: a table can map the control bit and the next few bits to a decode path, though the variable-length payload makes it less clean.

The XOR decoder has a deeper problem: a serial dependency. Each value is XORed with the previous value, so value *i* cannot be reconstructed until value *i-1* is known. The bitstream parsing is also serial: the number of bits consumed by point *i* depends on the leading-zero and meaningful-bit counts, which are stored in the stream itself. You cannot know where point *i+1* starts until you have decoded point *i*.

This serial dependency caps parallelism. A single decoder core can only go so fast, and adding cores does not help within a single series unless you split the series into blocks and decode blocks in parallel. That is another reason block structure matters: blocks are the unit of parallel decode. If a query touches 100 blocks, a thread pool can decode them concurrently. If a query touches one block, it is stuck on one core.

There is a way to break the XOR dependency, but it costs storage. If the encoder stores the XOR residuals separately from the reconstructed values, the decoder can parse residuals in parallel and then compute a prefix XOR. Prefix XOR is associative, so it can be vectorized with a scan. But the bitstream parsing remains serial because the residual lengths are variable. You can only parallelize the prefix XOR after you have parsed the residuals, which is the expensive part. In practice, the serial parse dominates, and the prefix XOR is cheap.

The DoD decoder has a similar but weaker dependency. The absolute timestamp is a prefix sum of deltas, and the deltas are a prefix sum of DoDs. Both are associative scans. If the encoder stored DoDs as fixed-width integers, the decoder could parse them in parallel and use SIMD prefix sums. The variable-length prefix code is what prevents this. This is the fundamental tension: variable-length codes buy ratio, and fixed-width codes buy throughput.

Some systems resolve the tension by using two codecs. The hot path — recent data, frequently queried — uses a fixed-width or frame-of-reference encoding that is SIMD-friendly. The cold path — historical data, rarely queried — uses the variable-length Gorilla-style encoding for maximum ratio. The transition is a background compaction job. This gives the best of both worlds at the cost of complexity and a write amplification during compaction.

The decoder's branch behavior also depends on the data distribution. A block of CPU utilization values changes slowly, so the XOR has a stable leading-zero window and the reuse path is taken repeatedly. The branch is predictable. A block of request latency values is noisy, so the window changes frequently and the branch mispredicts. The same code runs at different speeds on different series. This is why benchmarks that report a single decode throughput number are misleading. The number depends on the mix of series, and the mix changes with the workload.

## Decode amplification and the cost of query shape

Decode amplification is the ratio of points decoded to points returned. It is the hidden cost of block-based compression, and it is often larger than the compression ratio is small.

Suppose a system uses 512-point blocks. A dashboard queries the last five minutes at a 15-second scrape interval. That is 20 points. The query planner finds the block containing those points and decodes all 512. The amplification is 25.6x. If the block is 1,024 points, the amplification is 51.2x. If the block is 120 points, the amplification is 6x.

Amplification multiplies the decode cost. If decoding costs 10 CPU cycles per point, a query for 20 points costs 5,120 cycles with a 512-point block. At 3 GHz, that is 1.7 microseconds per series. For a query that touches 10,000 series, that is 17 milliseconds of pure decode overhead, even though the result set is only 200,000 points. The aggregation itself might be faster than the decode.

The amplification is not always bad. If the query is a range scan over the entire block, the decoded points are all used. The problem is point queries and short range queries, which are common in alerting and in high-resolution dashboards. Alerting rules often evaluate a single series over a short window; if the block is large, the alert evaluation decodes far more than it needs.

There are three ways to reduce amplification:

**Smaller blocks.** This directly reduces the number of decoded points per query, at the cost of more headers and a larger index. The optimal block size for a given workload is the one that minimizes total cost: decode amplification plus header overhead plus index lookup cost. For a workload with many short queries, the optimum is small. For a workload with long scans, the optimum is large.

**Sub-block indexing.** Some formats store a mini-index within each block, recording the bit offset of every *k*-th point. The decoder can seek to the nearest mini-index and start decoding from there, skipping the earlier points. This reduces amplification without reducing the block size. The mini-index costs bits, but it is much cheaper than a full block header. For a 512-point block, a mini-index every 32 points adds 16 entries, each maybe 2 bytes, for 32 bytes per block — 0.06 bytes per point. That is a good trade for short queries.

**Query-aware block sizing.** The encoder can choose block boundaries based on the series' query history. If a series is frequently queried over short windows, use small blocks. If it is only scanned in bulk, use large blocks. This is adaptive and complex, but it can be effective in systems with stable query patterns.

Decode amplification also interacts with caching. If the decoded block is cached, subsequent queries over the same block are cheap. But caching decoded points is expensive: a 512-point block of float64 values is 4 KiB, and a series with a year of data at 15-second intervals has about 2 million points, or 16 MB of decoded values. Caching decoded values for millions of series is impossible. Systems cache compressed blocks instead, and pay the decode cost on every query. This is why decode throughput is often the binding constraint: the compressed data fits in memory, but the decoded data does not.

## Encoding cost, out-of-order writes, and the write path

The decode path gets most of the attention, but the encode path has its own constraints. Ingest is a high-volume, latency-sensitive operation. A codec that is cheap to decode but expensive to encode can still be the wrong choice if it limits ingest throughput.

The XOR encoder is simple per point: XOR the current value with the previous, count leading and trailing zeros, and write the bits. The expensive part is maintaining per-series state. For each active series, the encoder must remember the previous value, the previous timestamp, the previous delta, and the current leading-zero window. At high cardinality — millions of active series — that state is large. If each series requires 64 bytes of encoder state, a million series require 64 MB, which is manageable. Ten million series require 640 MB, which is not. The state must be evicted and reconstructed, or the encoder must be stateless per block.

The DoD encoder has a similar state requirement: the previous timestamp and the previous delta. It also assumes monotonic timestamps. If a point arrives with a timestamp earlier than the previous point, the delta is negative, and the DoD can be large. The encoder can either reject the point, buffer it for sorting, or encode it as an out-of-order exception. Each choice has consequences.

Rejecting out-of-order points is simple but loses data. Buffering for sorting adds latency and memory. Encoding out-of-order points as exceptions is the most flexible, but it complicates the block format. The block must store the exception's index and timestamp, and the decoder must apply it during reconstruction. If out-of-order writes are rare, the exception path is cheap. If they are common — for example, if multiple writers scrape the same series with different clocks — the exception list can dominate the block.

Out-of-order writes also break the append-only assumption of block compression. If a new point belongs in the middle of an existing block, the block must be rewritten. This is write amplification: one new point can force re-encoding an entire block. Some systems avoid this by keeping a small in-memory buffer of recent points and only compressing them into a block when the block is full and the points are known to be in order. The buffer is queried directly, so recent data is uncompressed or lightly compressed. This is the head-block design used by many time-series databases: a small, mutable head block for recent data, and immutable, compressed blocks for older data. The head block trades ratio for write flexibility and query latency.

The write path also determines how quickly a series becomes queryable. If ingest writes to a write-ahead log and then compresses into blocks asynchronously, there is a delay between the point arriving and the point being visible to queries. If the delay is too long, dashboards show stale data. If the compression is done synchronously, ingest throughput suffers. The codec's encode throughput directly sets the maximum ingest rate per core.

Finally, the write path must handle counter resets. A counter that resets to zero produces a large negative delta. In a delta-of-delta timestamp encoding, this is irrelevant, but in a value encoding that assumes monotonicity, it is a problem. The XOR encoder does not assume monotonicity, so it handles resets naturally: the XOR of a large value and zero has many leading zeros, and the encoding is efficient. This is one reason XOR is preferred over integer delta for values: it is agnostic to the direction of change.

These write-path considerations are often invisible in compression benchmarks, which measure ratio and decode throughput on static data. In production, the codec must survive out-of-order writes, counter resets, high cardinality, and variable block sizes. The best codec is not the one with the highest ratio; it is the one whose worst case is acceptable for the workload's write and query patterns.

## Integer values and the delta alternative

Time-series values are not always floating-point. Counters, gauges that are counts, and many infrastructure metrics are integers. For integer values, XOR encoding is often suboptimal because the bit patterns of small integers have many leading zeros, but XORing two nearby integers can produce a value with many trailing zeros only if they share low bits. Delta encoding is more natural: store the difference between consecutive values. If the counter increments by 1, the delta is 1, which is a single bit. If the gauge drifts by a few units, the delta is small. The residual distribution is centered near zero, so zigzag encoding maps it to an unsigned integer, and bit-packing or variable-byte encoding stores it efficiently.

The complication is counter resets. A monotonic counter that resets to zero produces a large negative delta. The encoder must detect the reset and either store a flag or start a new block. Some systems store a reset marker as a special value; others use a separate reset count. The decoder applies the reset when reconstructing. If resets are rare, the overhead is negligible. If resets are frequent — for example, a counter that resets on every process restart — the delta encoding performs poorly and XOR may be better.

Delta encoding also composes with timestamps. If both timestamps and values are delta-encoded, the block format can be symmetric: two streams of residuals, each with its own bit-packing or variable-length scheme. This symmetry simplifies the codec but ignores the different statistical properties of timestamps and values. Timestamps are nearly periodic, so their second-order differences are near zero. Values are often random walks, so their first-order differences are near zero but not constant. Using DoD for values would amplify noise; using first-order delta for timestamps would miss the regularity. The right order of differencing depends on the signal.

For integer values, the choice between XOR and delta is not obvious. XOR is branchy but handles resets and sign changes without special cases. Delta is simpler and faster but requires reset handling and a zigzag mapping. In practice, many systems use XOR for floating-point values and delta for integer values, dispatching on the series type. The dispatch itself is a metadata decision: the series schema declares its value type, and the codec follows.

## Frame-of-reference and the SIMD bit-packing family

The Gorilla-style codecs are variable-length and serial. The opposite design is frame-of-reference (FOR) bit packing, which is fixed-length and parallel. FOR takes a block of integers, computes the minimum, subtracts it, and stores the residuals at a fixed bit width determined by the maximum residual. If the block's values span a narrow range, the width is small; if they span a wide range, the width grows. The decoder reads the width once and then unpacks every residual with the same operation.

Fixed-width unpacking is amenable to SIMD. A 128-bit vector register can unpack 32 4-bit values, 16 8-bit values, or 8 16-bit values in a few instructions. The bit widths are not always powers of two, so the unpacking requires shifts and masks, but the operations are branchless and regular. Libraries like SIMD-BP128 and FastPFor implement these kernels and achieve decode throughputs of several billion integers per second per core. That is orders of magnitude faster than a bit-at-a-time Gorilla decoder.

The cost is ratio. FOR cannot represent a single outlier without widening the entire block. If one value in a block of 1,024 is 10 times larger than the rest, the bit width grows by 4 bits, and every value pays. Variable-length codes handle outliers gracefully by spending more bits only on the outlier. This is the classic ratio-throughput tradeoff, and it explains why FOR is common in analytical column stores and less common in time-series stores that need maximum ratio.

A middle ground is patched frame-of-reference (PFOR). The block is encoded with a base width, and outliers are stored in an exception list. The decoder unpacks the base-width values and then patches the exceptions. PFOR gets most of FOR's speed and most of variable-length's ratio, at the cost of a more complex decoder and a data-dependent exception list. For time-series data with occasional spikes, PFOR can be a good fit.

Another family is byte-oriented: variable-byte, group varint, and Stream VByte. These encode integers in 1 to 5 bytes, with the length determined by the value's magnitude. They are faster than bit-level codes because they operate on bytes, but they waste bits when values are small. Stream VByte separates the control bytes from the data bytes, which allows SIMD decoding of the lengths. For timestamp deltas that are usually one or two bytes, Stream VByte can be competitive with bit packing.

The choice between bit-level and byte-level coding depends on the distribution of residuals. If residuals are small and uniform, bit packing wins. If residuals are highly variable, byte-oriented or variable-length wins. Time-series timestamps are small and uniform, so bit packing and DoD prefix codes both work. Values are more variable, so XOR or PFOR may win.

## Error propagation, checksums, and recovery

Bit-level codecs are fragile. A single flipped bit in a variable-length prefix can change the decoded length of the current point, which shifts the bit position for every subsequent point. The decoder does not resynchronize; it produces garbage for the rest of the block. The XOR value encoding is worse: because each value depends on the previous, a corrupted residual corrupts all following values in the block. The DoD timestamp encoding has a similar but weaker propagation: a corrupted delta shifts all subsequent timestamps, but the deltas themselves may still decode correctly if the prefix code is self-synchronizing. It is not. A corrupted prefix can consume the wrong number of bits and desynchronize the stream.

This fragility is why production formats never store raw compressed blocks without integrity checks. Every block carries a checksum, usually CRC32C or xxHash, computed over the compressed bytes. The decoder verifies the checksum before decoding. If it fails, the block is marked corrupt and the query returns an error or skips the block. The checksum costs 4 or 8 bytes per block, which is negligible compared to the header.

The block structure limits the damage. A corrupted block affects only the points in that block; other blocks decode normally. This is another argument for smaller blocks: they reduce the blast radius of corruption. But smaller blocks also mean more checksums and more headers, so there is a tradeoff. A typical block size of a few hundred points keeps the corruption blast radius to a few minutes of data at a 15-second scrape interval.

Recovery is harder. If the checksum fails, the original data is lost unless there is a replica or a write-ahead log. Some systems keep a copy of the raw points in the WAL for a retention period, allowing reconstruction of recent blocks. Older blocks rely on replication. The codec itself cannot recover from corruption because the compressed representation has no redundancy. This is a fundamental difference from error-correcting codes: compression removes redundancy, so there is nothing left to correct with. Integrity checks detect corruption; they do not repair it.

Torn writes are a related concern. If a process crashes while writing a block, the block may be partially written. The checksum will fail, and the block is discarded. The WAL ensures that the points are not lost; they are replayed and re-encoded. This is why the write path often writes to a WAL before compressing into blocks. The WAL is usually compressed with a generic codec like LZ4, which is fast and has its own checksums. The block codec is applied later, during compaction.

## The memory hierarchy and decode throughput

Decode throughput is not just a function of instruction count. It is a function of where the data lives. A compressed block that fits in L1 cache decodes much faster than one that must be fetched from DRAM. The compressed data is small, so it often fits in cache. The decoded data is large, so it often does not. The decoder streams decoded values to the aggregation or to the query result, and if the aggregation is simple, the decoded values may never be written to memory. This is a crucial optimization: decode and aggregate in one pass, keeping decoded values in registers or L1.

Memory bandwidth becomes the limit when the decoded output is written to a buffer. A 512-point block of float64 values is 4 KiB. Decoding a million points produces 8 MB of output. At 20 GB/s of memory bandwidth, writing 8 MB takes 0.4 ms. The decode itself might take 1 ms. So memory bandwidth is not always the bottleneck, but it can be if the decoder is fast. SIMD decoders can saturate memory bandwidth, which is why they benefit from streaming stores and cache blocking.

NUMA adds another dimension. On a multi-socket machine, the compressed data may be in memory attached to one socket, and the decoder thread may run on another. The remote memory access is slower. Time-series databases often shard series across sockets or pin threads to sockets to avoid this. The codec itself does not control NUMA placement, but the block size affects how much data is fetched per remote access. Larger blocks amortize the remote access over more points.

Prefetching helps. The decoder can prefetch the next block while decoding the current one. Because blocks are independent, the prefetch is straightforward. The query planner knows which blocks will be needed, so it can issue prefetches ahead of time. This hides memory latency and improves throughput. It also increases memory-level parallelism, which is often the real limit on modern CPUs.

The serial dependency of XOR decoding limits instruction-level parallelism. The CPU can execute multiple independent instructions per cycle, but the XOR decoder's dependency chain forces it to wait. The DoD decoder has a similar chain through the prefix sum of deltas. SIMD and superscalar execution cannot help with a strict dependency chain. This is why block-parallel decoding is so important: it gives the CPU independent work to do. If a query touches many blocks, the decoder can process them in parallel and hide the serial latency of each block.

## Adaptive codec selection and per-block metadata

No single codec is best for all series. A regular timestamp stream with slowly changing gauges compresses well with DoD and XOR. A sparse event stream with irregular timestamps and constant values compresses better with run-length encoding or a simple delta. A series of integers with a narrow range compresses better with FOR. A production system can choose the codec per block, encoding a small header that identifies the codec and its parameters.

The encoder can try multiple codecs and pick the smallest result. This is expensive but can be done during compaction, where CPU is cheaper than on the ingest path. The trial encodes a block with two or three candidate codecs, compares the compressed sizes, and writes the winner. The header stores a codec ID. The decoder dispatches on the ID. The overhead is a few bits per block and the CPU cost of trial encoding.

Adaptive selection handles pathological data gracefully. If a series has a counter reset, the delta codec performs poorly, but XOR may still be good. If a series is constant, run-length encoding collapses it to a few bytes. If a series has a single outlier, PFOR handles it better than FOR. The encoder does not need to be perfect; it needs to avoid the worst case. A simple heuristic — try DoD+XOR and a fallback raw encoding, pick the smaller — already bounds the worst case.

Metadata is the cost. Each block needs a codec ID, a bit width, a base value, a base timestamp, and lengths. This metadata is stored per block and must be read on every query. If the metadata is large, it reduces the ratio gain. A compact encoding for metadata is important. For example, the codec ID can be 2 bits, the bit width 6 bits, and the base values stored as varints. The metadata is then a few bytes per block, which is acceptable.

Some systems go further and use per-series metadata. The series schema declares the value type and the expected interval. The encoder uses this to choose a codec without trial encoding. This is faster but less adaptive. If the writer lies about the interval, the codec degrades. A hybrid approach uses the schema as a hint and falls back to trial encoding when the hint is wrong.

## Query-aware compression and late materialization

The codec does not exist in isolation. It interacts with the query engine. A query that filters on time can skip blocks whose timestamp range does not overlap the query. This is block pruning, and it is the main way time-series databases avoid decoding irrelevant data. The sparse index stores the minimum and maximum timestamp of each block, so the query planner can binary-search the index and read only the overlapping blocks. The codec's block size determines the granularity of pruning. Smaller blocks allow finer pruning but larger index.

A query that filters on value is harder. The compressed values are not directly comparable to a predicate. The decoder must decompress the block to evaluate the filter. Some formats store zone maps — min and max values per block — to allow value-based pruning. If the query asks for values above a threshold, blocks whose maximum is below the threshold can be skipped. Zone maps are cheap to store and can dramatically reduce decode work for selective queries. They are especially effective for gauges that stay within a narrow range.

Late materialization is the practice of decoding only the columns and blocks needed for the query, and only at the point where the values are used. In a columnar time-series store, timestamps and values are separate streams. A query that aggregates values without needing timestamps can decode only the value stream. A query that filters on time can decode only the timestamp stream, find the matching indices, and then decode the corresponding value ranges. This reduces decode work but complicates the block format: the value stream must be independently decodable, which means it needs its own block boundaries or a sub-index.

Aggregation over compressed data is the holy grail. If the codec allowed summing values without full decompression, queries would be much cheaper. In practice, this is only possible for simple encodings. Run-length encoded constant values can be aggregated by multiplying the value by the run length. Delta-encoded integers can be summed using prefix sums, but the decoder still must parse the deltas. XOR-encoded floats cannot be aggregated without decompression because XOR is not linear. This is a fundamental limitation: the more aggressive the compression, the less the query engine can do without decoding.

Vectorized execution and the codec are complementary. The decoder produces batches of values, and the execution engine processes them with SIMD. If the decoder itself is SIMD, the two stages can be fused, avoiding intermediate buffers. Fusing decode and aggregation is a common optimization in high-performance time-series engines. It requires the decoder to expose an iterator interface that the aggregation can consume, rather than materializing an array. The iterator abstraction hides the bit-level details but allows the aggregation to be written once for all codecs.

## The Economics of Decode: Cycles, Bytes, and Dollars

Decode throughput numbers in a paper or a README are almost always measured on a single core, with warm caches, on a synthetic stream that matches the codec's sweet spot. Production is not that. A query in a real system runs on a machine that is simultaneously ingesting new points, compacting old blocks, serving other queries, and competing for memory bandwidth. The codec's cost must be understood as part of a system cost, not as an isolated kernel.

The first step is to stop thinking in bytes per second and start thinking in cycles per point, because that is what you can measure and what translates to CPU time. A decode kernel that processes one point per branch has a cost dominated by branch mispredictions when the data is irregular. A kernel that processes one point per table lookup has a cost dominated by cache misses if the table is large. A SIMD kernel has a cost dominated by the number of instructions and the memory bandwidth to load the compressed bytes and store the decoded values. These are different cost profiles, and they respond differently to the shape of the data.

To build a cost model, you need three distributions: the distribution of query shapes (how many points returned, how many blocks touched), the distribution of data shapes (how regular the timestamps are, how noisy the values are), and the distribution of hardware states (cache hit rates, memory bandwidth contention). In practice, you approximate. You measure the average cycles per point for a few representative series, and you multiply by the decode amplification. You measure the tail latency for the worst series, and you decide whether it is acceptable.

The economic tradeoff is straightforward once you have the numbers. Suppose a codec that gives 2x better ratio costs 3x more CPU per point. If your workload is I/O-bound — the compressed data does not fit in memory and you are reading from disk or object storage — the better ratio wins because it reduces the bytes you must fetch. If your workload is CPU-bound — the compressed data fits in memory and you are limited by decode throughput — the faster codec wins even if it uses more storage. The break-even point depends on the ratio of storage cost to CPU cost, which varies by deployment: on-premise hardware has a fixed cost and you want to maximize utilization, while cloud storage and CPU are metered separately.

Cloud pricing makes the tradeoff explicit. Object storage costs on the order of a few cents per gigabyte per month. A vCPU-hour costs on the order of a few cents. If a codec saves 1 GB of storage per month but costs an extra 0.1 vCPU-hour per day to decode, the storage saving is small and the CPU cost is large. The opposite can happen if the data is cold and rarely decoded: then the storage saving dominates. This is why tiered storage and per-tier codec selection are not just an optimization; they are an economic necessity.

Benchmarking pitfalls are everywhere. A microbenchmark that decodes a single block in a tight loop ignores the cost of fetching the block, the cost of aggregating the decoded values, and the cost of writing the query result. A benchmark that uses a single thread ignores the fact that production queries are parallel and that the bottleneck may be the thread pool or a shared cache. A benchmark that uses synthetic data with a fixed distribution ignores the fact that real series have different distributions, and the codec's performance varies with the distribution. The only benchmark that matters is an end-to-end one that replays a realistic query workload against a realistic data set.

The worst-case cost is often more important than the average. A codec that is 10% faster on average but occasionally takes 100x longer on a pathological block will produce tail latency that violates SLOs. The pathological block might be a series with a counter reset, a gap, or a sudden spike. The decoder's branch predictor fails, the bitstream desynchronizes, or the fallback path is slow. Production systems need a bounded worst case, which usually means a fallback to a simple encoding when the clever one fails. The fallback must be cheap to detect and cheap to decode.

The cost of decoding at scale is therefore not a single number. It is a function of the data, the query, the hardware, and the economic constraints. The codec designer's job is to make that function as flat as possible: good ratio on typical data, acceptable ratio on pathological data, and predictable decode cost across the board. The rest of the system — block sizing, caching, tiering, compaction — is about managing the variance.

## Lifecycle of a Block: Compaction, Tiering, and Re-Encoding

A compressed block is born when a writer flushes a batch of points. It lives in a head block or a write-ahead log for a short time, then it is compacted into a larger block, then it is moved to a colder tier, and eventually it is deleted when its retention window expires. Each stage can change the codec, the block size, and the storage medium. The codec must survive this lifecycle without requiring a full rewrite of the entire data set every time the format changes.

Compaction is the process of merging small blocks into larger ones and re-encoding them. It serves several purposes: it reduces the number of blocks and therefore the index size, it removes deleted series and expired points, and it can switch to a more efficient codec for older data. Compaction is CPU-intensive because it decodes the old blocks and encodes the new ones. It competes with queries for CPU and memory bandwidth. In a busy system, compaction must be throttled or scheduled during low query load.

Write amplification is the hidden cost. A point may be written to the WAL, then to a head block, then to a compacted block, then to a cold tier. Each write is a copy, and each copy consumes I/O and CPU. Compression reduces the size of each copy, which reduces I/O, but it increases the CPU cost of re-encoding. The net effect depends on the ratio of I/O cost to CPU cost. On fast NVMe storage, CPU is often the bottleneck, so aggressive compaction can hurt. On object storage, I/O is the bottleneck, so compaction that reduces bytes is valuable even if it costs CPU.

Tiering is the practice of storing data on different media based on access frequency. Hot data — the last few hours — lives in memory or on NVMe and is queried frequently. Warm data — the last few weeks — lives on SSD and is queried occasionally. Cold data — months or years — lives on object storage and is queried rarely, usually during incident investigations or compliance audits. Each tier has a different cost profile, and the codec should be chosen accordingly.

On the hot tier, decode latency matters most. The codec should be fast to decode, even if the ratio is modest. Frame-of-reference bit packing or a simple delta encoding is often a good choice because it is SIMD-friendly and has a predictable cost. On the warm tier, the tradeoff is balanced. Gorilla-style DoD and XOR give a good ratio and acceptable decode speed. On the cold tier, ratio matters most because storage and network transfer dominate. The codec can be more aggressive, using larger blocks, more complex predictors, and entropy coding on top of the residuals.

Re-encoding between tiers is a background job. It reads blocks from the warmer tier, decodes them, encodes them with the colder tier's codec, and writes them to the colder tier. The job must be idempotent and restartable, because it can take hours or days for a large data set. It must also handle the case where a query reads a block that is being re-encoded. The standard solution is to write the new block to a new location and atomically update a pointer, so readers see either the old block or the new block, never a partially written one.

Deletion is the final stage. When data expires, the system drops entire blocks. This is cheap if the retention boundary aligns with block boundaries. If it does not, the system must rewrite the block to remove the expired points, which is a partial compaction. Aligning block boundaries with retention periods — for example, making each block span exactly one hour or one day — simplifies deletion but constrains the block size. It also makes the block size depend on the scrape interval: an hour of 15-second data is 240 points, while an hour of 1-second data is 3,600 points. The codec must handle both.

The lifecycle imposes a compatibility requirement. A block encoded five years ago must still be decodable today, even if the codec has evolved. This means the format must be versioned, and the decoder must support all historical versions. Adding a new codec is easy; removing an old one is hard because it requires re-encoding all data that uses it. In practice, systems keep decoders for old versions indefinitely, and they re-encode data only when it is compacted for other reasons. The cost of carrying old decoders is small compared to the cost of a full migration.

## Concurrency and the Read Path: Immutability as a Compression Enabler

Compressed blocks are immutable. Once written, a block is never modified in place. This property is not an accident of the codec; it is a deliberate design choice that makes concurrency tractable. Readers can access a block without acquiring a lock, because no writer will change it. Multiple queries can share the same block in cache without copying. A query can take a snapshot of the series by recording the set of block versions it will read, and that snapshot remains valid even as new blocks are written.

The read path starts with the query planner. It consults the sparse index to find the blocks whose timestamp range overlaps the query. It may also consult zone maps to skip blocks whose value range does not match the predicate. It then fetches the selected blocks from the block cache or from storage. Because blocks are immutable, the cache can be a simple hash map from block ID to compressed bytes. Eviction is based on LRU or LFU, and there is no need to invalidate entries when data changes; a new block simply gets a new ID.

Decoding is parallelized across blocks. A query that touches 100 blocks can dispatch 100 decode tasks to a thread pool. Each task creates a decoder instance for its block. Since blocks are independent, the decoder instances share no state, and they can run concurrently without synchronization. The only shared resource is the output buffer or the aggregation state, which must be merged at the end. The merge is usually cheap compared to the decode.

The serial dependency within a block limits parallelism within a single block. The XOR decoder cannot decode point i+1 until it has decoded point i. This means a single block is decoded by a single thread. If a query touches only one block, it cannot use more than one core. This is the fundamental reason why block size and query shape interact: a query that touches many blocks can use many cores, while a query that touches one block is stuck on one core. For point queries and short range queries, the block size should be small enough that the query touches multiple blocks, or the system should provide a sub-block index that allows parallel decode within a block.

Immutability also simplifies error handling. If a block fails its checksum, the decoder can discard it and return an error for that block only. Other blocks in the query continue to decode. The query result may be partial, but the system can report which blocks failed. This is much simpler than trying to repair a mutable block in place. The write-ahead log or a replica can be used to reconstruct the lost block later.

The write path uses a similar immutable approach. New points are appended to a head block or a WAL. When the head block reaches a size threshold, it is sealed and becomes immutable. A new head block is started. Readers that need the latest data read the head block directly, which may be uncompressed or lightly compressed. Readers that need historical data read the sealed blocks. The transition is atomic: a pointer is updated to include the new sealed block. This is the same pattern as a log-structured merge tree, applied to time-series blocks.

Garbage collection removes blocks that are no longer referenced by any snapshot and whose retention period has expired. Because blocks are immutable, garbage collection is safe: a block can be deleted as soon as no active query holds a reference to it. The reference counting can be coarse-grained, at the level of a snapshot, which avoids per-block reference counting. The cost of garbage collection is low, but it must be coordinated with compaction and tiering.

The combination of compression and immutability is what makes a time-series database scalable. Compression reduces the bytes that must be stored and moved. Immutability reduces the coordination that must be done to read and write those bytes concurrently. Together, they allow a system to ingest millions of points per second, store months of data on a single node, and answer queries with predictable latency. The codec is the part that turns the stream into bits; the block lifecycle and the concurrency model are the parts that turn those bits into a usable database.
