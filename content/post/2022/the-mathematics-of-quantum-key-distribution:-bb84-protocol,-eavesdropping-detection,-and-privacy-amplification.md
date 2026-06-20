---
title: "The Mathematics Of Quantum Key Distribution: Bb84 Protocol, Eavesdropping Detection, And Privacy Amplification"
description: "A comprehensive technical exploration of the mathematics of quantum key distribution: bb84 protocol, eavesdropping detection, and privacy amplification, covering key concepts, practical implementations, and real-world applications."
date: "2022-06-19"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-mathematics-of-quantum-key-distribution-bb84-protocol,-eavesdropping-detection,-and-privacy-amplification.png"
coverAlt: "Technical visualization representing the mathematics of quantum key distribution: bb84 protocol, eavesdropping detection, and privacy amplification"
---

**The Mathematics Of Quantum Key Distribution: BB84 Protocol, Eavesdropping Detection, And Privacy Amplification**

## Part 1: The Biggest Lie in Security – Expanded

For the better part of a century, we have been living with a lie. It is a comforting lie, a necessary one for the functioning of global commerce, private communication, and national defense, but a lie nonetheless. The lie is this: that a secret key, shared between two parties, can be kept secure against any adversary, provided the computational mathematics backing that key is sufficiently complex.

We have built an entire digital civilization on this premise. Every time you buy a coffee with a credit card, every time you send a “secure” email, every time your bank processes a transaction, you are leaning on the unspoken assumption that factoring large prime numbers is _hard_. The RSA algorithm, the Diffie-Hellman key exchange, and the elliptic curve cryptography that underpins TLS/SSL all rely on the stark, practical reality that a classical computer would take longer than the age of the universe to brute-force a 2048-bit key.

This is not a lie based on a theorem. It is a lie based on a lack of imagination.

As computer scientists, we revere the Church–Turing thesis. We believe in the universality of computation. Yet we have implicitly bet the entire security of the internet on a non-universal property: that a specific mathematical problem—factoring—belongs to a complexity class that is intractable. But the universe is not a classical Turing machine. The universe is quantum mechanical.

Enter Shor’s algorithm. In 1994, Peter Shor demonstrated that if you could build a sufficiently large, fault-tolerant quantum computer, you could factor large primes in polynomial time. RSA, ECDSA, Diffie–Hellman—they all shatter. The lie is exposed. The assumption that math is “hard enough” collapses under the weight of superposition and entanglement.

But here is the twist in the tale. The same quantum physics that threatens to break classical cryptography also offers a solution—a radically different kind of security that does not rely on mathematical hardness at all. It relies on the laws of physics themselves. This is the domain of **Quantum Key Distribution (QKD)** .

The core idea of QKD is almost absurdly simple: use single photons (or other quantum systems) to transmit a secret key, and any attempt by an eavesdropper to intercept or measure those photons will inevitably disturb them. By checking for that disturbance, the two legitimate parties can detect the eavesdropper’s presence. If no significant disturbance is observed, they can safely use the sifted bits as a shared secret key, whose security is guaranteed by the fundamental principles of quantum mechanics—not by computational assumptions.

If this sounds too good to be true, you are right to be skeptical. QKD is not a magic bullet. It does not solve all security problems. It cannot, by itself, authenticate the identity of the communicating parties. It is limited by distance, by noise, by the imperfection of real-world hardware. And the mathematical machinery needed to turn raw quantum transmissions into a secure key—error correction, parameter estimation, privacy amplification—is every bit as intricate as the classical cryptography it seeks to replace.

This blog post is a deep dive into that machinery. We will focus on the most famous QKD protocol: **BB84**, invented by Charles Bennett and Gilles Brassard in 1984. We will explore how it works, how eavesdropping is detected, and how we go from a partially compromised raw bit string to a provably secure final key through the twin processes of information reconciliation and privacy amplification. By the end, you will understand not only the protocol but the fundamental mathematical structure that underlies all quantum cryptography.

But first, we must understand the quantum toolkit.

---

## Part 2: The Quantum Toolkit – Qubits, Superposition, and the No-Cloning Theorem

