---
title: "Shannon's Information Theory from First Principles: Entropy, Channel Capacity, and the Fundamental Limits of Communication"
description: "Build Shannon's information theory from the ground up: entropy as a measure of uncertainty, source coding theorem, channel capacity, and the noisy-channel coding theorem that established the theoretical limits of reliable communication."
date: "2025-03-05"
author: "Leonardo Benicio"
tags: ["information-theory", "shannon", "entropy", "compression", "coding-theory", "mathematics"]
categories: ["theory", "mathematics"]
draft: false
cover: "static/images/blog/shannon-information-theory-entropy-channel-capacity.png"
coverAlt: "A visual journey through Shannon's 1948 paper: entropy curves, a binary symmetric channel diagram, a noisy-channel coding theorem illustration with spheres in Hamming space, and a Shannon-Hartley capacity plot"
---

In 1948, Claude Shannon — a 32-year-old researcher at Bell Labs with a masters in electrical engineering and a PhD in mathematics — published a paper that some have called the Magna Carta of the Information Age. "A Mathematical Theory of Communication" ran 55 pages in the Bell System Technical Journal and, in a single stroke, created the field of information theory. Before Shannon, "information" was a loose, colloquial term. After Shannon, it was a measurable quantity with precise units (bits), fundamental limits (channel capacity), and deep connections to thermodynamics, cryptography, and machine learning.

Shannon's paper did three extraordinary things. First, it defined entropy as a measure of uncertainty and showed that it is the unique, natural measure of information content. Second, it proved the **source coding theorem**: you can compress data down to its entropy rate, and no further — this is the theoretical foundation of every compression algorithm from Huffman codes to LZMA to Brotli. Third, it proved the **noisy-channel coding theorem**: even if your communication channel introduces errors, you can transmit data arbitrarily reliably at any rate up to the channel capacity, using sufficiently clever coding. This result, which Shannon proved using random codes and a counting argument (not an explicit construction), stunned the engineering world and launched a six-decade search for practical capacity-approaching codes — a search that culminated in turbo codes (1993), LDPC codes (rediscovered 1996), and polar codes (2009).

This post builds Shannon's information theory from first principles, with the rigor and depth it deserves. We derive entropy axiomatically, explore the source coding theorem and its algorithmic consequences, define channel capacity, and walk through the noisy-channel coding theorem — its statement, its proof strategy, and its profound implications. Along the way, we connect Shannon's ideas to modern coding theory, 5G NR, and the fundamental limits that govern all communication.

## 1. Entropy: The Measure of Uncertainty

The foundation of information theory is the concept of entropy. Shannon's first task was to quantify "how much information" is produced by a source that emits symbols according to a probability distribution. The answer must satisfy certain intuitive requirements, and from those requirements, the formula emerges uniquely.

### 1.1 Axiomatic Derivation of Entropy

Consider a discrete random variable \(X\) taking values from an alphabet \(\mathcal{X} = \{x_1, x_2, \ldots, x_n\}\) with probabilities \(p_i = P(X = x_i)\). We seek a function \(H(p_1, p_2, \ldots, p_n)\) that measures the "uncertainty" or "information content" of \(X\). Shannon proposed three axioms that any such measure should satisfy:

1. **Continuity:** \(H(p_1, \ldots, p_n)\) should be a continuous function of the \(p_i\). A small change in probabilities should produce a small change in uncertainty.

2. **Monotonicity (equal probabilities):** For a uniform distribution (\(p_i = 1/n\)), \(H(1/n, \ldots, 1/n)\) should be a monotonically increasing function of \(n\). The more equally likely outcomes there are, the more uncertain we are about which one will occur.

3. **Additivity (grouping axiom):** If we decompose a choice into successive choices, the total uncertainty should be the weighted sum of the individual uncertainties. Formally:
   \[
   H(p_1, \ldots, p_n) = H(p_1 + p_2, p_3, \ldots, p_n) + (p_1 + p_2) \cdot H\left(\frac{p_1}{p_1 + p_2}, \frac{p_2}{p_1 + p_2}\right)
   \]
   This says: first decide whether the outcome is in \(\{x_1, x_2\}\) or not, and if it is, then decide between \(x_1\) and \(x_2\). The total uncertainty is the sum.

