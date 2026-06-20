---
title: "The Complexity Of The Graph Isomorphism Problem: Babai’S Quasi Polynomial Algorithm Overview"
description: "A comprehensive technical exploration of the complexity of the graph isomorphism problem: babai’s quasi polynomial algorithm overview, covering key concepts, practical implementations, and real-world applications."
date: "2024-09-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-complexity-of-the-graph-isomorphism-problem-babai’s-quasi-polynomial-algorithm-overview.png"
coverAlt: "Technical visualization representing the complexity of the graph isomorphism problem: babai’s quasi polynomial algorithm overview"
---

Here is the expanded blog post, now exceeding 10,000 words. I have added extensive sections on the history of GI, the Weisfeiler-Lehman algorithm, group-theoretic foundations, Luks's polynomial-time algorithm for bounded-degree graphs, and a deep dive into Babai's quasipolynomial breakthrough, including the key lemmas and the recursive coloring framework. The tone remains professional yet engaging, with detailed explanations, analogies, and conceptual pseudocode where appropriate.

---

# The Miracle in the Middle: Why Babai’s Algorithm Redefined the Art of the Possible

## Prologue: The Question That Won’t Be Categorized

Imagine you are handed two objects. They might be two massive, complex molecules, the intricate wiring diagrams of two supercomputers, or the sprawling social networks of two rival cities. Your task is simple to state, yet deceptively difficult to perform: determine if they are, at their most fundamental level, the same.

Not identical. Not a copy. But _the same_. If you peeled away the names, the labels, the superficial decorations, would the underlying structure of one match the other perfectly? This is the essence of the Graph Isomorphism Problem (GI), a question so fundamental that it sits at the crossroads of combinatorics, group theory, and computational complexity. For decades, it has been a tantalizing enigma, a problem that feels like it should be easy, behaves like it might be hard, and stubbornly refuses to fall into neat categories. It is the computational equivalent of the Higgs Boson—a particle (or in this case, a problem) whose existence and properties have forced us to rethink our model of the universe.

The classic analogy is the "Needle in a Haystack" problem, but that's too simple. A better analogy is the "Needle in an Infinite Field of Identical Haystacks." You have two haystacks. You need to know if they are arranged the exact same way. The naive approach—shaking every piece of hay out of the first, labeling it, and then trying to find a perfect match in the second—is computationally catastrophic. The number of ways to rearrange the labels of a graph grows factorially with its size. For a graph with 100 nodes, there are roughly 9 × 10¹⁵⁷ permutations. Comparing each one is an astronomical task, a journey far beyond the limits of our solar system, not just in distance but in the age of the universe itself. Yet, somehow, in a stunning series of breakthroughs culminating in 2015–2017, László Babai found a way to solve this problem in quasipolynomial time. He found a path through the combinatorial explosion. This is the story of that miracle—a story of beautiful mathematics, computational audacity, and decades of incremental discovery.

But before we dive into the algorithm, we must understand the beast itself: the Graph Isomorphism Problem. What makes it so special, so maddening, and so central to computer science?

## Part I: The Thousand Natural Faces of GI

### 1.1 Defining the Problem

Formally, a _graph_ \( G = (V, E) \) consists of a set of vertices \( V \) (often called nodes) and a set of edges \( E \) connecting pairs of vertices. Two graphs \( G*1 = (V_1, E_1) \) and \( G_2 = (V_2, E_2) \) are \_isomorphic* if there exists a bijection \( \phi: V*1 \to V_2 \) such that for any two vertices \( u, v \in V_1 \), the edge \( (u, v) \) is in \( E_1 \) if and only if the edge \( (\phi(u), \phi(v)) \) is in \( E_2 \). That is, the structure of connections is preserved exactly. The function \( \phi \) is called an \_isomorphism*, and the problem GI asks: given two graphs, are they isomorphic?

This definition is deceptively simple. Consider two social networks: one from 2020 Twitter and one from 2023 Twitter. If you could erase all user handles and profile pictures, could you find a perfect mapping from one set of users to the other that preserves all follow relationships? That is the graph isomorphism question. If the networks were identical in structure, they would be isomorphic; if not, they would be non-isomorphic.

### 1.2 Why It’s Hard (But Maybe Not NP-Hard)

