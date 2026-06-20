---
title: "Linear Logic: Girard's Resource-Sensitive Logic, Exponential Modalities, and Linear Types in Rust"
description: "A comprehensive exploration of linear logic's resource-conscious foundations, proof nets, the ! and ? modalities translating intuitionistic to linear, and how Rust's ownership system mirrors these ideas."
date: "2021-09-29"
author: "Leonardo Benicio"
tags: ["linear-logic", "proof-theory", "linear-types", "rust", "girard", "resource-awareness"]
categories: ["theory", "mathematics"]
draft: false
cover: "/static/images/blog/linear-logic-resource-aware-computation.png"
coverAlt: "Diagram showing linear logic proof net with boxes representing exponential modalities"
---

In 1987, Jean-Yves Girard published a paper that would fundamentally alter how we think about logic and computation. The paper, titled simply "Linear Logic," introduced a new logical system where every assumption must be used exactly once. This was not a restriction for restriction's sake—it was a revelation. Girard had discovered that classical and intuitionistic logic could be decomposed into a finer-grained, resource-sensitive substrate. The ordinary implication \(A \to B\) was not primitive; it was the linear implication \(A \multimap B\) (use \(A\) exactly once to produce \(B\)) combined with the exponential modality \(!\) (allowing unlimited reuse). In symbols: \(A \to B \equiv \; !A \multimap B\).

