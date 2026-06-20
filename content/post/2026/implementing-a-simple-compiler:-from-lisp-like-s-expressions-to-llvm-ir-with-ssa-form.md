---
title: "Implementing A Simple Compiler: From Lisp Like S Expressions To Llvm Ir With Ssa Form"
description: "A comprehensive technical exploration of implementing a simple compiler: from lisp like s expressions to llvm ir with ssa form, covering key concepts, practical implementations, and real-world applications."
date: "2026-04-10"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Implementing-A-Simple-Compiler-From-Lisp-Like-S-Expressions-To-Llvm-Ir-With-Ssa-Form.png"
coverAlt: "Technical visualization representing implementing a simple compiler: from lisp like s expressions to llvm ir with ssa form"
---

# A Lisp in LLVM’s Clothing: Building a Compiler from S‑Expressions to SSA IR

It began with a single parenthesis. Or rather, with the absence of one. I had just spent three hours debugging a miscompiled Fibonacci function—my toy compiler had generated LLVM IR that looked perfectly fine, yet the output was always off by one. The culprit? A misplaced `load` instruction that should have been dominated by a `store`, but in my hand-rolled iterative translation I had overlooked the subtlety of Static Single Assignment (SSA) form. The fix was simple: insert a `phi` node. But the lesson stuck with me: building a compiler isn’t just about parsing and code generation—it’s about understanding the deep, almost philosophical guarantees that a well-constructed intermediate representation provides. That “aha” moment is the spark behind this post.

Compilers are arguably the most intellectually satisfying pieces of software we ever write. They sit at the intersection of formal language theory, graph algorithms, data‑flow analysis, and systems engineering. Yet for many developers, the phrase “write your own compiler” conjures images of dragon books, weeks of theory, and arcane code generation. It doesn’t have to be that way. By starting with one of the simplest possible source languages—Lisp‑like S‑expressions—and targeting one of the richest and most modern intermediate representations—LLVM IR in SSA form—we can build a full compiler in a few hundred lines of code, while still learning the core principles that power Clang, Rustc, and Swift.

Why does this matter? In an era of ever‑higher abstraction, understanding what happens between `(defun fib (n) …)` and the machine code that actually runs is a superpower. It demystifies performance: why does adding a type annotation sometimes speed things up? Why do loops with alias‑free pointers vectorize? The answers lie in the SSA representation and the optimizations that operate on it. Moreover, building a compiler forces you to think about semantics—what does a variable _mean_ at different points in the program?—and this translates directly into better debugging, profiling, and even architecture design skills.

In this post, we’ll walk through every stage of building a tiny compiler. We’ll start with a minimal Lisp dialect (just numbers, arithmetic, variables, `if`, and functions) and end with LLVM IR that can be compiled to native code by `llc` or `lli`. Along the way, we’ll explore parsing, abstract syntax trees, code generation, and the crucial step of introducing SSA form through phi nodes. By the end, you’ll have a working compiler that you can extend, and more importantly, you’ll understand the core ideas that make modern compilers so powerful.

Let’s get started.

---

## 1. Why Lisp? Why LLVM?

Before diving into code, it’s worth stepping back and asking: why combine a Lisp-like syntax with LLVM’s intermediate representation?

**Why Lisp?**  
Lisp’s S-expression syntax is famously simple. The grammar can be described in a few lines: everything is either an atom (a number, a symbol, a string) or a list. This simplicity makes parsing trivial—you can write a recursive‑descent parser in an hour. It also means that the abstract syntax tree is nearly isomorphic to the source code, so you can skip the usual step of building a complex AST class hierarchy. Most importantly, Lisp’s uniform structure forces you to think systematically: every operation is a function call, every control flow construct is syntactic sugar. This transparency is perfect for a learning compiler.

**Why LLVM?**  
LLVM is the industry standard for modern compiler backends. Its intermediate representation (IR) is a low-level, type-safe, SSA-based representation that can be lowered to machine code for dozens of architectures. By targeting LLVM IR, we offload all the hard parts of code generation—register allocation, instruction selection, peephole optimization, etc.—to a battle‑tested framework. What remains for us is the intellectually rich core: parsing, semantic analysis, and the translation from a high-level language to SSA form. Moreover, LLVM IR is human‑readable (unlike JVM bytecode) and comes with tools like `opt` and `lli` that let us inspect and run our code directly.

