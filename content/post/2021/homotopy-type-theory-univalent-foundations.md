---
title: "Homotopy Type Theory: The Univalence Axiom, Higher Inductive Types, and ∞-Groupoids"
description: "A deep dive into the univalent foundations of mathematics, where equality is homotopy, types are spaces, and the universe mirrors the ∞-groupoid of all ∞-groupoids."
date: "2021-08-11"
author: "Leonardo Benicio"
tags: ["homotopy-type-theory", "univalence", "type-theory", "homotopy", "infinity-groupoids", "martin-lof"]
categories: ["theory", "mathematics"]
draft: false
cover: "/static/images/blog/homotopy-type-theory-univalent-foundations.png"
coverAlt: "Diagram showing the correspondence between types, spaces, and ∞-groupoids in homotopy type theory"
---

In 2006, Vladimir Voevodsky gave a talk at Stanford that would change the foundations of mathematics. Having just solved the Milnor conjecture—a problem in motivic cohomology that had stood for thirty years—he turned his attention to a more fundamental question: what is the right logical foundation for computer-checked mathematics? His answer, developed in collaboration with Awodey, Warren, and others, was Homotopy Type Theory (HoTT). The central insight is audacious: the equality type of Martin-Löf Type Theory, when interpreted homotopically, encodes the full structure of an ∞-groupoid. Types are not just sets; they are spaces up to homotopy. And the universe of all types is itself an ∞-groupoid, reflecting the structure of the types it contains. This is the univalence axiom.

For the working computer scientist, HoTT offers more than philosophical satisfaction. Higher inductive types provide a native language for constructing quotient spaces, cell complexes, and even spectra directly within type theory. The univalence axiom implies that isomorphic structures are identical—a property that, in ordinary set theory, is flagrantly false (consider the sets \(\{a, b\}\) and \(\{c, d\}\); they are bijective but not equal as sets). In HoTT, the statement "isomorphic structures are equal" becomes a theorem, not a convention. This has profound consequences for how we structure mathematical libraries in proof assistants like Coq and Agda.

## 1. Martin-Löf Type Theory: The Point of Departure

Before we can understand HoTT, we must understand the intensional Martin-Löf Type Theory (MLTT) on which it is built. MLTT is a dependently typed λ-calculus with the following judgment forms:

\[
\Gamma \vdash A \; \text{type}, \quad \Gamma \vdash a : A, \quad \Gamma \vdash a \equiv b : A, \quad \Gamma \vdash A \equiv B \; \text{type}
\]

The key innovation of MLTT is the _identity type_: for any type \(A\) and elements \(a, b : A\), there is a type \(\mathrm{Id}\_A(a, b)\) (also written \(a =\_A b\)) whose elements are _witnesses_ that \(a\) equals \(b\). The introduction rule gives a reflexivity witness:

\[
\Gamma \vdash a : A \implies \Gamma \vdash \mathrm{refl}\_a : \mathrm{Id}\_A(a, a)
\]

The elimination rule is the _J-rule_ (based induction): given a family \(C(x, y, p)\) depending on \(x, y : A\) and \(p : \mathrm{Id}\_A(x, y)\), and given an element of \(C(x, x, \mathrm{refl}\_x)\) for all \(x\), we can construct an element of \(C(a, b, p)\) for any \(a, b, p\). Formally:

\[
\frac{\Gamma, x : A, y : A, p : \mathrm{Id}_A(x, y) \vdash C(x, y, p) \; \text{type} \quad
\Gamma, x : A \vdash d(x) : C(x, x, \mathrm{refl}\_x)}{
\Gamma \vdash J_{C,d}(a, b, p) : C(a, b, p)}
\]

The J-rule is the engine of equality reasoning in type theory. From it, we can derive symmetry, transitivity, and congruence of equality. But here is the crucial observation, first made clear by Hofmann and Streicher in their 1994 paper "The groupoid interpretation of type theory": the J-rule does _not_ imply that any two proofs of equality are equal. In fact, \(\mathrm{Id}\_{\mathrm{Id}\_A(a,b)}(p, q)\) can be nontrivial. The identity type has structure.

### 1.1 The Groupoid Interpretation

