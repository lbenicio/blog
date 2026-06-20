---
title: "A Comprehensive Look At Operational Transformation Control Algorithms: Ttf, Cc, And Jupiter With Tombstone"
description: "A comprehensive technical exploration of a comprehensive look at operational transformation control algorithms: ttf, cc, and jupiter with tombstone, covering key concepts, practical implementations, and real-world applications."
date: "2023-05-10"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/a-comprehensive-look-at-operational-transformation-control-algorithms-ttf,-cc,-and-jupiter-with-tombstone.png"
coverAlt: "Technical visualization representing a comprehensive look at operational transformation control algorithms: ttf, cc, and jupiter with tombstone"
---

# The Invisible Choreography: Why Your Cursor Doesn't Explode When You and Your Boss Edit the Same Google Doc

You have forty-five minutes before the deadline. The prose is flowing. You delete a paragraph, hit enter, and insert three new sentences. At the exact same microsecond, your manager on the other side of the planet is doing the same thing in the same document. They add a comment to a word you just deleted. You rearrange two sections that they are simultaneously highlighting. Somehow, magically, the text doesn't turn into digital gibberish. The document survives. The collaboration works.

Have you ever stopped to wonder _what_ is actually happening inside the machine when two people type in the same text document at the same time? Most of us don’t. We treat collaborative editing like Wi-Fi—it’s supposed to just work. But the reality is that underneath the slick UI of Google Docs, Notion, or Figma’s multiplayer mode lies a ferociously complicated set of mathematical transactions. Specifically, there is a fundamental class of algorithms that solve a deceptively difficult problem: **How do we reconcile two different versions of the same sequence of characters when they are changed simultaneously?**

This is the realm of **Operational Transformation (OT)** . For decades, OT has been the unsung hero of real-time collaboration. It is the invisible choreographer that ensures your keystroke and my keystroke don’t annihilate each other. It is the reason why you can have a _Star Wars_-style crawl of text appearing on screen without the document dissolving into chaos. But here is the dirty secret of the industry: Many developers know what OT _does_, but very few understand how it works. Even fewer understand the brutal trade-offs between the different control algorithms that make OT possible.

If you have ever tried to build a collaborative text editor, you have likely run into the "concurrency wall." You start with a simple "operational transform" function. You test it with two users typing the same letter at the same position, and it works. You test it with a delete and an insert at overlapping ranges, and it works. Then you add a third user, and suddenly the document diverges into three different realities. You add a fourth, and the universe tears apart. You spend nights debugging state machines, trying to figure out why the transform function doesn't compose correctly. And then you consider switching careers to farming.

But there is a path through this mathematical minefield. In this article, we are going to walk through the exact algorithms, data structures, and invariants that make real-time collaboration possible. We’ll start with the fundamental problem, build up the core OT transform function step by step, and then dive into the notorious "control algorithms" that make OT work for multiple users. We’ll also look at the modern alternative—CRDTs—and why you still see OT in production systems today.

By the end, you will not only know how Google Docs works under the hood, but you’ll be ready to implement a basic collaborative editor yourself (or at least understand why it’s so hard). So buckle up. We’re going to make your cursor explode on purpose, and then we’re going to put it back together.

---

## 1. The Core Problem: The Duality of Time and Space

Let’s start with the simplest possible scenario. Two users, Alice and Bob, are editing a shared document that contains the single word "Helo". Alice notices the missing 'l' and inserts 'l' at position 3 (making "Hello"). At the exact same moment, Bob, who is working on a different feature, inserts 'x' at position 0 (making "xHelo"). Both edits are concurrent—they happen without either user knowing about the other’s change.

Now, consider what happens if we just apply both edits naively. The initial state is "Helo". If we apply Alice’s insert first, we get "Hello". Then we apply Bob’s insert at position 0 to that result: "xHello". If we apply Bob’s insert first, we get "xHelo". Then we apply Alice’s insert at position 3—but wait, Bob’s insert shifted the string. Position 3 in "xHelo" is 'l' (the first l?). Actually, let's index carefully:

- "Helo": H(0), e(1), l(2), o(3)
- Alice inserts 'l' at position 3 → "Hell o"? No, "Helo" inserting at position 3 means after 'l' at index 2? Typically positions are before the character at that index. So inserting at position 3 in "Helo" puts 'l' before 'o', yielding "Hello". That's fine.
- Bob inserts 'x' at position 0 → "xHelo".

Now, if we apply Alice first: "Helo" → "Hello". Then apply Bob's insert at position 0 to "Hello" → "xHello". That gives us "xHello". Good.

If we apply Bob first: "Helo" → "xHelo". Then apply Alice's insert at position 3 to "xHelo". What is at position 3 in "xHelo"? Index: x(0), H(1), e(2), l(3), o(4). So position 3 is before 'l' (the second occurrence, but actually it's the only 'l'). Inserting 'l' there gives "xHel lo"? That's "xHello"? Let's spell: "xHelo" insert 'l' at pos3 → x H e l l o → "xHello". Same result! So in this case, order doesn't matter; we get the same final state. That's because the two operations affect different parts of the string and don't interfere.

Now let's make it more interesting. Both Alice and Bob insert 'x' at position 0 simultaneously. Alice's insert: 'a' at pos0. Bob's insert: 'b' at pos0. If we apply Alice first: "a...", then Bob's insert at pos0: "ba...". If we apply Bob first: "b...", then Alice's insert at pos0: "ab...". These give different results! Which one is correct? There is no "correct" answer in an absolute sense; the system must choose a deterministic rule to converge to a consistent state. The most common rule is that all sites eventually converge to the same document, but the order of concurrent insertions at the same position is arbitrary—as long as all participants see the same final ordering.

This is the essence of the collaborative editing problem: **How to achieve eventual consistency in the presence of commutative and non-commutative operations?**

Operational Transformation solves this by transforming the parameters of an operation according to the effects of previously applied concurrent operations, so that the operation "fits" into the current state as if the concurrent operations had not happened. But the transformation must satisfy certain properties to ensure convergence.

### 1.1 The Core Data: Operations

An operation is a description of a change to the document. In a text editor, operations are usually three types:

- **Insert(pos, char)** : Insert a character at the given position index.
- **Delete(pos, len)** : Delete a substring of length `len` starting at position `pos`.
- **Update(pos, newChar)** : Replace a character at position (less common; can be modeled as delete+insert).

The position is always relative to the current state of the document at the time the operation was generated. But when operations arrive out of order, the position may be invalid because other operations have shifted the document. The transform function adjusts the position so that the operation applies correctly.

### 1.2 The Transform Function

The heart of OT is the function `T(op1, op2) -> (op1', op2')` that takes two operations that are defined on the same initial document state and produces two new operations that are defined on the state after the other operation has been applied. More formally: if `S` is the initial state, and `op1` and `op2` are both applicable to `S`, then we want:

- `apply(apply(S, op1), op2')` == `apply(apply(S, op2), op1')`

That is, the two resulting states should be identical. Additionally, the transformation should be "semantically equivalent" in the sense that the final result preserves the intent of both users.

For text editing, we can define the transform function for the four possible combinations of insert and delete. Let’s build it step by step.

#### 1.2.1 Insert vs. Insert

Case: `op1 = Insert(p1, c1)`, `op2 = Insert(p2, c2)` on the same document state.

If `p1 < p2` (Alice inserts before Bob), then after Alice's insert, Bob's character is shifted right by 1. So we need to adjust Bob's position: `p2' = p2 + 1`. Similarly, if `p2 < p1`, then adjust Alice's position: `p1' = p1 + 1`. If `p1 == p2` (both insert at the same position), we need a tie-breaking rule. Usually, we use a site identifier or a timestamp to decide who goes first. For simplicity, we could say the user with the lower ID gets their insertion first, so the other's position is incremented by 1. So:

```
if p1 < p2: return (Insert(p1,c1), Insert(p2+1,c2))
if p1 > p2: return (Insert(p1+1,c1), Insert(p2,c2))
if p1 == p2:
    if id1 < id2: return (Insert(p1,c1), Insert(p2+1,c2))
    else: return (Insert(p1+1,c1), Insert(p2,c2))
```

#### 1.2.2 Delete vs. Delete

