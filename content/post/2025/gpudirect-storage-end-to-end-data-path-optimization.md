---
title: "GPUDirect Storage in 2025: Optimizing the End-to-End Data Path"
description: "How modern systems move data from NVMe and object storage into GPU kernels with minimal CPU overhead and maximal throughput."
date: "2025-09-16"
author: "Leonardo Benicio"
tags: ["gpu", "storage", "rdma", "data-path", "hpc"]
categories: ["distributed systems", "performance"]
cover: "/static/assets/images/blog/gpudirect-storage-end-to-end-data-path-optimization.png"
---

High-performance analytics and training pipelines increasingly hinge on how _fast_ and _efficiently_ data reaches GPU memory. Compute has outpaced I/O: a single multi-GPU node can sustain tens of TFLOPs while starved by a few misconfigured storage or copy stages. GPUDirect Storage (GDS) extends the GPUDirect family (peer-to-peer, RDMA) to allow DMA engines (NVMe, NIC) to move bytes directly between storage and GPU memory—bypassing redundant copies through host DRAM and reducing CPU intervention.

This article provides a deep, engineering-focused exploration of the end-to-end path: filesystems, NVMe queues, PCIe / CXL fabrics, GPU memory hierarchies, kernel launch overlap, compression, and telemetry. It mirrors the style of prior posts: structured sections, performance modeling, tuning checklist, pitfalls, future directions, and references.

---

## 1. Motivation & Problem Statement

### Why the Data Path Matters

1. **GPU Utilization Sensitivity**: Idle SMs due to I/O stalls waste expensive accelerator time.
2. **Energy Efficiency**: Extra memory copies burn power (DDR→PCIe→GPU) with no useful work.
3. **CPU Contention**: Data loader threads compete with orchestration, scheduling, and networking tasks.
4. **Scalability Breakpoints**: Adding GPUs does not scale linearly if the I/O subsystem saturates at earlier tiers.

### Traditional Path

`Storage (NVMe / Object)` → `Kernel / FUSE / Filesystem` → `Page Cache` → `User-space read()` → `Pinned Buffer (cudaHostAlloc)` → `cudaMemcpy` → `GPU global memory` → `Kernel`

Each arrow can introduce latency, CPU cycles, cache pollution, and memory bandwidth consumption.

### GDS-Enhanced Path (Ideal)

`Storage` → `DMA (NVMe controller or RDMA NIC)` → `GPU BAR / Memory` → `Kernel`

Host CPU involvement shrinks to submission/completion queue management and control-plane scheduling.

---

## 2. Architectural Components

### 2.1 Storage Device Layer

- **NVMe SSDs**: Provide parallel submission/completion queues; PCIe Gen5 x4 lanes approach ~14 GB/s. Multiple drives can be striped (RAID0 / software striping) for higher aggregate throughput.
- **Zoned Namespace (ZNS)**: Reduces FTL overhead; sequential zone append patterns align with large batched reads.
- **NVDIMMs / PMem (legacy)**: Still present in some tiered designs as intermediate caches.

### 2.2 Interconnect & Fabric

- **PCIe Gen5 / Gen6**: Latency ~150ns fabric hops; lane bifurcation and switch topology shape contention. Avoid oversubscribing upstream link for combined NIC + NVMe + GPUs.
- **CXL.io / CXL.mem**: Emerging for memory expansion; future direct GPU access to pooled memory may blur staging distinctions.
- **NVLink / NVSwitch**: Enables peer GPU memory forwarding; in multi-GPU pipelines, one GPU may prefetch for others.

### 2.3 GPU Memory & Hierarchy

- Global memory (HBM) is destination for DMA. L2 acts as a large cache for streaming kernels; proper alignment and large transfer granularities (≥128 KB) improve efficiency.
- Page faulting (on-demand memory) adds unpredictable latency; prefer explicit prefetch or pinned allocations.

### 2.4 Software Stack

