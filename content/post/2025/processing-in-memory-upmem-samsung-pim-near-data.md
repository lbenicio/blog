---
title: "Processing-in-Memory: UPMEM, Samsung HBM-PIM, and the Near-Data Computing Paradigm"
description: "How moving compute to where the bits live rewrites the rules of memory-bound computation, from UPMEM's DRAM-scale PIM to Samsung's HBM-PIM and the programming model that still keeps us up at night."
date: "2025-02-10"
author: "Leonardo Benicio"
tags: ["processing-in-memory", "pim", "upmem", "hbm-pim", "near-data-computing", "memory-wall", "dram", "computer-architecture"]
categories: ["systems", "hardware-architecture"]
draft: false
cover: "static/images/blog/processing-in-memory-upmem-samsung-pim-near-data.png"
coverAlt: "Diagram of a processing-in-memory architecture showing compute units embedded within DRAM banks connected by an inter-bank network"
---

The year is 1995. A paper appears in the proceedings of the International Symposium on Computer Architecture titled "Processing in Memory: Chips to Petaflops." The authors, led by Peter Kogge and including luminaries like Thomas Sterling, lay out a vision where the wall between processor and memory — a wall that has defined computing since the von Neumann report of 1945 — gets dismantled, not by making it thinner, but by moving the processors across it. They propose the EXECUBE architecture: a chip where DRAM cells and simple processing elements share the same silicon, and where the phrase "bus bandwidth" becomes a historical curiosity rather than a daily bottleneck. The paper is visionary, widely cited, and commercially irrelevant for the next twenty years.

Then, around 2015, something shifted. Actually, several somethings: Dennard scaling died, taking with it the free lunch of simultaneous frequency and density improvements. The memory wall — the exponentially growing gap between processor speed and memory bandwidth — stopped being an interesting performance footnote and started being the dominant constraint on virtually every interesting computation. Machine learning models grew from megabytes to terabytes. Graph analytics became a national security priority. Genomic sequencing costs dropped below the cost of analyzing the resulting data. And suddenly, putting compute inside memory looked less like an academic curiosity and more like the only plausible path forward.

By 2025, processing-in-memory — PIM to its friends — has bifurcated into two distinct architectural families, each with shipping silicon and each with its own distinct set of tradeoffs. On one side, UPMEM, a French startup-turned-product-company, offers general-purpose PIM: DRAM DIMMs with hundreds of tiny 32-bit RISC cores embedded directly in the memory chips, exposed to the programmer through a Linux driver and a C/C++ toolchain. On the other side, Samsung's HBM-PIM — and similar efforts from SK hynix — puts specialized floating-point units inside the logic die of High Bandwidth Memory stacks, targeting the narrow but economically enormous sweet spot of neural network training and inference. Between them, they sketch the full possibility space of near-data computing: from general-purpose programmability at DRAM densities to domain-specific acceleration at HBM bandwidths.

This post is a deep dive into that space. We will walk through the UPMEM architecture in detail — the bank organization, the DPU pipeline, the memory-mapped communication model — and then do the same for Samsung's HBM-PIM, which takes a fundamentally different approach. We will talk about the programming model problem, because it turns out that giving programmers thousands of tiny cores with non-uniform memory access is as hard as it sounds. We will look at what workloads actually benefit, what workloads don't, and why the difference matters. And we will try to answer the question that has hung over PIM since 1995: is this time different?

## 1. The Memory Wall: Why We Are Here

Before we can understand PIM, we have to understand the problem it solves. And to understand the problem, we need a few numbers that capture, with brutal clarity, why the von Neumann architecture is slowly strangling itself.

Let us start with the energy cost of data movement. A 64-bit double-precision floating-point operation on a modern CPU costs about 20 picojoules. Reading that same 64-bit value from DRAM — off-chip, across a DDR or HBM interface — costs roughly 2,000 picojoules. That is two orders of magnitude. For a 64-byte cache line, you are looking at roughly 20 nanojoules. When a machine learning training run performs somewhere around 10^18 floating-point operations, you can do the energy math yourself: if even 10% of those operations require off-chip data movement, you are spending megajoules just shuttling bits around. That is the energy equivalent of lifting a car several meters into the air, just to train BERT.

The bandwidth side is equally dire. A modern CPU might have an aggregate memory bandwidth of 100-200 GB/s across all channels. A modern GPU delivers 1-2 TB/s of memory bandwidth through HBM. Meanwhile, the computational throughput of those same devices is measured in teraflops — trillions of operations per second. For a GPU delivering 312 TFLOPS of half-precision compute with 2 TB/s of memory bandwidth, you have 312,000 / (2,000 / 2) ≈ 312 FLOPs per byte. That is the machine balance point: every byte you read from memory had better be used for at least 312 operations, or your compute units are going to sit idle waiting for data. This ratio, known as the operational intensity required to hide memory latency, has been getting worse for at least two decades.

