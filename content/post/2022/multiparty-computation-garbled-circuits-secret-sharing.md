---
title: "Multi-Party Computation: From Yao's Garbled Circuits to the SPDZ Line"
description: "A deep exploration of secure multi-party computation, tracing the intellectual arc from Yao's millionaires' problem through the SPDZ practical framework, with full protocol detail and modern applications."
date: "2022-12-26"
author: "Leonardo Benicio"
tags: ["mpc", "garbled-circuits", "secret-sharing", "spdz", "secure-computation"]
categories: ["theory", "systems"]
draft: false
cover: "/static/assets/images/blog/multiparty-computation-garbled-circuits-secret-sharing.png"
coverAlt: "Diagram showing multiple parties connected by secure computation protocol arrows, with Boolean and arithmetic circuit representations."
---

Imagine you and nine colleagues want to compute the average salary in the room without anyone learning anyone else's salary. Or imagine five hospitals want to train a diagnostic model on their pooled patient records without ever moving those records from their respective data centers. Or imagine a financial consortium that wants to detect money laundering across its member banks without any bank exposing its customer list. These are not thought experiments; they are the motivating use cases for secure multi-party computation (MPC), a field that has moved, in roughly forty years, from a theoretical curiosity to an engineering discipline with deployed systems protecting billions of dollars in assets.

The central question of MPC is deceptively simple: can \(n\) parties, each holding a private input \(x_i\), jointly compute a function \(f(x_1, \ldots, x_n)\) such that no party learns anything beyond what can be inferred from the output? The question was first posed by Andrew Yao in 1982, framed through what he called the "millionaires' problem": two millionaires want to know who is richer without revealing their actual wealth. The answer turned out to be yes—and the techniques developed to achieve it now underpin threshold signature schemes used in Ethereum validators, privacy-preserving machine learning, sealed-bid auctions, and secure DNS resolution.

This article traces the intellectual arc of MPC from its foundations through the practical frameworks that make it deployable today. We will build everything from first principles: the two fundamental paradigms (Boolean-circuit-based and arithmetic-circuit-based), the crucial technique of secret sharing, the transformation from passive to active security, and the engineering breakthroughs that brought MPC from gigabit circuits to real applications. Along the way we will encounter some of the most elegant constructions in all of cryptography, including Shamir's polynomial-based secret sharing, Yao's garbled circuits, the GMW protocol, the BGW protocol, and the SPDZ line of works that finally made MPC practical.

## 1. The Two Paradigms: Boolean Circuits and Arithmetic Circuits

Before diving into specific protocols, it is essential to understand the two representational frameworks in which MPC protocols operate. Every function that can be computed can be represented as a circuit, but the choice of circuit model fundamentally determines which cryptographic techniques are available and what the performance characteristics will be.

The Boolean circuit model represents a computation as a directed acyclic graph of logic gates—AND, OR, NOT, XOR—operating on single bits. This is the natural representation for any computation because every digital computation ultimately reduces to Boolean logic. In the Boolean model, an MPC protocol must evaluate each gate securely: given secret-shared or encrypted representations of the two input bits, produce a secret-shared or encrypted representation of the output bit, without revealing the intermediate values. The prototypical Boolean-circuit protocol is Yao's garbled circuits, which we will examine in depth shortly.

The arithmetic circuit model, by contrast, represents computation as a graph of addition and multiplication gates over a finite field \(\mathbb{F}\_p\) (typically a large prime, say 256 bits). Each wire carries a field element rather than a single bit, and gates perform modular addition and multiplication. This model is natural for computations that involve arithmetic—statistical calculations, linear algebra, polynomial evaluation, and, critically, the inner loops of machine learning. The prototypical arithmetic-circuit protocol is the BGW protocol, which uses Shamir secret sharing to evaluate addition gates "for free" (locally, without interaction) and multiplication gates via a degree-reduction step that requires communication.

The performance tradeoff between the two models is stark and defines the landscape of practical MPC. Boolean circuits excel at bitwise operations: comparisons, AES encryption, SHA-256 hashing. Arithmetic circuits excel at numerical computation: matrix multiplication, dot products, convolutions. A modern MPC practitioner chooses the circuit model based on the computation's "natural shape." If the computation is a deep neural network, arithmetic circuits with SPDZ-style preprocessed multiplication triples will dominate. If the computation is threshold ECDSA signing—which involves a single inversion and a couple of multiplications modulo the curve order, plus bit-decompositions of secret shared values—the picture becomes more nuanced, and many real systems combine both paradigms in a single protocol.

Understanding why addition is free in Shamir-based MPC while AND requires interaction in GMW-style secret-sharing-based MPC is the key insight that unlocks the design space. Let us now build the foundational primitives from the ground up.

## 2. Secret Sharing: The Arithmetic Foundation

Secret sharing is the mechanism by which a secret value is distributed among multiple parties such that no individual party (or coalition below a threshold) can reconstruct the secret, while the full set of authorized parties can. The two schemes that matter for MPC are additive secret sharing and Shamir's threshold secret sharing. Additive secret sharing is the simpler construction and forms the basis of the GMW and SPDZ protocols. Shamir's scheme enables the information-theoretic security of BGW.

### 2.1 Additive Secret Sharing

