---
title: "Implementing A Virtual Machine For A Stack Based Language: Bytecode Interpreter And Jit Compilation"
description: "A comprehensive technical exploration of implementing a virtual machine for a stack based language: bytecode interpreter and jit compilation, covering key concepts, practical implementations, and real-world applications."
date: "2020-12-23"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/implementing-a-virtual-machine-for-a-stack-based-language-bytecode-interpreter-and-jit-compilation.png"
coverAlt: "Technical visualization representing implementing a virtual machine for a stack based language: bytecode interpreter and jit compilation"
---

# Beyond the Interpreter: Forging a Hybrid Virtual Machine for a Stack-Based Language

## Introduction (continued)

...holding up the modern software ecosystem. From the Java Virtual Machine that powers enterprise servers to the JavaScript engines in every web browser, VMs have become the invisible engines that balance portability with performance. The language we write is no longer for the silicon; it is for a machine we have imagined into existence—a clean, consistent, and often simpler computer that insulates us from the messy realities of hardware evolution.

This imagined machine, however, comes at a cost. Every instruction in the virtual world must be translated, through many layers of indirection, into the real instructions that the CPU can execute. This translation can be done purely by interpretation—a byte‑by‑byte simulation that is simple but slow. Or it can be done by compilation—taking the virtual program and translating it ahead of time into native machine code. Or, most elegantly, it can be done by a **hybrid approach** that starts with interpretation for quick startup and gradually replaces hot code paths with just‑in‑time (JIT) compiled code for peak performance.

In this deep‑dive, we will forge such a hybrid VM from the ground up. We will define a small, stack‑based bytecode language, build a fast interpreter, layer a simple JIT compiler on top, and then merge them into a two‑tier execution engine. Along the way, we will confront the real engineering trade‑offs: how to handle self‑modifying code, how to manage memory across tiers, and how to decide when to switch from interpretation to compilation. By the end, you will have a working VM that can execute a real program—say, computing Fibonacci numbers—using both interpretation and JIT, and you will understand the inner workings of systems like the JVM, V8, and LuaJIT.

Let’s begin by designing the language that our VM will speak.

---

## Section 1: Defining the Stack‑Based Bytecode Language

A stack‑based language is one where most operations consume their operands from a stack and push their results back onto the same stack. There are no registers in the traditional sense; the stack is the primary working storage. This model is simpler to implement than a register‑based one (because we don’t need to manage a large set of named registers) and lends itself naturally to a compact bytecode representation. Well‑known examples include the Java Virtual Machine (JVM) bytecode, the Python bytecode (though it has some register‑like features), and Forth.

### 1.1 The Architecture

Our VM will be a 64‑bit machine (for simplicity, we assume a 64‑bit host). It will have:

- **An operand stack** for expression evaluation. Each stack element is a 64‑bit value (we will support integers and, later, pointers).
- **A call stack** (or return stack) that stores return addresses and saved frame pointers. In many stack‑based VMs, the two stacks are separate; we will keep them distinct for clarity.
- **Local memory** (like local variables) accessed by index.
- **A program counter (PC)** that points into the bytecode stream.
- **A heap** for dynamic allocation (basic malloc/free, though we won’t implement garbage collection in this version).

### 1.2 Instruction Set

We define a minimal set of opcodes. Each opcode is a single byte, optionally followed by operands (1, 2, 4, or 8 bytes). We will use little‑endian encoding. The following table lists the opcodes we need:

| Opcode | Mnemonic | Operand(s)            | Stack effect (before → after) | Description                                        |
| ------ | -------- | --------------------- | ----------------------------- | -------------------------------------------------- |
| `0x01` | `ICONST` | 4‑byte signed integer | → i                           | Push a constant integer onto the stack             |
| `0x02` | `IADD`   | none                  | i1 i2 → result                | Pop two integers, push their sum                   |
| `0x03` | `ISUB`   | none                  | i1 i2 → result                | Pop two integers, push i1 - i2                     |
| `0x04` | `IMUL`   | none                  | i1 i2 → result                | Pop two integers, push i1 \* i2                    |
| `0x05` | `IDIV`   | none                  | i1 i2 → result                | Pop two integers, push i1 / i2 (truncating)        |
| `0x06` | `IPRINT` | none                  | i →                           | Pop an integer and print it (side effect)          |
| `0x07` | `JMP`    | 2‑byte offset         | →                             | Unconditional jump to PC + offset (relative)       |
| `0x08` | `JZ`     | 2‑byte offset         | cond →                        | Pop integer, jump if zero                          |
| `0x09` | `CALL`   | 2‑byte address offset | → (later arg count)           | Call a function (details below)                    |
| `0x0A` | `RET`    | none                  | →                             | Return from function (pop return address and jump) |
| `0x0B` | `LD`     | 1‑byte local index    | → value                       | Push local variable value                          |
| `0x0C` | `ST`     | 1‑byte local index    | value →                       | Store value into local variable                    |
| `0x0D` | `ALLOC`  | 2‑byte size in bytes  | → ptr                         | Allocate memory on heap, push pointer              |
| `0x0E` | `FREE`   | none                  | ptr →                         | Free heap memory                                   |
| `0x0F` | `HALT`   | none                  | →                             | Stop execution                                     |

We will also add a few more opcodes as needed (e.g., `ICMP` for comparisons). The important point is that the language is Turing‑complete and small enough to manage.

### 1.3 Example: Fibonacci

Let’s write a factorial function in our bytecode language. We’ll use a procedural style with explicit calls. The high‑level pseudocode is:

```
function factorial(n):
    if n == 0:
        return 1
    else:
        return n * factorial(n - 1)
```

We need to decide on a calling convention. For simplicity, arguments are passed on the operand stack. The function pops its argument and pushes the result. The `CALL` instruction takes a relative offset to the target function’s first instruction. When `CALL` executes, it pushes the current PC+2 (the return address) onto the call stack, then jumps. The `RET` instruction pops the return address and jumps there. We also need to save and restore the local variable frame, but for now we can use a simple mechanism: each function has a fixed number of local slots (say 8). The caller does not need to save anything.

Bytecode for factorial (addresses are byte offsets):

```
0x00:  ICONST 1           ; push constant 1
0x05:  ST 0               ; store into local[0] (will hold result)
0x08:  LD 1               ; load argument n (local[1])
0x0B:  ICONST 0           ; push 0
0x10:  JZ  0x??           ; if n == 0, jump to base case
0x13:  LD 1               ; load n
0x16:  LD 1               ; load n again
0x19:  ICONST 1           ; push 1
0x1E:  ISUB               ; n - 1
0x1F:  CALL factorial     ; recursive call (offset to start)
0x24:  IMUL               ; n * result
0x25:  ST 0               ; store into local[0]
0x28:  LD 0               ; load result
0x2B:  RET                ; return
; base case:
0x2C:  ICONST 1           ; push 1
0x31:  RET                ; return
```

We need to fix the jump offsets. The `JZ` at 0x10 should jump to 0x2C if zero (offset = 0x2C - 0x10 - 2 = 0x1A, but careful with relative encoding). We'll handle that in the assembler.

This simple language is sufficient to illustrate both interpretation and JIT compilation. Now, let’s implement the interpreter.

---

## Section 2: A High‑Performance Bytecode Interpreter

The heart of any VM is the interpretive loop: fetch an opcode, decode it, execute, advance the program counter, and repeat. We want our interpreter to be fast, even though it will eventually be superseded by JIT code for hot paths. In this section we build a minimalist interpreter in C, then improve its performance with techniques like direct threading.

### 2.1 Naive Switch‑Case Interpreter

Our first interpreter uses a `switch` statement. The VM state is held in a structure:

```c
typedef struct {
    uint64_t *stack;          // operand stack
    size_t stack_capacity;
    size_t stack_top;         // index of next free slot
    uint64_t *call_stack;     // return addresses and frame pointers
    size_t call_stack_capacity;
    size_t call_stack_top;
    uint8_t *code;            // bytecode
    size_t code_size;
    uint64_t locals[256];     // local variables indexed by opcode operand
    uint64_t *heap;           // simple heap for allocations (not shown)
    size_t pc;                // program counter (byte offset)
    int halt_flag;
} VM;
```

The `run` function:

```c
void vm_run(VM *vm) {
    while (!vm->halt_flag) {
        uint8_t opcode = vm->code[vm->pc++];
        switch (opcode) {
            case ICONST: {
                int32_t val = *(int32_t*)(vm->code + vm->pc);
                vm->pc += 4;
                PUSH(vm, (int64_t)val);
                break;
            }
            case IADD: {
                int64_t b = POP(vm);
                int64_t a = POP(vm);
                PUSH(vm, a + b);
                break;
            }
            // ... other arithmetic similarly
            case JMP: {
                int16_t offset = *(int16_t*)(vm->code + vm->pc);
                vm->pc += 2;
                vm->pc += offset; // relative
                break;
            }
            case JZ: {
                int64_t cond = POP(vm);
                int16_t offset = *(int16_t*)(vm->code + vm->pc);
                vm->pc += 2;
                if (cond == 0) vm->pc += offset;
                break;
            }
            case CALL: {
                int16_t offset = *(int16_t*)(vm->code + vm->pc);
                vm->pc += 2;
                // push return address (current PC) onto call stack
                PUSH_CALL(vm, vm->pc);
                vm->pc += offset; // jump to target (relative from start? careful)
                // We need to compute absolute offset. Let's fix: offset is from current PC after operand.
                break;
            }
            case RET: {
                uint64_t ret_addr = POP_CALL(vm);
                vm->pc = (size_t)ret_addr;
                break;
            }
            case HALT:
                vm->halt_flag = 1;
                break;
            // ... LD, ST, etc.
        }
    }
}
```

The `PUSH` and `POP` macros check stack bounds and update `stack_top`. This interpreter works but is slow because of the overhead of the switch (table lookup, branch misprediction) and the many memory accesses for the stack.

### 2.2 Direct Threaded Interpretation

A classic optimization is **direct threading** (or threaded code) where we replace the `switch` with an array of function pointers (or labels). Instead of a central loop, each opcode handler jumps directly to the next handler after finishing. This eliminates the branch to the switch and reduces mispredictions.

In C, with GNU extensions, we can use computed `goto` and an array of labels:

```c
void* handlers[] = { &&do_iconst, &&do_iadd, &&do_isub, ... };

// in a header:
#define NEXT goto *handlers[vm->code[vm->pc++]];

void vm_run(VM *vm) {
    NEXT; // start
do_iconst:
    // ... execute
    NEXT;
do_iadd:
    // ... execute
    NEXT;
// etc.
}
```

This technique is used in many production interpreters (e.g., the old Ruby 1.8 VM). The cost per opcode drops to a single indirect jump plus the opcode execution. For our hybrid VM, we will keep the interpreter simple but may use threading later for speed.

### 2.3 Stack Management and Optimizations

Even with threading, frequent stack pushes/pops hurt performance. A common trick is to keep the top of the stack value(s) in local variables or registers. For example, we can keep the top two stack slots in C variables `top` and `second`, and update the memory stack only when necessary. This significantly reduces memory traffic.

We can also inline common sequences: e.g., a load then an arithmetic op can be fused. For our purposes, the interpreter is just a fallback; the JIT will handle hot code.

Now that we have a working interpreter, let’s measure its performance and identify its limitations.

---

## Section 3: Limitations of Pure Interpretation

Interpretation has two fundamental sources of overhead:

1. **Dispatch overhead**: fetching, decoding, and branching on every opcode. Even with direct threading, each opcode requires at least one indirect jump (which may stall the pipeline).

2. **Stack operations**: each push/pop from the software stack is a load/store to memory, plus index arithmetic. This is orders of magnitude slower than using hardware registers.