Before diving into the protocol, we need to establish a minimal understanding of quantum mechanics as it applies to information. The central object is the **qubit** (quantum bit). A qubit is a two-state quantum system, like a photon’s polarization or the spin of an electron. But unlike a classical bit (which is always either 0 or 1), a qubit can exist in a **superposition** of both basis states at the same time.

Mathematically, we represent a qubit state as a normalized vector in a two-dimensional complex Hilbert space. Let {|0⟩, |1⟩} be an orthonormal basis (the _computational basis_). A general pure state is:

|ψ⟩ = α|0⟩ + β|1⟩

where α, β ∈ ℂ, and |α|² + |β|² = 1.

When we _measure_ the qubit in the computational basis, the outcome is 0 with probability |α|² and 1 with probability |β|². After measurement, the state collapses to whichever outcome we obtained. This probabilistic collapse is the crucial feature that makes eavesdropping detectable: you cannot extract information about a qubit without disturbing it.

**The No-Cloning Theorem** is another essential principle. It states that it is impossible to create an identical copy of an unknown quantum state. Formally, there is no unitary transformation U such that U(|ψ⟩ ⊗ |0⟩) = |ψ⟩ ⊗ |ψ⟩ for all |ψ⟩. This is a direct consequence of the linearity of quantum mechanics. For classical key distribution, cloning is irrelevant; an eavesdropper could copy a classical bit stream without disturbing it. But in the quantum world, eavesdropping necessarily introduces detectable errors.

The final piece we need is the idea of **incompatible bases**. In BB84, we use two different bases: the rectilinear basis (+, which polarizes light horizontally/vertically – corresponding to the computational basis) and the diagonal basis (×, which polarizes light at ±45° – corresponding to the Hadamard basis). A state prepared in one basis yields a random outcome 50% of the time if measured in the other basis.

For example, let the rectilinear basis states be |0⟩ (horizontal) and |1⟩ (vertical). The diagonal basis states are |+⟩ = (|0⟩+|1⟩)/√2 and |−⟩ = (|0⟩−|1⟩)/√2. Measuring |+⟩ in the rectilinear basis gives 0 or 1 each with probability 1/2. This mismatch is the core of BB84’s eavesdropping detection.

---

## Part 3: The BB84 Protocol – Step by Step

BB84 is elegantly simple. Alice (the sender) wants to share a secret key with Bob (the receiver). They have a quantum channel (e.g., an optical fibre) and a public classical channel (e.g., the internet). Here are the steps:

**Step 1: Preparation and Transmission.**  
Alice generates a random string of bits (say 1000 bits). For each bit, she randomly chooses one of the two bases (rectilinear or diagonal) to encode that bit. She sends the corresponding qubit (photon) to Bob via the quantum channel. In practice, she might send each qubit as a weak laser pulse that approximates a single photon.

**Step 2: Measurement.**  
For each received qubit, Bob randomly chooses which basis to measure in. He records the measurement outcome and the basis he used.

**Step 3: Sifting.**  
After all qubits have been transmitted and measured, Bob announces over the classical channel which basis he used for each qubit (but not the outcome). Alice reveals which basis she used. They keep only those bits where their bases match. All other bits are discarded. This leaves a string of raw key bits of length roughly half the original (because they will agree 50% of the time by random chance – actually 50% of the total bits survive after matching).

**Step 4: Error Rate Estimation.**  
Alice and Bob now compare a random subset of their raw key bits (say 100 bits) over the classical channel. They compute the quantum bit error rate (QBER) – the fraction of bits that differ. In the absence of eavesdropping and noise, this should be very low (limited by detector noise, misalignment, etc.). If the QBER is higher than a threshold (typically around 11% for BB84), they abort. Otherwise, they proceed.

**Step 5: Information Reconciliation (Error Correction).**  
Even if the QBER is low, there will still be some errors. Alice and Bob need to reconcile their bit strings – i.e., correct the errors while leaking as little information as possible to an eavesdropper (Eve). This is done using an interactive error correction protocol, typically the **Cascade** algorithm or a low-density parity-check (LDPC) code. They exchange extra parity information over the classical channel; Eve may observe these exchanges, so we must account for the leaked bits in the next step.

