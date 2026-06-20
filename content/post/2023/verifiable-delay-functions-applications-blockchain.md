---
title: "Verifiable Delay Functions: Wesolowski, Pietrzak, and the Sequentiality Assumption"
description: "An exploration of VDFs from their cryptographic foundations through practical constructions, with emphasis on randomness beacons, blockchain consensus, and the sequential computation lower bounds."
date: "2023-01-21"
author: "Leonardo Benicio"
tags: ["vdf", "verifiable-delay-functions", "randomness", "blockchain", "sequential-computation"]
categories: ["theory", "systems"]
draft: false
cover: "/static/assets/images/blog/verifiable-delay-functions-applications-blockchain.png"
coverAlt: "Diagram of a verifiable delay function showing input x going through repeated squaring in a group of unknown order, producing output y and a proof π."
---

Randomness is a public good. Blockchains need unbiased random numbers to select leaders and committees. Lotteries need provably fair randomness to assure players the draw was not rigged. Cryptographic protocols need common reference strings that no party could have biased. And yet, generating public randomness that everyone can trust is surprisingly hard. If you simply publish the output of a hash function, nobody can verify that you didn't try many inputs until you found one you liked. If you use a commit-reveal scheme, the last participant to reveal can selectively abort to bias the outcome. The problem, known as the "randomness beacon" problem, is fundamentally about forcing sequential delay: you need a function that takes a predictable, verifiable amount of wall-clock time to compute, so that by the time the output is known, the input has been fixed beyond anyone's ability to manipulate it.

Verifiable Delay Functions (VDFs) are the cryptographic primitive designed to solve this problem. A VDF is a function \(f: \mathcal{X} \to \mathcal{Y}\) that takes a specified number of sequential steps \(T\) to evaluate, yet whose output can be verified in time much less than \(T\) (ideally \(O(\log T)\)). The "sequential" part is crucial: unlike a proof-of-work puzzle, which can be parallelized across many machines, a VDF must inherently resist parallel speedup. No matter how many GPU cores or ASICs you throw at it, the evaluation time cannot be reduced below some linear function of \(T\) on a single core. This property, called **sequentiality**, is what makes VDFs suitable for randomness beacons: by the time anyone can compute \(f(x)\), the input \(x\) is already history.

The concept of a VDF was formalized by Boneh, Bonneau, Bünz, and Fisch in 2018, but the intellectual lineage traces back to Ron Rivest's "time-lock puzzles" from 1996 and to the repeated squaring in RSA groups used in early proof-of-work schemes. The breakthrough of the 2018 paper was in the "verifiable" part: constructing a short proof that the evaluation was performed correctly, without requiring the verifier to redo the \(T\) squarings. Two proof systems emerged almost simultaneously—Wesolowski's proof (2018) and Pietrzak's proof (2018)—and the race was on to build practical VDFs for Ethereum's beacon chain and beyond.

## 1. The VDF Definition and Security Model

Formally, a VDF is a triple of algorithms \((\mathsf{Setup}, \mathsf{Eval}, \mathsf{Verify})\):

- \(\mathsf{Setup}(\lambda, T) \to \mathsf{pp}\): On input a security parameter \(\lambda\) and a delay parameter \(T\), output public parameters \(\mathsf{pp}\). This is run once and the parameters can be reused for many evaluations.
- \(\mathsf{Eval}(\mathsf{pp}, x) \to (y, \pi)\): On input \(x \in \mathcal{X}\), output a value \(y \in \mathcal{Y}\) and a proof \(\pi\). The evaluation must take \(T\) sequential steps; more precisely, it must be impossible to compute \(y\) in fewer than \((1-\epsilon)T\) steps even with polynomial parallelism.
- \(\mathsf{Verify}(\mathsf{pp}, x, y, \pi) \to \{\mathsf{accept}, \mathsf{reject}\}\): Verify that \(y\) is the correct VDF output on input \(x\). Verification must run in time \(O(\mathsf{poly}(\lambda, \log T))\), i.e., at most polylogarithmic in \(T\).

The security properties are:

1. **Correctness:** An honestly computed output always verifies.
2. **Sequentiality:** No adversary running in fewer than \((1-\epsilon)T\) sequential steps can compute \(y\) with non-negligible probability, even with polynomially many parallel processors.
3. **Uniqueness (sometimes called "soundness"):** For any input \(x\), there is exactly one output \(y\) that can pass verification. This is a stronger property than mere computational soundness and is essential for applications like randomness beacons where agreement on a single output is required.

The uniqueness property distinguishes VDFs from proof-of-work: in PoW, many valid solutions exist (any nonce that produces a hash below the target), and the fastest miner wins probabilistically. In a VDF, there is exactly one correct output, and everyone eventually converges to it.

## 2. The Repeated Squaring Construction

The dominant VDF construction, used in both Wesolowski and Pietrzak proofs, is repeated squaring in a group of unknown order. The idea is beautifully simple.

### 2.1 The RSA Group and the Hidden Order

Let \(N = p \cdot q\) be an RSA modulus where \(p\) and \(q\) are large primes. The multiplicative group \(\mathbb{Z}\_N^\*\) has order \(\phi(N) = (p-1)(q-1)\). If the factorization of \(N\) is unknown (suppose \(N\) is generated by a trusted setup or via a multiparty computation), then the order of the group is unknown to the evaluator. This is the **group of unknown order** (GUO) assumption.

The VDF evaluation is:

\[
y = x^{2^T} \pmod{N}
\]

That is, start with \(x\), square it, square the result, and repeat \(T\) times. Because squaring is not parallelizable (each squaring depends on the output of the previous squaring), this computation inherently requires \(T\) sequential multiplications modulo \(N\).

Why can't we shortcut the computation? If the group order \(\phi(N)\) is known, then \(x^{2^T} = x^{2^T \bmod \phi(N)}\) by Euler's theorem. Computing \(2^T \bmod \phi(N)\) takes \(O(\log T)\) multiplications (using repeated squaring of the exponent), and then we can compute \(x^{\text{this residue}}\) in \(O(\log \phi(N))\) multiplications—polylog time! But without knowing \(\phi(N)\), the fastest known method to compute \(x^{2^T}\) is indeed to perform the \(T\) squarings sequentially.

