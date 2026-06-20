---
title: "The Algorithmic Foundations Of Suffix Automaton: Construction And Applications In Substring Problems"
description: "A comprehensive technical exploration of the algorithmic foundations of suffix automaton: construction and applications in substring problems, covering key concepts, practical implementations, and real-world applications."
date: "2023-09-16"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/the-algorithmic-foundations-of-suffix-automaton-construction-and-applications-in-substring-problems.png"
coverAlt: "Technical visualization representing the algorithmic foundations of suffix automaton: construction and applications in substring problems"
---

# The Algorithmic Foundations Of Suffix Automaton: Construction And Applications In Substring Problems

**The opening hook.**

There is a moment, familiar to anyone who has ever wrestled with a truly gnarly string processing problem, when the universe of possible solutions seems to collapse into a binary choice. You can either brute-force the problem with a simple, readable algorithm that will fail catastrophically once the input size grows beyond a few kilobytes—or you can reach for a specialized data structure so elegant and so powerful that it feels almost like cheating. We’ve all built the O(n\*m) pattern matching loop, watched it choke on a 100MB genome, and felt that primal regret. But there is a third path: a path that relies on a product of pure algorithmic thought, a structure that solves substring problems with a voracious, linear-time efficiency that defies intuition.

We are talking about the **Suffix Automaton**.

For the uninitiated, the name itself sounds like a relic from a forgotten era of computer science, a piece of machinery that belongs in a theoretical textbook next to max-flow min-cut and the Hopcroft-Karp algorithm. But the reality is far more immediate. The Suffix Automaton (often abbreviated SAM, or DAWG for Directed Acyclic Word Graph) is one of the most beautifully efficient and profoundly practical data structures ever devised for the analysis of strings. It is a machine that can, in a single pass, absorb a string of length \( n \), and then, in time proportional to the length of the query, answer questions that would stump naive algorithms: "Is this string a substring of the original?" "How many times does this pattern appear?" "What is the longest common substring between two different texts?" "Where is the first occurrence of this pattern?"

The catch, of course, is that the construction of this machine is famously non-obvious. The first time I saw the algorithm—a series of state extensions, suffix link traversals, and clone creations—it felt like abstract algebra dropped into a programming problem. The beauty is that the construction runs in **O(n)** time and uses **O(n)** space, yet it produces a finite automaton that recognizes all substrings of the input. It is, in a very literal sense, a compact representation of the infinite set of all possible substrings.

In this article, we will demystify the Suffix Automaton. We will start from the ground up: what it is, why it works, and how to build it. Then we will explore its many applications, from simple substring existence checks to advanced statistics like longest common substring and lexicographically minimal rotation. Along the way, we will compare it with its better-known cousins—the suffix tree and suffix array—and show why the SAM often wins in terms of simplicity, memory, and speed. By the end, you will not only understand the machine, but you will also be equipped to wield it in your own projects.

---

## 1. What is a Suffix Automaton?

At its core, a Suffix Automaton is a **deterministic finite automaton (DFA)** that accepts exactly the set of all substrings of a given string \( S \) of length \( n \). It is _minimal_ in the number of states among all DFAs that recognize this language. This minimality is what makes it so efficient: the number of states is at most \( 2n - 1 \), and the number of transitions is at most \( 3n - 4 \) for \( n \geq 3 \).

Wait—a DFA that accepts _all substrings_? That sounds like a lot. After all, a string of length \( n \) has \( \frac{n(n+1)}{2} \) distinct substrings in the worst case, and yet the automaton has only linear size. The trick is that the automaton does not store every substring explicitly; it stores the _language_ of substrings. It is a minimal DFA for an infinite regular language (since substrings can repeat). The SAM is essentially the minimal DFA for the set of all suffixes of the string _and_ all their prefixes—which is exactly the set of substrings.

### 1.1 Relationship with Suffix Trees and Suffix Arrays

If you have worked with strings before, you probably know about suffix trees and suffix arrays. They also answer substring queries efficiently. How does the SAM compare?

