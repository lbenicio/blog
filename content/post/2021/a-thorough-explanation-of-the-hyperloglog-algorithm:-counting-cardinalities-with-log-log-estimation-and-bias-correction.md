---
title: "A Thorough Explanation Of The Hyperloglog Algorithm: Counting Cardinalities With Log Log Estimation And Bias Correction"
description: "A comprehensive technical exploration of a thorough explanation of the hyperloglog algorithm: counting cardinalities with log log estimation and bias correction, covering key concepts, practical implementations, and real-world applications."
date: "2021-08-12"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/a-thorough-explanation-of-the-hyperloglog-algorithm-counting-cardinalities-with-log-log-estimation-and-bias-correction.png"
coverAlt: "Technical visualization representing a thorough explanation of the hyperloglog algorithm: counting cardinalities with log log estimation and bias correction"
---

# A Thorough Explanation Of The Hyperloglog Algorithm: Counting Cardinalities With Log Log Estimation And Bias Correction

## 1. The Problem of the Uncountable

Imagine you work at a massive tech company—let’s call it _Google-Meta-Uber_, a conglomerate that runs a popular ride-sharing service, a global video platform, and a search engine. Every day, your systems handle billions of events. One morning, your product manager asks a deceptively simple question: "How many **unique** users watched our Super Bowl ad yesterday?"

Your first instinct is to reach for an `EXISTS` query or a Python `set()`. You grab a sample of 10 million records, run a quick script, and it works fine. But then you realize: yesterday’s event stream was **1.2 trillion** entries. Each user ID is a 16‑byte UUID. A naive `set` would require `1.2 trillion × 16 bytes ≈ 17.5 terabytes` of RAM. Even a compressed bitmap would struggle. You do the math again: **17.5 terabytes** just to count unique users. Even with cloud instances the size of small apartments, this is impractical—and you haven’t even done the actual query yet.

Worse, your product manager keeps coming back with follow‑up questions: “How many unique cities? How many unique devices? Can you break it down by country? By time window?” Each question multiplies the memory cost. You realise you cannot keep copies of the raw data, sorting becomes impossible at this scale, and exact deduplication is a luxury you can no longer afford.

This is the **cardinality estimation problem**, and it is one of the most fundamental yet frustrating challenges in data engineering. We need to know exactly how many distinct items exist in a multiset—but the dataset is too large to store, too fast to sort, and too expensive to deduplicate with traditional data structures. The problem is also known as _distinct count_ or _unique count_, and it appears everywhere: counting unique visitors to a website, distinct IP addresses hitting a server, unique search queries, distinct products purchased, and even in database query optimizers when estimating the number of distinct values in a column (NDV).

Traditional solutions fall into three categories:

- **Exact counting** (using hash sets or sorted arrays) – works for small data, but memory grows linearly with cardinality.
- **Deterministic approximations** (e.g., Bitmaps, Bloom filters) – memory efficient for low cardinalities, but for billions of distinct items even a compressed bitmap can be impractically large.
- **Probabilistic algorithms** – clever mathematical approaches that trade a tiny slice of accuracy for an enormous reduction in memory. The most famous of these is **HyperLogLog** (HLL), an algorithm that can estimate the cardinality of billions of unique elements using less than **1.5 kilobytes of memory**. It achieves this with an error rate of roughly 2‑3%, which for many practical applications is essentially perfect.

HyperLogLog was invented by Philippe Flajolet and his collaborators in 2007, building upon a long line of research in probabilistic counting that began with Flajolet and Martin’s 1985 paper _Probabilistic Counting Algorithms for Data Base Applications_. The name “HyperLogLog” hints at its ancestry: “LogLog” refers to the fact that memory usage scales as `O(log log N)`, a double logarithm that grows incredibly slowly. For example, to count up to 2^64 distinct elements (about 1.8 × 10^19), HLL needs only about 12 bits per register, times 2^p registers, where p is typically 10 to 18. That’s a total of a few kilobytes.

But how does it work? The name hints at something deeply subtle: _LogLog estimation_ with _bias correction_. Under the hood, HLL relies on a wonderfully counter‑intuitive property: the positions of leading zeros in hashed values follow a known probability distribution, and the longest run of zeros observed is a powerful estimator of the cardinality. Yet, that raw estimator is biased—it systematically over‑ or under‑estimates. The “correction” part of HyperLogLog involves a combination of harmonic means, empirical constants, and hybrid estimators for different cardinality ranges.

