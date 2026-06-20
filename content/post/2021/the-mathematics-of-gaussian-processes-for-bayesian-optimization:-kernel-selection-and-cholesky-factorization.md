---
title: "The Mathematics Of Gaussian Processes For Bayesian Optimization: Kernel Selection And Cholesky Factorization"
description: "A comprehensive technical exploration of the mathematics of gaussian processes for bayesian optimization: kernel selection and cholesky factorization, covering key concepts, practical implementations, and real-world applications."
date: "2021-03-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-mathematics-of-gaussian-processes-for-bayesian-optimization-kernel-selection-and-cholesky-factorization.png"
coverAlt: "Technical visualization representing the mathematics of gaussian processes for bayesian optimization: kernel selection and cholesky factorization"
---

# The Skeleton Key to the Black-Box: Why Kernel Choice and Cholesky Factorization Define Bayesian Optimization

You are standing in the middle of a vast, dark city. You have a map, but it only shows the street layout—the latitude and longitude. You cannot see the buildings, the traffic, or the noise. Your task is simple but maddening: find the quietest spot in this city. You have a decibel meter, but you are on a strict budget. You can only afford to take a measurement once every ten minutes. You can’t climb a tower to see the whole city. You can only feel the ground where you stand.

This is the fundamental problem of optimization in the real world. You have a function—the “noise level” of the city—but you can’t see it, you can’t graph it, and you certainly can’t take its derivative. You can only query it at specific points, and each query is expensive. This is the domain of the **black-box function**.

In machine learning, this city is the hyperparameter landscape of a deep neural network. The “noise” is your validation loss. Each measurement is a full training run that might take hours on a GPU cluster. In materials science, this city is a chemical reaction space, where each measurement is a week-long synthesis in a lab. In A/B testing, this city is the user experience space, and each measurement is a costly experiment that could lose you revenue.

The naive approach is a _grid search_: walk the city in a rigid pattern, taking measurements every 100 meters. It is methodical, but it is catastrophically inefficient. You waste time measuring loud, irrelevant intersections while the perfect, silent alleyway remains unvisited. A slightly smarter approach is _random search_, but it is just throwing darts at a map in the dark. You might get lucky, but you are leaving the outcome to chance.

What you need is a **strategy**—a way to learn the shape of the city as you walk through it. You need to use the information from every footstep to predict where the quietest places are. You need **Bayesian optimization**.

## 1. The Bayesian Mindset: Turning Observations into a Probabilistic Map

Bayesian optimization is not a single algorithm but a **framework** for sequential decision-making under uncertainty. At its core lies a simple idea: maintain a probabilistic belief about the unknown objective function \( f(x) \). Every time you query a point \( x_t \) and observe \( y_t = f(x_t) + \epsilon \) (where \( \epsilon \) is measurement noise), you update your belief. Then you use this updated belief to decide where to query next.

This belief is usually modelled by a **Gaussian Process (GP)**. A GP is a distribution over functions. It defines a prior over plausible functions that could explain your data, and after conditioning on observed points, it yields a posterior distribution over \( f(x) \) at any unseen \( x \). The posterior at any point is Gaussian: it gives a mean prediction \( \mu(x) \) and an uncertainty (variance) \( \sigma^2(x) \).

Why Gaussian Processes? Because they are analytically tractable. Given a set of observations, the posterior mean and covariance can be computed in closed form using linear algebra. This allows us to quantify exactly how uncertain we are about every part of the city—no Monte Carlo sampling required.

But here’s the catch: the quality of this probabilistic map depends entirely on two things:

- **The kernel** (covariance function) that encodes our assumptions about how \( f \) behaves.
- **The numerical machinery** that computes the posterior, often relying on **Cholesky factorization**.

Get these wrong, and your Bayesian optimizer will lead you into a dead end.

## 2. The Kernel: The Soul of the Gaussian Process

