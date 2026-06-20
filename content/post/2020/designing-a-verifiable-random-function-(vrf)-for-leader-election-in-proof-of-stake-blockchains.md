---
title: "Designing A Verifiable Random Function (Vrf) For Leader Election In Proof Of Stake Blockchains"
description: "A comprehensive technical exploration of designing a verifiable random function (vrf) for leader election in proof of stake blockchains, covering key concepts, practical implementations, and real-world applications."
date: "2020-05-17"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/designing-a-verifiable-random-function-(vrf)-for-leader-election-in-proof-of-stake-blockchains.png"
coverAlt: "Technical visualization representing designing a verifiable random function (vrf) for leader election in proof of stake blockchains"
---

# The VRF Leader Election Blueprint: How Blockchains Run Fair Lotteries Without Trust

## 1. Introduction: The Unseen Lottery of Blockchains

Imagine a decentralized network where every few seconds, a single participant earns the right to propose the next block—and with it, a handsome reward in cryptocurrency. In Proof of Stake (PoS) blockchains, this moment of power is not earned by burning electricity but by staking coins. But here’s the catch: the selection process must be **truly unpredictable** before the moment of election, **publicly verifiable** after, and **resistant to manipulation** by malicious insiders. If the leader can be predicted, attackers can bribe or launch denial-of-service attacks. If the selection can be biased, the richest stakeholders can collude to control the chain. If verification is impossible, distrust erodes the entire system.

One of the most elegant cryptographic tools that solves this problem is the **Verifiable Random Function (VRF)**. A VRF is like a digital lottery machine: given a secret key and a public seed, it outputs a random number and a proof that the number was generated correctly—without revealing the secret key. For leader election, every validator runs the VRF on the same seed, but only those whose output falls below a threshold (adjusted by their stake) become leaders. The proof can be checked by anyone, ensuring fairness.

But designing a VRF specifically for leader election in PoS blockchains is far from trivial. The naive approach—simply hashing the secret key with the seed—fails because anyone with the secret key can precompute the result. We need **deterministic yet unpredictable** outputs that cannot be forged, and we need to integrate them with **weighted selection** (since validators with larger stakes should win more often). Moreover, in a real blockchain, multiple leaders may be elected per round to handle network delays, and the VRF must support **batch verifiability** and **efficient proof sizes**.

This blog post will walk you through the design of a VRF specifically optimized for leader election in PoS blockchains. We’ll start with the mathematical foundations, then examine the full construction—from key generation to weighted lottery to batch verification. Along the way, we’ll discuss real-world implementations (Algorand, Cardano, Polkadot) and the subtle attacks that must be thwarted. By the end, you’ll understand not just _how_ VRFs work, but _why_ they are the bedrock of modern decentralized consensus.

---

## 2. Cryptographic Background: What Is a Verifiable Random Function?

A VRF is a cryptographic primitive that takes a private key `sk`, a public key `pk`, and an input `x` (often called the _seed_ or _alpha_), and produces two outputs:

- `y` – a pseudorandom output (a bit string, often a scalar or group element).
- `π` – a proof that `y` was correctly generated from `x` and `sk`.

The proof can be verified by anyone using the public key `pk` and the input `x`. The VRF must satisfy three core properties:

1. **Uniqueness:** For each private key and input, there is exactly one valid output. No adversary can produce two different valid proofs for the same `(pk, x)`.
2. **Pseudorandomness:** Without the private key, the output `y` is computationally indistinguishable from a truly random string, even if the adversary knows `x` and can adaptively query the VRF on other inputs.
3. **Verifiability:** Given `(pk, x, y, π)`, anyone can efficiently check that `y` is the correct output for `x` under `pk`.

These properties make a VRF fundamentally different from:

- **Hash functions:** A hash `H(x)` is deterministic and pseudorandom, but there is no proof that it came from a specific secret. Anyone can compute `H(x)`.
- **Pseudorandom functions (PRFs):** Like AES with a secret key, a PRF gives pseudorandom outputs but no verifiability—the secret is needed to compute.
- **Digital signatures:** A signature can be used to “commit” to a value (e.g., sign the seed), but the signature itself is not a pseudorandom output; one could bias the choice by generating many signatures.

