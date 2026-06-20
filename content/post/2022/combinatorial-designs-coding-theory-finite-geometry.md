---
title: "Combinatorial Designs and Coding Theory: Block Designs, Steiner Systems, and Finite Geometry"
description: "An exploration of combinatorial design theory—block designs, Steiner systems, finite projective planes—and their deep connections to error-correcting codes and experimental design."
date: "2022-10-10"
author: "Leonardo Benicio"
tags: ["combinatorial-designs", "coding-theory", "finite-geometry", "steiner-systems", "block-designs"]
categories: ["theory", "mathematics"]
draft: false
cover: "/static/assets/images/blog/combinatorial-designs-coding-theory-finite-geometry.png"
coverAlt: "Diagram of the Fano plane—the smallest finite projective plane with 7 points and 7 lines"
---

Balance. Symmetry. The arrangement of points into blocks such that every pair of points appears in exactly \(\lambda\) blocks. This is the central problem of combinatorial design theory, a field that originated with the statistical design of experiments (Fisher, Yates, Bose in the 1930s) and has since revealed deep connections to finite geometry, coding theory, and cryptography. The smallest and most beautiful example is the _Fano plane_: 7 points, 7 lines, each line contains 3 points, each point lies on 3 lines, and every pair of points determines a unique line. It is the projective plane of order 2 over \(\mathbb{F}\_2\), and it is the Steiner system \(S(2, 3, 7)\).

The interplay between designs and codes is profound. The incidence matrix of a design generates a linear code, and the parameters of the design translate into bounds on the code's dimension and minimum distance. The projective planes of order \(q\) (which exist whenever \(q\) is a prime power, by construction from \(\mathbb{F}\_q\)) give rise to a family of codes (the _projective geometry codes_) that include the Hamming codes and the Reed-Muller codes as special cases. This post develops design theory from first principles and explores its applications in coding theory, finite geometry, and experimental design.

## 1. Block Designs

**Definition 1.1.** A _balanced incomplete block design_ (BIBD) with parameters \((v, b, r, k, \lambda)\) is an arrangement of \(v\) points into \(b\) blocks such that:

1. Each block contains exactly \(k\) points.
2. Each point appears in exactly \(r\) blocks.
3. Every pair of distinct points appears together in exactly \(\lambda\) blocks.

The design is _incomplete_ because \(k < v\) (blocks are proper subsets). The parameters satisfy two fundamental identities:

\[
vr = bk, \quad \lambda(v - 1) = r(k - 1)
\]

The first counts point-block incidences in two ways (\(v\) points, each in \(r\) blocks, equals \(b\) blocks, each with \(k\) points). The second counts pairs containing a given point in two ways. These are _Fisher's inequalities_—necessary but not sufficient conditions for existence.

### 1.1 Fisher's Inequality and Symmetric Designs

