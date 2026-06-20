---
title: "Markov Chains for Computer Science: MCMC, Mixing Times, and Randomized Algorithms"
description: "A rigorous treatment of Markov chains from a computer science perspective—Metropolis-Hastings, coupling bounds, spectral gaps, and the role of rapid mixing in modern randomized algorithms."
date: "2022-01-31"
author: "Leonardo Benicio"
tags: ["markov-chains", "mcmc", "mixing-times", "randomized-algorithms", "monte-carlo", "probability"]
categories: ["theory", "mathematics"]
draft: false
cover: "static/images/blog/markov-chains-mcmc-mixing-times.png"
coverAlt: "Diagram of a Markov chain state space with transition probabilities and mixing time illustration"
---

If you have ever used PageRank, trained a Boltzmann machine, performed Bayesian inference with Stan, or sampled from a high-dimensional posterior distribution, you have relied on Markov chains. Specifically, you have relied on the fact that a carefully constructed Markov chain, after running for a sufficient number of steps, produces samples from a desired target distribution—even when that distribution is intractable to normalize or too complex to sample from directly. This is the magic of Markov Chain Monte Carlo (MCMC), and it rests on a delicate mathematical foundation: the theory of mixing times, spectral gaps, and ergodicity.

This post treats Markov chains rigorously from a computer science perspective. We will define the fundamental concepts—irreducibility, aperiodicity, stationarity, reversibility—and then develop the machinery for bounding mixing times: coupling arguments, the spectral gap, conductance, and the path method. Along the way, we will see how these ideas power algorithms for counting, sampling, and optimization that would be impossible with deterministic methods.

## 1. Markov Chains: Definitions and Basic Properties

A _Markov chain_ on a finite or countable state space \(\Omega\) is a sequence of random variables \((X*t)*{t \geq 0}\) satisfying the Markov property:

\[
\mathbb{P}(X*{t+1} = y \mid X_t = x, X*{t-1} = x*{t-1}, \ldots, X_0 = x_0) = \mathbb{P}(X*{t+1} = y \mid X_t = x)
\]

The future depends on the past only through the present. The chain is _time-homogeneous_ if the transition probability \(P(x, y) = \mathbb{P}(X\_{t+1} = y \mid X_t = x)\) does not depend on \(t\). We work exclusively with time-homogeneous chains.

The transition matrix \(P\) is a stochastic matrix: \(P(x, y) \geq 0\) for all \(x, y\), and \(\sum_y P(x, y) = 1\) for all \(x\). The \(t\)-step transition probabilities are given by \(P^t(x, y)\), the \((x, y)\)-entry of the \(t\)-th power of \(P\).

**Definition 1.1.** A distribution \(\pi\) on \(\Omega\) is _stationary_ for \(P\) if \(\pi P = \pi\), i.e., for all \(y\):

\[
\sum\_{x \in \Omega} \pi(x) P(x, y) = \pi(y)
\]

A chain is _reversible_ with respect to \(\pi\) if it satisfies the _detailed balance equations_:

\[
\pi(x) P(x, y) = \pi(y) P(y, x) \quad \forall x, y
\]

Detailed balance implies stationarity: \(\sum_x \pi(x) P(x, y) = \sum_x \pi(y) P(y, x) = \pi(y)\). Reversibility means that, at stationarity, the chain looks the same forward and backward in time.

### 1.1 Irreducibility and Aperiodicity

**Definition 1.2.** A Markov chain is _irreducible_ if for all \(x, y \in \Omega\), there exists \(t \geq 0\) such that \(P^t(x, y) > 0\). The chain is _aperiodic_ if for all \(x\), the greatest common divisor of \(\{t \geq 1 : P^t(x, x) > 0\}\) equals 1.

**Theorem 1.1 (Fundamental Theorem of Markov Chains).** If a finite-state Markov chain is irreducible and aperiodic, then it has a unique stationary distribution \(\pi\), and for any initial distribution \(\mu\),

\[
\lim\_{t \to \infty} \mu P^t = \pi
\]

In other words, the chain _converges_ to \(\pi\) regardless of where it starts. The question of _how fast_ it converges is the subject of mixing time theory.

## 2. Mixing Times: How Fast Does the Chain Converge?

Define the _total variation distance_ between two distributions \(\mu\) and \(\nu\) on \(\Omega\):

\[
\|\mu - \nu\|_{\mathrm{TV}} = \frac{1}{2} \sum_{x \in \Omega} |\mu(x) - \nu(x)| = \max\_{A \subseteq \Omega} |\mu(A) - \nu(A)|
\]

The _mixing time_ \(t\_{\mathrm{mix}}(\varepsilon)\) is the smallest \(t\) such that for all starting states \(x\),

\[
\|P^t(x, \cdot) - \pi\|\_{\mathrm{TV}} \leq \varepsilon
\]

