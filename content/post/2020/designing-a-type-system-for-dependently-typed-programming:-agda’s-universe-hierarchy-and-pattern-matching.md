---
title: "Designing A Type System For Dependently Typed Programming: Agda’S Universe Hierarchy And Pattern Matching"
description: "A comprehensive technical exploration of designing a type system for dependently typed programming: agda’s universe hierarchy and pattern matching, covering key concepts, practical implementations, and real-world applications."
date: "2020-09-03"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/designing-a-type-system-for-dependently-typed-programming-agda’s-universe-hierarchy-and-pattern-matching.png"
coverAlt: "Technical visualization representing designing a type system for dependently typed programming: agda’s universe hierarchy and pattern matching"
---

# The Paradox at the Core of Certainty: Mastering Agda's Dependent Type System

## Introduction

Every programmer knows the quiet dread of a successful compilation followed by a catastrophic runtime failure. A `NullPointerException`. A `TypeError: cannot concatenate 'str' and 'int'`. A simple off-by-one error that corrupts a critical data structure. We’ve built our entire profession on a fragile truce with complexity. Static type systems are our great firewall, but even the most sophisticated—TypeScript’s intricate generics, Haskell’s monadic purity, Rust’s ownership semantics—are ultimately built on sand. They can guarantee the _shape_ of data, but not its _meaning_. They can tell you a function returns a _list_, but they cannot, as a matter of type-level law, guarantee it returns a list of the correct _length_.

This is not a limitation of engineering effort; it is a foundational limitation of the design space of **simple types**. The core contract of a function `sort(list: List<Int>) -> List<Int>` is a promise of shape, not semantic correctness. The type system trusts you. It implicitly assumes that the function you wrote is correct, because it has no language to express the inviolable relationship between the input and the output—that the output is a permutation, that it is sorted.

To move beyond this trust-based paradigm, we must enter a realm where types are not merely labels, but **first-class, executable specifications**. This is the promiseland of **Dependent Types**.

In a dependently typed language, types can depend on _values_. A `List` can be parameterized not just by its element type, but by its length: `Vector (A : Type) (n : Nat)`. A function to concatenate two vectors doesn't just return a `List`; its signature becomes `concat (v1 : Vec A n) (v2 : Vec A m) -> Vec A (n + m)`. The type of the result _contains the computing logic of the sum_. The compiler doesn't just check that you returned a list; it checks that the length of the result is exactly the sum of the lengths of the inputs. If your implementation accidentally drops an element, the program will not type-check.

This is not a static analysis trick; it is a logical guarantee. The type system becomes a _theorem prover_, and your program becomes a _proof_ that its specification holds for all possible inputs. Agda, developed at Chalmers University of Technology, is one of the most powerful and elegant dependently typed languages in existence. It is built on the Unifying Theory of Dependent Types (UTT), and it implements the full Curry-Howard Isomorphism: every program is a proof, and every type is a proposition.

In this comprehensive guide, we will tear down the walls between programming and mathematics. We will explore the fundamentals of dependent types, build intuition through concrete Agda examples, and demonstrate how to construct verified software that cannot crash, cannot corrupt data, and cannot violate its own specification. By the end, you will understand why Agda is not just another programming language—it is a tool for mathematical reasoning, a weapon against complexity, and a new way of thinking about correctness.

## The Limits of Traditional Type Systems

### The Trust Model

Let’s first examine the standard type systems we use daily. In languages like Java, C#, or Python (with type hints), the type checker verifies that operations on values respect certain shape constraints. A function declared as `List<Integer> f(List<Integer> xs)` promises that you will get a list of integers if you give it a list of integers. But the type system has no way to express that the output list has the same number of elements as the input, or that it is sorted, or that it contains no duplicates. The programmer must manually ensure these properties through testing, assertions, or external verification.

Consider a simple example: a function that returns the first element of a list.

```java
public static <A> A head(List<A> list) {
    return list.get(0);
}
```

This function will throw an `IndexOutOfBoundsException` if called on an empty list. The type system cannot prevent this. In Haskell, we have the `Maybe` type to force handling of the empty case:

```haskell
head :: [a] -> Maybe a
head [] = Nothing
head (x:_) = Just x
```

This is better, but it still does not _guarantee_ that the caller handles the `Nothing` case properly. More importantly, it does not allow us to express that a function _always_ returns a value for non-empty lists. We could use a `NonEmpty` list type, but that requires library support and still doesn't connect the length of the input to the output.

### The Gap Between Type and Property

The fundamental problem is that simple types are **type-level data** that must be determined at compile time, but they cannot depend on runtime values. In `List<Int>`, the type parameter `Int` is fixed, but the length of the list is a runtime value that is invisible to the type system. We cannot write a function with signature:

```haskell
append :: Vec a n -> Vec a m -> Vec a (n+m)
```

because `n` and `m` are runtime values that `Vec` must somehow know about. In a dependently typed language, `n` and `m` are both _values_ of type `Nat` (natural numbers) that appear in the _types_ of the vectors and the result. This is not merely a syntactic sugar; it requires the type checker to compute `n + m` as a term, which may involve recursion, case analysis, and even termination checking.

### The Limitations of Refinement Types

Some languages offer “refinement types” (e.g., Liquid Haskell) that allow predicates on values, like `{v: Int | v > 0}`. This is a step in the right direction, but refinement types are still built on top of a simple underlying type system. They cannot express dependencies between _multiple_ values in a generic way. For example, the length of a list is a natural number that is part of the list’s _structure_; you cannot separate it from the list itself without losing information.

Moreover, refinement types are usually limited to decidable logics (e.g., Presburger arithmetic) to keep type checking automatic. Dependent types, on the other hand, allow arbitrary computation in types, making the type system Turing-complete. This power comes at a cost—type checking becomes undecidable in general—but with careful design (e.g., Agda’s termination and positivity checks), practical verification becomes achievable.

## What Are Dependent Types?

A dependent type is a type that depends on a _value_. The classic example is the type of vectors: `Vec A n` where `A` is the element type and `n` is a natural number representing the length. Here, `n` is a value of type `Nat`, and it is part of the type of the vector. This means that the type of a vector _contains_ its length. Functions that operate on vectors can express invariants in their signatures.

Dependent types arise naturally in several forms:

### 1. Dependent Functions

A dependent function (also called a Π-type) is a function whose return type depends on the _value_ of its argument. For example, consider a function that takes a natural number `n` and returns a vector of booleans of length `n` containing all `true`s:

```agda
replicate : (n : Nat) → Vec Bool n
replicate zero    = []
replicate (suc n) = true ∷ replicate n
```

The type of `replicate n` is `Vec Bool n`, which depends on the value `n`. In a traditional type system, we could write `replicate :: Int -> [Bool]`, but we could not encode the length in the type.

### 2. Dependent Pairs

A dependent pair (Σ-type) is a pair where the type of the second component depends on the value of the first. For example, `Σ (n : Nat) (Vec Bool n)` is the type of pairs `(n, xs)` where `xs` is a boolean vector of length `n`. This encapsulates an arbitrary-length vector without losing the length information.

### 3. Inductive Families

Inductive families are data types that are indexed by values. The classic example is `Vec` itself:

```agda
data Vec (A : Set) : Nat → Set where
  []  : Vec A zero
  _∷_ : {n : Nat} → A → Vec A n → Vec A (suc n)
```

Here, `Vec` is indexed by a natural number `Nat`. Each constructor enforces a certain index: `[]` only builds a vector of length zero, and `_∷_` adds one element, increasing the length by one. This indexing is not arbitrary; it is forced by the structure of the data.

## Agda: A Dependently Typed Programming Language

Agda is a functional language with a strong emphasis on theorem proving. It is named after the Swedish word for “the spirit of a system” (Agda is also a character in a famous Swedish children’s book). It is developed at Chalmers University and has been used for significant verification projects, such as the proof of the Four Color Theorem (in its predecessor, Coq, but Agda has its own contributions).

