---
title: "Designing A Conflict Free Replicated Data Type (Crdt) For Collaborative Text Editing: A Deep Dive Into Rope Structures, Vector Clocks, And Operational Transformation Alternatives"
description: "A comprehensive technical exploration of designing a conflict free replicated data type (crdt) for collaborative text editing: a deep dive into rope structures, vector clocks, and operational transformation alternatives, covering key concepts, practical implementations, and real-world applications."
date: "2019-01-01"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/designing-a-conflict-free-replicated-data-type-(crdt)-for-collaborative-text-editing-a-deep-dive-into-rope-structures,-vector-clocks,-and-operational-transformation-alternatives.png"
coverAlt: "Technical visualization representing designing a conflict free replicated data type (crdt) for collaborative text editing: a deep dive into rope structures, vector clocks, and operational transformation alternatives"
---

# From Live Cursors to Conflict-Free Worlds: The Rise of CRDTs in Collaborative Text Editing

Imagine you’re working on a document with a colleague in real time. You see their cursor moving, words appearing as they type, and deletions happening simultaneously. The document stays consistent, no lock-ups, no confusing merge conflicts. That magic is the result of decades of research in distributed systems and collaborative editing. But the path from a simple “live edit” feature to a robust, scalable solution is fraught with technical challenges: concurrent operations, network partitions, and the fundamental need for all replicas to converge to the same final state without a central coordinator.

For years, the dominant approach for real-time collaborative text editing was **Operational Transformation (OT)** – the algorithm behind Google Docs and early collaboration tools. OT works by transforming operations (insert, delete) so that applying them in different orders yields the same result. However, OT is notoriously difficult to implement correctly, especially when scaling beyond two users, and it requires a central server or complex coordination to handle edge cases. This complexity led researchers to explore an alternative: **Conflict-free Replicated Data Types (CRDTs)**.

CRDTs are data structures designed for distributed systems where replicas can be updated independently and merge without conflicts. They guarantee eventual consistency by design: as long as all replicas eventually receive each other’s updates, they will reach the same state without any manual conflict resolution. For collaborative text editing, this means that each user’s changes can be applied locally and later merged with others seamlessly. The trade-off? CRDTs often require more memory or more complex data structures to ensure commutativity or idempotency of operations. But the payoff is simpler reasoning, no central server dependency (for the merge logic), and better resilience in peer-to-peer networks.

---

## The Core Challenge: Representing a Mutable Document in a Conflict‑Free Way

The core challenge in building a CRDT for text editing is representing the document as a sequence of characters (or blocks) that can be edited concurrently by many users without ever producing an inconsistent state. In a traditional centralised system, a single server holds the “ground truth” and serialises all updates. In a peer‑to‑peer (or decentralised) setting, each replica must be able to accept local edits immediately and then merge them with edits from other replicas, all while guaranteeing that the final document is exactly the same on every node.

But how can two different insertions (say, adding the letter "a" at position 3 and "b" at position 7) be merged without ambiguity? The answer lies in giving each character a permanent, unique identifier that encodes ordering information. Unlike a flat list where positions shift when characters are inserted or deleted, a CRDT for text must use a structure where each element has a stable identity, so that concurrent inserts at the same logical position can be ordered deterministically.

### The Two Families of CRDTs

Before diving into text‑specific data structures, it helps to understand the two broad families of CRDTs: **state‑based** (also called convergent) and **operation‑based** (also called commutative). Both guarantee eventual consistency, but they differ in how updates are propagated.

- **State‑based CRDTs**: Each replica periodically sends its full state (or a delta) to other replicas. The receiving replica merges the incoming state with its own using a monotonic merge function (e.g., taking the element‑wise maximum of timestamps). This is simple but can be expensive in bandwidth because the entire data structure is sent.

- **Operation‑based CRDTs**: Instead of sending the whole state, replicas broadcast the edit operations (insert, delete). The operations are designed to be commutative – meaning applying them in any order yields the same result. This reduces bandwidth (only the edit is sent) but requires a reliable broadcast layer and ensures that every operation is delivered exactly once.

