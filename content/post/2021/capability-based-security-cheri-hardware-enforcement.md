---
title: "Capability-Based Security: CHERI Architecture, Hardware Capabilities, Spatial and Referential Safety, and Compartmentalization"
description: "A deep exploration of the CHERI capability architecture — how hardware-enforced capabilities provide spatial memory safety, referential integrity, and fine-grained compartmentalization at the instruction level."
date: "2021-02-26"
author: "Leonardo Benicio"
tags: ["cheri", "capability", "security", "memory-safety", "architecture", "compartmentalization"]
categories: ["systems", "security"]
draft: false
cover: "static/images/blog/capability-based-security-cheri-hardware-enforcement.png"
coverAlt: "A stylized diagram showing CHERI capabilities as unforgeable tokens bounding memory access, with capability registers constraining pointer operations at the instruction level"
---

In 2010, researchers at the University of Cambridge and SRI International began work on a radical hardware architecture called CHERI — Capability Hardware Enhanced RISC Instructions. The premise was audacious: extend the existing RISC-V and ARM instruction sets with hardware-enforced capabilities that could prevent virtually all spatial memory safety errors (buffer overflows, use-after-free, dangling pointers) at the hardware level, without breaking compatibility with existing C and C++ code. A decade later, CHERI has been implemented in FPGA prototypes, ARM's experimental Morello processor (shipping to researchers in 2022), and is being considered for widespread deployment by the UK government's Digital Security by Design initiative. This post explores how CHERI works, from the hardware capability representation to the software compartmentalization model.

## 1. The Memory Safety Crisis

Memory safety bugs — buffer overflows, use-after-free, null pointer dereferences, type confusion — account for roughly 70% of all security vulnerabilities in large C and C++ codebases, according to studies by Microsoft, Google, and others. Despite decades of investment in static analysis, fuzzing, and runtime mitigations (stack canaries, ASLR, DEP), these bugs persist because the underlying C/C++ memory model provides no protection against out-of-bounds access or use of freed memory.

CHERI's insight is that the root cause of these vulnerabilities is the nature of pointers in conventional architectures. A pointer in x86 or ARM is an integer — a raw number that can be arbitrarily modified, incremented past buffer boundaries, or used after the pointed-to memory has been freed. The hardware treats all pointers as equal, providing no way to distinguish a legitimate pointer from a forged one.

CHERI replaces raw pointers with capabilities — unforgeable tokens that encode not just the memory address but also the bounds of the accessible region, the permissions (read, write, execute), and an object type. A capability is 128 bits (or 64 bits in compressed format) and is hardware-protected: it cannot be forged by writing arbitrary data to memory, because capabilities are stored in tagged memory with a 1-bit tag that distinguishes them from ordinary data. The hardware enforces that capabilities can only be created by legitimate capability operations (narrowing bounds, reducing permissions, sealing) and can never be fabricated from raw data.

## 2. The CHERI Capability Format

A CHERI capability is a 128-bit value that encodes:

- **Address**: A 64-bit virtual address (the location in memory the capability refers to).
- **Base**: The lower bound of the memory region accessible through this capability (typically 64 bits, compressed into the 128-bit encoding).
- **Length**: The size of the accessible region (also compressed).
- **Permissions**: A set of bits indicating what operations are allowed: Load, Store, Execute, LoadCap (load a capability), StoreCap (store a capability), Seal, Unseal, and others.
- **Object type**: For sealed capabilities (used in compartmentalization), a type identifier that restricts what the capability can be used for.
- **Tag**: A 1-bit hardware tag that distinguishes capabilities from ordinary data. The tag is stored in the memory system (not in the capability value itself) and is propagated by all capability operations.

The critical property is that capabilities are monotonic: they can only become less powerful over time. A capability can be narrowed (base increased, length decreased), its permissions can be reduced, but it can never be widened or have permissions added. This ensures that if you receive a capability with restricted bounds, you cannot expand it to access memory outside those bounds.

When the processor loads a capability from memory, it checks the memory tag. If the tag bit is set, the loaded value is treated as a valid capability and can be used for memory access. If the tag bit is clear, the loaded value is treated as raw data and can only be used for arithmetic, not for memory access. This prevents a class of attacks where an attacker writes forged capability bytes to memory and then loads them — the tag bit won't be set, and the forged capability will be invalid.

## 3. Capability Compression: The Representable Region Problem

The most architecturally challenging aspect of CHERI is fitting a full capability — 64-bit address, 64-bit base, 64-bit length, plus permissions and type — into 128 bits. A naive approach would require 192+ bits, which is impractical for a 128-bit register file. CHERI solves this through a clever compression scheme based on the observation that bounds in real programs are not arbitrary; they have structure that can be exploited.

### The Floating-Point Bounds Representation

CHERI uses a floating-point-like representation for the base and length fields. Specifically, the base is encoded as a 64-bit value `b` that is decoded according to:

```
base_effective = B[63:E+14] << (E+14)
```

where `B` is the encoded base field and `E` is a shared exponent. The length is similarly encoded with the same exponent. This means both base and length are multiples of 2^(E+14). The exponent `E` ranges from 0 to 31, giving alignment requirements from 2^14 (16 KiB) to 2^45 (32 TiB).

