---
title: "Building A Password Hashing Function With Memory Hardness: Scrypt And Argon2 Internals"
description: "A comprehensive technical exploration of building a password hashing function with memory hardness: scrypt and argon2 internals, covering key concepts, practical implementations, and real-world applications."
date: "2020-06-29"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/building-a-password-hashing-function-with-memory-hardness-scrypt-and-argon2-internals.png"
coverAlt: "Technical visualization representing building a password hashing function with memory hardness: scrypt and argon2 internals"
---

# Building A Password Hashing Function With Memory Hardness: Scrypt And Argon2 Internals

## Introduction: The Most Important Code You’ll Never See

You click a link. It feels like an eternity. A spinning wheel. The URL in the status bar changes to a familiar pattern: `/reset-password?token=...`. You’re here because you forgot, but the real story is about _how_ the system knows you’re you without actually knowing your secret.

Behind that white, minimalist login form lies one of the most vicious arms races in modern computation. It’s not a war over network intrusion or zero-day exploits. It’s a war over _silicon geometry_ and _memory bandwidth_. It pits the scale of a massive GPU cluster—or worse, a custom ASIC mining farm—against a single, specific function running on a server’s CPU.

At the core of this battle is a dark truth: **Passwords are a terrible idea.** They are low-entropy secrets short enough for humans to remember, which makes them trivially easy for machines to guess. The only reason the internet doesn’t collapse into a mass account takeover every Tuesday is the password hash.

For decades, we built these hashes around a simple lie: _Make it slow_. We took SHA-256 and applied it 10,000 times (PBKDF2). We took MD5 and tried to make it chaotic (bcrypt). But "slow" is a relative term. To a human typing on a keyboard, 0.1 seconds is instant. To a GPU running 10,000 parallel cores, 0.1 seconds is a firehose of billions of guesses per hour.

The industry needed a paradigm shift. We couldn't just make the CPU work harder—because attackers buy hardware that makes the CPU look like a toy. We needed to change the game entirely.

That shift is **Memory Hardness**.

### The Unfair Advantage of Hardware

To understand why memory hardness is a revolutionary concept, we must first understand why attackers win with soft memory.

Consider the standard hash function. It is a deterministic series of CPU instructions: load a value, XOR it, shift it, add it, store a result. These operations are extremely efficient on modern processors. A CPU core can execute billions of them per second. But the attacker isn’t limited to a single CPU core. She can buy a commodity GPU with 10,000 small cores, each running at a lower clock but with massive parallelism. A single high‑end GPU like the NVIDIA RTX 4090 can evaluate SHA-256 at a rate of over 50 billion hashes per second. Custom ASICs for Bitcoin mining push that to trillions per second.

The defender, however, is constrained by the login server’s hardware. A typical web server might have 32 CPU cores and an acceptable latency budget of 100–200 milliseconds per login attempt. If the hash function takes 150 ms on one CPU core, the server can handle about 6 login attempts per second per core—hardly a bottleneck for a modest user base. But the attacker can scale horizontally: rent a cloud GPU instance with thousands of cores and run millions of guesses per second. The ratio can be 10⁵ to 1 in favor of the attacker.

This asymmetry is the reason why traditional CPU‑bound hashing is doomed. We need a function that forces the attacker to pay a cost that scales super‑linearly with the hardware they throw at it—ideally, one that makes parallelism almost useless.

Memory hardness achieves exactly that. A memory‑hard function requires a large, fixed amount of random‑access memory (RAM) to compute the result, and the computation proceeds in such a way that the memory accesses are unpredictable (data‑dependent). This defeats caching and makes parallel execution on GPUs or ASICs inefficient, because these architectures rely on high bandwidth to local memory but suffer when each thread needs a large private scratchpad.

But before we dive into the internals of scrypt and Argon2, we need to understand why earlier attempts failed, and why memory hardness wasn’t invented earlier.

## The Long Road: From Plaintext to Slow Hashing

### Passwords in the Stone Age

In the early days of the internet, many systems stored passwords in plaintext. That meant the password file was a simple list: `username:password`. When a user logged in, the system compared the submitted password directly to the stored string. This was catastrophically insecure. If an attacker gained access to the password file—through a misconfiguration, a database dump, or an SQL injection—every account was compromised instantly. Not only for that service, but for any other service where the user reused the same password.

### The First Fix: Cryptographic Hashes

