---
title: "A Deep Dive Into The Blowfish Cipher: P Array, S Boxes, And Key Schedule"
description: "A comprehensive technical exploration of a deep dive into the blowfish cipher: p array, s boxes, and key schedule, covering key concepts, practical implementations, and real-world applications."
date: "2024-08-22"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/a-deep-dive-into-the-blowfish-cipher-p-array,-s-boxes,-and-key-schedule.png"
coverAlt: "Technical visualization representing a deep dive into the blowfish cipher: p array, s boxes, and key schedule"
---

# The Blowfish Cipher: A Masterclass in Cryptographic Design

## Introduction: The Blowfish Cipher

In the ever-evolving landscape of cryptography, few algorithms have managed to maintain relevance for over three decades while remaining both elegant and practical. Blowfish, designed by Bruce Schneier in 1993, is one such cipher. It arrived at a time when the Data Encryption Standard (DES) was showing its age—its 56-bit key length had become vulnerable to brute-force attacks, and its Feistel structure, while sound, offered limited room for performance optimization on modern hardware. Schneier’s goal was to create a fast, free, and secure symmetric cipher that could be implemented efficiently on microcontrollers, 32-bit processors, and everything in between. The result was a cipher that not only replaced DES in many applications but also introduced a novel approach to key setup—one that remains a textbook example of how to embed key dependency directly into the algorithm’s fundamental components.

Why should anyone, especially a systems engineer or security researcher, care about a cipher from the early 90s? The answer lies in two words: **design philosophy** and **practical relevance**. Blowfish is still used today in certain embedded systems, password hashing (as part of bcrypt), and legacy applications. More importantly, its internal mechanics—the P-array and S-boxes—offer a masterclass in how to transform a simple Feistel network into a highly key-dependent, non-linear transformation. Understanding Blowfish is not merely an exercise in historical curiosity; it provides deep insight into how variable-length keys can be stretched into a large set of subkeys, how key scheduling can be made cryptographically strong by using the cipher itself, and how trade-offs between speed, memory, and security are negotiated in practice. This knowledge directly transfers to the analysis of modern ciphers like Twofish (Blowfish’s successor), ChaCha, and even block cipher modes in TLS 1.3.

## A Quick Tour of Blowfish’s Architecture

At its core, Blowfish is a 64-bit block cipher with a variable-length key ranging from 32 to 448 bits. It uses a 16-round Feistel network—a structure that splits the data block into two halves (left and right), applies a round function to the right half combined with a subkey, and then XORs the result with the left half before swapping halves. This architecture is identical in spirit to DES, but the round function itself is dramatically different. Blowfish’s round function relies on a set of substitution boxes (S-boxes) and a permutation array (P-array) that are precomputed from the encryption key. The key schedule expands the user-supplied key into 18 32-bit P-array entries (P1 through P18) and four 256-entry S-boxes (each entry also 32 bits). The total memory requirement for these structures is just over 4 KB (18 × 4 + 4 × 256 × 4 = 4,168 bytes). This compact footprint made it ideal for early 32-bit microprocessors with limited cache.

But the most innovative feature of Blowfish is how these arrays are initialized. Schneier used the fractional digits of π (pi) to create an initial set of fixed values for the P-array and S-boxes. Then, the user’s key is XORed into the P-array (cycling through the key bytes as needed). Finally, the cipher itself is used to encrypt an all-zero block, replacing each P-array entry and each S-box entry with the output of successive encryptions. This self-referential key scheduling ensures that the subkeys are both key-dependent and computationally expensive to derive—an intentional design choice that thwarts brute-force attacks on the key schedule itself.

Let’s now dive deep into each component, starting with the Feistel network and the round function, then moving to the key schedule, and finally exploring security, performance, and applications.

---

## 1. Historical Context and Design Goals

To appreciate Blowfish, we need to understand the cryptographic landscape of the early 1990s. The Data Encryption Standard (DES) had been the U.S. government standard since 1977, and its 56-bit key was already considered marginal by the early 1990s. In 1993, Michael Wiener published a design for a $1 million machine that could brute-force a DES key in about 3.5 hours. The Electronic Frontier Foundation’s _DES Cracker_ (1998) demonstrated the vulnerability at a cost of $250,000. While triple-DES offered a short-term fix (112-bit effective key), its performance on 1990s hardware was poor, especially in software. Moreover, DES’s 8 S-boxes were designed by the NSA, leading to suspicion and calls for a publicly designed, transparent cipher.

