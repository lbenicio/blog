---
title: "Object Storage: RADOS/Ceph Architecture, the CRUSH Placement Algorithm, S3 API Semantics, and Erasure Coding at Scale"
description: "A deep exploration of object storage — how Ceph's RADOS and CRUSH algorithm enable scalable, self-managing storage clusters, the S3 API's influence on cloud storage, and how erasure coding reduces storage overhead."
date: "2021-06-21"
author: "Leonardo Benicio"
tags: ["object-storage", "ceph", "rados", "crush", "s3", "erasure-coding", "distributed-systems"]
categories: ["systems", "distributed-storage"]
draft: false
cover: "/static/assets/images/blog/object-storage-rados-s3-crush-algorithm.png"
coverAlt: "A stylized diagram showing the Ceph CRUSH algorithm mapping objects to placement groups to OSDs across a hierarchical cluster map"
---

In 2006, Sage Weil published his PhD dissertation describing Ceph, a distributed object storage system that would become one of the most significant open-source storage projects of the next decade. Ceph's core innovation was RADOS (Reliable Autonomic Distributed Object Store) — a self-managing, self-healing cluster of storage nodes that required no centralized metadata servers, no configuration databases, and no manual balancing. Instead, Ceph used a clever algorithm called CRUSH (Controlled Replication Under Scalable Hashing) that allowed any client to compute the location of any object without consulting a central directory. Combined with the S3-compatible object storage API popularized by Amazon, Ceph brought scalable, software-defined storage to the masses. This post explores the RADOS architecture, the CRUSH algorithm, the S3 API, and the erasure coding that makes object storage cost-effective at scale.

## 1. The Object Storage Model: Flat Namespace, Immutable Objects

Object storage abandons the hierarchical directory structure of file systems in favor of a flat namespace. Instead of files organized into directories, object storage has "buckets" (S3 terminology) or "pools" (Ceph terminology) containing objects identified by unique keys. An object is a blob of data (from bytes to terabytes) with associated metadata (key-value pairs) and a globally unique identifier.

This flat model simplifies scalability. There's no directory hierarchy to maintain, no inode limits to hit, no path resolution to perform. Objects are stored and retrieved by their keys; the storage system maps keys to storage locations using a hash function or a placement algorithm. The metadata for each object (size, creation time, owner, custom tags) is stored alongside the object or in a separate metadata service.

The S3 API, introduced by Amazon Web Services in 2006, has become the de facto standard for object storage. S3 defines a simple set of HTTP-based operations: PUT (create or overwrite an object), GET (retrieve an object), DELETE (remove an object), LIST (enumerate objects in a bucket), and HEAD (retrieve metadata without the data). The API is intentionally simple — no rename, no append, no partial write (for simple PUTs) — which makes it easy to implement and scalable to trillions of objects.

Ceph's RADOS Gateway (RGW) implements the S3 API on top of RADOS, allowing Ceph clusters to serve as drop-in replacements for Amazon S3. Applications written for S3 can run against Ceph without modification, making Ceph the most popular open-source object storage platform.

## 2. RADOS: The Object Store That Manages Itself

RADOS is the foundation of Ceph. It's a distributed object store that runs on a cluster of OSDs (Object Storage Daemons), each managing one or more local storage devices (HDDs, SSDs, or NVMe). RADOS stores objects in "pools," which are logical groupings with configurable replication or erasure coding policies.

