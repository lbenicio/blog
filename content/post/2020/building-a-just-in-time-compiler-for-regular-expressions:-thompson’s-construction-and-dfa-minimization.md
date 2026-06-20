---
title: "Building A Just In Time Compiler For Regular Expressions: Thompson’S Construction And Dfa Minimization"
description: "A comprehensive technical exploration of building a just in time compiler for regular expressions: thompson’s construction and dfa minimization, covering key concepts, practical implementations, and real-world applications."
date: "2020-09-17"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/building-a-just-in-time-compiler-for-regular-expressions-thompson’s-construction-and-dfa-minimization.png"
coverAlt: "Technical visualization representing building a just in time compiler for regular expressions: thompson’s construction and dfa minimization"
---

# The Blinking Cursor and the Invisible Machine

There is a moment, familiar to every software engineer, that feels almost magical. You are staring at a massive log file—tens of thousands of lines—and you need to find every line containing a malformed IP address. You type a command: `grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'` and hit enter. The cursor blinks once. Twice. Before you can even lift your finger from the keyboard, a list of results appears, filtered from the noise in milliseconds.

Inside your editor, you want to refactor a codebase. You invoke a Find-and-Replace all for `var (.*) = function\((.*)\)` and replace it with `const $1 = ($2) =>`. Again, the operation completes so fast it feels synchronous, as if the machine was waiting for you to ask.

We take this speed for granted. We assume that because the CPU runs at gigahertz speeds, any "simple" string operation should be fast. But regular expressions are not simple. They are, in fact, a tiny, domain-specific programming language embedded inside every major text editor, programming language, and command-line tool. Every time you type a regex, you are writing a program. The question is: who compiles that program, and how do they make it run so damn fast?

The answer is a hidden stack of computer science that sits between your keystroke and the screen. It is a bridge that connects the abstract mathematics of automata theory to the raw silicon of your CPU. It is a story that involves a 1960s paper by a Turing Award winner, a technique for making state machines "optimal," and the modern art of generating machine code on the fly. This blog post is about how you can build the engine that sits behind that blinking cursor: a Just-In-Time (JIT) compiler for regular expressions.

### Why This Matters: Beyond the Command Line

Before we dive into the weeds of Thompson’s Construction and state tables, we must ask: why does this matter _today_? After all, we already have incredibly fast regex libraries—PCRE, RE2, Rust’s `regex` crate—that handle billions of operations per second. But the principles behind them are the same principles behind modern compilers, interpreters, and even hardware design. Understanding the theory of finite automata and the practice of just-in-time compilation gives you a lens through which you can see the entire stack of computing: from formal language theory to CPU branch prediction. More practically, building your own regex engine—even a toy one—is one of the most satisfying and educational projects you can undertake. It ties together parsing, state machines, optimization, and code generation.

In this post, we will:

- **Explore the theoretical foundation**: regular expressions, nondeterministic finite automata (NFAs), and deterministic finite automata (DFAs).
- **Build the intermediate representation**: convert a regex to an NFA using Thompson’s Construction.
- **Determinize the NFA**: subset construction and DFA minimization.
- **Simulate efficiently**: from table-driven interpreters to direct execution.
- **Cross the final frontier**: generate native machine code on the fly—our own JIT compiler for regexes.

By the end, you will have a mental model of how a regex engine works, and you’ll be equipped to write one yourself (or at least appreciate the engineering marvel inside the tools you use every day).

---

## 1. Regular Expressions and Automata Theory

### What is a Regular Expression?

Formally, a regular expression is a notation for describing a **regular language**—a set of strings over a finite alphabet that can be recognized by a finite automaton. The modern syntax (`.` for any character, `*` for zero or more, `+` for one or more, `?` for optional, `[abc]` for character classes, `|` for alternation, `()` for grouping) is a convenience layer built on top of a more primitive algebra.

The classic regular expression “calculus” consists of three base operations:

- **Concatenation**: `AB` matches a string where `A` is followed by `B`.
- **Alternation**: `A|B` matches either `A` or `B`.
- **Kleene star**: `A*` matches zero or more repetitions of `A`.

