---
title: "The Mathematics Of Hidden Markov Models For Part Of Speech Tagging: Viterbi Algorithm And Baum Welch"
description: "A comprehensive technical exploration of the mathematics of hidden markov models for part of speech tagging: viterbi algorithm and baum welch, covering key concepts, practical implementations, and real-world applications."
date: "2024-09-04"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-mathematics-of-hidden-markov-models-for-part-of-speech-tagging-viterbi-algorithm-and-baum-welch.png"
coverAlt: "Technical visualization representing the mathematics of hidden markov models for part of speech tagging: viterbi algorithm and baum welch"
---

Excellent. This is a fantastic starting point—a compelling hook that sets up a rich problem. Let me expand this into a substantial, deep, and engaging blog post. I will treat this as a full draft, expanding each section, adding new ones, and maintaining the professional-yet-accessible tone.

Here is the expanded blog post.

---

### The Hidden Code of Language: Unlocking Meaning with the Math of HMMs

Have you ever stopped to marvel at a simple sentence? Consider the word "lead." In the phrase, "I will lead the team," it is a verb, a call to action. In "The pencil is made of lead," it is a noun, a soft, gray metal. In "My dog needs a lead," it is a piece of tethering equipment. Your brain resolves this ambiguity in a flash, without conscious effort. You aren't consulting a dictionary; you are interpreting a symphony of grammar, context, and probability so fast and so deeply that the process is invisible to you.

This seemingly effortless act of understanding is, in fact, one of the most profound challenges in computer science. It is the foundational problem of **Natural Language Processing (NLP)** . How do we teach a machine to read a sentence and not just recognize the words, but understand their _role_? The answer, as with so many complex phenomena, lies hidden in a beautiful and rigorous branch of applied mathematics. The machine must learn to see the invisible—the grammatical structure that makes language meaningful.

The specific task we use to teach this structure is called **Part-of-Speech (POS) Tagging**. It is the digital equivalent of handing a sentence to a high school English teacher and asking them to label every word: noun, verb, adjective, preposition, adverb. It sounds deceptively simple, but it is a gateway problem. Every subsequent NLP task—from machine translation (e.g., Google Translate) and sentiment analysis (e.g., "Did this Amazon review like the product?") to named entity recognition (e.g., "Is 'Apple' a fruit or a company?") and even advanced conversational AI—depends on the quality of this initial, granular understanding.

The digital world runs on this invisible scaffolding. When your email client automatically categorizes a message as "Spam" or "Important," it is using a statistical model that relies, in part, on the grammatical structure of the text. When your phone predicts the next word in your text message, it is building a probabilistic model of word sequences—a model that is dramatically improved by understanding _what kind_ of word is likely to come next. When you ask Siri or Alexa a question, the very first step is not to search the web, but to parse your request into its constituent grammatical parts.

This blog post is your guide to that hidden code. We are going to build the reasoning machinery from the ground up. We will start by defining the problem of ambiguity in language, then introduce the elegant mathematical framework of **Hidden Markov Models (HMMs)** . We will not just describe the theory; we will walk through a complete, annotated example, and then we will see how this model is taught (trained) from real-world data. By the end, you will not just understand _that_ a machine can tag parts of speech; you will understand _how_ it does it, and you will appreciate the profound beauty of seeing language through the lens of probability.

---

### Section 1: The Tower of Babel: Why POS Tagging is Hard

Before we can build a solution, we must fully appreciate the problem. The central challenge in POS tagging is **ambiguity**. A single word can belong to multiple grammatical categories, and the correct category is determined entirely by its context. This is not a rare edge case; it is woven into the very fabric of English.

Let’s examine the word `book`. It can be a **noun** ("I read a good _book_") or a **verb** ("I will _book_ a flight"). How do you know the difference? The surrounding words give you the clues. The word "a" almost always signals that a noun is coming next. The word "will" often precedes a verb. Your brain is a master at recognizing these patterns.

