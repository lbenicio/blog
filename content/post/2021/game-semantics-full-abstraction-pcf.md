---
title: "Game Semantics: Fully Abstract Models of PCF, AJM Games, and Strategies as Sheaves"
description: "A rigorous exploration of game semantics—the technique that cracked the full abstraction problem for PCF by modeling computation as dialogue between Player and Opponent."
date: "2021-09-30"
author: "Leonardo Benicio"
tags: ["game-semantics", "pcf", "full-abstraction", "denotational-semantics", "ajm-games", "programming-language-theory"]
categories: ["theory", "mathematics"]
draft: false
cover: "static/images/blog/game-semantics-full-abstraction-pcf.png"
coverAlt: "Diagram showing a game semantic strategy as a tree of moves between Player and Opponent"
---

For over fifteen years, the full abstraction problem for PCF was the white whale of theoretical computer science. PCF (Programming Computable Functions) is a tiny, idealized functional language with natural numbers, recursion, and higher-order functions. Plotkin showed in 1977 that the standard Scott model of PCF—domain-theoretic, based on continuous lattices—was not fully abstract. There were programs that were observationally equivalent (indistinguishable in all program contexts) but denoted by different elements of the model. The search for a fully abstract model—one where observational equivalence coincides with denotational equality—consumed some of the best minds in semantics. Milner constructed a fully abstract model by quotienting the syntax (1977). Berry proposed stable domain theory (1978). But the "intrinsic" model—one that was not built from the syntax itself—remained elusive.

Until the 1990s, when Abramsky, Jagadeesan, and Malacaria (AJM) and, independently, Hyland and Ong (HO) solved the problem using game semantics. Their insight was radical: a program is a strategy in a two-player game. The game is played between Player (the program) and Opponent (the environment, or the program context). The moves represent interactions: calling a function, returning a value, querying an argument. The fully abstract model of PCF is precisely the category of games and strategies, with appropriate conditions (innocence, well-bracketing, history-freeness). This post unpacks this remarkable story—from the problem to the solution, with all the categorical and game-theoretic machinery in between.

## 1. PCF and the Full Abstraction Problem

PCF is the simply-typed lambda calculus extended with natural numbers, basic arithmetic, and a fixed-point combinator \(Y\_\sigma : (\sigma \to \sigma) \to \sigma\) for each type \(\sigma\). Its syntax is minimal:

\[
\begin{aligned}
M, N &::= x \mid \lambda x^\sigma.M \mid M N \mid n \mid \mathrm{succ} \mid \mathrm{pred} \mid \mathrm{ifzero} \mid Y\_\sigma
\end{aligned}
\]

The types are \(\sigma ::= \iota \mid \sigma \to \tau\) where \(\iota\) is the type of natural numbers. The operational semantics is call-by-name, given by a reduction relation \(M \Downarrow n\).

Two programs \(M, N : \sigma\) are _observationally equivalent_, written \(M \equiv\_{\mathrm{obs}} N\), if for all program contexts \(C[\,] : \sigma \to \iota\) (a term with a hole of type \(\sigma\) that yields a natural number), we have \(C[M] \Downarrow n \iff C[N] \Downarrow n\). This is the gold standard for semantic equivalence: programs are equivalent if no context can tell them apart. The universal quantifier over all contexts is what makes observational equivalence so powerful—and so difficult to capture in a denotational model.

### 1.1 The Scott Model

The standard denotational model of PCF interprets types as domains:

\[
\begin{aligned}
[\![\iota]\!] &= \mathbb{N}\_\bot \quad \text{(flat domain of natural numbers plus bottom)} \\
[\![\sigma \to \tau]\!] &= [\![\sigma]\!] \to_c [\![\tau]\!] \quad \text{(continuous functions)}
\end{aligned}
\]

Terms are interpreted by induction. The fixed-point combinator is interpreted by the least fixed-point operator \(\mathrm{fix}(f) = \bigsqcup*{n \geq 0} f^n(\bot)\). This model is *sound* (if \([\![M]\!] = [\![N]\!]\) then \(M \equiv*{\mathrm{obs}} N\)) and _computationally adequate_ (if \(M\) reduces to \(n\) then \([\![M]\!] = n\)), but it is _not_ fully abstract.