Agda’s syntax is similar to Haskell’s, but with some key differences: it uses Unicode heavily, it is case-sensitive (constructors are uppercase, functions lowercase), and it uses a set theoretic foundation with `Set` as the type of types. Agda supports interactive development through Emacs with a ‘hole’ system: you can write a program with `?` placeholders, and the system will tell you what type the placeholder should have, and even generate possible terms.

### Setting Up Agda

To follow along, you need to install Agda (version 2.6.x) and its standard library. Installation instructions are available on the Agda wiki. The Emacs mode is highly recommended because it provides syntax highlighting, hole filling, and automatic case splitting.

## Deep Dive: Natural Numbers and Vectors in Agda

Let’s start with the building blocks of dependent types: natural numbers and vectors.

### Natural Numbers

In Agda, natural numbers are defined as an inductive data type:

```agda
data ℕ : Set where
  zero : ℕ
  suc  : ℕ → ℕ
```

We can define addition:

```agda
_+_ : ℕ → ℕ → ℕ
zero  + m = m
suc n + m = suc (n + m)
```

This is standard. But note that this definition is _recursive_ and _termination-checked_. Agda ensures that every recursive call is on structurally smaller arguments, preventing infinite loops. This is crucial because functions are used in types, and non-terminating functions would make type checking unsound.

### Vectors (Length-Indexed Lists)

The `Vec` type is defined as:

```agda
data Vec (A : Set) : ℕ → Set where
  []  : Vec A zero
  _∷_ : ∀ {n} → A → Vec A n → Vec A (suc n)
```

Here, `∀ {n}` is an implicit argument. The `Vec` type is parameterized by `A : Set` (the element type) and indexed by `ℕ`. The constructors are: `[]` (empty vector, length zero) and `_∷_` (cons, takes an element and a vector of length `n` to produce a vector of length `suc n`).

Now we can write a function to compute the length of a vector. But because the length is already in the type, we don't need a function that returns `ℕ`; we can just pattern match on the vector’s index. However, we might still want a function that returns the length as a value:

```agda
length : ∀ {A n} → Vec A n → ℕ
length {n = n} _ = n
```

But this is trivial: the length is part of the type. We can also write a function that returns the length as a vector of `ℕ`? Actually, we can use Agda’s reflection.

### Concatenation of Vectors

Now for the pièce de résistance: append with a type that guarantees the length of the result is the sum of the lengths of the inputs.

```agda
_++_ : ∀ {A m n} → Vec A m → Vec A n → Vec A (m + n)
[]       ++ ys = ys
(x ∷ xs) ++ ys = x ∷ (xs ++ ys)
```

The type signature says: for any types `A`, and lengths `m` and `n`, given a vector of length `m` and a vector of length `n`, return a vector of length `m + n`. The implementation is straightforward: for empty left vector, return the right vector; for non-empty, recurse. The type checker will verify that the recursive call returns a vector of length `(m - 1) + n`, which is exactly `(suc m) + n - 1`? Actually, the pattern match reduces `m` to `suc m'` (since we have `x ∷ xs` of length `suc m'`). So the result type of the recursive call is `Vec A (m' + n)`, and then we cons `x` to get `Vec A (suc (m' + n))`. But the type we need is `Vec A ((suc m') + n)`. By the definition of `+`, `(suc m') + n = suc (m' + n)`. So the types match exactly. The type checker uses the definition of `+` to reduce the types and check equality. This is a simple example of how computation happens in types.

### Verification: The Append Proof

We can also prove properties about our functions using the type system itself. For example, we might want to prove that concatenation is associative. In Agda, we can write a function that returns a proof:

```agda
++-assoc : ∀ {A l m n} (xs : Vec A l) (ys : Vec A m) (zs : Vec A n) →
           (xs ++ ys) ++ zs ≡ xs ++ (ys ++ zs)
++-assoc []       ys zs = refl
++-assoc (x ∷ xs) ys zs = cong (x ∷_) (++-assoc xs ys zs)
```

Here, `≡` is propositional equality (defined as an inductive family). The proof by induction on `xs` is straightforward: the base case `xs = []` gives `(++ ([] ys) zs) = ys ++ zs` and `++ ([] (ys ++ zs)) = ys ++ zs`, so `refl` (reflexivity) works. In the inductive step, we use `cong` (congruence) to apply `x ∷_` to the recursive proof.