Consider a famous example from the field of computational linguistics: the sentence "I made her duck." This short, innocuous sentence is a minefield of ambiguity. Let's break it down.

1.  **"I made her duck."** Here, "duck" is a noun (the animal). "Made" could mean "created" or "caused to become." This version implies I created a duck for her, or I sculpted one.
2.  **"I made her duck."** Here, "duck" is a verb (to lower the head). "Made" means "caused." This version implies I caused her to duck her head.
3.  **"I made her duck."** Here, "made" could even be interpreted as "prepared as a meal." This version implies I cooked her pet duck for dinner.

Without knowing the meaning and grammar, the sentence is pure noise. A machine that only looks at words, without understanding their roles, is hopelessly lost.

This is the **Tower of Babel** problem for computers: a single stream of text contains multiple, overlapping languages (the language of nouns, the language of verbs, etc.). The task of POS tagging is to separate these languages, to label each word with its specific dialect.

The standard tag set used for this task is the **Penn Treebank Tag Set**, a collection of 36 tags (plus punctuation) that covers the major grammatical categories of English. It includes not just broad categories (noun, verb) but fine-grained ones:

- `NN`: Singular noun ("dog", "computer", "idea")
- `NNS`: Plural noun ("dogs", "computers")
- `VB`: Base form verb ("run", "think")
- `VBD`: Past tense verb ("ran", "thought")
- `VBG`: Gerund or present participle ("running", "thinking")
- `JJ`: Adjective ("big", "red")
- `RB`: Adverb ("quickly", "very")
- `IN`: Preposition ("in", "on", "at")
- `DT`: Determiner ("the", "a", "this")
- `PRP`: Personal pronoun ("I", "you", "he")
- And many more (`MD` for modal verbs like "can", `CC` for conjunctions like "and").

The goal of a POS tagger is to take a sentence like:
`"The quick brown fox jumps over the lazy dog."`
And produce an output like:
`"The/DT quick/JJ brown/JJ fox/NN jumps/VBZ over/IN the/DT lazy/JJ dog/NN ./."`

Notice the subtlety: "jumps" is tagged as `VBZ` (third-person singular present verb), not just `VB`. This level of granularity is crucial for downstream tasks. For machine translation, knowing the tense of a verb is essential. For sentiment analysis, knowing that an adjective modifies a noun is key to understanding the target of an opinion.

How do we build a machine that can consistently and accurately do this? The answer lies in a powerful statistical model that can learn these patterns from data.

---

### Section 2: The Mathematics of Sequence: Introducing Markov Chains

To understand a Hidden Markov Model, we must first understand its simpler cousin: the **Markov Chain**. Imagine you are weatherman on a very boring island. The weather only has two states: Sunny (`S`) and Rainy (`R`). Your job is to predict tomorrow's weather based on today's.

You notice a pattern. If it's sunny today, there's a 90% chance it will be sunny tomorrow, and a 10% chance it will turn rainy. If it's rainy today, there's a 50% chance it stays rainy, and a 50% chance it clears up to sunny.

You can represent this as a **transition matrix**:

```
     Tomorrow
      S    R
Today S  0.9 0.1
      R  0.5 0.5
```

This is a Markov Chain. It is a system that moves from one state to another, and the probability of moving to the next state depends _only_ on the current state. This is the **Markov Property**, also known as "memorylessness."

This is a powerful simplification. The entire history of the weather is compressed into the single, current state. The chain allows us to answer questions like:

- "What is the probability of three sunny days in a row, starting from a sunny day?" (0.9 _ 0.9 _ 0.9 = 0.729)
- "In the long run, what fraction of days will be sunny?" (This is called the _stationary distribution_ of the chain. For this chain, it would be `S: 5/6`, `R: 1/6`).

Now, apply this to language. Think of a sequence of words as a chain. The state is the **current word**. The Markov property says that the probability of the next word depends only on the current word. This is called a **bigram model** in NLP.

