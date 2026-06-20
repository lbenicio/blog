---
title: "Implementing The Knuth Morris Pratt Algorithm: Failure Function And String Matching"
description: "A comprehensive technical exploration of implementing the knuth morris pratt algorithm: failure function and string matching, covering key concepts, practical implementations, and real-world applications."
date: "2026-02-23"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Implementing-The-Knuth-Morris-Pratt-Algorithm-Failure-Function-And-String-Matching.png"
coverAlt: "Technical visualization representing implementing the knuth morris pratt algorithm: failure function and string matching"
---

# The Knuth–Morris–Pratt Algorithm: Mastering String Matching in Linear Time

## Introduction: The Art of Efficient String Matching

Imagine you’re a compiler engineer who has just been handed the output of a lexer: a stream of characters representing source code. You need to find every occurrence of a specific keyword—say, `struct`—in a file that’s hundreds of thousands of lines long. Or perhaps you’re building a bioinformatics pipeline that must locate a short DNA pattern like `ATCG` inside a genome spanning billions of base pairs. In both cases, the task is the same: given a **pattern** (the thing you’re looking for) and a **text** (where you’re looking), report all positions where the pattern appears.

At first glance, the problem seems trivial. A simple loop that slides the pattern over the text, character by character, and checks for a match—this is the **naïve algorithm**. It’s intuitive, easy to code, and correct. But if you’ve ever tried to use it on a large text, you’ve felt the sting of its inefficiency. For a pattern of length _m_ and a text of length _n_, the naïve approach runs in **O(n·m)** time. When _n_ is millions and _m_ is thousands, that quadratic blowup becomes a showstopper. The compiler takes minutes to process what should be seconds; the genome search crawls to a halt.

The history of computer science is filled with problems that seem simple until you demand performance. String matching is one of them. The challenge is not just to find a match, but to do so **without re-examining characters that have already been seen**. This is the core insight behind the **Knuth–Morris–Pratt (KMP) algorithm**—a classic, elegant, and widely taught linear-time solution.

### The Kernel of the Problem: Why Naïve Fails

Understanding why the naïve algorithm is slow is crucial to appreciating KMP. Let’s walk through a small example. Suppose the pattern is `"ABABAC"` and the text is `"ABABABAC"`. The naïve algorithm starts at position 0: it compares `A` vs `A`, `B` vs `B`, `A` vs `A`, `B` vs `B`, `A` vs `A` … then at the sixth character of the pattern, it expects `C` but finds `B` in the text (since text[5] = 'B' while pattern[5] = 'C'). A mismatch occurs. In the naïve approach, we then shift the pattern by one position and start comparing again from the beginning of the pattern against the next position in the text (position 1). That means we re‑examine many characters that we have already seen—in this case, we would compare text[1..] with pattern[0..] from scratch.

But notice something: we already know that the first five characters of the pattern matched the text at positions 0–4. The pattern has a certain structure: `"ABABA"` is a prefix that repeats. When the mismatch happens at the sixth character, instead of sliding by just one and starting over, we could use the knowledge that the matched prefix `"ABABA"` has a suffix which is also a prefix—namely `"ABA"`. This allows us to shift the pattern so that the already-matched suffix of the text aligns with the prefix of the pattern, without having to re‑compare those characters. That is exactly what the KMP algorithm does.

This example illustrates the fundamental inefficiency of the naïve method: it discards all the information gained from a partially successful comparison. In a worst‑case scenario, like searching for `"AAAA"` in `"AAAAB"`, the naïve algorithm performs many redundant comparisons, leading to O(n·m) time. The KMP algorithm eliminates this redundancy by preprocessing the pattern to build a **failure function** (also called the **prefix function** or **border array**), which tells us, for each prefix of the pattern, the length of the longest proper prefix that is also a suffix. This information guides how far we can safely shift the pattern when a mismatch occurs.

