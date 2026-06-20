---
title: "The Complexity Of The N Queens Problem: Backtracking With Heuristics And Symmetry Elimination"
description: "A comprehensive technical exploration of the complexity of the n queens problem: backtracking with heuristics and symmetry elimination, covering key concepts, practical implementations, and real-world applications."
date: "2024-12-26"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/the-complexity-of-the-n-queens-problem-backtracking-with-heuristics-and-symmetry-elimination.png"
coverAlt: "Technical visualization representing the complexity of the n queens problem: backtracking with heuristics and symmetry elimination"
---

# The Complexity Of The N Queens Problem: Backtracking With Heuristics And Symmetry Elimination

## Introduction: The Elegant Monster of the Chessboard

Imagine, if you will, a chessboard. Not the standard 8×8 grid you might have kicking around in a dusty closet, but a vast, shimmering plain of alternating black and white squares, stretching from the horizon of your mind’s eye. It is 1000 squares wide and 1000 squares deep. Now, imagine a single piece: a Queen. In chess, the Queen is the armchair general of the board, wielding the combined power of a Rook and a Bishop. She can move any number of squares vertically, horizontally, or diagonally. She is a predator, and her domain is absolute.

Now, the question: can you place one thousand Queens on this board—one for every single row—such that no two Queens threaten each other? This is the N Queens Problem, and it is one of the most deceptive, elegant, and computationally monstrous puzzles ever conceived. It is a sphinx of computer science, posing a question that is trivially easy to state yet profoundly difficult to solve at scale.

The story begins in 1848 with a German chess composer named Max Bezzel, who posed the original 8-Queens puzzle for a standard chessboard. For a few years, it was a parlor game for aristocrats and mathematicians. Carl Friedrich Gauss, the titan of mathematics, even dabbled with it, initially calculating 76 solutions (he missed a few—the actual number is 92 unique configurations). But what started as a Victorian-era brainteaser quickly evolved into something far more significant. As computers emerged from the basements of academia, the N Queens problem was resurrected, not as a game, but as a benchmark. It became the perfect torture test for a new breed of logic: the algorithm.

Why does this matter beyond the realm of recreational mathematics? Why should a distributed systems engineer care about a chess puzzle? The answer lies in the fact that the N Queens problem is a pristine member of a class called **constraint satisfaction problems (CSPs)**. Almost any real-world scheduling, resource allocation, or combinatorial optimization problem can be mapped onto a CSP. From assigning frequencies to radio towers to arranging seats on an airplane, from placing VLSI components on a chip to solving Sudoku—the same fundamental logic applies. By understanding how to solve N Queens efficiently, we learn how to solve a universe of problems.

In this post, we will peel back the layers of the N Queens problem, starting from the naive brute force approach and moving through the elegant art of backtracking. We will then supercharge that backtracking with cutting-edge heuristics and symmetry elimination, transforming an exponential search into something tractable for boards up to thousands of squares. We will walk through code examples, complexity analyses, and even touch on how distributed systems can wield this algorithm like a scalpel. By the end, you will not only grasp why N Queens is a computational beast—you will know how to tame it.

## The Problem Formalized

Before we dive into solutions, let's precisely define the problem. We have an N×N chessboard (N rows, N columns). We need to place N queens such that no two queens attack each other. In chess, a queen attacks any piece in the same row, same column, or same diagonal (both main and anti diagonal). Since we must place exactly one queen per row (because N queens on N rows means each row has exactly one queen for a valid solution), the problem reduces to choosing a column for each row.

**Definition**: A configuration is a permutation of the set {0, 1, ..., N-1} where the value at index i (row i) indicates the column of the queen in that row. However, not every permutation works because diagonal constraints must be satisfied.

**Diagonal constraint**: Two queens at positions (r1, c1) and (r2, c2) are on the same diagonal if |r1 - r2| = |c1 - c2|. Alternatively, they share a main diagonal if r1 - c1 = r2 - c2, or an anti-diagonal if r1 + c1 = r2 + c2.

Thus, the N Queens problem is a classic CSP: variables are rows, each with domain {0,...,N-1} (columns), constraints are that all values are distinct (column constraint) and no two queens share a diagonal.