| Layer                               | Role                      | Latency Sensitivity | Key Tuning                      |
| ----------------------------------- | ------------------------- | ------------------- | ------------------------------- |
| Filesystem (ext4/xfs/beeGFS/Lustre) | Namespace & metadata      | Moderate            | Mount opts, stripe size         |
| Block Layer / NVMe Driver           | Queueing & DMA submission | High                | IO depth, IRQ affinity          |
| GDS Library (cuFile)                | Direct path management    | High                | Batch size, alignment           |
| CUDA Runtime                        | Stream & event scheduling | High                | Concurrency, priority streams   |
| Application Loader                  | Batching, decode, augment | High                | Async pipelines, thread pinning |

---

## 3. Data Flow Variants

### 3.1 Synchronous CPU-Mediated Copy

1. CPU issues `read()` into page cache.
2. Copies into pinned buffer.
3. Launches `cudaMemcpyAsync` to device.
4. Kernel waits on stream event.

Issues: double-copy overhead, CPU involvement on hot path, page cache thrash for streaming-only data.

### 3.2 Direct Storage to GPU (GDS)

1. Register file descriptor with cuFile (establish mapping & capabilities).
2. Issue `cuFileRead` into device pointer.
3. Use CUDA events to chain kernel execution after DMA completes.

Reduces memory traffic and CPU load; requires large contiguous reads for best efficiency.

### 3.3 NIC to GPU (Object Storage + RDMA)

When remote object storage supports RDMA (or via gateway node), data can flow: `Remote NVMe` → `RDMA NIC` → `GPU`. Latency dominated by network round-trip; parallel outstanding reads mitigate.

### 3.4 Multi-GPU Prefetch & Relay

GPU0 prefetches data slice and uses NVLink P2P (`cudaMemcpyPeerAsync`) to distribute subsets to GPU1..N while its own kernel processes earlier batch—overlapping ingest and compute.

---

## 4. API & Code Examples

### 4.1 Basic cuFile Read

```c
#include <cufile.h>
#include <cuda_runtime.h>
#include <fcntl.h>
#include <unistd.h>

int main(){
    const char* path = "/mnt/datasets/segment.bin";
    int fd = open(path, O_RDONLY | O_DIRECT);
    cuFileDriverOpen();
    CUfileDescr_t desc = {};
    desc.handle.fd = fd;
    desc.type = CU_FILE_HANDLE_TYPE_OPAQUE_FD;
    CUfileHandle_t handle;
    cuFileHandleRegister(&handle, &desc);

    size_t bytes = 128UL * 1024 * 1024; // 128 MB
    void* d_ptr;
    cudaMalloc(&d_ptr, bytes);

    ssize_t ret = cuFileRead(handle, d_ptr, bytes, 0, 0);
    if (ret < 0) { /* handle error */ }

    // Launch kernel using data
    // myKernel<<<grid, block, 0, stream>>>(d_ptr, ...);

    cuFileHandleDeregister(handle);
    close(fd);
    cuFileDriverClose();
    cudaFree(d_ptr);
}
```

### 4.2 Overlapped Batch Pipeline (Pseudo-Python)

```python
# Pseudo: overlap I/O and compute on batches
streams = [cuda.Stream() for _ in range(P)]
buffers = [cuda.device_array((BATCH, SHAPE), dtype=np.float32) for _ in range(P)]

for batch_idx, offset in enumerate(range(0, total_bytes, chunk)):
    s = streams[batch_idx % P]
    buf = buffers[batch_idx % P]
    cufile.read(fd, buf, size=chunk, file_offset=offset, stream=s)
    model.forward_async(buf, stream=s)

# synchronize at end
for s in streams:
    s.synchronize()
```

### 4.3 Hybrid Path: Compression + Direct Read

Read compressed blocks directly to GPU, then launch GPU decompression (e.g., nvCOMP) before model ingestion.

```c++
// Pseudocode structure
for (block : blocks) {
    cuFileRead(handle, d_comp[slot], comp_bytes, file_off, 0);
    launch_nvcomp_decompress<<<... , stream>>>(d_comp[slot], d_decomp[slot]);
    user_kernel<<<... , stream>>>(d_decomp[slot]);
}
```

Constraint: Ensure decompression kernel consumes only after read completion—use stream ordering or explicit events.

---

## 5. Performance Modeling

### 5.1 Throughput Model

Let:

- B_nvme = Aggregate NVMe bandwidth (GB/s)
- B_pcie = Sustained PCIe bandwidth to GPU (GB/s)
- B_mem = Effective GPU memory write bandwidth (GB/s) for large transfers
- B_kernel = Data consumption rate of downstream kernels (GB/s)

Steady-state ingest rate R_ingest ≈ min(B_nvme, B_pcie, B_mem, B_kernel).

### 5.2 Queue Depth & Outstanding I/O

Throughput saturates as outstanding requests (QD) approaches device parallelism. Latency-sensitive small reads degrade aggregate. Use large aligned reads (≥1 MB) and maintain QD≥N_lanes utilization target.

### 5.3 Overlap Efficiency

Define overlap factor O = (Compute_Time + IO_Time - Makespan) / min(Compute_Time, IO_Time). Aim for O → 1. Diagnose with timeline correlation (Nsight Systems). Underlap indicates serialization or insufficient parallel I/O.

### 5.4 Roofline Extension (I/O + Compute)

Effective performance limited by min(Compute FLOP/s, R_ingest \* Operational_Intensity). Increase Operational Intensity by fusing lightweight transformations (e.g., normalization) into decompression or loading kernel.

### 5.5 CPU Offload Savings

CPU_Copy_Cycles ≈ (Bytes / Mem_BW_host) \* cycles_per_byte. GDS removes one host copy: savings scale linearly with dataset size. For multi-GPU nodes, cumulative CPU cycles reclaimed can be reassigned to coordination or pre-processing tasks.

---

## 6. Filesystems & Object Storage Considerations

### 6.1 Local POSIX (ext4/xfs)

- Align file extents with large sequential reads.
- Disable atime updates (`noatime`) to cut metadata writes.
- Consider direct I/O (`O_DIRECT`) to bypass page cache for purely streaming workloads.

### 6.2 Parallel FS (Lustre / BeeGFS / Spectrum Scale)

| Aspect        | Importance | Tuning Knob      | Note                                   |
| ------------- | ---------- | ---------------- | -------------------------------------- |
| Stripe Count  | High       | lfs setstripe    | Match stripes to NVMe count            |
| Stripe Size   | High       | lfs setstripe -S | Large (≥4MB) for throughput            |
| Metadata RPCs | Medium     | MDT config       | Cache directory entries                |
| Locking       | Medium     | Lock ahead       | Reduce contention for sequential scans |

### 6.3 Object Storage (S3-like)

- Latent; parallel range GET requests necessary.
- Use persistent HTTP connections, HTTP/2, or QUIC (where available) to reduce handshake overhead.
- Batch small objects or aggregate into larger shards.

### 6.4 Cache Layers

Local NVMe tier as read cache: promote hot shards; ensure eviction aligns with working set predictions.

---

## 7. Compression, Encoding & Format Choices

### 7.1 Columnar Formats (Parquet, ORC)

Pros: Predicate pushdown, selective decoding reduces bytes moved. Con: Nested encodings may fragment reads (seek storms) if columns interleaved physically.

### 7.2 Row-Major Binary Blocks

Favorable for GPU kernels expecting AoS→SoA transforms performed once on ingest; simpler prefetch logic.

### 7.3 GPU-Friendly Compression

| Codec    | GPU Decode Availability | Typical Ratio | Notes                    |
| -------- | ----------------------- | ------------- | ------------------------ |
| LZ4      | Yes (nvCOMP)            | 1.5–2.0×      | Fast, lower ratio        |
| ZSTD     | Emerging                | 2–4×          | Higher CPU fallback cost |
| GDeflate | Yes                     | 2–3×          | Balanced speed/ratio     |
| Snappy   | Partial                 | 1.5–2.0×      | Legacy analytic stacks   |

### 7.4 Trade-Off Analysis

Net ingest gain when (Compressed_Size / Raw_Size) < (Decode_Time / Copy_Time) threshold. GPU decode amortizes better at large batch sizes due to kernel launch overhead.

---

## 8. Telemetry & Observability

### 8.1 Metrics to Capture