**Counterexample (Plotkin, 1977).** Consider the _parallel-or_ function \(\mathrm{por} : \mathbb{B}_\bot \times \mathbb{B}_\bot \to \mathbb{B}\_\bot\) defined by:

\[
\mathrm{por}(\bot, \mathrm{true}) = \mathrm{true}, \quad \mathrm{por}(\mathrm{true}, \bot) = \mathrm{true}, \quad \mathrm{por}(\mathrm{false}, \mathrm{false}) = \mathrm{false}
\]

This function is continuous (monotone and preserves directed suprema) but is not definable in PCF. The Scott model contains \(\mathrm{por}\) and other "parallel" elements that PCF cannot express. Thus, there are distinct elements of the model that are observationally equivalent—the model distinguishes too many things. More subtly, there are also _finitary_ functions in the Scott model that are not sequentially definable, such as the "gustave" function discovered by Berry, which requires inspecting three arguments "in parallel" to determine the result.

### 1.2 The Sequentiality Problem

The full abstraction problem for PCF is intimately tied to the _sequentiality_ problem: which first-order functions are definable in PCF? The answer, provided by Milner and later refined by Vuillemin, is the _sequentially computable_ functions, characterized by the _Kahn-Plotkin sequentiality index_. A function \(f : \mathbb{N}_\bot^k \to \mathbb{N}_\bot\) is sequential if, for every argument tuple where \(f\) returns a defined value, there exists a sequential algorithm (a decision tree) that can determine the result by querying arguments one at a time in some order. PCF can only compute sequential functions, but the Scott model contains non-sequential continuous functions. The game semantics elegantly captures this sequentiality condition through the innocence constraint.

## 2. Game Semantics: The AJM Model

The key idea of game semantics is to interpret a type as a _game_ between Player (P) and Opponent (O). A program of type \(\sigma\) is a _strategy_ for P in the game \(\sigma\): a rule telling P what move to make, given the history of the game so far. This interactive, dialogue-based view of computation is fundamentally different from the input-output function view that dominated denotational semantics for decades.

### 2.1 Arenas and Games

An _arena_ \(A\) is a set of _moves_ partitioned into Player moves (\(P*A\)) and Opponent moves (\(O_A\)), equipped with an \_enabling relation* \(\vdash*A\) that determines which moves can legally be played when. A \_game* is an arena with additional structure specifying which player starts.

For flat types, the arena is trivial:

```
Arena for ι (natural numbers):
    O: q (question: "what is the number?")
    P: n (answer: the number n)
    Enabling: q ⊢ n for all n
```

The game always starts with Opponent asking a question (the environment initiates computation), and Player responds. For function types:

```
Arena for σ → τ:
    O: initial move in τ (Opponent asks about the result)
    P: initial move in σ (Player asks about the argument)
    O: response in σ (Opponent answers the argument query)
    P: response in τ (Player answers the original result query)
```

The back-and-forth models the call-and-return structure of functional computation. A function is evaluated by the environment asking for its result (O moves in \(\tau\)), the function asking about its argument (P moves in \(\sigma\)), and so on. This nesting of question-answer pairs creates a tree-like structure of interactions.

### 2.2 Legal Plays and Views

A _legal play_ in an arena is an alternating sequence of O and P moves (starting with O) such that every move is enabled by some previous move and the enabling relation is respected. The _P-view_ of a play \(s\), denoted \(\ulcorner s \urcorner\), is defined by induction:

- \(\ulcorner \epsilon \urcorner = \epsilon\)
- \(\ulcorner s \cdot o \urcorner = \ulcorner s \urcorner \cdot o\) if \(o\) is an O-move
- \(\ulcorner s \cdot p \urcorner = \ulcorner s' \urcorner \cdot p\) where \(s'\) is the prefix of \(s\) up to the move that enables \(p\)