In an \(n\)-party additive secret sharing scheme over a field \(\mathbb{F}\), a secret \(s \in \mathbb{F}\) is shared by choosing \(n-1\) uniformly random field elements \(r*1, r_2, \ldots, r*{n-1} \in \mathbb{F}\) and setting the \(n\)-th share to \(s - \sum*{i=1}^{n-1} r_i\). Party \(P_i\) receives share \([s]\_i = r_i\) (with \([s]\_n = s - \sum*{i=1}^{n-1} r*i\) for the last party). Reconstruction is trivial: \(s = \sum*{i=1}^n [s]\_i\).

The crucial property is that any set of fewer than \(n\) shares reveals nothing about \(s\). Given \(n-1\) shares, the missing share could be any value in \(\mathbb{F}\), and for each candidate value there is exactly one choice of the \(n\)-th random value that would produce that share, making all secrets equally likely. This is information-theoretic (perfect) security.

Additive secret sharing is linear, meaning that if parties hold shares \([a]\_i\) and \([b]\_i\), they can compute shares of \([a+b]\_i = [a]\_i + [b]\_i\) by local addition, with no communication. Similarly, \([a \cdot c]\_i = c \cdot [a]\_i\) for any public constant \(c\). Multiplication of two secret-shared values, however, requires interaction.

### 2.2 Shamir's Threshold Secret Sharing

Shamir's scheme, introduced in 1979, generalizes additive sharing to support arbitrary thresholds. To share a secret \(s\) with threshold \(t\) (meaning any \(t+1\) parties can reconstruct but any \(t\) or fewer learn nothing), one samples a random polynomial \(p(x)\) of degree \(t\) such that \(p(0) = s\). The polynomial is:

\[
p(x) = s + a_1 x + a_2 x^2 + \cdots + a_t x^t
\]

where each \(a_i\) is chosen uniformly at random from the field. Party \(P_i\) receives share \(p(\alpha_i)\) where \(\alpha_1, \alpha_2, \ldots, \alpha_n\) are distinct, non-zero, publicly known evaluation points. Reconstruction uses Lagrange interpolation: any \(t+1\) points uniquely determine the degree-\(t\) polynomial, and the secret is recovered by evaluating the interpolated polynomial at \(x=0\):

\[
s = \sum\_{i \in S} \lambda_i \cdot p(\alpha_i)
\]

where the Lagrange coefficients \(\lambda_i\) are public values that depend only on the set \(S\) of reconstructing parties:

\[
\lambda*i = \prod*{j \in S, j \neq i} \frac{-\alpha_j}{\alpha_i - \alpha_j}
\]

The beauty of Shamir sharing is that it is also linear: adding shares pointwise produces shares of a polynomial whose constant term is the sum of the two secrets. The degree of the sum polynomial is the maximum of the degrees of the two summand polynomials, which means that if we start with degree-\(t\) shares, the sum shares are also degree-\(t\). Multiplication, however, creates a polynomial of degree \(2t\) (the product of two degree-\(t\) polynomials), and reducing the degree back to \(t\) requires interaction—this is the degree-reduction step at the heart of the BGW protocol, which we discuss in Section 5.

## 3. Yao's Garbled Circuits: The Boolean Paradigm

Yao's garbled circuits protocol, introduced in 1986, solves the two-party case with security against semi-honest (passive) adversaries. Despite its age, it remains one of the most practically efficient approaches for two-party computation, especially for Boolean-heavy computations. The protocol is asymmetric: one party (the "garbler") constructs an encrypted version of the circuit, and the other party (the "evaluator") evaluates it without learning any intermediate values.

### 3.1 The Garbling Construction

Let the function \(f\) be represented as a Boolean circuit with gates of fan-in two. For each wire \(w\) in the circuit, the garbler generates two random \(\kappa\)-bit labels (typically \(\kappa = 128\) for computational security): \(k_w^0\) representing the value 0 on that wire, and \(k_w^1\) representing the value 1. These labels serve dual purposes: they encode the wire's value and they serve as keys for decrypting downstream gates.

For each gate \(g\) with input wires \(u, v\) and output wire \(w\), computing the Boolean function \(g: \{0,1\}^2 \to \{0,1\}\), the garbler constructs a garbled truth table. For each of the four possible input combinations \((a, b) \in \{0,1\}^2\), the garbler encrypts the output label \(k_w^{g(a,b)}\) under the two input labels \(k_u^a\) and \(k_v^b\):

\[
\text{Enc}_{k_u^a}(\text{Enc}_{k_v^b}(k_w^{g(a,b)}))
\]

The encryption is typically instantiated using a pseudorandom function (PRF) or, more efficiently, using the free-XOR and half-gate optimizations that we will discuss. The four ciphertexts are randomly permuted so that the evaluator, who knows only one pair of input labels (corresponding to the actual wire values), can decrypt exactly one entry and learn the corresponding output label—but cannot determine which entry she decrypted or what the other possible output label is.

### 3.2 Protocol Execution

The protocol proceeds as follows:

1. **Garbling:** The garbler constructs the garbled circuit as described and sends it to the evaluator, along with the garbled input labels corresponding to the garbler's own input bits.

2. **Oblivious Transfer for Evaluator's Input:** For each bit of the evaluator's input \(y*j\), the evaluator needs to obtain \(k*{input_j}^{y_j}\) without the garbler learning which label was chosen (and thus \(y_j\)). This is accomplished using 1-out-of-2 oblivious transfer (OT): the garbler inputs the two labels, the evaluator inputs her choice bit, and the evaluator receives the chosen label while the garbler learns nothing. OT is the only cryptographic primitive that Yao's protocol requires beyond symmetric-key operations.