The key property of RADOS is that it's self-managing. There is no central metadata server, no allocation table, and no configuration database that tells the system where each object is stored. Instead, RADOS uses the CRUSH algorithm to compute object locations deterministically. When a client wants to read or write an object, it hashes the object's name, feeds the hash into CRUSH along with the cluster map (a compact description of the cluster's topology), and gets back a list of OSDs that should store the object. The client then contacts those OSDs directly.

RADOS handles failures autonomously. Each OSD periodically sends heartbeats to its peers. If an OSD fails, the surviving OSDs detect the failure, update the cluster map to mark the OSD as "down," and trigger recovery: the objects that were stored on the failed OSD are replicated onto other OSDs to restore the desired replication factor. This recovery is distributed (all surviving OSDs participate) and throttled (to avoid overwhelming the cluster with recovery traffic while still serving client requests).

RADOS also handles data integrity. Each object stored on an OSD is checksummed (CRC32 or a stronger hash), and the OSD verifies the checksum on every read. If the checksum fails (indicating silent data corruption from bit rot or a firmware bug), the OSD reports the error, and the object is reconstructed from a healthy replica. This is "end-to-end data integrity" — the client writes with a checksum, the OSD stores and verifies the checksum, and the client can also verify the checksum on read.

## 3. CRUSH: Placement Without a Directory

CRUSH is the algorithm at the heart of Ceph's scalability. The problem CRUSH solves is: given an object name and a description of the cluster (a hierarchy of hosts, racks, rows, and datacenters), determine which OSDs should store the object and its replicas, without consulting a central directory.

CRUSH works by constructing a weighted hierarchy from the cluster map. Each OSD has a weight (proportional to its capacity). OSDs are grouped into hosts, hosts into racks, racks into rows, rows into datacenters. The CRUSH algorithm takes the object's placement group (derived by hashing the object name), and recursively selects OSDs from the hierarchy, biased by weight and constrained by placement rules.

The placement rules encode the data placement policy. A typical rule might be: "choose 3 OSDs, each from a different host, with hosts from different racks." CRUSH selects the first OSD by hashing the placement group ID and walking down the hierarchy, selecting a rack, then a host, then an OSD, each step weighted by capacity. For the second OSD, it chooses a different rack (to ensure rack-level fault tolerance) and selects a host and OSD from that rack. The third OSD comes from yet another rack.

The critical property of CRUSH is that it's deterministic and convergent. Given the same cluster map and the same placement group ID, CRUSH always produces the same list of OSDs. If the cluster map changes (OSDs are added or removed), CRUSH produces a new list, and the minimal number of objects need to be moved to conform to the new mapping. This is much more efficient than consistent hashing or a centralized placement table, because CRUSH can recompute the mapping on the fly without storing any state.

CRUSH has limitations. The placement is not perfectly uniform (some OSDs may get more data than others due to hash collisions and weight discretization), but the variance is small in practice (a few percent). And CRUSH's determinism means that if the cluster map is temporarily inconsistent (different clients have slightly different versions), they may compute different OSD lists for the same object, leading to temporary inconsistencies. Ceph mitigates this by having OSDs verify object ownership and forward requests to the correct OSD if there's a mismatch.

## 4. Erasure Coding: Storing Data Without Full Replication

Replication is simple and fast, but expensive: storing three copies of every object triples the storage cost. Erasure coding provides the same durability with much lower overhead. A \((k, m)\) erasure code takes \(k\) data chunks, computes \(m\) parity chunks, and stores all \(k+m\) chunks across different failure domains. Any \(k\) of the \(k+m\) chunks are sufficient to reconstruct the original data. The storage overhead is \((k+m)/k\).

For example, a (6, 3) erasure code stores 9 chunks total (6 data + 3 parity) and can tolerate the loss of any 3 chunks. The storage overhead is 1.5x (9/6), compared to 3x for triple replication. The trade-off is that erasure coding requires more computation (encoding and decoding) and more network I/O (reading from multiple OSDs to reconstruct data).

Ceph supports erasure coding at the pool level. When a client writes an object to an erasure-coded pool, the primary OSD divides the object into \(k\) data chunks, computes \(m\) parity chunks (using a Reed-Solomon or Cauchy code), and distributes the chunks across \(k+m\) OSDs. On read, the client (or the primary OSD) fetches any \(k\) chunks (typically the data chunks, if they're available) and reconstructs the object.

Erasure coding is ideal for cold data (infrequently accessed). The overhead of reconstruction (fetching from multiple OSDs, computing parity) adds latency, so it's less suitable for hot data. Many Ceph deployments use replication for high-performance pools (SSD-backed, for databases and VMs) and erasure coding for capacity pools (HDD-backed, for backups and archives).

## 5. Summary

Ceph's RADOS and CRUSH represent a fundamentally different approach to distributed storage. Instead of a centralized metadata service (like GFS/HDFS) or a distributed directory (like Amazon S3's internal architecture), Ceph uses a deterministic placement algorithm that allows any client to compute object locations independently. This eliminates metadata bottlenecks, enables linear scalability (add more OSDs = add more throughput), and simplifies the system architecture (no metadata cluster to manage).

The S3 API has become the lingua franca of object storage, and Ceph's compatibility with S3 (through RGW) has made it the go-to choice for organizations that want private object storage without vendor lock-in. Combined with erasure coding for cost-efficient data protection, Ceph can store exabytes of data on commodity hardware with petabyte-scale fault tolerance.

The CRUSH algorithm, now over 15 years old, remains one of the most elegant solutions to the data placement problem: a deterministic, decentralized algorithm that balances data across a heterogeneous, dynamic cluster with minimal data movement. It's a testament to the power of hashing — the same insight that powers consistent hashing, Dynamo, and Chord — applied with exceptional care and engineering to the messy realities of storage hardware.

## 6. CRUSH Map Internals: Hierarchical Placement Rules

The CRUSH map is a binary-encoded data structure that describes the cluster's topology and the placement rules. Let's examine a concrete CRUSH rule for a 3-replica, rack- fault-tolerant policy:

```text
rule replicated_rack {
    id 0
    type replicated
    min_size 1
    max_size 10
    step take default
    step chooseleaf firstn 0 type rack
    step emit
}
```

This rule says: starting from the "default" root (step take default), select 3 racks (firstn 0, where 0 is the number of replicas, specified at runtime), and within each selected rack, choose a single host and OSD (chooseleaf). The `chooseleaf` step ensures that each replica ends up on a different host within the chosen rack, providing host-level fault tolerance within each rack.

The CRUSH algorithm uses a variation of "straw" selection for weighted random choice. In straw selection, each item (rack, host, OSD) is assigned a "straw length" computed from a hash of the item's ID, the placement group ID, and the item's weight. Items with higher weights have longer straws. The algorithm selects the item with the longest straw that hasn't already been chosen (for the first replica) or that satisfies additional constraints (for subsequent replicas). This weighted selection ensures that data distribution is proportional to OSD capacities.

## 7. Ceph BlueStore: The Object Storage Engine

Ceph originally stored objects as files on a POSIX filesystem (XFS, ext4, or Btrfs). This approach, called FileStore, was simple but had significant limitations: POSIX transaction semantics (journal, write-ahead logging) were redundant with Ceph's own replication and consistency mechanisms, leading to "double writes" (Ceph writes data once, the filesystem journals it, making two writes). FileStore also suffered from directory fragmentation (storing millions of files in a directory) and `fsync` latency (the filesystem's fsync operation is not optimized for small, random writes).

