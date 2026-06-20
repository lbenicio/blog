---
title: "Implementing A Simple Type System For A Programming Language: Hindley Milner Type Inference"
description: "A comprehensive technical exploration of implementing a simple type system for a programming language: hindley milner type inference, covering key concepts, practical implementations, and real-world applications."
date: "2025-07-25"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Implementing-A-Simple-Type-System-For-A-Programming-Language-Hindley-Milner-Type-Inference.png"
coverAlt: "Technical visualization representing implementing a simple type system for a programming language: hindley milner type inference"
---

## The Magic of Invisible Types: Why Hindley‑Milner Type Inference Matters

Imagine writing a program without a single type annotation. You define functions, pass arguments, and combine operations—and yet the compiler catches every type mismatch before the code runs. No `: Int` or `-> String` cluttering your logic. The types are there, but they remain invisible, inferred from the way you use values. This isn’t a futuristic fantasy; it’s a reality in languages like Haskell, OCaml, Rust, and even modern Swift and Kotlin. The engine behind this elegance is the **Hindley‑Milner type inference algorithm**, a decades‑old gem of computer science that balances expressiveness, safety, and practicality.

As developers, we rarely stop to think about the machinery that checks our programs. Yet type inference is one of the most transformative features of modern programming languages. It frees us from the drudgery of writing explicit types while preserving the ironclad guarantees of static typing. It enables parametric polymorphism—the ability to write a single function that works on lists of integers, strings, or custom types—without sacrificing type safety. And it does all of this without requiring the programmer to lift a finger. To a newcomer, it feels like magic. To a compiler engineer, it’s a beautifully constrained problem: how do you derive the most general type for an expression, given nothing but the structure of the code?

The story begins in the late 1960s, when Roger Hindley observed that the type inference problem for the simply typed lambda calculus could be reduced to solving equations between type expressions. A few years later, Robin Milner, working on the ML language, independently developed a practical algorithm that extended Hindley’s work to include let‑polymorphism—the ability to declare a variable with a polymorphic type and use it in different ways within the same scope. Luis Damas later refined the algorithm, giving it the form we now call Algorithm W.

In this article, we’ll peel back the curtain on this celebrated piece of computer science. We’ll explore the core concepts—unification, substitution, principal types—and walk through the algorithm step by step. We’ll see how let‑polymorphism makes the whole thing work in practice, and we’ll examine the limitations that push the boundaries of inference. Along the way, we’ll touch on why Hindley‑Milner remains the gold standard for type inference in many of today’s most influential languages, and how it continues to inspire new language designs.

---

### Why Explicit Types Are a Burden

Before we dive into the algorithm, it’s helpful to consider the world without type inference. In languages like Java 1.4 or C (before `auto`), every variable, parameter, and return type must be spelled out:

```java
// Java style – explicit everywhere
public List<String> process(List<String> input) {
    List<String> result = new ArrayList<String>();
    for (String s : input) {
        if (s.length() > 5) {
            result.add(s);
        }
    }
    return result;
}
```

The types are repeated: the parameter `input` is `List<String>`, the local variable is `List<String>`, the return type is `List<String>`. This repetition is not only tedious but also brittle—if the structure of the list changes, you may have to update annotations in dozens of places. Worse, when you use generic functions like `map`, you often end up writing type arguments that are obvious from context:

```java
// Java 8 lambda with explicit type
List<Integer> lengths = input.stream()
                             .map((String s) -> s.length())
                             .collect(Collectors.toList());
```

The type `String` is redundant: the compiler already knows that `input` is a `List<String>`. Type inference eliminates this noise, letting programmers focus on logic rather than ceremony.

But the benefits go beyond convenience. Inference enables **parametric polymorphism**—the ability to write a function that works on any type, without specifying which one upfront. Consider `map` in Haskell:

```haskell
map :: (a -> b) -> [a] -> [b]
map f [] = []
map f (x:xs) = f x : map f xs
```

No type annotations are needed for the implementation; the compiler deduces the most general type. This same function can be applied to lists of integers, strings, or even nested lists. The inferred type `(a -> b) -> [a] -> [b]` tells us everything we need: it’s polymorphic over any types `a` and `b`, and it’s fully type‑safe.

Without inference, we would have to write something like Java’s generic method:

```java
public <A, B> List<B> map(Function<A, B> f, List<A> list) { ... }
```

Again, the parameters `A` and `B` are declared explicitly. Inference moves this burden from the programmer to the compiler, and in doing so it encourages more generic, reusable code.

---

### A Brief History: From Hindley to Milner to Damas