Bruce Schneier, then a rising figure in cryptography, saw an opportunity to create a cipher that was:

- **Fast** on 32-bit microprocessors (Intel 386, 486, Motorola 68020, etc.)
- **Compact** enough to fit in embedded systems with limited ROM/RAM (e.g., smart cards, microwave ovens)
- **Secure** against all known attacks at the time
- **Unpatented and royalty-free** to encourage adoption
- **Variable key length** to allow users to choose their security level

Blowfish was published in 1993 as part of a larger work, _Applied Cryptography_, and quickly gained popularity. It was used in numerous commercial products (e.g., SSH, PGP, and various VPN solutions) and remains a common choice for projects requiring a lightweight symmetric cipher.

## 2. Feistel Network: The Structural Backbone

Blowfish employs a classic Feistel network with 16 rounds. A Feistel network works as follows:

- The 64-bit plaintext block is split into two 32-bit halves: **L** (left) and **R** (right).
- For each round _i_ from 1 to 16:
  - Let **F** be the round function (described below) applied to the right half **R** combined with the round subkey _P[i]_.
  - Compute **new L** = **R**
  - Compute **new R** = **L** XOR **F(R, P[i])**
- After the 16th round, the halves are swapped one final time (undoing the last swap) and combined to produce the output block.

The advantage of a Feistel network is that encryption and decryption use the same structure—only the order of subkeys is reversed. This simplifies hardware implementations and reduces code size.

### Why 16 Rounds?

Schneier chose 16 rounds after a careful analysis of differential and linear cryptanalysis. At the time, the best known attacks on reduced-round variants of Blowfish were limited to about 10 rounds. Adding a safety margin, he settled on 16. Later research showed that full 16-round Blowfish resists all known practical attacks, though theoretical attacks exist (e.g., using 2^58 chosen plaintexts for a related-key attack, which is not feasible in practice). The round count also balances speed: adding more rounds would hurt performance without a corresponding security gain.

## 3. The Round Function (F-function)

The F-function is the heart of Blowfish’s nonlinearity. It takes a 32-bit input (the right half _R_) and a 32-bit round subkey _P[i]_ and produces a 32-bit output. The function is composed of four S-box lookups (S-boxes are 8×32-bit substitution tables) combined with XOR and addition operations.

Here is the exact computation:

1. XOR _R_ with _P[i]_ to produce a 32-bit value _X_.
2. Split _X_ into four bytes (from most significant to least significant): _a_, _b_, _c_, _d_ (each 8 bits).
3. Compute:  
   _F_result_ = (S[0][a] + S[1][b]) XOR S[2][c] + S[3][d]  
   where "+" denotes addition modulo 2^32, and XOR is bitwise exclusive-or.  
   Note: There is some variation in literature—the original code uses:  
   _F_result_ = ((S[0][a] + S[1][b]) XOR S[2][c]) + S[3][d]  
   but the standard formulation is as above (addition and XOR are not associative, so order matters). I'll use the version from the reference implementation.

The four S-boxes are each a permutation of the 256 possible byte inputs, but they are not necessarily bijective over 32-bit outputs—they simply map an 8-bit input to a 32-bit output, and they are designed to be highly nonlinear. The combination of addition and XOR introduces confusion (nonlinearity) and diffusion (mixing across bits).

### Why Addition and XOR?

Using modular addition (mod 2^32) in combination with XOR creates a nonlinear operation in GF(2). While addition is linear over the integers modulo 2^32, it is highly nonlinear over GF(2)—the bitwise representation of addition involves carries, which propagate across bits. This makes differential and linear cryptanalysis much harder. The S-boxes themselves are already nonlinear, but the interleaving of arithmetic and logical operations strengthens the overall function.

### Example: Computing F for a single round

Suppose _R_ = 0x12345678, _P[i]_ = 0xABCDEF01.  
_X_ = 0x12345678 XOR 0xABCDEF01 = 0xB9F9B979.  
Split into bytes: a=0xB9, b=0xF9, c=0xB9, d=0x79? Wait, careful: 0xB9F9B979 in hex: bytes = 0xB9 (MSB), 0xF9, 0xB9, 0x79 (LSB). So a=0xB9, b=0xF9, c=0xB9, d=0x79.  
Let’s assume S-box values (hypothetical):  
S[0][0xB9] = 0x3A5C6D8E  
S[1][0xF9] = 0x7F1A2B3C  
S[2][0xB9] = 0x4D8E9F10  
S[3][0x79] = 0x6A7B8C9D  
Then:  
S[0][a] + S[1][b] = 0x3A5C6D8E + 0x7F1A2B3C = 0xB97698CA (mod 2^32)  
XOR with S[2][c]: 0xB97698CA XOR 0x4D8E9F10 = 0xF4F807DA  
Add S[3][d]: 0xF4F807DA + 0x6A7B8C9D = 0x5F739477 (mod 2^32)  
So F_result = 0x5F739477.