The obvious improvement was to store a cryptographic hash of the password. Hash functions like MD5, SHA-1, and later SHA-256 are one‑way: given the output, it is computationally infeasible to recover the input. So the server would compute `hash(password)` and store that. On login, it would recompute the hash and compare.

This sounds secure, but it has a fatal flaw: **rainbow tables**. Since the hash function is deterministic, a pre‑computed table mapping common passwords to their hashes allows an attacker to reverse the hash in milliseconds. The solution was **salting**: adding a random, unique string to each password before hashing. The stored record now contains `salt:hash(salt || password)`. Rainbow tables become infeasible because each salt creates a different hash.

But even with salting, a single iteration of SHA-256 is far too fast. An attacker with a GPU can compute billions of hashes per second, enumerating the entire common‑password dictionary in seconds. The defender needed to slow down the hash evaluation.

### PBKDF2: The Brute‑Force Throttle

PBKDF2 (Password‑Based Key Derivation Function 2, RFC 2898) was designed to add a configurable work factor. It applies a pseudorandom function (typically HMAC‑SHA256) many times: `dk = PBKDF2(PRF, password, salt, c, dkLen)`, where `c` is the iteration count. The idea is simple: if you want the hash to take 100 ms, you set `c` high enough to achieve that on the server’s CPU. The attacker, who also uses a CPU, is slowed down equally. So far so good.

But the attacker doesn’t have to use a CPU. GPUs can compute HMAC‑SHA256 in parallel with extreme efficiency. A 10,000‑core GPU can evaluate PBKDF2‑SHA256 with `c=100,000` in roughly the same wall‑clock time per guess as a CPU with `c=100`. The iteration count doesn’t increase the attacker’s _memory_ requirement—each GPU core executes the same small logic, needing only a few registers. The attacker’s cost is linear in `c` but the parallelism factor gives them a three‑orders‑of‑magnitude advantage.

PBKDF2 is a CPU‑hard function. It fails to protect against custom hardware.

### bcrypt: Introducing a Small Memory Footprint

bcrypt, designed by Niels Provos and David Mazières in 1999, attempted to address the GPU problem by using a large (but not huge) internal state and a complicated key schedule derived from the Blowfish cipher. bcrypt runs a variant of the Blowfish key schedule for 2^cost iterations, mixing the password and salt into the P‑array and S‑boxes. The memory footprint is about 4 KB (the Blowfish state). This is sufficient to make GPU attacks somewhat harder, but still trivial because 4 KB fits easily into a GPU’s shared memory or registers. Modern GPU implementations of bcrypt can achieve millions of hashes per second per card.

Moreover, bcrypt’s cost parameter is limited; doubling the cost doubles the time, but the memory remains constant. It does not force the attacker to allocate more memory. So an ASIC can be built with a 4‑KB scratchpad per core, achieving extremely high throughput. bcrypt is _memory‑light_, not memory‑hard.

### The Paradigm Shift: Memory Hardness

The insight that changed password hashing forever came from two directions: the academic side with the 1997 paper “Random Oracles in a Folklore Construction” and the practical side with Colin Percival’s scrypt in 2009. Percival, a FreeBSD security officer, wanted a key derivation function that would be resistant to large‑scale hardware attacks. He introduced the concept of **memory hard functions**, where the cost of computing the function grows not only with CPU time but also with the amount of memory required. More importantly, the memory accesses must be _sequential_ or at least _data‑dependent_ to prevent trivial parallelization.

The core idea: **Make the attacker build a large memory “scratchpad” and then read from it in an unpredictable order.** Since memory latency is the bottleneck (not arithmetic), and since each guess requires a full pass through that large memory, the attacker cannot simply use tiny fast caches. They must pay the cost of allocating and accessing a large, random array. On a GPU, each thread needs its own copy of that array, and the total memory per GPU quickly becomes the limiting factor. A consumer GPU might have 24 GB of RAM, but with a function requiring 64 MB per hash, you can only run ~375 parallel threads. That’s a dramatic reduction from the 10,000 cores you could use for SHA-256.

Memory hardness is not a binary property; it’s a spectrum. The amount of memory, the access pattern (data‑dependent vs data‑independent), and the mixing function all affect the “hardness.” Let’s now examine the two most prominent memory‑hard password hashers: scrypt and Argon2.

## Scrypt: The First Production‑Ready Memory‑Hard Hash

Scrypt was designed by Colin Percival as a key derivation function (KDF) for generating cryptographic keys from passwords. It was later adopted by several cryptocurrencies (e.g., Litecoin) as a proof‑of‑work algorithm. As a password hash, it is specified in RFC 7914.

