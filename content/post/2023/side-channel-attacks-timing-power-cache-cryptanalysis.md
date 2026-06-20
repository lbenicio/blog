---
title: "Side-Channel Attacks: Timing, Power Analysis, Cache-Timing, and the Constant-Time Discipline"
description: "A rigorous exploration of side-channel cryptanalysis from Kocher's 1996 timing attack through differential power analysis to cache-timing attacks like Prime+Probe and Flush+Reload, with the countermeasure of constant-time programming."
date: "2023-04-04"
author: "Leonardo Benicio"
tags: ["side-channel-attacks", "timing-attacks", "power-analysis", "cache-timing", "constant-time", "cryptanalysis"]
categories: ["theory", "systems"]
draft: false
cover: "/static/images/blog/side-channel-attacks-timing-power-cache-cryptanalysis.png"
coverAlt: "Diagram showing attacker observing multiple side channels—timing, power trace, and cache access pattern—leaking information from a cryptographic computation."
---

A cryptographic algorithm, viewed as a mathematical abstraction, operates on numbers in a finite field. The implementation, viewed as a physical process, operates on electrical signals propagating through silicon. The gap between abstraction and physics is where side-channel attacks live. The algorithm's correctness proof guarantees nothing about the time it takes to execute, the power it consumes, the electromagnetic radiation it emits, or the pattern of addresses it sends across the memory bus. Yet all of these physical observables correlate with the secret data being processed, and an attacker who measures them with sufficient precision can recover cryptographic keys.

Side-channel attacks are among the most devastating and most elegant attacks in all of computer security. They do not break the mathematics of cryptography; they break the physics of computation. And because physics cannot be patched, defending against side channels requires a fundamentally different approach to programming: the constant-time discipline, where control flow and memory access patterns are strictly independent of secret data.

This article covers the major classes of side-channel attacks—timing, power analysis, and cache-timing—with their underlying physical mechanisms, the most significant attacks in each class, and the countermeasures that form the modern constant-time programming discipline.

## 1. The Physical Origins of Side Channels

Every logic gate in a CMOS processor consumes energy when it switches state. The energy is drawn from the power supply as a current spike, whose amplitude depends (slightly) on the data being processed. The switching takes time, whose duration depends (slightly) on the input values through effects like carry propagation in adders and speculative execution in out-of-order cores. The memory accesses touch cache lines, and which lines are touched depends on the addresses, which depend on the data.

These physical effects are not bugs. They are the inevitable consequence of building computation out of physical devices. A mathematically pure computation, if it could be isolated from the physical world, would be side-channel-free. But the computation must run on a real processor, which draws real power, emits real electromagnetic radiation, and interacts with a real memory hierarchy. The side channel is the computation's unavoidable physical footprint.

The attacker's challenge is measurement: can the relevant physical quantity be measured with sufficient precision to distinguish the secret-dependent variations from noise? The defender's challenge is elimination: can the secret-dependent variations be suppressed to below the noise floor of any feasible measurement apparatus?

## 2. Timing Attacks: The Original Sin

Paul Kocher's 1996 paper "Timing Attacks on Implementations of Diffie-Hellman, RSA, DSS, and Other Systems" is the founding document of side-channel cryptanalysis. Kocher observed that the time required to compute a modular exponentiation depends on the exponent bits if the standard square-and-multiply algorithm is used.

In square-and-multiply, the exponent is scanned bit by bit, left to right. For each bit, a squaring is always performed. If the bit is 1, an additional multiplication is performed. The time to compute the exponentiation is therefore:

\[
\text{time} = T*{\text{base}} + \text{wt}(k) \cdot T*{\text{mult}}
\]

where \(\text{wt}(k)\) is the Hamming weight of the key. By measuring the total execution time for many exponentiations with known inputs, an attacker can estimate the Hamming weight of the key, which dramatically reduces the search space for brute-force key recovery.