Typically we take \(\varepsilon = 1/4\) and define \(t*{\mathrm{mix}} = t*{\mathrm{mix}}(1/4)\). The choice of \(1/4\) is conventional; any \(\varepsilon < 1/2\) gives mixing times that differ by at most a constant factor (by submultiplicativity of the total variation distance).

### 2.1 Coupling Bounds

_Coupling_ is the most intuitive technique for bounding mixing times. A coupling of two distributions \(\mu\) and \(\nu\) is a pair of random variables \((X, Y)\) such that \(X \sim \mu\), \(Y \sim \nu\), and the joint distribution can be arbitrary. The _coupling inequality_ states:

\[
\|\mu - \nu\|\_{\mathrm{TV}} \leq \mathbb{P}(X \neq Y)
\]

For Markov chains, we construct a _Markovian coupling_: two copies of the chain \((X_t, Y_t)\) that each evolve according to \(P\) individually, but their transitions may be correlated. If we can arrange that once \(X_t = Y_t\), they stay together forever, then:

\[
\|P^t(x, \cdot) - P^t(y, \cdot)\|_{\mathrm{TV}} \leq \mathbb{P}_{x,y}(\tau\_{\mathrm{couple}} > t)
\]

where \(\tau\_{\mathrm{couple}} = \min\{t : X_t = Y_t\}\).

**Example: Random walk on the hypercube.** The state space is \(\{0, 1\}^n\). At each step, pick a coordinate uniformly at random and flip it (with probability 1/2). This chain is reversible with respect to the uniform distribution. A coupling: both chains pick the _same_ coordinate and attempt the _same_ new value. The Hamming distance between the two copies evolves as a random walk on \(\{0, 1, \ldots, n\}\) that is biased toward 0. The coupling time is \(O(n \log n)\), giving \(t\_{\mathrm{mix}} = O(n \log n)\).

### 2.2 Spectral Gap

The spectral method relates mixing time to the eigenvalues of \(P\). For a reversible chain, \(P\) is self-adjoint with respect to the inner product \(\langle f, g \rangle\_\pi = \sum_x \pi(x) f(x) g(x)\). Its eigenvalues satisfy:

\[
1 = \lambda*1 > \lambda_2 \geq \cdots \geq \lambda*{|\Omega|} \geq -1
\]

(assuming irreducibility and aperiodicity, so \(\lambda*2 < 1\)). The *absolute spectral gap* is \(\gamma*\* = 1 - \max\{\lambda*2, |\lambda*{|\Omega|}|\}\). When the chain is lazy (\(P(x, x) \geq 1/2\) for all \(x\)), all eigenvalues are nonnegative, and the spectral gap is \(\gamma = 1 - \lambda_2\).

**Theorem 2.1 (Spectral mixing bound).** For a reversible, lazy Markov chain,

\[
\|P^t(x, \cdot) - \pi\|\_{\mathrm{TV}} \leq \frac{1}{2\sqrt{\pi(x)}} e^{-\gamma t}
\]

Thus \(t*{\mathrm{mix}}(\varepsilon) \leq \frac{1}{\gamma} \log\left(\frac{1}{2\varepsilon \sqrt{\pi*{\min}}}\right)\), where \(\pi\_{\min} = \min_x \pi(x)\).

The spectral gap \(\gamma\) is the fundamental parameter governing mixing. Computing it exactly is usually intractable, but we can bound it using geometric and functional inequalities.

### 2.3 Conductance and the Cheeger Inequality

The _conductance_ (or _bottleneck ratio_) of a set \(S \subseteq \Omega\) is:

\[
\Phi(S) = \frac{Q(S, S^c)}{\pi(S)} = \frac{\sum\_{x \in S, y \notin S} \pi(x) P(x, y)}{\pi(S)}
\]

The _conductance of the chain_ is \(\Phi*\* = \min*{S : \pi(S) \leq 1/2} \Phi(S)\).

**Theorem 2.2 (Cheeger inequality for Markov chains).** For a reversible chain,

\[
\frac{\Phi*\*^2}{2} \leq \gamma \leq 2\Phi*\*
\]

This is the Markov chain analogue of the Cheeger inequality for manifolds. It relates the spectral gap (a global, analytic quantity) to the conductance (a combinatorial, cut-based quantity). The Cheeger inequality is the foundation for proving rapid mixing via canonical paths.

### 2.4 Canonical Paths

The _canonical paths_ method (Jerrum and Sinclair, 1989) bounds the conductance by constructing, for each pair \((x, y)\), a path in the state graph, and bounding the _congestion_—how many paths pass through each edge. Formally, given a family of paths \(\{\Gamma\_{xy}\}\), the _congestion parameter_ is:

\[
\rho = \max*{\text{edge } e} \frac{1}{Q(e)} \sum*{x, y : e \in \Gamma*{xy}} \pi(x) \pi(y) |\Gamma*{xy}|
\]

where \(Q(e) = \pi(u) P(u, v)\) for edge \(e = (u, v)\), and \(|\Gamma\_{xy}|\) is the length of the path. Then:

\[
\Phi\_\* \geq \frac{1}{2\rho}
\]

This yields a bound on the spectral gap via the Cheeger inequality, and hence on the mixing time. The canonical paths method was used to prove that the Metropolis algorithm for sampling matchings in a graph mixes rapidly—a result that resolved a longstanding open problem in approximate counting.

## 3. The Metropolis-Hastings Algorithm

The _Metropolis-Hastings algorithm_ (Metropolis et al., 1953; Hastings, 1970) is the workhorse of MCMC. Given a target distribution \(\pi\) known up to a normalizing constant, it constructs a reversible Markov chain with stationary distribution \(\pi\).

### 3.1 The Algorithm

Start with a _proposal chain_ (a symmetric Markov chain with proposal probabilities \(K(x, y) = K(y, x)\)). At each step, given current state \(X_t = x\):

1. Propose a new state \(y\) according to \(K(x, \cdot)\).
2. Accept the proposal with probability:

\[
\alpha(x, y) = \min\left\{1, \frac{\pi(y)}{\pi(x)}\right\}
\]

If accepted, set \(X*{t+1} = y\); otherwise, set \(X*{t+1} = x\).

The transition matrix is:

\[
P(x, y) = \begin{cases}
K(x, y) \cdot \min\left\{1, \frac{\pi(y)}{\pi(x)}\right\} & \text{if } y \neq x \\
1 - \sum\_{z \neq x} P(x, z) & \text{if } y = x
\end{cases}
\]

**Proposition 3.1.** The Metropolis chain is reversible with respect to \(\pi\).

_Proof._ For \(x \neq y\):

\[
\pi(x) P(x, y) = \pi(x) K(x, y) \min\left\{1, \frac{\pi(y)}{\pi(x)}\right\} = K(x, y) \min\{\pi(x), \pi(y)\}
\]

which is symmetric in \(x\) and \(y\) (since \(K\) is symmetric), giving \(\pi(x) P(x, y) = \pi(y) P(y, x)\). ∎

### 3.2 Gibbs Sampling

The _Gibbs sampler_ (or _heat bath_) is a special case of Metropolis-Hastings where proposals always target the conditional distributions. For a multivariate distribution \(\pi(x*1, \ldots, x_d)\), the Gibbs sampler updates one coordinate at a time by sampling from the full conditional \(\pi(x_i \mid x*{-i})\). The acceptance probability is always 1.

Gibbs sampling is particularly natural for graphical models (Bayesian networks, Markov random fields), where the full conditionals simplify due to the Markov structure. The deterministic scan Gibbs sampler updates coordinates in a fixed order; the random scan Gibbs sampler picks a coordinate uniformly at random.

## 4. Mixing Time Bounds via Coupling for MCMC

The analysis of MCMC mixing times typically proceeds in two steps: (1) construct a coupling or canonical paths argument to bound the mixing time, and (2) verify that the bound is polynomial in the problem size.

### 4.1 Path Coupling

_Path coupling_ (Bubley and Dyer, 1997) simplifies coupling arguments. Instead of coupling all pairs of states, it suffices to couple _adjacent_ states (in some graph structure) and show that the expected distance between coupled states decreases by a constant factor per step.

**Theorem 4.1 (Path Coupling).** Let \(\delta\) be a metric on \(\Omega\) taking integer values, with maximum distance \(D\). Suppose for each pair of states \((x, y)\) with \(\delta(x, y) = 1\), there exists a coupling such that:

\[
\mathbb{E}[\delta(X_1, Y_1) \mid X_0 = x, Y_0 = y] \leq (1 - \alpha) \delta(x, y)
\]

for some \(\alpha > 0\). Then \(t\_{\mathrm{mix}} \leq \frac{1}{\alpha} \log(D)\).

This theorem is remarkably powerful: local contraction implies global rapid mixing.

### 4.2 Rapid Mixing for the Hard-Core Model

The _hard-core model_ on a graph \(G = (V, E)\) with fugacity \(\lambda > 0\) is a probability distribution over independent sets \(I\) of \(G\):

\[
\pi(I) \propto \lambda^{|I|}
\]

Sampling from this distribution is a fundamental problem in statistical physics and approximate counting. The Metropolis chain for the hard-core model: pick a vertex \(v\) uniformly at random, and if \(v\) has no neighbors in the current independent set \(I\), add \(v\) to \(I\) with probability \(\lambda/(1+\lambda)\), or remove \(v\) if present.

Using path coupling, one can prove that this chain mixes rapidly when \(\lambda < \frac{1}{\Delta - 1}\) (where \(\Delta\) is the maximum degree of \(G\)). This is precisely the regime where the hard-core model exhibits no long-range correlations (the uniqueness regime of the Gibbs measure).

## 5. Applications in Randomized Algorithms

### 5.1 Approximate Counting via Sampling

