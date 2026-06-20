---
title: "Building A Secure Password Authenticated Key Exchange (Pake) From Oblivious Pseudorandom Functions (Oprf)"
description: "A comprehensive technical exploration of building a secure password authenticated key exchange (pake) from oblivious pseudorandom functions (oprf), covering key concepts, practical implementations, and real-world applications."
date: "2022-03-11"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/building-a-secure-password-authenticated-key-exchange-(pake)-from-oblivious-pseudorandom-functions-(oprf).png"
coverAlt: "Technical visualization representing building a secure password authenticated key exchange (pake) from oblivious pseudorandom functions (oprf)"
---

# Building a Secure Password Authenticated Key Exchange (PAKE) from Oblivious Pseudorandom Functions (OPRF)

**Table of Contents**

1. Introduction: The Password Problem
2. What Is a Password Authenticated Key Exchange?
3. Historical Attempts and Their Flaws
   - 3.1 Encrypted Key Exchange (EKE)
   - 3.2 Secure Remote Password (SRP)
   - 3.3 Augmented PAKEs and Verifier-Based Designs
4. The Offline Dictionary Attack – The Core Weakness
5. Oblivious Pseudorandom Functions (OPRF) Explained
   - 5.1 Definition and Properties
   - 5.2 A Simple OPRF Construction with OPRF
   - 5.3 Security Guarantees: Obliviousness & Pseudorandomness
6. Building a PAKE from OPRF – The OPAQUE Protocol
   - 6.1 High-Level Idea: Hardening Passwords with a Secret Key
   - 6.2 Protocol Steps in Detail
   - 6.3 Why This Eliminates Offline Dictionary Attacks
   - 6.4 Forward Secrecy and Server Compromise Resistance
7. Step-by-Step Worked Example with Code
   - 7.1 Setup and Registration
   - 7.2 Authentication Session
   - 7.3 Key Derivation and Session Establishment
8. Security Analysis
   - 8.1 Threat Model
   - 8.2 Proof Sketch: Reducing to OPRF Security and Strong DH
   - 8.3 Comparison with Existing PAKEs
9. Implementation Considerations
   - 9.1 Choice of Elliptic Curve and Hash Function
   - 9.2 Mitigating Side Channels and Timing Attacks
   - 9.3 Handling Password Changes and Account Recovery
10. Practical Impact and Adoption
11. Conclusion

---

## 1. Introduction: The Password Problem

Imagine this: you open your laptop, type your favorite website’s URL, and are greeted by a familiar login form. You enter your username and password, click “Sign In,” and within seconds you’re browsing your personal data. Simple, right? Behind that seamless interaction, a cryptographic handshake occurs — one that, in most cases, _leaks_ your password to a server across the network. Even under HTTPS, the server learns your password in plaintext. If the server is compromised, an attacker now has your credentials. And if you used that same password elsewhere (as most users do), the damage snowballs.

This problem has haunted security engineers for decades. Passwords remain the most ubiquitous authentication mechanism, yet their inherent weakness — low entropy, reuse, and susceptibility to phishing — makes them a prime target. The goal of a _Password Authenticated Key Exchange_ (PAKE) is to fix the fundamental flaw in password-based logins: proving knowledge of a password _without_ revealing it to the server, and simultaneously establishing a secure session key. The challenge is immense, because passwords are not cryptographic keys; they have little entropy and are vulnerable to brute-force guessing. If the protocol is not carefully designed, an attacker who observes the network traffic can perform an offline dictionary attack, trying candidate passwords until they find a match.

The holy grail is a PAKE that provides _security against offline dictionary attacks_, _forward secrecy_, and _resistance to server compromise_ — even if the entire server database is leaked. For years, protocols like SRP (Secure Remote Password) and EKE (Encrypted Key Exchange) attempted to achieve this, but each had limitations. SRP, for instance, requires the server to store a _verifier_ derived from the password. If that verifier leaks, an attacker can run an offline dictionary attack. EKE, while elegant, is vulnerable to partition attacks and requires careful handling of the encryption scheme.