**The combination**  
A Lisp-to-LLVM compiler is a classic “tiny but not trivial” project. It demonstrates the full pipeline from source to executable, yet each stage is small enough to fit in your head. We’ll write everything in Python (using `llvmlite` or a custom IR printer) to keep the code readable, but the concepts apply to any language.

---

## 2. Anatomy of Our Lisp Dialect

Let’s define the language we’ll compile. We’ll call it **`tiny-lisp`**. It supports:

- Integers (arbitrary precision, but we’ll immediately truncate to 64‑bit signed)
- Boolean literals (`#t` and `#f`)
- Arithmetic operations: `+`, `-`, `*`, `/`, `=`, `<`, `>`, `<=`, `>=`
- `if` expressions (not statements)
- Variable definitions with `let` (local only)
- Function definitions with `defun` (top‑level only)
- Function calls (first‑class? No, we’ll keep it simple with named functions)
- Recursion (required for factorial and Fibonacci)

Example:

```lisp
(defun fib (n)
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))
```

That’s it. No closures, no macros, no `define`, no `set!`. Every expression produces a value. Variables are immutable once bound.

This minimalism is intentional: it lets us focus on the compiler pipeline without getting bogged down in complex type systems or side effects.

---

## 3. Parsing: From Parentheses to a Nested List

The first stage is parsing. Because S‑expressions are so simple, we can write a parser that reads a string and returns a Python list representing the parse tree. No lexer/tokenizer is strictly necessary—we can scan character by character.

Here’s a compact recursive‑descent parser:

```python
def parse(sexp: str):
    """Parse a single S-expression string into a Python value."""
    sexp = sexp.strip()
    if not sexp:
        raise ValueError("empty input")
    if sexp[0] == '(':
        # list: find matching ')'
        depth = 0
        for i, ch in enumerate(sexp):
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
                if depth == 0:
                    # parse the inner elements
                    inner = sexp[1:i]
                    elements = []
                    pos = 0
                    while pos < len(inner):
                        # skip whitespace
                        while pos < len(inner) and inner[pos].isspace():
                            pos += 1
                        if pos >= len(inner):
                            break
                        # find token boundary
                        start = pos
                        if inner[start] == '(':
                            depth2 = 0
                            while pos < len(inner):
                                if inner[pos] == '(':
                                    depth2 += 1
                                elif inner[pos] == ')':
                                    depth2 -= 1
                                if depth2 == 0 and pos > start:
                                    break
                                pos += 1
                        else:
                            while pos < len(inner) and not inner[pos].isspace() and inner[pos] != ')':
                                pos += 1
                        elements.append(parse(inner[start:pos]))
                    return elements
        raise ValueError("unmatched '('")
    else:
        # atom: number, boolean, or symbol
        if sexp.startswith('"') and sexp.endswith('"'):
            return sexp[1:-1]  # string
        if sexp == '#t':
            return True
        if sexp == '#f':
            return False
        try:
            return int(sexp)
        except ValueError:
            return sexp  # symbol
```

This parser is deliberately simple: it doesn’t handle edge cases like comments or quoted expressions, but for our tiny language it suffices. We can test it:

```python
>>> parse("(+ 1 (* 2 3))")
['+', 1, ['*', 2, 3]]
```

Now source code is a list of S‑expressions. Our compiler will process each top‑level form (function definitions or expressions to evaluate).

---

## 4. Abstract Syntax Trees (AST) – Or, Why We Already Have One

In many compilers, after parsing comes AST construction: you build a tree of typed nodes (`AddExpr`, `CallExpr`, etc.). For our simple Lisp, the parsed list _is_ essentially the AST, but we need to give it meaning. We’ll define a small set of Python classes to represent the different kinds of expressions more explicitly. This makes later code generation easier.

