---
title: "JIT Compilation: Tracing vs Method JITs, V8's Ignition+TurboFan Pipeline, HotSpot's C1/C2 Tiered Compilation, and Deoptimization"
description: "A deep exploration of just-in-time compilation — how V8 and HotSpot turn JavaScript and Java bytecode into native code through multi-tier compilation pipelines, and the art of deoptimization that makes speculative optimization safe."
date: "2020-10-28"
author: "Leonardo Benicio"
tags: ["jit", "compilers", "v8", "hotspot", "javascript", "java", "tracing-jit"]
categories: ["systems", "compilers"]
draft: false
cover: "/static/assets/images/blog/jit-compilation-tracing-method-v8-hotspot.png"
coverAlt: "A stylized visualization of JIT compilation tiers, showing bytecode flowing through interpreter, baseline compiler, and optimizing compiler into native code"
---

In 1984, Peter Deutsch and Allan Schiffman published a paper titled "Efficient Implementation of the Smalltalk-80 System" that introduced a radical idea: instead of compiling a program before it runs or interpreting it instruction by instruction, why not compile it while it runs? The just-in-time (JIT) compiler was born. Nearly four decades later, JIT compilation powers every major web browser (JavaScript), the Java Virtual Machine, the .NET CLR, Python's PyPy, and even database query engines. The core insight is as relevant today as it was in 1984: a compiler that can observe the program's actual runtime behavior can make optimizations that a static compiler cannot. This post traces the evolution of JIT compilation, from tracing JITs to method JITs, through the tiered compilation architectures of V8 and HotSpot, and into the dark art of deoptimization.

## 1. The Fundamental JIT Trade-off

A JIT compiler faces a fundamental tension that static compilers don't: compilation time is part of program execution time. Every millisecond spent compiling is a millisecond the program isn't running. This means a JIT must balance compilation investment against expected performance gains. Spend too little time compiling, and the code runs slowly. Spend too much time compiling, and the program spends more time in the compiler than in the compiled code.

This tension motivates multi-tier compilation. Tier 1 is fast and dirty — a baseline compiler that generates unoptimized code as quickly as possible. Tier 2 applies optimizations to "hot" code that executes frequently. Some systems add Tier 3 for the hottest of hot code, applying the most expensive optimizations. The JIT continuously monitors execution and promotes (and sometimes demotes) functions between tiers.

The monitoring is driven by counters. Each function has at least two counters: an invocation counter (incremented on each call) and a back-edge counter (incremented on each loop iteration). When a counter exceeds a threshold, the function is queued for compilation at the next tier. The thresholds are tuned carefully: too low and the JIT wastes time optimizing cold code; too high and hot code runs too long in the interpreter.

## 2. Tracing JITs: Following the Hot Path

The tracing JIT, pioneered by Franz and Gal's TraceMonkey (Mozilla's JavaScript JIT from 2008) and refined by Andreas Gal's work on Adobe's Tamarin VM, takes a different approach from method-based JITs. Instead of compiling entire methods or functions, a tracing JIT records the actual sequence of operations executed along a hot path through the program and compiles that trace.

The tracing process works like this: the interpreter runs the program normally, monitoring loop back-edges. When a loop becomes hot (executes many iterations), the JIT enters "recording mode." It follows the execution path, recording every operation — every bytecode instruction executed, every type check performed, every value loaded and stored. When execution reaches the loop back-edge again (completing one iteration), the recording stops. The recorded trace is then compiled to native code with aggressive optimizations.

The key advantage of tracing is specialization. A traced path represents a specific sequence of operations with specific types. If a variable is always an integer along the trace, the compiled code can use integer arithmetic directly, without any type checks. If a function call always goes to the same target, it can be inlined. The compiled trace is perfectly specialized for the observed behavior.

The key disadvantage is trace explosion. A loop with an if-else statement generates two traces (one for the if branch, one for the else branch). Nested control flow generates exponential numbers of traces. Each trace must be compiled, cached, and connected to other traces through "trace stitching." The overhead of trace management can overwhelm the benefits of specialization. This is one reason why tracing JITs have largely been superseded by method JITs in production systems.

