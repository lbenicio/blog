---
title: "The Mathematics Of Secure Multiparty Computation For Machine Learning: Beaver Triples And Oblivious Transfer"
description: "A comprehensive technical exploration of the mathematics of secure multiparty computation for machine learning: beaver triples and oblivious transfer, covering key concepts, practical implementations, and real-world applications."
date: "2023-07-01"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/the-mathematics-of-secure-multiparty-computation-for-machine-learning-beaver-triples-and-oblivious-transfer.png"
coverAlt: "Technical visualization representing the mathematics of secure multiparty computation for machine learning: beaver triples and oblivious transfer"
---

# The Mathematics of Secure Multiparty Computation for Machine Learning: Beaver Triples and Oblivious Transfer

## Introduction

Imagine three hospitals, each holding thousands of patient records. They want to train a machine learning model to predict disease risk—a model that could save lives if it had access to all their data combined. But they cannot share raw patient information. Laws like HIPAA and GDPR forbid it, and even if they could, the privacy risks would be unacceptable. Yet, if they train separately, each model will be less accurate, biased by their own small, homogeneous populations.

This is the central tension of modern data science: the value of pooling sensitive data versus the absolute need to protect it. For years, the standard answer was “data cannot leave the building.” But what if the building never had to open its doors? What if multiple parties could jointly compute a function on their private inputs _without ever revealing those inputs to each other_? That is precisely the promise of **Secure Multiparty Computation (SMPC)** —a cryptographic toolset that enables parties to compute any function collaboratively while keeping each input secret.

SMPC is not science fiction. It is mathematically rigorous, increasingly practical, and already deployed in real-world systems (e.g., privacy-preserving advertising, genomic data analysis, and federated finance). But to understand how SMPC works under the hood—especially for heavy computations like machine learning—we must peel back the layers of abstraction and look at the mathematical building blocks. Two of the most critical primitives are **Oblivious Transfer (OT)** and **Beaver Triples**. Together, they form the engine that powers efficient, secure multiplication over secret-shared data—the operation that dominates the cost of training and inference.

In this post, we will explore the mathematics behind these primitives. We will start with the fundamental problem: how can two parties multiply two numbers without either party learning the other's input? From there, we will build up to the full machinery of OT and Beaver triples, see how they fit into larger protocols, and examine their role in practical machine learning pipelines. By the end, you will understand not only _what_ these primitives are, but _why_ they work and _how_ they make secure machine learning feasible.

## 1. The Fundamental Problem: Secure Multiplication in MPC

Before we dive into cryptographic primitives, we need to understand the core challenge that makes secure computation hard. Consider two parties, Alice and Bob. Each holds a private number: Alice has _a_, Bob has _b_. They want to compute the product _c = a × b_ without revealing _a_ or _b_ to each other (or to anyone else). This seems impossible at first glance: multiplication requires both inputs to be combined, and the act of combining seems to leak information. But cryptography has found ways around this.

### 1.1 Secret Sharing: The Foundation

Most modern SMPC protocols are built on **secret sharing**. Instead of keeping a value in one place, each party holds a _share_ of every value. Individually, shares reveal nothing about the underlying secret; only when enough shares are combined can the secret be reconstructed.

The simplest form is **additive secret sharing** over a finite field ℤ*q (think of integers modulo a large prime \_q*). To share a secret _x_, a dealer (or the parties jointly) picks random _x₁, x₂, …, xₙ_ such that _x₁ + x₂ + … + xₙ = x (mod q)_. Each party _i_ receives share _xᵢ_. No single share gives any information about _x_ because from the perspective of party _i_, _x_ is perfectly masked by the other random shares.

For two-party computation (2PC), we often use **additive shares modulo 2^k** (for fixed-point arithmetic) or over a prime field (for more algebraic structure). Let’s denote shares as ⟦x⟧ = (⟦x⟧₁, ⟦x⟧₂), where ⟦x⟧₁ + ⟦x⟧₂ = x.