The problem is not just technological; it is architectural. The von Neumann bottleneck is not a bug in a particular implementation of the model — it is the model. When you separate the unit that computes from the unit that stores, you create, by definition, a channel between them. And as the two units get faster, that channel gets strained. You can widen the channel — DDR5 is wider than DDR4, HBM3 is wider than HBM2e — but you cannot eliminate it. Not without violating the model.

Here is another way to think about it. Consider the following C snippet:

```c
    for (size_t i = 0; i < N; i++) {
        c[i] = a[i] + b[i];
    }
```

Three arrays, each of size N. For every iteration, we read two values from memory and write one back. Three memory operations for one floating-point add. The arithmetic intensity of this loop is 1/3 FLOP per byte (one addition, 24 bytes transferred for double precision). On a processor with a machine balance of 10 FLOPs per byte, this kernel runs at 3.3% of peak — assuming perfect caching and prefetching, which in practice is generous. The processor spends 97% of its time and energy waiting for memory. This is the STREAM triad, one of the most studied benchmarks in the history of high-performance computing, and it is the poster child for the memory wall.

PIM attacks this problem by moving the compute to where the data lives. In a PIM architecture, the addition happens inside the DRAM bank, right next to the sense amplifiers that read the bits. The data never leaves the memory chip. The energy cost collapses from the 2,000 pJ of an off-chip transfer to something closer to the 20 pJ of the actual computation. The bandwidth explodes because internal DRAM bandwidth — the bandwidth between the memory cells and the sense amplifiers, before any external interface gets involved — is measured in terabytes per second per chip. The tradeoff is that the compute you can do inside a DRAM bank is, necessarily, much simpler than what you can do in a modern out-of-order superscalar core. The art of PIM is finding the sweet spot across this tradeoff.

## 2. The UPMEM Architecture: A Programmer's PIM

UPMEM is a French semiconductor company founded in 2015 as a spin-off from research at INRIA and LIRMM. Their product is disarmingly simple to describe: take a standard DDR4 DIMM, replace the DRAM chips with UPMEM's custom chips, and suddenly each DIMM contains not just memory but also 2,048 tiny 32-bit RISC processing elements called DPUs (DRAM Processing Units). A server with 20 such DIMMs deploys over 40,000 DPUs. That is not a typo: forty thousand programmable cores, running at 350-500 MHz, each with its own small scratchpad memory and its own private slice of the DRAM address space.

To understand how this works, we need to descend into the chip microarchitecture. A UPMEM chip — fabricated on a standard DRAM process, which is crucial for cost — is organized into eight independent banks. Each bank contains a DPU and a dedicated 64 MB slice of DRAM. The DPU itself is a 14-stage in-order RISC pipeline with 32-bit general-purpose registers (24 GPRs, to be precise), supporting the standard integer and logical operations plus some extensions for bit manipulation and hardware loops. It has a 64 KB instruction memory (IRAM) and a 64 KB working memory (WRAM) that serves as a software-managed scratchpad — there is no data cache. The DPU can access its own bank's 64 MB DRAM slice with a latency of roughly 100 cycles and a bandwidth of about 1 GB/s per DPU. It can also send messages to other DPUs on the same DIMM or even across DIMMs through a tree-based interconnect.

The critical constraint — and the source of most of the programming difficulty — is that a DPU can only directly address its own bank's DRAM. If DPU 7 wants data that lives in bank 3, it must either request that data explicitly through the inter-DPU messaging system or the host CPU must orchestrate the data placement to begin with. This is a distributed memory architecture, not a shared memory one. Every DPU is its own little island of compute and memory, connected to the rest of the archipelago by a network with a latency measured in hundreds of cycles. If you have programmed MPI clusters or GPUs with explicit memory management, the mental model will be familiar. If you are used to OpenMP `#pragma omp parallel for`, you are in for a rough time.

Here is the topology as ASCII art:

```
    +====================================================+
    |                UPMEM DIMM (20 chips)                |
    |  +----------+  +----------+       +----------+     |
    |  | Chip 0   |  | Chip 1   |  ...  | Chip 19  |     |
    |  | +------+ |  | +------+ |       | +------+ |     |
    |  | | DPU  | |  | | DPU  | |       | | DPU  | |     |
    |  | +--+---+ |  | +--+---+ |       | +--+---+ |     |
    |  |    |     |  |    |     |       |    |     |     |
    |  | +--v---+ |  | +--v---+ |       | +--v---+ |     |
    |  | | 64MB  | |  | | 64MB  | |       | | 64MB  | |     |
    |  | | DRAM  | |  | | DRAM  | |       | | DRAM  | |     |
    |  | +------+ |  | +------+ |       | +------+ |     |
    |  +----+-----+  +----+-----+       +----+-----+     |
    |       |              |                  |           |
    |       +--------------+------------------+           |
    |                      |                              |
    |              +-------v--------+                     |
    |              | Interconnect   |                     |
    |              | (Tree/Mesh)    |                     |
    |              +-------+--------+                     |
    |                      |                              |
    |              +-------v--------+                     |
    |              | DDR4 PHY       |                     |
    |              +-------+--------+                     |
    +======================|==============================+
                           |
                   +-------v--------+
                   | Host CPU        |
                   | (x86/ARM)       |
                   +-----------------+
```

Each DPU executes a small kernel — typically a few hundred instructions — on its local slice of data. The host CPU is responsible for loading data onto the DIMMs, launching DPU kernels, and collecting results. The programming flow looks like this: (1) the host allocates buffers in UPMEM-managed memory using a custom `malloc`-like API, (2) the host copies input data into those buffers, (3) the host compiles a DPU kernel (written in a subset of C with some extensions) and loads it into the DPUs' IRAM, (4) the host launches the kernel across some subset of DPUs, (5) the DPUs execute independently, communicating point-to-point as needed, and (6) the host copies results back to main memory. If this sounds like GPU programming — `cudaMalloc`, `cudaMemcpy`, kernel launch, `cudaMemcpy` — you are exactly right. UPMEM has essentially transplanted the GPU offload model into the memory subsystem.

The UPMEM DPU instruction set is worth a brief detour. It is a 32-bit fixed-width RISC ISA with a mix of standard and custom instructions. The arithmetic operations are what you would expect: add, subtract, multiply (32-bit multiply, 64-bit result), divide (software-emulated), shifts, logical operations. Control flow uses compare-and-branch instructions with a single branch delay slot (remember those from MIPS?). There are hardware loop counters — `loop_begin` and `loop_end` instructions — that allow zero-overhead looping over fixed iteration counts, which is critical for the tight inner loops that PIM kernels tend to have. The memory instructions load and store 32-bit words to and from the local DRAM, with a notable limitation: loads have a multi-cycle latency (roughly 100 cycles) and there is no automatic prefetching. The programmer — or the compiler — must schedule loads well in advance of their use, interleaving independent instructions to hide latency.

The inter-DPU communication mechanism is a message-passing system based on a credit-based flow control. Each DPU has a fixed number of outgoing message buffers (typically 16). To send a message to another DPU, you write the destination DPU ID and the data to a special memory-mapped register; the hardware takes care of routing the message through the on-DIMM interconnect. The receiving DPU must have posted a receive buffer ahead of time. Messages are 32 bytes (8 words) each, and the network provides in-order delivery between any pair of DPUs but no global ordering guarantees. If you have ever worked with MPI, the semantics will feel familiar; if you have not, just remember that the programmer is responsible for ensuring that sends and receives are properly matched, and that deadlocks — two DPUs each waiting for the other to send — are very much possible and very much your problem.

One of the most striking aspects of UPMEM's design is that the DPUs are fabricated on a DRAM process, not a logic process. This is both a strength and a limitation. The strength is cost: DRAM processes are optimized for density and leakage, not performance, which means UPMEM can pack 2,048 DPUs onto a single DIMM at a price point that is competitive with standard server DRAM — roughly a 2-3× premium over equivalent-capacity vanilla DDR4. The limitation is that the DPUs are slow by logic standards. A 350 MHz in-order 32-bit RISC core running on a DRAM process is not going to win any SPEC benchmarks. The point is not the per-core performance, though; the point is the aggregate. 40,000 cores running at 350 MHz deliver a theoretical 14 trillion instructions per second at a power envelope of roughly 200-300 watts for the DIMMs alone — plus the host CPU. For embarrassingly parallel, memory-bound workloads, that aggregate throughput, combined with the internal DRAM bandwidth, can be transformative.

## 3. Samsung HBM-PIM: Accelerators in the Stack

If UPMEM represents the general-purpose, programmability-first approach to PIM, Samsung's HBM-PIM represents the domain-specific, performance-first approach. Announced in 2021 and demonstrated in customer systems by 2022, HBM-PIM integrates programmable processing units — which Samsung calls PCU (Programmable Computing Units) — directly into the logic die at the base of each HBM stack. Each PCU is a 16-wide SIMD unit operating at 300 MHz, capable of executing integer and floating-point operations. Since HBM stacks already sit right next to the GPU or accelerator die on a silicon interposer, the addition of compute to the HBM logic die creates a two-level compute hierarchy: the main GPU/accelerator for heavy lifting, and the HBM-embedded PCUs for memory-intensive operations that would otherwise be bottlenecked by the interposer bandwidth.

