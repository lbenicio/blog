---
title: "Branch Prediction and Speculative Execution: How Modern CPUs Gamble on the Future"
description: "Explore how modern processors predict branch outcomes and execute instructions speculatively, the algorithms behind branch predictors, the performance implications for your code, and the security vulnerabilities like Spectre that emerged from these optimizations."
date: "2021-08-15"
author: "Leonardo Benicio"
tags: ["cpu", "branch-prediction", "performance", "speculative-execution", "microarchitecture", "optimization", "spectre"]
categories: ["systems", "performance"]
draft: false
cover: "static/images/blog/branch-prediction-speculative-execution-modern-cpus.png"
coverAlt: "Abstract visualization of CPU pipeline branches diverging into multiple speculative paths, with some paths glowing as correct predictions and others fading as mispredictions"
---

Modern CPUs are marvels of prediction. Every time your code branches—every if statement, every loop iteration, every function call—the processor makes a bet on what happens next. Get it right, and execution flows at full speed. Get it wrong, and the pipeline stalls while work is thrown away. Understanding branch prediction transforms how you think about code performance. This post explores the algorithms, trade-offs, and real-world implications of one of computing's most important optimizations.

## 1. Why Prediction Matters

Consider a simple loop:

```c
for (int i = 0; i < 1000000; i++) {
    sum += array[i];
}
```

At the machine level, this becomes a branch instruction that checks `i < 1000000`. A modern CPU might take 15-20 cycles to determine the branch outcome (waiting for the comparison to complete). With a 3 GHz processor, that's 5-7 nanoseconds per iteration—just for the branch.

But the processor doesn't wait. It predicts the branch will be taken (loop continues) and keeps fetching instructions. One million correct predictions mean the branch overhead is nearly eliminated. The final iteration mispredicts (loop exits), costing ~15 cycles—a trivial price for eliminating millions of stalls.

### 1.1 The Pipeline Problem

Modern CPUs use deep pipelines to maximize throughput:

```text
Instruction Pipeline (simplified):
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│Fetch │Decode│Rename│Issue │Execute│Memory│Retire│
└──────┴──────┴──────┴──────┴──────┴──────┴──────┘
   │      │      │      │       │      │      │
Cycle 1   2      3      4       5      6      7
```

While instruction N is executing, the CPU is already fetching N+1, N+2, N+3, and so on. But what if N is a branch? The CPU doesn't know which instructions come next until the branch resolves.

**Without prediction:** Stop fetching until the branch resolves. The pipeline drains, wasting cycles equal to the pipeline depth (15-20+ stages on modern CPUs).

**With prediction:** Guess the branch outcome, keep fetching instructions from the predicted path. If correct, no cycles lost. If wrong, flush the speculative work and restart.

### 1.2 The Cost of Misprediction

When a branch mispredicts:

1. All speculatively executed instructions are discarded
2. The pipeline is flushed
3. Fetch restarts from the correct path
4. The pipeline must refill before useful work resumes

**Misprediction penalty:** 10-25 cycles on modern CPUs, depending on how deep the speculation went.

A branch that mispredicts 10% of the time with a 20-cycle penalty:

- Average cost: 0.10 × 20 = 2 cycles per branch
- For a tight loop with one branch per iteration, this is significant!

## 2. Static Branch Prediction

Early processors used simple, static rules.

### 2.1 Backward Taken, Forward Not Taken (BTFNT)

The simplest heuristic:

- **Backward branches** (target address < current address): Predict taken. These are usually loops.
- **Forward branches** (target address > current address): Predict not taken. These are usually early exits.

```c
// Backward branch - usually loops, predict taken
loop:
    ...
    jnz loop    // Predict: taken

// Forward branch - usually ifs, predict not taken
    test eax, eax
    jz skip     // Predict: not taken
    ...
skip:
```

BTFNT achieves ~65% accuracy on typical code—better than random, but far from ideal.

### 2.2 Compiler Hints

Some ISAs allow the compiler to provide hints:

```c
// GCC built-in for branch hints
if (__builtin_expect(error_condition, 0)) {
    // Unlikely path
    handle_error();
}

// Linux kernel macros
if (likely(condition)) { ... }
if (unlikely(condition)) { ... }
```

These hints can influence:

- Static prediction (on CPUs that use hints)
- Code layout (likely path falls through, unlikely path jumps)
- Instruction scheduling around the branch

### 2.3 Limitations of Static Prediction

Static prediction can't adapt to:

- Runtime data patterns
- Phase behavior (different behavior at different times)
- Input-dependent branches