BlueStore, introduced in Ceph's Luminous release (2017), replaced FileStore with a purpose-built storage engine that stores objects directly on raw block devices. BlueStore has two components: a small RocksDB instance for metadata (object names, attributes, allocation metadata) stored on a fast device (NVMe or SSD), and the object data itself stored on the raw block device (HDD or SSD). This separation allows metadata operations (listing objects, checking existence) to be fast (served from the metadata SSD) while bulk data is stored cost-effectively on HDDs.

BlueStore's write path is optimized for Ceph's replication model. Writes are first written to a "write-ahead log" (WAL) on the fast device (for low latency), then asynchronously written to the slow device in larger, sequential chunks. The WAL is a circular buffer that is replayed on crash recovery, providing crash consistency without the filesystem journal overhead. BlueStore also implements transparent compression (zlib, snappy, zstd) and checksumming (crc32c, xxhash) on a per-object basis.

## 8. Ceph RBD and CephFS: Block and File on Top of Objects

Ceph's RADOS object store is the foundation for two additional storage interfaces: RBD (RADOS Block Device) and CephFS (Ceph File System). RBD provides a virtual block device (like a hard disk) that can be attached to a VM or used as a raw storage volume. Internally, RBD stripes block device data across RADOS objects (typically 4 MB objects), using the CRUSH algorithm to distribute the objects across the cluster.

RBD supports thin provisioning (the block device appears to be a large size but only consumes space for written data), snapshots (point-in-time copies of the block device, implemented via copy-on-write at the RADOS object level), and layering (cloning a snapshot to create a new block device that shares unchanged data with the parent). These features make RBD a popular choice for VM disk images in OpenStack (Cinder) and Proxmox VE.