For example, after the word "the" (current state `DT`), the most likely next state might be a noun (`NN`, e.g., "the dog"), an adjective (`JJ`, e.g., "the big dog"), or a plural noun (`NNS`, e.g., "the dogs"). The model captures these probabilities directly from a large text corpus.

The probability of a sentence, like "The dog barked," is calculated as:
`P("The dog barked") = P("The" | <s>) * P("dog" | "The") * P("barked" | "dog") * P(</s> | "barked")`

where `<s>` and `</s>` are special start and end markers.

This is a useful model, but it's a **visible** Markov model. We can see the states (the words). The problem of POS tagging is different: we can see the words (the observations), but the states (the grammatical tags) are **hidden**. We need a Hidden Markov Model.

---

### Section 3: Revealing the Hidden Code: The Anatomy of an HMM

A Hidden Markov Model is an extension of a Markov Chain. It consists of two interrelated sequences:

1.  A sequence of **hidden states** (the POS tags, which we don't see directly).
2.  A sequence of **observed events** (the words, which we _do_ see).

The core idea is that the observed events are generated by the hidden states, which themselves form a Markov chain.

Let’s formalize this. An HMM is defined by five components:

1.  **N (Number of Hidden States):** The set of states our model can be in. For POS tagging, this is our tag set (e.g., `DT`, `NN`, `VB`, `JJ`, etc.). Let's call the state at time `t` as `q_t`.
2.  **M (Number of Observation Symbols):** Our vocabulary of distinct words. For a large English model, this could be hundreds of thousands of words. Let's call the observation at time `t` as `o_t`.
3.  **A (State Transition Probability Distribution):** This is the probability of moving from one hidden state (tag) to another. Formally, `A = {a_{ij}}`, where `a_{ij} = P(q_{t+1} = j | q_t = i)`. This captures the grammatical grammar of the language. For example, `a_{DT, NN}` (the probability of a noun following a determiner) will be very high, perhaps 0.6. `a_{DT, VB}` (the probability of a verb following a determiner) will be very low, perhaps near 0.
4.  **B (Observation Emission Probability Distribution):** This is the probability of observing a specific word given a hidden state (tag). Formally, `B = {b_j(k)}`, where `b_j(k) = P(o_t = v_k | q_t = j)`. This captures _lexical_ knowledge. For example, `b_{NN}(dog)` (the probability of seeing the word "dog" given that the state is a noun) will be a certain non-zero value. `b_{NN}(run)` (the probability of seeing "run" given that the state is a noun) will also be non-zero, but likely lower than the probability of seeing "run" given that the state is a verb, `b_{VB}(run)`.
5.  **π (Initial State Distribution):** The probability of starting in a given state. `π_i = P(q_1 = i)`. For example, `π_{DT}` (start with a determiner) is common. `π_{NN}` (start with a noun) is common. `π_{VB}` (start with a verb) is possible but less likely compared to starting a sentence with "Run!"

**The Three Fundamental Problems of HMMs**

There are three classic problems that every HMM practitioner must solve. For POS tagging, we are primarily concerned with Problem 2.

- **Problem 1 (Likelihood):** Given an HMM (with known A, B, π) and a sequence of observations O, compute the probability of O. How likely is this sentence under this model?
- **Problem 2 (Decoding):** Given an HMM and an observation sequence O, find the most likely sequence of hidden states Q. This is **our POS tagging problem**. Given the words we see, what is the most likely sequence of tags that produced them?
- **Problem 3 (Learning):** Given an observation sequence O and the set of possible states, learn the most likely parameters (A, B, π) for the HMM. This is **training** the model from data.

For the remainder of this post, we will focus on Problem 2 (Decoding) and how it solves POS tagging, but we will also touch upon Problem 3 (Learning) to understand how the model acquires its knowledge.

---

### Section 4: The Decoder's Algorithm: How to Unlock the Code with the Viterbi Algorithm

The algorithm for Problem 2 (Decoding) is the **Viterbi Algorithm**. It is a dynamic programming algorithm that finds the single most likely sequence of hidden states (the Viterbi path) given a sequence of observations.

Imagine we are lost in the forest of a sentence. At each step (each word), we have a set of possible paths (tag sequences) we could have taken. The Viterbi algorithm efficiently prunes these paths. It works by maintaining:

1.  **δ_t(j):** The probability of being in state `j` at time `t`, after considering the most likely path to that state.
2.  **ψ_t(j):** A backpointer to the state at time `t-1` that led to this most likely path.

**Step-by-Step Walkthrough**

Let's trace the Viterbi algorithm for a simple sentence: **"the book will lead"**, assuming we have a tiny model with only three hidden states: `DT`, `NN`, `VB`. (We'll ignore `MD` for "will" to keep it simple, and focus on the core idea).