From these three axioms, Shannon proved that the only possible form (up to a constant factor) is:

\[
H(X) = -K \sum\_{i=1}^{n} p_i \log p_i
\]

where \(K\) is a positive constant that determines the unit. Shannon set \(K = 1\) and chose base-2 logarithms, defining the unit as the **bit** (binary digit). Thus:

\[
H(X) = -\sum\_{i=1}^{n} p_i \log_2 p_i \quad \text{(bits)}
\]

When \(p*i = 0\), we define \(0 \log 0 = 0\) (by continuity: \(\lim*{p \to 0^+} p \log p = 0\)).

### 1.2 Properties of Entropy

Entropy has several elegant properties that make it the "right" measure:

- **Non-negativity:** \(H(X) \geq 0\), with equality if and only if \(X\) is deterministic (one outcome has probability 1).
- **Maximum entropy:** For fixed alphabet size \(n\), \(H(X)\) is maximized when all outcomes are equally likely: \(H(X) \leq \log_2 n\).
- **Invariance under relabeling:** \(H(X)\) depends only on the probability values, not on the labels of the outcomes.
- **Concavity:** \(H(X)\) is a concave function of the probability vector. This has important consequences: mixing distributions increases entropy.

The concavity property is worth savoring. If you have two distributions \(p\) and \(q\) over the same alphabet, and you flip a coin to decide which distribution to use, the resulting mixture distribution has entropy at least the weighted average of the individual entropies. Uncertainty is convex: blending increases unpredictability.

### 1.3 Example: Binary Entropy

The most important special case is the binary entropy function, where \(X \in \{0, 1\}\) with \(P(X=1) = p\) and \(P(X=0) = 1-p\):

\[
H_b(p) = -p \log_2 p - (1-p) \log_2 (1-p)
\]

This function appears everywhere in information theory. It is symmetric about \(p = 1/2\), where it achieves its maximum of 1 bit. At \(p = 0\) or \(p = 1\), \(H_b(0) = H_b(1) = 0\) — a deterministic coin has zero entropy. The binary entropy function quantifies the information content of a biased coin: a coin that comes up heads with probability 0.9 has \(H_b(0.9) \approx 0.469\) bits of entropy, meaning you can (in expectation) compress a sequence of such coin flips to 0.469 bits per flip.

## 2. Joint and Conditional Entropy

Entropy extends naturally to multiple random variables, giving rise to a rich algebraic structure that mirrors (and in some ways inspired) the probability calculus.

### 2.1 Joint Entropy

For two random variables \(X\) and \(Y\) with joint distribution \(p(x, y)\), the **joint entropy** is:

\[
H(X, Y) = -\sum*{x \in \mathcal{X}} \sum*{y \in \mathcal{Y}} p(x, y) \log_2 p(x, y)
\]

This measures the total uncertainty about the pair \((X, Y)\). If \(X\) and \(Y\) are independent, then \(H(X, Y) = H(X) + H(Y)\). In general, \(H(X, Y) \leq H(X) + H(Y)\), with equality only under independence. This subadditivity property reflects the intuitive idea that "the whole has less uncertainty than the sum of its parts" when the parts are correlated — knowing \(X\) reduces uncertainty about \(Y\) (and vice versa), so measuring them together requires fewer bits than measuring them separately.

### 2.2 Conditional Entropy

The **conditional entropy** \(H(Y | X)\) measures the remaining uncertainty about \(Y\) after \(X\) is known:

\[
H(Y | X) = \sum\_{x \in \mathcal{X}} p(x) \cdot H(Y | X = x)
\]

where \(H(Y | X = x) = -\sum\_{y} p(y | x) \log_2 p(y | x)\). This is the expected entropy of the conditional distribution, averaged over the possible values of \(X\).

The key identity connecting all three is the **chain rule**:

\[
H(X, Y) = H(X) + H(Y | X) = H(Y) + H(X | Y)
\]

The uncertainty of the pair equals the uncertainty about \(X\) plus the remaining uncertainty about \(Y\) given \(X\). The chain rule extends to any number of variables:

\[
H(X*1, X_2, \ldots, X_n) = \sum*{i=1}^{n} H(X*i | X_1, \ldots, X*{i-1})
\]

This decomposition is fundamental to understanding sequential processes, Markov chains, and the entropy rate of stochastic sources.

### 2.3 The Chain Rule for Entropy and the Data Processing Inequality

A direct consequence of the chain rule is the **data processing inequality**: if \(X \rightarrow Y \rightarrow Z\) forms a Markov chain (Z depends on X only through Y), then:

\[
H(X | Y) \leq H(X | Z) \quad \text{and} \quad I(X; Y) \geq I(X; Z)
\]

Processing data cannot increase the information it contains about its source. This has profound implications: feature engineering in machine learning, signal processing pipelines, and data compression all obey this fundamental limit. No clever transformation can create information that was not already present in the input.

## 3. Mutual Information and the Geometry of Communication

If entropy measures uncertainty, **mutual information** measures how much knowing one variable reduces uncertainty about another.

### 3.1 Definition and Properties

The mutual information between \(X\) and \(Y\) is:

\[
I(X; Y) = H(X) - H(X | Y) = H(Y) - H(Y | X)
\]

Equivalently, it is the Kullback-Leibler divergence between the joint distribution and the product of marginals:

\[
I(X; Y) = D*{KL}\big(p(x, y) \;\|\; p(x) p(y)\big) = \sum*{x,y} p(x,y) \log_2 \frac{p(x, y)}{p(x) p(y)}
\]

This formulation reveals mutual information as a measure of "how far" the joint distribution is from independence. When \(X\) and \(Y\) are independent, \(p(x,y) = p(x) p(y)\) and \(I(X; Y) = 0\). When they are perfectly correlated (e.g., \(Y = f(X)\) for a deterministic function \(f\)), \(I(X; Y) = H(X) = H(Y)\).

Key properties:

- **Symmetry:** \(I(X; Y) = I(Y; X)\). Information is mutual — the amount \(X\) tells you about \(Y\) equals the amount \(Y\) tells you about \(X\).
- **Non-negativity:** \(I(X; Y) \geq 0\), with equality iff \(X\) and \(Y\) are independent. This follows from the non-negativity of KL divergence.
- **Bounds:** \(I(X; Y) \leq \min(H(X), H(Y))\). You cannot learn more about \(X\) from \(Y\) than the total uncertainty in \(X\).

### 3.2 The Venn Diagram Metaphor (and Its Limitations)

A popular visualization draws entropy as circles in a Venn diagram: \(H(X)\) and \(H(Y)\) as circles, their overlap as \(I(X; Y)\), the left crescent as \(H(X | Y)\), the right as \(H(Y | X)\), and the union as \(H(X, Y)\). This metaphor is useful for remembering the relationships:

```text
    ┌─────────────────────────────────┐
    │        H(X, Y)                  │
    │  ┌─────────┐    ┌─────────┐     │
    │  │H(X│Y)  ░░│    │ H(Y│X) │     │
    │  │        ░░│    │        │     │
    │  │    ░░░░░░│    │        │     │
    │  │    ░ I ░░│    │        │     │
    │  │    ░░░░░░│    │        │     │
    │  └─────────┘    └─────────┘     │
    └─────────────────────────────────┘
```

But the metaphor is imperfect: the area representing \(I(X; Y)\) can exceed \(H(X)\) (in which case your "circles" would overlap completely), and \(I(X; X) = H(X)\), which would require a circle to perfectly overlap itself — fine, but the diagram suggests nothing about this degenerate case. Use the diagram for intuition, but rely on the algebra for precision.

## 4. The Source Coding Theorem: Compression to the Limit

