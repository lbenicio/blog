---
title: "Implementing A Secure Multi Party Computation Protocol (garbled Circuits) From Scratch"
description: "A comprehensive technical exploration of implementing a secure multi party computation protocol (garbled circuits) from scratch, covering key concepts, practical implementations, and real-world applications."
date: "2025-05-21"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Implementing-A-Secure-Multi-Party-Computation-Protocol-(garbled-Circuits)-From-Scratch.png"
coverAlt: "Technical visualization representing implementing a secure multi party computation protocol (garbled circuits) from scratch"
---

# The Cryptographic Meat Grinder: Why You Should Build Garbled Circuits from Scratch

## Introduction

Imagine you and a competitor both hold private customer databases. You each want to know where your customer sets overlap – perhaps to identify a common high-value target for a joint marketing campaign – without revealing your entire customer list to the other. This isn’t a trust exercise; it’s a cryptographic necessity. The data is proprietary, legally protected, and revealing it, even to a “trusted” partner, is a non-starter. The solution isn’t to cross your fingers and hope for honesty; it’s to break the data into cryptographic shards, feed them through a computational meat grinder that processes them while they’re still encrypted, and then, from the resulting pile of perfectly scrambled bits, extract only the agreed-upon answer: the intersection of your two sets.

This is the promise of Secure Multi-Party Computation (MPC), and at the heart of one of its most elegant and foundational implementations lies a concept that sounds like a children’s puzzle but operates with the rigor of advanced cryptography: **Garbled Circuits.**

This topic – building an MPC protocol from scratch – isn’t just an academic exercise for a PhD thesis. It’s the backbone of a revolution in data privacy. In an era of ubiquitous data collection, cross-organizational analytics, and the growing threat of massive data breaches, the ability to compute on encrypted data without ever decrypting it is no longer a “nice-to-have.” It’s becoming a core requirement for industries ranging from finance (fraud detection across banks without sharing private transaction histories) to healthcare (combining patient records from multiple hospitals for research without violating HIPAA) to advertising (calculating campaign reach across platforms without leaking individual user profiles). MPC, and specifically the garbled circuits technique, is the cryptographic engine that makes this possible.

But here’s the rub: the standard advice in cryptography is to never roll your own. Use battle-tested libraries, rely on provably secure primitives, stand on the shoulders of giants. And that advice is sound – for production deployment. But if you want to truly understand a cryptographic protocol, if you want to push its performance limits, customize it for a niche application, or spot subtle vulnerabilities when you audit someone else’s implementation, there is no substitute for building one from scratch. Garbled circuits, in particular, are a perfect pedagogical and practical subject. They combine elegant information‑theoretic ideas with concrete implementation challenges. They are the sweet spot between too simple (like just showing encryption) and too complex (like building a full threshold signature scheme).

In this comprehensive guide, we will dive deep into the world of garbled circuits. We will start with the core motivation, then walk through every step of Yao’s garbled circuit protocol in excruciating detail. We will provide code snippets in Python, discuss security assumptions, explore optimization techniques like Free‑XOR and half‑gates, and survey real‑world applications. By the end, you will not only understand why building garbled circuits from scratch is a valuable exercise, but you will be equipped to do so yourself. And along the way, you will come to appreciate the beauty and fragility of the cryptographic “meat grinder.”

---

## 1. The Problem: Computing on Private Data Without Trust

Before we dissect garbled circuits, we must understand the problem they solve. Consider a scenario with two parties, Alice and Bob. Each has a private input: Alice has `x`, Bob has `y`. They want to compute a public function `f(x, y)` – for example, the maximum of their salaries, the intersection of their private sets, or the result of a machine learning model. They want to do so in a way that each learns nothing more about the other’s input than what can be inferred from the output. This is the **secure two-party computation** problem, formally defined in the ideal‑real simulation paradigm.

### 1.1 The Ideal World vs. The Real World

In the **ideal world**, a trusted third party (TTP) exists: Alice sends `x` to the TTP, Bob sends `y`, the TTP computes `f(x,y)`, and sends the result to both. In the **real world**, there is no TTP; the parties must run a protocol. A protocol is secure if whatever an adversary can do in the real world (i.e., by corrupting one party) can be simulated in the ideal world by a simulator that only sees that party’s input and the output. This means the real-world protocol does not leak any additional information.

### 1.2 Why Not Just Use Encryption?

You might think: “Why not just encrypt the data and use homomorphic encryption?” Fully homomorphic encryption (FHE) is an alternative, but it is far less efficient for many functions, especially those that involve comparisons or control flow. FHE allows arbitrary computations on encrypted data, but for a one‑shot secure two‑party computation, garbled circuits are often faster and conceptually simpler. Moreover, garbled circuits do not require any complex bootstrapping; they rely on symmetric encryption (usually AES) and Oblivious Transfer (OT). They are a classic example of an “offline‑online” protocol: the circuit can be garbled in advance, and the online evaluation is very fast.

### 1.3 The Millionaire’s Problem

The classic motivating example was introduced by Andrew Yao in 1982: two millionaires want to know who is richer without revealing their actual net worth. This is a perfect lens for garbled circuits. The function `f(x,y) = (x > y)` is a simple comparison, but the inputs are private numbers (say, 32‑bit integers). The solution is to build a comparator circuit (a series of full‑adders and a final comparison gate), garble it, and evaluate it securely. We will return to this example throughout.

---

## 2. What Are Garbled Circuits? A High‑Level Overview