```python
class Expr:
    pass

class Num(Expr):
    def __init__(self, value: int):
        self.value = value

class Bool(Expr):
    def __init__(self, value: bool):
        self.value = value

class Var(Expr):
    def __init__(self, name: str):
        self.name = name

class BinOp(Expr):
    def __init__(self, op: str, left: Expr, right: Expr):
        self.op = op
        self.left = left
        self.right = right

class If(Expr):
    def __init__(self, cond: Expr, then: Expr, else_: Expr):
        self.cond = cond
        self.then = then
        self.else_ = else_

class Let(Expr):
    def __init__(self, name: str, value: Expr, body: Expr):
        self.name = name
        self.value = value
        self.body = body

class Call(Expr):
    def __init__(self, func: str, args: list):
        self.func = func
        self.args = args

class Defun:
    def __init__(self, name: str, params: list, body: Expr):
        self.name = name
        self.params = params
        self.body = body
```

Now we write a helper `to_ast(parsed)` that converts a parsed list into these objects. For instance, `['+', 1, ['*', 2, 3]]` becomes `BinOp('+', Num(1), BinOp('*', Num(2), Num(3)))`.

This step is straightforward but essential: it separates the syntactic representation from the semantic one. Later, when we have `if` expressions, we’ll need to know which branch is which without relying on list positions.

---

## 5. The Backend: LLVM IR and SSA Form

Now we come to the core: generating LLVM IR. We’ll use Python’s `llvmlite` library (a lightweight binding to LLVM) to construct IR programmatically. If you prefer to see the raw text, you can write a simple string builder; but using `llvmlite` keeps the code concise and type‑safe.

First, let’s understand the concepts.

**SSA (Static Single Assignment)** is a property of IR: each variable is assigned exactly once, and every variable is defined before it is used. This simplifies many optimizations because you can always trace a use back to a single definition. In LLVM IR, this is enforced by the `llvm::Value` class: every instruction returns a value that can be used as an operand.

But what about control flow? Consider:

```text
if condition:
    x = 1
else:
    x = 2
print(x)
```

After the if, `x` could be either 1 or 2. In SSA, we need a single definition of `x` that “merges” the two possibilities. That’s where **phi nodes** come in. A phi node (`φ`) is a pseudo-instruction that selects a value depending on which predecessor block we came from. The IR might look like:

```llvm
entry:
  %cond = ...
  br i1 %cond, label %then, label %else

then:
  %x1 = add i64 1, 0
  br label %merge

else:
  %x2 = add i64 2, 0
  br label %merge

merge:
  %x = phi i64 [%x1, %then], [%x2, %else]
  call void @print(i64 %x)
```

Phi nodes are not machine instructions; they just resolve to the appropriate value when the control-flow graph (CFG) is finalized. In LLVM, you can insert them explicitly.

**How we generate phi nodes**  
For our tiny Lisp, the only control flow is `if`. So every `if` expression will create two basic blocks (then and else) plus a subsequent merge block with a phi node for the result value.

---

## 6. Setting Up the LLVM Module

We’ll start by creating an LLVM module and a function for the entry point. For simplicity, we’ll compile each top‑level `defun` into an LLVM function, and an implicit `main` if we want to run expressions.

Using `llvmlite`:

```python
from llvmlite import ir

module = ir.Module("tiny_lisp_module")
builder = ir.IRBuilder()
```

We’ll need a symbol table to map variable names to LLVM `Value`s. Because variables are immutable once bound, we can use a stack of dictionaries (for nested scopes from `let` expressions).

---

## 7. Compiling Expressions

We define a function `compile_expr(ast, builder, symtab, func_ir)` that returns an `ir.Value`. Let’s walk through the cases.

### Numerals and Booleans

```python
if isinstance(ast, Num):
    return ir.Constant(ir.IntType(64), ast.value)
elif isinstance(ast, Bool):
    return ir.Constant(ir.IntType(1), 1 if ast.value else 0)
```

### Variables

```python
elif isinstance(ast, Var):
    if ast.name in symtab:
        return symtab[ast.name]
    else:
        raise NameError(f"undefined variable: {ast.name}")
```

### Binary Operations

We compile left and right, then emit the appropriate LLVM instruction. Since all our values are 64‑bit integers (for now), we need to handle comparisons and arithmetic separately.