CephFS provides a POSIX-compliant distributed file system on top of RADOS. Unlike object storage (which has a flat namespace), CephFS supports a hierarchical directory structure with standard file operations (open, read, write, close, stat, chmod, rename). CephFS metadata is managed by a cluster of Metadata Servers (MDS), which distribute the directory hierarchy across multiple servers using dynamic subtree partitioning. Each MDS is responsible for a portion of the directory tree, and the partitioning adapts to load (hot directories are split across multiple MDSes).

CephFS uses RADOS objects to store file data, with each file striped across multiple RADOS objects (similar to RBD). File metadata (inode information, directory entries) is stored in RADOS objects managed by the MDS. This means that CephFS inherits all the benefits of RADOS: self-healing, CRUSH-based placement, erasure coding support, and snapshot capabilities.

## 9. Ceph Operation: Recovery, Rebalancing, and Backfill

Ceph's self-managing capabilities are most evident during cluster operations. When an OSD fails, Ceph detects the failure (via heartbeat timeouts, typically within 20 seconds) and initiates recovery. The surviving OSDs that hold replicas of the affected placement groups begin copying data to new OSDs (chosen by CRUSH to maintain the desired placement policy). Recovery is distributed (all OSDs participate as both sources and destinations) and throttled to avoid overwhelming the cluster (the `osd_max_backfills` and `osd_recovery_max_active` settings control the rate).

When new OSDs are added to the cluster, Ceph rebalances data to utilize the new capacity. The CRUSH algorithm computes new placements for some placement groups (those that would now be assigned to the new OSDs under the updated cluster map), and Ceph migrates the affected placement groups to their new locations. The number of objects moved is proportional to the weight of the new OSDs relative to the total cluster weight — adding 10% more capacity moves roughly 10% of the data. This is "minimal data movement" relative to a naive approach that might rehash all objects.

Backfill is a special case of recovery used when an OSD returns after a temporary failure. Instead of re-replicating all data from scratch, the recovering OSD compares its local state with the surviving replicas and requests only the data it missed while it was down (tracked by PG log entries). This is much more efficient than full recovery, especially for OSDs that were down for a short period.

## 10. Ceph vs the World: Competitive Landscape

Ceph competes in a crowded storage market. On the object storage front, MinIO (an S3-compatible object store written in Go) offers a simpler architecture than Ceph — a single Go binary that stores objects on local filesystems, with erasure coding across nodes. MinIO is easier to deploy than Ceph (no separate monitor, manager, or metadata server to configure) but lacks Ceph's unified block and file interfaces. For pure object storage workloads, MinIO's simplicity is compelling.

On the block storage front, Ceph RBD competes with VMware vSAN, Nutanix, and cloud block storage services. RBD's advantage is its integration with OpenStack (Cinder), Kubernetes (Rook/Ceph), and Proxmox VE. The Rook operator automates Ceph deployment and management on Kubernetes, making Ceph accessible to teams without dedicated storage expertise.

On the file storage front, CephFS competes with NFS (simple, ubiquitous, but single-server), GlusterFS (scale-out NFS alternative, now part of Red Hat), and cloud file services (EFS, Azure Files). CephFS's advantage is its tight integration with the RADOS object store — the same cluster that serves S3 objects and RBD block devices can also serve CephFS files, with unified management and CRUSH-based placement.

Ceph's greatest strength — its unified platform — is also its greatest complexity. A Ceph cluster that serves RBD, CephFS, and RGW must run OSDs, MONs, MGRs, MDSes, and RGW instances, each with its own configuration and scaling considerations. The operational burden is significant. Rook (the Ceph operator for Kubernetes) has dramatically simplified Ceph deployment, but Ceph remains a complex system that requires expertise to operate at scale.

## 11. Ceph Monitor (MON) and the Paxos-Based Cluster Map

Ceph Monitors (MONs) maintain the cluster map — the authoritative description of the cluster's topology (which OSDs exist, their capacities, and their states — up, down, in, out). The cluster map is the single source of truth that all clients and OSDs use to compute data placement via CRUSH. Maintaining a consistent cluster map across all participants is a consensus problem, which Ceph solves using Paxos.