The P-view "forgets" O-moves that are not directly relevant to the current interaction, preserving only the _hereditary justification chain_. This is the technical heart of innocence.

### 2.3 Strategies

A _strategy_ \(\sigma\) for P in a game \(A\) is a nonempty, prefix-closed set of _even-length_ plays (sequences of moves obeying the enabling relation, alternating between O and P, starting with O) satisfying:

1. **Determinism:** If \(s\) is a play in \(\sigma\) and O can play \(m\) after \(s\), then there is at most one P move \(n\) such that \(s \cdot m \cdot n \in \sigma\).
2. **Innocence:** If \(s \cdot m \cdot n \in \sigma\) and \(t\) is another play in \(\sigma\) with the same P-view as \(s\) (that is, \(\ulcorner s \urcorner = \ulcorner t \urcorner\)), and the same O-move \(m\) is legal after \(t\), then \(t \cdot m \cdot n \in \sigma\).

Condition 2 says P's response depends only on the P-view of the history, not on the full history. This is the crucial constraint that enforces sequentiality and excludes parallel-or.

### 2.4 Composition of Strategies

Given strategies \(\sigma : A \to B\) and \(\tau : B \to C\), their composition \(\tau \circ \sigma : A \to C\) is defined by _parallel composition plus hiding_: the strategies play against each other in the shared game \(B\), and the moves in \(B\) are hidden from the external view. Formally, given plays in \(\sigma\) and \(\tau\) that agree on their projections to \(B\), we interleave them, delete the moves in \(B\), and take the set of all resulting plays as \(\tau \circ \sigma\).

More technically, let \(s\) be a sequence of moves from \(A\), \(B\), and \(C\). We say \(s\) is an _interaction_ of \(\sigma\) and \(\tau\) if:

- The projection of \(s\) to moves in \(A\) and \(B\) (with correct polarity) is in \(\sigma\).
- The projection of \(s\) to moves in \(B\) and \(C\) (with correct polarity, swapping P/O for \(B\)) is in \(\tau\).
  Then \(\tau \circ \sigma\) is the set of sequences obtained by deleting all moves in \(B\) from such interactions.

The miracle of game semantics is that this composition works: the result is a well-defined, innocent strategy. The category \(\mathcal{G}\) of games and innocent strategies is a cartesian closed category, and moreover it is _fully abstract_ for PCF—two programs have the same strategy if and only if they are observationally equivalent.

## 3. The Category of Games

Let us build the category \(\mathcal{G}\) more formally. Objects are _games_ (or _arenas_). A morphism from \(A\) to \(B\) is an innocent strategy for the game \(A \multimap B\) (the linear implication game, which is essentially the game where O starts in \(B\) and P can query \(A\)).

### 3.1 The Cartesian Closed Structure

The product of two games \(A\) and \(B\) is their "disjoint union plus interleaving": moves from \(A\) and \(B\) are available independently, with O starting in either component. The exponential \(A \Rightarrow B\) is defined by:

\[
A \Rightarrow B = \; !A \multimap B
\]

where \(!A\) is the "replication" of game \(A\)—infinitely many copies of \(A\) that can be opened independently. This corresponds to the fact that a function can call its argument multiple times.

The replication \(!A\) is the most technically subtle part of the construction. It must allow O to open new copies of \(A\) at any time, and each copy is played independently. In the AJM model, a move in \(!A\) is annotated with a "copy index" (a natural number), and O can open a new copy at any index. The exponential structure is exactly what distinguishes the game semantics of PCF from that of the simply-typed lambda calculus.

### 3.2 Innocence and the Excluded Strategies

Why does innocence exclude parallel-or? The strategy for por would need to respond to the first answer it receives, regardless of which component it comes from. But in the game for \(B \times B \to B\), the plays where the left component answers first and those where the right component answers first have different P-views. An innocent strategy cannot "remember" that the first answer came from the left while waiting for the right—its response depends only on the P-view, which in the second case has no left-answer in it.

More formally, the plays:

```
s1 = O: q_result, P: q_left, O: true_left
s2 = O: q_result, P: q_right, O: true_right
```

have P-views that are just the last question-answer pair. An innocent strategy that responds `true` to `s1` must, by innocence, also respond `true` to `s2` if it ever reaches that state—but then it would answer `true` before knowing both arguments, which is wrong for por. This argument generalizes: any non-sequential function is excluded by innocence.

### 3.3 The Compact Closed Structure

The category \(\mathcal{G}\) has more structure than a cartesian closed category. It is a _compact closed category_: there is a duality \(A \mapsto A^\perp\) (swapping the roles of P and O) such that:

\[
A \multimap B \cong A^\perp \otimes B
\]

where \(\otimes\) is a symmetric tensor product (disjoint union of arenas with interleaving, O starting in whichever component is appropriate). The compact closed structure means that \(\mathcal{G}\) is a model of multiplicative linear logic—and indeed, the game semantics of PCF factors through the translation of intuitionistic logic into linear logic: the exponential \(!\) recovers the cartesian closed structure from the linear structure.

This is a recurring theme: game semantics, linear logic, and full abstraction are deeply intertwined. The compact closed structure is what makes the geometry of interaction work, and it is what allows the definability proof to be structured cleanly.

## 4. Variations: HO Games, AJM Games, and Full Abstraction

### 4.1 The HO Model

Hyland and Ong independently developed a game semantics for PCF using a different but equivalent formulation. Their model uses _arenas_ and _justified sequences_ where each move points to the move that enabled it (its "justifier"). The HO model is "tree-based": the enabling relation forms a forest, and plays are justified sequences where each move explicitly justifies later moves.

The HO model achieves full abstraction through a different route: rather than innocence, they impose a _well-bracketing_ condition. In a well-bracketed strategy, when P answers a question, the answer must be "addressed" to the most recent unanswered question—mirroring the stack discipline of functional programming. Combined with _visibility_ (a generalization of innocence), this yields full abstraction.

### 4.2 AJM vs. HO

The relationship between the AJM and HO models was a source of productive confusion for several years. They are equivalent in the following sense: the model of PCF obtained from AJM games (with innocence) is isomorphic to the model obtained from HO games (with visibility and well-bracketing). Both yield the same compact closed category \(\mathcal{G}\) of games and strategies.

The equivalence was established by showing that both models embed into a common "relational" model of games and that the images coincide. This is a typical pattern in semantics: multiple presentations of the same mathematical object illuminate different aspects of the structure.

### 4.3 Definability

The final piece of the full abstraction proof is _definability_: every finite-state innocent strategy (or every recursive innocent strategy, for the language with recursion) is the denotation of some PCF term. This shows that the model contains no "junk"—every element of the model corresponds to a program.

The definability proof proceeds by induction on the structure of the game, constructing a PCF term that implements a given strategy. For finite strategies, the construction is effective: given the strategy's automaton, one can synthesize a PCF program. This is a kind of _program extraction_ from game semantics—a technique that has been extended to produce certified programs from specifications.

Specifically, the proof uses _decomposition lemmas_: any strategy \(\sigma : A \Rightarrow B\) can be decomposed into a "head" interaction followed by a tail that depends on the answer. By induction on the size of the game, the tail strategies are definable, and the head interaction can be encoded using the PCF conditional and recursion.

## 5. Strategies as Sheaves

A deep insight, due to Joyal and later developed by Melliès, is that strategies can be understood as sheaves on a certain site. The _game_ becomes a category (the category of "positions" or "configurations"), and a strategy becomes a sheaf—a functor satisfying a gluing condition.

### 5.1 The Site of a Game

Given a game \(A\), consider the category \(\mathbb{P}(A)\) whose objects are _positions_ (even-length plays) and whose morphisms are _extensions_ (one position extends to another by adding moves). A strategy \(\sigma\) can be seen as a presheaf on \(\mathbb{P}(A)\): to each position \(p\), it assigns the set of P-responses that are legal in \(\sigma\). The determinism condition says that this presheaf is a subsheaf of the presheaf of all P-moves.

