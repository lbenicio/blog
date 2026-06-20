---
title: "Building A Simple Virtual Machine: Bytecode Compilation And Execution (like A Minimal Jvm)"
description: "A comprehensive technical exploration of building a simple virtual machine: bytecode compilation and execution (like a minimal jvm), covering key concepts, practical implementations, and real-world applications."
date: "2025-11-22"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Building-A-Simple-Virtual-Machine-Bytecode-Compilation-And-Execution-(like-A-Minimal-Jvm).png"
coverAlt: "Technical visualization representing building a simple virtual machine: bytecode compilation and execution (like a minimal jvm)"
---

There is a peculiar magic that happens when you press the “Run” button. In that fleeting instant, a cascade of invisible transformations occurs—from the raw text of a programming language to the electrical whispers that rearrange silicon and memory. For most of us, this process is a black box. We accept its output with the same casual faith we grant to a light switch: we know it works, but the miracle of the electron’s journey through the copper wire is lost to the mundane.

But for someone who works with data, with systems, with the brittle architecture of logic, this ignorance is a weakness. To truly master computation is to understand the layers. The highest priest of this abstraction is the Virtual Machine (VM). You have almost certainly used one today. If you read this on a phone running Android (ART/Dalvik), or interacted with a web server running Java (the JVM), or even parsed a JSON object in JavaScript (V8, SpiderMonkey), you were in the presence of a VM. It is the invisible operating system beneath your operating system.

This is not a post about Docker or VMware. We are not here to discuss hardware virtualization for server consolidation. We are talking about the _Process Virtual Machine_—the runtime environment that treats your high-level code as a foreign language it must interpret into the harsh, unforgiving dialect of CPU instructions. Specifically, we are going to build one from scratch. We are going to walk the path of the JVM.

### The Seduction of the "Write Once" Fantasy

Why should you care? Why should a developer or engineer spend time building a piece of infrastructure that exists only to run other things?

The first reason is portability. The Java Virtual Machine was a revolutionary bet: that you could compile code not for an Intel x86 chip or an ARM processor, but for a purely abstract machine. The JVM promised that the same binary—the same blob of bytes—would run on a Windows server, a Linux mainframe, or a tiny embedded system. This was, and still is, a profound abstraction. It decouples the developer’s intent from the hardware’s tyranny. You write high-level code like Java or Kotlin, compile it to Java bytecode (a file with the `.class` extension), and that bytecode is then interpreted or just-in-time compiled by the JVM on any platform that has a JVM implementation. The portability is not free; it costs performance, but for many business applications, the trade-off is trivial. The JVM’s success spawned a family of languages: Scala, Groovy, Clojure, even Python (via Jython) and Ruby (via JRuby). They all compile down to the same common intermediate representation. The VM becomes a lingua franca, a universal substrate where languages can meet and interoperate.

But portability is only one layer of the seduction. The second reason is **security**. The JVM introduced the concept of a “sandbox” — a managed environment that prevents malicious code from corrupting the host system. When you download a Java applet (remember those?), it runs inside a restricted world: it can’t read your files, cannot access your network ports without permission, and its memory is separated from the operating system’s. This sandboxing is enforced by the bytecode verifier, a static analysis tool that checks the code before it ever executes. The verifier ensures that types are used correctly, that registers are initialized, and that stack operations are balanced. It is the bouncer at the door of the nightclub: no sharp objects allowed. Modern VMs like the JVM and .NET’s CLR have evolved these security mechanisms into sophisticated code access security models, but the core idea remains: the VM is a trusted intermediary between untrusted code and the machine.

A third reason, often overlooked, is **runtime optimization**. A VM can observe how your program behaves in real time and adapt. The JVM’s HotSpot engine is a prime example: it starts execution with an interpreter (slow but low latency), but identifies “hot spots” — code paths that are executed frequently. It then compiles those paths into native machine code, and if needed, recompiles with even more aggressive optimizations based on profiling data. This process, called adaptive optimization, can make dynamically typed languages (like JavaScript in V8) approach or even exceed the performance of statically compiled languages in certain workloads. A static native compiler has to make worst-case assumptions; a JIT compiler can make exact assumptions because it has seen the actual data flow. The VM becomes a living, learning entity that grows with the program.

### What Exactly Is a Process Virtual Machine?