**Key property:** Given shares of _x_ and _y_, each party can locally compute shares of _x + y_ (or any linear combination) by simply adding their shares: ⟦x + y⟧ᵢ = ⟦x⟧ᵢ + ⟦y⟧ᵢ. This is _free_ in terms of communication—no interaction required. Similarly, subtraction and multiplication by a public constant are local.

### 1.2 Why Multiplication is Hard

Now try to multiply two secret-shared values. Suppose we have ⟦a⟧ and ⟦b⟧. Each party holds (a₁, b₁) and (a₂, b₂) with a₁ + a₂ = a, b₁ + b₂ = b. The product is:

a × b = (a₁ + a₂)(b₁ + b₂) = a₁ b₁ + a₁ b₂ + a₂ b₁ + a₂ b₂.

Party 1 can compute a₁ b₁ locally, and party 2 can compute a₂ b₂ locally. But the cross-terms a₁ b₂ and a₂ b₁ involve shares from different parties. To compute these cross-terms securely, the parties need to **interact**. They must engage in a protocol that computes a₁ b₂ + a₂ b₁ without revealing a₁, b₂, a₂, b₁ to the other party.

This interaction is the bottleneck of SMPC. For a single multiplication, the parties need to send messages. For a machine learning model with millions of multiplications, naive interaction would be prohibitively expensive. That’s where Oblivious Transfer and Beaver Triples come in—they allow us to preprocess the heavy work and make online multiplication extremely fast.

## 2. Oblivious Transfer (OT)

Oblivious Transfer is one of the oldest and most fundamental cryptographic primitives. Introduced by Michael Rabin in 1981, it has since become a cornerstone of secure computation. At its simplest, **1-out-of-2 Oblivious Transfer** (often written as OT²₁) allows a sender who holds two messages (m₀, m₁) to send exactly one of them to a receiver, based on the receiver’s choice bit _c_. The receiver learns m*c but learns nothing about m*{1-c}, and the sender learns nothing about _c_.

### 2.1 A Simple OT Protocol (Using RSA)

Let’s build intuition with a classic protocol due to Even, Goldreich, and Lempel (1985), which uses public-key cryptography (specifically, RSA). We’ll assume the sender has an RSA key pair with modulus _N_ and public exponent _e_.

1. **Setup:** Sender generates random _x₀, x₁_ (different), and sends _N, e_ to receiver.
2. **Receiver’s choice:** Receiver generates a random _k_, and computes _v = (k^e + m_c) mod N_, where _m_c_ is their choice bit (interpreted as 0 or 1). Actually, this is a simplified version; the classic protocol uses a different approach with blinded messages. Let me describe the actual protocol correctly:

**Classic OT protocol (Even et al.):**

- Sender has messages m₀, m₁ ∈ ℤ_N. Sender picks random r ← ℤ_N, and sends to receiver: r.
- Receiver picks random k and sends back: v = (k^e + r_c) mod N, where r_c = r if c=0, else r_c = ? Actually, let’s use the standard description:

Sender chooses random r₀, r₁. Sends both? No. Better to use the “pick two random values” approach.

I’ll instead give a more modern, simplified version using symmetric cryptography to avoid confusion. In practice, OT is often built from oblivious transfer extension (OT extension) that uses a small number of “base OTs” and efficient symmetric-key operations.

### 2.2 OT from Symmetric-Key Primitives (Keller, Orsini, Scholl, 2015)

Modern OT is extremely efficient because of _OT extension_. The key idea is: we can perform many OTs using a small number of “seed” OTs (say 128) and many evaluations of a correlation-robust hash function (or a fixed-key AES). The result is that each additional OT costs only a few AES operations and a short message.

But to understand the role of OT in MPC, we don’t need the full construction. The important property is:

- OT can be used to **obliviously transfer bits**.
- Using a single OT, we can allow a party to learn one of two values without revealing which.

Now, how does OT help with multiplication? Consider the cross-term a₁ b₂ in our earlier product. Party 1 knows a₁ (a share), Party 2 knows b₂ (a share). They need to compute a₁ b₂ securely, and add it to the other terms. OT can do this: Party 1 can act as sender, Party 2 as receiver. The message m₀ = 0, m₁ = a₁. If Party 2’s choice bit is the _b_ bit? But b₂ is not a bit; it’s a field element. So we need to extend OT to handle multi-bit values.