3. **Evaluation:** The evaluator, now possessing one label per input wire, evaluates the circuit gate by gate. For each gate, she attempts to decrypt all four ciphertexts using her two input labels; exactly one decryption will succeed (in practice, a format check—such as a string of zeros appended to the plaintext—tells her which decryption is valid). She obtains the output label for the gate and proceeds. At the final output gates, the garbler provides a mapping from output labels to plaintext bits (e.g., a table saying "label X means 0, label Y means 1").

4. **Output Delivery:** The evaluator sends the garbled output labels to the garbler, who decodes them and sends the plaintext output. (In variants where only the evaluator learns the output, the output decoding table suffices.)

### 3.3 Optimizations: Free-XOR, Half-Gates, and Row Reduction

The original Yao construction required four ciphertexts per gate. Decades of optimization have reduced this to the point where XOR gates are "free" (require no ciphertexts and no communication) and AND gates require only two ciphertexts (or 1.5 ciphertexts in the half-gates construction).

The **free-XOR** technique (Kolesnikov and Schneider, 2008) exploits the following insight: set the wire labels so that \(k_w^1 = k_w^0 \oplus \Delta\) for every wire \(w\), where \(\Delta\) is a global random offset known only to the garbler. Now consider an XOR gate with inputs \(u, v\) and output \(w = u \oplus v\). The evaluator holds \(k_u^a = k_u^0 \oplus a\Delta\) and \(k_v^b = k_v^0 \oplus b\Delta\). She can compute the output label by XORing her input labels:

\[
k_u^a \oplus k_v^b = (k_u^0 \oplus a\Delta) \oplus (k_v^0 \oplus b\Delta) = (k_u^0 \oplus k_v^0) \oplus (a \oplus b)\Delta
\]

If the garbler has set \(k_w^0 = k_u^0 \oplus k_v^0\), then \(k_w^{a \oplus b} = k_w^0 \oplus (a \oplus b)\Delta\), which is exactly the XOR of the input labels. No ciphertexts needed, no communication beyond the initial circuit transmission.

The **half-gates** technique (Zahur, Rosulek, and Evans, 2015) reduces AND gates to two ciphertexts by decomposing each AND gate into two "half-gates" where one input is known to one party. The resulting garbled AND gate requires only two rows instead of four. Combined with free-XOR, the total cost for an AND gate is \(2\kappa\) bits of communication, which is essentially optimal for this approach.

**Row reduction** (Naor, Pinkas, and Sumner, 1999) reduces the four ciphertexts of a standard gate to three by noting that the first ciphertext can be fixed to all zeros by choosing the output label appropriately, eliminating the need to transmit it.

With all optimizations applied, modern garbled circuit implementations can evaluate roughly \(10^7\) AND gates per second on a single core, making them viable for moderate-sized computations.

### 3.4 Security and Limitations

Yao's protocol in the semi-honest model is secure under the assumption that the PRF used for encryption is a pseudorandom permutation, or more generally that the encryption satisfies the notion of "privacy" (indistinguishability of the garbled circuit and the evaluator's view from a simulation). The construction's security reduces to the security of the underlying symmetric primitives and the oblivious transfer protocol.

The protocol's main limitations are that it is inherently two-party, that it is interactive (the OTs require communication before evaluation begins), and that it is not reusable: each evaluation consumes a fresh garbled circuit. Extensions to the multi-party case exist—most notably the BMR (Beaver-Micali-Rogaway) construction, which lets multiple parties jointly garble the circuit—but these are significantly more complex.

Despite these limitations, garbled circuits remain the method of choice for two-party Boolean computations, and they form a crucial component in many mixed-protocol MPC systems where Boolean sub-computations (such as comparisons in an otherwise arithmetic protocol) are offloaded to garbled circuits.

## 4. The GMW Protocol: Secret-Sharing-Based Boolean MPC

Oded Goldreich, Silvio Micali, and Avi Wigderson published the GMW protocol in 1987, demonstrating that any polynomial-time computable function can be securely computed by \(n\) parties, tolerating a dishonest majority, assuming the existence of oblivious transfer. Unlike Yao's construction, which handles two parties via asymmetric garbling, GMW works for any number of parties by representing the computation as a Boolean circuit and evaluating it gate by gate using additive secret sharing and interaction.

### 4.1 The GMW Structure

Parties begin by additively secret-sharing their inputs: party \(P*i\) with input bit \(x_i\) distributes random shares \([x_i]\_1, \ldots, [x_i]\_n\) such that \(x_i = \bigoplus*{j=1}^n [x_i]\_j\) (where \(\oplus\) is XOR, equivalent to addition mod 2). The invariant is that at every stage of the computation, for every wire in the circuit, the parties hold additive shares of the wire's value.

**NOT gates** are trivial: since additive sharing over GF(2) is linear, each party can negate their share locally. Party 1 negates its share; all other parties keep theirs unchanged. The result is a valid sharing of the negated bit.

**XOR gates** are equally trivial: each party XORs its shares of the two input wires locally. No interaction.

**AND gates** are the non-trivial case. Given shares of bits \(a\) and \(b\), the parties must compute shares of \(a \land b = ab\). The algebraic identity:

\[
ab = \left(\bigoplus*i a_i\right) \land \left(\bigoplus_j b_j\right) = \bigoplus*{i,j} a_i b_j
\]