### High‑Level Structure

Scrypt has three nested loops:

1. **PBKDF2‑HMAC‑SHA256** with the password and salt to generate an initial block of pseudorandom data.
2. **ROMix** (sequential memory‑hard mixing) using Salsa20/8 as the core mixing function.
3. **PBKDF2‑HMAC‑SHA256** again to produce the final key.

The middle step is where the memory hardness lies. It takes a parameter `N` (the cost factor) that determines the memory usage: `128 * N` bytes (actually `128 * r * N` when using the parallel variant, but we focus on the basic `r=1` case). Typically `N = 2^14` (16384) yields 2 MB of memory. The user also supplies `r` (block size, default 8) and `p` (parallelization factor).

The ROMix algorithm:

- Input: a block `B` of length `128 * r` bytes (i.e., `r` Salsa20 blocks of 64 bytes each, but Salsa20/8 works on 64‑byte chunks). For simplicity, we’ll assume `r=1`.
- Initialization: Allocate an array `V` of `N` elements, each of size `128 * r` bytes. Fill `V[0]` with `B`. Then for `i` from 1 to `N-1`: `V[i] = salsa20_8(V[i-1] XOR B)`? Wait, the actual scrypt ROMix algorithm, as specified in RFC 7914, uses a different fill: `V[i] = blockmix_salsa8(V[i-1])`. The blockmix_salsa8 function combines two Salsa20/8 operations with XOR. But for conceptual understanding, think of `V` as a linear chain of random blocks.
- After filling `V`, we repeatedly index into it using data‑dependent indices derived from the current state. Specifically, we set `X = V[N-1]` and then for `i` from 0 to `N-1`:
  - Compute `j = integerify(X) mod N` (integerify interprets the first 64 bits of `X` as a little‑endian integer).
  - `X = blockmix_salsa8(X XOR V[j])`.
- Output `X`.

The critical point: the indices `j` depend on the current value of `X`, which in turn depends on all previous indices. This creates a sequential dependency chain. You cannot compute the `i`‑th iteration before you know `X` from the previous iteration. Moreover, the memory array `V` is accessed in a highly unpredictable pattern, leading to **random memory access** (RAM latency). On a CPU, this is exactly what we want: each iteration forces a cache miss that takes ~60–100 ns. On a GPU, each thread would need to access its own huge array, causing global memory bottlenecks. Salsa20/8 itself is fast—only 8 rounds of the Salsa20 core—but the memory latency dominates.

### Salsa20/8: The Mixing Core

Salsa20 is a stream cipher designed by Daniel J. Bernstein. Its core is a quarter‑round function that mixes 16 32‑bit words (64 bytes). Salsa20/8 uses 8 rounds (i.e., 4 double‑rounds) of this mixing to provide good diffusion with low computational cost. Because scrypt uses Salsa20/8 in a feedback loop, it effectively “mixes” the data in a way that is both GPU‑unfriendly and highly parallel inside the 64‑byte block.

### Security and Practical Considerations

Scrypt’s memory hardness is proven in the sense that any algorithm that reduces memory usage (e.g., a time‑memory trade‑off) incurs a large computational penalty. The inversion attack is even more costly.

However, scrypt has some limitations:

- The memory access pattern is fully data‑dependent. This opens a potential side‑channel. If an attacker can observe the timing or cache misses during the hash, they could infer bits of the password. In practice, this is hard to exploit remotely, but it’s a concern for local attackers.
- The mixing function (Salsa20/8) is not hardware‑friendly for ASICs because it requires bitwise rotations and additions, but ASIC designers can still build dedicated units. The real barrier is the memory hierarchy.
- scrypt’s parallelism parameter `p` is not true parallelism; it just runs `p` independent threads (each with its own memory). This increases memory linearly but does not increase the sequential data dependency. An attacker could run many threads on a CPU or GPU, each consuming its own memory block, as long as total GPU memory suffices. With large `p`, the memory requirement grows, but the latency penalty per guess remains the same.

In the end, scrypt was a huge step forward, but it wasn’t the final word. In 2013, the Password Hashing Competition (PHC) was launched to find a successor that would be more robust against evolving hardware, especially ASICs.

## Argon2: The PHC Winner and Modern Gold Standard

Argon2, designed by Alex Biryukov, Daniel Dinu, and Dmitry Khovratovich, won the Password Hashing Competition in 2015. It is memory‑hard, side‑channel resistant in one variant, and highly configurable. Argon2 comes in three flavors: Argon2d, Argon2i, and Argon2id.