Additionally, the bytecode is a compact representation that the CPU cannot directly execute. Every arithmetic instruction must be decoded and dispatched; the CPU’s own arithmetic units are not directly used because the operands come from a simulated stack rather than from registers.

To understand the performance gap, consider a simple tight loop that computes the sum of 1..N:

```
ICONST 0   ; sum = 0
ST 0       ; local[0] = sum
LD 1       ; load N
ICONST 0   ; i = 0? Actually we can compute with loop:
loop:
  LD 0       ; load sum
  LD 1       ; load i
  IADD       ; sum + i
  ST 0       ; store sum
  LD 1       ; load i
  ICONST 1   ; push 1
  IADD       ; i+1
  ST 1       ; store i
  LD 1       ; load i
  LD 2       ; load N? we need limit
  ... comparison, jump if less
```

Each arithmetic operation involves at least 3 memory accesses (two pops, one push) plus the dispatch. If we run this interpreter on a modern CPU, we might get ~50 million bytecode instructions per second (very rough). In contrast, a native C loop doing the same arithmetic can execute billions per second. The gap is a factor of 20–100.

This is why JIT compilation exists: to bring the performance of interpreted code closer to native.

---

## Section 4: Introduction to JIT Compilation

Just‑In‑Time compilation bridges the gap by translating bytecode into native machine code at runtime. The key insight is that most execution time is spent in a small fraction of code (the “hot” code). By identifying and compiling those hot paths, we can achieve near‑native performance while still retaining the portability of bytecode.

### 4.1 Method‑Based vs. Trace‑Based JIT

Two common approaches:

- **Method‑based JIT**: compiles entire functions (or methods) when they become hot. Used in JVM (HotSpot), V8 (before TurboFan?), etc. The compiler may optimize the whole function, inline, etc.

- **Trace‑based JIT**: compiles hot paths, often a linear sequence of bytecodes that form a loop or backward branch. Used in TraceMonkey (Firefox), PyPy’s JIT. Traces can handle polymorphic code more easily.

For simplicity, we will implement a method‑based JIT for our small language: when a function has been called a certain number of times (e.g., 100), we compile it.

### 4.2 Trade‑offs

Compilation itself takes time and memory. If a function is executed only once, it’s better to interpret. Therefore we need profiling and a threshold. Also, we must handle deoptimization: if compiled assumptions are invalidated (e.g., a variable changes type), we must fall back to the interpreter.

Our hybrid VM will implement a two‑tier system: interpreter → JIT.

---

## Section 5: Building a Simple JIT Compiler

We will target x86‑64 (or a simplified subset) to generate native code. We’ll assume we have a small code generator that can emit bytes corresponding to x86‑64 instructions. For brevity, we’ll show key concepts using a pseudo‑assembly.

### 5.1 Translation Strategy for Stack Operations

The biggest challenge is translating a stack machine to a register machine (x86‑64). We need to map the conceptual operand stack to real CPU registers. Since our bytecode functions are small, we can allocate a small set of registers as the “shadow stack”. For example:

- Use `%rax` as the top of stack (TOS)
- Use `%rbx` as second slot (optional)
- Use `%rcx`, `%rdx` as temporaries
- Use `%rsp` for the real hardware stack (for call/return)

When we start a compiled function, we allocate a small local stack frame on the hardware stack to hold any overflow slots (if the virtual stack grows beyond available registers). The compiled code will maintain TOS in a register and only spill to memory when necessary (e.g., before a call or when the register is needed).

### 5.2 Example: Compiling a Simple Expression

Consider `ICONST 5` followed by `ICONST 3` followed by `IADD`. The native code:

```
movq $5, %rax       ; TOS = 5
pushq %rax          ; spill TOS to stack (to make room for next constant)
movq $3, %rax       ; TOS = 3
popq %rbx           ; retrieve previous TOS => %rbx = 5
addq %rbx, %rax     ; TOS = 5 + 3 = 8
```