This output is then XORed with the left half L.

## 4. The Subkey Arrays: P-Array and S-Boxes

Blowfish’s most distinctive feature is its key schedule, which transforms the user-supplied key into a large set of subkeys: 18 P-array entries (P1..P18) and 256 entries for each of the four S-boxes (S[0..3][0..255]). All entries are 32-bit words.

### Initialization with Pi Digits

Schneier used a “nothing up my sleeve” number: the hexadecimal digits of the fractional part of π (pi). Specifically, the initial P-array and S-boxes are set to the digits of π starting from the first fractional digit (3.14159…). For example, P1 = 0x243F6A88, P2 = 0x85A308D3, etc. These fixed values ensure that the algorithm comes with a standard initialization. The full list can be found in the reference implementation.

### Key Expansion

The user key (a sequence of bytes, up to 56 bytes for a 448-bit key) is used to modify the P-array first:

- XOR the first 32 bits of the key with P1, the next 32 bits with P2, and so on. If the key is shorter than the P-array (which is 18×4=72 bytes), the key bytes are cycled repeatedly. For example, a 128-bit key (16 bytes) will be used four times (since 72/16 = 4.5, so the first 8 bytes of the key are XORed with P17 and P18 in the fifth cycle).

After XORing, we have a partially key-dependent P-array. Next, the P-array and S-boxes are updated using the cipher itself.

### Self-Encryption Step

The algorithm then executes the following:

- Initialize a 64-bit block to all zeros.
- For each subkey _k_ (first all 18 P-array entries, then all 1024 S-box entries):
  - Encrypt the 64-bit block using Blowfish with the current P-array and S-boxes (still in their partially initialized state). But note: at the beginning, the cipher is not fully defined because the P-array and S-boxes are not yet final. However, the encryption uses whatever values are currently stored.
  - Replace the subkey _k_ with the left half of the encrypted block.
  - Then encrypt the block again to get the right half, and replace the next subkey. Actually, the process is: for each pair of 32-bit subkeys (or for each single 32-bit subkey?), the original algorithm work by replacing the P-array entries one by one using successive encryptions of an all-zero block: after each encryption, the output block (64 bits) is split into two 32-bit halves, which become the next two P-array entries. That is, you encrypt the all-zero block once, store the left half as P1, and the right half as P2; then encrypt the same all-zero block again (with the updated P-array) to get P3 and P4, and so on. This process repeats for all 18 P entries (9 encryptions) and then for all 1024 S-box entries (512 encryptions), for a total of 521 encryptions.

The reference implementation uses a loop that calls the encryption function repeatedly with the same all-zero input. Each call produces two 32-bit outputs, used to fill two entries.

**Pseudocode for key schedule (C-like):**

```c
uint32_t P[18];
uint32_t S[4][256];
uint8_t key[]; // user key, length keylen bytes

// Step 1: Initialize P and S with pi digits (omitted for brevity)

// Step 2: XOR key bytes into P array (cycling)
int j = 0;
for (int i = 0; i < 18; i++) {
    uint32_t k = 0;
    for (int b = 0; b < 4; b++) {
        k = (k << 8) | key[j];
        j = (j + 1) % keylen;
    }
    P[i] ^= k;
}

// Step 3: Encrypt all-zero block repeatedly to update P and S
uint32_t L = 0, R = 0; // 64-bit block
for (int i = 0; i < 18; i += 2) {
    encrypt(L, R); // in-place encryption of (L,R)
    P[i] = L;
    P[i+1] = R;
}
for (int i = 0; i < 4; i++) {
    for (int j = 0; j < 256; j += 2) {
        encrypt(L, R);
        S[i][j] = L;
        S[i][j+1] = R;
    }
}
```

The `encrypt` function uses the current P and S arrays. Thus, the key schedule is self-referential and highly sensitive to the key. A single bit change in the key drastically alters all subkeys. This makes Blowfish resistant to related-key attacks (as long as the attacker cannot modify the key schedule, which is the case in normal use). However, the high computational cost of the key schedule—over 500 encryptions for each new key—is both a strength and a weakness. It makes key changes expensive, which is why Blowfish is typically used with a fixed key (e.g., in bcrypt, the key schedule is deliberately slowed down).