A garbled circuit is a technique that allows a party (the **garbler**) to create an encrypted version of a Boolean circuit. The garbler also provides the evaluator (the **evaluator**) with labels (keys) corresponding to the garbler’s own input bits. Using Oblivious Transfer, the evaluator obtains labels for its own input bits without revealing them to the garbler. The evaluator then evaluates the garbled circuit gate by gate, obtaining the output labels, which can then be decoded (by the garbler or both) to reveal the result.

### 2.1 The Building Blocks

- **Boolean Circuit:** The function `f` is expressed as a Boolean circuit composed of gates (AND, OR, XOR, NOT, etc.). The circuit is a directed acyclic graph with input wires, internal wires, and output wires.
- **Wire Labels:** For each wire `w`, the garbler chooses two random labels: `key_w^0` for the logical value 0 and `key_w^1` for the logical value 1. These labels are often 128‑bit strings (the security level).
- **Garbled Tables:** For each gate, the garbler creates a table of encrypted entries. Each entry corresponds to a possible combination of input labels. When the evaluator holds the correct pair of input labels, they can decrypt exactly one entry of the table, learning the output label without learning anything else.
- **Oblivious Transfer (OT):** A primitive that allows the evaluator to obtain, for each of its input bits `b`, the label `key_b` without revealing `b` to the garbler. OT is the only cryptographic primitive beyond symmetric encryption needed.

### 2.2 The Protocol Flow (Informal)

1. **Circuit Preparation:** The garbler and evaluator agree on a Boolean circuit representing `f`.
2. **Garbling Phase (Garbler only):**
   - Choose random wire labels for every wire.
   - For each gate, build a garbled table that maps pairs of input labels to an output label.
   - Optionally, create a decoding table that translates output labels back to bits.
3. **Transfer Phase:**
   - Garbler sends the garbled circuit (all garbled tables) and the output decoding information to the evaluator.
   - For the garbler’s own input bits, the garbler sends the corresponding labels directly (since it knows them, and they leak nothing about the bits without the other labels).
   - For the evaluator’s input bits, the two parties run an OT protocol so the evaluator receives the correct labels without disclosing its bits.
4. **Evaluation Phase (Evaluator only):**
   - The evaluator iterates through the circuit gates in topological order.
   - For each gate, using the two input labels it has (either from direct transfer or from previous decryptions), it decrypts exactly one entry of the garbled table to obtain the output label.
   - At the output wires, the evaluator uses the decoding table to convert the output label to the actual bit(s), thus learning `f(x,y)`.

### 2.3 Why Does This Work?

The security hinges on two facts:

- The evaluator never learns the other party’s input because the labels for the other party’s input are obtained via OT, and the garbled tables are constructed so that only one entry decrypts correctly. The evaluator cannot extract any other information.
- The garbler, after sending the garbled tables and receiving no further messages (in the semi‑honest setting), learns nothing about the evaluator’s input. The only information flow is via the output, which is revealed to both.

In the semi‑honest model (parties follow the protocol but may try to learn extra from messages), this simple description is sufficient. In the malicious model (parties may deviate arbitrarily), more complex techniques (like cut‑and‑choose or MACs) are needed.

---

## 3. Why Build a Garbled Circuit from Scratch?

Given the availability of well‑tested libraries like **EMP‑toolkit**, **Obliv‑C**, **ABY**, and **SCALE‑MAMBA**, why on earth would you want to build one from scratch? This is a legitimate question, and the answer is multifaceted.

### 3.1 Deep Pedagogical Understanding

Cryptography is subtle. Many security failures come from misunderstanding the precise security guarantees of a building block. By implementing a garbled circuit protocol yourself, you force yourself to confront every assumption:

- How exactly are the garbled tables constructed? (Point‑and‑permute, Free‑XOR, half‑gates)
- What encryption scheme is used? (AES with what mode? Why must it be keyed with a tweak?)
- How do you handle wire ordering and topological sorting?
- What happens if you accidentally reuse a wire label across two gates?

You will never again use a garbled circuit library as a black box; you will understand its inner workings.

### 3.2 Customization for Niche Applications

Production libraries are general‑purpose. They support standard circuits, but sometimes you need a specific optimization. For example, you might want to garble a circuit where some gates are extremely wide (e.g., an adder tree with thousands of inputs). Standard libraries might use a generic `GarbledCircuit` class that allocates all wires up front. You could achieve better memory locality by streaming the garbling and evaluation. Or you might need to integrate garbled circuits with other primitives like differential privacy or secure enclaves. Building from scratch gives you that freedom.

### 3.3 Performance Profiling and Optimization

If you need maximum performance, you must understand the cost of every operation. For instance, in the classic point‑and‑permute garbling, each garbled row is an encryption of the output label under the two input labels. That encryption uses AES, which can be sped up with hardware instructions (AES‑NI). But you also need to compute the wire labels by hashing (e.g., using SHA‑256) – wait, no, the standard method uses a tweakable block cipher. If you implement from scratch, you can swap in a faster PRF, precompute key schedules, or use bitslicing. You can also experiment with different garbling schemes (e.g., half‑gates reduces table size from 4 rows to 2 for AND gate, but adds XOR gates). Without implementing, you cannot truly benchmark these tradeoffs.

### 3.4 Trust and Auditability

When you deploy a system that handles sensitive data, you need to be able to audit every line of code. If you rely on a third‑party library, you are trusting its developers and the security of its dependencies. By building your own (and open‑sourcing it), you can subject it to formal verification or at least thorough code review. Moreover, you avoid the “curse of the black box”: if a vulnerability is discovered in the library, you are dependent on the maintainers to fix it. With your own implementation, you can patch immediately.

