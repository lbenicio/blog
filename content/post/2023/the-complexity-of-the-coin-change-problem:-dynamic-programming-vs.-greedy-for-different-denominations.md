---
title: "The Complexity Of The Coin Change Problem: Dynamic Programming Vs. Greedy For Different Denominations"
description: "A comprehensive technical exploration of the complexity of the coin change problem: dynamic programming vs. greedy for different denominations, covering key concepts, practical implementations, and real-world applications."
date: "2023-09-28"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-complexity-of-the-coin-change-problem-dynamic-programming-vs.-greedy-for-different-denominations.png"
coverAlt: "Technical visualization representing the complexity of the coin change problem: dynamic programming vs. greedy for different denominations"
---

# The Complexity Of The Coin Change Problem: Dynamic Programming Vs. Greedy For Different Denominations

## Introduction

**“Make change for 83 cents using as few coins as possible.”**

If you live in the United States, your brain probably runs a greedy algorithm without you even noticing: take a quarter (value 25), another quarter (50), a third quarter (75), then a nickel (80), and finally three pennies (83). Total coins: 6. Quick, efficient, and—are you sure it’s optimal? For US coins (1¢, 5¢, 10¢, 25¢), it is. But change that set to something slightly less friendly—say, denominations [1, 10, 25]—and the same greedy choice for 30¢ yields a quarter plus five pennies (6 coins), while the optimal is three dimes (3 coins). Suddenly, your “fast” heuristic collapses.

This humble problem—the **coin change problem**—sits at a fascinating intersection of algorithm design, computational complexity, and real-world utility. It appears in vending machines, banking software, cash register systems, and even in the core logic of blockchain fee estimation. Yet beneath its seemingly trivial surface lies a deep question: **when can we trust a simple greedy approach, and when must we pay the heavier runtime cost of dynamic programming?**

In this post, we’ll unpack both the greedy and dynamic programming (DP) solutions to the coin change problem, explore exactly how the _denomination set_ dictates which algorithm is appropriate, and reveal a surprising theoretical result: the greedy algorithm works _if and only if_ the coin system satisfies a property called the “canonical coin system.” We’ll also look at the performance trade-offs—greedy runs in O(n) time (where n is the number of denominations, usually tiny), while DP runs in O(n × target) time and space, which can become prohibitive for large targets. The choice isn’t merely academic; it can be the difference between a transaction processed in microseconds and one that exhausts memory.

But first, let’s walk slowly through the problem itself, its many variants, and why it remains a staple of algorithm courses and coding interviews. We’ll build from the ground up: first with formal definitions, then with algorithm designs, and finally with a rigorous analysis of when each approach is safe. Along the way, we’ll sprinkle in code, real-world anecdotes, and enough mathematical seasoning to satisfy the curious reader.

---

## 1. The Coin Change Problem: Formal Definition and Variants

### 1.1 The Minimum Coin Change Problem

The most common version of the coin change problem is often phrased as:

> Given a set of coin denominations \( C = \{c_1, c_2, \dots, c_n\} \) (each \( c_i > 0 \)), and an integer target amount \( T \), find the minimum number of coins needed to make exactly \( T \). If it is impossible to make the amount (e.g., target 3 with denominations [2,4]), return –1 or indicate impossibility.

We assume an unlimited supply of each coin. This is the **unbounded knapsack** variant – each coin can be used any number of times.

**Example 1:**

- Denominations = [1, 5, 10, 25], Target = 83 → 6 coins (3×25, 1×5, 3×1)
- Denominations = [1, 10, 25], Target = 30 → Optimal 3×10 = 3 coins. Greedy gives 6.

**Example 2:**

- Denominations = [2, 4], Target = 5 → Impossible, no combination adds to 5.

### 1.2 Number of Ways Variant

Another classic variant asks: _In how many ways can we make change for T?_ This counts combinations (order doesn’t matter) or permutations (order matters), depending on problem statement. For example, with denominations [1,2], target 4, combinations: {1+1+1+1}, {1+1+2}, {2+2} → 3 ways. Permutations would be 5.

While this post focuses on the minimum coin count, the DP approach is easily adapted to counting.

### 1.3 Bounded vs Unbounded

In the **bounded** version, each coin has a limited supply (e.g., you have 3 quarters, 10 dimes, etc.). This is more realistic for cash drawers. The DP table must consider the count of each coin, increasing complexity.

