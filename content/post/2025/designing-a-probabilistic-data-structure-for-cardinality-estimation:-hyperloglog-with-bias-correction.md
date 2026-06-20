---
title: "Designing A Probabilistic Data Structure For Cardinality Estimation: Hyperloglog With Bias Correction"
description: "A comprehensive technical exploration of designing a probabilistic data structure for cardinality estimation: hyperloglog with bias correction, covering key concepts, practical implementations, and real-world applications."
date: "2025-12-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/Designing-A-Probabilistic-Data-Structure-For-Cardinality-Estimation-Hyperloglog-With-Bias-Correction.png"
coverAlt: "Technical visualization representing designing a probabilistic data structure for cardinality estimation: hyperloglog with bias correction"
---

# The Art of Counting Without Counting: Probabilistic Cardinality Estimation and the HyperLogLog Algorithm

Imagine you are tasked with a seemingly simple job: count the number of distinct users who have visited your website today. Your data set is large, but not insurmountable—a few million events. You fire up a hash set, feed it user IDs, and output its size. Done. Now imagine you need to count every unique search query on Google over the last month. Or every distinct IP address that has contacted a major cloud provider’s load balancer in the last hour. Or every unique genome sequence in a massive metagenomics dataset. Suddenly, that hash set—which stores every single element explicitly—becomes a memory nightmare. A set of one billion unique 64-bit integers consumes eight gigabytes of RAM just for the keys, before any metadata overhead. On a large distributed system, that cost multiplies across every replica, every shard, and every aggregation layer. The problem isn't just memory, either: communicating and merging those enormous sets across machines is slow, bandwidth-intensive, and introduces significant latency. We need a different approach.

This is the domain of **cardinality estimation**. The goal is to determine, with high accuracy and very low resource usage, the number of _distinct_ elements in a multiset—without actually storing the elements themselves. The canonical solution in this space is the **HyperLogLog** (HLL) algorithm, first proposed by Flajolet et al. in 2007. HLL is a marvel of probabilistic data structure design. Using surprisingly little memory—often just a few kilobytes—it can estimate cardinalities into the billions with a relative error of roughly 1-2% standard deviation. It works by observing a beautiful statistical coincidence: the number of leading zeros in the hash of an element is a proxy for its rarity. The more distinct elements you have, the more likely you are to see a hash with a very long run of leading zeros. The algorithm tracks only the _maximum_ such run it has observed across all elements, and from that single number, it derives an estimate.

But how can a single integer possibly represent cardinalities that span nine orders of magnitude? The answer lies in decades of elegant algorithmic thinking—beginning with coin flips, moving through the early probabilistic counts of Flajolet and Martin, and culminating in the refined, practical masterpiece we call HyperLogLog. In this article, we’ll peel back every layer of the onion: from the fundamental intuition of probabilistic counting, through the mathematical machinery that turns randomness into information, to the engineering tricks that make HLL work at internet scale. We’ll walk through step-by-step Python implementations, examine the delicate bias corrections that turn a rough estimate into a reliable one, and explore how HLL is used in real-world systems like Redis, Apache Druid, and Google’s BigQuery. By the end, you’ll understand not just _how_ to count a billion things with 1.5 KB of memory, but _why_ it’s possible—and where the limits lie.

## The Cost of Exactness

Before we dive into the probabilistic world, let’s understand exactly why exact counting is so expensive. Consider a stream of one billion distinct 64-bit user IDs. If we use a hash set, we must store each unique ID. Even with a highly optimized hash set implementation (e.g., using open addressing and no additional metadata), the memory consumption is at least:

- **Key storage**: 1 billion × 8 bytes = 8 GB.
- **Hash table overhead**: A typical load factor of 0.75 means we need about 1.33 billion slots, each slot holding at least the key and maybe a pointer. With 8-byte pointers and 8-byte keys, that’s 16 bytes per slot, leading to ~21 GB.
- **Hash value storage**: We often precompute and store hash values for quick comparisons, adding more memory.

