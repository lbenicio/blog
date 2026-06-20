---
title: "Countdown to Quantum: Migrating an Enterprise to Post-Quantum Cryptography"
date: 2024-01-29T16:40:00Z
description: "Practical lessons from a multi-year effort to adopt quantum-safe cryptography without breaking production."
tags: ["security", "cryptography", "post-quantum", "infrastructure", "compliance"]
categories: ["Engineering"]
draft: false
cover: "/static/assets/images/blog/quantum-safe-cryptography-migration.png"
coverAlt: "Classical and quantum keys intertwined"
---

When the first credible quantum threat report reached our CISO's desk, the reaction was cautious curiosity. Quantum computers capable of breaking RSA-2048 remain years away, but data harvested today could be decrypted decades later. We handle sensitive customer contracts, healthcare records, and government workloads. Waiting for the quantum threat to manifest felt irresponsible. So we embarked on a multi-year migration to post-quantum cryptography (PQC). This post documents the journey—strategy, tooling, experiments, and the human moments that kept the program afloat.

## 1. Defining the threat

Quantum threats revolve around **harvest-now-decrypt-later**: adversaries record encrypted traffic today, expecting to decrypt it when Shor-capable machines arrive. NIST's PQC standardization informed our timeline, but uncertainty remained. We built scenarios: conservative (quantum risk > 15 years), moderate (7–10 years), aggressive (3–5 years). We assumed adversaries already harvested our traffic, pushing us toward proactive mitigation.

## 2. Principles and scope

We defined principles:

- **Comprehensive coverage**: protect data in transit, at rest, and in backups.
- **Hybrid cryptography first**: combine classical and PQC algorithms to hedge risk.
- **Backward compatibility**: avoid breaking clients or partner integrations.
- **Measurable progress**: track coverage via dashboards.
- **Community alignment**: follow NIST, ETSI, and open-source efforts to avoid proprietary cul-de-sacs.

Scope included TLS, VPNs, storage encryption, code signing, messaging, and long-term archives.

## 3. Inventorying cryptography

We audited our cryptography usage. A custom scanner parsed code repositories, config files, and binaries to identify algorithms, key lengths, libraries, and custom implementations. We cataloged certificates, key stores, HSM policies, and 3rd-party dependencies. The inventory fed a dependency graph mapping services to cryptographic components. It surfaced surprises: legacy internal APIs still used SHA-1 for signatures, IoT devices running 10-year-old firmware, archives encoded with proprietary ciphers.

## 4. Selecting algorithms

When NIST announced finalists (CRYSTALS-Kyber for key encapsulation, CRYSTALS-Dilithium/Falcon for signatures), we aligned our roadmap. We chose:

- **Key exchange**: hybrid ECDHE + Kyber-768 for TLS, pure Kyber for internal services after testing.
- **Signatures**: hybrid ECDSA + Dilithium for certificates, with Falcon for size-sensitive contexts.
- **Hashing**: continued use of SHA-2/SHA-3.

We opted for hybrid modes initially to maintain compatibility and mitigate unexpected PQC vulnerabilities.

## 5. Updating PKI

Our public key infrastructure required overhaul. HSM vendors rolled out firmware supporting PQC algorithms. We upgraded appliances, enabling dual key pairs per certificate (ECDSA and Dilithium). Certificate authorities updated issuance workflows to embed hybrid public keys. We built tooling to generate certificate signing requests (CSRs) with PQC extensions, and we coordinated with external CAs to ensure acceptance.

Certificate size growth posed challenges: Dilithium signatures are larger, impacting TLS handshake performance and MTU. We tuned handshake buffering and enabled TLS 1.3 0-RTT for supported clients to offset overhead.

## 6. TLS migration

We piloted PQC-enabled TLS in internal environments first. Using OpenSSL forked with PQC support, we configured servers to advertise hybrid key shares via TLS 1.3 extensions. Clients upgraded gradually—mobile apps, browsers, microservices. We measured handshake latency (increased ~8 ms initially), CPU cost (up 12%), and compatibility (legacy clients ignored new key shares gracefully).

We set up dashboards tracking PQC negotiation rates, fallback to classical, and error codes. Rollout proceeded in waves, starting with low-risk services. We used feature flags to toggle PQC support dynamically.

## 7. VPN and network security

Site-to-site VPNs relied on IPSec with IKEv2. Vendors released PQC-hybrid proposals (e.g., IKEv2 with post-quantum key exchange). We lab-tested firmware, verifying interoperability. Production rollout required coordination with partner networks. We negotiated maintenance windows, validated failover, and documented performance impact. Remote access VPN clients received updates with auto-negotiation—older clients defaulted to classical algorithms but triggered reminders to upgrade.

## 8. Storage and backups

Encryption at rest used AES-256 with RSA-protected keys. PQC affects key wrapping and distribution, not symmetric encryption. We replaced RSA key wrapping with hybrid approaches (RSA + Kyber). HSMs now generate PQC key pairs, and wrapping keys store in secure vaults. Backup archives (especially long-term cold storage) now encrypt with keys protected by PQC algorithms. We audited retention policies to ensure old archives re-encrypt before they reach quantum risk windows.