The MON cluster (typically 3 or 5 nodes) runs Paxos to agree on cluster map updates. When an OSD fails or a new OSD is added, a MON proposes a cluster map update. The Paxos protocol ensures that all MONs agree on the update, and the new map is disseminated to clients and OSDs via a gossip-based protocol (similar to how routers distribute link-state updates). Clients periodically check with a MON for map updates; OSDs exchange maps among themselves to detect and propagate changes quickly.

The MONs also manage authentication (CephX protocol), storage pool configuration (replication factor, erasure coding policy, CRUSH rule), and snapshot state. MONs do not store object data or metadata — they are purely control plane services. Their state is stored in a LevelDB database (or RocksDB) on local storage, with the Paxos log providing consistency across MON replicas. The MON cluster is the "brain" of Ceph, and its correct operation is essential for the entire cluster's health.

## 12. Summary

Ceph's RADOS and CRUSH represent a fundamentally different approach to distributed storage. Instead of a centralized metadata service, Ceph uses a deterministic placement algorithm that allows any client to compute object locations independently. This eliminates metadata bottlenecks, enables linear scalability, and simplifies system architecture. The S3 API has become the lingua franca of object storage, and Ceph's compatibility with S3 has made it the go-to choice for private object storage. Combined with erasure coding for cost-efficient data protection and a rich ecosystem of block (RBD) and file (CephFS) interfaces, Ceph provides a unified storage platform that can serve virtually any workload.

## 13. Ceph OSD Internals: ObjectStore and BlueStore

Ceph OSDs store objects using a pluggable ObjectStore interface. FileStore was the original implementation, storing objects as files on a POSIX filesystem (XFS, ext4). FileStore had significant limitations: the filesystem's journal introduced double writes (Ceph wrote to the OSD journal, then the filesystem wrote to its own journal), and directory operations (listing objects, checking existence) were slow for millions of objects.

BlueStore, introduced in Ceph Luminous (2017), replaced FileStore with a purpose-built storage engine. BlueStore stores object data directly on a raw block device, bypassing the filesystem entirely. Metadata (object names, attributes, allocation metadata) is stored in a small RocksDB instance on a fast device (NVMe or SSD). The separation of metadata (RocksDB) and data (raw block) allows each to be optimized independently: metadata operations are fast (RocksDB on SSD), and data operations bypass the filesystem (direct to disk with checksums).

BlueStore's write path is optimized for Ceph's replication model. Writes are first written to a Write-Ahead Log (WAL) on the fast device, then asynchronously written to the slow device in larger, sequential chunks (deferred writes). This provides low latency (the WAL write is fast) and high throughput (the deferred writes can be batched and reordered for optimal disk access). BlueStore also supports transparent compression (zlib, snappy, zstd) and checksumming on a per-object basis, providing data integrity without filesystem overhead.

## 14. A Day in the Life of a Ceph OSD