VRFs combine the best of all worlds: the secret holder can produce a random-looking value that anyone can verify without learning the secret.

### 2.1 History and Formalisation

The concept was introduced by Micali, Rabin, and Vadhan in 1999. Early constructions were built on number-theoretic assumptions (RSA, Diffie-Hellman). The most practical constructions today are based on elliptic curves, specifically the **EC-VRF** standardised in RFC 9381 (formerly draft-irtf-cfrg-vrf). In this construction, the output is a point on the curve (or a hash thereof), and the proof is a non-interactive zero-knowledge (NIZK) proof of discrete log equality.

For leader election, we typically want the output `y` to be a scalar (a large integer) that can be compared against a threshold. So we often apply a hash to the output point to get a uniform value in `[0, 2^L)`.

---

## 3. Why Not a Simpler Approach?

Before diving into the full VRF design, it’s instructive to see why simpler solutions fail, especially in the adversarial environment of a blockchain.

### 3.1 Hashing the Secret Key with the Seed

Consider a naive scheme: each validator has a secret key `sk`. To elect a leader for round `r`, they compute `output = H(sk || r)`, where `H` is a cryptographic hash like SHA-256. The output is deterministic and pseudorandom given `sk`. However, there is **no proof** that `output` came from `sk`. Anyone could claim a different value. The network would need to trust the validator’s word. Worse, a validator could compute `H(sk || r)` offline and then selectively reveal only if it yields a winning value—a classic _grinding_ attack.

### 3.2 Using a Digital Signature

A digital signature scheme (e.g., ECDSA) can provide verifiability: the validator signs the round seed `r` and then uses the hash of the signature as the lottery output. Anyone can verify the signature using the public key. This seems to work: the output is verifiable, and without the secret key, the adversary cannot predict it. But there is a subtle problem: **free will in choosing the seed**. If the validator can influence `r` (or the order of signatures), they could try many `r` values until they find one where the signature hash yields a winning output. This is exactly the _front-running_ / _grinding_ attack that PoS chains must prevent.

Moreover, the output of a signature is not guaranteed to be uniformly pseudorandom. While most signature schemes are “random looking,” the formal property is weaker than the pseudorandomness of a VRF. In practice, hashing the signature is common (as in Algorand’s original design), but the VRF construction provides stronger guarantees and a cleaner abstraction.

### 3.3 The Need for Unpredictability and Verifiable Determinism

The magic of a VRF is that the output is **determined by the secret key and the input**, yet **unpredictable** to anyone who doesn’t know the secret key. Even if an adversary can query the VRF on many inputs, they cannot predict the output for a new input. In blockchain leader election, the input is a public random seed (e.g., the hash of the previous block). Because the seed is not known in advance (it’s revealed only at the end of the previous round), no validator can precompute their output for the next round until the seed is published. This ties together the security of the VRF with the randomness of the seed—a crucial synergy.

---

## 4. The VRF Construction: Step‑by‑Step

We will now describe a concrete VRF construction suitable for leader election. The most widely used is the **EC‑VRF** (Elliptic Curve Verifiable Random Function) as specified in RFC 9381. We’ll simplify some details to focus on intuition.

### 4.1 Key Generation

Let `G` be a generator of a prime‑order elliptic curve group (e.g., the Ristretto group for Curve25519 or secp256k1). The private key `sk` is a random scalar `α` in `[1, q-1]`, where `q` is the order of the group. The public key is `pk = α * G`.

### 4.2 Evaluation (Proving)

Given a seed `x` (treated as a binary string), the VRF evaluator does:

1. Compute a hash point `H = HashToCurve(x)`. This is a deterministic function that maps `x` to a group element.
2. Compute `γ = α * H` (scalar multiplication).
3. Compute the output `β = HashToBase(γ)`. This is a large integer (e.g., 256 bits) that will be used for the lottery.
4. Construct a **zero‑knowledge proof** `π` that `γ = α * H` **without revealing `α`**. This proof typically uses a NIZK proof of discrete log equality: the evaluator shows that `log_G(pk) = log_H(γ)`. The proof consists of a pair `(c, s)` where `c` is a challenge derived from a hash (Fiat‑Shamir transform) and `s` is a response that cancels the secret.