shows that the AND of the shared values depends on cross-terms \(a_i b_j\) for \(i \neq j\). Each party \(P_i\) can compute \(a_i b_i\) locally (this is his contribution to the sum), but the cross-terms require cooperation. Specifically, for each pair \((i,j)\) with \(i \neq j\), parties \(P_i\) and \(P_j\) must jointly compute shares of \(a_i b_j\) without revealing \(a_i\) or \(b_j\). This is where oblivious transfer comes in: \(P_i\) and \(P_j\) run a 1-out-of-2 OT protocol where \(P_i\) inputs \(a_i\) and the two candidate values, and \(P_j\) inputs \(b_j\), obtaining a share of the product. Because OT requires only two parties, we need \({n \choose 2}\) OTs per AND gate—one for each unordered pair of parties.

After the cross-term computation, each party sums the shares they hold (their local \(a_i b_i\) plus all the cross-term shares they received) to obtain their share of the output wire.

### 4.2 From Semi-Honest to Malicious Security

The basic GMW protocol is secure only against semi-honest adversaries. Upgrading to malicious security requires ensuring that parties follow the protocol correctly. The approach, systematized in the "GMW compiler," adds two ingredients: commitment schemes and zero-knowledge proofs.

After each step, parties commit to their internal state. For steps that involve randomness (like the OT invocations for cross-terms), parties must prove in zero-knowledge that they followed the prescribed procedure. In practice, this approach is prohibitively expensive, and modern maliciously secure Boolean MPC protocols (such as those based on the "TinyOT" or "SPDZ-style" MAC techniques) use information-theoretic MACs instead of zero-knowledge proofs. We cover these in the SPDZ section.

### 4.3 Significance and Legacy

The GMW protocol's significance is primarily theoretical: it proves that secure computation is possible for any polynomial function without an honest majority, closing a foundational question in cryptography. The constant-round version of GMW (where the depth of the circuit determines the round complexity) and its parallel variants established the round-complexity landscape for MPC.

In practice, GMW's per-gate cost—quadratic in the number of parties—makes it unsuitable for large-scale computation. However, its central idea of evaluating circuits via secret sharing with interaction for nonlinear gates became the template for all subsequent secret-sharing-based MPC, including the far more practical SPDZ family.

## 5. The BGW Protocol: Arithmetic MPC with Honest Majority

The BGW protocol, named for its authors Michael Ben-Or, Shafi Goldwasser, and Avi Wigderson (1988), takes a radically different approach. Instead of operating on Boolean circuits with dishonest majority, BGW operates on arithmetic circuits over a finite field and achieves information-theoretic security against a passive adversary controlling fewer than \(n/2\) parties (or, with a broadcast channel, against an active adversary controlling fewer than \(n/3\)).

### 5.1 Shamir Sharing and the Degree Problem

The key observation of BGW is that Shamir's secret sharing scheme is not merely a way to store secrets but a way to compute on them. If each party holds a share \(p(\alpha_i)\) of a polynomial \(p(x)\) of degree \(t\), then for any linear function of the shared secrets, the parties can evaluate locally by applying the function to their shares. Addition: if \(s_a\) is shared via polynomial \(a(x)\) and \(s_b\) via polynomial \(b(x)\), then party \(P_i\) computes \(a(\alpha_i) + b(\alpha_i)\), which is a point on the polynomial \((a+b)(x)\). Since \(\deg(a+b) \leq \max(\deg(a), \deg(b)) = t\), the degree bound is maintained. Multiplication by a public constant works similarly.

The challenge is multiplication. If \(s_a\) and \(s_b\) are shared via degree-\(t\) polynomials \(a(x)\) and \(b(x)\), then party \(P_i\) can locally multiply his shares to obtain \(a(\alpha_i) \cdot b(\alpha_i)\), which is a point on the polynomial \((a \cdot b)(x)\). However, \(\deg(a \cdot b) = 2t\). If \(2t \geq n\), then \(2t+1\) points are needed to uniquely determine the product polynomial, but we only have \(n\) points total, and if the adversary controls up to \(t\) parties, the \(n-t\) honest parties' shares are insufficient to reconstruct. Moreover, even if reconstruction were possible (which would require \(2t < n\)), the product polynomial is not random: its coefficients are not uniformly distributed, which would leak information about the inputs.

### 5.2 The Degree-Reduction Step

BGW solves this with a degree-reduction subprotocol that transforms \(2t\)-degree shares of a product into \(t\)-degree shares of the same secret, maintaining the invariant that all secrets are shared via degree-\(t\) polynomials.

After local multiplication, the parties hold shares of a degree-\(2t\) polynomial \(c(x)\) where \(c(0) = s_a \cdot s_b\). The degree-reduction proceeds in two phases:

**Phase 1: Re-sharing.** Each party \(P_i\) takes his share \(c(\alpha_i)\) and independently shares it using a fresh degree-\(t\) polynomial \(r_i(x)\) with \(r_i(0) = c(\alpha_i)\). Party \(P_i\) sends \(r_i(\alpha_j)\) to party \(P_j\) for each \(j\). After this step, party \(P_j\) holds the values \(r_1(\alpha_j), r_2(\alpha_j), \ldots, r_n(\alpha_j)\).