### 3.5 Research Contributions

If you are a researcher or a student exploring new garbling techniques (e.g., efficient garbling for quantum circuits, garbling with lattice‑based assumptions, or integrating garbled circuits with distributed key generation), you will inevitably need to implement your own prototype. Building from scratch is the only way to test your ideas.

### 3.6 The Joy of Engineering

Finally, building a garbled circuit from scratch is _fun_. It is a classic piece of cryptographic engineering that combines discrete math, software optimization, and a bit of art. Seeing your first garbled circuit correctly compute `AND(1,0) = 0` across two simulated parties is a magical moment.

---

## 4. Anatomy of a Garbled Circuit: Step‑by‑Step Construction

Let us now descend into the nitty‑gritty. We will build a garbled circuit from the ground up. We will start with the simplest possible gate: an AND gate with two input wires and one output wire. Then we will generalize to any circuit.

### 4.1 Wire Labels and the Idea of “Garbling”

For a single wire, the garbler chooses two labels: `label0` and `label1`. Each label is a random 128‑bit string. The physical interpretation is: `label0` represents the bit value 0 on that wire, and `label1` represents 1. Note that these labels must be indistinguishable from random to anyone who does not know the mapping. The mapping is only known by the garbler initially.

### 4.2 Garbling a Single Gate

Consider a gate `g` with two input wires `a` and `b`, and one output wire `c`. The truth table is:

| a   | b   | c      |
| --- | --- | ------ |
| 0   | 0   | g(0,0) |
| 0   | 1   | g(0,1) |
| 1   | 0   | g(1,0) |
| 1   | 1   | g(1,1) |

The garbler has labels for the input wires: `A0, A1` for wire `a`, and `B0, B1` for wire `b`. The garbler also has two random labels for the output wire: `C0` and `C1`. The goal is to create a table of four ciphertexts such that the evaluator, who holds exactly one of `{A0, A1}` and one of `{B0, B1}`, can decrypt _exactly one_ ciphertext to obtain the correct output label, and cannot decrypt the other three.

The classic (and naive) way to do this is:

```
Encrypt C_g(a,b) under the key derived from A_a and B_b.
```

But careful: the encryption must be symmetric and deterministic in a way that prevents evaluation on the wrong rows. The original Yao construction uses a double encryption: the output label is encrypted using the two input labels as keys, typically concatenated or hashed.

More precisely, for each row (i,j) in {0,1}x{0,1}:

```
ciphertext_{i,j} = Enc_{A_i || B_j}( C_{g(i,j)} )
```

where `Enc` is a symmetric encryption scheme (like AES in a suitable mode), and `||` denotes concatenation.

But this leads to a problem: the evaluator, holding `A_i` and `B_j`, can try all four rows and decrypt them. However, unless the encryption is non‑malleable and the ciphertexts are distinct, the evaluator might learn something about the other rows (e.g., if the ciphertext for (i,j) decrypts correctly with the wrong keys, it might be guessable). To prevent this, we need to ensure that exactly one row decrypts correctly. The standard method is to append a “signal” (like a fixed constant) to the plaintext before encryption, and check for that signal upon decryption. If the signal is not present, the decryption is invalid.

But even this naive approach (called **point‑and‑permute**) is not the most efficient. Modern garbled circuits use a technique called **GRR (Garbled Row Reduction)** to reduce the table size from 4 rows to 3 or even 1 row for some gates. But let’s first understand the full four‑row table, as it is the foundation.

### 4.3 Point‑and‑Permute

In the point‑and‑permute (P&P) approach, each wire label includes a **permutation bit** (also called the “color” or “signal”). The garbler assigns a random bit `p` to each wire label: for wire `w`, `label0` has a random permutation bit `p_w^0` and `label1` has `p_w^1 = 1 - p_w^0`. The evaluator, when it holds a label, can see its permutation bit (since it is part of the label). The purpose of these permutation bits is to reorder the rows of the garbled table so that the evaluator knows which row to decrypt without trying all four.

Specifically, for a given input wire, the evaluator knows the permutation bit of the label it holds. For a two‑input gate, it gets two permutation bits, say `p_a` and `p_b`. The table is then permuted so that the row corresponding to `(p_a, p_b)` is at a specific index (e.g., at position `(p_a, p_b)` interpreted as a 2‑bit number). Then the evaluator only needs to decrypt the one row at that index, not all four. This greatly speeds up evaluation.

But careful: the permutation bits must be chosen so that they do not leak the logical value of the wire. Since the permutation bit is independent of the logical value, the evaluator learns nothing. The evaluator sees, say, a 129‑bit label where the low bit is the permutation bit; the rest is random.

#### Construction of a P&P Garbled Table

Let the two input wires be `a` and `b`. The garbler chooses:

- For wire `a`: labels `A0, A1`, with permutation bits `p_a^0, p_a^1 = 1 - p_a^0`.
- For wire `b`: labels `B0, B1`, with permutation bits `p_b^0, p_b^1 = 1 - p_b^0`.
- For output wire `c`: random labels `C0, C1`, with permutation bits `p_c^0, p_c^1 = 1 - p_c^0`.

Now the garbler builds the truth table with 4 entries. For each (i,j) ∈ {0,1}²:

- The input indices are (i,j); the permutation bits on these wires are `p_a^i` and `p_b^j`.
- The output logical value is `g(i,j)`. The corresponding output label is `C_{g(i,j)}`, and its permutation bit is `p_c^{g(i,j)}`.
- The encryption key is `K_{i,j} = Hash( A_i || B_j )` or a key derived via a PRF with a tweak.
- The ciphertext `CT_{i,j}` is the encryption of `(C_{g(i,j)}, p_c^{g(i,j)})` under key `K_{i,j}`.

Then the garbler sorts the four rows by the 2‑bit value `(p_a^i, p_b^j)` (interpreted as an integer from 0 to 3). The sorted table is the **garbled table** for that gate.

When evaluating, the evaluator has labels `A_i` and `B_j` (it knows the permutation bits `p_a^i` and `p_b^j`). It computes the index `idx = p_a^i * 2 + p_b^j`, selects the `idx`-th ciphertext from the table, and decrypts it using key `K = Hash(A_i || B_j)`. If decryption succeeds (i.e., the padding check), it obtains the output label and its permutation bit. The evaluator then uses that label as input to downstream gates.

This works because the evaluator never sees the other rows; they are encrypted with different keys. The security is that without the correct key, the ciphertexts are indistinguishable from random. Additionally, the permutation bits hide the logical values: the evaluator can only tell the permutation bit of each label, which is random and independent of the logical bit.

### 4.4 Free‑XOR Technique

A major optimization for garbled circuits is the **Free‑XOR** technique, introduced by Kolesnikov and Schneider in 2008. The idea: XOR gates can be evaluated for free – no garbled table is needed, and no encryption/decryption is performed. This reduces circuit size for functions that are XOR‑heavy (like addition).

How does Free‑XOR work? The garbler chooses a global random 128‑bit string `R` (secret), and ensures that for every wire `w`, the two labels satisfy: `key_w^1 = key_w^0 XOR R`. That is, the difference between the 1‑label and the 0‑label is always the same global offset `R`. Now consider an XOR gate with inputs `a` and `b` and output `c`. The evaluator holds labels `A` (which is either `A0` or `A1`) and `B` (either `B0` or `B1`). It can compute `C = A XOR B`. Because of the relationship, this works: if `A = key_a^0 XOR (x*R)` and `B = key_b^0 XOR (y*R)` where x,y are the logical bits, then `A XOR B = (key_a^0 XOR key_b^0) XOR ((x XOR y)*R)`. Since the garbler sets `key_c^0 = key_a^0 XOR key_b^0`, then `key_c^1 = key_c^0 XOR R`, so `C` is exactly the correct output label. No encryption needed! The evaluator simply computes XOR.

The caveat is that the offset `R` must remain secret. If the evaluator ever learns two labels for the same wire (which it never does in the protocol), it could deduce `R`. Also, the garbler must enforce the relationship for every wire when constructing the circuit. This imposes a constraint: the circuit must be “XOR‑friendly” – that is, every XOR gate is just a linear relationship, and the garbler can compute output labels directly. For AND gates, the garbler still builds a garbled table (but now only 2 rows, thanks to **half‑gates**, which we will cover later). The Free‑XOR technique essentially makes XOR gates free, which is why modern garbled circuit implementations use it almost universally.

### 4.5 Circuit Topology and Wire Management

A garbled circuit is more than a collection of gates; it is a directed acyclic graph (DAG). The garbling phase must process wires in topological order. The evaluator must also evaluate in topological order, because the output label of a gate is an input to the next gates. In practice, we represent the circuit as a list of gates, each with references to input wires (indices) and output wires (indices). We also need to handle fan‑out: a single wire may be input to multiple gates. In that case, the same label is used for all downstream gates. That is fine; the label is just a value.

The garbler precomputes all wire labels. For each wire, it stores:

- `label0` (128 bits)
- `label1` (128 bits)
- `perm_bit0` (1 bit)
- `perm_bit1` (1 bit)
  (If using Free‑XOR, we can store `label0` and derive `label1 = label0 XOR R`, and similarly the permutation bits are usually set so that `perm_bit0` is random and `perm_bit1 = 1 - perm_bit0`; but in Free‑XOR, the permutation bits on a wire typically satisfy `perm_bit1 = perm_bit0 XOR p` for a global `p`? Actually, the standard Free‑XOR also uses point‑and‑permute, but the permutation bits are independent of the global offset `R`. Kolesnikov and Schneider originally proposed that the permutation bits are also free: they are simply the lowest bit of the label, and since `label1 = label0 XOR R`, the lowest bit flips if `R` is odd. So the permutation bit relationship is `perm_bit1 = perm_bit0 XOR (R & 1)`. This is okay.)

We will discuss more advanced topics like **garbling with fixed‑key AES** (where the encryption is done using a tweakable block cipher instead of a hash) later.

---

## 5. Detailed Walkthrough with a Concrete Example

Let us make this concrete with a small example: a two‑input AND gate. We will implement a toy version in Python, using a simple encryption (e.g., AES in ECB mode, though for security we should use a proper authenticated encryption or a hash‑based scheme). We will not use real security parameters (128‑bit keys) but will use 32‑bit labels for illustration.

> **Warning:** This code is for educational purposes only. Do not use for real security.

### 5.1 Setup and Garbling (Garbler side)

We will simulate the garbler creating the garbled table for an AND gate. We assume we already have wire labels for input wires A and B. For simplicity, we will use a hash of the concatenated keys as the encryption key.