The sheaf condition corresponds to the fact that a strategy's response to a given O-move is determined locally by the P-view. This is a geometric condition: the P-view projection \(\mathbb{P}(A) \to \mathbb{P}\_{\mathrm{view}}(A)\) is a fibration, and innocence says that the strategy factors through this projection.

### 5.2 Concurrent Game Semantics and Event Structures

The sheaf-theoretic perspective opens the door to _concurrent_ game semantics, where multiple interactions can happen in parallel and the order of moves is partial, not total. In this setting, a game is an _event structure_ (a poset of events with a conflict relation), and a strategy is a _configuration_—a conflict-free, down-closed set of events.

Concurrent game semantics, developed by Rideau, Winskel, and others, provides models for concurrent higher-order languages and has applications to hardware verification and distributed protocols. The sheaf condition generalizes naturally: a strategy is a sheaf on the site of configurations with the "covering" given by compatible families of events.

### 5.3 From Sheaves to Polynomial Functors

A recent development recasts game semantics in the language of _polynomial functors_. A game is a polynomial functor \(p : \mathcal{E} \to \mathcal{B}\) (a "container" in the sense of Abbott, Altenkirch, and Ghani), and strategies are _lenses_—morphisms between polynomial functors that compose via pullback. This reformulation, due to Spivak and others, connects game semantics to database theory (where lenses model bidirectional transformations), to learning theory (where lenses model gradient-based updates), and to applied category theory. The polynomial perspective reveals that game semantics is not just about programming languages—it is about interactive systems in the broadest sense.

## 6. The Intensional/Extensional Divide

Game semantics exposes a fundamental distinction between _intensional_ and _extensional_ models. The Scott model is extensional: two functions are equal if they map equal inputs to equal outputs. But this is too coarse: it doesn't capture the computational behavior—how a function computes its result.

Game semantics is intensional: a strategy records not just the input-output mapping but the _dialogue_—the sequence of interactions that produced the output. Two functions that are extensionally equal (map the same inputs to the same outputs) may have different strategies if they interact differently with their arguments.

### 6.1 The Intensional Order

The intensional preorder on strategies: \(\sigma \leq \tau\) if every play in \(\sigma\) is also a play in \(\tau\) (i.e., \(\tau\) has more responses). This is the _stable order_ of Berry, and it captures the idea that one program is more defined than another. The extensional collapse of this order (identifying strategies with the same input-output behavior) recovers the Scott model. Thus, the Scott model is a quotient of the game model, and full abstraction fails because the quotient identifies too much.

### 6.2 Extensional Collapse and the Failure of Full Abstraction

The relationship can be diagrammed:

```
Game Model (fully abstract)
    |
    | Extensional collapse
    v
Scott Model (not fully abstract)
    |
    | Observational equivalence
    v
Syntactic Model (trivially fully abstract)
```

The game model sits at the top: it distinguishes everything that can be distinguished by observation. The Scott model is coarser—it identifies some distinct strategies (like different implementations of the same mathematical function). And the syntactic model is the coarsest—it identifies everything that is observationally equivalent.

## 7. Beyond PCF: Game Semantics for Richer Languages

The success of game semantics for PCF has led to extensions for many language features:

### 7.1 General References (Idealized Algol)

Abramsky and McCusker (1997) extended game semantics to languages with general references (mutable state), obtaining a fully abstract model of Idealized Algol. The key innovation was _non-innocent_ strategies: to model state, P must remember the history of assignments, which violates innocence. Instead, they impose a weaker condition called _visibility_ plus a _cell_ structure that tracks the state.

### 7.2 Nondeterminism and Probabilistic PCF

Harmer, Hyland, and Melliès (2007) developed game semantics for nondeterministic PCF, where strategies are no longer deterministic—P may have multiple possible responses to an O-move. For probabilistic PCF (Danos and Harmer, 2002), strategies become probability distributions over responses, and composition involves summing over possible interaction paths.

### 7.3 Concurrency and the \(\pi\)-Calculus