In this article, we will peel back the layers of HyperLogLog from the ground up. We will start with coin‑flipping experiments, build our way to the Flajolet‑Martin algorithm, discover its shortcomings, and then see how LogLog and finally HyperLogLog fixed them. Along the way, we will dive deep into the mathematics, implement a simplified version in Python, explore advanced variants like HLL++ and sparse representations, and discuss real‑world deployments in systems like Redis, Apache Druid, Presto, and BigQuery. By the end, you will not only understand why HyperLogLog works, but also how to use it correctly and when to choose alternatives.

## 2. Background: The Cost of Exact Counting

Before we appreciate the beauty of probabilistic algorithms, we must understand why exact counting is so expensive. Consider the problem: Given a multiset of size N (number of total elements), we want the number of distinct elements, often denoted as _M_ (or cardinality). The naive method is to maintain a hash set of all observed elements. For each new element, we compute its hash, look it up in the set, insert if missing, and increment count. This algorithm is exact but consumes memory proportional to _M_ — the number of _distinct_ elements, not the total N. If M is large (billions), the memory is forbidding.

A slightly more efficient approach uses a **bitmap** over the hash space. If we hash each element to a fixed number of bits (say 2^b bits), we can set the corresponding bit and later count the set bits. This reduces memory to 2^b bits, but suffers from collisions as the cardinality approaches 2^b. For exact counting, we would need b ≈ log2(M) + some safety margin, which again grows linearly with M’s logarithm — not too bad for small M, but for M = 10^9 we need about 30 bits, i.e., 2^30 bits = 128 MB. That’s better than 17.5 TB, but still too large for many embedded or real‑time systems. And if we need to count multiple distinct sets (e.g., per hour, per country), the memory multiplies.

**Bloom filters** can represent sets with a fixed size and a small false positive rate, but they do not directly give a cardinality estimate — they only answer membership queries. One can approximate cardinality by counting set bits and using known formulas, but that is a second‑order estimate with higher variance. Also, Bloom filters cannot be merged easily if they are built with different sizes.

**Sorted arrays** are even worse: sorting O(N) elements takes O(N log N) time and O(N) memory. For streaming data this is impractical.

The key insight from Flajolet and his contemporaries was that we do not need exact counts in many scenarios. A 2% error is often acceptable for dashboards, trend analysis, anomaly detection, and capacity planning. And if we can reduce memory from terabytes to kilobytes, the trade‑off is irresistible. That is the promise of probabilistic counting.

## 3. The Intuition: Coin Flips and Leading Zeros

### 3.1. The Coin Flip Analogy

Imagine you are playing a game: you flip a fair coin repeatedly until you see heads. Let X be the number of flips needed (including the heads). The probability that X = k is (1/2)^k for k ≥ 1 (since you must get k‑1 tails and then a head). The expected value of X is 2. But here’s the twist: if you repeat this experiment many times and record the maximum number of flips observed, say R = max X_i over n independent experiments, then R is a crude estimator of n. Why? Because the chance that you never see a run of length R or more decays exponentially. Heuristically, if you have n experiments, you expect to see a run of about log2 n. More formally, the maximum of n geometric random variables with p = 1/2 is approximately log2 n.

Let’s formalise this. If X_i ~ Geometric(1/2) with support {1,2,…}, then P(X_i ≥ k) = 2^{-(k-1)}. For k = log2 n + c, this probability becomes about 2^{-c} / n. The expected maximum R satisfies E[R] ≈ log2 n + γ / ln 2 + 1/2, where γ is Euler‑Mascheroni (≈0.577). So R is roughly log2 n plus a small constant. Therefore, we can estimate n ≈ 2^R.

But this estimator is severely biased and has high variance (since it depends on a single maximum). To improve, we can repeat this process many times using multiple experiments and take averages — this is exactly the idea behind the Flajolet‑Martin (FM) algorithm.

### 3.2. From Coin Flips to Hashed Values

Why coin flips? Because we can turn any data element into a coin‑flip pattern by hashing it. Given a good hash function, the bits of the hash value behave like independent fair coin flips. In particular, the number of leading zeros (or trailing zeros, depending on convention) in the binary representation of the hash is akin to the number of tails before the first head. More generally, if we define ρ(x) = position of the first 1 bit (least significant bit, LSB), then ρ(x) follows the same geometric distribution as the coin flip experiment. (For a fair hash, P(ρ(x) = k) = 1/2^k.)

Thus, for each distinct element in our dataset, we can compute its hash, find ρ(hash), and record the maximum observed ρ across all distinct elements. If we have M distinct elements, we expect this maximum to be roughly log2 M. So an estimator is: _M_ ≈ 2^{max ρ}.

### 3.3. The Flajolet‑Martin (FM) Algorithm

