---
title: "Online Learning: Regret Minimization, the Multiplicative Weights Algorithm, and Adversarial Bandits"
description: "A rigorous treatment of online learning—regret minimization, multiplicative weights, EXP3 for adversarial bandits, and the deep connections to game theory and boosting."
date: "2022-04-15"
author: "Leonardo Benicio"
tags: ["online-learning", "regret-minimization", "multi-armed-bandits", "multiplicative-weights", "game-theory"]
categories: ["theory", "mathematics"]
draft: false
cover: "/static/images/blog/online-learning-regret-minimization-multi-armed-bandits.png"
coverAlt: "Diagram illustrating the multiplicative weights update rule with experts and weights"
---

In the standard machine learning setup, the learner receives a batch of training data, learns a model, and deploys it. But many real-world problems are inherently _online_: the learner must make a sequence of decisions, receiving feedback after each one, without knowing the future. You bid in an auction. You route traffic to servers. You show advertisements to users. Each decision yields a reward (or loss), and the environment may be adversarial—actively trying to thwart you. The measure of success is not generalization error but _regret_: the difference between your cumulative reward and the reward of the best _fixed_ decision in hindsight.

Online learning theory, developed from the 1950s (Hannan, Blackwell) through the 2000s (Cesa-Bianchi, Lugosi, Freund, Schapire), provides a unified framework for such problems. The _multiplicative weights_ algorithm (also called Hedge, Exponentiated Gradient, or AdaBoost's core) achieves \(O(\sqrt{T \log N})\) regret against the best of \(N\) experts over \(T\) rounds. For the _adversarial bandit_ problem—where you only see the reward of the action you chose, not the counterfactual rewards of the others—the EXP3 algorithm achieves \(O(\sqrt{T N \log N})\) regret. These bounds are tight, and the algorithms are simple enough to implement in a few lines of code. This post develops the theory from the ground up.

## 1. The Expert Problem and Regret

In the _prediction with expert advice_ framework, there are \(N\) experts. At each round \(t = 1, \ldots, T\):

1. The learner chooses a distribution \(\mathbf{p}\_t\) over experts (or selects one expert deterministically).
2. The adversary reveals the losses \(\ell_t(i) \in [0, 1]\) for each expert \(i\).
3. The learner incurs expected loss \(\sum_i p_t(i) \ell_t(i)\).

The _regret_ of the learner against expert \(i\) is:

\[
R*T(i) = \sum*{t=1}^T \sum*{j=1}^N p_t(j) \ell_t(j) - \sum*{t=1}^T \ell_t(i)
\]

The goal is to achieve _sublinear regret_: \(R_T(i) = o(T)\) for all \(i\), meaning the average per-round regret goes to zero. Equivalently, the learner's performance approaches that of the best expert in hindsight.

### 1.1 The Multiplicative Weights Algorithm

**Algorithm 1 (MWA / Hedge).**
Initialize weights \(w_1(i) = 1\) for all \(i = 1, \ldots, N\).
For \(t = 1, \ldots, T\):

1. Set \(p_t(i) = w_t(i) / \sum_j w_t(j)\).
2. Receive losses \(\ell_t(i)\).
3. Update \(w\_{t+1}(i) = w_t(i) \cdot e^{-\eta \ell_t(i)}\), where \(\eta > 0\) is the learning rate.

**Theorem 1.1 (Regret Bound for MWA).** For any \(\eta > 0\),

\[
\sum*{t=1}^T \sum*{i=1}^N p*t(i) \ell_t(i) \leq \min_i \left(\sum*{t=1}^T \ell_t(i) + \frac{\log N}{\eta} + \frac{\eta T}{8}\right)
\]

Optimizing \(\eta = \sqrt{8 \log N / T}\) gives regret \(O(\sqrt{T \log N})\).

_Proof sketch._ Define the potential function \(\Phi*t = \sum*{i=1}^N w_t(i)\). Then:

\[
\Phi\_{t+1} = \sum_i w_t(i) e^{-\eta \ell_t(i)} \leq \sum_i w_t(i) \left(1 - \eta \ell_t(i) + \frac{\eta^2}{2} \ell_t(i)^2\right) \leq \Phi_t \left(1 - \eta \sum_i p_t(i) \ell_t(i) + \frac{\eta^2}{8}\right)
\]

(using the inequality \(e^{-x} \leq 1 - x + x^2/2\) for \(x \geq 0\), and noting \(\ell_t(i) \in [0, 1]\), so \(\ell_t(i)^2 \leq \ell_t(i)\); the worst-case bound gives \(\sum p_t(i) \ell_t(i)^2 \leq \sum p_t(i) \ell_t(i) \leq 1\)). Taking logs and summing:

\[
\log \frac{\Phi\_{T+1}}{\Phi_1} \leq -\eta \sum_t \sum_i p_t(i) \ell_t(i) + \frac{\eta^2 T}{8}
\]

But \(\Phi*{T+1} \geq w*{T+1}(i) = e^{-\eta \sum_t \ell_t(i)}\) for any expert \(i\), while \(\Phi_1 = N\). Hence:

\[
-\eta \sum_t \ell_t(i) - \log N \leq -\eta \sum_t \sum_i p_t(i) \ell_t(i) + \frac{\eta^2 T}{8}
\]

Rearranging yields the bound. ∎

## 2. The Adversarial Bandit Problem

In the _bandit_ setting, the learner only observes the loss of the chosen action, not the losses of all experts. This partial feedback makes the problem strictly harder.

**Algorithm 2 (EXP3: Exponential-weight for Exploration and Exploitation).**
Initialize \(w_1(i) = 1\) for all \(i\).
For \(t = 1, \ldots, T\):

1. Set \(p_t(i) = (1 - \gamma) \frac{w_t(i)}{\sum_j w_t(j)} + \frac{\gamma}{N}\) (mix with uniform exploration).
2. Draw action \(I_t \sim \mathbf{p}\_t\).
3. Receive loss \(\ell_t(I_t)\).
4. Construct importance-weighted estimator: \(\hat{\ell}_t(i) = \frac{\ell_t(i)}{p_t(i)} \mathbf{1}_{\{I_t = i\}}\) (unbiased: \(\mathbb{E}[\hat{\ell}_t(i)] = \ell_t(i)\)).
5. Update \(w\_{t+1}(i) = w_t(i) \cdot e^{-\eta \hat{\ell}\_t(i)}\).

**Theorem 2.1 (Regret Bound for EXP3).** With appropriate choices of \(\eta\) and \(\gamma\),

\[
\mathbb{E}[R_T] = O\left(\sqrt{T N \log N}\right)
\]

Optimally, \(\eta = \sqrt{\frac{\log N}{T N}}\) and \(\gamma = \eta N\).

The key idea: by adding uniform exploration (\(\gamma/N\)), we ensure that every action has a minimum probability of being chosen, so the importance-weighted estimators have bounded variance. The extra \(\sqrt{N}\) factor compared to the full-information setting is necessary: a lower bound shows that any bandit algorithm must incur regret \(\Omega(\sqrt{T N})\).

## 3. The Connection to Game Theory

Online learning has a beautiful connection to game theory via the _minimax theorem_. Consider a zero-sum game with payoff matrix \(M \in [0, 1]^{N \times N}\). The row player chooses a mixed strategy \(\mathbf{p} \in \Delta_N\), the column player chooses \(\mathbf{q} \in \Delta_N\), and the payoff is \(\mathbf{p}^\top M \mathbf{q}\).

**Theorem 3.1 (Minimax via Online Learning).** If both players use a no-regret algorithm (e.g., MWA), the average strategies \(\bar{\mathbf{p}} = \frac{1}{T} \sum \mathbf{p}\_t\) and \(\bar{\mathbf{q}} = \frac{1}{T} \sum \mathbf{q}\_t\) converge to a Nash equilibrium. Specifically:

\[
\max*{\mathbf{p}} \mathbf{p}^\top M \bar{\mathbf{q}} - \min*{\mathbf{q}} \bar{\mathbf{p}}^\top M \mathbf{q} \leq \frac{R_T^{\mathrm{row}} + R_T^{\mathrm{col}}}{T} \to 0
\]

This provides a constructive proof of the minimax theorem and an algorithm for computing approximate Nash equilibria in zero-sum games. The connection extends to _boosting_: AdaBoost can be derived as the row player's MWA strategy in a game where the column player (the weak learner) chooses a hypothesis and the row player (the booster) chooses weights over examples.

## 4. From Online Learning to Convex Optimization

The online learning framework extends naturally to online convex optimization (OCO), where the learner chooses a point \(x_t \in \mathcal{K}\) (a convex set) and suffers a convex loss \(f_t(x_t)\). The regret is against the best fixed point in hindsight.

**Algorithm 3 (Online Gradient Descent).**
\[
x*{t+1} = \Pi*{\mathcal{K}}(x_t - \eta \nabla f_t(x_t))
\]

where \(\Pi*{\mathcal{K}}\) is Euclidean projection onto \(\mathcal{K}\). For convex \(f_t\), OGD achieves regret \(O(\sqrt{T})\) for appropriately chosen \(\eta\). *Follow the Regularized Leader* (FTRL) generalizes this: at each step, choose \(x_t = \arg\min*{x \in \mathcal{K}} (\sum\_{s < t} f_s(x) + R(x)/\eta)\), where \(R\) is a strongly convex regularizer.

This framework unifies many algorithms: gradient descent (Euclidean regularizer), multiplicative weights (entropic regularizer on the simplex), and AdaGrad (adaptive regularizer based on past gradients). The theory of online learning thus provides a common language for optimization, learning, and game playing.

## 5. Applications

### 5.1 Portfolio Selection

_Universal portfolio_ algorithms (Cover, 1991) use multiplicative weights to rebalance a portfolio of stocks online, achieving wealth that asymptotically matches the best constant-rebalanced portfolio in hindsight. The regret bound translates into a guarantee that the algorithm's wealth grows at the same exponential rate as the best fixed portfolio.

### 5.2 Boosting

AdaBoost (Freund and Schapire, 1995) can be seen as the multiplicative weights algorithm where the "experts" are weak hypotheses and the "losses" are the classification errors on training examples. The final classifier is a weighted majority vote of the weak hypotheses, with weights proportional to their accuracy. The bound on training error from boosting is a direct consequence of the MWA regret bound.

### 5.3 Repeated Auctions and Pricing

In _online auction design_, a seller sets prices sequentially, observing whether each bidder purchases. The regret is against the optimal fixed price in hindsight. The problem is a bandit (only the purchase decision at the chosen price is observed), and EXP3-type algorithms achieve \(O(\sqrt{T})\) regret for discretized price sets.

## 6. Adaptive Regret and Switching Regimes

The standard regret benchmark compares against a _single_ fixed expert in hindsight. But what if the best expert changes over time? In many real-world scenarios—financial markets, network traffic patterns, user preferences—the optimal decision shifts. _Adaptive regret_ (also called _tracking regret_ or _shifting regret_) measures the learner's performance against a sequence of experts that can change at most \(k\) times.

**Definition 6.1 (Adaptive Regret).** For a sequence of expert indices \(i*1, \ldots, i_T\) with at most \(k\) switches (i.e., \(|\{t : i_t \neq i*{t+1}\}| \leq k\)), the \(k\)-shifting regret is:

\[
R*T^{(k)} = \sum*{t=1}^T \sum*{i=1}^N p_t(i) \ell_t(i) - \min*{i*1, \ldots, i_T \text{ with } \leq k \text{ switches}} \sum*{t=1}^T \ell_t(i_t)
\]

**The Fixed-Share Algorithm** (Herbster and Warmuth, 1998) achieves \(O(\sqrt{k T \log N})\) adaptive regret. The key idea: instead of starting from uniform weights each round, the algorithm "mixes in" a fraction \(\alpha\) of the uniform distribution at every step, preventing any expert's weight from decaying to zero. Formally:

\[
w*{t+1}(i) = (1 - \alpha) \cdot w_t(i) \cdot e^{-\eta \ell_t(i)} + \frac{\alpha}{N} \sum*{j=1}^N w_t(j) \cdot e^{-\eta \ell_t(j)}
\]

This is equivalent to the standard MWA on a modified graph where every pair of experts is connected by an edge of weight \(\alpha/N\). The mixing term ensures that if the currently-best expert suddenly performs poorly, the learner can quickly "switch" to a different expert that was previously discounted.

**Theorem 6.1 (Fixed-Share Regret).** With learning rate \(\eta = \sqrt{\frac{\log(N/\alpha)}{T}}\) and mixing parameter \(\alpha = k/T\), the Fixed-Share algorithm achieves:

\[
\mathbb{E}[R_T^{(k)}] = O\left(\sqrt{k T \log N} + \frac{T}{\eta} \alpha \log N\right) = O\left(\sqrt{k T \log N}\right)
\]

when \(k\) is known in advance. The _Learn-\alpha_ variant (Cesa-Bianchi, Mansour, and Stoltz, 2007) tunes \(\alpha\) adaptively without knowledge of \(k\), using a doubling trick over the mixing parameter.

### 6.1 Dynamic Regret for Convex Functions

In online convex optimization, the _dynamic regret_ compares against an arbitrary sequence of comparators \(u*1, \ldots, u_T\) rather than a fixed point. Zinkevich (2003) showed that for bounded variation \(V_T = \sum*{t=1}^{T-1} \|u\_{t+1} - u_t\|\), online gradient descent achieves dynamic regret \(O(\sqrt{T}(1 + V_T))\). For strongly convex losses, the bound improves to \(O(1 + V_T)\) using optimistic mirror descent. These bounds formalize the intuition that tracking a slowly-moving target is not much harder than competing against a fixed one.

## 7. Lower Bounds and the Minimax Optimal Regret

The upper bounds we have derived—\(O(\sqrt{T \log N})\) for full information and \(O(\sqrt{T N \log N})\) for bandits—are not merely sufficient; they are _optimal_ in the minimax sense. This section proves matching lower bounds, establishing that no algorithm can achieve substantially better regret against an adversarial environment.

### 7.1 Minimax Lower Bound for the Expert Problem

**Theorem 7.1 (Full-Information Lower Bound).** For any randomized learner, there exists an adversary (a sequence of loss vectors \(\ell_t \in [0,1]^N\)) such that:

\[
\mathbb{E}[R_T] = \Omega\left(\sqrt{T \log N}\right)
\]

_Proof Sketch._ The proof uses the probabilistic method with a random adversary. Each expert \(i\) is assigned a hidden "quality" \(q*i \sim \mathcal{N}(0, \sigma^2)\). At each round, the adversary sets \(\ell_t(i) = 1/2 + \varepsilon*{t,i}\) where \(\varepsilon\_{t,i} \sim \text{Uniform}(-q_i, q_i)\). The best expert in hindsight has cumulative loss roughly \(T/2 - \Omega(\sqrt{T \log N})\), while any online learner (which cannot identify the best expert without incurring regret during exploration) suffers expected cumulative loss \(T/2 - O(1)\). The gap is \(\Omega(\sqrt{T \log N})\). A more formal argument uses Pinsker's inequality and KL-divergence between the learner's distribution and the posterior over experts.

Equivalently, one can construct an adversary that picks a random expert \(i^_\) uniformly and sets \(\ell_t(i^_) \sim \text{Bernoulli}(1/2 - \varepsilon)\) and \(\ell_t(i) \sim \text{Bernoulli}(1/2)\) for \(i \neq i^\*\). Distinguishing the good expert from noise requires \(\Omega(\log N / \varepsilon^2)\) samples; optimizing \(\varepsilon\) against \(T\) yields the bound.

### 7.2 The Bandit Lower Bound

**Theorem 7.2 (Bandit Lower Bound).** For any bandit algorithm, there exists an adversary such that:

\[
\mathbb{E}[R_T] = \Omega\left(\sqrt{T N}\right)
\]

_Proof._ The adversary assigns all arms loss \(1/2\), except a randomly chosen "good" arm with loss \(1/2 - \varepsilon\). To identify the good arm, the learner must sample each of the \(N\) arms at least \(\Omega(1/\varepsilon^2)\) times (by the KL-divergence version of Hoeffding's inequality). During this exploration, the learner incurs regret \(\varepsilon\) per pull on suboptimal arms. The total regret balances exploration cost \(N/\varepsilon\) against per-round regret \(T\varepsilon\), yielding \(\varepsilon \sim \sqrt{N/T}\) and regret \(\Omega(\sqrt{T N})\).

**Tightness.** The EXP3 upper bound \(O(\sqrt{T N \log N})\) matches the lower bound up to a \(\sqrt{\log N}\) factor. Closing this logarithmic gap was a major open problem, resolved by Audibert and Bubeck (2010) with the _INF_ (Implicitly Normalized Forecaster) algorithm, which achieves \(O(\sqrt{T N})\) without the log factor by using a more refined importance-weighting scheme. The minimax optimal regret in the adversarial bandit setting is therefore \(\Theta(\sqrt{T N})\).

### 7.3 First-Order and Second-Order Bounds

While \(\sqrt{T}\) dependence is unavoidable in the worst case, better bounds are possible when losses are _stochastic_ or have _small variance_. The _first-order_ bound replaces the dependence on \(T\) with the cumulative loss of the best expert \(L_T^\* = \min_i \sum_t \ell_t(i)\):

\[
R_T = O\left(\sqrt{L_T^\* \log N} + \log N\right)
\]

This is achieved by the _AdaHedge_ algorithm (De Rooij et al., 2014), which adaptively tunes the learning rate based on observed losses. When the best expert has very small cumulative loss (e.g., in a near-realizable setting), the regret is substantially smaller than \(\sqrt{T}\).

The _second-order_ bound replaces \(T\) with the sum of squared losses, exploiting the fact that low-variance environments are easier:

\[
R*T = O\left(\sqrt{(\log N) \sum*{t=1}^T \sum\_{i=1}^N p_t(i) (\ell_t(i) - \bar{\ell}\_t)^2} + \log N\right)
\]

These refined bounds demonstrate that online learning algorithms are not merely worst-case optimal—they automatically exploit favorable problem structure without knowing it in advance.

## 8. Contextual Bandits and the LinUCB Algorithm

In many practical applications, the learner has access to _side information_ (context) before making a decision. In online advertising, the context is the user's browsing history; in personalized recommendations, it's the user's profile and past behavior; in clinical trials, it's the patient's medical characteristics. The _contextual bandit_ (or _bandit with covariates_) framework models this.

**Definition 8.1 (Contextual Bandit).** At each round \(t\):

1. The learner observes a context vector \(x\_{t,a} \in \mathbb{R}^d\) for each action \(a \in \{1, \ldots, K\}\).
2. The learner selects an action \(A_t\).
3. The learner observes reward \(r*t \sim \nu(x*{t, A_t})\), where \(\nu\) is an unknown reward distribution.

The goal is to minimize regret against the best _policy_ mapping contexts to actions, not just the best fixed action.

### 8.1 The Linear Realizability Assumption

A common and tractable assumption is _linear realizability_: there exists an unknown parameter vector \(\theta^\* \in \mathbb{R}^d\) such that:

\[
\mathbb{E}[r_t \mid x_{t,a}] = x\_{t,a}^\top \theta^\*
\]

The _LinUCB_ algorithm (Li et al., 2010) adapts the optimism-in-the-face-of-uncertainty principle to the linear setting. It maintains a regularized least-squares estimate of \(\theta^\*\) and constructs confidence ellipsoids around it.

**Algorithm 4 (LinUCB).**
Initialize \(A = I_d\) (the \(d \times d\) identity), \(b = \mathbf{0} \in \mathbb{R}^d\).
For \(t = 1, \ldots, T\):

1. Compute \(\hat{\theta}\_t = A^{-1} b\).
2. For each action \(a\), compute the upper confidence bound:
   \[U*t(a) = x*{t,a}^\top \hat{\theta}_t + \alpha \sqrt{x_{t,a}^\top A^{-1} x\_{t,a}}\]
   where \(\alpha = \sqrt{d \log((1 + T)/\delta)}\) is the exploration bonus.
3. Select \(A_t = \arg\max_a U_t(a)\).
4. Observe reward \(r*t\), update \(A \leftarrow A + x*{t,A*t} x*{t,A*t}^\top\), \(b \leftarrow b + r_t x*{t,A_t}\).

**Theorem 8.1 (LinUCB Regret).** With probability at least \(1 - \delta\), the cumulative regret of LinUCB satisfies:

\[
R_T = O\left(d \sqrt{T \log(T/\delta)}\right)
\]

The key insight: the confidence term \(\alpha \sqrt{x*{t,a}^\top A^{-1} x*{t,a}}\) is the standard deviation of the estimated reward, and summing it over \(T\) rounds yields \(\tilde{O}(d\sqrt{T})\) via an elliptical potential argument (the _elliptical lemma_: \(\sum*t \|x_t\|*{A_t^{-1}}^2 \leq 2d \log(\det(A_T)/\det(A_0))\)). The regret is independent of the number of actions \(K\) and scales only with the dimension \(d\).

### 8.2 Beyond Linearity: Kernel Methods and Neural Bandits

When the reward function is nonlinear, we can employ _kernel methods_ (KernelUCB, GP-UCB) or _neural networks_ (NeuralUCB). In the kernelized setting, the reward is modeled as \(f(x) = \langle f, \phi(x) \rangle\_{\mathcal{H}}\) in a reproducing kernel Hilbert space (RKHS). The confidence bounds involve the kernel matrix instead of \(A^{-1}\), and the regret is \(\tilde{O}(\sqrt{T \gamma*T})\) where \(\gamma_T\) is the \_maximum information gain*—a kernel-dependent complexity measure. For the RBF kernel, \(\gamma_T = O(\log^{d+1} T)\); for the linear kernel, \(\gamma_T = O(d \log T)\).

**Neural bandits** (Zhou et al., 2020) use the _neural tangent kernel_ (NTK) to analyze the behavior of overparameterized neural networks in the contextual bandit setting. Under the NTK regime, a wide ReLU network trained with gradient descent approximates a kernel method with the NTK, and the regret is \(\tilde{O}(d \sqrt{T})\) where \(d\) is the effective dimension of the NTK. This bridges the gap between deep learning practice and bandit theory.

## 9. Online Learning with Knapsack Constraints

Many real-world online decision problems involve _resource constraints_. An advertiser bidding in auctions has a daily budget. A cloud provider routing traffic has per-server capacity limits. A recommendation system must respect diversity or fairness constraints. The _online learning with knapsacks_ (Badanidiyuru, Kleinberg, and Slivkins, 2018) framework generalizes bandits to incorporate global resource limits.

**Definition 9.1 (Bandits with Knapsacks).** In each round \(t\), choosing action \(a\) consumes a vector of resources \(c*t(a) \in [0, 1]^d\) and yields reward \(r_t(a)\). The learner has a total budget \(B \in \mathbb{R}^d\) that cannot be exceeded over the \(T\)-round horizon. The optimal benchmark is the best \_static* policy (a distribution over actions) that respects the budget in expectation.

**Theorem 9.1 (Badanidiyuru et al., 2018).** There exists an algorithm achieving \(O(\sqrt{T})\) regret against the optimal static policy, provided the budget \(B = \Omega(T)\) (the expected per-round consumption is bounded away from zero). The algorithm maintains _virtual budgets_ updated via dual prices (Lagrange multipliers for the constraints), and selects actions using UCB on a Lagrangian-relaxed objective:

\[
a*t^\* = \arg\max_a \left(\text{UCB}\_t(a) - \sum*{j=1}^d \lambda*{t,j} \cdot c*{t,j}(a)\right)
\]

where \(\lambda\_{t,j}\) is the dual variable ("price") for resource \(j\), increased when the resource is over-consumed and decreased when under-consumed. This primal-dual approach unifies online learning with online convex programming under constraints, and the analysis combines the regret decomposition of FTRL with the Lagrangian saddle-point theory.

### 9.1 Applications

- **Budgeted bidding:** Advertisers bid in repeated second-price auctions with a total budget constraint. The optimal bidding strategy (value-based pacing) emerges as the solution to a knapsack bandit where arms are different bid multipliers.
- **Crowdsourcing with budget limits:** A platform assigns tasks to workers under a total budget, balancing task quality (reward) against worker cost (resource consumption). The UCB-with-budget algorithm automatically discovers the optimal price-quality tradeoff.
- **Energy-aware scheduling:** Data center job schedulers select server configurations (CPU frequency, parallelism level) to maximize throughput subject to a power budget. The knapsack bandit framework adaptively discovers the most energy-efficient configurations without offline modeling.

## 10. Delayed Feedback, Nonstationary Environments, and Beyond Worst-Case Analysis

Classical online learning assumes immediate, per-round feedback. In practice, feedback arrives with _delay_ (e.g., the outcome of a clinical trial is observed weeks after treatment; the conversion from an ad click occurs hours later). Moreover, environments are rarely stationary—user preferences drift, markets evolve, and adversaries adapt.

### 10.1 Online Learning with Delayed Feedback

When the feedback for round \(t\) arrives only at round \(t + D*t\) (where \(D_t\) is a random delay), the learner must make decisions with \_outstanding* (unresolved) feedback. The key challenge: the learner cannot distinguish between "arm looks bad because it's truly bad" and "arm looks bad because its recent feedback hasn't arrived yet."

**Theorem 10.1 (Joulani, György, and Szepesvári, 2013).** If the delays are bounded by \(D*{\max}\), then EXP3 can be modified to achieve regret \(O(\sqrt{(T + D*{\text{total}}) N \log N})\), where \(D\_{\text{total}} = \sum_t D_t\) is the cumulative delay. The modification: treat rounds with outstanding feedback as "virtual time" and update weights only when feedback arrives, using importance weighting based on the probability the action was selected at the time of the original decision.

For _unbounded_ delays with a known delay distribution, the regret becomes \(O(\sqrt{T N \log N} \cdot \mathbb{E}[D])\), scaling linearly with the expected delay. The _Q-UCB_ algorithm (for stochastic bandits) handles delays by maintaining an upper confidence bound that accounts for the number of _missing_ observations, not just the number of observations—an elegant modification that preserves the \(O(\sqrt{T \log T})\) instance-dependent regret under delayed feedback.

### 10.2 Nonstationary Bandits and Discounted UCB

When the reward distributions drift over time, the learner must "forget" old observations. The _discounted UCB_ algorithm (Kocsis and Szepesvári, 2006) applies a discount factor \(\gamma\) to past observations:

\[
\hat{\mu}_{t,a}^{\text{disc}} = \frac{\sum_{s=1}^{t-1} \gamma^{t-1-s} r*s \mathbf{1}*{\{A*s = a\}}}{\sum*{s=1}^{t-1} \gamma^{t-1-s} \mathbf{1}\_{\{A_s = a\}}}
\]

The confidence bound is rescaled by the effective sample size \(n*{t,a}^{\text{eff}} = \sum*{s < t} \gamma^{t-1-s} \mathbf{1}\_{\{A*s=a\}} \approx 1/(1-\gamma)\) when the process is near-stationary. For piecewise-stationary environments (abrupt changes at unknown times), the \_sliding-window UCB* maintains a window of the \(\tau\) most recent observations per arm, forgetting everything older than \(\tau\). The regret decomposes into the regret within each stationary segment plus the cost of re-learning after each change.

### 10.3 Smoothed Analysis and Beyond Worst-Case

The gap between worst-case theory (\(\sqrt{T}\) regret is necessary) and practical performance (much better on "real" data) has motivated _beyond worst-case_ analyses. In the _smoothed analysis_ framework (Spielman and Teng), the adversary's loss vectors are perturbed by small random noise. Under this perturbation, the regret of MWA drops from \(\Theta(\sqrt{T \log N})\) to \(O(\log T)\)—an exponential improvement. The intuition: noise breaks the adversarial correlations that force exploration, allowing the algorithm to quickly identify the best expert.

Similarly, the _stochastic bandit_ setting (where arm rewards are i.i.d.) admits instance-dependent logarithmic regret \(O(\sum\_{a : \Delta_a > 0} \frac{\log T}{\Delta_a})\) via the UCB1 algorithm, where \(\Delta_a\) is the suboptimality gap of arm \(a\). The KL-UCB algorithm (Cappé et al., 2013) achieves the asymptotically optimal constant \(1/\mathrm{KL}(\nu_a \| \nu^*)\) in the logarithmic term, matching the Lai-Robbins lower bound. These results show that the same algorithmic principles—optimism in the face of uncertainty, exponential weighting—are simultaneously optimal in both stochastic and adversarial environments, a property known as *best-of-both-worlds\*.

## 11. Online Learning and Differential Privacy

Differential privacy (Dwork et al., 2006) and online learning share a deep mathematical connection: both rely on controlling the sensitivity of outputs to individual inputs. In online learning, the _regret_ measures how much worse the learner performs compared to the best fixed expert; in differential privacy, the _privacy loss_ measures how much the output distribution changes when a single data point is modified.

### 11.1 The Tree-Based Aggregation Protocol

The _binary-tree mechanism_ (Dwork et al., 2010; Chan, Shi, and Song, 2011) solves the problem of privately releasing running sums \(S*t = \sum*{s=1}^t \ell_s\) under continual observation. The technique: maintain a binary tree over time steps, where each node stores a noisy version of the sum of its leaf range. To answer a prefix query \(S_t\), sum at most \(O(\log T)\) nodes in the tree. Each individual observation contributes to at most \(O(\log T)\) nodes, so by the Gaussian mechanism with appropriate noise scaling, the entire sequence of \(T\) outputs is \((\varepsilon, \delta)\)-differentially private with error:

\[
\max_t |\tilde{S}\_t - S_t| = O\left(\frac{\sqrt{\log(1/\delta)} \log^{3/2} T}{\varepsilon}\right)
\]

This error is polylogarithmic in \(T\), compared to the naive approach (adding independent noise to each \(S_t\)) which has error \(\Omega(\sqrt{T})\). The binary-tree mechanism directly yields a differentially private online learning algorithm: use the private prefix sums to estimate the cumulative loss of each expert, then apply the MWA update rule. The regret inflates additively by the privacy error, giving:

\[
R_T^{\text{private}} = O\left(\sqrt{T \log N} + \frac{\log^{3/2} T}{\varepsilon}\right)
\]

**Theorem 11.1 (Private Online Learning, Jain, Kothari, and Thakurta, 2012).** The Follow-the-Perturbed-Leader (FTPL) algorithm, where at each round the learner adds independent Laplace noise to each expert's cumulative loss, achieves \((\varepsilon, 0)\)-differential privacy with regret \(O(\sqrt{T \log N} + N\log T / \varepsilon)\). The noise masks the contribution of any single round's loss, preventing an adversary from inferring private information about the loss sequence from the learner's decisions.

### 11.2 The Exponential Mechanism and MWA

The MWA update rule \(w\_{t+1}(i) = w*t(i) \cdot e^{-\eta \ell_t(i)}\) is itself an instance of the \_exponential mechanism* from differential privacy: select a distribution over experts with probability proportional to \(\exp(\varepsilon \cdot \text{quality}(i) / 2\Delta)\), where the quality is the negative cumulative loss and sensitivity \(\Delta = 1\). This reveals that the MWA is inherently private—it only accesses loss information through aggregated, exponentiated weights—and explains why MWA-based algorithms are the building blocks of private collaborative filtering, private empirical risk minimization, and private bandit learning.

## 12. Game-Theoretic Equilibria, Calibration, and Internal Regret

The connection between online learning and game theory extends beyond the minimax theorem. A deeper concept is _calibration_: a forecaster is calibrated if, among days when it predicts "30% chance of rain," it actually rains 30% of the time. More generally, the forecaster's predictions should be statistically consistent with observed outcomes across all prediction-value subsets.

### 12.1 Internal Regret and Correlated Equilibria

While external regret compares against the best fixed expert, _internal regret_ compares against the best _transformation_ of the learner's own actions. For a sequence of actions \(a_1, \ldots, a_T\), the internal regret with respect to a pair of actions \((i, j)\) measures how much better off the learner would have been by replacing every occurrence of \(i\) with \(j\):

\[
R*{\text{int}}(i \to j) = \sum*{t=1}^T \mathbf{1}\_{\{a_t = i\}} (\ell_t(i) - \ell_t(j))
\]

An algorithm has _no internal regret_ if \(\max*{i,j} R*{\text{int}}(i \to j) \leq o(T)\). The _regret matching_ algorithm (Hart and Mas-Colell, 2000) achieves this by maintaining a matrix of cumulative regrets and choosing actions with probability proportional to positive regret:

\[
p*{t+1}(j) \propto \max\{0, R*{\text{int},t}(a_t \to j)\}
\]

**Theorem 12.1 (Convergence to Correlated Equilibrium).** If all players in a game use no-internal-regret algorithms, the empirical distribution of play converges to the set of _correlated equilibria_—a generalization of Nash equilibrium where players' actions may be correlated through shared signals. The set of correlated equilibria includes all Nash equilibria and is computationally tractable (a polytope defined by linear inequalities), unlike Nash equilibria which are PPAD-complete to compute. No-internal-regret dynamics thus provide a polynomial-time algorithm for computing approximate correlated equilibria in general-sum normal-form games.

### 12.2 Calibration as Online Learning

A forecaster outputs a predicted probability \(f*t \in [0,1]\) of a binary event each round, then observes outcome \(y_t \in \{0,1\}\). The forecaster is \_calibrated* if:

\[
\lim*{T \to \infty} \frac{1}{T} \sum*{t=1}^T (y*t - f_t) \cdot \mathbf{1}*{\{f_t \in I\}} = 0
\]

for every interval \(I \subseteq [0,1]\). Foster and Vohra (1998) showed that calibration is equivalent to no-internal-regret in a certain online learning game: define an "expert" for each pair (prediction interval, outcome), let the forecaster's action be the predicted probability, and define losses to penalize miscalibration. The _Foster-Vohra algorithm_—which predicts at round \(t+1\) the empirical frequency of \(y=1\) among past rounds with predictions similar to \(f\_{t+1}\)—achieves calibration and has no internal regret. This equivalence is one of the most elegant results bridging online learning and statistical decision theory.

## 13. Thompson Sampling and the Bayesian Perspective

An alternative to the frequentist (worst-case) regret framework is the _Bayesian_ approach, where the environment is assumed to be drawn from a known prior distribution, and the learner's goal is to maximize expected cumulative reward under this prior. _Thompson Sampling_ (Thompson, 1933) is the oldest bandit algorithm, yet it was largely overlooked for decades until empirical studies (Chapelle and Li, 2011) demonstrated its remarkable practical performance.

**Algorithm 5 (Thompson Sampling).** Maintain a posterior distribution over the parameters of each arm's reward distribution. At each round t: (1) Sample a parameter estimate for each arm from its current posterior. (2) Select the arm with the highest expected reward under the sampled parameters. (3) Observe the reward and update the posterior via Bayes' rule.

For Bernoulli bandits with Beta priors Beta(alpha, beta), the update is simply alpha <- alpha + r_t, beta <- beta + (1 - r_t) for the chosen arm. This makes Thompson Sampling as easy to implement as UCB1, with the added benefit of naturally incorporating prior knowledge.

**Theorem 13.1 (Agrawal and Goyal, 2012; Kaufmann, Korda, and Munos, 2012).** For the stochastic K-armed Bernoulli bandit, Thompson Sampling with Beta(1,1) priors achieves the asymptotically optimal regret R*T = O(sum*{a: Delta_a > 0} (log T) / KL(mu_a || mu^\*)), matching the Lai-Robbins lower bound. Here Delta_a is the suboptimality gap and KL is the Kullback-Leibler divergence between Bernoulli distributions.

The proof relies on the fact that Thompson Sampling's posterior probability that a suboptimal arm appears best decays exponentially in the number of times it has been pulled, because the posterior concentrates around the true mean at rate O(1/sqrt(n)). The optimal arm's posterior similarly concentrates, ensuring it is chosen with high probability after sufficient exploration.

**Practical advantages:** Thompson Sampling naturally balances exploration and exploitation: when uncertain (high posterior variance), it explores widely; when confident (low variance), it exploits. It handles non-stationarity gracefully via discounting, incorporates prior knowledge through informative priors, and extends to complex reward models—linear bandits, Gaussian processes, neural networks—through approximate posterior sampling (MCMC, variational inference, or bootstrap). These properties have made Thompson Sampling the algorithm of choice for online controlled experiments at Yahoo!, Google, and in adaptive clinical trial design.

**Connection to Best-of-Both-Worlds:** The _Tsallis-INF_ algorithm (Zimmert and Seldin, 2019) achieves both O(sqrt(K T)) regret in the adversarial setting and O(sum (log T)/Delta*a) in the stochastic setting \_simultaneously*, without knowing which regime applies. It uses a Tsallis entropy regularizer—generalizing the Shannon entropy of MWA—that interpolates between exponential weights (optimal for adversarial) and posterior sampling (optimal for stochastic). This best-of-both-worlds guarantee represents the current frontier of bandit algorithm design.

## 14. Summary

Online learning provides a rigorous framework for sequential decision-making under uncertainty. The multiplicative weights algorithm achieves \(O(\sqrt{T \log N})\) regret in the full-information setting; EXP3 achieves \(O(\sqrt{T N \log N})\) in the bandit setting. These bounds are optimal and the algorithms are simple. The connection to game theory yields constructive proofs of the minimax theorem and the convergence of no-regret dynamics to Nash equilibria. Adaptive regret bounds handle nonstationary environments. Contextual bandits extend the framework to incorporate side information. Knapsack constraints bring resource limits into the fold. And the deep ties to differential privacy and calibration reveal online learning as a fundamental paradigm that cuts across machine learning, optimization, game theory, and privacy.

For the practitioner, online learning algorithms are the basis of A/B testing frameworks (multi-armed bandits), online advertising (budgeted bidding), and recommendation systems (contextual bandits). The theoretical guarantees—sublinear regret, asymptotic optimality—translate into practical performance when the horizon is large enough.

To go deeper, Cesa-Bianchi and Lugosi's _Prediction, Learning, and Games_ is the definitive text. Bubeck and Cesa-Bianchi's survey "Regret Analysis of Stochastic and Nonstochastic Multi-armed Bandit Problems" covers the bandit setting exhaustively. And Hazan's "Introduction to Online Convex Optimization" extends the framework to general convex losses.
