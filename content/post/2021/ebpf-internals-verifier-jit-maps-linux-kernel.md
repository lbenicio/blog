---
title: "eBPF Internals: The In-Kernel Verifier, Safety Proofs, JIT Compilation to Native Code, Map Types, and XDP/TC Hooks"
description: "A deep exploration of eBPF internals — how the Linux kernel verifier proves safety, the JIT compilers that turn BPF bytecode into native instructions, the map infrastructure that enables stateful processing, and the XDP/TC hooks that make programmable networking possible."
date: "2021-05-08"
author: "Leonardo Benicio"
tags: ["ebpf", "linux", "kernel", "verifier", "jit", "xdp", "networking"]
categories: ["systems", "linux-kernel"]
draft: false
cover: "/static/assets/images/blog/ebpf-internals-verifier-jit-maps-linux-kernel.png"
coverAlt: "A stylized diagram showing eBPF bytecode flowing through the in-kernel verifier and JIT compiler into native code, with BPF maps providing state persistence"
---

In 2014, Alexei Starovoitov and Daniel Borkmann merged a patch set into Linux 3.18 that would transform the kernel more profoundly than any single feature since the introduction of loadable kernel modules. Extended Berkeley Packet Filter (eBPF) began as a modest extension to the classic BPF bytecode used for network packet filtering (think tcpdump). But its design — a verifiable, sandboxed bytecode that the kernel could safely execute in response to events — proved to be a universal mechanism for extending kernel functionality without changing kernel code. Today, eBPF powers networking (Cilium replaces kube-proxy), observability (Pixie, Parca), security (Falco, Tracee), and even kernel scheduling (BPF scheduler in Linux 6.x). This post dissects how eBPF works inside the Linux kernel.

## 1. The eBPF Architecture: A Virtual Machine Inside the Kernel

eBPF is an in-kernel virtual machine that executes user-provided bytecode in response to kernel events. The architecture has three key components:

1. **The verifier**: A static analyzer that proves the bytecode is safe before the kernel executes it. The verifier checks that the program terminates (no infinite loops), that all memory accesses are within bounds, that types are used consistently, and that the program doesn't leak kernel information.

2. **The JIT compiler**: A just-in-time compiler that translates verified bytecode into native machine code (x86-64, ARM64, etc.) for efficient execution. eBPF also has an interpreter for platforms without a JIT.