The story of Hindley‑Milner type inference begins in the 1960s, when Roger Hindley was studying type theory. He was investigating the simply typed lambda calculus—a minimal language with only functions and applications—and he noticed something remarkable: the problem of finding a type for a term could be reduced to solving a system of equations over type expressions. Each equation represents a constraint that must hold for the program to be well‑typed. Hindley showed that if a solution exists, there is a **most general solution** (a principal type) from which all others can be derived.

Independently, in the 1970s, Robin Milner was designing the ML language for the LCF theorem prover. ML was intended to be a safe, statically typed language that could handle the complexity of theorem proving. Milner needed a type system that would allow users to write generic functions (like `map`) without having to annotate every generic parameter. He rediscovered Hindley’s ideas and extended them with a crucial innovation: **let‑polymorphism**.

In the lambda calculus, a lambda‑bound variable (a function parameter) cannot be used with different types at different call sites. For example:

```lambda
let f = λx. x in (f 1, f "hello")
```

If `x` is bound by `λx`, then its type is fixed at the point of abstraction. The above code would be rejected because `x` can be only one type. But if we use `let`:

```lambda
let f = λx. x in (f 1, f "hello")
```

Here, `f` is defined in a `let` expression, and Milner’s insight was that we can treat `f` as **polymorphic** within the body of the `let`. This is the essence of let‑polymorphism: the type of `f` is generalized over any type variables that are not constrained by the context. In practice, it means we can write:

```ocaml
let id x = x in (id 1, id "hello")  (* works *)
```

but we cannot write:

```ocaml
let f = fun x -> x in f 1; f "hello"  (* also works with let! *)
```

The difference is that `let` introduces a binding whose right‑hand side can be typed in a polymorphic way, while lambda‑bound parameters are monomorphically typed.

Luis Damas, a PhD student of Milner, later formalized the algorithm in his 1985 thesis. He presented Algorithm W, which is the standard pedagogical version of Hindley‑Milner inference. Damas also identified the soundness and completeness properties: if the algorithm succeeds, it yields a principal type; if it fails, the term is indeed ill‑typed.

Since then, Hindley‑Milner has been the backbone of type inference in languages such as ML, Haskell, OCaml, F#, and more recently Rust, Swift, and Kotlin (in various degrees). It has been extended, optimized, and studied extensively, but its core ideas remain unchanged.

---

### Core Concepts: Substitution, Unification, and Principal Types

To understand Algorithm W, we need to grasp a few fundamental ideas.

**Type Variables and Type Expressions**  
We start with a set of type variables (usually written `α`, `β`, `γ` …) and base types (like `Int`, `Bool`, `String`). Type expressions are built from these, e.g., `α -> β`, `List α`, `(α, β) -> γ`. A **substitution** is a mapping from type variables to type expressions. Applying a substitution `S` to a type expression `τ` replaces each variable according to `S`. For instance, if `S(α) = Int` and `S(β) = Bool`, then applying `S` to `α -> β` yields `Int -> Bool`.

**Unification**  
Unification is the process of making two type expressions syntactically equal by finding a substitution for their variables. For example, to unify `α -> β` with `Int -> γ`, we deduce that `α` must be `Int`, `β` must be `γ`. The resulting substitution is `{α ↦ Int, β ↦ γ}`. If unification fails (e.g., trying to unify `Int -> Bool` with `Bool -> Int`), the program is ill‑typed.

The algorithm for unification is straightforward: recursively match the structure of the two types, bind variables to expressions, and check for consistency (occur check: a variable cannot be bound to a type that contains itself, to prevent infinite recursion).

**Principal Types**  
A type `τ` is **principal** for an expression `e` if it is the most general type that can be assigned to `e` under the given typing context. That is, any other valid type for `e` can be obtained from `τ` by substituting type variables. The existence of a principal type ensures that type inference is deterministic: the algorithm will always find the same principal type (up to renaming). The beautiful thing about Hindley‑Milner is that every typable term has a principal type, and Algorithm W computes it.

**Typing Judgments**  
The inference algorithm is built around typing judgments of the form:

$$\Gamma \vdash e : \tau$$

meaning “under environment $\Gamma$ (a mapping from variables to types), expression $e$ has type $\tau$.” For example:

$$\{x: \alpha\} \vdash x : \alpha$$

This says: given that `x` has type `α` in the environment, `x` itself has type `α`.

---

### Algorithm W: Step by Step