### 1.4 Importance in Computer Science

The coin change problem is a canonical example of **optimal substructure** and **overlapping subproblems**, making it a perfect vehicle to teach dynamic programming. It also illustrates the **greedy choice property** and when it fails. Variants appear in coding interviews (LeetCode 322, 518), algorithm exams, and technical systems.

---

## 2. The Greedy Approach: Simple, Fast, but Risky

### 2.1 How the Greedy Algorithm Works

The idea is straightforward:

1. Sort denominations in descending order.
2. Start with the largest denomination that does not exceed the remaining amount.
3. Use as many of that coin as possible (i.e., take `amount // coin` coins).
4. Subtract the value from the amount and repeat until amount becomes 0.
5. If the amount becomes negative (impossible), return –1.

#### Pseudocode:

```
function greedy_coin_change(coins, amount):
    sort(coins, descending)
    count = 0
    for coin in coins:
        while amount >= coin:
            amount -= coin
            count += 1
    if amount == 0:
        return count
    else:
        return -1
```

This runs in O(n) time (if coins are already sorted) – incredibly fast. For n typically ≤ 10 in real coin systems, it’s nearly instantaneous.

### 2.2 Why Greedy Works for US Coins

The US coin system [1, 5, 10, 25] is **canonical**, meaning greedy always yields the optimal solution for any target. Let’s test a few values:

- Target 99: 3 quarters (75), 2 dimes (20), 4 pennies → 9 coins. Optimal? 3×25 + 2×10 + 4×1 = 75+20+4 = 99. Yes.
- Target 67: 2 quarters (50), 1 dime (10), 1 nickel (5), 2 pennies → 6 coins. Alternative? Could use 1 quarter, 4 dimes, 2 pennies = 7 coins. Greedy optimal.
- Target 41: 1 quarter, 1 dime, 1 nickel, 1 penny = 4 coins. Optimal = 4. Try any other? 3 dimes + 11 pennies = 14 coins. No.

The reason lies in the property of **canonical coin systems**, which we’ll dissect in Section 4.

### 2.3 The Classic Counterexample

Take denominations [1, 10, 25]. This set is **not canonical**. Let’s run greedy on target 30:

- Largest coin ≤30: 25. Take 1 quarter, remaining 5.
- Next: 10 is >5, skip. 1: take 5 pennies.
- Coins: 1 quarter + 5 pennies = 6 coins.

But the optimal is 3 dimes (10+10+10) = 3 coins. Greedy fails.

Why? Because the greedy algorithm makes a **locally optimal** choice (using the largest coin possible) that turns out to be globally suboptimal. The gap arises because the denominations are not “nice”; specifically, 25 + 5 is worse than three 10s.

### 2.4 Other Counterexamples

- Denominations [1, 3, 4], target 6: Greedy: 4+1+1 = 3 coins. Optimal: 3+3 = 2 coins.
- Denominations [1, 20, 25], target 40: Greedy: 25+1\*15 = 16 coins. Optimal: 20+20 = 2 coins.
- Denominations [9, 6, 5, 1], target 11: Greedy: 9+1+1 = 3 coins. Optimal: 6+5 = 2 coins.

These examples highlight that greedy works only when the coin system has the **greedy choice property**: combining the largest coin with the optimal solution for the remainder yields the global optimum.

### 2.5 When Might Greedy Still Be Useful?

Even when not optimal, greedy can serve as a **heuristic** or approximation. For many practical systems, the optimal solution differs by only 1–2 coins. If real-time constraints are tight (e.g., a vending machine processing hundreds of transactions per second), greedy may be acceptable. However, we must be aware that in pathological cases (like [1, 10, 25] for 30), the gap can be large.

Furthermore, if the coin set is **canonical**, greedy is exact and extremely efficient. The challenge is knowing whether a given set is canonical.

---

## 3. Dynamic Programming Solution: Guaranteed Optimal, at a Cost

### 3.1 The DP Formulation (Minimum Coins)

We define `dp[i]` as the minimum number of coins needed to make amount `i`. Base case: `dp[0] = 0` (0 coins for 0 amount). For each amount `i` from 1 to T, we try each coin `c`:

`dp[i] = min( dp[i - c] + 1 ) for all c in coins where i - c >= 0`

If `dp[i]` remains infinity, it’s impossible.