Hofmann and Streicher showed that every type \(A\) in MLTT can be interpreted as a groupoid: objects are the elements of \(A\), and morphisms from \(a\) to \(b\) are the elements of \(\mathrm{Id}\_A(a, b)\). Composition is given by transitivity of equality, identities by reflexivity, and inverses by symmetry. The J-rule implies that this structure is indeed groupoidal—every equality is an isomorphism.

But why stop at groupoids? If \(\mathrm{Id}_A(a, b)\) itself has the structure of a type, then \(\mathrm{Id}_{\mathrm{Id}\_A(a,b)}(p, q)\) should be interpreted as the set of 2-morphisms between the 1-morphisms \(p\) and \(q\). Iterating, we obtain an infinite tower of higher identity types, corresponding to an ∞-groupoid. This is the fundamental insight of HoTT.

### 1.2 The Difference Between Intensional and Extensional MLTT

In extensional MLTT, the reflection rule states that from \(p : \mathrm{Id}\_A(a, b)\) we may conclude \(a \equiv b\) in the definitional equality judgment. This collapses the identity type to a mere proposition—all proofs of equality are equal, and the type theory behaves like sets. The extensional version has undecidable type checking (you must decide equality of terms, which may require arbitrary proof search). The intensional version, which HoTT extends, keeps definitional equality decidable while allowing the propositional equality to be rich and higher-dimensional. This trade-off—decidable type checking with a rich equality structure—is one of the great practical virtues of intensional MLTT.

## 2. The Homotopy Interpretation

In classical homotopy theory, a _space_ (or more precisely, a Kan complex) is a simplicial set satisfying the Kan extension condition. The fundamental ∞-groupoid \(\Pi\_\infty(X)\) of a space \(X\) has:

- Objects: points of \(X\).
- 1-morphisms: paths between points.
- 2-morphisms: homotopies between paths.
- 3-morphisms: homotopies between homotopies.
- ... and so on.

The homotopy hypothesis, conjectured by Grothendieck, states that ∞-groupoids are equivalent to topological spaces up to weak homotopy equivalence. In HoTT, we take this as a design principle: types _are_ spaces (∞-groupoids), and their identity structure is exactly the path structure of the space.

### 2.1 The Interpretation at Work

Under the homotopy interpretation:

- A type \(A\) is a space.
- A term \(a : A\) is a point in that space.
- An identity \(p : a =\_A b\) is a path from \(a\) to \(b\).
- A higher identity \(q : p =\_{a =\_A b} r\) is a homotopy between the paths \(p\) and \(r\).
- The J-rule becomes the _path induction_ principle: to prove a property about arbitrary paths, it suffices to prove it for the constant path \(\mathrm{refl}\).

The J-rule, in homotopical language, says that the space of paths is _contractible_ when one endpoint is fixed. More precisely:

**Theorem 2.1 (Based Path Induction).** For any type \(A\) with a point \(a : A\), the type \(\sum\_{x : A} (a =\_A x)\) is contractible, with center of contraction \((a, \mathrm{refl}\_a)\).

_Proof._ This follows directly from the J-rule. Given \((x, p) : \sum\_{x : A} (a =\_A x)\), we use path induction on \(p\) (with the family \(C(x, p) := (a, \mathrm{refl}\_a) = (x, p)\)) to show equality. ∎

This theorem implies that the identity type, while potentially complex in its higher-dimensional structure, is still _inductively generated_ from the constant path. This is the foundation on which the rest of HoTT is built.

### 2.2 Transport and Dependent Maps

One of the most used operations in HoTT is _transport_: given a type family \(P : A \to \mathcal{U}\) and a path \(p : x =\_A y\), we can transport an element \(u : P(x)\) along \(p\) to obtain \(\mathrm{transport}^P(p, u) : P(y)\). Transport is defined by path induction on \(p\), sending \(\mathrm{refl}\) to the identity function.

Transport is the workhorse of HoTT. It generalizes the familiar operation of "rewriting along an equality" but is compatible with the higher-dimensional structure: transporting along a path that is itself the concatenation of two paths is the same as transporting twice. This coherence is automatic from the J-rule.

### 2.3 Equational Reasoning in HoTT

Concatenation of paths \(p : x = y\) and \(q : y = z\) is denoted \(p \ct q : x = z\) (defined by induction on \(p\)). Symmetry gives \(p^{-1} : y = x\). These satisfy the groupoid laws up to higher paths:

\[
\mathrm{refl} \ct p = p, \quad p \ct \mathrm{refl} = p, \quad p \ct p^{-1} = \mathrm{refl}, \quad (p \ct q) \ct r = p \ct (q \ct r)
\]

These are proven as higher identity types—they are not definitional equalities but propositional ones, requiring path induction. This introduces a certain overhead in equational reasoning, which proof assistants mitigate with tactics that automate the application of these laws.

## 3. The Univalence Axiom

The univalence axiom, due to Voevodsky, is the statement that the universe \(\mathcal{U}\) of all (small) types is itself an ∞-groupoid, and its identity structure reflects equivalences between types. More precisely, there is a canonical map:

\[
\mathrm{idtoequiv}_{A,B} : (A =_{\mathcal{U}} B) \to (A \simeq B)
\]

sending \(\mathrm{refl}\_A\) to the identity equivalence on \(A\). The univalence axiom asserts that this map is itself an equivalence. In symbols:

\[
(A =\_{\mathcal{U}} B) \simeq (A \simeq B)
\]

This is a statement about the universe: identity of types is equivalent to equivalence of types. Two types that are isomorphic (in the sense of a homotopy equivalence, or more precisely a quasi-invertible map) are _identical_ as elements of the universe.

### 3.1 Equivalences, Formally

What does it mean for two types to be equivalent? In HoTT, several equivalent definitions coexist. The most convenient is Voevodsky's notion of _bi-invertible maps_:

**Definition 3.1.** A function \(f : A \to B\) is an _equivalence_ if there exist \(g : B \to A\) and \(h : B \to A\) such that \(g \circ f \sim \mathrm{id}\_A\) and \(f \circ h \sim \mathrm{id}\_B\), where \(\sim\) denotes pointwise equality. The type of equivalences is:

\[
\mathrm{isEquiv}(f) := \left(\sum*{g : B \to A} g \circ f \sim \mathrm{id}\_A\right) \times \left(\sum*{h : B \to A} f \circ h \sim \mathrm{id}\_B\right)
\]

And \(A \simeq B\) is defined as \(\sum\_{f : A \to B} \mathrm{isEquiv}(f)\).

Alternatively, a function is an equivalence if it has a two-sided inverse up to homotopy (a _quasi-inverse_), or if its fibers \(\sum\_{a : A} f(a) = b\) are contractible for all \(b : B\). These definitions are all equivalent—but the proof of their equivalence requires careful handling of the higher identity types that arise. This was one of the early technical triumphs of HoTT: showing that the various notions of equivalence coincide.

### 3.2 Consequences of Univalence

The univalence axiom has far-reaching consequences:

1. **Isomorphic structures are equal:** If two groups (or rings, or topological spaces, or any structured type) are isomorphic, then they are equal as elements of the type of groups. This eliminates the need for "transport along isomorphisms" that plagues set-theoretic formalizations of mathematics.

2. **Function extensionality:** Univalence implies function extensionality—the principle that two functions are equal if they are pointwise equal. This is derived, not assumed.

3. **Quotient types become unnecessary:** Many uses of quotient types can be replaced by using the univalence axiom to identify equivalent representations.

4. **The structure identity principle:** For a large class of mathematical structures (those definable as "standard" structures), the identity type of the structure type is equivalent to the type of isomorphisms of that structure.

**Theorem 3.2 (Structure Identity Principle).** Let \(S\) be a type of structures defined as a dependent sum \(\sum\_{X : \mathcal{U}} P(X)\). Under mild conditions, \((X, p) =\_S (Y, q)\) is equivalent to the type of isomorphisms between \((X, p)\) and \((Y, q)\).

### 3.3 Univalence in Action: Isomorphic Groups are Equal

Let us see univalence at work. Define the type of groups as:

\[
\mathrm{Group} := \sum*{G : \mathcal{U}} \sum*{\cdot : G \times G \to G} \sum*{e : G} \sum*{(\cdot)^{-1} : G \to G} \text{(group axioms)}
\]

Given two groups \(G\) and \(H\), a group isomorphism is a bijection \(f : G \to H\) that preserves the group operations. By the structure identity principle (a consequence of univalence), the identity type \(G =\_{\mathrm{Group}} H\) is equivalent to the type of group isomorphisms between \(G\) and \(H\). This means that in HoTT, isomorphic groups are _literally_ equal—we can substitute one for the other in any context without explicit coercion. This dramatically simplifies the formalization of algebra in proof assistants.