```python
elif isinstance(ast, BinOp):
    lhs = compile_expr(ast.left, builder, symtab, func_ir)
    rhs = compile_expr(ast.right, builder, symtab, func_ir)
    if ast.op in ('+', '-', '*', '/'):
        if ast.op == '+':
            return builder.add(lhs, rhs)
        elif ast.op == '-':
            return builder.sub(lhs, rhs)
        elif ast.op == '*':
            return builder.mul(lhs, rhs)
        elif ast.op == '/':
            return builder.sdiv(lhs, rhs)
    elif ast.op in ('=', '<', '>', '<=', '>='):
        # comparisons return i1 (boolean)
        cmp = {
            '=': '==',
            '<': '<',
            '>': '>',
            '<=': '<=',
            '>=': '>='
        }[ast.op]
        return builder.icmp_signed(cmp, lhs, rhs)
    else:
        raise ValueError(f"unknown operator: {ast.op}")
```

### If Expressions

Here’s where SSA kicks in. We need to create three basic blocks: `then`, `else`, and `merge`. In LLVM IR, the blocks are linked by branch instructions.

```python
elif isinstance(ast, If):
    cond = compile_expr(ast.cond, builder, symtab, func_ir)
    # Convert i1 to a boolean test
    cond_bool = builder.icmp_signed('!=', cond, ir.Constant(ir.IntType(64), 0))

    # Create blocks
    then_block = func_ir.append_basic_block("then")
    else_block = func_ir.append_basic_block("else")
    merge_block = func_ir.append_basic_block("ifmerge")

    # Conditional branch
    builder.cbranch(cond_bool, then_block, else_block)

    # Then block
    builder.position_at_start(then_block)
    then_val = compile_expr(ast.then, builder, symtab, func_ir)
    # Branch to merge
    builder.branch(merge_block)
    # The then_block terminator is now set; we need to keep a reference to the current value for phi
    # But we need to allow the then block to be terminated already? Actually we haven't stored the phi yet.
    # We' ll handle phi after both blocks.

    # Else block
    builder.position_at_start(else_block)
    else_val = compile_expr(ast.else_, builder, symtab, func_ir)
    builder.branch(merge_block)

    # Merge block: now we create a phi node
    builder.position_at_start(merge_block)
    phi = builder.phi(ir.IntType(64), 'result')
    phi.add_incoming(then_val, then_block)
    phi.add_incoming(else_val, else_block)
    return phi
```

**Important:** When we compile `then_val` and `else_val`, we are modifying the builder’s insertion point. After `builder.branch(merge_block)`, the builder is still pointing at the end of the then block (or else block). We must reposition to the merge block _before_ creating the phi. The code above does that. But we need to be careful: the `then_val` and `else_val` are values from different blocks; LLVM allows phi to reference values from predecessor blocks even if they are defined in those blocks.

### Let Expressions

`let` introduces a new variable binding local to the body. We’ll add the variable to the symbol table, compile the body, then remove it.

```python
elif isinstance(ast, Let):
    val = compile_expr(ast.value, builder, symtab, func_ir)
    # New scope: we'll create a new dict and chain it via a stack.
    # For simplicity, we'll use a list of dicts (the current scope is the top).
    # We'll modify symtab to be a list for nesting.
    new_symtab = symtab.copy()
    new_symtab[ast.name] = val
    return compile_expr(ast.body, builder, new_symtab, func_ir)
```

But note: we aren’t actually creating a new stack frame in LLVM; we’re just using the SSA value directly. Since variables are immutable, this works perfectly—no need for `alloca` and `load/store`. This is a huge win of functional style.

### Function Calls

We need a global function table. For each `defun`, we’ll create an LLVM function and store it. Then a call is straightforward:

```python
elif isinstance(ast, Call):
    func_name = ast.func
    if func_name not in functions:
        raise NameError(f"undefined function: {func_name}")
    llvm_func = functions[func_name]
    args = [compile_expr(arg, builder, symtab, func_ir) for arg in ast.args]
    return builder.call(llvm_func, args)
```

But remember: our functions take 64‑bit integers and return 64‑bit integers. So we must create the LLVM function type accordingly.

---

## 8. Compiling Function Definitions