- **Suffix Tree**: A compressed trie of all suffixes. Has O(n) nodes and edges. Supports pattern matching in O(|P|), but building it is often seen as complex (e.g., Ukkonen's algorithm). Memory overhead is high (each node stores multiple pointers, character ranges, etc.).
- **Suffix Array**: A sorted array of all suffix indices. Buildable in O(n) with SA-IS or O(n log n) with doubling. Pattern matching in O(|P| log n) or O(|P| + log n) with LCP array. More space efficient than suffix trees, but queries are slower and more complex to implement.
- **Suffix Automaton**: Building is arguably simpler than suffix trees (online, no need for implicit nodes). Pattern matching in O(|P|). States store fewer pointers (only transitions and suffix link). Memory is often less than suffix trees. Also, it can answer many queries (like number of occurrences, longest common substring) with additional data that is easy to maintain.

The SAM is less well-known, but for many substring problems, it is the most elegant and efficient tool.

### 1.2 Key Definitions

Let \( S \) be a string of length \( n \). Define:

- **Substring**: any contiguous segment \( S[l..r] \).
- **Suffix**: a substring ending at position \( n-1 \).
- **Right context** of a substring \( w \): the set of all positions \( i \) such that \( w \) occurs ending at \( i \) in \( S \). Equivalently, the set of all starting positions of suffixes that have \( w \) as a prefix? Actually, we define _endpos(w)_ = { set of all ending positions of occurrences of w in S }.

The SAM is built around the concept of **endpos equivalence classes**. Two substrings are considered equivalent if they have exactly the same set of ending positions. Each state in the SAM corresponds to an equivalence class of substrings that share the same endpos set. The transitions are defined so that reading a character \( c \) from a state moves to the state representing the endpos set of substrings \( w + c \), where \( w \) is any substring from the original class.

This equivalence relation partitions the set of substrings into at most \( 2n - 1 \) classes—hence the linear number of states.

---

## 2. Key Properties of the Suffix Automaton

Before diving into construction, we must understand the structural invariants that make the SAM tick.

### 2.1 States and Transitions

Each state \( v \) has:

- `len[v]`: the length of the longest substring in its endpos class.
- `link[v]`: a suffix link pointing to another state (explained below).
- `next[v][c]`: transition on character \( c \) to another state (or null if undefined).

Properties:

- The automaton is acyclic except for self-loops? Actually, it is a DAG (directed acyclic graph) because reading more characters always increases the length of substrings, and there are no cycles because the length strictly increases along any path from the initial state. (The initial state is state 0, representing the empty string, with len=0.)
- The language accepted by the automaton starting from the initial state is exactly the set of all substrings of \( S \). So reading a string \( P \) from the initial state, if we end in any state, then \( P \) is a substring.

### 2.2 Suffix Links (Failure Links)

For each state \( v \) (except the initial state), `link[v]` points to the state that represents the longest proper suffix of the substrings in \( v \)'s class that belongs to a different endpos class. In other words, if \( w \) is the longest substring in state \( v \), then `link[v]` corresponds to the longest substring that is a suffix of \( w \) and has a different endpos set.

This is analogous to failure links in the Aho-Corasick automaton, but here they are used during construction to propagate updates.

Crucially, the suffix links form a tree rooted at the initial state. This tree is called the **suffix link tree** or **parent tree**. It has the property that along the path from a state to the root, the lengths `len` decrease strictly.

### 2.3 Endpos Sets and the Min/Max Lengths

For a given state \( v \), let \( minlen(v) \) be the length of the shortest substring in its class. Because the class consists of all substrings that are suffixes of the longest substring \( w \) and are longer than \( minlen(v) \)? Actually, the equivalence class of \( v \) contains exactly all substrings that are suffixes of the longest substring \( w \) and have length in the interval \( (len(link[v]), len(v)] \). Why? Because if you take any suffix of \( w \) that is longer than the longest suffix that belongs to a different class, then it will still have the same endpos set as \( w \). So the substrings in a class form a contiguous range of lengths.

Thus, we have:
\[
\text{minlen}(v) = len(link[v]) + 1
\]
The number of distinct substrings in class \( v \) is \( len(v) - len(link[v]) \).

This property is the key to counting distinct substrings quickly: simply sum over all states (except initial) of \( len(v) - len(link[v]) \).

### 2.4 Size Bounds

The SAM for a string of length \( n \) has at most \( 2n - 1 \) states and at most \( 3n - 4 \) transitions. These bounds are tight for strings like "abbb...b". The proof relies on counting the number of endpos classes and the number of transitions per state.

---

## 3. Construction Algorithm

The classic construction due to Ukkonen (building on work by Blumer et al.) is an online algorithm: we process the string character by character, extending the automaton to recognize substrings of the prefix processed so far. At each step, we add a new character \( c \) to the end of the current string, and we update the automaton accordingly. The algorithm runs in amortized O(1) per character, so total O(n).

### 3.1 Core Idea

We maintain:

- `last`: the state representing the entire current string (i.e., the longest suffix).
- For each new character \( c \), we create a new state `cur` with `len[cur] = len[last] + 1`.
- We then walk back through suffix links from `last`, adding transitions on `c` until we either reach a state that already has a transition on `c`, or we reach the root (state 0). If we find no existing transition, we simply set `link[cur] = 0`.
- If we do find a state `p` that already has a transition on `c` to some state `q`, we have two cases:
  - If `len[p] + 1 == len[q]`, then `q` already represents substrings that are exactly one character longer than those in `p`. In this case, we can set `link[cur] = q`.
  - Otherwise, we need to **clone** state `q` into a new state `clone` that has `len[clone] = len[p] + 1`, copies all transitions from `q`, and links `link[clone] = link[q]`. Then we update `link[q] = clone` and `link[cur] = clone`. Finally, we traverse back from `p` along suffix links, replacing any transition on `c` that pointed to `q` with a transition to `clone`.

The cloning step ensures that the automaton remains minimal. It effectively splits the endpos class of `q` into two classes: one for substrings longer than `len[p] + 1`, and one for those of length exactly `len[p] + 1`. This is the trickiest part to understand, but it is the heart of the algorithm.

### 3.2 Step-by-Step Example

Let's build the SAM for the string `"ababa"` step by step.

We'll denote states as numbers. Initially, state 0 with len=0, link=-1 (or 0). `last = 0`.

**Step 1: Add 'a'**

- `cur = 1`, len=1.
- Walk from last=0: state 0 has no transition on 'a', so set `next[0]['a'] = 1`. Continue to link[0]=-1? Actually link[0]=-1 (sentinel). So stop. Set `link[1] = 0`.
- State structure: 0->1 on 'a'. last=1.

**Step 2: Add 'b'**

- `cur = 2`, len=2.
- Walk from last=1: state 1 has no 'b'? No. Set `next[1]['b'] = 2`. Go to link[1]=0. State 0 has no 'b'? No. Set `next[0]['b'] = 2`. Go to link[0]=-1. Stop.
- `link[2] = 0`.
- Transitions: 0->2 on 'b', 1->2 on 'b'. last=2.

**Step 3: Add 'a'**

- `cur = 3`, len=3.
- Walk from last=2: state 2 has no 'a'? No. Set `next[2]['a'] = 3`. Go to link[2]=0. State 0 has 'a'? Yes, to state 1. So we find a state `p = 0` with existing transition on 'a' to `q = 1`.
- Now check: `len[p] + 1 == len[q]`? len[0]=0, so 0+1=1, len[1]=1. Yes, equality holds.
- So we set `link[3] = q = 1`. We do not need to clone. Then we stop updating transitions (because we already processed all states from last up to p by setting transitions on 'a'? Actually we set transitions only on the walk before reaching p? Let's trace correctly: we started at last=2, set next[2]['a']=3. Then we moved to link[2]=0. At p=0, we found existing transition. Since len[p]+1 == len[q], we set link[cur]=q. We do not propagate further (no need to set transitions for states above p, because they already have transitions to q, and that's fine). So link[3]=1. last=3.

**Step 4: Add 'b'**

- `cur = 4`, len=4.
- Walk from last=3: state 3 has no 'b'? No. Set `next[3]['b'] = 4`. Go to link[3]=1. State 1 has 'b'? Yes, to state 2. So `p=1`, `q=2`. Check len[p]+1 == len[q]? len[1]=1, len[2]=2. 1+1=2, equal. So link[4]=2. Stop.

**Step 5: Add 'a'**

- `cur = 5`, len=5.
- Walk from last=4: state 4 has no 'a'? No. Set `next[4]['a'] = 5`. Go to link[4]=2. State 2 has 'a'? No? Wait, state 2 currently has only 'b' and maybe? Let's see: from earlier steps, state 2 has transition 'b'? Actually state 2 was created in step 2, and we set next[2]['a'] in step 3? No, in step 3 we set next[2]['a']=3? Wait, in step 3 we set next[2]['a']=3? Let's recount: In step 3, we walked from last=2. At state 2, we set next[2]['a']=3. Yes, state 2 has transition 'a' to state 3. So when we now (step 5) at state 2, we look for 'a' transition: it exists to state 3. So `p=2`, `q=3`. Check len[p]+1 == len[q]? len[2]=2, len[3]=3. 2+1=3, equal. So link[5]=3. Stop.

Thus, the SAM for "ababa" is built without any cloning. The final automaton has states 0..5. Let's draw transitions:

- 0: a->1, b->2
- 1: a->? none? Actually step 1: next[1] only has b->2 from step 2. Also step? In step 4, we did not add any transition from 1. So 1: b->2.
- 2: a->3 (step 3), b->? none? Actually step 2: next[2] was set with 'a'? No, at creation state 2 had no transitions; later step 3 added a->3. Also step 4? No. So 2: a->3.
- 3: b->4 (step 4), a? none.
- 4: a->5 (step 5).
- 5: no outgoing.

Suffix links: link[1]=0, link[2]=0, link[3]=1, link[4]=2, link[5]=3.

This automaton recognizes all substrings of "ababa". For example, is "aba" a substring? Start at 0: a->1, b->2, a->3. Yes, we reach state 3. Is "bab"? b->2, a->3, b->4. Yes.

Now consider a more complex case where cloning is needed: take string "abbb". Let's build quickly:

**String "abbb":**

- Add 'a': state1, len=1, link=0.
- Add 'b': state2, len=2, from last=1, no 'b' at 1, set next[1]['b']=2, go to 0, no 'b', set next[0]['b']=2, link[2]=0.
- Add 'b': cur=3, len=3. Walk from last=2: state2 has 'b'? Not yet. Set next[2]['b']=3, go to link[2]=0. State0 has 'b' to state2. So p=0, q=2. Check len[p]+1 == len[q]? 0+1=1, len[2]=2. Not equal. So we need to clone q.
  - Create clone state `clone` = 4. Copy all transitions from q=2: q's transitions? At this point, q=2 has transition 'b' to 3? Actually we just added next[2]['b']=3, but that was from the previous step? Wait we are in the same step: we set next[2]['b']=3, then we go to p=0. q=2 already has that transition? Actually the transition we just added to state2 is part of the current step. q=2 is the old state; we must copy its original transitions before we added new ones. In the algorithm, we only traverse backward after setting the transition from the current state? Let's clarify: The algorithm walks from `last` backwards, and for each state p we set next[p][c] = cur if it didn't exist. When we encounter p=0 already having next[0]['b']=q=2, we stop the walk. At that point, q is state 2 as it was before this step—it does not yet have the new 'b' transition to cur. So q's transitions are the ones from previous steps: q=2 currently has no outgoing transitions? In "abbb", after step 2, state 2 had no transitions (since only 'b' from 0 and 1 to 2). So q=2 has empty transitions. So we clone to clone=4, copy empty transitions. len[clone]=len[p]+1 = 1. link[clone]=link[q]=0. Then set link[q]=clone, link[cur]=clone. Then go to p=0, and for each state from p (including p) backwards while next[state][c]==q, we set it to clone. p=0 has next[0]['b']=q, so set next[0]['b']=4. Then go to link[p]=-1, stop. Also we need to adjust transitions from earlier states? The walk only goes from p backwards, not from other states. Since we already passed through state2 earlier? Actually we started from last=2, we set next[2]['b']=cur. That's fine. Then we moved to link[2]=0. At p=0 we found existing transition. The clone fix applies to p and all its suffix ancestors that had transition to q. So we set next[0]['b']=4. That's it.
  - Now state2 (q) has link to clone=4, and its own transitions unchanged (empty). Clone has len=1, link=0, transitions empty.
  - Final states: 0,1,2,3,4. last=3.

- Add another 'b': cur=5, len=4. Walk from last=3: state3 has no 'b'? Not set. Set next[3]['b']=5. Go to link[3]? link[3] was set? In step 3, link[3]=clone? Wait we set link[cur]=clone, so link[3]=4. So next state is 4. State4 has 'b'? Clone has no transitions, so none. Set next[4]['b']=5. Go to link[4]=0. State0 has 'b' now to state4 (after the clone). So p=0, q=4. Check len[p]+1 == len[q]? 0+1=1, len[4]=1, equal. So link[5]=q=4. Stop.

The resulting SAM for "abbb" has state 2 as a dead end? Actually state 2 (the original q) now has no outgoing transitions and its link points to clone. It still represents the substring "ab" (len=2). The clone represents substring "b" (len=1) with endpos set that includes both positions 2 and 3? The cloning correctly splits the suffix classes.

This example illustrates the core complexity.

### 3.3 Pseudocode

Here is a clean implementation in Python for building the SAM:

```python
class SAM:
    def __init__(self, max_len):
        self.next = [dict() for _ in range(2*max_len)]
        self.link = [-1]*(2*max_len)
        self.len = [0]*(2*max_len)
        self.size = 1  # number of states, start with state 0
        self.last = 0

    def extend(self, c):
        cur = self.size
        self.size += 1
        self.len[cur] = self.len[self.last] + 1
        p = self.last
        while p != -1 and c not in self.next[p]:
            self.next[p][c] = cur
            p = self.link[p]
        if p == -1:
            self.link[cur] = 0
        else:
            q = self.next[p][c]
            if self.len[p] + 1 == self.len[q]:
                self.link[cur] = q
            else:
                clone = self.size
                self.size += 1
                self.len[clone] = self.len[p] + 1
                self.next[clone] = self.next[q].copy()  # copy transitions
                self.link[clone] = self.link[q]
                while p != -1 and self.next[p].get(c) == q:
                    self.next[p][c] = clone
                    p = self.link[p]
                self.link[q] = self.link[cur] = clone
        self.last = cur
```

This runs in O(n) amortized because each extension either creates a new state or a clone, and the number of clones is bounded by n.

### 3.4 Complexity Analysis

- **States**: At most 2n-1.
- **Transitions**: Each state can have many transitions, but total transitions is O(n) because each transition either is created when a new state is added, or when a clone is made, and each clone copies transitions from an existing state; however copies can cause multiple transitions to be duplicated? Actually each clone copies transitions, but the total number of distinct transitions across the whole automaton is bounded by O(n). The proof is subtle: each transition corresponds to a pair (state, character) that is created only once, and the number of such pairs is at most 3n-4.
- **Time**: Each character addition does O(1) work on average because the while loops amortize to O(n) total.

---

## 4. Basic Applications

Once we have the SAM built, many substring problems become trivial or require only a small amount of additional computation.

### 4.1 Substring Existence Check

To check if a pattern \( P \) is a substring of \( S \), simply simulate the automaton: start from state 0, follow transitions for each character of \( P \). If at any point the transition is missing, \( P \) is not a substring. Otherwise, after consuming all characters, we are in some state, and \( P \) is a substring. This runs in O(|P|) time.

This is as fast as a suffix tree, and much simpler to implement than a suffix array's binary search with LCP.

### 4.2 Counting Occurrences of a Substring

This is a classic application. We want to know how many times a pattern \( P \) appears as a substring. The naive way would be to simulate to the state representing \( P \), and then count the number of end positions in that state's endpos class. But we don't store endpos sets explicitly. However, we can augment the SAM during construction with a count of how many times each state is reached by the suffixes.

**Method**: During the initial construction, each time we create a new state `cur` (which represents the entire current prefix), we set a counter `cnt[cur] = 1`. For cloned states, we set `cnt[clone] = 0`. After building the automaton, we need to propagate these counts up the suffix link tree. Because if a substring occurs at a given ending position, its suffixes also occur at that same ending position. So we can do a topological order (by decreasing `len`) and for each state, add its `cnt` to the `cnt` of its suffix link target.

Formally: sort states by `len` descending (this is a topological order because suffix links go to states with smaller `len`). Then for each state `v` (skip root), do `cnt[link[v]] += cnt[v]`.

After this, for any substring \( P \), we simulate to state \( v \) (if possible), and the answer is `cnt[v]`. This works because `cnt[v]` after propagation equals the size of the endpos set of that state—i.e., the number of occurrences of the substrings in that class.

Example: In string "ababa", after building and propagating, we can find count of "aba": state 3, cnt[3] =? "aba" occurs at positions 3 and 5? Actually in "ababa", occurrences of "aba": positions 1-3: "aba", and 3-5: "aba". So two occurrences. Our SAM state 3 should have cnt=2. Let's test: initially cnt[1]=1 (for 'a'), cnt[2]=1 (for 'ab'), cnt[3]=1 (for 'aba'), cnt[4]=1 (for 'abab'), cnt[5]=1 (for 'ababa'). Cloned? None. Propagate: sort len: 5,4,3,2,1,0. Add cnt[5] to link[5]=3: cnt[3]+=1 =>2. Add cnt[4] to link[4]=2: cnt[2]=2. Add cnt[3] to link[3]=1: cnt[1]=3. Add cnt[2] to link[2]=0: cnt[0]=3. Add cnt[1] to link[1]=0: cnt[0]=6. Now state 3 cnt=2, correct.

### 4.3 First Occurrence Position

We can also store the first occurrence (the smallest ending position) for each state. During construction, for each new state `cur`, we set `firstpos[cur] = len[cur]` (the position of the last character). For clones, `firstpos[clone] = firstpos[q]` (since clones inherit the positions from the original state? Actually careful: clones represent a subset of the original endpos, but the first occurrence might be the same as the original's first occurrence? In many implementations, we store `occ_first` as the earliest (or latest) occurrence, and for clones we set it to `firstpos[q]` because the clone's first occurrence is the same as the original's first occurrence for the shorter substrings? But actually, the clone's endpos set is a subset that excludes the most recent occurrence? In the classic approach, we store `firstpos` as the smallest ending position for the class. For clones, since they are created when the new character is added, the original state q already had its first occurrence. The clone's endpos set includes all occurrences of q except the newest one? Actually the clone receives all occurrences of q except the one that caused the split? The algorithm ensures that the endpos sets are split: the clone's endpos set = endpos(q) \ {current_end}? No, the clone gets the "old" endpos set (the one before adding the new character), and the original q gets the "new" endpos set (including the new position). But the min/max lengths change. So the smallest ending position for the clone is the same as the original q's smallest ending position. So we can set `firstpos[clone] = firstpos[q]`. For `cur`, we set `firstpos[cur] = len[cur]` (the current position). Then to answer queries: simulate to state v, answer is `firstpos[v] - |P| + 1` (the starting index). This works if we want the first occurrence in 0-indexed positions.

### 4.4 Number of Distinct Substrings

As mentioned, the total number of distinct substrings of \( S \) is the sum over all states (except root) of `len[v] - len[link[v]]`. This is O(n) to compute after building the SAM.

For "ababa", we have:

- state1: len1=1, link1=0 -> 1-0=1
- state2: len2=2, link2=0 -> 2
- state3: len3=3, link3=1 -> 3-1=2
- state4: len4=4, link4=2 -> 4-2=2
- state5: len5=5, link5=3 -> 5-3=2
  Total = 1+2+2+2+2 = 9 distinct substrings. Indeed, "ababa" has 9 distinct substrings: a, b, ab, ba, aba, bab, abab, baba, ababa. (Note: "aba" appears twice but distinct is one.)

---

## 5. Advanced Applications

Now that we have the basic arsenal, let's explore more complex problems.

### 5.1 Longest Common Substring of Two Strings

Given two strings \( S \) and \( T \), find the longest string that is a substring of both. This is a classic problem, often solved with suffix automata.

**Method**: Build the SAM for \( S \). Then traverse \( T \) character by character, maintaining a current state and a current length. Initially, state=0, len=0. For each character c in T:

- While state has no transition on c and state != 0: state = link[state], len = len[state] (or more precisely, after setting state to link, we set len = min(len, len[state])? Actually we need to reduce len to the longest substring possible ending at that state. Standard approach: if `next[state][c]` exists, set state = next[state][c], len += 1. Else, if state != 0, set state = link[state], len = len[state] (because when we follow suffix link, the longest substring in the new state is its len), and then try again. Keep track of the maximum len encountered.

This yields the length of the longest common substring. To retrieve the actual substring, we can also store the ending position in T and then extract from S using the state's first occurrence. Implementation is straightforward.

**Why it works**: The SAM for S contains all substrings of S. As we traverse T, we are simulating the automaton to find the longest suffix of T[0..i] that is a substring of S. This is exactly the longest common substring ending at position i. The maximum over i is the overall LCS.

### 5.2 Lexicographically Smallest Substring of Given Length

Given a length k, find the lexicographically smallest substring of that length in S. Since the SAM is a DAG, we can do a DFS from the root, following the smallest character at each step, while respecting lengths. More precisely, we can precompute for each state the number of different substrings that can be reached from it (i.e., the number of paths). Then we can find the k-th lexicographically smallest substring overall, or the smallest of a given length by traversing greedily.

### 5.3 Minimal Cyclic Shift

Given a string S (length n), find its lexicographically minimal rotation. This can be solved in O(n) using the SAM of S+S (double the string). The minimal rotation is the smallest substring of length n that appears in S+S starting at a position < n. We can traverse the SAM of S+S, always picking the smallest character that leads to a state from which we can still continue to reach length n. However, we must ensure we stop after n characters and that the starting position is valid (within first n). The SAM can answer this efficiently.

### 5.4 Substring Lexicographical Order (k-th Smallest Substring)

We can compute the total number of distinct substrings (as above). Then to find the k-th smallest lexicographically, we can do a DFS from the root, using sorted transitions, and counting how many substrings are reachable from each successor. This requires preprocessing `occ[v]` = number of distinct substrings starting from state v (including the empty prefix? Actually we need to count all paths from v, where a path corresponds to a substring). This is easily computed via DP on the DAG (since it's acyclic). Then we can find the k-th by walking.

### 5.5 All Occurrences of a Pattern (as indices)

If we want not just count but also positions, we can augment the SAM with a list of ending positions. For each state, we can store a vector of positions (or just the first and last?). But storing all positions would be O(n^2) in worst case. Instead, we can store the occurrence indices via a "pos" list and use the suffix link tree to propagate. Common technique: after building, do a DFS on the suffix link tree and for each state, collect all positions from its descendants. But that's still heavy. Alternatively, use the `firstpos` and `lastpos` to reconstruct? Not directly. For all occurrences, one can use the fact that the endpos set of a state is exactly the set of all positions in the subtree of the leaf states (states that were created as `cur` during construction) in the suffix link tree. So we can build a segment tree or a list of positions for the leaves, and then for each query we need to find all leaves in the subtree. That can be done with Euler tour and a merge sort tree, allowing O(k log n) to output k occurrences. That's more advanced but feasible.

---

## 6. Comparison with Suffix Tree and Suffix Array

| Feature                   | Suffix Automaton               | Suffix Tree                         | Suffix Array                                 |
| ------------------------- | ------------------------------ | ----------------------------------- | -------------------------------------------- |
| Build time                | O(n)                           | O(n) (Ukkonen)                      | O(n) (SA-IS) or O(n log n)                   |
| Memory                    | ~20 bytes per char (depending) | ~40+ bytes per char                 | ~4-8 bytes per char (plus LCP)               |
| Pattern matching          | O(m)                           | O(m)                                | O(m log n) or O(m+log n)                     |
| Occurrence count          | O(1) after DP                  | O(m) with precomputed counts        | O(m + log n) with binary search and RMQ      |
| Longest common substring  | O(n+m) with SAM of one string  | O(n+m) with generalized suffix tree | O(n+m) with suffix array and LCP (Kasai)     |
| Distinct substrings       | O(n)                           | O(n)                                | O(n) (need RMQ?)                             |
| Implementation complexity | Moderate                       | High                                | Moderate (simple suffix array with doubling) |
| Online construction       | Yes                            | Yes (Ukkonen)                       | No (requires full string)                    |

The SAM excels in its simplicity of use for many queries. The suffix tree is more general (can handle arbitrary sets of strings, can answer more complex queries like matching statistics), but its algorithmic complexity and memory footprint are deterrents. The suffix array is memory-efficient and often used in production, but pattern matching requires binary search (or an additional array for LCP to do O(m+log n)). For tasks like counting number of occurrences of a fixed pattern repeatedly, the SAM's O(1) is unbeatable.

However, note that the SAM is specific to a single string (unless you concatenate with separators). For multiple strings, you can build a generalized SAM (like a trie of strings), but that's more complex.

---

## 7. Advanced Topics: Generalized SAM and Dynamic SAM

### 7.1 Generalized Suffix Automaton

We can build a SAM for a set of strings by inserting them one by one, resetting `last` to the root before each new string. However, this only works if we want to recognize substrings of any of the strings? Actually, if we simply reuse the same automaton and extend with each character of each string, we effectively build the SAM for the concatenation of all strings, which would recognize substrings that span across boundaries (bad). To avoid cross-boundary substrings, we can use a unique separator (like '$') between strings. That works, but it changes the substring set slightly (the separator might be included). Better approach: Use a _SAM of a trie_ (also called a multiple string SAM). This allows building a minimal automaton for the set of substrings of multiple strings without concatenation. The algorithm is more involved but follows similar principles.

### 7.2 Dynamic SAM

What if we want to add characters to the beginning of the string, not just the end? The standard SAM is built left-to-right and handles only appending. Prepending is more difficult because the automaton is built in a particular direction. However, you can build a SAM for the reversed string and reverse the queries. There are also structures like the _bidirectional suffix automaton_ but they are less common.

---

## 8. Real-World Applications

Beyond theoretical exercises, the SAM is used in:

- **Bioinformatics**: Finding longest common substrings in DNA sequences, counting occurrences of short reads in a reference genome, detecting repeats.
- **Data deduplication**: Finding common substrings between files.
- **Text indexing**: Used in search engines for pattern matching in large corpora.
- **Compression algorithms**: The LZ factorizations can be computed using SAM (e.g., LZ77 parsing).
- **Music information retrieval**: Detecting repeated patterns in melodies.

### 8.1 Example: Counting Unique Substrings in a Genome

Suppose we have a bacterial genome of 5 million base pairs. Naively, there are ~12.5 trillion possible substrings, but only about 5 million distinct substrings? Wait, distinct substrings of a string of length n is at most n(n+1)/2, but typically much less for repetitive genomes. Using SAM, we can compute the exact number in O(n) time and memory. This is used in estimating sequence complexity.

### 8.2 Example: Pattern Matching in a Log File

Given a 1GB log file, we can build its SAM once (O(n) time, ~2GB memory maybe high, but possible with efficient implementation in C++). Then we can answer thousands of "how many times does error code X appear?" queries in O(|X|) time each. The preprocessing time pays off for many queries.

---

## 9. Conclusion

The Suffix Automaton is a testament to the power of elegant mathematical abstraction applied to algorithmic problems. It compresses the entire set of substrings of a string into a linear-sized DFA, and its construction algorithm is a marvel of online processing, cloning, and suffix links. Once built, it answers a vast array of substring queries with astonishing efficiency—often in time proportional to the query length, independent of the text size.

We have covered the fundamentals: endpos equivalence classes, states and suffix links, the O(n) construction algorithm with step-by-step examples, and numerous applications from counting occurrences to finding longest common substrings. We compared it to suffix trees and arrays, highlighting where it shines and where it falls short. We also touched on generalizations and dynamic variants.

If you have never implemented a SAM before, I encourage you to do so. Write a small test harness, compute the number of distinct substrings for your favorite literary work, or find the longest common substring between two Shakespeare plays. The satisfaction of seeing the automaton churn through gigabytes of text in seconds is addictive. The SAM is not just a data structure; it is a lens through which the structure of strings becomes transparent.

As David Eppstein once said, "Suffix automata are to substring matching what finite automata are to regular expression matching—a simple, clean, and theoretically optimal solution." In a world where string processing is ubiquitous, the SAM deserves a place in every programmer's toolbox.

---

_Further Reading:_

- Ukkonen, E. "On-line construction of suffix trees." Algorithmica 14.3 (1995): 249-260. (Classic)
- Blumer, A., et al. "The smallest automaton recognizing the subwords of a text." Information and Control 69.1-3 (1986): 23-36. (Original SAM)
- Crochemore, M., and Vérin, R. "On-line construction of automata for occurrences of factors." Theoretical Computer Science 210.1 (1999): 101-115.
- Gusfield, D. _Algorithms on Strings, Trees, and Sequences_. Cambridge University Press, 1997.

Now go forth and build automata that absorb strings. Your substring problems will never be the same.
