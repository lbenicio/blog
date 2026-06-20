---
title: "The Performance Of Jit Compilation For Dynamic Languages: Pypy’S Tracing Jit Vs. Naive Interpreter"
description: "A comprehensive technical exploration of the performance of jit compilation for dynamic languages: pypy’s tracing jit vs. naive interpreter, covering key concepts, practical implementations, and real-world applications."
date: "2023-10-02"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/the-performance-of-jit-compilation-for-dynamic-languages-pypy’s-tracing-jit-vs.-naive-interpreter.png"
coverAlt: "Technical visualization representing the performance of jit compilation for dynamic languages: pypy’s tracing jit vs. naive interpreter"
---

This is an excellent introduction that has all the hallmarks of a great technical deep-dive. The central conflict is clear, the stakes are high, and the solution (PyPy) is presented not as a magic bullet, but as the product of a specific, brilliant engineering trade-off.

Let’s expand this into the full, 10,000-word masterpiece it deserves to be. I will maintain the professional yet engaging tone, build on your excellent introduction, and structure the content for maximum impact and clarity.

---

### Part 1: Deepening the Axiom – The Slowness of Simplicity

Every programmer knows the trade-off. You can have the beautiful, flexible, expressive code of a dynamic language like Python or Ruby, a world where types are a suggestion and reflection is a superpower. Or you can have the raw, blistering speed of a statically-typed language like C or Rust, a world where every byte is accounted for before the program even starts. For decades, this has been the accepted axiom of software engineering: choose dynamism for agility, choose static typing for performance. You cannot have both.

But what if that axiom is a lie? Or, more precisely, what if it's an artifact of a limited imagination? What if you could write Python—the darling of glue code, data science, and rapid prototyping—and have it run at speeds that rival, or even surpass, hand-optimized C? This isn't a fever dream. It’s the promise, and the reality, of the cutting edge of runtime technology: the Tracing Just-In-Time (JIT) compiler, as embodied by PyPy.

This topic matters more than ever. We are living in an era of computational hunger. Data pipelines process petabytes, web servers handle millions of concurrent requests, and AI models are becoming more complex by the day. The critical infrastructure of modern technology—from the machine learning frameworks that power your recommendation feeds to the web backends that deliver your morning news—is increasingly written in dynamic languages. Python, in particular, is the undisputed king of exploration and development. Yet, its runtime performance is often a bottleneck. The standard CPython interpreter, for all its virtues of simplicity and stability, is a slowpoke.

The typical solution has been the "nuclear option": rewrite the hot path in C or C++. We see this in NumPy, the backbone of scientific Python, where the loops are executed by highly optimized, pre-compiled C and Fortran libraries. We see it in web frameworks like Django, where the template engine ultimately calls out to C for string operations. This works, but it creates a profound fracture in the developer experience. You are, in effect, writing a program in two languages: the Python glue and the C engine. This adds complexity, a significant barrier to entry, and a fragile boundary where errors can be catastrophic.

To truly understand the solution, we must first appreciate the depth of the problem. Why is CPython so slow? It’s not just a matter of “it’s interpreted.” The devil is in the details. Every single operation in a running Python program, from a simple `a + b` to a complex function call, goes through a layer of indirection and dynamism that would make a C compiler weep.

**The CPython Bytecode Loop: A Virtual Machine in Slow Motion**

When you run `python my_script.py`, the first thing that happens is compilation to bytecode. This is not the machine code of your CPU. It’s a high-level, portable representation of your program designed for a stack-based virtual machine. This bytecode is then executed by the CPython interpreter, a gargantuan `switch` statement inside a `for` loop. This loop is the heart of the slowness.

Consider the Python expression: `z = x + y`.

This seemingly simple line is translated into two bytecode instructions: `LOAD_FAST`, which pushes the value of `x` onto the virtual stack, and `BINARY_OP`, which pops the top two values, performs the addition, and pushes the result.

Inside the interpreter’s main loop, when it hits the `BINARY_OP` instruction, a cascade of work begins:

1.  **Type Lookup:** CPython doesn't know what `x` and `y` are. They could be integers, floats, strings, lists, or user-defined objects. It must call `PyNumber_Add(x, y)`.
2.  **Method Resolution:** `PyNumber_Add` doesn’t just add. It first looks up the `__add__` method on the type of `x`. It checks if `x` has a `tp_as_number` structure. This is a hash table lookup in the object's type's method table.
3.  **Argument Checking:** If `x` is an integer, it calls `int_add(x, y)`. Before that, it must check if `y` is also an integer. If not, it goes into a coercion protocol.
4.  **Object Construction:** The result, even for a simple integer, must be allocated on the heap as a new Python object (`PyLongObject`). This involves a call to `malloc` (or a custom allocator) to grab memory, setting the object’s reference count to 1, and storing the result.
5.  **Reference Counting:** The previous values of `x` and `y` were referenced. Now their reference counts must be decremented. If a count falls to zero, the object’s memory must be freed.

This entire, verbose sequence happens for _every single addition_ in your code. A C compiler would see `z = x + y` and emit, at most, three machine instructions: load `x` into a register, load `y` into another, and `ADD`. That’s it. No object creation, no type checking, no hash table lookups.

The interpreter is trapped by its own dynamism. It must pay the cost of generality at every single instruction. This is the "tax" of dynamic languages. The tax is a constant overhead per operation, often measured in hundreds of CPU cycles, versus the single-digit cycles of native code.

The "nuclear option" works because it bypasses the interpreter entirely. C code doesn't check types at runtime. It doesn't manage reference counts (or if it does with `Py_INCREF`, it does it as a conscious, explicit act). It just computes. But the code lives in a different universe, a frozen, pre-compiled world, cut off from the flexibility of Python.

The Tracing JIT compiler, the hero of our story, offers a third path. Its core insight is this: **Dynamism is a spectrum, not a binary state.** A program, even a highly dynamic one, spends most of its time in very rigid, predictable local patterns. The tracing JIT doesn't try to analyze the entire program ahead of time. Instead, it observes the program's execution at runtime, identifies the "hot" paths (the loops that are running over and over), and compiles a highly optimized, specialized version of _just that path_ into machine code.

This is the speed paradox resolved: not by sacrificing dynamism globally, but by surgically removing its cost at the most critical, repetitive points in execution.

### Part 2: The Spectrum of JIT Compilation – A Brief History of Speed

To fully appreciate the elegance of the Tracing JIT, we need to understand its place in the history of runtime optimization. JIT compilation is not a single technique, but a family of approaches, each with its own trade-offs between compilation time, code quality, and complexity.

**2.1. The Template JIT (The Simplest Approach)**

A Template JIT is a direct, one-to-one translation of bytecodes into machine code. For each bytecode instruction (like `BINARY_ADD`), there is a pre-written template of machine code. The JIT compiler, instead of interpreting the bytecode, simply copies the corresponding template into a block of executable memory and jumps to it.

This approach is simple to implement and fast to compile. However, it largely inherits the same overhead as the interpreter. The machine code for `BINARY_ADD` will still contain all the type checks, method lookups, and object allocation that the interpreter did. It’s simply running that overhead in native code instead of a C `switch` statement. The speedup is modest, often 2-3x at best. Early JITs for Java and .NET were largely template-based.

**2.2. The Method JIT (The Enterprise Standard)**

This is the dominant paradigm today, used by HotSpot (Java), V8 (JavaScript, including Node.js and Chrome), and the .NET CLR. The unit of compilation is a _method_ or _function_.