Modern CPUs use dynamic prediction that learns from runtime behavior.

## 3. Dynamic Branch Prediction

Dynamic predictors observe branch behavior and learn patterns.

### 3.1 One-Bit Predictor

The simplest dynamic predictor: remember the last outcome.

```text
State: Last outcome (Taken or Not Taken)
Prediction: Same as last outcome

Branch history:  T T T T T T T N T T T T
Predictions:     ? T T T T T T T N T T T
Correct:         - ✓ ✓ ✓ ✓ ✓ ✓ ✗ ✗ ✓ ✓ ✓
```

**Problem:** A loop that executes N times will mispredict twice per invocation:

- First iteration: May mispredict if loop wasn't taken last time
- Last iteration: Always mispredicts (predicts taken, but loop exits)

For a loop executed millions of times, two mispredictions per invocation is fine. For a loop executed 5 times inside an outer loop of millions, that's 2 million mispredictions!

### 3.2 Two-Bit Saturating Counter

Add hysteresis: don't change prediction on a single wrong outcome.

```text
States:
  00: Strongly Not Taken (predict NT)
  01: Weakly Not Taken (predict NT)
  10: Weakly Taken (predict T)
  11: Strongly Taken (predict T)

Transitions:
  On Taken outcome: Increment (max 11)
  On Not Taken outcome: Decrement (min 00)
```

```text
State diagram:
              Taken             Taken
          ┌──────────┐      ┌──────────┐
          ▼          │      ▼          │
     ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐
     │   00   │──│   01   │──│   10   │──│   11   │
     │Strong NT│  │Weak NT │  │Weak T  │  │Strong T│
     └────────┘  └────────┘  └────────┘  └────────┘
          │          ▲      │          ▲
          └──────────┘      └──────────┘
            Not Taken         Not Taken
```

**Benefit:** A single anomaly doesn't flip the prediction. The inner loop problem is greatly reduced:

- Loop entry: May be weak, but strong after first execution
- Loop exit: Mispredicts, but stays "weakly taken" for next invocation
- Next invocation: Correctly predicts taken on first iteration!

### 3.3 Branch Target Buffer (BTB)

Prediction isn't just about direction (taken/not taken). For taken branches, we need the target address.

**Branch Target Buffer:** A cache mapping branch addresses to target addresses.

```text
┌─────────────────┬────────────────────┬──────────────┐
│  Branch PC Tag  │  Target Address    │  Prediction  │
├─────────────────┼────────────────────┼──────────────┤
│  0x4000_1234    │  0x4000_5678       │  11 (Strong T)│
│  0x4000_2000    │  0x4000_2100       │  01 (Weak NT) │
│  ...            │  ...               │  ...          │
└─────────────────┴────────────────────┴──────────────┘
```

When a branch is fetched:

1. Look up branch PC in BTB
2. If hit: Use stored target and prediction
3. If miss: Use static prediction, compute target when branch executes

BTB entries are limited, so not all branches can be tracked. Working set size matters!

## 4. Correlating Predictors

Some branches correlate with other branches or with global execution history.

### 4.1 Local History

A branch may have a pattern based on its own history:

```c
for (int i = 0; i < n; i++) {
    if (i % 2 == 0) {
        even_work();
    }
}
```

This branch alternates: T, N, T, N, T, N...

A local history predictor tracks recent outcomes for each branch:

```text
Local History Table:
┌─────────────────┬────────────────┬──────────────┐
│  Branch PC      │  History (4b)  │  Prediction  │
├─────────────────┼────────────────┼──────────────┤
│  0x4000_1234    │  1010          │  Pattern: alt│
│  0x4000_2000    │  1111          │  Pattern: T  │
└─────────────────┴────────────────┴──────────────┘
```

The history bits index into a Pattern History Table (PHT) of 2-bit counters:

```text
Pattern History Table for branch 0x4000_1234:
History │ Counter │ Prediction
────────┼─────────┼───────────
  0000  │   01    │    NT
  0001  │   11    │    T
  0010  │   10    │    T
  ...   │   ...   │   ...
  1010  │   01    │    NT  ← Current history predicts NT
```

This captures repeating patterns within a single branch.

### 4.2 Global History

Branches often correlate with each other:

```c
if (x < 0) {
    // ...
}
// Later:
if (x < 0) {  // Same condition - perfectly correlated!
    // ...
}
```

Or more subtly:

```c
if (ptr != NULL) {
    if (ptr->valid) {  // Very likely taken if first branch was taken
        // ...
    }
}
```