1. NVMe queue depth distribution.
2. Average and p95 I/O latency.
3. DMA throughput (GB/s) per device.
4. GPU memory write throughput vs. theoretical.
5. SM occupancy during ingest phases.
6. Kernel wait time on data availability (timeline gaps).
7. CPU utilization (sys vs. user) for loader threads.
8. Dropped or retried I/O operations.

### 8.2 Tools

| Tool               | Layer    | Use                            |
| ------------------ | -------- | ------------------------------ |
| iostat / blktrace  | Block    | Latency & queue depth          |
| nvidia-smi dmon    | GPU      | PCIe Rx bytes / utilization    |
| Nsight Systems     | GPU + IO | Correlate streams & I/O events |
| cuFile logs        | GDS      | API timing, errors             |
| perf / eBPF probes | Kernel   | Syscall & IRQ attribution      |

### 8.3 Anomaly Diagnosis

- Rising I/O latency + flat queue depth → device throttling or thermal limits.
- High CPU sys% + low ingest throughput → excessive context switches or page cache churn (remove buffering layers).
- Low GPU utilization + high PCIe Rx → compute under-saturated; kernel fusion opportunities.

---

## 9. Tuning Techniques

### 9.1 Alignment & Granularity

- Align reads to 4KB (filesystem block) and ideally 128KB (device optimal). Misaligned offsets cause read-modify cycles.
- Batch small logical records into large extent-aligned I/O.

### 9.2 Queue Depth Management

Maintain sufficient concurrent `cuFileRead` requests. Empirically find knee where more parallelism adds latency (tail amplification) without throughput increase.

### 9.3 IRQ & Core Affinity

Pin NVMe and NIC interrupts to isolated cores; separate from CUDA driver management threads. Avoid sharing with application orchestration.

### 9.4 Stream & Stage Concurrency

Use multiple CUDA streams: one for read DMA, one for decompression, one for compute. Use events to build a dependency chain rather than host synchronizations.

### 9.5 Zero-Copy Pitfalls

Some control metadata may still transit host; measure with PCIe counters. Validate actual host copy elimination (profilers) instead of assuming.

### 9.6 Filesystem Mount Options

`noatime`, large journal commit intervals for ext4, disabling barriers only if power-loss risks acceptable (rarely recommended in production training clusters).

### 9.7 NUMA Considerations

If staging buffers unavoidable (mixed paths), allocate on NUMA node attached to target PCIe root complex. Use `numactl --hardware` mapping.

### 9.8 Adaptive Batch Sizing

Adjust batch size at runtime based on observed ingest latency: keep pipeline depth so that compute rarely stalls; shrink when latency spikes to relieve memory pressure.

---

## 10. Pitfalls & Anti-Patterns

1. **Tiny Random Reads**: Fragment throughput; consolidate or reorder.
2. **Overzealous Page Cache Bypass**: Some reuse patterns benefit from caching; measure before forcing `O_DIRECT`.
3. **Ignoring NUMA for Control Threads**: Results in cross-node waking of IRQ handlers.
4. **Underutilized NVMe Queues**: Single-threaded submission leaving bandwidth idle.
5. **Oversized Queue Depth**: Inflates latency tail; hurts responsiveness for mixed workloads.
6. **Synchronous Decompression**: Blocks potential overlap; move decode to GPU streams.
7. **Single Monolithic Kernel**: Hides I/O-induced stalls; break into stages with explicit dependencies.
8. **Assuming Compression Always Helps**: High-entropy data wastes decode cycles.
9. **Neglecting Thermal Throttling**: SSD temperature >70°C reduces performance; ensure airflow.
10. **Opaque Error Handling**: Silent short reads or partial DMA failures propagate corrupt tensors.

---

## 11. Case Study (Synthetic Benchmark)

### Setup

- 4× NVMe Gen5 drives (striped) delivering ~50 GB/s aggregate theoretical.
- 4× GPUs (H100), PCIe Gen5, each with ~2.0 TB/s HBM peak.
- Dataset: 4 TB of compressed binary blocks (average 2.2× compression via GDeflate).
- Workload: Read → decompress → normalize → feed into compute kernel simulating ML preprocessing.

### Scenarios