This architectural choice has profound implications. In the UPMEM model, data flows from the host CPU to the DIMMs, gets processed in place, and results flow back — the DIMMs are on the far side of a DDR bus. In the Samsung model, the PIM compute is inside the same package as the main accelerator, sharing the same silicon interposer. The latency between the main accelerator and the PIM units is measured in tens of nanoseconds rather than the hundreds of nanoseconds of a DDR round trip. But the PIM units themselves are less flexible than UPMEM's DPUs — they are SIMD lanes, not independent cores, and they are programmed through a library-based API rather than a general-purpose compiler toolchain.

Let us look at the physical organization:

```
    +============================================================+
    |                    HBM Stack with PIM                       |
    |                                                            |
    |  +-------------------+  +-------------------+              |
    |  | DRAM Die 8        |  | DRAM Die 8        |   ... 8-Hi   |
    |  | (8 Gb)            |  | (8 Gb)            |     stack    |
    |  +---------+---------+  +---------+---------+              |
    |            |                     |                          |
    |  +---------+---------+  +---------+---------+              |
    |  | DRAM Die 4        |  | DRAM Die 4        |              |
    |  | (8 Gb)            |  | (8 Gb)            |              |
    |  +---------+---------+  +---------+---------+              |
    |            |                     |                          |
    |  +---------+---------+  +---------+---------+              |
    |  | DRAM Die 0        |  | DRAM Die 0        |              |
    |  | (8 Gb)            |  | (8 Gb)            |              |
    |  +---------+---------+  +---------+---------+              |
    |            |                     |                          |
    |  +---------+---------+  +---------+---------+              |
    |  |    Logic Die      |  |    Logic Die      |              |
    |  | +----+ +----+     |  | +----+ +----+     |              |
    |  | |PCU0| |PCU1|     |  | |PCU0| |PCU1|     |              |
    |  | +----+ +----+     |  | +----+ +----+     |              |
    |  |   DRAM PHY + PHY  |  |   DRAM PHY + PHY  |              |
    |  +---------+---------+  +---------+---------+              |
    |            |                     |                          |
    +============|=====================|==========================+
                 |                     |
          +------v---------------------v------+
          |        Silicon Interposer         |
          +------|---------------------|------+
                 |                     |
          +------v------+       +------v------+
          | GPU/Accel    |       | GPU/Accel   |
          | Die 0        |       | Die 1       |
          +--------------+       +--------------+
```

Each PCU has its own register file, instruction memory, and a set of ALUs that operate in lockstep as a SIMD unit. The PCU can read from and write to the DRAM dies above it through the through-silicon vias (TSVs) that already connect the logic die to the memory dies. This is the key insight: the TSVs provide staggering internal bandwidth — roughly 1 TB/s per stack — but that bandwidth is only usable if you have logic on the logic die that can consume or produce data at that rate. A standard HBM stack has no such logic; all data must traverse the interposer to the GPU before any computation happens. With HBM-PIM, the PCUs can consume data at hundreds of GB/s right where it lives, producing much smaller result sets that then traverse the interposer back to the GPU.

Samsung's target workloads for HBM-PIM reveal the design philosophy. The canonical use case is a neural network layer that is bandwidth-bound: think of a fully-connected layer with a large weight matrix that is accessed exactly once per forward pass. In a conventional GPU, the weight matrix must be read from HBM across the interposer into the GPU's register file, the multiply-accumulate happens, and the activations are written back. The interposer bandwidth — typically 1.6-3.2 TB/s for a high-end HBM2e or HBM3 configuration — is the bottleneck. With HBM-PIM, the weight matrix lives in the HBM stack right above the PCU. The GPU sends the input activations to the PCU (a small transfer, since activations are much smaller than weights), the PCU performs the matrix-vector multiply locally at full TSV bandwidth, and only the output activations — again, a small transfer — come back across the interposer. The interposer bandwidth utilization drops by an order of magnitude for the same computational throughput.

Samsung reports that for the GEMV (general matrix-vector multiply) kernel — the computational core of inference — HBM-PIM delivers roughly 2× speedup and 70% energy reduction compared to a conventional HBM configuration. For training, the benefits are more nuanced because training requires writing updated weights back to memory, which creates additional data movement. But even there, gradient accumulation can be offloaded to the PCUs, reducing the amount of data that must cross the interposer.