**Global History Register (GHR):** A shift register tracking the outcomes of recent branches (not just this branch).

```text
GHR after sequence T, N, T, T, N, T:
┌───┬───┬───┬───┬───┬───┐
│ T │ N │ T │ T │ N │ T │
└───┴───┴───┴───┴───┴───┘
  ↑
Most recent
```

The GHR indexes into a global Pattern History Table:

```text
Prediction for current branch = PHT[hash(BranchPC, GHR)]
```

### 4.3 gshare Predictor

The gshare predictor XORs the branch PC with the GHR to index the PHT:

```text
              Branch PC
                 │
                 ▼
              ┌─────────┐
              │  XOR    │◄──── Global History Register
              └────┬────┘
                   │
                   ▼
         ┌─────────────────────┐
         │  Pattern History    │
         │  Table (2-bit       │
         │  counters)          │
         └─────────────────────┘
                   │
                   ▼
              Prediction
```

gshare captures both:

- Branch-specific patterns (from PC bits)
- Global correlation (from GHR bits)

It's simple, effective, and widely used as a baseline.

### 4.4 Tournament Predictors

Different predictors excel at different branch types. A tournament predictor uses multiple predictors and learns which is best for each branch:

```text
                    ┌──────────────┐
         ┌─────────│ Local Pred.  │─────────┐
         │         └──────────────┘         │
         │                                  │
         │         ┌──────────────┐         ▼
Branch ──┼────────│ Global Pred. │────────►MUX ──► Prediction
         │         └──────────────┘         ▲
         │                                  │
         │         ┌──────────────┐         │
         └─────────│   Chooser    │─────────┘
                   └──────────────┘
```

The chooser table tracks which predictor was more accurate for each branch (or branch pattern). Alpha 21264 used this design, achieving ~95% accuracy.

## 5. Modern Branch Predictors

Contemporary CPUs use highly sophisticated predictors with multiple levels.

### 5.1 TAGE: Tagged Geometric History Length

TAGE (TAgged GEometric) is the dominant predictor design in modern CPUs.

Key insight: Different branches need different history lengths. Loop counters need short history. Complex control flow needs long history.

TAGE uses multiple tables with geometrically increasing history lengths:

```text
                      Tagged Tables
             ┌──────┬──────┬──────┬──────┐
             │ T1   │ T2   │ T3   │ T4   │
             │ 4-bit│ 8-bit│16-bit│64-bit│
             │ hist │ hist │ hist │ hist │
             └──────┴──────┴──────┴──────┘
                │      │      │      │
                ▼      ▼      ▼      ▼
             ┌───────────────────────────┐
             │       Provider Select     │
             │   (longest match wins)    │
             └───────────────────────────┘
                          │
                          ▼
                     Prediction
```

Each table entry has:

- Tag (partial PC + history hash)
- Prediction counter (2-3 bits)
- Useful counter (for replacement)

The table with the longest matching history provides the prediction. TAGE achieves ~97% accuracy on typical workloads.

### 5.2 Perceptron Predictors

Neural-inspired predictors learn weights for history bits:

```text
Prediction = sign(w₀ + Σ(wᵢ × hᵢ))

Where:
  w₀ = bias weight
  wᵢ = weight for history bit i
  hᵢ = history bit i (+1 for taken, -1 for not taken)
```

Training is simple: if mispredicted, adjust weights toward the correct outcome.

Perceptrons can capture complex correlations that table-based predictors miss. AMD's Zen architecture uses perceptron-based predictors.

### 5.3 Loop Predictors

Loops have predictable iteration counts. Dedicated loop predictors detect and track loops:

```text
Loop Predictor Entry:
┌─────────────┬───────────┬───────────┬──────────┐
│  Branch PC  │  Limit    │  Count    │ Confident│
├─────────────┼───────────┼───────────┼──────────┤
│ 0x4000_1234 │    100    │    57     │   Yes    │
└─────────────┴───────────┴───────────┴──────────┘

Prediction: Taken until Count reaches Limit
```

When a loop is detected (repeated back-edge), the predictor:

1. Learns the iteration count
2. Predicts taken until count reached
3. Predicts not taken on final iteration

This eliminates the "last iteration" misprediction that plagues other predictors.

### 5.4 Return Address Stack

Function returns are indirect branches (target varies). But they follow a pattern: return to the instruction after the call.

**Return Address Stack (RAS):** A small stack that tracks call sites.

