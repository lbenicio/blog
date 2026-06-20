---
title: "Building A Custom Risc V Processor In Verilog: Pipelining, Hazard Detection, And Branch Prediction"
description: "A comprehensive technical exploration of building a custom risc v processor in verilog: pipelining, hazard detection, and branch prediction, covering key concepts, practical implementations, and real-world applications."
date: "2020-10-28"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/building-a-custom-risc-v-processor-in-verilog-pipelining,-hazard-detection,-and-branch-prediction.png"
coverAlt: "Technical visualization representing building a custom risc v processor in verilog: pipelining, hazard detection, and branch prediction"
---

# From Silicon to Software: Building a High-Performance RISC-V CPU in Verilog

The modern programmer lives in a world of astonishing abstraction. You write a line of code in Python, JavaScript, or Go, and through a magnificent tower of compilers, linkers, operating systems, and microarchitectures, that text is transformed into a cascade of electrons dancing through billions of transistors. The result is so reliable, so instantaneous, that we treat it as magic. But scratch beneath the surface, and the most fascinating part of this magic trick is the engine at its core: the Central Processing Unit (CPU). For decades, the internal architecture of this engine was a closely guarded secret, locked behind patents and corporate walls. But with the rise of RISC-V, the world of processor design has been democratized. Now, anyone with a laptop, a bit of patience, and a desire to truly understand computing can build their own CPU.

This post is a deep dive into that process. We are going to build a custom RISC-V processor from scratch using Verilog. But we aren’t just building a toy. We are going to tackle the three most critical and challenging concepts that separate a simple, slow processor from a modern, high-performance one: **Pipelining**, **Hazard Detection**, and **Branch Prediction**.

Before we get our hands dirty with the hardware description language (HDL), we need to understand _why_ this matters. The instruction set architecture (ISA) defines the contract between the software and the hardware—it tells the computer _what_ to do. The microarchitecture, however, defines _how_ it is done. RISC-V, being a clean, modular, and open ISA, is the perfect substrate for this exploration. Its simplicity allows us to focus on the architectural decisions without getting bogged down by decades of legacy baggage (looking at you, x86). By building a pipelined processor, we are not just following a tutorial; we are reliving the very evolution of computer architecture that occurred in the 1980s and 1990s, solving the same problems that engineers back then solved. And today, we have the tools and open-source ecosystems to actually implement these designs on real FPGAs or simulate them with astonishing accuracy.

---

## 1. Why Build a CPU? The Democratization of Hardware

In the past, designing a CPU required a team of PhDs, millions of dollars in EDA (Electronic Design Automation) tools, and a foundry willing to fabricate your chip. The barriers were insurmountable for hobbyists and even most academics. Then three things happened:

1. **Open-source instruction sets** – RISC-V emerged from UC Berkeley in 2010, offering a royalty-free, modular ISA. No patents, no licensing fees, just clean specifications.
2. **Open-source hardware description languages and tools** – Verilator, Icarus Verilog, and later the rise of open-source PDK (Process Design Kits) like SkyWater 130nm made it possible to simulate and even tape out chips for a few thousand dollars.
3. **Affordable FPGAs** – Boards like the Lattice iCEstick, the Digilent Arty, or the Xilinx Artix-7 families put tens of thousands of LUTs (Look-Up Tables) in the hands of students and makers for under $100.

Now, building a CPU is within reach. But why should a software engineer care? Because understanding the microarchitecture of the processor you run your code on unlocks a deeper level of performance reasoning. It explains why certain code patterns are fast, why branches matter, why cache misses hurt, and why modern compilers optimize the way they do. It is the ultimate systems knowledge.

In this article, we will build a RISC-V processor step by step. We start with the simplest possible design: a single-cycle CPU that executes one instruction per clock cycle. Then we transform it into a five-stage pipelined beast, adding hazard detection and branch prediction to keep it fed and efficient. Along the way, we will write Verilog code, simulate it, and discuss the trade-offs. By the end, you will have a complete, synthesizable processor that can run real RISC-V programs.

---

## 2. RISC-V Basics: The Instruction Set Architecture

RISC-V is a reduced instruction set computer architecture. Unlike x86, which has instructions ranging from 1 to 15 bytes, RISC-V has fixed-length 32-bit instructions in its baseline (RV32I). This simplicity is a gift to hardware designers: each instruction can be decoded uniformly, and the datapath can be built around a few simple patterns.

The RV32I base integer instruction set includes:

- **Arithmetic/Logical**: `add`, `sub`, `and`, `or`, `xor`, `sll`, `srl`, `sra`, `slt`, `sltu`
- **Immediate versions**: `addi`, `andi`, `ori`, `xori`, `slli`, `srli`, `srai`, `slti`, `sltiu`
- **Load/Store**: `lb`, `lh`, `lw`, `lbu`, `lhu`, `sb`, `sh`, `sw`
- **Branches**: `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu`
- **Jump**: `jal`, `jalr`
- **Upper immediate**: `lui`, `auipc`

Plus a few system instructions (`ecall`, `ebreak`, `fence`). There are only about 50 instruction flavors. Compare that to the thousands in x86. This minimalism makes RISC-V ideal for teaching and for custom hardware.

Each instruction is encoded into fields: opcode, rd (destination register), funct3, rs1, rs2, and funct7 for R-type; imm, rs1, funct3, rd, opcode for I-type; etc. The encoding is designed to be easily decoded: the opcode always occupies bits [6:0], the two source registers are always at bits [19:15] and [24:20], and the destination register is always at bits [11:7]. This regularity is deliberate—it allows the register file to be read and written in parallel with instruction decode.

For this project, we will implement only the RV32I base set, which is Turing-complete. You can write any program with it, including loops, conditionals, and function calls. We will also support the `mul` extension later if we want multiplication, but for now, integer addition and subtraction suffice.

---

## 3. The Single-Cycle CPU: A Naive Baseline

Before we pipeline, we need a working processor that executes one instruction per clock cycle. In a single-cycle design, the entire instruction—fetch, decode, execute, memory access, writeback—happens within one clock period. The clock period must be long enough to accommodate the longest critical path, which typically is a load instruction: read register file, add immediate, read data memory, write back to register file. This simplicity makes the control logic trivial, but the performance is abysmal because even simple instructions like `add` take as long as a `lw`, wasting most of the cycle.

Let’s outline the datapath:

- **Program Counter (PC)**: Register holding current instruction address.
- **Instruction Memory (IMem)**: Reads 32-bit instruction at PC.
- **Register File**: 32 registers, each 32 bits. Two read ports (rs1, rs2) and one write port (rd).
- **ALU**: Performs arithmetic and logical operations based on funct3 and funct7.
- **Data Memory (DMem)**: Accessed by load and store instructions. Single read/write port.
- **Control Unit**: Decodes opcode and funct fields to generate control signals: RegWrite, ALUSrc, MemRead, MemWrite, MemtoReg, Branch, Jump, ALUOp.

The control signals steer the muxes and enable memory writes. For example, if the instruction is `add x1, x2, x3` (R-type), ALUSrc = 0 (take second operand from register), RegWrite = 1, MemRead = 0, MemWrite = 0, MemtoReg = 0 (write ALU result to register), etc.

We can implement this in Verilog as a single always_comb block for combinational logic, plus registers for PC and the register file. But because the critical path is long, the maximum clock frequency is low. For a simple FPGA like iCE40, maybe 20–30 MHz. That’s fine for a demo, but not for high performance.

**Verilog snippet for single-cycle control unit:**

```verilog
always_comb begin
    case (opcode)
        OPCODE_R_TYPE: begin
            reg_write = 1'b1;
            alu_src   = 1'b0;  // register
            mem_read  = 1'b0;
            mem_write = 1'b0;
            mem_to_reg= 1'b0;
            branch    = 1'b0;
            jump      = 1'b0;
            alu_op    = 2'b10; // use funct
        end
        OPCODE_I_TYPE: begin
            reg_write = 1'b1;
            alu_src   = 1'b1;  // immediate
            mem_read  = 1'b0;
            mem_write = 1'b0;
            mem_to_reg= 1'b0;
            branch    = 1'b0;
            jump      = 1'b0;
            alu_op    = 2'b11; // immediate type
        end
        // ... other cases
    endcase
end
```

But we are not going to dwell on the single-cycle design. It’s a stepping stone. The real fun begins when we split the execution into stages: **pipelining**.

---

## 4. Pipelining: The Principle of Overlap

Pipelining is the hardware equivalent of an assembly line. Instead of waiting for one instruction to finish completely before starting the next, we break the execution into stages and let multiple instructions coexist in different stages. The classic five-stage RISC pipeline is:

1. **IF (Instruction Fetch)** – Fetch instruction from memory using PC.
2. **ID (Instruction Decode)** – Decode instruction, read register file.
3. **EX (Execute)** – Perform ALU operation or calculate address.
4. **MEM (Memory Access)** – Read or write data memory.
5. **WB (Write Back)** – Write result back to register file.

Each stage takes one clock cycle. In an ideal pipeline, the throughput becomes one instruction per cycle (IPC = 1), and latency increases to 5 cycles. But the clock period is now determined by the slowest _stage_, not the entire instruction. The critical path is much shorter, so we can crank up the clock frequency. A five-stage pipeline can run 3–5 times faster than a single-cycle design, achieving a net performance gain of 3–5x.

However, pipelining introduces complications. The stages are independent in hardware, but instructions depend on each other. The classic problem: if instruction i writes to register x1, and instruction i+1 reads x1, then in the pipeline, instruction i+1 may read the old value before i has written it. This is a **data hazard**. Similarly, branches change the flow of instructions; a taken branch means the instructions already fetched after it are wrong—a **control hazard**. Pipelining also creates structural hazards (two instructions wanting the same resource at the same time), but RISC-V’s separated instruction and data memories (Harvard architecture in this simple design) avoids most of them.

We will deal with all three. But first, let’s build the five-stage pipeline.

---

## 5. Building the Five-Stage Pipeline in Verilog

We need to insert pipeline registers between each stage to hold the intermediate results. The pipeline registers are triggered by the positive edge of the clock. Each stage reads from its input register, processes, and writes to the next pipeline register.

Let’s define the pipeline registers:

- **IF/ID:** holds the fetched instruction and PC+4.
- **ID/EX:** holds decoded instruction fields, register values, immediate, and control signals.
- **EX/MEM:** holds ALU result, second register value for stores, and control signals.
- **MEM/WB:** holds memory read data or ALU result, and write-back control.

The control signals are generated in the ID stage and then propagated through the pipeline so that each stage knows what to do. For example, the WB stage needs the `reg_write` signal to know if it should write to the register file.

In Verilog, we can implement the pipeline as a series of `always_ff @(posedge clk)` blocks. But we must also handle stalls and flushes, which we will add later.

**Simplified ID/EX pipeline register:**

```verilog
always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
        id_ex_pc         <= 32'b0;
        id_ex_rs1_val    <= 32'b0;
        id_ex_rs2_val    <= 32'b0;
        id_ex_imm        <= 32'b0;
        id_ex_rd         <= 5'b0;
        id_ex_control    <= 9'b0;
    end else if (stall) begin
        // hold values (stall)
    end else begin
        id_ex_pc         <= id_pc;         // from ID stage
        id_ex_rs1_val    <= regfile[rs1];
        id_ex_rs2_val    <= regfile[rs2];
        id_ex_imm        <= imm;
        id_ex_rd         <= rd;
        id_ex_control    <= control_signals;
    end
end
```

The EX stage reads `id_ex_*` inputs and computes the ALU result. The MEM stage reads `ex_mem_*` and accesses data memory. The WB stage reads `mem_wb_*` and writes back.

This structure works fine for a simple pipeline with no hazards. But as soon as we run actual code, we will run into problems.

---

## 6. Data Hazards: The Problem of Dependencies

Consider this sequence:

```
add x1, x2, x3   // R[1] = R[2] + R[3]
add x4, x1, x5   // R[4] = R[1] + R[5]
```

In a sequential processor, the first `add` writes x1 in cycle 5 (after WB). The second `add` reads x1 in cycle 2 (ID stage). So when the second instruction reaches ID, the first has not yet written x1. The second instruction will read the old value of x1—a data hazard.

There are three types of data hazards:

- **RAW (Read After Write):** The most common. The current instruction reads a register that a previous instruction will write. This is what we just saw.
- **WAR (Write After Read):** A previous instruction reads a register that a later instruction writes. In a simple in-order pipeline, WAR cannot happen because writes occur only after reads (WB is the last stage). However, with out-of-order execution, it can.
- **WAW (Write After Write):** Two instructions write the same register, the first write could be overwritten before the second. In our five-stage pipeline, WAW cannot happen because we write in WB in order. But with multiple functional units, it could.

For our design, we only need to handle RAW hazards.

**Solution 1: Stalling (Bubbles)**

The simplest fix is to stall the pipeline until the dependency is resolved. When the ID stage detects that a source register of the current instruction will be written by a previous instruction that hasn't reached WB yet, it inserts a bubble (NOP) and freezes the PC and IF/ID register. We call this a **pipeline stall** or **interlock**.