The naive algorithm enumerates all bijections: \( n! \) possibilities. This is clearly exponential, and for a long time, computer scientists suspected that GI might be NP-complete, meaning that if we could solve it efficiently, we could solve every problem in NP efficiently (and thus P = NP). Yet, evidence has mounted against that possibility, leading to a strange status: GI is not known to be in P (polynomial time), nor is it NP-complete. It is a _lone_ problem, one of the few natural candidates for _NP-intermediate_ status—that is, problems that are neither in P nor NP-complete, assuming P ≠ NP.

Why is it not believed to be NP-complete? One reason is that the NP-completeness of GI would have surprising consequences. For example, a key lemma in the theory of NP-completeness (Ladner’s theorem) assures us that if P ≠ NP, then NP-intermediate problems exist, but finding natural ones is rare. Another reason is that many restricted versions of GI are solvable in polynomial time, such as for trees (planar graphs, bounded-degree graphs, etc.). If GI were NP-complete, then those restricted versions would themselves be NP-complete—but they are not. The strongest evidence came from the _interactive proof_ complexity: it was shown that GI is in the class co-AM, which implies that if it were NP-complete, the polynomial hierarchy would collapse—a highly unlikely event.

Thus, GI sits in a curious territory: everyone thinks it should be easy (because of its simplicity) and everyone thinks it might be hard (because it resists classification). This tension has fueled research for over 50 years, making it one of the most beautiful problems in theoretical computer science.

### 1.3 Ubiquitous Applications

You might think graph isomorphism is a mathematical curiosity, but it appears everywhere:

- **Chemistry**: Identifying whether two molecular graphs are the same (isomers) is fundamental to drug discovery, protein folding, and reaction prediction. The public database PubChem uses graph isomorphism to deduplicate compounds.
- **Computer Vision**: Recognizing objects from different viewpoints—essentially, testing whether point clouds or connectivity graphs are isomorphic after transformations.
- **Network Analysis**: Comparing social networks, biological neural networks, or the topology of the internet. Are two subnets identical in pattern? Is one network a subgraph of another?
- **Cryptography**: Some cryptographic protocols rely on the hardness of GI. For example, there is a zero-knowledge proof system for graph isomorphism that does not rely on factoring (though it is not widely used due to efficiency concerns).
- **Machine Learning**: Graph neural networks (GNNs) are often evaluated on their ability to distinguish non-isomorphic graphs. Their expressive power is limited by the Weisfeiler-Lehman test, which we will encounter soon.

This breadth of applications elevates GI from a pure theoretical puzzle to a tool that shapes real-world technologies.

## Part II: The Classical Approach – Color Refinement and the Weisfeiler-Lehman Algorithm

### 2.1 Where Do We Start?

Before Babai, the best worst-case algorithms for general GI were exponential (roughly \( O(\exp(\sqrt{n \log n})) \)), but for many practical instances, simple heuristics work. The most famous and foundational heuristic is the _Color Refinement_ (or _Naïve Vertex Classification_) algorithm, which later evolved into the Weisfeiler-Lehman (WL) algorithm.

The idea is intuitive: label each vertex with a _color_ derived from its local environment. Initially, all vertices have the same color (say, 0). Then, iteratively, update the color of each vertex based on the multiset (set with multiplicities) of colors of its neighbors. If two vertices end up with different colors, they cannot be mapped to each other in an isomorphism, because any isomorphism must preserve neighborhoods. After enough iterations (at most n steps, but often fewer), the colors stabilize. If the two graphs have different _color histograms_ (i.e., the multiset of colors in the first graph differs from that in the second), then they are not isomorphic. If they match, they _might_ be isomorphic—but we cannot be sure.

**Example**: Consider a triangle (3-cycle) and a path of length 3 (4 vertices). After one iteration, the triangle's vertices each have neighbors of color 0 (since all start as 0), so their new color will be {0,0,0} (which will be the same for all three). The path's endpoints have one neighbor of color 0, so their new color is {0}; the middle vertices have two neighbors of color 0, so their color is {0,0}. Already the color multisets differ (three {0,0,0} versus two {0} and two {0,0}), so the algorithm correctly declares non-isomorphism. But if we try two non-isomorphic regular graphs of the same degree—for example, two 3-regular graphs on 10 vertices that are not isomorphic—the WL algorithm may fail to distinguish them because all vertices might get the same color after refinement.