**Step 6: Privacy Amplification.**  
Finally, Alice and Bob have two identical strings that are almost secure, but Eve might have partial information about them (both from her eavesdropping on the quantum channel and from listening to the classical reconciliation exchanges). Privacy amplification shrinks the key to eliminate Eve’s knowledge. They apply a randomly chosen universal hash function to their reconciled bit string, mapping it to a shorter string. With high probability, Eve’s mutual information with the final key is negligible.

Now let’s unravel each of these steps in detail, with the mathematics underpinning them.

---

## Part 4: Eavesdropping Detection – Why Intercept‑Resend Fails

Suppose Eve wants to learn Alice’s key. She has only one option: intercept the qubits on their way from Alice to Bob, measure them, then send a replacement qubit to Bob. But because she doesn’t know which basis Alice used, she must guess. Suppose she guesses the rectilinear basis when Alice used the diagonal basis. Eve’s measurement will collapse the qubit to either |0⟩ or |1⟩ (one of the rectilinear basis states), but then she sends that collapsed state to Bob. When Bob measures in the correct diagonal basis (if he happened to choose that basis), his outcome will be random (50/50) regardless of what Alice originally sent. When they later compare a sample, this introduces errors.

Let’s compute the error rate caused by a straightforward intercept-resend attack. Assume Alice sends a qubit in basis A (either + or ×) with bit value b. For each qubit:

- With probability 1/2, Eve guesses the correct basis. She measures b correctly and resends the same state. Bob’s measurement (if he chooses the same basis as Alice) will recover b correctly. No error.
- With probability 1/2, Eve guesses the wrong basis. She obtains a random bit c (uniform 0 or 1). She resends a state encoding c in the wrong basis. Now, when Bob measures in the correct basis (which he will with probability 1/2 – but remember we only keep bits where his basis matches Alice’s), he will get the correct bit with probability 1/2 (since the state is in the wrong basis) and the wrong bit with probability 1/2. So, among the sifted bits that Bob keeps, the error rate contributed by Eve’s attack is (1/2)(1/2) = 1/4.

But there is also a probability that Eve chooses the wrong basis and Bob also chooses the wrong basis – those bits are discarded in sifting anyway. So the overall QBER introduced by a full intercept-resend attack on the sifted key is 25%.

The actual QBER in a real system also includes background noise and detector dark counts, typically a few percent. A QBER above 11% is dangerous because the mutual information between Alice and Bob becomes less than that between Alice and Eve, making privacy amplification impossible. But below 11%, the protocol can still produce a secure key after error correction and privacy amplification.

**Formal security condition**  
Let I(A:B) be the mutual information between Alice and Bob after measurements, and I(A:E) be the mutual information between Alice and Eve. For a perfect key, we need I(A:E) = 0 and I(A:B) = 1 (perfect correlation). In practice, after sifting, the raw key has some QBER ε. The optimal collective attack by Eve yields I(A:E) = h₂(ε), where h₂(x) = –x log₂ x – (1–x) log₂(1–x) is the binary entropy function. Similarly, I(A:B) = 1 – h₂(ε). The condition for being able to distill a secure key is that the gap I(A:B) – I(A:E) > 0, i.e., 1 – 2h₂(ε) > 0, which gives ε < 0.11 (approx). This is why 11% is the standard threshold.

Thus, eavesdropping detection is not just about noticing an anomaly; it is a quantitative trade-off between errors and information leakage.

---

## Part 5: Information Reconciliation – The Cascade Protocol

After sifting, Alice and Bob have two bit strings A and B of length n (let’s say n = 1000). They are highly correlated but not identical. Eve may have partial information about A and also about the error correction process. To correct the errors, they need to exchange information over the public classical channel, but they must reveal as little as possible.

The most common approach is the **Cascade** protocol (proposed by Brassard and Salvail in 1993). It is an iterative, interactive error correction algorithm that exploits the ability to correct errors block by block.

**Initial step: Block division.**  
Alice and Bob divide their strings into blocks of a certain size k₁ (often chosen as k₁ = 0.73 / QBER). For each block, they compute and compare the parity. If the parities match, they assume the block is error-free (with high probability). If parities differ, they know an odd number of errors exists. They then perform a binary search within that block to locate and correct exactly one error. (Binary search: split the block, compare parities of halves, go to the half with odd parity, repeat.)