The result is an algorithm that runs in **O(n + m)** time, which for large texts is dramatically faster. But KMP is not just a practical tool—it is a masterpiece of algorithm design. Its elegance lies in the way it transforms the string matching problem into a problem about self‑similarity of the pattern, using an automaton‑like process that never moves the text index backward. In this post, we’ll dive deep into the mechanics of KMP, from its mathematical foundations to its implementation, and explore why it remains a cornerstone of stringology over fifty years after its discovery.

## The Naïve Algorithm and Its Pitfalls

Before we can appreciate KMP, we must fully understand the naïve algorithm and its weaknesses. The naïve (or brute‑force) string matching algorithm is straightforward: for every possible starting position _i_ in the text (0 ≤ i ≤ n‑m), compare the pattern character by character with the substring text[i .. i+m‑1]. If all m characters match, record the position. Then move to the next starting position. Here is a simple implementation in Python:

```python
def naive_search(text, pattern):
    n = len(text)
    m = len(pattern)
    matches = []
    for i in range(n - m + 1):
        match = True
        for j in range(m):
            if text[i + j] != pattern[j]:
                match = False
                break
        if match:
            matches.append(i)
    return matches
```

### Worst‑Case Behavior

The worst‑case input for the naïve algorithm occurs when every alignment results in a long partial match before failing. The classic example is searching for a pattern consisting of all the same character, such as `"AAAA"`, in a text of the same character followed by a different one, e.g., `"AAAAB"`. Let’s simulate:

- Text: `"AAAAB"` (n=5)
- Pattern: `"AAAA"` (m=4)

Start at i=0: compare text[0]='A' with pattern[0]='A' – match. Continue: text[1]='A' vs pattern[1]='A' – match. text[2]='A' vs pattern[2]='A' – match. text[3]='A' vs pattern[3]='A' – match. All four match, so record position 0.

Now shift to i=1: compare text[1]='A' vs pattern[0]='A' – match. text[2]='A' vs pattern[1]='A' – match. text[3]='A' vs pattern[2]='A' – match. text[4]='B' vs pattern[3]='A' – mismatch. So we compared 4 characters again.

i=2: compare text[2]='A' vs 'A' – match. text[3]='A' vs 'A' – match. text[4]='B' vs 'A' – mismatch. 3 comparisons.

i=3: text[3]='A' vs 'A' – match. text[4]='B' vs 'A' – mismatch. 2 comparisons.

Total comparisons: 4+4+3+2 = 13. For pattern length m=4 and text length n=5, the worst‑case is about (n‑m+1)*m = 2*4 = 8? Actually (n‑m+1)*m = 2*4 = 8, but we got 13 because the pattern is all same character causing many comparisons at each shift. The formal worst‑case is O(n·m) because each of the n‑m+1 shifts can take up to m comparisons. In this case, we have n‑m+1 = 2 shifts, but each shift’s comparisons vary; however, the total comparisons can be as high as m(n‑m+1) if the pattern matches all but the last character at each shift. For example, pattern = `"AAAB"`, text = `"AAAAB"`:

i=0: `AAAA` vs `AAAB` – mismatch at j=3. (4 comparisons)
i=1: `AAA` vs `AAAB` – mismatch at j=3. (4 comparisons)
i=2: `AA` vs `AAAB` – mismatch at j=2. (3 comparisons)
Total = 11, still roughly m\*(n‑m+1) = 8 but a bit more due to comparisons after mismatch? Actually the formal bound of m comparisons per shift is an upper bound, but in practice it can be exactly m when the pattern matches all characters before the last one. So worst‑case is indeed Θ(m·(n‑m+1)).

For large n and m (say n=10⁶, m=10⁴), this becomes 10¹⁰ comparisons—a trillion operations on a modern CPU would take hours. Even though the constant factors are small, the quadratic scaling is unacceptable for many applications.

### Where Does Inefficiency Come From?

The core problem is that the naïve algorithm discards all information from previous comparisons. When a mismatch occurs at some position in the pattern, we know exactly which characters of the text have been matched up to that point. But instead of using that knowledge to skip ahead, we simply slide the pattern by one and start over. In other words, we re‑examine text characters that we have already seen.

Consider a more complex pattern like `"ABABAC"` and text `"ABABABAC"`. Let’s trace:

- i=0: compare positions 0-5: `ABABA` match, then mismatch at index 5 (pattern[5]='C', text[5]='B').
- Naïve then shifts to i=1: compare pattern[0]='A' with text[1]='B' – immediate mismatch.
- i=2: compare pattern[0]='A' with text[2]='A' – match; then pattern[1]='B' with text[3]='B' – match; pattern[2]='A' with text[4]='A' – match; pattern[3]='B' with text[5]='B' – match; pattern[4]='A' with text[6]='A' – match; pattern[5]='C' with text[7]='C' – match! Found at position 2.

Notice that at i=2, we actually matched 6 characters, but we had already seen text[2..5] at i=0 (they were part of the matched prefix). The naïve approach wasted time at i=1 with an immediate mismatch, and at i=2 it had to re‑compare characters that it had already seen before. In total, for this example, naïve makes 1+1+6 = 8 comparisons (assuming we count the mismatch at i=1 as one comparison). KMP would do far fewer.

The key observation is that when a mismatch occurs after matching some prefix of the pattern, the pattern itself may contain a **border**—a proper prefix that is also a suffix. That border tells us how many characters we can safely skip. In the example, after matching `"ABABA"`, the longest border of `"ABABA"` is `"ABA"` (length 3). So instead of shifting by 1, we can shift by (matched length - border length) = 5‑3 = 2 positions. This aligns the suffix of the matched text (which we already know matches the border of the pattern) with the prefix of the pattern. Then we can resume comparing from the next character after the border.

This insight is the foundation of KMP. The algorithm precomputes a **failure function** (or **prefix function**) that gives, for each possible matched prefix length, the length of its longest border. Then during the search, when a mismatch occurs, we use this function to determine how far to shift the pattern without ever moving the text pointer backward.

## The Core Insight: Avoiding Redundant Comparisons

The central idea of KMP is to use the structure of the pattern itself to decide how many positions to shift when a mismatch occurs. Instead of shifting by one, we shift by an amount that ensures that the already‑matched suffix of the text aligns with a prefix of the pattern. This is exactly analogous to what a human would do when searching for a word in a book: if you see “ABABAC” and you’ve matched “ABABA” but the next character is wrong, you wouldn’t start over at the next position; you’d notice that the last few characters you matched (say “ABA”) could also be the beginning of a new occurrence. So you slide the pattern just enough to reuse that tail.

### Formalizing the Idea

Let’s define a **border** of a string _S_ as any proper prefix of _S_ that is also a suffix of _S_. For example, the string `"ABABA"` has borders of lengths 3 (`"ABA"`) and 1 (`"A"`). The empty string is also trivially a border (length 0), but we usually exclude it when talking about longest border. The **longest border** (also called **longest proper prefix that is also a suffix**) is crucial.

Suppose we are at some point in the search where we have matched the first _q_ characters of the pattern (0 ≤ q ≤ m) with the text, and the next character mismatches. Let _π_[q] be the length of the longest border of the prefix of length q (i.e., pattern[0..q‑1]). Then we know that the last _π_[q] characters of the matched text (the suffix) are equal to the first _π_[q] characters of the pattern (the border). Therefore, we can shift the pattern so that the prefix of length _π_[q] aligns with that suffix, without needing to re‑compare those characters. Then we can continue comparing the next character: the character at index _π_[q] in the pattern with the same text character that caused the mismatch. (In practice, we keep the text pointer stationary and just adjust the pattern index.)

This operation is often called “falling back” on the pattern. If the mismatch persists, we recursively use the failure function on the smaller prefix until we either find a match or reach the beginning of the pattern (π[0] = 0). This is reminiscent of a finite automaton where states correspond to the length of the matched prefix, and transitions are determined by the next character.

### A Visual Example

Let’s take pattern `"ABABAC"`. Compute its failure function (prefix function) for each prefix length q:

- q=0: empty string, border length = 0.
- q=1: prefix `"A"`. Proper suffixes: empty. No non‑empty border. π[1]=0.
- q=2: prefix `"AB"`. Suffixes: "B", empty. No border. π[2]=0.
- q=3: prefix `"ABA"`. Proper suffixes: "A", "BA". Among these, "A" is also a prefix (length 1). π[3]=1.
- q=4: prefix `"ABAB"`. Suffixes: "B", "AB", "BAB". "AB" is a prefix (length 2). Also "B"? "B" is not a prefix. So π[4]=2.
- q=5: prefix `"ABABA"`. Suffixes: "A", "BA", "ABA", "BABA". "ABA" is prefix (length 3). Also "A" (length 1). Longest is 3. π[5]=3.
- q=6: full pattern `"ABABAC"`. Suffixes: "C", "AC", "BAC", "ABAC", "BABAC". None is a proper prefix (the only prefix of length 1 is "A", but suffix of length 1 is "C", not matching). So π[6]=0. (The full pattern does not count as proper prefix)

So the failure array is [0,0,0,1,2,3,0] for q from 0 to 6. (We usually store π for each index in the pattern, i.e., for pattern position j, the length of border of pattern[0..j]. So π for j=0..m-1. But easier to work with q values. Standard implementation uses an array `lps` (longest proper prefix which is also suffix) of length m. Here lps[0]=0, lps[1]=0, lps[2]=1, lps[3]=2, lps[4]=3, lps[5]=0.)

Now, during search, suppose we have matched q=5 characters (i.e., pattern[0..4] = "ABABA" matched) and then the next text character is not 'C'. We look up π[5]=3. So we can shift the pattern such that the border of length 3 ("ABA") aligns with the last 3 characters of the matched text (which are "ABA" from the text). Then we set the new matched length to 3 and compare the next pattern character (pattern[3]='B') with the same text character that caused the mismatch. This avoids re‑comparing the first 3 characters.

If the new comparison also fails, we fall back again to π[3]=1, and so on. This process continues until we either match or reach q=0, at which point we move the text pointer forward and start matching from the beginning.

The beauty is that the text pointer never goes backward. We only adjust the pattern pointer using the precomputed table. This gives linear time.

### Mathematics of Borders

Why does this work? Because if we have matched a prefix of length q, and the text suffix of length k (k < q) is equal to that prefix, then k must be a border of the matched prefix. The largest such k is exactly π[q]. So by falling back to π[q], we are using the maximum possible amount of already‑matched characters to continue. Any larger shift would risk missing a potential occurrence.

A more formal argument: Suppose we have matched pattern[0..q‑1] with text[pos‑q..pos‑1] (pos is current text index). The next character text[pos] mismatches pattern[q]. We want to find the largest shift s such that for some k < q, pattern[0..k‑1] = text[pos‑k..pos‑1]. That k is a border of the matched prefix. The largest such k is π[q]. So we set q = π[q] and compare pattern[q] with text[pos] again. This process repeats.

The KMP search algorithm can be seen as running a deterministic finite automaton (DFA) where states are the lengths 0..m. The transition function δ(q, c) gives the length of the longest prefix of the pattern that is a suffix of the current matched string (which is the prefix of length q) concatenated with character c. Precomputing this transition table explicitly would be O(m·|Σ|) which is fine for small alphabets, but KMP achieves it implicitly using the failure function, enabling O(m) preprocessing and O(n) search.

## The Prefix Function (Failure Function) in Detail

The heart of the KMP algorithm is the prefix function, often denoted by π or `lps` (longest proper prefix which is also suffix). For each index j (0‑based) in the pattern, π[j] is defined as the length of the longest proper prefix of the substring pattern[0..j] that is also a suffix of that substring. Note that a proper prefix does not include the whole substring itself; thus for a single character, π[0]=0. For a string that has no border (except empty), π[j]=0.

### Computing the Prefix Function Efficiently

The naive way to compute π for all j would be O(m³) or O(m²) by checking each prefix against each suffix. However, we can compute it in O(m) time using a clever incremental algorithm. The idea is to build π for increasing lengths using previously computed values. The algorithm, as originally described by Knuth, Morris, and Pratt, uses two pointers: one for the current index i (starting from 1) and one for the length of the current longest border `len` (starting from 0). For each new character pattern[i], we try to extend the current border. If pattern[i] matches pattern[len], we increment len and set π[i] = len. Otherwise, we fall back to π[len‑1] and try again, until len becomes 0 or we find a match.

