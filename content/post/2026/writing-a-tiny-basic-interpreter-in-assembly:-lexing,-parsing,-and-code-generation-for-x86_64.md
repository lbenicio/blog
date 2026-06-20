---
title: "Writing A Tiny Basic Interpreter In Assembly: Lexing, Parsing, And Code Generation For X86_64"
description: "A comprehensive technical exploration of writing a tiny basic interpreter in assembly: lexing, parsing, and code generation for x86_64, covering key concepts, practical implementations, and real-world applications."
date: "2026-04-04"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Writing-A-Tiny-Basic-Interpreter-In-Assembly-Lexing,-Parsing,-And-Code-Generation-For-X86_64.png"
coverAlt: "Technical visualization representing writing a tiny basic interpreter in assembly: lexing, parsing, and code generation for x86_64"
---

Here is a 1,500-word introduction designed to hook the reader, establish context, and outline the technical journey ahead.

---

# Introduction: The Digital Telescope

There is a moment in every programmer’s life that feels like a religious experience. It often happens late at night, after hours of chasing a bug that seems to exist only in the spaces between your neurons. You are staring at a disassembly window, or perhaps you have just written a few lines of C that compile down to something unexpectedly elegant. Suddenly, the layers peel away. The syntax highlighting, the IDE, the operating system, the standard library—all of it becomes a thin, shimmering veil. Beneath it, you see the machine.

For me, that moment arrived while I was building a recursive descent parser for a simple arithmetic expression language. I was so proud of my elegant `factor()` and `term()` functions. They read like poetry. Then, out of curiosity, I compiled it for a bare-metal ARM microcontroller. I looked at the generated assembly for my `eval()` function. It was a horror show of stack pushes, pop, and function call overhead. My beautiful parser, conceptually pure, was dragging an entire operating system’s worth of baggage into a world that barely had 64 kilobytes of RAM.

I wondered: *What if the parser *was* the runtime? What if there was no gap between the code that reads the source and the machine that executes it?*

This question is the heart of why you would ever want to write a programming language interpreter in assembly language. It is not about practicality. It is not about performance—at least, not in the way you might think. It is about understanding the fundamental contract between human intention and silicon logic. It is about building a telescope, not to look at the stars, but to look at the gears of the machine itself.

## Why This Matters: The Pedagogy of Pain

We live in an age of absurdly high-level abstraction. A modern JavaScript developer can ship a multi-megabyte application without ever knowing what a register is, let alone how to use one. Python, Ruby, Java, and C# all provide layers of comfortable insulation. This is a good thing. Productivity is king.

But there is a dangerous side effect: **the illusion of computational magic.**

When you write `x = 5 + 3` in Python, the interpreter does an astonishing number of things. It has to read the bytes of your file, decode them into Unicode, tokenize them into a stream of meaningful words, parse those tokens into an Abstract Syntax Tree (AST), compile that AST into bytecode, and then execute that bytecode in a virtual machine that checks types, manages memory, and resolves namespaces. The actual addition of two small integers is the last, smallest thing that happens.

Writing an interpreter in assembly burns away that illusion. You cannot hand-wave a `malloc` call. You cannot rely on the OS to manage your stack frames. You cannot use a hash map for your symbol table. You have to _build_ the constraints that the language operates under, using nothing but raw memory and the x86_64 instruction set.

This is the purest form of systems programming you can do. It forces you to confront the architectural limits of the machine: the tiny, precious set of general-purpose registers, the rigid hierarchy of the cache and memory, the brutal flatness of the address space. It teaches you, with every single opcode you write, that **interpretation is not magic; it is a translation layer.**

By the end of this post series, you will never look at a `for` loop the same way again. You will see the comparison, the conditional jump, the pointer arithmetic. You will see the machine.

## The Context: Tiny BASIC and the Spirit of '76

Our choice of language is no accident. We are not implementing a full C compiler or a Lisp dialect. We are building a **Tiny BASIC** interpreter.

For those unfamiliar, Tiny BASIC was a specification published by Dr. Li-Chen Wang in the mid-1970s. It was a reaction to the high price of commercial BASIC interpreters for early home computers like the Altair 8800 and the IMSAI 8080. Dr. Wang wanted a free, minimal implementation that hobbyists could type in by hand (or, more realistically, toggle in via front-panel switches).

Tiny BASIC is perfect for this exercise because it is **computationally complete but syntactically trivial.**

Consider the entire grammar:

- A program is a list of numbered lines.
- Each line contains a statement.
- Statements include: `PRINT`, `INPUT`, `GOTO`, `GOSUB`, `RETURN`, `IF`, `LET`, `END`, and `REM`.
- Expressions are simple arithmetic with `+`, `-`, `*`, `/`, and variables named `A` to `Z`.

That is it. There are no functions. No strings. No arrays. No garbage collection. No complex scoping rules. The entire language fits on a single page of a technical manual.

This minimalism is a feature, not a bug. It allows us to focus entirely on the **three pillars of interpretation**: Lexing, Parsing, and Code Generation. With a full language like Python or JavaScript, the lexer alone would be a PhD thesis. With Tiny BASIC, we can write the entire pipeline, from source file to execution, in a few hundred lines of x86_64 assembly.

But do not let the simplicity fool you. Tiny BASIC has everything. It has variables (state), control flow (loops via `GOTO`, subroutines via `GOSUB`/`RETURN`), conditional branching (`IF`), and I/O (`PRINT`/`INPUT`). It is a general-purpose programming language. It just happens to be a very small one.

## The Architecture: Lexing, Parsing, and Code Generation

Let’s talk about what we are going to build.

In a traditional high-level language interpreter, the pipeline looks like this:

1.  **Lexer/Tokenizer:** Converts a string of characters into a list of tokens (e.g., `"PRINT "HELLO"` becomes `[TOKEN_PRINT, TOKEN_STRING("HELLO")]`).
2.  **Parser:** Takes the list of tokens and builds a tree (AST) that represents the grammatical structure of the program.
3.  **Interpreter/Compiler:** Walks the AST and executes it (interpretation) or generates machine code for it (compilation).

In our assembler version, we are going to twist this model into a very tight, deeply intertwined knot.

**Lexing in Assembly:**
In C or Python, a lexer is a state machine implemented with `switch` statements or lookup tables. It’s clean. In assembly, a lexer is a byte-by-byte scavenger hunt. We will hold the current character in a register (likely `AL` from the `RAX` register). We will compare it against ASCII values for digits, letters, and operators. We will advance a pointer through the source string. We will convert the text "100" into the integer 100 using iterative multiplication and addition. There are no string functions. We are the string function.

**Parsing in Assembly:**
Most modern interpreters use a technique called "Recursive Descent Parsing." You write functions like `parse_expression()`, `parse_term()`, `parse_factor()` that call each other based on the operator precedence. In assembly, we can mimic this. We will write a set of procedures that implement the grammar. But there's a catch: assembly lacks the syntactic sugar of function abstraction. Our "functions" will be sequences of instructions that end with `RET`, and we will manage a virtual "parser pointer" (our Instruction Pointer, or rather our source pointer) through the source code. We will handle operator precedence not with a complex table, but by the order in which we write our `CMP` and `JE` instructions.