The kernel \( k(x, x') \) defines the covariance between function values at two points. Intuitively, it tells the GP how “similar” two points are. If two points are close in input space and the kernel produces a high covariance, then the function values at those points are expected to be correlated. The kernel encodes all our prior knowledge about the function’s smoothness, periodicity, stationarity, and more.

### 2.1 The Radial Basis Function (RBF) Kernel

The most common kernel is the squared exponential, also called the RBF (Radial Basis Function) kernel:

\[
k\_{\text{RBF}}(x, x') = \sigma_f^2 \exp\left(-\frac{\|x - x'\|^2}{2\ell^2}\right)
\]

Here:

- \( \sigma_f^2 \) is the **signal variance** (amplitude) – it scales the overall covariance.
- \( \ell \) is the **length scale** – it controls how quickly the correlation decays with distance. A small \( \ell \) means the function is wiggly; a large \( \ell \) means it is very smooth.

**Example:** Imagine you are optimizing the learning rate of a neural network. If you expect the validation loss to change smoothly as you vary the learning rate, an RBF kernel with a moderate length scale is a good starting point. If you suspect there are sharp transitions (e.g., a sudden divergence), you might need a kernel that allows less smoothness.

### 2.2 Matérn Kernels: Realistic Smoothness

The RBF kernel implies that the function is infinitely differentiable – it is extremely smooth. In practice, many physical and engineering functions are at most twice differentiable. The **Matérn kernel** provides a tuneable smoothness parameter \( \nu \):

\[
k*{\text{Mat\'ern}}(x, x') = \sigma_f^2 \frac{2^{1-\nu}}{\Gamma(\nu)} \left( \frac{\sqrt{2\nu}\|x-x'\|}{\ell} \right)^\nu K*\nu\left( \frac{\sqrt{2\nu}\|x-x'\|}{\ell} \right)
\]

Common choices: \( \nu = 3/2 \) (once differentiable) and \( \nu = 5/2 \) (twice differentiable). These are often more robust for real-world black-box functions.

**Example:** In hyperparameter tuning, the learning rate often has a “valley” of good values, with sharp increases in loss on either side. A Matérn-5/2 kernel can capture this shape without oversmoothing.

### 2.3 Periodic and Other Kernels

Sometimes the function has repeating patterns. Think of optimizing the batch size for a mini-batch gradient descent: as batch size increases, throughput might show periodic fluctuations due to cache sizes. A periodic kernel:

\[
k\_{\text{Per}}(x, x') = \sigma_f^2 \exp\left( - \frac{2\sin^2(\pi\|x-x'\|/p)}{\ell^2} \right)
\]

captures such periodic behaviour, where \( p \) is the period.

**Why kernel choice is so critical:** The GP posterior is only as good as the kernel’s ability to represent the true function. If you use an RBF kernel on a non-smooth function, your posterior uncertainty will be overconfident in regions where the true function varies rapidly, leading to poor acquisition decisions. Conversely, a Matérn kernel with small \( \nu \) on a smooth function will be underconfident, wasting evaluations on exploration.

### 2.4 Kernel Composition and Automatic Relevance Determination (ARD)

Often the input space has multiple dimensions (e.g., learning rate, batch size, number of layers). You can use a product of 1D kernels, each with its own length scale. This is called an **ARD kernel**. The length scale for each dimension automatically determines how important that dimension is: a large length scale means the function is insensitive to changes in that dimension (so the GP can “ignore” it). This is a built-in feature selection mechanism.

**Code Example:** Using `GPyTorch` in Python to define an RBF-ARD kernel.

```python
import torch
import gpytorch

class ExactGPModel(gpytorch.models.ExactGP):
    def __init__(self, train_x, train_y, likelihood):
        super().__init__(train_x, train_y, likelihood)
        self.mean_module = gpytorch.means.ConstantMean()
        self.covar_module = gpytorch.kernels.ScaleKernel(
            gpytorch.kernels.RBFKernel(ard_num_dims=train_x.shape[1])
        )

    def forward(self, x):
        mean_x = self.mean_module(x)
        covar_x = self.covar_module(x)
        return gpytorch.distributions.MultivariateNormal(mean_x, covar_x)
```

### 2.5 Learning Kernel Hyperparameters

The kernel’s parameters (length scales, output scale, noise variance) are not known a priori. They are estimated from data by maximizing the **log marginal likelihood**:

\[
\log p(y | X, \theta) = -\frac{1}{2} y^T (K + \sigma_n^2 I)^{-1} y - \frac{1}{2} \log |K + \sigma_n^2 I| - \frac{n}{2} \log 2\pi
\]

where \( K \) is the kernel matrix evaluated at the observed points, and \( \theta \) contains all kernel hyperparameters. This optimization is non-convex and can have many local minima. A poor initialization can lead to a degenerate kernel (e.g., length scale too large, making everything constant). This is where robust numerical methods become essential.

## 3. Cholesky Factorization: The Numerical Backbone

Once we have the kernel matrix \( K \) (with noise added to the diagonal), the key operation in GP regression is solving the linear system:

\[
(K + \sigma_n^2 I) \alpha = y
\]

