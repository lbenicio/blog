---
title: "Implementing A Private Information Retrieval (Pir) Scheme With Computational And Information Theoretic Guarantees"
description: "A comprehensive technical exploration of implementing a private information retrieval (pir) scheme with computational and information theoretic guarantees, covering key concepts, practical implementations, and real-world applications."
date: "2022-06-07"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/implementing-a-private-information-retrieval-(pir)-scheme-with-computational-and-information-theoretic-guarantees.png"
coverAlt: "Technical visualization representing implementing a private information retrieval (pir) scheme with computational and information theoretic guarantees"
---

# The Privacy Paradox of Database Queries: A Deep Dive into Private Information Retrieval

## Introduction: The Privacy Paradox of Database Queries

Imagine you are a doctor researching a rare genetic disorder. You suspect that patients carrying a particular mutation respond exceptionally well to an experimental therapy. To test your hypothesis, you need to query a large, publicly funded medical database that contains anonymized treatment outcomes for thousands of individuals. Your query is simple: “How many patients with genotype X experienced remission after receiving therapy Y?” But here’s the catch—you do not want the database administrators, or anyone eavesdropping on your network, to know _which_ genotype or _which_ therapy you are investigating. Why? Because the very act of asking reveals information about your research direction, your intellectual property, or the vulnerable populations you care about. In a world of data brokers, surveillance capitalism, and adversarial governments, the ability to search a dataset without revealing what you searched for is not a luxury—it is a fundamental requirement for free inquiry, competitive intelligence, and personal privacy.

This is the problem that **Private Information Retrieval (PIR)** aims to solve. At its core, PIR allows a client to retrieve a record from a database without revealing to the database server(s) which record was fetched. Since its introduction by Chor, Goldreich, Kushilevitz, and Sudan in 1995, PIR has become a cornerstone of privacy-preserving computation, with applications ranging from anonymous web browsing to patent searches, location-based services, and secure elections. Yet despite decades of research, deploying PIR in practice remains a delicate balancing act between three conflicting goals: **privacy strength**, **efficiency**, and **trust assumptions**. The devil, as always, lies in the trade-offs.

### Why Not Just Encrypt Everything?

A natural first thought: if the database is encrypted, doesn't that protect the query? Not exactly. Encryption protects the _content_ of the data from eavesdroppers, but the _query itself_ is still visible. If you download the entire encrypted database and decrypt it locally, you learn everything, but that’s bandwidth-prohibitive for large datasets. If you instead ask the server to return a specific encrypted record, the server sees which record you requested—thus learning your query. Even if you use a secure channel (e.g., TLS), the server itself knows exactly which record you accessed. PIR goes a step further: it hides the _identity_ of the record from the server (or from any set of colluding servers up to a threshold). This is fundamentally different from encryption, which only hides the _content_.

### The Scope of This Article

In this comprehensive post, we will explore the two canonical flavors of PIR—information-theoretic and computational—and then investigate how modern research attempts to unify their strengths while mitigating their weaknesses. We will walk through detailed constructions, examine real-world applications, and discuss the practical hurdles that have kept PIR on the fringes of deployed privacy technology. Along the way, we’ll encounter elegant combinatorial designs, number-theoretic magic, and the hard limits imposed by information theory and computational complexity. By the end, you’ll have a deep understanding of why PIR is both tantalizing and maddeningly difficult to get right.

---

## 1. Setting the Stage: Formalizing Private Information Retrieval

Before diving into the flavors, let’s define the problem precisely. A PIR protocol involves two parties:

- **Client**: wants to retrieve a single record (bit, byte, or block) from a database of size _n_.
- **Server(s)**: hold the database, which is an array of _n_ records, each of size _b_ bits.

The protocol satisfies:

1. **Correctness**: If all parties follow the protocol, the client learns the desired record.
2. **Privacy**: The server (or any coalition of servers, depending on the model) learns nothing about which index was queried. More formally, the server’s view of the protocol is statistically or computationally indistinguishable for any two distinct query indices.

### Communication Complexity

The primary efficiency metric in PIR is communication complexity—the total number of bits exchanged between client and server(s). Ideally, we want this to be sublinear in _n_, because if the client had to download the whole database (_O(n)_ communication), they could trivially achieve privacy by extracting the needed record locally. That naive approach is indeed private (the server learns nothing), but it’s impractical for large _n_. The challenge is to reduce communication below _n_ while still hiding the query.