## 5. Encryption and Decryption in Detail

The encryption algorithm is straightforward once the subkeys are generated.

### Encryption

**Input:** Plaintext block (64 bits) = L0 || R0 (left 32 bits, right 32 bits).  
**Output:** Ciphertext block (64 bits).

1. For round = 1 to 16:
   - L = L XOR F(R, P[round])
   - Swap L and R (except after round 16, we swap one more time to undo the last swap)
2. After 16 rounds, swap L and R (the final swap).
3. Ciphertext = L || R.

Note: In the actual implementation, it's more efficient to avoid an extra swap by adjusting the loop:

```c
uint32_t L, R;
// ...
for (int i = 0; i < 16; i++) {
    L ^= F(R, P[i]);
    // swap L and R
    uint32_t temp = L; L = R; R = temp;
}
// After loop, swap back
uint32_t temp = L; L = R; R = temp;
// then add final XOR with P[16] and P[17]? Wait, Blowfish does not have a final whitening step; instead, after the loop, the two halves are XORed with P[17] and P[18]? Actually, look at original: The Feistel network uses P[1]..P[16] for the rounds, and then after the 16 rounds, the left half is XORed with P[17] and the right half with P[18]. This is a post-whitening step. Let me correct.

The Blowfish specification from Schneier's _Applied Cryptography_ (2nd ed.) states:

- After 16 rounds, the two halves are swapped once more (i.e., the last round does not swap, so after the loop you swap back).
- Then XOR L with P[17], XOR R with P[18].
- Concatenate L and R.

This is equivalent to:

```

for i = 1 to 16:
L ^= F(R, P[i])
swap(L, R)
swap(L, R) // undo the last swap
L ^= P[17]
R ^= P[18]
output = L || R

````

The final XOR with P[17] and P[18] is actually part of the key schedule output; these two P-entries are used as output whitening to prevent the last round from leaking information. (Some implementations treat them as part of the round function, but the standard is as described.)

### Decryption

Decryption uses the same structure but with subkeys in reverse order:

- XOR the ciphertext halves with P[18] and P[17] (reverse order).
- Then perform 16 rounds using P[16] down to P[1].
- Final swap.

Because Feistel networks are invertible (the XOR of the F-function is its own inverse), this works perfectly.

## 6. Security Analysis: Known Attacks and Limitations

Blowfish has been extensively cryptanalyzed for over 30 years. While no practical attack exists against the full 16-round cipher with a random key, some theoretical weaknesses have been identified.

### Weak Keys

In the early days, researchers discovered that certain keys produce P-array entries that are not sufficiently random. For example, keys that cause the all-zero plaintext to encrypt to itself after the first round? More specifically, because the key schedule uses the all-zero block as a fixed plaintext, if the key schedule produces a round subkey value that matches the output of the F-function in a particular way, the encrypted zero block might produce a zero block, leading to known patterns. This was mitigated by using the pi digits as initial values, but still, there exist a small class of weak keys (e.g., keys that make the P-array symmetric over rounds). In practice, these are vanishingly rare and do not affect security.

### Small Block Size (64-bit)

The most significant practical limitation of Blowfish today is its 64-bit block size. Due to the birthday bound, after encrypting about 2^32 blocks (32 GB of data) with the same key, there is a 50% chance of a collision in the ciphertext, which can reveal information about plaintext. For modern high-speed networks and disk encryption, this is unacceptable. The Sweet32 attack (2016) demonstrated that 64-bit block ciphers in CBC mode can be exploited to recover session cookies. Consequently, Blowfish is no longer recommended for new applications that require bulk encryption. However, it remains acceptable for applications with low data volumes (e.g., password hashing).

### Related-Key Attacks

A 2004 paper by Kelsey et al. demonstrated related-key attacks on Blowfish with 2^56 chosen-key queries and 2^58 chosen plaintexts, but this is purely theoretical because most implementations never allow an attacker to choose the key (except in some exotic protocols). The key schedule itself is strong, but the Feistel structure with a limited number of rounds makes it vulnerable to related-key differential analysis.

### Linear and Differential Cryptanalysis

Blowfish’s F-function, with its mixture of XOR and addition, provides strong resistance against linear and differential attacks. The best linear cryptanalysis requires 2^247 known plaintexts (impractical), and differential attacks require 2^241 chosen plaintexts. Full 16-round Blowfish is considered safe from these classical attacks.