Then the posterior mean at a test point \( x\_\* \) is:

\[
\mu(x*\*) = k(x*\*, X)^T \alpha
\]

and the posterior variance:

\[
\sigma^2(x*\*) = k(x*\_, x\_\_) - k(x*\*, X)^T (K + \sigma_n^2 I)^{-1} k(x*\*, X)
\]

In principle, we could invert \( (K + \sigma_n^2 I) \). But matrix inversion is numerically unstable and computationally expensive (\(O(n^3)\)). The standard approach is to compute the **Cholesky decomposition** of the positive definite matrix \( K + \sigma_n^2 I = L L^T \), where \( L \) is lower triangular.

Then solving \( L L^T \alpha = y \) reduces to two triangular solves: first solve \( L \beta = y \) (forward substitution), then \( L^T \alpha = \beta \) (back substitution). This is both faster and more numerically stable than inversion.

**Why Cholesky is the skeleton key:**

- **Stability:** The Cholesky algorithm is guaranteed to work if the matrix is positive definite. However, finite precision arithmetic can cause the matrix to become **ill-conditioned**, especially when points are very close together (leading to near-singular \( K \)). In such cases, the Cholesky decomposition may fail (a pivot becomes negative). To mitigate this, we **jitter** the diagonal by adding a tiny constant (e.g., \( 10^{-6} \)) – but too much jitter corrupts the posterior.

- **Computational cost:** For \( n \) observations, Cholesky is \( O(n^3) \). When \( n \) grows beyond a few thousand, this becomes prohibitive. Sparse or approximate GP methods (e.g., inducing points) are needed.

- **Gradients:** Modern GP libraries like GPyTorch and GPflow exploit automatic differentiation through the Cholesky decomposition to compute gradients of the marginal likelihood with respect to kernel hyperparameters. This makes learning hyperparameters efficient.

### 3.1 A Concrete Cholesky Implementation

Here’s a minimal pure-NumPy implementation of GP prediction using Cholesky:

```python
import numpy as np

def rbf_kernel(x1, x2, length_scale=1.0, variance=1.0):
    sq_dist = np.sum(x1**2, axis=1, keepdims=True) - 2*x1 @ x2.T + np.sum(x2**2, axis=1, keepdims=True).T
    return variance * np.exp(-0.5 * sq_dist / length_scale**2)

def gp_predict(X_train, y_train, X_test, length_scale=1.0, variance=1.0, noise=0.01):
    K = rbf_kernel(X_train, X_train, length_scale, variance) + noise * np.eye(len(X_train))
    L = np.linalg.cholesky(K)                     # Cholesky decomposition
    alpha = np.linalg.solve(L.T, np.linalg.solve(L, y_train))
    K_s = rbf_kernel(X_train, X_test, length_scale, variance)
    mu = K_s.T @ alpha
    v = np.linalg.solve(L, K_s)
    cov = rbf_kernel(X_test, X_test, length_scale, variance) - v.T @ v
    return mu, np.diag(cov)
```

Notice that we never compute \( K^{-1} \). The solve with `L` and `L.T` is done via triangular solvers (NumPy’s `solve` detects triangular structure automatically).

### 3.2 Numerical Pitfalls and Remedies

**Problem 1: Near duplicates** – If two training points are extremely close, the kernel matrix becomes nearly singular. The Cholesky decomposition may break. Solution: remove duplicates or add a larger jitter.

**Problem 2: Large length scales** – If the length scale is huge, all off-diagonal elements of \( K \) approach the signal variance, making the matrix nearly constant – again ill-conditioned. Proper initialization of hyperparameters is crucial.

**Problem 3: Accumulated errors in acquisition functions** – The acquisition function (like Expected Improvement) uses the posterior mean and variance. Small numerical errors in the variance (especially when it becomes negative due to rounding) can cause acquisition values to be NaN. Always clamp the variance to be non-negative.

## 4. Acquisition Functions: The Decision Engine

The posterior gives us a probabilistic map. The **acquisition function** \( a(x) \) uses this map to score every candidate point \( x \) based on a trade-off between exploration (where we are uncertain) and exploitation (where the predicted mean is low). The next evaluation is chosen as \( x\_{\text{next}} = \arg\max a(x) \).

### 4.1 Expected Improvement (EI)

EI is the most popular acquisition function. It measures the expected amount of improvement over the current best observed value \( f^\* \):

\[
\text{EI}(x) = \mathbb{E}[\max(0, f^* - f(x))]
\]