### Why Information-Theoretic PIR Requires Multiple Servers

In 1995, Chor et al. proved a fundamental lower bound: **any 1-server information-theoretic PIR scheme must have communication complexity at least _n_ bits** (assuming _b=1_). Intuitively, with a single server, the server must send back _n_ bits worth of information to make the client’s request indistinguishable from any other request; otherwise, some index will be systematically excluded. This impossibility result forces a choice: either relax the privacy guarantee to computational (allowing the server to have bounded computational power) or use multiple non-colluding servers to achieve information-theoretic security. This dichotomy defines the two main branches of PIR.

---

## 2. Information-Theoretic PIR (IT-PIR): Leveraging Multiple Servers

Information-theoretic PIR achieves perfect privacy without relying on computational hardness assumptions. The catch: it requires multiple servers (typically _k_ ≥ 2) that are assumed **not to collude**—that is, they will not share their views of the protocol to deduce the client’s query. If they do collude, privacy is lost.

### The Simple Two-Server Scheme for a Single Bit

Let’s start with the simplest case: a database of _n_ bits. The client wants to retrieve bit _i_. There are two servers, each holding an identical copy of the database.

The protocol:

1. The client generates _k_ random bit strings (or vectors) that XOR to a vector with a 1 at position _i_ and 0 elsewhere. For two servers, the client picks a random _n_-bit string _q₁_ uniformly. Then sets _q₂_ = _q₁_ ⊕ _eᵢ_, where _eᵢ_ is the unit vector with a 1 at position _i_.
2. The client sends _q₁_ to server 1 and _q₂_ to server 2.
3. Each server computes the dot product (mod 2) of its received query vector with the database vector _DB_: _r₁_ = ⟨_q₁_, _DB_⟩, _r₂_ = ⟨_q₂_, _DB_⟩. They return these single bits.
4. The client computes _r₁_ ⊕ _r₂_ = ⟨_q₁_ ⊕ _q₂_, _DB_⟩ = ⟨_eᵢ_, _DB_⟩ = _DB[i]_.

**Why is this private?** Each server sees only a uniformly random query vector (since _q₁_ is random, and _q₂_ is random as well, because XORing with a fixed _eᵢ_ preserves uniformity). Thus, each server’s view is independent of _i_; they have no information about which index the client wants. Even if an adversary observes one server, they learn nothing.

**Communication**: Each server receives _n_ bits, so total upload is _2n_ bits. Each server returns 1 bit, so download is 2 bits. Total _2n+2_ bits. That’s still linear in _n_, which is better than the trivial _n_ from one server? Actually, the trivial approach (download all _n_ bits) would require _n_ bits download from one server, but here we have _2n_ upload + 2 download. However, the upload can be reduced using more clever constructions.

### Reducing Communication with More Servers

Chor et al. showed that with _k_ servers, one can achieve communication complexity _O(n^{1/k})_. The idea is to treat the database as a _k_-dimensional hypercube. For example, with _k=4_ servers, you can achieve _O(n^{1/4})_ communication. The detailed construction involves partitioning the indices into _k_ dimensions and applying a recursive query expansion. We won’t go into the full math here, but the key insight is that each server returns a single bit for a “subcube” of the database, and the client combines them to recover the desired bit.

### Advantages and Disadvantages of IT-PIR

**Advantages:**

- Perfect privacy: no computational assumptions protects against adversaries with unlimited computing power.
- Simple, low-latency computation: servers only compute dot products (XORs) – extremely fast in hardware or software.
- Well-understood security models.

**Disadvantages:**

- Requires multiple non-colluding servers. In practice, collusion is hard to prevent unless servers are operated by independent entities (e.g., different organizations, different legal jurisdictions). This increases deployment complexity.
- Communication complexity is still polynomial in _n_ for any fixed number of servers, and for very large databases (e.g., billions of records) can be prohibitive.
- The database must be replicated across all servers, increasing storage and consistency overhead.

### A Concrete Example: Medical Database Query

