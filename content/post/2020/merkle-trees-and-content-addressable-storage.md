---
title: "Merkle Trees and Content‑Addressable Storage"
date: 2020-08-17T10:00:00Z
description: "From Git to distributed object stores: how Merkle DAGs enable integrity, deduplication, and efficient sync."
tags: ["storage", "merkle", "cas", "git", "consistency"]
categories: ["Engineering"]
draft: false
cover: "/static/assets/images/blog/merkle-trees-and-content-addressable-storage.png"
coverAlt: "Merkle DAG diagram with hashes cascading from leaves to root"
---

Hash the content, not the location—that’s the core of content‑addressable storage (CAS). Combine it with Merkle trees (or DAGs) and you get efficient verification, deduplication, and synchronization. This post connects the dots from Git to large‑scale object stores.

## Why Merkle?

Parent hashes commit to child hashes; any change percolates up. You can verify integrity by checking a root hash and a short proof path.

## Uses

- Git commits and trees; shallow clones via missing subtrees.
- Package managers with integrity checks.
- Deduplicated backups with chunking and rolling hashes.
- Object stores that replicate by exchanging missing subgraphs.

## Practical notes

- Hash choice (SHA‑256 vs BLAKE3) affects speed and hardware support.
- Chunking strategy controls dedupe granularity; rolling fingerprints (Rabin) find natural boundaries.
- Store metadata alongside blobs to avoid rehashing for trivial changes.

## 1) From trees to DAGs: modeling versions that share content

Classic Merkle trees have a fixed arity and two kinds of nodes: leaves containing hashes of fixed‑size blocks, and internal nodes containing hashes of their children. In real systems, multiple versions of content share substructure: two versions of a directory share most files, two backups share most chunks, two container images share many layers. That sharing naturally forms a directed acyclic graph (DAG) where a node can be referenced from multiple parents. The root is still a commitment to the whole, but now many roots can reference common subgraphs without duplication.

Design questions you must answer:

- Node encoding: what fields are hashed? Most systems include the children’s content hashes and sizes in the hash input, plus a domain separator (to avoid cross‑type collisions). Metadata that frequently changes but shouldn’t invalidate content (timestamps, ACLs) belongs outside the hash or in a separate metadata stream.
- Fan‑out: higher branching reduces depth and lookup hops but increases internal node size and write amplification. A 1,024‑way fan‑out keeps depth tiny even for billions of chunks; a 32‑way fan‑out improves cache locality for small manifests.
- Ordering: deterministic ordering of children (by offset, name, or hash) is critical so that two builders produce the same root for the same logical content. Non‑determinism leaks into roots and kills dedupe.

## 2) Chunking strategies: the dedupe dial

Deduplication comes from reusing identical chunk hashes. How you choose chunk boundaries decides how much reuse you’ll see:

- Fixed‑size: choose a power‑of‑two target (64 KiB, 1 MiB). Cheap to compute; naturally aligned to I/O. But an insertion near the start shifts all subsequent boundaries, turning shared content into non‑matches.
- Content‑defined chunking (CDC): compute a rolling hash over a sliding window; declare a boundary when the hash satisfies a pattern (e.g., the k lowest bits equal a mask). This finds “natural” boundaries that remain stable under local edits and appends. CDC dramatically improves dedupe for log files, VM images, and archives at the cost of CPU and some variability in chunk sizes.

Practical CDC recipe:

- Pick an average chunk size (e.g., 64 KiB); set min and max (e.g., 8 KiB to 512 KiB) to cap extremes.
- Use a fast rolling hash (Gear or Rabin); implement in a streaming fashion to avoid buffering entire files.
- After detecting a boundary, compute a cryptographic hash (SHA‑256/BLAKE3) of the chunk to use as the content address. The rolling hash itself is not a secure identifier.

Chunking interacts with compression and encryption. Per‑chunk compression (e.g., zstd) increases dedupe if compressed data is content‑defined (compress after chunking). Encrypting per chunk preserves dedupe provided the key and IV derivation are deterministic per chunk (e.g., SIV‑like modes with the content hash as nonce); naive randomized encryption defeats dedupe by design.