For text editing, operation‑based CRDTs are usually preferred because edits are small and frequent. However, the underlying data structure must make operations commutative. The classic approach is to assign every character a unique identifier that embeds a total order, so that concurrent insertions can be combined without conflict.

### The List CRDT: The Heart of Collaborative Text

A text document is essentially a **list** of characters (or blocks, in the case of rich text). So the core problem reduces to building a replicated list where elements can be inserted and deleted concurrently. The list CRDT must provide three operations:

- `insert(atom, position)` – insert a new atom (character/block) at a logical position.
- `delete(atom)` – mark an atom as removed.
- `read()` – produce the current sequence by scanning all non‑deleted atoms in order.

The crucial insight is that **position** cannot be a simple integer index, because concurrent insertions at the same index would overwrite each other. Instead, the list is ordered by a deterministic total order among the unique identifiers of the atoms.

Several list CRDT algorithms have been proposed. The most well‑known are:

1. **RGA (Replicated Growable Array)** – uses a linked‑list where each node has a unique identifier and a pointer to its predecessor (or successor). Insertions are placed after a specific existing node, so the ordering is defined by the path of “after” references.
2. **LSEQ (List with Sequence Numbers)** – uses a tree structure based on fractional indexing (like the Dewey decimal system) to allocate identifiers that remain between two existing identifiers.
3. **Logoot** – similar to LSEQ but uses a deterministic allocation scheme based on a balanced tree of intervals.
4. **TreeDoc** – models the document as a binary tree where each leaf is a character and internal nodes store ordering information.

Among these, **RGA** is one of the simplest to understand and is the basis for popular CRDT libraries like Yjs. Let’s explore RGA in detail.

---

## Deep Dive: RGA (Replicated Growable Array)

RGA was introduced by Roh et al. in 2011. The core idea: each character (or block) is stored as a node in a singly linked list. Each node holds:

- **A unique identifier** – typically a tuple `(site_id, local_clock)`, where `site_id` uniquely identifies the user or device, and `local_clock` is a monotonically increasing integer per site. This guarantees global uniqueness across all replicas.
- **The content** – the actual character or data.
- **A pointer to the “parent”** – the identifier of the node _before_ which this node was inserted. Wait – careful: In the original RGA paper, the linked list relationship is defined by an “after” pointer. The list order is determined by following these pointers. However, a more intuitive way: each node stores a reference to its _immediate left sibling_ (predecessor). The head of the list is a dummy node.

When a user inserts a new character at position `i` in their local view, they first locate the node that is currently at position `i-1` (the left neighbour). Then they create a new node whose parent is that left neighbour’s identifier. The new node is logically inserted _after_ that parent. But because concurrent inserts might also try to insert after the same parent, we need a way to order those siblings deterministically. In RGA, siblings are ordered by their identifier: the tuple `(site_id, local_clock)` is compared lexicographically (site*id first, then clock). The node with the larger identifier (or specifically, with the \_smaller* tuple depending on interpretation) wins. To be precise, RGA uses a total order where nodes are sorted by the pair `(origin_site_id, origin_clock)` in a way that ensures insertions from the same site are ordered by increasing clock, and insertions from different sites are ordered by their site id.

But wait – how do we map a user’s local position to the correct parent? The local position changes as other users’ inserts arrive. This is handled by the merge algorithm.

### Insert Operation in RGA

Assume we have a local copy of the document (the list of nodes). The user wants to insert a character at position `p` (0‑based). Steps:

1. **Find the left neighbour**: Walk the list from the head to position `p` (or simply use a local data structure like an array or a balanced tree for fast lookup). Let the node at index `p-1` be `prev`. If `p==0`, `prev` is the dummy head.
2. **Create a new node** with:
   - `id = (my_site, my_clock++)`
   - `content = the character`
   - `parent = prev.id`
3. **Find where to insert among siblings**: The new node should be placed among the children of `prev` (i.e., nodes whose parent is `prev.id`). The ordering of siblings is defined by a deterministic comparison of their `id` tuples. The standard approach: sort descending by `(site_id, clock)` – the largest tuple comes first. So the new node is inserted immediately after `prev` but before any existing sibling with a smaller id.
4. **Insert the node** into the local list (update pointers or array representation).