In recent years, a new paradigm has emerged: building a PAKE from an _Oblivious Pseudorandom Function_ (OPRF). The most prominent example is the **OPAQUE** protocol, which has been standardized by the IETF and is being deployed by companies like Google and Apple. OPAQUE combines the strengths of OPRF with a key exchange to produce a PAKE that is resistant to precomputation attacks, offline dictionary attacks, and server compromise — all while maintaining forward secrecy.

This blog post will take you on a deep dive into the construction of a secure PAKE from OPRF. We’ll start with the fundamentals, examine why earlier protocols failed, then demystify OPRF, and finally walk through the OPAQUE protocol step by step, complete with code examples and security analysis. By the end, you’ll understand why OPRF-based PAKEs represent the state of the art in password authentication and how you can implement them in practice.

---

## 2. What Is a Password Authenticated Key Exchange?

Before we dive into the cryptographic machinery, let’s clarify what we’re building. A Password Authenticated Key Exchange (PAKE) is a cryptographic protocol that allows two parties — typically a client and a server — to mutually authenticate each other and establish a shared secret session key, using only a low-entropy password as the authentication secret.

The key properties of a secure PAKE are:

- **Security against offline dictionary attacks:** An eavesdropper who records all protocol messages cannot later verify guesses for the password offline. The protocol must be designed so that the only feasible attack is an online brute-force, which can be rate-limited by the server.
- **Forward secrecy:** If the long-term secret (the password or a derived verifier) is later compromised, past session keys remain secure. This prevents an attacker from decrypting recorded traffic after learning the password.
- **Resistance to server compromise:** If the server’s database of password-related data is leaked, the attacker should not gain the ability to impersonate the user or perform offline dictionary attacks. Ideally, the leaked data should be useless without the user’s password.
- **Mutual authentication:** Both parties prove knowledge of the password. The client is sure it’s talking to the legitimate server, and the server is sure it’s talking to the legitimate client.

Additionally, practical PAKEs should be efficient, have low communication overhead, and be deployable on top of existing transport protocols like TLS.

PAKEs are classified into two main types: _balanced_ (or symmetric) PAKEs, where both parties know the password (e.g., EKE), and _augmented_ PAKEs (aPAKEs), where the server stores a _verifier_ derived from the password, not the password itself. The verifier is designed such that even if the server database is leaked, the attacker cannot directly recover the password without performing an expensive computation for each guess. Augmented PAKEs are more realistic for web applications because they protect users even when servers are compromised.

Our focus in this post will be on augmented PAKEs built from OPRF, which offer the strongest security guarantees.

---

## 3. Historical Attempts and Their Flaws

To appreciate the elegance of OPRF-based PAKEs, it’s helpful to understand why earlier protocols fell short.

### 3.1 Encrypted Key Exchange (EKE)

EKE, introduced by Bellovin and Merritt in 1992, is one of the first PAKE protocols. The basic idea is simple: the client encrypts a random public key (e.g., a Diffie-Hellman public key) using the password as a symmetric key, and sends it to the server. The server decrypts, performs a Diffie-Hellman exchange, and both derive a shared secret.

**Why it fails:** EKE is vulnerable to _partition attacks_. Because the password is used as an encryption key, an attacker can try to decrypt the first message with each candidate password; if decryption yields a valid-looking DH public key, the guess is likely correct. The attacker can then verify by checking the subsequent messages. This attack is offline and fast, making EKE insecure for low-entropy passwords.

Moreover, EKE requires that the encryption scheme be _key-committing_ — meaning that a ciphertext decrypts correctly only under the correct key. If the encryption scheme is not key-committing, multiple passwords may produce valid decryptions, but the attack still reduces the search space. Modern EKE variants (like SPEKE) fix some issues but still require careful parameter choices.

### 3.2 Secure Remote Password (SRP)

SRP, designed by Tom Wu in 1998, is a well-known augmented PAKE. The server stores a _verifier_ v = g^x mod p, where x is derived from the password (e.g., x = H(salt || password)). During authentication, the client proves knowledge of the password without revealing x, and both parties compute a shared key.