Algorithm W takes an expression `e` and an initial type environment `Γ`, and returns a pair `(S, τ)` where `S` is a substitution and `τ` is the inferred type of `e` under `S ∘ Γ` (the environment after applying `S`). The algorithm is defined recursively over the structure of expressions.

Let’s define a small language:

```
e ::= x                  (variable)
    | λx. e              (abstraction)
    | e1 e2              (application)
    | let x = e1 in e2   (let expression)
    | i                  (integer constant, type Int)
    | true | false       (boolean constants, type Bool)
```

We’ll also have constants like `+` with predefined types. For simplicity, assume `+ : Int -> Int -> Int`.

**Rule for Variables**  
If `e = x`, look up `x` in the environment `Γ`. Suppose `Γ(x) = τ`. Return `(∅, τ)` (the empty substitution and the type from the environment). If `x` is not in `Γ`, the term is untypable.

**Rule for Constants**  
Constants have fixed types. For example `Γ ⊢ 5 : Int` with substitution `∅`.

**Rule for Abstraction λx. e**  
We need to infer a type for the body `e` under an extended environment that binds `x` to a fresh type variable `β`. Then the result is a function type from `β` to the inferred type of `e`.

Algorithm:

1. Generate a fresh type variable `β`.
2. Extend `Γ` to `Γ' = Γ ∪ {x ↦ β}`.
3. Recursively infer `(S, τ_body) = W(Γ', e)`.
4. Apply `S` to `β` to get the actual type of `x` that satisfies constraints within the body: `S(β)`.
5. Return `(S, S(β) -> τ_body)`.

**Rule for Application e1 e2**  
The function `e1` must have a function type, and the argument `e2` must match the domain.

Algorithm:

1. Infer `(S1, τ1) = W(Γ, e1)`.
2. Apply `S1` to `Γ` to get `Γ1 = S1(Γ)`.
3. Infer `(S2, τ2) = W(Γ1, e2)`.
4. Apply `S2` to `τ1` to get `τ1' = S2(S1(τ1))`.
5. Generate a fresh type variable `γ` for the result type.
6. Unify `τ1'` with `τ2 -> γ`. Let `U` be the most general unifier.
7. Return `(U ∘ S2 ∘ S1, U(γ))`.

**Rule for let x = e1 in e2**  
This is where let‑polymorphism comes in. First infer the type of `e1`. Then we **generalize** over any type variables not mentioned in `Γ` to produce a polymorphic type scheme. That scheme is then instantiated with fresh type variables when `x` is used in `e2`.

Algorithm:

1. Infer `(S1, τ1) = W(Γ, e1)`.
2. Compute `Γ' = S1(Γ)`.
3. Compute the set of free type variables in `τ1` that are not free in `Γ'`. These are the variables that can be generalized. Let `V = ftv(τ1) ∖ ftv(Γ')`.
4. Form a type scheme `∀V. τ1`.
5. Extend `Γ'` to `Γ'' = Γ' ∪ {x ↦ (∀V. τ1)}`.
6. Recursively infer `(S2, τ2) = W(Γ'', e2)`.
7. Return `(S2 ∘ S1, τ2)`.

The key step is how a variable bound to a type scheme is used. When we later encounter `x` in the body, we **instantiate** its scheme by creating fresh type variables for each universally quantified variable. For instance, if the scheme is `∀α. α -> α`, we might instantiate it to `β -> β` where `β` is a fresh variable. This allows each use of `x` to have a potentially different type, as long as they all are instances of the scheme.

**A Worked Example**  
Let’s infer the type of `λx. x` (the identity function) using Algorithm W.

- Expression: `λx. x`.
- Environment: empty `Γ`.
- Rule for abstraction: generate fresh `β` for `x`.
- Extend environment: `Γ' = {x: β}`.
- Infer body `x`: variable lookup gives `τ_body = β`.
- No substitution from body (since just a variable).
- Return `(∅, β -> β)`.
- So the principal type is `β -> β`. After renaming, we write `a -> a`.

Now consider the let expression:

```
let id = λx. x in (id 1, id "hello")
```

- Infer `e1` = `λx. x` as above: `(∅, β -> β)` with `Γ = ∅`.
- Generalization: free type variables in `τ1` = `{β}`; free in `Γ = ∅`. So `V = {β}`.
- Scheme: `∀β. β -> β`.
- Environment `Γ'' = {id : ∀β. β -> β}`.
- Now infer `(id 1, id "hello")`. Pair of expressions: we infer tuples separately.
- For `id 1`:
  - Look up `id` in environment: get scheme `∀β. β -> β`. Instantiate with fresh `β1`. So `id` now has type `β1 -> β1`.
  - Infer `1`: type `Int`.
  - Unify `β1` with `Int` → substitution `{β1 ↦ Int}`.
  - Result type: `Int`.
