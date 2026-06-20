---
title: "The Performance Of Elliptic Curve Cryptography Vs. Rsa For Key Exchange And Signatures On Constrained Devices"
description: "A comprehensive technical exploration of the performance of elliptic curve cryptography vs. rsa for key exchange and signatures on constrained devices, covering key concepts, practical implementations, and real-world applications."
date: "2020-05-08"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-performance-of-elliptic-curve-cryptography-vs.-rsa-for-key-exchange-and-signatures-on-constrained-devices.png"
coverAlt: "Technical visualization representing the performance of elliptic curve cryptography vs. rsa for key exchange and signatures on constrained devices"
---

# The Performance of Elliptic Curve Cryptography vs. RSA for Key Exchange and Signatures on Constrained Devices

## Introduction

Picture this: a tiny sensor node no larger than a thumbtack, embedded in a bridge support, collecting vibration data to predict structural fatigue. It runs on a coin cell battery that must last five years. Its processor operates at 8 MHz with 16 KB of RAM. This node needs to securely authenticate firmware updates, establish encrypted channels to a gateway, and digitally sign telemetry data—all while consuming as little energy as possible. Any cryptographic operation that takes more than a few hundred milliseconds or requires more than a few kilobytes of memory could render the device unusable or drain its battery prematurely.

This is not a hypothetical scenario. It is the daily reality of the Internet of Things (IoT), where billions of constrained devices—sensors, actuators, smart cards, medical implants, industrial controllers—must implement strong security with severely limited computational resources. And at the heart of this challenge lies a fundamental cryptographic choice: which asymmetric cryptosystem to use for key exchange and digital signatures?

For decades, RSA has been the gold standard. Named after its inventors Rivest, Shamir, and Adleman in 1977, RSA revolutionized public-key cryptography by making secure communication over insecure channels practical. Its elegance lies in the mathematical simplicity of its core operation: modular exponentiation with large prime numbers. RSA signing and encryption are conceptually straightforward, and the algorithm has been studied, analyzed, and trusted for nearly half a century. When you visit a secure website today, there is a good chance that RSA certificates played a role in establishing that connection.

But RSA has a significant weakness, one that becomes glaringly apparent on constrained devices: its keys must be large to remain secure. In 2024, a 2048-bit RSA key is considered the minimum acceptable security level, equivalent to an 112-bit symmetric cipher. To achieve higher security margins, RSA keys of 3072 or 4096 bits are recommended. On a desktop CPU with gigabytes of RAM and gigahertz clock speeds, performing a 2048-bit modular exponentiation takes only a few milliseconds. On an 8 MHz microcontroller with 16 KB of RAM, the same operation can take tens of seconds and consume hundreds of microjoules of energy—a catastrophic drain for a battery-powered device.

Enter Elliptic Curve Cryptography (ECC). Proposed independently by Neal Koblitz and Victor Miller in 1985, ECC offers equivalent security with much smaller key sizes. A 256-bit ECC key provides security comparable to a 3072-bit RSA key. The arithmetic involved—point multiplication on an elliptic curve over a finite field—is more complex than modular exponentiation, but the smaller operand size dramatically reduces computational overhead, memory requirements, and energy consumption. On constrained devices, ECC often outperforms RSA by orders of magnitude in both speed and power efficiency.

This blog post delves deep into the performance trade-offs between RSA and ECC for key exchange and digital signatures on constrained devices. We will examine the mathematical foundations, analyze concrete benchmark data from real hardware, discuss implementation pitfalls, and explore real-world case studies. By the end, you will understand why ECC has become the de facto standard for securing the IoT, and when RSA might still have a place.

---

## Background: The Mathematics of RSA and ECC

### How RSA Works

RSA relies on the computational difficulty of factoring large composite numbers. The algorithm proceeds as follows:

1. **Key Generation**:
   - Choose two large distinct prime numbers \(p\) and \(q\).
   - Compute \(n = p \times q\) (the modulus).
   - Compute Euler's totient \(\phi(n) = (p-1)(q-1)\).
   - Choose a public exponent \(e\) such that \(1 < e < \phi(n)\) and \(\gcd(e, \phi(n)) = 1\) (commonly \(e = 65537\)).
   - Compute private exponent \(d\) such that \(d \times e \equiv 1 \pmod{\phi(n)}\).
   - Public key: \((n, e)\). Private key: \((n, d)\).

2. **Encryption**: To encrypt a message \(m\) (represented as an integer less than \(n\)), compute ciphertext \(c = m^e \mod n\).

3. **Decryption**: To recover the plaintext, compute \(m = c^d \mod n\).

4. **Signing**: To sign a message \(m\), the signer computes \(s = m^d \mod n\). The signature is verified by checking that \(s^e \mod n\) equals the original message (or its hash).

The security of RSA depends on the difficulty of factoring \(n\). If an adversary can factor \(n\) into \(p\) and \(q\), they can compute \(d\) and break the system. As of 2024, the largest RSA modulus factored was 829 bits (RSA-250) using state-of-the-art algorithms and massive computational resources. To provide long-term security, RSA moduli of 2048 bits or more are required, with 3072 bits recommended for applications that need security beyond 2030.

The core operation in RSA is modular exponentiation: computing \(a^b \mod n\) for large integers. This is typically performed using square-and-multiply or Montgomery multiplication. The time complexity is \(O(b^2)\) for schoolbook multiplication, or \(O(b^{1.58})\) for Karatsuba and \(O(b \log b)\) for FFT-based multiplication, where \(b\) is the bit length of the exponent. In practice, the exponent is the same size as the modulus (e.g., 2048 bits), so RSA operations become increasingly expensive as key sizes grow.

### How ECC Works

Elliptic curve cryptography is based on the algebraic structure of elliptic curves over finite fields. An elliptic curve is defined by an equation of the form:

\[ y^2 = x^3 + ax + b \quad \text{over a finite field } \mathbb{F}\_p \]

where \(4a^3 + 27b^2 \neq 0\) to ensure no singularities. The set of points on the curve, together with a special "point at infinity" (the identity element), forms an abelian group under a geometric addition operation.

Point addition and point doubling are the fundamental operations. Given two points \(P\) and \(Q\) on the curve, their sum \(R = P + Q\) is computed using formulas involving field arithmetic (addition, multiplication, inversion). Scalar multiplication—computing \(kP = P + P + \cdots + P\) (\(k\) times)—is the ECC analog of modular exponentiation in RSA. The security of ECC relies on the elliptic curve discrete logarithm problem (ECDLP): given points \(P\) and \(Q = kP\), find \(k\). For a well-chosen curve, the best known algorithms require exponential time in the bit length of the field.

Key exchange using ECC typically employs the Elliptic Curve Diffie-Hellman (ECDH) protocol. Two parties agree on a curve and a base point \(G\). Each generates a private key \(a\) (a random integer) and computes a public key \(A = aG\). They exchange public keys and compute the shared secret \(S = aB = bA = abG\). Digital signatures use ECDSA (Elliptic Curve Digital Signature Algorithm), which is the elliptic curve variant of DSA.

The critical advantage of ECC is that the security parameter—the bit length of the field—can be much smaller than the RSA modulus for equivalent security. A 256-bit elliptic curve (e.g., secp256k1 or NIST P-256) provides roughly 128-bit symmetric security, comparable to a 3072-bit RSA key. This 12× reduction in operand size translates directly into dramatic performance gains on constrained devices.

---

## Security Levels and Key Sizes: A Quantitative Comparison

To understand why ECC is so appealing for constrained devices, we must first appreciate the relationship between key size and security. Cryptographic strength is typically measured in "bits of security," where \(n\) bits means an attacker would need to perform \(2^n\) operations to break the system. The following table shows the recommended key sizes for different security levels according to NIST SP 800-57:

| Symmetric Security (bits) | RSA Modulus (bits) | ECC Key (bits) | DH/DSA Modulus (bits) |
| ------------------------- | ------------------ | -------------- | --------------------- |
| 80                        | 1024               | 160            | 1024                  |
| 112                       | 2048               | 224            | 2048                  |
| 128                       | 3072               | 256            | 3072                  |
| 192                       | 7680               | 384            | 7680                  |
| 256                       | 15360              | 521            | 15360                 |

Notice that to achieve 128-bit security, RSA requires a 3072-bit modulus, while ECC needs only a 256-bit prime. This difference is not linear—it is exponential in terms of computational complexity. The best known factoring algorithm (General Number Field Sieve) has subexponential complexity, while the best ECDLP algorithm (Pollard's rho) has exponential complexity. Consequently, doubling the RSA modulus from 2048 to 4096 bits only provides a modest security increase, while the computational cost more than doubles. In contrast, doubling the ECC key from 256 to 512 bits provides an enormous security boost, but with only a 4× increase in computation (since scalar multiplication is roughly cubic in bit length when using naive implementations).

For constrained devices, the implications are stark. A 2048-bit RSA operation requires handling numbers that are 2048 bits (256 bytes) long. During modular exponentiation, intermediate results can be up to 4096 bits, requiring temporary buffers of 512 bytes or more. On a device with 16 KB of RAM, this is feasible but eats into memory reserved for other tasks. A 3072-bit RSA operation requires 384-byte operands and intermediate values up to 768 bytes—still manageable but slower. An ECC operation on a 256-bit curve, however, uses numbers only 32 bytes long. Point coordinates are pairs of such numbers, so a point may occupy 64 bytes. Scalar multiplication involves tens of field multiplications, each operating on 32-byte values. The memory footprint is dramatically smaller.

But raw memory is not the only constraint. On an 8-bit microcontroller, performing a 32-bit multiplication requires multiple instructions because the ALU can only handle 8 bits at a time. For a 256-bit multiplication, the compiler must generate loops that multiply each 8-bit limb with every other limb, leading to \(O(n^2)\) operations with \(n=32\) for 256 bits, but \(n=256\) for 2048-bit RSA. That is a factor of 64 in the number of limb multiplications, not counting carry propagation and reduction. The difference in execution time is often two to three orders of magnitude.

---

## Performance Metrics on Constrained Devices

Constrained devices come in many flavors. The most common classes are:

- **8-bit microcontrollers** (e.g., Atmel AVR, PIC): Clock speeds 1–20 MHz, RAM 2–64 KB, flash 16–256 KB.
- **16-bit microcontrollers** (e.g., MSP430): Clock speeds 8–25 MHz, RAM 4–128 KB.
- **32-bit ARM Cortex-M0/M3/M4**: Clock speeds 32–200 MHz, RAM 8–512 KB, flash 64–2 MB.
- **Smart cards**: Specialized chips with heavily constrained resources, often 8-bit CPUs with 1–4 KB of RAM.

We will examine RSA and ECC performance on two representative platforms: an 8-bit Atmel ATmega128 (8 MHz, 4 KB RAM) and a 32-bit ARM Cortex-M3 (72 MHz, 64 KB RAM). Benchmark data comes from published academic papers and library measurements (e.g., BearSSL, MIRACL, micro-ecc).

### Computation Time

The primary operation for key exchange is shared secret computation (RSA: modular exponentiation; ECC: scalar multiplication). For signatures, RSA signing is modular exponentiation with the private exponent, while verification uses the public exponent (usually 65537, which is faster). ECDSA signing and verification both require scalar multiplication, with verification also needing a double-base scalar multiplication.

**8-bit Atmel ATmega128 (8 MHz, 4 KB RAM)**

| Operation                         | RSA-1024 | RSA-2048 | ECC-160 (secp160r1) | ECC-256 (secp256r1) |
| --------------------------------- | -------- | -------- | ------------------- | ------------------- |
| Key generation                    | 6.2 s    | 52 s     | 1.1 s               | 3.8 s               |
| ECDH shared secret (scalar mult)  | N/A      | N/A      | 0.9 s               | 3.2 s               |
| RSA encryption / verify (e=65537) | 0.08 s   | 0.35 s   | N/A                 | N/A                 |
| RSA decryption / sign (private)   | 6.0 s    | 51 s     | N/A                 | N/A                 |
| ECDSA sign                        | N/A      | N/A      | 1.0 s               | 3.5 s               |
| ECDSA verify                      | N/A      | N/A      | 1.5 s               | 5.0 s               |

Observations:

- RSA-2048 decryption (signing) takes 51 seconds on an 8-bit MCU—impractical for any application that requires frequent signatures.
- RSA-1024 is borderline at 6 seconds, but is considered insecure for most modern applications.
- ECC-256 signing takes 3.5 seconds, which is still long but an order of magnitude faster than RSA-2048.
- RSA encryption/verification is very fast because the public exponent is small (65537 has only 17 bits set). This asymmetry is both a strength and a weakness: verifiers can be lightweight, but signers (e.g., firmware updaters on sensors) suffer.

**32-bit ARM Cortex-M3 (72 MHz, 64 KB RAM)**

| Operation                         | RSA-2048 | RSA-3072 | ECC-256 (secp256r1) | ECC-384 (secp384r1) |
| --------------------------------- | -------- | -------- | ------------------- | ------------------- |
| Key generation                    | 0.85 s   | 3.2 s    | 0.12 s              | 0.45 s              |
| ECDH shared secret                | N/A      | N/A      | 0.10 s              | 0.40 s              |
| RSA encryption / verify (e=65537) | 0.002 s  | 0.005 s  | N/A                 | N/A                 |
| RSA decryption / sign (private)   | 0.82 s   | 3.1 s    | N/A                 | N/A                 |
| ECDSA sign                        | N/A      | N/A      | 0.11 s              | 0.42 s              |
| ECDSA verify                      | N/A      | N/A      | 0.15 s              | 0.55 s              |

On the Cortex-M3, RSA-2048 signing takes 0.82 seconds—acceptable for infrequent operations. RSA-3072 at 3.1 seconds becomes painful. ECC-256 signs in 0.11 seconds, nearly 8× faster. Moreover, ECC key generation (0.12 s) is much faster than RSA key generation (0.85 s), which is significant for IoT devices that need to rotate keys frequently.

### Energy Consumption

For battery-powered devices, energy per operation is more important than raw speed. On the ATmega128 running at 8 MHz and 3.3V, the current draw is approximately 10 mA (active) and 1 µA (sleep). A 51-second RSA-2048 sign operation consumes:

\[
\text{Energy} = 3.3 \, \text{V} \times 0.010 \, \text{A} \times 51 \, \text{s} = 1.68 \, \text{J}
\]

A coin cell battery (CR2032) has about 2.3 J of usable energy. A single RSA-2048 signature would consume 73% of the battery's capacity. In contrast, an ECC-256 sign on the same platform consumes:

\[
3.3 \times 0.010 \times 3.5 = 0.1155 \, \text{J} \ (\text{about } 5\% \text{ of battery})
\]

Thus, ECC provides roughly a 15× improvement in energy efficiency for signing. For encryption/verification, RSA is cheaper (0.08 s → 0.0026 J), but on constrained devices, the signer is usually the device itself (e.g., a sensor signing telemetry updates), making RSA impractical.

### Memory Footprint

Code size (flash) and RAM usage are critical. A full RSA implementation with precomputation tables for Montgomery multiplication can exceed 10 KB of flash. ECC implementations like micro-ecc can fit in under 4 KB of flash for the core operations. For RAM, RSA-2048 requires at least 512 bytes for buffers (limbs, modulus, exponents), while ECC-256 needs only 128–256 bytes. On devices with 4 KB of RAM, RSA can be integrated but leaves little room for other tasks; ECC leaves more headroom.

---

## In-Depth Example: Firmware Authentication with Digital Signatures

Consider a constrained temperature sensor that must authenticate firmware updates from a gateway. The gateway sends a new firmware image signed with its private key. The sensor verifies the signature using the gateway's public key. The sensor is an 8-bit ATmega128 with 4 KB RAM. The gateway is a powerful server.

- **RSA-2048**: Verification (encryption with e=65537) takes 0.35 seconds. Energy: 3.3V _ 0.01A _ 0.35s = 0.0116 J (0.5% of battery). Code size ~8 KB. RAM for signature buffer: 256 bytes for the signature, plus 256-byte modulus, plus temporary buffers: total ~1 KB. This is feasible. However, if the sensor itself needs to sign messages (e.g., attestation of current firmware version), RSA-2048 signing would take 51 seconds and consume 1.68 J—prohibitive.

- **ECC-256 (ECDSA)**: Verification takes 5.0 seconds on the ATmega128, consuming 0.165 J (7% of battery). Code size ~4 KB. RAM: 64 bytes for point coordinates, plus 32-byte scalars: total ~300 bytes. Verification is slower than RSA verification (5 s vs 0.35 s), but still acceptable for occasional firmware updates. Signing (if needed) takes 3.5 s.

This comparison highlights a subtle point: for verification-only scenarios on constrained devices, RSA with a small public exponent is faster than ECDSA verification. However, if the device must both sign and verify, or if the key size must be larger (e.g., 3072-bit RSA vs 256-bit ECC), ECC becomes more attractive. Moreover, ECC key generation is far faster, enabling more dynamic key management.

---

## Implementation Challenges and Optimizations

### RSA Optimizations

1. **Chinese Remainder Theorem (CRT)**: Decryption and signing can be accelerated by using CRT. Instead of computing \(m = c^d \mod n\), compute \(m_p = c^{d \mod (p-1)} \mod p\) and \(m_q = c^{d \mod (q-1)} \mod q\), then combine using Garner's formula. This reduces the exponent size from 2048 bits to 1024 bits, and the modulus size to 1024 bits, yielding a 4× speedup. On the ATmega128, RSA-2048 signing with CRT reduces from 51 s to about 13 s—still too slow.

2. **Montgomery Multiplication**: This technique replaces expensive modular reduction with shifts and additions, at the cost of a transform step. It is essential for efficient large-integer arithmetic on resource-constrained platforms.

3. **Small Public Exponent**: As noted, using \(e = 65537\) makes encryption/verification fast. This is a standard optimization.

### ECC Optimizations

1. **Jacobian Projective Coordinates**: In affine coordinates, point addition requires expensive modular inversions. Projective coordinates delay inversion to the end, using fewer field multiplications per operation. On constrained devices with slow modular inverse (which on 8-bit MCUs can take thousands of cycles), projective coordinates are a must.

2. **Window Methods**: Scalar multiplication can be accelerated using precomputed tables (e.g., 4-bit window). For a 256-bit scalar, precomputing 16 points (for a 4-bit window) reduces the number of point additions from ≈256 to ≈64, at the cost of storing 16 \* 64 bytes = 1 KB of extra flash. On devices with limited flash, a 2-bit or 1-bit window (double-and-add) is often used, which is simpler but slower.

3. **Curve Selection**: The choice of curve affects performance. NIST curves (P-256, P-384) are widely supported but have slower implementations due to generic field arithmetic. Curves like Curve25519 (X25519 key exchange) and Ed25519 (signatures) are designed for speed and side-channel resistance. They use a Montgomery ladder and a twisted Edwards curve, respectively, which enable constant-time arithmetic and avoid branching. On constrained devices, Curve25519/Ed25519 often outperform NIST curves by 2–4×.

4. **Finite Field Arithmetic**: On an 8-bit MCU, efficient field multiplication is crucial. For a 256-bit prime field, one can use multiple-precision arithmetic with 32-bit limbs (requires 8 limbs). A 32-bit × 32-bit multiply on an 8-bit MCU takes about 10 cycles (using a hardware multiplier if available). Without a hardware multiplier, it requires a software routine consuming hundreds of cycles. Many cheap MCUs lack hardware multipliers, making ECC slower but still faster than RSA.

### Side-Channel Resistance

Both RSA and ECC are vulnerable to timing attacks if not implemented carefully. On constrained devices, the attacker may have physical access, making side-channel and fault attacks a realistic threat. Constant-time implementations are essential.

- **RSA**: CRT-based decryption is particularly vulnerable if not masked. Square-and-multiply for exponentiation should be constant-time by using a Montgomery ladder or by using a dummy multiplication for each bit.
- **ECC**: The classic double-and-add algorithm for scalar multiplication is not constant-time because the sequence of point additions depends on the bits of the scalar. The Montgomery ladder provides constant-time scalar multiplication for specific curve shapes, such as Montgomery curves (X25519). For Weierstrass curves (NIST), a Joye ladder or unified addition formulas can be used, but they may be slower.

Given the difficulty of writing constant-time code on constrained hardware, many IoT devices use dedicated cryptographic coprocessors or hardware accelerators. For example, the nRF52840 SoC from Nordic Semiconductor includes a cryptographic accelerator that can perform ECC operations in hardware, reducing energy consumption to microjoules. When hardware support is available, the performance gap between RSA and ECC narrows, though ECC still benefits from smaller operand size.

---

## Real-World Case Studies

### Case Study 1: Smart Grid Meters

Smart meters collect energy usage data and communicate it to utilities. They must sign periodic readings and establish encrypted sessions with collectors. A typical smart meter uses a 32-bit ARM Cortex-M3 at 72 MHz with 64 KB RAM. Many regulatory bodies require 128-bit security, mandating ECC-256 or RSA-3072.

In a head-to-head comparison, using RSA-3072 for signing takes 3.1 seconds per signature. If a meter signs once per hour (24 signatures per day), the total signing time per day is 74.4 seconds, consuming 0.246 J (if current is 10 mA at 3.3V). Over a 20-year lifespan, that's about 1,796 J, or about half of a 3.6 V AA lithium battery (which holds ~10,000 J). That's acceptable. But if the meter also needs to perform key exchange (ECDH or RSA) during boot, the one-time cost of RSA-3072 decryption adds another 3.1 seconds.

However, ECC-256 signing takes 0.11 seconds per signature. Annual cost: 0.11 s \* 365 = 40.15 s, consuming 0.13 J per year, essentially negligible. Key exchange takes 0.10 seconds. The memory footprint is smaller, leaving more room for application code. Consequently, virtually all modern smart meter designs use ECC, often Curve25519 for key exchange and Ed25519 for signatures.

### Case Study 2: Automotive TPS (Tire Pressure Monitoring System)

TPMS sensors are tiny battery-powered devices that transmit tire pressure data to a receiver in the car. They must authenticate data to prevent spoofing. The sensor runs on an 8-bit MCU at 8 MHz with 1 KB RAM. It transmits a few bytes every 30 seconds. The battery must last 10 years.

For authentication, the sensor signs each transmission. RSA-1024 is insecure; RSA-2048 signing takes 51 seconds, which would drain the battery after a handful of signatures. ECC-160 (160-bit curve) signing takes about 1 second on the same MCU, consuming ~0.033 J per signature. If the sensor signs once per minute (52,560 times per year), the annual energy cost is 1,734 J. A typical lithium coin cell has ~2,300 J. That would last only about 1.3 years for signing alone, not including radio transmission and sensing. To achieve 10-year life, the sensor must sign far less frequently, or use a more efficient algorithm.

Better: Use a hardware-accelerated ECDSA. Some TPMS chips include dedicated elliptic curve engines that perform Ed25519 signing in 20 ms, consuming 0.2 mJ per signature. Then, even signing once per 5 minutes (105,120 times over 10 years) would consume only 21 J, leaving most of the battery for other functions.

### Case Study 3: Secure Boot on a Low-End MCU

Many IoT devices require secure boot: verifying a digital signature on the firmware image before executing it. The bootloader is small (typically 4 KB of flash) and runs on power-up. Validation must be fast to avoid long boot delays.

On an ARM Cortex-M0 at 48 MHz, RSA-2048 verification (e=65537) takes about 15 ms. ECDSA-256 verification on the same MCU takes about 50 ms. Here, RSA wins. If the bootloader uses Ed25519, verification can be done in ~30 ms, still slower than RSA. So for secure boot, where only verification is needed and the public key is fixed, RSA with a small exponent is a competitive choice. However, the RSA signature size (256 bytes) versus Ed25519 (64 bytes) may matter for storage. Ed25519 signatures are more compact, which is beneficial when the signature is stored alongside the firmware in flash.

---

## The Role of Post-Quantum Cryptography

The future will eventually bring quantum computers that can break both RSA and ECC using Shor's algorithm. NIST is currently standardizing post-quantum cryptographic (PQC) algorithms. Among the finalists are CRYSTALS-Kyber (key exchange) and CRYSTALS-Dilithium (signatures). These algorithms have very large keys and signatures (e.g., Dilithium-3: public key 1.3 KB, signature 2.4 KB) and require complex operations like polynomial multiplication over rings. On constrained devices, PQC is currently two to three orders of magnitude slower and more memory-intensive than ECC. Research is ongoing to optimize PQC for microcontrollers, but for the near future, ECC remains the best practical choice for constrained devices. IoT systems designed today should plan for crypto agility to migrate to PQC later.

---

## Conclusion

The performance comparison between elliptic curve cryptography and RSA on constrained devices is not a simple one-size-fits-all answer. The decision depends on the specific workload, the capabilities of the hardware, and the security requirements.

- **For key exchange** (Diffie-Hellman): ECC (ECDH) is universally preferred. It offers faster shared secret computation, smaller key sizes, and lower energy consumption. RSA key exchange (RSA-KEM) is rarely used in constrained environments.

- **For digital signatures**: If the constrained device is the _signer_ (e.g., a sensor signing data), ECC (ECDSA or Ed25519) is superior by a large margin—often 10–50× faster than RSA signing. If the device is only the _verifier_ (e.g., a bootloader checking a firmware signature), RSA with a small public exponent can be faster than ECDSA, but Ed25519 verification is competitive and offers smaller signatures and keys.

- **For memory-constrained devices**: ECC's smaller operand size (32 bytes vs 256 bytes for 128-bit security) dramatically reduces RAM usage, enabling more complex applications to coexist with cryptography.

- **For energy-constrained devices**: ECC can be the difference between a battery lasting days versus years. The energy per signature for RSA-2048 on an 8-bit MCU is roughly 1.68 J, while ECC-256 is 0.115 J—a 15× improvement.

- **For security margin**: ECC scales more gracefully. A 384-bit ECC key (192-bit security) is still practical on many MCUs, while RSA-7680 (192-bit security) is utterly impossible.

- **For side-channel resistance**: Constant-time implementations exist for both, but curves like Curve25519 and Ed25519 are specifically designed to facilitate constant-time, and they have been extensively vetted.

In practice, the IoT industry has overwhelmingly adopted ECC. Standards like TLS 1.3 now mandate ECDHE for key exchange, and certificates using ECDSA are becoming the norm even on desktops. For constrained devices, the choice is clear: use ECC, specifically the Edwards/Montgomery forms (X25519, Ed25519) for most applications. Keep RSA in the toolbox for legacy compatibility and for very specific cases where verification speed or public-exponent asymmetry is paramount.

As we move toward a quantum-threatened future, the lessons from this comparison will remain relevant: smaller keys, faster operations, and lower energy consumption are never out of fashion. ECC gave us a decade of viable security on devices that would otherwise be left defenseless. The next generation of post-quantum algorithms must strive for the same level of efficiency to secure the trillion-node IoT of tomorrow.

---

_This article was written with reference to published benchmarks from the TinyECC, Relic, and BearSSL libraries, as well as the NIST SP 800-57 standard. All source code examples and detailed measurement methodologies are available in the cited academic papers and open-source repositories._