Before we dive into construction, we must clarify our terminology. In computer science, “virtual machine” is an overloaded term. There are two broad categories: **System Virtual Machines** (like VMware, VirtualBox, or QEMU) that simulate an entire hardware platform—CPU, memory, I/O devices—and allow you to run a full operating system on top of another OS. These are used for server consolidation, disaster recovery, and running legacy systems. Then there are **Process Virtual Machines**, sometimes called application virtual machines or runtime environments. They provide an abstraction of a _single_ process. The JVM, the .NET Common Language Runtime (CLR), the Python interpreter (CPython), and the JavaScript engines (V8, SpiderMonkey, JavaScriptCore) are all process VMs. They do not simulate a whole computer; instead, they standardize an execution environment on top of an existing OS and CPU. They manage memory, call native libraries, handle threading, and enforce language semantics.

In a process VM, the “machine” is defined by:

- An **instruction set architecture** (the bytecode instructions).
- A **memory model** (how variables, objects, and stacks are laid out).
- A **calling convention** (how functions pass arguments and return values).
- A **runtime system** (garbage collector, exception handler, threading scheduler).

Your high-level code is compiled into bytecode, which is a sequence of simple, compact instructions. These instructions are then either interpreted by the VM’s core loop, or compiled to native code using a JIT. The beauty of this two-stage compilation (source → bytecode → native) is that the bytecode can be validated once and then executed anywhere the VM runs. The bytecode format is the “executable” of the virtual world.

### Why Build Your Own VM?

You might be thinking: “I could just study the JVM spec or pirouette through the V8 source code. Why build one?” Building something from scratch is the difference between reading a map and walking the terrain. By constructing a minimal process VM, you will:

1. **Deeply understand stack machines**: Most process VMs (JVM, CLR, CPython) are stack-based. You’ll learn how push, pop, and arithmetic operations flow through an operand stack.
2. **Demystify bytecode**: You will see that a `LOAD_FAST` and `BINARY_ADD` are just numbers. The magic is in the orchestration.
3. **Grasp memory management**: Implementing a simple garbage collector—even a naive mark-sweep—will teach you that memory is not infinite, and that the VM must orchestrate the lifecycle of objects.
4. **Appreciate the interpreter vs. compiler trade-off**: You can start with a simple while-switch loop and later add a JIT compiler skeleton. You will feel the performance pain.
5. **Talk to your computer**: When you write a small program in your own VM’s bytecode and see it print “Hello, World,” you know you’ve created a new layer of reality. It is addicting.

We will build a VM in this spirit. We’ll call it **NOVA** (Naive Optimized Virtual Architecture), and it will be written in Python for clarity, though the concepts translate directly to C or Rust. Our VM will be stack-based, with a fixed-size local variable array, a program counter, and a simple heap for objects. We will implement a small instruction set that can handle arithmetic, branching, function calls, and object creation. Then we will write a simple compiler from a minimal language called **MIL** (Mini Intermediate Language) to our bytecode.

### Core Concepts: Stack vs. Register Machines

All process VMs fit into two camps based on how they handle temporary values and arithmetic results.

**Stack machines** (JVM, CPython, Forth) use a last-in-first-out (LIFO) stack for operands. To add two numbers, you push both onto the stack, then execute an `add` instruction that pops two values, adds them, and pushes the result. The instructions are small (often one byte) because the operands are implicit. The JVM’s `iadd` instruction is just 0x60; it requires no explicit register numbers. Stack machines are easy to implement (you just need a stack array and a pointer) and produce compact bytecode. However, they often require more instructions than a register machine for complex expressions because you have to juggle stack slots.

**Register machines** (Dalvik, Lua 5.0+, ART) use virtual registers—named slots that the bytecode explicitly references. For example, to add two numbers, you might write `add v0, v1, v2` meaning “add register v1 and v2, store result in v0”. The bytecode is larger (each instruction includes register indices), but the number of instructions required for a given expression is lower, and register allocation can be optimized by the bytecode compiler. Modern mobile VMs (ART on Android) prefer register-based bytecodes because they reduce interpreter overhead and make JIT compilation more straightforward.

Our NOVA VM will be stack-based because it is conceptually simpler. But we will note where a register design would differ.

### Designing a Minimal VM: Specification

Let’s now design our VM. We will start with a concrete specification: the bytecode format, the instruction set, the memory architecture, and the execution model. This is the “contract” that our compiler and our runtime must both obey.