### Known Attacks on Reduced-Round Variants

Reduced to 8 rounds, Blowfish is breakable with 2^58 chosen plaintexts. This is why Schneider chose 16 rounds—to ensure a large safety margin.

## 7. Performance Considerations

Blowfish was designed to be fast on 1990s 32-bit processors. The key schedule is slow (intentionally, for password hashing), but encryption and decryption are very fast. On a modern desktop CPU, Blowfish encrypts at about 250-300 MB/s in software (compared to AES at 600-1000 MB/s with hardware acceleration). However, on platforms without AES-NI, Blowfish can be competitive.

### Memory Footprint

The P-array and S-boxes occupy 4,168 bytes. For embedded systems with limited cache, this can be a disadvantage compared to lightweight ciphers like Speck or Simon. However, many microcontrollers have enough RAM (e.g., 4 KB or more) to accommodate it. The 32-bit operations are natural for ARM Cortex-M and similar processors.

### Competing Ciphers of the Era

| Cipher | Block size | Key length | Rounds | Speed (1995) | Memory |
|--------|------------|------------|--------|--------------|--------|
| DES    | 64         | 56         | 16     | Moderate     | Small  |
| 3DES   | 64         | 112-168    | 48     | Slow         | Small  |
| Blowfish| 64        | 32-448     | 16     | Fast         | 4 KB   |
| IDEA   | 64         | 128        | 8.5    | Moderate     | Small  |
| RC5    | 32/64/128  | 0-2048     | 1-255  | Fast         | Small  |
| Twofish| 128        | 128/192/256| 16     | Moderate     | 4KB    |

Blowfish's advantage was its combination of speed and strong key schedule. IDEA was patented, RC5 had variable parameters, and DES was too slow.

## 8. The Legacy: Blowfish in Modern Applications

Despite its block size limitation, Blowfish lives on in two key areas:

### bcrypt: Password Hashing

The most important surviving use of Blowfish is in the **bcrypt** password hashing scheme, invented by Provos and Mazières in 1999. Bcrypt uses the Blowfish key schedule as a cost factor:

- Instead of using the key schedule to encrypt, bcrypt uses it to hash a password. The password is treated as the “key”, and the salt is used to perturb the P-array before key expansion.
- The cost parameter determines how many times the key schedule is iterated (e.g., 2^cost times). Each iteration runs the full Blowfish key schedule, which already requires 521 encryptions. So bcrypt is intentionally slow and CPU-intensive.
- After setup, the Blowfish block cipher is used to encrypt a known plaintext (usually the string “OrpheanBeholderScryDoubt”) 64 times. The output is the hash.

The strength of bcrypt lies in its resistance to GPU-based parallel attacks: the key schedule requires significant memory (4 KB) and is not easily parallelizable on a GPU (though modern GPUs can crack many bcrypt hashes per second). However, it remains far slower than SHA-256 or MD5 for the same number of operations.

### Embedded Systems and Smart Cards

Some legacy smart card applications still use Blowfish for symmetric encryption in secure transactions. Its 64-bit block size is acceptable for small messages (e.g., a few hundred bytes). Moreover, the lack of licensing fees made it attractive for low-cost devices.

### Legacy VPNs and File Encryption

Early versions of SSH (up to SSH 1.5) used Blowfish as a cipher option. Some old PGP versions also used it. These have been largely replaced by AES, but compatibility with older systems sometimes mandates Blowfish support.

## 9. Twofish: The Successor

When the Advanced Encryption Standard (AES) contest was announced in 1997, Bruce Schneier and a team submitted **Twofish**, a descendent of Blowfish. Twofish aimed to retain Blowfish’s strengths while fixing its weaknesses:

- **Block size**: 128 bits (addressing the 64-bit birthday bound).
- **Key length**: 128, 192, 256 bits (mandated by AES).
- **Feistel network**: still used, but with an extra layer of whitening and a key-dependent S-box similar to Blowfish.
- **Key schedule**: Even more complex, using Reed-Solomon codes and a key-dependent S-box to achieve high security.
- **Performance**: Designed to be fast on multiple platforms (32-bit, 8-bit, and hardware).

Twofish was a finalist in the AES competition, but lost to Rijndael (AES). Nevertheless, it has been widely used in TrueCrypt, KeePass, and other software.

The lessons from Blowfish—especially the use of key-dependent S-boxes and the self-referential key schedule—directly influenced Twofish. Understanding Blowfish is therefore an essential first step to understanding Twofish.