Laird (2008) and others have developed game semantics for concurrent languages, including the \(\pi\)-calculus. Here, games model channels and their interactions, and strategies correspond to processes. The composition of strategies corresponds to parallel composition plus hiding (restriction) of channels. A key technical innovation is _concurrent innocence_: in a concurrent setting, the P-view condition is relaxed to allow P to remember multiple "threads" of interaction simultaneously. The resulting category is a _compact closed category with biproducts_, providing a fully abstract model of the \(\pi\)-calculus.

### 7.4 Nominal Game Semantics

The theory of _nominal sets_ (Gabbay and Pitts, 2002) provides a foundation for game semantics of languages with name binding and freshness. Names are modeled as atoms that can be tested for equality but have no other structure. Nominal game semantics has been used to model languages with dynamic allocation, the \(\nu\)-calculus, and ML-style references. The key insight: name creation is modeled by a "new" move that generates a fresh atom, and strategies must be equivariant under renaming of atoms, ensuring that the exact choice of fresh name does not affect the observable behavior.

## 8. The Geometry of Interaction: Composition as Path Composition

The Geometry of Interaction (GoI), introduced by Girard in 1989, provides an alternative, algebraic formulation of game semantics that is particularly well-suited for implementation. In GoI, a program is interpreted as an operator on a Hilbert space (or more generally, an algebra), and composition corresponds to the execution formula:

$$
\mathrm{Ex}(\sigma, \tau) = (1 - \sigma^2)^{-1}
$$

But what does this mean concretely? In the game semantics setting, GoI provides a way to compute the composition of strategies without enumerating all possible interactions. Let's build this up from scratch.

### The Execution Formula as Feedback

Consider two strategies \(\sigma : A \multimap B\) and \(\tau : B \multimap C\). Their composition \(\tau \circ \sigma : A \multimap C\) should behave as follows: an O-move in \(C\) triggers \(\tau\), which may make a P-move in \(B\); this becomes an O-move for \(\sigma\), which may make a P-move in \(A\); this becomes an O-move visible to the environment; and so on. The "hidden" communication on \(B\) is exactly feedback from \(\tau\)'s output to \(\sigma\)'s input.

In the GoI, this feedback is captured by the trace of an operator. Let \(\sigma\) and \(\tau\) be represented as matrices whose entries encode the possible transitions. The composition corresponds to taking the trace over the \(B\)-moves, followed by the execution formula which "chases" the token through the network of transitions until it exits (produces a visible move) or deadlocks.

### Walkthrough: Composing Two Simple Strategies

Let's trace through a concrete composition. Define a game \(N\) (naturals) with a single O-question \(q\) and P-answers \(n \in \mathbb{N}\). A strategy \(\sigma : N \multimap N\) for the successor function:

- When O asks \(q\) in the output, P asks \(q\) in the input (query the argument).
- When O answers \(n\) in the input, P answers \(n+1\) in the output.

Another strategy \(\tau : N \multimap N\) for doubling: same pattern but answers \(2n\).

To compose \(\tau \circ \sigma\):