The output and proof together are `(β, π)`.

### 4.3 Verification

Given `(pk, x, β, π)`, a verifier:

1. Recomputes `H = HashToCurve(x)`.
2. Verifies the NIZK proof `π` to confirm that `γ` (which can be derived from the proof) satisfies `γ = α * H` for the same `α` that forms `pk`.
3. Computes `β' = HashToBase(γ)` and checks that `β' == β`.

If the proof verifies, the verifier is convinced that `β` was generated by the owner of `sk` for input `x`.

### 4.4 Why This Works

- **Uniqueness:** Because `γ` is uniquely determined by `sk` and `x` (scalar multiplication is deterministic), and the hash is deterministic, `β` is unique. The proof cannot be forged to produce a different `γ` (unless discrete log is broken).
- **Pseudorandomness:** The mapping from `x` to `β` behaves like a random oracle (assuming the hash functions are good) and the elliptic curve group is “random in the exponent.” Without `α`, `γ` looks like a random group element.
- **Verifiability:** The proof ensures that `pk` and `γ` share the same discrete log, without leaking `α`.

### 4.5 A Simple Python Example (Using Pseudocode)

We won’t show a full production implementation (that would require libraries like `libsodium` or `go-vrf`), but here’s a conceptual sketch:

```python
# Pseudocode with elliptic curve operations
import hashlib, ec_math

def vrf_keygen():
    sk = random_scalar()
    pk = sk * G
    return (sk, pk)

def vrf_eval(sk, x):
    H = hash_to_curve(x)
    gamma = sk * H
    beta = hash_to_base(gamma)
    proof = nizk_prove(sk, H, gamma, pk)
    return (beta, proof)

def vrf_verify(pk, x, beta, proof):
    H = hash_to_curve(x)
    gamma = nizk_extract(proof, H, pk)  # recovers gamma from proof
    if not nizk_verify(proof, H, pk, gamma):
        return False
    return hash_to_base(gamma) == beta
```

In practice, the `nizk_prove` function uses a Schnorr‑style proof of equality of discrete logs.

---

## 5. Weighted Leader Election: Turning VRF Outputs into Selections

In a PoS blockchain, validators don’t have equal power. Those with more stake (or “effective balance”) should be elected proportionally more often. The simple approach would be: each validator computes `output = VRF(sk, seed)`. If `output < threshold` (e.g., `output < TARGET`), they become a leader. But if all validators use the same threshold, they all have equal probability—unfair.

We need a **per‑validator threshold** that scales with stake. Let each validator `i` have an effective stake `s_i`. The total stake is `S = ∑ s_i`. In each round, we want the expected number of leaders to be `1` (or some constant `k`). For a single leader, we set a global target `T` such that `T / 2^L ≈ 1 / S` (where `L` is the bit length of the VRF output). Then validator `i` becomes a leader if:

```
VRF_output_i < T * s_i
```

Because `VRF_output_i` is uniformly distributed in `[0, 2^L)`, the probability for validator `i` is `(T * s_i) / 2^L = s_i / S`. Exactly proportional! This is known as **proportional election** or **threshold delegation**.

### 5.1 Multiple Leaders per Round

Sometimes we want more than one leader (e.g., for fast block production or committee selection). We can use a **slot‑based** approach. For each round `r`, we define `k` slots (e.g., `k = 150` in Algorand’s committee). For slot `j`, the validator computes `VRF(sk, seed || j)`. If the output falls below `T * s_i`, the validator is elected for that slot. This gives an expected `k` leaders per round (since each slot behaves independently). The independence holds because the VRF outputs for different `j` are pseudorandom and effectively independent given the secret key.

### 5.2 Handling Float Precision

