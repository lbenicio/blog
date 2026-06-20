---
title: "A Deep Dive Into The Sha 3 Sponge Construction: Keccak F Permutation, Padding, And Security Margins"
description: "A comprehensive technical exploration of a deep dive into the sha 3 sponge construction: keccak f permutation, padding, and security margins, covering key concepts, practical implementations, and real-world applications."
date: "2022-09-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/a-deep-dive-into-the-sha-3-sponge-construction-keccak-f-permutation,-padding,-and-security-margins.png"
coverAlt: "Technical visualization representing a deep dive into the sha 3 sponge construction: keccak f permutation, padding, and security margins"
---

Here is the expanded blog post, diving deep into every nook and cranny of the SHA-3 sponge construction.

---

**Title: A Deep Dive Into The SHA-3 Sponge Construction: Keccak F Permutation, Padding, And Security Margins**

The air in a modern data center is thick with the hum of servers, each one churning through trillions of calculations per second. Every time you check your email, swipe a credit card, or verify a digital signature, a silent, invisible machinery is at work: the cryptographic hash function. It’s the bouncer at the nightclub of the internet, responsible for verifying identity, ensuring integrity, and destroying any notion of message privacy. For decades, the undisputed king of the hill was SHA-2, a family of hash functions that have been the bedrock of TLS, SSH, Bitcoin, and most of the digital world we know.

But SHA-2 has a secret. It’s old. Not old like a vintage wine, but old like a veteran racehorse—still fast, still powerful, but built on a chassis designed decades ago. The threat landscape has evolved. We’ve learned that the Merkle–Damgård construction, while elegant and proven, is susceptible to subtle structural flaws: length extension attacks (where an attacker can compute a hash of a longer message without knowing the original) and a growing body of research suggesting that its internal state collision resistance might not be as robust as we once thought. We needed a new champion. Enter Keccak (pronounced "ket-chak"), the winner of the National Institute of Standards and Technology (NIST) SHA-3 competition, and with it, a radical departure from everything we knew about hashing.

We didn’t just get a new hash function; we got an entirely new _philosophy_ of secure hashing. SHA-3 isn’t a tweaked, faster version of SHA-2. It’s not a new algorithm built on the same old Merkle–Damgård frame. SHA-3 is an architectural revolution. It deconstructs the very concept of a hash function and rebuilds it from the ground up using a single, elegant, and permutation-based primitive: the _sponge construction_. To understand SHA-3 is to understand not just a new algorithm, but a new way of thinking about the foundations of cryptographic security. This is not just a blog post; it is a journey into the heart of the sponge.

### Part 1: The End of an Era – Why SHA-2 Wasn't Good Enough

Before we celebrate the new champion, we must understand the limitations of the old guard. The Merkle–Damgård construction, invented by Ralph Merkle and Ivan Damgård in the late 1980s, was a masterpiece of cryptographic engineering. It took a secure compression function, which maps a fixed-size input to a smaller output, and chained it together to process messages of arbitrary length. The model was simple: divide the message into blocks, feed each block into the compression function along with the previous output, and output the final state. It was the backbone of MD5, SHA-1, and SHA-2.

However, after decades of deep analysis, cryptanalysts began to see the cracks in the chassis. The most well-known vulnerability is the **length extension attack**.

**The Length Extension Attack in Detail:**

Imagine you have a secret password `S` and your password manager generates an authentication token using SHA-2: `H = SHA-2(S || M)`, where `M` is a message like "Allow access to account 1234". An attacker doesn't know `S` or `H`, but they _do_ know the output `H` and the length of `S` (or can guess it approximately). The Merkle–Damgård construction allows them to compute `SHA-2(S || M || Padding || M')` without knowing `S`. How? Because the final hash is simply the internal state of the compression function after processing all blocks. The attacker can "continue" the hashing process from that final state, reinitialize a new hash computation using `H` as the starting chaining value, and append a new block `M'`. This yields a valid hash for a longer message. The implications are severe: an attacker can forge a signature for a message they never saw, all because the hash function's internal state leaks.

This flaw is not a bug; it is an inherent property of the construction. SHA-2 cannot be used directly in MACs (Message Authentication Codes) without a specific construction like HMAC, which introduces a second pass to prevent this. It is a band-aid.