3. **Maps**: In-kernel key-value stores that eBPF programs use to maintain state across invocations. Maps are the only way for eBPF programs to persist data (there's no heap, no global variables in classic BPF), and they can be accessed from user space, enabling communication between eBPF programs and user-space management daemons.

The eBPF bytecode is a 64-bit RISC-like instruction set with eleven 64-bit registers (R0-R10, where R10 is the frame pointer and R0 is the return value), a 512-byte stack, and a set of "helper functions" provided by the kernel that eBPF programs can call. The instruction set includes arithmetic (add, sub, mul, div), bitwise operations (and, or, xor, lsh, rsh), load/store (1, 2, 4, 8 bytes), branches (conditional and unconditional), and function calls (both to helpers and, in newer kernels, to other BPF functions — BPF-to-BPF calls).

## 2. The Verifier: Proving Safety Before Execution

The verifier is the cornerstone of eBPF's safety model. Before any bytecode runs in the kernel, the verifier must prove that it is safe — that it cannot crash the kernel, corrupt memory, access out-of-bounds data, or loop indefinitely. The verifier performs several passes:

**Pass 1: Control flow graph construction**. The verifier decodes the bytecode and builds a control flow graph (CFG). It identifies basic blocks (sequences of instructions with no branches), determines the edges between blocks (branch targets), and checks that the CFG is a directed acyclic graph (DAG) — no back-edges, no loops. This ensures the program terminates (all paths through the program eventually reach the exit instruction).

**Pass 2: Depth-first search and path pruning**. The verifier walks all possible paths through the CFG, maintaining symbolic state at each program point. The state includes the type and value range of each register (R0-R10), the contents of the stack, and the "liveness" of each value. For conditional branches, the verifier splits the state: the taken path gets one set of constraints, the fall-through path gets the complementary set. This is essentially abstract interpretation — the verifier executes the program symbolically with a value-range abstract domain.

**Pass 3: Bounds checking**. For every memory access (load or store), the verifier checks that the access is within bounds. For context access (accessing the packet data or the event structure), the verifier tracks the minimum and maximum offsets of each pointer and ensures they stay within the valid range. For map access, the verifier ensures the key/value sizes match the map's definition.

**Pass 4: Type checking**. The verifier tracks the type of each register: PTR_TO_CTX (pointer to context), PTR_TO_MAP_KEY (pointer to a map key), PTR_TO_MAP_VALUE (pointer to a map value), PTR_TO_STACK (pointer to stack), SCALAR_VALUE (a number). Operations that mix types incorrectly (e.g., arithmetic on a PTR_TO_CTX) are rejected. This prevents pointer forgery — the attacker cannot turn a scalar into a pointer through arithmetic.

**Pass 5: Helper function validation**. For each call to a helper function, the verifier checks that the arguments have the correct types and that the return type is handled correctly. Some helpers have special semantics (e.g., `bpf_map_lookup_elem` returns a PTR_TO_MAP_VALUE if the lookup succeeds, or NULL if it fails), and the verifier models these semantics.

The verifier is conservative. It rejects programs that it cannot prove safe, even if they would be safe in practice. This includes programs with loops (unless bounded and with certain constraints), programs with complex pointer arithmetic, and programs that exceed the complexity limit (currently 1 million instructions processed by the verifier). The verifier's conservatism has been a source of friction for developers, but it's essential for the kernel's safety guarantee: no eBPF program that passes the verifier can crash the kernel.

## 3. The JIT Compiler: From Bytecode to Native Code

Once the verifier approves a program, it can be JIT-compiled to native code for execution efficiency. The eBPF JIT compilers (one per architecture: x86-64, ARM64, RISC-V, s390x, etc.) translate eBPF instructions to native instructions in a straightforward manner.

The translation is direct: each eBPF instruction maps to one or a few native instructions. For example, the eBPF instruction `BPF_ALU64_REG(BPF_ADD, R1, R2)` (add the values in R1 and R2, store in R1) translates to `add r1, r2` on x86-64. The JIT doesn't perform optimizations beyond peephole optimization — the verifier has already ensured correctness, and the JIT's job is fast translation.

The JIT performs register mapping: eBPF registers (R0-R10) are mapped to physical registers (on x86-64: R9 for the context pointer, R8 for R0, RBX for R6, RDI for R1, RSI for R2, RDX for R3, RCX for R4, R8 for R5, etc.). The mapping is chosen to be compatible with the x86-64 calling convention, so that calls to helper functions (which are regular C functions) don't require register shuffling.

The JIT also handles the prologue and epilogue. The prologue saves callee-saved registers, allocates stack space for the BPF stack (512 bytes), and initializes the frame pointer. The epilogue restores registers and returns. The entire JIT sequence — from BPF bytecode to executable native code — is emitted as a single contiguous block of native instructions, which the kernel marks as read-execute and invokes as a function call.

Benchmarks show that JIT-compiled eBPF is 3-5x faster than interpreted eBPF for typical programs (network policy enforcement, syscall filtering). The JIT overhead is a one-time cost at program load time; execution speed is comparable to natively compiled kernel code.

## 4. eBPF JIT Internals: x86-64 Native Code Generation Walkthrough

The JIT compiler is where eBPF's performance advantage materializes. Let's trace through the translation of several representative eBPF instructions to x86-64 native code, using the Linux kernel's actual JIT implementation (`arch/x86/net/bpf_jit_comp.c`) as our reference.

### Register Mapping and Calling Convention

The first design decision in any JIT is register allocation. The x86-64 JIT maps eBPF registers to hardware registers as follows (modulo variations across kernel versions):

```
eBPF R0  -> RAX  (return value / function result)
eBPF R1  -> RDI  (first argument / context pointer)
eBPF R2  -> RSI  (second argument)
eBPF R3  -> RDX  (third argument)
eBPF R4  -> RCX  (fourth argument)
eBPF R5  -> R8   (fifth argument)
eBPF R6  -> RBX  (callee-saved, general purpose)
eBPF R7  -> R13  (callee-saved, general purpose)
eBPF R8  -> R14  (callee-saved, general purpose)
eBPF R9  -> R15  (callee-saved, general purpose)
eBPF R10 -> RBP  (frame pointer / stack pointer)
```

This mapping is not arbitrary — it's carefully aligned with the System V AMD64 ABI calling convention. Registers RDI, RSI, RDX, RCX, R8, and R9 are argument registers in the ABI, so mapping eBPF R1-R5 to them means calls to helper functions (which are regular C functions) require zero register shuffling for the first five arguments. Registers RBX, R13, R14, R15, and RBP are callee-saved, so the JIT's prologue must save them, but the BPF program can use them freely without worrying about clobbering across helper calls.

### Arithmetic and Logic Translation

Simple ALU operations translate one-to-one. Consider the eBPF instruction:

```
BPF_ALU64_REG(BPF_ADD, BPF_REG_1, BPF_REG_2)  ; R1 += R2
```

The JIT emits:

```asm
add    rdi, rsi       ; RDI (R1) += RSI (R2)
```

A 32-bit operation like `BPF_ALU_REG(BPF_ADD, BPF_REG_1, BPF_REG_2)` becomes:

```asm
add    edi, esi       ; 32-bit add, zero-extends to 64 bits
```

The zero-extension semantics match eBPF's requirement that 32-bit ALU operations zero the upper 32 bits of the destination register.

For immediate operations, the JIT encodes the constant directly:

```
eBPF: BPF_ALU64_IMM(BPF_ADD, BPF_REG_1, 42)    ; R1 += 42
x86:  add    rdi, 42
```

### Memory Access: Loads and Stores

Memory operations are more complex because they involve bounds checking. However, the verifier has already proven bounds safety, so the JIT can emit unchecked memory accesses — the bounds check is unnecessary at runtime. An eBPF load:

```
eBPF: BPF_LDX_MEM(BPF_DW, BPF_REG_3, BPF_REG_1, 8)  ; R3 = *(u64 *)(R1 + 8)
x86:  mov    rdx, [rdi + 8]    ; RDX (R3) = load from RDI+8
```

The JIT uses the native addressing mode `[base + displacement]` to encode the offset directly in the instruction. For larger offsets that don't fit in the displacement field (32-bit signed), the JIT uses a two-instruction sequence:

```asm
mov    rax, 0x100000000      ; large offset (encoded as immediate)
add    rax, rdi              ; RAX = base + large_offset
mov    rdx, [rax]            ; RDX = load from computed address
```

### Branch Translation and the Importance of the CFG

Conditional branches in eBPF compare two registers and conditionally jump:

```
eBPF: BPF_JMP_REG(BPF_JNE, BPF_REG_1, BPF_REG_2, +16)  ; if R1 != R2 goto PC+16
x86:  cmp    rdi, rsi
      jne    .L_target_offset_16
```

The JIT computes the absolute native address of the branch target (which the verifier has confirmed exists and is valid) and emits a relative jump with the correct offset. The verifier's CFG construction is essential here: the JIT trusts that all branch targets are valid because the verifier has already validated the CFG.

Exit instructions terminate the BPF program:

```
eBPF: BPF_EXIT_INSN()                               ; return R0
x86:  mov    rax, rbx          ; if R0 != RAX, move to RAX
      ; epilogue: restore callee-saved regs
      pop    rbp
      pop    r15
      pop    r14
      pop    r13
      pop    rbx
      ret
```

### Helper Function Calls: Bridging BPF and Kernel C

Calls to helper functions are the most complex JIT operation. The eBPF instruction `BPF_CALL` with an immediate argument encodes the helper function index. The JIT must:

1. Load the helper function's address from a kernel table (`bpf_helpers[]` array).
2. Set up arguments according to the ABI (RDI=R1, RSI=R2, RDX=R3, RCX=R4, R8=R5).
3. Save R6-R9 (callee-saved BPF registers) to the stack — helper functions may clobber them.
4. Call the helper function.
5. Restore R6-R9 from the stack.
6. Move the return value to R0 (which maps to RAX, conveniently the return register).

The JIT emits:

```asm
; Save callee-saved BPF regs to stack slots
mov    [rbp - 8], rbx       ; save R6
mov    [rbp - 16], r13      ; save R7
mov    [rbp - 24], r14      ; save R8
mov    [rbp - 32], r15      ; save R9
; Arguments already in RDI, RSI, RDX, RCX, R8
mov    rax, helper_addr     ; load helper function pointer
call   rax                  ; call helper(rdi, rsi, rdx, rcx, r8)
; Restore callee-saved
mov    rbx, [rbp - 8]
mov    r13, [rbp - 16]
mov    r14, [rbp - 24]
mov    r15, [rbp - 32]
; Return value already in RAX = R0
```

### Tail Calls and BPF-to-BPF Function Calls

Tail calls (`bpf_tail_call`) are a special optimization where one BPF program transfers control to another without returning. The JIT implements this as a direct jump — no call/return overhead. BPF-to-BPF function calls (introduced in Linux 4.16) use the native `call` instruction with a stack frame, enabling subroutines within BPF programs. The JIT allocates a stack frame layout that accommodates both the BPF stack (512 bytes) and the native C calling convention's red zone and alignment requirements.

### Performance Characteristics

The JIT translation is essentially a linear scan over the verified bytecode, emitting one to a handful of native instructions per BPF instruction. The entire process takes microseconds for typical BPF programs (50-500 instructions). The resulting native code executes at near-identical speed to hand-written kernel C code for equivalent operations. The primary overheads are:

- **Register save/restore**: The prologue and epilogue save and restore 5 callee-saved registers (~10 instructions each).
- **Helper call overhead**: Similar to a regular function call (argument setup, call, return value handling) — about 15-20 cycles.
- **Spectre mitigations**: On affected CPUs, the JIT inserts `lfence` or retpoline sequences after indirect branches to prevent speculative execution attacks.

For XDP programs processing packets at 10+ Mpps (million packets per second), JIT compilation is the difference between line-rate performance and kernel bypass — interpreted BPF simply cannot keep up at those rates.

## 5. BPF Maps: Sharing State Between Kernel and User Space

BPF maps are the data structure that makes eBPF stateful. Without maps, an eBPF program would be a pure function: it reads its input (packet, syscall arguments, tracepoint data), computes a result, and returns. Maps allow the program to maintain state across invocations (counters, connection tables, configuration parameters) and to communicate with user-space management programs.

The kernel provides several map types, each optimized for different access patterns:

- **BPF_MAP_TYPE_HASH**: A generic hash table. Keys and values are arbitrary blobs with sizes specified at map creation. Lookup, insert, and delete are O(1) average case. This is the most commonly used map type.

- **BPF_MAP_TYPE_ARRAY**: A fixed-size array. Indices are 32-bit integers. Lookup is O(1) (direct indexing). The array is pre-allocated at map creation time, so lookups never fail. Ideal for counters indexed by CPU number or other dense integer keys.

- **BPF_MAP_TYPE_PERCPU_HASH / PERCPU_ARRAY**: Per-CPU variants of hash and array maps. Each CPU has its own copy of the map, eliminating cache-line contention for frequent updates. The eBPF program reads/writes the local CPU's copy; user space can aggregate across CPUs.

- **BPF_MAP_TYPE_LRU_HASH**: A hash map with LRU eviction. When the map is full and a new entry is inserted, the least recently used entry is evicted. Useful for caches (connection tracking, flow state).

- **BPF_MAP_TYPE_LPM_TRIE**: Longest prefix match trie. Used for routing table lookups (IP prefix to next hop). Keys are IP prefixes; values can be anything.

- **BPF_MAP_TYPE_RINGBUF**: A ring buffer for efficient streaming of data from eBPF programs to user space. Multiple producers (eBPF programs on different CPUs) can write to the buffer without locking; a single consumer (user space) reads the data. Used for observability (exporting events from the kernel to user space).

Maps are created from user space via the `BPF_MAP_CREATE` command in the `bpf()` syscall, which returns a file descriptor. The file descriptor can be "pinned" to the BPF filesystem (`/sys/fs/bpf/`) for persistence and sharing between processes. eBPF programs reference maps via file descriptors stored in the program's "map array" — the loader inserts the map's file descriptor into the program's instructions at load time.

## 5. Hooks: Where BPF Programs Attach

eBPF programs don't run spontaneously; they are attached to kernel hooks. Each hook type provides a specific context (the data the program can access) and expects a specific return value (the action the kernel should take based on the program's decision).