**Code Generation in Assembly:**
Here is where things get truly interesting. We are not going to _interpret_ the parsed structures directly. We are going to generate **native x86_64 machine code** at runtime.

Think about that for a second. Our Tiny BASIC interpreter will read a line like `10 LET A = 5 + 3`. It will lex the characters. It will parse the expression. Then, instead of calculating `5+3` immediately, it will emit the bytes `mov eax, 5; add eax, 3; mov [address_of_A], eax` directly into a block of executable memory. When the program is "done" parsing, it will see `RUN` and then **jump directly into this generated code** and execute it.

This is the final, beautiful payoff of doing this in assembly. We are building a **tiny JIT (Just-In-Time) compiler** from scratch. We are taking the abstract syntax and materializing it into the opcodes that the CPU fetches and executes directly. There is no interpreter loop. No virtual machine. No bytecode. Just raw, naked x86_64 instructions.

## What This Post Will Cover

This blog post is the first in a series. Here, we will lay the foundation.

We will start by defining the exact dialect of Tiny BASIC we are implementing. We will define the memory layout of our interpreter: where is the source code stored? Where are the 26 variables (A-Z)? Where are we going to put the generated code?

Then, we will dive into the **Lexer**. We will write assembly routines to:

- Skip whitespace and newlines.
- Recognize keywords like `PRINT`, `IF`, and `GOTO`.
- Read numeric constants and variable names.
- Handle the end of a line.

We will build this step-by-step, using the GNU Assembler (GAS) syntax, targeting a standard Linux x86_64 environment. We will run our first tests by loading a string, lexing it, and printing the tokens to the terminal using a simple `syscall`.

By the end of this post, you will have the front-end of your interpreter working. You will have wrestled with the raw bits of a programming language, and you will have won. The parser and code generator will follow in subsequent posts.

## A Final Warning and an Invitation

This is not easy. Assembly is the language of the machine, and the machine is unforgiving. A single off-by-one byte in a jump offset, a single forgotten stack push, and your program will segfault or, worse, silently corrupt memory. You will use `gdb` more than you have ever used a debugger in your life. You will stare at `objdump` output until your eyes water.

But I promise you this: when you type `10 PRINT "HELLO WORLD"` into the console of your interpreter, and the program you wrote in assembly parses it, generates machine code on the fly, and prints "HELLO WORLD" at 3 GHz without a single library call, you will feel something profound.

You will have touched the soul of the computer.

Let’s begin.

## The Engine Room: Lexing the Tiny BASIC Source

Before we can execute even a single `PRINT` statement, we must transform the raw characters typed by the user into a structured stream of tokens. This process, called **lexing** (or tokenization), is the front door of our interpreter. In a high-level language like Python, you might use a library like `re` or `ply`; in assembly, you are the library.

### Token Types for Tiny BASIC

Our dialect is deliberately minimal. It supports:

- **Numeric literals** (e.g., `42`, `007`) – stored as 64-bit integers.
- **String literals** (e.g., `"HELLO"`) – only for `PRINT`.
- **Keywords**: `LET`, `PRINT`, `IF`, `THEN`, `GOTO`, `END`, `INPUT`.
- **Variable names**: single letters `A` through `Z`, treated as memory locations.
- **Operators**: `+`, `-`, `*`, `/`, `=`, `<`, `>`, `(`, `)`.
- **Newlines** and **end-of-file** as statement terminators.

We’ll encode each token as a fixed‑size structure in memory. The fastest approach on x86‑64 is to use a tightly packed struct – for example, 16 bytes per token: an 8‑byte type identifier and an 8‑byte value (integer or pointer). We keep a global token buffer and a token count.

### Scanning Characters in Assembly

The lexer is a state machine that reads one character at a time from the input string. We maintain a pointer (`rsi` – source index) and a counter (`rcx` – remaining bytes). For each iteration we examine the byte at `[source]` and decide the next action.

```nasm
; rsi = pointer to current char
; rcx = remaining length
.next_char:
    cmp  rcx, 0
    je   .eof
    mov  al, [rsi]
    inc  rsi
    dec  rcx
    ; now dispatch based on al
```

A simple dispatcher using a jump table works well. First classify the character: digit, letter, quote, operator, whitespace. For each class we call a dedicated handler.

#### Example: Lexing a Numeric Literal

When we see a digit, we enter a loop that accumulates the value. Because assembly lacks a built‑in `int()` conversion, we manually multiply the running result by 10 and add the digit value.

```nasm
; assume al contains first digit
lex_number:
    xor  rax, rax          ; result = 0
.again:
    sub  al, '0'           ; convert ASCII to integer (al was digit)
    imul rax, 10           ; shift left by one decimal place
    add  rax, rbx          ; actually, need to hold digit temporarily
    ; better: keep digit in rdx
    ; (simplified) let's do it properly:
    xor  rdx, rdx
    mov  dl, al
    sub  dl, '0'
    imul rax, 10
    add  rax, rdx

    mov  al, [rsi]         ; peek next character
    cmp  al, '0'
    jb   .done
    cmp  al, '9'
    ja   .done
    inc  rsi
    dec  rcx
    jmp  .again
.done:
    ; store token with type = TOK_NUMBER, value = rax
    ; advance caller appropriately
    ret
```

**Note about efficiency**: At the assembly level, division and multiplication are expensive. For a toy interpreter it’s fine, but a real compiler would use a technique like Horner’s method with a sliding window. We keep it simple.

### Handling Keywords and Variables

When we encounter a letter (`A`–`Z`), we must decide if it’s a keyword like `LET` or a variable name. Because our keywords are short (3–5 characters), we can do a direct string comparison using `cmpsb` or by loading a quadword and comparing.

```nasm
; rsi points to first letter of word
; rcx has remaining input length
; we need to check the next few chars without consuming them permanently.
; Strategy: save rsi, try to match each keyword.
; For speed, we can build a trie, but a linear list of 7 keywords is fine.

    mov  r9, rsi          ; save start
    ; compare with "LET"
    mov  eax, [rsi]       ; load first 4 bytes (dword)
    cmp  eax, "LET "      ; note: space padded? We'll null-terminate internally.
    ; simpler: use cmpsb after lodsb?
    ; Better: load full 8-byte word and mask.
```

Assembly’s strength is that we can treat keywords as immediate values. For instance, we can store `"LET\0\0\0\0"` in a register and compare with `[rsi]`. But because keywords have different lengths, we must compare only the relevant bytes. A pragmatic approach: keep a small jump table indexed by the first letter, then verify the rest.

```nasm
; Jump table for first letter
    cmp  al, 'L'
    je   .maybe_let
    cmp  al, 'P'
    je   .maybe_print
    ; ... etc.
.maybe_let:
    ; verify that next two chars are 'E' and 'T', then a non-letter
    mov  ax, [rsi]
    cmp  ax, "ET"       ; two-byte compare
    jne  .variable
    ; check that character after that is not a letter/digit
    mov  al, [rsi+2]
    call is_alpha_numeric
    jc   .variable      ; if alphanumeric, it's a variable starting with 'L'? Actually variable can be only single char, so "LET" is keyword.
    ; ... accept keyword token
```