The _Jerrum-Valiant-Vazirani (JVV) reduction_ shows that for self-reducible counting problems, approximate counting is equivalent to approximate sampling. Specifically, for the number of satisfying assignments of a DNF formula, or the number of proper colorings of a graph, if we can sample approximately uniformly, we can count approximately—and vice versa.

MCMC provides the sampling side: run a rapidly mixing Markov chain whose stationary distribution is uniform over the structure of interest, and output the state after the mixing time. This yields a _fully polynomial randomized approximation scheme_ (FPRAS) for many #P-complete counting problems, including the number of matchings in a graph (the _permanent_ problem).

### 5.2 Simulated Annealing and Optimization

_Simulated annealing_ runs the Metropolis algorithm with a _temperature parameter_ \(T\) that decreases over time. The stationary distribution at temperature \(T\) is \(\pi_T(x) \propto e^{-f(x)/T}\), where \(f\) is the objective function to minimize. As \(T \to 0\), \(\pi_T\) concentrates on the global minima of \(f\). The cooling schedule must be slow enough for the chain to stay close to equilibrium at each temperature.

Simulated annealing is a generic optimization heuristic, but with rigorous convergence guarantees when the cooling schedule is logarithmic in time: \(T_t = c / \log t\) for sufficiently large \(c\). In practice, faster cooling often works but without guarantees.

### 5.3 Volume Estimation and the Dikin Walk

Computing the volume of a convex body in high dimensions is a classic problem. The Dikin walk is a Markov chain that samples uniformly from a convex body using barrier-function-based proposals. The mixing time analysis via conductance (Kannan, Lovász, and Simonovits, 1997) shows that the Dikin walk mixes in polynomial time, yielding an FPRAS for volume computation—a problem that is #P-hard for explicit polytope descriptions.

## 6. Comparison Methods and the Diaconis-Saloff-Coste Technique

Often we cannot bound the mixing time of a complicated chain directly, but we can compare it to a simpler chain whose mixing properties are known. The _comparison method_ (Diaconis and Saloff-Coste, 1993) provides a systematic way to transfer mixing time bounds from one chain to another via Dirichlet form inequalities.

**Definition 6.1 (Dirichlet Form).** For a reversible Markov chain with stationary distribution \(\pi\) and transition matrix \(P\), the _Dirichlet form_ of a function \(f : \Omega \to \mathbb{R}\) is:

\[
\mathcal{E}_P(f, f) = \frac{1}{2} \sum_{x, y \in \Omega} \pi(x) P(x, y) (f(x) - f(y))^2
\]

The spectral gap \(\gamma = 1 - \lambda_2\) satisfies the variational characterization:

\[
\gamma = \min*{f \text{ non-constant}} \frac{\mathcal{E}\_P(f, f)}{\operatorname{Var}*\pi(f)}
\]

where \(\operatorname{Var}_\pi(f) = \mathbb{E}_\pi[f^2] - (\mathbb{E}\_\pi[f])^2\). This is the Rayleigh quotient for the Laplacian \(I - P\).

**Theorem 6.1 (Comparison Theorem).** Let \(P\) and \(\tilde{P}\) be two reversible Markov chains on the same state space with the same stationary distribution \(\pi\). Suppose there exists a constant \(A\) such that for all \(f\),

\[
\mathcal{E}\_{\tilde{P}}(f, f) \leq A \cdot \mathcal{E}\_P(f, f)
\]

Then \(\tilde{\gamma} \leq A \cdot \gamma\), where \(\gamma\) and \(\tilde{\gamma}\) are the spectral gaps of \(P\) and \(\tilde{P}\). Consequently,

\[
t*{\text{mix}}^{(\tilde{P})}(\varepsilon) \leq A \cdot t*{\text{mix}}^{(P)}(\varepsilon)
\]

up to logarithmic factors.

**Proof Sketch.** From the variational characterization:

\[
\tilde{\gamma} = \min*f \frac{\mathcal{E}*{\tilde{P}}(f,f)}{\operatorname{Var}_\pi(f)} \leq \min_f \frac{A \cdot \mathcal{E}\_P(f,f)}{\operatorname{Var}_\pi(f)} = A \cdot \gamma
\]

The mixing time bound follows from the \(L^2\) mixing time bound \(t*{\text{mix}}^{(2)} \leq \frac{1}{\gamma} \log(1/\pi*{\min})\) and the relationship between total variation and \(L^2\) distances. ∎

The comparison method has been used to prove rapid mixing for:

- **Glauber dynamics for spin systems**: compare the Glauber dynamics on an arbitrary graph to the dynamics on a tree (where mixing is easy to analyze).
- **Random transpositions**: compare the random transposition shuffle on \(n\) cards to the "random-to-top" shuffle.
- **Metropolis on log-concave distributions**: compare to the ball walk or the Dikin walk.

### 6.1 Evolving Sets and the Morris-Peres Bound

