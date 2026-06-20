---
title: "A Rigorous Analysis Of The Texas Hold’Em Poker Endgame: Nash Equilibrium And Cfr+ (Counterfactual Regret Minimization)"
description: "A comprehensive technical exploration of a rigorous analysis of the texas hold’em poker endgame: nash equilibrium and cfr+ (counterfactual regret minimization), covering key concepts, practical implementations, and real-world applications."
date: "2022-10-28"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/a-rigorous-analysis-of-the-texas-hold’em-poker-endgame-nash-equilibrium-and-cfr+-(counterfactual-regret-minimization).png"
coverAlt: "Technical visualization representing a rigorous analysis of the texas hold’em poker endgame: nash equilibrium and cfr+ (counterfactual regret minimization)"
---

# The Poker Endgame: How Mathematics Conquered the River

## Introduction: The Theater and the Skeleton

The clatter of chips. The slow, deliberate slide of cards across green felt. The sudden, sharp intake of breath as a player makes a decision worth thousands of dollars, perhaps their entire tournament life. Poker, particularly Texas Hold’Em, is a theater of human psychology, a contest of nerve, intuition, and the ability to detect a bluff across a dimly lit table. Or so the romantic narrative goes.

But beneath that veneer of human drama lies a far colder, more deterministic beast. For decades, the most insightful players have spoken about the game in terms of edge, equity, and expected value. They know that while luck dominates a single hand, mathematics governs the long run. The best players don’t just read opponents; they calculate ranges and exploit tendencies. Yet, for all their skill, even the world champions operated with heuristic shortcuts—rules of thumb born from experience. They guessed. They _felt_ their way toward optimal play.

In 2017, that era ended. When the AI program Libratus, developed by Carnegie Mellon’s Noam Brown and Tuomas Sandholm, decisively beat four top human professionals in a 120,000-hand heads-up (two-player) no-limit Texas Hold’Em match, it did more than win a game. It brought poker’s hidden skeleton into the light. The AI didn’t win by reading tells. It won by computing something abstract yet profoundly concrete: a Nash Equilibrium for a game of imperfect information, using an algorithm known as Counterfactual Regret Minimization (CFR), and its powerful successor, CFR+.

This is not a blog post about how to bluff on the river. This is a blog post about the mathematics of perfect play in an inherently uncertain world. It is a rigorous analysis of the poker endgame, and why the final, furious round of betting is the most computationally interesting, the most psychologically rich, and the most mathematically solvable part of the game. Understanding this requires stripping away the romance and looking at hands, chips, and decisions as nodes in a tree of uncertainty—a tree that we can now solve to near-perfection.

## The Nature of Imperfect Information

To understand why poker is fundamentally different from chess or Go, we must first examine the concept of **imperfect information**. In chess, both players see the entire board. Every piece, every possible move is visible. The only uncertainty lies in your opponent’s future decisions. This makes chess a **perfect information** game. Game theory tells us that such games have a solution (the minimax value), and with enough computational power, you can compute optimal play. That is why AIs like AlphaZero defeated world champions: they brute-forced a pattern recognition that approximates the perfect strategy.

Poker, on the other hand, is an **imperfect information** game. You do not know your opponent’s hole cards. You do not know the cards yet to be dealt. The only certainty is that you know your own hand and the community cards. This asymmetry creates a web of probability and deception. A winning strategy must balance exploitation of opponent weaknesses with protection against being exploited. It must randomize (bluff with the correct frequency) and adjust to opponent tendencies.

The mathematical framework for analyzing such games is **game theory for imperfect information**, often called **Bayesian games** or **extensive-form games with chance moves**. The standard solution concept is the **Nash Equilibrium**: a set of strategies where no player can unilaterally improve their expected payoff by deviating. In two-player zero-sum games (like heads-up poker), a Nash equilibrium maximizes the worst-case outcome for each player—it’s a **minimax** strategy. If both players play a Nash equilibrium, neither can gain by changing. It is the definition of perfect play in the adversarial sense.