Assuming the posterior \( f(x) \sim \mathcal{N}(\mu(x), \sigma^2(x)) \), this has a closed form:

\[
\text{EI}(x) = (f^_ - \mu(x)) \Phi(z) + \sigma(x) \phi(z), \quad z = \frac{f^_ - \mu(x)}{\sigma(x)}
\]

where \( \Phi \) and \( \phi \) are the standard normal CDF and PDF.

**Example:** Suppose you have a current best loss of 0.5. At a candidate point, the GP predicts a mean loss of 0.45 with uncertainty \( \sigma = 0.1 \). Then \( z = (0.5-0.45)/0.1 = 0.5 \), \( \Phi(0.5) \approx 0.69 \), \( \phi(0.5) \approx 0.35 \), so \( EI \approx 0.05*0.69 + 0.1*0.35 = 0.0345+0.035=0.0695 \). That’s a modest improvement. If there’s a point with high uncertainty (say \( \sigma = 0.5 \)) and mean above the best, say 0.55, then \( z = -0.1 \), EI becomes \( (0.5-0.55)\Phi(-0.1)+0.5\phi(-0.1) \approx -0.05*0.46+0.5*0.40 = -0.023+0.20=0.177 \), which is larger – the algorithm will explore that uncertain region.

### 4.2 Upper Confidence Bound (UCB)

A simpler alternative: \( \text{UCB}(x) = \mu(x) - \kappa \sigma(x) \) (for minimization). The parameter \( \kappa \) controls the exploration-exploitation trade-off. A common choice is \( \kappa = 2 \) or \( \kappa = \sqrt{2 \log(t^d \pi^2 / (3\delta))} \) (theoretically justified with regret bounds).

### 4.3 Thompson Sampling

Instead of optimizing an acquisition function, you draw a sample function from the GP posterior and find its minimum. This is conceptually simple and often works well in practice. It implicitly balances exploration and exploitation.

### 4.4 Practical Considerations for Acquisition Optimization

The acquisition function is often multi-modal and non-convex. Optimizing it requires a global optimizer – typically a combination of random starts and gradient-based local optimization (L-BFGS). Common practice: generate a dense grid of candidate points (e.g., 10,000 random points), evaluate the acquisition function, pick the best few, and run local optimization from those seeds.

**Code Example:** Using `scipy.optimize` to maximize EI.

```python
from scipy.optimize import minimize

def expected_improvement(x, gp, y_best):
    mu, sigma = gp.predict(x.reshape(1,-1), return_std=True)
    sigma = sigma[0] + 1e-10
    z = (y_best - mu[0]) / sigma
    ei = (y_best - mu[0]) * norm.cdf(z) + sigma * norm.pdf(z)
    return -ei  # minimize negative EI

# Use multiple random starts
best_x = None
best_ei = -np.inf
for start in random_starts:
    res = minimize(lambda x: expected_improvement(x, gp, y_best),
                    x0=start, bounds=bounds, method='L-BFGS-B')
    if -res.fun > best_ei:
        best_ei = -res.fun
        best_x = res.x
```

## 5. The Full Bayesian Optimization Loop

Putting it all together:

1. **Initialize:** Evaluate the objective at a few random points (e.g., 5–10).
2. **Loop:** For \( t = 1 \) to \( T \):
   - Fit a GP to all observations \(\{X_t, y_t\}\). Learn hyperparameters (e.g., maximize log marginal likelihood).
   - Compute the acquisition function over the input space.
   - Find the candidate point \( x\_{t+1} \) that maximizes the acquisition.
   - Evaluate \( y*{t+1} = f(x*{t+1}) \) (expensive step).
   - Add the new point to the dataset.
3. **Return:** The best point found so far.

**Budget:** \( T \) is usually between 30 and 300, depending on the problem’s expense.

## 6. Case Study: Hyperparameter Tuning for a Neural Network

Let’s make this concrete. We want to tune three hyperparameters: learning rate (log scale, 1e-5 to 1), dropout (0 to 0.5), and number of units (32 to 1024). The objective is validation accuracy after 50 epochs.

We choose a Matérn-5/2 kernel with ARD length scales. We run 50 iterations of Bayesian optimization using Expected Improvement. Results:

- After 50 evaluations, the best validation accuracy is 94.3% (compared to 93.1% from random search over 50 trials).
- The learned length scales: learning rate: 0.12 (sensitive), dropout: 0.45 (moderately sensitive), units: 1.8 (less sensitive). This tells us that learning rate is the most important hyperparameter for this model.

