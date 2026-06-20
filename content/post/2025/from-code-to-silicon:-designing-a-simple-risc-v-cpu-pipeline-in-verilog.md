---
title: "From Code To Silicon: Designing A Simple Risc V Cpu Pipeline In Verilog"
description: "A comprehensive technical exploration of from code to silicon: designing a simple risc v cpu pipeline in verilog, covering key concepts, practical implementations, and real-world applications."
date: "2025-03-15"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/From-Code-To-Silicon-Designing-A-Simple-Risc-V-Cpu-Pipeline-In-Verilog.png"
coverAlt: "Technical visualization representing from code to silicon: designing a simple risc v cpu pipeline in verilog"
---

## Introduction: The Illusion of Magic (Expanded)

Every software engineer has felt it at least once. You compile a twenty-line function, run it, and a pixel turns red on a screen a few microseconds later. You write an `if` statement—a simple, logical fork in the road—and the machine, without hesitation, takes the correct path. The entire edifice of modern computing is built on a foundation of such mundane miracles. We call it “abstraction,” but often, it feels indistinguishable from magic. The programmer lives in a world of high-level constructs: variables, functions, objects, and threads. The hardware—the silicon wafer etched with billions of transistors—remains a distant, almost mythical entity.

Yet, every keystroke, every compile, every deployment rests on a layer cake of abstraction. At the bottom sits the Central Processing Unit (CPU), a mechanical beast of staggering complexity, driven by an unrelenting clock. Above it, we have microcode, instruction sets, assembly, operating systems, virtual machines, runtime environments, and finally, the languages we love. Most developers are content to stop at the compiler, viewing the CPU as a black box that executes instructions in a mysterious, but generally reliable, manner. This perspective, while practical for day-to-day development, is a profound intellectual tragedy.

Why? Because understanding the CPU is not just an academic exercise; it is the key to unlocking a deeper intuition for performance, concurrency, and the very nature of computation itself. When you understand that a modern CPU is a complex assembly line, or a “pipeline,” you begin to understand why branch mispredictions are expensive, why cache misses hurt, and why your tight loop isn’t running as fast as you crudely estimated from the clock speed. The limits of software are not defined by syntax or libraries, but by the physics of the silicon they run on. A single cache miss can stall the pipeline for hundreds of cycles. A branch misprediction can flush a dozen partially executed instructions. These are not academic corner cases; they are the daily reality of high-performance computing.

This blog post is your guided tour from the high-level abstraction of a programming language down to the digital logic that makes it all possible. We are going to tear down the black box. We are going to build one. Specifically, we will design a simple, five‑stage pipelined CPU based on the open‑source RISC‑V instruction set architecture (ISA) in its 32‑bit integer variant (RV32I). We will encode this design in Verilog, a Hardware Description Language (HDL) that lets us describe circuits, not just algorithms. By the end of this journey, you will be able to trace the execution of a single RISC‑V instruction from its fetch in memory to the moment its result updates the architectural state. You will understand why a CPU needs a pipeline, what hazards lurk in that pipeline, and how we can resolve them using forwarding and stalling.

But before we dive into the Verilog and logic gates, we need to establish a common language. We need to talk about what an instruction set architecture is, why RISC‑V is a perfect teaching vehicle, and how a simple five‑stage pipeline works in principle. We’ll also review the digital building blocks—combinational and sequential logic, registers, multiplexers, and the ALU—that form the musculature of the CPU. Then, we’ll build it, stage by stage, handling data hazards, control hazards, and structural hazards along the way. Finally, we’ll reflect on how this understanding changes the way you write software.

Welcome to the demystification of the CPU.

---

## Section 1: The Instruction Set Architecture – Our CPU’s Language

### 1.1 What is an ISA?

An Instruction Set Architecture (ISA) defines the contract between software and hardware. It specifies the programmer‑visible state (registers, memory, program counter) and the set of instructions that the CPU can execute. The ISA is the boundary where software meets silicon. For a compiler writer, the ISA is the target language. For a CPU designer, the ISA is the specification to implement. The beauty of a clean ISA is that it decouples software from implementation: programs written for a given ISA can run on any CPU that implements that ISA, regardless of internal microarchitecture.

### 1.2 Why RISC‑V?