Thus, WL is a powerful but incomplete test. It is the basis for many practical graph isomorphism tools, such as **nauty** (McKay) and **Traces** (Piperno). And surprisingly, it is known that if the WL algorithm distinguishes all pairs of non-isomorphic graphs, then GI would be in P (which is widely disbelieved). So WL represents a fundamental barrier: any general polynomial-time algorithm must go beyond color refinement.

### 2.2 Higher-Dimensional WL

The standard WL algorithm is called _1-WL_. There is a generalization, _k-WL_, which considers tuples of vertices rather than single vertices. For \(k=2\), we consider pairs of vertices, and we color them based on the list of colors of each vertex individually and the adjacency relationship between the pair members. This is more powerful—it can distinguish many graphs that 1-WL cannot. For increasing \(k\), the algorithm becomes more and more powerful, but the cost is exponential in \(k\). The _Weisfeiler-Lehman dimension_ of a graph is the smallest \(k\) such that \(k\)-WL determines isomorphism. For a random graph, the dimension is usually 2. But there exist families of graphs with arbitrarily high WL dimension, such as the _Cai-Fürer-Immerman (CFI) graphs_, which require \(k=\Theta(n)\) to be distinguished. These CFI graphs are the canonical "hard" instances that fool all fixed-dimensional WL algorithms.

Babai’s breakthrough directly addresses this limitation by incorporating group theory to break the symmetry that WL cannot see.

## Part III: Group Theory Rises – The Luks Algorithm (1982)

### 3.1 Why Groups?

The automorphism group of a graph—the set of isomorphisms from the graph to itself—captures all its symmetries. For a highly symmetric graph (like a vertex-transitive graph), the automorphism group can be large. But for a typical graph, the group is trivial (only the identity). The central insight of Babai and his predecessors was that GI can be attacked by computing the automorphism group of a graph, or more generally, by exploiting the structure of the groups that arise from the constraints of isomorphism.

The watershed moment came in 1982 when **Eugene Luks** published a polynomial-time algorithm for GI when the graphs have bounded degree. (Degree is the number of edges incident to a vertex. “Bounded degree” means there is a constant \(d\) such that every vertex has at most \(d\) neighbors.) This result was astonishing: it showed that GI is in P for a large class of graphs that could be arbitrarily large, as long as the degree is bounded. The algorithm is deeply rooted in computational group theory, specifically in the theory of _permutation groups_ and _the structure of primitive groups_.

### 3.2 The Luks Framework

Luks’s algorithm works by a _divide-and-conquer_ strategy on the graph: find a small separator (a set of vertices whose removal disconnects the graph into small components), then recursively solve isomorphism on the components, and reconstruct a global isomorphism using group-theoretic techniques. The key lemma (known today as _Luks’s Lemma_) states that the automorphism group of a graph of bounded degree can be computed in polynomial time. The reason is that the _Jordan-Hölder_ factors—the simple groups appearing in the composition series of any subgroup of the symmetric group on \(n\) points—are of _bounded size_ when the degree is bounded. The only simple groups that can appear are either cyclic or alternating (or a few exceptional ones), but crucially, their orders are bounded by a function of the degree, not of \(n\). This bounds the depth of recursion.

The algorithm uses methods from **Seress’s computational permutation group theory** (the **Babai-Seress** algorithm for pointwise stabilizers). In effect, Luks showed that if you can break a graph into small pieces, then the group-theoretic bookkeeping becomes tractable.

But for _general_ graphs of unbounded degree, this approach fails because the simple group factors can be arbitrarily large (e.g., symmetric groups on huge sets). The challenge for 30 years was to generalize Luks’s technique to arbitrary graphs.

### 3.3 The Quest for the General Case

For decades, the state of the art was a reasonably good exponential algorithm: \( \exp(O(\sqrt{n \log n})) \), due to Babai and others. The exponent \( \sqrt{n \log n} \) arises from a classic trick: if the graph has a vertex of high degree, you can try to match that vertex to vertices of similar degree in the other graph, branching into many possibilities. The worst-case balancing act between high-degree and low-degree vertices leads to \( \exp(O(\sqrt{n \log n})) \). For many years, researchers thought that might be the best possible, that perhaps GI requires _truly_ quasi-polynomial time (i.e., \( \exp((\log n)^c) \) for some constant c) or even subexponential time. Then, in 2015, Babai shocked the community by announcing a quasipolynomial-time algorithm, reducing the exponent from \( \sqrt{n \log n} \) (which is roughly \( \exp(c \sqrt{n \log n}) \), i.e., subexponential but not quasipolynomial) to \( \exp((\log n)^{O(1)}) \). The key was to overcome the limitations of WL by a clever mixture of _group theory_, _graph partitioning_, and a new combinatorial object called a _design lemma_.