Let’s flesh out the medical researcher example. Suppose the database has _n = 10,000,000_ patient records (roughly the size of a large hospital system’s de-identified data). Each record could be a single bit (e.g., whether the patient satisfied a condition). With a two-server IT-PIR scheme, the client must upload two vectors of 10 million bits each: that’s 2.5 MB per query (assuming 8 bits per byte, but we’re dealing with bits directly). Download is trivial (2 bits). 2.5 MB upload might be acceptable on a fast network, but if the researcher runs millions of queries (e.g., for machine learning feature extraction), it becomes costly. With a four-server scheme using _O(n^{1/4})_ communication, we could reduce upload to roughly _n^{1/4} = 10000^{1/4} ≈ 316_ bits (neglecting constants). That’s a huge improvement! But now we need four independent servers to trust.

### Real-World IT-PIR Deployments

Several research projects have implemented IT-PIR. One notable example is **Groth’s PIR** (2010) using Shamir secret sharing, achieving constant communication per server but requiring a number of servers quadratic in the security parameter. Another is the **Bentov et al. PIR** (2017) which uses lattice-based secret sharing to get very efficient multi-server PIR. However, none have seen widespread adoption due to the non-collusion requirement.

---

## 3. Computational PIR (CPIR): One Server, Cryptographic Guarantees

If we are willing to rely on computational hardness assumptions (e.g., factoring, discrete log, or lattice problems), we can achieve PIR with a single server. This is called **Computational PIR** (CPIR). The first such scheme was given by Kushilevitz and Ostrovsky in 1997, based on the Quadratic Residuosity Assumption (QRA). Since then, many improvements have been proposed.

### The Kushilevitz–Ostrovsky (KO) Scheme

We’ll sketch the original KO scheme. The database is an _n_-bit string. The client wants to retrieve bit _i_. The scheme works by recursively compressing the database using the Goldwasser-Micali encryption scheme, which encrypts bits under the QRA.

**High-level idea:**

- View the database as a _k_-dimensional cube (similar to the multi-server approach), but now the servers perform homomorphic operations on encrypted queries.
- The client encrypts a query vector that indicates the desired index, using a public-key encryption scheme that allows a limited form of homomorphic computation (XOR of ciphertexts corresponds to XOR of plaintexts).
- The server computes the dot product of the encrypted query with the database in the encrypted domain, returning an encrypted result.
- The client decrypts to get the desired bit.

The key is that the server sees only ciphertexts and learns nothing about the query due to semantic security (computational indistinguishability).

**Communication**: The original scheme achieved _O(n^{1/k})_ communication for a _k_-dimensional recursion, but with _k = O(log n)_, it can achieve _O(n^ε)_ for any ε > 0, or even _O(poly(log n))_ in later constructions using fully homomorphic encryption (FHE). However, early CPIR schemes suffered from enormous server-side computation: _O(n)_ modular multiplications per query, which for large _n_ (e.g., 10^6) is millions of operations, making it slower than simply transmitting the whole database.

### Modern CPIR: Lattice-Based PIR

The past decade has seen a revolution in CPIR thanks to **fully homomorphic encryption (FHE)** and **somewhat homomorphic encryption (SWHE)** based on lattice problems (Learning With Errors, LWE). In particular, the **Ring-LWE** variant allows very efficient polynomial multiplication, which is the core operation in many modern PIR schemes.

A landmark work is **`Spiral`** (2020) by Menon and Wu, which achieves sub-second query times for databases of millions of entries. The idea: represent the database as a matrix of polynomials, and the client sends a query that is an FHE-encrypted “selector polynomial” that zeroes out all rows except the one containing the desired record. The server performs matrix-vector multiplication in the encrypted domain using number-theoretic transforms (NTTs), returning a single encrypted polynomial. The client decrypts to extract the answer.

**Communication**: For a database of _N_ records, each of size _B_ bytes, Spiral achieves communication of roughly *2*KB + _B_ (near-optimal). Server computation is about _O(N log N)_ operations, but optimized NTT implementations make this feasible for _N_ up to 10^7 on a single machine.

### Why One Server is Attractive

A single-server PIR eliminates the collusion trust model. The client only needs to trust the database server to perform the computation correctly (or verifiability can be added). Moreover, it avoids the overhead of maintaining multiple synchronized replicas. For many applications, the simplicity of a single server outweighs the higher computational cost—especially as hardware accelerators (e.g., GPUs, ASICs) and optimized cryptographic libraries become available.

### The Achilles’ Heel: Server Computation