**Phase 2: Lagrange interpolation in the exponent.** Define the vector \(R = (r_1(0), r_2(0), \ldots, r_n(0)) = (c(\alpha_1), c(\alpha_2), \ldots, c(\alpha_n))\). This is a vector of points on the degree-\(2t\) polynomial \(c(x)\). Since \(2t < n\) (the honest majority condition), the value \(c(0) = s_a \cdot s_b\) can be expressed as a linear combination of the \(c(\alpha_i)\) via Lagrange interpolation:

\[
c(0) = \sum\_{i=1}^n \lambda_i \cdot c(\alpha_i)
\]

where \(\lambda_i\) are the Lagrange coefficients for interpolation at 0. Crucially, these coefficients are public and can be computed by all parties. Party \(P_j\) can now compute his share of the degree-reduced representation as:

\[
[c(0)]_j = \sum_{i=1}^n \lambda_i \cdot r_i(\alpha_j)
\]

Because each \(r_i(x)\) has degree \(t\) and \(\lambda_i\) are public scalars, the resulting polynomial \(\sum_i \lambda_i \cdot r_i(x)\) has degree \(t\), with constant term \(c(0) = s_a \cdot s_b\). The degree reduction is complete.

### 5.3 Security Thresholds

The BGW protocol's security thresholds are fundamental results:

- **Passive adversary, \(t < n/2\):** The protocol achieves perfect (information-theoretic) security. The \(n/2\) bound is tight; if the adversary controls half or more of the parties, it can reconstruct shared secrets.

- **Active adversary, \(t < n/3\):** With a broadcast channel, the protocol can be made secure against malicious adversaries controlling fewer than one-third of the parties. The \(n/3\) bound is tight for perfect security without cryptography; it traces back to the Byzantine agreement lower bound.

The gap between \(n/2\) (passive) and \(n/3\) (active) arises because detecting and correcting malicious behavior requires sufficient redundancy in the honest majority. With \(t < n/2\), the honest parties can always reconstruct the correct value (since any \(t+1\) correct shares determine the right polynomial), but a malicious party could send inconsistent shares during degree reduction, causing incorrect reconstruction. With \(t < n/3\), the honest parties have enough margin to both detect and correct such inconsistencies. The BGW paper provides error-correction techniques based on the Berlekamp-Welch algorithm for decoding Reed-Solomon codes.

### 5.4 Practical Considerations

Despite its elegance and information-theoretic security, BGW has limitations that make it less attractive than cryptographic alternatives for many applications. The degree-reduction step requires \(O(n^2)\) communication per multiplication, which becomes prohibitive for large party counts. Moreover, the honest-majority requirement excludes the important two-party case and the general dishonest-majority setting.

However, BGW's core technique—secret-shared computation on arithmetic circuits with degree reduction—is the direct ancestor of the SPDZ family, which we will see replaces the expensive degree-reduction step with preprocessed multiplication triples (Beaver triples), dramatically reducing online communication while retaining the arithmetic-circuit efficiency.

## 6. The SPDZ Line: Practical MPC with Preprocessing

The SPDZ line of protocols (pronounced "Speedz"), initiated by Damgård, Pastro, Smart, and Zakarias in 2012, represents the most successful effort to date at making MPC practical for dishonest-majority settings. The key innovations are the use of **message authentication codes (MACs)** to achieve active security at low cost, and a **preprocessing model** that separates the protocol into an expensive, function-independent offline phase and a cheap, function-dependent online phase.

The name "SPDZ" comes from the authors' initials, and the line has evolved through many variants: SPDZ-2 (MASCOT, 2016), Overdrive (2017), SPDZ2k (2018), and several optimizations for low-latency and RAM-based computation.

### 6.1 The MAC-Based Approach to Active Security

The central problem in dishonest-majority MPC is that a malicious party can lie about its shares. In the semi-honest setting, parties follow the protocol; in the malicious setting, a corrupted party might send a share that does not correspond to any valid secret sharing, effectively injecting errors into the computation. The SPDZ solution is to authenticate each secret-shared value with an information-theoretic MAC, shared among the parties in a way that prevents the adversary from forging a MAC on an incorrect value.

Concretely, each secret value \(x \in \mathbb{F}\_p\) is represented as a triple of shares:

- **Value shares:** \([x] = (x_1, \ldots, x_n)\) where \(x = \sum_i x_i\).
- **MAC shares:** \([\gamma(x)] = (\gamma(x)\_1, \ldots, \gamma(x)\_n)\) where \(\sum_i \gamma(x)\_i = \alpha \cdot x\).
- **Global MAC key:** \(\alpha\) is a random field element, itself secret-shared as \([\alpha]\) among the parties.

The invariant is that \(\alpha \cdot x = \sum_i \gamma(x)\_i \pmod{p}\). When parties open a value \(x\), they also open the MAC shares and verify that \(\alpha \cdot x\) matches the opened MAC. Critically, \(\alpha\) is never reconstructed during the protocol; it is only used in its shared form. An adversary who does not know \(\alpha\) cannot produce a valid MAC on an incorrect value except with probability \(1/p\), which is negligible for large \(p\) (e.g., \(p \approx 2^{128}\)).

The MAC is linear: if parties have authenticated shares of \(x\) and \(y\), and a public constant \(c\), they can compute authenticated shares of \(x + y\) and \(c \cdot x\) locally. Multiplication requires a preprocessed Beaver triple, which we now describe.

### 6.2 Beaver Triples and the Preprocessing Model