**XDP (eXpress Data Path)**: The earliest point in the network stack. The eBPF program runs in the network driver's receive path, before the kernel allocates an sk_buff (socket buffer) for the packet. The context is the raw packet data (Ethernet frame, IP header, TCP/UDP payload). The return value can be XDP_PASS (continue normal processing), XDP_DROP (silently drop the packet), XDP_TX (bounce the packet back out the same interface), or XDP_REDIRECT (send to a different interface or to user space via AF_XDP). XDP programs can process packets at line rate: 10+ million packets per second per core.

**TC (Traffic Control)**: The eBPF program runs in the kernel's traffic control layer, after the sk_buff has been allocated. The context is the sk_buff, giving access to all packet metadata (mark, priority, timestamps) and headers. TC BPF programs can filter, redirect, mark, or modify packets. They are more flexible than XDP but also slower (the sk_buff allocation and kernel stack overhead have already been incurred).

**Tracepoints, kprobes, uprobes**: eBPF programs can attach to kernel tracepoints (static instrumentation points), kprobes (dynamic kernel function entry/exit probes), and uprobes (user-space function probes). The context is the tracepoint's or function's arguments. These programs are used for observability (collecting latency histograms, tracing function calls, counting events).

**Socket filters and cgroup hooks**: eBPF programs can filter or modify traffic at the socket level (BPF_PROG_TYPE_SOCKET_FILTER), enforce network policy at the cgroup level (BPF_PROG_TYPE_CGROUP_SKB), or implement custom socket operations (BPF_PROG_TYPE_SOCK_OPS).