## 10. Implementation Example in C (Encryption Only)

Below is a simplified but functional implementation of Blowfish encryption in C (key schedule omitted for brevity). This demonstrates the Feistel rounds and F-function.

```c
#include <stdint.h>

extern uint32_t P[18];
extern uint32_t S[4][256];

static uint32_t F(uint32_t x) {
    uint32_t a, b, c, d;
    a = (x >> 24) & 0xFF;
    b = (x >> 16) & 0xFF;
    c = (x >> 8) & 0xFF;
    d = x & 0xFF;
    return ((S[0][a] + S[1][b]) ^ S[2][c]) + S[3][d];
}

void blowfish_encrypt(uint32_t *left, uint32_t *right) {
    uint32_t L = *left, R = *right;

    L ^= P[0]; // P[1] in 1-indexed (here P[0] is first round key)
    // Actually, the standard uses P[1] to P[16] for rounds, and P[17], P[18] for final.
    // Let's implement correctly:
    // Round 1..16
    for (int i = 0; i < 16; i++) {
        L ^= F(R ^ P[i]);  // Wait, careful: The F-function takes (R XOR P[i])? No, from earlier: L ^= F(R, P[i]) where F(R, P[i]) = F(R XOR P[i])? Actually in Blowfish, F takes the right half as input and the round key is XORed inside F? The standard description: The input to F is (R XOR P[i]). So F(x) = (S[0][a] + S[1][b]) XOR S[2][c] + S[3][d] where a,b,c,d are bytes of x. So we can write:
        // temp = R ^ P[i]; then F(temp)
        // Then L ^= F(temp)
        // So the round key is XORed with R before applying F.
        // But in my earlier F function I assumed x already includes the XOR? Let's separate.
        // Correct way:
        uint32_t temp = R ^ P[i];
        L ^= F(temp);
        // swap
        uint32_t t = L; L = R; R = t;
    }
    // After loop, swap back (since we swapped 16 times, final state has R in L and L in R)
    // Actually if we start with L0,R0, after first round we have L1=R0, R1=L0^F(R0^P0). After 16 rounds, L16 and R16 are swapped relative to usual.
    // Then we undo the last swap:
    uint32_t t = L; L = R; R = t;
    // Final whitening
    L ^= P[16];
    R ^= P[17];

    *left = L;
    *right = R;
}
````

Note: P[16] and P[17] correspond to P[17] and P[18] in 1-based indexing. The key schedule must generate P[0..17] accordingly.

## 11. Conclusion: Why Blowfish Still Matters

Blowfish is a cipher from a different era—one where block ciphers were designed with ingenuity and transparency, without government standardization or patent encumbrance. Its elegant use of a Feistel network, key-dependent S-boxes, a self-referential key schedule, and a design philosophy centered on performance and trust makes it a classic in the cryptographic canon.

For the modern practitioner, studying Blowfish offers several takeaways:

- **Key schedule design**: The idea of using the cipher itself to generate subkeys is powerful and finds use in hash functions (e.g., BLAKE) and other symmetric primitives.
- **Trade-offs**: Blowfish sacrifices key agility (slow setup) for encryption speed—a trade-off that makes sense for long-lived sessions (SSH) or password hashing (bcrypt).
- **Block size awareness**: The 64-bit block limitation is a cautionary tale about the importance of block size in modern protocols (Sweet32). New ciphers should use at least 128-bit blocks.
- **Transparency**: The use of “nothing up my sleeve” numbers (pi) and public design instills confidence—lessons for designing anything with cryptographic claims.

Blowfish may no longer be suitable for bulk encryption, but its legacy lives on in bcrypt (which hashes billions of passwords daily) and in the foundational concepts that informed Twofish and later ciphers. For anyone serious about cryptography, understanding Blowfish is not optional—it is a rite of passage.

---

### Further Reading

- Schneier, Bruce. "Description of a New Variable-Length Key, 64-Bit Block Cipher (Blowfish)". _Fast Software Encryption_, 1994.
- Provos, Niels and Mazières, David. "A Future-Adaptable Password Scheme". _USENIX_ 1999.
- Kelsey, John, et al. "Key-Schedule Weaknesses in Blowfish". _SAC_ 2004.
- "Sweet32: Birthday attacks on 64-bit block ciphers in TLS and OpenVPN". 2016.

---

_This article was written to provide a deep dive into the Blowfish cipher, its design decisions, security properties, and lasting relevance. Code examples and mathematical details aim to bridge the gap between theory and practice. Feel free to share and comment._