**Variable names** are single letters. If the token is not a keyword, we treat it as a variable token with an index 0..25. We simply compute `var_index = letter - 'A'`.

### String Literals and Comments

String literals appear only in `PRINT` statements. We scan until we see a closing quote, copying the characters into a separate string pool. In assembly we can store the pointer to the string in the token value.

Comments (typically REM) can be skipped entirely: when we see `REM`, consume until newline.

### Error Handling

The lexer must report on unexpected characters. In assembly, the simplest way is to call a `lex_error` function that prints a message and exits. For robustness we could collect error messages, but for our tiny interpreter a single `panic` is acceptable.

### Real‑World Note

Writing a lexer in assembly is an exercise in extreme manual control – every byte is accounted for. In production compilers, lexers are auto‑generated from regular expressions (e.g., lex/flex). However, the principles are identical: character classification, state transitions, and token emission. Understanding the assembly implementation makes high‑level lexers feel almost like magic you can touch.

---

## Parsing: From Tokens to an Abstract Syntax Tree

With a token stream in memory, we now need to determine the grammatical structure of the program. **Parsing** for Tiny BASIC must handle:

- **Expressions**: arithmetic with precedence (multiplication before addition), parentheses, relational operators.
- **Statements**: `LET var = expr`, `PRINT expr|string`, `IF expr THEN line-number`, `GOTO line-number`, `INPUT var`, `END`.

We have two classical approaches: **recursive descent** (elegant, manual) and **operator-precedence** (efficient, table‑driven). Because assembly lacks recursion in the traditional sense (but we can use the call stack), recursive descent is surprisingly natural. Each grammar non‑terminal becomes a procedure.

### Grammar for Tiny BASIC Expressions

```
expression   := term ( ('+' | '-') term )*
term         := factor ( ('*' | '/') factor )*
factor       := number | variable | '(' expression ')' | ( '+' | '-' ) factor
```

This is the classic expression grammar with left associativity. We’ll implement it as three functions: `parse_expression`, `parse_term`, `parse_factor`. Each consumes tokens and returns a representation of the parsed sub‑tree – but in a code generator we might output instructions directly rather than building an AST. This is called **syntax‑directed translation**.

### Parsing in Assembly: Stack Frames and Pointers

We maintain a global token pointer (`r12` – current token index). Each parse function advances it as needed and returns a result (e.g., a register holding the computed value or a pointer to generated code). For simplicity, we can **evaluate expressions immediately** (interpretive parsing), or generate machine code on the fly. I’ll show the interpretive path first, then discuss code generation.

#### Interpretive Expression Parser (AST‑free)

Because we are writing in assembly, we can evaluate the expression as we parse, keeping intermediate results on the x87 or SSE stack, or using a software stack. For integers, we can use the system stack (push/pop) to hold operands, and call the appropriate arithmetic helpers.

```nasm
; parse_expression returns value in rax (or uses stack)
; input: nothing, but uses global token pointer r12

parse_expression:
    push rbp
    mov  rbp, rsp
    sub  rsp, 8          ; local space if needed

    ; first parse a term
    call parse_term       ; result in rax
    push rax              ; push as initial left operand

.next_op:
    ; look at current token type
    mov  rdi, [token_array + r12*16]  ; token type field
    cmp  rdi, TOK_PLUS
    je   .add
    cmp  rdi, TOK_MINUS
    je   .sub
    jmp  .done            ; no more operators

.add:
    r12++                 ; consume '+'
    pop  rbx              ; left operand
    call parse_term       ; right operand in rax
    add  rbx, rax
    push rbx
    jmp  .next_op

.sub:
    ; similar with sub
    r12++
    pop  rbx
    call parse_term
    sub  rbx, rax
    push rbx
    jmp  .next_op

.done:
    pop  rax              ; result
    leave
    ret
```

`parse_term` works identically but checks for `*` and `/`. Division requires careful handling of the calling convention – we will use `idiv` after sign‑extending the dividend into `rdx:rax`. In assembly, division and modulus are notoriously tricky; we can write a `safe_div` function.

```nasm
; rbx = left, rax = right
; result in rax
    mov  rax, rbx
    cqo                 ; sign extend rax into rdx
    idiv rax, rcx       ; rax /= rcx? Actually idiv rcx uses rdx:rax / rcx
    ; better:
    mov  rax, rbx
    cqo
    idiv rcx            ; rcx holds divisor (right operand)
```

`parse_factor` handles numbers (return the value), variables (load from memory array `var[0..25]`), parentheses (recursively call `parse_expression`), and unary minus (negate). The variable storage is a simple array of 26 quadwords.

### Parsing Statements

Each statement starts with a keyword token. We decode the keyword and call a handler. For `LET`, we expect `LET var = expr`. The parser calls `parse_variable` to get the variable index, consumes `=`, calls `parse_expression`, and stores the result in `vars[index]`.

`IF` is more complex: `IF expr THEN line-number`. First parse the relational expression (we’ll need to add relational operators to the expression grammar). In Tiny BASIC, the condition uses the same expression parser but returns a boolean – we can define that `<`, `>`, `=` are lowest priority and evaluate to 0 or 1. Then `THEN` is followed by a numeric literal (line number). We do not parse further; we simply remember the target line. But we are not interpreting line by line – we are generating code. So `IF` generates a conditional jump.

`GOTO` is simple: parse a line number and generate an unconditional jump.

`PRINT` can handle multiple expressions separated by semicolons or commas. For simplicity, we just parse one expression (or string) and call a `print_int` or `print_string` routine.

### Recursion and the Call Stack

Note that `parse_expression` calls `parse_term`, which calls `parse_factor`, which may call `parse_expression` (for parentheses). This mutual recursion works fine in assembly because we use the hardware call stack. The only danger is stack overflow on deeply nested expressions. A tiny BASIC program rarely nests beyond 10 levels, so we are safe. However, the stack is also used for temporary holding of operands (the `push`/`pop` in `parse_expression`). We must be careful not to corrupt the return address. Using `rbp` as a frame pointer helps, but in the interest of simplicity we can use a dedicated software stack in memory (e.g., the `.bss` section) to avoid mixing data and return addresses.

For a production JIT, you might avoid recursion altogether and use an iterative algorithm like the **shunting yard**. But recursion in assembly is a beautiful demonstration of low‑level control flow – it’s the same mechanism that C compilers generate.

### Parsing with Error Recovery

When a syntax error occurs (e.g., unexpected token), we should skip the rest of the line and try to continue from the next line. This is easier in a line‑based language like BASIC. In assembly, we can maintain a line counter and, upon error, advance the token pointer until we hit a newline token. That’s a simple loop.

### From Parsing to Code Generation: Why Not a Tree?

At this point, many compiler textbooks construct an Abstract Syntax Tree (AST) and then walk it for code generation. In assembly, walking a tree recursively would be similar to our interpretive parser but would allocate nodes in memory. Instead, we can merge parsing and code generation into a single pass – **syntax‑directed translation**. This is extremely efficient and perfectly captures the spirit of writing a tiny interpreter in assembly. Each parse function emits the corresponding x86‑64 machine instructions directly into a memory buffer. No intermediate representation (IR) is needed. This is exactly how early BASIC interpreters and many simple JIT compilers work.

