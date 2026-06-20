---
title: "Implementing A Robust Checksum Algorithm: Adler 32 Vs. Crc 32C With Galois Field Multiplications"
description: "A comprehensive technical exploration of implementing a robust checksum algorithm: adler 32 vs. crc 32c with galois field multiplications, covering key concepts, practical implementations, and real-world applications."
date: "2024-08-30"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/implementing-a-robust-checksum-algorithm-adler-32-vs.-crc-32c-with-galois-field-multiplications.png"
coverAlt: "Technical visualization representing implementing a robust checksum algorithm: adler 32 vs. crc 32c with galois field multiplications"
---

# The Unseen Guardians: Implementing a Robust Checksum Algorithm – Adler-32 vs. CRC-32C with Galois Field Multiplications

**The Imperfect Mirror: A Digital Prelude**

Imagine you are a librarian at the Library of Alexandria, circa 300 BC. Your most sacred duty is to copy scrolls by hand. One scroll describes the architectural secrets of the Pharos lighthouse. As you squint, you copy a measurement: "The height is 117.5 meters." You pass it to your apprentice, who copies it for another patron. But the apprentice misreads your "5" as a "3." "The height is 117.3 meters." A single stroke of a reed pen, a minuscule error, and history is corrupted. The architect using this copy builds a tower the wrong height, and a century later, the lighthouse falls into the sea not because of a storm, but because of a misplaced digit.

This ancient problem—the silent propagation of error—is the original sin of information. In the modern world, the stakes are higher, but the problem is fundamentally the same. We are not copying scrolls; we are streaming 4K video across oceans, executing financial trades in microseconds, and storing exabytes of medical data in distributed object stores. The "scribes" are now spinning disks, solid-state drives, network cables, and cosmic rays. The "ink" is a stream of electrons, and the "reed pen" can be a voltage spike, a faulty memory cell, or a single bit flipped by a particle of background radiation.

This is the world where integrity is not a given; it is a product. And the tools we use to guarantee it are known, unglamorously, as **checksums**.

Checksums are the silent, tireless guardians of data integrity. They are the "are you sure?" we whisper to a file after a download. They are the mathematical fingerprints that detect whether a single bit has been altered in a multi‑gigabyte database. In this blog post, we will dissect two of the most prevalent checksum algorithms: the venerable Adler‑32 and the modern champion CRC‑32C. We will explore not only their mechanics but also the deep mathematics that makes CRC so robust—the elegant world of Galois field arithmetic. By the end, you will understand not just _how_ to use these algorithms, but _why_ they work, and when to choose one over the other.

---

## Part 1: The Philosophy of Data Integrity

### 1.1 What Is a Checksum, Really?

At its core, a checksum is a small, fixed‑size value computed from an arbitrary block of data. The function that produces it is designed so that any change in the data—even a single bit—produces a different checksum with high probability. The idea is simple: when you receive or retrieve data, you recompute the checksum and compare it with the stored value. If they match, you have high confidence that the data is unchanged.

But "high confidence" is not the same as "certainty." Checksums are not cryptographic hash functions; they are not designed to resist deliberate tampering. Instead, they detect random errors introduced by unreliable media or environmental noise. The distinction is crucial.

### 1.2 The Threat Landscape

Why do we need checksums at all? The digital world is surprisingly hostile to data.

- **Cosmic Rays:** High‑energy particles from space can flip bits in semiconductor memory. This is a well‑documented phenomenon in both space‑borne and terrestrial electronics. A single flipped bit in a financial transaction could mean the difference between a credit and a debit.
- **Electromagnetic Interference:** Power surges, nearby motors, or radio frequency noise can corrupt data buses.
- **Media Degradation:** Magnetic domains on a hard drive weaken over time. NAND flash cells wear out after a finite number of program/erase cycles.
- **Firmware Bugs:** Occasionally, a bug in the storage stack can silently corrupt data during a transfer.

Each of these threats is a variation of the Alexandrian scribe's mistake. The difference is that we now have mathematical tools to catch the error before the lighthouse falls.