All other constructs (like `+` and `?`) can be derived from these three. For instance, `A+` is equivalent to `AA*`, and `A?` is equivalent to `A|ε` (ε denotes the empty string). Character classes like `[a-z]` are shorthand for a large alternation of characters.

### NFAs and DFAs: The Two Faces of Recognition

A **finite automaton** is a mathematical machine with a finite set of states. It reads an input string one symbol at a time and transitions between states based on the symbol. If after reading the entire string the machine ends in an accepting state, the string is accepted.

There are two flavors:

- **Nondeterministic Finite Automaton (NFA)**: For a given state and input symbol, there may be zero, one, or multiple possible next states. It can also have **epsilon transitions** that move from state to state without consuming any input symbol. The NFA “guesses” which path to take; if any path leads to acceptance, the string is accepted.
- **Deterministic Finite Automaton (DFA)**: For every state and input symbol, there is exactly one next state. No epsilon transitions. The DFA is a pure “follow the rules” machine.

Why two models? NFAs are much easier to construct from a regular expression—Thompson’s Construction yields an NFA with a number of states linear in the length of the regex. DFAs are more complex to construct (exponential worst-case explosion in states) but are much faster to simulate: O(n) time for an n-character input, with no backtracking. The classic regex engine trade-off is between compilation time (NFA to DFA conversion can be expensive) and execution time.

### The Limits: Regular Languages

Not all patterns are regular. For example, matching balanced parentheses or HTML tags requires a context-free grammar, which a finite automaton cannot handle. But in practice, most pattern matching tasks are regular. Even backreferences (like in `(a*)\1`) are not regular; they require a pushdown automaton or backtracking. That’s why some regex engines (like PCRE) can be exponentially slow on certain inputs—they implement a more powerful model by allowing backtracking.

We will stick to pure regular expressions (no backreferences, no recursive patterns) because they admit efficient, linear-time matching via DFA execution. This is the model used by RE2 and Rust’s regex library.

---

## 2. Building the Automaton: Thompson’s Construction

In 1968, Ken Thompson—co-creator of Unix and the B programming language—published a short paper titled “Regular Expression Search Algorithm.” He described a method for converting a regular expression into an NFA. The key insight is that the NFA can be built recursively from the structure of the regex, with each subexpression contributing a small “fragment” of states.

Let’s recall the three base operations (and how to handle ε). We’ll represent an NFA fragment as a small graph with a single start state and a single accept state (or multiple, but Thompson used a unique accept). Epsilon transitions are represented as arrows labeled with ε.

### Base: Single Character

For a character `c`, we create two states: a start state `s` with a transition on `c` to an accepting state `a`.

```
s --c--> a
```

### Concatenation: `AB`

Given fragments for `A` (start s1, accept a1) and `B` (start s2, accept a2), we connect a1 to s2 with an ε transition. The combined fragment has start s1 and accept a2.

```
s1 --[A]--> a1 --ε--> s2 --[B]--> a2
```

### Alternation: `A|B`

We create a new start state `s` with two ε transitions, one to the start of the `A` fragment and one to the start of the `B` fragment. The two accept states (a1, a2) each have an ε transition to a new accept state `a`.

```
        --ε--> s1 --[A]--> a1 --
      /                         \
s --<                           >--ε--> a
      \                         /
        --ε--> s2 --[B]--> a2 --
```

### Kleene Star: `A*`

We insert a “loop”: create a new start state `s` and a new accept state `a`. Add an ε transition from `s` to the start of the `A` fragment, an ε transition from the accept of `A` back to the start of `A` (for repetition), and an ε transition from `s` directly to `a` (for zero repetitions). Also an ε transition from the accept of `A` to `a`.

```
        --ε--> s1 --[A]--> a1 --ε--
      /         |                 |
s --<           |                 >--ε--> a
      \         |                 |
        --ε----- ε ---------------
```