The security of repeated-squaring VDFs thus rests on two assumptions: (1) the factoring assumption (the order of \(\mathbb{Z}\_N^\*\) is unknown to anyone who doesn't know the factorization of \(N\)), and (2) the sequentiality assumption (computing \(x^{2^T} \bmod N\) without knowing the order inherently requires \(\Omega(T)\) sequential multiplications). The second assumption is less studied than factoring, and proving it from standard cryptographic assumptions is an open problem. In practice, we use the heuristic that repeated squaring is "inherently sequential."

### 2.2 Class Groups as an Alternative

RSA groups require a trusted setup to generate \(N\) without leaking the factorization. If the party that generates \(N\) knows \(p\) and \(q\), they can evaluate the VDF instantly, defeating the purpose. This motivated the use of **class groups** of imaginary quadratic orders as groups of unknown order. A class group is defined by a discriminant \(\Delta\) (a negative integer with \(\Delta \equiv 1 \pmod{4}\)), and its order is the class number \(h(\Delta)\), which is believed to be hard to compute without essentially enumerating the group. Unlike RSA moduli, class groups can be generated transparently (no trusted setup), because the discriminant is a public parameter and nobody knows the class number.

The Chia network's VDF competition and Ethereum's VDF research both explored class groups extensively. The main challenge: arithmetic in class groups is significantly slower than modular arithmetic in \(\mathbb{Z}\_N^\*\). A squaring in a class group of cryptographic size (approximately 1500 bits) takes roughly 10-100x longer than a squaring modulo a 2048-bit RSA modulus. The tradeoff between trust assumptions (RSA requires trusted setup; class groups don't) and performance is one of the central engineering questions in VDF deployment.

## 3. Wesolowski's Proof: Fast Verification via Challenge-Response

Benjamin Wesolowski, in a 2018 paper, proposed an elegant proof system for repeated-squaring VDFs. The core idea: the prover (who claims to have computed \(y = x^{2^T}\)) can convince the verifier by engaging in an interactive protocol that is then made non-interactive via the Fiat-Shamir heuristic.

### 3.1 The Interactive Protocol

The verifier wants to check that \(y = x^{2^T} \bmod N\). The prover sends \(y\). The verifier chooses a random prime \(\ell\) (say, a 128-bit or 256-bit prime) and sends it to the prover. The prover computes the quotient \(q\) and remainder \(r\) when dividing \(2^T\) by \(\ell\):

\[
2^T = q \cdot \ell + r, \quad 0 \leq r < \ell
\]

The prover then computes \(\pi = x^q \bmod N\) and sends \(\pi\) to the verifier. The verifier checks:

\[
\pi^\ell \cdot x^r \equiv y \pmod{N}
\]

If the equality holds, the verifier is convinced that the prover knows the correct \(y\).

Why is this convincing? If \(y = x^{2^T}\), then:

\[
\pi^\ell \cdot x^r = (x^q)^\ell \cdot x^r = x^{q\ell + r} = x^{2^T} = y
\]

The verification takes one exponentiation by the small prime \(\ell\) and one by the small remainder \(r\), each \(O(\log \ell) = O(\lambda)\) multiplications. The proof size is a single group element \(\pi\). The prover's extra work (beyond the \(T\) squarings) is computing \(x^q\), which requires \(O(\log q) \approx O(T/\ell)\) multiplications using fast exponentiation—still sequential, but can be done with a small constant factor overhead by computing it alongside the main VDF evaluation.

### 3.2 Non-Interactive Version

To make the proof non-interactive (so anyone can verify without interacting with the prover), we apply the Fiat-Shamir transform: the challenge prime \(\ell\) is derived by hashing the public parameters and the output \(y\):

\[
\ell = \mathsf{Hash}(\mathsf{pp}, x, y, T)
\]

mapped to a prime via rejection sampling (keep hashing until the output is prime). The security proof relies on the random oracle model.

### 3.3 Soundness

The soundness argument: if \(y \neq x^{2^T}\), then for the verification equation \(\pi^\ell \cdot x^r \equiv y\) to hold, we would need \(\pi^\ell \equiv y \cdot x^{-r}\). This means \(\pi\) is an \(\ell\)-th root of \(y \cdot x^{-r}\). Computing \(\ell\)-th roots in an RSA group without knowing the factorization is believed to be as hard as breaking RSA. Moreover, if the adversary could produce valid proofs for multiple distinct challenges \(\ell\), they could compute an \(\ell\)-th root for each, and by taking linear combinations, recover the factorization of \(N\) (using Shamir's "factoring with a known \(\ell\)-th root" technique). Since the challenge is chosen after the adversary commits to \(y\) (in the interactive version) or via random oracle (in the non-interactive version), the adversary cannot pre-compute an \(\ell\)-th root for the specific challenge.

Wesolowski's proof is remarkably efficient: proof size is one group element (2048 bits for RSA), verifier time is two small exponentiations (a few milliseconds), and prover overhead is modest. It is the proof system used in the VDF deployed in the Chia blockchain.

## 4. Pietrzak's Proof: Recursive Halving Without Random Oracles

Krzysztof Pietrzak proposed an alternative proof system in the same year, with a different set of tradeoffs. Pietrzak's proof avoids the random oracle model (it is statistically sound in the plain model under a computational assumption) but produces larger proofs: \(O(\log T)\) group elements instead of one.

### 4.1 The Recursive Halving Protocol

Pietrzak's insight: to prove \(y = x^{2^T}\), the prover can recursively halve the problem. Let \(T = 2^t\) (if \(T\) is not a power of 2, pad with dummy squarings). The prover computes the midpoint \(z = x^{2^{T/2}}\). The verifier sends a random challenge \(r\). The prover then proves the new statement:

\[
x'^{2^{T/2}} = y', \quad \text{where } x' = x^r \cdot z, \quad y' = z^r \cdot y
\]

If the original statement is true (and \(z\) is correct), then:

\[
(x^r \cdot z)^{2^{T/2}} = (x^r \cdot x^{2^{T/2}})^{2^{T/2}} = (x^{r+2^{T/2}})^{2^{T/2}} = x^{r\cdot 2^{T/2} + 2^T}
\]

and

\[
z^r \cdot y = (x^{2^{T/2}})^r \cdot x^{2^T} = x^{r\cdot 2^{T/2} + 2^T}
\]

So the halved statement is true. If the original statement is false, then no matter what \(z\) the prover provides, the halved statement is true for at most one challenge \(r\) (by the Schwartz-Zippel lemma). By recursively halving \(\log T\) times, the verifier reduces the problem to a trivial base case of size \(T=1\), while the soundness error accumulates to at most \((\log T) / 2^\lambda\) (negligible if the challenge space is large enough).

### 4.2 Proof Size and Verification Time

At each level of recursion, the prover must provide the midpoint value \(z\) as part of the proof. The total proof consists of \(\log T\) group elements. Verification requires \(\log T\) exponentiations by small challenges—\(O(\lambda \log T)\) multiplications total. This is slower than Wesolowski's constant-time verification but still polylogarithmic, and crucially, it does not rely on the random oracle model.

### 4.3 Comparison of the Two Proof Systems

The choice between Wesolowski and Pietrzak is a classic engineering tradeoff:

| Property        | Wesolowski                         | Pietrzak                                                             |
| --------------- | ---------------------------------- | -------------------------------------------------------------------- |
| Proof size      | 1 group element                    | \(\log T\) group elements                                            |
| Verifier time   | 2 small exponentiations            | \(O(\log T)\) small exponentiations                                  |
| Prover overhead | Compute one large exponent \(x^q\) | Compute and store \(\log T\) midpoints, plus modular exponentiations |
| Security model  | Random oracle                      | Plain model (statistical soundness)                                  |
| Common setup    | Needs a prime challenge hashing    | Needs random challenge at each level                                 |

For \(T = 2^{30} \approx 10^9\), Pietrzak's proof has 30 group elements (about 60 KiB), which is fine for most applications. The verifier must do 30 small exponentiations, which adds perhaps 100 ms on a modern CPU. Wesolowski's proof is 256 bytes and verifies in 5 ms. In almost all practical deployments, Wesolowski wins—but Pietrzak's proof is theoretically cleaner, and in contexts where the random oracle model is unacceptable (or where weak hash functions are a concern), it is preferred.

## 5. VDFs in Practice: Randomness Beacons

### 5.1 The Randomness Beacon Problem

A randomness beacon is a service that periodically publishes a fresh, unpredictable random value. The canonical application is blockchain leader selection: at regular intervals (e.g., every slot in a proof-of-stake chain), a random beacon must output a value that determines which validator proposes the next block. If the beacon can be predicted or manipulated, the blockchain's security collapses.

The classic approach is a commit-reveal scheme: participants commit to random values by publishing hashes, then later reveal the preimages, and the beacon output is the XOR of all revealed values. This works if (a) all participants reveal honestly, and (b) the last participant cannot selectively abort. But the last participant _can_ see all other reveals before deciding whether to reveal their own value, and if they don't like the resulting beacon output, they can abort, forcing a restart with a new set of commitments. In expectation, the adversary can bias the beacon by trying many times until they get a favorable outcome.

### 5.2 The VDF Solution

VDFs solve the last-revealer problem elegantly. Instead of relying on simultaneous reveal, the protocol works as follows:

1. **Commitment phase:** Each participant \(P_i\) publishes a commitment \(c_i = H(r_i)\) to a random value \(r_i\).
2. **Reveal phase:** Each participant publishes \(r_i\). The aggregated randomness is \(R = \bigoplus_i r_i\).
3. **VDF phase:** The VDF is evaluated on \(R\): \((y, \pi) = \mathsf{Eval}(R, T)\). The beacon output is \(y\).

The key insight: the VDF imposes a delay \(T\) that is longer than the reveal window. Even if the adversary is the last revealer, by the time they could compute the VDF output for a particular \(R\) (and decide whether to abort based on it), the reveal window has closed and the \(r_i\) values are fixed. The adversary cannot "look ahead" to see what beacon output their reveal will produce, because computing \(y\) from \(R\) takes \(T\) time, which exceeds the reveal deadline.

For this to work, \(T\) must be calibrated carefully: longer than the maximum network latency (so that all reveals propagate before any VDF completes), but short enough that the beacon outputs are not excessively delayed. In Ethereum's beacon chain, the target is roughly one VDF evaluation per slot (12 seconds), with \(T\) chosen so that the VDF takes approximately 8-10 seconds on a single fast core, leaving margin for network propagation and verification.

### 5.3 Ethereum's Randao and VDF Integration

Ethereum's beacon chain uses RANDAO (a commit-reveal scheme where each validator contributes entropy) without a VDF, relying on the economic incentive that validators who fail to reveal are penalized. However, there is concern that in some scenarios, a validator might prefer to lose their deposit (which is slashed) in exchange for biasing the beacon. VDFs are proposed as a long-term hardening to eliminate this attack vector entirely.

The Ethereum Foundation funded significant VDF research, including the development of hardware-accelerated VDF evaluators (FPGAs and eventually ASICs) that would allow anyone to compute the VDF as fast as physically possible, minimizing the advantage of a well-resourced adversary. This hardware dimension is crucial: if the adversary can compute the VDF 10x faster than the honest participants (by using an ASIC), then the effective delay is reduced 10x, and the attack window reopens.

## 6. Beyond Randomness: VDF Applications in Consensus and Beyond

### 6.1 Proof-of-Space-Time and Chia

The Chia blockchain replaces proof-of-work with proof-of-space-time: farmers dedicate disk space to the network, and the quality of their proofs determines their chance of winning a block. Chia incorporates a VDF to enforce time between blocks. Specifically, a VDF runs continuously, and when its output crosses a threshold determined by the quality of farmers' proofs-of-space, a new block is minted. The VDF ensures that blocks cannot be produced faster than some target rate, because the VDF imposes a minimum sequential delay between blocks. This replaces the "difficulty adjustment" mechanism of PoW chains with a more predictable, less energy-intensive schedule.

Chia's VDF uses class groups (to avoid trusted setup) with Wesolowski proofs. The VDF parameters are tuned so that a high-end CPU completes one VDF "infusion" (one squaring iteration) in roughly 10 milliseconds, with thousands of infusions per block.

### 6.2 Timestamping and Public Ledgers

VDFs enable "proof of elapsed time" that can be verified after the fact. A data item can be timestamped by being included as the input to a VDF: anyone can verify that the VDF output could not have been produced before some time after the data item was created, because the VDF takes that long to evaluate. This provides a cryptographic lower bound on the age of data, which is useful for audit trails, certificate transparency, and establishing precedence in intellectual property disputes.

### 6.3 Copy Protection and Rate Limiting

VDFs can serve as a rate-limiting primitive: a server can require clients to present a VDF evaluation on some nonce before accepting a request, slowing down automated attacks. Because the VDF inherently cannot be parallelized, buying 1000 cloud instances doesn't let an attacker evaluate 1000 VDFs faster than a single instance can evaluate one. This is a more nuanced rate limiter than hashcash-style proof-of-work, which parallelizes trivially.

## 7. The Sequentiality Assumption: A Deep Dive

The security of repeated-squaring VDFs rests on the assumption that modular squaring is "inherently sequential"—that is, the fastest way to compute \(x^{2^T} \bmod N\) is to perform \(T\) sequential squarings, and no algorithm achieves asymptotically better depth even with unlimited parallelism.

### 7.1 Can We Beat Sequential Squaring?

Several attempts have been made to accelerate repeated squaring:

- **Parallelizing a single squaring:** A modular multiplication can be parallelized to some extent (using carry-save adders, for example), but the depth still scales as \(O(\log n)\) for \(n\)-bit multiplication. This reduces the constant factor but not the asymptotic \(T\) dependency.
- **Using automorphisms in extension fields:** In some groups, the Frobenius endomorphism allows faster exponentiation. However, in RSA groups and class groups, no such speedup is known.
- **Quantum algorithms:** Shor's algorithm factors \(N\) in polynomial time, completely breaking the sequentiality assumption (because knowing the order enables the shortcut). However, Shor's algorithm requires a large fault-tolerant quantum computer, which does not exist today. For now, VDF security reduces to "sequentiality against classical computers."

The VDF community takes the sequentiality assumption seriously. The Chia VDF competition solicited attacks and speed records, offering bounties for implementations that beat the naive squaring by more than a constant factor. So far, no asymptotic speedup has been found.

### 7.2 The Profiling Problem

Even with the sequentiality assumption, deploying a VDF requires solving a profiling problem: what value of \(T\) corresponds to a target wall-clock time on typical hardware? If the VDF is tuned to take 10 seconds on an Intel Core i9, an AMD Threadripper with twice as many cores won't help (because of sequentiality), but a chip with twice the clock speed will. To keep the effective delay predictable, VDF parameters must be recalibrated periodically as hardware improves. This is analogous to the difficulty adjustment in proof-of-work, but the metric is single-thread performance rather than total hash rate.

## 8. Constructions Beyond Repeated Squaring

Repeated squaring is not the only VDF candidate. Several alternatives have been proposed:

### 8.1 Isogeny-Based VDFs

Isogeny-based cryptography, which has gained attention for post-quantum key exchange (SIKE), also yields VDF candidates. The idea: walk along an isogeny graph of supersingular elliptic curves for \(T\) steps, each step requiring a sequential isogeny computation. Verifiability is achieved using pairings to check the isogeny path. Isogeny-based VDFs offer two potential advantages: (1) post-quantum security (even if Shor's algorithm breaks factoring, isogeny problems seem harder for quantum computers), and (2) potentially faster verification via pairing-based proof systems. However, isogeny VDFs are newer and less studied than repeated squaring, and SIKE was recently broken on classical computers, casting doubt on the underlying assumptions.

### 8.2 Permutation-Based VDFs and the VeeDo Construction

The StarkWare team proposed a VDF based on iterating a permutation (like Keccak) and using STARK proofs for verifiability. The idea: start with a state \(s\), apply a permutation \(P\) for \(T\) iterations to get \(s' = P^T(s)\), and then use a STARK to prove the correctness of \(s'\). Because STARKs are plausibly post-quantum secure and have polylogarithmic verification time, this approach is attractive. The catch: evaluating a STARK for \(T\) iterations of a permutation is itself computationally heavy, and the concrete performance is orders of magnitude worse than Wesolowski proofs.

### 8.3 Incrementally Verifiable Computation (IVC)

VDFs can be seen as a special case of incrementally verifiable computation, where each step of the computation produces a proof that the step was performed correctly, and the proofs can be efficiently merged. Valiant's incrementally verifiable computation (2008) and the more recent Nova folding scheme (2022) provide a path to VDFs from recursive SNARKs. The advantage: IVC-based VDFs do not need a group of unknown order, potentially eliminating the trusted setup requirement. The disadvantage: the recursive proof merging is complex and, for now, slower than Wesolowski proofs for modest \(T\).

## 9. Implementation Challenges and the Hardware Dimension

### 9.1 The Race for the Fastest Squaring

The bottleneck in repeated-squaring VDFs is modular multiplication modulo a 2048-bit (or larger) number. A single squaring requires a 2048-bit × 2048-bit integer multiplication followed by a reduction modulo \(N\). On a modern x86-64 core, this takes roughly 50-100 nanoseconds using optimized GMP (GNU Multiple Precision) routines. At 10 ns per squaring, \(T = 10^9\) squarings take 10 seconds.

The Chia VDF competition saw implementations in software (GMP, FLINT) and on FPGAs, with ASICs proposed but not yet manufactured. The fastest software implementation (using hand-tuned AVX-512 assembly) achieved roughly 30 ns per squaring, or about \(3 \times 10^7\) squarings per second. At this rate, \(T = 3 \times 10^9\) corresponds to 100 seconds of VDF delay.

### 9.2 Wesolowski Proof Computation Overhead

The Wesolowski proof requires computing \(x^q\) where \(q = \lfloor 2^T / \ell \rfloor\). If computed naively after the VDF evaluation, this adds a factor of \(1/\ell\) overhead (since the exponent is roughly \(T/\ell\)). For a 128-bit challenge \(\ell\), the overhead is \(2^{-128}\)—negligible. But in practice, \(q\) is a large integer (roughly \(T\) bits), and computing \(x^q\) via the standard square-and-multiply algorithm requires about \(T\) squarings plus some multiplications—essentially as much work as the VDF itself!

The trick is to compute the proof **during** the VDF evaluation, not after. As the evaluator performs the \(T\) squarings, it can simultaneously build the proof by maintaining a "running proof" that accumulates the effect of each squaring. In Wesolowski's construction, this means computing the intermediate values \(x^{\lfloor 2^i / \ell \rfloor}\) for each step \(i\), which requires one additional modular multiplication per VDF step—a 2x overhead. There are optimizations that reduce this to 1.1x or even 1.01x by doing the proof accumulation only every \(k\) steps, at a small increase in proof size or verification time.

### 9.3 Memory-Hardness and ASIC Resistance

An important design dimension is whether the VDF should be **memory-hard** as well as sequentially hard. A memory-hard VDF would require not just \(T\) sequential steps but also large amounts of memory to evaluate, making ASIC acceleration less advantageous (because ASICs benefit most from reducing memory latency). Several proposals combine VDFs with memory-hard functions (like Argon2) to achieve this dual hardness, but the formal treatment of memory-hard VDFs is less developed than for pure sequentiality.

## 10. VDFs and the Broader Cryptographic Ecosystem

### 10.1 Relationship with Proof-of-Work

It is instructive to contrast VDFs with proof-of-work (PoW), since both involve expending computational resources to produce a verifiable output. PoW as used in Bitcoin involves finding a nonce such that the hash of the block header falls below a difficulty target. PoW is massively parallelizable: you can throw 10,000 ASICs at the problem and find a solution 10,000 times faster. This parallelism is intentional—it creates an economic incentive to invest in hardware, which in turn secures the network through the cost of attack.

VDFs, by contrast, deliberately resist parallelization. The economic model is different: a VDF does not secure the network through the total cost of computation but through the enforced passage of time. The security argument is that no adversary, regardless of resources, can compute the function faster than the prescribed delay. This makes VDFs suitable for applications where timing, not expenditure, is the security parameter.

The two primitives can be composed. A hybrid randomness beacon might use PoW to select a committee (exploiting PoW's Sybil resistance) and then use a VDF to extract unbiased randomness from the committee's contributions (exploiting VDF's sequentiality). The composability of cryptographic building blocks is a recurring theme in protocol design, and the PoW-VDF combination is a particularly elegant example.

### 10.2 VDFs and Time-Lock Encryption

Time-lock encryption is the problem of encrypting a message such that it cannot be decrypted before a specified time, even by the recipient. Rivest's original time-lock puzzle (1996) used repeated squaring in an RSA group for exactly this purpose: the recipient must perform \(T\) sequential squarings to recover the message, and no amount of parallelism helps. VDFs add verifiability to this picture: a time-lock puzzle based on a VDF allows the recipient to prove to a third party that they have performed the required work (and thus that the message was indeed decrypted after the specified time), without the third party having to redo the squarings.

This has applications in sealed-bid auctions (bids are encrypted under a time-lock puzzle and revealed after the auction closes), in commit-reveal protocols where delayed disclosure is desired, and in blockchain transaction ordering where a user wants to delay the execution of a smart contract function until some future block height.

### 10.3 Composability with Zero-Knowledge Proofs

A VDF proof (Wesolowski or Pietrzak) is already a kind of succinct argument. But what if we need to prove statements about the VDF output within a larger zero-knowledge proof? For instance, a rollup might use a VDF to sequence transactions and then prove, in a SNARK, that the sequencing was performed correctly. This requires the VDF verification to be expressed as a circuit or constraint system that can be embedded in the SNARK.

Wesolowski verification—two modular exponentiations by small exponents—can be expressed as a relatively small number of R1CS constraints (a few hundred thousand), making it feasible to verify inside a Groth16 or Plonk proof. Pietrzak verification, with its \(O(\log T)\) iterative structure, is even more amenable to recursive SNARK composition because each halving step is a simple algebraic check. The integration of VDFs with general-purpose ZKPs is an active research area with implications for fully verifiable blockchain protocols.

## 11. The Sociological Dimension: Why VDFs Captured the Imagination

It is worth reflecting on why VDFs, more than many other cryptographic primitives, captured the public imagination and attracted significant venture funding (Chia raised over $60 million, and the Ethereum Foundation committed millions to VDF research). I believe the answer lies in the confluence of three factors.

First, timing. VDFs arrived in 2018, at the peak of the ICO boom and the nascency of proof-of-stake, when the blockchain industry was desperately searching for a "better proof-of-work"—something that would provide the security properties of PoW without the energy consumption. VDFs promised to decouple security from energy expenditure, replacing electricity with time as the scarce resource.

Second, elegance. The repeated-squaring construction is stunningly simple to describe: "square \(x\) repeatedly \(T\) times modulo an RSA modulus." Anyone with undergraduate mathematics can understand the computation; the cleverness is all in the verification. This accessibility made VDFs a favorite topic for crypto Twitter and tech blogs, creating a feedback loop of attention and funding.

Third, hardware intrigue. The prospect of a VDF ASIC—a chip that does nothing but modular squaring as fast as physics allows—is catnip for hardware engineers. The VDF ASIC represents a pure form of the "race to the physical limit" that drives so much of high-performance computing. Unlike Bitcoin ASICs, which compete on SHA-256 hashrate, a VDF ASIC competes on single-threaded modular multiplication latency, which is bounded by the speed of light across a silicon die. The ultimate VDF ASIC would approach the physical limits of computation, and the pursuit of that limit is intellectually irresistible.

## 12. Summary

Verifiable Delay Functions fill a gap in the cryptographic toolbox that had been recognized for decades: the need for a function that is provably slow to evaluate but fast to verify. The repeated-squaring construction, instantiated in RSA groups or class groups, with Wesolowski or Pietrzak proofs, provides a practical solution that is being deployed in production blockchain systems today.

The intellectual core of VDFs lies at the intersection of several deep areas: the structure of groups of unknown order, the complexity theory of inherently sequential problems, probabilistically checkable proofs and their efficient instantiations via interactive protocols, and the engineering of high-speed modular arithmetic. The field has advanced from a problem statement to deployed code in under five years, driven by the immediate practical need for decentralized randomness.

Yet fundamental questions remain open. Is the sequentiality of repeated squaring provable from standard assumptions, or is it merely an empirical observation? Can we build post-quantum VDFs that are competitive with repeated squaring? Can we eliminate the trusted setup without paying the class-group performance penalty? And on the engineering side: can we produce a commodity ASIC for VDF evaluation that makes the playing field truly level, ensuring that no adversary can gain a significant speed advantage through custom hardware?

What makes VDFs particularly exciting as a research area is their position at the boundary between theory and practice. The theoretical questions—about inherent sequentiality, about proof systems with polylogarithmic verification, about the hardness of computing group orders—are deep and connected to fundamental problems in complexity theory and number theory. The practical questions—about modular multiplication circuits, about ASIC tapeout schedules, about calibration algorithms for time-varying hardware—are equally deep in their own domain. Rarely does a cryptographic primitive demand fluency in both the algebraic geometry of class groups and the physical design rules of 5nm CMOS.

The answers to these questions will determine whether VDFs become as ubiquitous as hash functions in cryptographic protocol design. The momentum is strong, the foundations are deep, and the practical need is undeniable. VDFs are no longer a cryptographic novelty; they are infrastructure—and infrastructure, once laid, tends to stay.