Despite recent breakthroughs, CPIR still incurs a significant server-side computational burden. For a database of size _G_ gigabytes, the server may need to process a significant fraction of the database for each query. In the naive approach, the server must essentially touch every record. Even with batching and SIMD operations, this can be a bottleneck. For example, a 1 GB database processed by a server with 10 GB/s bandwidth and high-throughput FHE might take 100 ms per query, which is fine for moderate loads, but for thousands of queries per second it becomes infeasible. By contrast, IT-PIR with multiple servers has trivial server computation (XORs) but requires network bandwidth.

### Example: Patent Search

Consider a patent examiner who wants to search a database of 10 million patent abstracts for prior art without revealing the keywords or the patent being examined. With a single-server CPIR, they could submit an encrypted keyword query. The server processes all abstracts in encrypted form, returning encrypted similarity scores. The examiner decrypts the top results. This protects the examiner’s interests from the patent office or competitors. With modern lattice-based PIR, the communication might be a few hundred kilobytes, and server time a few seconds—acceptable for a single query but not for high-throughput.

---

## 4. The Trust Assumption Spectrum

Beyond the IT vs. CP dichotomy, trust assumptions vary widely. Let’s map them:

- **Single-server, no assumptions** – impossible (information-theoretic lower bound).
- **Single-server, computational hardness** – CPIR. Trust that the cryptographic primitives are secure and that the server does not leak information via side channels.
- **Multiple servers, no collusion** – IT-PIR. Trust that at most _t_ servers collude (usually _t < k_). Requires independent server operators.
- **Hybrid: computational with multiple servers** – can reduce collusion threshold or improve efficiency. For example, using secret sharing across servers but encrypting the shares to prevent honest-but-curious servers from learning shares even if they collude.
- **Trusted execution environments (TEEs)** – not PIR per se, but an alternative: run the query inside an enclave (Intel SGX, AMD SE, etc.) such that the server only sees encrypted data and code. This provides privacy if the TEE is trustworthy, but introduces hardware trust that has been historically breached (e.g., SGX attacks).

PIR’s advantage over TEEs is that it relies only on mathematical guarantees, not on proprietary hardware.

---

## 5. Toward a Unified Scheme: Blending IT and CP

Given the stark trade-offs, researchers have sought protocols that combine the best of both worlds. The idea is to use multiple servers to split the computational load and reduce collusion concerns, while using lightweight cryptography to achieve privacy even if some servers collude. This is sometimes called **Robust PIR** or **Hybrid PIR**.

### Case Study: The DPF-Based Approach

A particularly elegant unified construction comes from **Distributed Point Functions (DPFs)**. A point function is a function that equals 1 at a specific point _i_ and 0 elsewhere. A DPF allows a client to distribute the description of a point function across _k_ servers such that each server’s share reveals nothing about _i_, but the servers can locally evaluate the function on any input _j_ and combine their results to learn the output.

DPFs can be built from lightweight computational assumptions (e.g., pseudorandom generators) and require only _O(log n)_ communication per server. Then, for a database _DB_, the client sends each server a DPF share for the point function _f_i_. Each server computes the dot product of its share’s evaluation over all _n_ positions with the database, returning a single value. The client combines these to recover _DB[i]_.

**Result**: Communication is _O(k log n)_ bits (small!), server computation is _O(n)_ operations per server (but these operations are cheap—just XORs or multiplications in a finite field). If the servers do not collude, the privacy is information-theoretic (since each share is independent and uniformly random given all but one share). If up to _t_ servers collude, privacy degrades gracefully (DPF can be designed to tolerate _t_ collusions with larger shares).

This hybrid approach significantly reduces communication compared to classical IT-PIR while keeping server computation low. It also reduces the trust requirement: you can use, say, three servers where any two colluding still cannot learn the query, but the system is still efficient.

### Another Unified Path: Homomorphic Secret Sharing

Homomorphic secret sharing (HSS) generalizes DPF to support more complex computations. With HSS, the client generates shares of a function that can be evaluated locally by each server, and the results combine to reveal the desired output. This bridges the gap between multi-server IT-PIR and single-server CPIR: the computation is done locally (no cryptographic work by servers beyond simple operations), but the privacy relies on a computational assumption (pseudorandomness of the shares). This yields very efficient protocols.