## 4. Higher Inductive Types

Higher inductive types (HITs) are the second major innovation of HoTT, complementing univalence. While ordinary inductive types (like \(\mathbb{N}\), lists, and trees) generate _points_, HITs can also generate _paths_ and higher cells. This allows us to construct spaces directly in type theory, including spheres, tori, cell complexes, and even Eilenberg-MacLane spaces.

### 4.1 The Circle as a HIT

The simplest nontrivial HIT is the circle \(\mathbb{S}^1\), defined by:

```
data S1 : Type where
    base : S1
    loop : base = base
```

The elimination rule (recursion principle) for the circle: to define a function \(f : \mathbb{S}^1 \to A\), we must provide:

- A point \(b : A\) (the image of `base`).
- A path \(\ell : b =\_A b\) (the image of `loop`).

Moreover, the _dependent_ elimination principle (induction) requires that when the motive is a dependent type family \(P : \mathbb{S}^1 \to \mathcal{U}\), the path corresponding to `loop` must lie in the fiber \(P(\mathrm{loop})\) via transport: we need a path \(\ell' : \mathrm{transport}^P(\mathrm{loop}, b) = b\). This illustrates the general principle: HIT induction is path induction on steroids—you must specify not just the behavior on points but on all the higher cells.

### 4.2 The Suspension and Spheres

The _suspension_ of a type \(A\) is the HIT:

```
data Susp (A : Type) : Type where
    N : Susp A
    S : Susp A
    merid : A -> N = S
```

Topologically, \(\Sigma A\) is the suspension of the space \(A\). The \(n\)-sphere \(\mathbb{S}^n\) can be constructed by iterating the suspension: \(\mathbb{S}^0 := \mathbf{2}\) (the type of booleans), \(\mathbb{S}^{n+1} := \Sigma(\mathbb{S}^n)\).

**Proposition 4.1.** \(\pi_1(\mathbb{S}^1) \cong \mathbb{Z}\).

_Proof (sketch)._ The universal cover of \(\mathbb{S}^1\) can be constructed as a HIT or using the definition of the integers. The fundamental group is the type of loops `base = base` modulo homotopy, which is equivalent to \(\mathbb{Z}\) via the winding number map. ∎

### 4.3 Homotopy Groups in HoTT

In classical homotopy theory, the \(n\)-th homotopy group \(\pi_n(X, x_0)\) is defined as the set of homotopy classes of maps \(\mathbb{S}^n \to X\). In HoTT, we can define it directly using the identity type structure. For a pointed type \((X, x_0)\), we define:

\[
\Omega(X, x*0) := (x_0 =\_X x_0), \quad \Omega^{n+1}(X, x_0) := \Omega(\Omega^n(X, x_0), \mathrm{refl}*{\cdots})
\]

The \(0\)-th homotopy set is \(\pi_0(X) := \|X\|\_0\), the set-truncation of \(X\) (a HIT that collapses all paths). For \(n \geq 1\):

\[
\pi_n(X, x_0) := \|\Omega^n(X, x_0)\|\_0
\]

The set-truncation ensures that the homotopy groups are sets (0-truncated types), corresponding to the classical fact that \(\pi_n\) is a group (or abelian group for \(n \geq 2\)).

**Theorem 4.2.** \(\pi_n(\mathbb{S}^n) \cong \mathbb{Z}\) for all \(n \geq 1\).

The proof of this fundamental theorem in HoTT is a major achievement, requiring the development of spectral sequences, the Freudenthal suspension theorem, and the Blakers-Massey theorem—all within type theory.

### 4.4 The Interval, Truncations, and Quotients

The _interval_ \(I\) is a HIT with two points and a path between them:

```
data Interval : Type where
    zero : Interval
    one  : Interval
    seg  : zero = one
```

The interval is contractible (it has a trivial homotopy type), but it is _not_ a mere proposition—it has distinct points connected by a path. This makes it useful for defining homotopies. A homotopy between functions \(f, g : A \to B\) is simply a function \(h : A \times I \to B\) that restricts to \(f\) at `zero` and \(g\) at `one`, or equivalently (by the universal property of the interval) a family of paths \(h : \prod\_{x:A} f(x) = g(x)\).

The _propositional truncation_ \(\|A\|\_{-1}\) is a HIT that collapses all elements of \(A\) to a single point, while adding a path between any two points:

```
data ∥A∥ : Type where
    ∣_∣ : A -> ∥A∥
    squash : forall (x y : ∥A∥) -> x = y
```

This forces \(\|A\|\_{-1}\) to be a _mere proposition_: a type with at most one element up to homotopy. Iterating, we get the set-truncation \(\|A\|\_0\) (add paths between all paths), the 1-truncation \(\|A\|\_1\), and so on. The general \(k\)-truncation \(\|A\|\_k\) is a HIT that adds higher-dimensional cells to collapse all structure above level \(k\), producing a \(k\)-type.

### 4.5 Pushouts and Colimits

The _pushout_ of two maps \(f : A \to B\) and \(g : A \to C\) is a HIT:

```
data Pushout (f : A -> B) (g : A -> C) : Type where
    inl : B -> Pushout f g
    inr : C -> Pushout f g
    glue : forall (a : A) -> inl (f a) = inr (g a)
```

Pushouts are the key to constructing spaces by attaching cells. The torus \(\mathbb{T}^2\) is the pushout of two inclusions of the circle into a disk. More generally, any CW complex can be built using iterated pushouts and suspensions. The _join_ \(A \* B\) (the HIT with points from \(A\), \(B\), and paths connecting them) is another fundamental HIT that plays a central role in the proof of the Freudenthal suspension theorem.

### 4.6 The Cauchy Reals and the Dedekind Reals as HITs

Even the real numbers can be approached via HITs. The _Cauchy reals_ \(\mathbb{R}\_c\) are constructed as the set-quotient of Cauchy sequences of rational numbers, which is a HIT. The _Dedekind reals_ \(\mathbb{R}\_d\) are defined as Dedekind cuts, which also require quotienting. In HoTT, these two constructions are not automatically equivalent—they are equivalent if we assume countable choice, but this is a subtle point that illustrates how HoTT brings constructive distinctions to the foreground.

## 5. ∞-Groupoids and the Univalent Foundations

We are now ready to state the central correspondence of HoTT with precision. The universe \(\mathcal{U}\) is an ∞-groupoid, and every type \(A : \mathcal{U}\) is an ∞-groupoid. The identity type \(a =\_A b\) is the hom-∞-groupoid of morphisms, and the iterated identity types encode the higher categorical structure.

### 5.1 The Hierarchy of h-Levels

Voevodsky introduced the notion of _h-level_ (homotopy level) to classify types by their homotopical complexity:

- **h-level -2:** A type \(A\) is _contractible_ if \(\sum*{a : A} \prod*{x : A} (a = x)\). There is exactly one contractible type up to equivalence.
- **h-level -1:** A type \(A\) is a _mere proposition_ if \(\prod\_{x, y : A} (x = y)\). Mere propositions are types with at most one element—they correspond to propositions in logic.
- **h-level 0:** A type \(A\) is a _set_ if \(\prod*{x, y : A} \prod*{p, q : x = y} (p = q)\). Sets are types whose identity types are mere propositions. They correspond to sets in classical mathematics.
- **h-level 1:** A type \(A\) is a _1-type_ (or groupoid) if its identity types are sets.
- **h-level \(n\):** Inductively, an \(n\)-type has identity types that are \((n-1)\)-types.

This hierarchy is cumulative: a mere proposition is a set, a set is a 1-type, and so on. The universe \(\mathcal{U}\) does not belong to any finite h-level—it is an ∞-groupoid.

**Lemma 5.1 (Universe is not a set).** The universe \(\mathcal{U}\) is not a 0-type (a set). In particular, \(\mathbf{2} \neq\_{\mathcal{U}} \mathbf{2}\) is not a mere proposition because there are two distinct automorphisms of \(\mathbf{2}\): the identity and the swap. By univalence, these give two distinct paths \(\mathbf{2} = \mathbf{2}\).

### 5.2 The Univalent Universe as an ∞-Groupoid

The univalence axiom characterizes the identity structure of the universe. For any two types \(A, B : \mathcal{U}\),

\[
(A =\_{\mathcal{U}} B) \simeq (A \simeq B)
\]

Now, \(A \simeq B\) is itself a type (the type of equivalences). This means the hom-∞-groupoid of the universe between \(A\) and \(B\) is equivalent to the ∞-groupoid of equivalences between \(A\) and \(B\). The n-cells in \((A =\_{\mathcal{U}} B)\) correspond to higher homotopies between equivalences.

This is exactly the structure that makes \(\mathcal{U}\) the "∞-groupoid of all ∞-groupoids" (modulo size issues). Univalence is the type-theoretic incarnation of the fact that the collection of ∞-groupoids is itself an ∞-groupoid, with the correct equivalences.

### 5.3 The Univalence Axiom vs. the Univalence Computation Rule

One limitation of the current formulation of HoTT is that univalence is an _axiom_, not a computation rule. This means that proofs using univalence do not automatically compute—they get "stuck" on the univalence axiom. This is a problem for applications that require executable programs extracted from proofs.

The _cubical type theory_ approach, pioneered by Bezem, Coquand, and Huber (2014), addresses this by giving univalence a computational interpretation. In cubical type theory, the identity type is replaced by a _path type_ equipped with an interval variable, and univalence becomes a theorem (with a computational reduction rule) rather than an axiom. Cubical Agda is an implementation of this idea that enables direct computation with univalence.

### 5.4 Cubical Type Theory in Depth

In cubical type theory, the judgmental structure is enriched with an _interval_ object \(\mathbb{I}\). A path from \(a\) to \(b\) in type \(A\) is a function \(p : \mathbb{I} \to A\) with \(p(0) = a\) and \(p(1) = b\) (where \(0, 1 : \mathbb{I}\) are the two endpoints). This is markedly different from MLTT's identity type—it is a _function_ type, not an inductive family. The Kan composition operation provides the "filling" of open boxes, which is the cubical analogue of the Kan condition in simplicial sets. Kan composition is what makes the path type behave like a proper equality type, supporting transport and the elimination principle.

The key result is that univalence is _provable_ in cubical type theory, and moreover the proof is computational—it reduces. The term `ua(e)` (univalence applied to an equivalence \(e : A \simeq B\)) reduces to a path obtained by "gluing" \(A\) and \(B\) along \(e\), using a generalization of the glue construction from Cohen, Coquand, Huber, and Mörtberg (2018). Specifically:

```
Glue : (phi : 𝔽) -> (T : Partial phi Type) -> (e : PartialP phi (λ o -> T o ≃ A)) -> Type
```

where \(\mathbb{F}\) is the "face lattice" of constraints on the interval, and `Partial` represents partial elements defined only when a given face constraint holds. The Glue type is the computational heart of univalence—it expresses that a type can be "reconstructed" from its partial views and the equivalences that relate them.

The computational interpretation of univalence has been implemented in Cubical Agda (an extension of Agda with cubical primitives) and in the Arend proof assistant. It is also the foundation for the `RedPRL` and `cooltt` experimental proof assistants.

## 6. Synthetic Homotopy Theory

HoTT enables a _synthetic_ approach to homotopy theory, in contrast to the classical _analytic_ approach using topological spaces or simplicial sets. In synthetic homotopy theory, we work directly within the type theory, constructing spaces via HITs and reasoning about them using the identity type.

### 6.1 The Freudenthal Suspension Theorem

**Theorem 6.1 (Freudenthal).** For an \(n\)-connected pointed type \(X\), the suspension map \(\Sigma : \pi*k(X) \to \pi*{k+1}(\Sigma X)\) is an isomorphism for \(k < 2n\). More precisely, the canonical map \(X \to \Omega\Sigma X\) is \((2n)\)-connected.

In HoTT, this theorem is proved by a clever argument using the _join_ construction and the _Blakers-Massey theorem_, which itself is proved using the encode-decode method—a technique for characterizing the identity types of HITs by constructing an explicit equivalence between paths and some data type.

### 6.2 The Blakers-Massey Theorem

**Theorem 6.2 (Blakers-Massey).** Given a pushout square:

```
    f
  A ----> B
  |        |
 g|        | inr
  |        |
  v  inl   v
  C ----> D
```

If \(f\) is \(m\)-connected and \(g\) is \(n\)-connected, then the gap map \(A \to B \times_D C\) is \((m+n)\)-connected.

In HoTT, this is proved using the _wedge connectivity lemma_ and clever manipulations of the identity types of pushouts. The proof is constructive and entirely synthetic—it operates directly on the HIT defining the pushout.

### 6.3 \(\pi_n(\mathbb{S}^n)\) in HoTT

The computation of \(\pi_n(\mathbb{S}^n) \cong \mathbb{Z}\) was a major milestone for HoTT. The proof, due to Brunerie and Ljungström, uses the Freudenthal suspension theorem to reduce to \(\pi_1(\mathbb{S}^1)\), which is computed using the encode-decode method on the circle.

For the circle, the encode-decode method goes as follows:

- Define a type family \(\mathrm{Code} : \mathbb{S}^1 \to \mathcal{U}\) by recursion: \(\mathrm{Code}(\mathrm{base}) := \mathbb{Z}\), \(\mathrm{Code}(\mathrm{loop}) := \mathrm{ua}(\mathrm{succ})\), where \(\mathrm{succ} : \mathbb{Z} \to \mathbb{Z}\) is the successor equivalence and \(\mathrm{ua}\) is the univalence axiom.
- Define functions \(\mathrm{encode} : \prod*{x : \mathbb{S}^1} (\mathrm{base} = x) \to \mathrm{Code}(x)\) and \(\mathrm{decode} : \prod*{x : \mathbb{S}^1} \mathrm{Code}(x) \to (\mathrm{base} = x)\).
- Prove that encode and decode are inverse equivalences.

This yields \((\mathrm{base} = \mathrm{base}) \simeq \mathrm{Code}(\mathrm{base}) \simeq \mathbb{Z}\), establishing \(\pi_1(\mathbb{S}^1) \cong \mathbb{Z}\).

### 6.4 The Hopf Fibration in HoTT

The Hopf fibration is the map \(\mathbb{S}^3 \to \mathbb{S}^2\) whose fibers are \(\mathbb{S}^1\). In HoTT, this is constructed using the fact that \(\mathbb{S}^1\) acts on itself and that \(\mathbb{S}^3\) is the join \(\mathbb{S}^1 \* \mathbb{S}^1\). The construction is elegantly expressed using HITs and the univalence axiom, and the proof that the fibers are equivalent to \(\mathbb{S}^1\) uses the encode-decode method on a suitable family over \(\mathbb{S}^2\). This was formalized by Buchholtz and Rijke (2017), demonstrating that nontrivial classical results in homotopy theory can be given constructive proofs in HoTT.

## 7. The Logic of HoTT: Propositions as Some Types

In classical type theory, the "propositions as types" correspondence identifies propositions with types: a proposition \(P\) is true if the type \(P\) is inhabited. In HoTT, this identification is refined: not all types are propositions. A type \(A\) is a _mere proposition_ if it has h-level -1: any two inhabitants are equal.

This refinement is crucial. In a proof assistant, the statement "all proofs of \(P\) are equal" is often desirable—it means that we can treat \(P\) as a classical proposition, where the specific witness does not matter. HoTT provides the propositional truncation \(\|A\|\) to turn any type into a mere proposition, enabling the best of both worlds: the rich structure of identity types when we need it, and the simplicity of propositional reasoning when we don't.

### 7.1 The Propositional Resizing Axiom

One technical issue is that the universe \(\mathcal{U}\) is _not_ a set—it is an ∞-groupoid. This means that the type of propositions \(\Omega := \sum*{P : \mathcal{U}} \mathrm{isProp}(P)\) (where \(\mathrm{isProp}(P) := \prod*{x,y:P} x = y\)) is a 1-type, not a set. If we want an impredicative universe of propositions (as in the Calculus of Inductive Constructions), we need to add a _propositional resizing_ axiom, which collapses the hierarchy of propositional universes.

### 7.2 The Axiom of Choice in HoTT

The axiom of choice takes a surprising form in HoTT. The type-theoretic axiom of choice:

\[
\prod*{X : \mathcal{U}} \prod*{Y : X \to \mathcal{U}} \left(\prod*{x : X} \|Y(x)\|\right) \to \left\|\prod*{x : X} Y(x)\right\|
\]

is actually a _theorem_ in HoTT (it follows from the definition of propositional truncation and the identity type). However, the _classical_ axiom of choice, which asserts the existence of a choice function without truncation, is not provable and is equivalent (via Diaconescu's theorem) to the law of excluded middle, which is not assumed in HoTT.

### 7.3 The Law of Excluded Middle and Univalence

The law of excluded middle (LEM), \(\prod\_{P : \mathcal{U}} \|P + \neg P\|\), is independent of HoTT—it is neither provable nor refutable. Adding LEM as an axiom is consistent with univalence. However, if one adds a "strong" form of LEM (without the truncation), then by Diaconescu's theorem, all types become sets, collapsing the higher-dimensional structure that HoTT was designed to capture. This tension between classical logic and the homotopy interpretation is fundamental: univalence is inherently constructive at the level of the universe, even if the logic of propositions is classical.

## 8. Set Theory vs. HoTT: A Philosophical Interlude

The univalent foundations represent a shift in the ontology of mathematics. In set theory, the fundamental notion is membership: everything is a set, and sets are characterized by their elements. In HoTT, the fundamental notion is _structure_: types are characterized by their identity types and universal properties. Two types can be equivalent without being equal as sets—but univalence says they _are_ equal as types in the universe.

This shift has practical consequences for formalization. In set theory, transporting a proof along an isomorphism is a tedious, error-prone process involving explicit rewriting. In HoTT, univalence makes it automatic: once you prove two structures are equivalent, you may treat them as identical. This is not just convenient—it reflects mathematical practice, where mathematicians routinely identify isomorphic structures without a second thought.

### 8.1 Canonicity and Computation

A major open problem in HoTT is _canonicity_: every natural number term should reduce to a numeral. In MLTT without axioms, canonicity holds. But the univalence axiom, as an axiom, breaks canonicity—a term built using univalence may not compute. Cubical type theory restores canonicity by giving univalence a computational interpretation.

The latest developments in this direction include _higher observational type theory_ (Altenkirch et al.) and _cartesian cubical type theory_ (Angiuli et al.), both of which aim to provide a fully computational foundation for univalent mathematics.

## 9. Applications and Current Research

HoTT is not just a theoretical curiosity. It has been used to formalize significant portions of mathematics:

1. **Homotopy theory:** The \(\pi_n(\mathbb{S}^n)\) proof in HoTT is a landmark. Work is underway on the \(\pi_4(\mathbb{S}^3)\) computation (due to Brunerie) and on spectral sequences in HoTT.

2. **Category theory in HoTT:** The univalent foundations provide a natural setting for category theory, where the notion of "category" is a 1-type and the notion of "univalent category" (where isomorphism is equivalent to identity) is a key concept. Ahrens, Kapulkin, and Shulman (2015) developed a comprehensive library of category theory in HoTT.

3. **Synthetic topology and domain theory:** The work of Escardó and others on compactness, overtness, and searchable types reveals deep connections between topology and computation.

4. **Homotopy canonicity:** The computational interpretation of univalence via cubical methods opens the door to executable univalent proofs—a Holy Grail of the field.

5. **Directed homotopy type theory:** A current frontier is the development of _directed_ type theory, where the identity type is replaced by a _directed_ hom-type, capturing the structure of \((\infty, 1)\)-categories rather than \(\infty\)-groupoids. This would provide a synthetic foundation for higher category theory itself. Riehl and Shulman (2017) proposed a type theory for synthetic \((\infty, 1)\)-categories based on a "simplicial" shape modality.

## 10. Summary

Homotopy Type Theory represents a profound synthesis of three streams of thought: Martin-Löf's type theory (with its constructive, proof-relevant equality), homotopy theory (with its infinite-dimensional groupoid structure), and higher category theory (with its systematic treatment of composition up to coherent homotopy). The univalence axiom is the keystone that locks these perspectives together, asserting that the universe of types mirrors the universe of ∞-groupoids.

For the working computer scientist, HoTT offers a principled framework for reasoning about equality in all its higher-dimensional glory. For the working mathematician, it offers a foundation where the informal practice of identifying isomorphic structures is formally justified. And for the philosopher, it offers a new vision of what mathematics could be: not a science of membership, but a science of structure and equivalence.

If you want to dive deeper, the canonical text is the _Homotopy Type Theory: Univalent Foundations of Mathematics_ book, freely available online and written collaboratively by contributors to the IAS Special Year on Univalent Foundations. For the cubical perspective, the Cubical Agda documentation and the papers by Coquand, Huber, and Mörtberg are essential reading. And for the philosophical implications, David Corfield's _Modal Homotopy Type Theory_ and Steve Awodey's papers on structuralism provide fascinating perspectives.

The journey from `refl` to univalence is long, but the view from the top—where equality is homotopy, types are spaces, and mathematics is structural all the way down—is genuinely transformative.