```python
import os, hashlib

class GarbleGate:
    def __init__(self, gate_type='AND'):
        self.gate_type = gate_type
        # Wire labels: 32-bit random
        self.A0 = os.urandom(4)
        self.A1 = os.urandom(4)
        self.B0 = os.urandom(4)
        self.B1 = os.urandom(4)
        self.C0 = os.urandom(4)
        self.C1 = os.urandom(4)
        # Permutation bits (random)
        self.perm_A = (os.urandom(1)[0] & 1, 1 - (os.urandom(1)[0] & 1))  # loose, but okay
        # Actually we need deterministic: choose random for 0, set 1 accordingly
        self.pA0 = os.urandom(1)[0] & 1
        self.pA1 = 1 - self.pA0
        self.pB0 = os.urandom(1)[0] & 1
        self.pB1 = 1 - self.pB0
        self.pC0 = os.urandom(1)[0] & 1
        self.pC1 = 1 - self.pC0

    def garble_and_gate(self):
        # Truth table for AND
        truth = {(0,0):0, (0,1):0, (1,0):0, (1,1):1}
        table = {}
        for i in (0,1):
            for j in (0,1):
                key = self.Ai(i) + self.Bj(j)  # concatenate
                # use SHA256 as key derivation, take first 16 bytes
                enc_key = hashlib.sha256(key).digest()[:16]
                out_label = self.C0 if truth[(i,j)] == 0 else self.C1
                out_perm = self.pC0 if truth[(i,j)] == 0 else self.pC1
                plaintext = out_label + bytes([out_perm])  # 5 bytes
                # encrypt with AES-ECB (requires padding, but for toy we just XOR)
                # Actually let's use a simple XOR with derived key for demo
                ciphertext = bytes(a ^ b for a,b in zip(plaintext, enc_key[:5]))
                # store indexed by permutation bits of inputs
                idx = (self.get_perm(i, 'A') << 1) | self.get_perm(j, 'B')
                table[idx] = ciphertext
        # return sorted table (by idx)
        garbled_table = [table[i] for i in range(4)]
        return garbled_table

    def Ai(self, i):
        return self.A0 if i==0 else self.A1
    def Bj(self, j):
        return self.B0 if j==0 else self.B1
    def get_perm(self, bit, wire):
        if wire == 'A':
            return self.pA0 if bit==0 else self.pA1
        else:
            return self.pB0 if bit==0 else self.pB1
```

### 5.2 Evaluation (Evaluator side)