Furthermore, the Merkle–Damgård structure creates a _sequential_ dependency. Each block must be processed in order. This makes parallelism difficult to achieve natively without additional design work. And while SHA-2 has withstood decades of cryptanalysis, the lingering fear of a collision attack (like the one that shattered SHA-1 in 2017) was enough to push NIST—and the cryptographic community—toward a new standard.

NIST opened the SHA-3 competition in 2007. They wanted a hash function that was not just faster or stronger, but fundamentally _different_. They wanted a new architecture that would survive attacks that might eventually break SHA-2. The winner was Keccak, designed by Guido Bertoni, Joan Daemen, Michaël Peeters, and Gilles Van Assche. Keccak didn't just offer a different compression function; it offered a different _universe_: the sponge.

### Part 2: The Philosophy of the Sponge – Soaking and Squeezing

The core idea of the sponge construction is beautifully simple. Imagine a physical sponge. You have a fixed capacity for absorbing water. To use it, you first **absorb** water (the input), and then you **squeeze** it out (the output). The sponge doesn't care how big the water bucket is; it just soaks up what it can fit in its pores, and squeezes out as much as you need. This is precisely how the cryptographic sponge works.

A sponge function is built around a **fixed-length transformation (or permutation) `f`** that operates on a state of `b` bits. This state `b` is divided into two parts:

- **The "Rate" (`r`)**: The size of the data chunk absorbed or squeezed in each operation. This determines the speed of the hash function.
- **The "Capacity" (`c`)**: The internal, hidden portion of the state. This determines the security level against attacks.

The total state size `b = r + c`. For SHA-3, `b` is fixed at 1600 bits (200 bytes). The transformation `f` is the **Keccak-f permutation**, which permutes this 1600-bit state in a series of clever, invertible steps. It is crucial that `f` is a permutation, meaning it is a bijection (one-to-one and onto). This property is what gives the sponge its unique security guarantees, as we will see.

The hash function operates in two distinct phases:

**Phase 1: The Absorbing Phase**

1.  **Initialization**: The 1600-bit state is initialized to all zeros.
2.  **Padding**: The input message is padded to a multiple of the rate size `r`. The padding rule is critical, but we will dive into it later.
3.  **Block Processing**: The padded message is split into blocks of size `r` bits. For each block:
    - XOR the block into the first `r` bits of the current state.
    - Apply the full Keccak-f permutation `f` to the entire 1600-bit state.

This is the "soaking up" process. The message is sequentially injected into the state through the rate portion. The capacity remains untouched by the message, ensuring that the internal state's entropy is never directly exposed.

**Phase 2: The Squeezing Phase**

1.  **Output Generation**: After all input blocks are processed, the state is "full." Now we squeeze out the hash.
2.  **First Output**: The first `r` bits of the current state are output as the first chunk of the digest.
3.  **Further Output (If Needed)**: If the desired output length exceeds `r`, we apply `f` again to the entire state, and output the next `r` bits. This process repeats until we have squeezed out the entire desired output.

This is where the magic happens. We are not done with a fixed-size output. We can squeeze out _arbitrary length_ data. This makes the sponge an **Extendable Output Function (XOF)**. SHA-3 is a XOF that truncates its output to standard lengths (224, 256, 384, 512 bits). The underlying sponge, however, can produce infinite output if we keep squeezing. (In practice, NIST defines specific XOFs like SHAKE128 and SHAKE256 based on the same sponge).

The entire process can be visualized as a simple loop:

```
State = 0^b

# Absorb Phase
for each message_block in padded_message:
    State[0:r] ^= message_block
    State = f(State)

# Squeeze Phase
digest = empty
while len(digest) < desired_output_length:
    digest += State[0:r]  # Append first r bits
    State = f(State)

return digest[0:desired_output_length]
```

This is remarkably elegant. The entire complexity, strength, and speed of the hash is dictated by the quality of the permutation `f` and the ratio of `r` to `c`. A high `r` (like 1024 bits in SHA3-256) makes the hash faster because you absorb more data per permutation call. A high `c` (like 512 bits in SHA3-256) provides greater security margin, but requires more internal state to be hidden from an attacker.

### Part 3: The Heart of the Machine – The Keccak-f Permutation