### 1.3 The Evolution of Checksumming

The earliest checksums were simple, like the longitudinal parity check used in paper tape and early magnetic tape. You sum all the bytes (modulo something) and store the sum. This catches many errors, but not all. For example, swapping two bytes leaves the sum unchanged. As data rates and volumes grew, more robust algorithms were needed.

- **16‑bit sum (Internet checksum):** Used in TCP/IP headers. Simple, fast, but weak against certain patterns of burst errors.
- **Fletcher‑32:** An improvement over simple sums that uses a running sum and a running sum of sums.
- **Adler‑32:** A variant of Fletcher‑32 designed for speed, used in the zlib compression library.
- **Cyclic Redundancy Checks (CRCs):** Based on polynomial division modulo 2. Extremely effective at detecting burst errors. CRC‑32 is the workhorse of Ethernet, ZIP files, and countless other protocols.

Today, two algorithms dominate the middle ground between performance and error‑detection strength: Adler‑32 and CRC‑32C (an optimized variant of CRC‑32). Let’s examine each in detail.

---

## Part 2: Adler‑32 – Speed Over Strength

### 2.1 Historical Context and Design

Adler‑32 was designed by Mark Adler in the 1990s as a part of the zlib compression library. The library needed a checksum that was very fast to compute, because it would be recalculated frequently as data was compressed and decompressed in streaming fashion. The Fletcher‑32 algorithm already existed, but its performance on 8‑bit processors was suboptimal. Adler‑32 simplified the computation while maintaining reasonable error‑detection properties.

### 2.2 The Algorithm

Adler‑32 operates on a stream of bytes. It maintains two 16‑bit accumulators: `A` and `B`. Initially, `A = 1` and `B = 0`. For each input byte `D`:

```
A = (A + D) mod 65521
B = (B + A) mod 65521
```

After processing all bytes, the checksum is `(B << 16) | A`. The modulus 65521 is the largest prime number less than 2^16. Why prime? Because using a prime modulus ensures that the sums wrap around in a way that improves the detection of certain error patterns. The prime avoids cycles that could reduce the range of possible checksum values.

Notice that `A` is the running sum of all bytes plus the initial 1, and `B` is the running sum of each intermediate `A`. This is reminiscent of a second‑order sum, giving Adlet‑32 the ability to detect more than just single‑bit errors.

### 2.3 Implementation in C

Here is a straightforward implementation:

```c
#include <stdint.h>

#define MOD_ADLER 65521

uint32_t adler32(const uint8_t *data, size_t len) {
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < len; i++) {
        a = (a + data[i]) % MOD_ADLER;
        b = (b + a) % MOD_ADLER;
    }
    return (b << 16) | a;
}
```

This version uses the modulo operator, which is expensive on many CPUs. In practice, the algorithm is often implemented without division by using a trick: the modulo operation can be deferred as long as the accumulators stay below a certain threshold (e.g., 2^16 \* 255). This allows for loop unrolling and massive speed gains.

### 2.4 Strengths and Weaknesses

**Strengths:**

- **Extremely fast** in software, especially on modern CPUs with efficient multiplication.
- **Simple to implement** – only a few lines of code.
- **Good for streaming** – can be updated incrementally as new data arrives.

**Weaknesses:**

- **Weak error detection** compared to CRCs. Adler‑32 fails to detect certain patterns of burst errors, especially those that are multiples of the modulus.
- **Not suitable for cryptography** – easily invertible.
- **Poor performance on hardware** – the modular arithmetic does not map well to hardware logic gates.

Adler‑32 is a classic trade‑off: you sacrifice robustness for raw speed. It is ideal for data compression scenarios where errors are unlikely and speed is king, but it is inadequate for critical infrastructure like network packets or storage filesystems.

---

## Part 3: Cyclic Redundancy Checks (CRC) – The Mathematics of Polynomials

### 3.1 The Core Idea