**Bytecode Format**: Our bytecode will be a sequence of 32-bit words (or we could use variable-length encoding, but we keep it simple). Each instruction is one word, possibly followed by payload words for immediates or addresses. We’ll define a magic number at the beginning of the stream to verify it’s a valid NOVA program, followed by the entry point address (the offset of the first instruction to execute), then the bytecode body.

**Memory Architecture**: NOVA will have:

- A **code segment**: read-only array of instructions (our bytecode).
- A **local variable array**: an array of 256 slots (we’ll index them with 8-bit indices). Each slot can hold an integer (32-bit signed) or a reference (address in heap). This simulates function local variables. For simplicity, we won’t implement a call stack yet; we will have a single static local frame.
- An **operand stack**: a LIFO stack of value words (integers or references). Depth limited to, say, 1024.
- A **program counter** (PC): index into the bytecode array.
- A **heap**: an array of objects. Each object is a simple tuple of (type_tag, fields). We’ll implement a minimal mark-sweep garbage collector.

**Instruction Set**: We need a minimal set to be Turing complete. Our opcodes will be one byte, followed optionally by payload bytes. In our 32-bit encoding, we can pack opcode and operands into one word: byte0 = opcode, bytes1-3 = payload (or first operand, and another word for second operand). For clarity, I will describe them as separate.

Define the following opcodes (we’ll assign numeric values later):

- `NOP` – do nothing.
- `ICONST` – push a constant integer onto the stack. (payload = constant).
- `ILOAD` – push local variable onto stack (payload = variable index).
- `ISTORE` – pop stack, store to local variable (payload = index).
- `IADD` – pop two ints, push sum.
- `ISUB` – pop two ints, push diff.
- `IMUL` – pop two ints, push product.
- `IDIV` – pop two ints, push quotient.
- `INEG` – pop one int, push negation.
- `ICMP` – pop two ints, compare: push -1 if first < second, 0 if equal, 1 if first > second.
- `JMP` – unconditional jump (payload = address offset relative or absolute).
- `JZ` – pop int, if zero jump to address.
- `JNZ` – pop int, if non-zero jump.
- `HALT` – stop execution.
- `PRINT` – pop top of stack and output as integer.
- `NEW` – allocate a new object on heap (payload = number of fields). Returns reference.
- `GETFIELD` – pop object reference and field index, push value.
- `SETFIELD` – pop object reference, field index, value, set field.
- `CALL` – call a function (placeholder for future: transfer control to a function body, push return address).
- `RET` – return from function.

We can add more later (float operations, string handling, etc.). The key is that we can express any computation with these.

**Execution Model**: The VM runs in a loop: fetch instruction at PC, decode opcode and payload, execute (manipulate stack and locals), increment PC appropriately (or set it to jump target). This is the classic “fetch-decode-execute” cycle of any CPU.

### Implementing the VM in Python

Let’s translate our specification into Python code. We will write a class `NovaVM` that loads a bytecode array (a list of integers) and runs the execution loop.

We’ll start with a stub:

```python
class NovaVM:
    def __init__(self, bytecode):
        self.bytecode = bytecode
        self.pc = 0
        self.stack = []
        self.locals = [0] * 256  # local variables
        self.heap = []  # list of objects; we'll manage allocation

        # opcode constants
        self.NOP = 0
        self.ICONST = 1
        self.ILOAD = 2
        self.ISTORE = 3
        self.IADD = 4
        self.ISUB = 5
        self.IMUL = 6
        self.IDIV = 7
        self.INEG = 8
        self.ICMP = 9
        self.JMP = 10
        self.JZ = 11
        self.JNZ = 12
        self.HALT = 13
        self.PRINT = 14
        self.NEW = 15
        self.GETFIELD = 16
        self.SETFIELD = 17
        self.CALL = 18
        self.RET = 19

    def run(self):
        while True:
            inst = self.bytecode[self.pc]
            opcode = (inst >> 24) & 0xFF  # first byte
            payload = inst & 0xFFFFFF     # lower 3 bytes (for immediate values)
            self.pc += 1

            if opcode == self.NOP:
                pass
            elif opcode == self.ICONST:
                # push the payload as an integer (signed interpretation)
                # We need to treat payload as signed 24-bit:
                if payload & 0x800000:
                    payload = -0x1000000 + payload
                self.stack.append(payload)
            elif opcode == self.ILOAD:
                index = payload & 0xFF  # only low byte
                self.stack.append(self.locals[index])
            elif opcode == self.ISTORE:
                index = payload & 0xFF
                self.locals[index] = self.stack.pop()
            elif opcode == self.IADD:
                b = self.stack.pop()
                a = self.stack.pop()
                self.stack.append(a + b)
            elif opcode == self.ISUB:
                b = self.stack.pop()
                a = self.stack.pop()
                self.stack.append(a - b)
            elif opcode == self.IMUL:
                b = self.stack.pop()
                a = self.stack.pop()
                self.stack.append(a * b)
            elif opcode == self.IDIV:
                b = self.stack.pop()
                a = self.stack.pop()
                self.stack.append(a // b)  # integer division
            elif opcode == self.INEG:
                a = self.stack.pop()
                self.stack.append(-a)
            elif opcode == self.ICMP:
                b = self.stack.pop()
                a = self.stack.pop()
                if a < b:
                    self.stack.append(-1)
                elif a == b:
                    self.stack.append(0)
                else:
                    self.stack.append(1)
            elif opcode == self.JMP:
                offset = payload & 0xFFFFFF
                # we treat payload as signed
                if offset & 0x800000:
                    offset = -0x1000000 + offset
                self.pc += offset - 1  # because we already incremented by 1
            elif opcode == self.JZ:
                offset = payload & 0xFFFFFF
                if offset & 0x800000:
                    offset = -0x1000000 + offset
                val = self.stack.pop()
                if val == 0:
                    self.pc += offset - 1
            elif opcode == self.JNZ:
                offset = payload & 0xFFFFFF
                if offset & 0x800000:
                    offset = -0x1000000 + offset
                val = self.stack.pop()
                if val != 0:
                    self.pc += offset - 1
            elif opcode == self.HALT:
                break
            elif opcode == self.PRINT:
                val = self.stack.pop()
                print(val)
            elif opcode == self.NEW:
                num_fields = payload & 0xFF
                obj = [0] * num_fields  # all fields initialized to 0
                self.heap.append(obj)
                self.stack.append(len(self.heap) - 1)  # reference = index in heap
            elif opcode == self.GETFIELD:
                field_idx = self.stack.pop()
                obj_ref = self.stack.pop()
                obj = self.heap[obj_ref]
                self.stack.append(obj[field_idx])
            elif opcode == self.SETFIELD:
                val = self.stack.pop()
                field_idx = self.stack.pop()
                obj_ref = self.stack.pop()
                obj = self.heap[obj_ref]
                obj[field_idx] = val
            elif opcode == self.CALL:
                # We'll implement a simple function call later
                pass
            elif opcode == self.RET:
                # Placeholder
                pass
            else:
                raise RuntimeError(f"Unknown opcode {opcode} at PC {self.pc-1}")
```

Note: The encoding is simplistic; we treat payload as a 24-bit signed number. For instructions that need two operands (like JMP), we pack the offset into the lower 24 bits. For `ILOAD` and `ISTORE`, we only use the low byte for variable index. This works for demonstration but is not type-safe.

Now we need a way to assemble bytecode from textual assembly or compile from high-level code. Let’s first write a simple assembler – a function that takes a list of symbolic instructions and produces the bytecode list.

```python
def assemble(instructions):
    # instructions is a list of (opcode, payload) tuples.
    bytecode = []
    for op, payload in instructions:
        # pack opcode (top 8 bits) and payload (lower 24 bits)
        bytecode.append((op << 24) | (payload & 0xFFFFFF))
    return bytecode
```

But we need to resolve labels for jumps. We’ll write a more complete assembler later. For now, let’s test with a simple program that computes factorial of 5 and prints it.

**Factorial program in our assembly**:
We need to set local variable 0 to 5, local 1 to 1 (accumulator), then loop: multiply accumulator by variable 0, decrement variable 0, loop until variable 0 is zero. Print accumulator.

Assembly pseudo-code:

- ICONST 5
- ISTORE 0
- ICONST 1
- ISTORE 1
- loop: ILOAD 0
- JZ end
- ILOAD 1
- ILOAD 0
- IMUL
- ISTORE 1
- ILOAD 0
- ICONST 1
- ISUB
- ISTORE 0
- JMP loop
- end: ILOAD 1
- PRINT
- HALT

