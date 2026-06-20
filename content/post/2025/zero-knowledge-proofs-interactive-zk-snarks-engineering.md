---
title: "Zero-Knowledge Proofs: From Interactive Protocols to zk-SNARKs and Practical Verifiable Computation"
description: "Build zero-knowledge proofs from the ground up: the simulation paradigm, Schnorr's protocol for discrete log, the transformation to non-interactive via Fiat-Shamir, and the engineering of modern zk-SNARKs for verifiable computation."
date: "2025-04-24"
author: "Leonardo Benicio"
tags: ["zero-knowledge", "cryptography", "zk-snarks", "interactive-proofs", "verifiable-computation", "blockchain"]
categories: ["theory", "cryptography"]
draft: false
cover: "/static/assets/images/blog/zero-knowledge-proofs-interactive-zk-snarks-engineering.png"
coverAlt: "Diagram showing a prover convincing a verifier of knowledge of a secret without revealing it, with the simulation paradigm represented as a thought bubble"
---

Imagine you want to prove to someone that you know the solution to a Sudoku puzzle — without revealing a single number of the solution. Or that you know a password — without transmitting the password or anything from which it could be derived. Or that a complex computation was executed correctly — without requiring the verifier to re-execute it. These are not parlor tricks. They are instances of zero-knowledge proofs (ZKPs), one of the most remarkable cryptographic primitives ever invented. A zero-knowledge proof allows a prover to convince a verifier of the truth of a statement while revealing _nothing_ beyond the fact that the statement is true. The verifier learns the single bit of information "the statement is true" and nothing else — not a hint, not a partial clue, not even information that could help a computationally unbounded adversary reconstruct the secret.

The theory of zero-knowledge proofs emerged in the mid-1980s from the work of Shafi Goldwasser, Silvio Micali, and Charles Rackoff, who introduced the concept in their 1985 paper "The Knowledge Complexity of Interactive Proof-Systems." Along with interactive proofs and probabilistically checkable proofs (which we explored in a previous post), zero-knowledge proofs form a trilogy of ideas that revolutionized our understanding of what can be proved and verified efficiently. In the decades since, ZKPs have evolved from a theoretical curiosity into a practical engineering discipline. Modern zk-SNARKs (Zero-Knowledge Succinct Non-interactive ARguments of Knowledge) enable proof generation and verification in milliseconds, with proof sizes of a few hundred bytes, independent of the complexity of the statement being proved. They are deployed in blockchain systems (Zcash, zk-rollups), in privacy-preserving identity systems, and in verifiable computation outsourcing.

This article will build zero-knowledge proofs from the ground up, starting with the foundational definitions, moving through classic interactive protocols (Schnorr, Graph Isomorphism), transitioning to non-interactive proofs via the Fiat-Shamir heuristic, and culminating in the engineering of modern zk-SNARKs, including Groth16, PLONK, and STARKs. We will emphasize both the mathematical beauty and the practical engineering challenges.

## 1. Defining zero-knowledge: the simulation paradigm

Before we can build zero-knowledge protocols, we must define what "zero-knowledge" actually means. The definition is subtle and took years to crystallize.

### 1.1 Interactive proof systems

An interactive proof system for a language \(L\) involves two parties: a prover \(P\) (computationally unbounded) and a verifier \(V\) (probabilistic polynomial-time). They interact for a polynomial number of rounds, after which \(V\) outputs "accept" or "reject." The system must satisfy:

- **Completeness**: If \(x \in L\), then the honest prover can convince the honest verifier to accept with probability at least \(2/3\).
- **Soundness**: If \(x \notin L\), then for every (possibly cheating) prover \(P^\*\), the verifier accepts with probability at most \(1/3\).

The constants \(2/3\) and \(1/3\) can be amplified arbitrarily by sequential repetition. The class IP of languages with interactive proofs equals PSPACE (Shamir, 1991), which means interactive proofs are remarkably powerful.

### 1.2 The zero-knowledge property

A proof system is _zero-knowledge_ if, for every polynomial-time verifier \(V^_\) (possibly cheating), there exists a polynomial-time simulator \(S\) such that for all \(x \in L\), the output distribution of \(S(x)\) is computationally indistinguishable from the transcript of the interaction between the honest prover \(P\) and \(V^_\) on input \(x\).