1. Environment asks \(q\) in the final output (O-move for \(\tau\)).
2. \(\tau\) responds by asking \(q\) in \(B\) (its input, which is \(\sigma\)'s output). This becomes an O-move for \(\sigma\).
3. \(\sigma\) responds by asking \(q\) in \(A\) (its input, visible to environment). This is P's question in the composed strategy.
4. Environment answers \(n\) in \(A\) (O-move for \(\sigma\)).
5. \(\sigma\) responds with \(n+1\) in \(B\) (its output, O-move for \(\tau\)).
6. \(\tau\) responds with \(2(n+1)\) in \(C\) (final answer, visible to environment).

The composed strategy computes \(n \mapsto 2(n+1)\). The interaction on \(B\) (steps 2, 5) is hidden; the visible interaction is only steps 1, 3, 4, 6.

### The Token Game and Data Flow

The GoI perspective reveals that game semantics is fundamentally about _data flow_. A play is a path of a token through a network of components (the strategies), where each component transforms the token according to its local transition rules. The execution formula computes the global behavior from the local transitions. This is exactly analogous to how a compiler composes the control flow graphs of individual functions into the program's global CFG — the token is the program counter, and each strategy is a basic block.

This data-flow interpretation has practical consequences. The GoI has been used to implement game semantics models in proof assistants (Coq, Agda) and to derive abstract machines for higher-order languages. The _abstract machine for PCF_ derived from GoI (by Danos, Herbelin, and Regnier) is essentially the Krivine machine — the standard abstract machine for call-by-name lambda calculus — confirming that game semantics captures the essential operational behavior of functional programs.

## 9. The Intensional-Extensional Spectrum and Categorical Structure

### 8.1 The Stable Order and Sequential Algorithms

Berry's _stable domain theory_ (1978) introduced the _stable order_: for continuous functions \(f, g : D \to E\), define \(f \leq*s g\) if \(f(x) \sqsubseteq g(x)\) for all \(x\) and additionally \(f\) and \(g\) agree on the minimal points where they differ. This order is the extensional collapse of the intensional order on strategies. The \_sequential algorithms* model (Berry and Curien, 1982) provides a concrete, syntax-free representation of PCF's sequential functions, and it is equivalent to the game semantics model. A sequential algorithm is a deterministic automaton that queries its arguments in some order and produces an output—exactly a finite-state strategy in the game model.

**Proposition 8.1 (Sequential Algorithms).** The category of sequential algorithms on concrete data structures is equivalent to the category of innocent strategies on the corresponding games. Under this equivalence, the stable order on sequential algorithms corresponds to the inclusion order on strategies (as prefix-closed sets of plays).

### 8.2 Cartesian Closed Categories of Games

The category \(\mathcal{G}\) of games and innocent strategies is cartesian closed. The exponential \(A \Rightarrow B\) is interpreted as the game \(!A \multimap B\), where \(!A\) is the "repetition" of the game \(A\)—intuitively, the ability for O to open arbitrarily many "copies" of \(A\), each played independently. The currying isomorphism \(\mathrm{Hom}(A \times B, C) \cong \mathrm{Hom}(A, B \Rightarrow C)\) holds in \(\mathcal{G}\). The proof constructs an explicit bijection between strategies by re-tagging moves according to which copy of \(B\) they belong to.

### 8.3 The Compact Closed Structure

The category \(\mathcal{G}\) is not just cartesian closed—it is _compact closed_, meaning it has a duality \(A \mapsto A^\perp\) (swap the roles of O and P) and a tensor product \(\otimes\) (disjoint union of games) with internal hom given by \(A \multimap B = A^\perp \otimes B\). This structure is the foundation of the _geometry of interaction_: every morphism \(f : A \to B\) can be "transposed" to a state, and composition becomes the _trace_ (feedback) of the tensor product. This categorical abstraction unifies game semantics, linear logic, and GoI within a single framework.

### 8.4 From Games to Polynomial Functors

A recent development recasts game semantics in the language of _polynomial functors_. A game is a polynomial functor \(p : \mathcal{E} \to \mathcal{B}\) (a "container" in the sense of Abbott, Altenkirch, and Ghani), and strategies are _lenses_—morphisms between polynomial functors that compose via pullback. This reformulation, due to Spivak and others, connects game semantics to database theory (where lenses model bidirectional transformations), to learning theory (where lenses model gradient-based updates), and to applied category theory. The polynomial perspective reveals that game semantics is not just about programming languages—it is about interactive systems in the broadest sense.

## 9. Proofs as Strategies: A Curry-Howard Perspective

The Curry-Howard correspondence extends to game semantics: a proof in intuitionistic logic (or linear logic) can be interpreted as a strategy in an appropriate game. The game for a formula \(A\) has O-moves corresponding to the introduction rules of the connectives in \(A\) and P-moves corresponding to the elimination rules. A proof is a strategy that "wins" against any Opponent—it always has a response that leads to a terminal position (the axioms).

From this perspective, proof normalization (cut elimination) is the composition of strategies: given proofs \(\pi : A \vdash B\) and \(\rho : B \vdash C\), the cut is the composition of their strategies \(\rho \circ \pi : A \vdash C\). Normalization corresponds to computing the composite strategy and simplifying it. This is yet another way in which game semantics unifies proof theory and programming language semantics.

In particular, the innocent strategies correspond exactly to proofs in the \(\eta\)-expanded \(\beta\)-normal forms of intuitionistic logic. The well-bracketing condition corresponds to the _focusing_ discipline of Andreoli: proofs must alternate between invertible (O) and non-invertible (P) phases.

This correspondence yields a striking result: the normalization of a proof (cut elimination) can be computed by playing the game. Given two proofs with strategies \(\sigma\) and \(\tau\), the strategy for the cut is the composition \(\tau \circ \sigma\). Normalizing the cut corresponds to computing this composite strategy and extracting its "canonical" form — the minimal strategy that realizes the same observable behavior. This gives an operational semantics to proof normalization that is entirely geometric: normalization is not a syntactic rewriting process but a process of discovering the hidden communication paths in the interaction of two components.

The practical implications of this correspondence are significant. In proof assistants like Coq and Agda, the kernel type-checker must normalize terms to check definitional equality. The game semantics perspective suggests that normalization can be implemented via the execution formula from the Geometry of Interaction, which is inherently parallel and can be compiled to hardware. Indeed, the GoI-based normalization algorithm has been implemented in the Lamping-Gonthier optimal reduction framework and, more recently, in FPGA-based proof accelerators that normalize lambda terms via token-passing games. This line of work — from game semantics to hardware-accelerated proof checking — illustrates how a deep semantic insight can eventually become practical engineering.

## 10. Summary

Game semantics solved the full abstraction problem for PCF by shifting the fundamental metaphor from "functions as graphs" to "programs as interactive strategies." A program is not a black-box mapping from inputs to outputs; it is a participant in a dialogue, responding to queries from its environment with its own queries and ultimately with answers. The conditions of innocence, well-bracketing, and visibility carve out exactly the space of sequentially realizable functions—the ones that PCF can express.

The impact of game semantics extends far beyond PCF. It provides a unified framework for modeling state, nondeterminism, probability, concurrency, and name binding—all within a single, mathematically elegant category of games and strategies. The sheaf-theoretic reformulation connects game semantics to topos theory and geometry, while the compact closed structure connects it to linear logic and the geometry of interaction. The polynomial functor perspective opens connections to databases, machine learning, and applied category theory.

For anyone who wants to understand what computation _is_ in mathematical terms, game semantics is indispensable. It reveals that computation is not just about _what_ a program computes, but _how_ it computes—the dialogue, the strategy, the sequence of interactions that lead from question to answer.

To go deeper, the canonical references are Abramsky and McCusker's lecture notes "Game Semantics" (in the Summer School on Logic and Computation), Hyland and Ong's "On Full Abstraction for PCF" (Information and Computation, 2000), and Melliès' "Asynchronous Games" series for the connection to sheaves and concurrency. For the categorical perspective, the book _Games, Logic, and Categorical Semantics_ edited by Abramsky provides an excellent overview, while Spivak and Niu's work on polynomial functors connects game semantics to modern applied category theory.

The legacy of game semantics extends well beyond the full abstraction problem. It fundamentally changed how we think about computation, shifting the paradigm from input-output functions to strategic interaction. The concepts pioneered by AJM and HO games — arenas, plays, strategies, innocence, bracketing — have become standard vocabulary in programming language theory. The category of games and strategies has proven to be a remarkably robust mathematical structure, hosting models of a vast range of computational phenomena: state, nondeterminism, probability, concurrency, and quantum computation. The geometry of interaction provided an algebraic formulation that bridges semantics and implementation. Game semantics is one of those rare achievements in computer science that is simultaneously a solution to a specific technical problem, a beautiful mathematical theory, and a source of enduring practical insights for reasoning about program equivalence, compiler correctness, and the semantics of higher-order programs.