But computing a Nash equilibrium for a game with 10^14 possible decision points (as in no-limit Texas Hold’Em) is a monumental challenge. Traditional linear programming methods fail due to the sheer size. Enter **Counterfactual Regret Minimization (CFR)**.

## Counterfactual Regret Minimization: The Engine of AI Poker

CFR is an iterative algorithm that learns an equilibrium by repeatedly playing the game against itself. It was introduced by Hart, Mas-Colell, and others in the 2000s and refined by Zinkevich, Johanson, Bowling, and Crandall for extensive-form games. The core idea is beautifully simple: track your regret for not having taken a different action in each **information set** (the set of game states you cannot distinguish from your perspective, given your hand and the board). Then, on each iteration, choose actions with probability proportional to the positive regret you’ve accumulated. Over many iterations, these regrets converge to zero, and the average strategy converges to a Nash equilibrium.

Let me break that down with a concrete example.

### A Simple Poker Ladder: The One-Card Game

Consider a trivial poker variant: each player gets a single card from a deck of three: Ace (high), King, Queen (low). One round of betting. No community cards. The bet size is fixed at one chip. Player 1 can check or bet; Player 2 can call or fold if bet into. This game has 12 information sets (for each possible hole card for each player) and is solvable by hand.

Suppose we want to compute an equilibrium using CFR. We initialize all strategies as uniform random (each action with equal probability). Then we repeatedly let the players play against each other, recording their actual actions and computing what their expected payoff would have been had they taken a different action. The difference between that hypothetical payoff and the actual payoff is the **regret** for that action. We sum regrets over all visits to that information set. At iteration t, we choose actions proportionally to the positive accumulated regret. This is called **regret matching**.

For the one-card game, after perhaps 10 million iterations, the average strategy will be very close to the unique Nash equilibrium. In equilibrium, Player 1 bets with Ace 100% of the time, bets with King about half the time (mixed), and never bets with Queen. Player 2 calls with Ace always, calls with King about half the time, and folds with Queen always. The expected value of the game for Player 1 is slightly positive (about 0.083 chips per hand).

Now, imagine scaling this up to full no-limit Texas Hold’Em. The number of information sets is astronomical. Each player has 169 distinct hand types (preflop) times every possible flop, turn, and river combination, times every possible bet size (which in no-limit can be any amount up to the effective stack). That’s trillions of decision points. CFR, however, can exploit the structure of the game tree through **abstraction** and **sampling**.

### The Mechanics of CFR in Practice

In practice, a CFR implementation does not traverse the entire game tree explicitly. Instead, it uses **sampling** to focus computational resources on likely states. It also uses **card abstractio**n: grouping similar hands together into “buckets” to reduce the state space. For example, an Ace-King suited is grouped with Ace-King offsuit and other premium hands. Or hand strength is represented as a continuous value (like expected equity against a random hand) and clustered.

The key innovation in Libratus was not just raw CFR power, but a combination of **offline equilibrium computation** (using CFR to solve a simplified abstraction of the game) and **online subgame solving** (recomputing optimal strategies for the specific river situation when the game actually reaches that point). This hybrid approach produced an AI that could adapt to the exact current board and stack sizes, something previous AIs could not do.

## CFR+: Faster Convergence to Equilibrium

The initial version of CFR, while theoretically guaranteed to converge, was slow. It could require billions of iterations to reach a sufficiently accurate Nash equilibrium even for abstracted games. In 2015, a breakthrough came: **CFR+**. Developed by Oskari Tammelin (a Finnish poker AI researcher) and later refined by Neil Burch, Martin Schmid, and others, CFR+ introduced two key modifications:

1. **Regret-weighted averaging**: Instead of averaging strategies uniformly over all iterations, CFR+ gives more weight to recent iterations, which often are closer to equilibrium.
2. **Strictly positive regrets**: Regrets are never allowed to go below zero; they are truncated. This subtle change prevents long-term regret accumulation from slowing convergence.

The result: CFR+ converges to an epsilon-equilibrium (within a small error) orders of magnitude faster than basic CFR. In practice, CFR+ could achieve strategies that were essentially unbeatable after a few CPU-months of computation. DeepStack and later Libratus both used CFR+ as their core engine.