A more recent technique for bounding mixing times is the _evolving sets_ method (Morris and Peres, 2005). For each set \(S \subseteq \Omega\), define its _conductance profile_:

\[
\Phi(S) = \frac{Q(S, S^c)}{\pi(S)}
\]

where \(Q(S, S^c) = \sum\_{x \in S, y \notin S} \pi(x) P(x, y)\). The _evolving set process_ is a Markov chain on subsets of \(\Omega\) that starts at a set \(S_0\), and at each step, transitions to the set of states reached by \(n\) independent transitions from \(S_t\) (in a suitable correlated way).

**Theorem 6.2 (Morris-Peres, 2005).** For a lazy, reversible chain,

\[
t*{\text{mix}} \leq 1 + \int*{4\pi*\*}^{3/4} \frac{4 du}{u \Phi*\*(u)^2}
\]

where \(\Phi*\*(r) = \min*{S: \pi(S) \leq r} \Phi(S)\) and \(\pi\_\* = \min_x \pi(x)\). This bound subsumes both the spectral and conductance bounds and can give sharper mixing time estimates for chains with bottlenecks at multiple scales.

## 7. Perfect Simulation: Coupling from the Past

MCMC gives samples that are approximately from \(\pi\) after the mixing time. But "approximately" is a nuisance: how close is close enough? _Coupling from the Past_ (CFTP), invented by Propp and Wilson (1996), provides an algorithm that yields samples _exactly_ from the stationary distribution in finite expected time—without knowing the mixing time.

**Algorithm 7.1 (Coupling from the Past).** Let \(\{U*t\}*{t \in \mathbb{Z}}\) be an i.i.d. sequence of random seeds. Define a deterministic update function \(\phi : \Omega \times \mathcal{U} \to \Omega\) such that \(\phi(x, U_t)\) has distribution \(P(x, \cdot)\). The algorithm:

1. Start at time \(T = -1\).
2. For each state \(x*0 \in \Omega\), trace the chain forward from time \(T\) to time \(0\) using seeds \(U_T, U*{T+1}, \ldots, U*{-1}\). Define \(F_T(x_0) = \phi(\cdots \phi(\phi(x_0, U_T), U*{T+1}) \cdots, U\_{-1})\).
3. If \(F_T(\cdot)\) is constant (all starting states coalesce to the same final state), output that state. Otherwise, set \(T \leftarrow 2T\) and repeat.

**Theorem 7.1 (Propp & Wilson, 1996).** If the chain is ergodic and the update function is monotone (with respect to some partial order), CFTP terminates almost surely in finite expected time and outputs a state distributed exactly according to \(\pi\). Moreover, the expected running time is \(O(t\_{\text{mix}})\).

**Proof of Exactness.** Consider the infinite past. The sequence of maps \(F\_{-\infty, 0}\) would take _every_ state to the same value (since coalescence occurs with probability 1 as \(T \to -\infty\)). The output of CFTP is precisely this value. Since the chain at time 0 (from the infinite past) is in stationarity, the output has distribution \(\pi\). Crucially, CFTP detects coalescence without knowing the infinite past—it iterates backward in time until it finds a time \(-T\) where all states coalesce. ∎

CFTP has been implemented for the Ising model (perfect sampling of random cluster configurations), permutations (perfect shuffle), and spatial point processes (perfect simulation of Poisson cluster processes). It is the gold standard when exact samples are needed.

## 8. Logarithmic Sobolev Inequalities and Concentration

The spectral gap gives \(L^2\) mixing bounds. _Logarithmic Sobolev inequalities_ (LSI) give stronger \(L^\infty\) mixing bounds and concentration. The _log-Sobolev constant_ \(\alpha\) of a reversible chain is the largest constant such that for all nonnegative functions \(f\),

\[
\mathcal{E}_P(\sqrt{f}, \sqrt{f}) \geq \alpha \cdot \operatorname{Ent}_\pi(f)
\]

where \(\operatorname{Ent}_\pi(f) = \mathbb{E}_\pi[f \log f] - \mathbb{E}_\pi[f] \log \mathbb{E}_\pi[f]\) is the entropy.

**Theorem 8.1 (Diaconis & Saloff-Coste, 1996).** For a reversible chain with log-Sobolev constant \(\alpha\),

\[
\|P^t(x, \cdot) - \pi\|\_{\text{TV}} \leq \frac{1}{2} \exp\left(1 - \alpha \left(t - \frac{1}{4\alpha} \log \log \frac{1}{\pi(x)}\right)\right)
\]

Thus \(t*{\text{mix}} = O\left(\frac{1}{\alpha} \log \log \frac{1}{\pi*{\min}}\right)\). The log-Sobolev constant satisfies \(\alpha \leq \gamma/2\) always, and \(\alpha\) can be exponentially smaller than \(\gamma\) for some chains (e.g., product chains). The LSI gives the correct mixing time for the random walk on the hypercube (\(\Theta(n \log n)\)), whereas the spectral gap alone gives \(O(n^2)\).