To concretize the Ceph architecture, let's trace a single write operation from client to disk. (1) The client hashes the object name and applies the CRUSH algorithm to find the primary OSD for the object's placement group. (2) The client sends the write to the primary OSD. (3) The primary OSD creates a PG log entry recording the operation, writes the data to its ObjectStore (BlueStore's WAL, then later to disk), and forwards the operation to the secondary OSDs. (4) Each secondary OSD writes the data to its ObjectStore and acknowledges the primary. (5) When the primary receives acknowledgments from a quorum of OSDs, it acknowledges the client and updates its PG log to mark the operation as committed. (6) If an OSD fails during this process, the PG log allows the surviving OSDs to determine which operations are committed and which need to be replayed or rolled back. The entire process, from client to acknowledgment, completes in 1-2 milliseconds on a well-tuned Ceph cluster with NVMe OSDs.

## 15. Ceph in Production: Lessons from Hyperscale Deployments

Ceph is deployed at massive scale in several high-profile environments. CERN uses Ceph to store physics data from the Large Hadron Collider — over 100 PB of raw capacity across multiple clusters. CERN's Ceph deployment handles a unique workload: very large files (multi-TB physics datasets), write-once-read-many access patterns, and extreme durability requirements (data must survive for decades). Ceph's erasure coding (with 8+3 or 8+4 schemes) and CRUSH-based placement (ensuring data is distributed across different rooms and buildings at CERN) make it a natural fit for this workload.

Bloomberg runs Ceph at several hundred petabytes for financial data storage. Bloomberg's workload is very different from CERN's: small objects (KB-sized financial records), high write throughput (millions of transactions per day), and strict latency requirements (analysts querying real-time data expect sub-second responses). Bloomberg's Ceph deployment uses replication (for low-latency reads), flash-based OSDs (for predictable performance), and careful CRUSH tuning (to keep data local to the query engines).

These production experiences have shaped Ceph's development roadmap. The community has learned that CRUSH placement is not perfectly uniform (variance of 5-15% in OSD utilization), that recovery performance is critical (a single OSD failure triggers massive data movement), and that operator tooling is as important as core performance (dashboards, alerts, automated remediation). Ceph's evolution from research prototype to production-grade storage system is a testament to both the elegance of its architecture and the dedication of its community.

## 16. The S3 API: Semantics, Consistency, and the CAP Theorem

The S3 API is deceptively simple — PUT, GET, DELETE, LIST — but its consistency semantics are subtle and have evolved over time. Understanding these semantics is essential for building correct applications on top of S3-compatible storage.

### The Consistency Model

Amazon S3 originally provided "eventual consistency" for all operations except PUT of a new object (which was strongly consistent). This meant that after a successful PUT (overwriting an existing object), a subsequent GET might return the old version — the new data could take time to propagate across S3's internal replication. In December 2020, AWS announced that S3 now provides "strong read-after-write consistency for all GET, PUT, and LIST operations" — a significant engineering achievement that required reworking S3's internal replication protocol. The new consistency model means that after a successful PUT, all subsequent GETs will return the new data, and after a successful DELETE, all subsequent GETs will return 404.

Ceph's RGW (RADOS Gateway) implements the S3 API with its own consistency model, which depends on the underlying RADOS replication. By default, Ceph provides strong consistency for reads and writes through synchronous replication (the write is acknowledged only after a quorum of OSDs have stored it). However, for multi-site deployments (Ceph's multi-site replication feature), consistency is eventual across sites — a write to the primary site may not be immediately visible at the secondary site. Applications that require cross-site strong consistency must use Ceph's "sync" policy or application-level coordination through an external consensus service like ZooKeeper or etcd.

### Multipart Uploads and Object Versioning