The programming model for HBM-PIM is deliberately constrained. Samsung provides a library — akin to cuBLAS or oneDNN — that exposes PIM-accelerated versions of common operations: GEMV, reduction, element-wise operations. The programmer (or, more commonly, the ML framework) calls these library functions, and the runtime decides whether to dispatch to the GPU or to the PIM units based on the operation size and the current system state. There is no public low-level ISA documentation for the PCU, and there is no equivalent of UPMEM's C compiler that would let you write arbitrary kernels. This is a feature, not a bug, from Samsung's perspective: it dramatically simplifies the programming challenge and ensures that the PIM units are used only for the workloads for which they were designed.

But it also limits the scope of what HBM-PIM can do. The PCUs are SIMD units; they are good at dense linear algebra but poor at irregular, pointer-chasing workloads. They cannot run a database hash join, a graph traversal, or a sparse matrix-vector multiply with arbitrary sparsity patterns — at least not efficiently. UPMEM's DPUs, despite being slower per core, can theoretically handle any of these because they are fully programmable. This is the fundamental tension in PIM design: generality versus efficiency, programmability versus performance.

## 4. The Programming Model Problem

We have hinted at this throughout the discussion, but it deserves its own section: programming PIM systems is hard. Not incrementally hard like learning a new library or a new language; fundamentally hard like learning to think about parallelism in a dimension you did not previously know existed.

The root of the difficulty is that PIM introduces a new axis of heterogeneity. Modern systems are already heterogeneous: CPUs with multiple core types (P-cores and E-cores in Alder Lake, for instance), GPUs with different levels of the memory hierarchy, FPGAs with custom datapaths. PIM adds yet another axis: compute that is colocated with specific memory regions, with varying degrees of programmability, and with memory access costs that are radically non-uniform.

In a UPMEM system, the following operations have radically different costs:

- Accessing a DPU's own WRAM (scratchpad): 1 cycle, ~0.02 nJ
- Accessing a DPU's own DRAM: ~100 cycles, ~0.5 nJ per byte
- Sending a message to a DPU on the same chip: ~200 cycles, ~1 nJ per byte
- Sending a message to a DPU on a different chip on the same DIMM: ~500 cycles
- Accessing host DRAM from a DPU: not directly possible; requires message to host

For comparison, accessing host DRAM from the host CPU takes about 100 ns (roughly 400 cycles on a 4 GHz CPU) and costs about 2,000 pJ for a 64-bit load. The DPU's local DRAM access is actually higher latency in cycles (100 cycles at 350 MHz ≈ 285 ns) but much cheaper in energy because the data stays on-chip. The programmer must reason about all of these numbers — or at least their relative magnitudes — to get good performance.

The UPMEM toolchain provides some help. The DPU compiler, based on LLVM, supports a restricted subset of C with some extensions for the DPU's specific features. You write a function, annotate it with `__mram_ptr` and `__dma_aligned` attributes to manage DRAM access patterns, and compile it to DPU machine code. The host-side API uses a familiar offload model:

```c
    // Host side (x86)
    struct dpu_set_t set;
    DPU_ASSERT(dpu_alloc(NR_DPUS, NULL, &set));
    DPU_ASSERT(dpu_load(set, "my_kernel", NULL));

    // Copy input data to DPU DRAM
    // ... (simplified; actual API involves buffer management)

    DPU_ASSERT(dpu_launch(set, DPU_SYNCHRONOUS));

    // Copy results back
    // ...
```

The DPU-side kernel looks like this:

```c
    // DPU side (DPU ISA)
    #include <mram.h>
    #include <defs.h>

    __mram_noinit uint32_t input[INPUT_SIZE];
    __mram_noinit uint32_t output[OUTPUT_SIZE];
    __host uint32_t num_elements;

    int main() {
        // Transfer from MRAM to WRAM for processing
        uint32_t local_buffer[CHUNK_SIZE];
        mram_read(&input[task_id * CHUNK_SIZE], local_buffer, CHUNK_SIZE * 4);

        // Process locally
        for (int i = 0; i < CHUNK_SIZE; i++) {
            local_buffer[i] = compute(local_buffer[i]);
        }

        // Write back to MRAM
        mram_write(local_buffer, &output[task_id * CHUNK_SIZE], CHUNK_SIZE * 4);

        return 0;
    }
```

The `mram_read` and `mram_write` functions trigger DMA transfers between the DPU's local DRAM (MRAM in UPMEM terminology) and the WRAM scratchpad. The programmer is responsible for double-buffering to overlap computation with memory transfers — the DPU has no automatic prefetching. This is not unlike programming a Cell processor's SPEs or a GPU's shared memory, but with a key difference: the DPU is not a coprocessor that you offload to occasionally; it is where your data lives. If you partition your data poorly, you pay a latency penalty on every access. If you partition it well, you achieve near-peak throughput. The gap between those two outcomes can be 10× or more.

## 5. Workloads That Benefit — and Workloads That Don't