Here is the standard algorithm in Python:

```python
def compute_prefix_function(pattern):
    m = len(pattern)
    pi = [0] * m
    len_border = 0  # length of previous longest border
    i = 1
    while i < m:
        if pattern[i] == pattern[len_border]:
            len_border += 1
            pi[i] = len_border
            i += 1
        else:
            if len_border != 0:
                len_border = pi[len_border - 1]
            else:
                pi[i] = 0
                i += 1
    return pi
```

Let’s walk through this algorithm with the pattern `"ABABAC"` (m=6). We'll denote the pattern characters: A B A B A C.

Initialize: pi[0]=0, len_border=0, i=1.

- i=1, pattern[1]='B', pattern[len_border]=pattern[0]='A'. Not equal. len_border==0, so set pi[1]=0, i=2.
- i=2, pattern[2]='A', pattern[0]='A' -> equal. len_border=1, pi[2]=1, i=3.
- i=3, pattern[3]='B', pattern[1]='B' -> equal. len_border=2, pi[3]=2, i=4.
- i=4, pattern[4]='A', pattern[2]='A' -> equal. len_border=3, pi[4]=3, i=5.
- i=5, pattern[5]='C', pattern[3]='B' -> not equal. len_border != 0, so set len_border = pi[len_border‑1] = pi[2] = 1. Then check pattern[5] vs pattern[1]='B' -> not equal. len_border != 0, set len_border = pi[0]=0. Now len_border==0, so set pi[5]=0, i=6 done.

Result: pi = [0,0,1,2,3,0] — same as earlier.

### Proof of Linear Time

The above while loop runs in O(m) because each iteration either increments i (which happens at most m times) or reduces len_border (which can happen at most m times total, since len_border only increases when we increment i and decreases via fallback; each fallback reduces len_border, and len_border is bounded by m). More formally, we can amortize: the total number of fallback operations is bounded by the number of increases, so total operations O(m).

### Understanding the Fallback Mechanism

The key to the algorithm is the fallback loop. When pattern[i] does not match pattern[len_border], we don’t simply reset len_border to 0; we set it to pi[len_border‑1]. Why? Because we are trying to find the next‑longest border of the current prefix that might allow the character to match. Consider we have a matched border of length len_border. That means pattern[0..len_border‑1] = pattern[i‑len_border..i‑1] (since the suffix of the current prefix up to i‑1 matches the prefix). But if the next character pattern[i] does not equal pattern[len_border], we need a shorter border. The longest proper border of the prefix of length len_border is pi[len_border‑1]. That gives us a new candidate border length. We then try to see if pattern[i] matches pattern[new_len]. This is essentially the same idea as the KMP search itself, but applied to the pattern against itself.

Formally, the algorithm builds the prefix function using a kind of reverse KMP search. This is a beautiful example of self‑referential computation.

### Edge Cases and Variations

The prefix function can be stored as an array of integers. For a pattern with no repeated characters, e.g., `"ABCDEF"`, all π[i] are 0. For a pattern consisting of identical characters, e.g., `"AAAAA"`, the prefix function will be: [0,1,2,3,4]. This makes sense: for "AAAA", the longest border of "AAA" is "AA" (length 2), etc.

There is also a variant called the **failure function** used in the original KMP algorithm, which is essentially the same but sometimes defined with a shift: `next[k] = π[k-1]` for k>0, and `next[0] = -1`. This allows a simpler implementation of the search loop without checking for zero separately. We’ll see that shortly.

## The KMP Search Algorithm

With the prefix function computed, the search algorithm is straightforward. We maintain two indices: `i` for the text (starting at 0) and `j` for the pattern (starting at 0). While i < n and j < m, we compare text[i] with pattern[j]. If they match, we increment both. If they don’t match, we fall back j to π[j‑1] (or to `next[j]` in the alternative formulation). If j becomes 0 after fallback, we simply increment i and try again. When j reaches m, we have found a match at position i‑m. Then we set j = π[j‑1] to continue searching for overlapping occurrences.