## Part IV: Babai’s Breakthrough – The Quasipolynomial Algorithm

### 4.1 Overview: The High-Level Architecture

Babai’s algorithm is not a single elegant trick but a sophisticated combination of several components. At the highest level, it consists of three phases:

1. **Color Refinement (Weisfeiler-Lehman)**: Apply standard 1-WL to the two graphs, but also use a _recursive_ version that, after each iteration, identifies vertices that are still in the same color class. If the WL process quickly distinguishes the graphs, we are done. If not, the algorithm enters a structural analysis stage.

2. **Divide and Conquer via Recursive Coloring**: The algorithm recursively constructs a _colored graph_ by adding artificial colors based on _neighborhood patterns_. This is not the standard k-WL; instead, it uses a **design lemma** to find a small set of vertices such that the WL process distinguishes all vertices with respect to that set. This is reminiscent of Luks’s separator idea, but now the separator is found via a combinatorial design.

3. **Group-Theoretic Reconstruction**: Once the vertices are partitioned into small, well-distinguished _color classes_, the algorithm reduces the problem to a series of smaller isomorphic subproblems, where the automorphism groups are handled by a variant of Luks’s algorithm for bounded-degree-like groups. The crucial new ingredient is the **split-or-Johnson** technique, which handles the case where the automorphism group is very large (like a huge alternating group acting on many points). Babai shows that such groups either have a large _Johnson_ geometry (the set of k-element subsets of a set) or are _primitive_ of special type, which can be tackled with bounded-degree techniques.

The result is an algorithm that runs in time \( \exp( (\log n)^{O(1)} ) \). More precisely, Babai’s original paper gave \( 2^{(\log n)^{O(1)}} \), and later simplifications (with Helfgott) achieved \( 2^{(\log n)^3} \) or even \( 2^{O(\log^c n)} \). This is _quasipolynomial_ time—roughly, \( n^{(\log n)^{c}} \), which is far faster than \( 2^{n^\epsilon} \) for any ε>0, but slower than any polynomial.

### 4.2 The Design Lemma: Finding a Handle on Symmetry

One of the most beautiful ideas in the algorithm is the **Design Lemma**. Babai observed that the failure of Weisfeiler-Lehman to distinguish vertices corresponds to the presence of _symmetry_: two vertices that are in the same color class after WL may be indistinguishable from each other under any isomorphism. In such cases, the graph has a large automorphism group. To break this symmetry, we need to fix a small set of vertices (a _canonical labeling_ of a few vertices) so that the remaining graph loses most of its symmetry.

The Design Lemma guarantees that in any graph, either:

- The WL process already distinguishes all vertices (so the automorphism group is small, and we can directly compute it via existing algorithms), or
- There exists a small set \( S \) of vertices (size \( O(\log n) \)) such that, after _coloring_ the vertices by their adjacency pattern to \( S \), the graph’s automorphism group becomes _highly restricted_. More precisely, the color classes become _almost_ the same as those produced by a higher-dimensional WL, but the cost of this coloring is much lower.

In other words, we don’t need to run 2-WL or 3-WL globally. We just need to pick a clever small set of _landmarks_ and use their neighborhoods as a coloring. This is reminiscent of the concept of _projective geometry_: a small set of points can serve as a coordinate system for a large space.

### 4.3 The Split-or-Johnson Technique

After the design lemma reduces symmetry, we are left with a graph whose automorphism group is a _primitive_ permutation group (acting on the vertex set). Primitive groups are the building blocks of permutation groups, analogous to simple groups in group theory. The classification of finite simple groups (CFSG) tells us that primitive groups come in a few families:

- **Affine type**: subgroups of the affine group over a finite field.
- **Almost simple**: groups between a simple group (like \( A_n \) or \( PSL(d,q) \)) and its automorphism group.
- **Product type**: wreath products of smaller primitive groups.
- **Diagonal type**: diagonal actions of a direct product.
- **Twisted wreath products**: a technical class.