Not every workload is suitable for PIM. In fact, most are not. PIM shines when the computation is memory-bound and the data access pattern is regular enough that you can partition data across PIM units without excessive cross-unit communication. This section surveys the landscape.

**Clear winners:**

1. **Sparse matrix-vector multiply (SpMV).** This is the computational kernel behind PageRank, iterative linear solvers, and a wide range of graph algorithms. The matrix is sparse — typically 99%+ zeros — which means the arithmetic intensity is very low (a handful of FLOPs per nonzero). The matrix is also large, often exceeding cache size by orders of magnitude. In a conventional system, SpMV is almost perfectly memory-bound. On UPMEM, you can partition the matrix rows across DPUs, store them in the local DRAM, and have each DPU compute its portion of the output vector. The inter-DPU communication is limited to occasional reductions. Speedups of 10-20× over optimized CPU implementations have been reported.

2. **Genomic sequence alignment.** Algorithms like BWA-MEM and minimap2 spend most of their time comparing short DNA sequences (reads) against long reference genomes. The reference genome is large (3 GB for human) and accessed with poor locality. On UPMEM, you can broadcast each read to all DPUs, each of which holds a chunk of the reference genome in its local DRAM, and let them all search in parallel. The output is a small set of alignment positions per read — minimal write-back traffic.

3. **Neural network inference (HBM-PIM).** As discussed, the GEMV kernel at the heart of transformer inference is a sweet spot for Samsung's architecture. With model sizes now routinely in the hundreds of billions of parameters, the weight matrices are so large that even HBM bandwidth becomes the bottleneck. HBM-PIM effectively moves the multiply-accumulate to the weights rather than moving the weights to the multiply-accumulate.

4. **Database operations.** Hash joins, aggregations, and filters on columnar data can benefit enormously from PIM. In a hash join, you build a hash table on one relation and probe it with the other. The probe phase is memory-bound: for each tuple in the probe relation, you look up a hash bucket in the build relation. Partitioning the build relation across DPUs (one hash partition per DPU) allows the probe to fan out across all DPUs in parallel. The TPC-H benchmark — the industry standard for database performance — has several queries that are dominated by hash joins and aggregations that fit this pattern.

**Mixed results:**

1. **Dense matrix-matrix multiply (GEMM).** This is the canonical HPC workload and the foundation of deep learning training. On paper, it seems like a perfect PIM candidate: huge data, regular access pattern. In practice, GEMM is compute-bound, not memory-bound, when properly tiled and executed on a modern GPU. The arithmetic intensity of GEMM is \(O(N)\) — the number of operations grows as \(N^3\) while the data grows as \(N^2\). For large N, you are compute-bound even on a GPU with 312 TFLOPS and 2 TB/s. PIM's bandwidth advantage does not help when bandwidth is not the bottleneck. The exception is when the matrices are small enough that the GPU cannot fill its pipelines; then PIM can help, but this is a niche case.

2. **Stencil computations.** These — common in computational fluid dynamics and climate modeling — access data in a regular pattern but with overlapping neighborhoods. A 7-point 3D stencil reads each grid point once for each of its 7 neighbors, meaning each point is read 7 times. The arithmetic intensity is low (a few FLOPs per byte), which suggests PIM would help. The challenge is that neighboring grid points may live on different DPUs, requiring communication across the DPU network. The ghost zone exchange — the data each DPU needs from its neighbors — can become the bottleneck. Whether PIM wins depends on the stencil size, the network topology, and the relative bandwidth of the DPU network versus the host's memory bus.

**Clear losers:**

1. **Pointer-chasing workloads.** Graph traversal with unpredictable edge distributions, sparse matrix factorization with dynamic pivoting, any code with unpredictable indirect branches — these all require low-latency access to data scattered across memory. A DPU running at 350 MHz with a 100-cycle DRAM access latency cannot hide the latency of chasing pointers; there is too little independent work to interleave. A modern out-of-order CPU with sophisticated prefetchers and a deep ROB (reorder buffer) does much better on these workloads.

2. **Compute-bound workloads.** If your code is limited by the speed of the arithmetic units rather than by memory bandwidth — think of Linpack, FFT, or molecular dynamics with a good neighbor list — PIM adds nothing because the bottleneck is not memory. In fact, PIM can make things worse because the DPUs are slower per-core than a modern CPU core.

3. **Small data.** If your working set fits in the CPU's L3 cache, the memory wall is not affecting you. PIM's advantages only manifest when data is large enough that it cannot be cached effectively.

## 6. The UPMEM vs. Samsung Design Space

Having described both architectures, we can now map the design space they occupy. The axes that matter are: programmability, per-unit performance, memory density, energy efficiency, and target workload generality.