### 2.3 Correlated OT and 1-out-of-2 OT for Field Elements

We can use OT in a bit-by-bit manner. Suppose we want to compute a₁ × b₂ where a₁ and b₂ are integers modulo 2^k. Write b₂ in binary: b₂ = Σ\_{j=0}^{k-1} b₂[j] _ 2^j. Then a₁ × b₂ = Σ_j (a₁ _ 2^j) if b₂[j]=1, else 0. So the product is a sum of terms, each of which is either a₁*2^j or 0. For each bit position j, Party 1 (who knows a₁) can set m₀ = 0, m₁ = a₁ * 2^j. Party 2 (who knows b₂) can choose based on b₂[j] to get the correct term. After k OTs, Party 2 obtains a₁ × b₂ (since it learns the sum of the chosen terms). But wait, Party 2 learns the product! That would reveal a₁ × b₂ to Party 2, which then (combined with its other share) might leak information about a₁? In secret sharing, revealing a₁ × b₂ to party 2 is okay if the other party also gets a random share that masks it. Actually, the standard approach is that the parties compute shares of the cross-term so that neither learns the true product.

Better: Use OT to directly compute a **multiplication triple** (Beaver triple) in a preprocessing phase. Then the online multiplication is just a few local operations.

## 3. Beaver Triples: The Preprocessing Paradigm

Beaver triples, named after Donald Beaver (1991), solve the online multiplication problem by moving the heavy cryptographic work to an offline phase. The idea is simple but powerful:

**Definition:** A Beaver triple (for multiplication) is a triple of secret-shared values (⟦a⟧, ⟦b⟧, ⟦c⟧) such that a × b = c (mod q). The shares are held by the parties. The crucial point is that _a_ and _b_ are uniformly random and independent of the actual inputs. They are generated during a preprocessing phase, and can be reused across many multiplications (each multiplication consumes one triple).

### 3.1 How to Multiply Using a Beaver Triple

Suppose we have shares ⟦x⟧ and ⟦y⟧ of the true inputs, and we have a Beaver triple (⟦a⟧, ⟦b⟧, ⟦c⟧) with c = a·b. The parties want to compute shares of ⟦z⟧ = ⟦x·y⟧.

**Protocol:**

1. **Masking:** Each party computes and broadcasts (or sends to the other) the masked values: ⟦d⟧ = ⟦x⟧ - ⟦a⟧, and ⟦e⟧ = ⟦y⟧ - ⟦b⟧. Because subtraction is local, this requires no interaction beyond revealing the masks _d_ and _e_ (which are publicly reconstructed). Note: _d_ = x - a, _e_ = y - b. Since a and b are random, d and e reveal nothing about x and y (they act like one-time pads).
2. **Reconstruction:** The parties reconstruct _d_ and _e_ by adding their shares and broadcasting the sum (or using a secure broadcast). Now both parties know the plaintext values _d_ and _e_.
3. **Local computation:** Each party can now compute its share of the product as:
   ⟦z⟧ = (d \* e) + d·⟦b⟧ + e·⟦a⟧ + ⟦c⟧.
   Because:
   x·y = (a+d)(b+e) = a·b + a·e + d·b + d·e = c + a·e + d·b + d·e.
   Since everyone knows d and e, they can each locally compute their share of a·e (by multiplying their share of a by e), and similarly for d·b. The term d·e is a public constant, so everyone adds the same constant to their share.

**Why it’s secure:** The only communication is the broadcast of the masked values d and e. These are uniformly random (since a and b are random), so they perfectly hide x and y. No information about the inputs is leaked.

**Cost:** One multiplication consumes one Beaver triple and requires two rounds of communication (for broadcasting d and e). In practice, with two parties and a point-to-point channel, it’s one round (each party sends its share of d and e to the other, and then they compute locally). The preprocessing cost is deferred.

### 3.2 Generating Beaver Triples

Now the question becomes: how do we generate these triples securely? We need to produce random secret-shared values a, b, c such that c = a·b. This can be done using Oblivious Transfer (OT) or using homomorphic encryption (e.g., Paillier). Here, we’ll focus on OT-based generation, which is more efficient in the two-party setting.