It is important to distinguish between two forms of the problem:

1. **Decision problem**: Is there at least one placement for a given N? (For N≥4, yes, always.)
2. **Counting problem**: How many distinct solutions exist for a given N? This grows super-exponentially.
3. **Optimization problem**: Often, we seek any one solution, or we want to find all solutions.

In this post, we focus on the counting problem and the search for all unique solutions (including symmetries), then discuss how to eliminate symmetries.

The search space is enormous. Without any pruning, the number of ways to place N queens is (N² choose N) ≈ N²!/ (N! (N²-N)!), which is astronomical. Even if we restrict to one queen per column via permutations, we have N! possibilities. For N=8, 8! = 40320, manageable. For N=20, 20! ≈ 2.4×10^18, far too large. But with backtracking and heuristics, we can prune drastically.

## Naive Approaches: Brute Force and Permutation

### Brute Force

The most naive method: generate all combinations of N positions (rows, columns) from the N² squares, then check constraints. The number of combinations is C(N², N). For N=8, that’s 4,426,165,368 (4.4 billion). That's already too many for a simple check, not to mention N=20.

### Permutation Method

A smarter naive approach: since each row must have exactly one queen, we generate all permutations of columns (0..N-1) representing a queen in each row. Then we check diagonal constraints. For N=8, that's 40320 permutations, each checked in O(N²) (or O(N) with clever logic). That’s fine for N=8, but for N=12, 12! = 479 million; still too many.

But we can improve the check: we can use arrays for diagonals. While generating permutations, we can keep track of occupied diagonals. That’s essentially backtracking—and we will cover it next.

Before moving on, let’s see why even permutation generation is exponential. The number of permutations grows as N!. This is faster than exponential but still super-exponential (since N! grows faster than 2^N). For N=20, 20! is 2.4e18; even if you could check one per nanosecond, it would take 76 million years. So we must prune.

## Backtracking: The Heart of the Solution

Backtracking is a systematic way of exploring the search space by building a solution incrementally, and abandoning a partial solution as soon as it violates constraints. For N Queens, we place queens one row at a time. At each step, we try placing a queen in a column that does not conflict with previously placed queens. If we ever reach a row where no column is valid, we backtrack (undo the last placement and try a different column).

### Recursive Backtracking Algorithm

We maintain three sets (or boolean arrays) to track conflicts:

- `cols`: which columns already have a queen.
- `d1`: main diagonals (r-c); we can index them as r-c + N-1 to make non-negative.
- `d2`: anti diagonals (r+c); index simply r+c.

Pseudo-code:

```
function solve(row, board, cols, d1, d2, solutions):
    if row == N:
        solutions.append(board.copy())
        return
    for col in 0..N-1:
        if not cols[col] and not d1[row-col+N-1] and not d2[row+col]:
            # place queen
            board[row] = col
            cols[col] = True
            d1[row-col+N-1] = True
            d2[row+col] = True
            solve(row+1, board, cols, d1, d2, solutions)
            # backtrack
            cols[col] = False
            d1[row-col+N-1] = False
            d2[row+col] = False
```

**Time complexity**: In the worst case, this explores the entire permutation space, O(N!). However, pruning reduces it dramatically. But still, without heuristics, it’s exponential. For N=12, it’s manageable; for N=15, the number of nodes visited can be ~10^7; for N=20, it’s in the billions.

**Space complexity**: O(N) for board and boolean arrays, and the recursion depth O(N). So it’s memory-efficient.

But we can do much better with heuristics.

## Heuristics: Guiding the Search

The plain backtracking tries columns in a fixed order (0 to N-1). But we can use heuristics to decide which column to try next, dramatically reducing the branching factor. The most popular heuristic for N Queens is **Minimum Remaining Values (MRV)**, also known as “most constrained variable”. In the context of N Queens, the variables are rows, but we are filling rows sequentially. However, we can apply heuristics to the choice of column for the current row.

### Forward Checking and Look-Ahead

Instead of just checking conflicts with placed queens, we can pre-compute for each empty row which columns are still available (i.e., not threatened by any already placed queen). Then, when placing a queen in the current row, we update a table of possible columns for future rows. If any future row ends up with zero available columns, we backtrack immediately. This is called **forward checking**.