Here is a Python implementation:

```python
def kmp_search(text, pattern):
    if not pattern:
        return []   # handle empty pattern
    n, m = len(text), len(pattern)
    pi = compute_prefix_function(pattern)
    matches = []
    j = 0  # number of characters matched in pattern
    for i in range(n):
        while j > 0 and text[i] != pattern[j]:
            j = pi[j-1]
        if text[i] == pattern[j]:
            j += 1
        if j == m:
            matches.append(i - m + 1)
            j = pi[j-1]
    return matches
```

Note: The common implementation uses a `while` loop for fallback and increments i in the outer `for`. The while loop handles multiple fallbacks if necessary. This is exactly the same logic as building the prefix function.

Let’s trace through the earlier example: text = `"ABABABAC"`, pattern = `"ABABAC"`.

Prefix function pi = [0,0,1,2,3,0].

Initialize i=0, j=0.

- i=0: text[0]='A', pattern[0]='A' -> match. j becomes 1.
- i=1: text[1]='B', pattern[1]='B' -> match. j=2.
- i=2: 'A' vs 'A' -> match, j=3.
- i=3: 'B' vs 'B' -> match, j=4.
- i=4: 'A' vs 'A' -> match, j=5.
- i=5: text[5]='B', pattern[5]='C' -> mismatch. Enter while: j=5>0, so j = pi[4]=3. Check again: text[5]='B' vs pattern[3]='B'? Now j=3, compare pattern[3]='B' with text[5]='B' -> match. j becomes 4.
- i=6: text[6]='A', pattern[4]='A' -> match. j=5.
- i=7: text[7]='C', pattern[5]='C' -> match. j=6 now equals m. Record match at i-m+1 = 7-6+1=2 (0‑based index 2). Then j = pi[5-1]=pi[4]=3.
- Loop continues? i goes to 8, n=8, so stop.

So we found one match at position 2. That’s correct.

Notice that during the fallback at i=5, we didn’t move i backward. We simply reduced j from 5 to 3 and then compared the same text character with pattern[3]. That’s the elegance: no backtracking on text.

### Alternative Formulation with `next` Array

Many textbooks present KMP with a `next` array that includes a sentinel at index 0 with value -1. The prefix function computed above is usually shifted: `next[0] = -1`, and for k ≥ 1, `next[k] = pi[k-1]`. The search loop then becomes:

```python
j = 0
i = 0
while i < n:
    if j == -1 or text[i] == pattern[j]:
        i += 1
        j += 1
        if j == m: found match
    else:
        j = next[j]
```

This version is sometimes easier to implement with a single while loop. The fallback to -1 effectively means we reset j to 0 and increment i. The prefix function computation can also be adapted to produce `next` directly.

## Complexity Analysis and Correctness

### Time Complexity

The KMP search algorithm runs in O(n + m) time. The preprocessing of the prefix function takes O(m) as argued. The search loop: each time we move the text pointer i forward (once per iteration of the outer for loop), we have at most one increment of j (when characters match). The while loop for fallback may reduce j, but j never goes below 0 and each reduction corresponds to a previous increment. The total number of reductions across the entire search is bounded by the total number of increments (which is at most n). Also, the outer loop runs exactly n times. So total operations are O(n). This is a standard amortized analysis.

Thus the overall time is O(n + m). Notably, this is the best possible time for exact string matching in the comparison model because you must at least examine each character of text and pattern.

### Space Complexity

The algorithm uses O(m) extra space for the prefix function (or next array). This is often negligible.

### Correctness Proof

We can argue correctness by showing that the algorithm never misses a match and never reports a false positive. The proof relies on the fact that when we fall back using the prefix function, we maintain the invariant that the prefix of length j of the pattern matches the suffix of length j of the currently scanned text (i.e., text[i‑j..i‑1]). When j reaches m, we have a full match. The fallback ensures that we do not skip over possible starting positions; in fact, the longest border ensures that we shift the minimal safe amount. Formal proofs can be found in algorithm textbooks (e.g., CLRS). The key point: if a match starts at position s, then when i reaches s+m, we will have j=m, and we record it. The algorithm only shifts j when a mismatch occurs, and the shift length is exactly the amount needed to align borders, which is optimal.

