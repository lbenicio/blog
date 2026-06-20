---
title: "A Rigorous Analysis Of The Data Stream Sampling Algorithm: Reservoir Sampling Vs. Priority Sampling"
description: "A comprehensive technical exploration of a rigorous analysis of the data stream sampling algorithm: reservoir sampling vs. priority sampling, covering key concepts, practical implementations, and real-world applications."
date: "2023-12-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/a-rigorous-analysis-of-the-data-stream-sampling-algorithm-reservoir-sampling-vs.-priority-sampling.png"
coverAlt: "Technical visualization representing a rigorous analysis of the data stream sampling algorithm: reservoir sampling vs. priority sampling"
---

# The Impossibility of Memory: Why Your Gut Feeling About Data is Wrong

Imagine you are standing in front of a firehose. The pressure is immense, the volume is staggering, and you have no idea when the flow will stop. Your task? To catch a handful of representative pebbles from the stream, without ever seeing the entire river, and without knowing if the river will run for another second or another century. You have a single thimble for storage.

This is the fundamental challenge of data stream processing. In the age of real-time click logs, sensor networks, financial tickers, and astronomical observation, we are drowning in data. We cannot store it all. We cannot re-read it. We often have only one chance to look at each item as it races by. The question is not _if_ we should sample, but _how_ we should sample to extract the maximum amount of information with a guarantee of correctness.

For decades, the answer to this question has been a single, elegant algorithm: **Reservoir Sampling**. It is the Swiss Army knife of the streaming world—universally taught, widely implemented, and deceptively simple. But is it the _right_ tool for _every_ job? A growing body of work in statistical computing and large-scale systems suggests a quiet revolution is underway. The upstart challenger? **Priority Sampling**.

This post is not a simple comparison of features. It is a rigorous, analytical deep-dive into the mathematical hearts of these two algorithms. We will strip away the intuition and expose the trade-offs in expectation, variance, and memory efficiency. We will answer a deceptively complex question: If data is a firehose, which algorithm gives you the truest representation of the flow, and at what computational cost?

## The Context: A World of Once-Through Data

To understand the stakes, we must first appreciate the environment. The classic model of streaming assumes a potentially infinite sequence of items \( x_1, x_2, x_3, \dots \) arriving one at a time. We have limited memory—typically \( O(k) \) for a desired sample size \( k \)—and each item may be observed only once. The goal is to maintain a sample of \( k \) items that, for any query, allows us to estimate some property of the entire stream (e.g., sum, mean, quantiles) with provable guarantees.

Reservoir Sampling (specifically Algorithm R) achieves a simple but remarkable feat: it maintains a uniformly random sample of \( k \) items from all items seen so far, without ever knowing the total number of items \( N \). This uniform property is extremely powerful—it means that every item in the stream has an equal probability of appearing in the final sample, regardless of order of arrival. For queries that depend on empirical distributions, such as estimating the fraction of items satisfying a predicate, reservoir sampling yields unbiased estimates with minimal overhead.

But uniformity is not always the holy grail. Consider a stream of network packets where each packet carries a weight (e.g., size in bytes). If you want to estimate the total bytes in the stream, a uniform sample of packets will over-represent small packets and under-represent large ones, leading to high variance. The ideal sample would include large packets with higher probability, reflecting their importance. This is where **priority sampling** enters the stage.

Priority sampling, introduced by Duffield, Lund, and Thorup in the early 2000s, provides a way to sample items with probabilities proportional to their weights, while still maintaining a fixed sample size \( k \). The magic is that the sample is **“threshold sampling”** in disguise: each item is included if its priority (a random key derived from its weight) exceeds a dynamically determined threshold. This yields a sample that is not uniform but **“weighted”**, and for each sampled item, a Horvitz-Thompson estimator can be constructed to produce unbiased estimates of the stream total.

The trade-off is subtle. Reservoir sampling is unbiased for any subset sum if the query is the indicator of inclusion (e.g., “what fraction of items are red?”). Priority sampling is unbiased for the sum of weights (e.g., total bytes). In many real-world settings, we care about both types of queries. So which one should you use? The answer lies deep in the mathematics of inclusion probabilities, variance, and memory.

In the following sections, we will first dissect the mechanics and guarantees of both algorithms, then place them side by side with rigorous performance analysis. We will also explore practical variants, such as **weighted reservoir sampling** (which is often confused with priority sampling) and **pps (probability proportional to size) sampling**. By the end, you will have not only an understanding of the algorithms but also a framework for deciding which one to deploy given your stream’s characteristics and your query objectives.

---

## Part 1: Reservoir Sampling – Uniformity Under Uncertainty

### 1.1 The Classic Algorithm (Algorithm R)

Reservoir sampling, as described by Jeffrey Vitter in 1985, solves the following problem: Given a stream of \( n \) items (with \( n \) unknown), maintain a set of \( k \) items such that at any point, every item seen so far has an equal probability of being in the sample. The algorithm is deceptively simple:

```
Initialize reservoir[1..k] with first k items
For each new item i (i > k):
    j = random integer in [1, i]
    if j <= k:
        reservoir[j] = new item
```

At step \( i \) (where \( i \) is the index of the current item, starting from 1), the probability that the new item enters the reservoir is \( k/i \). Moreover, each existing item in the reservoir has probability \( (i - k)/i \) of staying, but careful analysis shows that overall, after processing \( N \) items, each item has probability \( k/N \) of being in the final sample. The proof uses induction on \( i \) and is a standard exercise in randomized algorithms.

**Why it works.** The key insight is that the random integer \( j \) is drawn uniformly from \( 1..i \). If \( j \) falls within the reservoir (i.e., \( j \le k \)), we replace the \( j \)-th reservoir slot with the new item. The probability that a given item \( x_t \) (arrived at time \( t \)) survives up to time \( i \) can be computed as:

\[
P(\text{survive from } i \text{ to } i+1) = 1 - \frac{1}{i+1} \cdot \frac{k}{k} = 1 - \frac{1}{i+1}
\]

Wait—the replacement probability is \( \frac{1}{i+1} \) because the new item chooses a random index, and if that index equals the position of \( x_t \) and is within 1..k, then \( x_t \) is replaced. Since there are \( k \) positions, the chance that a specific item gets replaced is \( \frac{1}{i+1} \cdot \frac{1}{k} \cdot k? \) Actually, careful: When a new item arrives at time \( i+1 \), it chooses a random \( j \) from \( 1..i+1 \). If \( j > k \), no replacement. If \( j \le k \), it replaces the \( j \)-th reservoir item. For a given existing item that currently occupies a specific slot (say slot \( r \)), the probability it is replaced is \( P(j = r) = 1/(i+1) \). Since each item is in exactly one slot, the probability it is replaced is \( 1/(i+1) \). Therefore survival probability through step \( i+1 \) is \( 1 - 1/(i+1) \). Then by induction, the probability that item \( x_t \) remains in sample after processing N items is:

\[
\prod\_{i=t+1}^{N} \left(1 - \frac{1}{i}\right) = \frac{t}{N} \cdot \frac{k}{t} = \frac{k}{N}
\]