**Iterative step: Shuffling.**  
After the first pass, some errors may remain (e.g., an even number of errors in a block would give matching parities and go undetected). So the protocol shuffles the bits (using a shared random permutation) and repeats the block division with a larger block size. This is done multiple times until the error rate is driven down to zero (or negligible).

**Information leakage.**  
Each parity comparison reveals one bit of parity. In the worst-case scenario of a 10% error rate, Cascade leaks about 1.2–1.5 bits per corrected bit. The total number of leaked bits is L. These bits are known to Eve and must be accounted for in privacy amplification.

Formally, the reconciled string has length n, but Eve knows L bits of it. In the next step we shrink the key to eliminate that information.

---

## Part 6: Privacy Amplification – Universal Hashing

Privacy amplification is a technique from classical information theory. Alice and Bob have a shared string X of length n (after reconciliation), but Eve may have some side information about X: she knows a random variable Z (e.g., the parity bits leaked). We want to produce a shorter string Y of length m such that Eve’s mutual information I(Y;Z) is negligibly small.

The tool is a **universal hash function family**. A family ℌ of functions from {0,1}ⁿ to {0,1}ᵐ is called _universal_ if for any distinct x₁, x₂ ∈ {0,1}ⁿ, the probability that a randomly chosen h ∈ ℌ gives h(x₁) = h(x₂) is at most 1/2ᵐ.

Alice and Bob publicly agree on a random hash function h from ℌ (they can do this over the classical channel because even if Eve knows h, the security holds). Then they compute Y = h(X). The length m is chosen based on the amount of information Eve might have. A standard formula: m = n – t – s, where t is an upper bound on the number of bits Eve knows (including bits from eavesdropping and reconciliation leakage) and s is a security parameter (e.g., 100 bits). Then the probability that Eve can guess the entire key Y after observing Z is at most 2^(–s).

**Why universal hashing works:**  
The leftover hash lemma (LHL) states that if X has min-entropy at least k given Z (i.e., Hₘᵢₙ(X|Z) ≥ k), and we apply a universal hash function to produce an output of length m ≤ k – 2 log(1/ε), then the output is ε-close to uniform given Z. In QKD, the min-entropy of the raw key after sifting and reconciliation can be bounded by the QBER and the number of leaked bits.

Typically, an implementation of privacy amplification uses a well-known family of functions: for each bit of the output, we take a random linear combination of the input bits over GF(2). This corresponds to multiplying the input vector by a random binary matrix of size m × n. This is efficient and provably universal.

After privacy amplification, Alice and Bob share a final key of length m bits, which is (computational security aside) information-theoretically secure. The key can then be used for one-time pad encryption or as a seed for a symmetric cipher.

---

## Part 7: Security Proofs – Beyond Intercept‑Resend

The toy model of intercept‑resend is inadequate for a rigorous security proof. Eve can perform any operation allowed by quantum mechanics, including coherent attacks across multiple qubits, delaying measurements, or entangling her ancilla with the qubits. The core of modern QKD security theory is to show that BB84 is secure against arbitrary eavesdropping strategies, provided the QBER is below a certain threshold.

The security proof can be broken into two main approaches:

**Eberhard–Holevo bound approach (Shor–Preskill proof).**  
In 2000, Shor and Preskill gave an elegant proof that BB84 is secure by using the idea of **entanglement distillation**. They imagined that instead of sending a qubit, Alice and Bob share an entangled pair (e.g., a Bell state). Alice and Bob each measure their half in a basis they choose, obtaining correlated results. This is equivalent to the prepare‑and‑measure BB84, but now the protocol can be analysed using the tools of quantum error correction. The security reduces to the condition that the error rate is below the threshold of a certain quantum error correcting code (the 5‑qubit code). This yields the famous result: ε < 0.11.

**Complementarity argument (Koashi).**  
Another method uses the complementarity of measurements. The idea is that if the bits are correctly measured in the ± basis, then the phase information in the × basis cannot be too corrupted. This gives an upper bound on the information Eve can obtain. This approach yields the same threshold.