The key insight: when a program allocates a buffer, the base address and length are usually aligned to some power-of-two boundary — page alignment for large buffers, malloc alignment for small ones. The compression scheme exploits this to fit the bounds into fewer bits while preserving the property that the decoded bounds are always at least as restrictive as the intended bounds. That is, the representation can only over-approximate the bounds, never under-approximate.

### The Representable Region Invariant

A capability's bounds must satisfy the "representable region" invariant: for any capability with intended base `b` and length `l`, the effective decoded bounds `[base_effective, base_effective + length_effective)` must contain the original requested bounds `[b, b+l)`. Formally:

```
base_effective <= b  AND  b + l <= base_effective + length_effective
```

This means the representation always rounds the base down (to the nearest aligned value) and rounds the length up (to cover the entire requested region). This over-approximation is safe — it may grant slightly more access than strictly necessary (to the alignment padding), but never less. The allocator can choose alignment to minimize this padding overhead.

### Encoding Walkthrough with Concrete Numbers

Let's trace the encoding of a concrete example. Suppose `malloc(100)` returns address `0x7f8a_1234_5678`. The allocator must create a capability with base = `0x7f8a_1234_5678` and length = 100. The compression algorithm proceeds as follows:

1. Find the smallest exponent `E` such that both base and (base + length) can be represented.
2. For E = 0, alignment is 2^14 = 16,384 bytes. Check: does rounding base down to 16,384-byte alignment and length up to cover the region work? The decoded region would be `[0x7f8a_1234_0000, 0x7f8a_1234_4000)`, which covers our 100-byte buffer (with 16,284 bytes of padding).
3. Compute `base_encoded = base >> (E+14)` and `length_encoded = ceil((base+length - base_effective) >> (E+14))`.
4. Store `base_encoded`, `length_encoded`, and `E` in the 128-bit capability.

For large buffers — say `mmap` of 2 MiB — a larger `E` (coarser alignment) is used, minimizing the number of bits needed for the length field. For small buffers like `malloc(16)`, `E` stays small to minimize padding waste.

The hardware extracts these fields on every memory access and performs the bounds check using a three-input comparator:

```
access_address - base_effective < length_effective ? allow : trap
```

This check is implemented as a 64-bit subtract-and-compare that runs in parallel with the TLB lookup.

### Architectural Implications of Compression

The compression scheme has downstream effects throughout the architecture. Capability narrowing operations — reducing bounds, creating sub-capabilities — must compute new encoded representations that satisfy the representable region invariant. This requires a sequence of integer instructions: shift, mask, compare, conditional select. The CHERI ISA provides dedicated instructions (`CSetBounds`, `CSetAddr`, `CAndPerm`) that perform these operations atomically, ensuring the hardware tag is correctly maintained through the narrowing process. The `CSetBounds` instruction, for instance, takes a capability and a new length, computes the encoded representation, and returns a new capability with narrowed bounds — all in a single instruction that preserves the tag.

One subtlety: the representable region constraint means that some capability bounds cannot be exactly represented. If a program requests a capability to bytes 17-73 of a 100-byte buffer, the hardware rounds the base down to 16 and the length up to cover byte 73, potentially granting access to bytes 74-79 as well. In practice, this over-approximation is rarely exploitable because the "extra" bytes are within the same allocation unit. For security-critical code, CHERI provides explicit `CSetBoundsExact` (an inexact narrowing that signals when representation imprecision occurs), allowing the programmer to detect and handle the imprecision.

## 4. The Microarchitecture of Capability-Aware Memory Systems

Implementing CHERI requires modifications throughout the memory hierarchy — from the register file through the L1/L2 caches to main memory. These modifications are necessary to maintain the 1-bit capability tag that distinguishes capabilities from raw data.

### Tagged Memory at Scale

Every 128 bits of memory (or 64 bits in compressed CHERI-128 mode) requires a 1-bit tag. In a 16 GiB system, this means 128 MiB of tag storage — one bit per 16 bytes. The tag bits must satisfy three properties:

- **Non-addressable**: Tags cannot be accessed through normal load/store instructions; they are only manipulated through capability load/store (`CLoad`, `CStore`) and capability manipulation instructions. This prevents attackers from directly forging tags.
- **Atomic with data**: When a capability is stored to memory, the data and tag must be written atomically. A concurrent load must see either the old (data, tag) pair or the new (data, tag) pair, never a mixed state where the data is new but the tag is old (or vice versa).
- **ECC-integrated**: On systems with ECC memory, the tag bit can be stored in spare ECC bits. DDR5 ECC DIMMs have 8 spare bits per 64-bit data chunk, more than enough for one tag per 128 bits. This avoids requiring dedicated tag SRAM on the motherboard.

### Capability-Aware Cache Design

CHERI caches must store the tag bit alongside each cache line's data. For a 64-byte cache line that holds four 128-bit capabilities, the cache must store four tag bits. These tags flow through the entire cache hierarchy:

- **L1 Data Cache**: Tags are read on capability loads (`CLoad`) and written on capability stores (`CStore`). Ordinary loads and stores ignore tags — `ldr` (load register) returns the data bits but not the tag. The cache controller must prevent ordinary stores from modifying tags; only `CStore` can set tag bits. This is enforced by a write-enable signal that is only asserted for capability stores.
- **L2/L3 Caches**: Tags are propagated as part of the cache coherence protocol. For inclusive caches, tags from inner caches must be maintained in outer caches. The coherence protocol — whether MESI, MOESI, or a variant — must treat the {data, tag} pair as a single coherence granule.
- **Tag Cache**: Some implementations add a dedicated "tag cache" — a small, fast SRAM that caches only the 1-bit tags for recently accessed capabilities. Since ordinary loads don't need tags, the main data cache can serve ordinary loads without tag overhead, while capability loads hit the tag cache for tag validation.