RISC‑V is not just another ISA; it is a revolution. Born at UC Berkeley, it is the first widely‑adopted open‑source ISA. Unlike ARM or x86, RISC‑V is completely free to implement, with no licensing fees. It is designed with simplicity and modularity in mind. The base integer instruction set (RV32I) contains only about 40 instructions, making it an ideal vehicle for learning CPU design. Yet it is powerful enough to run full operating systems (Linux, FreeRTOS). RISC‑V is also extensible; you can add custom instructions for specialized accelerators.

### 1.3 RV32I Instruction Formats

RISC‑V uses fixed 32‑bit instructions. There are four main formats (R, I, S, B) plus a couple of variants (U, J). Each format encodes the opcode, registers, and immediate values in a consistent layout. Let’s examine the four core formats:

- **R‑type** (Register): Used for arithmetic/logic operations like `add rd, rs1, rs2`. Contains `opcode (7 bits)`, `rd (5 bits)` for destination register, `funct3 (3 bits)`, `rs1 (5 bits)`, `rs2 (5 bits)`, `funct7 (7 bits)`. Example: `ADD` has funct7=0x00, funct3=0x0.
- **I‑type** (Immediate): Used for arithmetic with immediate (`addi rd, rs1, imm`), loads (`lw rd, offset(rs1)`), and jumps (`jalr`). Layout: `opcode, rd, funct3, rs1, immediate[11:0]`.
- **S‑type** (Store): Used for store instructions (`sw rs2, offset(rs1)`). The immediate is split into two fields: `immediate[11:5]` and `immediate[4:0]` placed in the instruction word.
- **B‑type** (Branch): Used for conditional branches (`beq rs1, rs2, offset`). The immediate is encoded in a non‑contiguous but straightforward pattern (bits [12|10:5|4:1|11] in the instruction).

The regularity of these formats is a gift to hardware designers. Decoding an instruction is simply a matter of slicing the 32‑bit word according to the opcode and then extracting the relevant fields.

### 1.4 The Programmer‑Visible State

For RV32I, the state includes:

- 32 general‑purpose registers (x0 to x31). x0 is hardwired to zero.
- A program counter (PC) that points to the current instruction.
- Memory (byte‑addressable, little‑endian, up to 4 GiB).
- A set of control and status registers (CSRs) for interrupts and exceptions (we’ll ignore those for simplicity).

### 1.5 A Simple Program in RISC‑V Assembly

```assembly
# Add 5 and 3, store result in memory
addi x1, x0, 5      # x1 = 5
addi x2, x0, 3      # x2 = 3
add  x3, x1, x2     # x3 = 8
sw   x3, 0(x0)      # memory[0] = 8
```

This program will be our test case throughout the pipeline design.

Now that we have a language for our CPU, we need to build the hardware that executes these instructions. We start with the basic digital building blocks.

---

## Section 2: Digital Building Blocks – From Logic to State

Before we can design a CPU, we must understand the components from which it is constructed. In digital design, we work with two types of logic: combinational and sequential.

### 2.1 Combinational Logic

Combinational circuits produce outputs that depend only on the current inputs. Examples: AND, OR, XOR gates, adders, multiplexers, decoders. They have no memory. In Verilog, we describe combinational logic using `assign` statements or `always @(*)` blocks.

```verilog
// A 2-to-1 multiplexer
module mux2 #(parameter WIDTH=32) (
    input  [WIDTH-1:0] a, b,
    input  sel,
    output [WIDTH-1:0] out
);
    assign out = sel ? b : a;
endmodule
```

### 2.2 Sequential Logic – Flip‑Flops and Registers

Sequential circuits have state. The fundamental element is the flip‑flop (edge‑triggered D‑flip‑flop). In our CPU, we will use registers (a collection of flip‑flops) to hold pipeline stage results between clock edges. For example, the pipeline register between fetch and decode holds the instruction and the incremented PC.

```verilog
// A simple N-bit register with enable and reset
module register #(parameter WIDTH=32) (
    input               clk,
    input               rst,
    input               en,
    input  [WIDTH-1:0]  d,
    output reg [WIDTH-1:0] q
);
    always @(posedge clk) begin
        if (rst) q <= 0;
        else if (en) q <= d;
    end
endmodule
```

The clock is the heartbeat of the CPU. On every rising edge, values propagate from one pipeline stage to the next. The period of the clock is determined by the longest combinational path between any two registers.