The hazard detection unit checks:

- Is the current instruction (in ID) reading a register that the instruction in EX is going to write?
- Is the instruction in MEM also going to write it?

If yes, and if the EX instruction is an R-type or I-type (writes rd), then we stall for as many cycles as needed. For an ALU instruction, the result is available after EX (i.e., at the end of EX). So we need to stall one cycle (the EX stage will compute, then the MEM stage will hold it, then the WB stage writes in the next cycle). Actually, we could forward the result from the EX stage directly to the EX stage of the next instruction—that is **forwarding**.

**Solution 2: Forwarding (Bypassing)**

Forwarding is the most elegant way to resolve data hazards. Instead of waiting for the register file write, we add multiplexers in the ALU inputs that can pick the result from the EX, MEM, or WB stages if it matches the required register. For an ALU instruction, the result is ready at the end of EX, so we can forward it to the next instruction’s EX stage in the same cycle. This eliminates the need for stalls for ALU-to-ALU dependencies.

Let’s implement forwarding in Verilog. We need to check:

- In the EX stage, for the current instruction, compare the source register addresses (rs1 and rs2) with the destination register addresses (rd) of the instructions in the EX/MEM and MEM/WB pipeline registers.
- If there is a match and the previous instruction writes a register (RegWrite = 1), then select the forwarded value instead of the register file value.

We also must handle the case where the forwarded value comes from a load instruction—because memory data is not ready until the end of MEM. For a load followed by an ALU that uses the loaded value, we still need a one-cycle stall (a **load-use hazard**). But we can forward after that stall.

**Verilog forwarding logic (partial):**

```verilog
always_comb begin
    // Default: use register file values
    alu_src1 = id_ex_rs1_val;
    alu_src2 = (id_ex_alu_src) ? id_ex_imm : id_ex_rs2_val;

    // Forward from EX/MEM
    if (ex_mem_reg_write && ex_mem_rd != 0 && ex_mem_rd == id_ex_rs1)
        alu_src1 = ex_mem_alu_result;
    if (ex_mem_reg_write && ex_mem_rd != 0 && ex_mem_rd == id_ex_rs2 && !id_ex_alu_src)
        alu_src2 = ex_mem_alu_result;

    // Forward from MEM/WB
    if (mem_wb_reg_write && mem_wb_rd != 0 && mem_wb_rd == id_ex_rs1)
        alu_src1 = mem_wb_result;  // either ALU or memory data
    if (mem_wb_reg_write && mem_wb_rd != 0 && mem_wb_rd == id_ex_rs2 && !id_ex_alu_src)
        alu_src2 = mem_wb_result;
end
```

This forwarding handles RAW hazards for ALU-to-ALU and ALU-to-store. For load-use, we insert a bubble:

```verilog
// Hazard detection for load-use
if (id_ex_mem_read && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2))
    stall = 1;
```

When stall is asserted, we freeze the PC and insert a NOP in the ID/EX register (set control signals to 0). The bubble propagates through EX and MEM, and after one cycle the load result is available for forwarding.

---

## 7. Control Hazards: The Branch Problem

Branch instructions change the program counter. In a pipeline, we fetch instructions sequentially; when a branch is taken, the instructions already fetched after the branch are incorrect—we need to flush them and fetch from the branch target.

We can detect a branch in the EX stage (after computing the condition and target address). But by then, two instructions (the branch and the next) have been fetched (IF and ID). So we must flush the IF/ID and ID/EX registers when a branch is taken. That introduces a penalty of 2 cycles (i.e., two bubbles). This is called a **control hazard**.

To reduce the penalty, we can move branch resolution earlier—to the ID stage. We can compute the branch target and condition using the register values read in ID (which are the correct values if there are no data hazards). If we resolve in ID, we only need to flush one instruction (the one in IF). That gives a penalty of 1 cycle. But it requires a separate adder for the branch target and a comparator, which is cheap.

However, even with early resolution, every branch costs one cycle if taken. For a pipeline with many branches (like a loop), this hurts performance. That’s where **branch prediction** comes in.

---

## 8. Branch Prediction: Reducing the Cost of Taking Branches

Instead of assuming branches are not taken (which would flush on taken), we can predict the outcome. If we guess correctly, no penalty. If we guess wrong, we flush and pay the penalty. The goal is to have a high prediction accuracy to keep the pipeline full.

There are two types of branch prediction:

- **Static prediction:** Always predict taken, or always predict not taken, or predict based on branch direction (e.g., backward branches are likely taken—loops).
- **Dynamic prediction:** Use a history table to store recent outcomes of branches. A simple 2-bit saturating counter predicts based on last few outcomes.

We’ll implement a simple 2-bit dynamic predictor using a Branch History Table (BHT) indexed by the lower bits of the PC. Each entry is a 2-bit state machine:

- 00: Strongly not taken
- 01: Weakly not taken
- 10: Weakly taken
- 11: Strongly taken

When a branch is resolved, we update the state: if taken, increment (saturate at 11); if not taken, decrement (saturate at 00). The prediction is taken if state >= 10.

We also need a Branch Target Buffer (BTB) to store the target address of previously taken branches, so we don’t have to recompute it. For simplicity, we can compute the target in the ID stage anyway, but the BTB allows us to fetch from the predicted target in the IF stage directly.

**Implementation sketch:**

- In the IF stage, we read the BHT using the current PC bits to get a prediction. If predicted taken, we also read the BTB to get the predicted target. Otherwise, we use PC+4.
- In the ID stage, we resolve the branch (compute actual condition and target) and compare with prediction. If mispredicted, we flush the pipeline and set the PC to the correct target. Also update the BHT and BTB.

The flush signal clears the IF/ID register and sets the PC to the correct address. We also need to kill the instruction currently in ID (set its control signals to 0) because it was fetched based on the wrong prediction.

The complexity of branch prediction is not huge but adds several FSMs. In Verilog, we can implement the BHT as a small memory (e.g., 64 or 128 entries) with 2-bit counters. The BTB can be a register array storing target addresses.

**Verilog snippet for BHT update:**

```verilog
always_ff @(posedge clk) begin
    if (branch_resolved) begin
        case (bht[pc_index])
            2'b00: bht[pc_index] <= branch_taken ? 2'b01 : 2'b00;
            2'b01: bht[pc_index] <= branch_taken ? 2'b10 : 2'b00;
            2'b10: bht[pc_index] <= branch_taken ? 2'b11 : 2'b01;
            2'b11: bht[pc_index] <= branch_taken ? 2'b11 : 2'b10;
        endcase
    end
end
```

With a good predictor, we can achieve 80–90% accuracy for many workloads, reducing the effective branch penalty to less than 0.2 cycles per branch on average.

---

## 9. Putting It All Together: The Complete Pipeline Design

Now we have the components to build a complete five-stage pipelined RISC-V processor with:

- Forwarding for most data hazards (with stall for load-use)
- Hazard detection unit that stalls when necessary
- Branch prediction with 2-bit saturating counters and BTB
- Flush control on misprediction

The Verilog hierarchy will look like:

```
top.v
  - core.v
    - fetch_stage.v (PC, IMem, prediction logic)
    - decode_stage.v (register file, immediates, control, forwarding detection)
    - execute_stage.v (ALU, branch resolution)
    - memory_stage.v (DMem)
    - writeback_stage.v (write to register file)
    - hazard_unit.v (stall, flush signals)
    - branch_predictor.v (BHT, BTB)
    - pipeline_regs.v (IF/ID, ID/EX, EX/MEM, MEM/WB)
```

We must ensure that the register file write happens at the end of WB and reads happen in ID—this is standard. For forwarding, we need to handle the case where the write address is zero (x0 is always zero, and writes to x0 are discarded).

**Key signals:**

- `pc_src` from EX stage: indicates branch taken; used to redirect PC.
- `flush` from EX stage: on mispredict, clear IF/ID and ID/EX.
- `stall` from hazard unit: freeze PC and IF/ID when load-use hazard detected.

The exact timing: load-use hazard detection occurs in ID. The stall signal is generated in the current cycle, and in the next clock edge, the pipeline registers hold their values, and a NOP is injected into ID/EX. After one cycle, the load result is available in EX/MEM and can be forwarded.

---

## 10. Testing and Verification: Running Real Programs

We cannot claim we built a CPU until we can run real compiled RISC-V code. For testing, we can use the RISC-V GNU toolchain to compile a simple program (e.g., compute Fibonacci numbers) to a binary file, load it into instruction memory, and observe the results.

Simulation with Verilator or Icarus Verilog can print the register file and memory after each instruction. We can also create a testbench that compares our processor’s output against a golden reference (like a software emulator). For example, we can use `riscv-isa-sim` (Spike) to generate the expected register values and compare cycle by cycle.