**Finite‑key effects.**  
In practice, we have only a finite number of qubits. The statistical fluctuations in the error rate and in the sample size affect the achievable key length. A detailed finite‑key analysis (e.g., by Scarani et al.) gives formulas for the secure key rate as a function of block length and QBER. For short blocks, security parameters must be larger, reducing the final key length. For example, with 10^6 qubits and 1% QBER, the secure key rate is roughly 0.5 bits per sifted qubit. As block size grows, the rate approaches the asymptotic limit.

---

## Part 8: Real-World Implementation – Challenges and Solutions

The beautiful theory of BB84 must contend with the messy reality of experimental physics. The two major problems are **photon loss** and **phony‑state attacks**.

**Photon loss:** Fibre optics attenuate photons; for every kilometre, about 0.2 dB loss (if using standard telecom fibre at 1550 nm). After 100 km, almost 99% of photons are lost. This forces the use of single‑photon detectors with high efficiency and low dark count. Also, because Alice uses weak laser pulses, there is a non‑zero probability of sending multiple photons. Eve can exploit this by performing a _photon number splitting (PNS) attack_: she blocks single‑photon pulses, splits the multi‑photon pulses, keeps one copy for herself, and forwards the other to Bob. She then waits until the basis reconciliation to measure her copy, learning the bit with no error. This effectively breaks the security.

**Solution – decoy state protocol:** To defeat the PNS attack, Alice sends not just the signal states (with mean photon number μ) but also decoy states with different intensities (e.g., ν = 0.2, and vacuum). By comparing the yields and error rates of different intensities, Bob can estimate how many of the multi‑photon pulses contributed. The decoy state protocol (invented by Lo, Ma, and Chen, 2005) restores the security of BB84 with weak coherent sources, achieving experimental key rates over 100 km of fibre.

**Distance limitations:** Even with decoy states, the secure key rate drops exponentially with distance due to loss. For ground‑based fibre, maximum secure distance is around 400 km (some experiments up to 500 km). To go global, satellite‑based QKD is being developed. In 2017, the Chinese satellite Micius demonstrated QKD over 1200 km between ground stations, using the lower ambient noise of space. Since loss in free space scales with distance squared, not exponentially, satellite QKD is promising for intercontinental key exchange.

**Side‑channel attacks:** Real detectors are imperfect – they may have efficiency mismatches, afterpulses, or be vulnerable to bright light blindness. A famous attack exploited the fact that the detectors’ efficiency depends on the polarization of the incoming light, allowing Eve to trick Bob into registering clicks only for her chosen bits. Countermeasures include the use of measurement‑device‑independent QKD (MDI‑QKD), which removes all detector side channels by having Bob measure in a way that does not reveal which basis he used.

---

## Part 9: Conclusion – The Quantum Future

We have come full circle. The mathematics that once comforted us – that factoring large numbers is hard – is now being unsettled by the very physics we sought to ignore. Quantum key distribution offers a way out: a method for two parties to generate a shared secret key whose security is guaranteed by the laws of quantum mechanics, not by computational complexity.

But QKD is not a panacea. It cannot authenticate the public channel, it requires a physical infrastructure (either fibre or satellite), and it cannot solve the problem of storing secrets for long periods (since the keys are ephemeral). It is also not a replacement for public‑key cryptography; rather, it is a complementary technology for distributing symmetric keys, which can then be used with one‑time pads or block ciphers.

The real power of QKD lies in its provable security against any future technological advance. No matter how powerful quantum computers become, they cannot break the security of a key distributed via BB84, because the security does not depend on computational hardness. It depends on the fact that Eve cannot copy an unknown quantum state, and any measurement disturbs it.

The biggest lie in security, then, is not that classical cryptography works – it works very well for most purposes today. The lie is that we can ignore the quantum nature of the universe forever. The quantum future is coming, and QKD is one of the first technologies that turns that future into an advantage rather than a threat.

As computer scientists, we must understand both the potential and the limitations. The next generation of secure systems will likely be hybrid: classical public‑key infrastructure for authentication, quantum key distribution for freshness, and classical symmetric ciphers for bulk encryption. The mathematics of QKD – including the subtle interplay of quantum measurement, information theory, and cryptography – will be at the heart of our new security paradigm.

If you think the internet is broken today, wait until a large‑scale quantum computer arrives. But if you understand the mathematics of BB84, you already know one way to fix it.