### 8.1 Concentration of Measure for MCMC Estimators

If \(X*1, \ldots, X_m\) are samples from an MCMC chain at stationarity, we estimate \(\mathbb{E}*\pi[f]\) by \(\hat{\mu}_m = \frac{1}{m} \sum_{i=1}^m f(X*i)\). The variance of this estimator depends on the \_autocorrelation time*:

\[
\tau*f = 1 + 2 \sum*{k=1}^{\infty} \text{Corr}\_\pi(f(X_0), f(X_k))
\]

The effective sample size is \(m / \tau*f\). Chains with small \(\tau_f\) (rapidly decaying correlations) yield better estimates. For geometrically ergodic chains, \(\tau_f\) is bounded by \(O(1/\gamma)\), but for specific functions, it can be much smaller—this is the \_Bernoulli factory* phenomenon exploited in modern Bayesian computation.

## 9. Hamiltonian Monte Carlo and the Geometry of MCMC

The random-walk Metropolis algorithm suffers from the _curse of dimensionality_: in \(d\) dimensions, the optimal proposal scale is \(O(d^{-1/2})\), leading to \(O(d)\) mixing time. _Hamiltonian Monte Carlo_ (HMC, Duane et al., 1987; Neal, 2011) overcomes this by using gradient information to make long, coherent proposals that respect the geometry of the target distribution.

HMC augments the state \(x \in \mathbb{R}^d\) with a momentum variable \(p \sim \mathcal{N}(0, M)\) and simulates Hamiltonian dynamics:

\[
\frac{dx}{dt} = M^{-1} p, \quad \frac{dp}{dt} = -\nabla U(x)
\]

where \(U(x) = -\log \pi(x)\) is the potential energy. Hamiltonian dynamics preserves the Hamiltonian \(H(x, p) = U(x) + \frac{1}{2} p^\top M^{-1} p\), so the joint distribution \(\pi(x) \cdot \mathcal{N}(p; 0, M)\) is invariant. Discretization with the leapfrog integrator (symplectic, reversible, volume-preserving) yields a Metropolis proposal with high acceptance probability even for large step sizes.

**Theorem 9.1 (Neal, 2011; Mangoubi & Vishnoi, 2018).** For strongly log-concave distributions \(\pi(x) \propto e^{-U(x)}\) with \(m I \preceq \nabla^2 U(x) \preceq L I\), HMC mixes in \(\tilde{O}(\sqrt{L/m})\) gradient evaluations, compared to \(\tilde{O}(L/m)\) for Langevin dynamics and \(\tilde{O}((L/m)^2)\) for random-walk Metropolis. This is the _dimension-free mixing_ achieved by HMC in the ideal setting.

HMC is the engine of Stan (Carpenter et al., 2017), the dominant probabilistic programming language for Bayesian inference, which automatically tunes the step size and number of leapfrog steps using the No-U-Turn Sampler (NUTS).

## 10. The Propp-Wilson Perfect Sampling Algorithm in Detail

Coupling from the Past (CFTP) produces samples _exactly_ from the stationary distribution. Let us examine the algorithm more formally and prove its correctness.

**Algorithm 10.1 (Monotone CFTP).** Suppose the state space \(\Omega\) has a partial order \(\preceq\) with a unique minimum \(\hat{0}\) and maximum \(\hat{1}\). The update function \(\phi : \Omega \times \mathcal{U} \to \Omega\) is _monotone_ if \(x \preceq y \implies \phi(x, u) \preceq \phi(y, u)\) for all \(u\).

1. Let \(\{U*t\}*{t \in \mathbb{Z}}\) be i.i.d. random seeds drawn from some distribution.
2. For \(T = 1, 2, 4, 8, \ldots\):
   - Set \(L_T = \hat{0}\), \(U_T = \hat{1}\).
   - For \(t = T, T+1, \ldots, -1\):
     - \(L_T \leftarrow \phi(L_T, U_t)\), \(U_T \leftarrow \phi(U_T, U_t)\).
   - If \(L_T = U_T\), output \(L_T\) and halt.

**Theorem 10.1 (Propp and Wilson, 1996).** If the chain is ergodic and the update function is monotone, CFTP terminates almost surely in finite expected time. The output has distribution exactly \(\pi\).

_Proof._ Let \(\tau\_{\text{coal}}\) be the smallest \(T\) such that the chains from all starting states coalesce by time 0 when run from time \(-T\). Since the chain is ergodic, there exists a coupling of all starting states that coalesces in finite time with probability 1. By the monotonicity of \(\phi\), the chains from \(\hat{0}\) and \(\hat{1}\) sandwich all others: if they coalesce, all chains coalesce. Thus CFTP detects coalescence exactly when \(L_T = U_T\).