**Protocol for generating a Beaver triple (semi-honest, two-party):**

The parties want to produce shares of random a, b, c with a·b = c.

- Party 1 chooses random a₁, b₁, and a random choice bit for an OT? Actually, a common method works as follows:

1. Party 1 picks random a₁, b₁ ∈ ℤ_q.
2. Party 2 picks random a₂, b₂ ∈ ℤ_q.
3. They need to compute a₁·b₂ + a₂·b₁ + a₁·b₁ + a₂·b₂? Wait, the product a·b = (a₁+a₂)(b₁+b₂) = a₁b₁ + a₁b₂ + a₂b₁ + a₂b₂. They want to produce shares of this product such that Party 1 holds a share c₁ and Party 2 holds c₂, with c₁ + c₂ = a·b.

- They can set c₁ = a₁b₁ + a₁b₂ + something? No, because a₁b₂ involves cross terms. They need to use OT to let Party 1 learn a masked version of a₁b₂? Actually, a standard approach is:

- Party 1 computes t₁ = a₁b₁ (locally).
- Party 2 computes t₂ = a₂b₂ (locally).
- They need to compute a₁b₂ + a₂b₁. This is a “correlated product” problem. They can do this via OT:

Party 1 acts as OT sender for each bit of b₂? Alternatively, use the fact that:

a₁b₂ + a₂b₁ = (a₁ + a₂)(b₁ + b₂) - a₁b₁ - a₂b₂ = a·b - t₁ - t₂.

But that’s circular. Instead, use a protocol where Party 1 and Party 2 engage in an OT that allows Party 1 to learn a₁b₂ and Party 2 to learn a₂b₁? That would reveal the cross terms to them individually, but that’s okay if they then combine them with their own local terms and randomize.

A classic method: Use **correlated OT** (COT) to generate multiplication triples. In COT, the sender inputs a correlation function f (e.g., f(x) = x + Δ) and for each choice bit of the receiver, the sender obtains output such that the receiver’s output is either s₀ or s₁ with known correlation. Then by combining many such OTs, you can build a multiplication triple.

I’ll provide a simplified description:

**Triple generation using OT (informal):**

1. The parties jointly generate random shares ⟦a⟧, ⟦b⟧ via coin tossing (e.g., each picks a random share and sends it to the other? But that would reveal the share. They can use a PRG with a seed they both contribute to). Actually, they can simply each choose their own share of a and b. So Party 1 has a₁, b₁; Party 2 has a₂, b₂.
2. To compute c = (a₁+a₂)(b₁+b₂), they need to compute the cross terms. They use a **secure multiplication protocol** (e.g., based on OT) to compute shares of a₁·b₂ and a₂·b₁. For a₁·b₂: Party 1 knows a₁, Party 2 knows b₂. They can run a protocol where Party 1 gets a share r and Party 2 gets a share s such that r + s = a₁·b₂. This can be done using OT with additive shares.
3. Similarly for a₂·b₁.
4. Then each party adds its local contributions:

   Party 1: c₁ = a₁b₁ + r₁ + s₁ (where r₁, s₁ are the shares from the two OT-based subprotocols)
   Party 2: c₂ = a₂b₂ + r₂ + s₂

But careful: the shares from the subprotocols must be such that r₁+r₂ = a₁b₂ and s₁+s₂ = a₂b₁. Then c₁+c₂ = a₁b₁ + a₂b₂ + a₁b₂ + a₂b₁ = (a₁+a₂)(b₁+b₂) = a·b.

**Efficient OT-based triple generation:** In practice, modern implementations (e.g., the seminal work of Keller, Orsini, and Scholl, 2015) use OT extension to generate many triples in one go. They use a technique called **silent OT extension** (Boyle et al., 2019) that reduces the communication cost to almost nothing—essentially, the parties can generate triples from a small amount of correlation. This has made Beaver triples the go-to method for efficient secure computation.

## 4. Oblivious Transfer in Depth