The permutation `f` is the engine. If the sponge is the car, Keccak-f is the engine block. It is a 24-round iterative permutation (for the 1600-bit state, though smaller versions exist with fewer rounds) designed to be highly non-linear and diffusive. Each round consists of five distinct, carefully orchestrated steps, known collectively as the **Keccak-f Round Function**. These five steps are designed to ensure that a single bit change in the input results in a complete avalanche of changes across the entire 1600-bit state after just a few rounds.

The state is best visualized not as a simple 1600-bit vector, but as a 5x5x64 (25 x 64) three-dimensional array of bits. It can be thought of as a 5x5 grid of "lanes", where each lane is a 64-bit word. This three-dimensional structure is crucial to the design, allowing the permutation to mix bits both across lanes and along the bit positions.

Let's break down the five steps of each round: **Theta (θ), Rho (ρ), Pi (π), Chi (χ), and Iota (ι)**.

#### Step 1: Theta (θ) – The Confuser of Columns

Theta is the primary diffusion step. It is designed to mix bits along the vertical columns of the 5x5x64 state. The goal is to make every bit in the state depend on the parity of the columns around it.

Mathematically, Theta works in two sub-steps:

1.  **Compute Column Parity**: For each column (a specific x,z coordinate), compute the sum (XOR) of all 5 bits in that column. Let this 5x64 parity array be `C[x][z]`.
2.  **Compute Column Parity Deltas**: For each column, compute a "delta" value `D[x][z]`. The delta for a column is the XOR of the parity of the column to its left (`C[(x-1) mod 5]`) and the parity of the _rotated_ column two positions to its right (`C[(x+1) mod 5][z-1]`). This rotation is essential for ensuring bits are mixed across the z-axis, not just the x-axis.
3.  **Apply the Deltas**: XOR the delta `D[x][z]` into every bit of the entire lane at `(x, z)`.

**Why It Matters**: Theta ensures that a change in a single lane affects the parity of its column. This column parity change is then propagated to every other lane in that column, and also to adjacent columns (through the use of the `D` array). It effectively spreads local changes rapidly across the vertical dimension. Without Theta, the permutation would have very poor diffusion, and a collision attack would be trivial.

#### Step 2: Rho (ρ) – The Rotator of Lanes

Rho is a simple but crucial bit-level rotation operation. Each of the 25 lanes (64-bit words) of the state is rotated by a fixed, non-cryptographic, but specially chosen constant. Each lane gets a different rotation offset. For example, the lane at position (0, 0) is not rotated. The lane at (1, 0) is rotated by 1 bit. The lane at (2, 0) by 62 bits, and so on. This offset table is predetermined and ensures that bits in different lanes spiral away from each other, dramatically increasing the diffusion across the 3D state.

**Why It Matters**: The Rho step breaks the bit-slice symmetry. If all lanes were processed identically, the state would be prone to pattern-based attacks. By rotating each lane by a different amount, Rho ensures that the same bit position in different lanes represents different bits of the original input. This prevents an attacker from building linear relationships between bits across lanes.

#### Step 3: Pi (π) – The Permuter of Lanes

Pi is a lane-level permutation. It takes the 25 lanes of the 3D state and rearranges their positions in a 5x5 grid. It does this by taking the lane at coordinates (x, y) and moving it to new coordinates (y, 2x + 3y mod 5). It's a specific, mathematically invertible permutation. It is a deterministic, designed to be a matrix multiplication over the GF(2) field.

**Why It Matters**: Theta mixes bits within the x-z plane (columns). Rho rotates bits within each lane. But Pi mixes bits across the y dimension. Without Pi, the permutation would be decomposable into 5 independent 1D permutations, making it trivial to parallelize attacks. Pi ensures that the column mixing from Theta and the lane rotation from Rho are applied to lanes that are now in a completely different location in the next round. This forces the diffusion to be truly three-dimensional.

#### Step 4: Chi (χ) – The Non-Linear Gate

Chi is the only non-linear component of the permutation. It operates on the rows of the 5x5x64 state. It is a 5-bit to 5-bit mapping applied to each row. For each of the 5 rows (the bits at `(0,y)`, `(1,y)`, `(2,y)`, `(3,y)`, `(4,y)`), the output bit at position `x` is defined as:

`output[x] = input[x] XOR ( (NOT input[(x+1) mod 5]) AND input[(x+2) mod 5] )`