Kocher went further: by measuring the timing of individual multiplications (in a non-networked setting, with an oscilloscope probe on the CPU's clock line), the attacker can recover individual key bits. If the multiplication for a given bit position always takes slightly longer than a squaring (as is typical), the timing trace directly reveals the bit.

### 2.1 The Montgomery Ladder Defense

The constant-time defense against timing attacks on exponentiation is the **Montgomery ladder**. Instead of performing a multiplication conditionally on the key bit, the Montgomery ladder performs both a squaring and a multiplication for every bit, but selects which result to use based on the bit. The control flow is fixed; only the data selection differs. In pseudocode:

```
R0 = 1, R1 = x
for i = |k|-1 downto 0:
    if k[i] == 0:
        R1 = R0 * R1
        R0 = R0 * R0
    else:
        R0 = R0 * R1
        R1 = R1 * R1
```

The number of squarings and multiplications is identical for all keys of a given bit length. The sequence of operation types is fixed. Only the data in the registers depends on the key, but the timing of a multiplication does not depend on the multiplicands (in a constant-time multiplier, which most modern multiplier units approximate but do not perfectly achieve).

### 2.2 Network-Based Timing Attacks

Brumley and Boneh (2003) demonstrated that timing attacks can be mounted remotely, over a network, against an OpenSSL server performing RSA decryption. By sending carefully crafted TLS handshake messages and measuring the server's response time with microsecond precision, they recovered the private RSA key. The attack exploited the fact that OpenSSL used the Chinese Remainder Theorem (CRT) optimization for RSA, and the reduction step's timing varied with the input.

The defense, adopted by OpenSSL and every other cryptographic library, was RSA blinding: before decrypting, the server multiplies the ciphertext by a random value \(r^e \pmod{N}\), decrypts the blinded value, and divides out the blinding factor. This makes the decryption time independent of the actual ciphertext, because the intermediate values are randomized with each operation.

## 3. Differential Power Analysis (DPA)

If a timing attack is listening to the rhythm of computation, a power analysis attack is watching the breathing. Kocher, Jaffe, and Jun (1999) introduced Differential Power Analysis (DPA), which uses statistical methods to extract secret keys from power consumption traces.

### 3.1 The CMOS Power Model

In CMOS logic, the dominant power consumption occurs when gates switch state. The power trace \(P(t)\) is the sum of the instantaneous power drawn by all gates switching at time \(t\). The switching activity at any clock cycle depends on the data being processed: the Hamming weight of the data on a bus, the Hamming distance between successive values in a register, the specific bit patterns that activate different numbers of gates in an ALU.

For a cryptographic operation processing secret data \(s\), the power trace can be modeled as:

\[
P(t) = P*{\text{data}}(t, s) + P*{\text{noise}}(t)
\]

where \(P*{\text{data}}\) is the data-dependent component and \(P*{\text{noise}}\) is noise (thermal noise, measurement noise, unrelated circuit activity). The signal-to-noise ratio (SNR) determines the number of traces needed to extract \(s\).

### 3.2 Simple Power Analysis (SPA)

SPA directly visualizes a single power trace and identifies patterns corresponding to the algorithm's execution. For example, in a naive RSA implementation using square-and-multiply, the power trace shows a short pulse for squarings and a longer pulse for multiplications. The sequence of pulse durations directly reveals the key bits.

SPA defenses aim to make the power trace independent of the key: fixed-sequence algorithms (Montgomery ladder, as above), balanced hardware (matching the power profile of different operations), and random insertion of dummy operations.

### 3.3 Differential Power Analysis (DPA)

When the signal is too weak for SPA (e.g., the difference between operations is smaller than the noise), DPA uses statistical averaging across many traces. The attack works on any cryptographic algorithm where an intermediate value depends on a small portion of the key (a subkey) and known or chosen input data.

The classic DPA attack on AES:

1. Collect \(N\) power traces \(P_i(t)\) for \(N\) known plaintexts \(x_i\).
2. For each candidate subkey byte \(k\) (256 possibilities):
   a. Compute the predicted intermediate value after the first S-box: \(v*{i,k} = \text{S-box}(x_i \oplus k)\).
   b. Choose a selection function, typically the least significant bit of \(v*{i,k}\): \(D*{i,k} = \text{LSB}(v*{i,k})\).
   c. Partition the traces into two sets based on \(D*{i,k}\) (expected LSB = 0 vs. expected LSB = 1).
   d. Compute the difference of the average traces: \(\Delta_k(t) = \langle P \rangle*{D=1}(t) - \langle P \rangle\_{D=0}(t)\).
3. The correct subkey byte produces a statistically significant spike in \(\Delta_k(t)\) at the clock cycle when the S-box output is latched. Incorrect subkey bytes produce no correlation.

DPA is remarkably robust. It works even when the power trace is noisy, when the attacker doesn't know the exact time of the S-box operation, and when there are countermeasures like clock jitter. The number of traces needed ranges from hundreds (for unprotected smart cards) to millions (for protected implementations).

### 3.4 Hardware Countermeasures

DPA has driven a subfield of hardware countermeasures:

- **Balanced circuits:** Dual-rail precharge logic (WDDL, SABL) where every gate has a complementary gate that switches simultaneously, making total power consumption constant regardless of data.
- **Shielding:** Metal layers that attenuate electromagnetic emissions.
- **Random clock jitter:** Varying the clock frequency randomly so traces cannot be aligned for averaging.
- **Masking:** Splitting every sensitive intermediate value into multiple shares (typically two or three) using Boolean or arithmetic masking, so that no single share correlates with the secret. Masking is the dominant software countermeasure.

## 4. Cache-Timing Attacks

Modern processors spend more time waiting for memory than executing instructions. The cache hierarchy—L1, L2, L3, and sometimes L4—reduces average memory latency by keeping recently accessed data close to the core. But the cache is a shared resource: all processes on the same core (in a time-sharing system) or on sibling cores (in an SMT system) share the cache. The cache state—which lines are present and which are not—is a side channel that leaks memory access patterns.

### 4.1 Prime+Probe

In the **Prime+Probe** attack (Osvik, Shamir, and Tromer, 2006), the attacker fills a cache set with their own data (Prime), waits for the victim to execute (which may evict some of the attacker's lines), and then measures the access time to each of their lines (Probe). Lines that are slow to access were evicted by the victim, revealing which cache sets the victim touched.

The granularity of Prime+Probe is the cache set (typically 64 bytes for the L1 data cache, aligned by 64-byte boundaries). For AES implementations that use S-box lookup tables, the table entries accessed depend on the key XORed with the plaintext. By monitoring which cache sets (and therefore which S-box entries) are accessed during the first round, the attacker recovers the key.

### 4.2 Flush+Reload

**Flush+Reload** (Yarom and Falkner, 2014) is a higher-resolution variant that leverages shared memory. If the attacker and victim share memory pages (e.g., the attacker has mapped the same shared library as the victim, such as libcrypto), the attacker can:

1. Flush a specific cache line using the `clflush` instruction.
2. Wait for the victim to execute.
3. Reload the line and measure the access time. If it is fast, the victim accessed the line; if slow, the victim did not.

Flush+Reload achieves single-cache-line resolution and can be mounted across cores on the same physical CPU (because the last-level cache is shared). It has been used to extract RSA private keys from GnuPG (by monitoring which code lines of the exponentiation routine are executed), AES keys from OpenSSL (by monitoring S-box table accesses), and ECDSA nonces from various libraries.

### 4.3 Evict+Time and Other Variants

The cache-timing attack family has expanded to include Evict+Time (measure the victim's execution time, evict a specific cache set, and re-measure; a slowdown indicates the victim used that set), Prime+Abort (use Intel TSX transactional memory to abort on cache eviction, providing a precise signal), and various machine-learning-enhanced variants that use neural networks to extract keys from noisy timing measurements.

### 4.4 Cache-Timing Defenses

The primary defense against cache-timing attacks is to eliminate secret-dependent memory accesses. This means:

- **No S-box lookup tables.** Instead, compute the S-box algebraically on the fly, or implement it as a circuit using bitwise logical operations that do not touch memory. The BitSlice AES implementation (Käsper and Schwabe, 2009) represents the AES state as 128 separate bit-slices and performs the S-box using Boolean operations, eliminating all table lookups.
- **Preloading and locking.** Load all lookup tables into the cache at initialization and pin them there, so that subsequent accesses do not cause cache misses and thus do not leak timing. This works against Prime+Probe but not against Flush+Reload (which can still evict lines from shared caches).
- **Cache partitioning.** Intel's Cache Allocation Technology (CAT) allows partitioning the last-level cache among processes, so that the attacker and victim never share cache sets. This is an OS-level defense, not an application-level one.

## 5. Microarchitectural Data Sampling: MDS, RIDL, and Line-Fill Buffers

The cache side channels of Section 4 exploit the _state_ of the cache—which lines are present or absent. A more recent and more dangerous class of attacks, collectively called Microarchitectural Data Sampling (MDS), exploits the _transient data_ that flows through microarchitectural buffers as side effects of out-of-order and speculative execution. Unlike cache-timing, which leaks metadata (addresses), MDS leaks _actual data values_ from buffers deep inside the CPU core.

### 5.1 The Microarchitectural Buffers at Risk

Modern out-of-order CPUs contain dozens of internal buffers that hold in-flight data: the line-fill buffer (LFB) that holds cache lines being fetched from L2/L3, the load port buffers that hold data being forwarded between pipeline stages, and the store buffer that holds pending writes. These buffers are _microarchitectural_—they are invisible to the architectural state (registers, memory) but their contents can be inferred or directly sampled through side channels.

The line-fill buffer (LFB) is particularly dangerous. When a load misses the L1 cache, the CPU allocates an LFB entry that will eventually receive the requested cache line from the higher-level caches. During the miss, the LFB entry contains _stale data_ from previous fills—data that may belong to other processes, the kernel, or even SGX enclaves. An attacker who can trigger an L1 miss and probe the LFB's stale contents can read data across security boundaries.

### 5.2 RIDL: Rogue In-Flight Data Load

The RIDL attack (van Schaik et al., 2019) exploits the fact that when a load instruction faults or is assist-bound (e.g., requires a microcode assist for address translation), the load pipeline speculatively forwards data from the line-fill buffer to dependent instructions _before_ the fault is resolved. By arranging a load that faults (e.g., reading from an unmapped page), but speculatively depends on the loaded value to encode an address for a cache access, the attacker can:

```
// RIDL attack sketch
char *probe = allocate_probe_array();
char *victim_addr = (char *)0xDEADBEEF;  // unmapped, will fault

// The load faults, but speculatively, stale LFB data
// flows into 'leaked_value'
uint8_t leaked_value = *victim_addr;

// Speculatively, before fault, leaked_value indexes probe array
// This loads probe[leaked_value * 4096] into cache
char dummy = probe[leaked_value * 4096];

// After fault is handled, time probe array to recover leaked_value
for (int i = 0; i < 256; i++) {
    if (time_read(probe[i * 4096]) < THRESHOLD)
        printf("Leaked byte: %d\n", i);
}
```

RIDL demonstrated that stale data from every LFB entry—and thus from any process that recently ran on the same logical core—can be exfiltrated. The attack was demonstrated across processes, across user/kernel boundaries, and across Intel SGX enclave boundaries.

### 5.3 ZombieLoad, Fallout, and the MDS Family

ZombieLoad (Schwarz et al., 2019) extended RIDL to the fill-buffer sharing that occurs during Hyper-Threading: when two logical cores share a physical core, their LFBs are pooled. ZombieLoad allows an attacker thread on one logical core to sample the LFB data of the sibling thread, including AES keys, password strings, and disk encryption keys. Fallout (Canella et al., 2019) targeted the store buffer, demonstrating that store-to-load forwarding—where a load that matches a pending store receives the stored data—can leak stale store-buffer contents when the load partially matches the store address.

Collectively, the MDS-class attacks (RIDL, Fallout, ZombieLoad, RIDL) were among the most severe CPU vulnerabilities ever disclosed. Intel's mitigation involved microcode updates that clear the relevant buffers on context switches (the VERW instruction), combined with OS-level scheduling mitigations (disabling Hyper-Threading in security-sensitive deployments). The performance cost was significant: 5-40% throughput reduction for database and web-serving workloads, and near-zero for compute-bound cryptographic workloads.

### 5.4 MDS Implications for Cryptographic Implementations

For cryptographic code, MDS attacks mean that keys held in registers or L1 cache are not safe if an attacker can co-locate on the same physical core. This breaks the fundamental assumption of process isolation that cryptographic libraries rely on. The response has been to develop _data-independent usage_ patterns—ensuring that secret keys are loaded into registers and used only while interrupts are disabled and sibling threads are paused—and to leverage _cache line locking_ where available. More fundamentally, MDS validated the design principle of _formally verified microarchitectural isolation_, which requires that no microarchitectural state (buffers, predictors, caches) leaks across security domains—a property that post-MDS Intel CPUs (Ice Lake and later) partially achieve through hardware buffer flushing.

## 6. The Constant-Time Programming Discipline

The cumulative lesson of thirty years of side-channel attacks is that secure cryptographic code must follow a strict discipline: **every instruction executed and every memory location accessed must be independent of secret data.** This is the constant-time programming discipline.

In practice, constant-time coding means:

- **No secret-dependent branches.** The sequence of instructions executed must be identical for all possible values of the secret. This eliminates timing leaks from branch prediction and instruction fetch.
- **No secret-dependent memory accesses.** The addresses of all load and store instructions must be independent of the secret. This eliminates cache-timing leaks.
- **No secret-dependent instruction operands in variable-latency instructions.** On most processors, multiplication, division, and floating-point operations have data-dependent latency. These instructions must be avoided, or used only with fixed operands.
- **No secret-dependent shifts on some microarchitectures.** On certain Intel processors, the latency of a variable-distance shift (`shl eax, cl`) depends on the shift count, creating a timing side channel. Use constant-distance shifts or bit-test instructions instead.

This discipline is alien to most programmers, who are trained to optimize for the common case (which involves data-dependent branching) and to use table lookups for efficiency (which involve data-dependent memory access). Writing constant-time code requires a mental model of the processor that is closer to a circuit than a general-purpose computer: every data bit must affect only data, never control flow, never address generation.

### 5.1 Tool Support

Several tools help enforce the constant-time discipline:

- **ctgrind** (2014): A Valgrind-based dynamic analysis tool that tracks whether secret values influence branch conditions or memory addresses, reporting violations at runtime.
- **ct-verif** (Almeida et al., 2016): A static analysis tool based on the SMACK verifier that proves (for small programs) that all branches and memory accesses are independent of secret-labeled data.
- **dudect** (Reparaz et al., 2017): A statistical differential testing tool that compares execution-time distributions for different secret values and flags statistically significant differences.
- **Jasmin** (Almeida et al., 2017): A programming language designed for high-assurance constant-time cryptography, where the type system tracks secret values and the compiler guarantees that secret-dependent operations are forbidden.

### 5.2 The Cost of Constant-Time

Constant-time programming imposes a performance penalty. The BitSlice AES implementation is roughly 2x slower than a table-based implementation for the same block size on the same CPU (though the BitSlice approach parallelizes across blocks, making it faster than table-based implementations for counter-mode encryption where multiple blocks are processed simultaneously). The cost of eliminating secret-dependent branches in elliptic curve scalar multiplication is roughly 1.5-2x.

The security community has largely accepted this cost as necessary. Modern cryptographic libraries—libsodium, BoringSSL, curve25519-dalek, hacl-star—are constant-time by default. The Transition from OpenSSL's variable-time RSA (blinded but still exhibiting some timing variation) to BoringSSL's fully constant-time RSA was a multi-year engineering effort involving rewriting core bignum routines in constant-time assembly. The result is provably constant-time RSA at the cost of roughly 30% slower decryption, which is an acceptable tradeoff for most applications.

## 7. Beyond Classical Side Channels: EM, Acoustic, and Photonic

Timing, power, and cache are not the only side channels.

**Electromagnetic (EM) emissions.** Every current loop in a processor radiates an electromagnetic field. With a near-field probe placed near the chip, an attacker can measure EM emissions with higher spatial resolution than power analysis (because the probe can be positioned to pick up signals from specific regions of the die). EM attacks are more difficult to mount (requiring physical proximity) but more difficult to defend against (shielding is imperfect, and radiated emissions cannot be entirely suppressed without violating the laws of physics).

**Acoustic analysis.** Genkin, Shamir, and Tromer (2013) demonstrated that the sound emitted by a laptop's voltage regulator—a faint whine at frequencies between 1 kHz and 20 kHz—carries information about the CPU's power consumption, and thus about the cryptographic operations being performed. By recording the sound with a commodity microphone (or even a smartphone placed nearby), they recovered RSA and ElGamal keys. The defense involves acoustic shielding of the voltage regulator, which is uncommon outside of high-security environments.

**Photonic emission.** When a transistor switches, it emits a small number of photons in the near-infrared spectrum. With a sufficiently sensitive camera and backside access to the die (the chip must be decapsulated), an attacker can image the switching activity and extract keys. This attack requires physical access at the level of a well-equipped semiconductor lab and is relevant primarily for hardware security modules (HSMs) and smart cards.

**RowHammer and Plundervolt.** These attacks exploit the physical properties of DRAM cells (RowHammer: repeatedly accessing one row to flip bits in adjacent rows) and the programmable voltage regulators in modern CPUs (Plundervolt: undervolting the CPU to induce faults in cryptographic computations). They blur the line between side-channel attacks and fault injection attacks but share the common theme of exploiting physical implementation details that the mathematical abstraction ignores.

## 8. The Formal Verification Frontier

The constant-time discipline can be formally verified. A program either is constant-time (its control flow and memory accesses are independent of secret-labeled inputs) or it is not. This binary property is amenable to type systems, abstract interpretation, and symbolic execution.

The **CT-Verif** toolchain for Jasmin verifies constant-time for cryptographic primitives that have been implemented in Jasmin and compiled to assembly. The verified assembly is guaranteed to be constant-time on the target microarchitecture (assuming the microarchitecture itself is correctly modeled). This closes the gap between "we think this code is constant-time" and "we have a machine-checked proof that it is constant-time."

For higher-level cryptographic protocols (TLS, Signal), formal verification of side-channel resistance is an active research area. Protocols can leak at the design level (e.g., the TLS padding oracle attack, which is a protocol-level timing side channel), and verifying protocol-level constant-time requires modeling the interaction between the protocol state machine and the cryptographic primitives.

## 9. Template Attacks and Profiled Side-Channel Analysis

While DPA and cache-timing attacks are "non-profiled"—the attacker extracts the key from a single device without prior characterization—a more powerful class of **profiled attacks** exists when the attacker can characterize an identical device before attacking the target. Template attacks, introduced by Chari, Rao, and Rohatgi (2002) at CHES, are the canonical profiled attack and have evolved into a rich family of machine-learning-driven side-channel analysis techniques.

**The Profiling Phase.** The attacker possesses a _profiling device_ identical to the target, on which she can run arbitrary code with arbitrary keys. For each possible value of the subkey (e.g., each of the 256 possible values of one byte of the AES key), the attacker collects thousands of power traces during the target operation (say, the first S-box lookup of the first round). From these traces, she estimates a multivariate Gaussian distribution \(\mathcal{N}(\mu_k, \Sigma_k)\) for each subkey value \(k\), where \(\mu_k\) is the mean power trace (a vector of \(T\) time samples) and \(\Sigma_k\) is the \(T \times T\) covariance matrix. The covariance captures not just the noise level at each time sample but the correlation structure between samples—two time samples may be correlated because they both reflect the same underlying gate switching.

**The Attack Phase.** Given a single power trace \(\mathbf{t}\) from the target device, the attacker computes the likelihood \(\Pr[\mathbf{t} \mid k] = \mathcal{N}(\mathbf{t}; \mu_k, \Sigma_k)\) for each candidate subkey \(k\) and selects the maximum-likelihood candidate. The template attack is optimal in the sense of maximum likelihood estimation: if the noise is truly multivariate Gaussian and the covariance estimates are accurate, no other attack can achieve a higher success rate for a given number of traces.

**Machine Learning Extensions.** Modern profiled attacks replace the Gaussian model with convolutional neural networks (CNNs), random forests, and gradient-boosted trees. The advantage of deep learning is that it eliminates the need to select "points of interest" (the relevant time samples) manually—the network learns which time samples are informative during training. Cagli, Dumas, and Prouff (CHES 2017) demonstrated that CNNs achieve state-of-the-art attack performance on datasets like DPAv4, recovering AES keys from as few as 3–5 traces when trained on 50,000 profiling traces. The main limitation of deep learning approaches is their opacity: unlike the Gaussian template attack, which provides an interpretable model (the mean and covariance), a CNN provides a black-box classifier that is harder to validate and to use for designing countermeasures.

**The Attacker Model Debate.** Profiled attacks raise a fundamental question: how realistic is the assumption that the attacker can obtain an identical profiling device? In the smart card context, it is highly realistic—the attacker can buy the same model of card and characterize it exhaustively. For cloud-based attacks, the attacker may be able to co-locate a profiling VM on the same physical machine as the target. For hardware security modules (HSMs), the attacker may not have a profiling device, in which case non-profiled attacks (DPA, MIA, correlation power analysis) are the only option. The security community increasingly adopts the position that profiled attacks represent the worst-case threat model, and devices should be designed to resist them.

## 10. Correlation Power Analysis and Information-Theoretic Leakage Assessment

Differential Power Analysis (Section 3) partitions traces into two sets based on a single bit of an intermediate value and looks for a difference-of-means spike. Correlation Power Analysis (CPA), introduced by Brier, Clavier, and Olivier (CHES 2004), generalizes DPA to the full value of the intermediate, using Pearson's correlation coefficient as a continuous measure of dependence between the predicted power consumption and the measured traces. CPA is more efficient than DPA—requiring fewer traces—and provides a natural framework for quantifying leakage in information-theoretic terms.

### 10.1 The CPA Attack Algorithm

CPA replaces DPA's binary partition with a linear regression model. For each candidate subkey \(k\) and each trace \(i\), the attacker computes a _predicted power value_ \(h*{i,k}\) based on a power model of the device. The most common model is the Hamming weight (HW) model: \(h*{i,k} = \text{HW}(v*{i,k})\), where \(v*{i,k}\) is the intermediate value (e.g., the S-box output) and HW counts the number of 1-bits. The Hamming distance (HD) model, \(h*{i,k} = \text{HW}(v*{i,k} \oplus v'\_i)\), accounts for the previous state \(v'\_i\) of the register and is more accurate for CMOS registers where dynamic power dominates.

The attacker computes the Pearson correlation coefficient \(\rho*k(t)\) between the vector of predicted values \((h*{1,k}, \ldots, h\_{N,k})\) and the vector of measured power values at time sample \(t\) across all \(N\) traces:

\[
\rho*k(t) = \frac{\sum*{i=1}^N (h*{i,k} - \bar{h}\_k)(P_i(t) - \bar{P}(t))}{\sqrt{\sum_i (h*{i,k} - \bar{h}\_k)^2} \cdot \sqrt{\sum_i (P_i(t) - \bar{P}(t))^2}}
\]

If the correct subkey \(k^_\) yields a prediction that genuinely correlates with the device's power consumption, then \(\rho\_{k^_}(t)\) will show a statistically significant peak at the time sample where the intermediate value is processed. For incorrect subkeys, the correlation will be indistinguishable from zero. The absolute value of the peak correlation is typically 0.3–0.8 for unprotected implementations (a strong signal) and 0.05–0.15 for masked implementations (a weak signal requiring more traces).

### 10.2 Mutual Information Analysis (MIA)

CPA assumes a linear relationship between the predicted power and the actual power—specifically, that the power consumption is proportional to the Hamming weight of the intermediate value. In real devices, this relationship can be non-linear due to glitches, coupling effects, and the fact that different bits of a bus may have different capacitive loads. Mutual Information Analysis (MIA), proposed by Gierlichs, Batina, Tuyls, and Preneel (CHES 2008), replaces Pearson's correlation with Shannon's mutual information, which captures _any_ statistical dependence, linear or non-linear:

\[
I(K; T) = H(K) - H(K \mid T) = \sum*{k \in \mathcal{K}} \Pr[k] \sum*{t \in \mathcal{T}} \Pr[t \mid k] \log_2 \frac{\Pr[t \mid k]}{\Pr[t]}
\]

Here \(K\) is the subkey random variable and \(T\) is the measured trace value at a single time sample. The attacker estimates the conditional probability distributions \(\Pr[t \mid k]\) from the profiling traces (for each subkey candidate \(k\), build a histogram of trace values) and then computes \(I(K; T)\) for each time sample. The time sample with the highest mutual information for the correct subkey reveals the point of interest. The subkey candidate that maximizes the mutual information in the attack phase is selected.

MIA is more computationally intensive than CPA—building histograms and computing mutual information for 256 subkey candidates times \(T\) time samples can be millions of operations—but it is more robust against non-linear power models and against certain countermeasures that randomize the Hamming weight relationship. MIA has been successfully applied against masked AES implementations where CPA, relying on the linear HW model, failed to find the key.

### 10.3 Test Vector Leakage Assessment (TVLA)

An alternative to key-recovery attacks is **leakage assessment**: rather than trying to extract a key, the evaluator asks whether the device leaks _any_ secret-dependent information. The dominant methodology is Test Vector Leakage Assessment (TVLA), standardized in the ISO/IEC 17825 testing framework for side-channel resistance.

The basic TVLA procedure is the _fixed-vs-random t-test_:

1. Collect \(N\_{\text{fixed}}\) power traces with a fixed key and fixed plaintext.
2. Collect \(N\_{\text{random}}\) power traces with the same fixed key but random plaintexts.
3. At each time sample \(t\), compute Welch's t-statistic:
   \[
   t(t) = \frac{\mu*{\text{fixed}}(t) - \mu*{\text{random}}(t)}{\sqrt{\frac{\sigma^2*{\text{fixed}}(t)}{N*{\text{fixed}}} + \frac{\sigma^2*{\text{random}}(t)}{N*{\text{random}}}}}
   \]
4. If \(|t(t)| > 4.5\) for any time sample, the device fails—it exhibits statistically significant leakage at that time sample.

The threshold 4.5 corresponds to a 99.999% confidence level under the Gaussian null hypothesis that the two trace sets have the same mean. TVLA is attractive because it makes no assumptions about the leakage model or the attack strategy—it is a non-specific, black-box test. However, TVLA is also controversial: a device that passes TVLA may still be vulnerable to higher-order attacks (where the attacker combines multiple time samples), and a device that fails TVLA may still be secure in practice if the detected leakage cannot be exploited to recover the key (e.g., because the leakage is in a non-cryptographic portion of the trace). The community has converged on using TVLA as a screening tool—a necessary but not sufficient condition for side-channel resistance.

## 11. Fault Injection Attacks: Voltage Glitching, Clock Manipulation, and Laser Probing

Side-channel attacks are _passive_: the attacker observes the computation without disturbing it. Fault injection attacks are _active_: the attacker deliberately causes the computation to err, and uses the erroneous outputs to recover secret information. While technically distinct from side channels, fault injection exploits the same physical layer of the computing stack and is often deployed alongside side-channel analysis in combined attacks.

### 11.1 Differential Fault Analysis (DFA) on AES

Differential Fault Analysis, introduced by Biham and Shamir (1997), is the fault-injection analogue of differential cryptanalysis. The attacker runs the cryptographic computation twice on the same input: once normally (obtaining the correct output \(C\)) and once with a fault injected at a carefully chosen point (obtaining the faulty output \(C'\)). By comparing \(C\) and \(C'\), and exploiting the differential properties of the cipher, the attacker recovers the key.

For AES, the most common DFA attack injects a fault into the state just before the final MixColumns of the penultimate round. If a single byte of the state is corrupted by the fault, the difference at the output of the final round propagates through the inverse S-box in a predictable way. Each single-byte fault produces a set of candidate key bytes that are consistent with the observed output difference; with approximately 3–5 faults on the same input, the key space is reduced to a single candidate.

```
Normal: P -> ... -> S_{r-1} -> MC -> S_r -> SR -> SB -> K  -> C
Faulty: P -> ... -> S'_{r-1} -> MC -> S'_r -> SR -> SB -> K -> C'
                    ^
                   fault injected here (single byte flip)

Recovery: For each byte offset j:
  For each candidate k_j in GF(2^8):
    If InvSB(C_j xor k_j) xor InvSB(C'_j xor k_j)
       matches expected difference from MC propagation:
         keep k_j as candidate
  After ~3 faults: intersection of candidate sets yields unique key byte
```

DFA on AES requires precise fault location—the attacker must flip exactly one byte in the state between the penultimate and final MixColumns. Practical fault injection techniques for achieving this include:

- **Clock glitching:** Temporarily increase the clock frequency for one cycle, causing some registers to sample their inputs before the signals have stabilized, resulting in bit flips whose positions depend on the physical layout of the chip.
- **Voltage glitching (crowbar injection):** Momentarily short the power supply, dropping the core voltage below the transistor threshold. Some flip-flops will lose their state before others, depending on process variation, creating a byte-level fault with high probability.
- **Electromagnetic pulse injection:** Generate a sharp EM pulse with a probe positioned over the die. The pulse induces eddy currents in the power grid, locally dropping the voltage and causing faults in nearby logic. EM injection can achieve sub-millimeter spatial resolution, enabling targeting of specific AES rounds.
- **Optical (laser) fault injection:** Focus a near-infrared laser on the backside of the die. The laser creates electron-hole pairs in the silicon, temporarily increasing the conductivity of specific transistors. By pulsing the laser at the right moment and position (with ~1 μm precision), the attacker can flip individual bits in a target register. Laser injection is the "gold standard" for fault precision but requires decapsulating the chip and a several-hundred-thousand-dollar laser setup.

### 11.2 Safe-Error Attacks

Some fault injection attacks do not require the faulty output; the mere _occurrence_ (or non-occurrence) of a fault, as detected by timing or power measurement, leaks information. In a **safe-error attack** on RSA, the attacker injects a fault into the exponentiation (e.g., flipping a bit of the exponent during the square-and-multiply loop). If the flipped bit is 0 (originally 1), a multiplication is skipped, and the output is incorrect—but the attacker detects this via a timing change. If the flipped bit is 1 (originally 0), the fault has no effect (the multiplication is already not being performed). By testing each bit position with and without fault injection, the attacker recovers the key: a timing change means the bit was 1; no change means the bit was 0. Safe-error attacks are particularly dangerous because they bypass DFA countermeasures that check for incorrect outputs—the attacker never examines the output, only the _behavior_.

### 11.3 Combined Side-Channel and Fault Attacks

The most sophisticated physical attacks combine side-channel analysis and fault injection. For example, a combined attack on a masked AES implementation might:

1. Use a laser to disable the random number generator that generates the masks, reducing the masking to all-zero shares (equivalent to no masking).
2. Then use CPA to extract the key from the now-unmasked implementation.

Another combined approach is _ineffective fault analysis_: inject faults that are designed to have no effect on the output (e.g., flipping a bit that is masked into zero) and observe via power analysis whether the fault "took"—leaking information about the mask value, which can then be used to unmask the key.

### 11.4 Defenses Against Fault Injection

Defenses against fault injection fall into three categories:

- **Redundancy:** Compute the cryptographic operation twice (or three times) and compare the outputs. If they differ, a fault was injected and the output is suppressed. Temporal redundancy (perform the same computation twice on the same hardware) and spatial redundancy (perform the computation on two independent cores) provide fault detection at roughly 2x area/power overhead.
- **Error-detecting codes:** Encode the cryptographic state with a parity, CRC, or nonlinear error-detecting code that can detect single-bit or single-byte faults. For AES, the state can be extended with a parity byte that is updated alongside each round transformation. Faults are detected by checking parity at the end. The overhead is ~10% in area, but the codes can be circumvented by an attacker who injects faults that preserve the code (e.g., flipping an even number of bits in a parity-protected byte).
- **Hardware sensors:** Deploy on-chip glitch detectors (circuits that monitor the power supply for transient drops), clock monitors (circuits that detect frequency anomalies), and light sensors (photodiodes that detect laser illumination). When a fault is detected, the chip erases its key material and halts. These sensors are standard in smart card ICs and hardware security modules (HSMs) but are absent from general-purpose CPUs, making cloud-based fault attacks on cryptographic libraries a realistic concern.

### 11.5 Plundervolt and Software-Only Fault Injection

The Plundervolt attack (Murdoch et al., 2020) demonstrated that fault injection does not require physical access: on Intel CPUs, the `undervolt` MSR (model-specific register) allows software (running at ring 0, i.e., the kernel) to reduce the CPU core voltage below the manufacturer's specification. The reduced voltage destabilizes the circuit, causing timing violations that manifest as data corruption—precisely targeted faults. Plundervolt was used to recover an SGX enclave's sealing key by faulting the AES key schedule and applying DFA. Intel mitigated the attack by disabling the undervolt MSR in microcode, but the lesson stands: in the age of programmable power management, fault injection is becoming as accessible as side-channel analysis, and the two disciplines are converging into a unified field of _physical cryptanalysis_.

## 12. Case Study: Hertzbleed — When Dynamic Frequency Scaling Becomes a Side Channel

In 2022, Wang, Paccagnella, He, Shacham, Fletcher, and Kohlbrenner (UT Austin, UIUC, UW) published Hertzbleed, a devastating demonstration that the dynamic frequency scaling (DFS) mechanism present in all modern Intel, AMD, and Arm processors constitutes a remotely exploitable side channel. Hertzbleed won a Pwnie Award and forced a fundamental rethinking of the constant-time discipline.

**The Physical Mechanism.** Modern CPUs dynamically adjust their operating frequency in response to power consumption: the more gates switching, the more power drawn, and the more the CPU must reduce frequency to stay within its thermal design power (TDP) envelope. For certain instruction sequences—specifically, wide vector integer multiplications—the number of gate switches depends on the Hamming weight of the operands. When a cryptographic implementation processes a secret key bit that results in a large Hamming weight intermediate value, the CPU's frequency briefly drops; when the key bit results in a low Hamming weight, the frequency stays high. The wall-clock execution time therefore depends on the secret key, even if the implementation is constant-time in terms of instruction count and memory access pattern.

**The Attack.** Hertzbleed demonstrates key recovery for SIKE (Supersingular Isogeny Key Encapsulation, a post-quantum KEM) and for HQC (Hamming Quasi-Cyclic, another post-quantum scheme). The attacker repeatedly invokes the decapsulation operation with chosen ciphertexts and measures the response time over the network. By correlating timing variations with the Hamming weight of intermediate values, the attacker recovers the private key. Critically, the attack works against _constant-time implementations_—the code had no secret-dependent branches and no secret-dependent memory accesses, yet it leaked through the CPU's power management hardware.

In the SIKE case specifically, the decapsulation operation computes an isogeny whose degree depends on the private key. The implementation uses a constant-time Montgomery ladder (similar to the one described in Section 2.1) to traverse the isogeny, ensuring that the same sequence of field multiplications is executed regardless of the key. However, the _operands_ fed to those multiplications have different Hamming weights for different keys. The power consumption difference between a multiplication with operands of Hamming weight 128 versus Hamming weight 64 is enough to shift the CPU frequency by 10-50 MHz. By measuring the decapsulation time over thousands of chosen ciphertexts and applying a standard DPA-style statistical test (the Welch t-test), the attacker distinguishes key bits with confidence exceeding 99.9%. The full SIKE private key recovery required approximately 10,000 timing measurements—feasible in under an hour over a LAN connection.

The wider implication is that _any_ cryptographic implementation that processes secret-dependent data—even through a constant instruction sequence—can leak through frequency scaling. This includes almost all post-quantum schemes (which rely on large-integer or polynomial arithmetic with data-dependent Hamming weights), RSA, ECDSA, and AES in software. Hertzbleed unified the power side channel and the timing side channel into a single attack vector: power consumption modulates frequency, and frequency modulates wall-clock time, so power differences become timing differences that are measurable from software, across VMs, and even across the network.

**The Root Cause.** Hertzbleed exposes a flaw in the abstraction boundary that the constant-time discipline assumes. Constant-time code assumes that the CPU's timing is independent of data values for a fixed instruction sequence. This assumption, known as the "data-independent timing" (DIT) assumption, was always an approximation—even simple instructions like integer multiplication have data-dependent execution times on some microarchitectures—but it was a reasonable approximation for most practical purposes. DFS breaks this approximation decisively: the same instruction sequence takes measurably different wall-clock times depending on the data, through a mechanism that is invisible to the instruction-level timing model.

**Fixes and Implications.** Intel and AMD issued microcode updates that allow software to disable frequency throttling for sensitive code regions (via MSR writes to lock the frequency to the base clock). Arm introduced the Data Independent Timing (DIT) ISA extension in Armv8.4-A, which guarantees that a designated set of instructions execute in truly data-independent time, even across frequency changes. The broader lesson of Hertzbleed is that side channels emerge from every layer of the hardware stack, including mechanisms—like DFS—that were never designed to carry information and were not recognized as potential side channels. The defender must model the entire physical stack, not just the ISA, when reasoning about side-channel security.

## 13. Masking, Threshold Implementations, and Provable Countermeasures

While constant-time programming eliminates timing and cache side channels, it does not address power analysis (DPA) or electromagnetic emanations—the power consumption of individual gates still depends on the data being processed. **Masking** is the primary defense against power/EM side channels, and it comes with a rigorous theoretical foundation.

**Boolean Masking.** The basic idea of Boolean masking is to split each secret value \(x\) into \(d+1\) shares \(x*0, x_1, \ldots, x_d\) such that \(x = x_0 \oplus x_1 \oplus \cdots \oplus x_d\), where \(x_1, \ldots, x_d\) are uniformly random and independent. The computation is then performed on the shares individually, without ever reconstructing \(x\). A linear operation \(L\) is easy to mask: \(L(x) = L(x_0) \oplus L(x_1) \oplus \cdots \oplus L(x_d)\). A non-linear operation (like the AES S-box) is more complex and requires techniques such as \_masked table lookup*, _secure multiparty computation in the masked domain_ (using ISW multiplication, after Ishai, Sahai, and Wagner, 2003), or _threshold implementations_ that split the S-box into component functions where each share satisfies non-completeness and uniformity.

**The d-th Order Security Model.** A masked implementation is _d-th order secure_ if every set of \(d\) (or fewer) intermediate values is statistically independent of the secret. This is a rigorous, provable security notion: if the masking is \(d\)-th order secure and the noise in the power measurements is above a certain threshold, then the number of traces required for a successful DPA attack grows exponentially with \(d\). In practice, \(d=2\) (three shares) defeats most attackers, and \(d=4\) (five shares) is considered sufficient for high-security applications. The cost of masking is approximately \(O(d^2)\) runtime overhead—\(d+1\) shares mean \(d+1\) times the computation, plus the overhead of secure multiplications (each ISW multiplication costs \(O(d^2)\) field operations). For AES with \(d=2\), the overhead is roughly 5–10x; for \(d=4\), it is 20–40x.

**Threshold Implementations (TI).** Threshold implementations, introduced by Nikova, Rechberger, and Rijmen (2006), provide a provable defense against first-order DPA even in the presence of glitches—transient signal transitions that occur before a gate's output stabilizes. Standard Boolean masking is vulnerable to glitches because a glitch can cause a gate to transiently compute on an unmasked intermediate value. TI decomposes each non-linear function \(f\) into \(s\) component functions \(f_1, \ldots, f_s\) such that (1) **non-completeness**: each \(f_i\) is independent of at least one share of each input variable, ensuring that no single component sees all shares; (2) **correctness**: the XOR of the component outputs equals \(f(x)\); and (3) **uniformity**: the output shares are uniformly distributed. For the AES S-box, a 3-share TI requires 4 component functions and increases the S-box area by approximately 3x. TI has been used in several ASIC and FPGA implementations of AES, PRESENT, and Keccak, and forms the basis of the side-channel resistance claims for post-quantum candidates like Kyber and Dilithium.

**Composability and Verification.** A major challenge for masking is _composability_: two \(d\)-th order secure components, when composed, may not form a \(d\)-th order secure system because intermediate values at the component boundary may combine shares in unexpected ways. The Barthe et al. framework (maskVerif, 2015) provides a formal verification tool that checks whether a masked circuit is \(d\)-th order secure by analyzing the propagation of secret-labeled shares through the circuit. The tool has been used to verify masked AES, Keccak, and several post-quantum schemes. The combination of masking, threshold implementations, and formal verification represents the current state of the art in software and hardware countermeasures against power/EM side channels.

## 14. Summary

The constant-time programming discipline is the current best defense for software implementations. It is effective, verifiable, and increasingly mandated by cryptographic standards (FIPS 140-3 requires side-channel resistance testing). The price—a modest performance overhead and a radical departure from conventional programming idioms—is small compared to the cost of key compromise.

The arms race continues. New microarchitectural features (speculative execution, SMT, non-uniform cache architectures) create new side channels faster than the formal methods community can verify defenses. The Spectre and Meltdown attacks of 2018 showed that even the constant-time discipline is insufficient when the microarchitecture speculates past branches and leaks through the cache state—a lesson we will explore in depth in the next article. For now, the takeaway is that side-channel security is not a property of the algorithm but of the entire stack, from the transistor to the application, and that every layer must be hardened for the system to be secure.