When the runtime profiler determines a method is "hot" (e.g., it's been called many times), the entire method is queued for compilation. The method JIT compiles the function's bytecode into optimized machine code. The key is that this optimization can be much more aggressive than a template JIT. It can perform global analysis of the function:

- **Type Specialization:** Based on profiling data, it can assume that a parameter `x` is always an integer and generate code accordingly. If the assumption is ever broken, a "guard" in the generated code will trigger a "deoptimization" (bailout) back to the interpreter to handle the exceptional case.
- **Inlining:** If a method `foo()` calls a small method `bar()`, the compiler can inline `bar()`’s code directly into `foo()`, removing the function call overhead and enabling further optimizations across the two.
- **Intrinsics:** The compiler recognizes specific method calls (like `String.length()`) and replaces them with a single machine instruction (like `mov` from a known offset in the object), avoiding a call to the Java standard library.

Method JITs are powerful and can produce excellent code (often rivaling C++). However, they have a significant startup cost. The profiler needs to run for a while to identify hot methods, and the compilation of a complex method can take milliseconds. This is acceptable for long-running server processes (e.g., a JVM-based web server or a V8-powered Node.js service), but it creates a poor experience for short-lived scripts or highly interactive applications.

**2.3. The Tracing JIT (The Disruptor)**

The Tracing JIT flips the script entirely. Its unit of compilation is not a method, but a _trace_. A trace is a single, sequential path through the program's control flow. It is not the whole loop, but a record of one specific iteration of that loop under a specific set of runtime conditions.

The tracing JIT works in a fundamentally different way. It doesn't wait for a method to be hot. It uses an interpreter or a baseline JIT to run the code. A separate profiler monitors backward branches, which are the hallmark of loops. When a loop is detected as hot (e.g., iterating 1000 times), the system enters "recording mode." It switches from interpreting the bytecode to tracing it. Every step the interpreter takes—every bytecode executed in the loop's body—is recorded into a linear sequence called a _trace_.

Crucially, this recording is not just of the instructions, but of the _dynamic types and values_ of all variables. If `x` is an integer the first time through the loop, the trace will record `x` as an integer. It makes assumptions (called "guards") based on this single observation.

Once the loop exits (or after a certain number of recorded instructions), the tracer stops and hands the linear trace to the JIT compiler. The compiler takes this trace, which is a sequence of simple, specialized operations, and compiles it into highly optimized machine code. It can perform all the optimizations of a method JIT (constant folding, strength reduction, dead code elimination), but on a much smaller, simpler, and more predictable piece of code.

The generated code is a "fast path." It's a specialized piece of machine code for the exact conditions of that one trace. It is **guarded**. At the start of the compiled trace, there are checks (guards) to ensure that the runtime types and conditions match the assumptions made during recording. If they do, the code runs at blazing speed, almost as fast as C. If a guard fails, the execution bails out, back to the interpreter, and a new trace can be recorded for the new conditions.

This is the genius of the tracing JIT. It turns the interpreter's greatest weakness—its verbosity and need for generality—into its greatest strength. The interpreter provides a perfect "fallback" for any condition that the compiler doesn't understand. The compiler only needs to be correct for the hot paths. The interpreter handles the complex, edge-case, one-off paths.

### Part 3: The Deep Dive – How PyPy Makes the Paradox a Reality

PyPy is the most famous and successful implementation of a Tracing JIT for a dynamic language. It is not a compiler for Python. It is a _framework_ for writing dynamic language interpreters in a language called RPython (Restricted Python), which automatically yields a Tracing JIT for that language.

**3.1. The Pyramid of Abstraction: RPython, Meta-Tracing**

This is the most mind-bendingly beautiful part of PyPy's architecture. Instead of writing a Python interpreter _and_ a JIT compiler by hand, the PyPy team wrote a meta-tracing framework.

1.  **RPython Framework:** The PyPy core developers create a framework. This framework has primitives for building a bytecode interpreter. It abstracts over things like object models, garbage collection, and type representations.

2.  **Python Interpreter in RPython:** The PyPy team then writes a Python interpreter _in RPython_. RPython is a statically-typed subset of Python. You cannot use `eval`, metaclasses, or `__getattr__` at runtime in RPython. It looks and feels like Python, but it compiles down to C code (via the RPython toolchain). This is the "executor" for Python bytecode.

3.  **The Meta-Tracing JIT:** The magic of the framework is that any interpreter written in RPython _automatically_ gets a Tracing JIT for free. The framework itself contains the generic tracing and compilation machinery. It doesn't know anything about Python's addition operator. It only knows that the interpreter, written in RPython, has a large `switch` statement for processing bytecodes. The meta-tracer traces the execution of _this interpreter_ as it executes a Python program's bytecode.

Let's think about this carefully. When you run `z = x + y` in PyPy, the RPython interpreter is executing. Its internal bytecode loop is running. The meta-tracer traces the _interpreter's_ execution path. It sees the RPython code for `LOAD_FAST` and `BINARY_OP`. It doesn't care about the Python object "3." It cares about the RPython data structure representing that object.

The meta-tracer sees a sequence of low-level RPython operations: checking a pointer, accessing a field in a structure (to get the type of the Python object), jumping to a function pointer (for the addition). The result of the meta-tracing is a JIT compiler _for the Python interpreter itself_. This generated JIT compiler knows how to take a specific trace of Python bytecodes and turn it into machine code that runs the interpreter's RPython logic natively, bypassing the interpreter's own bytecode dispatch loop.

This is often called "bootstrapping the JIT." It is a radical departure from the standard approach. The PyPy team didn't write a new JIT compiler for Python. They wrote a tool that lets you write an interpreter and automatically get a JIT compiler for it. This is why PyPy can support the full Python language (minus a few edge cases with C extensions) with such remarkable fidelity. The interpreter handles all the complexity; the JIT just accelerates the hot paths through it.

**3.2. Anatomy of a PyPy Trace: From Python to Machine Code**

Let's walk through a concrete example to see how a trace is formed.

Consider this Python code:

```python
def sum_to_n(n):
    total = 0
    for i in range(n):
        total += i * i
    return total

print(sum_to_n(10000000))
```

When CPython runs this, it's slow. The inner loop has a multiplication and an addition, each with the overhead of object creation, type checking, etc.

When PyPy runs this:

1.  **Warm-up:** The interpreter runs the `sum_to_n` function normally. The profiler in the JIT framework notices that the loop `for i in range(n)` is being executed repeatedly.

2.  **Trace Start:** After the loop has been iterated, say, 1000 times, the tracer is activated. It starts recording. The interpreter is about to execute the bytecode for `i * i`.

3.  **Trace Recording (The Linear Sequence):** The recorder observes the exact operations the interpreter performs.
    - It sees the RPython code to look up the `__mul__` method on the object `i`.
    - It sees `i` is an integer (a `PyLongObject` in Python 3, or a `W_IntObject` in PyPy's terminology).
    - It sees the interpreter find the `int_mul` function.
    - It records a guard: `guard_class(i, W_IntObject)`.
    - It then sees the interpreter call `int_mul(i, i)`.
    - The RPython code for `int_mul` is traced. It extracts the C long value from the `W_IntObject`, multiplies it, and creates a new `W_IntObject` with the result.
    - The recorder sees this. It knows the structure of a `W_IntObject`. It sees the `malloc` call for the new result, the write of the integer value into it.
    - The loop continues. It adds the result to `total`.
    - The loop back-edge (jump to the start of the loop) is recorded.

The trace is a long, linear sequence of low-level RPython operations. Here’s a simplified, pseudo-representation of what the trace might look like:

```
v1 = get_var(loop, 'i')        # Get the object for i
guard_class(v1, W_IntObject)    # Check i is still an integer
v2 = get_field(v1, 'intval')    # Extract the C long value: i_val
v3 = mul(v2, v2)               # i_val * i_val
v4 = new(W_IntObject)           # Allocate new Python object
v5 = set_field(v4, 'intval', v3) # Store the result
# ... similar process for total = total + v4 ...
v6 = get_var(loop, 'total')
guard_class(v6, W_IntObject)
v7 = get_field(v6, 'intval')
v8 = get_field(v4, 'intval')    # v4 is the result of i*i
v9 = add(v7, v8)
v10 = new(W_IntObject)
v11 = set_field(v10, 'intval', v9)
set_var(loop, 'total', v10)

# ... loop back-edge ...
guard_not_finished()
jump_to_start()
```

4.  **Optimization (The JIT Compiler):** This trace is passed to the optimizer. This is where the real magic happens.
    - **Allocation Removal (Escape Analysis):** The optimizer sees `v4 = new(W_IntObject)` and `v10 = new(W_IntObject)`. It analyzes the trace. Can the new object "escape"? Is its address ever stored somewhere where another part of the program could access it, or is it used only for the subsequent operations in this trace? In this loop, the object `v4` is created, its `intval` is read into `v9`, and then... it's never used again. It's a temporary. The optimizer can **eliminate the allocation**. It replaces `v4` with a "virtual" alias for `v3`. It does the same for `v10`.
    - **Instruction Simplification:** With `v4` and `v10` removed, the trace becomes much simpler. The `get_field` and `set_field` operations on them are removed. The guards on `v4` and `v10` are also unnecessary (they are known to be `W_IntObject`).
    - **Constant Folding:** If `i` is a small constant, the multiplication can be computed at compile time.
    - **The Final Trace (Optimized):**

      ```
      v1 = get_var(loop, 'i')
      guard_class(v1, W_IntObject)
      v2 = get_field(v1, 'intval')
      v3 = mul(v2, v2)
      v6 = get_var(loop, 'total')
      guard_class(v6, W_IntObject)
      v7 = get_field(v6, 'intval')
      v9 = add(v7, v3)
      v10 = new(W_IntObject)         # Can we remove this too? Yes!
      set_var(loop, 'total', v10)  # Actually, it's all virtual.

      # loop back-edge
      guard_not_finished()
      jump_to_start()
      ```

After further optimization, the entire loop might be reduced to a single machine-code loop that operates on CPU registers (representing `i` and `total`) directly. There are no Python objects being created inside the loop. The `i` and `total` values are held as simple C `long` values. The `W_IntObject` is only materialized (created on the heap) if the loop exits and the value is needed by non-compiled Python code.

This is the speedup. The hot loop is no longer creating millions of Python objects, looking up methods, or managing reference counts. It is running a tight, register-based loop that does pure arithmetic. For `sum_to_n(10000000)`, PyPy can often be 50-100x faster than CPython on this code.

5.  **Guard Failure (The Bailout):** What if the Python code changed? What if we passed a list of floats? The `guard_class` instructions would fail. The generated machine code would jump to a "bailout" routine. This routine tears down the optimized stack, recreates the Python-level interpreter state (re-creating the `W_IntObject` from the register values that were stored), and jumps back to the interpreter. The interpreter then continues, and the profiler will eventually trigger a new trace for the new type.

### Part 4: The Reality Check – When the Paradox Breaks (And When It Holds)

The speed paradox is not universally conquered. PyPy is not a magic wand that makes all Python code fast. Understanding its strengths and weaknesses is essential to knowing when to wield it.

**When the Paradox Holds: PyPy’s Sweet Spots**

1.  **Long-Running, Loop-Intensive Pure Python:** This is PyPy's home turf. Any code that spends most of its time in tight Python loops doing arithmetic, string operations, or list/dict manipulations will see massive speedups. Data munging scripts, text parsing, and ETL pipelines that are written in pure Python are prime candidates.

2.  **Algorithms and Data Structures:** If you have implemented a merge sort or a binary search tree in pure Python, PyPy will make it scream. The tracing JIT can eliminate the overhead of function calls (via inlining) and object creation. The performance of a PyPy-accelerated algorithm can often approach that of a C implementation.

3.  **Web Frameworks (with caveats):** Frameworks like Flask, Django, and Pyramid benefit from PyPy. The actual business logic of a web request often involves a lot of Python-level dictionary lookups, string formatting, and conditional logic. PyPy's JIT can optimize these. However, the database interaction (via `psycopg2` or `MySQLdb`) is usually in C extensions, which can negate some of PyPy's advantage. The overhead of the JIT's warm-up can also be a problem for the first few requests to a server.

**When the Paradox Weakens: PyPy’s Kryptonite**

1.  **The C Extension Wall (The Interoperability Nightmare):** This is the single biggest barrier to PyPy's adoption. The "nuclear option" of rewriting hot paths in C is the default in the Python ecosystem. NumPy, Pandas, LXML, Pillow, and countless other foundational libraries are C extensions.

    CPython extensions are written against the CPython C API (`Python.h`). This API assumes direct access to CPython's internal data structures (like `PyObject`'s reference count and type pointer). PyPy's object model is fundamentally different. It uses a garbage collector (often a generational one), not reference counting. Its objects are laid out differently in memory.

    To run these extensions, PyPy provides a compatibility layer called **cpyext**. This layer creates a "shadow" CPython-style `PyObject` for every PyPy object that needs to interact with a C extension. This is immensely complex and slow. Every call from the C extension into Python, and vice-versa, involves crossing this boundary. For `numpy` operations, where the core work is in the C arrays, PyPy often loses its JIT advantage. The overhead of cpyext can make it significantly slower than CPython.

    The community has made strides. PyPy can now run a significant portion of NumPy's API, but performance is inconsistent. For data science workloads, CPython with NumPy remains the de facto standard.

2.  **Short-Lived Scripts:** If your `main()` function runs for less than a few hundred milliseconds, PyPy will likely be slower than CPython. The overhead of PyPy's own startup, the initial interpretation, and the JIT compilation must be paid. For a script that runs for 10ms, that overhead is a significant fraction of the total runtime. CPython, which starts up almost instantly, will win. This is the classic JIT startup penalty.

3.  **Memory Footprint:** A PyPy process can use significantly more memory than a CPython process for the same program. This is due to the overhead of:
    - The JIT compiler itself, which is a large piece of code loaded into memory.
    - The compiled traces (machine code blocks) that are stored in memory.
    - The garbage collector's metadata and the heap structure (often a generational GC has more overhead than a simple reference counting scheme).
    - The cpyext compatibility layer, which can create shadow objects.

    For a memory-constrained environment (like a Raspberry Pi or a microservice with a strict memory limit), this can be a deal-breaker.

4.  **Highly Polymorphic Code:** The tracing JIT thrives on monomorphic behavior (e.g., a variable always being an integer). If a variable's type changes frequently (e.g., a variable that is an integer on one iteration and a float on the next, or a function that accepts multiple types of arguments), the guards will fail constantly. Each failure triggers a bailout to the interpreter and a new trace attempt. The cost of failed speculation can overwhelm the benefit. Highly dynamic, deeply object-oriented code with complex inheritance hierarchies can be hard for a tracing JIT to optimize.

### Part 5: The Future of the Paradox – Beyond PyPy

The Tracing JIT is not the end of the story. The speed paradox is being attacked from multiple fronts.

**5.1. The Advent of Sub-typing and Static Analysis in Python**

The Python community is embracing static typing. The `mypy` type checker is now a standard tool. While Python's runtime is still dynamic, the presence of type annotations allows for new possibilities.

Projects like **Codon** are a radical departure. Codon is a Python compiler that uses type annotations and a static analysis pass to compile Python code directly to highly optimized native code, completely bypassing the CPython interpreter and runtime. Codon doesn't support the full Python runtime (no `eval`, no dynamic class creation at runtime), but for numerical and scientific code that uses static typing, it can produce code that rivals C++.

**5.2. The Future of Interpreters: Zonal Compilation and PGO**

The PyPy team is not resting on its laurels. A major area of research is **zonal compilation**, where the JIT is smart enough to compile larger, more coherent regions of the program than a simple loop trace. Meta-traces that cross function boundaries and even module boundaries can lead to even larger performance gains.

Another approach is **Profile-Guided Optimization (PGO)** inside the JIT. Instead of just tracing a single path, the JIT can gather richer profiling data about the likelihood of different branches. This allows it to generate code that is better optimized for the most common scenarios.

**5.3. The Resurgence of the Managed Runtime**

The lines are blurring. The .NET CLR with its RyuJIT is incredibly fast for C#. The JVM's HotSpot C2 compiler can produce code that is within a few percentage points of C++. The V8 engine for JavaScript has made browser-based apps faster than many desktop apps. The idea that "dynamic must be slow" is being steadily dismantled. The future likely belongs to "gradual typing" or "latent typing" – runtime systems that can dynamically adapt their compilation strategy based on the observed behavior of the code, making no distinction between a "statically typed" function and a "dynamically typed" one.

### Conclusion: Embrace the Paradox, Choose Your Weapon

The speed paradox is not a lie, but it is an oversimplification. The axiom that you must choose between dynamism and speed is a product of a specific technology from a specific time—the single-language, single-paradigm interpreter. The modern landscape is richer and more nuanced.

You don't have to choose one over the other forever. You can now build a system that is 90% Python (for flexibility, exploration, and rapid development) and identify the 10% that is the bottleneck. For that 10%, you now have multiple weapons:

- **The Nuclear Option (C Extensions):** Use it if you need battle-hardened libraries like NumPy and Pandas. Accept the complexity.
- **The Disruptor (PyPy):** Use it if your hot path is pure Python code with simple types and loops. Accept the startup time, the memory cost, and the occasional C extension headache.
- **The Compiler (Codon):** Use it for new, self-contained, numerically intensive projects where you can commit to static typing.

The beauty of this moment is that these are not mutually exclusive. The best engineers are becoming polyglots, not just in human languages, but in _runtime systems_. They understand that the "best" way to run Python is not a single answer. It's a choice made with deep context—an understanding of the trade-offs between dynamism, speed, memory, and startup time.

The next time you write a `for` loop in Python, remember that the CPU is not cursed. It is not inherently bound by the slowness of the interpreter. The performance is there, waiting to be unlocked. The key is not to abandon Python for C. The key is to use a runtime that understands that the vast majority of your code is repetitive, predictable, and waiting to be optimized into a rocket. The speed paradox is not a wall. It's a door. And the Tracing JIT is the key.