Total: easily 20–30 GB for a single node. In a distributed system with, say, 100 shards, each shard might hold a subset, but then we need to merge these sets. Merging two hash sets of size N and M requires O(N+M) memory and time—and if you want an exact global count, you must either ship all elements to a central node (bandwidth disaster) or use a distributed merge algorithm (e.g., a three-phase distributed set union). The communication cost in terms of network I/O and latency can be prohibitive.

Moreover, exact counting assumes you can store every element, which is often impossible when dealing with high-cardinality streams. For example, counting the number of distinct queries on Google over a month—think on the order of trillions—would require petabytes of storage if done exactly. Even if you could store them, the processing time to hash and insert each new unique element would dominate.

But do we really need exactness? In many applications, an estimate with 1-2% error is perfectly acceptable. For monitoring dashboards, traffic engineering, trend detection, and capacity planning, rough cardinalities are sufficient. The key insight: by accepting a small, controlled error, we can reduce memory usage from gigabytes to kilobytes and enable real-time merging across distributed systems.

## The Coin Flip Intuition

Let’s start with a thought experiment. Suppose you want to estimate how many times you’ve flipped a coin, but you are only allowed to remember _one number_. You flip the coin repeatedly. After each flip, you note the longest run of consecutive heads you have seen so far. How can that single number tell you anything about the total number of flips?

If you have flipped the coin only once, the maximum run of heads is either 0 or 1. After 10 flips, the probability of seeing a run of 3 heads is not negligible. After 1,000 flips, you expect to see runs of 8–10 heads. After a million flips, runs of 18–20 heads become likely. The expected maximum run of heads (or more generally, the maximum number of leading zeros in a binary string) grows logarithmically with the number of trials. Specifically, if you flip a fair coin N times, the expected maximum run of heads is roughly log₂(N) + constant. So if you observe a maximum run of, say, 20 heads, you can estimate that N ≈ 2²⁰ = 1,048,576 flips.

This is the core idea behind probabilistic counting for distinct elements: replace each element with a hash value (a random string of bits), then track the maximum number of leading zeros (or equivalently, the position of the least significant set bit). The hash function acts like a coin-flipping machine, assigning each element a pseudo-random binary sequence. The probability that a given hash starts with exactly k leading zeros is 2⁻ᵏ⁻¹ (since the (k+1)-th bit must be 1). So the maximum leading-zero count across all hashed elements is a statistic from which we can infer cardinality.

## From Coin Flips to Cardinality: The Flajolet-Martin Algorithm

The first practical algorithm based on this idea was the **Flajolet-Martin** (FM) algorithm, introduced by Philippe Flajolet and G. Nigel Martin in 1985. The original algorithm used hash functions to map elements to binary strings and kept a bitmap of bit positions (the positions of the first 1-bit). The estimate was computed from the leftmost zero in the bitmap, known as the "observable" bit. FM was not very accurate on its own, requiring many hash functions to average out the variance, which substantially increased memory and computation.

The key improvement came from two observations: (1) we don't need multiple hash functions if we use a single hash function but split the input into many "registers" (buckets) based on a prefix of the hash; and (2) we can use the _harmonic mean_ of register values instead of the arithmetic mean to dramatically reduce bias and variance. These insights led to the **LogLog** algorithm (1990) and later to **HyperLogLog** (2007).

Let’s step through the evolution with concrete examples.

### The Bit-Pattern Observation

Given a hash function H that outputs uniformly distributed 64-bit values, consider the binary representation of H(element). The number of leading zeros, say ρ, is a geometric-like random variable with P(ρ ≥ k) = 2⁻ᵏ. If we feed N distinct elements into the algorithm, the maximum ρ among them, denoted R = max(ρ), should be roughly log₂(N) + constant. So a naive estimate of cardinality is 2ᴿ.

But this single-register estimator has extremely high variance. Consider: if N=1,000, we might still get R=10 with probability ~ (1 - 2⁻¹⁰)^1000 ≈ 0.37. The estimate would be 2¹⁰=1024, close. But if we get R=15 (probability ~0.0015), the estimate jumps to 32768—wildly off. A single bad hash value can ruin the estimate.

### Stochastic Averaging: Using Multiple Registers