For exactness: imagine running the chain from time \(-\infty\) with the same sequence \(\{U_t\}\). Since the chain is ergodic, there is a (random) time \(-T_0\) such that all states coalesce by time 0. The CFTP loop doubles \(T\) until it finds such a \(T\), which happens with probability 1. The state output by CFTP is the state at time 0 of the chain started at \(-\infty\), which is exactly distributed as \(\pi\). The algorithm merely detects coalescence without knowing the infinite past. ∎

**Application to the Ising Model.** For the ferromagnetic Ising model on a finite graph, the state space \(\{-1, +1\}^V\) has a natural partial order: \(\sigma \preceq \sigma'\) if \(\sigma(v) \leq \sigma'(v)\) for all \(v\). The heat-bath update (which samples a spin from its conditional distribution given neighbors) is monotone with respect to this order. CFTP thus yields perfect samples from the Ising model at any temperature, enabling rigorous studies of phase transitions without Markov-chain convergence diagnostics.

## 11. Stochastic Gradient MCMC and the Unadjusted Langevin Algorithm

Classical MCMC requires the _full_ dataset at each iteration to compute the gradient of the log-posterior. For large-scale Bayesian inference (millions of data points), this is prohibitive. _Stochastic Gradient MCMC_ (Welling and Teh, 2011) replaces the full-data gradient with a mini-batch estimate, injecting carefully scaled noise to correct for the stochasticity.

**Definition 11.1 (Stochastic Gradient Langevin Dynamics, SGLD).** Given a prior \(p(\theta)\) and likelihood \(\prod\_{i=1}^N p(x_i \mid \theta)\), the SGLD update with mini-batch \(B_t \subset \{1, \ldots, N\}\) of size \(n\) is:

\[
\theta*{t+1} = \theta_t + \frac{\varepsilon_t}{2} \left( \nabla \log p(\theta_t) + \frac{N}{n} \sum*{i \in B_t} \nabla \log p(x_i \mid \theta_t) \right) + \eta_t, \quad \eta_t \sim \mathcal{N}(0, \varepsilon_t I)
\]

where \(\varepsilon_t \to 0\) as \(t \to \infty\) (decreasing step size). The gradient noise from mini-batching is \(\mathcal{N}(0, \frac{\varepsilon_t^2}{4} V(\theta_t))\) where \(V(\theta_t)\) is the variance of the stochastic gradient. The injected noise \(\eta_t\) dominates this stochastic gradient noise when \(\varepsilon_t\) is small, ensuring the correct stationary distribution in the limit.

**Theorem 11.1 (Teh, Thiery, and Vollmer, 2016).** Under regularity conditions (smoothness and dissipativity of the log-posterior), SGLD with step size \(\varepsilon_t = a (b + t)^{-\alpha}\) for \(\alpha \in (0, 1]\) converges weakly to the posterior distribution. The bias decreases as \(O(\varepsilon_t)\) and the variance decreases as \(O(\varepsilon_t^2)\), giving an optimal convergence rate of \(O(T^{-1/3})\) in 2-Wasserstein distance for \(\alpha = 1/3\).

**The Unadjusted Langevin Algorithm (ULA).** If we _omit_ the Metropolis-Hastings accept/reject step entirely and simply run the Langevin dynamics discretized, we obtain ULA. The asymptotic bias of ULA is \(O(\varepsilon)\) where \(\varepsilon\) is the step size—it does not have the exact posterior as its stationary distribution. However, for large \(N\), the bias is dominated by the Monte Carlo error unless an enormous number of samples is collected. In practice, SGLD and its variants (stochastic gradient Hamiltonian Monte Carlo, SGHMC; preconditioned SGLD) are the methods of choice for training Bayesian neural networks and for large-scale topic models.

```
SGLD bias-variance tradeoff:

  Step size epsilon_t:
    Large epsilon → fast mixing, large bias
    Small epsilon → slow mixing, small bias

  Optimal schedule: epsilon_t = a * t^{-1/3}
  → MSE = O(T^{-1/3}) in Wasserstein distance

  Practical guidance:
    - Use large mini-batches for smaller gradient variance
    - Use preconditioning (RMSprop, Adam) to handle anisotropy
    - Monitor convergence with thinned sample diagnostics
```

## 12. Quantum Markov Chains and the Quantum Mixing Time

The classical theory of Markov chains extends to the quantum realm, where states are density matrices and transitions are completely positive trace-preserving (CPTP) maps. A _quantum Markov chain_ (or _quantum channel_) \(\mathcal{E} : \mathcal{B}(\mathcal{H}) \to \mathcal{B}(\mathcal{H})\) is a CPTP map with a stationary state \(\rho*\*\) such that \(\mathcal{E}(\rho*\_) = \rho\_\_\).

**Definition 12.1 (Quantum Mixing Time).** The _quantum mixing time_ \(t*{\text{mix}}^Q(\varepsilon)\) of a quantum channel \(\mathcal{E}\) with unique stationary state \(\rho*\*\) is the smallest \(t\) such that for all initial states \(\rho\),