| Scenario | Path                        | Avg Ingest (GB/s) | GPU Utilization | CPU Core Usage | Notes                       |
| -------- | --------------------------- | ----------------- | --------------- | -------------- | --------------------------- |
| A        | CPU read + memcpy           | 18                | 55%             | 24 cores busy  | Double copy bound           |
| B        | CPU read + GPU decompress   | 21                | 61%             | 20 cores       | CPU still copy bottleneck   |
| C        | GDS direct + GPU decompress | 34                | 82%             | 8 cores        | Host copy removed           |
| D        | GDS + NVLink relay          | 36                | 85%             | 8 cores        | P2P distribution overlapped |
| E        | GDS + dynamic batch         | 38                | 88%             | 8 cores        | Adaptive pipeline tuning    |

### Observations

- Transition A→C shows ~1.9× ingest improvement; GPU utilization correlates with ingest.
- Relay plus dynamic batch provided marginal but real gains; diminishing returns approaching NVMe ceiling.
- CPU core usage drops freeing resources for auxiliary services (logging, scheduling).

---

## 12. Future Directions (2025+)

1. **CXL Memory Pooling**: Direct GPU reads from pooled CXL-attached memory could collapse staging layers.
2. **In-NIC Decompression**: Offloading lightweight codecs to programmable DPUs to free GPU cycles.
3. **Intelligent Prefetch Graphs**: ML-driven prediction of next dataset shard to pre-stage.
4. **End-to-End QoS**: Coordinated throttling across storage, PCIe switches, and GPU to maintain latency SLOs.
5. **Standardized Telemetry Schema**: Cross-vendor metrics for ingest phases enabling portable auto-tuners.
6. **Security Hardening**: Direct DMA paths expand attack surface; IOMMU + attestation enforcement.
7. **Data Path Virtualization**: Multi-tenant isolation of GDS resources without large overhead.

---

## 13. Tuning Checklist

| Category          | Question                         | Tool / Metric              | Action                                   |
| ----------------- | -------------------------------- | -------------------------- | ---------------------------------------- |
| Bandwidth         | Are NVMe lanes saturated?        | iostat, perf PCIe counters | Increase queue depth, stripe more drives |
| Alignment         | Are reads aligned?               | blktrace, strace           | Pad / repackage shards                   |
| GPU Wait          | Kernels waiting for data?        | Nsight timeline gaps       | Increase parallel reads / batch size     |
| Decompression     | GPU underutilized during decode? | SM occupancy               | Fuse decode + normalize                  |
| CPU Utilization   | High sys%?                       | top, perf                  | Reduce copies, enable GDS                |
| Queue Depth       | Flat throughput before peak?     | iostat, custom logs        | Tune outstanding I/O count               |
| Thermal           | SSD temps high?                  | smartctl                   | Improve cooling / spacing                |
| Compression Ratio | Low ratio (<1.2×)?               | ingest logs                | Disable compression for that shard class |
| NUMA Locality     | Remote memory accesses?          | numastat                   | Rebind threads, allocate locally         |
| Error Handling    | Silent short reads?              | cuFile logs                | Add verification / retries               |

---

## 14. References

1. NVIDIA GPUDirect Storage Documentation (2025).
2. NVMe 2.0 Base Specification.
3. PCI Express Base Specification 6.0.
4. NVIDIA Nsight Systems User Guide.
5. nvCOMP Compression Library Docs.
6. BeeGFS & Lustre tuning guides (2024–2025).
7. CXL Consortium: CXL 3.0 Spec Overview.
8. Research: _In-storage compute for data reduction_ (various 2023–2025 papers).
9. Linux Block Layer & IO_uring design docs.
10. SmartNIC/DPU architecture whitepapers (NVIDIA BlueField, AMD Pensando).

---

## 15. Summary

GPUDirect Storage shifts the bottleneck conversation from host memory copies to genuine device-level throughput constraints. Engineering high-throughput ingest requires coordinated tuning: filesystem striping, queue depth, alignment, compression strategy, stream concurrency, and telemetry-driven adaptation. As CXL, in-NIC processing, and standardized metrics mature, the ideal path trends toward fully pipelined, low-copy, and self-optimizing ingestion layers feeding ever-faster GPU compute pipelines.