This decomposition has profound consequences for computer science. It connects directly to memory management (linear types guarantee single ownership), concurrent computation (session types arise from linear logic's connectives), and program optimization (proof nets eliminate syntactic bureaucracy). When Rust programmers speak of "ownership," "borrowing," and "lifetimes," they are speaking—whether they know it or not—in the vocabulary of linear logic. The Rust type system is, in a very precise sense, an affine type system (use at most once) that lives on the linear-logical spectrum.

## 1. The Syntax of Linear Logic

Linear logic is built from a small set of connectives, each of which comes in two flavors: _multiplicative_ and _additive_. The multiplicative connectives correspond to parallel composition of resources; the additive connectives correspond to choice between resources. This division is not accidental—it reflects the difference between "and" as parallel independent availability (\(\otimes\)) and "and" as alternative availability (\(\with\)). The distinction is crucial for understanding the computational content.

**Multiplicatives:**

- \(A \otimes B\) (tensor): simultaneous availability of \(A\) and \(B\). To use \(A \otimes B\), you must eventually use both.
- \(A \parr B\) (par): the De Morgan dual of tensor. In the classical setting, \(\parr\) represents a kind of "disjunctive" parallel composition.
- \(\mathbf{1}\) (one): the unit of tensor. Represents no resources.
- \(\bot\) (bottom): the unit of par.
- \(A \multimap B\) (linear implication): defined as \(A^\perp \parr B\) in classical linear logic. Consumes \(A\) to produce \(B\).

**Additives:**

- \(A \with B\) (with): a choice that the _environment_ makes. Think of it as a pair where you can only use one component.
- \(A \oplus B\) (plus): a choice that the _system_ makes. Think of it as a tagged union.
- \(\top\) (top): the unit of with—a resource that can satisfy any demand (trivially).
- \(\mathbf{0}\) (zero): the unit of plus—no resource at all.

**Exponentials:**

- \(!A\) (of course): \(A\) can be used any number of times (including zero). This is what recovers intuitionistic implication.
- \(?A\) (why not): the De Morgan dual of \(!\). In the classical setting, represents a "reusable" acceptance of \(A\).

**Negation:**

- \(A^\perp\): linear negation, defined by De Morgan duality: \((A \otimes B)^\perp = A^\perp \parr B^\perp\), \((A \oplus B)^\perp = A^\perp \with B^\perp\), \((!A)^\perp = ?A^\perp\), etc.

### 1.1 The Sequent Calculus for Linear Logic

Linear logic is naturally presented in a one-sided sequent calculus. A sequent \(\vdash \Gamma\) means "the resources \(\Gamma\) are available, and the sequent is provable if they can be consumed according to the rules." The identity group:

\[
\frac{}{\vdash A, A^\perp} \; \text{(axiom)} \qquad
\frac{\vdash \Gamma, A \quad \vdash \Delta, A^\perp}{\vdash \Gamma, \Delta} \; \text{(cut)}
\]

The multiplicative rules:

\[
\frac{\vdash \Gamma, A \quad \vdash \Delta, B}{\vdash \Gamma, \Delta, A \otimes B} \; (\otimes) \qquad
\frac{\vdash \Gamma, A, B}{\vdash \Gamma, A \parr B} \; (\parr)
\]

The additive rules are more subtle, requiring a _context-splitting_ discipline: in the \((\with)\) rule, the same context \(\Gamma\) must be able to prove _both_ \(A\) and \(B\):

\[
\frac{\vdash \Gamma, A \quad \vdash \Gamma, B}{\vdash \Gamma, A \with B} \; (\with) \qquad
\frac{\vdash \Gamma, A}{\vdash \Gamma, A \oplus B} \; (\oplus_1) \quad
\frac{\vdash \Gamma, B}{\vdash \Gamma, A \oplus B} \; (\oplus_2)
\]

The exponential rules: \(!\) has the powerful structural rules of weakening and contraction built into its introduction:

\[
\frac{\vdash ?\Gamma, A}{\vdash ?\Gamma, !A} \; (!) \qquad
\frac{\vdash \Gamma}{\vdash \Gamma, ?A} \; (\text{weakening}) \qquad
\frac{\vdash \Gamma, ?A, ?A}{\vdash \Gamma, ?A} \; (\text{contraction})
\]

Observe the pattern: the \(!\) introduction rule requires that every other formula in the context be prefixed with \(?\). This enforces a strict separation between linear and nonlinear reasoning. A formula marked with \(!\) can be promoted from the linear world to the nonlinear world, but only in a context where everything else is already nonlinear (\(?\)). This stratification is the key to proving cut elimination for the full system.

### 1.2 Intuitionistic Linear Logic

For programming languages, we typically work with _intuitionistic_ linear logic (ILL), where sequents have exactly one conclusion: \(\Gamma \vdash A\). ILL is the fragment most relevant to type systems. The connectives simplify: \(\parr\) disappears (it is absorbed into \(\multimap\)), and we are left with \(\otimes\), \(\multimap\), \(\with\), \(\oplus\), \(!\), and the constants.

In ILL, the linear implication introduction rule is:

\[
\frac{\Gamma, A \vdash B}{\Gamma \vdash A \multimap B} \; (\multimap I)
\]

And the elimination rule is modus ponens:

\[
\frac{\Gamma \vdash A \multimap B \quad \Delta \vdash A}{\Gamma, \Delta \vdash B} \; (\multimap E)
\]

The crucial property is _context splitting_: the contexts \(\Gamma\) and \(\Delta\) in the elimination rule must be _disjoint_—each resource is used in exactly one premise. This enforces the linearity constraint: you cannot use the same resource twice.

### 1.3 Linear Logic as a Substructural Logic

Linear logic belongs to the family of _substructural logics_, which restrict the structural rules of classical logic. In Gentzen's sequent calculus for classical logic, we have:

- **Weakening:** \(\frac{\Gamma \vdash \Delta}{\Gamma, A \vdash \Delta}\) (add an unused assumption).
- **Contraction:** \(\frac{\Gamma, A, A \vdash \Delta}{\Gamma, A \vdash \Delta}\) (merge duplicate assumptions).
- **Exchange:** \(\frac{\Gamma, A, B, \Gamma' \vdash \Delta}{\Gamma, B, A, \Gamma' \vdash \Delta}\) (reorder assumptions).

Linear logic drops weakening and contraction globally and restores them locally via the exponentials. This is the key design choice: rather than having structural rules as global properties, they become logical connectives with explicit introduction and elimination rules. The result is a logic that is both more expressive (it distinguishes between resources used once, zero times, or many times) and better-behaved (cut elimination is more explicit and parallelizable).

## 2. Proof Nets: The Geometry of Linear Proofs

One of Girard's most beautiful innovations is _proof nets_. In sequent calculus, many proofs differ only by inessential permutations of rules—bureaucracy. For example, if you have \(\vdash \Gamma, A, B, C\) and apply tensor rules to combine \(A \otimes B\) first and then \((A \otimes B) \otimes C\), versus combining \(B \otimes C\) first and then \(A \otimes (B \otimes C)\), you get different proof trees that are morally the same. Proof nets eliminate this redundancy by representing proofs as graphs.

### 2.1 The Structure of Proof Nets

A proof net for the multiplicative fragment (MLL) is a graph built from:

- **Axiom links:** connecting dual atomic formulas \(A\) and \(A^\perp\).
- **Tensor nodes:** with two premises (the components of the tensor) and one conclusion.
- **Par nodes:** with two premises and one conclusion (or dually, one premise and two conclusions).

The graph must satisfy the _Danos-Regnier correctness criterion_: for every "switching" (a choice of one edge at each par node), the resulting graph is acyclic and connected. This criterion precisely characterizes which graphs correspond to valid proofs.

There is also a _contractibility criterion_, due to Danos, which is perhaps more intuitive: a proof structure is a proof net if and only if it contracts to a single point under a specific set of graph reduction rules (axiom annihilation and tensor-par annihilation).

### 2.2 Cut Elimination as Graph Rewriting

In proof nets, cut elimination (the normalization of proofs) becomes a purely local graph rewriting process. A cut between an axiom link and its dual simply disappears. A cut between tensor and par decomposes into two smaller cuts:

```
    A     B      A⊥    B⊥
     \   /        \   /
      ⊗            ⅋
       \          /
        \        /
         \      /
          CUT --->

    A -- CUT -- A⊥    B -- CUT -- B⊥
```

This geometric simplification is not just aesthetically pleasing—it reveals that cut elimination in linear logic is a distributed, parallelizable process. Each cut reduction is independent of others, and they can be performed in any order—the Church-Rosser property holds strongly.

An important theorem: _strong normalization_ for MLL proof nets can be proved by a simple combinatorial argument on the size of the net (specifically, the number of axiom links). Every reduction step decreases this measure, so the process must terminate. This is much simpler than the syntactic strong normalization proofs for the sequent calculus.

### 2.3 Boxes for Exponentials

The exponential modality \(!\) introduces _boxes_: a proof of \(!A\) is a box containing a proof of \(A\) that may be duplicated or discarded. In proof nets, boxes are subgraphs that are "sealed" from interaction until they are explicitly opened (dereliction) or duplicated (contraction). The box structure is what makes the system nontrivial—and also what makes it resistant to simple parallel cut elimination, because boxes can be nested.

The geometry of interaction (GoI), also due to Girard, provides an alternative: rather than boxes, use a dynamic algebra of operators that encode the exponential structure. GoI gives a semantics for cut elimination as a process of token passing through a network, making explicit the computational content of proofs. This has been developed into the _geometry of interaction machine_, an abstract model of computation.

### 2.4 The Danos-Regnier Criterion in Detail

Let us understand the switching criterion more carefully. A _switching_ for a proof structure is a choice, for each par node, of one of its two premise edges (the "left" or "right" premise). Deleting the edges not chosen in the switching yields a graph called a _switching graph_. The proof structure is a proof net if and only if every switching graph is acyclic and connected.

Consider the following structure (which is NOT a proof net):

```
    A     B     A⊥    B⊥
     \   /       \   /
      ⊗           ⊗
       \         /
        \       /
         \     /
          ⅋
```

In the switching where we choose the outer edges of the par, the graph becomes disconnected. Hence this is not a proof net. Intuitively, it attempts to "match" the components of two tensors in a way that violates the sequential nature of logical deduction. The switching criterion rules out such "Möbius-like" structures.

## 3. Resource Semantics and the Curry-Howard Correspondence

The Curry-Howard correspondence for linear logic connects each connective to a programming construct:

| Connective        | Logical Meaning                | Programming Meaning           |
| ----------------- | ------------------------------ | ----------------------------- |
| \(A \otimes B\)   | Both \(A\) and \(B\)           | Pair type (must use both)     |
| \(A \multimap B\) | Use \(A\) to get \(B\)         | Linear function type          |
| \(A \with B\)     | Choose between \(A\) and \(B\) | A pair where only one is used |
| \(A \oplus B\)    | Either \(A\) or \(B\)          | Sum type                      |
| \(!A\)            | Reusable \(A\)                 | Unrestricted/shared value     |
| \(\mathbf{1}\)    | Empty resource                 | Unit type                     |

The linear function type \(A \multimap B\) is the heart of resource-aware type systems. A function of this type _must_ use its argument exactly once. It cannot discard it (no weakening) and cannot duplicate it (no contraction). This is exactly the property that Rust's ownership system approximates with its move semantics.

### 3.1 The Translation of Intuitionistic Logic into Linear Logic

Girard's translation embeds intuitionistic logic into linear logic by marking each formula with \(!\) at the right places. Define:

\[
\begin{aligned}
(A \to B)^_ &= \; !A^_ \multimap B^_ \\
(A \land B)^_ &= \; A^_ \with B^_ \\
(A \lor B)^_ &= \; !A^_ \oplus !B^_ \\
(\neg A)^_ &= \; !A^\* \multimap \mathbf{0}
\end{aligned}
\]

Under this translation, a proof of \(A\) in intuitionistic logic becomes a proof of \(A^\*\) in linear logic. The \(!\) marks exactly the points where contraction and weakening are needed—where intuitionistic assumptions can be used zero or multiple times.

This translation reveals that intuitionistic logic is not "fundamental" in the resource-sensitive sense; it is linear logic with explicit permission to discard and duplicate. This is a profound insight: the "default" logic should be linear, and the ability to reuse assumptions should be opt-in.

### 3.2 Affine and Relevant Logics as Points on the Spectrum

Between linear logic (use exactly once) and intuitionistic logic (use any number of times) lie two intermediate systems:

- **Affine logic:** Allows weakening but not contraction. Resources can be discarded but not duplicated. This corresponds to Rust's ownership: values can be dropped, but they cannot be implicitly copied.
- **Relevant logic:** Allows contraction but not weakening. Resources can be duplicated but not discarded. This rejects the principle that a true statement follows from any premises—every assumption must be used at least once.

Linear logic unifies these by providing both weakening and contraction in a controlled way via the \(!\) modality. In a sense, it is the most expressive point on the spectrum, from which the others can be recovered by choosing which structural rules to apply freely.

## 4. Linear Types in Programming Languages

The idea of using linear logic as a type system for programming was pioneered by Philip Wadler in his 1990 paper "Linear types can change the world!" The slogan captures the intuition: a function with a linear type can mutate its argument in place because it knows no other reference to that value exists.

### 4.1 Wadler's Linear Types

Wadler's system extends the lambda calculus with a type system that tracks usage. Each variable is annotated with a multiplicity: `1` (linear, used exactly once), `ω` (unrestricted, used any number of times), or `0` (unused). The typing judgment \(\Gamma \vdash e : A\) splits the context: linear variables appear in exactly one subderivation, while unrestricted variables can be shared.

```haskell
-- Linear lambda: a function that uses its argument exactly once
linearMap :: (a ⊸ b) -> [a] ⊸ [b]
linearMap f [] = []
linearMap f (x:xs) = f x : linearMap f xs
```

Where `⊸` is the linear arrow.

### 4.2 Rust's Ownership as an Affine Type System

Rust's ownership system is best understood as an _affine_ type system. Each value in Rust has exactly one owner at any given time. When the owner goes out of scope, the value is dropped (memory freed, file closed, lock released). Ownership can be transferred (moved), but by default, values are not implicitly copied.

```rust
fn consume(s: String) {
    // s is moved here; the caller can no longer use it
    println!("{}", s);
}
// After consume returns, s is dropped
```

Rust provides `Copy` types for values that can be implicitly duplicated (like integers and booleans), and `Clone` for explicit duplication. References (`&T`) allow temporary, non-owning access without consuming the value—this is akin to the dereliction rule of linear logic: `!A ⊸ A`. A shared reference `&T` implements `Copy` (it can be duplicated), implementing the contraction rule at the level of references rather than values.

The lifetime system ensures that references never outlive the owned value they point to, preventing use-after-free errors. This is a safety property that follows from the linear discipline: if a value is used exactly once (in the sense of having a unique owner), then when that owner is disposed of, there can be no dangling references.

### 4.3 Linear Haskell

The GHC Haskell compiler recently gained support for linear types (the `LinearTypes` language extension). This allows writing functions with linear arrows `a %1 -> b`, which guarantee that the function consumes its argument exactly once. For example:

```haskell
{-# LANGUAGE LinearTypes #-}

-- A linear function that mutates an array in place
modifyArray :: Array a %1 -> (a -> a) -> Array a
```

This is particularly useful for guaranteeing safe mutation of mutable data structures without breaking referential transparency. Since the function consumes the array linearly, no other reference can exist, and in-place mutation is safe.

### 4.4 Session Types as Linear Logic

One of the most striking applications of linear logic to programming is _session types_, discovered by Honda (1993) and later connected to linear logic by Caires and Pfenning (2010). In the propositions-as-sessions correspondence:

- \(A \otimes B\) means "send \(A\), then continue as \(B\)."
- \(A \multimap B\) means "receive \(A\), then continue as \(B\)."
- \(A \oplus B\) means "select between \(A\) and \(B\) (internal choice)."
- \(A \with B\) means "offer a choice between \(A\) and \(B\) (external choice)."
- \(!A\) means "a replicable server providing \(A\)."
- \(\mathbf{1}\) means "close the session."

Under this correspondence, a linear logic proof is a communication protocol, and cut elimination is the interaction between two communicating processes. This is the foundation of the _Curry-Howard correspondence for concurrency_. The Rust framework `ferrite` and the Haskell library `sesh` implement session types based on these ideas.

### 4.5 Differential Linear Logic and Automatic Differentiation

A recent and exciting development is _differential linear logic_ (DiLL), introduced by Ehrhard and Regnier (2006). DiLL extends linear logic with _differential_ structure: morphisms can be differentiated, giving a notion of linear approximation. This provides a semantic foundation for automatic differentiation—the technique at the heart of modern machine learning.

In DiLL, the exponential \(!A\) is interpreted not just as "many copies of \(A\)" but as the space of _smooth_ functions on \(A\). The promotion rule corresponds to the Taylor expansion: a nonlinear function can be approximated by an infinite sum of multilinear maps. This connects directly to the reverse-mode automatic differentiation (backpropagation) used in deep learning frameworks. The linear type discipline ensures that gradients are computed exactly once and that no memory is leaked during the backward pass.

## 5. The Geometry of Interaction and Complexity

Girard's Geometry of Interaction (GoI) provides a dynamic semantics for linear logic cut elimination. In GoI, proofs are interpreted as operators on a Hilbert space (or, in the simplified "token machine" version, as state transition systems). Cut elimination becomes the computation of the feedback (or "execution formula"):

\[
\mathrm{EX}(u, \sigma) = \sum\_{n \geq 0} \sigma (u \sigma)^n
\]

where \(\sigma\) is the operator representing the cut, and \(u\) is the operator representing the rest of the proof. This formula computes the normal form without actually performing reduction—it is a kind of "analytic" computation.

### 5.1 Reversible Computing and Quantum Logic

Linear logic has deep connections to reversible and quantum computation. Because linear logic proofs are fundamentally about the movement and transformation of resources without duplication or erasure (except where explicitly marked by \(!\)), they naturally model reversible computations. The tensor \(\otimes\) and par \(\parr\) connectives are reminiscent of entanglement and the tensor product of quantum states.

Indeed, there is a well-developed _quantum programming language_ tradition that builds on linear logic, including the QPL language (Selinger, 2004) and the Quipper system. The key insight: quantum data cannot be cloned (no-cloning theorem) and cannot be erased (unitarity). This is exactly the linear discipline: quantum states are linear resources.

### 5.2 Complexity Bounds via Light Linear Logic

Girard's _Light Linear Logic_ (LLL) and _Elementary Linear Logic_ (ELL) refine the exponential \(!\) into stratified versions that control the complexity of cut elimination. In LLL, the modality is split into two: a "functorial" \(!\) (permitting arbitrary duplication) and a "bounded" § (permitting only polynomial duplication). This stratification yields a characterization of the polynomial-time computable functions: a function is computable in polynomial time if and only if it is representable in LLL. This is one of the most striking applications of proof theory to computational complexity, alongside bounded arithmetic and implicit computational complexity.

The stratification works as follows. In LLL, the rules for the modalities are restricted so that the depth of nested boxes cannot grow during cut elimination beyond a fixed bound. This bounds the time complexity of normalization to polynomial time. This result, by Baillot and Terui, ties proof theory directly to the P vs. NP question: if one could prove that a specific function (say, SAT) is not representable in LLL, one would have separated P from NP.

## 6. The Categorical Semantics of Linear Logic

Linear logic admits a rich categorical semantics in terms of _symmetric monoidal closed categories_ with additional structure. Specifically:

- A model of multiplicative linear logic (MLL) is a _-autonomous category_: a symmetric monoidal closed category with a dualizing object \(\bot\) such that the canonical map \(A \to (A \multimap \bot) \multimap \bot\) is an isomorphism.
- Additives correspond to finite products (\(\with\)) and coproducts (\(\oplus\)).
- Exponentials correspond to a _linear exponential comonad_: a comonad \(! : \mathcal{C} \to \mathcal{C}\) such that each \(!A\) is naturally a cocommutative comonoid.

The comonad structure of \(!\) captures the structural rules:

- **Dereliction:** \(!A \to A\) (use once).
- **Weakening:** \(!A \to \mathbf{1}\) (discard).
- **Contraction:** \(!A \to !A \otimes !A\) (duplicate).
- **Digging:** \(!A \to !!A\) (the exponential is idempotent).

The _co-Kleisli_ category of the comonad \(!\) is a cartesian closed category—this is exactly how intuitionistic logic is recovered: the Kleisli map \(!A \to B\) in the linear category corresponds to the implication \(A \to B\) in the cartesian closed category.

### 6.1 The Relational Model and Coherence Spaces

The simplest model of linear logic is the _relational model_ (or _multiset model_). Objects are sets, and a morphism from \(X\) to \(Y\) is a multiset of pairs—a relation where each pair can appear multiple times. The tensor product is the Cartesian product, and linear negation is a form of complement. This model has zero information about what the elements "are"; it only tracks multiplicities, which is exactly right for the resource-sensitive aspect of the logic.

Girard's original model of linear logic was _coherence spaces_ (or _coherent spaces_): a coherence space is a set \(X\) equipped with a reflexive, symmetric relation (the "coherence" relation), and morphisms are certain stable functions between them. Coherence spaces provide a model that is both denotational (compositional) and sensitive to the difference between deterministic and nondeterministic computation. This model was instrumental in the development of _stable domain theory_ and the semantics of PCF.

### 6.2 The Geometry of Interaction as a Categorical Construction

The Geometry of Interaction can be recast in categorical language as the _Int construction_ of Joyal, Street, and Verity (1996). Given a traced monoidal category \(\mathcal{C}\), the Int construction yields a compact closed category \(\mathrm{Int}(\mathcal{C})\) whose objects are pairs of objects of \(\mathcal{C}\) and whose morphisms are certain "feedback" constructions. The GoI interpretation of proofs corresponds exactly to this construction applied to a category of operators. This categorical perspective unifies GoI with other traced and compact closed structures appearing in knot theory, topological quantum field theory, and concurrency theory.

## 7. Linear Logic and Concurrency

Linear logic has become a foundational tool for reasoning about concurrent and distributed systems. The key observation is that the multiplicative conjunction \(\otimes\) models independent, parallel composition of processes, while \(\parr\) models communication or interaction.

### 7.1 The \(\pi\)-Calculus and Linear Logic

The \(\pi\)-calculus can be given a type system based on linear logic, where channel types are session types and the operational semantics of the \(\pi\)-calculus mirrors cut elimination in linear logic. A channel that is used to send an integer and then receive a boolean has the session type \(!\mathrm{Int} \otimes ?\mathrm{Bool} \otimes \mathbf{1}\) (or dually, \(?\mathrm{Int} \parr !\mathrm{Bool} \parr \bot\)). The duality of the session types corresponds exactly to linear negation.

### 7.2 Choreographic Programming and Multiparty Session Types

Extending the Curry-Howard correspondence for session types to multiple participants yields _multiparty session types_, which describe protocols involving several parties. A global type describes the choreography from a bird's-eye view, and projection yields local types for each participant. The consistency condition (that the projections compose to the global type) corresponds to cut elimination in a multi-conclusion linear logic.

## 8. Proof Search and Logic Programming

Linear logic has spawned an entire family of logic programming languages. Unlike Prolog (which is based on Horn clauses in intuitionistic logic), linear logic programming languages treat the context as a multiset of resources that are consumed as the program executes.

### 8.1 Lolli, Lygon, and Linear Prolog

Lolli (Hodas and Miller, 1994) extends hereditary Harrop formulas with linear implication. A Lolli program is a collection of linear clauses that can be consumed and produced during execution. This allows natural modeling of stateful computations: a vending machine that dispenses a candy and changes its state is modeled as a linear implication `coin ⊗ state_i ⊸ candy ⊗ state_{i+1}`.

Goal-directed proof search in linear logic is more complex than in intuitionistic logic because of the context-splitting problem: when proving \(A \otimes B\), the context must be split into two disjoint parts, one for \(A\) and one for \(B\). There may be exponentially many such splits, making naive proof search intractable. Resource management strategies (IO, I/O, etc.) address this by enforcing deterministic context management.

### 8.2 The Connection to Petri Nets

The multiplicative fragment of linear logic is equivalent to Petri net reachability. A Petri net state is a multiset of tokens (modeled as a tensor product of atomic formulas), and a transition is a linear implication \(A_1 \otimes \cdots \otimes A_n \multimap B_1 \otimes \cdots \otimes B_m\). Reachability in the Petri net corresponds to provability in linear logic: there is a path from the initial marking to the target marking if and only if the corresponding linear sequent is provable. This connection was established by Asperti and Busi and has practical applications in the verification of concurrent systems.

## 9. Focusing and Polarization in Linear Logic

A significant advance in the proof theory of linear logic was Andreoli's discovery of _focusing_ (1992). Focusing is a complete proof search strategy that drastically reduces the nondeterminism in the sequent calculus. The key observation is that the connectives of linear logic divide into two polarity classes:

- **Negative connectives:** \(\parr\), \(\with\), \(\bot\), \(\top\), \(?\), and \(\multimap\) (in its negative occurrence). Their introduction rules are _invertible_: the premises are uniquely determined by the conclusion. We can always apply these rules eagerly without risking backtracking.
- **Positive connectives:** \(\otimes\), \(\oplus\), \(\mathbf{1}\), \(\mathbf{0}\), \(!\). Their introduction rules are _non-invertible_: applying them requires a choice (how to split the context for \(\otimes\), which branch for \(\oplus\)) that may be wrong.

**Theorem 9.1 (Andreoli, 1992).** Any provable sequent in linear logic has a focused proof. In a focused proof, the proof alternates between _inversion phases_ (decomposing negative formulas eagerly) and _focusing phases_ (selecting a positive formula and decomposing it hereditarily until a negative subformula is reached, then switching back).

The focusing discipline reduces the proof search space from exponential to polynomial in many practical cases. It is the foundation of linear logic programming languages like Lolli and Lygon, where focusing corresponds to the operational semantics of goal-directed proof search. A focused proof is essentially a _deterministic computation_ embedded in a logic proof—the positive phases are the computational steps, the negative phases are the environment's responses.

### 9.1 Polarization and Evaluation Order

Polarization corresponds to _evaluation order_ in programming languages. Positive types are "eager" (call-by-value): their introduction requires the sub-formulas to be fully evaluated first. Negative types are "lazy" (call-by-name): their introduction can proceed without evaluating sub-formulas. The focusing discipline thus subsumes both call-by-value and call-by-name as special cases of a single logical framework.

In polarized linear logic, the \(!\) modality serves as a "thunk" that suspends a computation, converting a positive (eager) formula into a negative (lazy) one that can be duplicated. This is exactly the role of closures in call-by-value languages: a thunk \(\{\lambda x.M\}\) is a suspended computation that can be passed around and forced (derelicted) when needed.

## 10. Linear Logic and Optimal Reduction

A remarkable connection exists between linear logic proof nets and the _optimal reduction_ of the lambda calculus. Lévy (1980) defined the notion of optimal reduction: a strategy that minimizes the number of beta-reduction steps, avoiding the duplication of work caused by copying shared subterms. For decades, no algorithm was known to achieve optimal reduction—until Lamping (1990) invented a graph-rewriting algorithm based on a mysterious set of "sharing operators" (fans, brackets, and croissants).

Gonthier, Abadi, and Lévy (1992) showed that Lamping's algorithm is precisely the cut-elimination procedure for _proof nets_ of linear logic, where the sharing operators correspond to the nodes for contraction and dereliction of the \(!\) modality. Specifically:

- A "fan" node represents the _contraction_ rule: \(!A \to !A \otimes !A\). It duplicates a box.
- A "bracket" node represents the _dereliction_ rule: \(!A \to A\). It opens a box.
- A "croissant" (or "door") represents the boundary of a box.

The interaction rules of Lamping's algorithm—how fans propagate through other nodes—are exactly the cut-elimination steps for proof nets. This connection explained, for the first time, why Lamping's mysterious operators work: they are the proof-net realization of the exponential rules of linear logic.

**Theorem 10.1 (Gonthier et al., 1992).** Optimal reduction in the lambda calculus is simulated by cut elimination in the proof nets of linear logic. The number of Lamping-graph interaction steps corresponds exactly to the number of cut-elimination steps on the corresponding proof net.

This result has deep implications for both functional programming and proof theory. It means that the "right" way to reduce lambda terms—avoiding any duplication of work—is to first translate them into linear logic (via the Girard translation), build the proof net, and normalize it. The optimal lambda reducer is a proof-net normalizer. This is implemented in the _Bologna Optimal Higher-Order Machine_ (BOHM) and the _interaction abstract machine_ of Mackie and Pinto.

## 11. Focusing, Polarities, and Compiler Optimization

The focusing discipline has direct applications to compiler optimization. In a focused proof system for a linear type theory:

- Positive phases correspond to _known values_: the compiler has full information about the structure and can inline, specialize, and constant-fold.
- Negative phases correspond to _unknown contexts_: the compiler must generate code that works for any instantiation, leading to more generic (but potentially slower) code.

A compiler can use polarity information to decide where to inline (positive positions) and where to generate polymorphic dispatch (negative positions). This is the basis of _call-by-push-value_ (Levy, 2003), a type theory that makes the value/computation distinction explicit and has been used to structure optimizing compilers for functional languages.

In more detail, the polarized type system of call-by-push-value splits types into _value types_ (positive, denoted \(A^+\)) and _computation types_ (negative, denoted \(C^-\)). The key typing rules are:

```
Γ ⊢ V : A⁺                    (value introduction)
Γ ⊢ M : C⁻                   (computation introduction)
Γ ⊢ return V : F A⁺          (embed value into computation, where F is the "returner")
Γ, x : A⁺ ⊢ M : C⁻           (bind a value)
Γ ⊢ λx.M : A⁺ → C⁻           (function type, negative)
```

The \(F\) and \(U\) modalities mediate between the two worlds: \(F A^+\) is a computation that returns a value of type \(A^+\), and \(U C^-\) is a suspended computation that can be stored as a value. This is a clean, logically motivated alternative to the traditional call-by-value vs. call-by-name dichotomy, and compilers for languages like ML and Haskell can benefit from its clarity.

## 12. Recent Developments and Future Directions

Linear logic continues to influence new areas of computer science:

1. **Quantitative Type Theory:** The work of Atkey (2018) and McBride on _quantitative type theory_ (QTT) integrates linear, affine, relevant, and unrestricted types into a single system parameterized by a semiring of "usage annotations." This has been implemented in Idris 2.

2. **Graded Modal Types:** The _Granule_ language (Orchard et al.) extends linear types with "grades" that capture precise usage information (e.g., "used exactly 3 times") and security levels.

3. **Differentiable Programming:** Linear types are being used to ensure that gradients are computed exactly once in automatic differentiation systems, preventing memory leaks and ensuring correctness of backpropagation.

4. **Separation Logic:** The connection between linear logic and separation logic is deep: the separating conjunction \(\*\) is essentially the tensor \(\otimes\) in a specific model of linear logic where the "resources" are heap fragments. This explains why separation logic's frame rule works so well for local reasoning.

5. **Blockchain and Smart Contracts:** Linear logic's resource semantics maps naturally to the token-based economies of smart contracts. A transaction is a linear implication: consume some tokens, produce others. Linear logic provides a framework for reasoning about the correctness and resource safety of smart contract execution. Languages like Nomos and work by Ilya Sergey explore these connections.

6. **Quantum Programming:** The _no-cloning theorem_ in quantum mechanics—quantum states cannot be copied—is exactly the absence of the contraction rule. The _no-deletion theorem_—quantum information cannot be erased—is the absence of weakening. Thus quantum computation is inherently linear. The QPL language (Selinger, 2004) and the Quipper system (Green et al., 2013) use linear type systems to enforce these physical constraints at compile time, preventing programming errors that would violate the laws of quantum mechanics.

## 13. Summary

Linear logic is not merely an exotic logical system—it is the resource-sensitive core of computation. By decomposing intuitionistic implication into linear implication plus the exponential modality, Girard revealed that logic is fundamentally about the management of resources: some can be discarded, some duplicated, and some used exactly once. This perspective has enriched our understanding of type systems (Rust, Linear Haskell), concurrency (session types, choreographic programming), proof theory (proof nets, geometry of interaction), and complexity theory (light linear logic).

For the working programmer, the most immediate takeaway is this: when you annotate a Rust function with ownership and borrowing, when you use a linear type to ensure an array is mutated in place, or when you design a protocol with session types, you are doing applied linear logic. The proof nets that encode your program are being cut-eliminated by the runtime, and the resource semantics ensures that no data race, use-after-free, or protocol violation can slip through.

To go deeper, Girard's original 1987 paper "Linear Logic" (Theoretical Computer Science 50, pp. 1–102) remains a masterpiece. Troelstra's _Lectures on Linear Logic_ provides an accessible introduction to proof nets and the sequent calculus. Wadler's "A taste of linear logic" (1993) is a programmer-friendly summary, and the Rust Nomicon explains the ownership system in terms close to affine types. For the categorical perspective, Melliès' _Categorical Semantics of Linear Logic_ is comprehensive and insightful. And for the cutting edge, Ehrhard's work on differential linear logic opens the door to a principled understanding of automatic differentiation.