UPMEM prioritizes programmability and generality. The DPUs are full-fledged cores with a C compiler and a standard offload programming model. You can run arbitrary code on them — subject to the limitations of a 32-bit in-order core with no FPU (the DPU lacks hardware floating-point; floating-point must be emulated in software, which is slow). The memory density is high because UPMEM chips coexist with standard DRAM chips on a DIMM; a system can have terabytes of PIM-capable memory. The tradeoff is per-unit performance: 350 MHz in-order cores on a DRAM process are not fast by CPU standards. UPMEM wins when you have a large, memory-bound, embarrassingly parallel workload that does not require heavy floating-point or complex control flow.

Samsung HBM-PIM prioritizes performance and energy efficiency for a specific workload domain. The PCUs are SIMD units with hardware floating-point, operating at high bandwidth directly on the TSVs. They deliver excellent performance on dense linear algebra at very low energy. The tradeoff is programmability (library-only API) and limited memory capacity (HBM stacks are measured in gigabytes, not terabytes). Samsung wins when you are training or running inference on large neural networks and you need every last FLOP and every last watt optimized.

Could these two approaches converge? Possibly. The natural evolution is for UPMEM to add more capable DPUs — perhaps with floating-point units and wider SIMD — as DRAM process technology improves, and for Samsung to expose more programmability as the toolchain matures. But there are fundamental tensions: DRAM processes will never match logic processes for per-transistor performance, and HBM stacks will never match DIMMs for cost-per-bit. The two approaches may remain complementary for the foreseeable future.

## 7. Related Work and Historical Context

PIM has a surprisingly rich history. The idea predates not just UPMEM and Samsung but the entire modern semiconductor industry. The earliest reference I can find is a 1970 paper by Harold Stone titled "A Logic-in-Memory Computer," which proposed embedding simple logic gates within magnetic core memory — yes, core memory — to perform associative searches. The idea resurfaced periodically: in the early 1990s with the EXECUBE and Terasys projects, in the early 2000s with the UC Berkeley IRAM (Intelligent RAM) project led by David Patterson, and in the late 2000s with the Micron Automata processor, a non-von-Neumann architecture designed for pattern matching in DRAM.

Why did all of these fail commercially? The primary reason is that, until recently, the memory wall was not a critical problem for most commercially relevant workloads. When Dennard scaling was still delivering annual improvements in both transistor density and frequency, you could simply wait 18 months and your memory bandwidth problem would be solved by a faster DRAM standard. The secondary reason is that manufacturing logic on a DRAM process — or DRAM on a logic process — has historically been economically nonviable. DRAM fabs and logic fabs use different process technologies optimized for different goals. Putting them together on one chip meant compromising one or both, which meant worse economics than simply buying a separate CPU and DRAM.

What changed? Three things. First, the end of Dennard scaling around 2006 meant that CPU frequency stopped improving, and the only path to higher performance was more cores, which put more pressure on the memory subsystem. Second, the rise of data-intensive workloads — machine learning, graph analytics, genomics — created a market for architectures that could process data where it lives. Third, and perhaps most importantly, the semiconductor industry figured out how to manufacture logic on DRAM processes at acceptable cost. UPMEM's secret sauce is not a clever ISA or an innovative programming model; it is the process integration that lets them put 2,000+ working RISC cores on a DRAM DIMM without making the DIMM cost $100,000.

## 8. Performance Analysis and Benchmark Data

Let us ground this discussion with some concrete performance numbers. The following data is drawn from published work by the UPMEM team and independent academic evaluations.

For the STREAM benchmark (the triad: \(c[i] = a[i] + b[i]\)), a single UPMEM DIMM with 2,048 DPUs achieves roughly 300 GB/s of effective memory bandwidth — compared to about 20 GB/s for a single DDR4 channel on a conventional CPU. That is a 15× improvement in bandwidth for the same power envelope. The DPUs are running at about 350 MHz and achieving roughly 50% utilization because the arithmetic is trivial and the bottleneck is the DRAM access. If you extrapolate to a fully populated server with 20 DIMMs, the aggregate bandwidth reaches 6 TB/s — on par with a high-end GPU, but with an order of magnitude more memory capacity (5 TB vs. 80 GB for an H100).

For a genome sequencing pipeline (BWA-MEM, human genome alignment), UPMEM reports a 3.5× speedup over a 28-core Intel Xeon server while consuming 40% less energy. The key insight is that the seeding phase of BWA-MEM — which searches for exact matches between short reads and the reference genome — is embarrassingly parallel and almost perfectly memory-bound. Each DPU searches its local chunk of the reference genome independently, with no inter-DPU communication during the search.