**Theorem 1.1 (Fisher's Inequality, 1940).** In any BIBD, \(b \geq v\). A design with \(b = v\) is called a _symmetric design_ (or _square design_). For a symmetric \((v, k, \lambda)\)-design, any two distinct blocks intersect in exactly \(\lambda\) points.

Symmetric designs are intimately connected to finite projective planes, Hadamard matrices, and difference sets. The parameters satisfy \(k(k-1) = \lambda(v-1)\).

### 1.2 Steiner Systems

A _Steiner system_ \(S(t, k, v)\) is a BIBD where every \(t\)-subset of points appears in exactly \(\lambda = 1\) block (each block has size \(k\)). The Fano plane is \(S(2, 3, 7)\). The _Steiner triple system_ \(S(2, 3, v)\) exists if and only if \(v \equiv 1 \text{ or } 3 \pmod{6}\) (Kirkman, 1847).

**Theorem 1.2 (Steiner systems with \(t \geq 3\)).** \(S(3, 4, 8)\) exists (the extended Hamming code design). \(S(4, 5, 11)\) and \(S(5, 6, 12)\) exist (the Mathieu designs, associated with the sporadic Mathieu groups \(M*{11}\) and \(M*{12}\)). \(S(5, 8, 24)\) exists (the _Witt design_, associated with the Mathieu group \(M\_{24}\) and the binary Golay code). No Steiner system with \(t \geq 6\) is known (other than trivial ones), and their nonexistence for large \(t\) is a major open problem related to the classification of finite simple groups.

## 2. Finite Projective Planes

A _finite projective plane_ of order \(n\) is a symmetric \((n^2 + n + 1, n + 1, 1)\)-design. It has \(v = n^2 + n + 1\) points and an equal number of lines. Every line contains \(n+1\) points, every point lies on \(n+1\) lines, and any two distinct lines intersect in exactly one point.

### 2.1 Construction from Finite Fields

For any prime power \(q = p^e\), there exists a projective plane of order \(q\), denoted \(\mathrm{PG}(2, q)\). Points are 1-dimensional subspaces of \(\mathbb{F}\_q^3\); lines are 2-dimensional subspaces. Incidence is containment. The number of points is \((q^3 - 1)/(q - 1) = q^2 + q + 1\).

**Theorem 2.1 (Bruck-Ryser-Chowla, 1949).** If a projective plane of order \(n \equiv 1 \text{ or } 2 \pmod{4}\) exists, then \(n\) is the sum of two squares. This eliminates \(n = 6, 14, 21, 22, \ldots\) as possible orders.

The existence of a projective plane of order 10 was a famous open problem, resolved negatively by Lam, Thiel, and Swiercz (1989) via massive computer search. The existence of a projective plane of order 12 remains open. The _prime power conjecture_ asserts that every finite projective plane has prime power order—this is one of the major unsolved problems in combinatorics.

## 3. Designs, Codes, and the Assmus-Mattson Theorem

The connection between designs and codes is mediated by the _incidence matrix_: the \(v \times b\) matrix \(A\) where \(A\_{ij} = 1\) if point \(i\) is in block \(j\), and \(0\) otherwise.

### 3.1 Codes from Designs

The row space (or column space) of \(A\) over a finite field \(\mathbb{F}\_p\) (where \(p\) divides \(k-\lambda\) or similar) generates a linear code. For symmetric designs, the code is self-orthogonal (or self-dual) under appropriate conditions.

**Theorem 3.1 (Assmus-Mattson, 1969).** Let \(C\) be a linear code over \(\mathbb{F}\_q\) of length \(n\) with minimum distance \(d\). If the number of distinct nonzero weights of the dual code \(C^\perp\) is at most \(d - t\), then the supports of the minimum-weight codewords of \(C\) (or \(C^\perp\)) form the blocks of a \(t\)-design.

This theorem is the key to extracting designs from codes—and vice versa. It applies spectacularly to the Golay codes:

- The binary Golay code \(G\_{23}\) of length 23, dimension 12, minimum distance 7. Its weight-7 codewords form an \(S(4, 7, 23)\) Steiner system.
- The extended binary Golay code \(G\_{24}\) (length 24, dimension 12, \(d = 8\)). Its weight-8 codewords form an \(S(5, 8, 24)\) Steiner system—the Witt design, one of the most symmetric structures in all of mathematics.

### 3.2 Projective Reed-Muller Codes

The _projective Reed-Muller codes_ \(\mathrm{PRM}(r, q)\) are codes defined on the points of the projective space \(\mathrm{PG}(d, q)\), with codewords being evaluations of homogeneous polynomials of degree \(r\). The minimum weight codewords of \(\mathrm{PRM}(1, q)\) (the simplex code) form a projective plane design: every pair of points determines a unique line (codeword support), making the code the dual of the Hamming code.

## 4. Applications in Experimental Design

The original motivation for block designs was the _design of experiments_ in agriculture and industry. Fisher wanted to compare \(v\) varieties of wheat across \(b\) blocks of land, where each block can grow only \(k\) varieties, and soil heterogeneity means blocks must be "balanced"—each variety appears equally often, and each pair of varieties appears together equally often across blocks, to eliminate confounding effects.

A BIBD achieves this: the balanced structure ensures that any difference in yield between varieties can be attributed to the variety, not to block effects. This principle of _variance reduction through balance_ extends to modern A/B testing (balanced randomization), clinical trials (crossover designs), and computer performance experiments (Latin square designs for testing multiple factors simultaneously).

### 4.1 Orthogonal Arrays and Fractional Factorials

An _orthogonal array_ \(\mathrm{OA}(N, k, s, t)\) is a generalization of Latin squares: an \(N \times k\) array with entries from an \(s\)-symbol alphabet such that in any \(t\) columns, every \(t\)-tuple of symbols appears equally often. Orthogonal arrays with \(t = 2\) (strength 2) are equivalent to _mutually orthogonal Latin squares_ (MOLS), which produce BIBDs. Orthogonal arrays of strength \(t\) are the basis of _fractional factorial designs_, where a small fraction of all possible factor combinations is tested, and main effects and low-order interactions can be estimated without confounding.

## 5. Hadamard Matrices and Difference Sets

A _Hadamard matrix_ of order \(m\) is an \(m \times m\) matrix \(H\) with entries \(\pm 1\) such that \(HH^\top = mI\). Hadamard matrices exist only for \(m = 1, 2\), or multiples of 4; the _Hadamard conjecture_ asserts that they exist for all multiples of 4.

A Hadamard matrix gives rise to a symmetric \((4t - 1, 2t - 1, t - 1)\)-design (the _Paley design_) and a \((4t, 2t, t)\)-symmetric design. The rows of a Hadamard matrix are orthogonal vectors and form an optimal binary code (the _Hadamard code_) with length \(m\), size \(2m\), and minimum distance \(m/2\)—meeting the Plotkin bound.

**Difference sets:** A \((v, k, \lambda)\)-_difference set_ in a group \(G\) of order \(v\) is a \(k\)-subset \(D \subseteq G\) such that every non-identity element of \(G\) can be expressed as \(d_1 d_2^{-1}\) with \(d_1, d_2 \in D\) in exactly \(\lambda\) ways. The translates of \(D\) form the blocks of a symmetric design on which \(G\) acts regularly. The Singer difference set in \(\mathrm{PG}(2, q)\) gives the projective plane of order \(q\), and its code is the simplex code.

## 6. The Wilbrink-Brouwer Theorem and the Uniqueness of Designs

Many designs are characterized by their parameters up to isomorphism—or at least, only a few non-isomorphic designs exist for given parameters. The _Wilbrink-Brouwer theorem_ provides powerful uniqueness criteria.

**Theorem 6.1 (Wilbrink-Brouwer, 1983).** Let \(\mathcal{D}\) be a symmetric \((v, k, \lambda)\)-design with the property that its derived design (the design induced on the points of a block) is itself a symmetric design. Then, under additional arithmetic conditions on \(v\) and \(k\), the design is uniquely determined as either a projective geometry or a Hadamard design.

For the \((7, 3, 1)\)-design (the Fano plane), there is exactly one design up to isomorphism. For the \((16, 6, 2)\)-symmetric design, there are exactly three non-isomorphic designs. For the \((41, 16, 6)\)-design (the projective plane of order 4), there is exactly one. Classification is done via exhaustive search combined with algebraic constraints from the automorphism group.

### 6.1 Automorphism Groups and the Mathieu Connection

The automorphism group of the Witt design \(S(5, 8, 24)\) is the Mathieu group \(M\_{24}\), one of the 26 sporadic finite simple groups. Its order is:

\[
|M\_{24}| = 2^{10} \cdot 3^3 \cdot 5 \cdot 7 \cdot 11 \cdot 23 = 244,823,040
\]

\(M\_{24}\) is 5-transitive on the 24 points—for any two ordered 5-tuples of distinct points, there is an automorphism mapping one to the other. This extreme symmetry is why the Golay code and the Witt design found applications in the Voyager space missions (error correction for deep-space communication) and in the design of the Leech lattice (the densest sphere packing in 24 dimensions).

**Theorem 6.2 (Cameron, 1976).** The only nontrivial 5-transitive permutation groups are the symmetric groups \(S*n\) (\(n \geq 5\)), the alternating groups \(A_n\) (\(n \geq 7\)), and the Mathieu groups \(M*{12}\) and \(M\_{24}\). Thus, highly symmetric designs are rare, and their automorphism groups are among the most exceptional objects in finite group theory.

## 7. Mutually Orthogonal Latin Squares (MOLS) and Their Computational Complexity

A _Latin square_ of order \(n\) is an \(n \times n\) array filled with \(n\) symbols such that each symbol appears exactly once in each row and column. Two Latin squares \(L\) and \(M\) are _orthogonal_ if the \(n^2\) ordered pairs \((L*{ij}, M*{ij})\) are all distinct.

**Theorem 7.1 (Bose-Shrikhande-Parker, 1959-1960).** There exists a pair of mutually orthogonal Latin squares (MOLS) of order \(n\) for all \(n \neq 2, 6\). The Euler conjecture (that no pair exists for \(n = 6, 10, 14, \ldots\)) was spectacularly disproven by Bose, Shrikhande, and Parker, who constructed a pair of MOLS of order 10.

The construction of MOLS is equivalent to the existence of an orthogonal array \(\mathrm{OA}(n^2, 4, n, 2)\), which in turn yields a BIBD with parameters \((n^2, 2n(n-1), 2n-2, n-1, 2)\). For \(n = q\) (a prime power), MOLS can be constructed using the finite field \(\mathbb{F}_q\): label rows and columns with field elements, and define \(L^{(k)}_{ij} = k \cdot i + j\) for \(k = 1, \ldots, q-1\). This yields \(q-1\) MOLS of order \(q\)—the maximum possible number (since there are only \(n-1\) pairwise orthogonal Latin squares of order \(n\)).

### 7.1 MOLS in Computer Science

MOLS are not just combinatorial curiosities. They are used in:

- **Error-correcting codes:** The rows of a set of \(t\) MOLS of order \(n\) form an orthogonal array \(\mathrm{OA}(n^2, t+2, n, 2)\), which corresponds to a code with minimum distance \(t+1\).
- **Cryptographic threshold schemes:** An \(\mathrm{OA}(n^2, k, n, 2)\) can be used to construct a \((k-1, n)\)-threshold secret sharing scheme via the dual array.
- **Load balancing in distributed hash tables:** MOLS provide collision-free hash functions for distributing data across multiple dimensions of a storage cluster.

```python
# Python: Construct MOLS of prime order p using finite field arithmetic
def mols_prime(p):
    # Returns p-1 mutually orthogonal Latin squares of order p
    mols_list = []
    for k in range(1, p):
        square = [[(k * i + j) % p for j in range(p)] for i in range(p)]
        mols_list.append(square)
    return mols_list

# Verify orthogonality
def are_orthogonal(L1, L2):
    pairs = {(L1[i][j], L2[i][j]) for i in range(len(L1)) for j in range(len(L1))}
    return len(pairs) == len(L1) ** 2
```

## 8. t-Designs, Packings, and Coverings: Beyond BIBDs

The definition of a design generalizes to _t-designs_, where every \(t\)-subset of points appears in exactly \(\lambda\) blocks.

**Definition 8.1 (t-Design).** A \(t\)-\((v, k, \lambda)\) design is a collection of \(k\)-subsets (blocks) of a \(v\)-set such that every \(t\)-subset of points is contained in exactly \(\lambda\) blocks.

Every \(t\)-design is also an \(s\)-design for any \(s < t\), with derived \(\lambda_s = \lambda \binom{v-s}{t-s} / \binom{k-s}{t-s}\). The combinatorial explosion of large designs limits explicit constructions, but infinite families exist:

- **Witt designs:** \(5\)-\((12, 6, 1)\) and \(5\)-\((24, 8, 1)\).
- **Cameron designs:** \(3\)-\((2^{2m+1}, 2^{2m} - 2^{m-1}, (2^{2m-1} - 2^{m-1})(2^{2m-2} - 1) / 3)\) from quadratic forms over \(\mathbb{F}\_2\).

**Theorem 8.1 (Teirlinck, 1987).** Nontrivial \(t\)-designs exist for all \(t\). The construction is non-constructive (probabilistic method), and explicit constructions for general \(t\) remain an area of active research. For cryptographic applications, explicit \(t\)-designs with large \(t\) and manageable block size are of particular interest.

### 8.1 Covering Designs and the Lottery Problem

A _covering design_ \(C(v, k, t)\) is a minimum number of \(k\)-subsets (blocks) such that every \(t\)-subset is contained in at least one block. This is the "lottery problem": what is the smallest number of \(k\)-tickets needed to guarantee matching at least \(t\) numbers? For \(C(49, 6, 3)\), the known minimum is between 163 and 173—a problem relevant to combinatorial testing and fault detection in configurable software systems.

## 9. Designs in Cryptography: Authentication Codes and Secret Sharing

Combinatorial designs underpin several cryptographic primitives. An _authentication code_ (A-code) with secrecy can be constructed from an orthogonal array: the rows are the transmitted messages, the columns are the encoding rules (keys), and the property that any \(t\) columns contain each \(t\)-tuple equally often translates into perfect secrecy against coalition attacks of size up to \(t-1\).

**Theorem 9.1 (Stinson, 1992).** A \(t\)-\((v, k, \lambda)\) design with suitable \(\lambda\) can be transformed into a \((t-1, n)\)-threshold secret sharing scheme: the secret is a point, the shares are the blocks containing that point, and any \(t-1\) shares reveal no information about the secret (by the balance property), while \(t\) blocks intersect uniquely at the secret point.

The Witt design \(S(5, 8, 24)\) gives a 4-out-of-759 threshold scheme with share size 8 bits per share—information-theoretically optimal. These connections illustrate how the pure mathematics of combinatorial balance translates directly into practical security guarantees.

## 11. Spherical Designs, Numerical Integration, and the Kissing Number Problem

While block designs live in finite geometry, _spherical designs_ (Delsarte, Goethals, and Seidel, 1977) live on the surface of the sphere S^{d-1} in R^d. They provide optimal quadrature rules for numerical integration and are deeply connected to the kissing number problem, error-correcting codes, and the Leech lattice.

### 11.1 Definition and the Fisher-Type Lower Bound

**Definition 11.1 (Spherical t-Design).** A finite set X on the unit sphere S^{d-1} is a _spherical t-design_ if, for every polynomial p of total degree <= t, the average of p over X equals the average of p over the sphere (with respect to the uniform measure):

(1/|X|) sum*{x in X} p(x) = (1/omega_d) int*{S^{d-1}} p(x) dsigma(x)

where omega_d is the surface area of S^{d-1}. Intuitively, a spherical t-design is a finite set of points on the sphere that exactly integrates polynomials of degree up to t.

**Theorem 11.1 (Delsarte-Goethals-Seidel Lower Bound).** Any spherical t-design in S^{d-1} must have cardinality at least:

|X| >= C(d + floor(t/2) - 1, floor(t/2)) + C(d + floor((t-1)/2) - 1, floor((t-1)/2))

where C(n, k) is the binomial coefficient. Designs achieving this bound are called _tight_ spherical designs.

Tight spherical designs are extremely rare. The only known tight spherical t-designs for t >= 3 correspond to: regular simplexes (t=3), cross polytopes (t=3), the 600-cell in R^4 (t=11, |X|=120), the E_8 root system (t=7, |X|=240), and the minimal vectors of the Leech lattice in R^{24} (t=11, |X|=196560). The existence of a tight 5-design on 27 points in R^13 was a famous conjecture resolved by the theory of strongly regular graphs and the McLaughlin graph.

### 11.2 Quadrature and Cubature Formulas

In numerical integration on the sphere, a spherical t-design provides an equal-weight quadrature rule:

int*{S^{d-1}} f(x) dsigma(x) approx (omega_d / |X|) sum*{x in X} f(x)

with error bounded by O(|X|^{-t/(d-1)}) for smooth f. This is _optimal_ among equal-weight rules by the Sobolev embedding theorem. In practice, spherical designs provide quadrature nodes for problems in global illumination (rendering), molecular dynamics (orientational averaging), and computer vision (rotation averaging via SO(3) quadrature).

### 11.3 The Kissing Number Problem and Error-Correcting Codes

The _kissing number_ k(d) is the maximum number of non-overlapping unit spheres that can simultaneously touch a central unit sphere in R^d. This is intimately related to spherical codes: placing points on S^{d-1} with minimal angular separation at least 60 degrees.

The known values: k(1) = 2, k(2) = 6, k(3) = 12 (Newton-Gregory problem, resolved by Schutte and van der Waerden, 1953), k(4) = 24 (Musin, 2003), k(8) = 240 (from E_8, Viazovska via linear programming bounds), k(24) = 196560 (from the Leech lattice, Cohn and Kumar, 2004).

**Theorem 11.2 (Delsarte's Linear Programming Bound for Spherical Codes).** Let A(theta) be the maximum size of a spherical code on S^{d-1} with minimal angular separation theta. Then A(theta) is bounded above by the optimal value of a linear program whose constraints involve Gegenbauer polynomials (the zonal spherical harmonics). This LP bound is tight for the E_8 and Leech lattice kissing configurations, yielding their optimality.

The connection to error-correcting codes: the LP bound for spherical codes is the continuous analogue of the Delsarte LP bound for binary codes (which bounds A(n, d) -- the maximum size of a binary code of length n and minimum distance d). Both use the same algebraic framework of association schemes and orthogonal polynomials.

## 12. Association Schemes and the Algebraic Theory of Designs

The deepest unification of designs and codes comes from the theory of _association schemes_ (Bose and Mesner, 1959), which provide an algebraic framework encompassing block designs, strongly regular graphs, orthogonal arrays, and group-divisible designs.

### 12.1 Definition and the Bose-Mesner Algebra

**Definition 12.1 (Association Scheme).** A d-class _association scheme_ on a finite set X is a partition of X x X into d+1 symmetric relations R_0, R_1, ..., R_d such that:

- R_0 = {(x, x) : x in X} (the identity relation).
- For any (x, y) in R_k, the number of z such that (x, z) in R_i and (z, y) in R_j depends only on i, j, k, not on the choice of x and y.

These _intersection numbers_ p*{ij}^k completely determine the scheme. The adjacency matrices A_0, A_1, ..., A_d (where (A_i)*{x,y} = 1 if (x,y) in R*i) span a (d+1)-dimensional commutative algebra over the reals -- the \_Bose-Mesner algebra*.

**Theorem 12.1 (Spectral Decomposition of the Bose-Mesner Algebra).** The Bose-Mesner algebra has a unique basis of primitive idempotents E_0, E_1, ..., E_d (projectors onto common eigenspaces of all A_i). The change-of-basis matrices P (eigenvalues) and Q (dual eigenvalues) satisfy:

A*i = sum*{j=0}^d P*{ji} E_j, E_j = (1/|X|) sum*{i=0}^d Q\_{ij} A_i

The P and Q matrices satisfy the orthogonality relations that are the algebraic heart of design theory. A _t-design_ in the association scheme is a subset Y of X such that for all j with 1 <= j <= t, the characteristic vector of Y is orthogonal to E_j (lies in the span of E_0 alone).

### 12.2 The Hamming and Johnson Schemes

Two association schemes are fundamental for codes and designs:

- **Hamming scheme H(n, q)**: X = F_q^n, (x, y) in R_i iff d_H(x, y) = i. The eigenvalues are Krawtchouk polynomials. Codes in H(n, q) are the classical error-correcting codes.
- **Johnson scheme J(n, w)**: X = all w-subsets of an n-set, (A, B) in R_i iff |A intersect B| = w - i. The eigenvalues are Hahn polynomials. Designs in J(n, w) are the classical t-designs (Definition 1.1 of this post).

Delsarte's theory (1973) showed that the LP bound for codes and the Fisher-type inequalities for designs are both consequences of the positive-semidefiniteness of the Bose-Mesner algebra elements restricted to subsets.

## 13. Network Coding and Subspace Designs

A striking modern application of combinatorial designs to computer science is _network coding_, where intermediate nodes in a network combine packets algebraically rather than simply forwarding them. The theory of _subspace codes_ -- codes in the projective geometry PG(n-1, q) whose codewords are subspaces of a vector space -- provides optimal solutions for random linear network coding.

### 13.1 The Subspace Channel and the Koetter-Kschischang Codes

In random linear network coding (RLNC), a source injects packets (vectors in F*q^n) into the network. Each intermediate node transmits random linear combinations of received packets. The receiver collects such combinations and must recover the original packets. The channel is not a classical symbol-error channel but a \_subspace channel*: the receiver observes the row space of a matrix whose rows are the received linear combinations.

**Definition 13.1 (Subspace Code).** A _subspace code_ C in PG(n-1, q) is a collection of subspaces of F*q^n. The \_subspace distance* between two subspaces U, V is:

d_S(U, V) = dim(U) + dim(V) - 2 dim(U cap V)

This is a metric on the set of subspaces. A subspace code with minimum subspace distance d can correct up to floor((d-1)/2) "errors" where an error corresponds to the insertion of an adversarial packet (which increases the dimension of the received subspace) or the deletion of a legitimate packet.

**Theorem 13.1 (Koetter-Kschischang Code Construction, 2008).** Let alpha be a primitive element of F\_{q^m}. Define the _lifted MRD (Maximum Rank Distance) code_:

C = { row space of [ I_k A ] : A in M\_{k, n-k}(F_q) with rank(A) achieving the Singleton bound for rank-metric codes }

The codewords are k-dimensional subspaces, and the subspace distance between any two codewords is at least 2(k - d_R + 1) where d_R is the minimum rank distance of the underlying MRD code. This construction achieves the Singleton bound for subspace codes asymptotically.

### 13.2 q-Analogs of Designs and the q-Analog of the Fano Plane

The _q-analog_ of a combinatorial design replaces subsets by subspaces and cardinalities by dimensions over F*q. The \_q-analog of a Steiner system S(t, k, n)* is a collection B of k-dimensional subspaces of F_q^n such that every t-dimensional subspace is contained in exactly one subspace from B.

The existence of such q-Steiner systems is a major open problem. The smallest non-trivial case -- the q-analog of the Fano plane, a q-Steiner system S(2, 3, 7) -- was open for decades and finally constructed by Braun, Etzion, Ostergard, Vardy, and Wassermann (2016) using computational methods for q=2. The construction uses the theory of _cyclic subspace codes_ and the Singer cycle in GL(7, 2). The resulting object is a collection of 381 3-dimensional subspaces of F_2^7 (out of the total B(7,3)\_2 = 11811 such subspaces) such that every 2-dimensional subspace is contained in exactly one of them.

### 13.3 Batch Codes and Private Information Retrieval

A _batch code_ (Ishai, Kushilevitz, Ostrovsky, and Sahai, 2004) is a combinatorial design for distributed storage. Data items are encoded across n servers such that any k items can be retrieved by reading at most t items from each server. Batch codes generalize both error-correcting codes (robustness against server failures) and combinatorial designs (balanced retrieval patterns).

The construction of optimal batch codes uses _balanced incomplete block designs_ (BIBDs): distribute data items according to the incidence matrix of a BIBD, where rows are data items and columns are servers. The replication factor r in the BIBD determines the fault tolerance, and the block size k determines the retrieval efficiency. The interplay between the design parameters (v, b, r, k, lambda) and the batch code parameters (n, m, k, t) is a perfect example of how classical combinatorial design theory finds new life in modern distributed systems.

## 14. Locally Recoverable Codes and the Role of Incidence Structures

In large-scale distributed storage systems (e.g., Hadoop HDFS, Azure Storage, Facebook's f4), data is encoded with erasure codes for durability. Traditional Reed-Solomon codes require reading k blocks to reconstruct a single lost block -- expensive for repairs involving terabytes of data. _Locally recoverable codes_ (LRCs) allow reconstruction of a lost block by reading only a small number r of other blocks (the _locality_ parameter).

### 14.1 The Locality-Bandwidth Tradeoff

**Definition 14.1 (Locally Recoverable Code).** An (n, k, r)-LRC over F*q is a linear code of length n and dimension k such that for each coordinate i, there exists a set R_i of at most r other coordinates (a \_recovery set*) such that the value at coordinate i can be recovered from the values at coordinates in R_i.

The _recovery set_ structure forms a _hypergraph_ (or incidence structure) on the coordinate set. The constraints are:

- For each coordinate i, there is a hyperedge {i} union R_i.
- The global code must have minimum distance d satisfying the _Singleton-like bound_:

d <= n - k - ceil(k/r) + 2

This bound (Gopalan, Huang, Simitci, Yekhanin, 2012) generalizes the classical Singleton bound d <= n - k + 1, where the penalty term ceil(k/r) reflects the tension between local recoverability and global fault tolerance.

### 14.2 Combinatorial Designs for Recovery Set Construction

Optimal LRCs achieving the bound are constructed from incidence structures:

- **Steiner systems S(2, r+1, n)**: Each coordinate belongs to exactly one recovery set of size r+1, giving a regular LRC where recovery sets partition the coordinates.
- **Resolvable designs**: A _resolvable_ BIBD is one whose blocks can be partitioned into parallel classes, each of which partitions the point set. Each parallel class defines the local parity checks for a group of coordinates.
- **Partial geometries**: A partial geometry pg(K, R, T) provides LRCs where each coordinate participates in exactly K recovery sets, each recovery set has size R, and any two coordinates appear together in at most T recovery sets. The dual of this construction gives LRCs with multiple disjoint recovery sets per coordinate (availability).

### 14.3 The Tamo-Barg Construction via Polynomial Evaluation

**Theorem 14.1 (Tamo-Barg Optimal LRC, 2014).** Let r+1 divide n, and let F_q have a subgroup H of order r+1. Partition the evaluation points into n/(r+1) cosets of H. Choose a polynomial f(x) of degree < k + ceil(k/r) such that f restricted to each coset has degree < r. The evaluations of such f on all n points form an (n, k, r)-LRC achieving the optimal distance bound.

_Construction._ The key algebraic insight: on each coset a + H, the polynomial f(x) restricted to that coset is a polynomial in (x-a)^{r+1} of degree < k/r, so its evaluation at any r points suffices to interpolate the value at the remaining point via Lagrange interpolation on the coset.

This construction uses the structure of a _group divisible design_ where the groups are the cosets of H and the blocks are implicit in the low-degree polynomial interpolation property. It is currently the most widely deployed LRC construction, used in Microsoft Azure Storage (with r=6) and in Facebook's HDFS-RAID (with r=10).

The deep connection between combinatorial incidence structures and locally recoverable codes demonstrates that classical design theory is not merely a mathematical curiosity -- it provides the essential scaffolding for the fault-tolerant storage systems that underpin the modern cloud. From Fano planes to Azure Storage, the arc of combinatorial design bends toward practical impact.

The algebraic elegance of these constructions -- where polynomial interpolation over finite fields meets the incidence geometry of Steiner systems -- exemplifies the kind of cross-pollination between pure mathematics and systems engineering that characterizes the best work in theoretical computer science.

These structures continue to inspire new code constructions with applications to distributed storage, private information retrieval, and secure multiparty computation.

## 15. Summary

Combinatorial design theory is the mathematics of balanced arrangement. Block designs generalize the symmetry of finite projective planes to arbitrary parameters, constrained by Fisher's inequality and the Bruck-Ryser-Chowla theorem. Steiner systems are designs with \(\lambda = 1\), and their existence is linked to the sporadic simple groups. The Assmus-Mattson theorem bridges designs and codes, revealing that the most exceptional codes (Golay, Reed-Muller) are designs in another language. MOLS connect combinatorics to finite fields and provide practical constructions for codes, secret sharing, and load balancing.

For the computer scientist, designs provide:

- Error-correcting codes with optimal distance properties (Hadamard codes, Golay codes).
- Experimental designs for fair and efficient performance benchmarking.
- Constructions for cryptographic primitives (difference sets give sequences with ideal autocorrelation; Steiner systems give threshold schemes).
- Combinatorial objects for derandomization (expander graphs, extractors, and Ramsey-theoretic constructions).

To go deeper, the classic text is Beth, Jungnickel, and Lenz's _Design Theory_. For the coding theory connection, MacWilliams and Sloane's _The Theory of Error-Correcting Codes_ remains the bible. And for finite geometry, Dembowski's _Finite Geometries_ is the authoritative reference.