A **Beaver multiplication triple** is a triple of secret-shared values \(([a], [b], [c])\) such that \(c = a \cdot b\) and \(a, b\) are uniformly random and unknown to any party. These triples are the "fuel" that powers SPDZ online multiplication.

Given an authenticated Beaver triple \(([a], [b], [c])\), two authenticated shared values \([x]\) and \([y]\) can be multiplied as follows:

1. **Open masked values:** The parties reveal \(\epsilon = x - a\) and \(\delta = y - b\). Since \(a, b\) are random, \(\epsilon\) and \(\delta\) reveal nothing about \(x\) and \(y\) (they are one-time-pad encryptions). This opening involves checking MACs to ensure correctness.

2. **Local computation:** Each party computes:
   \[
   [z] = [c] + \epsilon \cdot [b] + \delta \cdot [a] + \epsilon \delta
   \]
   where \(\epsilon\) and \(\delta\) are now public. By the linearity of the secret sharing and MAC scheme, this yields a valid authenticated sharing of:
   \[
   z = c + \epsilon b + \delta a + \epsilon \delta = ab + (x-a)b + (y-b)a + (x-a)(y-b) = xy
   \]

The crucial point: the entire online multiplication requires only one round of communication (opening \(\epsilon\) and \(\delta\)), independent of the number of parties. This is in stark contrast to GMW's \(O(n^2)\) OTs per multiplication. The offline phase generates as many triples as the online phase will consume.

### 6.3 The Offline Phase: Generating Triples

The offline phase's job is to produce authenticated Beaver triples without correlating them with the eventual inputs. This is where the different SPDZ variants diverge.

**Original SPDZ** uses somewhat homomorphic encryption (SHE): party \(P_1\) generates triples by encrypting random values under an SHE scheme and having the other parties perform homomorphic operations to obtain shares. The computational cost is dominated by the SHE operations.

**MASCOT** (Keller, Orsini, and Scholl, 2016) replaces SHE with oblivious transfer, specifically correlated OT and random OT extensions. The key idea: a random OT allows two parties to obtain random values that satisfy a correlation, and by composing these correlations, full authenticated triples can be produced. MASCOT's offline phase runs at roughly 200,000 triples per second over a 10 Gbps network, sufficient for many applications.

**Overdrive** (Keller, Pastro, and Rotaru, 2018) improves on MASCOT by optimizing the triple generation for the case where the circuit contains many "sacrifice" triples (used for checking correctness). Overdrive introduces "semi-honest" preprocessing with a batch-check step that verifies many triples at once using random linear combinations, achieving amortized efficiency.

**SPDZ2k** targets the low-latency setting by operating modulo \(2^k\) rather than a prime, matching native CPU word sizes and eliminating modular arithmetic overhead. The MAC scheme is adapted to work modulo \(2^k\) with a security loss of at most \(\log_2 k\) bits, which is acceptable for \(k = 64\) or \(k = 128\).

### 6.4 The Online Phase: Circuit Evaluation

The online phase evaluates the arithmetic circuit layer by layer:

- **Addition gates:** Local computation, free.
- **Multiplication by constant:** Local computation, free.
- **Multiplication gates:** Consume one Beaver triple, one round of communication.
- **Input:** Input owner secret-shares his input, distributes shares with MACs.
- **Output:** Parties open the output value, verify MACs.

The online phase is remarkably efficient: for a circuit with \(M\) multiplications, the total communication is \(O(M \cdot n)\) field elements, with a very small constant. On a LAN, one multiplication round can complete in under a millisecond.

Because the online phase is circuit-independent until inputs are provided, it is possible to preprocess all the triples for a given function (say, an inference of a specific neural network) and then, when inputs arrive, evaluate with minimal latency. This separation is crucial for applications like privacy-preserving machine learning inference, where a client wants a prediction on their data without the server learning the data, and where the model weights are public (or shared among a consortium).

### 6.5 The SCALE-MAMBA System and Real-World Deployments

The SCALE-MAMBA system (2018) is the reference implementation of the SPDZ family, developed at the University of Bristol and Aarhus University. It compiles a high-level language (a Python-like DSL) into arithmetic circuits optimized for SPDZ's cost model. SCALE-MAMBA has been used in several notable deployments:

- **Boston Women's Workforce Council (2016):** A consortium of Boston-area companies used SPDZ-based MPC to compute the gender wage gap across their organizations without revealing individual firm data. This was one of the first real-world MPC deployments involving non-cryptographers.
- **Danish Sugar Beet Auction (2008):** Although predating SPDZ, this auction system used an earlier MPC protocol (based on BGW and Paillier encryption) to conduct a real sealed-bid auction among Danish farmers, demonstrating the feasibility of MPC for economic mechanisms.
- **Unbound Tech (now Coinbase):** MPC-based threshold signing, leveraging SPDZ-like protocols to protect private keys by splitting them among multiple servers, used by exchanges and custodians.
- **Privacy-Preserving Machine Learning:** Several systems (PySyft, TF Encrypted) use SPDZ-like protocols for private neural network inference.

The evolution continues. Recent work has pushed the online phase to sub-millisecond latency for moderate-sized circuits, making MPC viable for interactive applications. The combination of garbled circuits for Boolean sub-computations and SPDZ for arithmetic sub-computations—a "mixed protocol" approach—is the state of the art for many practical deployments.

## 7. Protocol Comparison and the Engineering Landscape

Let us step back and survey the landscape. The choice of MPC protocol depends on multiple interacting factors:

| Protocol | Parties | Threshold                 | Circuit Type | Active Security | Bottleneck                     |
| -------- | ------- | ------------------------- | ------------ | --------------- | ------------------------------ |
| Yao (GC) | 2       | Semi-honest               | Boolean      | With ZK proofs  | OTs, circuit size              |
| GMW      | n       | Dishonest majority        | Boolean      | With MACs/ZK    | \(O(n^2)\) OTs per AND         |
| BGW      | n       | Honest majority (\(n/2\)) | Arithmetic   | \(t < n/3\)     | Degree-reduction communication |
| SPDZ     | n       | Dishonest majority        | Arithmetic   | Yes (MACs)      | Triple generation (offline)    |

In practice, the dominant approaches for real deployments are:

1. **Two-party Boolean circuits** → Yao's garbled circuits with optimizations (free-XOR, half-gates). The most mature toolchain is the EMP-toolkit (Efficient Multi-Party computation Toolkit) from the University of Michigan and CMU.

2. **Multi-party arithmetic circuits with dishonest majority** → SPDZ family (SCALE-MAMBA, MP-SPDZ). This is the default for privacy-preserving ML and secure aggregation.

3. **Multi-party with honest majority (3-party or 4-party)** → Replicated secret sharing protocols (Araki et al., 2017; ABY3, 2018; Fantastic Four, 2021). These achieve incredible throughput—billions of multiplications per second—by exploiting the fact that with three parties and one corruption, replicated secret sharing (where each party holds two of the three additive shares) allows multiplication with minimal communication.

4. **Mixed protocols** → ABY (Demmler, Schneider, and Zohner, 2015) and MOTION (2020) combine Yao, GMW, and arithmetic sharing in a single framework, converting between representations as needed.

The engineering reality is that MPC is not a solved problem. Communication remains the dominant cost, and wide-area network (WAN) deployments with tens of milliseconds of latency are challenging. The constant factors in existing implementations are far from optimal: typical MPC evaluators achieve 50-100 AND gates per microsecond, while the underlying hardware could theoretically sustain thousands. This gap is closing through better engineering and through protocol innovations like function-dependent preprocessing and hardware acceleration of OT.

## 8. Beyond Semi-Honest: Covert Security and the Real Adversary Model

The semi-honest vs. malicious dichotomy simplifies a spectrum of adversarial behavior. In many practical settings, the threat model is neither fully passive nor fully active. **Covert security** (Aumann and Lindell, 2007) captures the idea that an adversary might cheat if she is certain not to get caught, and the protocol designer's goal is to ensure that any cheating attempt is detected with some specified probability \(\epsilon\). By setting \(\epsilon\) appropriately (say, \(1/2\) or \(99/100\)), the protocol gains a meaningful deterrent while remaining substantially more efficient than a fully malicious-secure protocol.

Covert security can be implemented efficiently in the SPDZ framework by reducing the number of MAC checks: instead of checking every opened value, spot-check a random subset. The adversary can cheat on unchecked values, but the probability of detection across an extended interaction can be made arbitrarily close to 1.

For the highest-assurance deployments—key management for financial systems, national security applications—fully malicious security with negligible error probability is the standard. The SPDZ MAC approach achieves this with concrete security loss of about \(\log_2 |\mathbb{F}|\) bits (typically ~128 bits), which is the standard cryptographic security parameter.

## 9. Applications and Case Studies

### 9.1 Threshold Signing for Blockchains

Ethereum's transition to proof-of-stake created a pressing need for distributed key management. Validators must sign blocks with their BLS private key, but storing the key on a single machine creates a single point of compromise. The solution: threshold BLS signatures generated via MPC.

In a threshold signing deployment, the private key \(sk\) is never assembled in one place. Instead, it is secret-shared among a set of signing nodes. When a message needs to be signed, the nodes run an MPC protocol that takes as input their shares of \(sk\) and the message \(m\), and outputs shares of the signature \(\sigma = H(m)^{sk}\). These shares are then combined (using Lagrange interpolation, since BLS signature aggregation is linear in the secret key) to produce the final signature.

The MPC protocol for BLS signing is particularly well-suited to the arithmetic-circuit model: the computation is essentially one hash-to-curve operation (Boolean-heavy, best done in garbled circuits or via specialized MPC-friendly hash functions) followed by an exponentiation (an arithmetic operation). The threshold signing MPC must be performed with low latency (sub-second) to keep up with the blockchain's slot time. This requirement has driven significant innovation in low-latency MPC, including the development of function-specific preprocessing and the use of pseudorandom correlation generators (PCGs) to compress the correlated randomness needed for triple generation.

### 9.2 Privacy-Preserving Machine Learning

The canonical PPML scenario has a model owner (say, a hospital with a trained diagnostic model) and a client (a patient) who wants a prediction without revealing their medical data. In the two-party setting, garbled circuits can evaluate the entire neural network inference, but the circuit size for a modern deep network (millions of ReLU activations) is prohibitive. The arithmetic approach with SPDZ is more scalable, but ReLU (which is essentially a comparison: \(x > 0 \;?\; x : 0\)) is awkward in arithmetic circuits because comparisons require bit decomposition.

The state of the art for PPML inference combines arithmetic sharing for the linear layers (matrix multiplications, which are just dot products) and garbled circuits or specialized comparison protocols for the nonlinear activations. The Delphi system (2020) from UC Berkeley and UT Austin uses neural architecture search to find model architectures that are both accurate and MPC-friendly (e.g., using quadratic activations \(x^2\) instead of ReLU, because squaring is just a multiplication).