## 9. Code signing and software updates

Our software update chain relies on signing binaries. We migrated to hybrid signatures: packages carry both Ed25519 and Dilithium signatures. Build systems updated to compute dual signatures, and clients verify both. We monitored download sizes (marginally larger) and verification times (up modestly). For embedded systems with constrained storage, we experimented with Falcon (smaller signatures) and trimmed metadata to compensate.

## 10. Messaging and identity

Internal messaging protocols (gRPC, Kafka) use TLS; PQC adoption flowed naturally. For SSO and identity tokens (JWTs), we adopted hybrid signatures for tokens, with verification libraries updated accordingly. We ensured third-party identity providers could handle PQC or at least hybrid tokens. We also updated FIDO2/WebAuthn devices to aware of PQC roadmaps, though standards remain in flux.

## 11. Performance engineering

PQC algorithms impose heavier CPU usage and larger messages. We optimized:

- **Handshake batching**: establishing connections in batches to amortize costs.
- **Session resumption**: aggressive use of TLS 1.3 resumption tickets.
- **Hardware acceleration**: evaluated PQC-ready acceleration (AVX2, ARM Neon optimizations).
- **Caching**: kept TLS contexts alive longer where safe.

We measured impact across data centers. Overall overhead stayed below 10% after optimization.

## 12. Testing and validation

We built automated test suites covering:

- Protocol interoperability between PQC-enabled and legacy clients/servers.
- Fallback to classical algorithms when PQC components absent.
- Resilience to downgrade attacks (we enforce TLS 1.3 with anti-downgrade checks).
- Load testing with simulated quantum-resistant handshake flood.

We also engaged third-party assessors to penetration-test PQC deployments and verify compliance with emerging standards.

## 13. Governance and reporting

We treated PQC migration as a program with executive sponsorship. A cross-functional task force met biweekly, tracking metrics: percentage of services PQC-enabled, certificates issued, partner readiness, performance baselines. We published internal scorecards and shared updates with board-level committees. Transparency kept momentum and helped secure budget.

## 14. Supplier and customer coordination

Supply chain readiness mattered. We surveyed vendors—cloud providers, SaaS partners, hardware vendors—about PQC timelines. We prioritized partnerships with vendors committing to PQC support. For customers, especially government agencies, we provided roadmaps and integration guides. Some required contractual updates reflecting PQC posture.

## 15. Incident simulation

We ran tabletop exercises simulating a quantum "break" scenario. We practiced revoking classical certificates, deploying PQC-only configurations, and communicating with customers. Drills exposed gaps—some monitoring tools failed to recognize new certificate formats. We fixed them and iterated.

## 16. Education and culture

Engineers underwent PQC training covering cryptography basics, algorithm choices, and migration playbooks. We hosted brown-bag sessions with cryptographers explaining risk assessments. Documentation offered guidance on using PQC libraries, handling larger keys, and debugging handshake issues. We recognized teams contributing major PQC milestones, reinforcing the program's importance.

## 17. Tooling

We contributed to open-source projects (e.g., liboqs) to fix bugs encountered during rollout. We built internal libraries abstracting algorithm selection, allowing services to request "default hybrid key" without dealing with details. We added linting to detect legacy algorithms in code reviews. Monitoring tools expose PQC metrics, enabling rapid troubleshooting.

## 18. Results

By end of 2023, 68% of internal services negotiated hybrid PQC handshakes. By mid-2024, we reached 92%. All external-facing APIs support hybrid TLS; clients negotiate PQC if they advertise support. Code signing uses hybrid signatures; package managers enforce verification. Archived data older than five years has been re-encrypted with PQC-protected keys. Performance overhead stabilized at 6% CPU, 40% handshake size increase, offset by resumption.

## 19. Lessons learned

- **Start with inventory**: knowing where cryptography lives is half the battle.
- **Hybrid buys time**: we hedge against PQC implementation bugs while preparing for pure PQC future.
- **Performance matters**: invest early in optimization to maintain user experience.
- **Community collaboration**: PQC is a collective effort; sharing findings accelerates progress.
- **Expect surprises**: obscure services and legacy devices require creative solutions.

## 20. Looking forward

We're planning the transition from hybrid to pure PQC once standards stabilize and clients catch up. We monitor NIST drafts, ETSI profiles, and browser roadmaps. We invest in post-quantum HSMs and exploring cryptographic agility frameworks allowing hot-switching of algorithms. We also examine quantum-resistant authentication, including lattice-based and hash-based signatures for identities.

## 21. Conclusion

Quantum threats remain hypothetical, but preparation is concrete. Migrating to post-quantum cryptography demanded patience, cross-disciplinary collaboration, and willingness to rethink assumptions. Today, our data enjoys longer-term protection, our partners trust our roadmap, and our engineers trek confidently toward a quantum future. When the first quantum-capable adversary emerges, we'll be ready—not because we predicted the exact date, but because we chose curiosity over complacency.