This proof is a _total function_: it must handle all cases, and it must terminate. Agda’s termination checker ensures that the recursive call is on structurally smaller `xs`. The associativity of append is now a theorem that holds for all vectors.

## Theorem Proving in Agda: The Curry-Howard Correspondence

The previous example illustrates the deep connection between programming and logic called the Curry-Howard correspondence. In simple terms:

- **Types are propositions**.
- **Programs are proofs**.
- **Evaluation of a term corresponds to normalization of a proof**.

When we write a function of type `(xs : Vec A l) (ys : Vec A m) (zs : Vec A n) → (xs ++ ys) ++ zs ≡ xs ++ (ys ++ zs)`, we are proving that for all vectors `xs`, `ys`, `zs`, the concatenation operation is associative. The function body is a proof by induction; the pattern matching corresponds to case analysis, and recursion corresponds to the induction hypothesis.

In Agda, this is not just a metaphor; it is literally how the language works. The type `∀ (x : T) → P x` is a universal quantification. The type `∃ (x : T) × P x` is an existential quantification implemented as a dependent pair. Logical connectives like conjunction (`∧`) are encoded as product types, and disjunction (`∨`) as sum types (tagged unions). Implication is a function type.

### Example: Proving `1 + 1 = 2`

We can write a proof that `1 + 1 ≡ 2` in Agda:

```agda
1+1≡2 : (suc zero + suc zero) ≡ suc (suc zero)
1+1≡2 = refl
```

Because `suc zero + suc zero` reduces to `suc (zero + suc zero)` then to `suc (suc zero)`, the two sides are definitionally equal (they reduce to the same term). `refl` is a proof of equality when the two terms are syntactically identical after reduction.

But not all equalities are definitional. For example, associativity of addition is not definitional; we must prove it by induction.

```agda
+-assoc : ∀ a b c → (a + b) + c ≡ a + (b + c)
+-assoc zero    b c = refl
+-assoc (suc a) b c = cong suc (+-assoc a b c)
```

Again, induction on `a`. This is a very simple proof; more complex theorems require deeper reasoning.

## Advanced Example: Verified Sorting

One of the most impressive applications of dependent types is verified sorting. We can write a sorting algorithm whose type guarantees that the output is sorted and is a permutation of the input.

### Defining Ordered Lists

First, we need a proposition that a list is sorted. We define an inductive family `Sorted` that holds for a list `xs` if it is sorted in non-decreasing order.

```agda
data Sorted {A : Set} (_≤_ : A → A → Set) : List A → Set where
  nil  : Sorted _≤_ []
  sing : ∀ x → Sorted _≤_ [ x ]
  cons : ∀ {x y xs} → x ≤ y → Sorted _≤_ (y ∷ xs) → Sorted _≤_ (x ∷ y ∷ xs)
```

But this is for plain lists. For vectors, we can do similar indexing. For simplicity, let's work with `List` but with a proof of sortedness attached.

A function `sort` would then have the type:

```agda
sort : (xs : List A) → Σ (List A) (λ ys → Sorted _≤_ ys × Permutation xs ys)
```

Here, `Permutation` is a relation that says `ys` is a permutation of `xs`. This is a heavy specification, but it can be done. In Agda, we can implement insertion sort and prove it correct.

### Insertion Sort Example

We will implement insertion sort on natural numbers with the usual ordering `_≤_`. First, define `Insert` that inserts an element into a sorted list, preserving sortedness:

```agda
insert : ℕ → List ℕ → List ℕ
insert x [] = x ∷ []
insert x (y ∷ ys) with x ≤? y
... | yes _ = x ∷ y ∷ ys
... | no  _ = y ∷ insert x ys
```

But we also need a proof that `insert` returns a sorted list if the input is sorted. We can write a lemma:

```agda
insert-sorted : ∀ x {xs} → Sorted _≤_ xs → Sorted _≤_ (insert x xs)
insert-sorted x nil = sing x
insert-sorted x (sing y) with x ≤? y
... | yes x≤y = cons x≤y (sing y)
... | no  x>y = cons (Nat.≤-trans (Nat.≤-reflexive ?) ?) ... -- becomes messy
```