**LSM (Linux Security Module) hooks**: Since Linux 5.7, eBPF programs can be attached to LSM hooks — the same hooks used by SELinux, AppArmor, and other mandatory access control systems. This allows dynamic, programmable security policies enforced by the kernel.

## 6. BPF CO-RE: Write Once, Run Everywhere

A major challenge for eBPF portability is that kernel data structures change between kernel versions. A BPF program that accesses `struct task_struct` on kernel 5.10 may break on kernel 5.15 if a field is added or reordered. BPF CO-RE (Compile Once, Run Everywhere) solves this using two techniques:

1. **BTF (BPF Type Format)**: The kernel compiles with debug information in BTF format, which describes the layout of all kernel data structures (offsets of fields, sizes of types, struct member types). BTF is compact (a few megabytes for the entire kernel) and is loaded into the kernel at boot.

2. **Relocations**: The BPF compiler (clang) emits "CO-RE relocations" — annotations that tell the BPF loader, "this field is at offset X in the compilation kernel; please adjust it to the actual offset in the running kernel." The loader reads BTF from the running kernel, looks up the field by name, and patches the BPF instruction with the correct offset.

With CO-RE, a single BPF binary can run on any kernel version that supports BTF (5.4+), without recompilation. This is essential for distributing BPF programs as part of a software product (instead of requiring compilation on the target machine).

## 7. Summary

eBPF has become the Linux kernel's universal extension mechanism — a safe, efficient way to add custom logic to the networking stack, the tracing infrastructure, the security subsystem, and increasingly to the scheduler and other core components. The verifier is the key to eBPF's safety: by proving that programs terminate and stay within bounds, it enables the kernel to execute untrusted code without risking stability. The JIT compilers make eBPF fast enough for production use at scale. And the map infrastructure provides the stateful foundation that makes eBPF more than just a packet filter.

The eBPF ecosystem is still evolving rapidly. New features like signed BPF programs, dynamically linked BPF libraries (BPF linkers), and user-space BPF runtimes (for non-Linux platforms) are expanding eBPF's reach. The original vision — a general-purpose in-kernel virtual machine — has been realized far beyond what Starovoitov and Borkmann likely imagined in 2014. eBPF is now one of the most important kernel technologies of the past decade, and its trajectory suggests it will become even more central to Linux's architecture in the years ahead.

## 8. eBPF for Observability: BCC, bpftrace, and the Future of Tracing

eBPF has revolutionized Linux observability. Before eBPF, kernel tracing required either static tracepoints (limited coverage), kernel modules (safety risk, requires compilation), or user-space probes (high overhead). eBPF enables safe, dynamic, low-overhead instrumentation of any kernel function, any user-space function, and any tracepoint.

BCC (BPF Compiler Collection) provides a set of tools and a Python/Lua frontend for writing eBPF programs. Tools like `execsnoop` (trace all `exec()` calls), `opensnoop` (trace all `open()` calls), `tcptop` (top-like display of TCP connections), and `biolatency` (histogram of block I/O latency) are built on BCC. Each tool is a short eBPF program (typically 50-200 lines of C) compiled at runtime by BCC's embedded Clang/LLVM.

bpftrace is a high-level tracing language for eBPF, inspired by DTrace. A one-liner like `bpftrace -e 'kprobe:do_sys_open { printf("%s: %s
", comm, str(arg1)); }'` compiles to an eBPF program that traces all file open operations, printing the process name and filename. bpftrace handles the boilerplate (program loading, map management, output formatting), letting users focus on the tracing logic.

The next frontier for eBPF observability is "continuous profiling" — using eBPF to capture stack traces at high frequency (hundreds of samples per second per CPU) and building flame graphs that show where CPU time is spent across the entire fleet. Projects like Parca and Pyroscope use eBPF to implement continuous profiling with minimal overhead (1-3% CPU), enabling fleet-wide performance analysis that was previously impossible.