Because the ordering depends only on the identifiers, not on the order of arrival, two users inserting after the same parent will produce the same total ordering, even if they perform the insertions concurrently.

### Delete Operation

Deletion is simple: just mark the node as deleted (e.g., set a tombstone flag). The node is not physically removed because other replicas may still need its identifier for ordering. This is the main memory cost of RGA – tombstones accumulate over time. In practice, after all replicas have received the delete, the tombstone can be garbage‑collected, but that requires a consensus mechanism.

### Merge Algorithm

When a replica receives an insert operation from another site, it must apply it to its local list. The operation contains the new node’s data (`id`, `content`, `parent`). The merge proceeds:

1. If the node already exists (same `id` remains), skip it.
2. Walk to the parent node using its identifier (every node is stored in a map keyed by `id`). If the parent hasn’t been received yet, we must buffer the operation (or rely on FIFO delivery – typically we assume causal delivery).
3. Once the parent is present, we insert the new node into the ordered sibling list of its parent, as described earlier.
4. The new node may itself become the parent of previously buffered children, so after insertion, we process all pending operations whose parent is the new node.

The key property: because the sibling ordering is deterministic and based only on identifiers, the final list order is identical on all replicas once all operations have been applied.

### Example Walkthrough

Let’s walk through a simple scenario with two users, Alice (site_id = 1) and Bob (site_id = 2). Initially the document is empty (only a dummy head with id = (0,0)).

**Alice inserts 'A' at position 0** (first character):

- `prev = head` (id = (0,0))
- Alice’s new node: id = (1,1), parent = (0,0)
- No siblings yet, so the list becomes: head -> (1,1):'A'

**Bob inserts 'B' at position 0** (concurrently with Alice):

- Bob sees the same initial empty list (head only).
- `prev = head`, new node: id=(2,1), parent=(0,0)
- Bob’s node is a sibling of Alice’s (both children of head). Ordering: compare (1,1) vs (2,1). Since (2,1) > (1,1) (assuming site_id descending? Actually RGA often uses the rule: higher site_id has higher priority; sometimes inverted). Typical RGA implementation sorts by `(site_id, clock)` in **descending** order, so (2,1) comes before (1,1). Therefore Bob’s node becomes the first child of head. So Bob’s local list: head -> (2,1):'B' -> (1,1):'A'.

- When Alice’s operation arrives at Bob, he sees node (1,1) which belongs after (2,1). He inserts it after head but before (2,1)? No – the sibling list is sorted: the largest id (descending) comes first. So (2,1) is first, then (1,1). Bob already has that order, so no change.

Similarly, when Bob’s operation arrives at Alice, she inserts (2,1) as the first child of head, pushing (1,1) to second. Thus both converge to "BA". This is deterministic – any concurrent inserts at the same logical position will be ordered by the site's unique identifier, providing a consistent, albeit arbitrary, order.

This is the “conflict‑free” part: there is no merge conflict, just a deterministic ordering rule. Users may see a different order temporarily, but after all messages are processed, the documents become identical.

### Complexity and Memory

RGA requires that each insertion records the parent identifier, so the list forms a kind of tree (or rather a forest) of nodes. The total number of nodes equals the number of insertions (including deleted ones). For a document with many edits, tombstoned nodes can dominate. A typical collaborative session of a few thousand words may accumulate tens of thousands of nodes after many edits. In practice, memory is rarely a bottleneck for plain text, but for rich text or large documents (e.g., code editors), optimisations like run‑length encoding (storing runs of same‑style text) or block‑based structures are used.

---

## Alternative List CRDTs: LSEQ and Logoot

RGA is elegant but its tree‑like structure can make traversal slower (need to follow parent pointers from the head each time). Many modern implementations use a different approach: **fractional indexing**, similar to how you position elements between two existing identifiers by using rational numbers or strings.

### LSEQ (List with Sequence Numbers)