### 2.3 The Arithmetic Logic Unit (ALU)

The ALU is the heart of execution. For RV32I, we need to support add, subtract, shifting, bitwise AND, OR, XOR, set‑less‑than (signed and unsigned). Here is a simplified ALU:

```verilog
module alu (
    input  [31:0] a, b,
    input  [3:0]  alu_control,   // from control unit
    output reg [31:0] result,
    output          zero
);
    assign zero = (result == 32'b0);
    always @(*) begin
        case (alu_control)
            4'b0000: result = a + b;           // ADD
            4'b0001: result = a - b;           // SUB
            4'b0010: result = a & b;           // AND
            4'b0011: result = a | b;           // OR
            4'b0100: result = a ^ b;           // XOR
            4'b0101: result = a << b[4:0];     // SLL
            4'b0110: result = a >> b[4:0];     // SRL (logical)
            4'b0111: result = $signed(a) >>> b[4:0]; // SRA (arithmetic)
            4'b1000: result = ($signed(a) < $signed(b)) ? 1 : 0; // SLT
            4'b1001: result = (a < b) ? 1 : 0; // SLTU
            default: result = 0;
        endcase
    end
endmodule
```

### 2.4 Register File

The register file holds the 32 general‑purpose registers. It has two read ports (A1, RD1) and one write port (A3, WD3). Reading is combinational; writing is clock‑edge triggered. RISC‑V requires that writes happen in the write‑back stage (at the end of the pipeline), and we must handle the write‑after‑read hazard correctly (we’ll see forwarding later).

```verilog
module regfile (
    input               clk,
    input               rst,
    input               we3,           // write enable
    input  [4:0]        a1, a2, a3,    // read addresses 1,2; write address
    input  [31:0]       wd3,           // write data
    output [31:0]       rd1, rd2
);
    reg [31:0] mem [0:31];
    // x0 is hardwired to zero
    always @(posedge clk) begin
        if (rst) begin
            integer i;
            for (i=0; i<32; i=i+1) mem[i] <= 0;
        end else if (we3 && a3 != 0) begin
            mem[a3] <= wd3;
        end
    end
    assign rd1 = (a1 == 0) ? 0 : mem[a1];
    assign rd2 = (a2 == 0) ? 0 : mem[a2];
endmodule
```

With these building blocks, we are ready to assemble the five‑stage pipeline.

---

## Section 3: The Five‑Stage Pipeline – A Stage‑by‑Stage Construction

A classic RISC pipeline consists of five stages:

1. **IF** – Instruction Fetch
2. **ID** – Instruction Decode / Register Fetch
3. **EX** – Execute (ALU or address calculation)
4. **MEM** – Memory access (load/store)
5. **WB** – Write‑back to register file

In an ideal pipeline, one instruction completes every clock cycle, yielding a throughput of one instruction per cycle (IPC) – ignoring hazards. We will build each stage as a Verilog module and then connect them via pipeline registers.

### 3.1 Instruction Fetch (IF) Stage

The IF stage must provide the next instruction to execute. It contains:

- The Program Counter (PC) register.
- An instruction memory (we’ll model it as a simple array or ROM).
- An adder to increment PC by 4 (for sequential instructions).
- A mux for branch/jump target selection (we’ll add this after we handle control hazards).

**Simplest implementation** (without branch handling):

```verilog
module if_stage (
    input               clk,
    input               rst,
    input               stall,       // from hazard unit
    input               flush,       // from hazard unit (clear pipeline)
    input  [31:0]       pc_target,   // branch target
    input               pcsrc,       // branch taken?
    output reg [31:0]   pc,          // current PC
    output [31:0]       instr       // fetched instruction
);
    reg [31:0] instr_mem [0:1023]; // 4KB instruction memory
    wire [31:0] pc_next;

    // PC logic
    always @(posedge clk) begin
        if (rst) pc <= 32'h0;
        else if (stall) pc <= pc;           // hold PC during stall
        else if (flush) pc <= pc_target;    // flush (branch taken)
        else if (pcsrc) pc <= pc_target;    // branch (not flush)
        else pc <= pc + 4;
    end

    // Instruction memory (synchronous read for simplicity)
    always @(posedge clk) begin
        if (!stall) instr <= instr_mem[pc[11:2]]; // word aligned
    end

    // Initialize with a small program (can be loaded from file)
    initial begin
        instr_mem[0] = 32'h00100093; // addi x1, x0, 1
        instr_mem[1] = 32'h00200113; // addi x2, x0, 2
        instr_mem[2] = 32'h00208133; // add  x3, x1, x2
        instr_mem[3] = 32'h00302023; // sw   x3, 0(x0)
        // ... etc.
    end
endmodule
```