### The Dream: One Query, Any Database

Ultimately, a unified scheme would offer:

- Sublinear communication (ideally logarithmic)
- Server computation linear in the database size but with very small constants (like XORs)
- Minimal trust—possibly a single server with computational privacy but acceptable performance
- Graceful degradation under collusion

No single scheme achieves all these simultaneously, but recent progress in DPF and HSS suggests we are close. For instance, the **`pRiv`** system (2018) by Backes et al. uses DPFs to achieve PIR with communication in the order of hundreds of bytes and server time under 0.1 ms per index in a 1 GB database, using two non-colluding servers. That’s remarkable.

---

## 6. Real-World Deployments and Applications

PIR has long been a theoretical curiosity, but the past five years have seen serious efforts to bring it to production. Let’s survey some compelling use cases.

### 6.1 Private Set Intersection (PSI) and Password Checkers

One of the most popular real-world uses of PIR is in password breach checking. Services like **Have I Been Pwned** (HIBP) allow users to check if their password has been exposed in a breach. However, the naive approach requires sending the password (or a hash prefix) to the server, which reveals the password or partial hash. HIBP uses k-anonymity via hash prefixes, but that still leaks a range.

With PIR, a client can query the HIBP database of hashed passwords without revealing which hash they are checking. This is a perfect PIR use case because the database is large (hundreds of millions of entries), but queries are relatively rare for individual users. A CPIR scheme like Spiral can serve this: the user downloads an encrypted response of a few kilobytes, and the server processes the whole database. Some startups (e.g., **1Password** ) have implemented such features using PIR.

### 6.2 Anonymous Patent and Literature Search

As mentioned earlier, patent offices, R&D companies, and academic researchers need to search prior art without revealing their search terms. A PIR-based patent search engine would allow a client to retrieve abstracts or full documents related to specific keywords without the server learning the keywords. The database could be the full corpus of patent texts (hundreds of GB). A multi-server PIR with DPFs could make this practical: the client sends short queries to each of a few servers, and the servers return aggregated results. This protects trade secrets and preliminary research directions.

### 6.3 Private Location-Based Services

When you ask a mapping service “nearest gas station”, the server learns your location. A location-based service using PIR could allow you to retrieve points of interest near your location without revealing coordinates. The database would be a grid of cells with precomputed data (e.g., nearest POI). The client queries the cell containing its location using PIR. This is a classic use case and has been studied extensively.

### 6.4 Secure Elections and Verifiable Mixing

In electronic voting, voters need to verify that their vote is recorded correctly without revealing how they voted. PIR can be used to allow voters to audit the ballot box: they can retrieve a commitment (or ciphertext) corresponding to their encrypted vote, without the election authority learning which voter is auditing. This protects against coercion while maintaining transparency.

### 6.5 Anonymous Web Browsing (Beyond Tor)

Tor provides anonymity by routing traffic through multiple relays, but it does not hide the content of the traffic from the exit node. Moreover, the exit node can observe which sites you visit. A PIR proxy could download a webpage without revealing which page to the server. However, today’s PIR is not fast enough for real-time streaming (video, etc.), but for static content or one-time fetches it could complement Tor.

### 6.6 Commercial Offerings

A few startups have emerged offering PIR as a service:

- **Cape Privacy** (now part of Baffle) – focused on encrypted query processing, though not pure PIR.
- **Stealth Software** – work on PIR for healthcare.
- **OpenMined** – open-source community exploring PIR for federated learning.

In 2021, Google published a paper on **PIR for Safe Browsing**, demonstrating a multi-server PIR system that checks URLs against a list of malicious sites without revealing the visited URL. They achieved low latency (~100ms) using two non-colluding servers.

---

## 7. Practical Challenges and Open Problems

Despite these advances, PIR is far from mainstream. Let’s analyze the remaining obstacles.

### 7.1 Server Computation Still Dominates

Even with the fastest CPIR algorithms, the server must process a significant portion of the database per query. For a 10 GB database, the server might need to read and compute on 10 GB of data per query. If the server handles many concurrent queries, this quickly becomes I/O-bound. Techniques like batch PIR (where multiple queries are processed together) can amortize costs, but they require clients to coordinate—often impractical.

### 7.2 Collusion in Multi-Server Models