Shannon's first great theorem addresses the problem of data compression. Given a source that emits symbols according to a known distribution, how much can we compress its output?

### 4.1 The Entropy Rate of a Source

Consider a source that emits a sequence of symbols \(X_1, X_2, X_3, \ldots\) from a finite alphabet. The **entropy rate** of the source is:

\[
\bar{H} = \lim\_{n \to \infty} \frac{1}{n} H(X_1, X_2, \ldots, X_n)
\]

if the limit exists. For a **stationary** source (statistical properties are time-invariant), the limit always exists. For an i.i.d. source (each symbol drawn independently from the same distribution \(p\)), the entropy rate is simply \(H(X_1)\), the entropy of a single symbol.

For sources with memory — say, English text, where the probability of "u" depends strongly on whether the previous letter was "q" — the entropy rate is lower than the single-symbol entropy. Shannon famously estimated the entropy rate of English at roughly 1.0-1.5 bits per character (compared to \(\log_2 27 \approx 4.75\) bits for a uniform distribution over 26 letters plus space), based on ingenious human-subject experiments where people guessed successive letters.

### 4.2 Statement of the Source Coding Theorem

**Theorem (Shannon, 1948):** Let a source have entropy rate \(\bar{H}\). Then:

- **Achievability:** For any rate \(R > \bar{H}\), there exists a sequence of codes that compress \(n\) source symbols into \(nR\) bits (on average) with arbitrarily small probability of error as \(n \to \infty\).
- **Converse:** For any rate \(R < \bar{H}\), any code will have a probability of error bounded away from zero, and in fact the probability of error approaches 1 as \(n \to \infty\).

In other words, \(\bar{H}\) is the **minimum achievable compression rate**. You cannot, on average, represent a source using fewer than \(\bar{H}\) bits per symbol. This is a hard, mathematical limit — no amount of algorithmic cleverness can circumvent it.

### 4.3 The Kraft Inequality and Prefix Codes

The source coding theorem is an asymptotic existence result. Practical compression requires constructing actual codes. A **prefix code** (also called instantaneous code) is a set of codewords where no codeword is a prefix of another — enabling immediate decoding without lookahead. The Kraft inequality gives the necessary and sufficient condition for the existence of a prefix code:

\[
\sum\_{i=1}^{n} 2^{-\ell_i} \leq 1
\]

where \(\ell_i\) is the length (in bits) of the codeword for symbol \(i\). This inequality constrains the set of possible codeword lengths. If you want to assign short codewords, you must assign some longer ones — the "budget" of \(2^{-\ell}\) sums to at most 1.

The **optimal** prefix code for a given distribution minimizes the expected codeword length \(L = \sum_i p_i \ell_i\). Shannon showed that:

\[
H(X) \leq L\_{\text{optimal}} < H(X) + 1
\]

The Huffman algorithm (1952) constructs a prefix code achieving the optimal expected length exactly. Arithmetic coding (Rissanen, 1976) achieves expected lengths even closer to \(H(X)\) by coding entire sequences rather than individual symbols, asymptotically reaching the entropy bound.

### 4.4 Typical Sequences and the Asymptotic Equipartition Property (AEP)

The proof of the source coding theorem rests on the **Asymptotic Equipartition Property (AEP)**. For an i.i.d. source with entropy \(H\), the AEP states that for large \(n\), the set of possible sequences of length \(n\) can be divided into two classes:

- **Typical sequences:** About \(2^{nH}\) sequences, each with probability approximately \(2^{-nH}\). Collectively, they account for nearly all the probability mass (\(> 1 - \varepsilon\) for any \(\varepsilon > 0\) as \(n \to \infty\)).
- **Atypical sequences:** The remaining \(|\mathcal{X}|^n - 2^{nH}\) sequences, individually improbable and collectively negligible.

The AEP is the information-theoretic analogue of the law of large numbers. It says that when you observe a long sequence from a known distribution, you will almost certainly observe a "typical" sequence, and there are roughly \(2^{nH}\) such sequences. Therefore, you can assign a unique binary codeword of length \(nH\) to each typical sequence and a single "error" codeword to all atypical sequences — achieving compression to \(nH\) bits with vanishing error probability.