What does this mean intuitively? The simulator \(S\) can _produce a convincing transcript of the interaction without ever talking to the prover_ — and since the simulator has no access to the secret, the transcript cannot contain any information about the secret. If the verifier could extract any information from the real interaction, it could extract the same information from the simulated transcript, which by construction contains none. Therefore, the real interaction must reveal nothing beyond the truth of the statement.

This is called the _simulation paradigm_, and it is the gold standard definition of zero-knowledge. If the indistinguishability is perfect (the distributions are identical), we have _perfect zero-knowledge_. If it is statistical (negligible statistical distance), we have _statistical zero-knowledge_. If it is computational (no polynomial-time distinguisher can tell them apart), we have _computational zero-knowledge_.

### 1.3 An example: the Ali Baba cave

The classic intuition-building metaphor for zero-knowledge is the Ali Baba cave, due to Quisquater and Guillou. Peggy (the prover) knows the magic word to open a door at the back of a circular cave. Victor (the verifier) wants to verify that Peggy knows the word without learning it.

The protocol: Peggy enters the cave and randomly chooses path A or B to reach the door. Victor, standing at the entrance, shouts "A!" or "B!" at random. Peggy must exit from the path Victor calls. If Peggy knows the magic word, she can always comply (open the door from either side). If she doesn't, she can only exit correctly if Victor happens to call the path she entered from — which happens with probability \(1/2\). After \(k\) repetitions, a cheating Peggy succeeds with probability \(2^{-k}\).

Crucially, Victor learns nothing about the magic word. A simulator could produce a convincing transcript by simply guessing Victor's challenge in advance, entering the corresponding path, and having Peggy exit from there — no magic word needed. The transcript looks identical to a real interaction where Peggy does know the word.

## 2. Sigma protocols and Schnorr's identification

Sigma protocols are a class of three-move interactive proofs with a specific structure that makes them amenable to zero-knowledge and to non-interactive conversion via Fiat-Shamir. They are the building blocks of modern ZKPs.

### 2.1 The sigma protocol structure

A sigma protocol for a relation \(\mathcal{R}\) has three messages: (1) commitment \(a\) from prover to verifier, (2) challenge \(e\) from verifier to prover (random), (3) response \(z\) from prover to verifier. The protocol satisfies:

- **Completeness**: Honest prover with valid witness succeeds.
- **Special soundness**: Given two accepting transcripts \((a, e, z)\) and \((a, e', z')\) with the same commitment \(a\) but different challenges \(e \neq e'\), one can efficiently extract a witness. This means that a prover who can answer two different challenges must actually know the secret.
- **Honest-verifier zero-knowledge (HVZK)**: There exists a simulator that, given a random challenge \(e\), can produce a transcript \((a, e, z)\) indistinguishable from a real interaction, without knowing the witness.

HVZK is weaker than full zero-knowledge because it assumes the verifier follows the protocol honestly. However, sigma protocols can be transformed into full zero-knowledge proofs against malicious verifiers through standard techniques.

### 2.2 Schnorr's protocol: proving knowledge of a discrete logarithm

Let \(\mathbb{G}\) be a cyclic group of prime order \(q\) with generator \(g\). The prover knows a value \(x \in \mathbb{Z}\_q\) such that \(h = g^x\) (the public key). The prover wants to convince the verifier that she knows \(x\) without revealing it.

**Protocol**:

1. **Commitment**: Prover picks a random \(r \in \mathbb{Z}\_q\), computes \(a = g^r\), and sends \(a\) to the verifier.
2. **Challenge**: Verifier picks a random challenge \(e \in \mathbb{Z}\_q\) and sends it to the prover.
3. **Response**: Prover computes \(z = r + e \cdot x \pmod{q}\) and sends \(z\) to the verifier.
4. **Verification**: Verifier checks that \(g^z = a \cdot h^e\).

**Why it works (completeness)**:

If the prover is honest, \(g^z = g^{r + ex} = g^r \cdot (g^x)^e = a \cdot h^e\).

**Why it is sound (special soundness)**:

Given two accepting transcripts \((a, e, z)\) and \((a, e', z')\) with \(e \neq e'\), we have:

\[
g^z = a \cdot h^e \quad \text{and} \quad g^{z'} = a \cdot h^{e'}
\]

Dividing: \(g^{z - z'} = h^{e - e'}\). Therefore \(h = g^{(z - z') / (e - e') \pmod{q}}\), and the witness is \(x = (z - z') / (e - e') \pmod{q}\). So from two transcripts, we can extract the discrete logarithm.

**Why it is zero-knowledge (HVZK)**:

Given a challenge \(e\), the simulator picks a random \(z \in \mathbb{Z}\_q\) and computes \(a = g^z \cdot h^{-e}\). The transcript \((a, e, z)\) is identically distributed to a real transcript because in both cases, \(a\) is uniformly distributed in \(\mathbb{G}\) (conditioned on the verification equation holding), \(e\) is random, and \(z\) is determined by \(a\) and \(e\). Since the simulator produces exactly the same distribution without knowing \(x\), the protocol is perfect HVZK.

### 2.3 Other classic sigma protocols

The Schnorr template generalizes to many relations. For the Graph Isomorphism problem, there is a perfect zero-knowledge proof: given two graphs \(G_0\) and \(G_1\), the prover knows an isomorphism \(\pi : G_0 \to G_1\). In each round, the prover sends a random isomorphic copy \(H\) of \(G_0\), the verifier challenges a bit \(b\), and the prover reveals the isomorphism from \(G_b\) to \(H\). The protocol is zero-knowledge because a simulator can guess the challenge in advance and prepare accordingly.

For Hamiltonian Cycle, Blum's protocol (1986) gives a computational zero-knowledge proof: the prover commits to the adjacency matrix of a randomly permuted graph, the verifier challenges either to reveal the Hamiltonian cycle or to open all commitments and show the graph is a permutation of \(G\).

## 3. From interactive to non-interactive: the Fiat-Shamir transform

Interactive protocols require communication. For many applications — blockchain proofs, email verification, verifiable computation — we want _non-interactive_ proofs: the prover produces a single message (the proof) that anyone can verify without further interaction.

### 3.1 The Fiat-Shamir heuristic

Amos Fiat and Adi Shamir (1986) proposed a simple but powerful transformation: replace the verifier's random challenge with the output of a cryptographic hash function applied to the commitment and the statement being proved. That is, instead of the verifier sending \(e\), the prover computes:

\[
e = H(\text{statement} \| a)
\]

where \(H\) is a hash function modeled as a random oracle. The proof then consists of \((a, z)\), and the verifier recomputes \(e = H(\text{statement} \| a)\) and checks the verification equation.

The Fiat-Shamir transform converts any sigma protocol into a non-interactive zero-knowledge proof in the _random oracle model_. The random oracle model assumes that the hash function behaves as a truly random function — an idealization that does not hold for any concrete hash function, but which has proven remarkably robust in practice.

### 3.2 Schnorr signatures

Applying Fiat-Shamir to Schnorr's protocol yields the Schnorr signature scheme. To sign a message \(m\) with private key \(x\) (where the public key is \(h = g^x\)):

1. Pick random \(r \in \mathbb{Z}\_q\), compute \(a = g^r\).
2. Compute \(e = H(m \| a)\).
3. Compute \(z = r + e \cdot x \pmod{q}\).
4. The signature is \((a, z)\) (or sometimes \((e, z)\) since \(a\) can be recovered).

Verification: given \((a, z)\), compute \(e = H(m \| a)\) and check whether \(g^z = a \cdot h^e\).

Schnorr signatures are provably secure (unforgeable) in the random oracle model under the discrete logarithm assumption. They are also compact, fast, and have nice algebraic properties that make them suitable for multi-signature and threshold signature schemes.

### 3.3 The random oracle model: strengths and caveats

The Fiat-Shamir heuristic is justified in the random oracle model, but concrete hash functions are not random oracles (they have structure, and their outputs are correlated in ways that true random functions are not). Counterexamples exist where Fiat-Shamir applied to a sound interactive protocol yields an insecure non-interactive protocol when the random oracle is instantiated with a real hash function. These counterexamples are somewhat contrived, but they motivate the search for non-interactive ZK proofs in the _standard model_ (without random oracles).

## 4. zk-SNARKs: succinct non-interactive arguments of knowledge

For truly practical verifiable computation, we need more than basic sigma protocols. We want proofs that are _succinct_ — much shorter than the computation being verified, and fast to verify. This is where zk-SNARKs come in.

### 4.1 What does SNARK stand for?

- **Succinct**: The proof size is small (ideally a few hundred bytes) and the verification time is fast (ideally polylogarithmic in the size of the computation), regardless of how complex the proved statement is.
- **Non-interactive**: A single message from prover to verifier.
- **ARgument**: The soundness holds only against computationally bounded provers (as opposed to "proofs" which hold against unbounded provers).
- **of Knowledge**: The prover not only convinces the verifier that the statement is true, but also proves that the prover _knows_ a witness. This is formalized via an _extractor_: given the prover's state, one can efficiently extract a valid witness.

Adding "zk" means zero-knowledge: the proof reveals nothing about the witness beyond the truth of the statement.

### 4.2 The Pinocchio protocol: an overview

The first practical zk-SNARK, Pinocchio (Parno et al., 2013), reduced proving general computations to checking certain polynomial equations. The key steps are:

1. **Arithmetic circuit representation**: The computation is expressed as an arithmetic circuit over a finite field \(\mathbb{F}\_p\). Gates perform addition and multiplication. Any computation with bounded loops can be expressed this way.

2. **Quadratic Arithmetic Programs (QAPs)**: The circuit is transformed into a QAP — a set of polynomials that encode the circuit constraints. Specifically, for a circuit with \(n\) gates and \(m\) wires, a QAP consists of polynomials \(u_i(X), v_i(X), w_i(X)\) for each wire \(i\), and a target polynomial \(t(X)\). An assignment \(a = (a_1, \dots, a_m)\) satisfies the circuit if and only if:

\[
\left(\sum*{i=1}^m a_i u_i(X)\right) \cdot \left(\sum*{i=1}^m a*i v_i(X)\right) - \left(\sum*{i=1}^m a_i w_i(X)\right)
\]

is divisible by \(t(X)\). That is, there exists a polynomial \(h(X)\) such that the above expression equals \(h(X) \cdot t(X)\).

3. **Cryptographic encoding**: The polynomials are evaluated at a secret point \(s \in \mathbb{F}\_p\) (chosen during a trusted setup) and encoded using pairing-based cryptography (elliptic curve pairings). The prover computes and sends group elements representing the evaluation of relevant polynomials at \(s\); the verifier checks a few pairing equations. The verifier never learns \(s\), so the prover cannot fake the divisibility check.

4. **Succinct verification**: Regardless of the circuit size, the verifier only needs to compute a constant number of pairings (a few elliptic curve operations). This is where the "succinct" property comes from.

### 4.3 Trusted setup: the dark secret

Pinocchio and Groth16 require a _trusted setup_ (also called a "ceremony") where a secret parameter \(s\) (and associated "toxic waste" \(\alpha, \beta, \gamma, \delta\)) is generated, used to create a common reference string (CRS), and then destroyed. If the toxic waste is not destroyed, a malicious actor could forge proofs. This is the most significant practical limitation of early SNARK constructions.

The "ceremony" is a multi-party computation (MPC) where many participants sequentially contribute randomness to generate the parameters. As long as _at least one_ participant is honest and destroys their contribution, the toxic waste cannot be reconstructed. Projects like Zcash conducted elaborate public ceremonies with multiple participants across the globe, using air-gapped computers that were physically destroyed afterward.

### 4.4 Groth16: the asymptotically optimal SNARK

Jens Groth (2016) designed a zk-SNARK that achieves the theoretically optimal proof size: just 3 group elements (2 from \(\mathbb{G}\_1\) and 1 from \(\mathbb{G}\_2\) in a bilinear pairing setting) and a single verification equation with 3 pairings. This is provably minimal for pairing-based NIZK arguments. Groth16 is the most widely deployed zk-SNARK, used in Zcash (Sapling upgrade) and many other systems.

The Groth16 protocol, given a QAP, works as follows (at a very high level):

- Setup generates random \(\alpha, \beta, \gamma, \delta, x \in \mathbb{F}\) and publishes proving key (many group elements) and verification key (a few group elements).
- Prover, given a witness \(a\), computes \(h(X)\) (the quotient polynomial), evaluates at \(x\), and produces a proof \(\pi = (A, B, C)\) in \(\mathbb{G}\_1^2 \times \mathbb{G}\_2\).
- Verifier checks: \(e(A, B) = e([\alpha]\_1, [\beta]\_2) \cdot e(\dots, [\gamma]\_2)\) — a single pairing equation that encapsulates the entire QAP check.

The elegance of Groth16 is that the entire circuit satisfaction condition is compressed into a single pairing equation. The downside remains the trusted setup, which must be performed for each circuit (though universal setups exist for PLONK).

## 5. PLONK: universal and updatable setup

PLONK (Permutations over Lagrange-bases for Oecumenical Non-interactive arguments of Knowledge), introduced by Gabizon, Williamson, and Ciobotaru in 2019, represents a significant advance in SNARK design. Its key innovation is a _universal_ trusted setup: a single setup ceremony produces a structured reference string (SRS) that can be used for _any_ circuit up to some maximum size. This contrasts with Groth16, where each circuit requires its own setup.

### 5.1 The PLONK circuit model

PLONK represents computations differently from QAPs. Instead of reducing to a single divisibility check, PLONK uses:

- A **gate constraint equation**: Every gate in the circuit must satisfy \(q_L a + q_R b + q_M ab + q_O c + q_C = 0\), where \(a, b, c\) are the wire values at the gate, and \(q_L, q_R, q_M, q_O, q_C\) are selector constants that define the gate type (addition, multiplication, constant, etc.).

- A **copy constraint** (wire permutation): If the output wire of one gate connects to the input wire of another, their values must be equal. This is enforced using a permutation argument based on the fact that two sequences are permutations of each other if and only if their products over a random challenge are equal.

### 5.2 The PLONK protocol sketch

1. **Preprocessing**: The circuit is preprocessed into a set of selector polynomials \(q*L(X), q_R(X), q_M(X), q_O(X), q_C(X)\) and permutation polynomials \(S*{\sigma*1}(X), S*{\sigma*2}(X), S*{\sigma_3}(X)\). These are encoded in the SRS during setup.

2. **Proving**: The prover commits to the wire value polynomials \(a(X), b(X), c(X)\) and the permutation polynomial \(z(X)\) using polynomial commitment schemes (originally KZG commitments based on pairings). Then the prover shows that:
   - The gate equation holds at all points.
   - The permutation (copy constraint) check passes.
   - The commitments are correctly formed and the polynomials have the right degree.

3. **Verifying**: The verifier checks a constant number of pairing equations (or, in the newer PLONK variants with Bulletproofs-style commitments, group exponentiations in an inner product argument).

### 5.3 UltraPLONK, TurboPLONK, and custom gates

PLONK's arithmetization is flexible. Variants like TurboPLONK and UltraPLONK add custom gates — for example, a gate that computes a 32-bit XOR, or a gate that looks up a value in a precomputed table (the "lookup argument" or "Plookup"). Custom gates reduce the number of gates needed for common operations, dramatically improving prover performance. UltraPLONK can even handle Plonky2-style "Goldilocks field" arithmetic (using the prime \(2^{64} - 2^{32} + 1\)), which is much faster on 64-bit CPUs than the large elliptic curve fields used in traditional SNARKs.

### 5.4 The importance of the universal setup

The universal SRS of PLONK means that a single, large-scale trusted setup ceremony can serve an entire ecosystem. This is a huge practical advantage. The Ethereum ecosystem, for example, conducted a large multi-party computation for the "Perpetual Powers of Tau" SRS, which can be used by any PLONK-based application. This reduces the friction and trust assumptions for deploying new zk-SNARK applications.

## 6. STARKs: no trusted setup and post-quantum security

STARKs (Scalable Transparent ARguments of Knowledge), introduced by Eli Ben-Sasson, Iddo Ben-Tov, Alessandro Chiesa, and colleagues, eliminate the trusted setup entirely. Instead of relying on a secret SRS, STARKs use public randomness and collision-resistant hash functions. This makes them _transparent_ — anyone can verify that the parameters were generated honestly — and _post-quantum secure_ (since they rely only on hash functions, not on the discrete logarithm or pairing assumptions that quantum computers could break).

### 6.1 The STARK compilation pipeline

The STARK proving pipeline is conceptually:

1. **Algebraic Intermediate Representation (AIR)**: The computation is expressed as a set of constraints on a trace table. For a computation with \(T\) steps, the prover writes down the values of all registers at each step, and the constraints enforce that each step correctly follows from the previous one.

2. **Low-degree extension**: The trace table is encoded as a polynomial (or a set of polynomials) over a finite field, using Reed-Solomon encoding. The polynomial has degree much smaller than the field size.

3. **FRI protocol** (Fast Reed-Solomon Interactive Oracle Proof of Proximity): This is the core innovation of STARKs. The verifier wants to check that the trace polynomial satisfies the constraints and has low degree. FRI allows the verifier to check low-degreeness of a committed polynomial with polylogarithmic communication. The prover commits to the polynomial via a Merkle tree of its evaluations.

4. **Compilation to a non-interactive proof**: The interactive protocol is made non-interactive via Fiat-Shamir.

The result is a proof that is larger than SNARKs (typically tens to hundreds of kilobytes for practical computations) but which has no trusted setup and is plausibly post-quantum secure.

### 6.2 Comparison: SNARKs vs STARKs

Each technology has distinct trade-offs:

- **SNARKs** (Groth16, PLONK): Smaller proofs (a few hundred bytes), faster verification (a few pairings or exponentiations), but require a trusted setup and rely on pairing-based assumptions that are not post-quantum secure.
- **STARKs**: Larger proofs (10-100 KB), somewhat slower verification, but transparent (no setup) and based on collision-resistant hashing (believed post-quantum secure). They also tend to have faster proving times for large statements.
- **Hybrids** (PLONK with Bulletproofs-style commitments, Halo2's inner product argument): Aim for transparent setup with small proofs, but verification is linear or polylogarithmic but slower than constant-time SNARKs.

The choice depends on the application: for on-chain verification where proof size and verification gas cost matter, SNARKs are preferred. For maximum trust minimization and quantum resistance, STARKs are preferred.

## 7. Engineering challenges in practical zk-SNARKs

Building a production zk-SNARK system involves overcoming significant engineering challenges beyond the cryptographic protocol design.

### 7.1 Proving time and memory

The prover's work is the bottleneck. For a circuit with \(n\) gates, generating a Groth16 proof requires:

- Computing the QAP polynomials \(u_i(X), v_i(X), w_i(X)\) (preprocessing, done once per circuit).
- Given a witness, computing \(h(X)\) — the quotient polynomial of the QAP divisibility check.

Computing \(h(X)\) naively involves an FFT (or NTT) of size \(O(n)\), and for a circuit with \(2^{20}\) constraints (about a million gates), this requires substantial memory and time. Techniques include:

- **Multi-exponentiation optimizations** (Pippenger's bucket method) to speed up the group operations.
- **Incremental proving** via proof recursion: instead of proving a large computation in one SNARK, break it into chunks and recursively verify SNARK proofs of sub-computations. This can make proving time linear in the computation size with a small constant.
- **GPU acceleration**: NTT operations and multi-exponentiations are accelerated on GPUs, reducing proving time from hours to minutes or seconds.

### 7.2 Front-end design: from program to circuit

Writing a zk-SNARK application requires translating the program logic into an arithmetic circuit. This is done by front-end tools:

- **Circom** (used in production by projects like Tornado Cash and zk-rollups): A domain-specific language for defining arithmetic circuits, with a compiler that generates the R1CS (Rank-1 Constraint System) representation.
- **ZoKrates**: A toolbox for zk-SNARKs on Ethereum, providing a Python-like DSL.
- **Leo** (Aleo): A statically-typed language that compiles to R1CS.
- **Cairo** (StarkWare): A language that compiles to an AIR for STARK proving, used for StarkNet and StarkEx.
- **Noir** (Aztec): A Rust-like DSL for zero-knowledge proofs.

The challenge in circuit design is that every conditional branch and every array index access must be "compiled away" into unconditional arithmetic operations (since circuits have no control flow). A simple `if` statement becomes a polynomial constraint like `result = condition * true_value + (1 - condition) * false_value`. This often leads to large circuits and requires careful optimization.

### 7.3 Proof recursion and aggregation

For scalability, we often need to aggregate many proofs into a single proof. This is achieved by _proof recursion_: the verification algorithm of a SNARK is itself expressed as an arithmetic circuit, and a new SNARK proves that the verification circuit was correctly executed on a previous SNARK proof. The result is a single compact proof that attests to the validity of an entire batch of proofs.

Recursion is the key to zk-rollups on Ethereum: a single SNARK proves that thousands of transactions were correctly executed, and this single proof is posted on-chain. The recursive verification is performed by a "prover network" and the final aggregated proof occupies only a few hundred bytes of block space.

### 7.4 Memory and storage proofs

A recent frontier is _memory proving_ and _storage proving_. A SNARK can prove not only that a computation was executed correctly, but also that it was executed on a specific memory state — for instance, that the computation read and wrote values at specific addresses according to a memory consistency model. This is crucial for proving correct execution of virtual machines (like the EVM or RISC-V) where the state is large and sparse.

The PLONK-based technique uses permutation checks to enforce memory consistency: every read from an address must return the last value written to that address. This is achieved by sorting the memory accesses by address and time, and checking adjacency constraints. The result is the ability to prove full EVM execution with a memory footprint that scales with the number of memory operations rather than the total address space.

## 8. Applications: where zero-knowledge matters

Zero-knowledge proofs are not just an academic exercise. They are being deployed in production systems at scale.

### 8.1 Privacy-preserving cryptocurrencies

Zcash, launched in 2016, uses zk-SNARKs (initially a predecessor of Groth16, later Groth16 in the Sapling upgrade) to enable _shielded transactions_. In a shielded transaction, the sender, receiver, and amount are all encrypted, but the transaction is accompanied by a zk-SNARK proving that the transaction is valid — specifically, that the sender has sufficient balance, that the inputs and outputs balance, and that the sender knows the spending keys for the input notes. All of this is verified without revealing any information about the parties or amounts.

Zcash's setup required the famous "ceremony" — a multi-party computation with participants including Peter Todd, Derek Hinch, and others, using air-gapped computers that were physically destroyed.

### 8.2 zk-rollups: scaling Ethereum

Ethereum's limited throughput (roughly 15-30 transactions per second on L1) has driven the development of Layer 2 scaling solutions. zk-rollups post a single SNARK proof on Ethereum L1 that attests to the correct execution of thousands of L2 transactions. The proof is verified by the L1 smart contract (using elliptic curve precompiles on Ethereum), and only the proof and minimal state diffs are stored on L1.

Notable zk-rollup projects include:

- **zkSync** (Matter Labs): Uses PLONK-based proofs.
- **StarkNet** (StarkWare): Uses STARKs for scalability.
- **Polygon zkEVM**: Proves correct execution of the EVM bytecode, making it bytecode-compatible with Ethereum L1.
- **Scroll**: Another zkEVM approach with bytecode-level compatibility.

These systems are processing billions of dollars in value, with proof generation running on clusters of GPUs and FPGAs.

### 8.3 Verifiable computation and identity

Beyond blockchain, zk-SNARKs enable:

- **Privacy-preserving identity**: Prove you are over 18, or that your passport is valid, without revealing your name, date of birth, or passport number.
- **Verifiable machine learning**: Prove that a specific model was run on specific data and produced a specific output, without revealing the model weights or the data.
- **Secure multiparty computation with public verification**: Not only compute a function on private inputs, but produce a proof that the computation was correct.
- **Audit logs and compliance**: Prove that a system satisfies regulatory requirements (e.g., reserves exceed liabilities) without revealing individual transactions.

## 9. Theoretical frontiers

Zero-knowledge proof research continues at a rapid pace, with several exciting directions.

### 9.1 Incrementally verifiable computation (IVC)

IVC, pioneered by Valiant (2008) and refined by Ben-Sasson, Chiesa, Tromer, and Virza, allows proofs to be built up step-by-step. After each computation step, a new proof is generated that attests to the correctness of all previous steps. The proof size remains bounded regardless of the number of steps. This enables "rollup" architectures where the prover continuously proves the evolving state of a system, rather than batching transactions into discrete blocks.

Halo2 (Zcash's next-generation proving system, based on the work of Bowe, Grigg, and Hopwood) achieves IVC using _nested amortization_ and a novel "accumulation scheme" that avoids the cost of full recursion. This allows practical IVC with good concrete performance.

### 9.2 Lattice-based and code-based ZKPs

With the threat of quantum computers, there is growing interest in zero-knowledge proofs based on assumptions that are believed post-quantum secure. Lattice-based ZKPs (e.g., based on Ring-LWE) and code-based ZKPs (based on the hardness of decoding random linear codes) are active research areas. These tend to produce larger proofs and have slower provers than pairing-based SNARKs, but they offer post-quantum security. Ligero (Ames et al., 2017) and Aurora (Ben-Sasson et al., 2019) are examples of post-quantum ZKPs with reasonable concrete performance.

### 9.3 Succinct arguments without pairings

Pairings (bilinear maps on elliptic curves) are a key ingredient in Groth16 and PLONK but are computationally expensive and not post-quantum secure. Alternative approaches include:

- **Bulletproofs** (Bünz et al., 2018): Use the hardness of discrete logarithm directly (no pairings), with \(O(\log n)\) proof size and \(O(n)\) verification. Already deployed in Monero for range proofs.
- **Inner product arguments** (Bootle et al., 2016): Similar to Bulletproofs, with slightly better constants.
- **DARK** (Bünz et al., 2020): Uses groups of unknown order (RSA groups or class groups) to achieve constant-size proofs without pairings.

### 9.4 Formal verification of ZKPs

Given the complexity of ZKP implementations and the high stakes of bugs (loss of privacy, forged proofs), formal verification of ZKP compilers and provers is critical. Projects are emerging that formalize the soundness and completeness of SNARK protocols in proof assistants (Coq, Lean) and verify that the implementation conforms to the specification. The field is transitioning from "seems correct" to "machine-checked correct."

## 10. Summary

Zero-knowledge proofs are among the most exciting technologies at the intersection of cryptography and computer science. They allow us to prove statements about secrets without revealing the secrets themselves, achieving a seemingly paradoxical combination of verifiability and privacy. What began as a theoretical curiosity in the 1980s has matured into a practical engineering discipline, with zk-SNARKs and STARKs deployed in production systems securing billions of dollars in value.

We have traced the arc from foundational definitions (the simulation paradigm) through classic interactive protocols (Schnorr, sigma protocols) to non-interactive proofs via Fiat-Shamir, and into the modern SNARK landscape: Pinocchio's QAPs, Groth16's optimal proofs, PLONK's universal setup, and STARKs' transparency. We have explored the engineering challenges — proving time optimization, proof recursion, memory consistency, and circuit front-ends — that make these protocols practical at scale. And we have glimpsed the future: incrementally verifiable computation, post-quantum ZKPs, and machine-checked correctness.

### 10.1 Key takeaways

- **Zero-knowledge proofs** satisfy completeness, soundness, and the zero-knowledge property (formalized via simulation).
- **Sigma protocols** (three-move, special soundness, HVZK) are the building blocks; **Schnorr's protocol** proves knowledge of discrete log.
- **Fiat-Shamir** converts interactive to non-interactive using a hash function in the random oracle model.
- **zk-SNARKs** achieve succinctness via QAPs and pairing-based cryptography, but require a trusted setup.
- **PLONK** introduces universal trusted setup and flexible arithmetization with custom gates.
- **STARKs** eliminate trusted setup using FRI and hash functions, at the cost of larger proofs.
- **Engineering** involves circuit front-ends, NTT acceleration, proof recursion, and memory consistency.

### 10.2 Further reading

- **"The Knowledge Complexity of Interactive Proof-Systems"** by Goldwasser, Micali, and Rackoff (STOC 1985) — the foundational paper.
- **"How to Prove Yourself: Practical Solutions to Identification and Signature Problems"** by Fiat and Shamir (CRYPTO 1986).
- **"Pinocchio: Nearly Practical Verifiable Computation"** by Parno, Howell, Gentry, and Raykova (IEEE S&P 2013).
- **"On the Size of Pairing-Based Non-interactive Arguments"** by Jens Groth (EUROCRYPT 2016).
- **"PLONK: Permutations over Lagrange-bases for Oecumenical Noninteractive arguments of Knowledge"** by Gabizon, Williamson, and Ciobotaru (2019).
- **"Scalable, transparent, and post-quantum secure computational integrity"** by Ben-Sasson, Ben-Tov, Chiesa, et al. (2018) — the STARK paper.

### 10.3 Closing thoughts

There is something profoundly counterintuitive about zero-knowledge proofs. We are so accustomed to the idea that verification requires access — that to check a solution, you must see the solution — that the possibility of verifying without seeing feels almost magical. But, as with so many things in cryptography, the magic dissolves into rigorous mathematics: the simulation paradigm gives a precise technical meaning to "reveals nothing," and the algebraic structure of pairings and polynomial commitments gives a concrete construction that achieves it. Zero-knowledge proofs remind us that information is a subtle, non-physical quantity — it can be hidden, compressed, and verified in ways that defy our everyday intuitions but that are perfectly well-defined in the language of computational complexity.