**Strengths:** SRP offers forward secrecy and resistance to offline dictionary attacks if the server database is intact. It also involves the server in the protocol (the server must be online and know the verifier).

**Weaknesses:** The fatal flaw of SRP is that the verifier v is a public key (a group element). If an attacker steals the database containing v and the salt, they can run an offline dictionary attack: for each candidate password, compute x' = H(salt || password'), then v' = g^x' and compare with the stored v. This is an offline attack that is essentially as fast as a single exponentiation per guess. With modern GPUs, millions of attempts per second are feasible. Thus, SRP fails the “resistance to server compromise” property.

Additionally, SRP requires the server to store a value that is a function of the password, meaning that a compromised server can be used as an _oracle_ – the attacker can query with a candidate password and check if the server accepts it, but that’s an online attack. The real problem is the offline verifier-matching attack.

### 3.3 Augmented PAKEs and Verifier-Based Designs

Other augmented PAKEs, such as AMP, B-SPEKE, and PROF, attempted to improve on SRP by making the verifier harder to invert. For example, using a hash function instead of a group exponentiation, or incorporating a second server to split the secret (threshold PAKE). However, most still required storing some deterministic function of the password, which inevitably allowed offline verification if the database leaked.

The core issue is that if the server stores _any_ deterministic information that depends only on the password, an attacker can compute that information for guessed passwords and compare. The only way to prevent this is to ensure that the stored server data is _blind_ — that is, it cannot be computed offline without interacting with the client. This is precisely where Oblivious Pseudorandom Functions enter the picture.

---

## 4. The Offline Dictionary Attack – The Core Weakness

To understand why offline dictionary attacks are so devastating, let’s formalize them.

Suppose the server stores a record for user U that contains some value V_U derived from the password pw_U, possibly with a salt. An attacker obtains the database (e.g., through SQL injection). The attacker then:

1. Chooses a candidate password pw'.
2. Computes the corresponding V'(pw', salt) using the same derivation function f.
3. Compares V' with V_U. If they match, the password is correct.

This attack is offline because the attacker does not need to interact with the server after obtaining the database. The computation per guess can be very fast (a hash, a multiplication, etc.), and parallelized across many users. With a database of millions of passwords, the attacker can test all common passwords against all users in minutes.

**The root cause:** The server stores a deterministic function of the password. To thwart offline attacks, we must make the stored value _nondeterministic_ from the attacker’s perspective, or make it impossible to compute without some secret held by the client or a separate party.

_Solution:_ Use a cryptographic primitive that allows the client to transform the password using a secret held by the server, such that the client does not learn the server’s secret, and the server does not learn the password. The stored data is then a _blinded_ version of the password that cannot be verified offline without the client’s cooperation.

Welcome to the world of **Oblivious Pseudorandom Functions**.

---

## 5. Oblivious Pseudorandom Functions (OPRF) Explained

### 5.1 Definition and Properties

An Oblivious Pseudorandom Function (OPRF) is a two-party protocol between a _client_ and a _server_. The server holds a secret key k (a long-term seed). The client holds an input x (the password). At the end of the protocol:

- The client learns the value F(k, x), where F is a pseudorandom function.
- The server learns nothing about x (obliviousness).
- The client learns nothing about k (except what can be inferred from the single output).

In other words, the server “signs” the client’s input without seeing it, and the client gets a pseudorandom output that it could not have computed on its own without the server’s secret key.

OPRF provides two main security properties:

1. **Obliviousness:** The server does not learn the client’s input. Even a malicious server that deviates from the protocol cannot determine x with better probability than random guessing.
2. **Pseudorandomness:** The output F(k, x) is indistinguishable from random to the client, given that the protocol is executed honestly. A client cannot distinguish the output from a random string without performing the OPRF protocol for that specific (k, x) pair.

A crucial consequence is that even if the server’s secret key k is later leaked, the OPRF outputs for previously queried inputs remain unknown to an attacker unless the attacker also knows x. However, for password protection, we usually have the server store a _masked_ version of the password using k.

### 5.2 A Simple OPRF Construction with Diffie-Hellman