**Note**: In a real design, instruction memory is often separate from data memory (Harvard architecture). For simplicity, we keep them separate.

### 3.2 Instruction Decode (ID) Stage

The ID stage decodes the instruction fetched in IF. It must:

- Extract opcode, register addresses, and immediates.
- Read the register file (rs1, rs2).
- Generate control signals for later stages (RegWrite, ALUSrc, MemWrite, MemRead, MemtoReg, Branch, ALUOp, etc.).
- Pass along the immediate value.

We will implement a **control unit** as a separate module that outputs a bundle of control signals based on the opcode and funct3/funct7 fields.

```verilog
module id_stage (
    input  [31:0] instr,
    input  [31:0] wd3,               // write‑back data
    input  [4:0]  a3,                // write address (from WB stage)
    input         we3,               // write enable
    input         clk, rst,
    output [31:0] rd1, rd2,          // register values
    output [31:0] imm,               // sign‑extended immediate
    output [6:0]  opcode,
    output [2:0]  funct3,
    output [6:0]  funct7,
    output        regwrite, memwrite, memread, alusrc, memtoreg,
    output [1:0]  aluop,
    output        branch             // branch instruction?
);
    // Register file instantiation
    wire [4:0] rs1 = instr[19:15];
    wire [4:0] rs2 = instr[24:20];
    wire [4:0] rd  = instr[11:7];

    regfile rf (clk, rst, we3, rs1, rs2, a3, wd3, rd1, rd2);

    // Immediate generation (sign extension)
    assign opcode = instr[6:0];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];

    // Control unit (combinational)
    control_unit cu (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .regwrite(regwrite),
        .memwrite(memwrite),
        .memread(memread),
        .alusrc(alusrc),
        .memtoreg(memtoreg),
        .aluop(aluop),
        .branch(branch)
    );

    // Immediate extension (RISC‑V formats)
    wire [11:0] imm_i = instr[31:20];
    wire [11:0] imm_s = {instr[31:25], instr[11:7]};
    wire [12:0] imm_b = {instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    // For simplicity, we handle only I‑type and R‑type in this snippet
    assign imm = { {20{instr[31]}}, instr[31:20] }; // I‑type immediate
endmodule
```

The **control unit** is a truth table mapping opcodes to control signals. For RV32I, we can implement it as a case statement.

### 3.3 Execute (EX) Stage

The EX stage performs the actual computation. It has:

- ALU.
- A mux to select the second ALU operand (register value vs. immediate) based on `alusrc`.
- ALU control (derived from `aluop` and `funct3`/`funct7`).
- Branch address calculation (adder for PC+imm and comparison of rs1, rs2).

```verilog
module ex_stage (
    input  [31:0] pc,           // from IF/ID pipeline register
    input  [31:0] rd1, rd2,
    input  [31:0] imm,
    input  [1:0]  aluop,
    input         alusrc,
    input  [2:0]  funct3,
    input  [6:0]  funct7,
    output [31:0] alu_result,
    output        zero,
    output [31:0] pc_branch      // for branch target
);
    wire [31:0] alu_src2 = alusrc ? imm : rd2;
    wire [3:0]  alu_control;

    // ALU control decoder
    always @(*) begin
        case (aluop)
            2'b00: alu_control = 4'b0000; // ADD for lw/sw
            2'b01: alu_control = 4'b0001; // SUB for beq
            2'b10: alu_control = {funct7[5], funct3}; // R‑type
            default: alu_control = 0;
        endcase
    end

    alu alu_inst (rd1, alu_src2, alu_control, alu_result, zero);

    // Branch target = PC + immediate (shifted left 1 for B‑type)
    assign pc_branch = pc + imm;
endmodule
```

**Important**: We have not yet handled the branch decision. That will be done in the EX stage as well: `branch_taken = branch & zero` (for beq) or `branch & (rs1 < rs2)` for blt. We’ll add a comparator as part of the branch logic.

### 3.4 Memory (MEM) Stage