In practice, `T * s_i` may not be an integer. We can compute the comparison using big integers: treat `VRF_output` as a 256‑bit integer, and check `VRF_output < (T * s_i) // 1`. The global target `T` must be chosen so that the expectation is `k`. More precisely, if we want `k` leaders per round with total stake `S`, we set `T = (k * 2^L) // S`. This may be slightly off due to integer rounding, but the probabilistic guarantee holds over many rounds.

### 5.3 Example: Weighted Lottery with 3 Validators

Let `L = 8` (output range 0–255), total stake `S = 100`. We want `k = 1` leader per round. Then `T = (1 * 256) // 100 = 2`. So the threshold is `2 * s_i`. Validator A has stake 50 → threshold 100 → probability 100/256 ≈ 39%. Validator B has 30 → threshold 60 → 23%. Validator C has 20 → threshold 40 → 15.6%. Sum = 200/256 ≈ 78%? Wait, that sums to less than 1 because we haven’t accounted for rounds with zero leaders. Actually, with `T=2`, the expected number of leaders per validator is `(2*s_i)/256`. Summing gives `(2*100)/256 = 200/256 ≈ 0.78`. That’s less than 1. To get expected 1, we need `T = 256/100 ≈ 2.56`, but we must use integer arithmetic. We can scale: use `T = (256 * 1000) // 100 = 2560` and compare `VRF_output * 1000 < T * s_i`. Or simpler: use `T = 256` and compare `VRF_output < s_i`. That gives expected leaders = `S / 256 = 100/256 ≈ 0.39`. So to get ≈1, we need a larger range. In practice, 256‑bit outputs mean extremely fine granularity; integer arithmetic is straightforward.

---

## 6. Batch Verification: Scaling to Thousands of Validators

In a live blockchain, every node must verify the VRF proofs of all elected leaders (and sometimes all validators who claim to be leaders). If each verification takes a few milliseconds, the cost can become prohibitive when thousands of validators participate.

**Batch verification** allows multiple VRF proofs to be verified simultaneously with less total work than verifying each individually. The core idea is to leverage the algebraic structure of the proof. For EC‑VRF, the proof is a NIZK proof of equality of discrete logarithms. The verification equation typically involves checking two pairings (or two multi‑scalar multiplications). By combining many proofs into a single equation using random coefficients (a technique similar to batch verification of Schnorr signatures), we can reduce the cost from `O(n)` group operations to `O(n)` hashes plus a constant number of multi‑scalar multiplications.

### 6.1 The Technique

Let each proof `π_i` for validator `i` with public key `pk_i`, seed `x_i`, and hash point `H_i` (derived from `x_i`) consist of a group element `γ_i` (the EC point) and a Schnorr proof `(c_i, s_i)`. The standard verification check is:

```
s_i * G ?= γ_i + c_i * pk_i
s_i * H_i ?= (something) + c_i * γ_i   // actually for a correct proof there are two equations.
```

In practice, the EC‑VRF specification uses a single verification equation: `c = H( H(γ) || ... )` and checks `s*G = γ + c*pk`. For batch verification, we can multiply each proof’s equation by a random scalar `r_i` and sum them. The random scalars prevent malicious provers from constructing a batch that passes while individual proofs are invalid.

**Result:** The batch verifier does one multi‑scalar multiplication of size `2n` (the sum of all `r_i * G` terms) instead of `n` individual point operations. This can yield 2‑5× speedups.

### 6.2 Caveats

Batch verification is only safe if the random coefficients are truly random and generated after the proofs are received (to avoid injection attacks). In a blockchain, each node can generate the same pseudo‑random coefficients using a seed (e.g., the round number) to avoid communication overhead.

Not all VRF constructions support batch verification. EC‑VRF does, but RSA‑based VRFs are harder to batch. The choice of curve also matters: pairing‑friendly curves (like BLS12‑381) allow even more efficient batching using pairings, but they are not necessary.

---

## 7. Implementation Details: Code Walkthrough

Let’s implement a minimal VRF‑based leader election in Python using the `vrf‑py` library (a wrapper around `libsodium`). We’ll also demonstrate the complete round logic.

