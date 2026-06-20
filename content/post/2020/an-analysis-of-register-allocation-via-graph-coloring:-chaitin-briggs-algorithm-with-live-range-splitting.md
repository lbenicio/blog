---
title: "An Analysis Of Register Allocation Via Graph Coloring: Chaitin Briggs Algorithm With Live Range Splitting"
description: "A comprehensive technical exploration of an analysis of register allocation via graph coloring: chaitin briggs algorithm with live range splitting, covering key concepts, practical implementations, and real-world applications."
date: "2020-09-17"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/an-analysis-of-register-allocation-via-graph-coloring-chaitin-briggs-algorithm-with-live-range-splitting.png"
coverAlt: "Technical visualization representing an analysis of register allocation via graph coloring: chaitin briggs algorithm with live range splitting"
---

# The Silent Performance Tax: How Your Compiler Plays Graph Coloring with Your CPU’s Most Precious Resource

You have just spent the last four hours debugging a performance-critical function. The logic is elegant, the algorithm is asymptotically optimal, and the data structures are perfectly chosen. You lean back, satisfied, only to run your benchmark and discover a horrifying 40% slowdown compared to your hand-tuned assembly version. The culprit isn't your algorithm. It’s the invisible bureaucracy running inside your CPU: the register allocator. It has made a terrible, costly decision, deciding to dump a frequently used variable into main memory, wasting hundreds of cycles on a single load, because it simply ran out of physical space.

This is the silent performance tax paid by every compiled language. Every `mov` instruction, every function call, every tight loop is a negotiation between the infinite, abstract world of the source code and the brutally finite, physical reality of the processor’s register file. A register is the only memory that can be operated on directly by arithmetic logic. Accessing it takes a single cycle. Accessing a value in L1 cache takes ~4 cycles. Accessing RAM... well, let's just say it's an eternity in CPU time (around 100-200 cycles). The critical bottleneck of modern compilation is not about how clever your data structure is on paper, but how well the compiler can keep that data in the one place where it can be processed instantly.

For decades, this problem—finding the most efficient way to map an unlimited number of programmer-defined variables into a severely limited number of physical machine registers—has been a cornerstone of compiler optimization theory. The classic solution, first proposed by Gregory Chaitin at IBM in the early 1980s, was a stroke of genius that re-framed the problem entirely. It wasn't a scheduling problem, nor a packing problem. It was a _graph coloring_ problem.

Chaitin’s insight was both elegant and profound. He realized that the core difficulty of register allocation—deciding which variables should share a register and which must be kept apart—is mathematically equivalent to a well-known combinatorial problem: coloring the vertices of a graph so that no two adjacent vertices share the same color. The colors are physical registers, the vertices are the “live ranges” of variables (the periods during which a variable holds a value that will be used later), and the edges represent conflicts: two variables whose live ranges overlap cannot occupy the same register. Finding an assignment of registers with at most `k` colors (where `k` is the number of available registers) is exactly the same as deciding whether a graph is `k`-colorable. And as Chaitin proved, this problem is NP-complete in general. Your compiler is solving an NP-complete problem every time you press “Compile.”

Yet real compilers do this in seconds, not hours. How? By using clever heuristics, approximations, and the simple fact that most programs’ interference graphs are not worst-case monsters. In this deep dive, we will walk through the full algorithm Chaitin invented, examine every phase with concrete examples, explore modern improvements that power LLVM and GCC, and understand why—even after forty years—register allocation remains one of the most fascinating and impactful domains of compiler engineering.

---

## 1. The Register Allocation Problem: A Matter of Life and Cycles

Before diving into graph coloring, we need to appreciate the stakes. Modern processors have a small number of general-purpose registers (16 in x86-64, 31 in AArch64, 16 in RISC-V). Each register can hold one machine word (typically 64 bits). Your source code, on the other hand, may define hundreds of variables in a single function. Even after optimization passes like constant propagation and dead code elimination, intermediate representations easily contain dozens of virtual registers—temporary values that need a physical home.

The register allocator’s job is to map these virtual registers to physical registers during the code generation phase. When the supply of physical registers runs out, the allocator must _spill_ some values to memory (stack slots). Spilling inserts load and store instructions to move data between registers and memory. Each spill adds latency, consumes instruction cache, and often breaks optimizations like instruction scheduling.