## 3) Indexes and packs: making small objects economical

CAS creates lots of tiny objects. Storing them one‑by‑one in an object store (or filesystem) thrashes metadata and system calls. The fix is packing:

- Pack many small chunks into larger pack files (tens of MB). Maintain an index from chunk hash → pack file + offset + length.
- Lay out chunks in packs to maximize locality for common access patterns (e.g., pack chunks that belong to the same file or layer).
- Periodically repack: rewrite packs to defragment, drop unreachable chunks, and rebuild optimal orderings.

Indexes must be memory‑efficient and fast. A two‑tier scheme is common: a small in‑memory hash table of top bits (or a minimal perfect hash) points into an on‑disk index of sorted entries. Bloom filters or quotient filters can quickly determine “definitely not present” without hitting disk.

## 4) Synchronization by exchanging Merkle proofs

Two replicas that both store DAGs can synchronize by exchanging roots. If the roots match, they’re consistent. If not, descend:

1. Request the list of child hashes and sizes for the root.
2. For each child, if you already have that hash, skip; otherwise, request that subgraph.
3. Repeat until you’ve fetched all missing nodes and chunks.

This protocol is naturally incremental and dedupe‑aware. For bandwidth‑constrained links, you can exchange summaries first (Bloom filters of chunk IDs, or hash‑prefix ranges) to avoid requesting obviously present chunks. For rate fairness, cap the number of outstanding subgraph requests per peer and prioritize shallow nodes first to reduce the breadth of the search quickly.

## 5) Security and threat modeling

Merkle proofs provide integrity, but you need to think about adversaries:

- Collision resistance: choose a modern hash (SHA‑256 or BLAKE3). Assume the network is hostile; verify hashes upon receipt before admitting content into the repository.
- Second‑preimage resistance: for content validation, an attacker shouldn’t be able to craft a different chunk with the same hash. Again, modern hashes suffice today.
- Domain separation: don’t reuse the same hash prefix space for different object types; include a type tag (e.g., “chunk\0”, “node\0”, “manifest\0”) in the byte stream you hash.
- Untrusted manifests: when clients supply manifests, verify that all referenced chunks exist and are authorized. Enforce quota per tenant to prevent building enormous unreferenced DAGs.
- Authenticated encryption: if you store encrypted chunks, use AEAD with the content hash as associated data so that decryption implicitly validates identity.

## 6) Garbage collection that won’t eat your lunch

GC is deceptively hard at scale. The minimalist algorithm is mark‑and‑sweep:

1. Enumerate all live roots (refs, tags, manifests pinned by policy).
2. Traverse reachable nodes and chunks; mark them in a reachability bitmap or a counting Bloom filter.
3. After a grace period, delete unmarked chunks and nodes.

Pitfalls and mitigations:

- Racing references: a client may publish a new root that references chunks you are about to sweep. Maintain a write‑ahead log of reference updates and replay it before sweeping; or hold new writes in a quarantine area until the next mark phase completes.
- Multi‑tenant leaks: global dedupe means one tenant can keep another tenant’s chunks alive by referencing them. If that’s a policy violation, namespace your hashes (e.g., tenantID || hash) or encrypt with per‑tenant keys so cross‑tenant references don’t work.
- Massive repos: a full traversal won’t fit in a maintenance window. Use incremental GC: partition the DAG, track generation numbers, and traverse hot generations more frequently.

## 7) Case studies: Git, OCI images, and backup tools

- Git: blobs (file contents) and trees (directories) are content‑addressed by SHA‑1 historically (moving to SHA‑256). Pack files combine deltas and raw objects; repacks improve locality. Shallow and partial clones exchange just the reachable DAG. Git proves that a Merkle repository can scale to billions of objects on a laptop if packs and indexes are well‑engineered.
- OCI/Docker: layers are tarballs addressed by digest; manifests point to layer digests. Registries dedupe layers across images. Content distribution is Merkle‑like but manifests are small enough to fetch eagerly; layers stream as large blobs with range requests.
- Backups (restic, Borg): CDC chunking over filesystems, per‑chunk encryption, and repository pruning via reachability. Snapshot diffs are instant because they’re just alternate roots. Restore performance depends on pack locality and prefetch strategies.