For PPML _training_, the challenge is an order of magnitude harder because training requires many iterations over the data, and each iteration involves forward and backward passes. The ABY3 and Fantastic Four protocols, operating in the three-party honest-majority setting, have demonstrated training of modest neural networks (MNIST, CIFAR-10) at throughputs measured in millions of operations per second, making them the current frontier.

### 9.3 Private Set Intersection

Private Set Intersection (PSI) is the problem of two parties each holding a set wanting to compute the intersection without revealing anything else. PSI is a special case of MPC, but dedicated protocols vastly outperform generic MPC for this task.

The state-of-the-art PSI protocols use a combination of oblivious transfer and hashing. The most efficient approach for large sets (billions of items) is the "circuit-PSI" approach based on Cuckoo hashing and OT extension (Pinkas, Schneider, and Zohner, 2014, 2018). The idea: each party hashes their items into bins using Cuckoo hashing. Bins are then compared using OT-based string equality tests. The total cost is linear in the set size, with a small constant.

PSI has found applications in contact discovery (Signal's private contact discovery uses Intel SGX, but MPC-based alternatives have been proposed), advertising conversion measurement (Google and Meta's private join protocols for measuring ad effectiveness without cross-site tracking), and password breach detection (haveibeenpwned.com's private query protocol).

## 10. The Frontier: Information-Theoretic MPC and Continuous Improvements

The SPDZ framework uses cryptographic assumptions (OT, PRFs, symmetric encryption). But BGW shows that information-theoretic (unconditional) security is possible with an honest majority. Is information-theoretic MPC practical? For the three-party setting with one corruption, the answer is a resounding yes. The replicated secret sharing approach achieves throughput of \(10^9\) multiplications per second on a single core, with no cryptographic operations in the online phase. The preprocessing is done via correlated randomness (generated using PRGs, so the entire system relies on the PRG's security, but the online phase is information-theoretic).

For larger numbers of parties, information-theoretic MPC becomes communication-bound. The degree-reduction step in BGW requires \(O(n^2)\) communication per multiplication in the naive version, though this can be reduced to \(O(n)\) using packed secret sharing (where each share encodes multiple secrets via polynomial evaluation at multiple points). Even so, the constants are large, and cryptographic MPC with OT extension or somewhat homomorphic encryption generally outperforms information-theoretic MPC for more than a handful of parties.

An exciting recent direction is **pseudorandom correlation generators** (PCGs), which compress the correlated randomness needed for MPC into short seeds that can be expanded locally. The Boyle et al. construction of PCGs from the Learning Parity with Noise (LPN) assumption, and the subsequent improvements by Couteau et al., have the potential to make MPC preprocessing essentially communication-free: each party receives a short seed from a trusted dealer (or the dealer is emulated via MPC), and expands it locally into all the correlations needed for the online phase. When combined with silent OT (where the OT extension is done non-interactively using the same PCG technique), the communication cost of MPC can be driven down to the theoretical minimum: the online phase communicates only the masked values for multiplications and the final output.

## 11. Summary

Multi-party computation has travelled a remarkable arc. What began as Yao's philosophical question—can two millionaires compare their wealth without revealing it?—has become a technology that protects billions of dollars in cryptocurrency assets, enables privacy-preserving analytics across competing organizations, and promises to reshape how we think about data ownership in the age of machine learning.

The intellectual architecture of MPC rests on three pillars: the Boolean paradigm (Yao's garbled circuits, GMW), the arithmetic paradigm (BGW, Shamir-based computation), and the preprocessing paradigm (Beaver triples, SPDZ). Each paradigm responds to a different set of constraints—two-party vs. multi-party, honest majority vs. dishonest majority, Boolean-heavy vs. arithmetic-heavy computation—and the modern MPC engineer navigates among them, often combining multiple paradigms within a single system.

The SPDZ line, with its MAC-based active security and preprocessing model, has emerged as the most practical framework for dishonest-majority arithmetic MPC. Its online phase is simple, fast, and parallelizable; its offline phase, while computationally intensive, benefits from decades of optimization in OT extension, somewhat homomorphic encryption, and PCG-based compression. The SCALE-MAMBA system and its successors have reduced the barrier to entry from "PhD in cryptography" to "competent systems programmer," which may be the most significant achievement of all.

Looking forward, the convergence of MPC with hardware enclaves (TEEs like Intel SGX and AMD SEV), with zero-knowledge proofs (for verifiable computation on private data), and with differential privacy (for provable bounds on what the output reveals) suggests a future where privacy-preserving computation becomes a routine part of the systems stack. The millionaires' problem is solved. The challenge now is to make the solution as invisible and reliable as TLS—and the trajectory is promising.

The mathematical elegance of Shamir sharing, the engineering cleverness of garbled circuit optimizations, and the principled composition of the SPDZ MAC scheme all testify to a field that has produced not just results, but genuine intellectual beauty. For the systems researcher, MPC offers a particularly rich playground: protocol design must contend with network latency, memory hierarchy, parallelism, and the eternal tension between security and performance. For the theorist, it offers deep questions about the minimal assumptions needed for secure computation and the fundamental limits of what can be computed privately. And for the world beyond computer science, it offers a technical pathway toward a future where data can be useful without being exposed—a future in which privacy is not a policy afterthought but a mathematical guarantee.