**Step 1: Initialization (t=1)**

For each state `i`, we calculate its probability:
`δ_1(i) = π_i * b_i(word_1)`

Our word is "the".

- `δ_1(DT) = π_{DT} * b_{DT}(the)`. Assume `π_{DT}` = 0.4 (high probability to start with a determiner) and `b_{DT}(the)` = 0.2 (a very common word for a determiner). `δ_1(DT) = 0.4 * 0.2 = 0.08`.
- `δ_1(NN) = π_{NN} * b_{NN}(the)`. Assume `π_{NN}` = 0.3 (common to start with a noun). `b_{NN}(the)` = 0.001 (extremely rare; "the" is almost always a determiner). `δ_1(NN) = 0.3 * 0.001 = 0.0003`.
- `δ_1(VB) = π_{VB} * b_{VB}(the)`. Assume `π_{VB}` = 0.1 (less common to start with a verb). `b_{VB}(the)` = 0.0 (impossible). `δ_1(VB) = 0`.

We set `ψ_1(i) = 0` (no previous state).

**Step 2: Recursion (t=2 to T)**

For each subsequent time step `t`, and for each state `j`:
`δ_t(j) = max_i [ δ_{t-1}(i) * a_{ij} ] * b_j(word_t)`
`ψ_t(j) = argmax_i [ δ_{t-1}(i) * a_{ij} ]`

**Time t=2 (word: "book"):**

We calculate for state `j = NN`:

- From `i = DT`: `δ_1(DT) * a_{DT, NN}` = `0.08 * 0.6` = `0.048`
- From `i = NN`: `δ_1(NN) * a_{NN, NN}` = `0.0003 * 0.1` = `0.00003`
- From `i = VB`: `δ_1(VB) * a_{VB, NN}` = `0 * 0.2` = `0`
- `max_i = 0.048` (from state `DT`). So `ψ_2(NN) = DT`.
- `δ_2(NN) = 0.048 * b_{NN}(book)`. Assume `b_{NN}(book)` = 0.05 (a common noun). `δ_2(NN) = 0.048 * 0.05 = 0.0024`.

We calculate for state `j = VB`:

- From `i = DT`: `δ_1(DT) * a_{DT, VB}` = `0.08 * 0.01` = `0.0008`
- From `i = NN`: `δ_1(NN) * a_{NN, VB}` = `0.0003 * 0.2` = `0.00006`
- From `i = VB`: `δ_1(VB) * a_{VB, VB}` = `0 * 0.5` = `0`
- `max_i = 0.0008` (from state `DT`). So `ψ_2(VB) = DT`.
- `δ_2(VB) = 0.0008 * b_{VB}(book)`. Assume `b_{VB}(book)` = 0.02 (a less common verb). `δ_2(VB) = 0.0008 * 0.02 = 0.000016`.

**Time t=3 (word: "will"):**

We calculate for state `j = NN`:

- From `i = NN`: `δ_2(NN) * a_{NN, NN}` = `0.0024 * 0.1` = `0.00024`
- From `i = VB`: `δ_2(VB) * a_{VB, NN}` = `0.000016 * 0.2` = `0.0000032`
- `max_i = 0.00024` (from state `NN`). So `ψ_3(NN) = NN`.
- `δ_3(NN) = 0.00024 * b_{NN}(will)`. Assume `b_{NN}(will)` = 0.001 (very rare; "will" as in a legal document is a noun). `δ_3(NN) = 0.00024 * 0.001 = 2.4e-7`.

We calculate for state `j = VB`:

- From `i = NN`: `δ_2(NN) * a_{NN, VB}` = `0.0024 * 0.2` = `0.00048`
- From `i = VB`: `δ_2(VB) * a_{VB, VB}` = `0.000016 * 0.5` = `0.000008`
- `max_i = 0.00048` (from state `NN`). So `ψ_3(VB) = NN`.
- `δ_3(VB) = 0.00048 * b_{VB}(will)`. Assume `b_{VB}(will)` = 0.1 (very common; "will" as a future auxiliary verb is extremely common). `δ_3(VB) = 0.00048 * 0.1 = 0.000048`.

**Time t=4 (word: "lead"):**

We calculate for state `j = NN`:

- From `i = NN`: `δ_3(NN) * a_{NN, NN}` = `2.4e-7 * 0.1` = `2.4e-8`
- From `i = VB`: `δ_3(VB) * a_{VB, NN}` = `0.000048 * 0.2` = `0.0000096`
- `max_i = 0.0000096` (from state `VB`). So `ψ_4(NN) = VB`.
- `δ_4(NN) = 0.0000096 * b_{NN}(lead)`. Assume `b_{NN}(lead)` = 0.03 (common noun). `δ_4(NN) = 2.88e-7`.

We calculate for state `j = VB`:

- From `i = NN`: `δ_3(NN) * a_{NN, VB}` = `2.4e-7 * 0.2` = `4.8e-8`
- From `i = VB`: `δ_3(VB) * a_{VB, VB}` = `0.000048 * 0.5` = `0.000024`
- `max_i = 0.000024` (from state `VB`). So `ψ_4(VB) = VB`.
- `δ_4(VB) = 0.000024 * b_{VB}(lead)`. Assume `b_{VB}(lead)` = 0.04 (common verb). `δ_4(VB) = 9.6e-7`.

**Step 3: Termination**

Find the state with the highest probability at the last time step:
`P* = max_i δ_T(i) = max(2.88e-7, 9.6e-7) = 9.6e-7`
`q_T* = argmax_i δ_T(i) = VB`

**Step 4: Backtracking**

Now we trace back our steps using the backpointers to find the most likely path.

- `q_4* = VB`
- From `ψ_4(VB)` we know the previous state is `VB`. So `q_3* = VB`.
- From `ψ_3(VB)` we know the previous state is `NN`. So `q_2* = NN`.
- From `ψ_2(NN)` we know the previous state is `DT`. So `q_1* = DT`.

**Result:** The most likely sequence of tags for "the book will lead" is `[DT, NN, VB, VB]`.

What does this mean? The Viterbi algorithm learned that:

- "the" is a Determiner.
- "book" is a Noun (a book).
- "will" is a Verb (the future auxiliary).
- "lead" is a Verb (to lead the team).

It correctly disambiguated "lead" as a verb, even though "lead" can also be a noun. It did this by looking at the context: after a future auxiliary verb like "will", a base-form verb is far more likely than a noun. The probabilities in the transition matrix (`a_{VB, VB}` being higher than `a_{VB, NN}`) and the emission matrix (`b_{VB}(lead)` being higher than `b_{NN}(lead)` for a verb context) guided it to the correct conclusion.

This is the power of the hidden code: the machine didn't just see the word; it saw a sequence of grammatical states, each adding its own probabilistic clue to the final decision, like a jury of linguists deliberating on every word.

---

### Section 5: Where Do the Probabilities Come From? (Training the HMM)