The FM algorithm (1985) implements this idea directly. For each element in the stream, compute a hash value h(x). Find the position of the first 1‑bit in h(x) (counting from the least significant bit). Let ρ(x) be that position (1‑based; if hash is all zeros, treat as a special case). Maintain a bitmap of size L (say L=32 or 64 bits) where we set the bit at index ρ(x). After processing all elements, the bitmap shows the smallest ρ values that have been observed. The location of the rightmost set bit in the bitmap gives the maximum ρ. Then the cardinality estimate is 2^{max_ρ}.

However, the raw estimate is very noisy (variance is high) because it uses only a single maximum. To reduce variance, FM uses a technique called **probabilistic counting with multiple trials**: they use _m_ independent hash functions (or equivalently, a single hash function but with _m_ different buckets derived from the hash) and maintain an array of _m_ bitmaps. Then they average the estimates from each bucket, but not a simple average — they use a “stochastic averaging” technique that effectively uses the harmonic mean of the bucket observations to correct bias.

Wait, that sounds like HyperLogLog already. Actually, FM and its successors (LogLog, HyperLogLog) all use the same underlying principle but differ in how they combine the observations.

### 3.4. Why So Many Versions?

The original FM algorithm uses a bitmap per bucket (or a single bitmap with multiple hash functions), which is memory‑heavy. The LogLog algorithm (2003) introduced the idea of storing only the maximum ρ value per bucket, not a full bitmap, dramatically reducing memory. HyperLogLog (2007) further improved accuracy by using the harmonic mean instead of the geometric mean, and added a sophisticated bias correction for small and large cardinalities.

Let’s trace these steps one by one.

## 4. The Flajolet‑Martin Algorithm in Detail

### 4.1. Algorithm Description

We have a multiset D of elements. We choose m = 2^k buckets (for some integer k, e.g., m=1024). For each element x, we compute a hash h(x) (say a 32‑bit hash) and split it into two parts: the first k bits (or the last k bits) determine the bucket index j, and the remaining bits are used to compute ρ. Specifically:

- Let h(x) = binary string of length L.
- Let j = the integer value of the first k bits (or last k bits — consistency is what matters).
- Let w = the remaining bits (or we can treat the whole hash and compute ρ on the leading zeros after the bucket bits).
- Compute ρ(w) = position of the first 1‑bit in w.
- For bucket j, maintain a register M[j] = max( M[j], ρ(w) ).

After processing all elements, we have an array of m registers, each containing the maximum ρ observed in that bucket.

Now, each bucket receives approximately M/m distinct elements (since the hash distributes uniformly). So within bucket j, the maximum ρ we observe is roughly log2 (M/m). Therefore, the average of the register values across buckets should be about log2 (M/m) + some constant. An estimator is:

M*est = m * 2^{ (1/m) \_ Σ M[j] }

But this is a raw estimator. Flajolet and Martin originally used a different formula involving the bitmap and the concept of “phase” but the modern version (LogLog) uses the average.

However, the average of logarithms leads to a biased estimate. The original FM algorithm used a correction factor φ(m) derived empirically.

### 4.2. Drawbacks of FM

- **Memory**: FM still requires a bitmap per bucket? Actually the original FM stored a full bitmap for each bucket? No, the original FM used a single bitmap but multiple hash functions; that is memory‑inefficient. The “stochastic averaging” variant (often called PCSA – Probabilistic Counting with Stochastic Averaging) uses m buckets and stores the maximum ρ per bucket, which is exactly LogLog. So FM and LogLog are very close.
- **Variance**: The estimate from each bucket is still based on a maximum, and averaging across buckets reduces variance but not optimally. The variance of the estimator is about 1.3 / sqrt(m).
- **Bias**: For small cardinalities, the estimator is biased because the maximum ρ may be small and the average of logs is distorted.
- **No merging**: Actually FM cannot be easily merged because the bitmaps have to be combined via OR, which is fine, but the later LogLog and HLL allow merging by taking element‑wise max, which is trivial.

In practice, FM is rarely used today; LogLog and HLL dominate.

## 5. LogLog: Storing Only the Log of the Maximum

### 5.1. The LogLog Algorithm

The LogLog algorithm (Durand & Flajolet, 2003) simplifies FM by storing only the _floor_ of the logarithm of the maximum pattern, i.e., the integer values of ρ. For each bucket, we keep a byte (or a small integer) representing the maximum ρ observed. Memory cost: m \* log2(log2(n)) bits, which is the “LogLog” name.

The algorithm:

1. Choose m = 2^p buckets (p is a precision parameter, typically 10 to 16).
2. Initialize registers M[0..m-1] to 0.
3. For each element x in data stream:
   - Compute hash h = hash64(x) (a good 64‑bit hash e.g., MurmurHash3, xxHash).
   - Use the first p bits to determine bucket index j.
   - Let w = the remaining bits (64 - p bits) appended with a leading 1 to avoid all zeros? Actually we need to count leading zeros (or trailing zeros) on the remaining bits. Often they pad with a leading 1 to ensure the position is at least 1 and to handle all‑zero word.
   - Compute ρ = number of leading zeros in w (or position of first 1, which is leading zeros + 1).
   - M[j] = max(M[j], ρ).
4. After processing, compute the harmonic mean of the bucket estimates? Actually LogLog uses the arithmetic mean of the bucket values (since each bucket’s stored value is an integer, we compute the average R̄ = (1/m) \* Σ M[j]).
5. The cardinality estimate is: _E_ = α*m * m \_ 2^{ R̄ }
   where α_m is a bias correction factor that depends on m. α_m ≈ 0.39701 for m ≥ 64; derived from the expected value of the maximum of geometric variables.

Wait, that estimator uses exponentiation of the average of logs, which introduces bias. The original LogLog paper derived α_m to correct that bias for large cardinalities. However, for small cardinalities, the estimate is still poor, so they used linear counting for small ranges.

### 5.2. The Bias Correction Factor α_m

The formula E = α*m * m \_ 2^{ R̄ } is derived from the fact that the estimator of the number of distinct elements per bucket (call it n_j) is approximately 2^{ M[j] }, but the expectation of 2^{ M[j] } is not 2^{ E[M[j]] }. In fact, the expectation of 2^{M[j]} given n_j is about n_j / φ, where φ is a constant related to the mean of the geometric distribution. The constant α_m is designed so that E[α_m * m * 2^{ R̄ }] ≈ M.