IT-PIR’s security hinges on servers not colluding. In practice, who operates these servers? They must be independent, which introduces organizational overhead. If the same cloud provider runs all servers (e.g., AWS in two different regions), collusion is still possible—the provider could combine logs. True independence requires different jurisdictions, different legal entities, and contractual prohibitions— expensive to maintain.

### 7.3 Malicious Adversaries

Most PIR schemes assume **honest-but-curious** servers: they follow the protocol but try to learn as much as possible from the messages. Malicious servers might deviate to break privacy or to provide incorrect responses. Verifiable PIR (e.g., using zero-knowledge proofs) can ensure correctness, but adds overhead. Additionally, malicious servers could mount side-channel attacks (timing, power analysis) to infer the query. The cryptographic assumptions in CPIR do not protect against physical attacks.

### 7.4 Scalability to Very Large Databases

PIR is typically designed for static databases. If the database changes frequently (e.g., dynamic content), the system must handle updates while preserving privacy. This is an active research area called **dynamic PIR**. Most deployed systems avoid it by using periodic snapshots.

### 7.5 Legal and Business Barriers

Even if the technology is ready, companies may resist deploying PIR because they profit from knowing user queries. Ad-supported services, search engines, and data brokers build their business on analyzing queries. PIR would eliminate that data source. Thus, only applications where the client has strong privacy motivation (e.g., medical, financial, security) are likely to adopt PIR.

---

## 8. The Road Ahead: Future Directions

The field of PIR is vibrant. Here are some promising arcs:

### 8.1 PIR with Trusted Hardware

Combining PIR with TEEs (like Intel SGX) could reduce server computation: the query runs inside an enclave that decrypts the query, accesses the database, and returns the result—all without the rest of the server learning anything. This essentially builds a one-server CPIR without heavy cryptography, because the TEE acts as a trusted party. However, TEE vulnerabilities and side channels remain a risk. A hybrid approach (PIR + TEE) can provide defense in depth.

### 8.2 Rate-Limiting and Oblivious RAM

PIR can be combined with **Oblivious RAM (ORAM)** to hide the access pattern even when the client performs many queries over time, and the server sees the sequence of queries (though individually private). This prevents the server from linking queries from the same client. ORAM+ PIR is an active area.

### 8.3 Quantum-Resistant PIR

Lattice-based CPIR is believed to be post-quantum secure. However, IT-PIR (no computational assumptions) is automatically quantum-resistant. As quantum computers threaten current cryptography, the need for IT-PIR may grow, even with the multi-server overhead.

### 8.4 Standardization and Libraries

Several open-source libraries now implement PIR:

- **`pir_comp`** (C++ from Microsoft) – lattice-based CPIR.
- **`spiral`** (Rust) – high-performance CPIR.
- **`libsecp256k1` with ECDLP-based PIR** – less common.
- **`openmpir`** – multi-server PIR using DPF.

Standardization by bodies like IETF or NIST would boost adoption.

---

## 9. Conclusion: Trading Off Has Never Been More Important

Private Information Retrieval is a testament to how far cryptography has come: we can now query a database while remaining mathematically hidden, even from the database owner. Yet the field forces us to confront the fundamental trade-offs between privacy, efficiency, and trust.

For the medical researcher, the choice might be:

- Use a four-server IT-PIR with fast XOR computation, low latency, but need four independent institutions to host replicas.
- Use a single-server CPIR with heavy computation but easy deployment.
- Use a hybrid DPF-based scheme with two servers and pseudorandom secrets, offering sublinear communication and moderate trust.

No single solution fits all. The key is to match the protocol to the threat model and resource constraints.

As we move toward a world where data is increasingly centralized and privacy is increasingly threatened, PIR offers a principled path to reclaiming control over our queries—the hidden footprints of our digital lives. The next decade will likely see PIR integrated into everyday tools: your browser, your password manager, your navigation app. When that happens, the paradox of database queries will finally be resolved: you will be able to ask anything, and only you will know what you asked.

---

_Author’s note: This article has covered the foundations of PIR, the two canonical flavors, unified approaches, applications, and challenges. If you’re interested in implementing PIR, I recommend starting with the open-source libraries mentioned. For a deeper theoretical dive, the original Chor et al. paper and the Kushilevitz–Ostrovsky paper are essential reading. The future of private queries is bright—and it’s already here._