Actually simpler: typical construction: `s` —ε→ `a` and `s` —ε→ start of `A`; accept of `A` —ε→ `s` (back to start) and —ε→ `a`. This gives zero or more repetitions.

For `A+` we would omit the direct `s`—ε→`a` edge.

With these fragments, any regex can be parsed into an AST (abstract syntax tree) and then transformed into an NFA. The total number of states is at most twice the number of characters and operators in the regex.

### Example: `a*b|bc`

Let’s build the NFA for this regex manually. We’ll follow the recursive construction:

1. `a*`:
   - Fragment for `a`: states 0 (start) →1 (accept) on `a`.
   - Apply Kleene star: new start 2, new accept 3. Edges:
     - 2 --ε→ 3 (zero repetitions)
     - 2 --ε→ 0 (start of a fragment)
     - 1 --ε→ 2 (back to loop)
     - 1 --ε→ 3 (exit after at least one)
       Actually typical: add new start 2, new accept 3; 2 --ε→ 0; 1 --ε→ 2; 1 --ε→ 3; 2 --ε→ 3.
2. `b`: states 4→5 on `b`.
3. `a*b|bc`: alternation. First part is `a*b` (concatenate a\* with b):
   - Combine a\* (states 2,3? Wait we need clear). Let's create fresh states.
     Better to number directly.