CRC algorithms are fundamentally different from Adler‑32. Instead of using arithmetic modulo a prime, CRC treats the entire message as a binary polynomial. Each bit of the message becomes a coefficient of a polynomial (0 or 1). The checksum is the remainder when this polynomial is divided by a fixed generator polynomial, modulo 2 (i.e., using XOR instead of subtraction). The remainder is the CRC value.

Because polynomial division modulo 2 is linear over GF(2) (the Galois field of two elements), the CRC has powerful error‑detection properties. A single bit error corresponds to adding a monomial (like x^k) to the message polynomial. Whether the division yields a non‑zero remainder depends on whether the error polynomial is divisible by the generator – and the generator is chosen to make this unlikely.

### 3.2 Polynomial Arithmetic in GF(2)

Let’s recall the arithmetic of GF(2). It has only two elements: 0 and 1. Addition and subtraction are the same – both are XOR. Multiplication is AND. So polynomial addition is simply XOR of coefficients with no carries. For example:

`(x^3 + x + 1) + (x^2 + x) = x^3 + x^2 + 1` (because x+x = 0).

Polynomial division is performed similarly to long division, but with XOR instead of subtraction.

### 3.3 The CRC Algorithm Step by Step

Let the message be represented as a polynomial M(x) of degree m-1 (where m is the number of bits). Let G(x) be the generator polynomial of degree n (usually 32 for CRC‑32). The CRC is computed as follows:

1. Append n zero bits to the message (equivalent to multiplying M(x) by x^n).
2. Divide the augmented message polynomial by G(x) using modulo‑2 division.
3. The remainder R(x) is the CRC value, typically of degree n-1 or less (i.e., n bits).

In practice, the division is implemented using a linear feedback shift register (LFSR). The hardware version uses shift registers and XOR gates. The software version simulates this process using a table‑driven approach.

### 3.4 CRC‑32 and CRC‑32C: The Two Standard Generators

There are many CRCs defined by different generator polynomials. The most famous is CRC‑32, used in Ethernet, ZIP, and many other protocols. Its generator polynomial is:

`G(x) = x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10 + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1`

This is often written in hex as `0x04C11DB7` (without the leading 1 for the x^32 term, which is implied).

CRC‑32C (Castagnoli) is an improvement defined by the polynomial:

`G(x) = x^32 + x^28 + x^27 + x^26 + x^25 + x^23 + x^22 + x^20 + x^19 + x^18 + x^14 + x^13 + x^11 + x^10 + x^9 + x^8 + x^6 + 1`

Hex: `0x1EDC6F41`. This polynomial was selected for its superior detection of burst errors, especially in modern high‑speed networks. Many new protocols and storage systems (e.g., ZFS, iSCSI) have adopted CRC‑32C.

### 3.5 The Error‑Detection Arsenal of CRCs

The mathematics of polynomial division ensures that CRCs can detect:

- **All single‑bit errors** (provided the generator polynomial has at least two terms, which all standard ones do).
- **All two‑bit errors** as long as the generator polynomial is primitive and has a factor `x+1`.
- **Any odd number of errors** if the generator polynomial contains the factor `x+1` (which is equivalent to having even parity).
- **Burst errors of length ≤ n** (where n is the degree of the generator) – i.e., any contiguous block of up to 32 corrupted bits is guaranteed to be detected.
- A large fraction of longer burst errors.

No simple checksum can match this detection power.

---

## Part 4: Galois Field Multiplications – The Heart of High‑Performance CRC

### 4.1 Why Not Simple LFSR?

The textbook software implementation of CRC uses a table of precomputed values (usually 256 entries for byte‑wise processing). This is efficient, but it still requires one table lookup and a few XOR operations per byte. For extremely high data rates (e.g., 100 Gbps networking), this per‑byte overhead is significant. Moreover, hardware implementations often require multiple bits processed per clock cycle. This is where Galois field (GF) multipliers come in.

### 4.2 Galois Fields: A Quick Refresher