---

## Code Generation: Emitting Raw x86‑64 Machine Code

The heart of our interpreter is a **code buffer** – a contiguous region of memory that we fill with executable instructions. On Linux, we allocate it with `mmap` (or `malloc` + `mprotect` to make it executable). We maintain a pointer `emit_ptr` (`r14` for convenience) that we advance as we write bytes.

### Generating Code for an Expression

Let’s change our `parse_expression` to output x86-64 instructions instead of interpreting. The goal: after parsing an expression, the generated code will compute the value and leave it in `rax` (or on the x87 stack – but we’ll use integer registers). We need a strategy for register allocation. Our variables are fixed memory locations, so we can load them into registers as needed. For simplicity, we can generate code that always uses `rax` for the left operand and pushes intermediate results onto the stack (using `push`/`pop` instructions). That way we don’t need a sophisticated register allocator.

Consider the expression `3 + 4 * 5`. Our parser (now a code generator) will process as follows:

- `parse_factor` for `3`: emit `mov rax, 3` (but that overwrites any previous rax – we need to push). Instead, a better convention: each term pushes its result onto the stack. So `parse_factor` for a number emits `push 3`. For a variable it emits `push qword [var_addr + index*8]`.

- `parse_term` for `4 * 5`: It sees `parse_factor` for `4` → emits `push 4`. Then sees `*` operator: emits `pop rcx` (right operand), `pop rax` (left operand), `imul rax, rcx`, then `push rax`. Then factor `5` → `push 5`, then combine: left (previous push was the product? Actually after first multiplication we have push result; then next factor push 5; then operator `*` again: pop rcx (5), pop rax (product of 4*?), but that’s wrong because the `*`should associate left. Wait, we must restructure:`parse_term` should use a loop that first pushes the left factor, then for each operator, pop left and right and push result. This works exactly like our interpretive parser but we emit machine instructions.

#### Emitting Instructions as Bytes

To emit `push 3`, we need the opcode for `push immediate`. On x86‑64, `push imm8` is `6A ib`, `push imm32` is `68 id`. Since `3` is small, we can use `6A 03`. For `push dword [var]`, we use `FF /6` with a ModRM byte. But we must compute the correct encoding. Writing a full assembler in assembly is not trivial, but for a tiny BASIC we can pre‑compute instruction templates and fill in immediates and offsets.

Let’s define a few helper macros (or functions) that write specific patterns:

```nasm
; emit_push_imm64: but 64-bit immediate push requires a different opcode.
; Simpler: for integers we can do `mov rax, imm64; push rax`.
; That’s 10 bytes (48 B8 + 8 bytes immediate) + 1 byte push. Overhead but acceptable.

emit_mov_rax_imm64:
    mov  byte [emit_ptr], 0x48    ; REX.W
    mov  byte [emit_ptr+1], 0xB8  ; MOV RAX, imm64
    mov  [emit_ptr+2], imm        ; store 8 bytes
    add  emit_ptr, 10
    ret

emit_push_rax:
    mov  byte [emit_ptr], 0x50    ; PUSH RAX
    inc  emit_ptr
    ret
```

For arithmetic, we need `pop rcx`, `pop rax`, then `imul rax, rcx`, then `push rax`:

```nasm
emit_pop_rcx:
    mov  byte [emit_ptr], 0x59    ; POP RCX
    inc  emit_ptr
emit_pop_rax:
    mov  byte [emit_ptr], 0x58
    inc  emit_ptr
emit_imul_rax_rcx:
    ; two‑operand imul: 48 0F AF C1
    mov  word [emit_ptr], 0x0F48
    mov  byte [emit_ptr+2], 0xAF
    mov  byte [emit_ptr+3], 0xC1  ; ModRM for rax, rcx
    add  emit_ptr, 4
```

This becomes tedious but is entirely doable. Because our instruction set is tiny, we can hardcode the sequences. For division, we need `cqo` (48 99) before `idiv rcx` (48 F7 F9). For addition/subtraction we use `add rax, rcx` (48 01 C8) / `sub rax, rcx` (48 29 C8). All 3‑4 byte patterns.

#### The Advantage: Blazing Speed

Once the code buffer is filled, we can cast it to a function pointer and call it. Because we generate native machine code, the execution of the BASIC program will be as fast as hand‑written assembly – at least for integer arithmetic. This is far superior to a pure interpreter that decodes tokens at runtime. And we did it all in assembly, with no external JIT library.

### Handling Variables and Memory

Variables are stored at a fixed address in `.bss`. We generate code to read/write them using `mov rax, [var_base + index*8]` or `mov [var_base + index*8], rax`. The address `var_base` is known at assembly time (the label). However, our code buffer is separate from the generated program’s text. When we emit instructions that reference absolute addresses, we must ensure the addresses are resolved at emit time (since the code will run from the buffer, the label is not within that buffer). Therefore, we need to embed the absolute address of `var_base` as an immediate. For position‑independent code, we would use RIP‑relative addressing, but for simplicity we can just use a static address (the interpreter itself is a single binary). We can obtain the address at runtime by using `lea rax, [rip + var_base]` but that requires the generated code to be within the same process (it is). Actually, the generated code runs in the same process, so the address of `var_base` is fixed. We can store that address in a register before calling the generated code, say in `r13`. Then generated code can use `mov rax, [r13 + index*8]`. This is efficient and avoids absolute addresses.

So we set up a convention: before jumping to the generated code, we load `r13` with the address of the variables array. All generated code uses `r13` as base.

### Control Flow: IF and GOTO

Tiny BASIC has line numbers. Our parser will need a two‑pass approach or we can use **backpatching**. In a single pass, we parse statements in sequence and generate code. When we encounter a `GOTO 100`, we don’t yet know where line 100’s code will be. We must emit a jump with a placeholder offset and keep a list of `fixups`. After parsing all lines, we go back and fix the offsets.

This is a classic technique in assemblers. We maintain a fixup table: each entry holds the location in the code buffer of a jump displacement that needs to be filled with the target address minus the address of the next instruction. For `IF expr THEN line`, we emit a comparison (e.g., compare rax with 0), then a conditional jump (e.g., `jz .next_line`) but we need to jump to the line’s code.

We can resolve by scanning the parsed line number table. Suppose we store the starting address of each line’s generated code in an array indexed by line number (line numbers are small, e.g., 1..999). Upon seeing `GOTO 100`, we look up `line_addrs[100]` and if it is already known (the line was parsed earlier), we emit a direct `jmp` with the correct offset. If not yet known, we emit a `jmp` with a dummy offset and record the fixup. After generating all code, we resolve all pending fixups.

In a tiny interpreter, the number of lines is small, so we can afford a second pass. As we parse, we don’t generate final code until we know all line addresses. One approach: first parse all lines and build a list of tokens for each line (a line‑based token stream). Then do code generation in line order. That gives us the addresses before any jumps. However, forward references still require fixups (line numbers may refer to later lines). So we still need backpatching.

#### Example: Generating an IF statement

```
IF A > 10 THEN 50
```

First, parse the relational expression `A > 10`. Our expression parser for relational operators will generate code that computes `A` (load variable), then `10` (push 10), then `cmp rax, rcx` and `setg` to produce 0/1. For simplicity, we can instead generate:

- `mov rax, [r13 + var_A*8]`
- `mov rcx, 10`
- `cmp rax, rcx`
- `jle .skip` (if condition false, jump over the THEN code)
- (then code to jump to line 50)
- `.skip:`

But we cannot generate the jump to line 50 until we know its address. So we emit a `jmp` with a dummy 4‑byte displacement, record the fixup, then later patch.

### Real‑World Application: JIT Compilation in the Browser

The technique we just described – parsing a high‑level language and emitting x86‑64 machine code on the fly – is exactly how modern JavaScript engines (V8, SpiderMonkey) achieve high performance. They use a baseline compiler that quickly generates code without much optimization. The browser’s **JIT** (Just‑In‑Time) compiler does exactly what we are doing: lex, parse, generate native code, and execute. By writing a tiny version in assembly, you gain a visceral understanding of the foundations of modern execution environments.

### Challenges and Pitfalls

- **Memory permissions**: The code buffer must be readable, writable, and executable. On modern Linux, you allocate with `mmap` using `PROT_READ | PROT_WRITE | PROT_EXEC`. An alternative is to use `mprotect` on a `malloc`’d page, but `mmap` is cleaner.
- **Calling C library functions**: If we want `PRINT` to output to the terminal, we can generate calls to `printf` (or write syscalls). To call an external function, we must align the stack (16‑byte alignment before `call`), which we can enforce by ensuring the generated code adjusts RSP appropriately. For simplicity, you might implement a simple integer print routine in assembly and call it via `call print_int` (where `print_int` is part of our interpreter binary). That requires RIP‑relative addressing; we can use `lea rax, [rip + print_int]` and then `call rax` in the generated code.
- **Stack discipline**: If we use the x86‑64 stack heavily in generated code (push/pop for expression evaluation), we must ensure that the stack pointer returns to its original value after the generated code finishes. Our main code buffer function is just a subroutine; it can use the caller’s stack.
- **Error handling at code generation**: If we detect a division by zero or an undefined variable at compile time, we can emit an immediate jump to an error handler. Runtime errors (e.g., division by zero) require us to insert checks – `test rcx, rcx; jz .error`.

### Putting It All Together: A Complete Example

Let’s write a mini‑program in Tiny BASIC:

```
10 LET A = 5
20 LET B = A + 3
30 PRINT B
40 END
```

Our lexer produces tokens. Our parser, seeing `LET`, will emit:

1. Load variable index for A.
2. Parse expression `5` → emit `mov rax, 5`.
3. Emit `mov [r13 + index*8], rax`.

For line 20, it loads A, adds 3, stores to B.

For line 30, it loads B, then calls a `print_int` function (which we pre‑generated and know its address).

Line 40 emits `ret` (end of program).

After generating all code, we jump to the start of the code buffer. The generated program runs and prints `8`.

### Optimizations (Optional)

Once the basic framework works, you can experiment with simple optimizations:

- **Constant folding**: If an expression reduces to a constant, you can compute it at compile time and emit a single `mov` instead of arithmetic instructions.
- **Register allocation**: Instead of pushing/popping for every subexpression, you could allocate variables to registers (e.g., using a linear scan). This is a major challenge but rewarding.

---

## Conclusion (for the main body)

Writing a tiny BASIC interpreter in x86‑64 assembly is a deep dive into the core of computing. You peel back layers of abstraction – from tokens to machine code – and learn how even the simplest language can be brought to life with raw hardware instructions. The lexer teaches you character‑level parsing; the parser reveals the beauty of recursive structure; and the code generator shows you how to become your own assembler. While this project is academic, the principles are exactly those used in production JIT compilers, SQL engines, and even hardware simulators. Every line of assembly you write for this interpreter is a brick in your understanding of how languages and machines talk to each other.

Now, go ahead – fire up your text editor, an assembler (NASM, FASM), and a linker. Start with a lexer that reads a string, and build up, one instruction at a time. You might be surprised how far a few thousand lines of assembly can take you.

# Writing A Tiny Basic Interpreter In Assembly: Lexing, Parsing, And Code Generation For X86_64

Building a toy interpreter is a rite of passage for many programmers, but doing it entirely in assembly—specifically x86_64—takes the exercise from academic to nearly masochistic. Yet the rewards are immense: you gain a visceral understanding of how high‑level constructs map to machine code, how lexers and parsers work under the hood, and what it really means to generate code at runtime. In this post, we’ll walk through advanced techniques for implementing a tiny BASIC interpreter directly in x86_64 assembly (NASM syntax). We’ll go beyond the basics and cover edge cases, performance pitfalls, and expert best practices that turn a toy into a solid, production‑ready micro‑interpreter.

## 1. The Big Picture: Why Assembly?

You might ask: why not write the interpreter in C and let the compiler handle optimisation? True, but writing in assembly forces you to confront every detail—register allocation, stack discipline, memory layout, and the exact sequence of bytes that form a running program. For a **tiny** BASIC interpreter, the goal is often minimalism (think sub‑4 KB executables) or extreme performance for a niche domain (e.g., embedded scripting). An assembly‑written interpreter can also act as a primitive JIT compiler: we emit x86‑64 instructions directly into executable memory, skipping the overhead of a VM.

This post assumes you’re comfortable with x86_64 assembly, NASM syntax, and the System V AMD64 ABI. We’ll use Linux syscalls for I/O.

---

## 2. Lexing: The Art of Tokenising at the Metal

### 2.1. Token Structure

In a typical high‑level language, tokens are objects or structs. In assembly, we represent tokens as fixed‑size records in memory. A tiny BASIC needs only a handful of token types: `NUMBER`, `STRING`, `KEYWORD` (LET, PRINT, IF, GOTO, etc.), `OPERATOR` (+, -, \*, /, =, <, >, <=, >=), `IDENTIFIER`, and `EOF`. A token record might be 8 bytes (type + value) or even 4 bytes if we’re cramped.

```
struc token
    .type:   resb 1     ; e.g., 0=NUMBER, 1=KEYWORD, ...
    .value:  resd 1     ; union: for NUMBER -> integer, for KEYWORD -> enum index, for STRING -> pointer
    .line:   resw 1     ; optional, for error reporting
endstruc
```

### 2.2. Zero‑Copy Lexing

Lexing a line of BASIC source (likely single‑stepped or line‑numbered) can be done directly over the input buffer without copying characters. This is critical for performance: every `movsb` or `rep movsb` costs cycles. Instead, we maintain a pointer (`rsi`) and advance it as we recognise tokens.

**Advanced technique**: use a lookup table for character classification. Build a 256‑byte table (aligned to 256 for fast indexing) that tells you with a single `mov al, [table + rcx]` whether a byte is a digit, letter, whitespace, operator start, etc. This avoids branches.

```nasm
; Class table: 0 = other, 1 = digit, 2 = letter, 3 = whitespace, 4 = operator char
char_class:  times 256 db 0
; ... fill table at init
```

Then lexing becomes:

```nasm
get_char:
    movzx eax, byte [rsi]      ; current character
    movzx ebx, byte [char_class + rax]
    ; decide what to do based on ebx
```

**Edge case**: multi‑character operators like `<=` or `>=`. After reading the first operator character (e.g., `<`), peek at the next byte. If it’s `=` or `>`, consume it as well and emit the combined token. Handle `=` separately: it’s both assignment and equality test depending on context; in tiny BASIC, it’s usually `LET A = 5` (assignment) and `IF A = 5` (equals). The parser will disambiguate.

**Whitespace handling**: skip all whitespace (including tabs and newlines) before each token. But keep a copy of the current line pointer for error messages. A common pitfall is not skipping trailing spaces inside string literals – strings in BASIC are usually delimited by double quotes and can contain spaces.

**Error recovery**: In assembly, error handling is often a `jmp` to a fatal error routine with a message. For a more robust lexer, you can implement a simple “panic mode”: skip characters until a newline or a known good token start is found. This requires tracking the line number separately.

### 2.3. Performance Consideration: Avoiding Division

Lexing numbers: converting a decimal string to an integer usually involves repeated `mul` (multiply) and `add`. However, `mul` is slow on some microarchitectures (especially older ones). For a tiny interpreter, you can use a small loop with `imul` and `add`:

```nasm
; input: rsi points to start of digits, rcx = length (could be unknown)
; output: eax = integer
xor eax, eax
.next_digit:
    movzx edx, byte [rsi]
    sub edx, '0'
    imul eax, 10
    add eax, edx
    inc rsi
    dec rcx
    jnz .next_digit
```

**Advanced trick**: for extremely fast conversion, use a precomputed table of powers of 10 and a sequence of `lea` instructions to multiply by 10 without `imul`: `lea eax, [eax*4 + eax]` gives `eax*5`, then `lea eax, [eax*2 + eax]`? Actually, `eax*10 = (eax*4+eax)*2`, which can be done with two `lea`s if available. However, on modern x86_64, `imul` with a small constant is often just as fast (3 cycle latency) and much simpler.

---

## 3. Parsing: Recursive Descent Without the Recursion

### 3.1. Left Recursion and Operator Precedence

Tiny BASIC’s expressions are simple: arithmetic (+, -, \*, /) as well as relational operators. A straightforward recursive descent parser can run into left recursion for binary operators. The standard solution is to write a **Pratt parser** (top‑down operator precedence). In assembly, this means implementing a table of operator bind power and calling functions based on token type.

**Duplicate**: a Pratt parser typically uses a while loop and a stack of operators. In assembly, we can implement the loop using registers for the current token and a small stack (in memory) for the operand nodes. The stack depth is limited (tiny BASIC expressions are rarely deeply nested), so using a fixed‑size buffer (e.g., 64 entries) is acceptable.

**Best practice**: store intermediate results as pointers to **abstract syntax tree (AST)** nodes in a custom allocator. For a tiny interpreter, you can forgo an AST altogether and directly generate code or evaluate on the fly. However, for control flow (IF, GOTO), you need at least a pre‑parse to collect line numbers. **Hybrid approach**: parse into a flat, simple intermediate representation (IR) that is essentially a list of instructions (opcode + operands). This is often called a **bytecode**, but we can emit real machine code instead.

### 3.2. Expression Parsing in Assembly (Pratt Style)

Assume we have a `peek_token` and `consume_token` function. We assign each token a left‑binding power (lbp). For example:

| Token       | lbp |
| ----------- | --- |
| NUMBER / ID | 0   |
| +, -        | 10  |
| \*, /       | 20  |
| <, >, =     | 5   |

The main parsing loop:

```
parse_expression(min_lbp):
    token = peek()
    if token.type in (NUMBER, IDENTIFIER):
        node = make_leaf(token)
        advance()
    else:
        error()
    while peek_token.lbp >= min_lbp:
        operator = peek()
        advance()
        right = parse_expression(operator.lbp + 1)
        node = make_binop(operator, node, right)
    return node
```

In assembly, this is a sequence of calls and jumps. The `peek` and `consume` routines must be fast—ideally they just increment a token index and return the next token record. Use `lea` to load the token base address plus index \* sizeof(token).

**Common pitfall**: forgetting to handle unary minus. In BASIC, `-5` is allowed. We can treat `-` as a prefix operator with very high binding power (like 30) only when the previous token was an operator or start‑of‑expression. This requires tracking context.

### 3.3. Handling IF and GOTO

Control flow in tiny BASIC is line‑based. `IF X > 0 THEN 100` means: evaluate condition; if true, jump to line 100; else continue. `GOTO 200` is unconditional.

The parser must resolve line numbers. During parsing, when encountering a literal number that looks like a line reference (after THEN or GOTO), we should look it up in a table that maps line numbers to their positions in the source or, better, to their eventual code addresses. This is similar to a symbol table but for line numbers.

**Advanced**: You can implement a two‑pass system: first pass collects all line numbers and their positions; second pass generates code. In assembly, this means storing line numbers and the offset where they appear into a sorted array, then emitting fix‑ups (like JMP rel32 offsets) during code generation.

### 3.4. Error Messages

Parsing mistakes (e.g., missing operand, extra token) should produce helpful messages. Write a small `error` function that prints the current line number and a character pointer (the offending token). Remember to keep the line number in a global variable (`.bss`) and update it whenever you encounter a CR/LF.

---

## 4. Code Generation: Writing Machine Code at Runtime

### 4.1. Straight‑Line Code vs. JIT

The simplest approach is a **tree‑walker** interpreter: evaluate the AST recursively in assembly. This is slow because each node overhead includes function calls and stack management. Instead, we can **compile** the expression into a sequence of x86‑64 instructions stored in a **code buffer**, then execute that buffer. This is the essence of a tiny JIT compiler.

Your code buffer should be mmap’d with `PROT_READ | PROT_WRITE | PROT_EXEC`. Allocate a generous size (e.g., 4 KB per expression). Keep a pointer (`r12`) that tracks the next free byte.

### 4.2. Register Allocation (Simplified)

For tiny BASIC, we can use a simple scheme: use `rax` and `rdx` as work registers for arithmetic. All variables (e.g., `A`, `B`) are stored in a small array in memory (say, 26 elements for A‑Z). When compiling an expression, we load a variable into `rax`, push `rax` to stack if needed for binary ops, then combine.

**Example compilation of `A + B * C`**:

```
load A into rax
push rax
load B into rax
push rax
load C into rax
pop rbx   ; rbx = B
imul rbx, rax   ; rbx = B * C
pop rax   ; rax = A
add rax, rbx
```

The generated code might look like:

```nasm
mov rax, [var_A]
push rax
mov rax, [var_B]
push rax
mov rax, [var_C]
pop rbx
imul rbx, rax
pop rax
add rax, rbx
; final result in rax
```

**Edge case**: division. `idiv rbx` requires sign‑extending `rax` into `rdx` (use `cqo` before division). Also, division by zero must be checked; at runtime, we can insert a conditional jump to an error handler. For performance, you may avoid runtime division checks if your language guarantees (or you can prove) divisor ≠ 0.

### 4.3. Relocatable Code and Jumps

For `IF` and `GOTO`, we need to emit conditional jumps. For example, `IF A = 5 THEN 100` compiles to:

```
compute A into rax
cmp rax, 5
jne .skip
; jump to code for line 100
.skip:
; continue
```

But we don’t know the address of line 100’s code yet (it may be forward reference). So we emit a **placeholder** jump and later patch the offset. This requires storing a list of `{ address_of_jump, target_line }` entries. After all code is generated (or after the second pass), we resolve them.

**Performance consideration**: Use `jmp rel32` (5 bytes) for forward jumps to avoid unnecessary NOPs. For backward jumps (loops), you already know the offset at generation time, so you can emit the correct displacement immediately.

### 4.4. Calling System Calls and Library Functions

BASIC’s `PRINT` needs to output numbers or strings. We can’t call `printf` from raw assembly easily (without linking libc). Instead, use Linux `write` syscall. Convert an integer to a decimal string in a scratch buffer, then call `syscall`. This conversion loop should be similar to the lexer’s integer‑to‑string, but reversed.

**Best practice**: keep a small stack‑allocated buffer (128 bytes). For performance, avoid division for each digit; you can use a small lookup table of powers of 10 and repeated subtraction, but division is fine for a tiny interpreter.

### 4.5. Stack Alignment

System V ABI requires the stack to be 16‑byte aligned before a `call` instruction. If you generate code that eventually calls a C function (like `printf` or `exit`), you must ensure proper alignment. Usually, after your prologue (push rbp?), you have `%rsp` mod 16 = 8. Then before calling a function, you need to `push` a dummy register to align. Keep a note in your code generator: maintain a pseudo‑stack depth that tracks pushes/pops; at any call site, adjust.

**Common pitfall**: forgetting to restore stack pointer after an error that long‑jumps. Use a fixed stack frame at the start of each interpreted program; avoid growing the hardware stack arbitrarily.

---

## 5. Putting It All Together: The Interpreter Loop

The main loop:

1. Read a line from stdin (or a program file).
2. Lex the entire line into a token buffer.
3. Parse tokens, building IR or directly generating code into the executable buffer.
4. For non‑control‑flow statements (LET, PRINT), the generated code can be executed immediately. For IF/GOTO, we store the generated code in a table indexed by line number.
5. After all lines are processed, we resolve jump fix‑ups.
6. Execute the program from the first line’s code buffer.

**Edge case**: `END` or `STOP`. Emit a `ret` instruction. The interpreter itself can be called as a subroutine from your main assembly wrapper.

**Performance**: Executing generated code directly is orders of magnitude faster than a tree walker. However, the lex/parse/codegen pass per line adds overhead. For small programs, the overhead dominates; for larger programs with many statements, JIT pays off.

### 5.1. Self‑Contained Executable

Your interpreter should be a single assembly source file that uses only syscalls (no libc). The generated code buffer should only refer to memory addresses inside the interpreter’s data segment (variables array, output buffer). Ensure that the code buffer is located in an executable region – use `mmap` or a fixed‑size `.text`‑like section that you mark writable and executable (not recommended for security).

**Best practice**: allocate a region of memory with `mmap(NULL, size, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)`. This is safe and portable.

---

## 6. Edge Cases and Pitfalls

- **Empty line / comment**: Skip lines starting with `REM` or just whitespace. Do not generate code.

- **Overflow**: `ADD` and `MUL` can overflow. In tiny BASIC, typically wrap to 16‑bit or 32‑bit integers. Decide on a fixed size (32‑bit signed). Use `jo` (jump if overflow) to an error routine if you want to detect overflow, or simply let it wrap silently (like most BASICs).

- **Variable initialisation**: All variables default to zero. In your generated code, before loading a variable, you may want to zero it only once. Since variables are in a fixed memory block, they are zero‑filled at program start (since `.bss` is zeroed by OS). Good.

- **Division by zero**: Insert a test before `idiv`. For example:

  ```nasm
  test rbx, rbx
  jz .error_div_zero
  cqo
  idiv rbx
  ```

  This adds two instructions per division. In a tiny interpreter, it’s a small overhead but important for safety.

- **Multiple statements per line**: Some BASIC dialects allow `:`. After lexing, you may parse each statement separately and chain generated code sequentially.

- **String literals in PRINT**: Strings are not evaluated; you can generate code that loads the address of the string literal (stored in a separate data area) and then calls a print routine.

---

## 7. Advanced Optimisations

- **Constant folding**: While parsing, if both operands are constants, compute the result at compile time and emit only a `mov rax, const`. This eliminates arithmetic code.

- **Peephole optimisation**: After generating code, scan the buffer for redundant `push/pop` pairs (e.g., `push rax; pop rax`). Replace them with zero bytes (NOPs) or remove completely. In assembly, you can write a small patcher that runs after code gen.

- **Register caching**: Use a small register file (e.g., keep the most recent value in `rax`, another in `rcx`, etc.) to avoid memory loads. This is complex but can halve the number of instructions.

- **Inline constant loading**: Instead of `mov rax, [var_A]`, you might prefer to load immediate if the variable is known at compile time (e.g., always zero for uninitialised). However, variables can change at runtime, so this only applies to constants.

---

## 8. Best Practices for Assembly Interpreter Development

1. **Plan your register usage**:
   - `r12`: code buffer pointer (write pointer)
   - `r13`: current token index
   - `r14`: token base address
   - `r15`: variable array base
     Keep a comment at the top of the file documenting the register convention.

2. **Use macros for common patterns**:

   ```nasm
   %macro EMIT 1
       db %1
   %endmacro
   %macro EMIT_BYTE 1
       mov byte [r12], %1
       inc r12
   %endmacro
   %macro EMIT_DWORD 1
       mov dword [r12], %1
       add r12, 4
   %endmacro
   ```

   This makes code generation readable.

3. **Unit test each component separately**. Write a test harness in assembly that calls your lexer, parser, compiler with known inputs and checks the output against expected bytes.

4. **Keep error messages in a separate read‑only section** (`.rodata`). Use `write` syscall to output them.

5. **Use version control and incremental builds**. Even a tiny interpreter will have many iterations; a large `.asm` file can become unwieldy.

---

## 9. Deeper Insight: Why Not a Full Tree‑Walker?

A tree‑walker that recursively visits AST nodes is simple to implement in high‑level languages. In assembly, recursion consumes stack frames and function calls, which are slow and complex to manage (especially with dynamic allocation). Generating native code removes the interpretive overhead entirely. For a tiny BASIC, the code generated for a single expression may be 20‑30 bytes – easily executed in nanoseconds. The overhead of code generation (lexing + parsing + emitting bytes) is the dominant cost, but it is a one‑time cost per line; the execution then runs at near‑native speed. This makes your interpreter competitive with compiled languages for the specific domain of simple scripts.

---

## Conclusion

Writing a tiny BASIC interpreter in x86_64 assembly is a deep dive into the heart of language implementation and low‑level optimisation. By implementing a hand‑rolled lexer, a Pratt parser, and a direct‑to‑machine‑code code generator, you gain a visceral appreciation for how interpreters work from the bottom up. The discipline required to manage registers, memory, and alignment teaches best practices that carry over to any systems programming. The final product – a self‑contained, blisteringly fast mini‑BASIC – is a testament to what can be built with minimal tools and maximal understanding.

So take your favourite assembler (NASM, FASM, or even the raw assembler of your choice), allocate an executable buffer, and start emitting bytes that compute `LET X = 1 + 2 * 3`. The journey from lexer to JIT is one every serious programmer should take at least once.

# Conclusion: The Art of Building from Nothing

## A Journey Through the Bare Metal

We began this series with a simple question: what does it take to make a computer understand a high-level language like Tiny Basic? The answer, as we discovered, is a journey through three distinct layers of interpretation — lexing, parsing, and code generation — all implemented in the most unforgiving of environments: x86‑64 assembly. By the end, we had a working interpreter that could parse `PRINT 2 + 3 * 4` and execute it on real hardware, without relying on any runtime, operating system services, or even a standard library. That is no small feat.

Let’s recap the key milestones. First, we built a lexer that chewed through a stream of ASCII characters and produced tokens — numbers, keywords, operators, and newlines. Every character had to be inspected, categorized, and converted into a small integer code, all while managing a buffer with naive but functional pointer arithmetic. The lexer taught us that even the simplest tokenization requires careful handling of edge cases: multi‑character keywords like `PRINT`, negative numbers, and whitespace between tokens.

Next came the parser. We chose a recursive descent approach because it mirrors the grammar most naturally and is easy to implement even in assembly. The parser’s job was to consume tokens and build an Abstract Syntax Tree (AST) in memory. Each node was a fixed‑size structure — three words: an opcode and two pointers (or values). We dealt with operator precedence by writing separate functions for addition/subtraction and multiplication/division, each calling down to the next level. The challenge wasn’t the algorithm; it was managing the call stack, preserving registers, and ensuring that we never leaked memory. Every time we allocated a node, we had to commit it to a simple bump‑allocator arena because dynamic memory management in assembly is a rabbit hole we wisely avoided.

The final layer was code generation. This is where the interpreter became a compiler: we walked the AST and emitted real x86‑64 machine code into a freshly allocated block of executable memory. Emitting `ADD` or `SUB` instructions based on the AST operators, loading immediate values into registers, resolving the order of operations by the shape of the tree — all done by writing raw bytes. We then used a function pointer to jump into that generated code and execute it, bringing the Tiny Basic program to life. The most delicate part was making sure the generated code conformed to the calling convention (System V AMD64 ABI) so that control could return cleanly to our interpreter.

## Actionable Takeaways: Lessons from the Trenches

Writing an interpreter in assembly is not practical for production software, but it is an unparalleled learning experience. Here are the takeaways that will serve you long after you close this series:

**1. Every abstraction you take for granted has a cost.**  
When you are forced to manage registers manually, parse numbers byte by byte, and emit machine code, you develop a deep appreciation for what lexers, parsers, and code generators do automatically in higher‑level languages. The next time you write a Python decorator or a C macro, remember that underneath it all is a chain of transformations as mechanical as the code we wrote.

**2. Simplicity is not weakness; it is survival.**  
Our interpreter had no garbage collector, no hash tables, and no dynamic memory beyond a simple arena. That forced us to make honest trade‑offs: a linear‑search symbol table that worked for ten variables but would fail for ten thousand; a recursive descent parser that couldn’t handle left‑recursive grammar; a code generator that only supported a handful of expressions. These limitations were not bugs — they were conscious design decisions that kept the project small enough to fit in a human brain. When building anything from scratch, start tiny and extend only when necessary.

**3. Testing at the byte level is essential.**  
Assembly has no type system and the debugger often shows you the wrong line. We learned to write unit tests for the lexer by comparing token streams, tests for the parser by printing the AST structure, and tests for code generation by executing the generated code in an isolated environment (we used a small test harness that called our interpreter from C). Without these tests, one wrong `MOV` operand would have sent us on a wild goose chase. Adopt a test‑first mentality even for “low‑level” work.

**4. The boundary between interpreter and compiler is porous.**  
Our interpreter did not execute the AST directly; it compiled it to machine code on the fly. That is exactly what a JIT compiler does, albeit with far more sophistication. You now understand the core mechanism behind language implementations like LuaJIT, PyPy, and V8’s Turbofan. The same concepts — lexing, parsing, intermediate representation, machine code generation — scale from a toy interpreter to the most advanced runtimes.

## Next Steps: Where to Go From Here

You now have a foundation that most programmers never build. What you do with it is limited only by ambition. Here are several paths you can take:

**Extend the language** – Add `GOTO`, `IF`, `FOR` loops, and string variables. Each addition will test your parser’s resilience and your code generator’s flexibility. I suggest implementing a simple state machine for the parser to handle loops without recursion, as deep recursion in assembly can quickly overflow the stack.

**Explore intermediate representations** – Our AST was the IR, but you could add a three‑address code (TAC) layer between parsing and code generation. This would decouple parsing from target‑specific details and make it easier to add optimizations like constant folding or dead code elimination.

**Port to a different architecture** – Try ARM64 or RISC‑V. The lexer and parser are architecture‑independent, but the code generator will need to learn new instruction encodings, calling conventions, and register sets. This exercise will solidify your understanding of CPU design.

**Study production interpreters** – After this hands‑on experience, read the source code of a small JITed language like LuaJIT or a Forth system such as Jonesforth. You will recognize patterns and appreciate the enormous engineering effort that goes into handling complexity we deliberately avoided.

**Read the classics** – _Compilers: Principles, Techniques, and Tools_ (the Dragon Book) will give you the theory behind parsing and code generation. _Linkers and Loaders_ by John Levine will explain what happens after you emit machine code. _The Art of Assembly Language Programming_ by Randall Hyde will teach you to think in assembly more fluently.

**Build a real JIT** – If you are feeling bold, extend your interpreter to cache compiled versions of frequently executed blocks — a simple form of tracing JIT. This will require handling self‑modifying code, memory protection (mprotect), and invalidation mechanisms. It is a deeply rewarding challenge.

## A Strong Closing Thought

We live in a world of towering stacks of abstractions. Each day, we write code in languages that are themselves compiled or interpreted by other languages, which run on operating systems that are written in yet other languages, all sitting atop microcode and silicon. It is easy to forget that at the bottom of that stack is a machine that knows nothing but ones and zeros, waiting for instructions we must give it.

By writing a Tiny Basic interpreter in assembly, you have walked that stack from top to bottom. You have seen the raw material of computation — the bytes, the registers, the jumps — and you have shaped it into something that can understand and execute human‑readable programs. That act of creation, building a language interpreter from nothing but opcodes, is a humbling and empowering experience. It reminds us that every piece of software, no matter how sophisticated, was once an idea in someone’s mind, made real through the same fundamental steps: lex, parse, generate.

The computer is a perfectly obedient servant, but only if we speak to it with absolute precision. Assembly is that precision, and a Tiny Basic interpreter is a conversation between you and the machine. Now that you know how to start that conversation, you can teach the machine to speak any language you imagine. Keep coding, keep building from nothing, and never lose the wonder that a few thousand bytes of assembly can bring a tiny language to life.
