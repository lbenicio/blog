---
title: "The Design Space of Parallel Stencil Kernels: Roofline Limits, Cache Blocking, Temporal Tiling, and Halo Exchange"
description: "A first-principles tour of why stencil kernels are bandwidth-bound, how blocking and temporal tiling change the arithmetic intensity, and how halo exchange and surface-to-volume ratios constrain distributed implementations."
date: "2026-10-26"
author: "Leonardo Benicio"
tags: ["parallel computing","high performance computing","stencil computation","cache blocking","roofline model","domain decomposition","memory hierarchy","performance engineering"]
categories: ["Computer Science","Systems Design","Parallel Computing"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/the-design-space-of-parallel-stencil-kernels-roofline-limits-cache-blocking-temporal-tiling-and-halo-2026-10-26.jpg"
coverAlt: "Isometric technical illustration of a translucent three-dimensional grid with a highlighted sub-block and a blue halo, concentric shells indicating a dependence cone, layered planes suggesting memory hierarchy, and a rising slanted line representing a roofline."
---

A stencil computation updates every element of a dense grid from a fixed neighborhood of that element. The canonical example is small enough to fit on a slide: for a three-dimensional seven-point Laplacian in double precision, each interior point performs seven loads, six additions, and one store. It is also one of the most reliable ways to discover that a machine's advertised bandwidth and its *attainable* bandwidth are different numbers, and that the distance between them is where nearly all of the engineering effort goes.

Stencils matter because they are the computational core of a great deal of numerical software: explicit finite-difference solvers for wave, heat, and fluid equations; image filters and convolution kernels; iterative smoothers inside multigrid hierarchies; lattice Boltzmann steps; cellular automata; and — with the right framing — the sliding-window convolutions inside convolutional neural networks. They are also a useful teaching object because the performance model is almost entirely mechanical. There is no branch prediction puzzle, no pointer chasing, no hash function to tune. There is a grid, a neighborhood, and a memory system that either keeps up or does not.

This article works through the design space from first principles. The goal is not to present a single "best" kernel — there isn't one, because the right answer depends on the stencil radius, the grid size, the number of time steps, the memory hierarchy, and how many ranks the domain is split across. The goal is to give you the arithmetic that lets you predict, before you write a line of code, roughly where a given stencil will land, and which of the available levers will actually move it.

## The stencil as a dataflow graph

Formally, a stencil is defined by a neighborhood function over an index space. For a grid point indexed by a multi-index `p`, the update is

```
u_new[p] = f(u[p + d] for d in S)
```

where `S` is a finite set of offsets — the *stencil shape* — that always contains the zero offset. The *radius* `r` is the maximum L∞ or L2 norm of the offsets, depending on convention; the *order* of accuracy is a property of the discretization, not of the implementation, and it is worth keeping the two separate in your head. Implementation performance depends on the shape and radius. Numerical correctness depends on the coefficients and the truncation error.

For an explicit time-stepping scheme, the update is applied repeatedly, and step `t+1` depends on step `t`. That temporal dependence is what makes stencils interesting: it is a source of parallelism (every point at a given time step is independent of every other point at that time step) and a source of reuse (the data read at step `t` will be read again at step `t+1`).

### Halos, ghosts, and boundary conditions

The neighborhood `S` means that points near the edge of the domain reference indices outside it. There are two standard ways to handle this. The first is to allocate a *ghost layer* — a band of `r` extra cells on each side of the array — and fill it according to the boundary condition. Dirichlet boundaries write a fixed value; Neumann boundaries copy the adjacent interior value; periodic boundaries copy from the opposite face. The second is to split the kernel into an interior loop that assumes all neighbors are valid and a boundary loop that applies the boundary logic. The split is usually worth doing: the interior loop has no branches and no bounds checks, which makes it far easier for the compiler to vectorize.

The ghost layer is not free. For a `B^3` block in three dimensions with radius 1, the ghost region contains `(B+2)^3 - B^3` cells, which is roughly `6B^2` for large `B`. That is the *surface-to-volume ratio* showing up already, inside a single node's cache. It will show up again, with the same shape, when we talk about distributed halo exchange.

### The dependence cone

If you unroll the time loop symbolically, point `p` at step `t+T` depends on all points within radius `r*T` of `p` at step `t`. This cone of influence is the fundamental reason temporal blocking works: to advance a block of the grid by `T` steps, you do not need the entire grid — you need the block plus a halo of width `r*T`. The redundant work is the cost of that halo; the benefit is that the interior data stays resident across `T` steps instead of being streamed from DRAM `T` times.

## Arithmetic intensity from first principles

Before optimizing anything, compute the ratio of floating-point operations to bytes moved. This is the single most useful number for a stencil, because it tells you immediately which wall you are going to hit.

Take the seven-point Laplacian in double precision. Assume the coefficients are constant, so the update is one multiply and six adds — seven flops per point, and we will use that count. (If the coefficients vary per point, or if the stencil is anisotropic and requires six multiplies plus six adds, the count is closer to twelve. State your assumption explicitly whenever you quote a flop count; the difference is a factor of two and it changes the roofline position.)

Now count traffic. A naive implementation that reads each neighbor from memory and writes the result has, per point:

- 7 loads × 8 bytes = 56 bytes read
- 1 store × 8 bytes = 8 bytes written
- total: 64 bytes

That gives `7 / 64 ≈ 0.11` flops per byte. This is the number that describes the kernel as written, and it is the number that makes stencils look hopeless on paper.

The compulsory traffic — the minimum any implementation must move if the grid does not fit in cache — is one read and one write per point per time step: 16 bytes, or `7 / 16 ≈ 0.44` flops per byte. Everything between 0.11 and 0.44 is a measure of how well the implementation exploits reuse within a time step; everything below 0.44 per step is a measure of how well it exploits reuse *across* time steps.

If the grid does fit in cache, the compulsory traffic is paid once and then amortized over all time steps, and the arithmetic intensity per step approaches infinity in the limit. That is why small-grid stencils and large-grid stencils behave so differently, and why a benchmark on a 256³ grid tells you very little about a 2048³ grid.

## The roofline as a design constraint

Plot attainable floating-point throughput against arithmetic intensity and you get the roofline: a slanted line `min(peak_flops, bandwidth × intensity)`. The knee is at `intensity = peak_flops / bandwidth`, often called the ridge point.

Consider a concrete, explicitly hypothetical machine: 1 TFLOP/s of double-precision throughput and 200 GB/s of attainable DRAM bandwidth. (These are round numbers chosen for arithmetic convenience, not measurements of any particular part.) The ridge point is at 5 flops per byte. Our stencil, at 0.11 to 0.44 flops per byte, sits far to the left of the knee, on the slanted part of the line. Its attainable throughput is therefore `bandwidth × intensity`, which is somewhere between 22 and 88 GFLOP/s — two to four percent of peak.

That is the whole story of stencil performance in one paragraph. The kernel is not compute-bound; it is not even close. The only lever that matters is reducing bytes moved per useful flop, and there are exactly three places to do it:

1. **Intra-node reuse.** Keep data in registers, L1, L2, or L3 across multiple uses. This is cache blocking.
2. **Inter-step reuse.** Keep data on-chip across multiple time steps. This is temporal blocking.
3. **Inter-node reuse.** Reduce the bytes crossing the network per unit of work. This is halo exchange optimization, and it is a bandwidth problem with a latency component layered on top.

Everything else — loop unrolling, vectorization, prefetching, thread affinity — is about making sure the memory system actually delivers the bandwidth the roofline assumes. Those are real and necessary, but they operate on the *attainable* bandwidth term, not on the intensity term.

### Three ceilings, not one

A single roofline conflates several distinct limits, and it is worth separating them:

- **DRAM bandwidth.** The hard floor. Once your working set exceeds the last-level cache, every byte of compulsory traffic comes from here.
- **Last-level cache bandwidth.** Typically several times DRAM bandwidth on modern parts. A blocked kernel that fits its working set in L3 can exceed the DRAM roofline.
- **Interconnect bandwidth.** For distributed runs, the halo exchange competes with the compute for the same memory system, and on many clusters the NIC's DMA traffic consumes DRAM bandwidth on the way in and on the way out.

A kernel can be simultaneously under the DRAM roofline and over the interconnect roofline. When that happens, adding ranks makes things slower, and the fix is algorithmic — increase the block size in the spatial dimensions, or increase the number of time steps per exchange — not microarchitectural.

## Cache blocking: buying reuse with redundant reads

The idea behind cache blocking is to choose a traversal order that maximizes reuse before eviction. Instead of sweeping the entire grid plane by plane, process a sub-block of the grid that fits in cache, then move to the next sub-block.

For a three-dimensional stencil with radius 1, a block of side `B` requires a working set of roughly `(B+2)^3` cells to advance one step without re-reading from DRAM. In double precision that is `8(B+2)^3` bytes. If you have, say, 8 MB of usable L3 per core — a plausible but again illustrative figure — you can afford `B` around 90. In practice you want to leave headroom for the output array and the streaming input, so the usable block is smaller, and the classic result is that three-dimensional blocking with a single time step buys you a modest factor over a naive sweep: you go from reading each point seven times to reading each point roughly once, which is a factor of about seven on the read side, or about 4× on total traffic once the store is included.

That factor is real but bounded. The compulsory 16 bytes per point per step is still paid on every step, because the block is streamed in and out. To do better you must keep the block resident across multiple steps, which is temporal blocking.

### The redundant-read tax

Blocking is not free. Each block must read a halo of `r` cells from its neighbors, and those cells are read again by the neighboring block. For a `B^3` block, the halo fraction is approximately `6B^2 / B^3 = 6/B`. At `B = 90` that is under 7 percent, which is acceptable. At `B = 16` — a block size you might pick to maximize parallelism — it is over 37 percent, which is not.

This is the central tension of cache blocking: larger blocks mean less redundant traffic but fewer independent tasks to schedule and a larger working set to keep resident. The optimum is machine-specific, and it is usually found empirically rather than derived. What the arithmetic gives you is the shape of the trade-off, and the knowledge that the redundant-read tax scales as `1/B` while the reuse benefit saturates once the block fits in cache. Past the point where the working set fits, increasing `B` buys you nothing but costs you halo reads and parallelism. That knee is where you want to be.

### One-dimensional, two-dimensional, and three-dimensional blocking

The dimensionality of the blocking matters as much as the block size. A one-dimensional block — a strip of columns — reuses data along one axis only, so it captures roughly a third of the available reuse for a seven-point stencil. Two-dimensional blocking captures reuse in the plane and is often the sweet spot for large grids, because the working set `B^2 × N` stays manageable while the halo fraction drops as `1/B`. Three-dimensional blocking is optimal in principle but the cube must fit in cache, which limits `B` and therefore limits the number of independent tasks available.

A useful rule of thumb: block in as many dimensions as your cache allows, and no more. The marginal benefit of adding a dimension is a reduction in halo traffic; the marginal cost is a cubic growth in working set.

### What blocking does to the roofline position

With single-step blocking, the effective intensity rises from roughly 0.11 to roughly 0.44 flops per byte — a factor of four, which on the slanted part of the roofline is a factor of four in throughput. That is a large win for a change in loop order and nothing else. But it is also the ceiling for single-step blocking: you cannot do better than compulsory traffic without keeping data on-chip across time steps.

That is where the next set of techniques begins, and where the design space gets genuinely interesting: temporal blocking turns the time loop into a tiling problem, and the tiles are not rectangular. The dependence cone we derived earlier means that a block advanced by `T` steps needs a halo of `r*T`, so the redundant work grows with the square of the temporal depth, while the traffic per step falls as `1/T`. Finding the optimum requires trading a quadratic cost against a hyperbolic benefit — and that trade-off, along with the wavefront scheduling that makes temporal blocking implementable, is the subject of the next section.

## Temporal tiling: trading redundant computation for traffic

The dependence cone gives a precise budget. To advance a block of side `B` by `T` steps with a radius-`r` stencil, the initial data must cover a cube of side `B + 2rT`. The central `B^3` cells are the useful output; the surrounding shell is the redundant computation. For large `B` and modest `rT`, that shell is approximately `6rT B^2` cells, so the redundant-work factor is

```
W(T) = (1 + 2rT/B)^3
```

and the traffic per useful point per step, if only the final state is written, is

```
Q(T) = 8 * ( (1 + 2rT/B)^3 + 1 ) / T
```

bytes. The first term is the initial read of the extended block; the second is the final write of the central block. Both are amortized over `T` steps.

This expression is the heart of temporal tiling. As `T` grows, the write traffic falls as `1/T`, but the read traffic grows as `T^2` once `2rT/B` is no longer small. The minimum is at roughly `T ~ B/(4r)`, where the halo width `rT` is about a quarter of the block side. At that point the extended block is `1.5B` on a side, the redundant computation is about `3.4x`, and the traffic per point per step is

```
Q ~ 8 * (3.375 + 1) / (B/(4r)) = 140 r / B
```

bytes. For `B = 64` and `r = 1`, that is about 2.2 bytes per point per step, compared with 16 bytes for a naive sweep. The memory traffic has dropped by a factor of seven, at the cost of computing each point about 3.4 times. On a machine whose ridge point is 5 flops per byte, the blocked kernel is now comfortably compute-bound: the useful arithmetic intensity is `7 / 2.2 ~ 3.2` flops per byte, but the actual flops executed per byte are `7 * 3.375 / 2.2 ~ 10.7`, which is above the ridge. The kernel is no longer waiting on DRAM; it is waiting on the floating-point units, and the effective peak is reduced by the redundant-work factor.

That is the correct way to think about temporal blocking: it is not free, and it does not create flops from nowhere. It converts a bandwidth problem into a compute problem, and it is only a win if the machine has compute headroom to spare. On a GPU with a very high flop-to-byte ratio, that headroom is usually there. On a CPU with a narrower vector unit and a large cache, the optimum may be a smaller `T`, or no temporal blocking at all.

### Rectangular, trapezoidal, and diamond tiles

The simplest temporal tile is rectangular in space-time: load the extended cube, run `T` steps over the whole cube, write the central cube. The live working set is the entire extended cube, `8(B + 2rT)^3` bytes. For `B = 64`, `r = 1`, `T = 16`, that is `8 * 96^3 ~ 7 MB`, which fits in a large L3 but not in L2. For larger `T` or larger `B`, it will not fit, and the rectangular tile loses its advantage.

A trapezoidal tile narrows the spatial extent as time advances, following the dependence cone. At step `t` of the tile, only the region that can still influence the final central block needs to be computed; its side is `B + 2r(T - t)`. The live set is smaller, and the redundant computation is the same in total volume, but it is spread over time. The implementation is more complex because the loop bounds change with `t`.

A diamond tile goes further and overlaps the cones of adjacent tiles, so that redundant computation is shared between neighbors. In one dimension, the space-time tiling is a set of diamonds or parallelograms; in three dimensions, the shapes are polyhedra. The benefit is a further reduction in redundant work, at the cost of a more irregular schedule and more complicated boundary handling. For most production stencil codes, the practical choice is a rectangular or trapezoidal tile with a modest `T`, because the implementation cost of diamond tiling rarely pays for itself outside of very large runs.

### Wavefront scheduling

Wavefront scheduling is the implementation technique that makes temporal tiling fit in cache. Instead of computing the entire extended block for step `t`, then the entire block for step `t+1`, you process the grid in a skewed order: a point `(i, j, k)` at time `t` is computed only after its neighbors at time `t-1` are available. If you order the work by `i + j + k + t`, the dependencies form a wavefront that sweeps through space-time.

The live set for a wavefront is not the full extended cube. In three dimensions, the wavefront is a surface, and the data that must remain on-chip is a band of thickness proportional to `rT` in the direction of the wavefront. For a block of side `B` and temporal depth `T`, the live set is roughly `B^2 * rT` cells, or `8 B^2 rT` bytes. With `B = 64`, `r = 1`, `T = 16`, that is `8 * 4096 * 16 ~ 0.5 MB`, which fits in L2. The wavefront therefore allows much larger temporal depths than a rectangular tile, because the working set grows linearly with `T` rather than cubically.

The cost is parallelism. A wavefront has a sequential dependence in the time direction, so you cannot simply assign each time step to a different thread. You can, however, parallelize across the wavefront surface, which contains `B^2` points. For a 64^3 block, that is 4096 independent points per wavefront, enough for many cores. The wavefront also changes the memory access pattern: consecutive points in the wavefront are not contiguous in memory, so you need to be careful about vectorization and cache-line utilization. In practice, wavefront scheduling is often implemented by tiling the wavefront itself into smaller spatial tiles, each of which is processed with vectorized inner loops.

## Halo exchange and the surface-to-volume ratio

In a distributed-memory implementation, the grid is partitioned into subdomains, one per rank. Each rank owns a contiguous block of cells and must obtain the values of neighboring cells that lie outside its block. Those values are the *halo* or *ghost* cells, and they are obtained by exchanging messages with the neighboring ranks.

The cost of halo exchange is governed by the surface-to-volume ratio. For a cubic subdomain of side `L`, the volume is `L^3` and the surface area is `6L^2`. With a radius-`r` stencil, the halo layer has thickness `r`, so the number of ghost cells is approximately `6rL^2`. The fraction of the subdomain that must be exchanged each step is therefore

```
halo fraction ~ 6rL^2 / L^3 = 6r / L
```

This is the same `1/L` scaling that appeared in cache blocking. It is the fundamental reason why strong scaling of stencil codes is difficult: as you add ranks, `L` shrinks, and the halo fraction grows. At `L = 64` and `r = 1`, the halo is about 9 percent of the subdomain. At `L = 16`, it is 37 percent. At `L = 8`, it is 75 percent. Beyond a certain point, the ranks spend more time exchanging halos than computing.

The arithmetic intensity of the communication is also easy to compute. Each step performs about `7L^3` flops on the subdomain and exchanges about `6rL^2` cells, or `48rL^2` bytes in double precision. The communication intensity is

```
I_comm = 7L^3 / (48rL^2) = 7L / (48r) ~ 0.146 L / r
```

flops per byte exchanged. On a machine with 1 TFLOP/s of compute and 10 GB/s of network bandwidth, the network ridge point is 100 flops per byte. To stay on the compute side of that ridge, you need `L > 685r`. For `r = 1`, that is a subdomain of side 685, which is larger than many full grids. In practice, distributed stencil codes are almost always network-bound at scale, and the only ways to improve are to increase `L` (use fewer ranks or a larger global grid) or to reduce the number of exchanges (not the bytes per exchange) by temporal blocking.

### Temporal blocking does not reduce halo bytes

It is tempting to think that temporal blocking will reduce the network traffic in the same way it reduces DRAM traffic. It does not. Suppose a rank advances its subdomain by `T` steps before exchanging halos. To do so, it needs an initial halo of width `rT`, not `r`. The number of ghost cells is `6rT L^2`, and the exchange happens once every `T` steps. The bytes exchanged per step are therefore

```
6rT L^2 * 8 / T = 48rL^2
```

which is exactly the same as exchanging a width-`r` halo every step. The total volume of data crossing the network is unchanged. What temporal blocking changes is the *number* of messages: it sends one large message instead of `T` small ones. That reduces latency overhead and makes it easier to overlap communication with computation, but it does not reduce the bandwidth requirement.

This is an important distinction. If your distributed stencil is limited by network bandwidth, temporal blocking will not save you. If it is limited by message latency, or by the overhead of packing and unpacking many small buffers, temporal blocking can help a great deal. The surface-to-volume ratio remains the fundamental constraint: the only way to reduce halo bytes per step is to increase `L`, which means weaker scaling or a larger problem.

### Overlapping communication and computation

The standard technique for hiding halo-exchange latency is to split the subdomain into an interior region and a boundary region. The boundary region depends on the halo, so it cannot be computed until the halo arrives. The interior region does not depend on the halo, so it can be computed while the messages are in flight. For a radius-1 stencil, only the outermost one-cell layer depends on the halo, so the interior is almost the entire subdomain. The overlap potential is therefore large: you can post the nonblocking receives, pack and send the halos, compute the interior, then wait for the receives and compute the boundary.

The amount of work that can be overlapped is proportional to `(L - 2r)^3 / L^3`, which is close to 1 for large `L`. For small `L`, the boundary region is a larger fraction, and the overlap is less effective. This is another reason why small subdomains are inefficient.

In three dimensions, the halo exchange can be decomposed into face, edge, and corner exchanges. Face exchanges are the largest and most regular; edges and corners are smaller but can be numerous. A common optimization is to exchange faces first, then edges, then corners, so that the largest messages are in flight as early as possible. Another is to use a single packed buffer for all ghost cells, which reduces the number of messages but increases the packing cost. The right choice depends on the network's latency and bandwidth characteristics.

### Subdomain shape

For a fixed number of ranks and a fixed global grid, the subdomain shape affects the surface-to-volume ratio. A cube minimizes surface area for a given volume, so cubic subdomains are optimal in principle. In practice, the global grid may not be cubic, and the decomposition may be constrained by the network topology or by the number of ranks. A common approach is to use a recursive bisection that splits the longest dimension at each step, which tends to produce subdomains that are as close to cubic as the grid allows.

If the grid is much larger in one dimension than the others, a slab decomposition -- splitting only along the long axis -- can be attractive because it produces large, regular messages and simple communication patterns. But the surface-to-volume ratio is worse: a slab of dimensions `L1 x L2 x L3` with `L1` large and `L2, L3` fixed has surface area `2L2L3` and volume `L1L2L3`, so the halo fraction is `2/L1`. That can be smaller than the cube's `6/L` if `L1` is large enough, but it limits the number of ranks to `L1 / L1_per_rank`. In general, you want the subdomain aspect ratio to match the global grid's aspect ratio, so that the decomposition is balanced and the surface area is minimized for the given number of ranks.

## The distributed roofline

The roofline for a distributed stencil has three ceilings: compute, DRAM bandwidth, and network bandwidth. The kernel is bound by the minimum of the three. Cache blocking and temporal tiling move the DRAM ceiling up by reducing bytes per flop. Halo exchange optimization moves the network ceiling up by reducing messages and overlapping latency, but it cannot change the fundamental bytes-per-flop of the halo exchange. To move the network ceiling, you must increase the subdomain size `L`, which means using fewer ranks or a larger global grid.

A useful design procedure is to compute the three intensities and compare them to the three ridge points. For a given subdomain size `L`, radius `r`, and temporal depth `T`, the DRAM intensity is approximately `7 / Q(T)` flops per byte, where `Q(T)` is the temporal-blocked traffic per point per step. The network intensity is `7L / (48r)` flops per byte. The compute intensity is just the peak flops, but the redundant work from temporal blocking reduces the effective peak by `W(T)`. The kernel will be bound by the smallest of:

```
compute: peak_flops / W(T)
DRAM: bandwidth * (7 / Q(T))
network: network_bandwidth * (7L / (48r))
```

If the network term is the smallest, no amount of cache blocking or temporal tiling will help. You need a larger `L`, a faster network, or an algorithm that exchanges less data. If the DRAM term is the smallest, temporal tiling is the lever. If the compute term is the smallest, you have redundant work to trim: reduce `T` or increase `B`.

This is the design space in one picture. The parameters `B`, `T`, and `L` are not independent: `B` and `T` are constrained by the cache size, `L` is constrained by the number of ranks and the global grid, and all three are constrained by the available parallelism. The optimum is a point where the three ceilings meet, and it shifts as you change the machine, the problem size, and the stencil radius. That is why stencil optimization is an empirical discipline as much as a theoretical one -- but the arithmetic tells you which experiments are worth running.

## Vectorization, data layout, and the cost of being unaligned

The roofline tells you how many bytes you can afford to move. It does not tell you whether the memory system will deliver them at full rate. That depends on the access pattern, and for stencils the access pattern is usually regular but not always optimal.

The first rule is unit stride. In a three-dimensional array stored in row-major order, the fastest-varying index should be the one you vectorize over. If you vectorize along `x`, consecutive lanes access consecutive addresses, and a single cache line feeds an entire vector register. If you vectorize along `z`, each lane touches a different plane, and the hardware must issue a separate memory transaction for each element. The difference is not subtle: on a typical CPU, a unit-stride vector load can use the full bandwidth of a cache line, while a strided load may use only one-eighth of it. On a GPU, the same principle applies with even higher stakes, because the memory system is designed around 128-byte transactions and coalesced access.

The second rule is alignment. A vector load that crosses a cache-line boundary costs two transactions instead of one. The compiler will often generate a peeled loop to align the start of the vectorized region, but it cannot always do so when the array base is not aligned or when the loop bounds are not known at compile time. Allocating arrays with an alignment attribute, or using a library that guarantees 64-byte alignment, removes this source of overhead. For stencils, the halo makes alignment slightly awkward: the first interior point may not be aligned with the vector width, so you need a scalar prologue and epilogue. The cost is small if the grid is large, but it is not zero, and it shows up in the limit of many small subdomains.

The third rule is that the data layout should match the stencil. A seven-point Laplacian has a natural layout: a single three-dimensional array with the three indices in memory order. A multi-component stencil, such as a shallow-water solver with height and two velocity components, has a choice. An array-of-structures layout stores all components for a point contiguously, so a vector load brings in multiple components of the same point. A structure-of-arrays layout stores each component in a separate array, so a vector load brings in the same component for multiple points. The right choice depends on the stencil. If the components are updated independently, structure-of-arrays is usually better because it gives unit-stride access for each component's stencil. If the components interact at every point, array-of-structures may reduce the number of loads, but it complicates vectorization because the lanes are not independent.

A related issue is the write-allocate policy. When a store misses in cache, many processors fetch the cache line before writing it, even though the entire line will be overwritten. For a stencil that writes every point in the grid, this is wasted bandwidth: the line is read from DRAM only to be completely replaced. Non-temporal stores, or streaming stores, bypass the cache and write directly to memory, avoiding the read-for-ownership. On some architectures, they also reduce cache pollution, leaving more of the cache for the input data. The catch is that non-temporal stores are only beneficial if the output is not read again soon. In a temporal blocking scheme, the output of one step is the input of the next, so you want it in cache. In a single-step sweep, the output is not reused until the next time step, so non-temporal stores can help. The decision depends on the temporal depth of the kernel.

## Fusing stencil passes

Many stencil codes apply more than one stencil per time step. A hyperbolic solver may compute fluxes, then update the state, then apply a limiter. A multigrid smoother may compute a residual, then a correction. Each pass reads and writes the grid, so the naive implementation pays the compulsory traffic multiple times. Fusion combines the passes into a single sweep, keeping the intermediate values in registers or shared memory.

The benefit is straightforward. If you have two passes, each with 16 bytes of compulsory traffic per point, fusing them reduces the traffic to 16 bytes per point plus the extra loads for the stencil neighbors. The arithmetic intensity roughly doubles, and on the slanted part of the roofline, so does the throughput. The cost is register pressure. Each fused pass requires its own set of accumulators and neighbor values, and the number of live values grows with the number of passes. If the register file is exhausted, the compiler spills to local memory, which is a cache-backed region of DRAM, and the performance collapses. The art of fusion is to find the largest number of passes that fits in registers without spilling.

A common pattern is to fuse the flux computation with the state update. For a finite-volume scheme, the flux at a face depends on the state on both sides of the face. Instead of computing all fluxes into a temporary array, then updating the state, you can compute the flux for each face on the fly and accumulate it into the state. This requires a small amount of redundant computation at the boundaries between vector lanes, but it eliminates the temporary array entirely. The memory traffic drops from three arrays (state, fluxes, new state) to two (state, new state), and the arithmetic intensity increases accordingly.

Fusion also has a correctness dimension. If the passes are not independent, fusing them changes the order of operations, which can change the floating-point result. For most stencils, the difference is at the level of round-off, but for some schemes, such as those with limiters or nonlinear switches, the order matters. You should verify that the fused version produces the same results as the unfused version, or at least the same results within the tolerance of the scheme.

## Higher-order stencils and the arithmetic-intensity illusion

It is tempting to think that a higher-order stencil, with more points and more flops, will have a higher arithmetic intensity and therefore run closer to peak. The arithmetic is more subtle. For a three-dimensional stencil of radius `r`, the number of points in the stencil is `(2r+1)^3`. If you compute the update directly, each output point requires `(2r+1)^3` loads and roughly `2(2r+1)^3` flops. The ratio of flops to bytes is therefore `2 / 8 = 0.25` flops per byte, independent of `r`. The extra flops are matched by extra loads, and the arithmetic intensity does not improve.

The situation changes if the stencil is separable. A separable stencil can be applied as a sequence of one-dimensional stencils, one along each axis. For a radius-`r` stencil, each one-dimensional pass has `2r+1` points and requires `2(2r+1)` flops per point. If you apply the three passes in sequence, the intermediate arrays are written and read, so the memory traffic is three times the compulsory traffic, but the flops are only `O(r)` per point instead of `O(r^3)`. The arithmetic intensity of the separable version is `O(r)` flops per byte, which grows with `r`. However, the three-pass implementation has poor locality: each pass streams the entire grid. If you fuse the three passes into a single sweep, you can keep the intermediate values in registers and achieve the same `O(r)` flops per byte with compulsory traffic. This is the standard technique for high-order stencils, and it is the reason why spectral and pseudo-spectral methods, which are separable, can be much more efficient than their finite-difference counterparts.

The catch is that fusing separable passes requires a larger register footprint. For a radius-`r` stencil, you need to keep `2r+1` values along the fastest axis, plus the partial results from the other two axes. For `r = 4`, that is nine values per point, which is manageable. For `r = 8`, it is seventeen values, which may exceed the register file. In that case, you can split the stencil into a few smaller passes, or use shared memory to stage the intermediate values. The design space is again a trade-off between arithmetic intensity and register pressure, and the optimum depends on the machine.

## Multi-component and multi-physics stencils

Multi-component stencils are common in computational fluid dynamics, where the state vector contains density, momentum, and energy. Each component is updated by a stencil that may depend on all other components. The arithmetic intensity of the combined update is higher than that of a single-component stencil because the same neighbor values are used for multiple components. If you load the neighbor state once and compute all components, you amortize the load over several flops. For a five-component state, the arithmetic intensity can be five times higher than for a scalar stencil, which moves the kernel closer to the compute roofline.

The data layout matters even more here. If you use an array-of-structures layout, a vector load brings in all five components for a single point, which is efficient for the update but awkward for vectorization across points. If you use a structure-of-arrays layout, you can vectorize across points for each component, but you must load the same neighbor indices for each component, which means five separate loads. The total bytes moved are the same, but the access pattern is different. In practice, the structure-of-arrays layout is usually preferred because it gives unit-stride access for each component and allows the compiler to use vector loads for the neighbor values. The array-of-structures layout is better when the components are tightly coupled and the update is not vectorizable across points.

Another consideration is the number of registers. A multi-component stencil with a radius-1 neighborhood needs to keep the neighbor values for all components in registers. For a three-dimensional stencil, that is 27 neighbor points times the number of components. With five components, that is 135 values, which is far beyond the register file. The compiler must spill, and the performance suffers. The solution is to block the stencil in space and process a small tile of points at a time, so that the neighbor values are reused across the tile. This is the same cache-blocking idea, but applied at the register level. The tile size is chosen so that the working set fits in registers, and the redundant loads are amortized over the tile.

## Boundary conditions and the cost of the edge

The boundary is a small fraction of the grid, but it can be a large fraction of the code. A naive implementation puts a branch inside the inner loop to check whether the current point is on the boundary. The branch is predictable, so it does not cost much in terms of misprediction, but it prevents vectorization and adds instruction overhead. The standard fix is to separate the boundary from the interior. The interior loop has no branches and can be vectorized. The boundary loop handles the edges, faces, and corners, and it can be written as a separate kernel with its own optimized code.

The boundary kernel is often memory-bound and latency-bound, because it processes a small number of points with irregular access patterns. It is tempting to ignore it, but on a small grid, or on a subdomain in a distributed run, the boundary can be a significant fraction of the work. For a subdomain of side `L`, the boundary layer has `O(L^2)` points, while the interior has `O(L^3)` points. The ratio is `O(1/L)`, so for `L = 64`, the boundary is about 5 percent of the points. That is small but not negligible. If the boundary kernel is ten times slower than the interior kernel, it can account for a third of the runtime.

The solution is to make the boundary kernel as efficient as possible. Use the same vectorization and blocking strategies as the interior, but with a smaller tile. For periodic boundaries, you can use a ghost layer and copy the values from the opposite face, which turns the boundary into a regular stencil update. For Dirichlet boundaries, you can set the ghost values to a constant and use the same interior kernel. For Neumann boundaries, you can copy the adjacent interior value. In all cases, the goal is to avoid branches in the inner loop and to keep the boundary work proportional to the surface area.

## Autotuning and parameter search

The design space we have described has several parameters: the spatial block size `B`, the temporal depth `T`, the vector width, the number of threads, the cache-blocking strategy, and the layout. The optimal values depend on the machine, the grid size, the stencil radius, and the number of ranks. There is no closed-form solution that works for all cases. The practical approach is autotuning: define a parameter space, run the kernel for a set of configurations, and choose the best one.

Autotuning is most effective when the parameter space is small and the parameters are independent. For stencils, the most important parameters are the block size and the temporal depth. The block size is constrained by the cache size, and the temporal depth is constrained by the register file and the cache. You can often reduce the search space by using a model to predict the performance and then validating the top candidates. For example, the roofline model can predict the DRAM traffic for a given `B` and `T`, and you can use that to filter out configurations that are obviously bad. The remaining configurations can be benchmarked.

The search itself is a form of optimization. A simple grid search is often sufficient because the performance surface is smooth and the optimum is broad. If the surface is noisy, you can use a few repetitions and take the median. If the search space is large, you can use a random search or a Bayesian optimizer. The key is to make the search automatic and to include it in the build process, so that the kernel is tuned for the machine it will run on. This is the approach taken by libraries like Halide, TVM, and Kokkos, and it is the reason why stencil performance can vary by a factor of two or more between a hand-tuned kernel and a portable one.

## Measurement and the pitfalls of the roofline

The roofline is a model, not a measurement. It assumes that the kernel can achieve the peak bandwidth and the peak flops simultaneously, which is never true. The attainable bandwidth is usually 60 to 80 percent of the theoretical peak, and the attainable flops are lower when the kernel is not perfectly vectorized. When you compare your kernel to the roofline, you are comparing it to an upper bound that is not achievable. The useful comparison is to a well-optimized microbenchmark, such as a copy or a triad, that measures the same memory system with the same access pattern.

It is also important to count the right bytes. The roofline model counts DRAM traffic, but the hardware counters may count cache traffic or memory transactions. A kernel that reads a cache line twice may show twice the L1 traffic but the same DRAM traffic. If you are trying to determine whether a kernel is DRAM-bound, you should use the DRAM counters. If you are trying to determine whether it is cache-bound, you should use the L1 or L2 counters. The roofline model is only as good as the counters you feed it.

Finally, beware of the 'peak flops' trap. The peak flops of a processor are usually quoted for a specific instruction mix, such as fused multiply-add, and for a specific vector width. A stencil that uses only additions and multiplications may not reach that peak, even if it is perfectly vectorized. The effective peak is lower, and the ridge point is higher. If you use the theoretical peak in your roofline model, you will overestimate the compute ceiling and underestimate the importance of bandwidth. The correct approach is to use the attainable flops for your kernel, which you can measure with a compute-bound microbenchmark, and the attainable bandwidth, which you can measure with a memory-bound microbenchmark. The ratio of the two is the ridge point you should use.

---

That is the design space in one picture. The parameters `B`, `T`, and `L` are not independent: `B` and `T` are constrained by the cache size, `L` is constrained by the number of ranks and the global grid, and all three are constrained by the available parallelism. The optimum is a point where the three ceilings meet, and it shifts as you change the machine, the problem size, and the stencil radius. That is why stencil optimization is an empirical discipline as much as a theoretical one -- but the arithmetic tells you which experiments are worth running.

## Mixed precision and the memory-traffic lever

The roofline arithmetic treats the data type as a constant. In double precision, a seven-point Laplacian moves 16 bytes per point per time step at minimum: one 8-byte read and one 8-byte write. Switch the state to single precision and the compulsory traffic halves to 8 bytes per point per step. The flop count is unchanged if the arithmetic is still performed in double precision after loading single-precision values, but that is rarely what happens in practice. The usual pattern is to store the state in single precision, accumulate the stencil in single precision or in a wider type, and write the result back in single precision. The roofline intensity then rises from roughly 0.44 to roughly 0.875 flops per byte for the same useful flop count. On the slanted part of the roofline, that is a near-doubling of attainable throughput, which is why mixed precision is one of the few levers that can move a bandwidth-bound stencil without changing the algorithm.

The catch is that precision is not a free parameter. Reducing the state to single precision changes the truncation error, the accumulation error, and the stability bound of the time integrator. For a wave equation, the numerical dispersion relation depends on the precision of the coefficients and the field values. For a diffusion problem, the error accumulates over many steps, and single precision may exhaust its significant digits long before the simulation ends. The safe approach is to treat precision as a design variable: choose the simplest precision that satisfies the error tolerance, then verify it with a convergence study. If the scheme is already second-order accurate, single precision may be entirely adequate for moderate grid sizes, because the discretization error dominates the round-off error. If the scheme is spectral or high-order, double precision may be necessary to preserve the accuracy.

There is also a hardware dimension. Some processors execute single-precision arithmetic at twice the rate of double precision, especially on vector units and accelerators. In that case, reducing precision improves both the memory traffic and the compute ceiling. The ridge point moves: the peak flops rise, but the bandwidth stays the same, so the ridge point in flops per byte moves to the right. A kernel that was bandwidth-bound in double precision may still be bandwidth-bound in single precision, but it will be closer to the knee. The correct comparison is not single precision is faster but the roofline position for the selected precision is whatever it is, and that position depends on the attainable bandwidth and the attainable flops for that type.

Mixed precision can also be applied selectively. The state may be stored in single precision while the coefficients are kept in double precision, or the stencil may be applied in single precision but the time integration accumulated in double precision. Each choice changes the traffic and the error. A common pattern in iterative solvers is to use a low-precision preconditioner and a high-precision residual. For stencils, the analogous pattern is to use a low-precision update for most steps and a high-precision correction every few steps. The performance model is the same: count the bytes for each buffer and the flops for each pass, then compute the intensity of the combined kernel. The design space is larger, but the arithmetic is still mechanical.

## Asynchronous and communication-avoiding temporal blocking

The previous sections treated halo exchange as a synchronous operation: each rank exchanges halos, then computes, then exchanges again. In practice, the exchange is usually asynchronous. The rank posts nonblocking receives, packs and sends its halo buffers, computes the interior, waits for the receives, and then computes the boundary. The overlap window is the time it takes to compute the interior, which is of order (L - 2r)^3 flops. For large L, that window is long enough to hide the network latency of a single exchange. The limiting factor is not the latency but the bandwidth: the exchange consumes memory bandwidth on both the sending and receiving sides, and on many systems the network interface card's DMA traffic competes with the stencil's own memory traffic.

Asynchronous exchange is a latency-hiding technique, not a bandwidth-reducing technique. It does not change the number of bytes that must cross the network. To change the bytes, you must change the algorithm. Communication-avoiding temporal blocking does exactly that: it increases the temporal depth T, exchanges a wider halo rT once every T steps, and computes redundantly in the extended shell. As derived earlier, the bytes per step are unchanged, but the number of messages falls by a factor of T. If the network is latency-bound or message-rate-bound, this is a large win. If the network is bandwidth-bound, it is not.

There is a second form of communication avoidance that does change the bytes: redundant computation over a wider region. Suppose each rank is responsible for an L^3 subdomain but computes a region of side L + 2rT. To do that, it needs initial data over the larger region. If the initial data is already distributed, each rank must receive the extra shell from its neighbors. That is a one-time exchange of 6rT L^2 cells. After that, the rank can advance T steps without any communication, because it has all the data it needs. The final central L^3 is correct; the outer shell is redundant. The communication volume per step is 6rT L^2 / T = 6r L^2, exactly the same as exchanging a width-r halo every step. So redundant computation does not reduce the asymptotic communication volume either. It reduces the frequency, not the total.

The only way to reduce the asymptotic communication volume is to increase L, the subdomain side length. That means using fewer ranks, a larger global grid, or a different decomposition. For a fixed global grid and a fixed number of ranks, the surface-to-volume ratio is fixed by the decomposition. This is why strong scaling of stencil codes is fundamentally limited: the halo fraction 6r/L grows as L shrinks, and no scheduling trick can make it disappear. The practical goal is to keep the halo fraction below the point where communication time exceeds compute time. If the compute time per step is C L^3 and the communication time per step is N 6r L^2, where C is the per-point compute cost and N is the per-byte network cost, then the ratio is N 6r / (C L). The crossover is at L = 6r N / C. For a machine with fast network and slow compute, that crossover can be small; for a machine with slow network and fast compute, it can be large. The arithmetic tells you which regime you are in.

Asynchronous execution also raises a scheduling question: what happens when the wavefront of one rank advances faster than its neighbor's? In a stencil, the answer is that the faster rank must wait, because it cannot compute its boundary until the neighbor's halo arrives. This is a load-imbalance problem. If the work per rank is equal, the wait is bounded by the network jitter. If the work is unequal, the fastest ranks stall while the slowest catch up. The usual fix is to over-decompose: use more subdomains than cores, and let a scheduler assign subdomains to cores as they become free. This is the same idea as task-based runtime systems, and it is particularly effective for adaptive or irregular stencils where the cost per point varies.

## I/O, checkpointing, and the extended roofline

Long-running stencil simulations must write checkpoints, diagnostics, and visualization data. These writes are part of the memory traffic, and they can dominate the roofline if they are frequent. Suppose the grid contains N points and a checkpoint writes 8N bytes. If a checkpoint is written every K time steps, the checkpoint traffic per step is 8N/K bytes. The stencil's compulsory traffic per step is 16N bytes. The checkpoint adds a fraction 1/(2K) to the traffic. For K = 100, that is 0.5 percent, which is negligible. For K = 10, it is 5 percent, which is noticeable but not fatal. For K = 1, it doubles the traffic.

The problem is that checkpoints are usually written through the same memory system as the stencil. The write goes to the page cache, then to the file system, then to disk or to a parallel file system. Each of these stages consumes bandwidth. On a distributed run, the checkpoint may be written by all ranks simultaneously, which creates a burst of network and storage traffic. The burst can stall the stencil even if the average checkpoint traffic is small, because the stencil cannot proceed until the I/O subsystem drains the burst. The standard fixes are to write asynchronously, to compress the data, to write from a subset of ranks, or to use a parallel file system that can absorb the burst. From a roofline perspective, the checkpoint is an additional term in the bytes-per-step budget, and it must be included in the arithmetic.

The same logic applies to in-situ analysis. If the simulation sends data to a visualization or analysis process every few steps, that transfer is part of the communication budget. It may be small relative to the halo exchange, or it may be larger if the analysis requires the full field. The design choice is whether to write the data to storage and analyze it later, or to analyze it in memory while the simulation runs. In-situ analysis avoids the storage traffic but adds communication traffic and consumes compute resources that could be used for the stencil. The roofline model for the combined simulation-plus-analysis system has more terms, but the method is the same: count the bytes, count the flops, and identify the smallest ceiling.

## Topology-aware rank placement and subdomain mapping

The surface-to-volume ratio tells you how much data must cross the network. It does not tell you how long that crossing will take. The time depends on the network topology, the routing, and the placement of ranks. On a torus or a mesh, neighboring ranks should be placed on neighboring nodes. On a fat-tree, the placement matters less for bandwidth but can still matter for latency and for congestion. A Cartesian decomposition is convenient because the halo exchange partners are known: each rank sends to and receives from its six face neighbors, plus edges and corners. If the rank numbering is chosen so that face neighbors are close in the physical network, the exchange is faster.

The standard approach is to build a Cartesian communicator whose dimensions match the subdomain grid. The communicator assigns ranks to coordinates, and the runtime maps those coordinates to physical nodes. If the mapping is not topology-aware, a face exchange may cross the network core instead of a single switch. The effect is usually modest at small scale but becomes significant at large scale, where bisection bandwidth is a scarce resource. A topology-aware mapping can reduce the number of hops and the likelihood of congestion. The details depend on the interconnect, but the principle is general: communication costs are not uniform, and the decomposition should account for that.

There is also the question of what to exchange. In three dimensions, a face exchange is a contiguous 2D slab, which can be packed into a single buffer and sent with one message. An edge exchange is a 1D line, and a corner exchange is a single point. The face exchanges carry most of the bytes; edges and corners carry relatively little. A common optimization is to include edges and corners in the face buffers, so that each rank sends one message per face and the message contains the face, its edges, and its corners. This reduces the number of messages and the number of synchronization points. The packing cost is small compared to the network cost. The roofline term for the network does not change, but the achievable fraction of the peak network bandwidth improves.

For unstructured or adaptive stencils, the decomposition is not Cartesian, and the halo is obtained from a graph partition. The surface-to-volume ratio is replaced by the edge cut of the partition, and the same principle applies: minimize the cut while balancing the work. The arithmetic is less clean because the number of neighbors per rank varies, but the roofline model still holds with the appropriate counts. The design space is larger, but the first question is always the same: how many bytes must cross the network per useful flop, and is that term the smallest ceiling?