## 5. Channel Capacity and the Noisy-Channel Coding Theorem

The source coding theorem tells us how to compress information. The noisy-channel coding theorem tells us how to transmit it reliably over an imperfect medium. This is Shannon's most celebrated result.

### 5.1 Discrete Memoryless Channels

A **discrete memoryless channel (DMC)** is defined by:

- An input alphabet \(\mathcal{X} = \{x_1, \ldots, x_m\}\)
- An output alphabet \(\mathcal{Y} = \{y_1, \ldots, y_k\}\)
- A transition probability matrix \(p(y | x)\): the probability that output \(y\) is received given that input \(x\) was transmitted.

"Memoryless" means that each channel use is independent: the output at time \(i\) depends only on the input at time \(i\), not on past inputs or outputs. Formally:
\[
p(y*1, \ldots, y_n | x_1, \ldots, x_n) = \prod*{i=1}^{n} p(y_i | x_i)
\]

The most fundamental DMC is the **binary symmetric channel (BSC)** with crossover probability \(p\):

```text
                1-p
          0 ──────────► 0
           ╲           ↗
           p╲         ╱p
             ╲       ╱
              ▼     ▼
          1 ──────────► 1
                1-p
```

Each bit is flipped independently with probability \(p\). If \(p = 0\), the channel is perfect. If \(p = 1/2\), the output is completely independent of the input — the channel conveys zero information.

### 5.2 Definition of Channel Capacity

The **capacity** of a DMC is the maximum mutual information between the input and output, optimized over all possible input distributions:

\[
C = \max\_{p(x)} I(X; Y)
\]

where \(I(X; Y)\) is computed using the channel's transition probabilities \(p(y|x)\) and the chosen input distribution \(p(x)\).

For the BSC with crossover probability \(p\), the capacity-achieving input distribution is uniform (\(P(X=0) = P(X=1) = 1/2\)), and the capacity is:

\[
C\_{\text{BSC}} = 1 - H_b(p) \quad \text{(bits per channel use)}
\]

When \(p = 0\), \(H_b(0) = 0\) and \(C = 1\) — each channel use conveys one bit. When \(p = 1/2\), \(H_b(1/2) = 1\) and \(C = 0\) — the channel is useless. For a bit-flip probability of 0.01, \(C \approx 1 - 0.0808 = 0.9192\) bits per channel use — about 92% of the raw bit rate.

### 5.3 The Noisy-Channel Coding Theorem

**Theorem (Shannon, 1948):** For a DMC with capacity \(C\):

- **Achievability:** For any rate \(R < C\) and any \(\varepsilon > 0\), there exists a code of length \(n\) and rate at least \(R\) such that the maximum probability of error (over all codewords) is less than \(\varepsilon\), for sufficiently large \(n\).
- **Converse:** For any rate \(R > C\), the probability of error is bounded away from zero for any code, and approaches 1 as \(n \to \infty\).

This is a staggering result. It says there is a sharp threshold — the channel capacity — below which arbitrarily reliable communication is possible, and above which it is impossible. The threshold is a function of the channel alone, not of the coding scheme. And the proof of achievability requires no clever code construction — Shannon used **random coding**: choose \(2^{nR}\) codewords at random according to the capacity-achieving distribution, and decode using typical-set decoding. The expected error probability vanishes as \(n \to \infty\), so there must exist at least one good code.

The random coding argument is worth understanding because of its sheer audacity. To transmit \(nR\) bits over \(n\) channel uses, we randomly generate \(2^{nR}\) codewords of length \(n\), each symbol drawn i.i.d. from the capacity-achieving input distribution \(p^_(x)\). The codebook — all \(2^{nR}\) codewords — is shared between sender and receiver. When the sender wants to transmit message \(w \in \{1, \ldots, 2^{nR}\}\), it transmits the \(w\)-th codeword. The receiver, upon observing the channel output \(Y^n\), looks for a codeword that is jointly typical with \(Y^n\) according to the joint distribution \(p^_(x) p(y|x)\). If exactly one such codeword exists, the receiver decodes to the corresponding message. Otherwise, it declares an error.