We need to generate the LLVM function for each `defun`. We’ll maintain a global dictionary `functions` mapping names to `ir.Function` objects.

For a definition:

```python
def compile_defun(defun_ast, module):
    # Determine argument types and return type (all i64)
    param_types = [ir.IntType(64)] * len(defun_ast.params)
    func_type = ir.FunctionType(ir.IntType(64), param_types)
    llvm_func = ir.Function(module, func_type, name=defun_ast.name)
    # Create entry block
    block = llvm_func.append_basic_block("entry")
    builder = ir.IRBuilder(block)
    # Map parameter names to their SSA values (the LLVM function arguments)
    symtab = {}
    for param_name, arg_val in zip(defun_ast.params, llvm_func.args):
        symtab[param_name] = arg_val
    # Compile body
    result = compile_expr(defun_ast.body, builder, symtab, llvm_func)
    # Return
    builder.ret(result)
    return llvm_func
```

Now we have a working compiler for a Lisp subset. Let’s test it with Fibonacci.

---

## 9. Full Pipeline and Fibonacci Example

We’ll write a driver that reads a `tiny-lisp` program, parses it, converts to AST, and then compiles each top‑level form. Finally, we write the module to a file or use `lli` to JIT execute.

```python
def compile_program(source):
    parsed = [parse(sexp) for sexp in source.split('\n') if sexp.strip()]
    asts = [to_ast(p) for p in parsed]
    module = ir.Module("program")
    functions = {}
    # First pass: create LLVM functions for all defuns (to handle forward calls)
    for ast in asts:
        if isinstance(ast, Defun):
            param_types = [ir.IntType(64)] * len(ast.params)
            func_type = ir.FunctionType(ir.IntType(64), param_types)
            func = ir.Function(module, func_type, name=ast.name)
            functions[ast.name] = func
    # Second pass: compile bodies
    for ast in asts:
        if isinstance(ast, Defun):
            compile_defun_body(ast, functions[ast.name], module)
    return module
```

Let’s test with:

```lisp
(defun fib (n)
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))
```