The MEM stage handles load and store instructions. It contains the data memory (256 words or more). For loads, we read from memory; for stores, we write.

```verilog
module mem_stage (
    input         clk,
    input         memread,
    input         memwrite,
    input  [31:0] alu_result,   // address
    input  [31:0] write_data,   // from rd2 (register rs2)
    output [31:0] read_data
);
    reg [31:0] dmem [0:255];   // 1KB data memory

    always @(posedge clk) begin
        if (memwrite) dmem[alu_result[9:2]] <= write_data;
    end

    assign read_data = memread ? dmem[alu_result[9:2]] : 0;
endmodule
```

### 3.5 Write‑Back (WB) Stage

The WB stage selects which value to write to the register file: either the ALU result (for arithmetic instructions) or the data read from memory (for loads). The `memtoreg` control signal selects between them.

```verilog
module wb_stage (
    input         memtoreg,
    input  [31:0] alu_result,
    input  [31:0] read_data,
    output [31:0] result     // value to write to register file
);
    assign result = memtoreg ? read_data : alu_result;
endmodule
```

### 3.6 Pipeline Registers

We need four pipeline registers to separate the stages:

- **IF/ID**: holds the instruction and PC+4.
- **ID/EX**: holds decoded instruction fields, register values, immediates, control signals, plus the PC for branch calculation.
- **EX/MEM**: holds ALU result, write data, and control signals for memory and write‑back.
- **MEM/WB**: holds the result to write back, the write address, and the RegWrite control signal.

Each pipeline register is a module with clock, reset, enable (for stalling), and clear (for flushing). For brevity, I’ll show the ID/EX register as an example:

```verilog
module ID_EX_reg (
    input               clk, rst,
    input               stall, flush,
    // inputs from ID
    input  [31:0]       pc, rd1, rd2, imm,
    input  [4:0]        rs1, rs2, rd,
    input               regwrite, memwrite, memread, alusrc, memtoreg,
    input  [1:0]        aluop,
    input               branch,
    // outputs to EX
    output reg [31:0]   ex_pc, ex_rd1, ex_rd2, ex_imm,
    output reg [4:0]    ex_rs1, ex_rs2, ex_rd,
    output reg          ex_regwrite, ex_memwrite, ex_memread, ex_alusrc, ex_memtoreg,
    output reg [1:0]    ex_aluop,
    output reg          ex_branch
);
    always @(posedge clk) begin
        if (rst) begin
            ex_pc <= 0; ex_rd1 <= 0; ex_rd2 <= 0; ex_imm <= 0;
            ex_rs1 <= 0; ex_rs2 <= 0; ex_rd <= 0;
            ex_regwrite <= 0; ex_memwrite <= 0; ex_memread <= 0;
            ex_alusrc <= 0; ex_memtoreg <= 0; ex_aluop <= 0;
            ex_branch <= 0;
        end else if (flush) begin
            // set control signals to 0 (nop)
            ex_regwrite <= 0; ex_memwrite <= 0; ex_memread <= 0;
            ex_alusrc <= 0; ex_memtoreg <= 0; ex_aluop <= 0;
            ex_branch <= 0;
            // other fields can be left unchanged or zeroed
        end else if (!stall) begin
            // normal operation: load from ID stage
            ex_pc <= pc; ex_rd1 <= rd1; ex_rd2 <= rd2; ex_imm <= imm;
            ex_rs1 <= rs1; ex_rs2 <= rs2; ex_rd <= rd;
            ex_regwrite <= regwrite; ex_memwrite <= memwrite; ex_memread <= memread;
            ex_alusrc <= alusrc; ex_memtoreg <= memtoreg; ex_aluop <= aluop;
            ex_branch <= branch;
        end
    end
endmodule
```

Now we have all the pieces. Time to assemble the CPU and tackle the elephant in the pipeline: hazards.

---

## Section 4: Hazards and Their Mitigation

A pipeline can go wrong in three ways:

1. **Structural hazard**: Two instructions need the same hardware resource at the same time. (e.g., single memory for instructions and data). We avoid this by using separate instruction and data memories.
2. **Data hazard**: An instruction depends on the result of a previous instruction that hasn’t been written back yet.
3. **Control hazard**: A branch changes the PC, and the next instructions have already been fetched.

### 4.1 Data Hazards – Forwarding and Stalling

Consider the classic sequence:

```
add x1, x2, x3   # x1 = x2 + x3
add x4, x1, x5   # x4 = x1 + x5 (depends on x1)
```

Without intervention, the second add will read a stale value of x1 from the register file because the first add’s result hasn’t been written back yet (it’s in the EX stage). The solution is **forwarding** (or bypassing): we can feed the result directly from the EX or MEM stage back to the ALU input.

We need a **forwarding unit** that detects when the current EX stage’s source registers match the destination register of a previous instruction that is in the EX, MEM, or WB stage (and that instruction writes to the register file).

The forwarding unit outputs two multiplexer select signals to choose between the register file value and the forwarded value.

**Example Verilog for forwarding in the EX stage:**

```verilog
module forwarding_unit (
    input  [4:0] id_ex_rs1, id_ex_rs2,
    input  [4:0] ex_mem_rd, mem_wb_rd,
    input        ex_mem_regwrite, mem_wb_regwrite,
    output [1:0] forward_a, forward_b  // 00: from regfile, 01: from EX/MEM, 10: from MEM/WB
);
    always @(*) begin
        // Forward to ALU input A
        if (ex_mem_regwrite && (ex_mem_rd != 0) && (ex_mem_rd == id_ex_rs1))
            forward_a = 2'b01;
        else if (mem_wb_regwrite && (mem_wb_rd != 0) && (mem_wb_rd == id_ex_rs1))
            forward_a = 2'b10;
        else
            forward_a = 2'b00;

        // Forward to ALU input B
        if (ex_mem_regwrite && (ex_mem_rd != 0) && (ex_mem_rd == id_ex_rs2))
            forward_b = 2'b01;
        else if (mem_wb_regwrite && (mem_wb_rd != 0) && (mem_wb_rd == id_ex_rs2))
            forward_b = 2'b10;
        else
            forward_b = 2'b00;
    end
endmodule
```

Then in the EX stage, we replace `rd1` and `rd2` with muxed values:

```verilog
wire [31:0] alu_src1 = (forward_a == 2'b01) ? ex_mem_alu_result :
                       (forward_a == 2'b10) ? mem_wb_result : id_ex_rd1;
wire [31:0] alu_src2 = (forward_b == 2'b01) ? ex_mem_alu_result :
                       (forward_b == 2'b10) ? mem_wb_result : (id_ex_alusrc ? id_ex_imm : id_ex_rd2);
```

However, forwarding is not enough for **load‑use hazards**. Consider:

```
lw x1, 0(x2)
add x3, x1, x4   # x1 is only available after MEM stage
```

The result from the load is available at the end of MEM stage, but the ALU needs it at the beginning of EX stage for the next instruction. We cannot forward because the data is not ready in time. We must insert a **stall** (bubble) for one cycle.

The hazard unit detects a load‑use condition: if the instruction in ID has a source register that matches the destination register of a load instruction in EX (with MemRead = 1), we need to stall the pipeline (freeze IF/ID and insert a nop into ID/EX).

```verilog
module hazard_unit (
    input  [4:0] id_ex_rd,
    input        id_ex_memread,
    input  [4:0] if_id_rs1, if_id_rs2,
    output       stall       // stall signal for pipeline
);
    assign stall = id_ex_memread && ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
endmodule
```

When `stall` is asserted, we:

- Prevent PC from changing (PC write enable = 0).
- Prevent IF/ID register from updating (its stall input = 1).
- Send a nop into ID/EX (by asserting flush on ID/EX and setting all control signals to 0).

### 4.2 Control Hazards – Branch Prediction

Every branch instruction introduces a control hazard. By the time we know the branch outcome (in EX stage), we have already fetched the next instruction (and maybe the one after that). If the branch is taken, we must flush the incorrectly fetched instructions.

Our simple approach: **assume not taken** (predict forward). When the branch is actually taken, we flush the IF/ID and ID/EX pipeline registers (set their flush input) and redirect the PC to the target.

The flush signal is generated by the EX stage when `branch_taken` is true.

But there is still a penalty: one wasted cycle (the instruction after the branch is fetched but then flushed). For a deeper pipeline, more cycles are wasted. Better branch predictors (e.g., 2‑bit saturating counter, branch target buffer) can reduce the penalty.

### 4.3 Putting It All Together – Top-Level CPU with Hazard Handling