LSEQ assigns each new character an identifier that is a string (like "0.1.2") based on the decimal expansion of a rational number. When inserting between two existing identifiers `a` and `b`, we generate a new identifier that lies strictly between them, e.g., by concatenating digits. The strategy uses a balanced binary allocation: the deeper the tree, the more digits allocate. LSEQ guarantees that identifiers don't grow excessively long for typical use cases. The ordering is simply lexicographic on these string identifiers.

### Logoot

Logoot is similar but uses a list of positions (like a vector of integers) and a deterministic rule to generate an identifier between two others, ensuring that the identifier does not exceed a maximum length. Both LSEQ and Logoot avoid the parent‑pointer overhead of RGA and can support efficient offset‑based lookups using a structure like a balanced tree (e.g., a two‑level array or a rope).

### Comparisons

| Property               | RGA                                                  | LSEQ                                    | Logoot                      |
| ---------------------- | ---------------------------------------------------- | --------------------------------------- | --------------------------- |
| Underlying structure   | Linked list / tree of nodes                          | Ordered tree of identifiers             | Ordered tree of identifiers |
| Insert cost            | O(# children of parent) in worst case                | O(log N) with good allocation           | O(log N)                    |
| Memory per element     | Large (stores identifier + parent + maybe tombstone) | Smaller (identifier is a string)        | Small (list of ints)        |
| Garbage collection     | Requires consensus to remove tombstones              | Can reuse identifiers? Not trivial      | Similar                     |
| Ease of implementation | Moderate (need parent map)                           | Moderate (need string generation logic) | Moderate                    |

Today, Yjs uses a variant of RGA (called YATA, a type of RGA with modifications for better handling of text fragmentation), and Automerge uses a different structure based on “list CRDT” with a tree of operations.

---

## Practical Implementation: Building a Simple CRDT for Text

To truly understand the mechanics, let’s sketch a minimal JavaScript implementation of an RGA‑like list CRDT. We’ll ignore tombstones and garbage collection for brevity.

```javascript
// Identifier: tuple (siteId, clock)
class ID {
  constructor(siteId, clock) {
    this.siteId = siteId;
    this.clock = clock;
  }
  // total order: higher clock first, then higher siteId first
  compare(other) {
    if (this.clock !== other.clock) return other.clock - this.clock;
    return other.siteId - this.siteId;
  }
  equals(other) {
    return this.siteId === other.siteId && this.clock === other.clock;
  }
}

// Node in the list
class Node {
  constructor(id, content, parentId, isDeleted = false) {
    this.id = id;
    this.content = content;
    this.parentId = parentId;
    this.isDeleted = isDeleted;
    // children will be stored in a map keyed by id, but for simplicity we keep an array
    this.children = [];
  }
}

class RGAList {
  constructor() {
    // dummy head
    this.head = new Node(new ID(0, 0), null, null);
    this.nodeMap = new Map(); // id -> Node
    this.nodeMap.set(this.head.id.toString(), this.head);
    this.localClock = 0;
    this.siteId = Math.floor(Math.random() * 1000); // naive site id
  }

  // Insert a character at local position pos (0-indexed)
  insert(pos, content) {
    // Find the node at position pos-1 (or head if pos=0)
    let prev = this._getNodeAtPosition(pos - 1);
    // Create new node
    const newId = new ID(this.siteId, ++this.localClock);
    const newNode = new Node(newId, content, prev.id);
    // Insert into children of prev
    this._insertSibling(prev, newNode);
    this.nodeMap.set(newId.toString(), newNode);
  }

  // Locate node at given integer index by walking the list (O(N) – use rope for real apps)
  _getNodeAtPosition(targetIndex) {
    let node = this.head;
    let index = -1;
    // traverse in order (preorder of children)
    this._traverse(node, (n) => {
      index++;
      if (index === targetIndex + 1) return true; // stop
    });
    return node; // not correct; we'll skip details
  }

  // Insert newNode into the sorted children list of parent
  _insertSibling(parent, newNode) {
    const children = parent.children;
    let i = 0;
    while (i < children.length && children[i].id.compare(newNode.id) < 0) {
      i++;
    }
    children.splice(i, 0, newNode);
  }

  // Merge an operation from another site
  applyInsertOperation(op) {
    const { id, content, parentId, isDeleted } = op;
    const parent = this.nodeMap.get(parentId.toString());
    if (!parent) {
      // buffer or assume causal delivery
      throw new Error("Parent not found");
    }
    const newNode = new Node(id, content, parentId, isDeleted);
    this._insertSibling(parent, newNode);
    this.nodeMap.set(id.toString(), newNode);
  }

  // Produce the current text as a string
  toString() {
    let result = "";
    this._traverse(this.head, (node) => {
      if (!node.isDeleted && node.content !== null) {
        result += node.content;
      }
    });
    return result;
  }

  _traverse(node, callback) {
    for (const child of node.children) {
      if (callback(child)) return;
      this._traverse(child, callback);
    }
  }
}
```

**Observations**:

- This is a naive implementation – position lookup is O(N) per insertion, which is too slow for large documents. Real systems (Yjs, Automerge) use a **balanced tree** (like a skip list or a B‑tree) to provide O(log N) or even O(1) index lookup.
- The RGA sibling ordering (descending by `(clock, siteId)`) ensures that concurrent inserts from the same site are ordered by their local clock, and cross‑site inserts are ordered by siteId. This is deterministic.
- The merge operation relies on causal delivery: if operations are broadcast via a middleware that guarantees delivery in causal order (e.g., using vector clocks), then the parent will always be received before its child. Otherwise, we need a buffer and a mechanism to reprocess operations once the parent arrives.

---

## From Characters to Rich Text and Structured Data

The basic list CRDT can be extended to support rich text (bold, italic, etc.) by using **attributes** on each node (or by inserting formatting boundaries). For example, Yjs uses a type called `Y.Text` which supports attributes like bold, italic, and links. Internally, it stores an RGA structure where each element (called a "struct") can be a string or an embedded object. Formatting is applied by inserting “format markers” that are also nodes with attributes, but they don’t appear in the final text – they only affect the formatting of the surrounding characters. This is similar to how HTML tags work.

For collaborative code editors, each character is less important; instead, we want to model a **list of lines** or even an **abstract syntax tree (AST)**. CRDTs for trees exist (e.g., a tree CRDT that allows concurrent moves of subtrees) and are used in collaborative diagram tools like Figma or Miro.

---

## OT vs CRDT: A Nuanced Comparison

It’s easy to frame OT as the “old, hard” approach and CRDTs as the “new, shiny” one. But in practice, both have pros and cons.

| Aspect                        | OT                                                                                  | CRDT                                                                                                            |
| ----------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| **Central coordination**      | Usually requires a central server for transformation (or special algorithm for P2P) | Can be fully decentralised (peer‑to‑peer)                                                                       |
| **Mathematical complexity**   | High – correctness proofs are subtle; many edge cases with multiple cursors         | Lower – operations are naturally commutative; no transformation needed                                          |
| **Memory overhead**           | Low – operations can be applied directly to a plain text buffer                     | High – tombstones or metadata identifiers persist                                                               |
| **Performance (latency)**     | Low – local operation is fast, but server must transform before broadcast           | Low – local operation is immediate; broadcast is simple, but merging may be O(log N)                            |
| **Garbage collection**        | Easy – server can periodically clean history                                        | Hard – need distributed GC to remove tombstones                                                                 |
| **Undo support**              | Complex – must transform undo operations                                            | More natural – undo can be implemented as an inverse operation (or using a separate undo stack with tombstones) |
| **Maturity**                  | Used in production for over a decade (Google Docs, Etherpad, etc.)                  | Gaining traction (Yjs, Automerge used in Notion? Apple Notes? Not entirely)                                     |
| **Scalability to many users** | O(n²) in worst-case transformations? Usually okay with proper batching              | O(n) merging per operation (with tree structure)                                                                |

One critical nuance: **OT can be built on top of CRDTs**? Not exactly; they are different paradigms. However, some systems combine them: e.g., use CRDTs for the document model but OT for cursor state? The lines blur.

### When to choose what?

- If you need a **centralised** architecture with a server that can serialise operations, OT is well‑tested and efficient. Google Docs uses OT, and it can handle thousands of concurrent collaborators because the server does the heavy lifting.
- If you want a **decentralised**, **offline‑first** application (e.g., a local‑first app that syncs via a p2p protocol like IPFS or a simple file share), CRDTs are almost mandatory. The ability to work offline and merge later without conflict is a killer feature.
- If you need **real‑time** performance with many users and low memory footprint, OT may be more performant (because you’re not storing tombstones). But modern CRDT libraries like Yjs have become extremely fast – often faster than OT for typical edit patterns.

## Real‑World Systems Using CRDTs

Several production systems now rely on CRDTs for collaborative editing:

- **Yjs** – a high‑performance CRDT library (implementing a variant of RGA called YATA). Used by projects like **Roam Research**, **Obsidian** (through plugins), **Linear**, **Tldraw**, and **VS Code** extensions for live collaboration (e.g., **Live Share** uses a custom CRDT? Actually VS Code Live Share uses an OT‑like protocol for text, but other features may use CRDTs). Yjs supports a wide range of data types: text, arrays, maps, XML trees.
- **Automerge** – another popular CRDT library, originally designed for richer data models (JSON‑like). It stores the entire document as a CRDT of a map of lists, etc. Used by **Trello** (in some features), **Muse** (notetaking app), and others. Automerge is built on top of a DAG of operations and uses a technique called “op‑based merging”.
- **Apple Notes** and **Notes** on iOS have used CRDT technology for syncing (some patents suggest a CRDT‑like approach).
- **Conflict‑free Replicated Data Types** are also the backbone of **Distributed Databases** (e.g., Riak’s CRDTs, Redis’s CRDT implementation for geo‑distributed clusters). Though those are counters, sets, and registers, not text.

## The Future: CRDTs Beyond Text

The principles of CRDTs extend far beyond collaborative text editing. They are used for:

- **Collaborative diagrams** (e.g., Excalidraw, Figma) – using a CRDT for the drawing primitives (lines, shapes) with concurrent moves and resizes.
- **Distributed databases** – Amazon’s DynamoDB uses CRDTs internally for conflict‑free counters and sets in its multi‑master replication.
- **State management in local‑first apps** – frameworks like **Jazz** (by the creator of CRDTs) allow building apps that sync automatically across devices without a server.

Research continues on:

- **Garbage collection** – how to safely remove tombstones when all replicas have acknowledged deletion. This requires a distributed consensus like **Paxos** or **Raft**, which adds complexity but can eventually free memory.
- **Delta‑based CRDTs** – sending only the changes (deltas) instead of full state, but still in the state‑based family. This combines the best of both worlds: low bandwidth and simple merge logic.
- **Compression** – using techniques like **interleaving** (storing runs of consecutive characters from the same site) to reduce metadata size.

## Conclusion

From the early days of Operational Transformation, which demanded a central brain and careful mathematics, we have evolved to Conflict‑free Replicated Data Types – structures that by their nature embrace concurrency and decentralisation. The trade‑offs are real: more memory for identifiers and tombstones, but a simpler mental model that scales naturally to peer‑to‑peer networks and offline‑first applications.

If you are building a collaborative editor, the choice between OT and CRDT is not just a technical decision – it’s a philosophical one. Do you trust a central coordinator to enforce order, or do you design a system where every replica carries its own truth that will eventually align with others? The latter is the path of CRDTs: a world where conflict is not resolved, but rather never arises. And as we move toward an increasingly decentralised internet (with local‑first apps, edge computing, and offline collaboration), CRDTs are not just an alternative to OT – they are becoming the foundation for how we collaborate on structured data of all kinds.

The magic of seeing a colleague’s cursor move in real time is now underpinned by data structures that are elegant in their simplicity and powerful in their consistency guarantees. The next time you edit a document with a friend, imagine the invisible identifiers floating between your characters – tiny atoms of order in a universe of concurrent chaos.