I’ll use a systematic approach: each fragment has its own start and accept indices. For brevity, the resulting NFA for `a*b|bc` will have about 10-12 states. It’s a classic example. (I'll include a diagram in the blog.)

The important point: the construction is simple and linear in the size of the regex. This is why many practical regex engines first build an NFA.

---

## 3. From NFA to DFA: Subset Construction

Now that we have an NFA, we could simulate it directly. Simulating an NFA means tracking all possible states the automaton could be in after reading each symbol. For an input of length n, we maintain a **set** of current NFA states, and for each character, we compute the next set by following all possible transitions (including ε-closure). This is essentially a **subset construction** performed on the fly. The worst-case size of the state set is O(2^k) where k is number of NFA states, but in practice, it’s often manageable.

But we can also perform the subset construction eagerly at compile time, producing a DFA. The algorithm:

1. Compute the ε-closure of the start state of the NFA. This is the start state of the DFA.
2. For each DFA state (a set of NFA states), and for each input symbol (or character class), compute the set of NFA states reachable by following that symbol from any NFA state in the set, then take the ε-closure of that set. This becomes a new (or existing) DFA state.
3. Repeat until no new DFA states are created.

The resulting DFA may have exponential number of states in the worst case (e.g., for `a{1,100}` or very ambiguous patterns). In practice, most common regexes produce modest-sized DFAs.

### Example: NFA to DFA for `(a|b)*abb`

This is a classic example from compiler design (the “tiger” language). The NFA has around 10 states. The DFA may have about 7 states. That’s manageable.

But for a regex like `.*a.*b.*c`, the DFA would have basically four states (depending on how you optimize). For patterns with many repetitions, DFA size can blow up.

This is why some engines (like RE2) use a hybrid: they convert the NFA to a DFA lazily, only expanding the states actually visited during matching. This avoids exponential blow-up for many inputs while retaining the speed of DFA execution for the hot paths.

### DFA Minimization

After constructing a DFA, we can **minimize** it by merging equivalent states. Two states are equivalent if, for every possible suffix, they lead to acceptance (or rejection) and transition to equivalent states. The classic algorithm is **Hopcroft’s algorithm**, which partitions states iteratively. This reduces the size of the DFA and thus the memory footprint. For many regexes, minimization collapses loops into minimal form.

---

## 4. Simulation and Execution

Once we have a DFA, how do we simulate it against a string? The textbook way is a **table-driven** DFA:

- Precompute a transition table: `delta[state][char] = next_state`.
- For each character in input, `state = delta[state][char]`.
- After the last character, check if `state` is an accepting state.

The table can be large: for a DFA with N states and an alphabet of 256 bytes, the table is N×256 entries. For N=1000, that’s 256k entries; fine. For N=100000, it’s 25 million entries—too much.

Alternative: use a **compressed representation** such as a list of transitions per state, or a character class partition that collapses bytes into equivalence classes (e.g., all digits behave the same). This is what RE2 does: it precomputes a “state machine” with byte equivalence classes.

### Direct-coded DFA

Instead of a table, we can generate code that directly implements the DFA as a series of conditionals. For each state, we can have a switch statement or a series of if-else checks. This eliminates the memory access for the transition table and allows the CPU’s branch predictor to learn patterns. This is effectively **ahead-of-time compilation**—compiling the DFA into native code before any matching runs. But we can also do it at runtime, which is JIT.

---

## 5. Just-In-Time Compilation: Generating Machine Code

Now we reach the star of the show: **Just-In-Time (JIT) compilation** for regexes. The idea is to take the DFA (or even directly the NFA) and, at runtime, generate native machine code in memory that executes the automaton. This machine code is then executed to match input strings. The advantage: no interpretation overhead, no table lookup; the generated code can be as tight as hand-written assembly.

### Why JIT for Regexes?

- **Speed**: JIT can be 2-10x faster than table-driven DFA for short strings, because it eliminates indirection and branch misprediction.
- **Specialization**: The generated code can hardcode constants (like the accepting states), unroll loops, and even merge character class checks into efficient bitmask operations.
- **Lazy compilation**: Only compile a regex if it’s used many times (like in a hot loop). Libraries like PCRE’s JIT (pcre_jit) do exactly this: they first try to match with the interpreter; if the same pattern is used repeatedly, they JIT-compile it.

### The Machinery: Writing Self-Modifying Code

To generate machine code at runtime, you need to allocate a block of memory with execution permission (e.g., `mmap` with `PROT_EXEC`), then write bytes that represent x86-64 (or ARM) instructions into that buffer, then call the buffer as a function pointer.

Let’s sketch a simple JIT for a DFA with states 0..N-1 and an alphabet of bytes. The generated code will:

1. Initialize a register to the start state ID.
2. Loop over the input bytes (provided as a pointer and length).
3. For each byte, compute next state using a **state dispatch table** or a series of comparisons.

The simplest approach: for each state, emit a block of code that tests the input byte against the transitions. In the worst case, if a state has 256 distinct transitions, you need a jump table. But you can reduce the number of checks by using byte equivalence classes (like grouping all lowercase letters). Many characters in regexes are just “any character” (`.`), which can be handled by a simple `if (byte == any) goto next_state;` but actually `.` matches any _except_ newline depending on flags. So you need a check for `byte != '\n'`.

Let’s build a minimal JIT for a DFA with two states: start (0) and accept (1), with transitions: state0 on ‘a’ → state1, otherwise stay in state0; state1 on ‘b’ → state0, otherwise stay in state1. This is a trivial pattern: `[^b]*a?[^a]*b`? Actually simpler: this recognizes strings where every ‘a’ is followed by ‘b’? Not exactly. Let’s focus on the generation technique.

#### Example JIT in C (pseudo)

```c
void* compile_dfa(void* (*alloc)(size_t, int prot),
                  int num_states,
                  int (*transition)(int state, char ch),
                  int accepting) {
    // Allocate executable memory
    size_t code_size = estimate_code(num_states);
    uint8_t* code = (uint8_t*)alloc(code_size, PROT_EXEC);
    // Write prologue: function entry, setup stack frame (if needed)
    // Input: rdi = string pointer, rsi = length
    // We'll use registers: eax = state, ecx = current byte, rdi = current pointer, rsi = remaining length
    // ...
    // For each state, emit a block
    // Use a switch on state: for simplicity, we use a computed goto (GCC extension) but in assembly we'd use jump table.
    // ...
    // Write epilogue: return state (0 for mismatch, 1 for accept)
    flush_icache(code, code_size);
    return code;
}
```

But we must be careful: we need to handle the fact that the DFA might have many states, and we don’t want to explode code size. Real systems use a **linear bytecode** or **threaded code** approach (like Forth), where each state is a short sequence of instructions that ends with a jump to the next state. This is similar to how modern interpreters work.

### PCRE JIT Internals

PCRE’s JIT (by Zoltan Herczeg) is a masterpiece. It compiles the NFA into a small, efficient piece of x86-64 code that uses a **stack-based** approach akin to a virtual machine. It supports backreferences, capturing groups, and all the complex features—at the cost of worst-case exponential time (since it has to backtrack). But for many patterns, it runs blazingly fast.

The key: it generates code for each node in the NFA (character test, alternation, etc.) and links them together. It uses a technique called **“fallthrough”** when possible to avoid branching.

### RE2 and Rust’s regex: DFA-based JIT?

RE2 does not use JIT; it uses a lazy DFA (online subset construction) with table lookup. Rust’s regex library uses a similar approach but with some vectorized instructions for character classes (SSE4.2 instructions for `pcmpistri` etc.). They achieve high performance by being pure DFA and avoiding backtracking.

However, there is academic work on JIT-compiling DFA to native code, e.g., “JIT Compilation of Regular Expressions” by Lauther and Strahm, and the practical implementation in the **Hyperscan** library (used by Snort and Suricata for network intrusion detection). Hyperscan uses a combination of DFA and NFA with JIT for some paths.

---

## 6. Advanced Optimizations

### Minimization and State Compression

Before JIT, we can shrink the DFA. Minimization reduces states. Then we can encode transition tables compactly. For JIT, smaller DFA means less code.

### Character Class Partitioning

Instead of handling all 256 byte values, we can group them into equivalence classes. For example, if the regex has only `[a-z]` and `[0-9]`, we need to distinguish lowercase letters, digits, and everything else. That’s three classes, reducing the number of branches per state.

### Caching Compiled Code

In a long-running application, we don’t want to JIT a regex every time. Libraries cache the compiled code based on the pattern and flags.

### Hybrid Approaches

Modern engines often combine techniques:

- Try to match with a fast DFA (if simple).
- If that fails (due to backreferences or exponential blow-up), fall back to an NFA backtracking engine.
- JIT only the backtracking engine when needed.

---

## 7. Real-World Implementations

Let’s briefly survey how the giants do it:

- **PCRE (Perl Compatible Regular Expressions)**: Uses a recursive backtracking engine with a JIT backend. The JIT compiles the pattern into a series of guards and fails quickly.
- **RE2 (by Google)**: Uses a lazy DFA and Thompson NFA, with no backtracking. No JIT; but it is very fast due to compilation to efficient matching code.
- **Rust’s regex crate**: Similar to RE2—DFA-based, uses SIMD for character class checks. No JIT yet, but ahead-of-time compilation of automaton to a specialized Rust function is possible via macros.
- **Hyperscan (Intel)**: Designed for high-throughput network filtering. Uses a variety of automata (DFA, NFA, “tape”) and generates efficient code for x86, including SIMD for scanning multiple bytes simultaneously.

---

## 8. Building a Toy JIT Regex Engine

Let’s put it all together and outline a project you could build yourself in a weekend.

### Step 1: Write a Regex Parser

Parse a small subset: concatenation, alternation, Kleene star, character classes, `^` and `$` (anchors). Build an AST. E.g., in Rust:

```rust
enum Regex {
    Char(char),
    Concat(Vec<Regex>),
    Alt(Box<Regex>, Box<Regex>),
    Star(Box<Regex>),
    Dot,
    // etc.
}
```

### Step 2: Thompson’s Construction

Implement a function that takes a `Regex` and returns an NFA as a vector of states. Each state has a list of transitions: for a given character, or ε.

### Step 3: Subset Construction to DFA

Compute ε-closure, build DFA states. Represent DFA as a struct with `states: Vec<State>`, where each `State` has a map from byte to next state index, and a boolean `accepting`.

### Step 4: Minimization (Optional)

Implement Hopcroft’s algorithm to merge equivalent states.

### Step 5: Generate Machine Code

We need a small assembler in our own code. We can emit raw x86-64 bytes. Let’s design a simple calling convention:

- Input: `rdi` = pointer to string, `rsi` = length.
- Output: `eax` = 1 if match, 0 otherwise.
- Registers: `eax` for current state, `ecx` for current byte, `r8` for end pointer.
- We’ll use a **loop** over bytes, with a **jump table** indexed by state and byte.

But a jump table requires forming an address in memory. Simpler: for each state, emit a block of code that does a series of comparisons. Since we have a small number of states, we can use a switch-like structure:

```
start:
    mov eax, 0          ; state = 0
loop:
    cmp rsi, 0
    je end
    movzx ecx, byte ptr [rdi]
    ; dispatch based on state
    cmp eax, 0
    je state0
    cmp eax, 1
    je state1
    ; ...
    jmp end_fail
state0:
    ; handle state 0 transitions
    ; example: if char == 'a' -> state1, else stay state0
    cmp ecx, 'a'
    jne stay0
    mov eax, 1
    jmp next
stay0:
    ; no change, keep state 0
next:
    inc rdi
    dec rsi
    jmp loop
state1:
    ; handle state 1
    ; similar
end:
    ; check if state is accepting
    cmp eax, 1
    sete al
    ret
```

But this is naive. For realistic DFAs, we want to use a binary search over the transitions or a jump table if dense. If the alphabet is partitioned into few classes, we can use a precomputed class lookup table.

### Step 6: Execute

Call the generated function pointer with a test string. Benchmark.

### Example in C (sketch)

```c
// Assume we have a DFA with transitions indexed by state and byte class.
// We generate code that uses a class table: uint8_t class[256] precomputed.
// For each state, we emit:
//   mov bl, class[ecx]   // get class of current byte
//   mov eax, next_state_table[eax*num_classes + ebx]
// This requires a global table. But we can embed the table pointer as an immediate.
```

For a full implementation, see various open-source projects like `re2`’s `dfa.cc` or `regex-automata` crate.

---

## 9. Performance and Benchmarks

How does JIT compare?

- Table-driven DFA: ~1-2 ns per character (with L1 cache hits).
- Direct-coded DFA (without JIT, just generated C code): similar.
- JIT: can be slightly faster due to reduced instruction count and better branch prediction. In benchmarks by PCRE JIT, they claim up to 8x speedup over the interpreter for certain patterns.
- NFA simulation: ~10-100x slower depending on ambiguity.

However, JIT compilation time adds overhead. For a regex that is applied to millions of strings, this overhead is negligible. For a one-off use, it might not be worth it. That’s why libraries use a threshold: if the pattern is compiled more than N times, enable JIT.

### Real numbers:

- RE2 on a modern CPU: ~200 MB/s throughput for large inputs.
- PCRE JIT: can reach 1 GB/s for simple patterns.
- Hyperscan: up to 10 Gbps for network traffic.

---

## 10. Conclusion: The Magic Demystified

We began with the blinking cursor and the invisible machine. Now you know what that machine does. It parses your regex into an abstract syntax tree, transforms it into an NFA using Thompson’s construction, determinizes it into a DFA (maybe lazily), and then either interprets a transition table or—if speed is paramount—compiles the DFA into native machine code that runs directly on your CPU.

The entire journey is a beautiful illustration of how abstract mathematics (regular languages, automata theory) is connected to practical engineering (parsing, code generation, memory management). Every time you hit Enter after typing a regex, you are invoking a chain of algorithms that have been refined over decades.

Building your own JIT regex engine is a fantastic way to solidify this knowledge. Start small: parse a tiny subset, implement an NFA simulator, then a DFA simulator, then try generating code. You’ll experience first hand the trade-offs between compile time and execution speed, the agony of debugging a segmentation fault in your own generated code, and the thrill of seeing your regex match a string in microseconds.

The next time you use `grep` or a text editor’s find-and-replace, take a moment to appreciate the invisible machine that makes it all possible. It’s not magic—it’s just a really good compiler.