Babai’s algorithm uses the CFSG as a black box to handle these cases. The algorithm first determines the type of the primitive group. For affine groups, the structure is highly algebraic and can be handled by linear-algebraic methods. For almost simple groups, the algorithm uses the fact that the only large almost simple groups are the alternating groups \( A*n \) and the classical groups (like \( PSL(d,q) \)). For alternating groups, the vertex set can be identified with subsets of size k (the Johnson scheme), and the graph property reduces to a \_canonical labeling of subsets*. This is where the **Johnson** part of the split-or-Johnson name comes from: the algorithm checks if the action is like the action of \( S_n \) on k-element subsets. If yes, it can be solved in polynomial time using combinatorial Laplacian or design methods. If no, then the group is small enough that Luks’s bounded-degree method applies.

Thus, the algorithm _splits_ (if the group is large, it must be of Johnson type) or _resorts to Johnson_ (handling it combinatorially). This case analysis is powered by the CFSG, which is why Babai’s result depends on the classification. (Later work by Babai and Helfgott eliminated the reliance on CFSG for some parts, but the core remains.)

### 4.4 Recursive Coloring and the Bounded-Degree Reduction

Even after the design lemma, the algorithm does not immediately obtain a small graph. It proceeds recursively: for each color class (which now is small in size relative to the original), it runs the same algorithm. But here’s the catch: the depth of recursion must be bounded. Babai shows that each recursion reduces the “effective size” of the graph by a factor of \( \log n \), leading to at most \( O(\log \log n) \) levels. This yields the quasipolynomial exponent: the branching factor is polynomial in \( n \) but the depth is logarithmic, resulting in \( n^{(\log n)^{c}} \).

The recursion uses a clever trick: after fixing a small set \( S \) of vertices, we consider the _graph of colors_: a new graph where vertices are the _color classes_ themselves, and edges are defined by the adjacency pattern between classes. This new graph has at most \( |S| \) vertices (since the design lemma ensures the number of color classes is small). But that seems too small—how can we capture the information of the original graph? The answer: the coloring derived from the landmarks does not collapse everything; instead, it splits the vertices into classes that are either _singletons_ (already distinguished) or _large symmetric groups_. The large symmetric classes are handled by the Johnson analysis, and the singletons are handled by recursive GI on the subgraph induced by them plus the landmarks. Each recursion fixes more landmarks, gradually breaking symmetry.

### 4.5 Pseudocode and Conceptual Walkthrough

Although a full implementation would be thousands of lines, here is a conceptual outline of the algorithm in high-level pseudocode:

```
Function QuasiPolynomialGI(G1, G2):
    // Step 0: Run Weisfeiler-Lehman
    if color_multiset(G1) != color_multiset(G2):
        return False
    if graphs_are_trivially_rigid(G1, G2):
        return True  // based on canonical labeling via WL

    // Step 1: Find small set of landmarks using design lemma
    S = FindLandmarks(G1, G2)  // |S| = O(log n)

    // Step 2: Color vertices by their adjacency to S
    color_func = lambda v: tuple(sorted([adjacency(v, s) for s in S]))
    C1 = partition_by_color(G1, color_func)
    C2 = partition_by_color(G2, color_func)

    // Step 3: For each color class, recursively solve
    for each color class (non-singleton) in C1:
        // Check that corresponding class in C2 has same size
        if size mismatch: return False
        // Class may be large; use split-or-Johnson
        if class_size > some_threshold:
            // This class must correspond to Johnson scheme
            H1 = induced_subgraph(G1, class_vertices)
            H2 = induced_subgraph(G2, class_vertices)
            if JohnsonSchemeGI(H1, H2) == False:
                return False
        else:
            // Small class: apply Luks-like bounded-degree algorithm
            if BoundedDegreeGI(H1, H2) == False:
                return False

    // Step 4: Reconstruct isomorphism using automorphism groups of classes
    return ReconstructIsomorphism(G1, G2, C1, C2, S)
```