```python
import hashlib
import struct
from vrf import VRF # hypothetical import
# Actually we'll use a simplified VRF class

class SimpleVRF:
    def __init__(self, sk, pk):
        self.sk = sk
        self.pk = pk

    def evaluate(self, seed):
        # In real life, calls libsodium's crypto_vrf_prove
        output = some_hash(self.sk + seed) # wrong, but for illustration
        proof = some_nizk(self.sk, seed)
        return output, proof

    @staticmethod
    def verify(pk, seed, output, proof):
        # verify proof
        pk_derived = ...
        return output == computed_output

# ----------------- Leader Election -----------------
TOTAL_STAKE = 10_000_000  # in smallest unit
TARGET_LEADERS = 150       # per round
VRF_BITS = 256
TARGET = (TARGET_LEADERS * (2**VRF_BITS)) // TOTAL_STAKE

validators = [
    {"pk": pubkey1, "stake": 1_000_000},
    {"pk": pubkey2, "stake": 2_000_000},
    # ...
]

round_seed = generate_round_seed(block_hash_previous_round)

leaders = []
for validator in validators:
    sk = validator.get("sk") # only the validator has this
    # In reality, each validator computes its own VRF privately and then broadcasts.
    output, proof = vrf.evaluate(sk, round_seed)
    threshold = TARGET * validator["stake"]
    if output < threshold:
        leaders.append({
            "pubkey": validator["pk"],
            "output": output,
            "proof": proof
        })

# All nodes receive the leaders' claims and verify
for claim in leaders:
    if not vrf.verify(claim["pubkey"], round_seed, claim["output"], claim["proof"]):
        reject(claim)
    # also check that output < TARGET * stake_of_pubkey
```

In production, the `vrf` module uses a real EC‑VRF. The `generate_round_seed` function must be deterministic and tamper‑resistant. For example, in Algorand, the seed is the SHA‑256 hash of the previous block’s header.

---

## 8. Security Considerations: Attacks and Mitigations

Even with a correct VRF, the overall leader election protocol is vulnerable to several attacks. We must analyse each.

### 8.1 Grinding Attacks on the Seed

An attacker who can influence the seed (e.g., by choosing which block to extend) can try many seeds until they find one that elects them as leader. This is the **bias** attack. The mitigation is to make the seed **unpredictable and non‑malleable**. In most modern PoS chains, the seed is the hash of the previous block, which itself is a deterministic function of the block’s contents. However, if the block proposer can include extra data, they may try to “grind” by searching over different block headers. To prevent this, some protocols use a **verifiable delay function (VDF)** to add a time delay to seed generation, making grinding computationally infeasible (e.g., in Chia). Others use a **commit‑reveal** scheme where validators commit to random values in one round and reveal them in the next, combining them into the seed.

### 8.2 Denial‑of‑Service (DoS) Against the Leader

If the leader can be predicted in advance, an attacker can target them with a DoS attack just before they propose a block. The VRF’s unpredictability helps: the identity of the leader is only known to the leader themselves until they broadcast the proof. However, once they broadcast, there is a brief window before the block is finalised. Some protocols (like Algorand) use a **silent leader** approach: the leader doesn’t announce itself, but just proposes the block; other nodes can verify the VRF proof after the fact.

### 8.3 Nothing‑at‑Stake and Long‑Range Attacks

A validator could sign multiple blocks for the same round, trying to fork the chain. The VRF proof contains the round number as part of the seed, so a proof for round `r` cannot be reused for round `r+1`. This prevents replay attacks. However, a malicious validator could still produce multiple valid VRF outputs for the same round by using different secret keys (if they hold multiple stakes). That is fine: each stake is an independent identity.

### 8.4 Adversarial Key Generation

Since the secret key is chosen by the validator, could an adversary generate many keys until a specific key’s VRF output for the initial seed is favourable? This is a **key grinding** attack. To mitigate, the protocol should enforce that keys are registered before the seed is known. In a chain, the initial seed can be derived from the genesis block, which is fixed after key registration.

---

## 9. Real‑World Implementations

### 9.1 Algorand