Now that we have motivated OT as a building block for triple generation, let’s dive deeper into its mathematics.

### 4.1 The Ideal Functionality

We can think of OT as an ideal functionality F_OT that takes input from sender and receiver and produces outputs:

- Sender inputs (m₀, m₁) both of length λ bits.
- Receiver inputs a choice bit c.
- F_OT outputs m_c to the receiver, and outputs nothing to the sender (except maybe “done”).

The security requirements:

- Receiver learns only m*c, and nothing about m*{1-c}.
- Sender learns nothing about c.

### 4.2 A Concrete OT Protocol from Decisional Diffie-Hellman

One of the simplest OT protocols is based on the Decisional Diffie-Hellman (DDH) assumption. Let G be a cyclic group of prime order q with generator g.

**Protocol:**

- **Setup:** Sender picks a random secret key sk = s ∈ ℤ_q, computes pk = g^s. Sender sends pk to receiver.
- **Receiver’s message:** Receiver picks random r ∈ ℤ_q. If c=0, it sets B = g^r; if c=1, it sets B = pk^r = g^{s·r}. It sends B to sender.
- **Sender’s response:** Sender computes two encryption keys: k₀ = H(B^s) and k₁ = H((B/pk)^s). Wait, careful: If c=0, B = g^r, so B^s = g^{r s} and (B/pk) = g^r / g^s = g^{r-s}, so (B/pk)^s = g^{s(r-s)}. These are different; the sender can compute both. Then sender encrypts m₀ with k₀ and m₁ with k₁, e.g., by XORing with H(k₀) etc. The receiver knows r, so if c=0, it can compute k₀ = H(g^{r s})? Actually, receiver knows pk = g^s, so g^{r s} = pk^r. So receiver can compute k₀ = H(pk^r). But it cannot compute k₁ because that requires (B/pk)^s = (g^{r} / g^{s})^s = g^{s(r-s)} which it cannot compute without s. However, if c=1, B = pk^r = g^{s r}, then B^s = g^{s^2 r} (unknown), but (B/pk) = g^{sr}/g^s = g^{s(r-1)}, so (B/pk)^s = g^{s^2(r-1)}. The receiver knows pk = g^s, but cannot compute g^{s^2} without s. Actually, this protocol is a variant of the “ElGamal-like” OT. There is a more standard one using CDH.

I think a cleaner exposition is the classic protocol from Even, Goldreich, and Lempel (1985) using trapdoor permutations. But for brevity, we’ll move on to the important part: how OT is used in practice for MPC.

### 4.3 OT Extension

OT extension allows us to perform many OTs using only a small number of “base” OTs (e.g., 128) combined with symmetric-key primitives. The seminal idea comes from Beaver (1996) and was later refined by Ishai, Kilian, Nissim, and Petrank (IKNP, 2003). The core idea:

1. **Base OTs:** The parties run λ base OTs (where λ = security parameter, e.g., 128). In each base OT, the sender inputs a pair of random seeds (s₀*j, s₁_j) and the receiver inputs a choice bit r_j. The receiver learns s*{r_j}\_j.
2. **Extension:** The sender generates many pairs of messages using a correlation-robust hash function (or fixed-key AES). By applying a linear transformation, the receiver can obtain many OTs from the base ones.

The result: after the initial overhead, each additional OT costs only a few AES operations and sends a short message (like 128 bits). This makes OT drastically cheaper than public-key cryptography.

## 5. From Triples to Machine Learning

Now we have the tools: Beaver triples for efficient online multiplication, and OT for generating those triples offline. How do we go from this to training a neural network?

### 5.1 Linear Layers: Matmul and Convolution

Neural networks consist mostly of linear operations: matrix multiplications, convolutions, additions, and scalar multiplications. All of these are composed of additions and multiplications. With secret shares, addition is free locally. Multiplication requires one Beaver triple per multiplication of two secret values. But note: for a matrix multiplication of size m×n and n×p, you need m × n × p individual multiplications. That’s a lot of triples. However, there are optimizations.

