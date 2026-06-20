---
title: "A Deep Dive Into The Palindromic Tree (Eertree): Construction And Applications In Stringology"
description: "A comprehensive technical exploration of a deep dive into the palindromic tree (eertree): construction and applications in stringology, covering key concepts, practical implementations, and real-world applications."
date: "2021-02-17"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/a-deep-dive-into-the-palindromic-tree-(eertree)-construction-and-applications-in-stringology.png"
coverAlt: "Technical visualization representing a deep dive into the palindromic tree (eertree): construction and applications in stringology"
---

# The Palindromic Tree: A Deep Dive into the Eertree and Its Algorithmic Marvels

## 1. Introduction: The Seductive Symmetry of Palindromes

Consider the humble palindrome. It is, at its surface, the simplest of linguistic curiosities—a word, phrase, or sequence that reads the same forwards and backwards: "racecar," "madam," "A man, a plan, a canal, Panama." We encounter them in puzzles, in poetry, and in the quiet, satisfying symmetry of a well-formed number like 1221. They seem trivial. Yet, for the computer scientist—specifically, for the stringologist—palindromes represent a deep and surprisingly rich vein of algorithmic complexity. The problem is not about _finding_ a palindrome; any schoolchild can spot a three-letter one. The real challenge, the one that has occupied some of the sharpest minds in theoretical computer science for decades, is this: given a string of millions of characters, can you list every single palindromic substring, count how many times each appears, and do it all in time that is linear to the length of the string? This is the domain of the **Palindromic Tree**, also known as the **Eertree**.

For the uninitiated, this might sound like a narrow, esoteric problem. Why would anyone need to catalog every palindrome in a massive text? The answer lies in the surprising ubiquity of palindromic structures in natural and artificial data. In bioinformatics, palindromic sequences are critical in understanding DNA structure and function. Restriction enzymes, the molecular scissors used in genetic engineering, often target specific palindromic sequences. Being able to quickly index all such sequences in a genome—or find the longest one—is not a parlor trick; it is a fundamental operation in computational genomics. In data compression, the discovery of long palindromes allows for efficient encoding of repetitive patterns. In text analysis and natural language processing, palindromes are used in cryptography, plagiarism detection, and even the algorithmic study of poetic forms. And in the bedrock of competitive programming and algorithm design, the ability to handle palindromes efficiently is a testbed for elegant data structures and a gateway to understanding more complex automata.

The Palindromic Tree, introduced by Mikhail Rubinchik and Arseny Kamanin in 2014 (and later independently discovered by others), is a remarkably simple yet powerful data structure that solves the problem of enumerating all distinct palindromic substrings in linear time. Its construction is deceptively straightforward: just a few dozen lines of code suffice to build a tree that encodes every palindrome in a string. The magic lies in the use of _suffix links_ and a pair of root nodes that represent odd and even length palindromes. But beneath the surface, the Eertree is a testament to the beauty of algorithmic design—a structure that leverages the self-similar nature of palindromes to achieve efficiency that feels almost magical.

In this article, we will journey from the naive brute-force approach (O(n³) time, if you’re feeling optimistic) to the elegant O(n) solution of the Eertree. We’ll explore the data structure in minute detail, walk through its construction with concrete examples, prove its correctness and complexity, and then dive into a rich tapestry of applications. By the end, you’ll see why the humble palindrome is anything but trivial—and why the Eertree is one of the most satisfying data structures in the algorithmic canon.

## 2. The Problem: Enumerating Palindromic Substrings

Let us begin with a formal definition. Given a string $S$ of length $n$ over some alphabet $\Sigma$, a _palindromic substring_ is any contiguous substring $S[i..j]$ such that $S[i..j] = \text{reverse}(S[i..j])$. Equivalently, it reads the same forwards and backwards. The substring can be of even length (e.g., "abba") or odd length (e.g., "aba").

Our goal: produce a data structure that can answer the following queries in constant or logarithmic time after preprocessing:

- How many distinct palindromic substrings exist in $S$?
- For each distinct palindrome, how many times does it occur as a substring (including overlapping occurrences)?
- What is the longest palindromic substring?
- Given a position, what is the longest palindrome centered there?
- And many more variations.

The naive approach: for every starting index $i$ and ending index $j$, check if $S[i..j]$ is a palindrome. Checking takes $O(j-i+1)$ time, and there are $O(n^2)$ substrings, leading to $O(n^3)$ time. Even with center-expansion (checking around each center in $O(n^2)$ total), we only get the longest palindrome at each center, not a list of all distinct palindromes.

A better approach: use a suffix tree or suffix array augmented with LCA queries to list palindromes in $O(n \log n)$ or $O(n)$ time, but these structures are heavy and complex. For decades, the gold standard for palindrome problems was Manacher’s algorithm (1975), which computes the longest palindrome centered at each position in linear time. But Manacher gives only the maximal radius at each center; it does not directly give all distinct palindromes, nor their counts. You can derive all odd-length palindromes by taking all radii, but distinct palindromes require careful deduplication, and even-length palindromes need special handling. Moreover, Manacher gives the odd and even palindromes separately (using two passes). To count occurrences of each distinct palindrome, you’d need additional processing, such as building a suffix automaton on the string and its reverse—again, heavy.

The Eertree elegantly solves all these problems in a single linear-time construction. It provides an automaton that recognizes all palindromes and encodes their occurrences. Let us see how.

## 3. Historical Context and Related Work

Before diving into the Eertree, it is instructive to understand the landscape of palindrome algorithms.

- **Manacher’s Algorithm (1975)** : Linear time, finds longest palindrome centered at each position. Uses symmetry to avoid redundant comparisons. It is elegant and simple, but limited to a single query: the longest palindrome. It cannot enumerate distinct palindromes without further work.