## 9. eBPF Security: The Verifier as a Gatekeeper

The eBPF verifier is not just a safety check — it's a security boundary. Unprivileged eBPF (accessible to non-root users via `CAP_BPF`) relies on the verifier to prevent privilege escalation. A malicious or buggy eBPF program could leak kernel memory, corrupt kernel data structures, or cause denial of service if the verifier didn't catch it.

The verifier has been the subject of intense security scrutiny. Vulnerabilities in the verifier itself (CVE-2020-8835, CVE-2021-3490, CVE-2022-23222) have allowed eBPF programs to bypass safety checks and access kernel memory. These vulnerabilities are typically in the verifier's bounds tracking or type checking logic — the verifier incorrectly believes a pointer is within bounds when it isn't, or incorrectly believes a register contains a scalar when it contains a pointer. Each vulnerability leads to verifier hardening: more conservative bounds analysis, additional sanity checks, and expanded fuzzing coverage.

Unprivileged eBPF is now disabled by default on many distributions due to these security concerns. The kernel provides a `kernel.unprivileged_bpf_disabled` sysctl that prevents unprivileged users from loading eBPF programs. For production systems, the recommendation is to keep unprivileged eBPF disabled and use only signed eBPF programs loaded by privileged services. Signed BPF (BPF token authentication) is an emerging feature that allows an administrator to delegate specific eBPF capabilities to trusted workloads.

## 10. eBPF in the Scheduler: The BPF Scheduler (extensible sched)

One of the most exciting recent developments in eBPF is its application to CPU scheduling. Linux 6.6 (2023) introduced the BPF scheduler framework, allowing eBPF programs to implement custom scheduling policies. The traditional Linux scheduler (CFS/EEVDF) is a one-size-fits-all solution that works reasonably well for most workloads but cannot be optimal for all. Database servers, real-time audio processing, and HPC workloads all have different scheduling needs.

The BPF scheduler framework exposes hooks at key scheduling decision points: `sched_select_cpu` (which CPU should a waking task run on?), `sched_enqueue` (add a task to the run queue), `sched_dequeue` (remove a task from the run queue), and `sched_tick` (periodic timer, used for preemption decisions). A BPF program can implement a custom policy (e.g., "always schedule latency-sensitive tasks on the same socket as their data") using efficient BPF data structures (maps for task metadata, arrays for per-CPU state).

The verifier constraints that make eBPF safe for networking also apply to scheduling. The BPF scheduler program cannot loop indefinitely, cannot access kernel memory outside its designated maps, and must terminate within a bounded number of instructions. This makes it safe to run a user-provided scheduler in the kernel's hottest path (the `schedule()` function). The overhead of the BPF scheduler is typically less than 1% compared to CFS for equivalent policies, and the flexibility enables performance improvements of 10-50% for specialized workloads.

## 11. eBPF as a Platform: Building Services on BPF

The eBPF ecosystem is evolving from "eBPF as a kernel mechanism" to "eBPF as a platform." Several companies are building entire products on eBPF. Cilium provides Kubernetes networking, security, and observability entirely through eBPF, replacing kube-proxy, network policies, and service mesh sidecars with eBPF programs. Pixie provides instant-on Kubernetes observability using eBPF to capture metrics, traces, and logs without instrumenting application code. Isovalent (now part of Cisco) builds enterprise eBPF solutions for cloud-native networking and security.

The appeal of eBPF as a platform is its combination of safety, performance, and programmability. Unlike kernel modules (which can crash the kernel, have unrestricted access, and require per-kernel-version compilation), eBPF programs are verifiably safe, sandboxed, and portable via CO-RE. Unlike user-space agents (which have high overhead from context switches and data copies), eBPF programs run in the kernel with near-zero overhead. This makes eBPF the ideal foundation for infrastructure software — networking, security, observability — that needs kernel-level visibility and performance with user-space safety and programmability.

The eBPF platform market is growing rapidly. The eBPF Foundation, part of the Linux Foundation, coordinates development across the ecosystem. Google, Meta, Netflix, and other hyperscalers run eBPF-based infrastructure at massive scale. The future of Linux system programming is increasingly eBPF-first — instead of patching the kernel, write an eBPF program.

## 12. eBPF Verifier Internals: The Path Pruning Algorithm

The eBPF verifier's path exploration is a fascinating application of abstract interpretation. The verifier must explore all possible paths through the control flow graph, but the CFG can be enormous (exponential in the number of branches). The verifier uses "state pruning" to avoid re-exploring equivalent states: if the verifier reaches a program point with a state that is "more general" (less constrained) than a previously explored state at the same point, the current path can be pruned — any execution that follows from the current state is also possible from the more general state.

"More general" means that the new state has all the register types of the old state, but with wider value ranges, fewer alignment constraints, and fewer spilling (stack slot initialization) guarantees. The verifier maintains a cache of explored states at each program point, keyed by the instruction pointer. When exploring a new path, it looks up the cache: if the current state is "covered" (subsumed) by a cached state, the path is pruned. This is essentially a form of symbolic execution with subsumption checking.

The verifier's bounds tracking uses a combination of signed and unsigned value range analysis. Each 64-bit register has both a signed range `[smin, smax]` and an unsigned range `[umin, umax]`. When the verifier sees a conditional branch `if r1 < 10`, it updates the signed range of r1 on the taken path to `[INT64_MIN, 9]` and on the fall-through path to `[10, INT64_MAX]`. When the branch is unsigned (`if r1 < 10` with unsigned comparison), it updates the unsigned range instead. This dual range analysis is essential for verifying array bounds checks, where the comparison is usually unsigned.