For a graph processing workload (PageRank on a scale-free graph with 4 billion edges), UPMEM achieves roughly 8 GTEPS (giga traversed edges per second) on a single server with 20 DIMMs. A comparable Xeon server with 2 sockets (56 cores) achieves about 2 GTEPS. The factor of 4× comes from the fact that PageRank is almost entirely driven by random access to the graph structure, and the UPMEM DIMMs provide much higher effective random-access throughput than a CPU's cache hierarchy.

For HBM-PIM, Samsung's published numbers for GEMV (FP16, matrix size 8192×8192) show 1.5 TFLOPS per HBM stack, compared to about 0.8 TFLOPS for the same HBM stack without PIM. The 1.9× speedup is modest, but the energy reduction — 70% — is transformative for data center operators for whom power is often the binding constraint.

What these numbers suggest is that PIM is not a panacea. It does not make every workload faster. But for the specific class of memory-bound, data-parallel computations that increasingly dominate the data center, it offers a path around the memory wall that is both practical and economically viable.

## 9. The Road Ahead: Open Problems and Research Directions

Despite the commercial progress, PIM remains a research-rich area with fundamental open problems. Here are some of the most important ones.

**The programming model.** We have talked about this, but it bears repeating: programming 40,000 heterogeneous cores with non-uniform memory access and explicit communication is not something most programmers can do well. The UPMEM toolchain helps, but it is still at the level of CUDA circa 2008 — functional, but requiring deep architectural knowledge to achieve good performance. What would a high-level programming model for PIM look like? Perhaps something like the PGAS (Partitioned Global Address Space) model used in Chapel and UPC, where the programmer specifies data distributions and the runtime handles communication. Or perhaps something like Halide or TVM for tensor computations, where the programmer specifies the computation and the compiler automatically tiles, distributes, and schedules it across PIM units. This is an active area of research, and the answer will probably depend on the workload domain.

**Data placement.** Even with a good programming model, the physical placement of data across PIM units has first-order performance implications. If two DPUs that need to communicate frequently are placed on different DIMMs, the communication cost is much higher than if they are on the same chip. The data placement problem — how to map logical data partitions to physical DPUs to minimize communication cost — is NP-hard in general (it reduces to graph partitioning). Practical heuristics exist but are brittle across workload and scale.

**Consistency and coherence.** Current PIM systems are not cache-coherent with the host CPU. If the host and a DPU both access the same memory region, the programmer is responsible for ensuring consistency — typically by having the host wait for the DPU to finish before reading the results. This is manageable for the batch-oriented workloads that PIM currently targets, but it precludes more dynamic, interactive uses. Adding hardware cache coherence between the PIM units and the host would be enormously complex and power-hungry; adding software coherence through something like versioned memory regions is more plausible but still challenging.

**Fault tolerance.** With 40,000 DPUs in a single server, the probability that at least one DPU experiences a transient fault (a bit flip due to an alpha particle, for instance) during a long-running computation is high. UPMEM does not currently provide hardware ECC on the DPU-side memories. For scientific computing workloads that run for hours or days, this is a real concern. Techniques like algorithm-based fault tolerance — where the algorithm itself includes redundancy that can detect and correct errors — are one approach, but they increase the computational cost and complicate the programming model.

**Security.** PIM opens a new attack surface. If a malicious workload can run code on the DPUs, can it read or modify data belonging to other workloads? The current UPMEM model assumes a single user per DIMM (or a trusted set of users), but in a cloud environment, this assumption does not hold. Providing memory isolation between DPUs — essentially, a PIM-level equivalent of virtual memory — is an open problem with hardware, software, and performance dimensions.

## 10. Summary

Processing-in-memory is not a new idea, but it is an idea whose time has finally arrived. The end of Dennard scaling, the rise of data-intensive workloads, and the maturation of DRAM-logic process integration have converged to make PIM commercially viable for the first time. UPMEM and Samsung represent two distinct points in the design space — general-purpose DRAM-scale PIM versus domain-specific HBM-scale PIM — and both are shipping products with demonstrated performance benefits for real workloads.

The programming model remains the biggest obstacle to widespread adoption. Programming thousands of tiny cores with non-uniform memory access is hard, and the toolchains — while functional — are not yet mature enough to make it easy. But this is a solvable problem, and the research community is actively working on it.

If I had to make a prediction: within five years, PIM will be a standard feature of high-end servers and accelerators, in the same way that GPUs went from niche graphics processors to essential compute engines. The memory wall is not going away. PIM is the most plausible way through it. And for researchers and engineers who invest in understanding the architecture and the programming model now, the payoff will be the ability to run computations at scales and speeds that conventional architectures simply cannot match.

The von Neumann bottleneck has defined computing for eighty years. We are finally, tentatively, beginning to move beyond it.