Case: `op1 = Delete(p1, l1)`, `op2 = Delete(p2, l2)`.

We need to handle overlapping and non-overlapping deletions. The general rule: after the first deletion, the positions of the second deletion may shift if the deleted range overlaps or is before.

- If the two deletion ranges are disjoint and non-overlapping:
  - If `p1 + l1 <= p2`: then `p2' = p2 - l1` (because characters before p2 were removed).
  - If `p2 + l2 <= p1`: then `p1' = p1 - l2`.
- If they overlap:
  - The second deletion's effective range is reduced or shifted. We must compute the intersection. The typical approach is to transform the second delete to remove only the characters that are still present after the first delete.

A precise algorithm:

```
def transform_delete_delete(op1, op2):
    p1, l1 = op1.pos, op1.len
    p2, l2 = op2.pos, op2.len
    # Case 1: op1 deletes completely within op2's range
    if p1 >= p2 and p1 + l1 <= p2 + l2:
        # op2's deletion is effectively split into two parts: before and after op1.
        # After op1, the left part (before op1) remains same, right part shifts left by l1.
        new_op2 = Delete(p2, l2 - l1)
        # op1 remains unchanged because op2's effect didn't affect op1's positions
        new_op1 = op1
    # Case 2: op1 deletes before op2
    elif p1 + l1 <= p2:
        new_op2 = Delete(p2 - l1, l2)
        new_op1 = op1
    # Case 3: op2 deletes before op1
    elif p2 + l2 <= p1:
        new_op1 = Delete(p1 - l2, l1)
        new_op2 = op2
    # Case 4: partial overlap - op1 extends beyond op2's left edge but not fully inside
    # ... (many subcases)
```

This becomes messy quickly. In practice, many OT systems model delete as a pair of positions (start, end) or use a different approach like "tombstones" in CRDTs. The crucial point: the transform function must be carefully designed to handle all edge cases.

#### 1.2.3 Insert vs. Delete

Case: `op1 = Insert(p1, c1)`, `op2 = Delete(p2, l2)`.

We need to adjust the insert position if the delete removes characters before it, and adjust the delete position if the insert adds characters before it.

- If `p1 <= p2`: insert is before or at the start of the delete range. Then after insert, the delete range shifts right by 1. So `p2' = p2 + 1`. The delete itself remains same length. Return (Insert(p1,c1), Delete(p2+1, l2)).
- If `p1 > p2 + l2`: insert is after the delete range. Then after delete, the insert position shifts left by l2. So `p1' = p1 - l2`. Return (Insert(p1 - l2, c1), Delete(p2, l2)).
- If `p2 < p1 <= p2 + l2`: insert is inside the delete range. Then the character being inserted is about to be deleted. This is a tricky semantic conflict. Typically, the system must decide: either the insert "survives" and the delete shrinks, or the insert is ignored. Usually, we want to preserve the insert (intent of creator). So we delete the characters around it. One approach: remove the delete operation for the character that would have been inserted (i.e., split the delete into two parts). The transformed delete becomes Delete(p2, p1 - p2) and Delete(p1+1, p2+l2 - p1) but that's two operations. Most OT systems don't allow a single operation to become multiple; they handle it by adjusting positions.

A common simplification: if insert is inside delete, we transform the delete to exclude the inserted character. That is, we shorten the delete by 1 and shift the remaining part after the insert to the right. For example, p1=3, p2=2, l2=3 (deletes indices 2,3,4). Insert at 3: after deletion, original indices shift. The transformed delete could be considered to delete positions 2 and 4 only (skipping the inserted char). This is complex.