A Galois field, denoted GF(2^k), is a finite field with 2^k elements. In CRC, we work with GF(2) polynomials of degree less than n (where n is the degree of the generator polynomial). The set of all such polynomials under addition (XOR) and multiplication modulo an irreducible polynomial forms GF(2^n). For CRC‑32, we are not directly in GF(2^32) because the generator polynomial is not necessarily irreducible. However, the arithmetic of CRC division can be expressed in terms of multiplication in GF(2) modulo the generator, which is a polynomial ring.

### 4.3 The Key Insight: CRC as a Multiplication

Consider two messages A and B concatenated. The CRC of the concatenation can be computed from the CRC of A and the CRC of B using a property called **linear CRC**. Specifically:

`CRC(A || B) = (CRC(A) * x^|B|) XOR CRC(B)`

where `*` denotes polynomial multiplication modulo the generator, and `x^|B|` is the polynomial representing a shift by the length of B in bits. This is exactly a multiplication in the quotient ring GF(2)[x]/(G(x)).

If we precompute a table of multipliers for all possible byte values, we can process many bytes in parallel. This is the basis of **slicing‑by‑n** algorithms (e.g., slicing‑by‑8). Each slice processes a fixed number of bytes (e.g., 8) using a table of size 256 \* 8 entries.

### 4.4 Multiplication in Hardware: The GMAC Instruction