Algorand was the first major blockchain to use VRF for leader election (and committee selection). It uses the EC‑VRF construction with the ed25519 curve. Each round, a randomly selected committee of about 1500 validators (out of thousands) is chosen via VRF. The committee then runs its own Byzantine agreement protocol. The VRF seed is the hash of the previous round’s block. Algorand’s VRF implementation is open‑source and available in `go‑vrf` and `py‑vrf`.

### 9.2 Cardano (Ouroboros)

Cardano’s Ouroboros Praos protocol also uses VRF for slot leader selection. Each slot (every 20 seconds), the VRF output determines who can produce a block. The stake distribution is updated every epoch. The VRF used is also EC‑based, with the BLS curve in newer versions (Ouroboros Genesis). Cardano’s research papers provide formal security proofs under the “random oracle” model.

### 9.3 Polkadot (BABE)

Polkadot’s block production engine (BABE) uses VRF to assign slot leaders in a “round‑robin” fashion but with a VRF fallback for slots where no leader is elected. The VRF output is used to prioritise eligible validators. The proof is carried in the block header.

### 9.4 Others

- **Solana** uses a VRF for leader schedule (predictable but verifiable) but supplemented by a PoS‑based rotation.
- **Dfinity** (Internet Computer) uses VRF for random beacon and committee selection.
- **Chia** uses VDF for randomness, but VRF plays a role in pooling.

---

## 10. Advanced Topics: Post‑Quantum VRF, Aggregation, and Composability

### 10.1 Post‑Quantum Security

Current VRF constructions rely on the hardness of the discrete log problem, which is broken by Shor’s algorithm. For post‑quantum security, lattice‑based VRFs have been proposed (e.g., using the Ring‑LWE assumption). These are more computationally expensive but are being standardised. Some blockchains (e.g., QANplatform) are exploring quantum‑resistant VRFs.

### 10.2 Proof Aggregation

Instead of batch verification, one can aggregate multiple VRF proofs into a single short proof. This is useful for compressing committee membership proofs. Techniques from BLS signatures and SNARKs can be applied, but they often introduce pairing overhead.

### 10.3 Composable Randomness

A VRF can be combined with other cryptographic primitives to build more complex systems:

- **VRF + VDF**: Use VRF to generate a random seed, then VDF to enforce a time delay, making it impossible to grind the VRF output.
- **VRF + threshold signatures**: Use VRF to select a signing committee, then threshold signatures to produce a block.

---

## 11. Conclusion

The Verifiable Random Function is a small but mighty cryptographic tool that solves a fundamental problem in Proof of Stake blockchains: how to conduct a fair, unpredictable, and verifiable lottery without a trusted central authority. By combining the determinism of a secret key with the transparency of a public proof, VRF enables leader election that is both resistant to manipulation and efficient enough for high‑throughput networks.

Designing a VRF for leader election is not just about picking a curve and hashing an output. It involves careful integration with stake weights, multiple slots, batch verification, and robust seed generation. The constructions we’ve explored—EC‑VRF with threshold‑based weighted selection—are battle‑tested in Algorand, Cardano, and Polkadot, and continue to evolve.

As blockchains strive for higher scalability and lower latency, VRFs will likely be augmented with zero‑knowledge proofs, dynamic committees, and post‑quantum resilience. But the core idea remains: a random function that can be trusted without trust. In the lottery of blockchains, VRF is the unbiased referee who never cheats, never sleeps, and never reveals its secrets—until it’s time to prove them.

---

**Further Reading**

- RFC 9381 – Verifiable Random Functions (EC‑VRF)
- “Verifiable Random Functions” – Micali, Rabin, Vadhan (1999)
- Algorand’s VRF Implementation – github.com/algorand/go‑vrf
- Ouroboros Praos: An Adaptively‑Secure, Semi‑synchronous Proof‑of‑Stake Blockchain (2017)
- “Batch Verification of VRF Proofs” – Boneh et al. (2020)

_This blog post was written for an audience of cryptographic engineers and blockchain developers. Code snippets are illustrative; production implementations should use audited libraries._