### TLB Integration and Page-Level Tag Control

The Translation Lookaside Buffer (TLB) must also be CHERI-aware. In a conventional architecture, a TLB entry maps virtual page numbers to physical page numbers with permission bits (read, write, execute). In CHERI, each TLB entry gains a "capability page" bit. If this bit is set, the page contains capabilities, and the hardware enforces that only capability load/store instructions can access it. Ordinary loads and stores to capability pages trap with a capability violation exception.

This prevents a critical attack: writing raw bytes that mimic a capability's bit pattern to a page, then loading them as capabilities. If the page is marked as a capability page (because legitimate capabilities were stored there), an attacker's ordinary store (which can't set tags) will leave the tag bits at 0, and the subsequent capability load will see an invalid capability (tag = 0).

### Pipelining the Bounds Check for Zero-Cycle Overhead

The critical performance question is whether bounds checking adds latency to memory accesses. CHERI implementations overlap the bounds check with the existing TLB lookup:

```
   Pipeline Stage E0:   Instruction decode, extract capability register number
   Pipeline Stage E1:   AGU computes effective address from base+offset;
                         simultaneously begin bounds check (address - base)
   Pipeline Stage E2:   TLB lookup (virtual -> physical);
                         complete bounds check (compare against length)
   Pipeline Stage E3:   Cache access using physical address
   Pipeline Stage E4:   Data return / writeback
```

The bounds check — a 64-bit subtract (address - base_effective) followed by a 64-bit compare (result < length_effective) — completes in the same cycle as the TLB lookup. Since both the TLB hit signal and the bounds check result are needed before the cache access, no additional pipeline stage is required. The area cost is mainly in the integer comparator and subtractor for the bounds check, plus the tag storage throughout the memory hierarchy. On ARM's Morello prototype, the bounds check logic adds approximately 2% to the core area.

## 5. Formal Security Properties: Monotonicity, Integrity, and Confinement

CHERI's security guarantees can be formalized as properties of a capability machine — an abstract model of computation where all memory accesses are mediated by capabilities. These properties are not just design goals; they are theorems that can be (and have been) proven about the CHERI ISA formal model.

### The Monotonicity Theorem

**Theorem (Capability Monotonicity)**. For any sequence of capability operations starting from a valid capability C, all derived capabilities C' satisfy `authority(C') ⊆ authority(C)`, where `authority(C)` denotes the set of (address, permission) pairs permitted by C.

In simpler terms: capabilities never gain authority. You can only restrict, never expand. This is the fundamental property that makes CHERI's security compositional — if you reason about the maximum authority granted by any capability, you can bound what any derived capability can do.

**Proof sketch**. The CHERI ISA defines a finite set of capability-manipulating instructions: `CSetBounds`, `CSetAddr`, `CAndPerm`, `CSetOffset`, `CSeal`, `CUnseal`, and `CBuildCap`. For each instruction, we analyze its effect on the authority set:

1. **CSetBounds(c, new_length)**: Returns capability with bounds `[c.base_effective, c.base_effective + new_length_effective)`. Since `new_length_effective >= new_length` (representation over-approximation) and the new length is requested to be ≤ original length, the new bounds are a subset of the original bounds. Authority decreases monotonically.
2. **CSetAddr(c, new_addr)**: Returns capability with address set to `new_addr` but same bounds. If `new_addr` is outside the original bounds, the result is invalid (tag cleared). So valid results have authority ⊆ original.
3. **CAndPerm(c, perm_mask)**: Returns capability with permissions `c.perms & perm_mask`. The permission set is bitwise-and'd, so permissions can only be removed, never added.
4. **CSeal(c, otype)**: Returns a sealed capability. Sealed capabilities cannot be used for direct memory access, so authority decreases (all memory access is revoked).
5. **CUnseal(c)**: Requires the correct object type. If the caller has the unsealing authority, the original capability is returned; otherwise invalid. Authority does not increase beyond what was originally sealed.
6. **CBuildCap**: Produces a capability from in-memory representation, but requires that the memory location holds a valid capability with tag = 1 and appropriate permissions. This is not creation from nothing; it is a controlled materialization.

By case analysis over all instructions, the property holds. No instruction can produce a capability with authority not present in its input capabilities.

### Non-Forgeability and Tag Integrity

**Theorem (Capability Integrity)**. A valid capability (tag = 1) can only be produced by: (1) loading an existing valid capability from tagged memory via `CLoad`; (2) deriving from an existing valid capability via the narrowing instructions listed above; or (3) constructing via `CBuildCap` from tagged memory with appropriate permissions.

No sequence of arithmetic, logical, or ordinary load/store instructions can produce a value with tag = 1.

This property is enforced structurally. The ALU, shifter, multiplier, and other functional units operate on the 128-bit data value but unconditionally clear the output tag to 0. Only capability-specific functional units — the capability narrowing unit, capability load unit, and capability build unit — can assert the output tag to 1. This separation is enforced in the processor's data path, not in microcode or configurable logic.

### Confinement via Sealed Capabilities

Sealed capabilities provide a confinement guarantee that is stronger than traditional OS process isolation in an important way: compartments in the same address space are isolated by capabilities, not by page tables.

**Theorem (Compartment Confinement)**. Let compartment A hold a sealed capability S to compartment B's entry point. Let A hold no other capabilities that grant access to B's memory. Then A cannot read, write, or execute any memory within B's compartment except through calling S (which invokes B's code at B's designated entry point, running with B's capabilities).

**Proof**. The proof follows from four lemmas:

1. Sealed capabilities cannot be dereferenced — load and store instructions trap when given a sealed capability.
2. The only operation that transforms a sealed capability into a dereferenceable capability is `CUnseal`, which requires the correct object type. The object type is itself a capability-granted authority.
3. A compartment cannot forge object types — capabilities are non-forgeable (by the integrity theorem).
4. The indirect call through S transitions execution to B's entry point, and the CHERI ISA provides a `CInvoke` instruction that atomically unseals and jumps, loading B's capability registers.

This is a hardware-enforced implementation of the object-capability model, where sealed capabilities act as unforgeable object references. The key difference from software object-capability systems (like those in E or Joe-E) is that CHERI's enforcement is at the instruction level, not dependent on language-level type safety or runtime checks.

### Relation to the Take-Grant Protection Model

CHERI's capability model can be analyzed through the lens of the classic Take-Grant protection model. In the Take-Grant model, a system state is a directed graph where nodes are subjects/objects and edges are capabilities (with take and grant rights). The safety question — can a subject ever obtain a capability to an object for which it currently has no path in the graph? — is decidable in the Take-Grant model.

CHERI refines this model by replacing the abstract "take" and "grant" rights with concrete capability operations. The monotonicity theorem corresponds to the Take-Grant property that the graph edges can only shrink (capabilities can only be restricted). The integrity theorem corresponds to the property that new edges can only be created by copying existing edges through authorized paths, never from thin air. And confinement corresponds to the property that a subject with only a sealed capability to another subject cannot expand its authority beyond the transitive closure of its original capabilities.

This formal grounding gives CHERI a sound theoretical basis — its security properties are not empirical observations but mathematically provable guarantees of the ISA.

## 6. Spatial Safety: Bounds Checking in Hardware

CHERI enforces spatial memory safety by checking every capability-based memory access against the capability's bounds. When the program executes a load or store through a capability, the hardware checks: is the access address within [base, base+length)? If not, the hardware raises a capability violation exception, which the operating system can handle (terminating the process, delivering a signal, or logging the violation).

The bounds check is performed in parallel with the memory access, so it adds no latency to the critical path. The hardware extracts the base and length from the capability, computes the access bounds, and compares the access address — all in the same pipeline stage as the TLB lookup. For accesses within bounds, the overhead is zero. For out-of-bounds accesses, the hardware traps.

This eliminates buffer overflows by construction. If a function receives a capability to a 100-byte buffer, any attempt to access byte 101 will trap. No amount of pointer arithmetic can extend the capability's bounds — the capability's base and length are hardware-immutable after creation.

CHERI also maintains bounds through pointer arithmetic. When you add an offset to a capability, the result is still a capability with the same base and length but an updated address. If the offset would take the address outside the bounds, the capability is invalidated (its tag is cleared), and subsequent use will trap. This prevents out-of-bounds pointer arithmetic from producing a usable pointer.

## 7. Temporal Safety: Use-After-Free Prevention

Spatial safety alone doesn't prevent use-after-free — accessing memory after it has been deallocated. CHERI addresses temporal safety through a combination of capabilities and software memory management.

When memory is allocated (via `malloc` or `mmap`), the allocator creates a capability with bounds covering the allocated region and returns it to the caller. The caller uses this capability for all accesses to the allocated memory. When the memory is freed, the allocator revokes the capability — it communicates to the hardware that all capabilities pointing to the freed memory should be invalidated.

CHERI provides hardware support for capability revocation through "capability sweeping." The operating system maintains a list of capabilities associated with each memory allocation. When the allocation is freed, the OS sweeps the capability list, clearing the tags on all capabilities that reference the freed region. This is not instantaneous (sweeping large capability lists can take time), but it provides eventual temporal safety: once the sweep completes, any remaining dangling capabilities will trap on use.

A more fine-grained approach uses CHERI's "sealed capabilities" for memory reclamation. The allocator hands out a sealed capability that must be unsealed (using a special unseal instruction that checks the object type) before it can be used. When the memory is freed, the allocator changes the seal type, preventing any outstanding sealed capabilities from being unsealed. This provides immediate temporal safety for the sealed capability model.

## 8. Referential Safety and Control-Flow Integrity

CHERI capabilities extend beyond data pointers to code pointers (function pointers, return addresses, vtable pointers). A function pointer in CHERI is a capability with Execute permission, and its bounds are the extent of the function's code. If an attacker overwrites a function pointer, they can only redirect execution to code within the targeted function — they cannot jump to arbitrary addresses, ROP gadgets, or injected code.

CHERI provides fine-grained control-flow integrity (CFI) through "sealed capabilities" for return addresses. When a function is called, the return address is stored as a sealed capability on the stack. The function prologue saves the sealed return capability; the epilogue unseals it and jumps to it. An attacker who overwrites the return address with raw data cannot forge a valid sealed capability (because they can't set the tag bit), so their overwrite will trap on return.

For indirect calls (C++ virtual methods, function pointer calls), CHERI uses "sentinel capabilities" — special capabilities that can be called but not read or written. The compiler emits a sentinel capability for each legitimate indirect call target. The function pointer table contains only these sentinels. An attacker who overwrites a function pointer with an arbitrary value will produce an invalid capability that traps on use.

These CFI protections, combined with spatial safety, eliminate the vast majority of control-flow hijacking attacks. Return-oriented programming (ROP), jump-oriented programming (JOP), and vtable pointer overwrites all rely on the ability to forge valid code pointers, which CHERI prevents.

## 9. Compartmentalization: Least Privilege at Scale

Beyond memory safety, CHERI enables fine-grained software compartmentalization — splitting a monolithic program into mutually distrusting components that communicate through tightly controlled interfaces. This is essentially capability-based security at the software architecture level.

A CHERI compartment is a protection domain with its own set of capabilities. A compartment can access only the memory, code, and capabilities that have been explicitly delegated to it. Two compartments in the same address space cannot access each other's data unless a capability has been passed between them. This is much finer-grained than traditional process-based isolation (where each process has its own address space) and much cheaper (compartment switches are function calls, not context switches).

CHERI compartments communicate through "sealed capabilities." A compartment that wants to provide a service (say, a decompression library) seals a capability to its entry point with a unique object type. The client compartment receives this sealed capability and can call it (using the unseal-on-call instruction), but cannot read or modify the decompression library's internal data. The sealed capability is an unforgeable token that grants access to a specific service with well-defined semantics.

The performance of compartmentalization is critical for adoption. A CHERI compartment switch — calling from one compartment to another — is essentially a function call with a few extra instructions to validate and unseal capabilities. On current CHERI implementations, this costs less than 10 cycles added to the function call overhead. Compare this to a context switch between processes (thousands of cycles) or even a syscall (hundreds of cycles), and CHERI compartmentalization is dramatically cheaper. This enables a programming model where libraries, plugins, and even individual data structures are isolated by default, without the performance penalty of traditional IPC.

## 10. The Morello Prototype and CHERI-RISC-V

ARM's Morello prototype, announced in 2019 and shipped to researchers in 2022, is a quad-core ARM processor with CHERI extensions. It is based on the ARM Neoverse N1 (a server-class core) and implements the full CHERI capability model. The Morello board runs a CHERI-extended version of FreeBSD (CheriBSD) and can execute unmodified ARMv8 binaries alongside CHERI-aware binaries.

CheriBSD demonstrates that CHERI can be incrementally adopted. Existing C/C++ code compiles to CHERI binaries with minimal source changes (the compiler automatically uses capabilities for all pointers). The developer adds capability annotations where they want fine-grained bounds or compartmentalization. Libraries can be CHERI-fied one at a time. The CheriBSD kernel itself has been partially CHERI-fied, using capabilities for internal data structures and user-kernel boundary crossing.

The CHERI-RISC-V specification extends the RISC-V ISA with capabilities, following the same design principles as CHERI-ARM. RISC-V's open nature makes CHERI-RISC-V an attractive target for research and niche applications (aerospace, industrial control, secure enclaves). The specification is being standardized through the RISC-V Foundation's CHERI task group.

## 11. Performance Overhead and Trade-offs

CHERI's performance overhead depends on the workload. For most C/C++ code, the overhead is modest:

- **Capability tag memory**: Each 128 bits of capability require 1 bit of tag storage. This adds approximately 0.8% memory overhead (1 bit per 16 bytes). The tag memory is stored alongside the data memory, typically in ECC bits or in dedicated SRAM, so it doesn't reduce usable memory capacity on most systems.

- **Bounds checking**: The bounds check is performed in parallel with the TLB lookup and adds zero cycles to the critical path for in-bounds accesses. Out-of-bounds accesses trap, but these are the exception, not the common case.

- **Capability narrowing**: Narrowing a capability (reducing its bounds) requires a few instructions to compute new base and length, set the appropriate fields, and revalidate the capability. For `memcpy` and similar functions that narrow capabilities for sub-buffer access, this adds 2-3 instructions compared to raw pointer arithmetic.

Overall, CHERI's performance overhead on real hardware is estimated at 3-8% for typical server workloads, with some workloads seeing higher overhead (10-15%) due to frequent capability narrowing or capability load/store operations. This is comparable to the overhead of other memory safety mechanisms like AddressSanitizer (ASan, which adds ~73% overhead) or memory tagging (MTE, which adds ~3-8% overhead). Unlike ASan, CHERI's safety guarantees are production-strength: they cannot be bypassed by an attacker who controls the program's execution.

## 12. Summary

CHERI represents a fundamental rethinking of the hardware-software security interface. By replacing raw pointers with unforgeable, bounds-checked capabilities, CHERI eliminates the root cause of spatial memory safety vulnerabilities — the ability to forge or corrupt pointers. By extending capabilities to code pointers, CHERI provides control-flow integrity that defeats ROP, JOP, and related attacks. And by enabling fine-grained compartmentalization with near-zero performance overhead, CHERI makes the principle of least privilege practical at the software component level.

The CHERI architecture has moved from academic research to industrial prototype (ARM Morello) to standards track (CHERI-RISC-V). The UK government's Digital Security by Design initiative, backed by 70 million pounds of funding, aims to accelerate CHERI adoption across the technology industry. If successful, CHERI could do for memory safety what hardware memory protection (paging, segmentation) did for process isolation: make it a ubiquitous, hardware-enforced foundation that all software builds on.

The vision is ambitious: a world where buffer overflows, use-after-free, and control-flow hijacking are not just mitigated but eliminated by construction. CHERI won't solve all security problems — logic errors, side channels, and supply chain attacks remain — but it addresses the largest single category of exploitable vulnerabilities. That's a prize worth pursuing.

## 13. CHERI for Existing Codebases: The Porting Experience

One of the most impressive aspects of CHERI is its compatibility story. The CHERI Clang/LLVM compiler can compile unmodified C and C++ code to CHERI binaries, automatically using capabilities for all pointer types. The programmer does not need to annotate every pointer — the compiler does the heavy lifting.

However, C's type system often erases bounds information. A function that takes a `char *buf` pointer receives a capability with whatever bounds the caller passed, but the function signature doesn't specify the expected bounds. CHERI addresses this through a combination of compiler heuristics (inferring bounds from allocations, array declarations, and `malloc` size arguments) and programmer annotations (`__attribute__((cheri_bounds(expression)))` enables explicit bounds specification when the compiler can't infer them).

Common C idioms that break with CHERI include: pointer-integer-pointer round-tripping (casting a capability to an integer and back strips the tag and metadata), custom memory allocators (which must be CHERI-aware to create capabilities with correct bounds), and variable-length arrays (where bounds depend on runtime values). The CHERI project has developed porting guides and tools (like the `cheri-crashdump` analyzer) that help developers identify and fix CHERI-related issues. The experience of porting CheriBSD (FreeBSD) to CHERI showed that most kernel code compiles without changes, but device drivers and memory management require CHERI-specific modifications.

## 14. Capability-Based Security Beyond Memory Safety

While memory safety is CHERI's headline feature, the capability model enables security properties that go far beyond bounds checking. Sealed capabilities enable "opaque pointers" — a library can return a sealed capability to the caller, which the caller can pass back to the library but cannot dereference or modify. This is a form of information hiding enforced by hardware.

CHERI compartments can implement the principle of least privilege at a granularity impossible with traditional MMU-based isolation. A JSON parser compartment receives a capability to the input buffer (read-only), a capability to the output parse tree buffer (write-only), and nothing else. Even if the parser contains a vulnerability that allows arbitrary code execution, the attacker cannot access the network, read files, or modify data outside the parser's explicitly delegated capabilities. This is the "least privilege" principle made practical — the compartment's authority is exactly what it needs and nothing more.

## 15. The CHERI Software Ecosystem

The CHERI software stack is maturing rapidly. CheriBSD, the CHERI-extended FreeBSD, provides a complete OS environment with CHERI-aware kernel, libc, and userland. The CheriBSD kernel itself is partially compartmentalized using CHERI capabilities. CheriBSD supports both pure-capability (CHERI) binaries and hybrid (capability-aware but with traditional pointers) binaries, allowing incremental adoption.

The CHERI software development kit includes: CHERI Clang/LLVM (compiler with CHERI extensions), CHERI GDB (debugger with capability-aware memory inspection), CHERI QEMU (emulator for CHERI-RISC-V and CHERI-ARM), and CHERI Test Suite (thousands of test cases validating capability semantics). These tools enable developers to target CHERI without physical CHERI hardware — development and testing can be done entirely in emulation.

## 16. CHERI and Formal Verification: The seL4-CHERI Connection

The combination of CHERI hardware with a formally verified kernel (seL4) represents perhaps the highest-assurance computing platform ever built. The seL4 microkernel has been formally verified to ensure functional correctness (no bugs), integrity (no unauthorized modification), and confidentiality (no unauthorized information flow). When seL4 runs on CHERI hardware, the kernel's verification is complemented by CHERI's hardware-enforced memory safety.

The seL4-CHERI combination enables a security architecture where: (1) the kernel is proven correct (verified by Isabelle/HOL), (2) user-space processes are isolated by CHERI capabilities (each process receives only the capabilities it needs), and (3) the kernel's own memory accesses are validated by CHERI (the kernel uses CHERI capabilities internally, so even a kernel bug — though proven not to exist — would be caught by CHERI if it somehow manifested). This is defense in depth at its finest: formal methods for the software, hardware enforcement for the hardware.

The DARPA HACMS program demonstrated the seL4-CHERI combination on a quadcopter drone. The drone's flight software was decomposed into isolated compartments (motor control, navigation, communication), each with CHERI capabilities restricted to its function. The motor control compartment could not access the network; the communication compartment could not control the motors. Formal verification of seL4 ensured the kernel's correctness; CHERI ensured that compartments could not exceed their authority. The result was a drone that could survive cyber attacks on its communication system without losing flight control — a level of assurance previously impossible.

## 17. The Economics of Memory Safety

The CHERI project raises an important economic question: how much should we pay for memory safety? CHERI hardware adds area (for capability tag storage), power (for bounds checking on every memory access), and complexity (new instructions, new exception types) to the processor. The performance overhead is 3-8% for most workloads. Are these costs justified by the security benefits?

Microsoft's security team estimates that 70% of all Windows vulnerabilities are memory safety bugs. Google's Project Zero reports similar numbers for Android and Chrome. The annual cost of these vulnerabilities — in patching, incident response, and data breaches — runs into billions of dollars globally. CHERI's 3-8% overhead means that a datacenter of 100,000 servers running CHERI would effectively "lose" 3,000-8,000 servers' worth of compute capacity to the overhead. But the cost of a single major breach can exceed the cost of thousands of servers.

The ARM Morello evaluation program is gathering data on this trade-off. Early results suggest that for security-critical workloads (cloud isolation, browser sandboxing, IoT firmware), CHERI's overhead is more than justified by the reduction in attack surface. For compute-bound batch workloads, the overhead may not be worth it. The future is likely a heterogeneous deployment: CHERI for security-critical services, traditional processors for throughput-optimized batch processing, with the software ecosystem supporting both.

## 18. CHERI and the Future of Secure Computing

CHERI represents a bet that hardware-enforced memory safety is worth the cost. The bet is not yet fully validated — Morello is a prototype, not a product — but the early results are encouraging. The Digital Security by Design program is funding the development of a CHERI-based system-on-chip (Arm's Morello-based SoC) and the adaptation of critical software (FreeBSD, PostgreSQL, nginx) to take advantage of CHERI capabilities.

The long-term vision is a multi-layered security architecture: CHERI provides spatial memory safety and compartmentalization at the hardware level; seL4 (or a verified hypervisor) provides formal guarantees at the kernel level; language-level safety (Rust, safe C/C++ subsets) prevents logic errors; and application-level policies (capability grants, compartment boundaries) enforce the principle of least privilege. Each layer provides defense in depth — if one layer fails, the others still protect.

This vision is ambitious but achievable. All the pieces exist in prototype form. The challenge is engineering them into production-quality, cost-effective products that can be deployed at scale. The CHERI project, now in its second decade, is steadily chipping away at this challenge. If it succeeds, the computing landscape will be fundamentally safer — memory safety bugs, which have plagued software for half a century, will be caught at the hardware level before they can become exploits.

## 19. CHERI and Temporal Memory Safety: Cornucopia and CHERIvoke

While CHERI provides strong spatial safety (bounds checking), temporal safety (use-after-free prevention) requires additional mechanisms. The Cornucopia project at Microsoft Research extends CHERI with "temporal capabilities" that include a generation number. When memory is allocated, it receives a capability with a unique generation. When the memory is freed, the generation is invalidated. Any attempt to access the memory through a stale capability (with the old generation) traps. This is similar to the "generational references" approach in the Vale language, but enforced by hardware rather than software.

The CHERIvoke project explores asynchronous memory reclamation for CHERI. In a traditional system, freeing memory is synchronous — the allocator marks the memory as free and returns. With CHERIvoke, the allocator sweeps capabilities lazily, clearing tags on dangling capabilities as a background task. This is analogous to RCU (Read-Copy-Update) in the Linux kernel: the memory is logically freed immediately (no new references can be created), but physical reclamation is deferred until all existing references have been detected and invalidated. CHERIvoke makes use-after-free exploitation impossible by guaranteeing that any dangling capability will trap, while keeping the allocation fast path lightweight.

These temporal safety extensions to CHERI demonstrate that capabilities can address both spatial and temporal memory safety. Combined with compartmentalization, they provide a comprehensive memory safety architecture that covers the four major classes of memory errors: spatial (buffer overflow), temporal (use-after-free), type confusion (through sealed capabilities), and information leakage (through capability bounds).

## 20. CHERI in the Cloud: Multi-Tenant Isolation at Microsecond Granularity

CHERI compartments enable a new model of cloud isolation that is finer-grained and faster than VM-based or container-based isolation. A cloud provider could run multiple tenants' code in the same process, with each tenant's library (or even individual function) isolated in its own CHERI compartment. Cross-compartment calls are function calls (tens of cycles), not context switches (thousands of cycles). This enables "microservice isolation at library granularity" — each library gets exactly the capabilities it needs, and a vulnerability in one library cannot affect others.

Microsoft's Verona project (a research language and runtime for safe infrastructure) is exploring this model. In Verona, each "cown" (concurrent owner, a unit of isolation) runs in a CHERI compartment with its own set of capabilities. Cowns communicate through message passing, with the messages being capabilities that grant access to shared data. The CHERI hardware enforces that a cown cannot access data outside its explicitly granted capabilities. This is the actor model implemented with hardware-enforced isolation.

The economic implications are significant. If a cloud provider can pack 10x more tenants per server (by replacing heavy VM isolation with lightweight CHERI compartment isolation), the cost per tenant drops proportionally. CHERI's fine-grained isolation could be the key to making confidential computing economically viable at scale, rather than a premium feature for security-conscious customers.

## 21. Summary

CHERI represents a fundamental rethinking of the hardware-software security interface. By replacing raw pointers with unforgeable, bounds-checked capabilities, CHERI eliminates the root cause of spatial memory safety vulnerabilities. By extending capabilities to code pointers, CHERI provides control-flow integrity that defeats ROP and JOP attacks. And by enabling fine-grained compartmentalization with near-zero performance overhead, CHERI makes the principle of least privilege practical at the software component level. The CHERI architecture has moved from academic research to industrial prototype (ARM Morello) to standards track (CHERI-RISC-V), and its influence on processor design will likely grow as the cost of memory safety vulnerabilities continues to mount.

## 22. CHERI and the C++ Object Model: Challenges of Inheritance and Virtual Functions

C++ poses unique challenges for CHERI because of its complex object model. Virtual function calls, multiple inheritance, virtual base classes, and dynamic_cast all involve pointer manipulations that must be CHERI-aware. Consider a virtual function call: the vtable pointer in the object header is a pointer to an array of function pointers. In CHERI, the vtable pointer must be a capability with Execute permission, and the individual function pointers within the vtable must also be capabilities. The compiler must generate code that constructs these capabilities correctly and validates them on use.

Multiple inheritance requires pointer adjustments (the "this" pointer for a base class may be at a different offset than for the derived class). In CHERI, adjusting a capability also adjusts its bounds — the adjusted capability must have bounds that cover only the base class subobject, not the entire derived object. The compiler must insert capability narrowing instructions at each pointer adjustment point, which adds overhead but ensures that a virtual function call through a base class pointer cannot access memory outside the base class subobject.

CHERI's C++ support is implemented in the CHERI Clang compiler through a combination of compiler transformations and runtime support. The compiler generates capability-aware code for all pointer manipulations, and the runtime (libcheri) provides helper functions for operations like dynamic_cast (which requires walking the class hierarchy and comparing type information stored as capabilities). The performance overhead of CHERI for C++ code is higher than for C (10-15% for C++ vs 5-8% for C) due to the additional capability narrowing and validation at each pointer cast. But the security benefits — spatial safety for all C++ objects, CFI for all virtual calls — are correspondingly greater.

## 23. CHERI and the Linux Kernel: Porting Challenges and Solutions

Porting the Linux kernel to CHERI is an enormous undertaking — the kernel is millions of lines of C that make extensive use of pointer arithmetic, type punning, and custom memory allocators, all of which must be CHERI-aware. The CHERI-Linux project (part of the UK's Digital Security by Design program) is tackling this challenge, with the goal of running an unmodified Linux userspace on a CHERI-capable kernel.

The kernel's memory allocator (`kmalloc`, `vmalloc`, the slab allocator) must create CHERI capabilities for every allocation. The `kmalloc` function now returns a capability with bounds covering exactly the requested size, not the underlying slab page. This requires changes to the slab allocator to track per-object bounds and to create capabilities with precise bounds when objects are handed out. The `copy_from_user` and `copy_to_user` functions must validate that the user-space pointer's bounds cover the requested transfer size before performing the copy.

Device drivers are the hardest part to port. Drivers often use `ioremap` to map device MMIO regions into the kernel's address space, and then perform pointer arithmetic on the mapped addresses. In CHERI, `ioremap` returns a capability with bounds covering the MMIO region, and pointer arithmetic must stay within those bounds. Driver code that casts between integer types and pointer types (a common pattern in DMA programming) must be rewritten to use proper capability operations. The CHERI-Linux project provides a set of helper macros (`cheri_ptr`, `cheri_bounds_set`, `cheri_perms_and`) that drivers can use to manipulate capabilities safely. The porting effort is ongoing, and it's expected that a fully CHERI-ized Linux kernel will take several more years of work.

## 24. The CHERI Investment Thesis: Why Governments and Industry Are Betting on Capabilities

The UK government's Digital Security by Design (DSbD) program has invested over 200 million GBP in CHERI technology, making it one of the largest government investments in computer architecture research in decades. The investment thesis is straightforward: memory safety vulnerabilities cost the global economy hundreds of billions of dollars annually in patching, incident response, and data breaches. A hardware solution that eliminates 70% of these vulnerabilities, with 3-8% performance overhead, has an enormously positive return on investment. The DSbD program aims to prove that CHERI works at scale, catalyzing industry adoption and eventually making CHERI-based processors the default for safety-critical and security-sensitive applications.

Beyond the UK, the United States Department of Defense has also invested in CHERI research through DARPA's HACMS and CHERI-related programs, recognizing that memory safety is a matter of national security. The European Union's Horizon Europe framework has funded CHERI research through multiple cybersecurity initiatives, and Japan's NEDO has explored CHERI for industrial control systems. This multinational investment reflects a growing consensus that software-only approaches to memory safety — static analysis, fuzzing, sanitizers — have reached diminishing returns, and that a hardware-software co-designed solution is necessary to break the cycle of vulnerability discovery, patching, and exploitation. The analogy often drawn is to the automotive industry, where seat belts and airbags (software mitigations) are essential but crumple zones and reinforced frames (hardware enforcement) provide the foundational protection that makes everything else more effective.

ARM's participation in the Morello program signals that the semiconductor industry is taking CHERI seriously. If Morello demonstrates that CHERI's overhead is acceptable and its compatibility story is workable, it's plausible that future ARM architectures will include CHERI extensions as a standard feature — much like virtualization extensions (VT-x, ARM Virtualization Extensions) transitioned from optional to mandatory over a decade. The RISC-V CHERI standardization effort ensures that CHERI is not tied to a single ISA vendor, which is essential for broad adoption. If CHERI succeeds, it will be one of the most significant improvements to computer security since the introduction of protected memory (paging, segmentation) in the 1960s.

CHERI is not just a research project or a government bet — it is a fundamental re-examination of the hardware-software contract. For decades, we accepted that processors would execute whatever instructions they were given, regardless of whether those instructions violated memory safety. CHERI says: the processor should enforce memory safety at the instruction level, and no amount of buggy or malicious software should be able to bypass that enforcement. That is a vision worth building.