To reduce variance, we use the idea of **stochastic averaging**. Instead of one register, we maintain m registers (e.g., m=1024). We split the hash value into two parts: the first log₂(m) bits determine the register index (bucket), and the remaining bits are used to compute the leading-zero count for that register. Each element updates exactly one register: if its leading-zero count (ρ) is larger than the current value in that register, we update it. At the end, we have an array of m numbers, each being the maximum ρ observed in that bucket.

Now, each register sees roughly N/m elements on average. The maximum ρ in each register is an estimator of the local cardinality N/m. If we average these register estimators and then multiply by m, we get an estimate for N. The variance reduces by a factor of m because we are averaging independent estimates.

The **LogLog** algorithm uses the arithmetic mean of the register values: it computes (sum over registers of 2^{register value}) / m, then multiplies by a bias correction constant. The name "LogLog" comes from the fact that the size of the registers is proportional to log₂(log₂(N)) bits—astoundingly small.

### HyperLogLog: Better Averaging, Lower Error

Flajolet, Fusy, Gandouet, and Meunier improved LogLog by replacing the arithmetic mean with the **harmonic mean** of the register estimates. The harmonic mean is less sensitive to large outliers, which in this context arise when a register sees an abnormally high leading-zero count. The HyperLogLog estimate is:

E = α*m * m² _ ( Σ_{j=1}^{m} 2^{-M[j]} )^{-1}

where M[j] is the value in register j (the maximum leading-zero count), and α_m is a constant that corrects for bias (depends on m). The use of 2^{-M[j]} rather than 2^{M[j]} is intentional: it stabilizes the sum, making the estimator more robust.

With m=1024 registers, HyperLogLog achieves a standard error of about 1.04/√1024 ≈ 3.25%. For m=65536, error drops to 0.4%. Memory usage is m _ (number of bits per register). To store ρ values up to, say, 64, you need 6 bits per register (since log₂(64) = 6). So m=1024 uses 6 _ 1024 = 6 KB; m=65536 uses 48 KB. This is the magic: 48 KB to count up to 2⁶⁴ distinct elements with sub-percent error.

## A Step-by-Step Python Implementation of HyperLogLog

Let’s build a working HyperLogLog estimator in Python. We’ll keep it simple but faithful to the algorithm.

```python
import hashlib
import struct
import math

class HyperLogLog:
    def __init__(self, b=10):
        # b = number of bits used for register index; m = 2^b registers
        self.b = b
        self.m = 1 << b
        self.M = [0] * self.m
        # Correction constants (from Flajolet et al.)
        self.alpha_m = {
            16: 0.673,
            32: 0.697,
            64: 0.709,
        }.get(self.m, 0.7213 / (1 + 1.079 / self.m))

    def _hash(self, element):
        # Use SHA-256 and take first 64 bits (big-endian)
        h = hashlib.sha256(str(element).encode()).digest()
        x = struct.unpack('>Q', h[:8])[0]  # 64-bit integer
        return x

    def _rho(self, value, max_bits=64):
        # Number of leading zeros (position of first 1-bit, starting from MSB)
        # If value is 0, return max_bits (all zeros)
        if value == 0:
            return max_bits
        return (value.bit_length() - 1).bit_length()  # Not correct; we need leading zeros count
```

Wait—computing leading zeros correctly requires care. For a 64-bit value, the number of leading zeros is 64 - (floor(log₂(value)) + 1) if value != 0, else 64. In Python we can use `value.bit_length()` which gives number of bits needed to represent value. Leading zeros = 64 - bit_length(value). But we have to be careful: the hash is 64 bits, so we want the leading zeros from the most significant bit. So:

```python
    def _rho(self, value):
        if value == 0:
            return 64
        return 64 - value.bit_length()
```

Now, to update:

```python
    def add(self, element):
        x = self._hash(element)
        # First b bits for register index
        j = x >> (64 - self.b)
        # Remaining bits (64 - b) for leading zero count
        # We need to shift left b bits to get the remaining bits aligned to MSB
        w = x << self.b
        # Leading zeros of w (but w is 64 bits; after shift, it's still 64 bits, but leftmost b bits are zeros)
        # The number of leading zeros of w is at least b (the shifted bits) + possibly more.
        # The leading zero count we want for the register is rho(w) - b? Actually we need rho of the remaining part.
        # Original paper: use the remaining bits, count leading zeros from that.
        # Easier: mask out the first b bits and count leading zeros on the remaining (64-b) bits.
        # But the hash is 64 bits; we can use x and extract the lower 64-b bits as a 64-bit number with b leading zeros.
        # More standard: let x be a 64-bit hash. Let j = x >> (64 - b)  (top b bits).
        # Let r = rho( (x << b) )  # This shifts left by b, so the top b bits become zero, and the rest fill the MSB positions.
        # The first 1 appears somewhere in the shifted value, but we need to count leading zeros on a (64-b)-bit field?
        # Actually, the paper defines rho(w) where w is the remaining (64-b) bits padded to 64 bits?
        # The simplest implementation: compute w = (x << b) | (1 << (b))? No.
        # According to the standard HLL implementation (e.g., Redis, Postgres), compute:
        #  j = hash >> (64 - b)   # top b bits as bucket index
        #  w = hash & ((1 << (64 - b)) - 1)   # lower 64-b bits
        #  rho = leading_zeros(w) + 1   # they count number of zeros + 1 (position of first 1)
        # But careful: the count of leading zeros in w (a (64-b)-bit number) is from the most significant of that field.
        # In 64-bit representation, w occupies the lower 64-b bits. Leading zeros relative to the full 64 bits would be (b + zeros_in_w).
        # Actually, the original paper uses a binary string of length L (e.g., L=64 after hash). The bucket index is the first p bits, then the remaining bits provide the "word" for leading zeros. The count rho is the number of leading zeros in that remaining word + 1.
        # So standard approach: compute leading zeros of the remaining bits, treating them as a (64-p)-bit word.
        # Python has int.bit_length() on that integer (which doesn't have leading zeros beyond its highest bit). So we need to simulate leading zeros within a fixed length.
        # Simpler: use the full hash and compute rho(x) where x is the whole hash? But then leading zeros depend on bucket bits.
        # Let's do the exact textbook method:
        # Let p = b
        # Let L = 64
        # Let j = x >> (L - p)  # top p bits
        # Let w = x & ((1 << (L - p)) - 1)  # lower L-p bits
        # rho = number of leading zeros of w in the context of L-p bits: that is (L - p) - w.bit_length() if w != 0 else (L - p)
        # Then update M[j] = max(M[j], rho + 1) (they add 1 to make range 1..L-p+1).
```

To avoid confusion, I'll adopt the formulation used by many popular HLL libraries (like Redis's implementation):

```python
    def add(self, element):
        x = self._hash(element)
        # Bucket index from top b bits
        j = x >> (64 - self.b)
        # Remaining bits (lower 64-b bits) for leading zeros
        # Shift left by b to align the remaining bits to the MSB position.
        # Actually, we want the number of leading zeros in the lower (64-b) bits treated as a (64-b)-bit number.
        # So we can extract the lower bits and compute leading zeros in a field of length (64-b).
        lower_bits = x & ((1 << (64 - self.b)) - 1)
        if lower_bits == 0:
            rho = 64 - self.b
        else:
            # Number of leading zeros in a (64-b)-bit field
            rho = (64 - self.b) - lower_bits.bit_length()
        # Value to store: rho + 1 (position of first 1)
        self.M[j] = max(self.M[j], rho + 1)
```

Now for the estimate:

```python
    def estimate(self):
        # Compute harmonic mean
        sum_inv = 0.0
        for val in self.M:
            sum_inv += 2.0 ** (-val)
        E = self.alpha_m * self.m * self.m / sum_inv
        # Apply small-range correction
        if E <= 5 * self.m:
            # Count number of zero registers
            V = self.M.count(0)
            if V > 0:
                # Linear counting estimate
                E = self.m * math.log(self.m / V)
        # Large-range correction for near overflow (if using 64-bit, not needed for typical cases)
        return E
```

Testing:

```python
hll = HyperLogLog(b=10)  # 1024 registers
for i in range(100000):
    hll.add(f"user{i}")
print(hll.estimate())  # Should be around 100000
```