Specifically, α*m = ( 1 / (m * (Γ(-1/m) \_ 2^(1/m) ) ... ) no, that’s for HyperLogLog. For LogLog the formula is based on the gamma function. The original paper gives a table of α_m values for different m.

For large m, α_m converges to about 0.39701. But many implementations (including early HyperLogLog) use a fixed value of 0.39701 for all m > 64.

### 5.3. Performance and Error

For LogLog, the standard error is about 1.30 / sqrt(m). For m=1024 (p=10), error ≈ 1.30/32 ≈ 4.1%. For m=2^16=65536, error ≈ 0.5%. Memory usage is m * 5 bits (if max ρ fits in 5 bits for 64‑bit hash? Actually max ρ ≤ 64, so 6 bits). So m=1024 uses 1024*5 = 5 Kb. That’s already great.

But HyperLogLog improves this error to about 1.04 / sqrt(m) by using the harmonic mean instead of arithmetic mean, and by refining the small‑range correction.

## 6. HyperLogLog: The Harmonic Mean and Bias Correction

### 6.1. Step 1: Using the Harmonic Mean

The insight of HyperLogLog is that the arithmetic mean of the logged observations (R̄) is sensitive to outliers. Since the distribution of M[j] is skewed, the arithmetic mean of the exponents (2^{M[j]}) is actually a better estimator? Wait, HyperLogLog uses the harmonic mean of the _individual bucket estimates_. Specifically:

For each bucket j, we have a register value M[j]. The contribution of this bucket to the overall estimate is: estimate from bucket j = 2^{ M[j] }. But we want to combine them. If we took the arithmetic mean of these estimates, we would get the sum divided by m, but the expectation of the sum is not linear because the buckets are independent but the estimates are biased. The harmonic mean is more robust to large values and yields a smaller bias.

The HyperLogLog estimator for large cardinalities is:

E = α*m \* m^2 / ( Σ*{j=0}^{m-1} 2^{-M[j]} )

where α_m is a constant that corrects the bias introduced by the harmonic mean. This formula is derived from a stochastic averaging argument: the sum of 2^{-M[j]} approximates the expected value m \* ∫ ... Actually it is based on the fact that E[2^{-M}] = 1 / (n/m + 1) , so the harmonic mean of the 2^{M} estimates works well.

### 6.2. Derivation of α_m

The factor α_m is defined as:

α_m = ( m \* ∫_0^∞ ( log2( (2 + u)/(1 + u) ) )^m du )? Not exactly. The original paper gives:

α*m = ( 1 / (m * (Γ(-1/m) \_ 2^(1/m) ... ) )? Let me find the exact expression.

From the original HyperLogLog paper (Flajolet et al., 2007), the estimator for large cardinalities (M >> m) is:

E = α*m * m^2 \_ ( Σ 2^{-M[j]} )^{-1}

where α_m is defined as:

α_m = ( 1 / (m \* ∫_0^∞ ( log2( (2+u)/(1+u) ) )^m du ) ) ... no.

Actually, α_m = ( m ∫_0^∞ ( 1 - 2^{-u} )^m du )^{-1}? Let me derive from the paper.

The standard value of α_m for m = 2^p (p integer) is given in a table:

- p=4 (m=16): α=0.673
- p=5 (m=32): α=0.697
- p=6 (m=64): α=0.709
- p≥7 (m≥128): α=0.7213 / (1 + 1.079/m)

Yes, in many implementations (e.g., Redis), for p=14 (m=16384), α = 0.7213/(1+1.079/16384) ≈ 0.72127.

The formula α = 0.7213/(1 + 1.079/m) is a good approximation for m > 128. For smaller m, the paper provides exact values.

### 6.3. Step 2: Small Range Correction

For small cardinalities (less than a threshold, typically 5\*m/2), the harmonic mean estimator is biased because there are many buckets still at 0, and the sum of 2^{-M[j]} becomes dominated by zeros. The estimator becomes unreliable.

The solution is to use **linear counting** when the number of zero registers (Z) is significantly large. Linear counting is a simple technique: if the hash space is large (2^L), and we have m registers (buckets), the proportion of empty registers after inserting n distinct elements is approximately e^{-n/m}. So given Z empty registers, we estimate:

E_linear = m \* ln( m / Z )

For small cardinalities, linear counting is more accurate than the harmonic mean estimator.

The threshold is usually when E < 5\*m/2. In that case, we compute Z (number of registers with value 0). If Z > 0, use the linear counting formula; otherwise, we fall back to the harmonic mean estimator (but this case rarely happens for small cardinalities because there should be many zeros).

### 6.4. Step 3: Large Range Correction

For extremely large cardinalities (near the capacity of the hash function), we might encounter register values approaching the maximum bits (e.g., 64 for a 64‑bit hash). In that case, the estimator may start to saturate. The solution is to detect when the register values exceed a certain threshold (e.g., when the estimated cardinality is > 2^32 for 32‑bit hash, or > 2^50 for 64‑bit), and then switch to a formula using the sum of the registers directly? Actually, the large range correction in the original paper is: if E > 2^32 (for 32‑bit hash), they replace E with something like: -2^32 \* log(1 - E/2^32). But in practice, with a 64‑bit hash, it’s rare to exceed 2^64. Many implementations simply cap the estimate to the maximum possible cardinality.

### 6.5. The Full HyperLogLog Algorithm

Putting it together:

1. Choose precision p (⇒ m = 2^p registers).
2. Initialize registers all zero.
3. For each element x:
   - hash = hash64(x)
   - bucket = first p bits of hash (e.g., most significant bits)
   - w = remaining bits (64-p bits) + a leading 1 (to ensure ρ ≥ 1)
   - ρ = number of leading zeros in w + 1 (or count leading zeros and treat as position)
   - if ρ > M[bucket]: M[bucket] = ρ
4. After all elements:
   - Compute Z = count of registers equal to 0
   - If Z == 0: use harmonic mean estimator:
     sum = Σ 2^{-M[j]}
     E = α_m * m^2 / sum
     Else (Z > 0): if E < 5*m/2 (where E is the estimate from the harmonic mean? Actually the algorithm recomputes differently: they first compute the harmonic mean estimate regardless, then if that estimate is < 5*m/2, they use linear counting if Z > 0, else use harmonic mean. Wait, typical implementation: compute E_raw = α_m * m^2 / Σ 2^{-M[j]}. Then apply small range correction: if E_raw ≤ 5\*m/2, then use linear counting if Z>0, else use E_raw. Larger range: if E_raw > 2^32 for 32‑bit hash, use alternative formula -2^32 log(1 - E_raw/2^32). But with 64‑bit hash, this step is rarely needed.
5. Return final E.

Many modern implementations skip the large range correction for 64‑bit hashes.

### 6.6. Error Analysis

The standard error of HyperLogLog is approximately 1.04 / sqrt(m). This is a significant improvement over LogLog’s 1.30 / sqrt(m). For p=14 (m=16384), error ≈ 1.04/128 ≈ 0.81%. For p=12 (m=4096), error ≈ 1.04/64 ≈ 1.6%. For p=10 (m=1024), error ≈ 3.3%. Memory for p=14: each register needs to store a value up to 50 (since 64‑bit hash) which fits in 6 bits, so 16384 \* 6 bits = 12.3 KB. That’s astonishing.

## 7. Bias Correction: A Deeper Look

### 7.1. Why is Bias Correction Needed?

The harmonic mean estimator α_m \* m^2 / Σ 2^{-M[j]} is derived under the assumption that the number of distinct elements per bucket is large enough that the distribution of 2^{-M[j]} behaves like the expected value. For small counts, this approximation breaks down. The bias manifests as a systematic underestimation or overestimation.

The correction involves multiple regimes:

- **Very small cardinalities** (say M < 2.5\*m): linear counting is used because many registers are zero.
- **Small cardinalities** (M from ~2.5\*m to ~several times m): The harmonic mean estimator is still biased, but the bias can be corrected empirically by adjusting α_m for the small range? Actually, the original paper does not apply another correction; they simply switch to linear counting until the zero registers vanish. Once Z=0, the harmonic mean estimator works reasonably well but still might have slight bias for moderate counts.
- **Medium to large cardinalities**: The estimator is essentially unbiased.
- **Very large cardinalities** (near hash capacity): corrections to avoid saturation.

Many implementations use the “bias correction” table as described in the original paper, but a more recent approach is to use **empirical bias curves**. For example, the HLL++ algorithm (Google’s variant) uses a piecewise linear interpolation of empirically measured biases across the range of cardinalities. This reduces the relative error to below 1% even for small cardinalities.

### 7.2. The Four Regime Model (Google’s HLL++)

HLL++ is described in the 2013 paper _HyperLogLog in Practice: Algorithmic Engineering of a State of The Art Cardinality Estimation Algorithm_ by Heule, Nunkesser, and Hall. It introduces:

1. **Sparse representation**: For very small cardinalities, instead of maintaining full registers, they store a list of (bucket, ρ) pairs. This saves memory when the stream is sparse.
2. **Normal representation**: The usual dense array of registers.
3. **Bias correction using empirical data**: Instead of a simple threshold, they computed the true bias of the harmonic mean estimator for every possible cardinality (up to some limit) by simulation, and stored a lookup table. Then the estimate is adjusted by a spline interpolation of the bias.
4. **64-bit hashing and long registers**: They use 64-bit hashes and registers of 6 bits (since ρ max = 64). But they also increase the precision p to up to 18 (m=262144) for high accuracy.

HLL++ is used in BigQuery and many Google systems.

## 8. Implementation Details in Practice

### 8.1. Choosing the Hash Function

The hash function must be fast, have good avalanche effect, and produce uniformly distributed bits. Commonly used hashes:

- **MurmurHash3** (32 or 64 bit) – good balance of speed and quality.
- **xxHash** – very fast, suitable for streaming.
- **CityHash** (Google) – fast for short keys.
- **HighwayHash** – fast and secure (SIMD).
- In Redis, they use the **64-bit xxHash** for HyperLogLog.

For HyperLogLog, a 64-bit hash is preferred because it allows counting up to 2^64 distinct elements. With a 32-bit hash, the maximum meaningful cardinality is about 2^32 (4 billion), but estimates beyond that suffer from hash collisions.

### 8.2. Register Size

For a 64-bit hash, the maximum possible ρ is 65 (since number of leading zeros from 0 to 64, plus 1). So we need 7 bits per register to store values 0..65. However, values above 50 are extremely rare (probability < 2^{-50}). Even rho=40 is astronomically improbable for practical cardinalities. But we must be able to store the maximum observed value, so we need up to 65. Thus, each register uses 7 bits. Many implementations use 6 bits (values 0..63) but may cap at 63, which is fine for cardinalities up to 2^63. Actually, for a 64-bit hash with leading zeros count (including a leading 1), the maximum ρ is 65. If we use 6 bits, we can store up to 63, which would underestimate if we happen to get ρ=64 or 65. The probability of seeing ρ=64 when M is smaller than 2^63 is essentially zero, but if M were 2^64, we would expect to see ρ around 64. So for safety, 7 bits are used. Aggregate memory: m \* 7 bits.

For m=2^14=16384, that’s 16384\*7 = 114688 bits ≈ 14 KB. That’s still tiny.

### 8.3. Counting Leading Zeros Efficiently

Most CPUs have a built‑in instruction: `CLZ` (Count Leading Zeros) on ARM, `LZCNT` on x86 (with BMI), or `BSR` (Bit Scan Reverse) on older x86. In software, we can use bit twiddling:

```c
int clz(uint64_t x) {
    if (x == 0) return 64;
    int n = 0;
    if ((x >> 32) == 0) { n += 32; x <<= 32; }
    if ((x >> 48) == 0) { n += 16; x <<= 16; }
    if ((x >> 56) == 0) { n += 8; x <<= 8; }
    if ((x >> 60) == 0) { n += 4; x <<= 4; }
    if ((x >> 62) == 0) { n += 2; x <<= 2; }
    if ((x >> 63) == 0) { n += 1; x <<= 1; }
    return n;
}
```

Alternatively, use compiler builtins like `__builtin_clzll()` (GCC/Clang).

### 8.4. Merging HyperLogLogs

One of the most powerful features of HyperLogLog is that two HLL data structures built from disjoint data sets can be merged by taking the element‑wise maximum of their registers:

For each bucket j, M_merged[j] = max(M1[j], M2[j]).

This works because the maximum ρ observed in the union of two streams is simply the maximum of the two individual maxima. The hash distribution ensures that the register values are independent? Actually they may not be independent if the same element appears in both streams, but for distinct elements, the merger works. If an element appears in both streams, its ρ value is the same, so the max retains the correct value. Thus, HLL supports merging without any loss of information, which is crucial for distributed systems.

This mergability is used in systems like Druid and Presto to pre‑compute HLL sketches per shard and then merge them at query time to get global cardinality estimates.

## 9. Example Implementation in Python

Let’s write a simplified but functional HyperLogLog in Python using 64‑bit hashing (via hashlib sha256 truncated? We’ll use Python’s built‑in hash but that’s not reliable across runs; better to use `mmh3` from the `mmh3` package). We’ll keep it clear, not optimized.

```python
import math
import mmh3  # pip install mmh3

class HyperLogLog:
    def __init__(self, p=14):
        self.p = p
        self.m = 1 << p  # number of registers
        self.registers = [0] * self.m
        # alpha constant based on p
        self.alpha = {16: 0.673, 32: 0.697, 64: 0.709}
        if self.m >= 128:
            self.alpha = 0.7213 / (1 + 1.079 / self.m)
        else:
            self.alpha = self.alpha.get(self.m, 0.7213 / (1 + 1.079 / self.m))

    def add(self, item):
        # hash item to 64-bit using mmh3 hash64 (returns tuple of ints)
        # We'll use the first element for simplicity
        h1, h2 = mmh3.hash64(item, seed=0)
        hash_val = h1  # use first 64 bits
        # Extract bucket from first p bits
        bucket = hash_val >> (64 - self.p)
        # Remaining bits for rho
        w = hash_val & ((1 << (64 - self.p)) - 1)
        # Leading zeros in w (pad with leading 1 to avoid zero)
        if w == 0:
            rho = 65  # all zeros, position 65? Actually leading zeros count 64 -> +1 = 65
        else:
            # Count leading zeros: Python int.bit_length
            rho = (64 - self.p) - w.bit_length() + 1  # position of first 1
            if rho == 0: rho = 1  # shouldn't happen
        if rho > self.registers[bucket]:
            self.registers[bucket] = rho

    def count(self):
        # Count zeros
        Z = self.registers.count(0)
        if Z == self.m:
            return 0
        # Harmonic mean
        sum_inv = sum(1.0 / (1 << reg) for reg in self.registers)  # 2^{-reg}
        E = self.alpha * self.m * self.m / sum_inv
        # Small range correction
        if E <= 5.0 * self.m / 2.0:
            if Z > 0:
                E = self.m * math.log(self.m / Z)
        else:
            # Large range correction (if needed for 64-bit, but we skip)
            pass
        return int(E + 0.5)

# Example usage
hll = HyperLogLog(p=10)
for i in range(10000):
    hll.add(str(i))
print(hll.count())  # Expected close to 10000
```

Note: Python implementation is for illustration; production code should use bit operations, precomputed powers, and efficient loops.

## 10. Real-World Use Cases

HyperLogLog is everywhere:

- **Redis**: The `PFADD`, `PFCOUNT`, `PFMERGE` commands implement HyperLogLog with p=14 (16384 registers), giving about 0.81% error. Memory per key is about 12 KB. Used for real‑time unique visitor counts, distinct IPs, etc.

- **Apache Druid**: Druid uses HLL (with a variant called HLLSketch) to approximate distinct counts for high‑dimensional data. It can merge sketches from different segments efficiently.

- **Google BigQuery**: The `APPROX_COUNT_DISTINCT` function uses HLL++ (the Google variant) with automatic precision selection.

- **Presto / Trino**: They provide `approx_distinct` using HLL, with configurable standard error.

- **ClickHouse**: Uses an HLL implementation (Uniq state) to count distinct values in analytics queries.

- **Stream processing** (Flink, Kafka Streams): Use HLL as a stateful aggregator for unique counts over sliding windows.

- **Database query optimizers**: Some systems use HLL to estimate dataset size and distinct values for query planning.

## 11. Comparison with Other Probabilistic Algorithms

### 11.1. Count-Min Sketch (CMS)

CMS estimates frequency counts (not distinct counts). It can approximate how many times an element appears, but not the cardinality of distinct elements. For cardinality, you could sum over all distinct elements, but that defeats the purpose.

### 11.2. Bloom Filter Cardinality Estimator

A Bloom filter can be used to estimate cardinality: after inserting all elements, the number of set bits follows a predictable expectation given the cardinality. However, the variance is higher than HLL, and merging Bloom filters of different sizes is problematic. Also, Bloom filters are not designed for cardinality estimation; they are membership queries.

### 11.3. Theta Sketches

Theta sketches (from Apache DataSketches) are another family of cardinality estimation algorithms. They work by maintaining a sample of hashed values and dynamically adjusting a threshold to keep the sample size small. They can be more accurate for small cardinalities and support set operations (intersection, union, difference) precisely. HLL is simpler and faster for union, but Theta sketches can handle more complex set queries.

### 11.4. K‑Minimum Values (KMV)

KMV (or K‑minimum) algorithm stores the k smallest hash values seen. It provides an unbiased estimator of cardinality: M ≈ (k-1) / (largest hash value among stored?). Actually, if we store the k smallest hashes, and the k‑th smallest is H, then M ≈ (k-1) / H (assuming hash in [0,1)). KMV has lower memory than HLL for high accuracy? HLL is more memory efficient for a given error because it uses the leading zeros property. KMV requires storing k hash values (e.g., k=1024 x 8 bytes = 8 KB). HLL with same memory gives about 1% error. KMV with k=1024 gives error ≈ 1/√k ≈ 3%. So HLL wins for memory vs error.

### 11.5. HyperLogLog vs Adaptive Sketches

There is also a variant called **Adaptive HLL** that changes the precision based on the cardinality. And **Virtual HyperLogLog** that extends to very high cardinalities.

## 12. Limitations and Pitfalls

### 12.1. Hash Collisions

Although rare with 64‑bit hash, collisions can cause underestimation. The theoretical bound is about 2^32 elements before collisions become non‑negligible. For counting beyond 10^12, consider using 128‑bit hash or switch to a more explicit technique. The data duplication (if two different elements hash to the same value) still counts as one distinct.

### 12.2. Non‑Uniform Distributions

HLL assumes a perfect hash. If the hash function has biases, the estimates degrade. Always test with your data.

### 12.3. Small Set Underestimation

Even with linear counting correction, HLL can underestimate very small sets if the hash distribution leads to many collisions? But linear counting is unbiased for small sets. However, the transition between linear counting and harmonic mean can cause a discontinuity. HLL++ handles this smoothly with bias tables.

### 12.4. Set Operations Beyond Union

HLL supports union (by max), but **intersection** and **difference** are not directly supported. To estimate intersection cardinality, you can compute |A ∩ B| = |A| + |B| - |A ∪ B|, but this suffers from high error when the sets are similar. There are variants like **HyperLogLog++ with inclusion‑exclusion** or using **Theta sketches** for better set operations.

### 12.5. Floating Point Precision

The sum of many 2^{-reg} values can be numerically stable, but for m=2^14, sum may be small. Double precision is fine.

## 13. Conclusion

HyperLogLog is a masterpiece of algorithmic engineering. It solves a seemingly impossible problem—counting up to billions of distinct items with kilobytes of memory—using the simple intuition that the longest run of leading zeros in hashed values reveals the logarithm of the cardinality. By combining the harmonic mean, stochastic averaging, and rigorous bias correction, HyperLogLog achieves an accuracy of 2‑3% with memory less than the size of a single Ethernet packet.

The algorithm’s elegance lies in its trade‑off: it sacrifices exactness for enormous savings in space and time. And for many real‑world applications—Web analytics, network monitoring, database statistics, real‑time dashboards—that trade‑off is not just acceptable; it’s transformative.

Whether you are building a high‑speed data pipeline, optimizing a query engine, or just trying to answer your product manager’s question about unique users, HyperLogLog is your friend. Remember: 1.5 kilobytes and a 2% error. That’s the power of probabilities.

And if you ever need even more accuracy, you can always increase `p`—each extra bit doubles the number of registers and reduces error by a factor of sqrt(2). But for most cases, the default `p=14` gives you the sweet spot: a single Ethernet packet’s worth of memory for a near‑perfect estimate of the uncountable.

_Further reading:_

- Flajolet, P., et al. _HyperLogLog: the analysis of a near-optimal cardinality estimation algorithm_ (2007)
- Heule, S., et al. _HyperLogLog in Practice: Algorithmic Engineering of a State of The Art Cardinality Estimation Algorithm_ (2013)
- Redis documentation on HyperLogLog
- Apache DataSketches documentation

_Code repositories:_

- Redis hyperloglog.c (C)
- Google HLL++ (C++ in OpenCensus)
- Python hll library on PyPI

Now go forth and approximate.