However, tracing JITs excel in certain domains. PyPy, the Python JIT, uses a meta-tracing approach: instead of tracing the user's program directly, PyPy traces the interpreter executing the user's program. This allows PyPy to generate specialized JIT compilers for any language that can be implemented as an interpreter. Meta-tracing is an elegant way to bring JIT compilation to new languages with minimal effort.

## 3. Method JITs: Compiling Whole Functions

Method-based JITs, the dominant approach in modern VMs, compile entire methods (functions) rather than individual traces. The compilation unit is a method, class, or function, which simplifies bookkeeping (one compiled version per method, not N traces) and enables classic compiler optimizations like inlining, loop unrolling, and global value numbering.

V8's original JIT pipeline (pre-2017) used two compilers: Full-codegen (a fast, non-optimizing baseline compiler) and Crankshaft (an optimizing compiler). Full-codegen generated code directly from the AST in a single pass, producing correct but slow code. Crankshaft, applied to hot functions, used a more sophisticated pipeline: the bytecode was translated to a high-level IR (Hydrogen), optimized (typed-guided optimizations, inlining, GVN), translated to a low-level IR (Lithium), register-allocated, and emitted as native code.

V8's current pipeline (since 2017) replaced Full-codegen and Crankshaft with Ignition (an interpreter) and TurboFan (an optimizing compiler). Ignition is not a compiler but a bytecode interpreter — it executes V8's internal bytecode format without translating to native code. This is slower than baseline compilation but uses much less memory (bytecode is more compact than native code) and simplifies the system (no need for a separate baseline compiler). TurboFan then compiles hot functions from Ignition's bytecode, applying a full optimization pipeline.

## 4. V8's Ignition and TurboFan in Detail

Ignition is V8's interpreter, but it's not a simple switch-loop interpreter. It's a register-based interpreter that operates on V8's internal bytecode. The bytecode is generated from the JavaScript AST during parsing and is stored in the function's "bytecode array." Each bytecode instruction operates on virtual registers and an accumulator.

Ignition uses several optimization techniques to make interpretation fast:

1. **Bytecode dispatch threading**: Instead of a single dispatch loop with a switch statement, Ignition uses "direct threading" where each bytecode handler ends with a jump to the next handler. The dispatch table maps opcodes to handler addresses, and the dispatch is a single indirect jump. This reduces branch mispredictions compared to a central dispatch loop.

2. **Inline caching**: For property accesses (`obj.x`), Ignition uses inline caches (ICs) — small stubs of native code that cache the result of the last property lookup. If the object has the same "shape" (hidden class) as the cached lookup, the access completes in a few instructions without calling into the runtime.

3. **Feedback collection**: During interpretation, Ignition collects type feedback: what types of values flow through each operation, which function is called at each call site, which object shape is seen at each property access. This feedback is stored in "feedback vectors" associated with each function and is used by TurboFan to guide optimization.

TurboFan, V8's optimizing compiler, reads the bytecode and the feedback vectors to generate optimized native code. The pipeline is:

```text
Bytecode + Feedback
    │
    ▼
Sea-of-Nodes IR    ← Nodes represent operations, edges represent
    │                data flow and control flow. The graph is
    │                built from bytecode and annotated with types
    │                from feedback.
    ▼
Typed Optimizations ← Type guards are inserted based on feedback.
    │                Operations are specialized: if a `+` always
    │                sees integers, it becomes an integer add.
    │                Inlining, GVN, LICM, DCE.
    ▼
Lowering           ← High-level operations are lowered to
    │                machine-level operations. JavaScript
    │                objects become pointer manipulations.
    │
    ▼
Register Allocation ← Linear scan or greedy allocator.
    │
    ▼
Code Generation    ← x86-64, ARM64, etc.
```

TurboFan's "sea-of-nodes" IR is particularly well-suited to JIT compilation. The graph representation makes it easy to insert and remove nodes (for deoptimization support), and the scheduling phase can reorder operations to exploit instruction-level parallelism.