## 13. eBPF Concurrency: Spin Locks and Per-CPU Data

eBPF programs were historically single-threaded: each invocation of a BPF program on a given CPU ran to completion without interruption. But with the introduction of BPF spin locks (2020) and BPF timers (2022), eBPF programs can now sleep, be preempted, and run concurrently on multiple CPUs. This introduces new safety challenges for the verifier.

BPF spin locks (`bpf_spin_lock`) protect shared data structures in BPF maps. The verifier enforces that a spin lock is held when accessing the protected data: the lock must be acquired before accessing the data, the lock cannot be held across a sleepable helper call (which would cause a deadlock if the thread is preempted), and the lock must be released on all paths that acquired it. The verifier tracks lock state as part of the symbolic state, similar to how it tracks register types and bounds.

Per-CPU data structures (BPF_MAP_TYPE_PERCPU_ARRAY, BPF_MAP_TYPE_PERCPU_HASH) provide a simpler concurrency model: each CPU has its own copy of the data, so accesses don't require locking. The verifier ensures that a per-CPU pointer is only accessed on the CPU that owns it. This is enforced by checking that the program is not preemptible (not in a sleepable context) and that the pointer is not stored to a global map (where it could be accessed by another CPU). Per-CPU data is the preferred concurrency approach for most eBPF programs because it avoids lock contention and deadlocks.

## 14. The eBPF Memory Model: Acquire-Release Semantics and Kernel Consistency

The interaction between eBPF programs and the kernel's memory model is a subtle and critical topic. BPF maps reside in kernel memory, which means accesses to map values are subject to the kernel's memory model — which on Linux is the C11 memory model as implemented by the kernel's `READ_ONCE`/`WRITE_ONCE` macros, with explicit barriers provided by `smp_rmb()`, `smp_wmb()`, and `smp_mb()`.

### Implicit Ordering for Map Access

When a BPF program reads from or writes to a map, the kernel provides implicit ordering guarantees. A `bpf_map_update_elem` call from user space is visible to a subsequent BPF program invocation — the map implementation uses RCU (Read-Copy-Update) for read-mostly maps (like ARRAY maps) or spin locks for mutable maps (like HASH maps). Similarly, a BPF program's write to a map is visible to a subsequent `bpf_map_lookup_elem` from user space. However, the ordering is not sequentially consistent — reordering can occur if proper barriers are not used.

For per-CPU maps, the situation is simpler. Each CPU accesses its own copy of the data, so there is no concurrent access within the kernel. User-space reads must iterate over all per-CPU copies and aggregate them. The kernel provides `bpf_map_lookup_percpu_elem` to read a specific CPU's value, but consistency across CPUs is not guaranteed — the user-space reader may see a mix of old and new values from different CPUs.

### BPF Spin Locks and Acquire-Release

BPF spin locks (`bpf_spin_lock` / `bpf_spin_unlock`) provide acquire-release semantics compatible with the kernel's locking model. Acquiring a spin lock (\(bpf_spin_lock\)) acts as an acquire operation: all loads and stores after the lock acquisition (in program order) are ordered after the lock acquisition. Releasing a spin lock (\(bpf_spin_unlock\)) acts as a release operation: all loads and stores before the lock release are ordered before the lock release.

Formally, for a critical section protected by `bpf_spin_lock`:

```
Thread A:                    Thread B:
  lock(L)  [acquire]           lock(L)  [acquire, blocks until A releases]
  x = 1    [store]             r1 = x  [load, sees 1]
  y = 2    [store]             r2 = y  [load, sees 2]
  unlock(L) [release]          unlock(L) [release]
```

The release in Thread A synchronizes with the acquire in Thread B, providing happens-before ordering. This is exactly the same guarantee as Linux kernel spin locks (`spin_lock` / `spin_unlock` in kernel C code).

### Atomic Operations in BPF

Linux 5.12 introduced atomic operations for BPF programs: `BPF_ATOMIC` instructions that perform atomic add, and, or, xor, exchange (xchg), and compare-exchange (cmpxchg) on map values. These are implemented using the architecture's native atomic instructions (`lock add`, `lock cmpxchg` on x86-64). The verifier ensures that atomic operations are only performed on values in BPF maps (not on the stack or context), and that the size of the atomic operation (32-bit or 64-bit) matches the alignment of the value.

Atomic operations in BPF have full sequentially consistent ordering — they include implicit full memory barriers before and after the operation. This is stricter than C11's `memory_order_seq_cst` (which only orders atomics with respect to other atomics) and is equivalent to the kernel's `atomic_t` operations. For BPF programs that need to maintain concurrent counters or implement lock-free data structures, atomic operations provide the necessary primitives without the overhead of spin locks.

### The Verifier's Role in Memory Ordering

The verifier does not currently model memory ordering — it does not track happens-before relationships or check that data races are prevented. This is a known gap: a BPF program can write to a map value without holding the appropriate spin lock, creating a data race with another BPF program or with user space. The kernel does not detect or prevent such races; it relies on the programmer to use the correct synchronization.

The BPF community is exploring extensions to the verifier that would track lock state across map accesses, similar to how the Linux kernel's Kernel Concurrency Sanitizer (KCSAN) detects data races at runtime. In the meantime, safe BPF programming requires careful manual adherence to the synchronization conventions of each map type.

## 15. eBPF Program Lifecycle: From Object File to Live Attachment