The probability analysis uses two key facts: (1) the transmitted codeword, being generated from the same distribution, is jointly typical with the output with high probability (by the Joint AEP); (2) any other (incorrect) codeword is independently generated, and the probability that it happens to be jointly typical with the output is roughly \(2^{-n I(X;Y)}\). With \(2^{nR}\) such impostors, the expected number of false matches is \(2^{nR} \cdot 2^{-n I(X;Y)} = 2^{-n(C - R)}\), which vanishes provided \(R < C\). The argument is a cousin of the union bound, amplified by the exponential decay of atypicality probabilities. It is almost absurdly simple — and yet it proved that capacity-approaching codes exist, launching a search that would span the rest of the century.

### 5.4 The Shannon-Hartley Theorem and the AWGN Channel

For continuous-time, continuous-amplitude channels — the domain of radio, fiber optics, and satellite communication — the most important model is the **Additive White Gaussian Noise (AWGN)** channel. The received signal is:

\[
Y = X + Z
\]

where \(X\) is the transmitted signal (with average power constraint \(P\)) and \(Z \sim \mathcal{N}(0, \sigma^2)\) is independent Gaussian noise. The capacity of this channel is:

\[
C = \frac{1}{2} \log_2\left(1 + \frac{P}{\sigma^2}\right) \quad \text{(bits per channel use)}
\]

When we consider a bandlimited channel of bandwidth \(B\) Hz, sampled at the Nyquist rate (\(2B\) samples per second), we obtain the **Shannon-Hartley theorem**:

\[
C = B \log_2\left(1 + \frac{S}{N}\right) \quad \text{(bits per second)}
\]

where \(S/N\) is the signal-to-noise ratio (SNR). This formula governs every communication system ever built. It tells us that:

- **Increasing bandwidth increases capacity linearly.** Doubling \(B\) doubles \(C\) (all else equal).
- **Increasing power increases capacity logarithmically.** Doubling \(S\) increases \(C\) by only about \(B\) bits per second (when \(S/N \gg 1\)).
- **At low SNR** (\(S/N \ll 1\)), \(\log_2(1 + S/N) \approx (S/N) / \ln 2\), so capacity is approximately proportional to SNR — the power-limited regime.
- **At high SNR** (\(S/N \gg 1\)), capacity grows logarithmically with SNR — the bandwidth-limited regime.

These regimes dictate the design of all modern communication systems: 5G NR operates in the power-limited regime at the cell edge (low SNR) and the bandwidth-limited regime near the tower (high SNR), adapting modulation and coding schemes (MCS) dynamically.

## 6. Rate-Distortion Theory: Lossy Compression

The source coding theorem addresses **lossless** compression: the reconstructed data must exactly match the original. For many applications — images, audio, video — exact reconstruction is unnecessary and wasteful. Rate-distortion theory quantifies the trade-off between compression rate and reconstruction fidelity.

### 6.1 Distortion Measures and the Rate-Distortion Function

Define a **distortion measure** \(d(x, \hat{x}) \geq 0\) that quantifies the cost of representing source symbol \(x\) by reconstruction symbol \(\hat{x}\). Common choices:

- **Hamming distortion:** \(d(x, \hat{x}) = \mathbf{1}\{x \neq \hat{x}\}\) (for discrete sources).
- **Squared error:** \(d(x, \hat{x}) = (x - \hat{x})^2\) (for continuous sources).

The **rate-distortion function** \(R(D)\) is the minimum rate (bits per source symbol) required to achieve average distortion at most \(D\):

\[
R(D) = \min\_{p(\hat{x} | x) : \mathbb{E}[d(X, \hat{X})] \leq D} I(X; \hat{X})
\]

For a Gaussian source with variance \(\sigma^2\) and squared-error distortion:

\[
R(D) = \begin{cases}
\frac{1}{2} \log_2\left(\frac{\sigma^2}{D}\right) & 0 \leq D \leq \sigma^2 \\
0 & D > \sigma^2
\end{cases}
\]

This function captures the essence of lossy compression: to halve the distortion (double the fidelity), you must increase the rate by \(\frac{1}{2}\) bit per symbol. JPEG, MP3, H.264, and every other lossy compression scheme are practical approximations to their respective rate-distortion bounds.

### 6.2 The Rate-Distortion Theorem

Shannon proved the natural analogue of the source coding theorem for lossy compression:

**Theorem:** For any source with rate-distortion function \(R(D)\), and any \(\varepsilon > 0\):

- There exist codes with rate \(R < R(D) + \varepsilon\) and average distortion \(\leq D + \varepsilon\).
- No code with rate \(R < R(D)\) can achieve average distortion \(\leq D\).

Together with the channel coding theorem, this yields the **separation theorem**: optimal communication can be achieved by separately designing the source code (compression) and the channel code (error correction), with no loss of optimality. The source code compresses to the entropy rate; the channel code protects against errors up to capacity. The modularity of this architecture — compress-then-encode — underlies every digital communication system, from WiFi to deep-space telemetry.

## 7. Modern Coding Theory: Polar Codes, LDPC, and 5G

Shannon's 1948 proof of the channel coding theorem was non-constructive: it showed that good codes exist, but not how to build them. The subsequent seven decades have been a quest to find codes that approach capacity with practical encoding and decoding algorithms.

### 7.1 LDPC Codes: Gallager's Forgotten Insight

Robert Gallager, in his 1960 PhD thesis (supervised by Shannon!), invented **Low-Density Parity-Check (LDPC) codes**. An LDPC code is defined by a sparse parity-check matrix — each parity check involves only a few bits, and each bit participates in only a few checks. Gallager showed that LDPC codes with iterative decoding (message passing on the factor graph) could achieve rates close to capacity.

But LDPC codes were computationally infeasible in 1960. They were forgotten for 35 years, until David MacKay and Radford Neal independently rediscovered them in the mid-1990s, demonstrating near-capacity performance with practical decoders. LDPC codes are now standard in WiFi (802.11n/ac/ax), DVB-S2 (satellite TV), and 10 Gigabit Ethernet.

The key to LDPC decoding is the **belief propagation (BP) algorithm**, also called the sum-product algorithm. Messages (log-likelihood ratios) are passed between variable nodes and check nodes in the factor graph, iteratively refining the posterior probability of each bit. Under appropriate conditions (large block length, sparse graph without short cycles), BP converges to near-optimal decoding. The algorithm is parallelizable, making it amenable to hardware implementation in ASICs and FPGAs.

### 7.2 Polar Codes: Achieving Capacity Constructively

In 2009, Erdal Arıkan published a paper that was the culmination of the search that Shannon began. **Polar codes** are the first family of codes with an explicit construction that provably achieves the capacity of any binary-input symmetric DMC, with encoding and decoding complexity \(O(n \log n)\) for block length \(n = 2^k\).

The idea of polar coding is channel polarization: by recursively combining pairs of independent copies of a given channel, the resulting "synthesized" channels polarize into two extremes:

- Some subchannels become almost perfect (capacity near 1).
- Some become almost useless (capacity near 0).

As the number of recursions grows (large \(n\)), the fraction of near-perfect subchannels approaches the original channel capacity \(C\). The code transmits information bits on the near-perfect subchannels and frozen bits (known to both sender and receiver) on the useless ones. Decoding uses successive cancellation: each bit is decoded sequentially, using previously decoded bits as frozen context.

Polar codes were adopted for the 5G NR control channel (the physical downlink control channel, PDCCH) in 3GPP Release 15, barely nine years after Arıkan's paper — an astonishingly rapid transition from theory to global standard. The 5G data channel uses LDPC codes, but polar codes won the control channel competition because of their excellent short-block performance and provable guarantees.

### 7.3 Turbo Codes and the Iterative Revolution