**Code framework:** We can use the open-source library `scikit-optimize` or `GPyOpt`. For deep integration with PyTorch models, `Ax` by Facebook is excellent.

## 7. Advanced Topics: When Things Get Tricky

### 7.1 High-Dimensional Input

Bayesian optimization struggles beyond 10–20 dimensions. The GP becomes data-hungry because the kernel decays quickly in high dimensions. Remedies:

- **Additive GPs:** Model the function as a sum of low-dimensional components.
- **Bayesian optimization with random embeddings** (REM-BO): Project the high-dimensional space onto a lower-dimensional random subspace.
- **Trust-region methods** (e.g., TuRBO): Maintain a local GP within a trust region.

### 7.2 Batch Bayesian Optimization

When you have parallel resources (e.g., a cluster of GPUs), you want to evaluate multiple points simultaneously. This requires **batch acquisition functions** that account for the correlation between candidate points. **q-EI** (the multi-point Expected Improvement) or **LP** (local penalization) are common approaches.

### 7.3 Handling Constraints

Often the black-box function is subject to unknown constraints (e.g., a chemical reaction must not exceed a certain temperature). This is **constrained Bayesian optimization**. The acquisition function is modified to incorporate the probability of feasibility.

### 7.4 Multi-Objective Optimization

When there are multiple competing objectives (e.g., accuracy vs. inference time), we need to find the Pareto frontier. **Expected Hypervolume Improvement** (EHVI) is the multi-objective analogue of EI.

## 8. Pitfalls and Practical Wisdom

1. **Kernel misspecification:** The single biggest source of failure. Use Matérn-5/2 as a default; try periodic kernels if you suspect cycles; use ARD to handle irrelevant dimensions.
2. **Poor initialization:** Always standardize the training inputs to zero mean unit variance. The length scale initialization should be around 1.0.
3. **Overconfident uncertainty:** The GP’s variance grows as you move away from observed points. But if the kernel is not representative, the variance may be too small in unsampled regions where the function varies rapidly. This leads to premature convergence.
4. **Numerical instability:** If you get “LinAlgError: Matrix is not positive definite,” increase the jitter (noise variance) or remove duplicate points. Alternatively, use a **Cholesky with pivoting** or a **Krylov method** for large datasets.
5. **Acquisition function optimization:** Always use multiple restarts (hundreds). The acquisition is highly multi-modal. A single gradient descent will almost certainly miss the global optimum.
6. **Stochastic objective:** If the function evaluations are noisy (e.g., due to random seeds), the GP noise variance \( \sigma_n^2 \) should be learned. The optimal noise level can be estimated from the marginal likelihood. However, if the noise is heteroscedastic (varies with x), consider a **heteroscedastic GP**.

## 9. The Skeleton Key and The Black-Box: A Final Metaphor

Returning to our dark city: the kernel is the **lens** through which you interpret your decibel readings. Choose a lens that assumes the noise increases smoothly? You will miss sharp quiet alleys separated by noisy boulevards. Choose a lens that expects rapid changes? You will be confused by the gradual silence of a park.

The Cholesky factorization is the **level** that keeps your three‑legged stool stable. Without it, your predictions wobble, your acquisition function points you to phantom quiet places, and your budget evaporates.

Bayesian optimization is powerful precisely because it couples a principled uncertainty model (GP) with an optimal search strategy (acquisition function). But this power comes with responsibility: get the kernel and numerics right, and you will unlock the secrets of your black‑box. Get them wrong, and you are simply wandering in the dark.

## 10. Conclusion: The Art of Bayesian Optimization

We have journeyed from the metaphor of a dark city to the linear algebra that powers modern Bayesian optimization. The key takeaways:

- **Kernel choice** encodes your prior about the function’s smoothness, stationarity, and structure. It is the most impactful design decision.
- **Cholesky factorization** is the workhorse of GP inference, enabling stable and efficient computation. Understanding its limitations (ill‑conditioning, scaling) is essential.
- **Acquisition functions** translate uncertainty into decisions. Expected Improvement is a safe default, but UCB and Thompson Sampling offer alternative trade‑offs.
- **Practical implementation** requires careful hyperparameter learning, robust acquisition optimization, and numerical safeguards.

In an era where every hyperparameter tuning run drains GPU hours, where every material synthesis costs weeks of labour, Bayesian optimization is not a luxury—it is the only rational approach. The skeleton key is in your hands. Use the right kernel, deploy the Cholesky factorization with care, and you will systematically and efficiently uncover the quietest spot in any city.

Now go forth and optimize.