### Handling Overlapping Matches

In the code above, after finding a match, we set j = pi[j‑1] to allow overlapping matches. For example, pattern = "AA", text = "AAA". The matches should be at positions 0 and 1. The algorithm would: after matching at i=1 (j=2), set j=pi[1]=1, then continue with i=2, text[2]='A', j=1, compare pattern[1]='A' -> match, j=2, record match at position 2-2+1=1? Actually careful: i increments after comparison. Let's simulate quickly: For i from 0 to 2 (n=3):

- i=0: text[0]='A', j=0 initial. Compare: match, j=1.
- i=1: text[1]='A', j=1, compare pattern[1]='A' -> match, j=2. Since j==m=2, record match at i-m+1 = 1-2+1=0. Then j=pi[1]=1.
- i=2: text[2]='A', j=1, compare pattern[1]='A' -> match, j=2. Record match at i-m+1 = 2-2+1=1.
  So both positions found. Good.

## Implementation Considerations

### Handling Empty Pattern

If the pattern is empty, by convention it is considered to be found everywhere? Usually, we return an empty list because a pattern with length 0 is degenerate. In our code, we added an early check.

### Character Encoding

KMP works on any alphabet—ASCII, Unicode, bytes. The comparison is character-by-character. For large alphabets like Unicode, it’s still fine because the algorithm only compares equality.

### Performance in Practice

KMP is O(n+m), but in practice, the constant factors can be high due to the failure function lookups and extra loops. For small patterns or random text, the naïve algorithm often outperforms KMP because of lower overhead. KMP shines when the pattern contains many repeated substrings or when the text is large and the pattern is long. Real‑world implementations of `grep` or `sed` often use the Boyer‑Moore algorithm, which can be faster on average. However, KMP has the advantage of linear worst‑case time, making it useful in safety‑critical systems or when worst‑case guarantees are needed.

### Optimization: Precomputing the Full Automaton

If the alphabet size is small (e.g., DNA bases: 4), we can precompute the entire transition table of size (m+1)×|Σ| for the KMP automaton. Then the search becomes a simple loop: state = 0; for each character c in text: state = next[state][c]; if state == m: found. This is sometimes called the **KMP automaton** or **string matching automaton**. It uses more memory (O(m·|Σ|)) but speeds up the inner loop (no fallback while). For large alphabets, the table may be too big.

### Memory‑Efficient Implementation

The standard `lps` array is sufficient. Some implementations store it as a list of integers. For very large patterns (millions of characters), the O(m) memory is acceptable.

## Comparison with Other Algorithms

KMP is one of several linear‑time string matching algorithms. It’s instructive to compare it with two other famous algorithms: Rabin‑Karp and Boyer‑Moore.

### Rabin‑Karp

Rabin‑Karp uses hashing to find matches. It computes a rolling hash of the pattern and of each window in the text. Expected time is O(n+m), but worst‑case can be O(nm) if many hash collisions occur. It is often used for multiple pattern search (e.g., with a hash table). KMP is more robust because it guarantees linear worst‑case time without relying on randomness.

### Boyer‑Moore

Boyer‑Moore is a heuristic algorithm that often performs sublinear in practice (O(n/m) on average) by skipping characters based on the “bad character rule” and “good suffix rule”. It is widely used in Unix `grep`. However, its worst‑case is O(nm) in the original version, though modifications (like the Galil rule) can make it linear. For patterns with large alphabets, Boyer‑Moore can be very fast because it skips many characters. For patterns with small alphabets (e.g., DNA), KMP may be competitive.

KMP has a simple worst‑case guarantee, which makes it a favorite in textbooks and in applications where predictability matters, such as real‑time systems or network intrusion detection.

### Z‑algorithm