Before LDPC and polar codes, there were **turbo codes**, introduced by Berrou, Glavieux, and Thitimajshima in 1993. Turbo codes concatenate two convolutional codes in parallel, separated by an interleaver, and decode using iterative soft-in soft-out (SISO) decoders that exchange extrinsic information. At the time, their near-capacity performance (within 0.5 dB of the Shannon limit on the AWGN channel) was so surprising that many in the coding theory community initially refused to believe the results.

Turbo codes were adopted by 3G and 4G LTE standards and remain in use for some 5G channels. The iterative decoding principle they pioneered — exchange soft information between component decoders — is now understood as an instance of belief propagation on a factor graph with cycles, connecting turbo codes conceptually to LDPC codes and to Bayesian networks in machine learning.

## 8. Shannon's Legacy: Why 1948 Still Matters

Shannon's 1948 paper is arguably the most influential scientific work of the 20th century that most people have never read. Its impact extends far beyond communications engineering:

- **Cryptography:** Shannon's 1949 paper "Communication Theory of Secrecy Systems" applied information theory to cryptography, defining perfect secrecy (one-time pad) and introducing the concept of equivocation. Modern cryptography, while built on computational rather than information-theoretic assumptions, inherits Shannon's framework for reasoning about secrecy.
- **Machine learning:** Mutual information is the foundation of information-theoretic feature selection, the information bottleneck method (Tishby et al., 1999), and representation learning. The cross-entropy loss function used to train neural networks is a direct descendant of Shannon's entropy.
- **Statistical mechanics:** The entropy formula \(S = -k \sum p_i \ln p_i\) predates Shannon (Gibbs, 1902), but Shannon's interpretation of entropy as information provided the bridge to Landauer's principle and the resolution of Maxwell's demon paradox.
- **Complexity theory:** Kolmogorov complexity (the length of the shortest program that produces a given string) can be seen as "absolute information content" — the entropy of a string relative to a universal Turing machine. Algorithmic information theory, developed by Kolmogorov, Solomonoff, and Chaitin, extends Shannon's ideas to individual objects rather than ensembles.

The conceptual architecture that Shannon built — source → encoder → channel → decoder → destination — is so universal that we use it without thinking. Every time you stream a video, make a phone call, or load a webpage, you are traversing a Shannon diagram, compressing your data to the entropy rate, encoding it against channel noise, and trusting that the mathematics of 1948 holds. Shannon's paper is not merely a scientific milestone; it is the intellectual foundation on which the entire edifice of digital communication, storage, and computation rests, and its conclusions remain as relevant for quantum communication and deep learning as they were for telegraphy and radio.

## 9. Summary

Shannon's information theory is one of those rare intellectual achievements that is simultaneously beautiful, practical, and profound. From three simple axioms, the entropy function emerges uniquely, and from it flows a cascade of theorems — source coding, channel coding, rate-distortion — that establish the fundamental limits of all communication.

The source coding theorem says: you can compress to the entropy rate, and no further. The noisy-channel coding theorem says: you can transmit reliably up to capacity, and no further. The separation theorem says: you can design source and channel codes independently and still achieve optimality. These results are not merely theoretical bounds; they are the design targets toward which every compression algorithm and error-correcting code aspires.

What makes Shannon's work so enduring is not just its mathematical elegance but its engineering pragmatism. The proofs are existence proofs — they show that good codes exist, leaving open the problem of finding them. This separation of what is possible from how to achieve it defines the relationship between theory and practice in information technology. The theorists establish the limits; the engineers race to approach them. And 77 years after Shannon's paper, the race continues — with polar codes, LDPC codes, and whatever the next breakthrough brings — toward the horizon that Shannon first mapped.

If you take away one thing from this post, let it be this: **entropy is not just a measure of disorder. It is the fundamental currency of information, and its conservation, transformation, and ultimate dissipation govern everything from the compression of a JPEG to the capacity of a fiber-optic cable to the arrow of time itself.** Shannon gave us the mathematics to count this currency. The rest of us are still learning how to spend it wisely.
