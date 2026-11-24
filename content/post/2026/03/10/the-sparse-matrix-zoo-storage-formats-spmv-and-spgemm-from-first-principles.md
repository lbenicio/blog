---
title: "The Sparse Matrix Zoo: Storage Formats, SpMV, and SpGEMM from First Principles"
description: "A deep, implementation-oriented tour of sparse linear algebra on modern hardware: why sparse kernels behave nothing like dense ones, how COO, CSR, ELL, SELL-C-sigma, DIA, and block formats trade memory for regularity, how SpMV hits the memory wall, why SpGEMM is really an allocation problem, and how to measure all of it honestly."
date: "2026-03-10"
author: "Leonardo Benicio"
tags: ["sparse-matrices","hpc","parallel-computing","performance-engineering","numerical-linear-algebra","graph-analytics"]
categories: ["Parallel Computing","Systems Design"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/the-sparse-matrix-zoo-storage-formats-spmv-and-spgemm-from-first-principles-2026-03-10.jpg"
coverAlt: "An isometric editorial illustration of a surreal zoo where each enclosure visualizes a different sparse matrix storage format as glowing dot patterns, grids, diagonals, and blocks, with data streams flowing through CPU/GPU memory and multiplication machinery."
---

# The Sparse Matrix Zoo: Storage Formats, SpMV, and SpGEMM from First Principles

## 1. Why sparse is a different game

Dense linear algebra has a comfortable property: the cost of an operation is predictable from the dimensions alone. Multiplying two dense n-by-n matrices performs on the order of n cubed floating-point operations and touches on the order of n squared memory locations, and every one of those locations is touched. Performance engineering for dense kernels is therefore mostly about keeping the arithmetic units fed: block for cache, vectorize, use the widest fused multiply-add units available, and let the hardware do the rest. The arithmetic intensity of a blocked dense GEMM is high enough that a well-tuned implementation can approach the machine's peak floating-point throughput rather than its memory bandwidth.

Sparse linear algebra throws away that predictability. A sparse matrix is one in which most entries are zero, and the zeros are not stored. The consequence is that the cost of an operation depends not on the dimensions of the matrix but on the number and the distribution of its nonzeros. Two matrices with identical dimensions can differ in cost by orders of magnitude, and, more insidiously, two matrices with identical nonzero counts can differ in achieved performance by a large factor because of how the nonzeros are arranged.

This is not a cosmetic difference. It changes the entire shape of the engineering problem. In dense code, the question is how to increase arithmetic intensity until you are compute bound. In sparse code, the question is usually how to reduce the number of bytes you must move per useful floating-point operation, because you are almost always memory bound, and the indirect addressing patterns that sparse data forces on you defeat the prefetchers and the cache hierarchies that make dense code fast.

There is a second, subtler difference. Sparse kernels are usually *irregular*: the amount of work per row, per column, or per block varies wildly across the matrix. Irregular work means load imbalance, and load imbalance means that a parallel algorithm's runtime is set by the slowest participant rather than by the average. A sparse kernel that is perfectly balanced in the aggregate can still lose most of its parallelism to a handful of dense rows.

The purpose of this article is to build a working mental model of sparse linear algebra as it is actually practiced on CPUs and GPUs. We will start with vocabulary and the graph view of a matrix, then survey the storage formats that make up the sparse matrix zoo and the trade-offs that distinguish them. We will then examine the two kernels that dominate the field: sparse matrix-vector multiplication (SpMV), which is the workhorse of iterative solvers and graph analytics, and sparse matrix-matrix multiplication (SpGEMM), which is the workhorse of algebraic multigrid setup, graph clustering, and sparse neural network layers. Along the way we will look at sparse triangular solve, semiring generalizations, and the practical business of measuring these kernels without fooling ourselves.

Everything here is grounded in mechanisms rather than in measured numbers. Where I give a figure, it is derived from first principles, such as the number of bytes a format must move per nonzero. I will not quote benchmark results, because benchmark results depend on the machine, the matrix, the compiler, and the day, and a number quoted out of context is worse than no number at all.

## 2. Vocabulary and the graph view

Before formats, we need precise vocabulary.

The **nonzero count**, usually written nnz, is the number of stored entries. It is the fundamental unit of cost in sparse computation: almost every sparse algorithm's time and space are expressed in terms of nnz rather than in terms of the matrix dimensions.

The **sparsity pattern** or **structure** of a matrix is the set of positions that are stored, independent of their numerical values. Two matrices can share a structure and differ in values. This distinction matters because many algorithms have a *symbolic* phase that depends only on structure and a *numeric* phase that depends on values, and the symbolic phase can be reused across many numeric factorizations.

**Fill-in** is the appearance of new nonzeros during a factorization or elimination. Gaussian elimination on a sparse matrix generally produces more nonzeros than the original matrix had, and the amount of fill depends dramatically on the order in which rows and columns are eliminated. Fill-in is the reason sparse direct solvers spend enormous effort on reordering, and it is the reason that a matrix which fits comfortably in memory as a system may not fit at all as a factorization.

**Bandwidth** and **profile** are measures of how far nonzeros sit from the diagonal. A banded matrix has all nonzeros within a fixed distance of the main diagonal. Bandwidth is relevant because banded and profile formats can exploit it, and because reordering algorithms such as reverse Cuthill-McKee exist specifically to reduce it.

**Hypersparsity** describes matrices with so few nonzeros per row that storing a full row pointer for every row would waste more space than the data itself. A matrix with a million rows and a thousand nonzeros is hypersparse. Hypersparse matrices require formats that store only the nonempty rows, usually as a list of (row index, row) pairs.

Now the graph view, which is the single most useful reframing in the field. An m-by-n sparse matrix A corresponds to a bipartite graph with m row vertices and n column vertices, and an edge from row i to column j for every stored entry A(i,j). If the matrix is square and structurally symmetric, this collapses to a directed graph on n vertices, with an edge i to j whenever A(i,j) is nonzero, and to an undirected graph if the structure is symmetric.

Under this correspondence, a great deal of linear algebra becomes graph traversal. Multiplying a matrix by a vector is a step of neighbor aggregation. Solving a triangular system is a traversal in dependency order. Computing A times A is path enumeration of length two. The nonzero structure of a Cholesky factor is a chordal completion of the graph. Fill-in minimization is a graph elimination ordering problem. Preconditioners are approximate graph summaries.

This correspondence is not merely aesthetic. It is why the same kernels appear in finite element solvers, social network analysis, and machine learning, and it is why GraphBLAS exists as a standardization effort: it takes the sparse matrix as the fundamental object and expresses graph algorithms as linear algebra over semirings, which we will return to in Section 7.

## 3. The storage formats

There is no single best sparse format. There is a zoo, and the animals in it are adapted to different niches. The organizing tension is always the same: **regularity versus compactness**. A regular format is one whose memory access pattern is predictable and vectorizable, which is what the hardware wants. A compact format is one that stores exactly the nonzeros and nothing else, which is what the memory system wants. You can have one or the other, and sometimes a carefully chosen compromise.

### 3.1 Coordinate format (COO)

The coordinate format, also called triplet format, is the simplest possible representation: three parallel arrays of row indices, column indices, and values, one entry per nonzero.

```cpp
struct Coo {
  std::vector<int>    row;   // size nnz
  std::vector<int>    col;   // size nnz
  std::vector<double> val;   // size nnz
};
```

COO is the format you use while *building* a matrix, not the format you use while *computing* with one. Its virtues are that appending is trivial, that the ordering of entries is irrelevant, and that duplicate entries are permitted and can simply be summed later. Its vice is that it stores an explicit row index for every nonzero, which is pure overhead once the matrix is finished, and that it offers no structure for a kernel to exploit: to process row i you must scan the entire array.

COO is therefore a staging format. The standard workflow is to accumulate entries in COO, then convert once to a compressed format. The conversion is a counting sort by row index, followed by an optional in-row sort and duplicate summation.

### 3.2 Compressed sparse row and column (CSR and CSC)

CSR is the default. It stores three arrays: a row pointer array of length m+1, a column index array of length nnz, and a value array of length nnz. The nonzeros of row i occupy the half-open range from `row_ptr[i]` to `row_ptr[i+1]`, and `row_ptr[m]` equals nnz.

```cpp
struct Csr {
  int m = 0, n = 0;
  std::vector<int>    row_ptr;   // size m+1
  std::vector<int>    col_idx;   // size nnz
  std::vector<double> val;       // size nnz
};
```

CSR is compact: it stores one index per nonzero plus one pointer per row, and the pointer cost is negligible for any matrix with more than a few nonzeros per row. It supports row-wise traversal with perfect locality along the value and index arrays, and it supports the row-oriented algorithms that dominate iterative solvers.

Its weaknesses are equally clear. Random access to a single entry A(i,j) requires a binary search within row i, which is logarithmic in the row length. Inserting a new nonzero requires shifting the tail of the arrays. And the row pointer array imposes a serial dependency on parallel traversal: to find where row i starts, you must have already read `row_ptr[i]`, which is fine for a scan but awkward for fine-grained dynamic work distribution.

CSC is CSR applied to the transpose: a column pointer array, row indices, and values. CSR and CSC are not different formats so much as different orientations of the same format, and converting between them is a transpose, which we will write in Section 9.

A note on index width. Using 32-bit indices halves the index traffic relative to 64-bit indices, and index traffic is often a large fraction of total traffic in SpMV. For matrices with fewer than roughly two billion nonzeros, 32-bit indices suffice, and using them is one of the highest-leverage micro-optimizations available. The cost is that you must handle overflow carefully when computing `row_ptr[m]` and when indexing into arrays with a 32-bit offset.

### 3.3 Diagonal and banded formats (DIA)

If a matrix is banded, you can store it as a set of diagonals. DIA stores an array of shape (number of diagonals) by (m), where each row of the array is one diagonal, offset from the main diagonal, with unused positions padded.

DIA is extremely regular: accessing diagonal d at row i is a single affine index computation, which vectorizes beautifully. For genuinely banded matrices, such as those arising from finite difference discretizations of simple partial differential equations on structured grids, DIA is close to ideal.

For anything else, DIA is a disaster. The padding is proportional to the number of diagonals times the number of rows, so a matrix with a few very long diagonals and a few very short ones wastes enormous amounts of memory. The format has no way to skip a diagonal position that is structurally zero. DIA is the clearest example of the regularity-versus-compactness trade-off: it buys perfect access regularity at the cost of storing zeros.

### 3.4 ELLPACK and its relatives

ELLPACK, usually called ELL, takes a different approach to regularity. It pads every row to the same length, namely the maximum number of nonzeros in any row, and stores the result as two dense rectangular arrays: one of column indices and one of values. Padded positions are marked with a sentinel column index (typically zero) and a zero value, so that the multiply-accumulate contributes nothing.

The critical implementation detail is the memory layout. Storing the arrays as `val[row][slot]` is wrong for vectorization, because consecutive rows are far apart in memory. The correct layout is `val[slot][row]`, so that for a fixed slot index, consecutive rows are contiguous. A SIMD kernel then processes a vector of rows at the same slot, gathering the corresponding x values and accumulating into a vector of partial sums. This is the classic ELL SpMV kernel, and its access pattern is exactly what a vector unit wants: contiguous loads of values and column indices, and a gather of x.

ELL's weakness is the padding. If row lengths vary widely, the padding is proportional to the difference between the maximum and the average row length, which can be enormous. A single dense row in an otherwise sparse matrix makes ELL store a full dense matrix. This is a real and common pathology, and it is the reason for the next two formats.

### 3.5 Sliced ELL (SELL-C-sigma)

Sliced ELL attacks the padding problem by not padding the whole matrix at once. Instead, it partitions the rows into slices of C consecutive rows, and pads each slice independently to the maximum row length *within that slice*. The parameter C controls the granularity of the trade-off: large C gives long, regular inner loops but more padding, small C gives less padding but shorter loops and more per-slice overhead.

The sigma in SELL-C-sigma refers to sorting: before slicing, rows are sorted by length, so that rows of similar length end up in the same slice and the per-slice padding is small. Sorting by length is a permutation of the rows, which is fine as long as you also permute the output vector consistently, or permute back at the end.

The choice of C is dictated by the vector width. For a CPU with a 256-bit vector unit holding four doubles, C is typically a multiple of four. For a GPU, C is typically a multiple of the warp size, so that a warp processes one slice position at a time. SELL-C-sigma is a genuinely good compromise format, and it is widely used in practice for matrices with moderately irregular row lengths.

### 3.6 Block formats (BSR and BCSR)

Many sparse matrices are not merely sparse; they are *block sparse*. This happens whenever the underlying problem has multiple degrees of freedom per node, as in finite element discretizations of elasticity (three or six degrees of freedom per node), in coupled multiphysics, and in certain machine learning models where groups of weights are pruned together.

Block compressed sparse row (BSR) exploits this. The matrix is partitioned into dense blocks of size r by c, and the block structure is stored in CSR form: a block row pointer array, a block column index array, and a value array holding r times c values per stored block. Blocks that are structurally zero are omitted entirely.

BSR is a large win when the block structure is real. The index traffic drops by a factor of r times c, because one index now addresses a whole dense block. The inner kernel becomes a small dense matrix-matrix multiplication, which is exactly the kind of computation that vector units and tensor cores are designed for. And the access pattern within a block is fully regular.

The cost is that BSR stores zeros inside blocks that are only partially dense. If the block density is low, BSR wastes memory. The standard remedy is to choose the block size adaptively, or to use a hybrid where dense blocks are stored in BSR and the remaining stray nonzeros are stored separately in COO or CSR. This hybrid is exactly what the next format does.

### 3.7 Hybrid formats and CSR5

The hybrid format (HYB) is a direct response to the ELL padding problem. It splits each row into two parts: the first k nonzeros of every row go into an ELL array, and any nonzeros beyond k go into a COO array. The ELL part captures the regular bulk of the matrix with a fixed, tunable amount of padding, and the COO part captures the irregular tail without any padding at all. Choosing k as roughly the median row length is a common heuristic. HYB is a pragmatic format that handles the wide-row-length distributions that appear in real finite element and circuit simulation matrices.

CSR5 takes a different approach to the same problem. It reorganizes CSR into a two-dimensional tiling: the matrix is divided into tiles of consecutive rows, and within each tile, entries are arranged so that the kernel can process a vector of rows simultaneously. The trick is a bitmask per tile position that records which rows still have entries at that position, allowing the kernel to skip rows that have been exhausted without sorting or padding. This gives vectorized, coalesced access with no padding waste, at the cost of a more complex preprocessing step and a more complex kernel. The general lesson is that you can often get both compactness and regularity if you are willing to spend preprocessing time on a smarter layout.

### 3.8 Choosing a format

Given the zoo, how do you choose? The honest answer is that format selection is a function of the matrix's row-length distribution, the target architecture, and whether the matrix is reused.

A rough decision procedure:

- If the matrix is banded or nearly so, and the bandwidth is small relative to the dimension, use DIA.
- If row lengths are nearly uniform and the maximum is not much larger than the average, use ELL, or SELL-C-sigma if there is moderate variance.
- If there is a clear block structure with high block density, use BSR.
- If row lengths are highly skewed, with a regular bulk and a long irregular tail, use HYB or SELL-C-sigma with a well-chosen slice size.
- Otherwise, use CSR. It is the safest default, it is the format that libraries implement best, and it is the format that most algorithms are written against.

The important point is that the decision is empirical. You can compute the row-length histogram cheaply, and from that histogram you can predict the padding overhead of ELL and SELL-C-sigma exactly, the index overhead of CSR exactly, and the storage of BSR exactly. There is no reason to guess.

### 3.9 Conversion and preprocessing costs

Every format change costs time. Converting COO to CSR is a counting sort, linear in nnz plus the number of rows. Sorting rows by length is a sort of m integers. Building SELL-C-sigma requires the sort plus a per-slice maximum computation. Building BSR requires deciding the block size, which is a nontrivial combinatorial problem if you want to minimize storage.

These costs are amortized in two situations. The first is when the matrix is reused many times, as in an iterative solver that performs thousands of SpMV operations against a fixed matrix. The second is when the matrix is reused across many right-hand sides, as in a direct solver that factorizes once and solves many times. If a matrix is used exactly once, the conversion cost can dominate the kernel cost, and you should use the format you already have.

A related and often-overlooked cost is the *symbolic* cost of factorization and of SpGEMM. In these operations, the structure of the result must be computed before the values can be computed, and the symbolic phase can be more expensive than the numeric phase. We will return to this in Section 5.

## 4. SpMV: the canonical sparse kernel

Sparse matrix-vector multiplication computes y = A x, where A is sparse and x and y are dense. It is the single most important sparse kernel, because it is the inner loop of every Krylov subspace method (conjugate gradient, GMRES, BiCGStab), every power iteration (PageRank, spectral clustering), and every explicit time-stepping scheme for a discretized partial differential equation.

### 4.1 The algorithm and its memory traffic

In CSR, the algorithm is a nested loop. For each row, accumulate the dot product of the row with x.

```cpp
void spmv_csr(const Csr& A, const double* x, double* y) {
  for (int i = 0; i < A.m; ++i) {
    double acc = 0.0;
    for (int k = A.row_ptr[i]; k < A.row_ptr[i + 1]; ++k)
      acc += A.val[k] * x[A.col_idx[k]];
    y[i] = acc;
  }
}
```

Now count the bytes. For each nonzero, we read one value (8 bytes for double) and one column index (4 bytes for a 32-bit index). We also read one element of x, but x is reused across rows, so in the ideal case it is cached and its traffic is amortized. We write one element of y per row, which is 8 bytes per row. And we read one row pointer per row, 4 bytes per row.

So the dominant term is 12 bytes per nonzero, and the floating-point work is two operations per nonzero (one multiply, one add). The arithmetic intensity is therefore about 2 flops per 12 bytes, or roughly 0.17 flops per byte. That is a very low number. A modern CPU core can sustain on the order of tens of flops per cycle, but it can only load on the order of tens of bytes per cycle from main memory. At an intensity of 0.17, the memory system is the bottleneck by a wide margin, and the floating-point units sit idle.

This is the central fact of SpMV: it is a memory-bound streaming kernel that happens to do a little arithmetic along the way. Everything else in SpMV optimization follows from it.

The second fact is that the streaming is not clean. The access to x is a gather: the indices `col_idx[k]` are arbitrary, so the hardware cannot prefetch x effectively. If x is small enough to fit in cache, this is fine. If x is large, each gather is a potential cache miss, and the effective traffic is much higher than the ideal 12 bytes per nonzero. This is why SpMV performance degrades as the matrix dimension grows even when nnz stays fixed.

### 4.2 The roofline for SpMV

It is worth being explicit about the roofline reasoning, because it tells you what to optimize. Plot arithmetic intensity on the horizontal axis and achieved flops per second on the vertical axis. The roofline has two regimes: a sloped region where performance is proportional to intensity (memory bound), and a flat region at the machine's peak (compute bound). The knee is at the machine's balance point, the ratio of peak flops to peak bandwidth.

For SpMV in CSR with double precision and 32-bit indices, the intensity is about 0.17. The machine balance for a typical server core is on the order of ten or more flops per byte. SpMV is therefore far to the left of the knee, deep in the memory-bound region, and the only way to move right is to increase the intensity. There are exactly two ways to do that: reduce the bytes per nonzero, or increase the flops per nonzero.

Reducing bytes per nonzero means using narrower indices, using single precision where accuracy permits, or exploiting structure so that fewer indices are needed per value. Increasing flops per nonzero means processing multiple vectors at once, which is the SpMM case we will discuss shortly, or exploiting block structure so that each index addresses many values.

### 4.3 Row blocking and register blocking

If the matrix has block structure, you can store it in BSR and the intensity improves dramatically. Consider a block of size r by c. The traffic per block is 4 bytes for the block column index plus 8 times r times c bytes for the values, and the work is 2 times r times c flops. The intensity is therefore 2rc / (4 + 8rc) flops per byte, which approaches 0.25 flops per byte as rc grows. That is still low, but it is a real improvement over 0.17, and it comes with a second benefit: the inner computation is a dense small matrix-vector product, which vectorizes.

Even without explicit block structure, you can get some of the benefit by *register blocking* across rows. The idea is to process several rows at once, sharing the gather of x. If four rows are processed together, the x values loaded for one row may be reused by another row if their patterns overlap, and more importantly the loop overhead and the row pointer reads are amortized.

```cpp
void spmv_csr_4x1(const Csr& A, const double* x, double* y) {
  int i = 0;
  for (; i + 4 <= A.m; i += 4) {
    double a0 = 0, a1 = 0, a2 = 0, a3 = 0;
    int b0 = A.row_ptr[i],     e0 = A.row_ptr[i + 1];
    int b1 = A.row_ptr[i + 1], e1 = A.row_ptr[i + 2];
    int b2 = A.row_ptr[i + 2], e2 = A.row_ptr[i + 3];
    int b3 = A.row_ptr[i + 3], e3 = A.row_ptr[i + 4];
    int len = std::max(std::max(e0 - b0, e1 - b1),
                       std::max(e2 - b2, e3 - b3));
    for (int t = 0; t < len; ++t) {
      if (b0 + t < e0) a0 += A.val[b0 + t] * x[A.col_idx[b0 + t]];
      if (b1 + t < e1) a1 += A.val[b1 + t] * x[A.col_idx[b1 + t]];
      if (b2 + t < e2) a2 += A.val[b2 + t] * x[A.col_idx[b2 + t]];
      if (b3 + t < e3) a3 += A.val[b3 + t] * x[A.col_idx[b3 + t]];
    }
    y[i] = a0; y[i + 1] = a1; y[i + 2] = a2; y[i + 3] = a3;
  }
  for (; i < A.m; ++i) {
    double acc = 0.0;
    for (int k = A.row_ptr[i]; k < A.row_ptr[i + 1]; ++k)
      acc += A.val[k] * x[A.col_idx[k]];
    y[i] = acc;
  }
}
```

This kernel has four independent accumulator chains, which gives the out-of-order engine something to overlap, and it amortizes the row pointer reads. The cost is four conditional branches per iteration, which the branch predictor may or may not handle well depending on how correlated the row lengths are. In practice, the benefit is real but modest, because the kernel is still bound by the 12 bytes per nonzero and by the gather latency. Register blocking helps most when it also improves the reuse of x, which requires the rows to have overlapping patterns.

The more aggressive variant is to block both rows and columns, giving a 2D register tile. This is the sparse analogue of the dense GEMM register blocking, and it requires a preprocessing step that groups rows with similar patterns. The gain comes from reusing x values across the rows in the tile, which reduces the effective gather traffic.

### 4.4 Vectorization and the gather problem

On a CPU with SIMD, the natural thing to vectorize is the inner loop over nonzeros within a row. But this loop has a serial dependency: the accumulator is a scalar reduction, and vectorizing a reduction requires either a horizontal reduction at the end or a tree of partial sums.

The bigger obstacle is the gather. The expression `x[A.col_idx[k]]` is a gather, and gather instructions are slower than contiguous loads on most architectures. If the hardware has a gather instruction, it may still be microcoded and slow. If it does not, the compiler must emit scalar loads, which defeats the vectorization.

There are several ways around this. One is to transpose the problem: instead of gathering x, scatter into y. Scatter has the same problem in reverse. Another is to use a format where the inner loop is over rows rather than over nonzeros, which is what ELL does: for a fixed slot, the rows are contiguous, so the values and column indices load contiguously, and only the x gather remains. A third is to sort the nonzeros within each row by column index, which improves the locality of the gather if x is partially cached.

Sorting within rows is a cheap preprocessing step that often pays for itself, and it is worth doing by default. It also enables a merge-based kernel, which we turn to next.

### 4.5 Merge-based SpMV and load balancing

Row-per-thread parallelism has a load balancing problem: if one row has a million nonzeros and the rest have ten, then the thread that gets the dense row determines the runtime. This is not a hypothetical; it happens in real matrices, and it is the reason that naive parallel SpMV can scale poorly even on a machine with many cores.

There are two families of fixes. The first is to split long rows across multiple threads, with each thread computing a partial sum and the partials combined by an atomic add or a second reduction pass. This is easy on GPUs, where atomic adds to global memory are available, but it introduces nondeterminism in the floating-point result, because the order of additions changes. For an iterative solver, that nondeterminism can be acceptable, but for reproducibility it is not.

The second family is merge-based decomposition. Instead of partitioning the rows, partition the nonzeros. Assign each thread a contiguous range of the nnz array, and have each thread walk its range while simultaneously advancing a row cursor. When the thread's range crosses a row boundary, it flushes the accumulator for the completed row and starts a new one. The work per thread is now balanced by construction, because every thread gets the same number of nonzeros, and the memory access is perfectly sequential along the value and index arrays.

The cost of merge-based decomposition is that each thread must determine which row it starts in, which requires a binary search in the row pointer array. This is a small, one-time cost per thread. The benefit is that load balance is guaranteed regardless of the row-length distribution, and the access pattern is as regular as CSR allows. Merge-based SpMV is one of the few techniques that improves both balance and locality at the same time, and it is a good default for GPU implementations.

### 4.6 ELL and block SpMV

In ELL, the kernel is inverted: the outer loop is over slots, and the inner loop is over rows. For each slot, load a vector of column indices and a vector of values, gather the corresponding x entries, and accumulate into a vector of partial sums. At the end, write the partial sums to y. The gather is still there, but everything else is contiguous, and the accumulation is a pure vector operation with no cross-lane dependency until the final reduction.

The padded entries must be neutral. The value is zero, so the multiply contributes nothing, and the column index is a sentinel that points at a valid location in x so that the gather does not fault. Using column index zero is the usual choice, provided that x has at least one element.

For BSR, the inner kernel is a small dense matrix-vector product. For a block of size r by c, you load the r-by-c block, load the c elements of x at the block's column indices, and compute r dot products. If r and c are chosen to match the vector width, this vectorizes cleanly. The block column indices are still a gather, but there are r times c times fewer of them, so the gather cost is amortized over more work.

### 4.7 SpMM and multi-vector kernels

If you multiply a sparse matrix by a dense matrix with k columns rather than a vector, you get SpMM, and the arithmetic intensity improves by roughly a factor of k. The reason is that the index traffic is unchanged (you still read one column index per nonzero), but the value traffic and the flop count both scale with k. The intensity becomes approximately 2k / (4 + 8k) flops per byte, which rises toward 0.25 as k grows and, more importantly, the *useful* work per byte rises without bound in the flop term.

In practice, SpMM with a moderate number of columns is a much better use of the machine than SpMV, and it is the reason that blocked iterative methods, which solve for multiple right-hand sides simultaneously, can be far more efficient per unit of work than their single-vector counterparts. It is also the reason that sparse neural network inference, where the sparse weight matrix multiplies a batch of activations, is more tractable than sparse-vector products would suggest.

The implementation of SpMM is a straightforward generalization: replace the scalar accumulator with a small array of accumulators, one per column of the dense right-hand side, and replace the scalar multiply-accumulate with a loop over the columns. The register pressure grows with k, so there is a limit to how wide you can go before spilling, and the optimal k is a function of the register file size and the block structure.

### 4.8 Symmetric and triangular cases

If the matrix is symmetric, you can store only the lower triangle and compute the product of the full matrix by processing each stored entry twice: once as A(i,j) contributing to y(i), and once as A(j,i) contributing to y(j). This halves the storage and the index traffic, at the cost of a scatter into y, which is less regular than a gather from x. Whether the trade is worth it depends on the machine: scatter is cheap if y fits in cache and the writes coalesce.

Sparse triangular solve, computing x such that L x = b with L lower triangular and sparse, is a different beast entirely, and we will treat it in Section 6, because its parallelism is limited by data dependencies rather than by memory bandwidth.

### 4.9 GPU SpMV

On a GPU, SpMV is usually implemented with one warp per row, or with a merge-based decomposition, or with a format-specific kernel such as ELL or SELL-C-sigma. The design considerations are different from the CPU case in three ways.

First, the memory system is different. GPUs have much higher aggregate bandwidth but much higher latency, and they hide latency through massive thread-level parallelism rather than through out-of-order execution. A kernel that would be latency-bound on a CPU can be bandwidth-bound on a GPU if there are enough warps in flight.

Second, the work distribution is different. A GPU has thousands of threads, so load imbalance is more likely and more damaging. Merge-based decomposition and row splitting are common remedies.

Third, the reduction is different. A warp-level reduction uses shuffle instructions, which are fast and deterministic. A block-level or grid-level reduction uses shared memory or atomics, which are slower and, in the atomic case, nondeterministic.

The choice of format interacts with all of this. ELL and SELL-C-sigma map naturally onto a warp-per-slice-position execution model, with the slice size set to the warp size. CSR maps naturally onto a warp-per-row model, with a warp-level reduction at the end of each row. BSR maps onto a model where each thread processes one block, using the tensor cores if the block size matches their shape.

## 5. SpGEMM: the hard one

Sparse matrix-matrix multiplication, C = A B, is where sparse linear algebra stops being a streaming problem and starts being a data structure problem. The reason is that the structure of C is not known in advance. It depends on the interaction between the structures of A and B, and computing it requires work that is itself proportional to the size of C.

### 5.1 Gustavson's algorithm and the sparse accumulator

The classic row-wise algorithm is due to Gustavson. For each row i of A, iterate over the nonzeros A(i,k). For each such k, iterate over the nonzeros B(k,j), and accumulate the product A(i,k) times B(k,j) into position j of the output row.

The accumulation needs a temporary storage indexed by column, and the natural choice is a dense array of length n, called the sparse accumulator or SPA. Alongside it, you keep a marker array that records which columns have been touched, so that you can enumerate the touched columns at the end of the row without scanning all n entries.

```cpp
void spgemm(const Csr& A, const Csr& B, Csr& C) {
  C.m = A.m; C.n = B.n;
  C.row_ptr.assign(A.m + 1, 0);
  std::vector<double> acc(B.n, 0.0);
  std::vector<int>    marker(B.n, -1);
  std::vector<int>    touched;
  for (int i = 0; i < A.m; ++i) {
    touched.clear();
    for (int ka = A.row_ptr[i]; ka < A.row_ptr[i + 1]; ++ka) {
      int    k = A.col_idx[ka];
      double a = A.val[ka];
      for (int kb = B.row_ptr[k]; kb < B.row_ptr[k + 1]; ++kb) {
        int j = B.col_idx[kb];
        if (marker[j] != i) { marker[j] = i; acc[j] = 0.0; touched.push_back(j); }
        acc[j] += a * B.val[kb];
      }
    }
    std::sort(touched.begin(), touched.end());
    for (int j : touched) { C.col_idx.push_back(j); C.val.push_back(acc[j]); }
    C.row_ptr[i + 1] = (int)C.col_idx.size();
  }
}
```

The marker trick is worth pausing on. By storing the row index i in `marker[j]` rather than a boolean, the algorithm avoids clearing the accumulator between rows. A column j is touched in row i exactly when `marker[j] != i`, and after processing row i, every touched column has `marker[j] == i`, which is automatically invalid for row i+1. This is a standard and elegant idiom, and it is the reason that SpGEMM can be linear in the number of floating-point operations plus the size of the output, rather than linear in n times m.

The cost of the dense SPA is O(n) memory per thread. For a matrix with a hundred million columns, that is 800 megabytes of accumulator plus 400 megabytes of markers, which is unacceptable. This is why parallel SpGEMM implementations use per-thread SPAs of bounded size, or switch to hash-based accumulators for rows whose output is sparse relative to n.

### 5.2 Hash and heap accumulators

A hash accumulator replaces the dense array with a hash table keyed by column index. The advantage is that the memory is proportional to the number of touched columns rather than to n, which matters for hypersparse matrices. The disadvantage is that hashing costs more per operation than a direct array index, and the constant factor is significant when the row is dense.

The practical approach is adaptive: use a dense SPA when the expected number of touched columns is a large fraction of n, and a hash table when it is a small fraction. The threshold is a tuning parameter, and it depends on the relative cost of a cache miss in the dense array versus a hash probe.

A third option is the heap-based accumulator, which maintains the output row as a sorted list and merges the sorted rows of B into it. This is attractive when the rows of B are already sorted, because the merge is linear and the output is produced in sorted order without a final sort. It is the natural choice for a symbolic phase, where you only need the structure and not the values.

### 5.3 The allocation problem

Here is the fundamental difficulty with SpGEMM, and it is worth stating plainly: you do not know how much memory C needs until you have computed it, and computing it requires memory to store the result.

There are four standard ways out.

**Symbolic pre-pass.** Compute the structure of C first, using only the indices, and allocate exactly. The structure of row i of C is the union of the structures of the rows of B indexed by the nonzeros of row i of A. Computing this union for every row is itself a SpGEMM-like operation, and it can cost as much as the numeric phase. The benefit is that the numeric phase can write into preallocated, exactly sized arrays with no reallocation.

**Two-pass counting.** Do a first pass that counts the nonzeros per row of C without storing values, then allocate, then do a second pass that computes and stores. This doubles the index traversal work but avoids the memory blowup of dynamic growth.

**Dynamic growth.** Start with a guess and grow the output arrays with reallocation when they fill. This is simple but can be catastrophic: repeated reallocation copies the entire output, and the amortized cost depends on the growth policy. It is acceptable for small matrices and unacceptable for large ones.

**Over-allocation.** Allocate generously and shrink at the end. The problem is choosing the over-allocation factor; too small and you reallocate anyway, too large and you exhaust memory. For matrices where the fill ratio (nnz of C divided by the product of the average row densities) is predictable, this works well.

In practice, most high-performance SpGEMM implementations use a symbolic pre-pass or a two-pass approach, and they invest heavily in making the symbolic phase fast, because it is often the bottleneck.

### 5.4 Parallel decomposition

The parallel decomposition of SpGEMM is a classic problem in distributed computing, and the analysis is instructive.

**1D row-wise.** Each process owns a block of rows of A and the entire matrix B. It computes its block of rows of C independently. The advantage is that there is no communication during the computation and the result is embarrassingly parallel. The disadvantage is that every process must store all of B, so the memory per process is the size of B plus its slice of A and C. This is fine for a handful of processes and untenable for thousands.

**1D column-wise.** Symmetric: each process owns a block of columns of B and all of A. Same memory problem, transposed.

**2D (SUMMA-like).** The processes are arranged in a grid, and A is distributed by column blocks and B by row blocks. At each step, a column block of A and a row block of B are broadcast along the grid, and the corresponding outer product is accumulated. This reduces the memory per process and the communication volume relative to 1D, at the cost of more synchronization. The communication volume analysis is the standard one for dense SUMMA, adapted to the sparse case: the amount of data broadcast depends on the sparsity of the blocks.

**3D.** Add a third dimension that splits the inner dimension k, so that partial products are computed independently and then reduced. This increases parallelism and reduces memory per process, at the cost of a reduction step and more total communication.

The right choice depends on the ratio of communication to computation, which for sparse matrices is highly matrix-dependent. A matrix with a few dense rows and columns behaves more like a dense matrix, and a matrix with a uniform sparse structure behaves more like a graph.

### 5.5 Expand-sort-compress

On GPUs and other highly parallel machines, a different strategy dominates: expand the products into a list of (row, column, value) triples, sort the list by (row, column), and then compress adjacent duplicates by summing. This is the expand-sort-compress pipeline.

The expansion step is trivially parallel: each nonzero A(i,k) produces a list of products with the nonzeros of row k of B, and these can be written to a global buffer with atomic counters for the per-row offsets. The sort step is the expensive one, but radix sort on a 64-bit key formed from the row and column indices is fast and highly parallel. The compression step is a segmented reduction, which is also fast.

The advantage of expand-sort-compress is that it has no per-thread accumulator, so the memory is proportional to the total number of products rather than to the number of threads times n. The disadvantage is that the intermediate buffer can be much larger than the output, because the same (i,j) position may be produced many times before compression. For matrices with high inner dimension density, the expansion factor can be large.

The practical implementations reduce the expansion factor by blocking: process the inner dimension in chunks, so that the partial products for a chunk are compressed before the next chunk is expanded. This is a space-time trade-off, and the optimal chunk size depends on the available memory and the density of the inner dimension.

### 5.6 Block and hypersparse SpGEMM

Block SpGEMM operates on BSR matrices, and it is a different algorithm from scalar SpGEMM because the inner operation is a dense block multiply-accumulate. The accumulator holds dense blocks rather than scalars, and the marker array indexes block columns rather than scalar columns. The advantage is that the inner kernel is a small dense GEMM, which is exactly what the hardware is good at. The disadvantage is that the accumulator is larger, because each touched block column holds a full r-by-c block.

Hypersparse SpGEMM handles matrices with many empty rows. The key observation is that the output rows corresponding to empty rows of A are empty, and the output rows corresponding to rows of A whose nonzeros all point into empty rows of B are also empty. A hypersparse implementation tracks the list of nonempty rows explicitly, so that it never iterates over empty rows. This is essential for graph algorithms, where the frontier of a breadth-first search is hypersparse even when the graph itself is not.

### 5.7 Applications

SpGEMM shows up in more places than you might expect.

**Algebraic multigrid setup.** The coarse-grid operators are formed by triple products of the form R A P, where R is a restriction operator and P is a prolongation operator. Both are sparse, and the triple product is two SpGEMMs. The setup cost of algebraic multigrid is often dominated by these products, and it is the reason that multigrid setup is a bottleneck in large-scale implicit solvers.

**Graph clustering and triangle counting.** The number of triangles in a graph is the sum of the entries of the elementwise product of A cubed with A, which is a masked SpGEMM. Spectral clustering requires forming the graph Laplacian and multiplying by it, which is SpMV, but the construction of higher-order structures uses SpGEMM.

**Sparse neural networks.** A sparse weight matrix multiplied by a dense batch of activations is SpMM, but when the sparsity pattern itself is learned or when the network has sparse-sparse interactions, SpGEMM appears. Structured sparsity patterns, such as the 2:4 pattern supported by recent tensor cores, are essentially a block format with a fixed block density, and they are handled by a specialized kernel that resembles block SpGEMM.

**Boolean and tropical semirings.** Replacing the arithmetic operations with logical operations turns SpGEMM into a graph reachability computation. Replacing them with min and plus turns it into a shortest-path computation. We will return to this in Section 7.

## 6. Sparse triangular solve and preconditioners

Sparse triangular solve is the operation that most clearly exposes the limits of parallelism in sparse computation, because its parallelism is bounded by data dependencies rather than by memory bandwidth.

Consider solving L x = b where L is lower triangular and sparse. The forward substitution recurrence is x(i) = (b(i) minus the sum over j less than i of L(i,j) x(j)) divided by L(i,i). The dependency is explicit: x(i) depends on x(j) for every nonzero L(i,j) with j less than i.

The standard parallelization is level scheduling. Build a directed acyclic graph whose vertices are the rows and whose edges are the dependencies, and assign each vertex a level equal to the length of the longest path from any source. Vertices at the same level are independent and can be solved in parallel. The number of levels is the critical path length, and it bounds the parallel speedup: with p processors, the best you can do is the number of levels, and if the number of levels is small, you cannot use many processors.

For many matrices, the level structure is extremely unbalanced. The first level might contain a single row, the second a few, and the last level almost all the rows. This is the same load imbalance problem as SpMV, but worse, because it is structural rather than accidental. Reordering the matrix can change the level structure, and there is a real tension between reorderings that reduce fill-in (which tends to increase the critical path) and reorderings that increase parallelism (which tends to increase fill-in).

There are several ways to get more parallelism. Block triangular solve treats the matrix as a block matrix and solves the diagonal blocks with dense kernels, which have much more internal parallelism. Recursive blocking applies the same idea hierarchically. The spike method partitions the matrix into a small number of large blocks and solves the resulting reduced system, which is dense and can use dense kernels. Iterative refinement can be used to correct the solution of an approximate solve.

Preconditioners are where triangular solve matters most, and they are the reason that sparse iterative solvers are hard to scale. An incomplete LU factorization with zero fill, ILU(0), computes a factorization with the same structure as the original matrix. Applying the preconditioner requires a forward and a backward triangular solve, and both are sequential in the worst case. The result is that a Krylov solver with an ILU preconditioner can have a large fraction of its runtime in the preconditioner, and that fraction does not decrease as you add processors.

The alternatives are preconditioners with more parallelism and less effectiveness. Block Jacobi preconditioners are perfectly parallel but converge slowly. Multilevel preconditioners, such as algebraic multigrid, have parallelism in the smoother and in the coarse-grid solve, but the coarse-grid solve is itself a sparse triangular solve on a smaller matrix. Polynomial preconditioners are perfectly parallel but require more iterations. Choosing a preconditioner is a trade-off between the number of iterations and the cost per iteration, and the optimum depends on the machine and the problem.

## 7. Graph analytics as sparse linear algebra

The graph view of a sparse matrix becomes a computational tool when you generalize the arithmetic. A semiring is a set with two operations, usually called addition and multiplication, that satisfy the usual algebraic laws except that addition need not have inverses. If you replace the field operations in SpMV or SpGEMM with semiring operations, you get a family of algorithms.

Take the boolean semiring, where addition is logical OR and multiplication is logical AND. Then SpMV computes, for each row i, whether there exists a column j such that A(i,j) is true and x(j) is true. That is exactly one step of a breadth-first search, where A is the adjacency matrix and x is the frontier. The whole BFS is a sequence of SpMV operations with a mask to avoid revisiting vertices.

```cpp
// One BFS step as SpMV over the (OR, AND) boolean semiring.
void bfs_step(const Csr& A, const std::vector<char>& frontier,
              const std::vector<char>& visited, std::vector<char>& next) {
  next.assign(A.m, 0);
  for (int i = 0; i < A.m; ++i) {
    char acc = 0;
    for (int k = A.row_ptr[i]; k < A.row_ptr[i + 1]; ++k)
      acc |= frontier[A.col_idx[k]];
    next[i] = acc & (char)(!visited[i]);
  }
}
```

Take the tropical semiring, where addition is minimum and multiplication is addition. Then SpMV computes, for each row i, the minimum over j of A(i,j) plus x(j), which is one step of a shortest-path relaxation. Repeated application computes single-source shortest paths in a graph with nonnegative weights.

Take the standard arithmetic semiring and add a normalization step, and you get PageRank: repeatedly multiply the transition matrix by the rank vector, add a teleportation term, and normalize.

This unification is the motivation for GraphBLAS, a standardization effort that defines a set of sparse linear algebra operations parameterized by semiring, with masks, and with a small set of operations (matrix times matrix, matrix times vector, elementwise operations, and reductions). The claim is that a large fraction of graph algorithms can be expressed in this vocabulary, and that doing so lets you reuse a single highly optimized kernel library rather than writing a bespoke kernel for every algorithm.

The claim is largely true, and the caveats are instructive. The first caveat is that the performance of a graph algorithm expressed as linear algebra depends on the semiring and on the sparsity of the operands. A BFS expressed as SpMV over the boolean semiring is fast when the frontier is dense and slow when the frontier is sparse, because the kernel still traverses the whole matrix. The fix is to switch between a push formulation (iterate over the frontier and scatter into the next frontier) and a pull formulation (iterate over all vertices and gather from the frontier) depending on the frontier density. This is the classic direction-optimizing BFS, and it is a reminder that the linear algebra abstraction hides a decision that matters.

The second caveat is that the semiring operations may not be associative in floating point, which affects reproducibility, and that some semirings have no efficient vectorized implementation. The min-plus semiring, for example, requires a minimum reduction, which is not the same as a sum reduction and may not map to the same hardware instructions.

The third caveat is that the abstraction can obscure memory layout decisions. A graph algorithm that is naturally edge-centric may be forced into a vertex-centric linear algebra formulation that has worse locality. The abstraction is a tool, not a straitjacket.

## 8. Measuring sparse kernels honestly

Sparse kernel benchmarking is full of traps, and it is worth enumerating them, because a wrong measurement leads to a wrong optimization.

**The matrix matters more than the machine.** A kernel that is fast on one matrix can be slow on another with the same dimensions and the same nnz. Always report the matrix, its dimensions, its nnz, and its row-length distribution. A single number without the matrix is meaningless.

**Effective bandwidth is the right primary metric for SpMV.** Compute the bytes moved (12 per nonzero plus 8 per row, plus the vector traffic) and divide by the time. Compare against a streaming benchmark that measures achievable bandwidth on the same machine. The ratio tells you how much headroom remains. If you are at 90 percent of achievable bandwidth, there is nothing left to gain from the kernel itself, and you should look at the algorithm.

**Flops per second is a misleading metric for SpMV.** It will be low, and it will always be low, because the kernel is memory bound. Reporting it invites the wrong conclusion.

**Warm-up and repetition matter.** The first iteration of a kernel pays for page faults, TLB misses, and cache cold misses. Report steady-state numbers, and say how many iterations you ran.

**NUMA effects matter.** On a multi-socket machine, the placement of the matrix arrays relative to the thread that reads them can change performance substantially. Use first-touch initialization or explicit placement, and be aware that a matrix allocated by one thread and read by another will be remote.

**The gather cost depends on the vector size.** If x fits in cache, the gather is cheap. If it does not, the gather is expensive. Report the dimension, and if you are comparing two kernels, make sure both see the same cache conditions.

**Preprocessing must be counted.** If a format requires a conversion, and the matrix is used once, the conversion is part of the cost. If the matrix is used many times, it is amortized. Say which situation you are measuring.

**Floating-point results depend on the summation order.** A parallel SpMV with atomic accumulation produces a different result than a sequential one, and a merge-based SpMV produces yet another. If you are validating correctness, compare against a tolerance, not against bitwise equality, unless you have designed for determinism.

**The compiler can change everything.** Vectorization, unrolling, and instruction selection are all sensitive to flags and to the exact form of the loop. A kernel that does not vectorize under one compiler may vectorize under another. Inspect the generated assembly when performance is surprising.

## 9. A worked implementation

Let us put the pieces together with a small, complete CSR library. The goal is not to be fast but to be correct and to expose the structure of the algorithms.

First, the conversion from COO to CSR. This is a counting sort by row index.

```cpp
Csr coo_to_csr(const Coo& coo, int m, int n) {
  Csr A;
  A.m = m; A.n = n;
  const int nnz = (int)coo.val.size();
  A.row_ptr.assign(m + 1, 0);
  for (int k = 0; k < nnz; ++k) A.row_ptr[coo.row[k] + 1]++;
  for (int i = 0; i < m; ++i) A.row_ptr[i + 1] += A.row_ptr[i];
  A.col_idx.assign(nnz, 0);
  A.val.assign(nnz, 0.0);
  std::vector<int> next(A.row_ptr.begin(), A.row_ptr.end() - 1);
  for (int k = 0; k < nnz; ++k) {
    int i = coo.row[k];
    int p = next[i]++;
    A.col_idx[p] = coo.col[k];
    A.val[p] = coo.val[k];
  }
  return A;
}
```

This produces a CSR matrix whose rows are in the order the entries appeared in COO, and whose columns within a row are unsorted, with duplicates preserved. To sort and sum duplicates, do a second pass that sorts each row and merges equal columns.

```cpp
void compress_rows(Csr& A) {
  int w = 0;
  std::vector<int> new_ptr(A.m + 1);
  std::vector<int> order;
  for (int i = 0; i < A.m; ++i) {
    int begin = A.row_ptr[i], end = A.row_ptr[i + 1];
    new_ptr[i] = w;
    if (begin == end) continue;
    order.resize(end - begin);
    std::iota(order.begin(), order.end(), begin);
    std::sort(order.begin(), order.end(),
              [&](int a, int b) { return A.col_idx[a] < A.col_idx[b]; });
    int prev = -1;
    for (int t : order) {
      int j = A.col_idx[t];
      if (j == prev) {
        A.val[w - 1] += A.val[t];
      } else {
        A.col_idx[w] = j;
        A.val[w] = A.val[t];
        ++w;
        prev = j;
      }
    }
  }
  new_ptr[A.m] = w;
  A.row_ptr = new_ptr;
  A.col_idx.resize(w);
  A.val.resize(w);
}
```

The write cursor w never exceeds the read cursor t, so the in-place compaction is safe. The duplicate summation reads `A.val[t]` before it can be overwritten, because `w - 1` is strictly less than `t` whenever a duplicate is found.

Next, the transpose, which is the CSR-to-CSC conversion and also the building block for symmetric operations.

```cpp
Csr transpose(const Csr& A) {
  Csr T;
  T.m = A.n; T.n = A.m;
  T.row_ptr.assign(A.n + 1, 0);
  for (int k = 0; k < (int)A.col_idx.size(); ++k) T.row_ptr[A.col_idx[k] + 1]++;
  for (int j = 0; j < A.n; ++j) T.row_ptr[j + 1] += T.row_ptr[j];
  T.col_idx.assign(A.col_idx.size(), 0);
  T.val.assign(A.val.size(), 0.0);
  std::vector<int> next(T.row_ptr.begin(), T.row_ptr.end() - 1);
  for (int i = 0; i < A.m; ++i)
    for (int k = A.row_ptr[i]; k < A.row_ptr[i + 1]; ++k) {
      int p = next[A.col_idx[k]]++;
      T.col_idx[p] = i;
      T.val[p] = A.val[k];
    }
  return T;
}
```

This is again a counting sort, this time by column index, and it is linear in nnz plus n. It is the standard way to transpose a sparse matrix, and it is much faster than a naive nested loop that searches for each entry.

Finally, the SpGEMM from Section 5.1, which we can now read with full context. The marker array uses the row index as the sentinel, so it never needs to be cleared. The touched list collects the columns that were written, and sorting it produces the output row in column order. The accumulator is dense, which is fine for a matrix whose rows are not too sparse relative to n.

The extension to a parallel SpGEMM is a matter of giving each thread its own accumulator and marker array, partitioning the rows of A among the threads, and writing each thread's output into a preallocated region of the output arrays. The preallocation requires a symbolic pass, which is the allocation problem from Section 5.3 in concrete form.

## 10. Pitfalls

A collection of mistakes that are easy to make and expensive to discover.

**Assuming CSR is always best.** It is the best default, not the best format. For a matrix with uniform row lengths, ELL will beat it. For a banded matrix, DIA will beat it. Measure before you commit.

**Forgetting that x may not fit in cache.** A kernel that is fast on a small test matrix may be slow on a large one, because the gather from x becomes a cache miss. Test at realistic dimensions.

**Ignoring the row-length distribution.** The mean row length tells you almost nothing. The maximum and the variance tell you whether padding formats will work and whether load imbalance will be a problem. Plot the histogram.

**Using 64-bit indices by default.** It doubles the index traffic, which is a large fraction of SpMV traffic. Use 32-bit indices unless you have more than two billion nonzeros, and handle the overflow cases explicitly.

**Assuming the symbolic phase is free.** In SpGEMM and in factorization, the symbolic phase can dominate. Measure it separately.

**Reallocating the output of SpGEMM.** Dynamic growth of the output arrays can turn a linear algorithm into a quadratic one. Use a symbolic pass or a two-pass counting scheme.

**Nondeterministic floating-point reductions.** Atomic accumulation in a parallel SpMV produces run-to-run variation. If you need reproducibility, use a deterministic reduction tree or a fixed partitioning.

**Ignoring NUMA.** On a multi-socket machine, remote memory access can halve your bandwidth. Place your data deliberately.

**Benchmarking a kernel in isolation.** A kernel that is fast in a microbenchmark may be slow in the context of a solver, because of cache pollution, because of the interaction with the preconditioner, or because the solver's convergence changes. Measure the end-to-end time as well.

**Confusing structural zeros with numerical zeros.** A matrix may have stored entries that happen to be numerically zero. Formats that assume stored entries are nonzero will waste space, and algorithms that assume a stored entry contributes will do extra work. Some solvers periodically prune numerical zeros; this is a trade-off between storage and the cost of the pruning pass.

## 11. Where this is heading

The trajectory of sparse linear algebra is toward heterogeneity and toward tighter integration with the applications that use it.

On the hardware side, the interesting developments are in accelerators with sparse support. Tensor cores with structured sparsity, such as the 2:4 pattern, are essentially a hardware block format with a fixed density, and they force a specific sparsity structure on the model. Processing-in-memory architectures promise to move computation to where the data lives, which is attractive precisely because sparse kernels are memory bound. And the memory hierarchy itself is changing, with high-bandwidth memory and stacked DRAM changing the balance point of the roofline.

On the software side, the trend is toward libraries that abstract the format. GraphBLAS is the most visible example, but the same idea appears in sparse tensor compilers, which take a sparse computation expressed in a high-level language and generate kernels specialized to the sparsity pattern and the target machine. The promise is that you write the algorithm once and the compiler picks the format; the reality is that format selection is still hard, and the best results come from giving the programmer control over the format while automating the kernel generation.

On the algorithmic side, the most interesting work is in the interaction between the numerical method and the sparsity structure. Reordering affects fill, parallelism, and convergence. Preconditioners affect the number of iterations and the cost per iteration. The choice of format affects the achievable bandwidth. These decisions are coupled, and treating them independently leaves performance on the table. A solver that chooses its reordering, its preconditioner, and its format jointly, based on the matrix and the machine, will beat one that makes each choice in isolation.

The one constant is the tension we started with: regularity versus compactness. Every format in the zoo is a point on that spectrum, and every kernel is an attempt to extract regularity from a structure that does not naturally have it. Understanding that tension is what lets you look at a new format or a new kernel and immediately see what it is trading away.

## 12. Summary

Sparse linear algebra is the study of computation on data whose structure is irregular, and the irregularity is not incidental; it is the whole problem. The storage format is the primary design decision, and it is a choice between storing zeros to gain regularity (ELL, DIA) and storing only nonzeros to gain compactness (CSR, COO). The kernels that consume these formats are memory bound, and their performance is governed by the bytes moved per useful floating-point operation, which for SpMV in CSR is on the order of twelve bytes per nonzero and can only be improved by reducing index width, exploiting block structure, or processing multiple vectors at