Rather than diving into every subcase, we can rely on a known correct formulation from the literature, such as the one used in the Jupiter system (Google Wave's predecessor). The key is that the transform function must satisfy certain algebraic properties to ensure convergence in a multi-user scenario.

### 1.3 The Required Properties: TP1 and TP2

For a transform function to be correct for multiple users with arbitrary concurrency, it must satisfy two properties:

- **TP1 (Transformation Property 1)** : For any two concurrent operations `op1` and `op2`, the transformation `T(op1, op2) = (op1', op2')` ensures that applying `op1` then `op2'` yields the same state as applying `op2` then `op1'`. This is the pairwise correctness we already described.

- **TP2 (Transformation Property 2)** : For three operations `op1`, `op2`, `op3`, the order of composing transformations does not matter. More specifically, if we first transform `op1` with `op2` and then transform the result with `op3`, we should get the same as if we first transformed `op1` with `op3` and then with `op2`. In other words, the transformation is associative. Mathematically, this allows the system to merge operations from multiple users in any order and still converge.

Proving TP2 for a given transform function is notoriously difficult. Many early OT systems that "worked" in limited tests failed under unexpected concurrency patterns because their transform functions violated TP2. In fact, the problem of finding a correct and complete set of transform functions for text editing was an open research problem for many years, and even today most implementations have known corner cases.

### 1.4 A Simple Example: Fixing the Concurrent Insert

Let’s return to our earlier example where Alice and Bob both insert at position 0. We can use the transform to make them converge.

Initial: "Helo" (length 4)

- Alice: Insert(0, 'a')
- Bob: Insert(0, 'b')

Both issued at same time, no knowledge of each other. They are concurrent.

When Alice's operation arrives at Bob's site, Bob has already applied his own operation. So Bob's state is "bHelo" (if he applied his own first). Now Alice's Insert(0,'a') needs to be transformed against Bob's Insert(0,'b'). Using the rule: same position, lower ID wins. Suppose Alice has lower ID. Then transformed Alice's operation becomes Insert(0,'a') (since lower ID stays at 0), and Bob's (already applied) remains. But wait, we need to transform Alice's op against Bob's op to get a new op that can be applied to Bob's state. The transform gives (Insert(0,'a'), Insert(1,'b')). Because Alice's ID lower, her position unchanged, Bob's position shifted to 1. But Bob already applied his own op as Insert(0,'b'). So Bob's state is "bHelo". To incorporate Alice's op, we take the transformed version of Alice's op relative to Bob's op: that is Insert(0,'a'). Applying that to "bHelo" gives "abHelo". Meanwhile, Alice's state: she applied her own op first: "aHelo". Then she receives Bob's op, and transforms Bob's op against hers: since Alice's ID lower, Bob's op transforms to Insert(1,'b'). Applying to "aHelo" gives "abHelo". They converge. Good.

Thus, with a simple tie-breaking rule, we achieve convergence for this case. But this only works because both operations are inserts at the same position. Real-world text editing involves sequences of operations with dependencies (e.g., a user types a word, which is a series of inserts; another user deletes a whole line). The transform function must handle all these interactions.

---

## 2. The Control Algorithm: Orchestrating the Dancers

The transform function is just a small, albeit critical, part of a collaborative system. The bigger challenge is the **control algorithm** that decides when to send operations, how to order them, and how to merge histories from multiple clients. The control algorithm is the conductor of the invisible orchestra.

There are two main families of control algorithms: **client-server** and **peer-to-peer (P2P)** . Google Docs uses a client-server architecture where all operations go through a central server that serializes and broadcasts them. In contrast, Etherpad uses a more sophisticated client-server approach with operation merging. There is also the classic **dOPT** algorithm for P2P, and the **Jupiter** algorithm that was used in Google Wave.

### 2.1 The dOPT Algorithm: The First Attempt

The first control algorithm for OT was the **distributed operational transformation (dOPT)** algorithm, proposed by Clarence Ellis and Simon Gibbs in 1989 for the Grove system. dOPT is a P2P algorithm where each site maintains a state vector (a vector clock) to track the operations it has seen. When a site receives an operation, it uses the vector clock to determine which other operations are concurrent, and then transforms the incoming operation against the appropriate subset of concurrent operations before applying it.

The problem with dOPT is that it requires full pairwise OT depth and is highly sensitive to the order of transformations. It is known to have the "causality violation" problem: if the transform function violates TP2, the system can diverge. Furthermore, dOPT typically uses a centralized history buffer that can grow unboundedly.

### 2.2 The Jupiter Algorithm: Wave of the Future

In 1995, researchers at Bell Labs proposed the **Jupiter** algorithm, which was later used in Google Wave (and inspired parts of Google Docs). Jupiter's key insight is to use a **server-side state machine** that maintains a consistent order of operations. It is a client-server protocol where the server acts as a "reference point" and both the server and the client maintain a copy of the document state.

The protocol works as follows:

- Each client connects to a server. Both maintain a current document state.
- When a client generates an operation, it sends it to the server. The server receives it and:
  1.  Transforms the operation against any pending operations that the server has not yet sent to that client (i.e., operations from other clients that haven't been acknowledged by this client).
  2.  Applies the transformed operation to the server's state.
  3.  Broadcasts the operation (possibly transformed again) to all other clients.
- When a client receives an operation from the server, it transforms it against its own pending operations (those it has generated but not yet received acknowledgment from the server), then applies it.

This architecture ensures that the server always sees operations in a global order (the order they arrive at the server). The transformations are only needed to reconcile what the client has done locally before the server's broadcast arrives.

The critical mechanism: each client and server maintain a "state vector" that records the number of operations they've processed from each other. The transformation function is only ever applied to pairs of operations that are concurrent (i.e., neither knows about the other). In Jupiter, all operations are sent to the server, and the server serializes them. This avoids the multi-way transformation problem because the server always sees operations sequentially. The transform only happens client-side when a remote operation arrives to be merged with locally pending operations.

Jupiter is simpler than dOPT because it avoids the need for a full history buffer; only the pending operations (which are few, limited by latency) need to be kept. However, it still requires the transform function to be correct for those pairwise transformations.

### 2.3 State Management: The X and Y Dimension

In Jupiter, each client maintains a two-dimensional array or matrix for transformation: the "x" dimension represents operations from the server that the client has not yet processed in the context of its own pending operations. The "y" dimension is the reverse. The algorithm uses a technique called **state vector shifting** to always ensure that the next operation to transform is the one with the smallest vector clock.

The details are quite involved, but the important takeaway is that by imposing a single authoritative ordering point (the server), Jupiter dramatically reduces the complexity of the control algorithm. This is one reason why Google Docs (which uses a similar approach) is able to support hundreds of concurrent editors: the server becomes the bottleneck, but the algorithm remains simple.

### 2.4 Why Not Use CRDTs Instead?

In recent years, **Conflict-free Replicated Data Types (CRDTs)** have emerged as an alternative to OT. CRDTs are data structures designed so that concurrent updates commute; thus, no transformation is needed. The most famous CRDT for text is the **Replicated Growable Array (RGA)** , used by systems like Mute (a peer-to-peer text editor) and Automerge.

CRDTs work by assigning unique identifiers to each character (or block) that remain stable even after insertion/deletion. The order of characters is determined by a total order on these identifiers. Since identifiers are generated in a commutative way (e.g., using logical clocks to create globally unique identifiers), insertions at the same position can be ordered deterministically without transformation.

The main advantage of CRDTs is that they remove the need for a complex transform function and can work completely peer-to-peer without a central server. The downside: they require more memory (tombstones for deletions) and can be slower for large documents because the identifier resolution can be O(n). However, research has made CRDTs performant (e.g., using balanced trees or skip lists).

So why does Google Docs still use OT? The reasons are historical inertia and performance. OT was developed first, and Google built its infrastructure around it. Additionally, OT can be more efficient for typical editing patterns where deletes are common (CRDT tombstones can accumulate). Google Docs also uses a hybrid approach: offline editing uses CRDT-like mechanisms? Actually, Google Docs' offline mode uses a form of operation log that relies on OT transforms.

But for new projects, many engineers are adopting CRDTs because they are easier to prove correct (commutativity is built-in) and avoid the tricky TP2 pitfalls.

---

## 3. Edge Cases: When Good Transforms Go Bad

Even with a correct transform function and a good control algorithm, there are subtle edge cases that can break a collaborative editing system. Let's explore a few.

### 3.1 The "Puzzle" of Undo

One of the hardest features to implement in an OT system is **undo**. If a user performs an action and then undoes it, the undo operation must be transformed against any concurrent operations from others. The naive approach—simply sending an "inverse" operation—fails because the inverse may not correctly apply after transformations.

Consider: Alice inserts "hello" at position 0. Bob simultaneously inserts "x" at position 0. Alice's insert transforms to Insert(0,"hello") (assuming her ID lower), Bob's transforms to Insert(1,"x") (after Alice's). Now Alice undoes her insert. The inverse is Delete(0,5). But after Bob's insert, the "hello" string is at positions 0-4 (still) because Bob's insert is at position 1, so "hello" is at 0-4? Actually let's trace: Initial doc "". Alice applies her own: "hello". Bob's op arrives, transformed to Insert(1,"x"). So doc becomes "hxello". Wait, that's wrong: If Alice's original insert was at 0, Bob's transformed version should be Insert after Alice's 5 characters? Actually, the transform rule for concurrent inserts: if Alice's ID lower, Bob's position shifts by length of Alice's insert? In our simple single-character case, we only handled single char. For multi-char insert, the transform needs to handle lengths. Usually, an Insert operation inserts a string, not just a single character. So when Alice inserts "hello" (length 5), Bob's single-char insert at 0 should become Insert(5, 'x') because Alice's insert occupies positions 0-4. So after Alice's applied, then Bob's transformed op is Insert(5,'x'), resulting in "hellox". Good.

Now Alice wants to undo her insert. The inverse operation is Delete(0,5). But after Bob's insert, the string is "hellox". Delete(0,5) would delete "hello", leaving "x". That is correct: the effect of Alice's original insert is removed, and Bob's insert remains. However, if Bob's insert had been at position 2 (inside the "hello"), the undo would delete around it. The OT undo must carefully transform the inverse against all concurrent operations that happened after the original op.

Systems like Google Docs handle undo by storing a history of operations and their inverses, and when undo is triggered, they recompute the inverse relative to the current state, which may involve many transformations. This is computationally expensive but feasible.

### 3.2 The Copy-Paste Problem

Another classic edge case: copy and paste across the document. If Alice copies a paragraph and pastes it elsewhere, that's a pair of delete and insert operations that are causally related. But if Bob modifies the source paragraph concurrently, the paste operation refers to text that no longer exists. How should the system handle this? Usually, the copy is a reference to a range of characters. When pasting, the system must re-scope the operation to the current state. This often leads to "paste as of the time of copy" semantics, which can surprise users.

OT systems typically treat copy-paste as a sequence of operations (delete at source range, insert at target with the copied content). If the source text is concurrently deleted, the paste is effectively an insertion of the original text, which may conflict with the delete. The transform function must mediate.

### 3.3 Rich Text Formatting

So far we've only considered plain text. Real editors support bold, italics, links, etc. Representing formatting as operations introduces additional complications. For example, applying bold to a range of text that is concurrently being deleted or split by an insertion requires careful transformation. Google Docs likely uses a layered approach: the text operations are transformed, and formatting is applied post-hoc via a separate algorithm that adjusts range boundaries.

---

## 4. Building a Minimal OT Engine in Python

To solidify understanding, let's build a minimal OT engine for single-character operations on a plain text document. This will be limited but illustrates the core ideas.

We'll define operations as tuples: ('insert', pos, char) or ('delete', pos). We'll ignore length for simplicity.

```python
class OTEngine:
    def __init__(self):
        self.doc = ""
        self.history = []  # list of operations applied
        self.pending = []  # ops generated locally, not yet acked

    def generate_op(self, op):
        # Accepts a local operation (already applied to self.doc)
        self.pending.append(op)
        self.history.append(op)
        return op

    def receive_op(self, op, from_site=0):
        # Transform the incoming op against all pending ops
        # For simplicity, assume we only transform against one pending (last one)
        # In reality we need full serialization
        for pending_op in self.pending[::-1]:  # reverse order?
            # Simplified: transform once
            op = self.transform(op, pending_op)
        # Apply
        self.apply(op)
        self.history.append(op)

    def apply(self, op):
        if op[0] == 'insert':
            _, pos, char = op
            self.doc = self.doc[:pos] + char + self.doc[pos:]
        elif op[0] == 'delete':
            _, pos = op
            self.doc = self.doc[:pos] + self.doc[pos+1:]

    def transform(self, op1, op2):
        # op1 is the incoming op, op2 is the already applied pending op
        # We compute op1' such that applying op2 then op1' = applying op1 then op2' (ignoring op2')
        # For simplicity, we just handle insert vs insert and delete vs delete
        if op1[0]=='insert' and op2[0]=='insert':
            _, p1, c1 = op1
            _, p2, c2 = op2
            if p1 < p2:
                return ('insert', p1, c1)
            elif p1 > p2:
                return ('insert', p1+1, c1)
            else:
                # same position, lower site first (site assumed from order? here just use p2)
                return ('insert', p1+1, c1)  # assume incoming is later
        elif op1[0]=='delete' and op2[0]=='delete':
            _, p1 = op1
            _, p2 = op2
            if p1 < p2:
                return ('delete', p1)
            elif p1 > p2:
                return ('delete', p1-1)
            else:
                # same position - cannot both delete same char? actually possible if concurrent
                # treat as no-op? here just skip
                return ('delete', p1)  # trivial
        elif op1[0]=='insert' and op2[0]=='delete':
            _, p1, c1 = op1
            _, p2 = op2
            if p1 <= p2:
                return ('insert', p1, c1)
            else:
                return ('insert', p1-1, c1)
        elif op1[0]=='delete' and op2[0]=='insert':
            _, p1 = op1
            _, p2, c2 = op2
            if p1 < p2:
                return ('delete', p1)
            else:
                return ('delete', p1+1)
        else:
            raise Exception("Unknown op")
```

This is a gross simplification and will fail in many scenarios, but it demonstrates the pattern. A real OT engine would have proper state vectors, handle multiple pending ops, and support strings, not just characters.

---

## 5. Trade-Offs: OT vs. CRDTs in the Real World

To wrap up, let's compare the two approaches in terms of practical considerations for building a collaborative editing system.

| Aspect                              | OT                                                                                                  | CRDT                                                                                          |
| ----------------------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **Server Requirement**              | Central server often needed for serialization (Jupiter)                                             | Can be fully P2P; also works with server                                                      |
| **Algorithmic Complexity**          | High: transform function must be correct for all operation pairs; control algorithm adds complexity | Lower: no transformation needed; just define commutative merge                                |
| **Memory Overhead**                 | Low: operations can be applied in-place; only pending or recent history kept                        | Higher: tombstones for deletions; identifiers for each character can be large                 |
| **Performance for Large Documents** | Good: operations can be batched; document state is linear                                           | Can be slower due to identifier lookups; recent optimizations (like RGA with skip lists) help |
| **Undo Support**                    | Very hard: requires inverse transformation                                                          | Easier: undo can be a separate operation that cancels effects                                 |
| **Offline Collaboration**           | Hard: need to maintain operation log and transform later                                            | Natural: CRDTs allow offline edits to merge later without conflict                            |
| **Proven Deployments**              | Google Docs, Etherpad, ShareJS                                                                      | Automerge, Mute, Yjs (used in some production apps)                                           |

---

## 6. Conclusion: The Dance Continues

The next time you see a cursor moving in a shared document, take a moment to appreciate the algorithmic ballet happening beneath the surface. Operational Transformation, despite its complexity and known pitfalls, has enabled the real-time collaboration that we now take for granted. CRDTs offer a promising alternative, but they are not a silver bullet—each approach embodies trade-offs between simplicity, performance, and correctness.

If you are building a collaborative application today, you have more options than ever. You can use a library like Yjs (CRDT-based) or ShareJS (OT-based) and avoid reinventing the wheel. But if you ever need to debug a divergence issue, you'll be glad you understand the choreography.

Your cursor doesn't explode because brilliant computer scientists spent decades solving a seemingly impossible problem: how to make separate universes collide in a way that feels like one universe. And they succeeded—well, most of the time. There are still corner cases where documents diverge, where undo breaks, where the server goes down and the tape runs backwards. But for the vast majority of users, the invisible choreographer keeps the dance going, keystroke after keystroke, second after second.

And now you know the steps.

---

_If you enjoyed this deep dive, consider implementing a simple OT system yourself. Start with two users, then three, then add formatting. You’ll quickly appreciate the genius of those who tamed this complexity. And maybe, just maybe, you’ll find a way to make the dance even smoother._