## 8) Performance engineering

Hot loops in a CAS:

- Hashing: dominate CPU. Use SIMD‑accelerated implementations; parallelize across cores; adopt BLAKE3 for impressive multi‑threaded throughput.
- Index lookups: memory bound. Keep a compact, cache‑friendly top‑level index that quickly eliminates misses; batch lookups to hide latency.
- Small reads: prefetch and coalesce adjacent chunks; place sibling chunks together in packs to reduce seeks.
- Write amplification: avoid rewriting entire packs when adding a few chunks; use append‑only logs with periodic compaction.

Measure the right metrics: chunk cache hit rate, average and tail latency for chunk reads, bytes of metadata per byte of content, and GC debt (bytes unreachable but not yet reclaimed). When tails are bad, profile for lock contention in indexes, slow crypto paths, and pathological pack layouts.

## 9) Operational playbook

- Namespace strategy: decide whether hashes are global or per tenant. If global, design access controls and audit trails to prevent cross‑tenant data inference.
- Quotas and budgets: protect the system from accidental growth by capping chunks per repo, refs per tenant, and max DAG depth.
- Repair tooling: provide verify and fsck‑like commands that scan for missing or corrupt chunks and rebuild indexes from packs.
- Disaster recovery: replicate packs and indexes; test restoring from only packs plus a recent index snapshot.
- Observability: trace sync sessions, record how many nodes were reused vs transferred, and expose GC progress as a first‑class metric.

## 10) A cautious migration plan

If you’re adding CAS to an existing store:

1. Start by mirroring writes: keep writing to the old layout while building CAS chunks and manifests in parallel.
2. Verify read parity: for a sample, reconstruct objects from CAS and compare byte‑for‑byte against the legacy path.
3. Flip reads: move a small percentage of traffic to read from CAS; compare latency and error profiles.
4. Flip writes: once confident, write only to CAS; continue syncing to legacy during a decommissioning window.
5. Decommission: retire legacy; keep conversion tools for archival access.

## 11) Troubleshooting: symptoms and likely causes

- High p99 read latency but good p50: packs are too fragmented; rebuild with locality.
- GC never catches up: roots proliferate; enforce policies on retention and ref churn; switch to incremental GC.
- Poor dedupe ratios: chunking parameters mismatch the workload; enable CDC with a larger average size; compress before packing if many chunks are tiny.
- Registry syncs saturate WAN: add hash‑prefix range summaries; prioritize shallow nodes first; rate‑limit per peer.

## 12) A short glossary

- Chunk: a unit of content with a cryptographic hash identity.
- Node: an internal DAG record that lists children and sizes; its hash commits to the subgraph.
- Manifest/root: an entry point that defines a version (e.g., a snapshot, image, or directory tree).
- Pack: a file that stores many chunks to amortize overhead.
- Proof: the minimal set of sibling hashes needed to verify inclusion of a chunk in a root.

Content‑addressable storage with Merkle DAGs is deceptively simple and astonishingly effective. It lets you reason about data by identity, share substructure across versions, and synchronize with mathematical confidence. With careful design around chunking, packs, GC, and security, it scales from laptops to multi‑region object stores—while staying elegant enough to explain on a whiteboard.

## 13) Tooling and schema evolution

Over time, manifests and node schemas evolve. Plan versioning:

- Add a version field to node/manifests; use domain‑separated hashes per version to prevent cross‑interpretation.
- Provide migration tools that rewrite older graphs into new formats lazily during repack.
- Build debuggers: print a DAG, validate reachability, fetch proofs, and diff two roots by traversing only changed subgraphs.
- For public APIs, publish a formal spec so external clients can interoperate safely.