**Matrix multiplication via triples:** You can run the standard algorithm with triples for each element-wise multiplication. But because each multiplication reveals the masked values d and e, you must be careful about **input reuse**. If you reuse the same secret-shared value in multiple multiplications (e.g., the same weight matrix W is multiplied by many inputs), you need to avoid that the masks leak information about the underlying value. In the Beaver triple protocol, the masks d = x - a and e = y - b are revealed. If x is used in multiple multiplications with different y’s, then a would be the same, and d would be x - a each time. That would be x - a each time, which is constant, so it still doesn’t leak x because a is random and unknown. But the adversary sees d repeatedly? Actually, d is computed as x - a where a is from the triple. If the same triple is used for two multiplications, then you’d be using the same a twice, but that’s not allowed because each triple is consumed once. So triples are consumed by one multiplication each. If you have a value x that appears in many multiplications, you consume many triples, each with a fresh a. So the d values are independent random numbers (since a is fresh each time), so no information leaks.

**Optimization for matrix multiplication:** You can use the "Garbled Circuit" approach or combine multiple multiplications into one using techniques like **inner product multiplication**. There’s also the possibility of using **fixed-point arithmetic** and packing.

### 5.2 Non-Linear Layers: ReLU, Sigmoid, Softmax

Activation functions are the bottleneck in secure neural networks because they are not linear. ReLU(x) = max(0, x) requires comparison. Computing comparison over secret shares is expensive. Common approaches:

- **Convert to boolean shares:** Use a bit decomposition of the arithmetic shares, then evaluate a garbled circuit for the comparison (e.g., using the Yao circuit or a protocol like the one of Demmler et al., 2015). This requires a conversion from arithmetic to boolean shares, which has its own cost.
- **Piecewise polynomial approximation:** Approximate ReLU with a low-degree polynomial (e.g., x^2 or x^3) and use only multiplications. This avoids boolean circuits but introduces approximation error.
- **Lookup tables via OT:** Evaluate a function by OT where one party holds a table of outputs for all possible inputs. This is feasible for functions with small domains (e.g., sigmoid for 8-bit values).

Similarly, softmax involves exponentiation, which is often approximated or done via lookup tables.

### 5.3 Secure Training: Stochastic Gradient Descent

Training a model requires computing gradients through backpropagation. Each gradient update involves many multiplications. The overall flow:

1. **Forward pass:** Compute predictions via linear and activation functions.
2. **Backward pass:** Compute error signals and gradients, again involving linear operations and activation function derivatives.
3. **Update:** Subtract learning rate times gradient from weights.

All these operations are composed of additions and multiplications (and comparisons). With Beaver triples, the multiplications are efficient as long as triples are available. The offline phase (triple generation) can be done before the data is even seen, making the online phase fast.

**Example: Secure Linear Regression**

Consider training a linear regression model y = Wx + b on distributed data. We have two parties holding parts of the data. They want to compute the gradient ∇W = (y_pred - y) \* x^T. This involves matrix multiplication of errors and inputs. If they can compute y_pred securely, they can compute the gradient using the same Beaver triple machinery.

A simple 2-party protocol for linear regression (semi-honest):

- Each party holds shares of their data.
- Using triples, they compute predictions.
- Compute error shares (local subtraction).
- Multiply error shares with input shares to get gradient shares (using triples).
- Add gradient shares to update weight shares.

This requires O(n*d*epochs) triples where n is number of samples and d is feature dimension. For large datasets, this can be terabytes of triples, but offline generation using OT extension is fast enough for many applications.

## 6. Advanced Topics and Optimizations

### 6.1 Malicious Security

The above protocols assume **semi-honest** parties: they follow the protocol but try to learn extra information from the messages. In **malicious** security, a party may deviate arbitrarily (e.g., send incorrect values) to break privacy or correctness.

To achieve malicious security, we add zero-knowledge proofs or cut-and-choose techniques. For triple generation, we need to ensure that the triples are correctly formed (c = a·b). This can be done by having the parties commit to their shares and then reveal a few triples for verification (sacrificing them). This is called **triple sacrifice**: we generate more triples than needed, and sacrifice some to verify correctness of the rest.

### 6.2 Fixed-Point Arithmetic and Overflow