For large objects (multi-gigabyte files), S3 supports multipart uploads: the client divides the object into parts (minimum 5 MB per part, maximum 10,000 parts), uploads each part independently (with retry on failure), and then issues a "complete multipart upload" request that atomically assembles the parts into a single object. This enables parallel upload (multiple parts in flight simultaneously), resumable uploads (if a part fails, only that part needs to be re-uploaded), and upload of objects larger than a single PUT can handle (S3's maximum single PUT is 5 GB; multipart enables up to 5 TB).

Ceph's RGW implements multipart uploads using RADOS objects: each part is stored as a separate RADOS object, and the "complete" operation creates a manifest object that references the parts. This manifest approach allows the parts to be distributed across the cluster via CRUSH, enabling parallel writes to different OSDs and maximizing throughput for large object uploads.

S3 also supports object versioning: when enabled on a bucket, every PUT creates a new version of the object rather than overwriting the previous version. DELETE creates a "delete marker" rather than removing the object, allowing the previous version to be recovered. Versioning is the foundation for S3's durability guarantees — even if an object is accidentally deleted, the previous version remains recoverable. Ceph implements versioning in RGW using RADOS object versioning, where each version has a unique internal object name.

## 17. Erasure Coding Mathematics: Reed-Solomon and Jerasure

Erasure coding transforms the durability-cost equation by replacing full replication with parity-based redundancy. Understanding the mathematics behind erasure coding illuminates the trade-offs between storage overhead, fault tolerance, and computational cost.

### Reed-Solomon Codes

The most common erasure code is Reed-Solomon (RS). An RS(k, m) code operates over a finite field (typically GF(2^8) or GF(2^16), meaning arithmetic on 8-bit or 16-bit symbols). Given k data symbols d*0, d_1, ..., d*{k-1}, the encoder computes m parity symbols p*0, p_1, ..., p*{m-1} as:

```
p_i = sum_{j=0}^{k-1} d_j * alpha_i^j  (mod GF(2^8))
```

where alpha_i are distinct nonzero elements of the finite field. The Vandermonde structure of the coefficient matrix ensures that any k of the k+m symbols can reconstruct the original data — the system of equations formed by the surviving symbols is always solvable because the corresponding k×k submatrix of the Vandermonde matrix is invertible.

The computational cost of Reed-Solomon encoding is O(km) field operations. For small k and m (e.g., 6+3), this is fast enough for software implementation (tens of GB/s on modern CPUs with SIMD acceleration). For larger codes (e.g., 20+4 for cold storage), the encoding cost grows quadratically, motivating hardware acceleration (FPGA or GPU) for exabyte-scale deployments.

### Jerasure and Cauchy Reed-Solomon

Ceph uses the Jerasure library (developed by James Plank at the University of Tennessee) for erasure coding. Jerasure implements multiple erasure coding algorithms, including standard Reed-Solomon, Cauchy Reed-Solomon (which uses a Cauchy matrix instead of a Vandermonde matrix, enabling faster decoding), and Liberation codes (a type of low-density parity-check codes optimized for minimal decoding latency).

The choice of erasure coding algorithm depends on the workload: Cauchy Reed-Solomon provides the best balance of encoding/decoding speed and storage overhead for most Ceph deployments. Liberation codes are faster for decoding (important for read-heavy workloads) but have slightly higher storage overhead. The Ceph administrator can select the algorithm per pool, tuning for the expected access pattern.

### The Reconstruction Path

When a Ceph client reads an object from an erasure-coded pool and one of the data chunks is unavailable (the OSD hosting it is down), the primary OSD must reconstruct the missing chunk from the available chunks. The reconstruction process: (1) the primary OSD reads k available chunks (data or parity) from other OSDs, (2) inverts the k×k submatrix of the encoding matrix corresponding to the available chunks, (3) multiplies the available chunks by the inverted matrix to recover the original data, (4) returns the data to the client. This reconstruction adds latency (multiple OSD reads plus matrix computation) and network bandwidth (reading k chunks instead of 1). This is the fundamental trade-off of erasure coding: reduced storage cost in exchange for higher read amplification during degraded reads.

For this reason, Ceph by default routes reads to the data chunks (not parity chunks) when all data OSDs are available, avoiding reconstruction entirely. Only during degraded mode (an OSD is down or slow) does reconstruction occur. This is why erasure coding is best suited for cold data — degraded reads are rare, and the storage savings outweigh the occasional reconstruction cost.

## 18. Summary

Ceph's RADOS architecture and CRUSH algorithm represent a fundamentally different approach to distributed storage. By replacing a centralized metadata service with a deterministic, hash-based placement algorithm, Ceph eliminates metadata bottlenecks and enables linear scalability. Any client can compute the location of any object independently, without consulting a directory — this is the key insight that makes Ceph scale to exabyte deployments. The S3-compatible RADOS Gateway brings the industry-standard object storage API to Ceph, enabling drop-in replacement for Amazon S3 in private cloud deployments. Erasure coding transforms the storage economics, providing high durability at a fraction of the replication overhead. BlueStore, CephFS, and RBD extend the platform to meet block and file storage needs, making Ceph a unified storage platform.

The operational complexity of Ceph — its many components (OSDs, MONs, MGRs, MDSes, RGW), its sensitivity to hardware and network performance, and the learning curve of its configuration — remains the primary barrier to adoption. But tools like Rook (the Ceph operator for Kubernetes) and Ceph Dashboard are steadily reducing that barrier. Ceph's journey from a UC Santa Cruz PhD dissertation to a production-grade storage platform powering CERN, Bloomberg, and thousands of other organizations is one of the great success stories of open-source infrastructure. It demonstrates that elegant, mathematically principled design — the CRUSH algorithm, the Paxos-based cluster map, the Jerasure erasure coding library — can deliver practical value at enormous scale.