- **Argon2d**: Uses data‑dependent memory access. Strongest resistance against time‑memory trade‑offs but vulnerable to side‑channel attacks (cache timing). Suitable for environments where side‑channels are not a threat (e.g., server‑side hashing).
- **Argon2i**: Uses data‑independent memory access. Resistant to side‑channel attacks, but weaker against time‑memory trade‑offs. Designed for key derivation on devices where an attacker might trigger cache collisions.
- **Argon2id**: A hybrid. First half of the passes uses data‑independent access (like Argon2i), second half uses data‑dependent access (like Argon2d). This provides the best of both worlds: side‑channel resistance during the part where the password is still influential, and strong memory hardness later. This is the recommended variant for general‑purpose password hashing.

### Argon2 Internal Structure

Argon2 works over a memory matrix of `m` blocks, where each block is 1024 bytes (1 KB). The matrix dimensions are `m = p * t` where `p` is the number of lanes (parallelism) and `t` is the number of slices per lane. Usually the memory size is between 15 MB (recommended minimum) and 64 MB. The number of passes (`time` parameter) is often 1–3. A single pass is sufficient for memory hardness on its own, but multiple passes increase CPU cost without increasing memory.

The algorithm proceeds in **slices** and **passes**:

1. **Initialize** the memory blocks with pseudorandom data derived from the password, salt, and parameters.
2. **Fill** the memory matrix using a **compression function** `G`. The compression function takes two 1024‑byte blocks and produces one: `G(X, Y) = Z`. It uses a combination of Blake2b (a fast hash) and a custom mixing function.
3. **Access pattern**: For each block to be computed, the hash uses the indices of two previously computed blocks. In Argon2d, those indices are determined by the value of the current block itself (data‑dependent). In Argon2i, the indices are determined by a deterministic sequence that does not depend on the block contents (data‑independent). In Argon2id, the first half of the passes uses data‑independent, the second half uses data‑dependent.

The core idea is similar to scrypt: fill a large memory, then access it in a pseudorandom order, and the cost of random memory access dominates. But Argon2 improves over scrypt in several ways:

- **Larger block size**: 1024 bytes instead of 64 bytes, making it more cache‑unfriendly per block.
- **Better mixing function**: The compression function `G` is built from Blake2b, which is faster than Salsa20/8 and more standard.
- **Parallelism with memory sharing**: Argon2 can run up to `p` lanes in parallel, but they share the same memory matrix. This allows a server to use multiple CPU cores to compute a single hash faster, while still maintaining the same memory cost per thread. An attacker cannot split a single hash across many GPUs because the memory access pattern is sequential and depends on all previous blocks.
- **Time‑memory trade‑off resistance**: Argon2d’s data‑dependent access makes it extremely resistant to memory‑reduction attacks. Even reducing memory by 20% multiplies the computational cost by 2–4. Argon2i has a weaker guarantee but is still strong. Argon2id provides a balanced trade‑off.

### The Compression Function G

The heart of Argon2 is the function that takes two memory blocks `X` and `Y` and produces a new block `Z`. First, it computes `R = X XOR Y`. Then it applies a Blake2b hash of `R` (128 bytes output) to get a seed. Then it uses a custom permutation called **AR2-128** (a set of rotations and additions) to mix the 128‑byte block horizontally and vertically. The final block is `Z = G(X, Y)`. This design ensures that each new block depends heavily on both input blocks, preventing shortcutting.

### Practical Parameters

When you use Argon2 in a library like `libsodium` or the Node.js `argon2` package, you specify:

- `time` (t): number of passes (usually 1–3).
- `mem` (m): memory size in kibibytes (e.g., 2^16 = 64 MB).
- `parallelism` (p): number of threads (usually 1–4).
- `variant`: Argon2id is recommended.

For a modern server, setting `time=2`, `mem=64 MB`, `p=2` yields a hash time of about 0.5–1 second on a single CPU core. That’s acceptable for login (users can wait a second) but makes a GPU brute‑force attack extremely expensive. Even a high‑end GPU with 24 GB of RAM can only run ~384 threads (24 GB / 64 MB = 384). And because Argon2’s memory access pattern is highly random, those threads will cause massive memory‑bandwidth contention, reducing throughput. The attacker’s guess rate drops to a few hundred hashes per second per GPU, instead of billions.

### Side‑Channel Resistance