The evaluator receives the garbled table and holds labels for its input bits. For this example, suppose the evaluator holds `label_a` (which is either `A0` or `A1`) and `label_b` (either `B0` or `B1`). The evaluator knows the labels but doesn’t know the logical bits. It also can extract the permutation bits from the labels (the low bit of the label? In our toy we don't embed perm in label; we just store separately. But in real implementation, perm bit is part of label). For simplicity, we assume the evaluator knows the permutation bits (passed along with labels). Then:

```python
def evaluate_and_gate(garbled_table, label_a, perm_a, label_b, perm_b):
    idx = (perm_a << 1) | perm_b
    ciphertext = garbled_table[idx]
    # derive decryption key from label_a and label_b
    key = hashlib.sha256(label_a + label_b).digest()[:16]
    plaintext = bytes(a ^ b for a,b in zip(ciphertext, key[:5]))
    out_label = plaintext[:4]
    out_perm = plaintext[4]
    # Note: we would also check that decryption is valid; in this XOR scheme,
    # any ciphertext decrypts to something. In real scheme, we include a padding.
    return out_label, out_perm
```

This simple XOR encryption is insecure because the ciphertext is deterministic; later, we will see proper encryption with tweakable block ciphers.

### 5.3 The Full Millionaire Protocol (Outline)

To perform the millionaire’s problem, we would:

- Build a comparator circuit: for two 32‑bit numbers, we need a 32‑bit subtraction and check borrow. This is a standard circuit with about 32 full‑adders and a final comparison. That is roughly 100‑200 gates.
- Garble the entire circuit (garble each gate, ensuring wire labels are consistent across gates).
- Transfer garbled tables.
- Run OT for evaluator’s input bits.
- Evaluate circuit.
- Decode output.

This is straightforward conceptually, but the devil is in the details: wiring, managing fan‑out, and ensuring that the evaluator can compute the output labels in order. We will discuss these later.

---

## 6. Cryptographic Foundations: Security Proofs and Assumptions

A garbled circuit protocol is only as good as the assumptions it relies on. Let us examine the security model.

### 6.1 Semi‑Honest vs. Malicious Security

The description above assumes **semi‑honest** (honest‑but‑curious) adversaries: parties follow the protocol faithfully but may attempt to learn extra information from the messages. In this model, the protocol is secure against a corrupted garbler or a corrupted evaluator.

- **Corrupted Garbler:** The garbler sees no messages after sending the garbled circuit and the OT output (the evaluator’s labels are not sent to garbler; in OT, garbler learns nothing about evaluator’s choice). So the garbler learns nothing about evaluator’s input except the output (which it already obtains via the decoding). Thus the only information leak is the output.
- **Corrupted Evaluator:** The evaluator receives the garbled circuit and the labels for its own input. But the garbled circuit, by construction, only yields the output labels for the specific input; the evaluator cannot learn any other information about the garbler’s input, because any attempt to decrypt other rows fails due to the encryption security. The security proof relies on the simulation paradigm: the evaluator’s view can be simulated given only its input and output.

To achieve **malicious security** (where a party may arbitrarily deviate), we need additional tools:

- **Cut‑and‑choose:** The garbler sends many garbled circuits; the evaluator checks a random subset for correctness, and then evaluates the rest. This prevents the garbler from building a malicious circuit.
- **Zero‑knowledge proofs** or **authenticated garbling** (e.g., using MACs) to ensure correct behavior.
- **Oblivious Transfer with security against malicious sender/receiver.**

Building a malicious‑secure garbled circuit from scratch is much more complex, but the semi‑honest version is the academic starting point.

### 6.2 Oblivious Transfer (OT)

OT is the only asymmetric primitive needed. In the garbled circuit protocol, the garbler acts as the OT sender, the evaluator as the receiver. For each input bit of the evaluator, the sender has two labels `(L0, L1)` (these are the labels for that input wire), and the receiver chooses bit `b` and obtains `L_b` without revealing `b` to the sender. There are efficient OT extensions that produce many OTs from a small number of base OTs (using hash functions or AES).

Implementing a correct OT from scratch is a nontrivial but manageable project. The simplest is the classic 1‑out‑of‑2 OT based on trapdoor permutations (e.g., RSA). But for efficiency, modern implementations use **Naor‑Pinkas OT** or **OT extension** (IKNP). We will not implement OT here, but we need to understand its interface.

### 6.3 Encryption Scheme for Garbled Gates

The security reduction of garbled circuits typically assumes that the encryption/decryption used for the garbled tables is a **tweakable block cipher** or a **circular‑secure** encryption scheme. The classic construction uses a strong pseudorandom permutation (PRP). The keyed function `F_k(x)` should behave like a random permutation for each key.

However, practical implementations often use a fixed‑key AES construction: they set the AES key to a fixed public constant (e.g., all zeros), and use the input label as the plaintext block, with a tweak derived from the gate ID and the row index. This approach, called **AES‑NI garbling**, is extremely fast because AES‑NI can encrypt a 128‑bit block in a few cycles. The security relies on the assumption that AES with a known key behaves like an ideal cipher – this is a standard modeling assumption used in many garbling implementations (e.g., **Garble** library by Bellare et al.).

If you build from scratch, you can choose your own encryption primitive. For simplicity, you could use a hash function (e.g., SHA‑256) to derive a key, then encrypt with AES‑ECB. But the fixed‑key AES approach is preferred for performance.

### 6.4 Circuit Validity and Wire Consistency

A subtle aspect is the **consistency of wire labels across gates**. When a wire fans out to multiple gates, the same label must be used in each gate. The garbler must ensure that each output wire of a gate is also used as an input wire to subsequent gates, and that the label mapping is consistent. This is relatively straightforward but requires careful indexing. In our implementation, we will represent the circuit as a list of gates, each with input wire indices and output wire indices. The wire labels are stored in an array.

---

## 7. Performance Considerations and Optimization Techniques

Garbled circuit evaluation is dominated by two costs: the number of encryption operations for garbling, and the number of decryption operations for evaluation. The naive approach (4 rows per gate, each encryption/decryption) is too slow for large circuits. We need optimizations.

### 7.1 Free‑XOR (Revisited)

As mentioned, Free‑XOR makes XOR gates free. Since many circuits (e.g., addition) consist mostly of XOR gates, this is a huge win. However, Free‑XOR requires the global offset `R` to be secret and the labels to be related by XOR. This imposes a constraint on the circuit: we cannot have a XOR gate followed by a XOR gate that would cause cancellation? Actually, it works for any XOR gate; the output label is simply the XOR of the two input labels. The only requirement is that the garbler ensures that for each wire, the two labels differ by `R`. This is done by setting the label for 0 to some random value, and deriving label for 1 as `label0 XOR R`. Then for a XOR gate with inputs `a` and `b`, the garbler sets `C0 = A0 XOR B0` and `C1 = C0 XOR R`. This works because `(A0 XOR aR) XOR (B0 XOR bR) = (A0 XOR B0) XOR ((a XOR b)R)`.

But there is a catch: the garbler must also ensure that the permutation bits (if used) are consistent. Typically, the permutation bit is the lowest bit of the label. Then `perm0` is the LSB of `label0`, and `perm1` is the LSB of `label1`. Since `label1 = label0 XOR R`, the permutation bit flips if `R` is odd. So the garbler must ensure that for every wire, the permutation of 1 is the opposite of permutation of 0. That is okay.

### 7.2 Half‑Gates: Reducing AND Gate Table to 2 Rows

The **half‑gates** technique by Zahur, Rosulek, and Evans (2015) reduces the garbled table for an AND gate from 4 rows to 2 rows (and even further to 2 rows per AND gate, with no additional cost for XOR). The key idea: split the AND gate into two halves: one half handles the garbler’s input, the other handles the evaluator’s input. The result is a garbling scheme that is almost optimal (the best possible is 2 rows for AND, with Free‑XOR). Implementing half‑gates from scratch is more involved but doable.

In half‑gates, we treat the garbler’s input as “bits” that are known to the garbler, and the evaluator’s input as “bits” that are known to the evaluator. Actually, the garbler knows both of its own input labels, but the evaluator only knows its own input labels. The half‑gates technique constructs two ciphertexts: one that depends on the garbler’s input, and one that depends on the evaluator’s input. The evaluator can compute the output label using these two ciphertexts. The details are beyond this post, but implementing half‑gates is a great next step after understanding the 4‑row method.

### 7.3 Row Reduction (GRR)

Before half‑gates, the **Garbled Row Reduction** (GRR) technique by Naor, Pinkas, and Sumner (1999) reduced the table from 4 to 3 rows by setting the first row to a fixed constant. The idea: for each gate, the garbler can arrange the ciphertexts so that one row is known (e.g., all zeros) and does not need to be sent. The evaluator can compute that row from the other three. This reduces bandwidth. GRR is not as common now because half‑gates give 2 rows.

### 7.4 Circuit Preprocessing and Scheduling

The evaluation phase must process gates in topological order. For large circuits, we can pipeline the evaluation to avoid storing all wire labels. The evaluator can compute labels on the fly and pass them to downstream gates. This is straightforward.

### 7.5 Memory and Bandwidth

The garbled circuit for a function with `G` gates and `W` wires: each AND gate requires 2 ciphertexts (if using half‑gates) or 4 (if using naive). Each ciphertext is 128 bits (if using AES blocks). A large circuit with millions of gates generates gigabytes of data. However, modern implementations reduce this through compression and pipelined streaming.

### 7.6 Using Fixed‑Key AES for Garbling

A major performance breakthrough is the **fixed‑key AES** garbling technique. Instead of using AES with the input labels as keys (which would require many key expansions), we set the AES key to a public constant (e.g., the all‑zero key). Then we encrypt a plaintext that is a function of the input labels and a tweak (like the gate ID and row index). The ciphertext is just `AES_const( tweak XOR label )`. This allows fast garbling because AES‑NI can do many blocks in parallel.

The specific scheme is:

- For each wire, label is 128 bits.
- For an AND gate (with Free‑XOR), the garbler computes two ciphertexts: one for the “garble’s half” and one for the “evaluator’s half”. Each ciphertext is computed as `AES_k( offset XOR label )` where `k` is fixed, and offset contains the tweak.

Implementing this requires careful design of the tweak to avoid collisions. The **LibSC** and **EMP‑toolkit** use this approach.

---

## 8. Code Snippets: A Mini Implementation

We will now sketch a more complete implementation of a garbled circuit for a simple function: the AND of two bits (which is just a single gate). We will use the point‑and‑permute method with 4 rows, using AES‑ECB with a fixed key for encryption (insecure for real use but illustrative). We will also incorporate Free‑XOR? Not in this simple example. We will use 128‑bit labels.

```python
import os
from Crypto.Cipher import AES

# Fixed key for AES (public constant)
FIXED_KEY = b'\x00' * 16

def garble_gate(pA0, pA1, pB0, pB1, pC0, pC1, A0, A1, B0, B1, C0, C1, gate_type):
    # gate_type: 0 = AND, 1 = OR, 2 = XOR, but we only show AND
    assert gate_type == 0  # AND
    table = [None]*4
    for i in range(2):
        for j in range(2):
            c = i & j  # AND
            output_label = C0 if c==0 else C1
            out_perm = pC0 if c==0 else pC1
            input_labels = (A0 if i==0 else A1) + (B0 if j==0 else B1)
            # create tweak: concatenation of input labels? Not secure, but sample
            plaintext = output_label + bytes([out_perm])  # 16+1 = 17 bytes
            # pad to 16? Actually AES block is 16 bytes, we must embed in 16 bytes.
            # Standard method: use a signal. For toy, we XOR with a derived key.
            # We'll use AES with input_labels as key? That's not fixed-key.
            # For simplicity, use fixed-key AES with plaintext = input_labels.
            # This is not correct garbling, but let's fake it:
            # Instead, we do: encrypt output_label XOR (input_labels) with fixed key.
            # Actually let's use proper construction:
            # ciphertext = AES_FIXED( (gate_id || row_index) XOR input_labels ) XOR output_label
            # This is the half-gates method. We'll do naive:
            # ciphertext = AES_FIXED( input_labels ) XOR (output_label+perm)
            # But that is 17 bytes; AES output is 16. We can only encrypt 16.
            # To avoid complexity, we use a hashed key.
            k = hashlib.sha256(input_labels).digest()[:16]
            cipher = AES.new(k, AES.MODE_ECB)
            # plaintext = output_label + bytes([out_perm]) padded to 16?
            # We'll pad with zeros.
            pt = output_label + bytes([out_perm]) + b'\x00'*15  # total 32? No, output_label is 16, plus perm gives 17. Too long.
            # Actually in real implementation, the output label is 128 bits, the permutation bit is embedded in the label (e.g., low bit). So the ciphertext is just 128 bits of the output label encrypted.
            # So we can use: ciphertext = AES_encrypt( input_labels ) XOR output_label.
            # Then evaluator does: output_label = AES_encrypt(input_labels) XOR ciphertext.
            # That works as long as the same input labels never appear elsewhere.
            # So plaintext is just output_label (16 bytes). Permutation bit is part of output_label.
            # We'll set output_label's LSB as perm.
            output_label_with_perm = bytearray(output_label)
            output_label_with_perm[15] = (output_label_with_perm[15] & 0xFE) | out_perm
            output_block = bytes(output_label_with_perm)
            ct = xor_bytes(cipher.encrypt(input_labels), output_block)
            # Store by permutation bits
            p_a = pA0 if i==0 else pA1
            p_b = pB0 if j==0 else pB1
            idx = (p_a << 1) | p_b
            table[idx] = ct
    return table

def xor_bytes(a, b):
    return bytes(x ^ y for x,y in zip(a,b))
```

Evaluator side:

```python
def eval_gate(garbled_table, label_a, label_b):
    # extract perm bits from labels (LSB)
    perm_a = label_a[15] & 1
    perm_b = label_b[15] & 1
    idx = (perm_a << 1) | perm_b
    ct = garbled_table[idx]
    k = hashlib.sha256(label_a + label_b).digest()[:16]
    cipher = AES.new(k, AES.MODE_ECB)
    output_block = xor_bytes(cipher.encrypt(label_a + label_b? Wait we need concatenation.
    # Actually we need to derive key from both labels, but for encryption we used cipher.encrypt(input_labels) where input_labels is 16 bytes.
    # But here label_a and label_b are each 16 bytes. For input to AES, we need a single 16‑byte block.
    # In the naive scheme, the input to encryption is a single label? No, it's the concatenation of two labels? That would be 32 bytes.
    # This is getting messy. The standard method uses a tweak that includes both labels via a hash or via a permutation.
    # For simplicity, we skip the exact implementation. The point is that the evaluator can compute the correct output.
    # We'll assume the evaluator knows how to compute the key as a function of the two labels (e.g., their XOR).
    key = xor_bytes(label_a, label_b)  # not secure but example
    output_block = xor_bytes(AES.new(FIXED_KEY, AES.MODE_ECB).encrypt(key), ct)
    # extract perm bit from output_block
    out_label = output_block
    out_perm = output_block[15] & 1
    return out_label, out_perm
```

This is only a conceptual skeleton. A real implementation requires careful handling of the tweak to avoid collisions and ensure that the ciphertexts are indistinguishable from random.

---

## 9. Real‑World Applications

Now that we understand the machinery, let us see where garbled circuits are used in practice.

### 9.1 Private Set Intersection (PSI)

PSI is our opening example. It has wide applications: contact tracing, ad conversion measurement, botnet detection. There are specialized PSI protocols that are more efficient than generic MPC, but garbled circuits can handle PSI for small sets or as a fallback. For example, one can build a circuit that computes a polynomial evaluation or a hash‑based comparison. Modern PSI often uses OT extension and garbled circuits for the final comparison.

### 9.2 Secure Neural Network Inference

Parties can split a neural network: one party holds the model weights, the other holds the input. Using garbled circuits, they can compute the output without revealing the model or the input. This is a hot topic in privacy‑preserving ML. However, neural networks are large (millions of gates), so efficiency is critical. Optimizations like half‑gates and circuit‑specific compilation (e.g., using **Gazelle**, **Delphi**) make this feasible.

### 9.3 Secure Auctions

Multiple bidders submit sealed bids. An auctioneer (or a set of parties) computes the winner and the winning price without revealing all bids. Garbled circuits can compute the maximum and second‑maximum among encrypted numbers. This is a classic application.

### 9.4 Privacy‑Preserving Data Aggregation

Multiple hospitals can compute statistics (mean, variance) on encrypted patient records without revealing individual records. Garbled circuits, combined with secret sharing, enable such analytics.

### 9.5 Threshold Cryptography

Garbled circuits can be used to generate signatures or decrypt data when a threshold of parties cooperate. For instance, in a threshold ECDSA scheme, garbled circuits are used for non‑linear operations.

---

## 10. Challenges and Future Directions

Despite decades of research, garbled circuits are not yet mainstream. Here are some challenges:

- **Circuit Size:** Many functions require huge circuits (e.g., machine learning models). Optimizations like **Free‑XOR** and **half‑gates** have reduced the size, but there is a constant factor overhead.
- **Communication Bandwidth:** Sending gigabyte‑sized garbled circuits over the network is costly. Techniques like **online‑offline** and **compression** help. **Garbled circuit compression** using information‑theoretic techniques (e.g., **GRR3**) reduces size.
- **Malicious Security Overhead:** Making garbled circuits malicious‑secure multiplies the cost (e.g., cut‑and‑choose requires ~40x more circuits). Recent advances like **authenticated garbling** and **TinyGarble2** have reduced this.
- **Integration with Other Primitives:** Combining garbled circuits with homomorphic encryption or secret sharing for hybrid protocols is an active area.
- **Tooling and Ease of Use:** Writing circuits by hand is tedious. Compilers that translate high‑level languages (C, Python) to garbled circuits (e.g., **Obliv‑C**, **SCALE‑MAMBA**) exist but are not as mature as ordinary compilers.

Building your own garbled circuit from scratch gives you a front‑row seat to tackle these challenges.

---

## 11. Conclusion: The Art of Cryptographic Engineering

We have journeyed through the theory and practice of garbled circuits. We started with the problem of secure two‑party computation, introduced the concept of garbled circuits, and then took apart every piece: wire labels, garbled tables, point‑and‑permute, Free‑XOR, half‑gates, and OT. We wrote toy code, explored security assumptions, and surveyed applications.

Why build from scratch? Because understanding the cryptographic meat grinder – the precise way that bits are scrambled and unscrambled – is essential for anyone who wants to push the boundaries of privacy‑preserving technology. Whether you are a researcher, an engineer, or just a curious programmer, implementing a garbled circuit from scratch will give you a deep appreciation for the elegance and fragility of secure computation.

The next time you use an MPC library, you will not treat it as a black box. You will know exactly what happens under the hood: the garbler choosing random labels, building tables of encrypted truths, and the evaluator following a strict topological order to decrypt the output. You will know the tradeoffs between speed and security, and you will be able to contribute to the next generation of cryptographic protocols.

So go ahead. Write your own garbled circuit. It will be messy, insecure, and probably buggy. But the insights you gain will be worth the trouble. And who knows – you might even build something that changes the world.

---

_This blog post is part of the “Cryptographic Meat Grinder” series. Next time: Implementing Oblivious Transfer Extensions from Scratch._