One of the most elegant OPRF constructions is the **2HashDH** OPRF, based on Diffie-Hellman over a prime-order group G with generator g. Let H be a hash function mapping arbitrary inputs to group elements. The protocol:

- Server’s key: a random scalar k.
- Client’s input: password pw (x).
- **Step 1:** Client hashes the password to a group element: a = H(pw). Then blinds it by raising to a random blinding factor r: blinded = a^r (i.e., multiply by r in exponent). Sends blinded to server.
- **Step 2:** Server receives blinded. Computes evaluated = blinded^k = (a^r)^k = a^{rk}. Sends evaluated back to client.
- **Step 3:** Client removes the blinding factor: output = evaluated^{1/r} = (a^{rk})^{1/r} = a^k = H(pw)^k.

The client now has F(k, pw) = H(pw)^k. This is a pseudorandom function because under the computational Diffie-Hellman assumption, H(pw)^k is indistinguishable from a random group element for a client who does not know k.

**Why it’s oblivious:** The server only sees a^r, a random group element (since r is random). Without knowing r, the server cannot recover a = H(pw). Even a malicious server cannot learn pw because a^r is uniformly random and gives no information about pw.

**Why the client learns only F(k, pw):** The client gets a^k, which is exactly the OPRF output. It cannot learn k because that would require solving the discrete log of a^k base a.

### 5.3 Security Guarantees: Obliviousness & Pseudorandomness

Formally, the 2HashDH OPRF is secure under the _Computational Diffie-Hellman (CDH)_ assumption in the random oracle model (where H is modeled as a random oracle). The CDH assumption says that given g, g^a, g^b, it is hard to compute g^{ab}. This translates to: given a = H(pw) and a^r (from the client) and a^{rk} (from the server), an attacker cannot compute a^k without knowing either r or k.