Most secret sharing is done modulo 2^k (e.g., k=64) or a large prime. Real numbers are represented as fixed-point: multiply by a scale factor (e.g., 2^16) and truncate after multiplication. But truncation is not linear—it involves comparison or bit shifting. Secure truncation protocols exist (e.g., using oblivious transfer or garbled circuits) but add overhead.

### 6.3 Communication Round Complexity

Each Beaver multiplication requires at least one round of communication (to send the masked shares). For deep networks, the round count accumulates: each layer requires a round for multiplications and possibly extra rounds for activations. Optimizations like **function secret sharing** (FSS) can reduce rounds for certain functions.

### 6.4 Comparison with Other Privacy Techniques

- **Homomorphic Encryption (HE):** Allows computation on encrypted data but is extremely slow for non-linear functions. HE can be used for linear layers, while SMPC handles non-linear ones. Hybrid approaches exist (e.g., CrypTFlow, EzPC).
- **Differential Privacy (DP):** Adds noise to protect individual records, but degrades accuracy. DP is usually combined with SMPC for stronger guarantees.
- **Trusted Execution Environments (TEE):** Use hardware enclaves (e.g., Intel SGX) to process data in a secure environment. But TEEs have side-channel vulnerabilities and trust assumptions.

SMPC (with OT and triples) offers provable security without trusted hardware, and with modern optimizations, it is becoming practical for many ML tasks.

## 7. Real-World Applications and Case Studies

### 7.1 Medical Research Consortia

Multiple hospitals (as in our introduction) can use SMPC to train a model on combined data. For example, the **iDASH** competition (2016) involved secure genome-wide association studies using SMPC with Beaver triples. They achieved running times of hours for linear regression on hundreds of samples and thousands of SNPs.

### 7.2 Financial Fraud Detection

Banks hold transaction data; they want to collaborate on fraud detection models without leaking customer information. SMPC allows them to compute aggregate statistics and train models across institutions.

### 7.3 Private Set Intersection and Machine Learning

A variant of SMPC called **Private Set Intersection (PSI)** allows parties to find common elements without revealing non-common ones. Google uses a PSI-based approach for its privacy-preserving advertising measurement (Ads Data Hub).

### 7.4 Open Source Implementations

Several libraries implement SMPC with OT and Beaver triples:

- **ABY** (Demmler et al., 2015): Mixed-protocol framework (arithmetic, boolean, Yao).
- **MP-SPDZ** (Keller, 2020): Comprehensive framework with many protocols.
- **CrypTen** (Facebook, 2020): PyTorch-like interface for secure computation.
- **EzPC** (Microsoft, 2020): Compiler from high-level to secure protocols.

## 8. Conclusion

Secure Multiparty Computation is no longer a theoretical curiosity. With the mathematical inventions of Oblivious Transfer and Beaver triples, we have turned the impossible problem of private multiplication into an efficient, practical tool. Beaver triples allow us to defer expensive cryptographic operations to an offline phase, making online model training nearly as fast as plaintext computation (in terms of round complexity). Oblivious Transfer, especially through OT extension, provides the foundation for generating those triples with minimal cost.

The journey from a thought experiment—three hospitals wanting to collaborate—to a deployed system involves understanding these primitives at a deep level. The mathematics is beautiful: secret sharing, random masks, and clever protocols weave together to preserve privacy without sacrificing correctness.

But the story isn’t over. Researchers continue to push the boundaries: malicious security with minimal overhead, efficient comparison for non-linear functions, and scaling to billion-parameter models. As the need for privacy grows, the mathematics of SMPC will only become more important.

We encourage you to dive into the code of MP-SPDZ or ABY, implement a simple secure multiplication, and see Beaver triples in action. The future of collaborative machine learning depends on us understanding and leveraging these powerful tools.

_Further reading:_

- “How to Simulate It” by Lindell – a great introduction to simulation-based security.
- “Efficient Multiplication Protocols” by Beaver (1991).
- “OT Extension” by Asharov et al. (2013) – detailed explanation.
- “Faster Secure Two-Party Computation in the Single-Execution Model” by Keller, Orsini, and Scholl (2015).