## Libratus: The AI That Crashed the Party

In January 2017, at Rivers Casino in Pittsburgh, the AI Libratus faced four of the world’s best heads-up no-limit Texas Hold’Em players: Jason Les, Dong Kim, Daniel McAulay, and Jimmy Chou. The match lasted 20 days, 120,000 hands. The humans were allowed to consult with each other and study previous hands. They were highly motivated. But Libratus crushed them, winning by a margin of 1.8 million chips (big blinds). The AI did not exploit specific human weaknesses; it simply played a near-perfect equilibrium strategy that minimized its own losses while maximizing gains from human errors.

How did Libratus achieve this?

- **Pre-computed blueprint strategy**: Using CFR+, Libratus pre-solved an abstraction of the game with about 10^12 decision points. This blueprint was a Nash equilibrium for the abstracted game. However, the abstraction was coarse enough that humans could find exploits if they studied it. Therefore, Libratus needed to adapt.

- **Self-improvement subgame solving**: At the start of each hand, after the cards were dealt, Libratus computed a refined strategy for the specific situation using **counterfactual regret minimization** on the fly. It solved a **subgame** (the remaining decision tree from the current state to the river) using a technique called **nested subgame solving** or **safe subgame solving**. This ensured that the on-the-fly adjustments did not create weaknesses elsewhere.

- **Avoiding exploitation**: Libratus used **theorem-proving** to guarantee that its online adjustments never made its overall strategy exploitable by a perfect opponent. It essentially computed a Nash equilibrium for the entire game, but using the current state as a boundary.

The result: Libratus played close to perfectly. Post-match analysis showed that its strategy on the river was particularly strong. Humans often misjudged bet sizing, bluffing frequencies, and calling frequencies. Libratus never tilted, never got bored, and never deviated from its mathematically optimal plans.

## Pluribus: The Multiplayer Breakthrough

In 2019, the same team released **Pluribus**, the first AI to beat top human professionals in six-player no-limit Texas Hold’Em. Multiplayer poker is fundamentally harder than heads-up for two reasons: the equilibrium concept shifts to a **Nash equilibrium in multiplayer zero-sum games** (which is not unique and can be tricky), and the state space explodes combinatorially. Pluribus used a combination of **Monte Carlo Counterfactual Regret Minimization** (MCCFR) and abstracted search. It did not pre-solve the full game; instead, it used a shallow search tree in real time, combined with a precomputed **baseline strategy** for the early streets.

Pluribus’s river play was again the crux. In multiplayer, the river often decides the pot, and equilibrium strategies involve complex bet sizing and bluffing ranges that are counterintuitive to human players. Pluribus showed that even with imperfect information, a machine can compute near-optimal river decisions in real time, without needing to see opponents’ hole cards.

## The Mathematics of the River

Why is the river so special? In poker, the river is the final betting round. No more cards will come. This means:

- **The game tree ends at the river.** After the river betting, there is a showdown. This terminal nature makes the river a perfect candidate for exact or near-exact solution using **extensive-form game solving** with smaller subtrees.
- **Information sets are refined.** On the river, you know the full board. Your hand strength is fully determined (though still unknown to your opponent). The only uncertainty is your opponent’s hand. So the river reduces to a game of **all-in betting** with only one round of betting left.
- **Pot odd and bet sizing become linear.** The decision to call a bet on the river is a straightforward pot odds calculation if you knew your opponent’s exact hand. But because you have only a probability distribution over their hands (their **range**), the optimal call involves comparing your **hand equity** against that range, adjusted for bet size and the fact that your opponent may be bluffing.

This leads to the classical **GTO river strategy** known from game theory textbooks: your bluffing frequency should be such that your opponent is indifferent between calling and folding with his bluff-catchers. This is derived from the **indifference principle**. If you bet a pot-sized bet on the river, your opponent’s break-even calling frequency is 50% (he needs to win the pot 1/(1+1) = 50% of the time). Therefore, your value bets should be balanced such that the ratio of bluffs to value bets is 1:2 (for a pot-sized bet). For a half-pot bet, the bluff-to-value ratio is 1:3.