- For `id "hello"`: similarly instantiate with fresh `β2`, get `β2 -> β2`, unify with string type, get `String`.
- Pair: `(Int, String)`.
- The overall substitution from the body includes `β1 ↦ Int`, `β2 ↦ String`. No effect on `β` of the scheme.
- Final result: type `(Int, String)`.

Without let‑polymorphism, we would have been forced to assign a single type to `id`, making `(id 1, id "hello")` ill‑typed.

---

### Let‑Polymorphism and Its Subtleties

Let‑polymorphism is the crown jewel of Hindley‑Milner. It allows a single binding to be used at multiple types, as long as the variable is introduced via `let`. But why not allow the same for function parameters? The answer lies in safety and decidability. If a lambda‑bound variable could be polymorphic, we would need higher‑rank types (types with `∀` inside function arguments), which are not inferable in general. Hindley‑Milner restricts polymorphism to `let`‑bound variables, keeping inference decidable and complete.

This restriction is known as **let‑bound polymorphism** or **prenex polymorphism**. It works because the body of a `let` is closed: the bound variable is never used in a context that would force it to be monomorphic before generalization. In contrast, a lambda parameter is expected to be used at a single type in each invocation; making it polymorphic would require the caller to choose a type, which is not possible without annotations.

**The Value Restriction**  
Hindley‑Milner inference becomes tricky when the right‑hand side of a `let` is not a syntactic value. Consider:

```ocaml
let r = ref [] in r := [1]; r := ["hello"]
```

Here, `ref []` returns a mutable reference containing an empty list. If we generalize the type of `r` to `∀α. α list ref`, then we would be allowed to assign both an integer list and a string list to the same reference, which would be unsound because the reference would end up containing mixed types. To avoid this, ML dialects impose the **value restriction**: only syntactic values (variables, lambdas, constructors, etc.) can be generalized. If the right‑hand side is not a value (e.g., a function application like `ref []`), then it is not generalized—its type variables remain monomorphic. In this case, `r` gets a monomorphic type like `'a list ref` (with `'a` as a local variable that is unified with the first use). This conservative rule preserves soundness in the presence of mutable state.

The value restriction is often cited as a limitation of Hindley‑Milner, but it is a necessary trade‑off. Languages like Haskell, which are pure (no mutable cells), can drop the restriction entirely and generalize any expression. This is why Haskell’s type inference is often considered more powerful—though it too faces other constraints (e.g., the monomorphism restriction, which is being relaxed in recent GHC versions).

---

### Practical Examples in Modern Languages

Hindley‑Milner—or its close relatives—appears in many popular languages. Let’s see how it manifests in a few.

**Haskell**  
Haskell’s type inference is arguably the most complete implementation of Hindley‑Milner (plus extensions like multi‑parameter type classes and GADTs). You can write:

```haskell
-- No type annotations needed
filter' :: (a -> Bool) -> [a] -> [a]
filter' _ [] = []
filter' p (x:xs) = if p x then x : filter' p xs else filter' p xs
```

The compiler infers the principal type automatically. If you accidentally misuse a function, you get a clear error:

```haskell
-- Error: Couldn't match expected type ‘Bool’ with actual type ‘Int’
bad = map (+1) [True, False]
```

Haskell also uses type inference to support type classes: the `+` operator has type `Num a => a -> a -> a`, so `map (+1)` works on `[Int]`, `[Double]`, etc.

**OCaml**  
OCaml implements a variant of Hindley‑Milner with some differences (value restriction, row polymorphism). It is famous for its powerful inference, especially in the presence of labeled and optional arguments:

```ocaml
let compose f g x = f (g x)  (* inferred: ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b *)
```

OCaml also supports **polymorphic variants** which require clever inference to track possible tags.

**Rust**  
Rust’s type inference is based on Hindley‑Milner but tailored for its ownership system. Variables are often inferred without annotations:

```rust
fn main() {
    let v = vec![1, 2, 3];   // v is Vec<i32>
    let doubled: Vec<i32> = v.iter().map(|x| x * 2).collect();
}
```

Rust requires annotations for function signatures (to aid documentation and compilation speed), but inside function bodies inference works well.

**Swift and Kotlin**  
These languages offer local type inference that is not as powerful as full Hindley‑Milner: they often require annotations at function boundaries and do not support full let‑polymorphism (e.g., generics are a separate concept). However, inside a function, you can often omit type annotations:

```swift
let numbers = [1, 2, 3]
let squared = numbers.map { $0 * $0 }   // inferred: [Int]
```

Their inference algorithms are more ad‑hoc, but they draw inspiration from Hindley‑Milner.

**TypeScript**  
TypeScript uses a form of bidirectional inference that is highly pragmatic but not as principled. It can infer many types, but it sometimes struggles with higher‑order functions and complex generics. Its inference is not full Hindley‑Milner; it sacrifices completeness for better error messages and incremental compilation.

---

### Limitations and Extensions

Hindley‑Milner is not a panacea. Several extensions have been developed to overcome its limitations.

**Polymorphic Recursion**  
Consider a recursive function where the recursive call is at a different type than the function itself. For example:

```haskell
data Nested a = Leaf a | Nest (Nested [a])

flatten :: Nested a -> [a]
flatten (Leaf x) = [x]
flatten (Nest xs) = concat (flatten xs)
```

Here, `flatten` is called on `Nested [a]` inside the `Nest` case, which is a different type than the top‑level `a`. Standard Hindley‑Milner cannot infer this because it assumes recursive calls use the same type—it would try to unify `a` with `[a]`. To support this, we need an explicit type annotation to break the cycle. Languages like Haskell (with `-XPolymorphicRecursion`) allow this.

**Higher‑Rank Types**  
Sometimes you want a function to take a polymorphic argument:

```haskell
apply :: (forall a. a -> a) -> Int -> String
apply f x = (f x, f (show x))  -- illegal in plain Hindley‑Milner
```

Here, `f` must be a function that works for any type. This requires **higher‑rank polymorphism** (rank‑2 types). Inference for such types is undecidable in general, so languages require annotations for the parameter.

**GADTs**  
Generalized algebraic data types (GADTs) allow types of constructors to be more flexible, but they break the principal‑type property. GADTs require explicit type annotations in certain contexts.

**Monomorphism Restriction**  
In early Haskell, a let‑binding that is not a function could be generalized too eagerly, leading to unexpected sharing. The monomorphism restriction forced bindings that look like constants (e.g., `x = 1+2`) to have a monomorphic type. This is being lifted in modern Haskell (with `-XNoMonomorphismRestriction`).

---

### Impact on Language Design

Hindley‑Milner’s success has shaped the design of many languages. It offers a sweet spot: the programmer writes no type annotations for most expressions, yet enjoys full static safety. This encourages the use of higher‑order functions and generic programming.

However, it also imposes constraints. Languages must decide whether to prioritize inference over expressiveness. For instance, Rust’s ownership system forces occasional annotations (lifetimes). Swift’s inference is less predictable for complex generics. OCaml’s row‑polymorphism adds complexity. Haskell has moved beyond HM with extensions that require occasional annotations.

Some languages (like Go) have opted out of full inference to keep the type system simple and the compiler fast. Others (like Scala) have pushed the boundaries with implicit conversions and type‑level computation, sacrificing inference completeness.

---

### Conclusion: Why Hindley‑Milner Still Matters

Hindley‑Milner type inference is a triumph of theoretical computer science that has become a practical tool used by millions of programmers. It balances three often‑conflicting goals:

1. **Expressiveness** – it supports parametric polymorphism, higher‑order functions, and algebraic data types.
2. **Safety** – it guarantees that all type errors are caught at compile time, with no runtime type failures.
3. **Ergonomics** – it frees developers from writing repetitive type annotations, letting them write code that reads like a dynamic language.

The algorithm itself is elegant: it reduces type checking to equation solving via unification, and let‑polymorphism elegantly handles generic functions without requiring annotations. The cost is that some advanced patterns (polymorphic recursion, higher‑rank types) require explicit types, but these are rare in everyday code.

As we continue to design new languages, Hindley‑Milner remains a benchmark. Every modern type‑inference engine—whether in Rust, Swift, Kotlin, or TypeScript—owes a debt to the original work of Hindley, Milner, and Damas. The ability to deduce types from the way values are used is not magic; it’s a careful, well‑understood algorithm that deserves the admiration of every programmer who has ever benefited from the “invisible types” that quietly keep our code correct.

So the next time you write `map f lst` without a single type annotation, take a moment to appreciate the decades of research that make that possible. The types are there—they’re just invisible. And that’s exactly how they should be.

---

_This article was written as a deep dive into the theory and practice of Hindley‑Milner type inference. If you found it interesting, try implementing a small version of Algorithm W yourself—it’s a rewarding exercise that reveals the beauty of the algorithm in every unification step._