## 5. HotSpot's C1 and C2: The Java Tiered Compilation Story

The HotSpot JVM, Oracle's flagship Java VM, uses a tiered compilation system with two JIT compilers: C1 (the client compiler) and C2 (the server compiler, also known as "Opto").

C1 is a fast, lightly optimizing compiler. It translates bytecode to an SSA-based high-level IR (HIR), performs a few optimizations (constant folding, inlining of small methods, null check elimination), translates to a low-level IR (LIR), and generates machine code. C1's compilation speed is roughly 1000-2000 bytecodes per millisecond, and the generated code is typically 2-3x faster than interpretation.

C2 is an aggressively optimizing compiler. It translates bytecode to an ideal graph (a sea-of-nodes IR similar to TurboFan's), applies a large suite of optimizations (inlining, escape analysis, lock elision, loop unrolling, range check elimination, auto-vectorization), and generates highly optimized machine code. C2 compilation is slow — it can take seconds for large methods — but the generated code can be 10-20x faster than interpretation.

HotSpot's tiered compilation system (introduced in Java 7) works as follows:

- **Level 0**: Interpretation with profiling. The interpreter collects edge counts (which branches are taken) and type profiles (which receiver types are seen at virtual call sites).

- **Level 1**: C1 compilation without profiling. For simple methods where further optimization is unlikely to help (getters, setters, trivial methods).

- **Level 2**: C1 compilation with limited profiling. Collects basic invocation and back-edge counts.

- **Level 3**: C1 compilation with full profiling. Collects detailed type profiles for virtual calls and branches.

- **Level 4**: C2 compilation with full optimization. Uses the profiles collected at levels 0-3.

The JVM decides which level to use based on the method's invocation count, the compiler queue length, and the available profiling data. Methods typically progress through levels 0 → 3 → 4, but simple methods may skip directly to level 1, and methods that are never called frequently stay at level 0.

A unique feature of HotSpot is that C1 and C2 can compile concurrently (in background threads), so compilation doesn't block the application. The application continues running the interpreter or lower-tier code while the higher-tier compilation proceeds in the background. When the compilation completes, the new code is installed, and future invocations use it.

## 6. Speculative Optimization and Deoptimization

What makes JIT compilation truly powerful — and complex — is speculative optimization. The JIT observes that a certain condition holds (a variable is always an integer, a method call always goes to the same target, a loop always iterates at least once), optimizes the code assuming that condition continues to hold, and inserts a guard to check the assumption. If the guard fails, the JIT deoptimizes: it reverts execution to the interpreter or a lower-tier compiled version, reconstructs the program state, and continues execution.

Deoptimization is the art of unwinding optimized code back to a state that the interpreter (or baseline compiler) can understand. This requires:

1. **Deoptimization points**: The optimizing compiler identifies points in the code where deoptimization might be necessary (typically at the beginning of each basic block or after a type guard). At each deoptimization point, the compiler records the mapping from optimized registers and stack slots to the corresponding bytecode-level variables.

2. **Deoptimization metadata**: For each deoptimization point, the compiler emits metadata describing how to reconstruct the interpreter state: which bytecode instruction was being executed, which values were in which registers, what the stack frame looked like.

3. **Deoptimization runtime**: When a guard fails, the runtime walks the stack frames, using the deoptimization metadata to translate optimized frames into interpreter frames. This involves creating new stack frames in the interpreter format, copying values from registers to the interpreter's local variable slots, and adjusting the program counter to the appropriate bytecode instruction.

Deoptimization is expensive — it can take thousands of cycles to reconstruct the interpreter state — so the JIT must be careful not to over-speculate. If a guard fails frequently, the JIT should recompile the function without that assumption (or with a less aggressive assumption). This is called "deoptimization-driven recompilation."

V8 and HotSpot both support on-stack replacement (OSR) during deoptimization. If a long-running loop was compiled with an assumption that later proves false, the optimized loop can be replaced with interpreter execution mid-loop. This is crucial for responsiveness: the JIT can't wait for the current invocation to finish before deoptimizing.

## 7. Inline Caches and Hidden Classes

One of the most important JIT optimizations is inline caching, which accelerates property access in dynamically typed languages. In JavaScript, `obj.x` is not a simple offset calculation — `x` could be a property on `obj` itself, on `obj`'s prototype, or accessed via a getter function. Resolving `obj.x` normally requires a hash table lookup in the object's "shape" (hidden class) and potentially a prototype chain walk.

An inline cache (IC) memoizes the result of this lookup. At the `obj.x` code location, the JIT stores a reference to the last object shape seen and the offset where `x` was found. On subsequent executions at the same code location, if the object has the same shape, the JIT loads the value directly from the cached offset — two or three instructions instead of a full property lookup.

V8's ICs go further with "megamorphic" ICs. If a property access sees many different object shapes (more than 4-8, depending on the IC type), it transitions to a megamorphic state that uses a hash table to map shapes to offsets. This is slower than a monomorphic (single-shape) cache but faster than a full runtime lookup.

HotSpot uses a similar technique for virtual method dispatch. At a virtual call site (`receiver.foo()`), HotSpot records the last concrete type of the receiver and the actual method that was called. If the receiver type is the same on the next invocation, the call is dispatched directly (a single indirect jump) without a vtable lookup. If the receiver type changes, the JIT falls back to a full vtable dispatch.

## 8. Escape Analysis and Scalar Replacement

Escape analysis is a JIT optimization that determines whether an object "escapes" the method that creates it — that is, whether it can be accessed by other threads or by code outside the current method. If an object does not escape, the JIT can apply scalar replacement: instead of allocating the object on the heap, the JIT allocates its fields as separate local variables (scalars) that can be stored in registers or on the stack.

For example, consider a `Point` object created to hold x and y coordinates during a geometric computation. If the `Point` is never passed to another method, stored in a global variable, or returned to the caller, the JIT can replace it with two integer variables `x` and `y`. This eliminates the heap allocation (saving memory and GC pressure) and the pointer indirection to access the fields (saving instructions).

HotSpot's C2 includes a powerful escape analysis that can even eliminate synchronization on non-escaping objects (lock elision). If a `StringBuffer` is used only within a single method and never shared between threads, C2 can remove the synchronization on its internal buffer, reducing overhead. This optimization is particularly effective for idiomatic Java code that creates many short-lived objects, like the builder pattern or stream pipelines.

## 16. The JIT Compilation Memory Model and Code Cache Management

JIT compilers consume memory for compiled code, and this memory must be managed carefully to avoid exhausting the process's address space. The "code cache" is a region of memory where the JIT stores compiled native code (and associated metadata: deoptimization tables, stack maps, GC maps). The code cache has a finite size (typically 128-512 MB for HotSpot, configurable with `-XX:ReservedCodeCacheSize`), and when it fills up, the JIT must evict less-frequently-used compiled code.

HotSpot's code cache is divided into three segments: non-profiled code (C1-compiled methods without profiling), profiled code (C1-compiled methods with profiling), and non-method code (stubs, adapters, runtime routines). When the code cache fills up, HotSpot "sweeps" — it identifies methods that have not been called recently and discards their compiled code, freeing space for new compilations. This is a form of "speculative deoptimization" — the method reverts to interpretation (or lower-tier compilation) and may be recompiled later if it becomes hot again.

V8's code cache management is more dynamic because it also serves JavaScript, which doesn't have a fixed set of methods. V8 uses a "generational" code cache: newly compiled code goes into a "nursery" region; code that survives multiple GC cycles (i.e., functions that continue to be called) is promoted to a "tenured" region. When memory pressure is high, V8 can flush the entire nursery, discarding code that was compiled for short-lived scripts or infrequently-called functions. This strategy reflects the web workload, where most JavaScript code runs once (page load) and is never used again.

## 17. Formal Verification of JIT Compilers

Can a JIT compiler be formally proven correct? This is an active research area with significant implications for security. A bug in a JIT compiler can generate incorrect native code that violates memory safety, creating vulnerabilities that circumvent all higher-level safety guarantees. Several projects have tackled JIT compiler verification.

The CompCertSSA project extends the CompCert verified C compiler with support for just-in-time compilation of a simple dynamic language. The verification proves that the JIT-generated code is semantically equivalent to the source program, assuming the source program passes the verifier. This is a refinement proof: the native code's behavior is a subset of the source program's specified behavior.

The SunSPOT project at Oracle Labs verified a subset of the HotSpot C1 compiler using the JVM's formal specification. The verification covers instruction selection (mapping bytecode to x86-64 instructions) and register allocation, proving that the generated code respects the JVM's type safety and memory safety guarantees. While not covering the full complexity of C1 (which includes inline caching, profiling, and deoptimization), SunSPOT demonstrated that automated verification of production JIT compilers is feasible.

## 18. Summary

JIT compilation is the alchemy that turns interpreted bytecode into native performance. At its core is a simple trade-off: invest compilation time where it yields runtime speedup. Multi-tier compilation operationalizes this trade-off by applying increasingly expensive optimizations to increasingly hot code. The magic of JIT compilation lies in speculation — by observing runtime behavior and optimizing for the common case, JITs can achieve performance that approaches or exceeds static compilation. Deoptimization provides the safety net, allowing the JIT to recover gracefully when its assumptions prove wrong.

The future of JIT compilation is increasingly tied to language design and hardware evolution. New languages with type systems designed for JIT optimization (Julia, Mojo) push the boundaries of what's possible. New hardware with larger caches, better branch predictors, and specialized instructions changes the cost-benefit calculus of speculative optimization. And new verification techniques promise to bring formal correctness guarantees to JIT compilers, making them not just fast but trustworthy.

## 9. Summary

JIT compilation is the alchemy that turns interpreted bytecode into native performance. At its core is a simple trade-off: invest compilation time where it yields runtime speedup. Multi-tier compilation — V8's Ignition+TurboFan, HotSpot's C1+C2 — operationalizes this trade-off by applying increasingly expensive optimizations to increasingly hot code. Tracing JITs offer an alternative approach, specializing on exact execution paths, but have largely been superseded by method JITs due to complexity.

The magic of JIT compilation lies in speculation. By observing runtime behavior and optimizing for the common case, JITs can achieve performance that approaches or even exceeds static compilation, because they have information that static compilers don't: the actual types flowing through each operation, the actual targets of each call, the actual shapes of each object. Deoptimization provides the safety net, allowing the JIT to recover gracefully when its assumptions prove wrong.

The future of JIT compilation is increasingly tied to language design. Languages like JavaScript and Python are notoriously difficult to optimize because of their dynamic typing and mutable object layouts. But even these languages yield to techniques like inline caching, hidden classes, and type feedback. As new languages emerge (Wasm, Mojo, Carbon) and old languages evolve (Java with value types, JavaScript with TypeScript-aware JITs), the JIT remains the bridge between programmer convenience and machine efficiency.

## 10. The GraalVM Compiler: JIT as a Framework

GraalVM, developed by Oracle Labs, represents a new approach to JIT compilation: the compiler itself is written in Java and runs as part of the application. GraalVM's JIT compiler (Graal) is a high-performance, retargetable compiler that can be used as a replacement for C2 in HotSpot (JVMCI, JVM Compiler Interface, allows pluggable JIT compilers), as a standalone compiler for native images (ahead-of-time compilation of Java to native executables), and as a multi-language JIT for Truffle languages (JavaScript, Python, Ruby, R).

The Graal compiler uses a sea-of-nodes IR, similar to TurboFan and C2, but with a focus on speculative optimizations that exploit dynamic type feedback. Graal's inlining heuristics are particularly sophisticated: they consider the caller's and callee's bytecode size, the call frequency, the receiver type profile, and the estimated code size increase, and they make inlining decisions that maximize performance within a code cache budget. Graal can inline through multiple levels of virtual dispatch by speculating on receiver types, deoptimizing if the speculation fails.

GraalVM's native image technology uses aggressive ahead-of-time (AOT) compilation, including closed-world static analysis, to produce standalone native executables from Java bytecode. The native image builder runs a closed-world analysis that determines all classes, methods, and fields reachable from the entry point, and compiles the entire application to native code. Reflection, JNI, and dynamic class loading must be configured explicitly (via reflection configuration files) because they are invisible to static analysis. The result is a native executable that starts in milliseconds (instead of seconds for a JVM) and uses a fraction of the memory of a JVM deployment.

## 11. PyPy and Meta-Tracing JITs

PyPy, the Python JIT compiler, takes a fundamentally different approach from method JITs: it's a meta-tracing JIT. Instead of tracing the user's Python program directly, PyPy traces the Python interpreter executing the user's program. The result is a JIT that can optimize any language implemented as an interpreter, not just Python.

The meta-tracing process works as follows. The developer writes an interpreter for their language in RPython (a restricted subset of Python that can be statically compiled). PyPy's toolchain translates the interpreter into C code, adding a "tracing JIT" layer that observes the interpreter's execution. When the interpreter executes a hot loop (in the user's program), the tracer records the interpreter's operations — the bytecode dispatch, the type checks, the arithmetic — and optimizes them across the interpreter boundary. The user's Python loop becomes a single trace of optimized machine code, with all interpreter overhead eliminated.

Meta-tracing is a remarkably elegant idea: write an interpreter, get a JIT for free. PyPy has demonstrated that this approach achieves performance competitive with V8's method JIT for Python (2-10x faster than CPython for most benchmarks), while requiring far less engineering effort than building a custom JIT for each language. The meta-tracing approach has been applied to Ruby (Topaz), PHP (HippyVM), and Prolog, demonstrating its generality.

## 12. The JavaScript Type Specialization Problem

JavaScript's dynamic typing poses a unique challenge for JIT compilers. In Java, `int x = 5` guarantees that `x` is always an integer. In JavaScript, `let x = 5` assigns an integer to `x`, but `x` could later hold a string, an object, or `undefined`. The JIT must handle all possible types while optimizing for the common case.

V8's approach is "type feedback" — Ignition observes the types flowing through each operation and records them in feedback vectors. If a function's `+` operator always sees two integers, Ignition records "both operands are Smis (small integers)" in the feedback. TurboFan then specializes the compiled code for integer addition, with a guard: if either operand is not a Smi, deoptimize.

This speculation is incredibly effective in practice. JavaScript programs are typically "type-stable" — variables hold the same type throughout their lifetime, even though the language allows them to change. The JIT exploits this stability to generate code that's as fast as statically typed code, with deoptimization as the fallback when the assumption fails. The combination of type feedback, speculative optimization, and deoptimization is what makes JavaScript performance competitive with statically typed languages.

## 13. The PyPy Meta-Tracing JIT in Depth

PyPy's meta-tracing approach is worth examining in more detail because it represents a fundamentally different point in the JIT design space. A meta-tracing JIT traces the interpreter, not the user program. When the interpreter executes a hot loop in the user's Python program, the tracer records every interpreter operation — bytecode dispatch, stack manipulation, type checks. The trace is then optimized across the interpreter boundary: all the interpreter overhead is constant-folded away, leaving just the user's operations.

For example, a Python function `def add(a, b): return a + b` might translate to a dozen interpreter bytecodes: load a, load b, binary_add, return. The tracer records all twelve operations and optimizes them to two native instructions: load a into register, add b to register, return. The ten interpreter bytecodes that moved data between the Python stack and the interpreter's internal registers are eliminated because the trace optimizer can see that they're redundant when the interpreter's state is inlined.

Meta-tracing is an elegant shortcut: instead of writing a JIT for your language, write an interpreter and let the meta-tracer turn it into a JIT. The downside is that the JIT is only as good as the interpreter's design — a poorly structured interpreter produces traces that are hard to optimize. PyPy's interpreter was carefully designed for traceability, with a straight-line bytecode dispatch and minimal abstraction.

## 14. Partial Evaluation and Futamura Projections

The theoretical foundation of JIT compilation lies in partial evaluation, a program transformation technique developed by Yoshihiko Futamura in the 1970s. A partial evaluator takes a program and some of its inputs, and produces a specialized version of the program that is optimized for those known inputs. The first Futamura projection states that specializing an interpreter with respect to a source program yields a compiled program. The second Futamura projection states that specializing a partial evaluator with respect to an interpreter yields a compiler. The third states that specializing a partial evaluator with respect to itself yields a compiler generator.

JIT compilation can be understood through this lens. The interpreter is a general program that executes bytecode. The bytecode is a "known input" that can be partially evaluated. The JIT compiler partially evaluates the interpreter with respect to the bytecode, producing specialized native code. This is exactly what a tracing JIT does (it records the interpreter's execution on a specific path) and what a method JIT does (it compiles the interpreter's bytecode handlers for a specific method). The Futamura projections provide a formal framework for understanding why JIT compilation works: it's partial evaluation applied at runtime.

In practice, modern JIT compilers go beyond simple partial evaluation. They apply speculative optimizations based on observed runtime behavior (type feedback, branch probabilities), not just static partial evaluation. They deoptimize when assumptions fail, reverting to the interpreter. And they tier compilation, applying more investment to hotter code. These extensions make JIT compilation more powerful than classical partial evaluation, but the conceptual foundation remains.

## 15. The Limits of JIT Compilation and the Rise of AOT

JIT compilation has theoretical limits that have driven renewed interest in ahead-of-time (AOT) compilation. The "warm-up" problem: a JIT-compiled program runs slowly at startup because it starts in the interpreter and must "warm up" before the JIT optimizes hot code. For long-running servers, this is acceptable. For short-lived functions (serverless, CLI tools), the program might exit before the JIT finishes optimizing. The "memory overhead" problem: JIT compilers store compiled code in a code cache, which grows over time. For memory-constrained environments (mobile, embedded), this overhead is significant. The "profile pollution" problem: if a function is optimized for one workload profile and later used with a different profile, the optimizations may be counterproductive, requiring deoptimization and recompilation.

These limits have driven the adoption of AOT compilation for managed languages. GraalVM Native Image compiles Java bytecode to native executables ahead of time, eliminating warm-up and reducing memory overhead by 10-50x compared to JVM deployment. .NET Native (and .NET 7's ReadyToRun) provide AOT compilation for .NET applications. Kotlin/Native compiles Kotlin directly to native code via LLVM. The trade-off is that AOT compilation loses the ability to speculate on runtime behavior — type feedback, branch probabilities, and inline caches are all runtime phenomena that AOT cannot exploit. The future is likely hybrid: AOT for startup and memory efficiency, JIT for peak performance, with the runtime seamlessly transitioning between them.

## 19. The Economic Argument for JIT vs AOT Compilation

Why do JIT compilers still dominate for managed languages like Java and JavaScript, despite the warm-up overhead and code cache memory cost? The answer is economic: JIT compilation enables "write once, run anywhere" with competitive performance, without per-platform compilation or distribution complexity.

A Java application compiled AOT (via GraalVM Native Image) produces a single native binary for a specific platform (Linux/x86-64, say). To support multiple platforms, the developer must produce (and test) multiple binaries. The JAR file (bytecode), in contrast, runs on any platform with a JVM. The JVM's JIT compiler adapts the code to the specific CPU microarchitecture (Skylake vs Zen vs Apple Silicon), applying optimizations that are only valid for that specific hardware.

Furthermore, the JIT can exploit runtime information that AOT cannot. A server that runs the same JAR for years benefits from HotSpot's "aging" optimizations: code that has been running for days or weeks receives the highest optimization tier and is never deoptimized. The JIT essentially performs profile-guided optimization (PGO) on live production data, achieving better performance than any offline training run could. This "organic optimization" is impossible with AOT compilation and is a key reason why Java and JavaScript performance continues to improve the longer an application runs.