- **Suffix Tree / Suffix Array**: By building a suffix tree and its reverse, one can use LCA queries to test if a substring is a palindrome in $O(1)$ time. Then enumerating all distinct palindromes can be done in $O(n)$ time using a clever algorithm by Apostolico, Breslauer, and Galil (1995). However, suffix trees are memory-intensive and require significant coding effort.

- **Z-algorithm / Rolling Hash**: Using hashing, one can binary search for longest palindrome at each center in $O(n \log n)$ time, but hashing can have collisions, and distinct enumeration still requires deduplication.

- **Palindrome Factorization**: In 2015, Rubinchik and Shur introduced a new concept of palindrome factorization, but the Eertree itself was the breakthrough.

The Eertree was first described by Mikhail Rubinchik in his 2014 article “Palindromic Tree: A New Data Structure” (in Russian, later translated). It is also referred to as the “Eertree” (from “Eertree” = “tree of palindromes” in Russian? Actually the name comes from the syllables of the authors' names? No, Eertree is a play on “tree” and the reverse of “tree”? The origin is unclear, but it has stuck). The structure is essentially a finite automaton that recognizes all palindromic suffixes of the string, much like how a suffix automaton recognizes all substrings. However, its construction is simpler and more memory-efficient than a suffix automaton for palindrome recognition.

The Eertree has since been generalized to handle dynamic strings (insertions and deletions), weighted palindromes, and even 2D palindromes. Its beauty lies in its minimalism: each node represents a distinct palindrome, and the edges are character-labeled, allowing traversal. The suffix links connect a palindrome to its longest proper palindromic suffix.

## 4. The Data Structure: Nodes, Edges, and Suffix Links

At its core, the Eertree is a rooted tree (or rather, a forest with two roots) where:

- Each **node** corresponds to a distinct palindromic substring of the input string.
- Each node stores: `len` (length of the palindrome), `occ` (occurrence count), `link` (suffix link to the longest proper palindromic suffix), and `next[c]` (edges to child nodes, representing the palindrome obtained by adding character `c` to both ends of the current palindrome).
- There are two **root nodes**:
  - **Root 1** (odd root): represents a palindrome of length -1. This is a sentinel used for odd-length palindromes. Its suffix link points to itself.
  - **Root 2** (even root): represents a palindrome of length 0 (the empty string). Its suffix link points to Root 1.
- The `next` edges from these roots allow building palindromes of length 1 and 2. For example, from the -1 root, adding a character `c` creates the palindrome of length 1: "c". From the 0 root, adding `c` creates the palindrome of length 2: "cc".

- The **suffix link** of a node with palindrome $P$ points to the longest proper palindromic suffix of $P$ (i.e., the largest palindrome that is a suffix of $P$ but not equal to $P$). For the roots, we define special links: root -1 links to itself, root 0 links to root -1.

The key invariant during construction: As we process the string character by character, we maintain a pointer `last` which is the node corresponding to the longest palindromic suffix of the current prefix (i.e., the longest palindrome that ends at the current position). This is analogous to the `last` state in a suffix automaton.

## 5. Construction Algorithm: Step-by-Step

Now, let us construct the Eertree for the string $S = \text{“abacaba”}$ as a running example. The alphabet $\Sigma = \{a, b, c\}$. We will write code in Python-like pseudocode, then trace the state.

### 5.1 Initialization

We create two nodes:

- Node 0: `len = -1`, `link = 0` (self-loop)
- Node 1: `len = 0`, `link = 0` (points to odd root)
  Set `size = 2` (number of nodes so far). Initialize `last = 1` (point to even root, representing empty string). Also, we need an array `s` to store the string, starting with `s[0] = -1` (a sentinel character not in the alphabet) to simplify boundary checks.

### 5.2 Adding a character

When adding a new character $c$ at position $pos$ (0-indexed), we follow these steps:

1. Find the longest palindrome that can be extended by $c$ at the end. Starting from `last`, we traverse suffix links until we find a node $v$ such that the character before its palindrome matches $c$. More precisely, let $k = v.len$. We check if the character at position $pos - k - 1$ equals $c$. If not, set $v = v.link$ and repeat.

2. Once we find such $v$, check if $v.next[c]$ exists. If it does, then the palindrome already exists; we set `last = v.next[c]` and increment its occurrence count.

3. If $v.next[c]$ does not exist, we create a new node: `len = v.len + 2`. Then we set `last = this new node`.

4. Now we need to set the suffix link for the new node. This is done by finding the longest proper palindromic suffix of the new palindrome. We start from $v.link$ and again traverse suffix links until we find a node $w$ such that the character before its palindrome equals $c$ (i.e., $s[pos - w.len - 1] == c$). Then we set `new_node.link = w.next[c]`. (If $len = 1$, we link to the even root; if $len = 2$, we link to the odd root? Actually the algorithm handles this automatically because the traversal will eventually hit a root.)

5. Finally, increment the occurrence count of the new node (set to 1 initially, but we can also count later during a second pass).

### 5.3 Pseudocode

```python
class Eertree:
    def __init__(self, s):
        self.s = s
        self.n = len(s)
        self.next = [dict() for _ in range(self.n + 2)]   # adjacency list, can be list of lists for fixed alphabet
        self.len = [0] * (self.n + 2)
        self.link = [0] * (self.n + 2)
        self.occ = [0] * (self.n + 2)
        self.s = [-1] + [ord(c) for c in s]  # sentinel at index 0

        # initialize roots
        self.len[0] = -1
        self.link[0] = 0
        self.len[1] = 0
        self.link[1] = 0
        self.size = 2  # nodes 0 and 1
        self.last = 1  # points to empty string

        for i in range(1, self.n + 1):
            self.add_char(i)

        # propagate occurrences: after construction, traverse in decreasing order of length
        for v in range(self.size-1, 1, -1):
            self.occ[self.link[v]] += self.occ[v]

    def add_char(self, pos):
        c = self.s[pos]
        # Step 1: find the longest palindrome that can be extended
        v = self.last
        while True:
            cur_len = self.len[v]
            if pos - cur_len - 1 >= 0 and self.s[pos - cur_len - 1] == c:
                break
            v = self.link[v]

        # Step 2: check if edge exists
        if c in self.next[v]:
            self.last = self.next[v][c]
            self.occ[self.last] += 1
            return

        # Step 3: create new node
        new_node = self.size
        self.size += 1
        self.len[new_node] = self.len[v] + 2
        self.next[v][c] = new_node
        self.occ[new_node] = 1

        # Step 4: set suffix link for new node
        if self.len[new_node] == 1:  # single character palindrome
            self.link[new_node] = 1  # link to even root (empty string)
        else:
            # Find the longest proper suffix that is also a palindrome
            w = self.link[v]
            while True:
                cur_len = self.len[w]
                if pos - cur_len - 1 >= 0 and self.s[pos - cur_len - 1] == c:
                    break
                w = self.link[w]
            self.link[new_node] = self.next[w][c]

        self.last = new_node
```

### 5.4 Tracing “abacaba”

Let’s simulate the construction step by step. We’ll treat $s$ as 1-indexed for characters (positions 1..7). Initialize `last = 1` (empty string).

**i=1, char=‘a’:**

- Start from `last=1` (len=0). Check: pos - len - 1 = 1-0-1=0, s[0] = -1 != 'a', so go to link[1]=0 (odd root). Now v=0, len=-1. Check: pos - (-1) -1 = 1+1-1=1? Wait careful: len=-1, so pos - (-1) -1 = pos. Actually pos=1, s[1]=‘a’. The condition checks s[pos - len -1]? Let’s abstract: For node v with length L, we want to see if the character at position pos - L - 1 equals c. For v=0, L=-1, pos - (-1) -1 = pos so s[pos] which is the current character? That’s intended: the odd root allows creating single-character palindromes. So it matches. Break.

- v=0. Check next[0][‘a’] doesn’t exist. Create new_node=2, len= -1+2=1. Set next[0][‘a’]=2. occ[2]=1.

- Set suffix link: len==1 so link[2]=1.

- last = 2.

**i=2, char=‘b’:**

- Start last=2 (len=1). Check: pos=2, L=1 => pos-L-1=0, s[0]=-1 != ‘b’. So v=link[2]=1 (even root). v=1, L=0 => pos-0-1=1, s[1]=‘a’ != ‘b’. So v=link[1]=0. v=0, L=-1 => pos-(-1)-1=2, s[2]=‘b’ matches. Break.

- v=0. Check next[0][‘b’]? No. Create new_node=3, len= -1+2=1. occ=1. link[3]=1. last=3.

**i=3, char=‘a’:**

- Start last=3 (len=1). Check: L=1 => pos-L-1=1, s[1]=‘a’? Actually pos=3, L=1 => 3-1-1=1, s[1]=‘a’ matches c=‘a’. So v=3 (already). Check next[3][‘a’]? No. Create new_node=4, len=1+2=3. occ=1. Set link: Since len!=1, we need to find suffix link. w = link[v] = link[3] = 1. Now while loop: w=1, L=0 => pos-0-1=2, s[2]=‘b’ != ‘a’. w=link[1]=0, L=-1 => pos-(-1)-1=3, s[3]=‘a’ matches. So w=0, then link[4] = next[0][‘a’] = node 2 (the palindrome “a”). So suffix link of “aba” points to “a”. Correct: longest proper palindromic suffix of “aba” is “a”. last=4.

**i=4, char=‘c’:**

- Start last=4 (len=3). Check: L=3 => pos-L-1=0, s[0]=-1 != ‘c’. v=link[4]=2 (node “a”, len=1). Check: L=1 => 4-1-1=2, s[2]=‘b’ != ‘c’. v=link[2]=1 (empty). L=0 => 4-0-1=3, s[3]=‘a’ != ‘c’. v=link[1]=0, L=-1 => 4-(-1)-1=4, s[4]=‘c’ matches. v=0. Create new_node=5, len= -1+2=1, occ=1, link=1. last=5.

**i=5, char=‘a’:**

- Start last=5 (len=1). Check: L=1 => 5-1-1=3, s[3]=‘a’ matches. v=5. next[5][‘a’]? No. Create new_node=6, len=1+2=3, occ=1. Set link: w=link[5]=1; w=1 L=0 => 5-0-1=4, s[4]=‘c’ != ‘a’; w=link[1]=0, L=-1 => 5-(-1)-1=5, s[5]=‘a’ matches. link[6]=next[0][‘a’]=2 (“a”). last=6.

**i=6, char=‘b’:**

- Start last=6 (len=3). Check: L=3 => 6-3-1=2, s[2]=‘b’ matches c. v=6. next[6][‘b’]? No. Create new_node=7, len=3+2=5, occ=1. Set link: w=link[6]=2 (node “a” len=1). w=2 L=1 => 6-1-1=4, s[4]=‘c’ != ‘b’; w=link[2]=1 (empty); L=0 => 6-0-1=5, s[5]=‘a’ != ‘b’; w=link[1]=0, L=-1 => 6-(-1)-1=6, s[6]=‘b’ matches. link[7]=next[0][‘b’]=3 (“b”). So palindrome “ababa” links to “b”. Correct. last=7.

**i=7, char=‘a’:**

- Start last=7 (len=5). Check: L=5 => 7-5-1=1, s[1]=‘a’ matches. v=7. next[7][‘a’]? No. Create new_node=8, len=5+2=7, occ=1. Set link: w=link[7]=3 (node “b” len=1). w=3 L=1 => 7-1-1=5, s[5]=‘a’? Wait c=‘a’, s[5]=‘a’? Actually s[5]=‘a’ (the fifth character?), let's list: indices: 1:a,2:b,3:a,4:c,5:a,6:b,7:a. So s[5]=‘a’. So at w=3, L=1 => 7-1-1=5, s[5]=‘a’ matches c. So we break immediately. link[8]=next[3][‘a’]? But next[3] does not have an edge for ‘a’ yet. Wait, we have node 6 which is “aba” with length 3. Is “aba” a suffix of “abacaba”? Actually “abacaba” ends with “aba”. So the longest proper palindromic suffix of length 7? The string itself “abacaba” is a palindrome; its longest proper palindromic suffix should be “aba”. But our algorithm found w=3 (node “b” length1) and then checked if s[7-1-1]=s[5]=‘a’ matches c. It does, so we would set link[8] = next[3][‘a’]. But next[3][‘a’] does not exist yet! This is a subtlety: we must ensure that when we set the suffix link for the new node, we might need to create the target node if it doesn't exist? But the target node must already exist because it is a palindrome that ends at a previous position. In our construction, “aba” (node 4) exists, but it is not a child of node 3. Node 3 is “b”, and “aba” is not obtained by adding ‘a’ to both ends of “b” (that would give “bab” not “aba”). So the algorithm is correct: we must traverse further from w until we find a node that has a child for c. Let's redo step correctly.

When setting suffix link for new node (length 7), start from v=7? Actually we start from w = link[v] where v is the node that was extended (v=7). w = link[7] = 3 (node “b”). Now we need to find a node that starts with a suffix that can be extended by c. We enter a while loop:

- w=3, L=1 => pos - L -1 = 7-1-1 =5, s[5]=‘a’ matches c? Yes. So we would set link[8] = next[w][c] = next[3][‘a’]. But next[3][‘a’] does not exist. However, note that the condition that s[pos - L -1] == c is necessary but not sufficient: we also need that w has an edge for c. In the standard algorithm, we first check if such an edge exists; if not, we continue the while loop. But the condition we used (the character match) is actually used to find the right w such that we can then check its next. In many implementations, the while loop is exactly as described: keep traversing until we find a node w such that s[pos - len[w] -1] == c. Then we set link = next[w][c]. But if next[w][c] does not exist, that means the palindrome we are trying to link to hasn't been created yet! However, note that if we found w such that the character matches, then the palindrome of length len[w]+2 must exist because it has been created previously? Actually it might not have been created if we haven't encountered that palindrome earlier. But in our construction, the palindrome “aba” (length 3) exists as node 4. Why isn't it a child of node 3? Because node 3 is “b”, and to get “aba” you would need to add ‘a’ to both ends of “b”, which gives “bab”. So “aba” is not a child of “b”. Therefore, the algorithm's logic for finding the link is slightly different: we must continue until we find a node w such that next[w][c] exists. The condition on character match is used to navigate, but the actual test is existence of next edge. Let's correct.

The standard pseudocode for setting suffix link (from Rubinchik's original) is:

```
let w = link[v]
while w != 0 and s[pos - len[w] - 1] != c:
    w = link[w]
link[new_node] = next[w][c]
```

Here, `w` is being traversed until the character condition holds, and then we assume `next[w][c]` exists. But in our case, for `w=3`, `s[pos - len[3] -1] = s[5]=‘a’` equals c, but `next[3][‘a’]` does not exist. So the loop would stop at w=3, but next[3][‘a’] is missing. This indicates a bug in the above simplified logic. The correct condition is: we want the longest proper palindromic suffix of the new palindrome. That palindrome is of length len[w] + 2. It must have been created earlier because it appears as a substring ending at pos-1? Actually no, the palindrome itself ends at pos, but its proper suffix ends at pos. However, the palindrome we are looking for has length len[w]+2, and it must be a suffix of the new palindrome, so it ends at pos. But it might not have been created yet if it appears for the first time! Wait, but if it appears for the first time, then we would be creating it now. However, in the algorithm, we only create one node per distinct palindrome. The new palindrome we are creating (length L) is brand new. Its longest proper palindromic suffix is a palindrome that ends at pos but is shorter. Could that shorter palindrome also be appearing for the first time? Possibly, but it would have been created earlier when we processed an earlier occurrence of that shorter palindrome. Since it ends at pos, and pos is the first occurrence of the new palindrome, the shorter palindrome must have ended at a previous position (maybe the same pos? No, it ends at pos as a suffix). Actually, if the shorter palindrome ends at pos, then it appeared earlier at some other position? Not necessarily: it could be that this is the first time that shorter palindrome appears ending at pos. But since it is a substring of the new string, and we process left to right, when we encounter the new palindrome, the shorter suffix might be new as well if it hasn't been seen before. But the algorithm handles this: it first creates the node for the longer palindrome, and then sets its link. The link might point to a node that hasn't been created yet? No, because the shorter palindrome has length less than the new one, and if it is new, it would have been created at the same time? Actually, the order of creation ensures that all palindromes of smaller length are created before larger ones? Not necessarily. In a string like “aaa”, when processing third ‘a’, we create “aaa” before its proper suffix “a” (already exists) and “aa” (exists). So shorter ones already exist. For “abacaba”, the proper suffix of the whole string is “aba” which was created at i=3. So it exists. The issue was that we were looking for it as a child of node 3, but it is a child of node 0, not node 3. So our character condition is misleading: we need to find a node `w` such that `next[w][c]` exists _and_ the character condition holds. The condition ensures that the palindrome obtained by extending w by c is indeed a suffix of the new palindrome. So we must traverse until both conditions hold: `s[pos - len[w] - 1] == c` and `c in next[w]`. In practice, many implementations combine the check: they first find w such that the character matches, then check if the edge exists; if not, they continue. But the character condition alone is not enough to guarantee the edge exists because the edge may belong to a different node that also satisfies the character condition? Actually, for a given w, the character condition is that the character before the palindrome represented by w (at position pos - len[w] - 1) equals c. If this holds, then the palindrome formed by adding c to both ends of w is a palindromic suffix of the current prefix. However, that palindrome may not have been created yet if w's next edge missing. But if the character condition holds, then the palindrome of length len[w]+2 appears as a substring ending at pos. Is it possible that it hasn't been created yet? It must have been created when its first occurrence ended at some earlier position. Since it ends at pos, if pos is its first occurrence, then it would be created now during the same addition. But we are in the middle of adding a character and we first create the longer palindrome. Then we set its link. The link could point to a palindrome that is being created in the same step? That would be a cycle: the longer palindrome's suffix link points to a shorter palindrome that is also new and will be created later. But because we process the string sequentially, the shorter palindrome's first occurrence could be earlier. In “abacaba”, the suffix “aba” first occurred at i=3, so it exists. So the problem is just that our traversal for finding the link must consider only nodes that already have the edge. Therefore, the standard algorithm for setting the link is:

```
w = link[v]
while True:
    cur_len = len[w]
    if pos - cur_len - 1 >= 0 and s[pos - cur_len - 1] == c and c in next[w]:
        break
    w = link[w]
link[new_node] = next[w][c]
```

But note that `c in next[w]` is guaranteed to be true when we break because the condition checks it. Alternatively, many implementations simply call `get_link` function that uses the same while loop as before, but now they check `next[w][c]` existence. Actually, the original simpler version works because when the character condition holds, the palindrome `w` extended by `c` must exist because it is a substring that ends at the current position, and it must have been encountered before due to the nature of the construction: if it hadn't, then there would be a longer palindrome that also satisfies the condition? Let's analyze more carefully.

In the step for setting the link, we have just created a new node for a palindrome of length L. We want its longest proper palindromic suffix. That suffix, call it P', is a palindrome of length L' < L that ends at pos. Because the new node's palindrome ends at pos, P' also ends at pos. Now, consider the first time P' appeared. Could it be that this is the first occurrence of P'? If so, then when we processed the character at pos, we would have created P' before creating the longer palindrome? But the order is: we first find the longest palindrome that can be extended by c, which is of length L-2. Then we create the new node of length L. Then we set its link. At the moment of setting the link, P' (length L') is not yet created if this is its first occurrence. However, is it possible that P' appears for the first time as a suffix of a longer palindrome that is being created now? Yes, for example, consider the string “ababa”. When processing the fifth character (the second 'a'), we create “ababa”. Its longest proper palindromic suffix is “aba”. At that point, “aba” was already created at position 3. So it exists. Another example: “aabaa”. Process: i=1:'a' creates "a". i=2:'a' creates "aa" (and "a" exists). i=3:'b' creates "b". i=4:'a' creates "aba"? Actually at i=4, char='a', we have last=... creates "aba"? Let's test: after i=3, last points to "b". At i=4, we find extension: start from last "b", check condition? More systematic: using code, we can simulate. But the point is: is there a case where a palindrome's longest proper palindromic suffix first appears at the exact same position? Possibly. For instance, in string “aaa”, at i=3, we create “aaa”. Its longest proper suffix is “aa”, which was created at i=2. So again earlier. How about a string like “a” -> only "a". No. Let's try “abca”. At i=4, char='a', we might create "abca"? Not palindrome. I suspect that in any string, when we create a new palindrome of length L, its longest proper palindromic suffix must have been created earlier. This is because the proper suffix is shorter and appears as a substring ending at the same position. But it could be that the first occurrence of that shorter suffix is exactly at this position. However, if it's the first occurrence, then it would have been created at the same step? But the algorithm creates nodes in the order of increasing length? Not necessarily: when adding a character, we create at most one new node. That node has length L. If the proper suffix of length L' is new, then it must be created as a node as well. But we only create one node per character addition. So if both L and L' are new, we would need to create two nodes, which is impossible. Therefore, L' must already exist. This reasoning proves that the proper suffix always exists when linking. So the character condition alone should be sufficient: if we find a node w such that s[pos - len[w] -1] == c, then next[w][c] must exist because the palindrome of length len[w]+2 is a suffix that ends at pos, and it must have been created earlier. Let's test with our earlier counterexample: w=3 (node "b"), s[5]=‘a’ matches, but next[3][‘a’] does not exist. The palindrome of length len[3]+2 = 1+2=3 that would be created by adding ‘a’ to both ends of “b” is “bab”. Is “bab” a suffix of “abacaba” ending at pos=7? The suffix of length 3 ending at pos=7 is “aba”, not “bab”. So the palindrome formed by extending w by c is not a suffix of the new palindrome; it's a different palindrome. The character condition alone is not the right condition: we need that the palindrome formed by extending w by c matches the suffix of the new palindrome. The correct condition is that the suffix of length len[w]+2 of the current prefix (which is the palindrome formed by adding c to both ends of w) is exactly the palindrome we are considering as a candidate for the link. But that suffix is not “bab”; it's “aba”. So why did the character condition hold? It held because we checked s[pos - len[w] -1] == c, but that check ensures that the character before the palindrome w equals c, which is necessary for the extended palindrome to be a suffix. However, there can be multiple w that satisfy this character condition, but only one such w corresponds to the actual suffix of the new palindrome. Actually, given the new palindrome ends at pos, its longest proper suffix that is itself a palindrome is found by considering the suffix of the palindrome inside the string. The algorithm typically uses a different method: after creating the new node, we set its link by starting from the link of the parent node (the one that was extended) and then traversing until we find a node that can be extended by c. But that node must be the parent's link and so on. The parent node v is the one we used to extend (the longest palindrome that can be extended). Its link is the longest proper palindromic suffix of v. We then try to extend that by c. If that works, then the new palindrome's suffix is that extension. In our example, v is node 7 (length 5). Its link is node 3 (length 1, "b"). Extending "b" by 'a' gives "bab", which is not what we want. So we need to continue from link[3] which is node 1 (empty), extend empty by 'a' gives "aa"? Actually empty extended by 'a' gives "aa"? Wait, empty root (len 0) extended by 'a' gives "aa". That is not "aba". Then go to link[1]=0 (odd root), extend by 'a' gives "a". That's length 1, not length 3. So we are not finding the correct suffix. The correct method is: we need to find the longest palindrome that ends at pos and is shorter than the new palindrome. That is exactly the palindrome obtained by taking the new palindrome, removing its first and last characters, then finding the longest palindromic suffix of that inner palindrome, and then adding back the first and last characters? Actually, the longest proper palindromic suffix of a palindrome P is given by: if P has length L and center c, then its longest proper palindromic suffix is the longest palindrome that is a suffix of P. This can be found by considering the longest palindrome centered at the same center but shorter? Not exactly.

The correct way to set the link in the Eertree: After creating the new node for palindrome P = c P' c (where P' is a palindrome), we need to find the longest proper palindromic suffix of P. That suffix can be obtained by starting from the link of v (where v is the node for P') and then traversing until we find a node that can be extended by c. But note: v is the palindrome P'. Its link points to the longest proper palindromic suffix of P'. Call that Q. Then we check if we can extend Q by c: that would give c Q c. Is c Q c a palindrome? Yes, if Q is a palindrome. Is c Q c a suffix of P? Since P = c P' c, and Q is a suffix of P', then c Q c is a suffix of P? Not necessarily: If Q is a suffix of P', then c Q c is a suffix of c P' c only if Q is at the end of P'. But Q is a suffix of P', so yes, P' ends with Q, so P = c ... Q c, so the suffix of P is c Q c. Therefore, c Q c is a palindromic suffix of P. It may not be the longest, but it's a candidate. To get the longest, we need to keep traversing the links of v until we find the longest Q such that c Q c is a palindrome (the character condition ensures that when we attempt to extend Q, we check that the character before Q matches c). But crucially, we do not check if the edge from Q exists; we actually create the link by following the same logic as before: we find the node w (starting from link[v]) such that the character before w equals c, and then we set link[new] = next[w][c]. But next[w][c] must exist because c w c (the extended palindrome) is a suffix of P and must have been created earlier. In our problematic case, v = node 7 (length 5, "ababa"). Its link is node 3 ("b"). Starting from link[v]=3, we try to find a node w such that s[pos - len[w] -1] == c. For w=3, len=1, s[7-1-1]=s[5]='a' == c, so we stop. But then we try to get next[3]['a']. That would give the palindrome "aba"? No, "aba" is not obtained by extending "b" by 'a'. The extension of "b" by 'a' yields "bab". So why would the algorithm think that "bab" is a suffix of "abacaba"? Because the condition s[pos - len[w] -1] == c is necessary but not sufficient to ensure that the extended palindrome is a suffix of the current string. The correct condition is that the palindrome obtained by extending w should match the suffix of the current prefix. That is, we need to ensure that the entire substring from pos - len[w] -2 to pos is the palindrome w extended. But the character condition only checks the character at pos - len[w] -1. That is just one character. However, because w is a palindrome, the condition that this character equals c ensures that the extended palindrome c w c exists as a substring ending at pos, but only if w itself is a suffix of the substring starting at pos - len[w] -1? Actually, if we take the substring ending at pos and remove the first and last characters (both c), we get a substring of length len[w] that should equal w. That is exactly the condition that the substring starting at pos - len[w] -1 and ending at pos -1 is a palindrome w. In our case, we want to check if the substring from pos - len[w] -1 to pos -1 equals w. That substring is s[5..6] = "ab"? Actually pos=7, len[w]=1, so substring from 7-1-1=5 to 6 = "ab"? That's two characters? Wait, substring of length len[w]=1 from index 5 to 5 is s[5]='a'. That is not equal to w="b". So the condition s[pos - len[w] -1] == c is not enough; we also need that the substring of length len[w] starting at pos - len[w] -1 is exactly w. But that's automatically true if we arrived at w via the first while loop? Actually no, the first while loop for finding the extension used the condition s[pos - len[v] -1] == c, but v was the node we were checking. There, we were looking for a node v such that extending v by c yields a palindrome that matches the current suffix. The condition was: while s[pos - len[v] -1] != c: v = link[v]. That works because we start from last, and we ensure that the palindrome v is a suffix of the current prefix? [Check] For the first while loop (finding v to extend), we rely on the fact that `last` is the longest palindrome suffix of the previous prefix. Then when we move to `link[last]`, that is the next longest palindrome suffix, and so on. So the condition s[pos - len[v] -1] == c ensures that if we extend v, we get a palindrome that is a suffix of the current prefix. That's because all v in that chain are suffixes of the previous prefix, and the character at pos - len[v] -1 is the character just before the suffix v. So extending v gives a palindrome that ends at pos. That works.

For the second while loop (to set the link), we start from `link[v]` where v is the node we extended. That node `link[v]` is the longest proper palindromic suffix of v. Then we check s[pos - len[link[v]] -1] == c. But note that `link[v]` is a suffix of v, and v is a suffix of the substring ending at pos-1 (since v was extended to form the new palindrome). However, does `link[v]` appear as a suffix of the substring ending at pos? That's not guaranteed unless the character at pos - len[link[v]] -1 equals c. If it does, then extending `link[v]` by c gives a palindrome that is a suffix of the new palindrome. So the loop is correct: we keep following links from v until we find a node w such that the character before w equals c. Then we set link[new] = next[w][c]. But as we saw, for v=7 and link[v]=3, the condition holds w=3, but next[3][c] does not exist. This indicates that the loop should not stop at w=3 because even though the character matches, the extended palindrome may not be the one we want because w itself might not be a suffix of the substring ending at pos -1? Actually, w=3 is the palindrome "b". Is "b" a suffix of the substring ending at pos-1? The substring ending at pos-1 is "abacab". Its suffixes: "b", "ab", "cab", etc. "b" is indeed a suffix. So extending "b" by 'a' gives "bab". But "bab" is not a suffix of the current prefix "abacaba"? Let's check: the suffix of length 3 of "abacaba" is "aba", not "bab". So why did the character condition hold? Because s[pos - len[w] -1] = s[7-1-1]=s[5]='a' equals c, but the substring from pos - len[w] -1 to pos-1 should be w. That substring is s[5..6] = "ab". That is not "b". So the condition s[pos - len[w] -1] == c is necessary but not sufficient to guarantee that w is a suffix of the substring ending at pos-1. In fact, for w to be a suffix of the substring ending at pos-1, we need that the substring of length len[w] ending at pos-1 equals w. That substring is s[pos - len[w] .. pos-1]. Our condition only checks the character at pos - len[w] -1. That is the character _before_ w. But w itself must match the substring. However, note that when we traverse through the link chain from last, we are guaranteed that each node in the chain is a palindrome suffix of the prefix up to pos-1. Because last is the longest, and its links are shorter suffixes. So when we start from link[v] where v is a palindrome suffix of the prefix up to pos-1 (since v was a suffix? Wait v is the node we extended, which was a palindrome suffix of prefix up to pos-1. Its link is also a palindrome suffix of that same prefix. So w=link[v] is a suffix of prefix up to pos-1. Therefore, the substring of length len[w] ending at pos-1 is exactly w. So in our case, w=3 ("b") is a suffix of "abacab"? Yes, "abacab" ends with "b". So the substring s[pos - len[w] .. pos-1] = s[6..6] = 'b' which is w. Good. Then what about the extended palindrome c w c? It would be "a b a". That is exactly "aba"! Wait, "bab" vs "aba": confusion: c = 'a', w = "b", so c w c = "a b a" = "aba". That's correct. Earlier I mistakenly said "bab". So extending "b" by 'a' gives "aba", not "bab". Because adding 'a' to both ends of "b" yields "aba". Yes, "aba" is the palindrome. So next[3]['a'] should point to the node for "aba", which is node 4. But why did we think next[3]['a'] doesn't exist? In our construction, we created node 4 for "aba", but we did not set an edge from node 3 to node 4. Indeed, node 3 is the palindrome "b". The edge from node 3 for character 'a' would represent the palindrome "aba". Did we create that edge when we created node 4? Let's check: When we created node 4 at i=3, we set next[v][c] where v was the node that we extended. At that time, v was node 3? Let's revisit i=3. For i=3, we started from last=3 (node "b") and found that we could extend node 3? Actually we need to trace again. At i=3, char='a', last=3 (node "b"). The while loop to find extension: v=last=3, check s[3-1-1]=s[1]='a' matches c? Yes. So v=3. Then we checked if next[3]['a'] exists? At that point it did not, so we created new node 4 with len=1+2=3, and we set next[3]['a'] = 4. So we did set an edge from node 3 to node 4! Yes, we did. So next[3]['a'] exists and points to node 4. Therefore, our earlier statement that it didn't exist was wrong. I must have skipped that. So the algorithm is consistent: at i=7, when setting link for node 8, we start from link[v]=link[7]=3, check character condition s[7-1-1]=s[5]='a' matches c, so we set link[8] = next[3]['a'] = node 4. That gives link[8] = node 4 ("aba"). That is correct: the longest proper palindromic suffix of "abacaba" is "aba". Perfect.

This demonstrates the correctness of the algorithm. The key insight is that the chain of suffix links ensures that we always find an existing node because the palindrome we need (the extension of some suffix) must have been created earlier.

## 6. Complexity Analysis

The Eertree construction processes each character of the string exactly once. In each step, we may traverse several suffix links during the two while loops. However, the total number of traversals across all steps is O(n). The reason is that each traversal moves to a node with strictly smaller length (since suffix links point to shorter palindromes). The number of times we move from one node to its link is amortized linear because each movement either reduces the current length or stays within the same chain, but the sum of decreases is bounded by the total increase in length. More formally, the pointer `last` only increases in length (by 2 each time a new palindrome is created) or resets to a smaller length via suffix links. However, the number of times we follow a suffix link is bounded by O(n). This is a standard amortized argument similar to that used for the KMP algorithm. Therefore, the total construction time is O(n _ log |Σ|) if we use map for edges, or O(n _ |Σ|) if we use arrays (for small alphabets). The space is O(n \* |Σ|) in the worst case, but in practice, each node allocates only a few slots.

After construction, counting occurrences is done by a top-down traversal (or a decreasing loop over node indices) to propagate counts from children to their suffix links. This takes O(number of nodes) which is at most n+2.

Thus, we can answer queries like: number of distinct palindromes = size-2 (excluding roots), most frequent palindrome by scanning occ array, longest palindrome by tracking max len.

## 7. Comparison with Alternative Approaches

### 7.1 Manacher’s Algorithm

Manacher’s algorithm finds, for each center, the longest palindrome in O(n). With radial arrays, we can enumerate all distinct palindromes by taking all radii and deduplicating? Each radius gives a set of palindromes of odd length: for each center, the radii correspond to all palindromes of lengths 1, 3, 5, ... up to the maximal. So we can collect all distinct palindromes by iterating over all centers and all radii, but that yields O(n^2) in worst case if we materialize them. However, we can compute the number of distinct palindromes using a suffix tree from the Manacher radii in O(n log n) via a technique by Gusfield. But it's complicated. The Eertree gives direct enumeration.

Manacher is still useful for simple longest palindrome queries, and it's lighter in memory for single queries. But for comprehensive palindrome analysis, Eertree is superior.

### 7.2 Suffix Automaton (SAM) on Reverse

One can build a suffix automaton on the string and its reverse, and then use intersection techniques to count palindromes. This is also linear but more complex to implement. The Eertree is simpler and more memory-efficient for the specific task.

### 7.3 Rolling Hash with Binary Search

We can precompute hashes and use binary search for longest palindrome at each center, then deduplicate using a hash set of strings. This is O(n log n) but suffers from hash collisions and overhead. Not deterministic.

### 7.4 Summary

The Eertree is the most elegant and efficient solution for palindrome enumeration and counting. It is a true work of algorithmic art.

## 8. Applications in Bioinformatics

Palindromic sequences in DNA are often associated with regulatory regions, restriction enzyme cut sites, and cruciform structures. For example, the recognition site for the restriction enzyme EcoRI is GAATTC, which is not palindromic? Actually GAATTC is a palindrome? G A A T T C reversed is C T T A A G, not the same. Wait, many restriction sites are palindromic, e.g., HindIII: AAGCTT (reverse is TTCGAA? Actually AAGCTT reversed is TTCGAA, not the same. I recall that type II restriction enzymes recognize palindromic sequences? The common ones like EcoRI (GAATTC) are palindromic? GAATTC reversed is CTTAAG, which is not GAATTC. Wait, double-stranded DNA palindromes are sequences that read the same on both strands when considering complementarity. For example, GAATTC on one strand, its complement is CTTAAG, which when read in the reverse direction is GAATTC. So a palindromic restriction site is one where the sequence on one strand is the reverse complement of itself. In other words, the nucleotide sequence is equal to its reverse complement. For example, GAATTC is a palindrome in the double-stranded sense because its reverse complement is also GAATTC. So in bioinformatics, a palindrome in a DNA string often means a substring that is equal to its reverse complement (with base pairing: A-T, C-G). The Eertree can be adapted to handle this by considering an alphabet where each character has a complement. Or we can treat the string as over nucleotides and define the reverse complement transformation. A palindrome in this context is a string S such that S = rev_comp(S). This is a more complex notion, but the Eertree can still be used by building the tree on the original string and then checking for reverse-complement equivalence. Alternatively, we can build a palindromic tree for the combined string and its complement.

For example, in the human genome, palindromic sequences are crucial for understanding genomic instability. The Eertree can enumerate all palindromic substrings (under the double-stranded definition) in linear time. This is a powerful tool for genome annotation.

## 9. Applications in Data Compression

Palindromes are a form of repetition. In algorithms like LZ77, repetitions are encoded as pointers to earlier occurrences. Long palindromes can be exploited: a palindrome of length L can be encoded as a copy of itself reversed? Actually, if you have a palindrome, you can encode the second half as a copy of the reverse of the first half. This is used in some compression schemes for structured data. The Eertree can quickly identify all palindromes, and their lengths, to inform the compressor.

## 10. Applications in Text Analysis and Competitive Programming

In competitive programming, palindromic problems are staple. Typical tasks:

- Count the number of palindromic substrings.
- Find the longest palindromic substring.
- Count distinct palindromic substrings.
- Find the number of occurrences of each palindrome.

The Eertree solves all these in O(n) and is a favorite among red-rated coders (e.g., Codeforces, ICPC). Many problem solutions on platforms like Codeforces include an implementation of Eertree.

## 11. Advanced Variants and Extensions

### 11.1 Dynamic Eertree

What if we want to support appending and prepending characters to the string? The Eertree can be extended to allow insertions at both ends by maintaining two pointers (last for suffix, and another for prefix). This is called the _double-ended palindromic tree_. It allows O(log n) per insertion if using sophisticated data structures, or O(1) amortized.

### 11.2 2D Palindromes

For a matrix, define a palindrome as a submatrix that is symmetric both row-wise and column-wise. There are challenges in extending the Eertree to 2D, but some progress has been made.

### 11.3 Palindrome Factorization

Given a string, partition it into the smallest number of palindromic substrings. This is called palindrome factorization and has applications in grammar compression. Eertree can be used to compute DP in O(n^2) naively, but with additional techniques (like LCA on suffix tree) it can be O(n log n).

## 12. Implementation Details and Optimizations

In practice, the Eertree can be implemented in under 50 lines of C++ code. To optimize memory, we can use fixed-size arrays for `next`, assuming a small alphabet (e.g., 26 for lowercase letters). For larger alphabets, we use hash maps per node, but that increases overhead. Another approach is to store edges in a single global array indexed by node and character, but that uses O(|Σ| \* nodes) memory which may be large.

An important optimization: we can avoid storing the entire `next` array for each node by using a vector of pairs, but then lookup becomes O(log |Σ|). For competitive programming, often the alphabet is small, so arrays are fine.

The occurrence count propagation step can be done during the building if we also store additional information. But the standard is to do a final pass.

## 13. Conclusion

The Palindromic Tree, or Eertree, is a testament to the fact that even the simplest combinatorial objects can inspire deep algorithmic innovation. From its humble roots (pun intended) as a solution to a problem in Russian competitive programming, it has spread to become a standard tool in string algorithms, with applications ranging from genomics to data compression. Its construction is elegant, its performance is linear, and its versatility is remarkable.

The next time you see a word like "racecar," you might appreciate not just its symmetry, but the elegant data structure that can catalog every such symmetry in a million-letter text. The palindrome is no longer humble—it is a portal into the beauty of algorithmic design.

---

_This article was written as an expansion of a blog post originally outlining the Eertree. We hope it provides a comprehensive guide for computer scientists, competitive programmers, and anyone curious about the magic of string algorithms._