We need to compute addresses in the bytecode for jumps. We’ll write a minimal assembler that collects label positions.

Implement a simple assembler:

```python
def assemble_with_labels(lines):
    # lines: list of strings, each is "OPCODE [payload] [label:]"
    # We'll parse manually.
    bytecode = []
    labels = {}
    # first pass: find label positions
    pos = 0
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if ':' in line:
            label, rest = line.split(':', 1)
            labels[label] = pos
            line = rest.strip()
            if not line:
                continue
        if ' ' in line:
            op, payload_str = line.split(' ', 1)
        else:
            op = line
            payload_str = None
        # We'll skip generating opcode now; just count words
        # Determine instruction size: all our ops are 1 word currently.
        pos += 1
    # second pass: generate bytecode
    bytecode = []
    pos = 0
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if ':' in line:
            label, rest = line.split(':', 1)
            line = rest.strip()
            if not line:
                continue
        if ' ' in line:
            op, payload_str = line.split(' ', 1)
        else:
            op = line
            payload_str = None
        opcode = op_to_code(op)  # define mapping
        if payload_str:
            # could be number or label
            if payload_str in labels:
                payload = labels[payload_str]  # absolute address? we want relative offset?
                # For simplicity, we'll support absolute addresses for JMP/JZ/JNZ
                payload = payload - (pos + 1)  # relative offset from next instruction
            else:
                payload = int(payload_str)
        else:
            payload = 0
        bytecode.append((opcode << 24) | (payload & 0xFFFFFF))
        pos += 1
    return bytecode
```

We need the `op_to_code` mapping. Then run:

```python
program_lines = [
    "ICONST 5",
    "ISTORE 0",
    "ICONST 1",
    "ISTORE 1",
    "loop: ILOAD 0",
    "JZ end",
    "ILOAD 1",
    "ILOAD 0",
    "IMUL",
    "ISTORE 1",
    "ILOAD 0",
    "ICONST 1",
    "ISUB",
    "ISTORE 0",
    "JMP loop",
    "end: ILOAD 1",
    "PRINT",
    "HALT"
]
bytecode = assemble_with_labels(program_lines)
vm = NovaVM(bytecode)
vm.run()
# Should print 120
```

Great! We have a working VM. But this is just the beginning.

### Compiling High-Level Code to Bytecode

Building a VM is satisfying, but to truly complete the story we need a compiler that translates a readable language into our bytecode. Let’s design a simple language called MIL (Mini Intermediate Language) that supports integer variables, arithmetic, conditionals, loops, and functions.

MIL grammar (simplified):

```
program = statement*
statement = assignment | if_statement | while_statement | print_statement | func_def | call_expr
assignment: "let" identifier "=" expression ";"
if_statement: "if" "(" expression ")" block ["else" block]
while_statement: "while" "(" expression ")" block
print_statement: "print" expression ";"
block: "{" statement* "}"
expression: literal | identifier | binary_op | unary_op | call_expr
binary_op: expression ("+"|"-"|"*"|"/"|"<"|">"|"=="|"!=") expression
unary_op: "-" expression
literal: integer
call_expr: identifier "(" expression* ")"
func_def: "func" identifier "(" parameters ")" block
parameters: identifier ("," identifier)*
```

We need to translate MIL into our NOVA bytecode. The compiler will maintain a symbol table for variables (assigning them to local slots), emit code for expressions, and handle control flow.

Let’s sketch a recursive descent compiler. We’ll keep it simple – no advanced optimization.

**Variable allocation**: each variable gets a local slot number. For simplicity, we allocate sequentially from slot 0. Functions will have their own scope but we ignore function calls for now.

**Expression code generation**: For an expression like `a + b * c`, we generate code that pushes a, then b, then c, then `IMUL`, then `IADD`. This is standard stack-based compilation.

**Control flow**: `if (cond) { ... } else { ... }` translates to: evaluate cond, JZ else_label, then code for true branch, JMP end_label, else_label: code for false branch, end_label: continue.

**While loop**: evaluate cond, JZ end_label, execute body, JMP cond_check (or loop start). So we need two labels.

Let's implement a simple compiler class `MILCompiler`.