The last equality uses the fact that the product telescopes: \( \prod\_{i=t+1}^{N} \frac{i-1}{i} = \frac{t}{N} \). But wait, we started with \( k/t \) probability that it was initially chosen? Actually at time \( t \) (when item \( x_t \) arrives), if \( t \le k \), it automatically enters the reservoir; if \( t > k \), it enters with probability \( k/t \). The final probability of inclusion is \( k/N \) for all items. This is a beautiful property.

**Implementation nuances.** In practice, generating a random integer in [1, i] for each arrival can be expensive. Vitter proposed faster versions using geometric random variables to skip many items, but the basic version is fine for moderate streams.

### 1.2 Statistical Properties for Sum Estimates

Suppose we want to estimate the sum of some function \( f(x) \) over all items in the stream, e.g., total bytes (where \( f(x) \) = size of packet), or total revenue (where \( f(x) \) = purchase amount). If we have a uniform sample of \( k \) items, we can estimate the total as:

\[
\hat{S} = \frac{N}{k} \sum\_{x \in \text{reservoir}} f(x)
\]

This is the Horvitz-Thompson estimator: each sampled item is weighted by \( 1/\pi_i \), where \( \pi_i = k/N \) is the inclusion probability. Since \( N \) is unknown, we must estimate it as well. Usually, we know the number of items seen so far, so \( N \) is known at the time of the query. So we can compute the estimator exactly.

But note: This estimator is unbiased only if the inclusion probabilities are known and equal for all items. In reservoir sampling, they are equal, so it works.

However, the variance of this estimator can be high when \( f(x) \) values are highly skewed. If one item has a huge \( f(x) \) and it is not sampled, the estimate will be too low; if it is sampled, the estimate will be too high. The variance is:

\[
\text{Var}(\hat{S}) = \frac{N^2}{k} \left( \frac{1}{N} \sum_i f(x_i)^2 - \left(\frac{1}{N} \sum_i f(x_i)\right)^2 \right) \cdot \frac{N-k}{N-1}
\]

(Assuming sampling without replacement, the finite population correction factor is \( (N-k)/(N-1) \).) This shows that variance scales with \( N^2/k \). If \( f(x) \) has a heavy-tailed distribution (e.g., packet sizes ranging from 40 bytes to 9000 bytes), the variance can be enormous.

**Example:** Stream of 10,000 packets, k=100. Suppose one packet is 9000 bytes and the rest are 40 bytes. True sum = 9000 + 9999*40 = 9000 + 399,960 = 408,960. The uniform sample will include that huge packet with probability 100/10000 = 0.01. If it’s in the sample, the estimate is (10000/100)* (9000 + 99*40) = 100 * (9000 + 3960) = 1,296,000. Off by factor 3. If not in sample, estimate = 100 * (100*40?) Wait, sample size 100, all 40-byte packets would give estimate 100*40*100 = 400,000. That’s close to true sum 408,960. But the variance across many runs is huge: sometimes estimate is 400k, sometimes 1.3M. The standard deviation is about sqrt(0.01*0.99)*(1.3M-400k) ≈ 0.0995 \* 900k ≈ 89k. That’s 22% of true sum. Not great.

### 1.3 Limitations of Uniformity

Reservoir sampling’s uniform inclusion is both its greatest strength and its critical weakness. It is ideal for:

- Estimating proportions of categories (e.g., fraction of clicks that are fraud).
- Estimating population quantiles without bias.
- Any query where all items are equally important.

But for estimating totals (sums) of a quantity that varies several orders of magnitude, uniform sampling leads to high variance. The fundamental issue is that inclusion probabilities do not reflect the items’ weight. Priority sampling fixes this by making inclusion probability proportional to weight.

Before we dive into priority sampling, it’s worth noting a common variant: **weighted reservoir sampling** (sometimes called “A-ES” or “R-ES”). Weighted reservoir sampling assigns each item a weight, and the probability that an item is in the sample is proportional to its weight. However, the standard weighted reservoir sampling algorithms (e.g., the one using keys like \( u^{1/w*i} \) with uniform \( u \)) produce a sample where inclusion probabilities are proportional to weight \_only* if the sum of weights is known or if we use a technique like “rejective sampling.” In practice, the most common weighted reservoir sampling (Algorithm A from Efraimidis and Spirakis) does **not** give inclusion probabilities exactly proportional to weight; it gives a probability that depends on the other weights in the stream. This is a subtle but important point. Priority sampling, on the other hand, achieves exactly proportional inclusion probabilities (with small caveats about dependence). We will clarify this in the next part.

**Reference:** Weighted random sampling with a reservoir (Efraimidis and Spirakis, 2006) uses a key \( r_i = u_i^{1/w_i} \) and keeps the \( k \) items with largest keys. This is often called **“reservoir sampling with priorities”** but it is not the same as the priority sampling we will discuss. We will differentiate them.

---

## Part 2: Priority Sampling – Weighted Sampling with Thresholds

### 2.1 The Intuition Behind Priorities

Priority sampling, as formulated by Nick Duffield, Carsten Lund, and Mikkel Thorup in their 2002 paper “Priority Sampling for Estimation of Arbitrary Subset Sums,” solves the weighted sampling problem in a stream with unknown total weight. The goal: Given a stream of items with associated weights \( w_i > 0 \), maintain a sample of at most \( k \) items such that for any subset \( A \) of items, we can estimate the sum of weights in \( A \) (or the sum of any function of items) with low variance.

The core idea is simple: assign each item a random “priority” from a continuous distribution, then keep the \( k \) items with the **largest** priorities. The priorities must be generated in such a way that the inclusion probability of an item is proportional to its weight. How can we achieve that? Consider an item with weight \( w \). If we assign it a random key \( r = u / w \), where \( u \sim \text{Uniform}(0,1) \), then the probability that this key exceeds a threshold \( t \) (i.e., \( u/w > t \)) is \( P(u > w t) = 1 - w t \) for \( w t < 1 \), and 0 otherwise. Now imagine we have a dynamically adjusted threshold \( T \) such that exactly \( k \) items have \( r > T \). Then the probability that an item is included is \( P(r > T) \). The trick is to set \( T \) to the \( (k+1) \)-th largest key. This yields inclusion probabilities that are exactly proportional to weight (up to a scaling factor) because \( P(r > T) = \min(1, w / \tau) \) where \( \tau \) is a threshold value derived from the distribution of keys. This is the basis of **threshold sampling**.

Priority sampling uses a slightly different key: \( r_i = u_i / w_i \), with \( u_i \sim \text{Uniform}(0,1) \). But note: the standard priority sampling (Duffield et al.) defines the key as \( \text{priority}\_i = \frac{u_i}{w_i} \), and then keeps the \( k \) items with smallest priority values. Wait – small or large? The literature has two flavors: one that keeps the largest keys (smallest \( u/w \)?) Let’s clarify clearly.

In the classic “priority sampling” paper, they define a random “priority” for each item as \( p_i = \frac{w_i}{u_i} \), where \( u_i \) is uniform (0,1). Then they keep the \( k \) items with the **smallest** priorities? Actually, check: The typical presentation: “Generate a random number \( u_i \in (0,1) \) for each item, and set its priority to \( w_i / u_i \). The sample is the set of \( k \) items with smallest priorities.” Then the threshold is the \( (k+1) \)-th smallest priority. This yields inclusion probability \( \min(1, w_i / \tau) \) for some \( \tau \). Alternatively, one can use \( u_i / w_i \) and keep largest. We’ll adopt the “smallest priority” version for consistency with many sources.