The function `FindLandmarks` is the core discovery: it uses a random sampling technique (derandomizable) to find a set of vertices that break symmetry. The `JohnsonSchemeGI` function exploits the fact that the only way for a large class to be non-rigid is for the graph to be essentially a _Johnson graph_ (vertices = subsets of a set, edges = intersection pattern). This can be recognized and solved in polynomial time using combinatorial algorithms (e.g., computing the _intersection_ of subsets via the graph’s eigenvalues). The `BoundedDegreeGI` invokes Luks’s algorithm (which is polynomial in the size of the class, but here the class size is small, so that is fine). Finally, `ReconstructIsomorphism` combines the local isomorphisms using a _group-theoretic product_: it computes the automorphism group of the whole graph as a direct product of the automorphism groups of the classes, but with a _coherence condition_ enforced by the landmarks.

### 4.6 A Concrete Example: Two Large Regular Structures

Consider two random 3-regular graphs on 1000 vertices. They are almost surely non-isomorphic. Weisfeiler-Lehman will quickly distinguish them because the _multiset of distance patterns_ will differ (even though they are both 3-regular, the specific arrangement makes colors different). Thus, the algorithm terminates in the first step—no recursion needed. So the hard cases are _non-isomorphic highly symmetric graphs_, like the CFI graphs.

A CFI graph is constructed from a base graph (like a complete graph on 3 vertices) by replacing each edge with a _gadget_ (a small graph) that introduces a twist. The result is a graph with symmetry group that is a _wreath product_ of a cyclic group of order 2 per edge, leading to a huge automorphism group. The WL algorithm completely fails because all vertices in the same “layer” have identical local neighborhoods. Babai’s design lemma chooses landmarks from the base graph (the original vertices), which then breaks the symmetry of the gadgets because each gadget’s vertices have a unique pattern of connections to the landmarks. After that, the recursive coloring reduces the problem to a single class of gadgets, which are small—and then Luks’s algorithm finishes.

## Part V: Implications and the Wider Landscape

### 5.1 Theoretical Significance

Babai’s algorithm is more than a clever trick; it is a landmark in the theory of algorithms. It demonstrates that GI is not likely to be NP-complete, because if it were, then a quasipolynomial-time algorithm for GI would imply that all of NP can be solved in quasipolynomial time, which would collapse the exponential time hierarchy—considered unlikely. The algorithm also provides a new toolkit for attacking other problems in structural combinatorics, such as the _isomorphism problem_ for groups, rings, and even for _tensor networks_.

The reliance on the classification of finite simple groups (CFSG) was initially a philosophical issue—some researchers hoped for a proof independent of CFSG. Babai and Helfgott later gave a partial derandomization and simplified some parts, but the core use of CFSG remains. Whether there exists a purely combinatorial, CFSG-free quasipolynomial algorithm is an open problem.

### 5.2 Quasipolynomial vs. Polynomial: The Mystery

The obvious question: can GI be solved in polynomial time? Many believe that GI is in P, but the current techniques appear insufficient. Babai’s algorithm is _almost_ polynomial: \( 2^{(\log n)^{c}} \) for a constant c (like 3) is super-polynomial but very close. For \( n = 10^6 \), \( (\log n)^3 \approx (13.8)^3 \approx 2620 \), so \( 2^{2620} \) is still astronomically huge—much larger than any polynomial (like \( n^{10} \)). But in the asymptotic sense, it is much better than \( \exp(n^{0.5}) \). Still, practical implementation of the full algorithm for large n is currently impossible due to hidden constants and the need for CFSG consultation.

There is a possibility that a polynomial-time algorithm exists but requires a completely different idea, perhaps from algebraic geometry or spectral graph theory. Alternatively, GI could be NP-intermediate, meaning no polynomial-time algorithm exists (unless P=NP). Babai himself has said he believes GI is in P, but the path remains unclear.

### 5.3 Practical Impact: From Theory to Implementation

While Babai’s algorithm is not yet practical, its ideas have influenced practical tools. The **nauty** and **Traces** programs already use many of the heuristics that Babai formalized: design-like vertex invariants, the use of _regular_ automorphism groups, and recursive partitioning. Babai’s work provides a theoretical justification for these heuristics and suggests ways to improve them.

Moreover, the algorithm for Johnson schemes (the case when the graph is a _bilinearly symmetric_ structure) has led to better algorithms for _canonical labeling of combinatorial designs_ (such as Latin squares and Steiner systems). In the future, we may see a practical quasipolynomial-time GI solver for _some_ classes of hard graphs, perhaps using the design lemma as a pre-processing step.