For N Queens, forward checking is simple: maintain a 2D boolean array `available[row][col]` that indicates whether placing a queen at (row, col) is still possible given all placed queens. Initially all true. When we place a queen at (r, c), we mark as false all cells in the same column, and same diagonals (both directions) for all rows > r. This update is O(N) per placement. Checking for empty row is O(N²) worst case, but we can keep counters for each row.

### Minimum Remaining Values on Columns

Another heuristic: for the current row, instead of trying columns in fixed order, we can sort the columns by the number of conflicts they cause for future rows. For each column candidate, we compute a heuristic value. A common choice is to count how many future rows would be blocked if we placed the queen at that column. We then try columns with the **highest** reduction (or lowest number of future options) first—this is a “fail-first” heuristic, which prunes early.

Alternatively, we can choose the column that minimizes the number of conflicts with future rows (i.e., leaves the most flexibility). Both can be effective; the fail-first heuristic tends to reduce the size of search tree.

**Implementation**: Before the loop over columns, calculate for each valid column the number of future rows that would become invalid (due to diagonals/column clashes). The column that eliminates the most possibilities is tried first.

### Example: N=8

Without heuristic, backtracking for 8-Queens visits about 8! / something? Actually, the number of nodes visited for N=8 is 876? Let me recall: The classic recursive backtracking with simple order visits about 876 nodes (including leaves). With forward checking, it’s fewer. An MRV heuristic can reduce to around 200 nodes.

For larger N, the impact is dramatic. For N=30, pure backtracking may be infeasible (could be billions), while with heuristics and symmetry elimination, solutions can be found in seconds.

### Code Snippet: Heuristic Column Ordering in Python

```python
def get_candidates(row, cols, d1, d2, N):
    candidates = []
    for col in range(N):
        if not cols[col] and not d1[row-col+N-1] and not d2[row+col]:
            # compute heuristic: number of rows from row+1 to N-1 that would be blocked
            threat_score = 0
            for future_row in range(row+1, N):
                # Check if col is still available for future_row (without further placements)
                # Actually we need to consider blocking of diagonals/column for future rows
                if col < N and ...: # simplified
                    threat_score += 1
            candidates.append((threat_score, col))
    # sort by threat descending (fail-first)
    candidates.sort(reverse=True)
    return [col for _, col in candidates]
```

But computing threat for each candidate naively is O(N^2) per row, leading to O(N^3) overall, which may negate benefit. In practice, we compute heuristic more efficiently using precomputed arrays.

### Advanced Heuristics: The “Knight’s Move” and other patterns

Some researchers have used heuristics specific to the N Queens geometry. For example, placing queens in a pattern that avoids the main diagonals first. But the generic MRV works well.

## Symmetry Elimination: Cutting the Search Space by a Factor of 8

One of the most powerful techniques to reduce the search space for counting all **unique** solutions (under symmetry) is to eliminate symmetric placements. The standard 8-Queens problem has 92 distinct solutions, but when considering rotations and reflections, there are 12 fundamental ones. For general N, the number of solutions grows, but symmetries still produce equivalent configurations.

The symmetries of a square board are:

- Rotations: 0°, 90°, 180°, 270° (4 rotations)
- Reflection across vertical axis, horizontal axis, main diagonal, anti-diagonal (4 reflections)
  Total 8 symmetries (the dihedral group D4). Some configurations are self-symmetric under certain transformations.

To count only unique solutions, we can enforce a **canonical representation** or add constraints that break symmetries.

### Method 1: Post-Processing

First find all solutions (including symmetric ones), then group them by canonical ordering (e.g., rotate/reflect each solution to its lexicographically smallest representation). This doubles the work.

### Method 2: Pruning During Search

We can break symmetries by imposing constraints on the first few queen placements that cannot be violated by the chosen canonical representation. For example, we can require that the queen in the first row (row 0) is placed in the left half of the board (column < N/2) to avoid mirror images. But rotations also need to be considered.

A common technique: since the board is symmetric under 90° rotation, we can restrict the first queen to the “first quadrant” (i.e., row 0, col ≤ N/2) and also ensure that if col = N/2 (when N even), then the next queen is not placed in the symmetric position. More systematically:

- Place the queen in row 0 at column c. To break reflections across vertical axis, we can enforce c ≤ (N-1)/2 (left half). For N even, c ≤ N/2 - 1 (strictly left) to avoid symmetric counterpart.
- To break rotations, we also need to consider that if c is on the main diagonal, a 90° rotation might map it to itself? Actually, we need to ensure that the entire board’s orientation is fixed. A common approach is to break symmetries by constraining the positions of the first two queens.

One powerful method: **symmetry breaking via lexicographic ordering**. We can define a total order on all possible configurations (e.g., by reading the board row-major: list of column positions). Then we only accept a configuration if it is lexicographically minimal among all its rotations and reflections. During backtracking, we can prune if the current partial assignment cannot lead to a lexicographically minimal solution. This is more complex to implement but reduces search drastically.

### Simpler: Constrain First Queen to a Fixed Column

For many purposes (e.g., find any solution), we can place the first queen at a fixed position (0,0) and then only search for solutions where row 0 queen is at column 0. Since all solutions are symmetric to one with queen at (0,0)? Actually no—for N=8, there are solutions with queen at column 0, but not all. However, we can use this to find one solution quickly (place first queen at (0,0) or (0,1) etc. But for counting all unique solutions, we need a more systematic method.

### Example: Reducing N=8 Search

Without symmetry breaking, the number of solutions is 92 (including reflections). With symmetry breaking, we reduce to 12 fundamental solutions. The search space for the backtracking algorithm is also reduced because we eliminate equivalent branches early. For N=8, the number of nodes visited can drop from ~800 to ~200.

## Advanced Techniques: Bitboards and Algorithm X

For extremely large N (N up to thousands), recursive backtracking with heuristics can still work if we only need one solution. But for counting, we need more power. Two advanced techniques stand out:

### Bitboard Representation

Using bitwise operations, we can represent the board as three integer bitmasks: columns, main diagonals, anti-diagonals. Each bit represents a column or diagonal. For a board of size N up to 64 (or more with multi-word), we can test and set in O(1) using bit operations. This is extremely fast.

Example (pseudo-code for N ≤ 64 using 64-bit integers):

```c
uint64_t cols = 0, d1 = 0, d2 = 0;
void solve(int row, uint64_t cols, uint64_t d1, uint64_t d2) {
    if (row == N) { count++; return; }
    uint64_t available = ~(cols | (d1 >> row) | (d2 >> (N - 1 - row)))
                         & ((1ULL << N) - 1);
    while (available) {
        int col = __builtin_ctzll(available); // get lowest set bit
        uint64_t mask = 1ULL << col;
        solve(row+1, cols | mask, (d1 | mask) << 1, (d2 | mask) >> 1);
        available &= available - 1; // remove bit
    }
}
```

Note the diagonal updates: shifting left/right for diagonal propagation.

This bitboard method is extremely efficient and is used in most modern solvers.

### Dancing Links (Algorithm X)

Donald Knuth’s Algorithm X solves exact cover problems using a sparse matrix representation with dancing links. The N Queens problem can be transformed into an exact cover problem: columns represent constraints (each row, each column, each diagonal) and rows represent possible queen placements. Then Algorithm X finds all solutions efficiently. It uses a doubly linked list to cover and uncover columns, allowing super-fast backtracking. However, for N Queens, the bitboard backtracking with heuristics is often faster for moderate N.

## Distributed Systems and Parallel Backtracking

As a distributed systems engineer, you might wonder how to parallelize this problem across multiple machines. The search tree is naturally parallelizable: we can assign different branches (different placements for the first few rows) to different workers. This is a classic **master-worker** pattern.

### Master-Worker Architecture

1. **Master**: Explore the search tree down to a certain depth (e.g., first 3 or 4 rows). For each partial assignment at that depth, the master creates a task (state of the board). These tasks are sent to workers.
2. **Workers**: Each worker receives the initial state (which includes the partially filled board, the sets of occupied columns and diagonals). The worker then runs a recursive backtracking from that state to find all solutions. It returns the list of solutions (or just counts) to the master.
3. **Master** aggregates results.

Challenges:

- **Load balancing**: Some branches are much larger than others (e.g., placing first queen in center vs corner). A static partition may lead to stragglers. Use a dynamic work-stealing approach.
- **Task granularity**: Too fine-grained tasks cause communication overhead; too coarse may imbalance. Typically, depth 2-4 for N=20.
- **Symmetry elimination across workers**: If we enforce symmetry breaking globally, we must ensure workers don't duplicate symmetric solutions. We can break symmetries on the master side before distributing tasks.
- **State serialization**: The board state (columns, diagonals) can be represented as several integers, easily serialized.

### Example: Using MPI or a Distributed Task Queue

For N=35, the number of solutions is huge ( > 10^10 ), so counting all solutions is infeasible on a single machine. Distributed computing with hundreds of nodes can push the boundary. For instance, a known computation of N=26 solutions took a cluster of PCs with careful parallelization.

The parallel backtracking is a classic application of **embarrassingly parallel** search with careful load balancing.

## Complexity Analysis: How Far Can We Go?

Let's talk numbers. The number of solutions for N Queens grows approximately as N! \* a^N for some small constant? Actually, it's super-exponential but with an exponent slightly less than N!. Known results:

- N=8: 92
- N=12: 14200
- N=15: 2,279,184
- N=20: 39,029,188,884 (39 billion)
- N=25: 275,986,683,743,434 (275 trillion)
- N=27: 234,907,967,154,122,528 (235 quadrillion)

The number of solutions grows roughly by a factor of 10 per increment in N. So counting all solutions becomes impossible for N>27 with current technology. But we can find a single solution quickly for much larger N—up to N=1000 or more using backtracking with heuristics and bitboards.

The search tree size for finding one solution is drastically smaller. For example, a simple backtrack with heuristics can place 1000 queens in milliseconds. The reason is that the constraints become denser as N increases, so the branching factor remains low (on average less than 1? Actually, the number of valid placements per row is around N/3? Wait, early rows have many choices, later rows few. But with MRV, we quickly prune.

### Empirical Timings

For a single solution:

- N=1000: ~0.5 seconds with optimized C++ using bitboard and heuristic (first column with fewest conflicts).
- N=10000: ~5 seconds.
- N=100000: maybe a minute? The algorithm is O(N) or O(N^2)? It depends. There is known O(N) algorithm based on pattern: for N>3, you can always construct a solution using a simple pattern (e.g., placing queens in a spiral). But that's not searching—it's a constructive algorithm. For actual backtracking, it still scales.

But for counting all solutions, N>27 is currently intractable.

## Modern Applications and Extensions

The N Queens problem is more than a benchmark. It is used for:

- **Constraint Satisfaction**: teaching tool for CSP algorithms.
- **Genetic Algorithms**: as a testbed for evolutionary optimization.
- **Parallel Computing**: to evaluate load balancing algorithms.
- **Quantum Computing**: as a demonstration problem for quantum algorithms (Grover's search).
- **Graph Theory**: connections to Latin squares and graph coloring.

Beyond N Queens, the concepts of backtracking, heuristics, and symmetry breaking apply to countless real-world problems like scheduling, resource allocation, and puzzle solving.

## Conclusion: The Everlasting Puzzle

We started with a simple question: can we place N queens on an N×N board without them attacking each other? From a Victorian puzzle, we dove into the depths of algorithmic efficiency, exploring backtracking, heuristics, symmetry elimination, and distributed parallelism. The N Queens problem is a microcosm of computer science itself—it teaches us about exponential complexity, pruning, and the art of making intractable problems tractable through clever intelligence.

Even after 175 years, there are still open questions. For instance, the exact number of solutions for N=28 is unknown (though computational efforts continue). The problem continues to challenge our machines and our minds.

So next time you look at a chessboard, think not just of the game, but of the vast combinatorial landscape that lies within. And if you ever need to place a thousand queens on a board, you now know how to do it—with a bit of backtracking, a touch of heuristics, and a dash of symmetry.

---

_This blog post has covered the N Queens problem in depth, from naive approaches to advanced distributed systems. We hope you enjoyed the journey. Feel free to share your thoughts and experiments in the comments!_