Understanding the full lifecycle of an eBPF program — from compilation to execution to teardown — is essential for building reliable BPF-based systems. The lifecycle involves several kernel subsystems working in concert: the BPF syscall interface, the verifier, the JIT, the attachment points, and the memory management subsystem.

### Phase 1: Compilation and Relocation

The lifecycle begins with C source code compiled by Clang with `-target bpf`. The compiler emits an ELF object file containing eBPF bytecode in a `.text` section, map definitions in a `maps` section, and CO-RE relocations in a `.rel` section. The ELF file also contains BTF metadata describing the program's types and the maps it uses.

At this stage, the program is an inert object file — no kernel interaction has occurred. The loader (typically `libbpf` or `bpftool`) reads the ELF file and performs relocations: resolving map references (replacing map-internal indices with file descriptors), applying CO-RE relocations (adjusting field offsets for the target kernel), and resolving BPF-to-BPF function calls.

### Phase 2: Loading and Verification

The loader issues the `BPF_PROG_LOAD` syscall command, passing the bytecode, the program type, and metadata. The kernel:

1. Copies the bytecode into kernel memory.
2. Invokes the verifier to prove safety. If verification fails, the syscall returns `-EACCES` with a verifier log describing the rejection reason.
3. If verification succeeds and JIT is enabled, the kernel JIT-compiles the bytecode to native code.
4. Allocates a `struct bpf_prog` to represent the loaded program, with pointers to the bytecode and JIT-compiled code.
5. Returns a file descriptor to user space.

The file descriptor is a reference to the kernel's `struct bpf_prog`. As long as the FD is held open (by the loader or by pinning to the BPF filesystem), the program remains loaded. The FD can be passed to other processes via Unix domain sockets (SCM_RIGHTS), allowing privilege separation between the loader and the attacher.

### Phase 3: Attachment

The loaded program is inert until attached to a hook. Attachment varies by program type:

- **XDP**: The user-space program issues a `setsockopt` or netlink message to attach the BPF FD to a network interface. The kernel stores the `struct bpf_prog *` in the interface's XDP hook slot. When a packet arrives, the driver's NAPI poll loop calls `bpf_prog_run_xdp(prog, xdp_buff)`, which invokes the JIT-compiled native code.
- **TC**: Attachment is via netlink (`tc filter add ... bpf obj ...`). The BPF program is linked into the traffic control qdisc's filter chain.
- **Tracepoints/kprobes**: The kernel's tracing infrastructure (`perf_event_open` with BPF) attaches the program to the tracepoint or kprobe. When the tracepoint fires, the kernel calls the BPF program.
- **Cgroup/skb**: Attachment is via `BPF_PROG_ATTACH` syscall, specifying the cgroup FD and the attach type.

Each attachment increments the program's reference count. A single loaded program can be attached to multiple hooks simultaneously (e.g., the same XDP program attached to multiple interfaces).

### Phase 4: Execution

When the hook fires (packet arrives, syscall is made, tracepoint triggers), the kernel invokes the BPF program. For JIT-compiled programs, this is a direct function call to the JIT code; for interpreted programs, it's a call to `__bpf_prog_run()` which executes the bytecode in a loop. The BPF program runs in the context of the triggering event (in the same kernel thread, with the same preemption state) and must complete within a bounded time (the verifier's DAG guarantee).

### Phase 5: Detachment and Unloading

A BPF program can be detached by the user-space loader (via `BPF_PROG_DETACH` or the appropriate netlink command) or automatically when the attaching entity (interface, cgroup, process) is destroyed. Detachment decrements the program's reference count. When the reference count drops to zero — all attachments removed, no open file descriptors, no pinned BPF filesystem entries — the kernel frees the `struct bpf_prog`, the bytecode, and the JIT-compiled code.

This reference-counted lifecycle is critical for safety: a BPF program can never be freed while it might still execute (because a reference is held by each attachment point). The BPF filesystem provides persistence beyond the loader process: by pinning a BPF FD to `/sys/fs/bpf/my_prog`, the program remains loaded even after the loader exits, and can be re-attached by other tools.

## 16. Summary

eBPF has become the Linux kernel's universal extension mechanism — a safe, efficient way to add custom logic to the networking stack, the tracing infrastructure, the security subsystem, and increasingly to the scheduler and other core components. The verifier is the key to eBPF's safety: by proving that programs terminate and stay within bounds, it enables the kernel to execute untrusted code without risking stability. The JIT compilers make eBPF fast enough for production use at scale. The map infrastructure provides the stateful foundation that makes eBPF more than just a packet filter. And the rich ecosystem of hooks (XDP, TC, tracepoints, LSM, scheduler) means that eBPF can observe and influence virtually every aspect of kernel behavior. eBPF is not just a technology — it's a platform, and it's changing how we build infrastructure software.

## 17. eBPF and Hardware Offload: SmartNICs and the Future

eBPF is extending beyond the CPU to programmable hardware. Netronome SmartNICs support offloading eBPF programs to the NIC's programmable processors, allowing packet processing to happen at line rate without consuming host CPU cycles. An XDP program compiled to eBPF bytecode can be JIT-compiled to the SmartNIC's native instruction set (typically a RISC-like ISA) and executed directly on the NIC. This is "XDP offload" — the eBPF program runs on the NIC, drops or forwards packets before they reach the host, and the host CPU never sees the filtered packets.

The verifier must be extended for hardware offload: it must verify that the eBPF program is safe for the NIC's hardware, which has different constraints than the host CPU (limited instruction set, no support for certain map types, bounded loop iterations). The eBPF offload API allows the NIC driver to report its capabilities (supported instructions, maximum program size, map types), and the verifier checks the program against those capabilities. If the program exceeds the NIC's capabilities, the verifier rejects it for offload (but it can still run on the host CPU).