Now we can write the top‑level `pipeline_cpu` module that instantiates all stages, pipeline registers, forwarding unit, and hazard unit. We will have a single clock and reset. The control signals propagate through the pipeline registers.

```verilog
module pipeline_cpu (
    input clk, rst
);
    // Internal wires
    wire [31:0] pc, pc_next, instr;
    wire        stall, flush_ifid, flush_idex;
    wire [31:0] if_id_instr, if_id_pc;
    // ... many more wires

    // Instantiate stages
    if_stage if_inst (clk, rst, stall, flush_ifid, pc_target, pcsrc, pc, instr);
    IF_ID_reg if_id_reg (clk, rst, stall, flush_ifid, pc, instr, if_id_pc, if_id_instr);
    // ... continue
endmodule
```

This is a substantial amount of Verilog. For a complete example, see the numerous RISC‑V pipelined CPU implementations on GitHub (e.g., [UltraEmbedded/riscv](https://github.com/UltraEmbedded/riscv)).

---

## Section 5: Performance Analysis – How Fast Is Our Pipeline?

The throughput of a pipelined CPU is limited by the slowest stage. If we assume all stages have equal delay, a 5‑stage pipeline can issue one instruction per cycle (ignoring hazards). This gives a speedup of 5 over a single‑cycle implementation (which would require 5× the clock period). In reality, the memory stage (data memory) is often the bottleneck.

But hazards reduce throughput. The **CPI (Cycles Per Instruction)** increases due to:

- Stalls from load‑use hazards: +1 cycle per load that is immediately used.
- Branch mispredictions: +1 cycle per mispredicted branch (for our simple predictor).
- Structural hazards (if any): but we have separate memories, so none.

A typical mix of instructions might have 20% loads, 50% ALU, 20% branches, 10% stores. With forwarding, ALU‑to‑ALU data hazards cause no stalls. Load‑use hazards cause about 1 stall per 5 loads (if 25% of loads are followed by a dependent instruction). That adds 5% CPI increase. Branch mispredictions add maybe 20% × 1 cycle = 0.2 CPI. So actual CPI might be around 1.25. This is far from the ideal 1.0 but much better than a multi‑cycle design.

To improve performance, we can:

- Increase pipeline depth (superscalar, deeper pipelines like 10‑stage in modern CPUs).
- Use dynamic branch prediction (reduces misprediction penalty).
- Use multiple ALUs and instruction issue (superscalar).

But with great depth comes great complexity and power consumption. The trade‑offs are part of the art of CPU design.

---

## Section 6: Beyond the Five‑Stage Pipeline

The five‑stage pipeline is a pedagogical classic, but modern CPUs are far more complex. They are **superscalar** (issue multiple instructions per cycle), **out‑of‑order** (reorder instructions to avoid stalls), and **speculative** (execute instructions before branches are resolved). They contain deep cache hierarchies, translation lookaside buffers (TLBs), and sophisticated branch predictors.

However, the fundamental principles remain the same: fetch, decode, execute, memory, write‑back. Hazards still exist, but are handled by reorder buffers (ROB), reservation stations, and scoreboarding. The complexity is staggering, but the core insight—that a CPU is an instruction pipeline—remains the unifying concept.

For the curious engineer, I recommend:

- _Computer Organization and Design_ by Patterson and Hennessy (the RISC‑V edition).
- _Digital Design and Computer Architecture_ by Harris and Harris (with RISC‑V).
- Open‑source RISC‑V cores: `picorv32`, `serv`, `rocket-chip`.

---

## Conclusion: The Magic is Engineering

We began with a Python one‑liner and ended with Verilog modules that describe how electrons flow through transistors to add two numbers. We have seen that the CPU is not a black box but a carefully engineered pipeline, governed by the laws of physics and the constraints of digital logic. Understanding this pipeline changes the way you write software:

- You avoid tight loops that rely on branch mispredictions (e.g., unpredictable branches in hot code).
- You arrange data accesses to maximize cache locality (minimizing cache misses, which are much more expensive than pipeline stalls).
- You think about instruction‑level parallelism and how the compiler can reorder operations to reduce hazards.

The next time you run a program and marvel at its speed, remember the humble pipeline underneath. The illusion of magic is sustained by layers of abstraction, each built by engineers who understood the layer below. Now you are one of them.

The CPU is demystified. Go forth and optimize.