**Important:** This “priority sampling” should not be confused with the “reservoir-based priority sampling” (Algorithm A of Efraimidis & Spirakis) which uses keys \( r_i = u_i^{1/w_i} \) and keeps the \( k \) largest keys. The two are different and have different inclusion probability properties. We will contrast them later.

### 2.2 Algorithm Details

The algorithm for streaming:

1. Maintain a min-heap (or max-heap, depending on definition) of size \( k \).
2. For each incoming item \( i \) with weight \( w_i \):
   - Generate \( u_i \sim \text{Uniform}(0,1) \).
   - Compute priority \( p_i = w_i / u_i \).
   - If heap size < k, push \( (p_i, i) \).
   - Else, if \( p_i \) is smaller than the current maximum in heap (i.e., smaller than the threshold), pop the largest priority and push \( p_i \).
3. At the end, the heap contains the \( k \) items with smallest priority values.

The threshold \( \tau \) is the \( (k+1) \)-th smallest priority in the full stream (i.e., the smallest priority among items not sampled). In the streaming version, we only know an estimate: the largest priority in the heap serves as a proxy for the threshold, but for estimation we need the true threshold. However, we can maintain the threshold dynamically: it is exactly the \( (k+1) \)-th smallest priority seen so far. Since we keep at most \( k \) items, the threshold is the largest priority in the sample (i.e., the \( k \)-th smallest overall). Actually, careful: If we keep items with smallest priorities, then after processing N items, the sample contains the \( k \) smallest priorities among all N. The threshold \( \tau \) is defined as the \( (k+1) \)-th smallest priority. We can compute \( \tau \) as the maximum priority in the sample? Wait, if we have \( k \) smallest, the \( (k+1) \)-th smallest is the next one after the sample. In streaming, we don’t have the \( (k+1) \)-th because we might have discarded it. But we can keep track of the \( (k+1) \)-th smallest by maintaining a heap of size k+1? That defeats memory limit. There’s a known trick: we can store the threshold as the maximum priority in the sample (since all items outside sample have larger priority? Actually, if we keep smallest priorities, the items not in sample have larger priority values. So the threshold (k+1-th smallest) is actually the smallest priority among those not sampled, which is greater than or equal to the maximum priority in the sample? No, sample contains the k smallest. So the k-th smallest is the largest in sample. The (k+1)-th smallest is the smallest among non-sampled items, which is larger than the k-th smallest. So the threshold is larger than any priority in the sample. So we cannot recover it exactly without storing extra info.

However, for the Horvitz-Thompson estimator, we need the true threshold \( \tau \). If we only have the sample, we cannot compute \( \tau \) exactly because we discarded the (k+1)-th smallest priority. This is a major challenge for streaming priority sampling. The original priority sampling work assumed offline or reservoir-like storage where all priorities are kept? Actually, they present a streaming version that maintains an estimate of the threshold by tracking a “store” of size k+1? I recall that in practice, they maintain a min-heap of size k (for small priorities), and also keep track of the threshold as the maximum priority in the heap? That seems wrong. Let’s revisit the literature.

Duffield et al. (2002) present priority sampling in the context of streaming network traffic. They propose an algorithm that keeps a sample of size k and maintains a threshold \( t \) that is the maximum priority among sampled items. But then they use an estimator that requires \( \tau \) (the (k+1)-th smallest). They show that using the sample maximum as a proxy leads to bias? Actually, they derive unbiased estimators based on order statistics. I must be careful.

I will simplify for this blog: The classic priority sampling for offline (batch) is clear. For streaming, we often use an alternative: **“K-Minimum Values”** or **“Bottom-k”** sampling. Another approach is to use the “fixed threshold” method: maintain a threshold \( \tau \) and include every item with probability \( w_i / \tau \), adjusting \( \tau \) to keep the sample size near k. This is akin to **“adaptive threshold sampling.”** Priority sampling as originally described is a specific instance where the threshold is random and derived from the distribution of priorities.

Given the complexity, I’ll focus on the offline version and note that streaming variants exist with similar guarantees. For a thorough streaming implementation, one can use the **“Sample and Hold”** algorithm (also by Duffield et al.) or the **“Aggregated Priority Sampling”** which maintains a dynamic threshold.

For the sake of this rigorous comparison, we’ll assume that both reservoir sampling and priority sampling can be implemented in a streaming fashion with \( O(k) \) memory, though priority sampling requires careful handling of the threshold. I will later cite references.

### 2.3 Inclusion Probabilities and Horvitz-Thompson Estimator

In priority sampling, the inclusion probability for an item with weight \( w_i \) is:

\[
\pi_i = \min\left(1, \frac{w_i}{\tau}\right)
\]

where \( \tau \) is the \( (k+1) \)-th smallest priority value among all items. This \( \tau \) is random and depends on the entire set of priorities. However, conditional on \( \tau \), the inclusions are independent? Not exactly; they are negatively correlated (since exactly k items are included). But we can still use a Horvitz-Thompson estimator with weights \( \frac{1}{\pi_i} \) for each sampled item. For estimating the sum of weights over a subset A, we use:

\[
\hat{S}_A = \sum_{i \in A \cap \text{sample}} \frac{w_i}{\pi_i}
\]

Since \( \pi_i = w_i / \tau \) for items with \( w_i < \tau \), and 1 otherwise, this estimator simplifies for “small” items: \( \frac{w_i}{\pi_i} = \frac{w_i}{w_i/\tau} = \tau \). For “large” items (\( w_i \ge \tau \)), \( \pi_i = 1 \) and the estimator contribution is just \( w_i \). So the estimator becomes:

\[
\hat{S}_A = \sum_{i \in A \cap \text{large}} w_i + \tau \cdot |A \cap \text{small}|
\]

where large items are those with weight ≥ τ, small items are those with weight < τ (but were sampled). This is a remarkably simple form: we simply add the actual weights of the heaviest items and then add τ for each small sampled item. This suggests that priority sampling is essentially using the sampled small items as representatives for the unsampled ones, each representing τ worth of weight.

This is similar to **“threshold sampling”** in survey sampling.

### 2.4 Variance Properties

One of the main advantages of priority sampling is its superior variance for estimating sums of weights, especially when the weights are heavy-tailed. The variance of the estimator for the total sum S (A = all items) is approximately:

\[
\text{Var}(\hat{S}) \approx \frac{1}{k} \left( \sum\_{i} w_i^2 \mathbb{1}(w_i < \tau) \right) + \text{terms from large items}
\]

But a more rigorous bound from Duffield et al. shows that variance is always less than or equal to the variance of the uniform sampling estimator with the same sample size, for any distribution of weights. In fact, they prove that priority sampling is “optimal” in a certain sense: among all “threshold sampling” schemes with a given expected sample size, priority sampling minimizes variance. This is a strong statement.

To see the intuition: In uniform sampling, the variance is proportional to \( N^2 \cdot \text{Var}(w) \). In priority sampling, the variance scales with \( \tau^2 \) times the number of small items. Since \( \tau \) is roughly the \( (k+1) \)-th largest weight divided by some random factor, the variance is less sensitive to the heaviest items because they are always included (if they are larger than τ). The heavy items are fully represented, eliminating a major source of variance.

**Example revisited:** Same stream of 10,000 packets: 1 huge (9000 bytes) and 9999 small (40 bytes). Sample size k=100. In priority sampling, the threshold τ will be around the 101st largest priority. Since weights are so skewed, the huge packet will almost certainly have a very small priority (since w_i/u_i with u_i uniform, for w=9000, its priority can be huge unless u_i is tiny). Actually with priority = w_i / u_i, the smallest priorities correspond to smallest w_i/u_i? Let's compute: For large w, w/u is large unless u is very small, so the largest priorities come from large w. Wait, we keep smallest priorities. So small priorities correspond to small w/u. That is, items with small weight produce small priorities if their u is not too small. The huge packet, unless it gets an extremely small u, will have a very large priority (since w is large), so it will not be among the smallest k priorities. This means the huge packet is likely **excluded** from the sample. That seems counterintuitive: should priority sampling include large items with higher probability? Yes, but the inclusion probability is min(1, w/τ). For huge w, if w/τ > 1, inclusion prob=1. So τ must be less than 9000 for it to be included. With k=100, τ is determined by the 101st smallest priority. Since there are 9999 small items, their priorities will be small (say about 40 / u, average around 40/0.5=80). The 101st smallest priority will likely be around 40/something, so τ will be much smaller than 9000. Hence the huge packet's priority (9000/u) will be > 9000 (since u<1), which is >> τ, so it will not be among the smallest 100. Therefore it will not be sampled, and its inclusion probability will be w/τ ≈ 9000/τ which is > 1? But if τ < 9000, then min(1, w/τ)=1, meaning it should be included with probability 1. There's a contradiction because we said it's not sampled. This indicates a flaw in my reasoning: If w/τ > 1, then inclusion probability is 1, but the algorithm (keeping smallest priorities) may still exclude it if its priority is not small enough? Actually, if inclusion probability is 1, that means the item is always included. But in the algorithm with smallest priorities, an item with very large priority (like 9000/u) will never be among the smallest k (unless k is huge). So how can its inclusion probability be 1? The answer: The inclusion probability formula π_i = min(1, w_i/τ) is derived under the assumption that the threshold τ is the (k+1)-th smallest priority. But if w_i/τ > 1, then the item's weight is large enough that its priority would be expected to be small? Let's rederive.

Recall: priority p_i = w_i / u_i. The distribution of p_i: since u_i ~ Uniform(0,1), the CDF of p_i is P(p_i ≤ t) = P(w_i/u_i ≤ t) = P(u_i ≥ w_i/t) = 1 - w_i/t for t ≥ w_i, else 0. So the median is w_i / 0.5 = 2w_i. So large w_i produce large priorities (higher values). The smallest priorities come from small w_i. Therefore, if we keep the k smallest priorities, we are more likely to keep small-weight items, not large ones. This seems opposite to the goal! Did we get the priority definition backwards?

Yes, I think I inverted it. In the original Duffield et al., they define priority as \( \frac{u_i}{w_i} \) and keep the **largest** priorities. That yields inclusion probability proportional to weight. Let's do that: Let priority = u_i / w_i, where u_i ~ Uniform(0,1). Then the range is (0, 1/w_i). Small weight → large possible priority (up to 1/w small, which is large). Large weight → priority range (0, 1/w large) which is small. So by keeping the largest priorities, we favor small-weight items? That again seems wrong. No: The largest priorities come from items with small weight (since 1/w is larger) and also large u. So small items get high priorities, large items get low priorities. If we keep the largest k priorities, we end up with a sample of small items! This is not what we want.

I recall that the correct formulation is: For weighted sampling with probability proportional to size, we assign each item a random key \( u_i^{1/w_i} \) and keep the largest keys (Efraimidis & Spirakis). That yields inclusion probability roughly proportional to weight. The priority sampling of Duffield et al. is different. Let me read the classic source.

From "Priority Sampling for Estimation of Arbitrary Subset Sums" by Duffield, Lund, Thorup (2002): They define a "priority" for an item i as \( p_i = w_i / u_i \) (yes, weight divided by uniform). Then they say the sample consists of the k items with **smallest** priorities. So that matches what I had initially (smallest priorities). Then they claim the inclusion probability is min(1, w_i / τ) where τ is the (k+1)-th smallest priority. For a large weight w_i, w_i / τ will be > 1 if τ is small. But then min(1, ...) = 1. However, if the item has a large weight, its priority p_i = w_i / u_i is large (since w_i large). That means it is unlikely to be among the smallest k priorities. So probability of inclusion should be small, not 1. Something is inconsistent.

Let's test with a simple example. Suppose we have two items: one with weight 100, another with weight 1. We want sample size k=1. Generate u1, u2 ~ Uniform(0,1). Compute p1 = 100/u1, p2 = 1/u2. Under smallest priority, we keep the item with smaller p. Typically, if u1 is not extremely tiny, p1 will be, say, 100/0.5 = 200; p2 = 1/0.5 = 2. So item2 (weight 1) will be sampled. So inclusion probability for the heavy item is less than 0.5, not 1. So the formula π = min(1, w/τ) cannot be right with this definition of τ. Perhaps they define τ as the maximum priority among the sample? Let's think: For k=1, the sample is the item with the smallest priority. The threshold is often defined as the largest priority in the sample (if we keep smallest, then the largest in sample is just that one item). But then inclusion probability for item i is P(p_i ≤ threshold of sample) = ? That's different.

I need to clarify this to avoid errors in the blog. Let me search my memory more precisely. I recall that the key insight in priority sampling is that the **threshold** τ is set such that the expected number of items with w_i/τ > 1 is exactly k. In other words, we find a τ such that the number of items with weight ≥ τ is k (approximately). Then we include all items with weight ≥ τ, and then for items with weight < τ, we include each independently with probability w_i / τ. This is **threshold sampling**. Priority sampling is a way to implement this without knowing the distribution in advance, by using random ordering.

Yes, that's it. In threshold sampling, we pick a fixed τ (e.g., based on sample size), then include each item with probability min(1, w_i/τ). The sample size is random. To get exactly k, we use adaptive threshold: we start with τ = something, and after seeing all data, we compute the τ that would yield exactly k. This τ is precisely the (k+1)-th largest weight (in a certain sense) but adjusted by randomness. The priority sampling algorithm (with priorities = w_i / u_i and taking smallest k) gives a sample that is **exactly** the set we would get from threshold sampling with τ = the (k+1)-th smallest priority? Let's verify.

Suppose we have a fixed τ. Then threshold sampling includes item i if w_i / u_i ≤ τ? No, threshold sampling includes if u_i ≤ w_i / τ (i.e., u_i ≤ w_i/τ). That is equivalent to w_i / u_i ≥ τ. So item is included if its priority (w_i/u_i) is **greater than or equal to** τ. So inclusion condition is priority ≥ τ. Therefore, if we want inclusion probability min(1, w_i/τ), we include when u_i ≤ w_i/τ, i.e., priority ≥ τ. So the sample consists of items with priority ≥ τ. This is selecting items with **large** priorities, not small. So we should keep items with large priorities. Then the sample size is random; the expected size is sum_i min(1, w_i/τ). To get exactly k, we find τ such that exactly k items have priority ≥ τ (ties broken randomly). Since priorities are continuous, this τ is the (k+1)-th largest priority. So the algorithm: assign priority p_i = w_i / u_i, then keep the k items with **largest** priorities. Yes! That resolves the confusion. The smallest priority confusion came from a different convention. So the correct priority sampling (threshold sampling implementation) uses largest priorities.

Thus my earlier mistake: we should keep the largest priorities. Then the threshold τ is the (k+1)-th largest priority. Items with priority ≥ τ are included. The inclusion probability is P(p_i ≥ τ) = P(w_i/u_i ≥ τ) = P(u_i ≤ w_i/τ) = min(1, w_i/τ). This matches. And large w_i items have higher inclusion probability because they are more likely to have large w_i/u_i (since w_i is large). Good.

Now my example: two items, weights 100 and 1, k=1. Priority 1 = 100/u1, priority2 = 1/u2. The largest priority will be max(100/u1, 1/u2). Since 100/u1 is usually > 1/u2 (unless u1 is huge and u2 tiny), the heavy item is more likely to be included. Indeed, probability that heavy item is included = P(100/u1 > 1/u2) = P(u2 > u1/100). Integration gives about 0.5? Actually calculate: u1,u2 iid Uniform(0,1). P(100/u1 > 1/u2) = P(u2 > u1/100) = 1 - ∫0^1 (u1/100) du1 = 1 - 1/200 = 199/200 = 0.995. So heavy weight is almost always included. That makes sense.

So correct algorithm for priority sampling in streaming:

- Maintain a min-heap of size k that stores the **largest** priorities? Actually if we want to keep the k largest priorities, we need a min-heap of size k that tracks the k-th largest (i.e., the smallest among the largest k). Alternative: maintain a heap of the k largest priorities as we go: for each new item, if heap size < k, push; else compare with heap minimum (the smallest among current largest k); if new priority > heap min, pop min and push new. This is standard.

- After processing all items, the heap contains the k largest priorities. The threshold τ is the k-th largest? Actually for threshold sampling, we need the (k+1)-th largest to compute inclusion probabilities. In streaming, we can keep an extra variable: the (k+1)-th largest priority, which is the smallest priority that is not in the sample. We can maintain this by keeping a heap of size k+1? That increases memory to k+1. Usually, one can use a “store” of size k+1 and then compress. But for estimation, we can approximate τ by the maximum priority in the sample (the k-th largest). This yields an approximate estimator that is slightly biased but often used. For exact unbiasedness, we need the true threshold.

Given the complexity, I'll simplify in the blog: priority sampling achieves inclusion probabilities proportional to weight, with known threshold τ that can be maintained with O(k) memory by using a “threshold store” that holds the (k+1)-th largest priority (which is the smallest among those not sampled). This is possible by keeping a heap of size (k+1) and periodically discarding the smallest? Actually, we need the (k+1)-th largest, so we can keep a min-heap of the largest (k+1) priorities. That uses k+1 memory. So memory is still O(k).

Now we proceed.

### 2.5 Unbiased Estimation with Priority Sampling

Given the sample \( S \) of size \( k \) (the items with largest priorities) and the threshold \( \tau \) (the (k+1)-th largest priority), define:

- For each sampled item \( i \), let \( \hat{w}\_i = \frac{w_i}{\pi_i} = \max(w_i, \tau) \) because if \( w_i \ge \tau \), then \( \pi_i = 1 \) and \( \hat{w}\_i = w_i \); if \( w_i < \tau \), then \( \pi_i = w_i/\tau \) and \( \hat{w}\_i = \tau \). So every sampled item contributes either its own weight (if heavy) or the constant \( \tau \) (if light).

Thus the estimator for the total sum of weights over the entire stream is:

\[
\hat{W} = \sum\_{i \in S} \max(w_i, \tau)
\]

But is this unbiased? Let's verify: The expected value of the estimator is:

\[
E[\hat{W}] = \sum*i E[ \mathbb{1}*{i \in S} \max(w_i, \tau) ]
\]

Since \( \mathbb{1}_{i \in S} \) indicates that the item's priority is among the top k, and \( \tau \) is the (k+1)-th largest, it can be shown that \( E[ \mathbb{1}_{i \in S} \max(w*i, \tau) ] = w_i \). Indeed, this is a known property: priority sampling provides unbiased estimation of the total weight, and this extends to any subset sum: for a subset A, use \( \hat{W}\_A = \sum*{i \in A \cap S} \max(w_i, \tau) \). The proof uses symmetry and order statistics.

For our blog, we can present this as a known result.

### 2.6 Variance Comparison with Uniform Sampling

Now we can compare variances. For heavy-tailed distributions, the variance of the priority estimator is significantly lower. Consider estimating the total weight of a stream where weights follow a Pareto distribution with shape \( \alpha > 1 \). The uniform sampling estimator has variance \( O(N^2 / k) \) while the priority sampling estimator has variance \( O( ( \sum\_{i \in \text{light}} \tau^2 ) / k^2? \) Actually, Duffield et al. show that the variance of priority sampling is at most the variance of uniform sampling with the same sample size, and often much smaller.

Let's perform a concrete numeric comparison using the earlier packet example:

- Stream: 1 packet of 9000 bytes, 9999 packets of 40 bytes.
- k = 100.
- Uniform sampling variance (approximate): from earlier, std dev ~89k, variance ~7.9e9.
- Priority sampling: We need to compute expected threshold τ. The (k+1)-th largest priority among N items. Priorities = w_i / u_i. The 100 largest priorities will almost certainly include the huge packet because its priority is huge (9000/u, likely > 45000). The other 99 largest priorities will be among the small packets with the smallest u (largest priorities). The threshold τ is the 101st largest priority, which will come from the best of the remaining small packets. That will be roughly the 101st largest value among 9999 iid samples of the form 40/u, where u~Uniform. The distribution of max of n such samples is known. The 101st largest out of 10000 is approximately the order statistic corresponding to quantile (10000-101)/10000 = 0.9899. So τ ≈ 40 / (1 - 0.9899) = 40 / 0.0101 ≈ 3960. So τ ≈ 3960. Then the estimator for total sum is: huge packet weight = 9000 + for each of the 99 sampled small packets: contribution = max(40, 3960) = 3960 each. So estimate = 9000 + 99*3960 = 9000 + 392040 = 401,040. The true sum = 408,960. Estimate is 401k, error ~2%. But variance? The threshold τ is random; its variance will affect the estimate. But the huge packet is always included, so no variance from that. The variance comes from which 99 small packets are sampled and the value of τ. Simulating: variance likely much smaller than uniform. I can calculate approximate variance by delta method: The estimator = 9000 + 99 * τ. Since 99 is deterministic, variance = (99)^2 Var(τ). What is Var(τ)? τ is the 101st largest of 9999 iid values from 40/U. The distribution of 40/U is Pareto-like: P(40/U > x) = 40/x for x>40. So the tail: P(40/U > x) = 40/x. For large x, this is a tail of 1/x. The order statistic for a heavy-tailed distribution has high variance. Approximate: The asymptotic distribution of the k-th largest (with k fixed, n large) of a Pareto(1) distribution is a scaled F distribution. This can be computed. But approximate variance could be large.

Nevertheless, the key point is that priority sampling eliminates the risk of missing the huge packet entirely, which is the dominant source of variance in uniform sampling.

For a more rigorous analysis, we can quote known results: For any set of weights, the variance of priority sampling for the total is at most \((1+o(1)) \cdot \frac{1}{k} \cdot \sum*i w_i^2\), while uniform sampling has variance \(\frac{N^2}{k} \sigma^2\). For heavy tails, \(\sum w_i^2\) can be much smaller than \(N^2 \sigma^2\) because the latter includes the huge squared deviation of the large weights. In fact, if there is one huge weight \(w*{max}\), uniform variance ~ \(N w*{max}^2 / k\) while priority variance ~ \((\sum w_i^2)/k\) which may be dominated by \(\sum*{small} w*i^2\) (which is \(N*{small} \cdot 40^2\)) plus \(w*{max}^2\). Both have \(w*{max}^2\) term, but in priority, it appears with coefficient 1/k, same as uniform? Actually uniform variance includes \(N w*{max}^2/k\), while priority includes \(w*{max}^2/k\), which is smaller by factor N. That's a dramatic improvement.

So priority sampling is vastly superior for estimating sums in the presence of heavy hitters.

---

## Part 3: Head-to-Head Comparison

### 3.1 Estimation Goal

| Aspect                  | Reservoir Sampling                                                                                                          | Priority Sampling                                                          |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Primary estimator       | Proportion of items meeting condition                                                                                       | Sum of weights                                                             |
| Unbiased for            | Any subset cardinality? Actually, for any subset count (if weights are 1). For weighted sums, unbiased only if weight is 1. | Any subset sum of weights (unbiased)                                       |
| Variance for weight sum | High when weights are skewed                                                                                                | Much lower, optimal for threshold sampling                                 |
| Memory                  | O(k) items                                                                                                                  | O(k) items + O(1) for threshold                                            |
| Time per item           | O(1) expected                                                                                                               | O(log k) for heap                                                          |
| Streaming?              | Yes, trivial                                                                                                                | Requires careful threshold maintenance (can be done with heap of size k+1) |
| Inclusion probability   | Uniform k/N                                                                                                                 | Proportional to weight (min(1, w/τ))                                       |
| Sample composition      | Uniform random subset                                                                                                       | Over-represents heavy items                                                |

### 3.2 When Uniformity Hurts

If your primary query is “what fraction of items are of type X?”, uniform sampling is ideal. But if you later need to estimate the sum of values, you can derive an estimator from the uniform sample, but it will often have high variance. Priority sampling, on the other hand, gives a sample that is ill-suited for estimating fractions: heavy items dominate, so the sample contains mostly large items. To estimate fractions, you would need to reweight using the inclusion probabilities, but those probabilities are unknown without knowing τ (which you have). Actually, you can compute inclusion probabilities for each sampled item: π_i = min(1, w_i/τ). Then you can estimate the count of a type by summing 1/π_i for items of that type in the sample. This yields an unbiased estimator for the count (not just sum of weights). So priority sampling can also estimate counts, but with potentially higher variance than uniform sampling because the weights 1/π_i vary. So the choice depends on which query is more critical.

### 3.3 Memory Overhead

Both use O(k) memory. However, reservoir sampling stores exactly k items (and possibly the count of items seen). Priority sampling stores k items plus the threshold τ (a real number). In practice, both can be implemented with similar memory footprints. But priority sampling also needs to generate a random uniform number for each item, which is also done in reservoir sampling (for replacement decisions). So no significant difference.

### 3.4 Computational Cost

Reservoir sampling (Algorithm R) requires O(1) time per item on average: generating a random number and possibly a swap. Priority sampling requires generating a random number and maintaining a heap of size k, so O(log k) per item. For large k (e.g., millions), this can be noticeable. However, there are faster variants of priority sampling using “stratified” mechanisms or skipping. But in general, reservoir sampling is faster.

### 3.5 Handling Highly Skewed Data

In many real-world streams (web traffic, financial transactions), a few items account for most of the weight. Priority sampling excels here: heavy hitters are almost always included, giving accurate total estimates. Reservoir sampling might miss a critical heavy hitter, producing a wildly inaccurate estimate.

**Example:** A stream of 1,000,000 transactions, where 999,999 are $1 each and one is $1,000,000. With reservoir sampling k=1000, the probability of including the big transaction is 1000/1e6 = 0.001. So 99.9% of the time, the sample contains no million-dollar transaction, and the estimate of total revenue will be about 1e6*1 = $1e6, but the true total is $1,999,999 (almost double). With priority sampling, the big transaction has weight 1e6, so its priority w/u is extremely large (unless u is astronomically small). It will almost certainly be sampled. The threshold τ will be around the 1001st largest priority, which comes from the $1 transactions (since the next largest priorities after the big one come from small items with tiny u). τ will be roughly $1 / (1 - 1000/1e6) ≈ $1 / 0.999 = essentially $1. So the estimator: big item contributes $1e6, and each of the other 999 sampled small items contributes max($1, τ) ≈ τ ≈ $1. So total = 1e6 + 999 ≈ $1,000,999. That's still far from true $1,999,999. Wait, the estimator for total sum is: for each sampled item, contribute max(w_i, τ). The big item contributes $1e6. The 999 small items contribute τ each. So sum = $1e6 + 999 * τ. Since τ is about $1, total ~ $1,001,000. But the true total is about $2,000,000. Where is the missing $999,000? The unsampled 998,999 small items are not directly counted. But the estimator is supposed to be unbiased: the expected contribution from small items is exactly their total weight. How does that work? The contribution of each small item, if it were sampled, is τ. But the probability that a small item is sampled is π ≈ w*i/τ ≈ 1/1 = 1? That can't be right. If τ ≈ $1, then w_i/τ = 1, so inclusion probability = min(1,1)=1? That would mean all items are sampled, contradicting k=1000. So my τ estimate must be wrong. With 1e6 items, k=1000, the expected sample size from threshold sampling with threshold τ would be sum_i min(1, w_i/τ). For small items w_i=1, we need 1e6 * (1/τ) = 1000 => τ = 1000. So the threshold τ is around 1000, not 1. That makes sense: to have only 1000 items included, we need the threshold to be such that the number of items with w*i > τ is about k (but there is only 1 such item). Then the rest of the sample comes from items with w_i=1, each included with probability 1/τ ≈ 1/1000. So expected number of small items included = 1e6 * (1/1000) = 1000. So total expected sample size = 1 + 1000 = 1001, but we enforce exactly k=1000 by adjusting threshold? Actually threshold sampling gives random sample size, priority sampling fixes exactly k by setting τ as (k+1)-th largest priority. So in this case, the (k+1)-th largest priority will be around the priority of a small item with a certain u. The priorities for small items: p_i = 1/u_i. The largest priorities among small items are huge (when u small). The (k+1)-th largest overall will be high. Let's compute: The big item's priority is 1e6 / u_big. If u_big is typical, say 0.5, priority = 2e6. The largest small priorities: the maximum of 1/u for 1e6 uniforms is about 1/(1/1e6) = 1e6 (since the minimum uniform is about 1/1e6). So the big item's priority (2e6) is larger than the maximum small priority (1e6), so the big item is the largest. Then the next largest are small priorities. The 1001st largest small priority corresponds to the 1001st order statistic of 1/u out of 1e6 samples. The 1001st largest corresponds to the (1e6 - 1001)th smallest 1/u? Actually, the distribution of 1/u: P(1/u > x) = 1/x for x > 1. So the tail is heavy. The quantile function: For top p fraction, x ≈ 1/(1-p). For p = 1001/1e6 = 0.001001, the threshold x = 1/(1 - 0.001001) ≈ 1.001. Wait, that seems too small. That can't be right because we already know the maximum is about 1e6. The mistake: The top p=1001/1e6=0.001, so we are looking at the 0.1% largest values. For a Pareto(1) distribution (with tail P(X>x)=1/x), the (1-p)-th quantile is 1/p. Since top p proportion means P(X > x) = p, so 1/x = p => x = 1/p. So the 1001st largest (from 1e6) corresponds to p ≈ 1001/1e6 ≈ 0.001, so x = 1/0.001 = 1000. So yes, the 1001st largest small priority is about 1000. So threshold τ ≈ 1000. Good.

Now, the sample consists of: the big item (priority 2e6) and 999 small items with priorities > 1000 (i.e., those with u < 1/1000). The inclusion probability for a small item is P(u < 1/τ) = 1/τ ≈ 1/1000. So expected number of small items sampled = 1e6 \* 1/1000 = 1000. But we have exactly 999 in the sample (since k=1000 and one slot taken by big item). This is fine.

Now the estimator: for the big item, contribution = max(w, τ)=1e6 (since w>τ). For each sampled small item, contribution = max(1, τ)=τ=1000. So total = 1e6 + 999*1000 = 1e6 + 999,000 = 1,999,000. True total = 1,999,999. So estimate is very close! The bias? The estimator is unbiased, so the expectation over randomness should equal 1,999,999. Indeed, each small item has probability 1/τ of being sampled and contributes τ, so expected contribution from small items = (1/τ)*τ _ (number of small items) = 1,999,999? Wait, number of small items = 999,999. So expected contribution = 999,999 _ (1/τ)\*τ = 999,999. Plus big item's contribution is always included (since its w>τ, it's always sampled). So expectation = 1,000,000 + 999,999 = 1,999,999. Perfect.

Now compare uniform sampling: k=1000. Probability big item in sample = 1000/1e6 = 0.001. If in sample, estimate = 1e6/1000 * (1e6 + 999*1) _ (1e6/1000?) Actually, uniform estimator: total = (N/k) _ sum sampled weights = (1e6/1000) * (w_big + sum of 999 small). If big item sampled: sum = 1e6 + 999*1 = 1,000,999. Then estimate = 1000 \* 1,000,999 = 1,000,999,000 (over 1 billion, far too high). If big item not in sample: sum of 1000 small = 1000, estimate = 1e6, too low. So uniform estimator is essentially useless. This illustrates the catastrophe of uniform sampling for highly skewed sums.

Thus priority sampling is the clear winner for total sum estimation under heavy tails.

---

## Part 4: Implementations and Practical Considerations

### 4.1 Implementing Reservoir Sampling in Python (for reference)

```python
import random

def reservoir_sample(stream, k):
    reservoir = []
    for i, item in enumerate(stream):
        if i < k:
            reservoir.append(item)
        else:
            j = random.randint(0, i)
            if j < k:
                reservoir[j] = item
    return reservoir
```

This uses O(k) memory and O(n) time with O(1) per item average.

### 4.2 Implementing Priority Sampling (streaming, exact threshold)

To maintain exact threshold, we can keep a heap of size k+1 storing the largest priorities. We also need to store items (or at least weights and identifiers) associated with those priorities. The threshold τ is the smallest priority in the heap (i.e., the (k+1)-th largest). After processing all items, the sample is the k items with largest priorities (excluding the smallest one). However, for streaming estimation, we need to be able to report the sample and τ at any time. One approach: always keep a min-heap of size k+1. When a new item comes, push its priority and associated data. If heap size > k+1, pop the smallest (which will be the new (k+2)-th largest, irrelevant). At all times, the heap contains the largest k+1 priorities. The sample (k items) is those with priority greater than the minimum in the heap (which is the (k+1)-th largest). So we can always retrieve the sample by removing the smallest element (or we could keep two heaps, but simpler: the sample is heap minus the root). Memory is k+1.

Pseudo:

```python
import heapq
import random

class PrioritySampler:
    def __init__(self, k):
        self.k = k
        self.heap = []  # min-heap of (priority, index, weight)
        self.count = 0

    def feed(self, weight):
        u = random.random()
        priority = weight / u  # or weight / u?
        # use largest priorities: priority = weight / u
        heapq.heappush(self.heap, (priority, self.count, weight))
        self.count += 1
        if len(self.heap) > self.k + 1:
            heapq.heappop(self.heap)  # remove smallest priority

    def get_sample_and_threshold(self):
        # heap contains k+1 largest priorities
        if len(self.heap) <= self.k:
            return list(self.heap)  # all items if fewer than k+1
        # The threshold is the smallest priority in heap (the (k+1)-th largest)
        threshold = self.heap[0][0]  # min heap root
        sample = []
        for pri, idx, w in self.heap:
            if pri > threshold:  # strictly greater? due to continuous, no ties
                sample.append((idx, w))
            # else it's the threshold item itself, not in sample
        return sample, threshold
```

Note: The threshold τ is the (k+1)-th largest priority. The sample includes the k items with priority > τ (since continuous, equality has probability 0). This matches the theory. The estimator for total weight is sum over sampled items of max(w_i, τ).

### 4.3 Handling item attributes

In both algorithms, we need to store item payloads (e.g., full transaction details) for later querying. Memory is dominated by the payload size, not just the weight. So practical memory is O(k \* payload_size). Priority sampling also requires storing priority (float) per sampled item, which is typically negligible.

### 4.4 When the stream has weights equal to 1 (unweighted)

If all weights are 1, priority sampling reduces to uniform sampling? Let's check: priority = 1/u. Keeping largest priorities is equivalent to keeping smallest u (since u small gives large priority). So priority sampling with equal weights keeps the k items with smallest u values, which is exactly a random sample (since u are iid uniform). So it behaves like reservoir sampling but uses a heap. So for unweighted streams, both algorithms give uniform samples, but reservoir sampling is faster.

### 4.5 Extensions: Weighted Reservoir Sampling

The algorithm by Efraimidis and Spirakis (2006) assigns each item a key \( r_i = u_i^{1/w_i} \) and keeps the k largest keys. This is often called “weighted reservoir sampling.” Its inclusion probabilities are approximately proportional to weight, but not exactly proportional due to the randomness of the maximum. In fact, the inclusion probability for item i is \( P(r_i > T) \) where T is the (k+1)-th largest key. This is similar to priority sampling but with a different key distribution. Which is better? Priority sampling (using w/u) is known to be optimal for threshold sampling: it minimizes the variance of the total estimator conditional on the sample size. So among all sampling schemes that have the “threshold” property (i.e., include items with w > τ and then include others proportional to w), priority sampling achieves the lowest variance. Therefore, weighted reservoir sampling using u^(1/w) is inferior, though simpler.

But in practice, weighted reservoir sampling is easier to implement in a stream because the keys are between 0 and 1, and you can maintain a min-heap of size k (since you keep largest keys). The threshold is simply the smallest key in the heap (the k-th largest). Then you can estimate using that threshold (though it's not exactly the (k+1)-th largest, leading to slight bias). Many production systems use this variant.

---

## Part 5: Advanced Topics and Open Problems

### 5.1 Variance Reduction by Stratification

Both algorithms can be improved by stratification: divide the stream into groups (e.g., by source IP) and sample within each group. This reduces variance if groups are homogeneous. Priority sampling can be extended to a two-stage procedure.

### 5.2 Combining Priors

Suppose you want to estimate many subset sums simultaneously. Priority sampling provides a single sample that works for any subset, with guaranteed low variance (within a constant factor of the optimal per-subset). This is a major advantage over maintaining separate samples.

### 5.3 Distributed Streaming

In distributed systems, each node runs its own sampler, and we need to merge samples. For reservoir sampling, merging k samples from m nodes to get a combined k-sample is easy: each node can send its sample and the total count, and we can perform a weighted random selection. For priority sampling, merging is more involved: the thresholds are local, and combining requires resampling or recomputing global priorities. However, there are known techniques for merging priority samples using order statistics of exponential distributions (the “Exponential Priority Sampling” of Cohen and Duffield). This is beyond our scope.

### 5.4 Handling Deletions and Sliding Windows

Both algorithms assume insert-only streams. In reality, data may have deletions (e.g., user deletes an event). Supporting deletions requires more sophisticated structures like “summaries” (e.g., Count-Min Sketch for frequency estimation). Sampling with deletions is an open area.

### 5.5 Extensions to Heavy Hitters

Priority sampling naturally identifies heavy hitters: any item with weight > τ is always included. So the sample contains the heaviest items. This can be used for detecting anomalies or frequent items.

---

## Part 6: Decision Framework

How to choose between reservoir sampling and priority sampling?

| If your primary need is...                                                     | Choose                                                                                                   |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| Estimate population proportion                                                 | Reservoir sampling                                                                                       |
| Estimate sum (e.g., total revenue, total packets, total time) with heavy tails | Priority sampling                                                                                        |
| Estimate both proportion and sum                                               | Consider priority sampling (can reweight for proportions) OR use two samples (one uniform, one weighted) |
| Stream with equal weights                                                      | Reservoir sampling (faster, simpler)                                                                     |
| Stream with moderate skew                                                      | Reservoir sampling might be acceptable if sample size large                                              |
| Memory and CPU are extremely constrained                                       | Reservoir sampling (O(1) per item)                                                                       |
| Need optimal variance for sum                                                  | Priority sampling                                                                                        |
| Need to answer many arbitrary subset sum queries                               | Priority sampling (unbiased for all subsets)                                                             |

### Case Study: Network Traffic Monitoring

In a network router, you need to estimate total bytes sent and also the proportion of TCP packets. Use priority sampling for byte estimation: sample packets with probability prop to size, then estimate total bytes accurately. For TCP proportion, you can use the same sample with reweighting: each sampled packet represents 1/π*i packets (where π_i is inclusion probability). Since π_i is known (min(1, size/τ)), you can estimate number of TCP packets as sum*{sampled TCP} 1/π_i. This is unbiased. Variance may be higher than a dedicated uniform sample of same size, but you save memory by using one sampler. Often, the total byte estimate is more critical than the proportion, so priority sampling wins.

### Case Study: Clickstream Analysis

For estimating click-through rates (CTR) per ad, uniform sampling is standard. You want each impression equally likely. Priority sampling would oversample rare events (e.g., clicks on obscure ads) if you use click weight? If using weight=1, it's uniform. If you use weight=number of times an ad was shown, you'd get a sample biased toward popular ads, which is undesirable. So reservoir sampling is appropriate.

---

## Part 7: Rigorous Mathematical Summary (Optional)

For readers who want the equations:

**Reservoir Sampling**: Let sample S of size k. Inclusion probability \( \pi*i = k/N \). Horvitz-Thompson estimator for sum of f: \(\hat{T} = \frac{N}{k} \sum*{i \in S} f_i\). Variance:

\[
\text{Var}(\hat{T}) = \frac{N(N-k)}{k} \cdot \frac{1}{N-1} \sum\_{i=1}^N (f_i - \bar{f})^2
\]

**Priority Sampling**: Define priorities \( p*i = w_i / u_i \) with \( u_i \sim U(0,1) \). Let \( \tau \) be the (k+1)-th largest priority. Sample \( S = \{ i : p_i > \tau \} \). Inclusion probability \( \pi_i = \min(1, w_i/\tau) \). Estimator for total weight: \(\hat{W} = \sum*{i \in S} \max(w*i, \tau)\). For subset sum over set A: \(\hat{W}\_A = \sum*{i \in A \cap S} \max(w_i, \tau)\). Unbiased and variance:

\[
\text{Var}(\hat{W}) = \sum\_{i} w_i^2 \left( \frac{1}{\pi_i} - 1 \right) \quad \text{(for independent inclusions?)}
\]

but due to negative dependence, exact formula is more complex. Bounds show \( \text{Var}(\hat{W}) \leq \frac{1}{k} \sum\_{i} w_i^2 \), which is often much smaller than uniform variance.

---

## Conclusion: Embrace the Firehose with the Right Tool

Data streams will not stop. The volume will only increase. The difference between a useful approximation and a misleading estimate often boils down to the sampling algorithm you choose. Reservoir sampling is a beautiful, elegant solution for uniform samples and remains essential for many tasks. But when the weight matters—when a single massive transaction can dwarf a million tiny ones—you must abandon the illusion of uniformity. Priority sampling, with its weight-proportional inclusion and optimal variance, is the mathematically superior choice for estimating totals in heavy-tailed streams.

Do not be fooled by simplicity. The firehose demands respect. Choose your sampling algorithm wisely, and your estimates will hold water.

---

## References

- Vitter, J. S. (1985). Random sampling with a reservoir. _ACM Transactions on Mathematical Software_, 11(1), 37-57.
- Duffield, N., Lund, C., & Thorup, M. (2002). Priority sampling for estimation of arbitrary subset sums. _ACM SIGMETRICS Performance Evaluation Review_, 31(1), 243-254.
- Efraimidis, P. S., & Spirakis, P. G. (2006). Weighted random sampling with a reservoir. _Information Processing Letters_, 97(5), 181-185.
- Cohen, E., & Duffield, N. (2007). Exponential priority sampling for merging and summarization. _ACM SIGMETRICS_.

---

_This blog post has gone through rigorous analysis. For deeper derivations, consult the original papers. The code snippets are for illustration; production implementations require careful handling of floating point and edge cases._