But this is a simplification for the case where you only bet with a polarized range (either very strong or nothing). In reality, equilibrium river strategies involve **non-polarized** (merged) ranges, multiple bet sizes, and check-raising. CFR computes the exact frequencies for every possible hand in every situation.

### A Concrete River Example

Let’s illustrate with a simplified no-limit heads-up scenario. Suppose the board on the river is K♠ Q♠ J♠ 10♥ 2♦. You hold A♠9♣ (a straight flush? Wait, that would be a straight flush if A♠ Q♠ J♠ 10♠? Actually board has K♠ Q♠ J♠ so you need A♠10♠ for royal flush. Let's use a different example).

Better: Board: A♠ K♠ Q♠ J♠ 10♠. Now any spade gives a flush? Actually that's a straight flush for spades. Let's use a generic scenario.

Consider river: A♣ K♣ Q♣ 7♥ 2♦. You are in position with T♥9♥ (missed straight draw). The pot is 100 chips. Effective stacks are 200 chips. Your opponent checks to you. You consider betting 100 chips (pot-sized). According to GTO, you should have a balanced range that includes some bluffs. But which hands should you bluff with? Typically, you would bluff with hands that have no showdown value (like missed draws) and that block your opponent’s calling range. Here, your T9 does not block any of the flush draws or pairs that your opponent might call with. It might be a suboptimal bluff candidate. A better bluff candidate would be something like 8♠7♠ (blocking flush), but we don't have that.

In a real equilibrium, the AI would compute the exact bluffing frequency for each hand, taking into account card removal effects. The math gets intricate, but the underlying principle is indifference.

## The Indifference Principle and Its Wrath

Consider a simplified game: the **River Betting Game** with a binary outcome (you either have a strong hand (value) or a weak hand (bluff)). Your opponent has a bluff-catcher that beats all your bluffs but loses to all your value bets. The pot is P, you can bet b (multiple of the pot). You choose a fraction v of value hands to bet, and a fraction b of bluff hands to bet (assuming you always bet value and sometimes bluff). Your opponent then calls with probability c (indifferent). The condition for them to be indifferent:

- If they fold, they get 0 EV.
- If they call, they win P+b when you bluff (probability of bluff given bet = b/(v+b)), and lose b when you have value (probability v/(v+b)).
- So indifference: 0 = (P+b)_(b/(v+b)) - b_(v/(v+b))
  => (P+b)*b = b*v
  => P*b + b^2 = b*v => v = P + b.

Thus the value-to-bluff ratio (v/b) is (P+b)/b. For pot-sized bet (b=P), v/P = 2, so v = 2b? That yields v/b = 2, meaning 2 parts value, 1 part bluff. That's the classic 2:1 ratio.

But our AI does not compute this simple ratio for all situations; it solves a linear program that incorporates the fact that there are many hand strengths, not just binary. It computes the exact set of hands to bet in each size, and those to check, and those to check-raise if opponent bets. The results often surprise humans.

## Deep Dive into CFR Implementation (Pseudocode)

To ground the discussion, here is a simplified Python-style implementation of CFR for a small game. This is for educational purposes; real implementations use C++ and optimized memory.

```python
import numpy as np

class CFRNode:
    def __init__(self, num_actions):
        self.num_actions = num_actions
        self.regret_sum = np.zeros(num_actions)
        self.strategy_sum = np.zeros(num_actions)

    def get_strategy(self, realization_weight):
        # Use regret matching: positive regrets proportional
        regret_positive = np.maximum(self.regret_sum, 0)
        total = np.sum(regret_positive)
        if total > 0:
            strategy = regret_positive / total
        else:
            strategy = np.ones(self.num_actions) / self.num_actions
        # accumulate average strategy weighted by reach probability
        self.strategy_sum += realization_weight * strategy
        return strategy

    def get_average_strategy(self):
        total = np.sum(self.strategy_sum)
        if total > 0:
            return self.strategy_sum / total
        else:
            return np.ones(self.num_actions) / self.num_actions
```

Then we traverse the game tree recursively, computing values and updating regrets. This pattern scales to full poker using sampling and abstraction.

## The Computational Post-Mortem: Why the River is Solvable

The river is the most computationally tractable part of the poker tree because:

- The remaining depth is small (just one betting round).
- The number of possible board-card combinations is limited: 52 choose 5 = 2.6 million, but after accounting for order and hand range, it’s tractable.
- Bet sizes can be discretized to a small set (e.g., 1/3 pot, 1/2 pot, pot, overbet). In Libratus, the AI considered 15 possible bet sizes preflop but reduced them on later streets.
- The river subgame can be solved exactly using linear programming or extensive-form game solving, as long as the ranges at the start of the river are known or approximated.

Libratus's approach was to pre-solve the entire game in a coarse abstraction, then at the river, recompute a more refined equilibrium for the specific subgame using **nested solving** to ensure safety.

## The Human Bluff: Heuristic vs. Optimal

Consider a classic human heuristic on the river: "You should bluff when the river card completes a draw that you could have been representing." This is correct only in a limited sense. A GTO AI bluffs with hands that are indifferent to being called—not necessarily because they "represent" a specific draw. The AI chooses bluff candidates that have blockers to the opponent's calling range. For example, if the board is draw-heavy, bluffing with the Ace of the suit that just completed reduces the chance the opponent has a flush, making your bluff more credible. Humans think in narrative: "I'll represent the flush." The AI thinks in probability: "My EV from bluffing with this hand is higher than checking, after accounting for the opponent's optimal response."

This leads to bizarre plays: sometimes the AI folds stronger hands than expected, or checks back a marginal value hand to protect its checking range. The river is where these subtleties come out most starkly.

## What We Learned from the AI: Lessons for Players

River play is where the "must" and "should" break down. Many players learn simple rules like "call with bluff-catchers if the pot odds are better than your equity against his betting range." But implementing that requires knowing the opponent's betting range precisely. Humans tend to either call too much (stations) or fold too much (nits). The AI’s strategy lies in between, adjusting frequencies based on exact board texture, stack depth, and opponent tendencies.

If you want to improve your river game, studying GTO river solutions from solvers (PioSOLVER, GTO+, MonkerSolver) is the best approach. But beware: those solvers assume a fixed opponent that also plays GTO. In reality, you must adapt. The AI did both: computed GTO baseline and deviated to exploit.

## The End of Romance? Or its Evolution?

Does the triumph of mathematics mean the end of poker's human drama? No. It does mean that the highest level of play has moved from intuition to computation. But poker remains a game of incomplete information. Even with perfect GTO strategies, the game is not deterministic; it involves randomness (both from card distribution and from mixed strategies). The AI's decisions are probabilistic—it bluffs at specific frequencies, not always. So there is still suspense. But the mystery of whether a player "read" their opponent correctly is replaced by the question of whether they computed their own optimal frequencies correctly.

Moreover, humans can still win by deviating from GTO when they have a good read on the opponent’s tendencies—provided they do not become exploitable themselves. The best human players now combine solver-based study with human insight.

## Conclusion: The River as a Mirror

The river is the final judge in poker. It is where all the earlier decisions converge into a simple, high-stakes choice: fold, call, or raise. The mathematics behind the river reveal that even in the face of uncertainty, there exists a precise, computable optimal behavior. The AIs Libratus and Pluribus demonstrated that we can compute that behavior, and that it dominates human intuition.

But perhaps the deepest lesson is that the river reflects not only the cards but the nature of decision-making under risk. The indifference principle, the equilibrium strategies, the bluffing frequencies—they all testify to a hidden order beneath the chaos of the felt. In the end, poker is not about psychology; it is about revealed preferences. And the river reveals everything.

The clatter of chips, the slide of cards, the sharp intake of breath—they are all just noise around a mathematical signal. The best players, human or AI, listen to that signal. Now you know how to hear it too.