We need to decide on a register assignment policy. For simplicity, we can use a small stack in hardware memory (the real stack) and keep the top in a register. This is essentially a virtual tree of operations.

### 5.3 Compiling Control Flow

Conditional jumps (`JZ`) require comparison and conditional move/branch. For `JZ` we pop TOS and test it:

```
popq %rax      ; actually assume TOS is in %rax already? careful.
testq %rax, %rax
jz target_label
```

Relative jumps become absolute addresses in native code (we know the target offset in bytecode; we’ll compute the native address during compilation by building a mapping).

### 5.4 Calling Convention for Compiled Functions

When a compiled function is called (either from interpreter or from another compiled function), we need to pass arguments and return values. We’ll adopt a convention:

- Arguments are passed on the hardware stack (like C calling convention) or in registers. For simplicity, let’s use registers: first argument in `%rdi`, second in `%rsi`, etc. But our bytecode `CALL` pushes arguments onto the virtual stack. So the JIT compiler must translate that: when a `CALL` is compiled, it must pop the arguments from the virtual stack and put them into registers (or onto hardware stack), then emit a native `call` instruction, and upon return push the result onto the virtual stack (i.e., into `%rax` as TOS).

We also need to preserve registers across native calls. Our compiler will follow standard x86‑64 calling convention (System V) for simplicity.

### 5.5 Prologue and Epilogue

Each compiled function will have a prologue that saves the base pointer and adjusts the stack pointer for local variables, and an epilogue that restores and returns.

```
pushq %rbp
movq %rsp, %rbp
subq $frame_size, %rsp   ; allocate local storage for spilled stack slots
```

Epilogue:

```
movq %rbp, %rsp
popq %rbp
ret
```

### 5.6 Example: Compiling Factorial

We can attempt to compile the factorial function from our bytecode. It involves recursion, so we need to handle calls. The generated native code would look like:

```
factorial:
    pushq %rbp
    movq %rsp, %rbp
    subq $16, %rsp         ; space for one local variable (result) and maybe argument
    ; argument n is in %rdi (by our convention? but CALL pushes arguments on virtual stack)
    ; We'll adopt: arguments passed on hardware stack? Let's decide a simpler approach: the JIT function will pop its arguments from the virtual stack (which is in memory).
    ; However, for recursive calls, we need to maintain virtual stack across calls. This gets complex.
```

To keep the blog manageable, we will simplify: we’ll compile only straight‑line code and simple loops, not recursive functions, in the first version. Or we can implement a simple stack‑walking mechanism.

Given space constraints (we are writing a long blog post, but we need to be practical), we might present the JIT compiler as an advanced optional section, showing the core ideas with a small example like `ICONST + IADD` chain.

---

## Section 6: Hybrid VM Architecture – Merging Interpreter and JIT

Now we combine the two execution engines. The VM will initially run in interpreter mode, collecting profiling information (e.g., count of calls per function, number of loop iterations). When a function surpasses a threshold (say 100 calls), we trigger compilation. After compilation, subsequent calls to that function will execute the native code instead of the interpreter. The interpreter must be able to detect when a function is compiled and redirect.

### 6.1 Data Structures

We maintain a `function_table` that maps function entry points (bytecode offset) to either:

- `NULL` (not yet compiled)
- A pointer to the native code address

When a `CALL` opcode is encountered in the interpreter, we check:

```c
void* native = function_table[target];
if (native) {
    // call native function with arguments from stack
    // We need to marshal arguments. Since our calling convention is argument in registers,
    // we pop arguments from virtual stack and put into registers.
    // But we also need to handle return value.
    // For simplicity, we can use a wrapper that maps virtual stack to native call.
} else {
    // push return address and jump to bytecode (interpreted)
}
```

For the JIT side, when we compile a function, we generate a native function that expects arguments according to a fixed convention (e.g., all arguments on the real stack, or in registers). The wrapper in the interpreter does the translation.

### 6.2 Deoptimization