The Z‑algorithm computes for a string S the array Z[i] = length of longest substring starting at i that matches a prefix of S. It can be used for string matching by concatenating pattern + "$" + text and computing Z. This also runs in O(n+m) and is conceptually simpler. KMP and Z are closely related; the Z‑algorithm can be seen as a variant. But KMP has the advantage of using O(m) extra space vs O(n) for Z in some implementations.

## Applications and Extensions

### Bioinformatics

In genomics, DNA sequences are long strings over a 4‑letter alphabet. Exact string matching is used to locate primers, restriction sites, or patterns in genomes. KMP’s linear time and small memory footprint make it suitable for aligning reads to a reference (though often approximate matching is needed). For example, looking for a 20‑base pair pattern in a 3‑billion‑base‑pair human genome would take about 3 billion comparisons using KMP—roughly a few seconds on a modern CPU.

### Text Editors and Compilers

The `find` functionality in text editors often uses KMP or Boyer‑Moore. Compilers use KMP in lexical analysis (e.g., scanning for keywords). Although lexer generators like Lex or Flex use deterministic finite automata built from regular expressions, the underlying matching technique is similar.

### Network Security

Intrusion detection systems (like Snort) search for patterns in network packets. They often use Aho‑Corasick, which is an extension of KMP to multiple patterns. Aho‑Corasick builds a trie with failure links (like KMP’s prefix function) to simultaneously search for many patterns in linear time.

### Multiple Pattern Matching: Aho‑Corasick

The Aho‑Corasick algorithm generalizes KMP to a set of patterns. It constructs a trie of all patterns and then adds failure links from each node to the longest proper suffix that is also a prefix of some pattern. The search is then a simple traversal of the automaton. This is widely used in antivirus software and spam filters.

### Approximate String Matching

KMP can be adapted for approximate matching (e.g., K‑mismatches) but not trivially. The standard edit distance algorithms (Needleman‑Wunsch, Smith‑Waterman) are used instead.

## Advanced Insights: The Automaton View

For the mathematically inclined, KMP defines a **string matching automaton** (SMA). The states are the lengths of the longest prefix matched so far, from 0 to m. The start state is 0, and the accept state is m. The transition function δ(q, c) returns the new state after reading character c. This can be computed using the failure function: if pattern[q] == c, then δ(q, c) = q+1; else, recursively fall back to π[q‑1] and check again, until q=0; if pattern[0] != c, then δ(0, c)=0. This can be precomputed into a 2D array.

The KMP search is essentially simulating this automaton, but by using the failure function on‑the‑fly rather than storing all transitions. This is memory‑efficient.

The prefix function itself can be seen as a kind of **self‑automaton** where the pattern is matched against itself.

## Conclusion

The Knuth–Morris–Pratt algorithm is a milestone in algorithm design. It elegantly solves the exact string matching problem in linear time by preprocessing the pattern to understand its internal symmetry. The key idea—using borders to avoid redundant comparisons—is both simple and profound. Once you grasp the concept of the prefix function, the search algorithm becomes almost trivial.

Beyond its practical utility, KMP is a perfect example of how algorithmic thinking can transform a naive O(n·m) solution into an optimal O(n+m) one. It demonstrates the power of amortized analysis, the beauty of self‑referential computation, and the importance of precomputation. Even today, over fifty years after its invention, KMP remains a fundamental tool in the string‑processing toolbox.

Whether you are a student learning about string algorithms, a software engineer building a text search feature, or a researcher working on pattern matching, understanding KMP deepens your appreciation for the subtle art of efficient algorithm design. And the next time you type Ctrl+F and see results appear instantly, you’ll know that somewhere, a descendant of KMP (or Boyer‑Moore or Rabin‑Karp) is working behind the scenes, making your digital life seamless.

---

_Further reading:_

- Knuth, Morris, Pratt, "Fast Pattern Matching in Strings", 1977.
- Introduction to Algorithms (CLRS), Chapter 32: String Matching.
- The Z‑algorithm: A simpler linear‑time string matching method.
- Aho‑Corasick algorithm for multiple patterns.