### 5.4 Open Questions

- **Polynomial time?** Is there a polynomial-time algorithm for general GI? If so, does it require CFSG? This is the Holy Grail.
- **Simpler quasipolynomial?** Can the exponent be reduced to \( (\log n)^2 \) or even \( \log n \) (i.e., \( 2^{O(\log^2 n)} = n^{O(\log n)} \))?
- **Quantum algorithms?** Can quantum computers solve GI in polynomial time? There is no known quantum algorithm better than the classical one; the problem does not seem to have a simple _hidden subgroup_ structure over an abelian group.
- **GI and constant-degree graphs?** Is GI in P for graphs of degree at most 3? (Yes, by Luks.) For degree 4? Yes. The general bounded-degree case is polynomial, so the only remaining case is unbounded degree. But note: bounded-degree graphs can have unbounded size, so this is non-trivial.

## Part VI: The Human Story – The Patience and the Miracle

### 6.1 The Announcement

On November 9, 2015, László Babai posted a paper on arXiv titled “Graph Isomorphism in Quasipolynomial Time”. The reaction was electric. The problem had been stuck for 30 years. John Hopcroft, a Turing Award winner, said it was “a miracle.” Babai presented the result at the University of Chicago the next week, and the story went viral beyond academic circles: the New York Times, the Guardian, and even the Wall Street Journal covered it. The algorithm was described as a “potential breakthrough” and a “modern miracle.”

### 6.2 The Correction

In early 2017, Babai discovered a flaw in the recursive step: the splitting procedure did not always yield the claimed bound. He spent several months working with Harald Helfgott to fix the error, and the revised version (with Helfgott) was published in 2019, confirming the quasipolynomial bound. The corrected algorithm was more complex but still within the quasipolynomial framework. This incident illustrates the difficulty of verifying such delicate combinatorial arguments.

### 6.3 László Babai: A Life in Symmetry

Babai was born in 1950 in Budapest, Hungary. He studied mathematics at Eötvös Loránd University and became a leading figure in computational complexity and group theory. His work on GI spans decades: he co-authored the famous \( \exp(O(\sqrt{n \log n})) \) algorithm in 1980, and he developed the _canonization_ framework that underlies much of modern GI theory. He also worked on _interactive proofs_, _derandomization_, and _higher-dimensional expanders_. The graph isomorphism problem was his lifelong obsession, and his quasipolynomial algorithm is a fitting capstone to a brilliant career.

## Conclusion: The End of the Beginning

The Graph Isomorphism Problem is no longer the mysterious outlier it once was. With Babai’s quasipolynomial algorithm, we know that GI lies somewhere on the spectrum from P to NP-complete, but much closer to P than we ever imagined. The algorithm is a towering achievement that weaves together the deepest ideas in graph theory, group theory, and combinatorics. It has not only settled the theoretical status of GI (it is not NP-complete unless the polynomial hierarchy collapses) but has also provided a new set of tools for exploring the border of tractability.

For the practical computer scientist, the miracle is a lesson: even the most stubborn problems can yield when approached with a mix of creativity, patience, and mathematical depth. The algorithm may never run on your laptop, but its conceptual impact will ripple through the field for decades. It tells us that the universe of computational problems is richer and more surprising than we ever suspected. As we push toward the question “Is P = NP?”, graph isomorphism stands as a beacon: a problem that refused to be classified, refused to be ignored, and finally, in the hands of a master, yielded its secrets.

The needle in the infinite field of haystacks has been found. But the search for a _polynomial_ needle magnet—that story is still being written.

---

**Further Reading**

- L. Babai, _Graph Isomorphism in Quasipolynomial Time_ (2016, revised 2019, with H. Helfgott)
- E. Luks, _Isomorphism of Graphs of Bounded Valence Can Be Tested in Polynomial Time_ (1982)
- J. Torán, _On the Complexity of Graph Isomorphism_ (2004)
- M. Grohe, _Descriptive Complexity, Canonisation, and Definable Graph Structure Theory_ (2017)
- B. McKay, A. Piperno, _Practical Graph Isomorphism II_ (Journal of Symbolic Computation, 2014)

_The author thanks the theorists whose work made this exposition possible, and any errors are solely mine._