This is a simple, algebraic expression, but it is critically important. It is the only step that is not a linear XOR operation. Without non-linearity, the entire permutation could be represented as a giant system of linear equations, which a quantum computer or classical linear algebra could solve to find a preimage or collision. Chi is the "bouncer" that prevents this. It provides the vital **confusion** necessary for cryptographic security.

**Why It Matters**: Non-linearity is the heart of cryptographic primitives. Without it, a hash function is broken. Chi is elegantly simple but introduces enough algebraic complexity to thwart known attacks. It is also entirely bit-sliced, meaning it can be implemented very efficiently using simple bitwise operations (XOR, AND, NOT) on modern CPUs.

#### Step 5: Iota (ι) – The Round Constant Injector

Iota adds a round-dependent constant to a single lane of the state (specifically, the lane at position (0, 0)). This constant is different for each of the 24 rounds. It is derived from a linear feedback shift register (LFSR). The constants are all sparse, having only a handful of bits set.

**Why It Matters**: This step is seemingly trivial, but it is essential for preventing symmetry. Without Iota, all 24 rounds would be identical. An attacker could exploit a symmetry in the state to find fixed points or collisions. By injecting a unique constant every round, Iota breaks any potential symmetry between rounds of the permutation. It also breaks the alignment between the absorbing and squeezing phases, providing a defense against slide attacks and related-key attacks.

### Part 4: The Sponge in Action – Padding and the Multi-Rate Sponge

Now that we understand the engine, we need to understand how we feed the fuel into it. This is where **padding** comes in. The message must be padded to a multiple of the rate `r`. But the padding rule is not arbitrary. For SHA-3, the padding scheme is called **multi-rate padding** (specifically, **pad10\*1**).

**pad10\*1**: Append a '1' bit to the message, append zero or more '0' bits, and finally append another '1' bit. The total length of the padded message must be a multiple of `r`.

The elegance of this padding is uncanny. The leading '1' and trailing '1' act as delimiter. The sequence "10\*1" ensures that there is exactly one '1' at the start and one '1' at the end of the padding. This is crucial for two reasons:

1.  **Prevents Padding Removal Attacks:** In older constructions, padding could be ambiguous. For example, if the message ends in '0', the padding might be '100' or '10 0 0...'. pad10\*1 exactly defines the padding as "10...1", so there is no ambiguity when removing it.
2.  **Domain Separation:** The first bit of the "1" tells the sponge that this is a fresh input block. The final "1" tells the sponge that this is the last block. This separation is critical for security proofs.

Furthermore, Keccak uses a special **domain separation** bit. For SHA-3 hash functions, a '01' byte is appended to the message before padding. For SHAKE XOFs, a '11' byte is appended. This ensures that even if you use the same underlying sponge with the same rate, you never get the same output for a hash versus a XOF. It is a cryptographic firewall between the two modes.

### Part 5: Security Margins – The Secret of the Capacity

You might ask: "If the permutation `f` is a permutation, and it's invertible, can't I just invert the entire sponge?" The answer is a resounding _no_, because the state is never fully revealed. The **capacity `c`** is the secret.

Recall: the state is `b = r + c`. During the absorb phase, only the first `r` bits are affected by the message. The capacity `c` is never directly fed with the input, and during the squeezing phase, only the first `r` bits of the state are output. The capacity `c` remains hidden at all times.

This hidden capacity is the root of the sponge's security. Consider a collision attack. An attacker wants to find two different messages that produce the same output. To do this, they would need to find two different internal states (after processing each block) that eventually converge to the same final state. However, the attacker cannot directly observe the capacity, so they cannot tell if two different inputs lead to the same internal state. They essentially have to guess the `c` bits. The probability of a collision is roughly `2^(-c/2)` (the square root of the capacity). This is the classic birthday bound.

For SHA-3-256, the capacity `c` is 512 bits, and the rate `r` is 1088 bits (1600 - 512 = 1088). The security level is 256 bits because 512/2 = 256. For SHA-3-512, the capacity is 1024 bits, giving a security level of 512 bits.

But here is the genius: the capacity also protects against **state recovery attacks**. Even if an attacker learns the entire output of the squeezing phase (which is just the rate bits), they cannot reconstruct the full 1600-bit state because they don't know the `c` bits. Without the full state, they cannot reverse the `f` permutation to discover the previous state. This makes the sponge resistant to future quantum attacks or advanced cryptanalysis that might allow partial state recovery.