\[
\|\mathcal{E}^t(\rho) - \rho\_\*\|\_1 \leq \varepsilon
\]

where \(\|\cdot\|\_1\) is the trace norm. This is the quantum analogue of total variation distance.

**Theorem 12.1 (Temme, Kastoryano, Ruskai, Wolf, and Verstraete, 2010).** For a primitive (irreducible and aperiodic) quantum channel \(\mathcal{E}\) with spectral gap \(\gamma = 1 - |\lambda_2|\) (where \(\lambda_2\) is the second largest eigenvalue in magnitude),

\[
t\_{\text{mix}}^Q(\varepsilon) \leq O\left(\frac{1}{\gamma} \log \frac{d}{\varepsilon}\right)
\]

where \(d = \dim(\mathcal{H})\). The spectral gap of a quantum channel is the analogue of the classical spectral gap, and it governs the convergence rate of _dissipative quantum systems_.

**Applications to Quantum Algorithms.** Quantum Markov chains arise in:

- **Quantum Metropolis Sampling** (Temme et al., 2011): A quantum algorithm for preparing thermal states \(\rho\_\beta \propto e^{-\beta H}\) of a quantum Hamiltonian \(H\), with mixing time that can be quadratically faster than classical MCMC for certain Hamiltonians (those with a quantum spectral gap amplification).
- **Quantum Gibbs Sampling** (Poulin and Wocjan, 2009): Uses repeated weak measurements and quantum phase estimation to sample from the Gibbs distribution, with complexity polynomial in the inverse temperature and the gap.
- **Dissipative Quantum State Preparation** (Verstraete et al., 2009): Engineers a quantum channel whose unique stationary state is a desired entangled state (e.g., a PEPS or a cluster state), so that running the channel prepares the state by "cooling" the system.

The interplay between classical MCMC theory and quantum information is a rich and rapidly developing frontier. The canonical paths method, the Cheeger inequality, and the comparison theorem have all been lifted to the quantum setting, providing a unified mathematical framework for understanding mixing in both classical and quantum systems.

### 12.1 Semi-Markov Chains and Sojourn Time Distributions

A natural generalization of Markov chains is the _semi-Markov process_, where the holding time in each state is not necessarily exponential (as in CTMCs) but can follow an arbitrary distribution. A semi-Markov chain is specified by a transition matrix \(P\) (for which state to visit next) and a family of holding time distributions \(F\_{ij}(t)\) (for how long we stay in \(i\) before jumping to \(j\)). Semi-Markov chains model systems where event durations matter—e.g., job completion times in a computing cluster, residence times of packets in router buffers, or dwell times of customers on a webpage.

**Theorem 12.2 (Semi-Markov Renewal Theorem, Cinlar, 1969).** For an irreducible semi-Markov process, the long-run fraction of time spent in state \(i\) is:

\[
\pi_i = \frac{\tilde{\pi}\_i \cdot \mathbb{E}[T_i]}{\sum_j \tilde{\pi}\_j \cdot \mathbb{E}[T_j]}
\]

where \(\tilde{\pi}\) is the stationary distribution of the embedded discrete-time Markov chain \(P\), and \(\mathbb{E}[T_i] = \sum*j P*{ij} \int*0^\infty t \, dF*{ij}(t)\) is the mean holding time in state \(i\). The stationary distribution of a semi-Markov process is _time-weighted_: states with longer holding times are visited more frequently in the time-average sense, even if they are rare in the embedded chain.

This result is essential for analyzing systems where workload and timing interact, such as the _M/G/1 queue with Markov-modulated service_, the _IEEE 802.11 DCF backoff protocol_ (where backoff durations are discrete uniform, not geometric), and Google's _Borg cluster scheduler_ (where task placement decisions depend on estimated task durations from historical data).

## 13. Summary

Markov chains are the mathematical engine of randomized computation. The theory of mixing times—coupling, spectral gaps, conductance, canonical paths—provides the tools to prove that a chain converges rapidly to its stationary distribution. MCMC algorithms like Metropolis-Hastings and Gibbs sampling leverage this theory to sample from complex, high-dimensional distributions, enabling approximate counting, Bayesian inference, and optimization at scales that deterministic methods cannot touch.

The central tension in the field is between _computational efficiency_ (rapid mixing) and _statistical accuracy_ (faithfulness to the target distribution). The art of MCMC design lies in constructing chains that mix quickly while remaining reversible with respect to the desired distribution. The theoretical guarantees—when they exist—transform heuristics into algorithms with proven bounds on running time and error.

To go deeper, the classic text is _Markov Chains and Mixing Times_ by Levin, Peres, and Wilmer. For the MCMC perspective, _Monte Carlo Statistical Methods_ by Robert and Casella is comprehensive. And for the theoretical computer science angle, Jerrum's _Counting, Sampling, and Integrating: Algorithms and Complexity_ is essential.