With 100K distinct elements and b=10 (error ~3.25%), we might get something like 98,500 or 103,000.

## The Math Behind the Magic: Bias and Error Corrections

Why does HyperLogLog need different estimation formulas for small, medium, and large cardinalities? Because the raw estimate is biased in the extremes.

### Small Cardinalities: When Many Registers Are Still Zero

If the true cardinality N is much smaller than the number of registers m, then many registers remain at their initial value 0. The harmonic mean formula becomes unstable because a single register with value 0 contributes an infinite 2⁰ = 1 to the sum (actually 2^{-0}=1 is okay, but biased). More importantly, the estimator assumes that each register receives enough elements to approximate a geometric distribution—this fails when N << m. In that regime, it's better to use a different method: **linear counting**. Linear counting is derived from the observation that the number V of registers that still hold 0 after inserting all elements follows a Poisson distribution. The expected value of V is m _ e^{-N/m}. Solving for N gives N = m _ ln(m/V). This is highly accurate for N up to about m _ ln(m) (roughly m _ 2.3). HyperLogLog transitions to linear counting when the raw estimate E is less than 5m.

As N grows, more registers become non-zero, and the variance of the linear counting estimate increases. Beyond that threshold, the harmonic mean estimator is used.

### Large Cardinalities: The Saturation Danger

When N approaches 2^(max_bits_in_register), the registers can saturate. For example, if we use 6-bit registers, the maximum representable value is 63 (logarithm of 2^63). If cardinality exceeds 2^60, the maximum leading-zero count can exceed 63, leading to truncation. This is rarely an issue for 64-bit hashes and 6-bit registers (up to 2^63). But with larger register sizes, we might need 7 or 8 bits. The HLL paper provides an empirical correction for the case when E is very large (approaching the maximum representable cardinality).

### The Alpha Correction Constant

The factor α_m is computed to make the estimator unbiased for large cardinalities. The theoretically derived α_m for the harmonic mean approach is:

α_m = 0.7213 / (1 + 1.079 / m) for m >= 128.

For smaller m, it depends on specific values (as shown in the Python code). The correction reduces the systematic overestimation that would otherwise occur.

## Merging HyperLogLog Sketches

One of the most powerful features of HyperLogLog is that it is **a distributed data structure that supports merges without loss of information**. Given two HLL sketches with the same configuration (same number of registers and hash function), you can merge them by taking the element-wise maximum of their register arrays. The merged array represents the union of the two streams, because each register stores the maximum ρ observed across all elements that mapped to that bucket. The merge is idempotent, commutative, and associative, making it perfect for distributed systems.

Example: Suppose shard A processed 1 million unique users, shard B processed 2 million unique users, with 500k overlap. We can compute the total distinct users by merging the two HLL sketches and calling estimate(). This requires transmitting only a few kilobytes between shards, regardless of cardinality.

This property is why HLL is the foundation of approximate distinct count in systems like Apache Druid, ClickHouse, Spark, and Redis (via the PFADD/PFMERGE commands).

## Practical Considerations in Real Systems

### Hash Function Quality

HyperLogLog relies heavily on the randomness of the hash function. A poor hash (e.g., with correlations) can produce systematic bias. In practice, we use cryptographic hashes like SHA-256, MurmurHash3, or xxHash. For performance-critical applications (e.g., high-throughput streams), a fast non-cryptographic hash like MurmurHash3 is preferred, as long as its output is uniformly distributed.

### Choosing the Number of Registers (b)

The parameter b (log2 m) dictates the memory/accuracy trade-off.

- b = 4 (16 registers): Very small, but error >25%.
- b = 10 (1024 reg): ~3.25% error, 6 KB memory. Good for approximate counts in monitoring dashboards.
- b = 12 (4096 reg): ~1.6% error, 24 KB.
- b = 14 (16384 reg): ~0.8% error, 96 KB.
- b = 16 (65536 reg): ~0.4% error, 384 KB.

In many databases (e.g., PostgreSQL extension `hll`), b can be set per-column.

### Sparse Representation for Small Cardinalities