```text
Call site 0x1000 ──► Push 0x1004
Call site 0x2000 ──► Push 0x2004
Call site 0x3000 ──► Push 0x3004

Return ──► Pop 0x3004 (predict return to 0x3004)
Return ──► Pop 0x2004 (predict return to 0x2004)
Return ──► Pop 0x1000 (predict return to 0x1004)
```

RAS handles returns with near-perfect accuracy for normal call/return patterns. Problems arise with:

- Exceptions (unwind stack without returns)
- Tail calls (return address isn't pushed)
- Speculation (speculative calls corrupt RAS)

Modern CPUs use techniques like checkpointing to recover RAS on misprediction.

## 6. Indirect Branch Prediction

Most branches have a fixed target (direct branches). But some have variable targets:

```c
// Virtual function call
obj->method();  // Target depends on object's vtable

// Switch statement (jump table)
switch (x) { ... }  // Target depends on x

// Function pointer
callback(data);  // Target is the function pointer value
```

### 6.1 Indirect Target Array (ITA)

Simple approach: cache recently seen targets.

```text
┌─────────────────┬────────────────────┐
│  Branch PC      │  Recent Targets    │
├─────────────────┼────────────────────┤
│  0x4000_1234    │  0x5000, 0x6000    │
│  0x4000_2000    │  0x7000            │
└─────────────────┴────────────────────┘
```

Predict the most recently seen target. Works well for monomorphic call sites (one target) but poorly for polymorphic calls.

### 6.2 Indirect Target Predictor with History

Like branch direction, indirect targets can correlate with history:

```c
switch (state) {
    case A: next_state = B; break;
    case B: next_state = C; break;
    case C: next_state = A; break;
}
// Repeating pattern: A→B→C→A→B→C...
```

Modern indirect predictors use history to predict targets:

```text
Prediction = TargetTable[hash(BranchPC, GHR)]
```

### 6.3 Virtual Call Optimization

Virtual calls are common in OOP code. Techniques to help prediction:

**Devirtualization:** Compiler converts virtual calls to direct calls when the type is known.

**Polymorphic inline caches:** At runtime, cache recent receiver types and inline the predicted path.

```c
// Polymorphic inline cache (pseudocode)
if (obj->type == cached_type) {
    cached_method(obj);  // Fast path, direct call
} else {
    obj->vtable[method_index](obj);  // Slow path
    cached_type = obj->type;  // Update cache
}
```

## 7. Speculative Execution

Branch prediction enables speculation—executing instructions before knowing if they should execute.

### 7.1 How Speculation Works

```text
Time ──────────────────────────────────────────────►

Instruction stream: A, B, BRANCH, C, D, E...

Pipeline:
Cycle 1: Fetch A
Cycle 2: Fetch B, Decode A
Cycle 3: Fetch BRANCH, Decode B, Execute A
Cycle 4: Fetch C (speculative!), Decode BRANCH, Execute B
Cycle 5: Fetch D (speculative!), Decode C, Execute BRANCH
         └─► Branch resolves: prediction was CORRECT
Cycle 6: Fetch E, Decode D, Execute C  (all valid!)

If prediction was WRONG:
Cycle 5: Branch resolves wrong
         Flush C, D from pipeline
         Restart fetch from correct path
```

### 7.2 Speculative State Management

Speculative instructions can't modify permanent state until the branch is confirmed. CPUs use:

**Reorder Buffer (ROB):** Instructions complete out-of-order but retire (commit) in order. Speculative instructions wait in the ROB until the branch commits.

**Physical Register File:** Results are written to physical registers. Architectural registers are updated only on retirement.

**Store Buffer:** Stores wait in a buffer until retirement, then write to cache.

### 7.3 Memory Ordering and Speculation

Speculative loads are tricky:

```c
if (x < array_size) {      // Mispredicted as taken
    value = array[x];       // Speculative load (x might be out of bounds!)
}
```

The load executes speculatively, potentially accessing invalid memory. Modern CPUs:

- Allow speculative loads (for performance)
- Check bounds when the load retires
- Squash if the load was invalid

But the load still affects microarchitectural state (caches, TLBs), leading to security issues...

## 8. Security: Spectre and Friends

Speculative execution vulnerabilities shocked the industry in 2018. They exploit the side effects of mispredicted speculation.

### 8.1 Spectre Variant 1: Bounds Check Bypass

```c
if (x < array1_size) {           // Can be mispredicted!
    y = array2[array1[x] * 256]; // Speculatively executed with bad x
}
```

Attack:

1. Train predictor to expect branch taken
2. Call with `x` out of bounds
3. Speculative execution reads `array1[x]` (secret data)
4. Uses secret as index into `array2`, loading a cache line
5. Branch misprediction detected, execution rolled back
6. **But:** Cache state persists! The loaded cache line reveals the secret

This leaks arbitrary memory through cache timing side channels.

### 8.2 Spectre Variant 2: Branch Target Injection

Indirect branch prediction can be poisoned:

1. Attacker trains BTB with malicious target
2. Victim process executes indirect branch
3. Speculation jumps to attacker-chosen "gadget"
4. Gadget leaks secrets via cache side channel
5. Speculation rolled back, but cache side effects remain

This allows cross-process and cross-privilege attacks.

### 8.3 Mitigations

**Software mitigations:**

```c
// Speculation barrier
if (x < array_size) {
    __asm__ volatile("lfence");  // Block speculation
    y = array[x];
}

// Array index masking
x &= ~(-(x >= array_size));  // Clamp x to valid range
```

**Hardware mitigations:**

- IBRS/IBPB: Indirect Branch Restricted/Prediction Barrier
- STIBP: Single Thread Indirect Branch Predictor
- Enhanced IBRS: Hardware mode that isolates prediction
- Microcode updates: Various fixes for specific variants

**Performance impact:** Mitigations can cost 2-30% performance depending on workload and mitigation level.

### 8.4 The Fundamental Problem

Speculation side channels exist because:

1. Prediction affects what instructions execute (even speculatively)
2. Speculative execution affects microarchitectural state
3. Microarchitectural state is observable through timing

Fixing this fundamentally would require either:

- Never speculate (massive performance loss)
- Isolate all microarchitectural state (extremely difficult)
- Eliminate timing side channels (practically impossible)

Modern CPUs continue to balance security and performance with targeted mitigations.

## 9. Writing Branch-Prediction-Friendly Code

Understanding prediction helps you write faster code.

### 9.1 Make Branches Predictable

Sort data when possible:

```c
// Unpredictable: random true/false
for (int i = 0; i < n; i++) {
    if (data[i] >= 128) {  // ~50% taken if random
        sum += data[i];
    }
}

// Better: sort first, then all false followed by all true
std::sort(data, data + n);
for (int i = 0; i < n; i++) {
    if (data[i] >= 128) {  // First N iterations false, rest true
        sum += data[i];
    }
}
```

The sorted version can be 3-5x faster due to better prediction!

### 9.2 Use Conditional Moves

Replace branches with conditional moves when possible:

```c
// Branchy version
if (a > b) {
    max = a;
} else {
    max = b;
}

// Branchless version (compiler may generate CMOV)
max = (a > b) ? a : b;

// Explicitly branchless
max = b ^ ((a ^ b) & -(a > b));
```

Conditional moves have fixed latency (~1-2 cycles) regardless of data patterns. Useful when:

- Branch is unpredictable (near 50/50)
- Both paths are simple (cheap to compute both)

**Warning:** Don't use branchless code blindly! If the branch is predictable, branches are faster because they can speculate ahead.

### 9.3 Loop Unrolling

Reduce branch overhead by processing multiple elements per iteration:

```c
// Original: 1 branch per element
for (int i = 0; i < n; i++) {
    sum += a[i];
}

// Unrolled: 1 branch per 4 elements
for (int i = 0; i < n; i += 4) {
    sum += a[i] + a[i+1] + a[i+2] + a[i+3];
}
```

Fewer branches = fewer opportunities for misprediction.

### 9.4 Profile-Guided Optimization (PGO)

Let the compiler learn branch behavior:

```bash
# Step 1: Build instrumented binary
gcc -fprofile-generate -O2 program.c -o program

# Step 2: Run with representative workload
./program typical_input.txt

# Step 3: Rebuild with profile data
gcc -fprofile-use -O2 program.c -o program
```

PGO enables:

- Better branch prediction hints
- Hot path optimization
- Cold path outlining
- Better inlining decisions

PGO can improve performance by 10-30% for branch-heavy code.

### 9.5 Avoid Unpredictable Indirect Branches

Virtual calls and function pointers are indirect branches:

```c++
// Hard to predict: polymorphic
for (Shape* s : shapes) {
    s->draw();  // Different target each time
}

// Easier to predict: monomorphic or sorted
std::sort(shapes.begin(), shapes.end(),
          [](auto a, auto b) { return typeid(*a).name() < typeid(*b).name(); });
for (Shape* s : shapes) {
    s->draw();  // Targets cluster together
}
```

## 10. Measuring Branch Performance

### 10.1 Performance Counters

Modern CPUs provide hardware counters for branch events:

```bash
# Linux perf
perf stat -e branches,branch-misses ./program

# Example output:
#  1,234,567,890  branches
#     12,345,678  branch-misses  # 1.00% of all branches
```

Key metrics:

- **Branch misprediction rate:** Aim for < 2% on hot paths
- **Instructions per branch:** Lower means more control flow
- **Branch MPKI:** Mispredictions per kilo-instructions

### 10.2 Microbenchmarking

Isolate branch prediction effects:

```c
// Predictable pattern
for (int i = 0; i < N; i++) {
    if (i % 2 == 0) sum++;  // Alternating: TNTNTN...
}

// Unpredictable pattern
for (int i = 0; i < N; i++) {
    if (rand() % 2 == 0) sum++;  // Random: ???
}
```

Compare performance to quantify prediction impact.

### 10.3 CPU-Specific Analysis

Intel VTune and AMD uProf provide detailed branch analysis:

- Per-branch misprediction rates
- BTB hit/miss rates
- Indirect branch target patterns
- Speculation efficiency

## 11. Branch Prediction Across Architectures

### 11.1 x86 (Intel/AMD)

Intel Haswell and later use TAGE-like predictors with:

- Multiple prediction tables
- Loop predictors
- Return address stack (16-32 entries)
- Indirect target predictors

AMD Zen uses perceptron-based predictors with:

- TAGE backup
- Large history lengths
- Sophisticated indirect prediction

Both achieve ~97% accuracy on typical workloads.

### 11.2 ARM

ARM cores vary widely:

- **Cortex-A55 (efficiency):** Simple bimodal predictor, ~85% accuracy
- **Cortex-A78 (performance):** TAGE-like, ~95% accuracy
- **Apple M-series:** Highly sophisticated, possibly perceptron-based

ARM's big.LITTLE design means prediction quality varies between cores.

### 11.3 RISC-V

RISC-V is an ISA, not an implementation. Predictors vary by vendor:

- SiFive U74: gshare-based, moderate accuracy
- Alibaba XuanTie: TAGE-based, high accuracy
- Research implementations: Testing novel predictor designs

### 11.4 GPU "Prediction"

GPUs handle branches differently:

```text
SIMD Execution:
Thread 0:  if (true)  { A } else { B }
Thread 1:  if (true)  { A } else { B }
Thread 2:  if (false) { A } else { B }
Thread 3:  if (true)  { A } else { B }

Execution:
1. All threads execute A (thread 2 masked)
2. All threads execute B (threads 0,1,3 masked)
```

GPUs don't predict; they execute both paths with masking. This is called **divergence** and is why GPU code should minimize branches.

## 12. Advanced Topics

### 12.1 Branch Prediction and SMT

Simultaneous Multithreading (Hyper-Threading) shares prediction resources:

- BTB entries are shared or partitioned
- GHR may be per-thread or shared
- Prediction tables compete for space

Competing threads can cause prediction interference. Some CPUs partition resources for security (prevent cross-thread Spectre attacks).

### 12.2 Speculative Memory Disambiguation

Modern CPUs speculate on memory dependencies:

```c
store [A], value1
load  [B]  // Does B alias A?

// CPU speculates "no alias", executes load early
// If wrong, replay the load after the store completes
```

This is called memory disambiguation prediction. Misprediction causes pipeline flushes similar to branch misprediction.

### 12.3 Value Prediction

Why stop at predicting branches? We could predict values:

```c
x = load_from_memory();  // Predict x = 42
y = x + 1;               // Speculatively compute y = 43
```

Value prediction has been researched for decades but isn't in mainstream CPUs due to:

- Complexity of recovery on misprediction
- Limited accuracy for most values
- Area/power costs

Some specialized uses exist (stride predictors for addresses).

### 12.4 Machine Learning Predictors

Research explores ML for prediction:

- Neural networks for branch prediction
- Reinforcement learning for predictor training
- Learned index structures for BTB

Challenge: ML inference must complete in < 1 cycle, limiting model complexity.

## 13. Historical Perspective

### 13.1 Early Predictors (1980s)

- Simple static prediction
- One-bit dynamic predictors
- Small BTBs

Accuracy: ~70-80%

### 13.2 Two-Level Predictors (1990s)

- Local and global history
- gshare, gselect
- Tournament predictors

Accuracy: ~90-95%

### 13.3 Modern Predictors (2000s-present)

- TAGE and variants
- Perceptron predictors
- Sophisticated loop/return prediction

Accuracy: ~97%+

- Sophisticated loop/return prediction

Accuracy: ~97%+

### 13.4 The Accuracy Wall

Prediction accuracy has plateaued:

- Easy branches are already perfect
- Hard branches are fundamentally unpredictable
- Diminishing returns from predictor complexity

Future gains likely come from:

- Reducing misprediction penalty
- Better speculative execution management
- Compiler assistance

## 14. Real-World Case Studies

Understanding branch prediction theory is valuable, but seeing real performance impacts cements the knowledge.

### 14.1 The Sorted Array Benchmark

The famous Stack Overflow question "Why is processing a sorted array faster than an unsorted array?" demonstrates branch prediction perfectly:

```cpp
int main() {
    const int arraySize = 32768;
    int data[arraySize];

    // Fill with random values 0-255
    for (int c = 0; c < arraySize; ++c)
        data[c] = std::rand() % 256;

    // Optionally sort
    // std::sort(data, data + arraySize);

    long long sum = 0;
    for (int i = 0; i < 100000; ++i) {
        for (int c = 0; c < arraySize; ++c) {
            if (data[c] >= 128)
                sum += data[c];
        }
    }
}
```

Results:

- **Unsorted:** ~10 seconds
- **Sorted:** ~2 seconds

The sorted version is 5x faster because the branch becomes predictable. First half: all not-taken. Second half: all taken.

### 14.2 JSON Parsing Branches

JSON parsers are branch-heavy, checking character types continuously:

```c
while (*p) {
    if (*p == '"') parse_string();
    else if (*p == '{') parse_object();
    else if (*p == '[') parse_array();
    else if (isdigit(*p)) parse_number();
    // ...
}
```

Optimized parsers like simdjson use:

- SIMD to classify multiple characters at once
- Branchless state machines
- Data-parallel parsing

simdjson achieves 2-4GB/s versus ~200MB/s for traditional parsers, largely by eliminating unpredictable branches.

### 14.3 Game Engine Physics

Physics engines often process many objects:

```cpp
for (Entity& e : entities) {
    if (e.hasPhysics) {
        if (e.isAwake) {
            if (e.collisionEnabled) {
                // Process physics
            }
        }
    }
}
```

Optimizations:

- Sort entities by type (all physics entities together)
- Use data-oriented design (separate arrays for different properties)
- Process in batches of similar entities

Modern engines achieve 10-100x improvements through branch-friendly data organization.

### 14.4 Database Query Processing

Database queries involve many branches:

```c
// Filter predicate
for (Row& row : table) {
    if (row.age > 30 && row.salary > 50000 && row.dept == "ENG") {
        results.push_back(row);
    }
}
```

Database optimizations:

- Vectorized execution (process columns in batches)
- Predicate reordering (most selective first)
- Compiled queries (eliminate interpretation overhead)

Vectorized databases like DuckDB, ClickHouse achieve order-of-magnitude improvements.

## 15. Compiler Optimizations for Branches

Compilers employ sophisticated techniques to improve branch behavior.

### 15.1 If-Conversion

Convert branches to conditional moves:

```c
// Original
if (condition) {
    x = a;
} else {
    x = b;
}

// If-converted (compiler generates CMOV)
x = condition ? a : b;
```

Compilers apply if-conversion when:

- Both paths are simple
- Branch is likely unpredictable
- Architecture supports conditional moves

### 15.2 Branch Probability Propagation

Compilers track branch probabilities through the code:

```c
if (error_check()) {  // Rare: 0.01%
    handle_error();   // Also rare
    return;
}
// Normal path: 99.99%
do_work();
```

Probabilities inform:

- Code layout (hot path falls through)
- Inlining decisions (inline hot paths)
- Register allocation (optimize for hot path)

### 15.3 Hot/Cold Splitting

Move unlikely code out of hot paths:

```c
// Before
void process() {
    if (unlikely(error)) {
        // 100 lines of error handling
    }
    // Hot path
}

// After (compiler splits)
void process() {
    if (unlikely(error)) {
        handle_error_cold();  // Outlined to separate function
    }
    // Hot path (better instruction cache)
}
```

Cold code outlining improves instruction cache utilization for hot paths.

### 15.4 Loop Unswitching

Hoist loop-invariant conditions:

```c
// Before
for (int i = 0; i < n; i++) {
    if (flag) {  // Loop-invariant!
        work_a(i);
    } else {
        work_b(i);
    }
}

// After unswitching
if (flag) {
    for (int i = 0; i < n; i++) {
        work_a(i);
    }
} else {
    for (int i = 0; i < n; i++) {
        work_b(i);
    }
}
```

Eliminates n-1 branches, improving prediction and enabling further optimizations.

### 15.5 Speculative Compilation

JIT compilers can optimize based on runtime behavior:

```java
// HotSpot JVM
if (obj instanceof Dog) {  // 99% Dog
    ((Dog) obj).bark();
}

// JIT generates:
// if (obj.class == Dog.class) {  // Fast path: direct call
//     dog_bark(obj);
// } else {
//     slow_path_instanceof(obj);  // Deoptimize if assumption broken
// }
```

This "speculative optimization" bets on observed patterns, with fallback for uncommon cases.

## 16. Branch Prediction in Different Domains

### 16.1 Embedded Systems

Resource-constrained embedded systems have simpler predictors:

- Cortex-M series: Static or simple bimodal
- Smaller BTBs (32-128 entries)
- Lower misprediction penalties (shorter pipelines)

Embedded developers often:

- Avoid complex control flow
- Use lookup tables instead of branches
- Manually unroll critical loops

### 16.2 High-Frequency Trading

HFT systems are extremely latency-sensitive:

- Every nanosecond matters
- Branch mispredictions are critical path
- Custom hardware (FPGAs) avoids branches entirely

HFT optimizations:

```cpp
// Branchless comparison
int cmp = (a > b) - (a < b);  // Returns -1, 0, or 1

// Branchless min/max
int min = b + ((a - b) & ((a - b) >> 31));

// Pre-computed decision tables
action = decision_table[state][event];
```

### 16.3 Scientific Computing

Scientific code is often predictable (regular loops over arrays):

```fortran
! Matrix multiplication - highly predictable
do i = 1, n
    do j = 1, n
        do k = 1, n
            C(i,j) = C(i,j) + A(i,k) * B(k,j)
        end do
    end do
end do
```

But irregular data structures cause problems:

```c
// Sparse matrix - unpredictable access patterns
for (int i = 0; i < nnz; i++) {
    if (col[i] == target_col) {  // Unpredictable!
        sum += val[i];
    }
}
```

Scientific libraries optimize sparse operations carefully.

### 16.4 Cryptographic Code

Cryptography requires constant-time execution to prevent timing attacks:

```c
// WRONG: Timing depends on secret key bits
if (secret_key[i]) {
    result = operation_a();
}

// RIGHT: Always execute both, select result
result_a = operation_a();
result_b = operation_b();
mask = -(secret_key[i] & 1);  // All 1s or all 0s
result = (result_a & mask) | (result_b & ~mask);
```

Constant-time code deliberately avoids prediction-dependent timing.

## 17. Future Directions

### 17.1 Learned Predictors

Machine learning for prediction shows promise:

- Neural network-based BTB indexing
- Reinforcement learning for table management
- Transfer learning from similar workloads

Challenges:

- Inference latency (must be < 1 cycle)
- Training complexity
- Generalization to new workloads

### 17.2 Software-Hardware Co-design

Better compiler-hardware communication:

- Richer branch hints from compilers
- Hardware profiling feedback to compilers
- Adaptive optimization based on runtime behavior

### 17.3 Security-First Predictors

Post-Spectre designs prioritize security:

- Isolated prediction domains per security context
- Speculative execution firewalls
- Prediction state clearing on context switches

### 17.4 Heterogeneous Prediction

Different predictors for different branch types:

- Simple predictor for loop branches
- Neural predictor for data-dependent branches
- Table-based for indirect branches

Dynamic selection based on branch characteristics.

## 18. Summary

Branch prediction is a cornerstone of modern CPU performance:

- **Deep pipelines** require prediction to avoid stalls
- **Dynamic predictors** learn from runtime behavior
- **Modern designs** (TAGE, perceptron) achieve ~97% accuracy
- **Speculation** enables out-of-order execution but creates security risks
- **Code patterns** dramatically affect prediction accuracy

Key takeaways for developers:

1. **Predictable branches are nearly free** (~0 cycles overhead)
2. **Unpredictable branches are expensive** (10-25 cycles penalty)
3. **Sorting data** can dramatically improve prediction
4. **Branchless code** is only faster for unpredictable branches
5. **Profile your code** to find branch hotspots
6. **Understand the architecture** to write efficient code

The branch predictor is the CPU's crystal ball, making educated guesses millions of times per second. Understanding how it works transforms how you think about the true cost of a simple if statement.

Every branch in your code is a bet. The CPU is gambling on the future, billions of times per second. Understanding these bets helps you write code that wins more often.