So far, we have taken the probabilities `A`, `B`, and `π` as given. But how do we get them? We **train** the HMM on a large corpus of text that has already been manually tagged by linguists. This is called a **Treebank**. The most famous is the Penn Treebank, which contains over 4.5 million words of American English, all tagged with POS labels.

With a labeled dataset, estimating the probabilities becomes a simple counting exercise.

**Estimating Transition Probabilities (A):**
`a_{ij} = (Count of transitions from state i to state j) / (Count of times the state i occurs)`

For example, to find `a_{DT, NN}`:

1. Count every time the tag `DT` appears in the corpus.
2. Count how many of those times it is immediately followed by the tag `NN`.
3. Divide.
   If `DT` appears 100,000 times and is followed by `NN` 60,000 times, then `a_{DT, NN} = 0.6`.

**Estimating Emission Probabilities (B):**
`b_j(k) = (Count of times word k is tagged as state j) / (Count of times state j appears)`

For example, to find `b_{NN}(dog)`:

1. Count the number of times the word "dog" appears in the corpus tagged as `NN`.
2. Count the total number of times the tag `NN` appears.
3. Divide.
   If `NN` appears 200,000 times, and "dog" appears as an `NN` 500 times, then `b_{NN}(dog) = 0.0025`.

**The Problem of Zero**

Imagine a word in your test sentence that was never seen in the training data. For example, the word "supercalifragilisticexpialidocious" might never appear. If you try to calculate `b_{NN}(super...)` from your data, you will get `0 / 200000 = 0`. The entire probability for any path that contains this word will become zero, and the Viterbi algorithm will fail.

This is the **zero probability problem** (also called the _data sparsity_ problem). To solve it, we use **smoothing** techniques. The most common is **Add-k Smoothing** (or Laplace Smoothing).

Instead of: `b_j(k) = Count(k, j) / Count(j)`
We use: `b_j(k) = [Count(k, j) + 1] / [Count(j) + V]`

where `V` is the size of our entire vocabulary (the number of unique words). This ensures that even words never seen as a noun still get a tiny, non-zero probability. This allows the model to handle unseen words gracefully, by relying more heavily on the transition probabilities.

For completely unseen words (e.g., new names like "Zyzzyxel"), a more sophisticated approach is to build a special model for "unknown" words based on their morphology (e.g., words ending in "-ed" are likely past-tense verbs, words ending in "-ly" are likely adverbs).

---

### Section 6: The Grand Conclusion: Beyond the Tag

We have traveled a long path. We started with a simple, ambiguous word ("lead") and ended with a complete probabilistic machine for reading language. We have seen that a Hidden Markov Model is not just a clever algorithm; it is a philosophical statement about the nature of language itself. It proposes that language can be understood as a two-tiered system: a hidden, orderly world of grammar (the states) that generates the messy, observable world of words (the emissions). The Viterbi algorithm is the decoder ring that allows us to glimpse this hidden order.

This is why HMMs were the dominant paradigm in NLP for decades, and why they are still taught as a fundamental building block in every machine learning and NLP course. While modern state-of-the-art systems have moved on to more powerful models like Transformers (the "T" in ChatGPT's GPT), the core principles remain the same. The Transformer is, at its heart, a massively more complex method for computing context-dependent probabilities. It still learns the hidden patterns between words, just with billions of parameters instead of a few thousand. It still faces the problem of ambiguity. It still benefits from the foundational insights of the Viterbi algorithm.

The next time you see a sentence, take a moment to appreciate the invisible scaffolding beneath it. You are looking at a sequence of hidden states, a dance of probabilities, a solution to a hidden code that you solved in a fraction of a second, and that a computer must laboriously learn. The beauty is that now you know the math behind that miracle. The machine doesn't "understand" language in the human sense, but it has learned a powerful, rigorous, and beautiful way to model it. And that is, in its own right, a deeply human achievement.