But the problem is not just about counting variables. It’s about _when_ they live. Two variables that are never alive at the same time can safely share the same register. For example, in the sequence `a = …; … = a; b = …; … = b;`, `a` and `b` could use the same register if `a` is dead before `b` is defined. This is the essence of liveness analysis.

### 1.1. Liveness: The Hidden Life of a Variable

A variable is _live_ at a program point if its current value will be read before it is overwritten. Liveness is computed via backward dataflow analysis. For each instruction, we define:

- **Def**: the set of variables defined (written) by the instruction.
- **Use**: the set of variables used (read) by the instruction.
- **In**: variables live on entry to the instruction.
- **Out**: variables live on exit from the instruction.

The dataflow equations are:

\[
\text{In}[i] = \text{Use}[i] \cup (\text{Out}[i] - \text{Def}[i])
\]
\[
\text{Out}[i] = \bigcup\_{j \in \text{succ}(i)} \text{In}[j]
\]

We compute fixed points by iterating backward over the control-flow graph. The result is a set of live variables at every program point. From this, we extract _live ranges_: intervals (possibly spanning multiple basic blocks) during which a variable holds a value that may be used later. Importantly, if a variable is defined multiple times, it may have multiple distinct live ranges.

### 1.2. The Interference Graph: Drawing the Battle Lines

Once we have live ranges, we build an interference graph (IG). Each vertex represents a live range. An edge exists between two vertices if their live ranges overlap at any program point. If two live ranges interfere, they cannot reside in the same physical register simultaneously. If they do not interfere, they can share a register—this is called _register assignment_, and it is the goal of graph coloring.

The interference graph captures all the constraints. The register allocator’s job reduces to: given an IG with `n` vertices and a palette of `k` colors, assign each vertex a color such that no two adjacent vertices share the same color. If possible, the function uses only `k` registers. If not, we must spill some vertices (remove them from the graph, insert memory operations, and retry).

### 1.3. Why Graph Coloring?

Why not just pack variables into registers greedily? Because a greedy algorithm that assigns registers in program order can easily make a decision early that forces a spill later, even if a different ordering would have fit everything. Graph coloring, by looking at the global conflict structure, can make better decisions. It is also a natural framework for spilling: when the graph is not `k`-colorable, we choose a vertex to spill, which removes it and all its edges, potentially making the remaining graph colorable.

The equivalence to graph coloring was first formalized by Chaitin et al. in 1981 (paper: _Register Allocation via Coloring_). The NP-completeness result came shortly after: Chaitin showed that register allocation with `k` registers is NP-complete (by reduction from graph `k`-coloring). In practice, however, the interference graphs of real programs often have special structure—they are _interval graphs_ in straight-line code, and even in loops they rarely hit the pathological cases. Compilers use a heuristic called the _simplify_ phase, which removes vertices with degree less than `k` (i.e., those that can always be colored no matter what), and then spills a vertex when stuck. This simple approach works remarkably well.

---

## 2. Chaitin’s Algorithm: The Blueprint

Chaitin’s algorithm consists of five phases, which may be repeated if spilling occurs. The original paper described them as:

1. **Liveness analysis** – compute live ranges.
2. **Build the interference graph** – vertices from live ranges, edges from interference.
3. **Coalesce** – merge pairs of non-interfering move-related vertices (optimization, we’ll discuss later).
4. **Simplify** – repeatedly remove vertices of degree < k, pushing them onto a stack.
5. **Select** – pop vertices and assign colors (registers) from the palette, respecting that already-assigned neighbors use certain colors.
6. (If any vertex cannot be colored) **Spill** – mark a vertex for spilling, insert loads/stores, and restart from liveness analysis.

Let’s walk through each phase with a concrete example.

### 2.1. A Simple Function and Its Liveness

Consider this C-like code (left) and its three-address code (right):

```c
int foo(int x, int y) {
    int a = x + 1;
    int b = a * 2;
    int c = b - 3;
    return c + y;
}
```

Three-address code with virtual registers (v0..v3):

```
// assume x, y in v0, v1
L0: v2 = v0 + 1       // a = x+1
L1: v3 = v2 * 2       // b = a*2
L2: v4 = v3 - 3       // c = b-3
L3: v5 = v4 + v1      // return c+y
```

For simplicity, assume only one live range per virtual register (no redefinitions). Liveness analysis backward:

- At L3 (return): uses v4, v1. Defines v5 (but v5 is used nowhere after return, so it is dead on exit). So: In[L3] = {v4, v1}.
- At L2: defines v4 (the new c). Uses v3. Out[L2] = In[L3] = {v4, v1}. Since L2 defines v4, the old v4 is killed. In[L2] = Use[L2] ∪ (Out[L2] - Def[L2]) = {v3} ∪ ({v4, v1} - {v4}) = {v3, v1}.
- Continue: L1 defines v3, uses v2. Out[L1] = In[L2] = {v3, v1}. Def kills v3. In[L1] = {v2} ∪ ({v3, v1} - {v3}) = {v2, v1}.
- L0 defines v2, uses v0. Out[L0] = In[L1] = {v2, v1}. Defs kills v2. In[L0] = {v0} ∪ ({v2, v1} - {v2}) = {v0, v1}.

Thus, the live ranges are:

- v0: from L0 (entry) to L0 (exit) – but since v0 is used only in L0, it is live from entry to L0 (before the def?). Actually careful: x is a parameter, live on entry, used in L0, then dead after L0. So live range: [entry, L0] (excluding after L0).
- v1: live on entry (y) and used in L3. So live from entry to L3, but also holds value until last use. Live range: [entry, L3].
- v2: defined in L0, used in L1. Live [L0, L1].
- v3: defined in L1, used in L2. Live [L1, L2].
- v4: defined in L2, used in L3. Live [L2, L3].

Now we can spot interferences:

- v0 and v1 interfere because both live on entry.
- v0 and v2? v0 dies before v2 is used? Actually v0 live until L0, v2 live from L0 (after def) to L1. At L0, after the instruction, v0 is no longer used (it is dead), while v2 becomes live. But we need to check interference at the point _immediately before_ the instruction. Classic interference condition: two live ranges interfere if there exists a program point where both are simultaneously live. At entry, v0 and v1 are live. At L0 before instruction, v0 and v1 are live, and v2 is not yet live (its def hasn't happened). After L0, v0 is dead, v2 is live. So no point where v0 and v2 are both live. Thus no edge. Similarly, v1 is live almost everywhere; it interferes with v2, v3, v4? Let's check:
- At L0 after: v1 live, v2 live (they coexist from L0 to L1). So v1 interferes with v2.
- At L1 after: v1 live, v3 live => edge.
- At L2 after: v1 live, v4 live => edge.
- v2 and v3? v2 live until L1, v3 live from L1 to L2. At L1 after instruction, v2 may be dead (its last use is in L1). Typically, the last use point: if v2 is used in L1 and then not used again, we consider v2 dead after L1’s use. So v2 and v3 do not overlap—v2 dies right before v3 is defined? Actually careful: L1 defines v3 after using v2. So the use of v2 happens before the def of v3. There is no point where both are live. So no edge. Similarly, v3 and v4 do not overlap.
- v2 and v4? No overlap.
- v3 and v1 we already have edge.
- v4 and v1 edge.

So interference graph vertices: v0, v1, v2, v3, v4. Edges: (v0,v1), (v1,v2), (v1,v3), (v1,v4). That’s it. This graph is a star centered at v1 with leaves v0, v2, v3, v4.

Now, suppose we have 3 available registers (k=3). Can we color this graph? v1 has degree 4 > 2 (k-1)? Actually degree 4 >= k, so we cannot directly simplify v1. However, v0 has degree 1 < k, so we can push v0 onto stack. Simplify v0: remove it, edges (v0,v1) gone. New degrees: v1 now has 3 neighbors (v2,v3,v4). Still degree 3 >= k? k=3, degree 3 is not < k (needs <3). So v1 is still not simplify-able. Other vertices v2, v3, v4 each have degree 1 (only v1). They are <3, so we can push them. For example, push v2, then v3, then v4. After removing them, remaining graph has only v1 (degree 0). Push v1. Stack (from bottom to top): v0, v2, v3, v4, v1? Wait order matters: we pushed v0 first, then v2, v3, v4, v1. Actually let's do systematically:

- Initial graph G. Low-degree vertices (degree < k): v0 (deg=1), v2 (deg=1), v3 (deg=1), v4 (deg=1). v1 deg=4 not low.
- Pick one low-degree vertex, e.g., v0. Push v0 on stack. Remove v0 and its edges. New graph: v1 deg=3, v2 deg=1, v3 deg=1, v4 deg=1.
- Now v2, v3, v4 are still low-degree. Pick v2, push, remove. v1 deg=2 (neighbors v3,v4). Still v1 deg=2 < k? k=3, so deg=2 <3 → now v1 becomes low-degree! So we can push v1 now. But we have others. Actually after removing v2, v1 has degree 2 (v3,v4). That is <3, so v1 is low-degree. We can push v3, v4, then v1. Let’s order: push v3 (remove), v1 deg=1, push v4 (remove), v1 deg=0, push v1. Stack: [v0, v2, v3, v4, v1] (top).

Now selection: pop v1 first. In empty graph, assign any color say r1. Pop v4: neighbors? v4 was connected to v1 only (which is now assigned r1). So v4 can take any other color, e.g., r2. Pop v3: neighbor v1 only → pick r2 or r3. Pop v2: neighbor v1 only → pick available. Pop v0: neighbor v1 only → pick available. So all colored without spilling. This shows that even though v1 had high degree initially, after removing leaves it became colorable. This demonstrates the power of simplification: it doesn't remove high-degree vertices if they later become low-degree after neighbors are removed.

### 2.2. What If We Need to Spill?

If the graph is not `k`-colorable even after simplification, we reach a state where all remaining vertices have degree >= k. Then we choose a vertex to spill—typically the one with the lowest _spill cost_ (estimated as the number of extra loads/stores divided by the number of uses). We mark that vertex as spilled, remove it from the graph (which may make other vertices low-degree), and continue simplification. At the end of selection, spilled vertices get assigned a stack slot. Then we must insert load instructions before each use and store instructions after each definition, which creates new live ranges and potentially new interferences. The entire algorithm is rerun on the modified code. This iteration can repeat, but usually converges quickly.

---

## 3. Advanced Phases: Coalescing and Rematerialization

Chaitin’s original algorithm also included a _coalescing_ step. Coalescing merges pairs of non-interfering move-related nodes. A _move_ instruction copies a value from one register to another (e.g., `v4 = v1`). If we can assign the same register to both source and destination, the move becomes a no-op and can be eliminated. Coalescing merges the two live ranges into one, reducing the number of vertices and potentially simplifying the graph. However, merging may increase the degree of the combined vertex, potentially causing spills. Modern compilers use _conservative coalescing_ (Briggs et al.), which only merges if the combined node has fewer than `k` neighbors with degree >= `k`, ensuring that merging does not make the graph uncolorable.

Another important optimization is _rematerialization_. Instead of spilling a value to memory and reloading it, the compiler can recompute it from cheaper operands. For example, a constant or a simple expression like `x + 0` can be recomputed with a single instruction instead of a memory load. This is especially powerful for values that are cheap to compute but expensive to spill.

---

## 4. From Theory to Practice: Implementation Realities

Most production compilers (GCC, LLVM, and many industrial backends) implement variations of Chaitin-Briggs graph coloring. Let’s look at how LLVM handles register allocation (RegAllocGreedy or RegAllocBasic). LLVM’s greedy allocator uses a priority-based approach: it processes live ranges in order of descending spill cost, attempting to allocate registers while using interference graph constraints. It doesn’t build the full graph upfront but uses a union-find data structure to model interference on the fly. This makes it faster and more scalable, but the underlying principle remains the same.

### 4.1. Spill Cost Heuristics

Choosing which variable to spill is critical. The heuristic must balance:

- **Number of uses** (more uses → more loads/stores if spilled).
- **Dynamic frequency** (inside a loop, spilling is more expensive than outside).
- **Register pressure** (variables with many interfering neighbors may cause more spills if not chosen).

Typical cost: `cost = sum_over_uses(10^depth_of_loop)`. Deeper loops have higher weight. The allocator will prefer to spill variables with low cost and high degree (to reduce graph complexity).

### 4.2. Handling of Callee-Save Registers

In most ABIs, the calling convention designates some registers as _callee-saved_: the called function must preserve their values for the caller. The register allocator must ensure that at function entry, these registers are saved (spilled to stack) if used, and restored before return. This adds extra live ranges for the saved values and complicates coloring. Modern allocators treat callee-save registers as part of the color palette but with an additional cost: using a callee-save register incurs a spilling cost (save/restore). The allocator may prefer caller-save registers for short-lived values and use callee-save for values that live across many calls.

### 4.3. Register Allocation for Vector/SIMD

Modern processors have separate register files for floating-point and vector operations (e.g., x86 XMM/YMM/ZMM registers, ARM NEON/SSE). Register allocation for these works similarly, but the number of colors differs (e.g., 16 XMM registers, 32 ZMM registers). Additionally, vector registers often hold multiple elements, and allocation may need to consider alignment and sub-register access.

---

## 5. The Rise of Linear Scan: Speed Over Optimality

While graph coloring is the gold standard for static compilation, JIT compilers (e.g., in Java HotSpot, JavaScript V8) need fast allocation because they compile code at runtime. For these, _linear scan_ register allocation is preferred. It was popularized by Poletto and Sarkar in 1999.

Linear scan works in a single pass over the live ranges sorted by start point. It maintains a set of active live ranges (currently live) and a set of free registers. When a new live range starts, it assigns a free register if available; otherwise, it spills the active live range with the _farthest next use_. This is a greedy approach that runs in O(n log n) time, far cheaper than building an IG. It often produces acceptable code, though it can miss opportunities for better decisions when live ranges are overlapping in complex ways. Many JITs combine linear scan with small amounts of global analysis to improve quality.

---

## 6. A Concrete Performance Example

Let’s examine a real C function and its generated assembly with different optimization levels to see register allocation at work.

```c
// test.c
int sum_array(int *arr, int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        sum += arr[i];
    }
    return sum;
}
```

Compile with `gcc -O0 -S test.c` (no optimization) vs `-O2`. With `-O0`, the compiler spills almost everything to memory: `sum` is stored on stack, `i` on stack, even the loop counter. The assembly is full of loads and stores—slow but easy to debug. With `-O2`, the compiler keeps `sum` in a register (`eax`), `i` in a register (`edx`), and the array pointer in a register (`rcx`). The inner loop becomes tight: `add eax, [rcx + rdx*4]`. No spills, minimal instructions. The performance difference can be 10x or more on large arrays.

Now consider a more complex function with many live ranges:

```c
int many_vars(int a, int b, int c, int d, int e) {
    int x = a + b;
    int y = c + d;
    int z = e + x;
    int w = y + z;
    return w;
}
```

This has 9 virtual registers (including args). With 16 x86-64 registers, no spills occur at `-O2`. But on a 32-bit architecture with only 6 registers (x86-32: eax, ecx, edx, ebx, esi, edi—some reserved), spilling becomes inevitable. The allocator must decide which of `a, b, c, d, e, x, y, z, w` to keep and which to spill. Graph coloring will pick the best combination.

---

## 7. Beyond Chaitin: Modern Research Directions

Graph coloring dominated for decades, but recent research explores alternatives:

- **Partitioned Boolean Quadratic Programming (PBQP)**: formulates allocation as a combinatorial optimization problem solvable with specialized algorithms. It can model more complex costs, including cross-instruction benefits.
- **Integer Linear Programming (ILP)**: exact solution for small functions, used in research compilers.
- **Sparse Graph Coloring**: exploits the sparsity of typical interference graphs to use simpler heuristics.
- **Machine Learning**: train a model to predict optimal spill decisions based on program features. Still experimental but promising.

Nevertheless, Chaitin’s framework underpins all these: the idea of interference graph and coloring remains central.

---

## 8. Conclusion: The Invisible Art of Keeping Data Close

Register allocation is a masterpiece of theoretical computer science applied to practical engineering. Chaitin’s insight—that mapping variables to registers is isomorphic to graph coloring—transformed a messy, ad‑hoc problem into a clean, formal one. The algorithm he devised, with its phases of liveness analysis, graph building, simplification, and spill iteration, has been the backbone of compilers for forty years. Its beauty lies in its simplicity: a small number of heuristics, a clear termination condition, and a proven ability to generate near‑optimal code for real‑world programs.

Next time you compile a performance‑critical function and marvel at the tight assembly generated by `-O2`, remember the invisible hand of the register allocator. It’s solving an NP‑complete problem in milliseconds, deciding where every value lives, and in doing so, determining whether your loop runs at 3 cycles per iteration or 30. The next time you see a 40% slowdown, you might just be witnessing a spilled variable—a single bad decision in a combinatorial sea. But thanks to Chaitin and his intellectual descendants, those decisions are getting better every year.

So the next time you write `int x = …`, know that your compiler is about to play a high‑stakes game of graph coloring. And if you’re lucky, it’ll color inside the lines.