This becomes hairy quickly. The Agda standard library provides tools to help. But the point is that we can encode these properties.

### Binary Search Trees with Height Balance

Another classic verified data structure is a balanced binary search tree (e.g., AVL trees). With dependent types, we can enforce that the tree is truly a binary search tree (every key in the left subtree is less than the root, and every key in the right subtree is greater) and that the height is balanced (the difference between heights of left and right subtrees is at most one). This can be done using indexed types where the index encodes the tree’s structure.

For example, we can define a type `BST (lower upper : ℕ)` that represents a binary search tree containing keys in the interval `(lower, upper)`. The constraints on insertion ensure that new keys fall within the bounds.

This is reminiscent of the concept of **refinement types** but taken to the extreme: the type is a full specification.

## Comparison with Other Dependently Typed Languages

Agda is not alone in the dependently typed world. Here’s how it compares to other prominent systems:

| Language        | Key Features                                                        | Use Cases                                                      |
| --------------- | ------------------------------------------------------------------- | -------------------------------------------------------------- |
| **Agda**        | Pure dependent types, strong normalization, interactive development | Theorem proving, certified programming                         |
| **Coq**         | Tactics-based proof assistant, extraction to OCaml/Haskell          | Large-scale formalization (e.g., CompCert, Four Color Theorem) |
| **Idris**       | Dependently typed with practical features (effects, IO, FFI)        | General-purpose programming with verification                  |
| **Lean**        | Fast, powerful tactics, large library, active community             | Theorem proving, mathematics (e.g., perfectoid spaces)         |
| **F\* (FStar)** | Effect types, refinement types, SMT automation                      | Low-level security verification                                |

Agda is distinguished by its minimalism: it has no tactics, no built-in automation, and relies entirely on the user writing terms. This makes it both elegant and challenging. The Emacs Agda mode provides powerful hole-based development that often compensates.

## Practical Considerations: Writing Real Programs in Agda

While Agda is primarily a proof assistant, it is a total programming language, meaning every function must terminate, and every pattern match must be exhaustive. This guarantees that all programs are well-defined and free of runtime errors (including non-termination).

However, this comes at a cost. Writing Agda code is often slower than writing in other languages because you must prove properties as you go. For industrial-scale software, this is often impractical, but for safety-critical systems (e.g., avionics, medical devices, smart contracts), it is invaluable.

### Compilation and Execution

Agda programs can be compiled to Haskell or JavaScript using the Agda compiler. There is also a backend that produces standalone executables. The standard library provides facilities for IO, state, and other effects, though they are wrapped in a `IO` monad similar to Haskell’s.

### Learning Curve

The learning curve for Agda is steep. You need to understand:

- Dependent pattern matching and the `with` construct.
- The universe hierarchy (`Set`, `Set1`, ...).
- Proving equality and using rewriting.
- Termination and positivity checking.
- The interactive development environment.

But the reward is a deep understanding of how types and proofs interact.

## Conclusion

We began with a lament: that our best type systems cannot guarantee the meaning of our programs, only their shape. Dependent types shatter this limitation. In Agda, we can write functions whose types express invariants so precisely that a correct-by-construction program becomes the norm, not the exception.

From simple vector concatenation to verified sorting algorithms and balanced trees, Agda lets us encode specifications as types and then fill in the proofs interactively. The type checker becomes a theorem prover, and the development process becomes a dialogue between the programmer and the logic.

Is dependent typing the future of software engineering? Perhaps not for everyday applications—the overhead is too high for most projects. But for the foundations of critical systems, for cryptographic protocols, for programming languages themselves, dependent types offer a path to truly fault-free software.

The paradox of certainty is resolved: with Agda, we don’t just trust our code; we prove it correct. And in that proof lies the ultimate form of engineering confidence.

---

_If you enjoyed this deep dive, try installing Agda and working through the exercises in the Agda Tutorial. The journey from "sort works on lists" to "sort is proven correct" is long, but every step is a testament to the power of dependent types._