**Example test program (assembly):**

```asm
.globl _start
_start:
    li x1, 10          # x1 = 10
    li x2, 0           # x2 = 0 (previous)
    li x3, 1           # x3 = 1 (current)
loop:
    beq x1, x0, end    # if counter zero, end
    add x4, x2, x3     # x4 = x2 + x3
    add x2, x3, x0     # x2 = x3
    add x3, x4, x0     # x3 = x4
    addi x1, x1, -1    # decrement counter
    jal x0, loop       # jump to loop
end:
    # x2 contains Fibonacci number at index 10 (should be 55)
```

We can compile with `riscv32-unknown-elf-gcc` and link to a custom linker script that places code at address 0. Then convert the binary to a Verilog hex file for instruction memory.

In simulation, we can inspect that after the end of the program, x2 equals 55. If it does, our pipeline works.

But there may be subtle bugs: forwarding from MEM to EX when the instruction in EX is a store (we need to forward only to the ALU input for the address calculation, not to the store data). Also handling of `jalr` (indirect jumps) requires careful PC calculation.

**Testing edge cases:**

- Branch prediction misprediction followed by another branch.
- Load-use hazard with the load instruction being a byte/halfword load (sign extension).
- Multiply extension (if we add M extension).
- Exceptions? We keep it simple; we ignore traps for now.

We should also run the RISC-V compliance tests (like `rv32ui-p-*`) that exercise each instruction. These tests are small self-checking programs that write results to a memory location. If our processor passes, we are confident.

---

## 11. Synthesis and FPGA Implementation

After simulation verification, we can synthesize the design for an FPGA. Using open-source tools like `yosys` for synthesis and `nextpnr` for place-and-route, we can target the iCE40 HX8K board (e.g., iCEBreaker). The design will consume around 3000–4000 LUTs and a few Block RAMs for instruction and data memory. The maximum frequency may be around 20–30 MHz due to the long combinational paths from forwarding muxes and the branch predictor.

We can interface with an on-board UART to communicate with a host PC, loading programs via a bootloader. That turns our homemade CPU into a real, working computer—capable of running, say, a simple game like Pong or a ray tracer (in software).

But optimization is possible: we can add more pipeline stages (e.g., 6 or 7), separate ALU for branch resolution, or implement a more aggressive branch predictor like a gshare or tournament predictor. However, those are beyond the scope of this introductory build.

---

## 12. Beyond the Basics: What Else Can We Do?

The processor we built is a full implementation of RV32I plus the ability to handle hazards and predict branches. But there are several ways to extend it:

- **Multiply and Divide (M extension):** Add an ALU block for `mul`, `div`, `rem`. The multiply operation takes multiple cycles; we can stall the pipeline and use a sequential multiplier.
- **Caches:** Add a small L1 cache (instruction and data) to reduce memory latency. This introduces cache miss penalties and need for cache coherency if we ever go multicore.
- **Superscalar:** Issue two instructions per cycle. Decode two instructions simultaneously, check dependencies, and dispatch to multiple ALUs. This significantly increases complexity.
- **Out-of-Order Execution:** Dynamically schedule instructions to execute as soon as operands are ready, with a reorder buffer. This is the territory of modern processors like the Apple M1 or Intel Core.

But even the simple five-stage pipelined processor with forwarding and branch prediction is a powerful educational tool. It encapsulates the core ideas that transformed the microprocessor industry from the 1970s to today.

---

## 13. Conclusion: The Magic is Understandable

We started with a line of code and ended with a transistor-level understanding of how that code is executed. The journey from single-cycle to five-stage pipelined RISC-V CPU is not just an exercise in Verilog; it is a journey through the fundamental principles of modern computing. Pipelining, hazard detection, and branch prediction are the three pillars that support the high-performance processors we rely on every day. By implementing them ourselves, we demystify the magic.

The RISC-V revolution has opened the gates. Now, anyone can build a CPU, test it, and even run it on real hardware. The barriers are down. If you have the curiosity and patience, you can create a custom processor that exactly fits your needs—whether for a teaching project, a specific accelerator, or just the sheer joy of understanding.

So, go ahead. Download an FPGA toolchain, write some Verilog, and build your own processor. The feeling of seeing your own CPU execute your own code is incomparable. And now you know exactly how the magic works.

---

_The full source code for the pipelined RISC-V processor described in this article is available on GitHub at [link]. It includes Verilog modules, testbenches, and sample programs. Happy building!_