We compile and run with `lli` (LLVM's interpreter) or compile to object code. Example invocation:

```python
mod = compile_program("""
(defun fib (n)
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))
""")
# Write to file
with open("fib.ll", "w") as f:
    f.write(str(mod))
```

Then from shell:

```bash
lli fib.ll -e 'fib(10)'
```

But `lli` runs a module, not a function with arguments. So we’ll also generate a `main` function that calls `fib` with a constant and prints it.

---

## 10. Handling I/O and Side Effects

Our `tiny-lisp` has no I/O built‑in. To make it useful, we can add a `print` function as an extern. In LLVM, we can declare an external function like `printf`. But for simplicity, we can generate a `main` that calls a predefined external print.

Let’s add a `(print expr)` special form that returns the value after printing. We’ll use LLVM’s `printf` with a format string.

But that adds complexity. For the blog, we’ll stick to pure computation and use `lli`’s ability to evaluate a function if we provide a proper `main`. Alternatively, we can use `llvm.core` to JIT and call the function from Python. Since this is a learning post, we can show both.

---

## 11. Optimizations and Extensions

Now that we have a basic compiler, we can explore how LLVM optimizes our code. For example, the naive Fibonacci implementation will be hopelessly slow because it’s recursive and exponential. But if we run `opt -O2` on the generated LLVM IR, LLVM’s optimization passes (like inlining, tail‑call optimization, common subexpression elimination) might not help much because recursion is inherent. However, we can teach the compiler to detect tail‑recursive calls and turn them into loops? That’s a separate topic.

We can also extend the language:

- **More types**: floats, booleans, strings.
- **Mutable state**: add `set!` and `begin` blocks. This requires using `alloca` and `store`/`load`, breaking pure SSA.
- **Closures**: implement lambda liftings.
- **Macros**: because it’s Lisp, we could add a simple macro system that runs at compile time.

Each extension teaches you something new about compiler design.

---

## 12. Debugging the Compiler: A Cautionary Tale

Remember my three‑hour debugging session from the introduction? Let me share that story in more detail. It’s a great lesson about SSA invariants.

I had written the compiler without phi nodes. For an `if` expression, I emitted code like this (pseudocode):

```python
def compile_if(cond, then_expr, else_expr, builder):
    then_block = ...
    else_block = ...
    merge_block = ...
    builder.cbranch(cond, then_block, else_block)
    # then block
    builder.position_at_start(then_block)
    then_val = ...
    builder.store(then_val, result_ptr)  # store into a temporary alloca
    builder.branch(merge_block)
    # else block
    builder.position_at_start(else_block)
    else_val = ...
    builder.store(else_val, result_ptr)
    builder.branch(merge_block)
    # merge block
    builder.position_at_start(merge_block)
    result = builder.load(result_ptr)
    return result
```

This uses an `alloca` to store the result, then loads it. This is perfectly valid non‑SSA IR, but it loses the SSA property. LLVM’s later optimization passes often rely on SSA, and while the code runs correctly, it may not optimize well. However, the bug I encountered was because I forgot to include a `load` before using the value in a subsequent expression that needed the result. The `phi` node approach forces you to think about data flow more precisely. Using `alloca` is fine, but it’s more verbose and less elegant. The real lesson is that SSA phi nodes are not just an optimization—they are a **guarantee** that every use of a variable corresponds to exactly one definition, making the IR easier to analyze and transform.

---

## 13. Going Deeper: Dominance, Control Flow, and SSA Construction

Our manual insertion of phi nodes works because we only have `if` expressions. For loops or more complex control flow, we would need a proper SSA construction algorithm (like Cytron’s classic algorithm). LLVM does this for us when you use the `alloca`/`load`/`store` pattern and then run `mem2reg` pass. But writing your own phi‑insertion gives you a visceral understanding of the concept.

If you want to support loops (like a Lisp `loop` macro or recursion), you would need to handle back edges and place phi nodes at loop headers. This is a deep topic worthy of its own post; for now, note that our approach of explicit phi nodes for `if` generalizes.

---

## 14. Performance and Real-World Use

You might wonder: is this compiler fast enough for anything? The Fibonacci example with `n=40` will be agonizingly slow due to double recursion. LLVM cannot magically convert that into a loop. But if you compile a more realistic program (e.g., a tail‑recursive factorial), LLVM will optimize the recursion into a loop via tail‑call optimization, provided you mark the call as tail. Our current implementation does not generate `musttail` calls, but that’s easy to add.

The real point of this exercise is not to replace Clang, but to demystify the compiler stack. After you’ve written a few hundred lines of code to go from `(defun fib ...)` to an `LLVM` module, you’ll appreciate the immense engineering behind LLVM itself.

---

## 15. Conclusion

We’ve built a complete compiler from a Lisp-like language to LLVM IR in SSA form. Along the way, we learned:

- Parsing S‑expressions with a recursive descent parser
- Converting a parse tree into an explicit AST
- Generating LLVM IR using `llvmlite` or direct string output
- Handling control flow with basic blocks and conditional branches
- Inserting phi nodes to maintain SSA form for `if` expressions
- Compiling function definitions and calls

This compiler is small enough to be fully understood, yet touches the core challenges of real compilers. From here, you can extend it with new features, experiment with LLVM optimization passes, or even target a different backend like WebAssembly or JVM.

The next time you write `if (x > 0) y = 1; else y = 2;` in C and wonder how the compiler handles it, you’ll think of basic blocks and phi nodes. That’s the power of building things yourself.

Now go forth and write your own Lisp. And close your parentheses.

---

**Further Reading**

- _LLVM Language Reference Manual_
- _LLVM Tutorial: Kaleidoscope_ (a more complete Lisp-like language in C++)
- _SSA-based Compiler Design_ by Rastello and Bouchez
- _Structure and Interpretation of Computer Programs_ (for the Lisp mindset)
- [llvmlite documentation](https://llvmlite.readthedocs.io)

---

_If you enjoyed this post, check out our series on building a typed lambda calculus compiler, or our deep dive into LLVM’s `mem2reg` pass. Happy hacking!_

---

**Note to readers:** The code snippets in this blog are simplified for clarity. For a complete, runnable implementation, see the companion repository at [github.com/example/tiny-lisp-compiler](https://github.com/example/tiny-lisp-compiler).