When the true cardinality is small relative to m, storing all m registers (most of which are zero) is wasteful. For N < 0.5\*m, many registers remain zero. To save memory, some implementations use a **sparse representation** that only stores non-zero register entries (as an offset-value list). Once the number of non-zero registers exceeds a threshold, they convert to the full dense array. This reduces memory consumption for small cardinalities by an order of magnitude. For example, if N=1,000 and m=65536, the dense array would use 48 KB, but the sparse representation might use only a few hundred bytes.

### Accuracy Guarantees (Beyond Standard Error)

The standard error is 1.04/√m. This means that for a single estimate, about 68% of the time the true cardinality will be within 1 standard error of the estimate, and about 95% within 2 standard errors. However, the error distribution is not perfectly Gaussian; it has a slight positive skew for small cardinalities and is more symmetric for large ones. The paper provides precise quantile tables for confidence intervals.

## Extensions and Variants

### HyperLogLog++

Google published an improved version called **HyperLogLog++** (2013) that addresses two issues:

1. Bias correction for small cardinalities using a more refined linear counting transition.
2. Sparse representation using a list of (index, value) pairs.
3. 64-bit hash functions for larger range.

The overall error characteristics are similar, but the practical memory footprint is further reduced.

### Streaming Algorithms for More Than Counting

HyperLogLog is just one member of a family of **sketches**—probabilistic data structures that approximate statistical properties of massive streams. Others include:

- **Bloom Filters**: approximate set membership (no cardinality).
- **Count-Min Sketch**: approximate frequency count of items.
- **T-Digest**: approximate percentiles.
- **Theta Sketches** (DataSketches): a more general framework for cardinality estimation and set operations (union, intersection, difference). Theta sketches can produce exact answers for small sets and approximate for large ones.

### Distinct Counts in SQL

Many SQL databases now support approximate distinct count functions. For example, PostgreSQL has the `hll` extension; Redshift has `APPROXIMATE COUNT(DISTINCT)`; BigQuery uses `APPROX_DISTINCT`. Under the hood, they all use HyperLogLog or a close variant.

## When NOT to Use HyperLogLog

HyperLogLog is not a universal hammer. It has limitations:

- **Small cardinalities**: If you need exact counts for small sets (e.g., <1,000), the error percentage can be high, and memory overhead for the sparse representation may still be larger than just using a hash set.
- **Set operations beyond union**: HLL supports union natively, but intersection and difference are tricky. The common technique is to use inclusion-exclusion: |A ∩ B| = |A| + |B| - |A ∪ B|. But this suffers from error propagation and can be unstable when sizes are comparable. Better to use Theta sketches for set operations.
- **Adversarial input**: If an attacker can craft hash collisions (i.e., choose elements that hash to the same bucket with abnormally high leading zeros), they can inflate the estimate. Cryptographically strong hashes mitigate this.
- **Extreme accuracy demands**: If you need <0.1% error, HLL may require tens of MB of memory. Alternative algorithms like **Adaptive Counting** or **Berkamp Counting** can achieve lower error for the same memory, but are more complex.

## Conclusion: The Elegance of Logarithmic Thinking

The journey from simple coin flipping to HyperLogLog illustrates a beautiful principle in computer science: by embracing randomness and statistical inference, we can trade precision for efficiency in a controlled way. The algorithm's reliance on leading zeros—a seemingly trivial bit of information—is a testament to the power of extracting signal from noise. A single 64-bit hash, when combined with stochastic averaging across a few thousand buckets, yields a robust estimate that scales to trillions of elements. No exotic hardware, no deep neural networks—just pure mathematical insight.

HyperLogLog has become a de facto standard for cardinality estimation in large-scale data systems. It powers real-time analytics, network monitoring, database query optimizers, and more. The next time you see a dashboard reporting "approximately 2.3 million distinct visitors today" with a small error bar, you’ll know that behind that simple number lies a brilliant piece of probabilistic engineering—one that counts without counting, and in doing so, makes the impossible practical.

---

_Are you building a system that needs to count distinct elements at scale? Consider HyperLogLog. And if you need exactness for a small subset, combine it with a small exact set—a hybrid approach that gives you the best of both worlds._