Modern processors, especially x86‑64, include special instructions for carry‑less multiplication. Intel’s `PCLMULQDQ` instruction performs a 64‑bit multiply that produces a 128‑bit result, with no carries between bits. This is exactly the multiplication needed for GF(2) arithmetic. Using this instruction, a CRC can be computed extremely fast by performing multiplication of the current CRC value by a precomputed constant (the polynomial `x^64 mod G(x)` and then XORing with the next chunk of data.

This technique, known as **Carry‑less Multiplication (CLMUL)** CRC, can process data at line rate, achieving throughputs of tens of gigabits per second per core.

### 4.5 Code Example: CRC‑32C Using PCLMULQDQ (Simplified)

The following is a high‑level pseudocode sketch that demonstrates the principle. The full implementation involves handling alignment and buffer sizes:

```c
#include <wmmintrin.h> // for _mm_clmulepi64_si128

uint32_t crc32c_clmul(const uint8_t *buf, size_t len, uint32_t crc) {
    // Assume len is multiple of 16 for simplicity
    __m128i xmm_crc = _mm_cvtsi32_si128(~crc);  // reflect bits? (details omitted)
    __m128i xmm_zero = _mm_setzero_si128();
    while (len >= 16) {
        __m128i data = _mm_loadu_si128((const __m128i*)buf);
        xmm_crc = _mm_xor_si128(xmm_crc, data);
        // Perform folding: multiply current CRC by x^64 mod G and combine with next part
        __m128i product = _mm_clmulepi64_si128(xmm_crc, xmm_const1, 0x00);
        xmm_crc = _mm_xor_si128(product, xmm_crc);
        // ... further folding using another constant
        buf += 16;
        len -= 16;
    }
    // Final reduction to 32 bits
    uint32_t result = _mm_extract_epi32(xmm_crc, 0);
    return ~result; // typical CRC post‑processing
}
```

The actual constants and folding steps are carefully chosen based on the generator polynomial. The result is a CRC that can run at multiple bytes per clock cycle.

---

## Part 5: A Head‑to‑Head Comparison – Adler‑32 vs CRC‑32C

| Property                       | Adler‑32                                          | CRC‑32C                                                               |
| ------------------------------ | ------------------------------------------------- | --------------------------------------------------------------------- |
| **Basis**                      | Arithmetic modulo a prime (65521)                 | Polynomial division modulo 2                                          |
| **Detection of burst errors**  | Weak – limited to length around 16 bits           | Excellent – guarantees detection of up to 32 consecutive flipped bits |
| **Detection of random errors** | Good but not perfect; fails for certain multiples | Very high – designed to maximize Hamming distance                     |
| **Speed (software)**           | Very fast – simple integer operations             | Fast with table lookup; faster with CLMUL hardware                    |
| **Speed (hardware)**           | Poor – modular arithmetic is expensive in gates   | Excellent – simple XOR gates                                          |
| **Incremental update**         | Trivial                                           | More complex but possible                                             |
| **Adoption**                   | zlib, PNG (as part of gzip)                       | Ethernet, SATA, ZFS, iSCSI, NVMe                                      |
| **Cryptographic security**     | None                                              | None (though CRCs are not designed for security)                      |

### 5.1 When to Use Which?

- **Use Adler‑32** when you need a lightweight, fast checksum for non‑critical applications, especially in compression or streaming contexts where data corruption is rare and you want minimal overhead. For example, zlib uses Adler‑32 for its integrity check in the gzip format.
- **Use CRC‑32C** when data integrity is paramount and you can afford a few more CPU cycles. This includes storage filesystems (ZFS uses CRC‑32C for its checksum of data blocks), network protocols (Ethernet frame, iSCSI), and any system where undetected bit flips could be catastrophic.

### 5.2 Performance Numbers

On modern Intel Skylake architecture, software CRC‑32C (using a slicing‑by‑8 table) can achieve about 2‑3 GB/s per core. With CLMUL hardware acceleration, throughput jumps to 10‑15 GB/s. Adler‑32, implemented efficiently with deferred modulo, can reach 5‑8 GB/s. So while Adler‑32 is faster in pure software, CRC‑32C with hardware acceleration surpasses it.

---

## Part 6: Practical Implementation Considerations

### 6.1 Table‑Driven CRC‑32C

The most common software implementation uses a 256‑entry table. Each entry holds the CRC of a single byte (the polynomial remainder for that byte). The algorithm processes each byte:

```c
uint32_t crc32c_table[256];

void init_crc32c_table() {
    for (int i = 0; i < 256; i++) {
        uint32_t crc = i;
        for (int j = 0; j < 8; j++) {
            if (crc & 1)
                crc = (crc >> 1) ^ 0x82F63B78; // reflected polynomial
            else
                crc >>= 1;
        }
        crc32c_table[i] = crc;
    }
}

uint32_t crc32c(const uint8_t *buf, size_t len) {
    uint32_t crc = 0xFFFFFFFF; // initial value (often all ones)
    while (len--) {
        crc = (crc >> 8) ^ crc32c_table[(crc ^ *buf++) & 0xFF];
    }
    return crc ^ 0xFFFFFFFF; // final XOR
}
```

Note that the polynomial `0x82F63B78` is the reflected version of the CRC‑32C polynomial. Reflection is a common optimization for little‑endian architectures.

### 6.2 Incremental CRC

Often data arrives in chunks. You can update the CRC incrementally by simply feeding new bytes through the same algorithm, keeping the state in the `crc` variable. This is a major advantage over some more complex error‑correcting codes.

### 6.3 Combining CRCs (Reduction)

When you have two CRCs computed on separate blocks and you want the CRC of the concatenated data without processing the entire message again, you need to use the multiplication in GF(2). Specifically:

```
CRC(A || B) = (CRC(A) * x^|B|) XOR CRC(B)
```

where `x^|B|` is computed modulo the generator polynomial. This can be done using a precomputed table for powers of x and a carry‑less multiplication if available.

### 6.4 Avoiding Pitfalls

- **Big‑endian vs Little‑endian:** Both Adler‑32 and CRC have agreed‑upon byte orders in network protocols. Make sure your implementation matches the specification.
- **Initial and final XORs:** Many CRCs XOR the initial value with 0xFFFFFFFF and do the same at the end to ensure that a zero‑length message does not produce a zero CRC (which would be indistinguishable from a missing checksum).
- **Implementation bugs:** The most common source of errors is incorrect reflection. Always test against known test vectors.

---

## Part 7: Case Studies – Real‑World Implementation

### 7.1 Ethernet: The Original CRC‑32

Ethernet frames use a 32‑bit CRC (often called the Frame Check Sequence) computed over the destination address, source address, length/type field, data, and padding. The polynomial is the standard CRC‑32 (0x04C11DB7). The NIC hardware computes the CRC on the fly as the packet is transmitted, and the receiver checks it. If the CRC does not match, the frame is discarded. This simple mechanism has been the backbone of reliable networking for decades.

### 7.2 ZFS: End‑to‑End Data Integrity

The ZFS filesystem uses CRC‑32C for its data and metadata checksums (as well as a more advanced checksum for block pointers). Every block of data is checksummed before being written and verified on read. Unlike traditional filesystems that rely on the underlying disk’s error detection (which may be insufficient), ZFS implements its own integrity verification at the storage pool level. This protects against silent data corruption that can occur in disks, RAM, or even the CPU.

### 7.3 gzip and PNG: The Speed Lovers

The gzip format uses Adler‑32 for both its compressed data and an optional header checksum. While some might argue that CRC would be safer, gzip’s use case is primarily compression of data that is already protected by the transport layer (e.g., TCP). The performance advantage of Adler‑32 was significant on the slower CPUs of the 1990s. Modern PNG files also use Adler‑32 for the IDAT chunk.

### 7.4 Database Systems: B‑Tree Checksums

Many modern databases (e.g., SQLite, InnoDB) use CRC‑32C or CRC‑32 to protect the pages of their B‑tree indexes. A corrupted page could lead to data loss or corruption of the index structure. By storing a CRC per page, the database engine can detect errors early and attempt recovery or notify the administrator.

---

## Part 8: The Future – Hardware Acceleration and New Algorithms

### 8.1 ARM Neon and SSE

Beyond Intel’s CLMUL, ARM processors have a similar instruction: `VMULL.P8` (polynomial multiply) and a dedicated CRC‑32C instruction `CRC32C` in the ARMv8 architecture. This means CRC‑32C is now hardware‑accelerated on virtually all modern mobile and server CPUs.

### 8.2 Beyond 32‑bit Checksums

For applications requiring even lower probability of undetected errors, 64‑bit CRCs (CRC‑64) exist. The polynomial `0xAD93D23594C935A9` is used by some storage systems. However, the increased CPU overhead and storage cost often outweigh the marginal benefit.

### 8.3 Cryptographic Hashes as Checksums?

Some systems (e.g., BitTorrent) use SHA‑1 or SHA‑256 to verify file integrity. These are cryptographic hashes designed to resist deliberate tampering. However, they are orders of magnitude slower than CRC or Adler‑32. For most unintentional error detection, the computational cost is unjustifiable.

### 8.4 Erasure Coding and Checksums

Often checksums are combined with erasure coding (e.g., Reed‑Solomon codes) to provide both error detection and correction. In this context, the checksum serves as a quick early warning, while the erasure code can reconstruct missing or corrupted data.

---

## Conclusion: The Unseen Guardians

In our digital world, data is constantly in motion. Bits travel through copper, fiber, and air; they are stored on magnetic platters, silicon cells, and even in DNA. Every second, countless cosmic ray strikes and voltage transients threaten to corrupt that data. Without the silent vigilance of checksums, a single flipped bit could bring down an airplane’s autopilot, corrupt a medical record, or cause a stock market flash crash.

We have journeyed from the ancient scribe’s misreading to the elegant mathematics of Galois fields. Adler‑32 and CRC‑32C represent two philosophies: the pragmatist who values speed and the perfectionist who demands robustness. Both have their place, but as Moore’s law ends and data rates accelerate, the balance is tipping toward CRC‑32C, especially with its hardware acceleration.

The next time you download a file, stream a video, or write a blog post, remember that an unseen mathematical guardian is watching over your data. It is not flashy, it is not talked about in security headlines, but it is the quiet hero that makes our digital civilization possible.

And if you ever find yourself implementing a checksum, you now have the tools to choose wisely.