The security margin is essentially how much of the state is hidden. A higher capacity provides a bigger margin, but at the cost of speed. The trade-off is deliberate. NIST selected specific parameters (`c = 2 * output_length`) to provide a generous, future-proof security margin that is simpler to reason about than the complex resistance analysis required for SHA-2.

### Part 6: A Practical Example – Hashing "Hello" with SHA-3-256

Let's solidify everything with a simplified, conceptual example. We'll use SHA-3-256: `r = 1088 bits`, `c = 512 bits`.

1.  **Input**: The message "Hello" (40 bits = 5 bytes).
2.  **Domain Separation**: Append '01' byte -> "Hello\x01" (48 bits).
3.  **Padding**: We need the total length to be a multiple of 1088. 48 bits is not. We apply pad10*1: append a '1' bit, then as many '0's as needed, then another '1'. Let's calculate. The padded message length `L` must satisfy `L mod 1088 = 0`. We start with 48 bits, add 1 (the first '1'), then add `x` zeros, then add 1 (the final '1'). So `48 + 1 + x + 1 = 50 + x` must be a multiple of 1088. The next multiple is 1088 * 1 = 1088. So `50 + x = 1088` => `x = 1038`. So we pad with 1 bit, 1038 zeros, and 1 bit. Total padded message length = 1088 bits.
4.  **Absorb**: The padded message is exactly one 1088-bit block. We XOR it into the first 1088 bits of the all-zero state.
5.  **Apply f**: We apply the 24-round Keccak-f permutation to the entire 1600-bit state.
6.  **Squeeze**: We need a 256-bit digest. The first 1088 bits of the state are our candidate. We take the first 256 bits of that. That is our SHA-3-256 hash of "Hello". (We do not apply `f` again because we already have enough output.)
7.  **Output**: `0x3338be694f50c5f338814986cdf0686453a10b0cec90ca6550c96d30d3c8e57c` (This is the actual SHA-3-256 hash of "Hello").

Now, if we had wanted a 1024-bit hash, we would take the first 1088 bits from the state, truncate to 1024 bits. That's it. No extra rounds needed. This is why the sponge is so powerful for XOFs.

### Part 7: Why It Matters – The Practical Implications

The SHA-3 sponge construction is not just an academic curiosity. It has profound practical implications for the future of cryptography.

- **Resistance to Length Extension**: The sponge is inherently resistant. Since the internal state is never fully revealed, an attacker cannot "continue" a hash computation from a known output. This makes SHA-3 safe to use directly in MACs without needing HMAC.
- **Strong Security Margins**: The capacity-based security model provides a clean, mathematical guarantee. It's easier to reason about than the complex security of Merkle-Damgård. NIST chose conservative parameters, giving us a hash function that is arguably over-engineered for today's threats, making it more future-proof.
- **Elegant Simplicity**: The permutation `f` is the only heavy part. The absorbing, squeezing, and padding are trivial to implement correctly. This reduces the chance of implementation errors.
- **Parallelism**: While the sponge is inherently sequential (you must absorb before squeezing), the permutation `f` itself is highly parallelizable. Modern CPUs can execute the Theta, Rho, Pi, Chi, and Iota steps in a way that exploits SIMD instructions (like AVX-512), making Keccak incredibly fast in hardware and software.
- **The Dawn of XOFs**: The ability to produce arbitrary-length output is a game-changer. SHAKE128 and SHAKE256 are already being used in new protocols like TLS 1.3 (as a PRF) and Ed25519 (as a hash function). XOFs eliminate the need for multiple hash sizes and complex KDF constructions.

### Conclusion: The Sponge’s Legacy

As we close this deep dive, we should pause to appreciate the sheer elegance of the design. Cryptography is often about brute force—long keys, complex algorithms, and tons of rounds. The SHA-3 sponge is the opposite. It is a minimalist masterpiece. It deconstructs the hash function down to its core: a permutation, a rate, a capacity, and a simple loop. It proves that security does not have to come from complexity; it can come from a clever, well-understood architecture.

The next time you use SHA-3 (and you likely will, as it becomes increasingly standardized), remember that you are not just using a hash function. You are using a sponge. A simple, beautiful, and remarkably secure sponge that is busy absorbing and squeezing, silently protecting the data that powers our digital world. The old racehorse has been put out to pasture. The new champion is here, and it's built to last.