The future of eBPF offload is tightly coupled with the rise of SmartNICs and IPUs (Infrastructure Processing Units). As more data center operators deploy SmartNICs for network virtualization and security, eBPF will be the universal programming model that spans the host CPU, the SmartNIC, and even the switch (P4-programmable switches are converging with eBPF through the BPF/P4 bridge). eBPF is not just a kernel technology — it's becoming the "Linux of programmable networking," providing a unified programming model across heterogeneous hardware.

## 18. eBPF Program Types and Their Verifier Constraints

Each eBPF program type has specific constraints enforced by the verifier. A `BPF_PROG_TYPE_XDP` program receives a raw packet buffer and can read/write packet data, but cannot access kernel memory or call most helper functions. A `BPF_PROG_TYPE_TRACEPOINT` program receives tracepoint arguments and can read kernel memory (within bounds), but cannot write to kernel memory or modify process state. The verifier enforces these constraints by checking the program's use of helper functions and context accesses against a whitelist specific to the program type.

The program type determines which helper functions are available. An XDP program can call `bpf_xdp_adjust_head` (adjust packet headroom) but not `bpf_get_current_pid` (get the current process ID) because the XDP hook runs in a context where there is no current process. A tracing program can call `bpf_get_current_pid` but not `bpf_xdp_adjust_head`. The verifier checks each helper call against the program type's allowed helper list and rejects unauthorized calls.

The verifier also enforces size limits on programs: initially 4,096 instructions per program, later increased to 1 million for privileged programs. The instruction limit prevents denial-of-service attacks where a malicious (or buggy) BPF program would consume unbounded verifier time. The verifier itself has a complexity limit: it stops exploring paths after processing a certain number of instructions (currently 1 million), and if the program hasn't been fully verified by that point, verification fails. These limits are tuned empirically based on production workloads and verifier performance.

## 19. eBPF and the Future of Operating Systems

eBPF is changing how we think about operating systems. The traditional OS model — a monolithic kernel with a fixed set of abstractions — is giving way to a more flexible model where the kernel provides mechanisms (hooks, verifier, maps, helpers) and user-space programs define policies. This is sometimes called "software-defined kernel" or "kernel as a platform."

The implications are profound. Networking, which was once the exclusive domain of kernel developers, is now programmable by anyone who can write C (for eBPF programs). Kubernetes networking (Cilium), DDoS mitigation (Cloudflare's L4Drop), and load balancing (Facebook's Katran) are implemented as eBPF programs. Observability, which once required kernel patches or modules, is now done with eBPF tracing (Pixie, Parca, bpftrace). Security, which was enforced by static kernel policies (SELinux, AppArmor), can now be dynamically programmed (Falco, Tracee).

The vision of eBPF is that the kernel becomes a runtime — a safe, efficient execution environment for user-provided code that observes and controls system behavior. This is not a new vision (microkernels and exokernels had similar goals), but eBPF realizes it within the existing Linux kernel, incrementally, without requiring a rewrite of the entire OS. That pragmatism is why eBPF has succeeded where previous attempts at kernel extensibility failed.

The incremental adoption story is worth examining. eBPF did not require kernel developers to abandon existing subsystems or rewrite drivers. Instead, it introduced hooks at strategic points — the networking stack, the scheduler, the LSM framework, tracepoints — that existing code already traversed. Each hook is an insertion point where an eBPF program can inspect state and optionally influence behavior, but the default path (no eBPF program attached) is identical to the pre-eBPF code path. This means that eBPF can be adopted selectively: a Kubernetes cluster can use Cilium for networking while leaving other kernel subsystems untouched; a security team can deploy Falco for threat detection without modifying the kernel's built-in security mechanisms. This contrasts sharply with previous extensibility approaches like loadable kernel modules, which required deep kernel knowledge to write and could crash the kernel if buggy, and with microkernels, which required a complete architectural shift. eBPF's genius is that it provides microkernel-like extensibility within a monolithic kernel, with safety guarantees that make it production-ready.

## 20. eBPF and WebAssembly: Competing or Complementary?

eBPF and WebAssembly are often compared as "in-kernel sandbox" vs "user-space sandbox," but they are increasingly complementary. eBPF excels at in-kernel event-driven processing with minimal overhead; Wasm excels at portable, language-agnostic sandboxing with rich runtime support. Several projects are bridging the two: `bpftrace-wasm` compiles bpftrace scripts to Wasm for execution in user-space testing environments. `wasm-bpf` allows Wasm programs to call eBPF helpers (map operations, helper functions) from user space, providing a Wasm-friendly interface to eBPF functionality.

The most interesting convergence is in the observability space. Pixie (a Kubernetes observability platform) uses eBPF to capture kernel-level metrics (CPU, memory, network) and compiles the data processing logic to Wasm, which runs in a user-space sandbox. eBPF handles the high-performance, kernel-level data capture; Wasm handles the safe, portable data processing. This division of labor — eBPF for kernel hooks, Wasm for user-space logic — is likely to become a common pattern in cloud-native infrastructure. The two technologies are not competitors; they are two layers of the same stack.

eBPF has changed the trajectory of the Linux kernel. What began as a better packet filter has become the kernel's universal extension mechanism, enabling a new generation of infrastructure software that is safer, faster, and more flexible than anything that came before. The kernel is no longer a monolith to be patched and recompiled — it is a platform to be programmed.