Argon2i’s data‑independent access pattern ensures that an attacker cannot use cache timing to learn the password. In a shared environment (e.g., cloud VM), an attacker might run a malicious process on the same physical core that can observe cache misses. With data‑dependent access, the attacker could deduce the sequence of indices, which reveals bits of the intermediate state and eventually the password. Argon2i avoids that by computing index sequences using a deterministic, password‑independent method. The cost: it is slightly less resistant to time‑memory trade‑offs. Argon2id gives you the best of both worlds: the first half (where password influence is still minimal) uses data‑independent access; the second half (where password has already been well mixed) uses data‑dependent access, so the final memory hardness is high.

## Comparison: Scrypt vs. Argon2

| Feature                          | Scrypt                                         | Argon2                                                              |
| -------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------- |
| Block size                       | 128‑1024 bytes (configurable via `r`)          | 1024 bytes (fixed)                                                  |
| Core mixing                      | Salsa20/8                                      | Blake2b + custom permutation                                        |
| Data access pattern              | Data‑dependent (ROMix)                         | Data‑dependent (Argon2d), independent (Argon2i), hybrid (Argon2id)  |
| Side‑channel resistance          | None (data‑dependent)                          | Argon2i & Argon2id have it                                          |
| Parallelism                      | `p` independent threads, each with own memory  | `p` lanes sharing memory matrix efficiently                         |
| Time‑memory trade‑off resistance | Good, but not as tight as Argon2d              | Excellent for Argon2d, good for Argon2i                             |
| Standardization                  | RFC 7914                                       | RFC 9106 (Argon2)                                                   |
| Cryptographic audit              | Widely analyzed, some concerns about Salsa20/8 | Intensively analyzed, PHC winner, over 30 independent cryptanalyses |

In general, **Argon2id is the recommended choice** for new implementations (as of 2024). Scrypt is still secure for legacy systems, but its lack of side‑channel resistance and its inferior parallel scaling make it second‑best.

## Implementation Details and Code Example

Let’s touch on how you might use these in production. In Python, using `hashlib`:

```python
import hashlib
import os

# Scrypt: N = 2^14 (16 MB), r = 8, p = 1
salt = os.urandom(16)
dk = hashlib.scrypt(b'my_password', salt=salt, n=2**14, r=8, p=1, dklen=32)
```

But note: Python’s `hashlib.scrypt` is a simple wrapper; it does not include the side‑channel considerations.

For Argon2, use a dedicated library like `argon2-cffi`:

```python
from argon2 import PasswordHasher

ph = PasswordHasher(
    time_cost=2,          # number of passes
    memory_cost=65536,    # 64 MB
    parallelism=2,        # number of threads
    hash_len=32,
    salt_len=16,
    type=PasswordHasher.ARGON2ID
)
hashed = ph.hash("my_password")
# $argon2id$v=19$m=65536,t=2,p=2$<salt>$<hash>
```

In Node.js:

```javascript
const argon2 = require("argon2");
const hash = await argon2.hash("my_password", {
  timeCost: 2,
  memoryCost: 65536,
  parallelism: 2,
  type: argon2.argon2id,
});
```

## The Arms Race Continues

While Argon2 and scrypt are today’s best practice, the arms race never stops. ASICs can be built with integrated DRAM, allowing memory‑hard functions to be computed in dedicated hardware, albeit at a higher cost per unit. Memory‑hardness buys time, but eventually the attacker’s economies of scale might erode that advantage.

Future functions may incorporate **cache‑hardness** (requiring tight control of the cache hierarchy) or **bandwidth‑hardness** (forcing the attacker to waste memory bandwidth). Some research explores using post‑quantum assumptions. But for now, the most important step you can take is to use Argon2id with reasonable parameters.

## Conclusion: Why You Should Care

The code you never see—the password hash—is the unsung hero of internet security. It is the last line of defense after everything else fails. A single SQL injection leak could expose millions of hashes. If those hashes are plain SHA-256, the attacker’s job takes minutes. If they are Argon2id with 64 MB of memory, the attacker’s job takes decades.

Memory hardness is not a luxury; it is a necessity. It forces attackers to invest in memory and bandwidth rather than pure parallel arithmetic. By understanding how scrypt and Argon2 work, you can make informed decisions about security parameters and appreciate the mathematical elegance behind the login button.

The next time you click “Forgot password,” remember: somewhere, deep in a server, a memory‑hard function is fighting a silent war against silicon. And with the right algorithm, it’s a war you can win.