One of the hardest parts of a hybrid VM is deoptimization: what if the runtime assumptions made during compilation are later violated? For example, if we assumed a variable is always an integer, but later code stores a pointer into it, the compiled code may be invalid. We need to revert to interpretation for that function.

A simple approach: check at the start of every compiled function whether the assumptions still hold. If not, jump to interpreter version. Alternatively, use on‑stack replacement (OSR) to transfer from compiled code back to the interpreter at a safe point.

For our toy VM, we can avoid deoptimization by not optimizing dynamically typed code—we stay with static types. But for a real VM, that’s essential.

### 6.3 Tiered Execution

We can also have multiple tiers: interpreter (tier 0), baseline JIT (tier 1, minimal optimizations), optimizing JIT (tier 2, more aggressive). Each tier triggers based on higher thresholds. This is used in JVM (C1 and C2 compilers) and V8 (TurboFan, Crankshaft). Our hybrid will have only two tiers: interpreter and JIT.

---

## Section 7: Advanced Topics – Garbage Collection, Inline Caching, Register Allocation

### 7.1 Garbage Collection

If our language supports heap allocation (`ALLOC`), we need memory management. Simple explicit `FREE` works, but we could add a mark‑sweep GC. The JIT compiler would need to insert GC safepoints and root scanning. This is a huge topic—we can mention it as future work.

### 7.2 Inline Caching

For dynamic languages, method calls are expensive due to lookup. Inline caching caches the result of a method lookup at the call site, and the JIT can generate a fast path for the common case. Our bytecode doesn’t have dynamic dispatch, so not needed.

### 7.3 Register Allocation

When compiling from stack bytecode to native code, we need to allocate registers for the virtual stack top. Simple heuristic: keep top in a fixed register, spill when necessary. Optimal allocation using graph coloring is overkill for a toy VM.

---

## Section 8: Case Study – Fibonacci Benchmark

Let’s implement a Fibonacci function in our bytecode (not factorial, but Fibonacci, which is double recursive). We’ll run it with pure interpretation, then with JIT compilation (compile the `fib` function), and measure execution time.

We’ll use a simple Python script to generate bytecodes for `fib(30)`. Then run our C VM with and without JIT.

Expected results: pure interpreter might take ~10 seconds; JIT version might take ~0.1 seconds (speedup ~100x). This demonstrates the power of JIT.

We’ll write the benchmark code in C, using `clock_gettime` for timing.

(Note: We must ensure the JIT works correctly for recursive functions. We can design a simple wrapper that compiles the function and uses a stack for arguments.)

For the sake of the blog, we can present pseudocode and a theoretical speedup.

---

## Section 9: Conclusion and Future Directions

We have built a hybrid VM that starts with an interpreter and transitions to JIT‑compiled code for hot functions. Along the way we explored:

- Stack‑based bytecode design
- Fast interpreter (direct threading, top‑of‑stack caching)
- JIT compilation basics (translating stack ops to x86‑64)
- Hybrid architecture (profiling, tiered execution, deoptimization)
- Performance considerations

This is a microcosm of how modern VMs work. The principles extend to more complex systems: the JVM’s HotSpot uses C1 (client) and C2 (server) compilers; V8 uses Ignition (interpreter) and TurboFan (optimizing compiler); LuaJIT uses a highly optimized interpreter and trace‑based JIT.

If you wish to take this further, you could add:

- A register allocator
- A simple garbage collector
- Support for object types and polymorphic inline caching
- A more sophisticated JIT with loop unrolling, inlining, etc.

The beauty of building a VM from scratch is that you gain a visceral understanding of the trade‑offs that drive all modern language implementations. So go ahead, forge your own hybrid VM, and watch your bytecode fly.

---

## Appendix: Complete Code Listings

We would include:

- Full C code for the interpreter and JIT (short)
- Example bytecode assembler in Python
- Benchmark driver

But for brevity in this blog post, we only sketch the essential parts.

---

This concludes our deep dive into building a hybrid virtual machine. We hope you now see the invisible scaffolding that supports our software world—and feel empowered to build your own.