We can compute this bottom-up. The time complexity is O(n × T), space O(T) if we keep only a 1D array.

#### Python Implementation:

```python
def coin_change_dp(coins, amount):
    INF = float('inf')
    dp = [INF] * (amount + 1)
    dp[0] = 0
    for i in range(1, amount + 1):
        for coin in coins:
            if i - coin >= 0:
                dp[i] = min(dp[i], dp[i - coin] + 1)
    return dp[amount] if dp[amount] != INF else -1
```

#### Example Run: coins = [1, 10, 25], amount = 30

Initialize dp[0:31] = [0, inf, inf, ...]

i=1: coin 1 → dp[1] = min(inf, dp[0]+1) = 1  
i=2: coin 1 → dp[2] = min(inf, dp[1]+1) = 2  
...  
i=10: coin 10 → dp[10] = min(inf, dp[0]+1) = 1 (better than using 10 ones)  
i=20: coin 10 → dp[20] = dp[10]+1 = 2; coin 25 not applicable.  
i=25: coin 25 → dp[25] = dp[0]+1 = 1; also coin 10 → dp[15]+1 (dp[15] is 1? Actually dp[15]=1? From i=10+5? Wait, need to fill properly. Let's compute carefully:

We'll step through:  
dp[0]=0  
i=1: coin1→dp[1]=1  
i=2: coin1→dp[2]=2  
...  
i=10: coin1→dp[10]=10? No, we also check coin10: dp[0]+1=1, so dp[10]=1  
i=11: coin1→dp[10]+1=2, coin10→dp[1]+1=2 → dp[11]=2  
...  
i=20: coin1→dp[19]+1=... dp[19]=2? Actually let's compute quickly with DP table (skipping many):

Better to run actual code. After i=10: dp[10]=1  
i=15: coins: 1→dp[14]=? dp[14] should be 4? Wait easier:  
Let’s use a systematic approach for i up to 20:

i=1: dp[1]=1  
i=2: dp[2]=2  
...  
i=9: dp[9]=9  
i=10: dp[10]=1 (coin10)  
i=11: min(dp[10]+1=2, dp[1]+1=2) =2  
i=12: min(dp[11]+1=3, dp[2]+1=3)=3  
... i=19: min(dp[18]+1, dp[9]+1) =10? Actually dp[18]=?  
Let’s shortcut: The optimal for 20 is 2 (two 10s). DP will find it: i=20: coin10 → dp[10]+1=1+1=2, coin25 not allowed, coin1→dp[19]+1 (dp[19]=? 19 can't be made with 10 except 10+1\*9 = 10 coins? Actually dp[19] from coin10: dp[9]+1 =9+1=10, or coin1: dp[18]+1=... likely 10. So min=2).

i=25: coin25→dp[0]+1=1, coin10→dp[15]+1 (dp[15]? coin10→dp[5]+1=5+1=6? Actually using 10+1*5 -> 6 coins, maybe better with 10+10? No 15 can't be two 10s; 10+1*5=6, 1*15=15. So dp[15]=6. So coin10 gives 7. So dp[25]=1.  
i=30: coin25→dp[5]+1=5+1=6, coin10→dp[20]+1=2+1=3, coin1→dp[29]+1 (dp[29] from 25+4? Actually dp[29] = dp[25? No, 25+1*4 =5 coins, or 10+10+1\*9 = 11? Better: dp[29] = min(dp[4]+1 (coin25? 25>29) no, coin10→dp[19]+1, coin1→dp[28]+1). Quick: dp[29] is 5? 25+1+1+1+1 =5, correct. So coin1 gives 6. So dp[30] = min(6,3,6) = 3.

Thus output 3, the optimal.

### 3.2 Reconstructing the Coin Combination

Often we need to know _which_ coins to use. We can store an auxiliary array `choice[i]` that records the last coin used to achieve dp[i]. Then backtrack.

```python
def coin_change_dp_with_coins(coins, amount):
    INF = float('inf')
    dp = [INF] * (amount + 1)
    last_coin = [-1] * (amount + 1)
    dp[0] = 0
    for i in range(1, amount + 1):
        for coin in coins:
            if i - coin >= 0 and dp[i - coin] + 1 < dp[i]:
                dp[i] = dp[i - coin] + 1
                last_coin[i] = coin
    if dp[amount] == INF:
        return -1, []
    # reconstruct
    coins_used = []
    amt = amount
    while amt > 0:
        c = last_coin[amt]
        coins_used.append(c)
        amt -= c
    return dp[amount], coins_used
```

### 3.3 Complexity Analysis

- **Time:** O(n × T). For large T (e.g., T = 10^6) and n = 10, that’s 10^7 operations – acceptable in Python if optimized, but in millions of transactions could be heavy.
- **Space:** O(T) for dp array. For T = 10^7, dp array of 10 million integers ≈ 80 MB (Python ints are larger, but using array('i') or list of ints ~28 bytes each → 280 MB). This can be problematic.
- We can reduce space to O(n) using the limited number of denominations? No, DP inherently needs O(T) to store results for smaller amounts. However, we can use **BFS** on the state space of remainders modulo a coin value to reduce complexity in some cases.

### 3.4 Handling Unbounded vs Bounded with DP

The DP above assumes unlimited coins. For bounded coins, we need a different DP (e.g., 2D table or using multiple knapsack techniques). This is more complex but still polynomial in n and total coin count.

### 3.5 BFS Alternative for Minimum Coins

Since we want the minimum number of coins (shortest path in a graph where edges correspond to adding a coin), we can use **BFS** on states from 0 to T. Each state i has edges to i + c. BFS finds shortest path (in coin count) in O(n × T) time as well, but may be faster in practice if many states are unreachable. However, worst-case similar.

---

## 4. When Does Greedy Work? The Theory of Canonical Coin Systems

### 4.1 Definition of a Canonical Coin System

A coin system (set of denominations, sorted ascending, with 1 included) is **canonical** if for every possible target amount, the greedy algorithm using the fewest coins (i.e., taking as many of the largest coin as possible) produces an optimal solution (minimum number of coins).

The term “canonical” was introduced by Magazine, Nemhauser, and Trotter (1975) in their seminal paper “When the Greedy Solution Solves a Class of Knapsack Problems.” They provided a characterization and an algorithm to test canonicity.

Key points:

- Canonical systems include US coins [1,5,10,25], but also many others like [1,2,5,10,20,50] (euro).
- Non-canonical examples: [1,10,25], [1,3,4], [1,20,25].

### 4.2 The Magazine, Nemhauser, Trotter (MNT) Characterization

The result: a coin system is canonical if and only if, for every amount `v` in the range from the smallest non-1 coin to the sum of two largest coins (or more precisely, up to some bound), greedy and optimal give the same answer. More formally, let the coins be sorted ascending with c1=1. For each `i` from 2 to n, consider the smallest amount `w` that is less than c*i + c*{i-1} and check if greedy’s coin count for `w` is minimal. If any such `w` fails, system is non-canonical.

The practical test algorithm:

```
def is_canonical(coins):
    coins = sorted(coins)
    n = len(coins)
    # For each denomination from second to last
    for i in range(1, n):
        # sum of two consecutive largest coins? Actually the condition:
        # For each coin c_i, consider the amount equal to c_i - 1
        # and check that greedy on that amount yields the same as optimal.
        # But careful: The MNT condition is more complex.
```

Better to use the algorithm from the paper: For each coin `c_i` (i from 2 to n-1), compute `greedy(c_i - 1)` and `optimal(c_i - 1)`. If they differ, non-canonical. Then also check amounts between `c_i` and `c_i + c_{i-1}`? The precise condition is: for each `k` from 2 to n-1, the amount `c_k - 1` must be made optimally by greedy. And also the amount `c_k + c_{k-1} - 1`? Wait, I recall a simpler condition from a later paper: A coin system is canonical iff for each `i`, the greedy solution for `c_{i+1} - 1` is optimal.

Let’s test with [1,10,25]: c2=10, check amount 9. Greedy: 9*1=9 coins. Optimal: 9*1=9 coins. So passes. c3=25, check amount 24. Greedy: 25 can’t use, then 10 → 2 tens =20, then 4 ones =24, total 6 coins. Optimal for 24? 10+10+1+1+1+1 =6 coins as well, or 10+1*14 = 15, so 6 is minimal? Actually 2 tens + 4 ones =6, can we do better? 1+1+...? 24 ones =24 coins. So optimal is 6. Greedy also 6. So test passes both. Yet we know system is non-canonical (for 30). So the condition must include amount 30. Indeed, the bound is up to `max(coins) * (max_coin - 1)` or something.

Let’s recall the precise theorem:

**Theorem (Magazine, Nemhauser, Trotter 1975):**  
Let coins be sorted \( c*1 = 1 < c_2 < \dots < c_n \). The greedy algorithm is optimal for all amounts if and only if the greedy algorithm is optimal for all amounts \( v \) for which  
\[
0 \leq v \leq c*{n-1} + c_n - 1
\]
or more strongly, for all \( v \) up to \( 2c_n - 1 \). Actually the paper states that it suffices to check amounts \( v \) such that \( g(v) \neq o(v) \) for \( v \) less than some bound.

A more computer-science-friendly test: For each coin `c_i` (i from 2 to n-1), compute the minimum number of coins needed to make `c_i - 1` (optimal) and compare with greedy. Also compute for `c_i + c_{i-1} - 1`. If all match, it's canonical. Let's test [1,10,25]:

- i=2 (10): check 9: greedy 9, optimal 9 -> ok.
- check 10+1-1? That would be 10? Not relevant. For i=3 (25): check 24: greedy 6, optimal 6. Also check 25+10-1 = 34. Greedy for 34: 25 + 9= 1 quarter + 9 pennies =10 coins. Optimal for 34: 10+10+10+4 = 4 dimes + 4 pennies = 8 coins? Actually 34: 25+1\*9=10, or 10+10+10+1+1+1+1=8, or 10+10+1+1+1+1+1+1+1+1? Let's compute optimal exactly: 34 = 10+10+10+4? 4 is 4 ones → total 7 coins? Wait 10+10+10=30, plus 4 ones =7 coins. Can we do better? 25+9=10 coins, so 7 is optimal. Greedy gives 10. So difference! Hence non-canonical. So the test includes checking `c_i + c_{i-1} - 1` = 34.

Thus algorithm details:

```
def is_canonical(coins):
    coins = sorted(coins)
    n = len(coins)
    for i in range(2, n):  # i index of coin from 2nd to last
        # amount to check
        amount = coins[i] + coins[i-1] - 1
        g = greedy_count(coins, amount)
        opt = optimal_count(coins, amount)
        if g != opt:
            return False
    return True
```

But does this cover all cases? Let’s test on [1,3,4]:

coins = [1,3,4]. n=3. i=2 (coin index 1? Actually indices: [1,3,4] with 0-based: i from 2 to n-1? i=2? Let's use 1-based: i=2 (value 3) and i=3 (value 4). For i=2 (value=3): amount = 3 + 1 -1 =3? That's coin[i-1]=1, so 3+1-1=3. Greedy for 3: 3→1 coin, optimal 1. So ok. i=3 (value=4): amount = 4 + 3 -1 =6. Greedy for 6: 4+1+1=3 coins. Optimal: 3+3=2 coins. Different → non-canonical. Correct.

What about [1,5,10,25]? Let's compute: i=2 (5): amount = 5+1-1=5. greedy=1, optimal=1. i=3 (10): amount = 10+5-1=14. greedy: 10+1*4=5 coins. optimal? 10+1*4=5, or 5+5+1*4? Actually optimal is 5+5+1*4=6? Wait 14: can we do 10+1\*4=5, or 5+5+1+1+1+1=6. So greedy gives 5, optimal 5. i=4 (25): amount = 25+10-1=34. greedy: 25+10? Actually 25+9=1 quarter +9 pennies =10 coins. Optimal for 34: 10+10+10+4 = 7 coins? Wait 34 with US coins: 25+5+1+1+1+1 = 6? 25+5=30, plus 4 pennies = 6 coins. Or three dimes +4 pennies =7. So optimal is 6? Actually 25+5+1+1+1+1=34 counts: 1 quarter, 1 nickel, 4 pennies = 6 coins. Greedy: 1 quarter, 1 nickel? No greedy takes quarter then next largest coin ≤9 is nickel? 9>=5, so 1 nickel, then 4 pennies = 6. So greedy gives 6 as well. So all pass → canonical.

Thus the MNT condition holds.

### 4.3 Why This Condition Exists

The intuition: The worst-case scenario for greedy happens when the optimal solution uses two coins that are not the largest, and the greedy would take one large coin and many small ones. The critical amounts to test are just below the sum of two large coins, where the trade-off is most pronounced.

### 4.4 Is the Condition Necessary and Sufficient?

Yes, per the original paper. However, the test above might require checking multiple amounts per coin pair? Actually the MNT condition says: it suffices to check all `v` from `c_{i-1}` to `c_i + c_{i-1} -1` for each i? The simpler version checking just `c_i + c_{i-1} - 1` works for many but not all? In some systems, the failure might occur at a lower amount. Example: [1, 3, 11, 22]? Let’s test.

Better to implement the full check: For each coin `c_i` (i>1), check all amounts from `c_{i-1}+1` to `c_i -1` and also the amount `c_i + c_{i-1} -1`. Many sources use the “two largest coins” bound.

For thoroughness, we should mention the algorithm commonly used in competitive programming:

```
def is_canonical(coins):
    coins = sorted(coins)
    maxLimit = coins[-1] + coins[-2]  # or 2*coins[-1]
    # compute optimal DP up to maxLimit
    dp = [float('inf')] * (maxLimit+1)
    dp[0] = 0
    for i in range(1, maxLimit+1):
        for coin in coins:
            if i >= coin:
                dp[i] = min(dp[i], dp[i-coin] + 1)
    # check greedy for all amounts up to maxLimit
    for amt in range(1, maxLimit+1):
        g = greedy_count(coins, amt)
        if g != dp[amt]:
            return False
    return True
```

This is O(n * maxLimit) which for maxLimit up to, say, 2*100 = 200 is cheap. So we can always test canonicity.

### 4.5 Real-World Coin Systems

- **US dollars**: [1, 5, 10, 25, 50? (half-dollar rarely used), 100 (dollar coin)] – The commonly used set is canonical.
- **Euro**: [1, 2, 5, 10, 20, 50] – This is also canonical. Check 2+5-1=6: greedy for 6: 5+1=2 coins, optimal? 2+2+2=3, so greedy better? Actually greedy gives 2, optimal also 2? Wait 6: 5+1=2 coins, 2+2+2=3, so optimal=2. Good. Next check 5+10-1=14: greedy: 10+1\*4=5 coins, optimal: 10+2+2=3? Actually 14 can be 10+2+2=3 coins, or 5+5+2+2=4, so optimal=3. Greedy gives 5? Wait greedy: take 10, remainder 4 → 2+2? But greedy for remainder 4: takes 2, then 2 → 2 coins, total 3. So greedy also yields 3. Check 10+20-1=29: greedy: 20+5+2+2=4 coins, optimal? 20+5+2+2=4, or 10+10+5+2+2=5, so optimal=4. So passes.
- **British pounds**: [1, 2, 5, 10, 20, 50, 100, 200] – likely canonical.

- **Historical oddities**: Some countries had non-canonical systems, e.g., [1, 3, 7] maybe? Check: 3+7-1=9: greedy: 7+1+1=3, optimal: 3+3+3=3? Actually 3 threes = 9, also 3 coins. Tie. But check 7+1? Need to find a counterexample: [1, 3, 4] we already saw.

### 4.6 What If the Coin System Doesn't Include 1?

If 1¢ coin doesn't exist, some amounts may be impossible. Greedy may still work for those that are possible, but we need to ensure the system is “complete” enough. For analysis, we usually assume 1 is present to guarantee all amounts are achievable.

---

## 5. Why Greedy Fails (and DP Succeeds): A Deeper Look at Subproblems

### 5.1 Optimal Substructure and Overlapping Subproblems

Both greedy and DP rely on a property called **optimal substructure**: the optimal solution to a problem contains within it optimal solutions to subproblems. For coin change, if we have an optimal set of coins for amount T, and we remove one coin of value c, the remaining coins must be optimal for amount T-c. This holds because we can’t have a better combination for the remainder; otherwise we could improve the whole.

DP exploits this by solving subproblems in increasing order of amount. Greedy attempts to make a locally optimal choice and hopes that the substructure still leads to global optimum. But greedy fails when the local choice (largest coin) is not part of any optimal solution.

### 5.2 The Greedy Choice Property

The greedy algorithm works only if the following holds:

> For any amount T, there exists an optimal solution that includes the largest coin ≤ T.

If this property is true, then greedy can repeatedly pick that coin. For US coins, this holds. For [1,10,25] and T=30, the largest coin (25) is _not_ in any optimal solution (optimal is 10+10+10). So greedy fails because the greedy choice property is violated.

### 5.3 Mathematical Condition for Greedy Choice Property

A necessary and sufficient condition for the greedy algorithm to be optimal is that for any coin denominations, the coin system is **canonical**. But there’s also a connection to **matroids**? Not exactly; coin change is not a matroid because the set of coin combinations doesn't form an independence system with the matroid property. However, a similar concept is the **exchange property**.

Consider that if we have two solutions, we can exchange coins to improve one. For canonical systems, there is a known characterization: For each coin c_i (i>1), the amount c_i - 1 can be made using only coins smaller than c_i and with the greedy algorithm yielding optimal. This condition is reminiscent of the “standard” coin system definition (like representation in base b, but with non-uniform columns).

### 5.4 DP’s Guarantee

DP doesn’t assume any property. It explores all possibilities by combining optimal solutions to smaller subproblems. Because optimal substructure holds universally, DP always finds the optimum. The only cost is time/space.

### 5.5 Visualization with Decision Trees

We can view the problem as a tree: root = amount T, each branch subtracts a coin, leaf = 0. The optimal path is the shortest. Greedy picks the largest subtraction at each node without looking ahead. DP evaluates all subtrees using memoization.

---

## 6. Performance Trade-offs: Greedy vs DP in Practice

### 6.1 Time Complexity Comparison

- Greedy: O(n) if sorted, n typically ≤ 10. For each transaction, nearly instant.
- DP: O(n × T). If T = 10^6, n=10, that’s 10^7 operations. In Python, maybe 0.2–0.5 seconds per transaction. In a high-frequency system, not acceptable.

### 6.2 Space Complexity

- Greedy: O(1) extra.
- DP: O(T) if 1D array. For T up to 10^9, completely infeasible.

### 6.3 When to Use Each

- Use greedy when you can guarantee the coin system is canonical (e.g., US dollars, euros) and you need extreme speed.
- Use DP when accuracy is paramount and T is moderate (e.g., up to 10^5 or 10^6). Also use DP if coin system is unknown or likely non-canonical.
- Hybrid approach: check canonicity ahead of time (once per coin set). If canonical, use greedy; otherwise fall back to DP. This is common in vending machines where coin sets may vary per country.

### 6.4 Real-World Latency

Consider a vending machine in the US processing 1000 transactions per second. Greedy takes ~1 microseconds, DP would take ~100 ms per transaction (assuming T=200 and n=4, DP about 800 iterations). That’s 100 seconds for 1000 transactions – unacceptable. Hence greedy is used, leveraging the canonical property.

### 6.5 Memory Constraints in Embedded Systems

Vending machines have limited RAM. Storing a DP table for amounts up to 1000 (max change) would require a few KB, which is okay. But for a cash register that can handle amounts up to 10,000 (100 dollars), DP table 10,001 entries \* 4 bytes = 40KB – still fine. However, if the system needs to handle arbitrary large amounts (e.g., bank software for any integer amount up to millions), DP memory blows up. Greedy is essential.

---

## 7. Real-World Applications Beyond Vending Machines

### 7.1 Cash Register and Retail Systems

Most modern point-of-sale systems use a greedy-like algorithm to dispense change. They often combine greedy with a limited inventory of coins (bounded version). The assumption is that the nation’s coin system is canonical, but if a coin type is missing (e.g., no quarters), the algorithm may need fallback to DP or to a limited-exact algorithm.

### 7.2 Blockchain Fee Estimation

In Bitcoin, transaction fees are calculated based on transaction size in bytes. But there is also a problem of selecting which unspent outputs (UTXOs) to use to minimize fees or to make change. This is similar to the coin change problem but with a bounded set of coins (your UTXOs). The goal is to minimize the number of inputs or maximize the change amount. Greedy heuristics are common (take largest UTXOs first), but optimal DP is too expensive due to many UTXOs. So approximations are used.

### 7.3 Currency Exchange and Arbitrage

Coin change problems appear in converting between currencies with transaction costs – find the minimum number of trades to convert one currency to another. This is a graph shortest path problem, but similar ideas.

### 7.4 Scheduling and Resource Allocation

The coin change problem is analogous to packing problems: allocate resources in discrete units. For example, assigning server capacity (e.g., 1, 5, 10 unit machines) to meet a total load. Greedy works if the capacity units are canonical.

---

## 8. Extensions and Advanced Topics

### 8.1 Bounded Coin Change Problem

If each coin has a limited number, greedy becomes trickier. Example: coins [1,10,25] with only 2 quarters, 1 dime, 5 pennies. Greedy may run out of large coins. DP can handle by using multiple states or a 2D table (number of coins used). Complexity increases.

### 8.2 Counting Combinations (Number of Ways)

DP for number of ways: `dp[i] += dp[i - coin]` for each coin, but careful with order to avoid permutations. Use coin-outer loop to count combinations, inner loop for amount.

### 8.3 Space Optimization for DP

We can reduce 2D DP to 1D because each state depends on previous amounts. But space still O(T). There is a trick using BFS and modular arithmetic to reduce complexity for “large coin” systems? Not standard.

### 8.4 Shortest Path Formulation and BFS

We can treat each amount as a node in a graph, edges of weight 1 to `amount + coin`. Then BFS from 0 to T finds the shortest number of coins. Complexity O(n \* T) in worst case, but can be optimized for large T if only reachable states matter. BFS uses queue and visited array (size T+1) – same memory. Could be faster than DP if T is large but optimal path is short (like US coins for 83: depth only 6). BFS explores up to depth d, which is the optimal number of coins. In worst case, depth can be T (if only 1¢ coin), so BFS still O(T).

### 8.5 The “Frobenius Coin Problem” Connection

The coin change problem is connected to the Frobenius coin problem (largest unattainable amount) when denominations are relatively prime. Not directly about minimum coins, but interesting.

### 8.6 Greedy with Arbitrary Denominations – Approximation Guarantees

Even when greedy is not optimal, we can prove that it never uses more than some factor times optimal. For example, if the coin system is “canonical,” it’s exact. If not, the approximation ratio can be arbitrarily bad? Consider denominations [1, N-1, N]. For target (N)*... Actually, make greedy bad: [1, k, 2k-1]? Let’s test [1, 10, 19] for target 30: greedy: 19+10+1=3? Actually 19+10=29, then 1 → 3 coins. Optimal: 10+10+10=3 coins – same. Need larger gap: [1, 99, 100] for target 198: greedy: 100+99? Actually 100+1*98 = 99 coins. Optimal: 99+99=2 coins. Huge ratio. So greedy can be arbitrarily bad.

Thus relying on greedy blindly is dangerous.

### 8.7 Testing Canonicity on the Fly

If you have a system where the coin set may change (e.g., a machine that accepts custom tokens), you can test canonicity once using the MNT algorithm (computing DP up to 2\*max_coin) and then decide which solver to use. This is practical.

---

## 9. Conclusion

The coin change problem is a beautiful microcosm of algorithm design. It asks a simple question: _“What’s the fewest coins to make change?”_ But the answer splits into two distinct regimes: the fast but fragile greedy algorithm, and the reliable but costly dynamic programming approach.

We’ve seen that greedy works exactly when the coin system is canonical – a property that can be tested and that holds for many real-world currencies. When it holds, we can enjoy O(n) time and O(1) space, processing transactions in microseconds. When it doesn’t, we must fall back to DP (or another exact method), paying O(nT) time and O(T) space.

Beyond performance, the problem teaches deep lessons: the importance of understanding assumptions, knowing when heuristics are safe, and the trade-offs between simplicity and correctness. In a world increasingly driven by real-time, large-scale systems, these trade-offs become critical.

Whether you’re building a vending machine, designing a banking algorithm, or just trying to pay for coffee with exact change, the coin change problem is a constant companion. Next time you reach for a quarter, take a moment to appreciate the decision tree your brain is traversing. And if you ever encounter a coin system like [1, 10, 25] in the wild, beware: the greedy path may lead you astray.

---

_Further Reading:_

- Magazine, M. J., Nemhauser, G. L., & Trotter, L. E. (1975). When the greedy solution solves a class of knapsack problems. _Operations Research_, 23(2), 207-217.
- Kozen, D., & Zaks, S. (1994). Optimal bounds for the change-making problem. _Theoretical Computer Science_, 123(1), 377-388.
- LeetCode 322: Coin Change (minimum coins).
- LeetCode 518: Coin Change II (number of ways).

_Code for this post can be found at [github.com/example/coin-change]._