```python
class MILCompiler:
    def __init__(self):
        self.symbols = {}
        self.next_local = 0
        self.labels = {}
        self.label_counter = 0
        self.bytecode = []
    def new_label(self):
        name = f"L{self.label_counter}"
        self.label_counter += 1
        return name
    def emit(self, opcode, payload=0):
        self.bytecode.append((opcode << 24) | (payload & 0xFFFFFF))
    def resolve_label(self, label):
        # we need to backpatch: store current index and later fix offset
        # For simplicity, we'll use absolute addressing with forward reference
        # This requires two-pass. We'll skip details for brevity.
        pass
```

We'll not write the full compiler here due to space; but the idea is there. After building the compiler, we can write MIL programs, compile to bytecode, and run on NOVA.

### Adding Complexity: Functions and Call Stack

Our VM currently has a single set of local variables and no call stack. To support functions, we need a **call frame** system. Each function call pushes a new frame containing: return address (PC after call), saved local variables (or a new locals array), and possibly an operand stack pointer (to isolate stacks). For simplicity, we can implement a separate call stack that holds frames. Each frame has its own local array (we can reuse a global array but save/restore, or allocate new list). We'll introduce new instructions: `CALL` (with function index or address) and `RET`.

We need to modify our VM to handle multiple frames. We'll store frames on a separate Python list `call_stack`. Each frame is an object with `locals`, `pc` (return address). When `CALL` is executed, we push current frame (with locals copy), set new locals (maybe copy arguments from stack), and set PC to function address. On `RET`, we pop frame, restore locals and PC.

This complicates the VM but is essential for any real language.

Even more sophisticated: we could add object-oriented features, arrays, and garbage collection. Let's discuss garbage collection briefly.

### Garbage Collection: Mark and Sweep

As we allocate objects with `NEW`, the heap fills up. We need to reclaim objects that are no longer reachable from the stack or locals. The simplest GC is **mark-sweep**. We'll add a `GC` instruction (or trigger it automatically when heap is full). The algorithm:

1. **Mark phase**: starting from all references in the operand stack and local variables (and any global/static roots), traverse object graph. Set a mark bit on each visited object.
2. **Sweep phase**: iterate over heap, any object not marked is freed (its slot can be reused). Unmark all marked objects for next GC.
   Since our heap is a Python list, we cannot truly free memory; we can mark slots as free and reuse them for new allocations. We'll maintain a free list.

Implementing a mark-sweep collector in our VM is a good exercise. We'll need to store a reference bit in each object (e.g., `obj[0] = mark_flag` or a separate array). We'll also need to know for each object the set of references it contains: either we require a type tag (like object vs integer) per field, or we treat all fields as references and the GC scans them. For simplicity, we can treat every word as a potential reference; but we must be careful not to treat integers as references. A common approach is to use a **tagged pointer** scheme: the least significant bit of a value indicates whether it's an integer (LSB=1) or a reference (LSB=0). Or we can keep type information in a separate table. We'll skip the full implementation but note that real VMs invest serious effort in GC (generational, concurrent, etc.).

### Advanced Topic: Just-in-Time Compilation

Our VM is purely interpretive; each instruction is decoded and executed in a while loop. This is slow. A JIT compiler could translate repeated hot loops into native machine code (x86 or ARM tiny instructions). The simplest JIT is to replace a group of bytecode instructions with a small block of native code that does the same work, then jump to native execution. Implementing a JIT is beyond the scope of this post, but understanding the interpreter is the first step.

### Conclusion: Seeing Through the Layers

We started with the magic of the “Run” button and descended through layers of abstraction until we built our own runtime. We learned that a process virtual machine is not a physical replica of a computer, but a conceptual contract: a set of rules about memory, instructions, and control. The NOVA VM we built is minimal, but its architecture mirrors the JVM, V8, and CPython at a fundamental level.

By constructing this VM, you have taken a step toward mastering the layers. Next time you press “Run,” you can imagine the bytecode being fetched, the stack growing and shrinking, the GC marking roots, the JIT compiling hot spots. You are no longer a user of the black box—you are its architect.

The beauty of computing is that you can always peel back another layer. The virtual machine runs on a host operating system, which runs on a hypervisor (if containerized), which runs on hardware microcode, which implements an ISA in silicon. At each level, there is a similar loop: fetch, decode, execute. The VM is just a loop that interprets a foreign dialect. And now you know how to write that loop.

This is the power of building from scratch. The electron’s journey may still be a miracle, but the layers in between are now your own creation. Happy coding.