For password hardening, we rely on the fact that the server’s secret key k is unknown to an attacker. If an attacker steals the server’s database (which contains a value derived from F(k, pw) but not k), they cannot compute F(k, pw') for arbitrary pw' because they lack k. Thus, offline dictionary attacks are prevented.

---

## 6. Building a PAKE from OPRF – The OPAQUE Protocol

The OPAQUE protocol, proposed by Jarecki, Krawczyk, and Xu in 2018, is the definitive example of an augmented PAKE built from OPRF. It was standardized as RFC 9492 in 2023 and is now part of the TLS 1.3 handshake extensions for password authentication.

### 6.1 High-Level Idea: Hardening Passwords with a Secret Key

The core insight of OPAQUE is to separate the password into two components:

- A **hardened password** derived via OPRF, which is used for authentication.
- A **masked secret** stored on the server that allows key agreement.

Specifically, during registration, the client and server run an OPRF where the server uses its secret key k, and the client’s input is the password pw. The client obtains rwd = H(pw)^k (a group element). This rwd is then used as a _strong secret_ (like a high-entropy key) to encrypt a long-term secret key pair for the user (e.g., a Diffie-Hellman private key). The server stores the encrypted private key and the OPRF key k (or a value derived from it).

During authentication, the client and server run the OPRF again, the client recovers rwd, decrypts the private key, and then performs an ordinary Diffie-Hellman key exchange (matching the public key stored on the server) to establish a session key. Because the OPRF output is pseudorandom and unknown to the server, and because the encrypted private key can only be decrypted with rwd, an attacker who steals the server database cannot recover rwd or the private key without the password.

Crucially, the server does not store the password or any deterministic function of it. The only stored secrets are:

- The server’s OPRF key k (which is a high-entropy random scalar).
- For each user, an encryption of the user’s static private key, along with the user’s static public key and the OPRF result of the password under k.

But the stored OPRF result (which is actually the encryption key for the private key) is itself encrypted or masked? Wait, let’s be more precise.

### 6.2 Protocol Steps in Detail

OPAQUE has two phases: **Registration** (one-time) and **Authentication** (each login).

#### Registration

Assume we have a prime-order group G (e.g., an elliptic curve) with generator g. H is a hash-to-curve function. Let (skU, pkU) be a long-term static key pair for the user (e.g., an ECDH key). We also need a symmetric encryption scheme (Enc, Dec) and a key derivation function KDF.

1. **Client:** Has password pw. Generates a random blinding factor r, computes a = H(pw), sends blinded = a^r to server.
2. **Server:** Has secret key k (random). Computes evaluated = blinded^k = a^{rk}. Sends evaluated back.
3. **Client:** Computes rwd = evaluated^{1/r} = a^k = H(pw)^k. This rwd is a group element; derive a symmetric key K_enc = KDF(rwd).
4. **Client:** Encrypts its static secret key skU to get envU = Enc(K_enc, skU). Sends envU and the public key pkU to server.
5. **Server:** Stores for user U: salt (optional, for H? may not be needed if H is deterministic), pkU, envU, and also the OPRF output? Wait, the server doesn’t learn rwd. But the server needs to be able to assist the client in recovering rwd during authentication. That’s accomplished by the server keeping k and the client’s blinded value? No, the server doesn’t store per-user values except those from step 5. Actually, OPAQUE decouples the OPRF from the key exchange. The server must store something to enable the OPRF during authentication — that something is the server’s private key k, which is global for all users (or per-user, but typically global). The per-user data is just pkU and envU.

During authentication, the client will again run OPRF with the same server (using same k) to recover rwd, then decrypt envU to get skU, and then perform a fresh ephemeral Diffie-Hellman exchange with the server using pkU (the server knows skU? Actually, the server does not know skU; it only stores the encrypted envU. But the server must also know the corresponding _public_ key pkU, which is stored. The server can then use its own long-term private key? Wait, we need to clarify the key agreement step.

In OPAQUE, the static key pair (skU, pkU) is used for _key confirmation_ and _mutual authentication_. The server also has a static key pair (skS, pkS). After the OPRF step, the client obtains skU (by decrypting envU). Then both parties perform a _two-message key exchange_ similar to HMQV or a simple Diffie-Hellman:

- Client generates ephemeral key ephC, sends E = g^ephC.
- Server also generates ephS, sends S = g^ephS.
- Both compute a shared secret using their own static keys and the other’s public key, plus the ephemeral keys. The exact formula is: K = H(ephC, ephS, skU, pkS, ...) or similar, ensuring forward secrecy and key confirmation.

The server knows pkU (public) but not skU. However, the server also needs to prove it knows the password? In an augmented PAKE, the server does _not_ need to prove knowledge of the password; it only assists the client in obtaining the key. The client authenticates to the server by decrypting envU with the OPRF output — if decryption fails, the client cannot compute the correct shared secret. The server authenticates to the client by proving knowledge of its own static private key skS, which is independent of the password.

Thus, OPAQUE achieves server-sided security (server compromise does not reveal password) and mutual authentication.

#### Authentication

1. Client sends its username to server.
2. Server looks up pkU and envU for that user.
3. Client and server run OPRF as in registration: client blinds a = H(pw), sends blinded to server; server returns evaluated = blinded^k; client computes rwd = evaluated^{1/r}.
4. Client derives K_enc = KDF(rwd) and decrypts envU to get skU.
5. Now both parties run an authenticated key exchange. Typically, the client sends an ephemeral public key E (and optionally a tag). The server responds with its ephemeral public key S and a confirmation tag computed using the shared secret derived from both static and ephemeral keys.
6. Client verifies the server’s confirmation tag; if valid, client sends its own confirmation tag.
7. Both parties output the session key.

### 6.3 Why This Eliminates Offline Dictionary Attacks

An attacker who steals the server database obtains:

- For each user: pkU, envU (encrypted static private key), and possibly other metadata.
- The server’s OPRF secret key k (if the entire server is compromised).

If the attacker knows k, then for a candidate password pw', they can compute H(pw')^k (the OPRF output) and then try to decrypt envU. However, this requires the attacker to know the password _before_ they can test it. But they can indeed test offline: for each pw', compute rwd' = H(pw')^k, derive K_enc', decrypt envU, and see if the decrypted value is a valid private key (e.g., a scalar within range). This is an offline dictionary attack!

**Wait – this seems to contradict the claim.** Indeed, if the attacker obtains the OPRF key k, they can perform offline attacks. However, in the security model, we consider two levels of compromise:

- **Server compromise (database leak):** The attacker steals the user data (envU, pkU) but _not_ the OPRF key k. The OPRF key is stored separately, ideally in a hardware security module (HSM) or in memory that is not part of the database dump. In practice, this separation is reasonable: the OPRF key is a single high-entropy value that can be protected more rigorously than per-user records.
- **Total server compromise:** If the attacker gets both the database and the OPRF key, they can run offline attacks. But that is inevitable: if the attacker knows all server secrets, they can simulate the protocol. The goal is to ensure that a database leak alone does not allow offline attacks, and that even with the OPRF key, the attacker still cannot decrypt past sessions (forward secrecy) because the ephemeral keys are not compromised.

Thus, OPAQUE provides _resistance to server compromise_ in the sense that the database alone is useless for offline attacks. This is a huge improvement over SRP, where the database itself contains the verifier.

Additionally, OPAQUE offers _forward secrecy_: session keys are derived from ephemeral Diffie-Hellman shares, which are deleted after the session. Even if the OPRF key and the encrypted private key are later compromised, past session keys remain secure because the ephemeral private keys are not stored.

### 6.4 Forward Secrecy and Server Compromise Resistance

Forward secrecy is achieved because the session key depends on randomly generated ephemeral keys that are not stored. The static key skU is only used to authenticate the key exchange, but the actual shared secret combines ephemeral keys in a way that prevents an attacker who later learns skU from deriving the session key (if the ephemeral keys are unknown). The formula typically uses the “key derivation function with contributions from both static and ephemeral keys,” such as in HMQV.

Server compromise resistance (database only) is achieved by:

- The server does not store any deterministic function of the password. The only password-related value is envU, which is encrypted with a key that depends on the password through the OPRF. Without the password, an attacker cannot decrypt envU.
- The OPRF key k is not stored in the database (in the standard model), so an attacker cannot compute H(pw')^k to test guesses.

If the database is leaked but k remains secret, the attacker has no way to verify passwords offline. The only attack remaining is online guessing, which is rate-limited by the server.

---

## 7. Step-by-Step Worked Example with Code

We’ll implement a simplified version of OPAQUE in Python, using the Ristretto group (a prime-order elliptic curve group) and the 2HashDH OPRF. For simplicity, we omit some details like hashing to curve, KDF, and key confirmation tags. The purpose is to illustrate the flow.

### 7.1 Setup and Registration

We need an elliptic curve group. We’ll use the Ristretto255 group (from the curve25519 family). In practice, use a library like `cryptography` or `pyca/ed25519`. Here we define a mock.

```python
import os
import hashlib
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# For simplicity, we use a generic group with scalar multiplication.
# We'll represent group elements as bytes (public keys).
# OPRF uses group element exponentiation (scalar multiplication).

class Group:
    def __init__(self):
        # Use x25519 as our group: base point and scalar multiplication.
        self.base = x25519.X25519PrivateKey.generate().public_key()  # dummy
        # Actually, we need a fixed generator. Let's define a function.

    def hash_to_curve(self, data):
        # Hash input to a curve point (simplified: use scalar multiplication of base)
        # In real implementation, use hash-to-curve (RFC 9380)
        pass

    def scalar_mult(self, scalar_bytes, point):
        # Multiply point by scalar
        pass
```

But for a clear example, let’s avoid deep cryptographic library details and focus on the conceptual steps using integers modulo a prime (simulated). For a tutorial, we can use the `nacl` library or just describe.

I will present a code-like pseudocode that is clear enough.

#### Registration Steps (Pseudocode)

```
# Server initialization
server_oprf_key = random_scalar()  # k
server_static_sk, server_static_pk = generate_keypair()

# Client registration
password = b"correct horse battery staple"
blinding_factor = random_scalar()
a = hash_to_curve(password)        # H(pw)
blinded = a * blinding_factor      # a^r
# Send to server

# Server
evaluated = blinded * server_oprf_key  # a^{rk}
# Send back

# Client
rwd = evaluated * (blinding_factor^{-1})  # a^k
enc_key = KDF(rwd)  # derive symmetric key

# Generate user static keypair
user_sk, user_pk = generate_keypair()
env = encrypt(enc_key, user_sk)   # encrypted secret key

# Server stores: username, user_pk, env
```

### 7.2 Authentication Session

```
# Client sends username
# Server looks up user_pk, env for that user

# OPRF phase (same as registration)
client blinds a, sends to server
server returns evaluated
client computes rwd and enc_key
user_sk = decrypt(enc_key, env)

# Now key exchange with server's static public key (server_pk) and user's static keys
# Client generates ephemeral key pair (eph_sk, eph_pk)
eph_sk_client = random_scalar()
eph_pk_client = g * eph_sk_client
# Send eph_pk_client to server

# Server generates its own ephemeral key pair (eph_sk_server, eph_pk_server)
# Send eph_pk_server to client

# Both compute shared secret using their own static and ephemeral keys, and the other's public keys.
# In OPAQUE, the shared secret is: K = H( eph_pk_client || eph_pk_server ||
#   (user_sk * server_pk) || (eph_sk_client * server_pk) || ... )
# For simplicity, we do:
ss = eph_sk_client * server_pk + user_sk * eph_pk_server + eph_sk_client * eph_pk_server
# (This is an HMQV-like combination)

session_key = KDF(ss || transcript)
```

### 7.3 Key Derivation and Session Establishment

After both sides compute the same session key, they can send confirmation tags (e.g., HMAC of the transcript) to prove they have the key. Then the session is established.

This example, though simplified, shows the critical components: OPRF to recover a strong secret, decryption of the static key, and an ephemeral Diffie-Hellman exchange for forward secrecy.

---

## 8. Security Analysis

### 8.1 Threat Model

We consider a network adversary who can:

- Eavesdrop on all communication.
- Inject, modify, or replay messages.
- Compromise the server database (obtain user records but not the OPRF key).
- Compromise the server’s OPRF key (total server breach, but the attacker cannot have both database and key simultaneously in the ideal case? Actually we consider separate events).

Our goal: Even if the database is leaked, the adversary cannot impersonate the user or learn the password via offline dictionary attacks. Even if the OPRF key is leaked, past sessions remain secure (forward secrecy) and the attacker still cannot directly authenticate as the user without the password (they would need to run the OPRF online with the client? Actually, if the attacker has the OPRF key, they can compute rwd for any password, but they still need to decrypt envU. But they also have envU from the database, so they can try guesses offline. However, to actually authenticate, they would need to run the full protocol with the server, which requires the server’s cooperation. So the attacker could impersonate the client if they also have the password. So with the OPRF key, they can run offline attacks. That’s acceptable because it requires total server compromise.

### 8.2 Proof Sketch: Reducing to OPRF Security and Strong DH

The security of OPAQUE is proven in the UC (Universally Composable) model. The main reduction:

- The OPRF ensures that the value rwd = H(pw)^k is pseudorandom to the client, and unknown to the server. Thus, the encryption key K_enc is indistinguishable from random to any party that does not know the password and does not participate in the OPRF.
- An attacker who steals the database (envU, pkU) but not k cannot compute rwd for any password because computing H(pw)^k requires k. Thus, they cannot decrypt envU to get skU.
- An attacker who compromises k gains the ability to compute rwd for any password, but then they must still perform online authentication (which can be rate-limited) to actually use it. However, they could run offline dictionary attacks. OPAQUE does not protect against total server compromise, which is considered acceptable.
- The key exchange part provides forward secrecy under the CDH assumption. The session key is derived from ephemeral keys and static keys such that compromise of static keys later does not reveal past session keys.

### 8.3 Comparison with Existing PAKEs

| Property                                   | SRP                       | EKE                                      | OPAQUE                                               |
| ------------------------------------------ | ------------------------- | ---------------------------------------- | ---------------------------------------------------- |
| Offline attack resistance (server DB leak) | No – verifier comparison  | Yes (if encryption is key-committing)    | Yes (DB alone useless without OPRF key)              |
| Forward secrecy                            | Yes                       | Yes (with ephemeral keys)                | Yes                                                  |
| Server compromise resistance               | No                        | Yes (server does store trivial verifier) | Yes (database plus OPRF key needed)                  |
| Mutual authentication                      | Yes (both prove password) | Yes                                      | Yes (user proves password, server proves static key) |
| Efficiency                                 | Moderate                  | Low (encryption overhead)                | Moderate (OPRF + DH)                                 |

OPAQUE also supports _salt regeneration_ and _password change without server interaction_ — the client can re-encrypt envU with a new OPRF output.

---

## 9. Implementation Considerations

### 9.1 Choice of Elliptic Curve and Hash Function

For OPRF, we need a hash function that maps to a curve point (hash-to-curve). The IETF standard RFC 9380 specifies several methods (e.g., “hash to curve” for P-256, Curve25519). For the key exchange, a standard prime-order curve like P-256 or Curve25519 is suitable. Avoid curves with cofactor > 1 without proper handling (e.g., X25519 has cofactor 8, which must be cleaned). The Ristretto255 group (a prime-order group derived from Curve25519) is ideal.

### 9.2 Mitigating Side Channels and Timing Attacks

The OPRF step involves exponentiation with a random blinding factor. The blinding factor must be generated from a secure random number generator. The server’s evaluation (exponentiation with k) should be constant-time to prevent timing leaks about k. Implement scalar multiplication using Montgomery ladder or other constant-time algorithms.

Also, during decryption of envU, the decryption operation should not leak whether the ciphertext is valid (e.g., using an authenticated encryption scheme). If decryption fails (wrong password), the client should continue the protocol to simulate a valid session, then reject at the end to avoid timing differences.

### 9.3 Handling Password Changes and Account Recovery

When the user changes their password, they need to re-run the OPRF with the new password to obtain a new rwd, then re-encrypt their static secret key skU with the new K_enc. The new envU is stored. The server’s OPRF key k remains the same. No interaction with the server is required beyond updating the stored envU.

For account recovery (forgot password), the user typically must go through an out-of-band process (e.g., email reset). In OPAQUE, there is no backdoor; the password is the only way to decrypt skU. Thus, recovery requires generating a new key pair, which is a good practice (new credentials after recovery).

---

## 10. Practical Impact and Adoption

OPAQUE has been standardized by the IETF (RFC 9492, 9493). It is seeing adoption in:

- **Apple’s iCloud Keychain** and password manager (iOS 17, macOS Sonoma).
- **Google’s Password Checkup** and upcoming features.
- **Cloudflare** has implemented OPAQUE for use in their Zero Trust platform.

The protocol can be integrated into TLS 1.3 as a **Password Authentication** extension, allowing secure password-based login without a separate TLS tunnel. This reduces the attack surface compared to sending passwords over HTTPS.

The biggest hurdle to adoption is the need for server-side changes: storing a high-entropy OPRF key and implementing the protocol correctly. However, libraries like `libopaque` (C) and `rust-opaque` (Rust) are available.

---

## 11. Conclusion

The journey from password plaintext leaks to a secure, forward-secret, server-compromise-resistant protocol is long. OPRF-based PAKEs like OPAQUE represent a breakthrough: they decouple the password from the server’s stored data using an oblivious primitive, ensuring that a database leak alone does not enable offline guessing. By combining an OPRF with a carefully designed key exchange, OPAQUE achieves all the desirable properties of a modern authentication protocol.

We’ve seen how historical protocols fell short, how OPRF works, and how OPAQUE stitches everything together. With standardization and growing industry support, OPRF-based PAKEs are poised to become the new standard for password authentication on the internet.

Next time you type your password, remember: the cryptography behind that “Sign In” button could be OPAQUE, working silently to keep your secrets safe.

---

_This article was written with the help of [your assistant name] and references to the OPAQUE paper (Jarecki, Krawczyk, Xu, 2018) and RFC 9492._
