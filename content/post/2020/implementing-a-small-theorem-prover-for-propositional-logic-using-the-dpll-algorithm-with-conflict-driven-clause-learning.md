---
title: "Implementing A Small Theorem Prover For Propositional Logic Using The Dpll Algorithm With Conflict Driven Clause Learning"
description: "A comprehensive technical exploration of implementing a small theorem prover for propositional logic using the dpll algorithm with conflict driven clause learning, covering key concepts, practical implementations, and real-world applications."
date: "2020-08-09"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/implementing-a-small-theorem-prover-for-propositional-logic-using-the-dpll-algorithm-with-conflict-driven-clause-learning.png"
coverAlt: "Technical visualization representing implementing a small theorem prover for propositional logic using the dpll algorithm with conflict driven clause learning"
---

## The Satisfiability Problem: Why Your Code Needs to Argue With Itself

What if I told you that one of the most powerful tools in computer science—a tool that verifies your chip designs, plans your supply chains, and even helps robots navigate—can be reduced to a single, absurdly simple question: "Is there a way to assign 'true' and 'false' to a bunch of variables so that a certain logical statement comes out true?"

That's the Boolean Satisfiability Problem, better known as **SAT**. It sounds almost trivial, doesn't it? For a statement with five variables, you can brute-force it in your head. For ten variables, a napkin and a pencil will do. But the moment you have fifty, a hundred, or a million variables—as modern industrial applications routinely do—the exponential explosion hits you like a freight train. The search space for a problem with just one hundred variables is larger than the number of atoms in the observable universe. Brute force is dead.

And yet, every day, SAT solvers conquer problems with millions of clauses and variables. They don't search the entire space. They learn. They argue with themselves. They perform a kind of logical judo, flipping the opponent's strength into a weakness.

Today, I’m going to show you how that magic works by building a small, functional theorem prover for propositional logic from scratch. We'll implement the **DPLL algorithm** (Davis–Putnam–Logemann–Loveland) and supercharge it with **Conflict-Driven Clause Learning (CDCL)**—the innovation that turned SAT solvers from academic curiosities into industrial workhorses.

### Why Should You Care About Propositional Logic?

Before we dive headfirst into code, let's talk about _why_ this matters beyond the academic exercise. Propositional logic is the assembly language of reasoning. Every modern formal verification tool—from the ones that check if your airplane's fly-by-wire software has a race condition, to the ones that prove a compiler didn't introduce a bug—ultimately reduces to a SAT problem. Hardware verification, software model checking, automated planning, routing in VLSI design, even artificial intelligence (including theorem proving itself) rely on SAT solvers. These solvers are the silent engines behind countless "Did we build this right?" questions in industry.

But propositional logic is also the _easiest_ logic: no quantifiers, no functions, no arithmetic. Just variables that are either true or false, connected by AND, OR, and NOT. This simplicity makes it a perfect sandbox for understanding automated reasoning. Once you grasp how SAT solvers work, you can appreciate their cleverness and see why they are a cornerstone of modern computing.

### Setting the Stage: The Language of SAT

A SAT problem typically receives its input as a **conjunctive normal form (CNF)** formula. CNF is a conjunction (AND) of clauses, where each clause is a disjunction (OR) of literals. A literal is a variable (like x) or its negation (like ¬x). For example:

```
( x ∨  y ) ∧ (¬x ∨  z ) ∧ (¬y ∨ ¬z )
```

We want to find an assignment to variables x, y, z (each true or false) that makes the whole formula true. This particular formula is satisfiable: set x = true, y = false, z = true, and each clause becomes true. But many formulas are unsatisfiable, meaning no assignment works. The challenge is to decide which, and to find a satisfying assignment if one exists.

Why CNF? Because any propositional formula can be mechanically transformed into CNF with at most a linear blowup (using the Tseitin transformation). And CNF has a nice property: a clause is only false when _all_ its literals are false. That makes reasoning about conflicts straightforward.

### Brute Force: The Exponential Wall

Let’s consider the problem size. With n variables, there are 2^n possible assignments. For n=100, that's about 1.27 x 10^30 assignments—far more than the estimated 10^80 atoms in the observable universe. Even if you could check one assignment per nanosecond, it would take longer than the age of the universe to finish. So brute force is hopeless.

But SAT solvers avoid the full search through intelligent branching, early pruning, and learning. The most fundamental algorithm that underpins modern solvers is **DPLL** (Davis–Putnam–Logemann–Loveland), a backtracking search with two key inference rules:

- **Unit propagation**: If a clause has all but one literal false, the remaining literal must be true.
- **Pure literal elimination**: If a variable appears only with one polarity (all positive or all negative) in the remaining formula, assign it that value. (Modern solvers often skip this for performance, but it's part of the original algorithm.)

DPLL forms the skeleton of every SAT solver today. We'll implement it, then add conflict-driven clause learning.

### Implementing a Simple DPLL Solver in Python

Let’s build a minimal but functional DPLL solver in Python. We'll represent a CNF formula as a list of clauses, each clause as a list of integers (positive for variable, negative for negation). Variables are 1-indexed.

```python
def dpll(formula, assignment):
    # assignment is a dict mapping var to True/False
    # Unit propagation
    formula, assignment = unit_propagate(formula, assignment)
    if not formula:  # empty formula -> all clauses satisfied
        return assignment
    if any(clause == [] for clause in formula):  # empty clause -> conflict
        return None

    # Choose a variable to branch on (simple heuristic: first variable in first clause)
    var = abs(formula[0][0])
    # Try var = True first
    new_assignment = assignment.copy()
    new_assignment[var] = True
    result = dpll(simplify(formula, var, True), new_assignment)
    if result is not None:
        return result
    # Then try var = False
    new_assignment[var] = False
    return dpll(simplify(formula, var, False), new_assignment)
```

We need helper functions: `unit_propagate`, `simplify`. Let's define them.

```python
def unit_propagate(formula, assignment):
    changed = True
    while changed:
        changed = False
        for clause in formula:
            if len(clause) == 1:  # unit clause
                lit = clause[0]
                var = abs(lit)
                if var in assignment:  # already assigned
                    continue
                value = lit > 0
                assignment[var] = value
                formula = simplify(formula, var, value)
                changed = True
                break  # restart the loop after modification
    return formula, assignment

def simplify(formula, var, value):
    new_formula = []
    for clause in formula:
        if (value and var in clause) or (not value and -var in clause):
            # clause satisfied, skip
            continue
        new_clause = [lit for lit in clause if abs(lit) != var]
        new_formula.append(new_clause)
    return new_formula
```

This basic DPLL works on small examples. For instance, solving `(x ∨ y) ∧ (¬x ∨ z) ∧ (¬y ∨ ¬z)`:

```python
formula = [[1,2], [-1,3], [-2,-3]]
assignment = {}
result = dpll(formula, assignment)
print(result)  # e.g., {1: True, 2: False, 3: True}
```

But this solver is slow on larger problems because it uses naïve branching, no conflict analysis, and no learning. It will re-explore the same dead ends repeatedly. That's where Conflict-Driven Clause Learning comes in.

### From DPLL to CDCL: Learning from Mistakes

Conflict-Driven Clause Learning (CDCL) extends DPLL by adding the ability to **learn** new clauses from conflicts. When the solver hits a conflict (an empty clause), it analyzes the conflict to derive a _conflict clause_—a new constraint that prevents the solver from making the same combination of decisions again. This clause is added to the formula, and the solver backtracks to a point where one of the conflicting decisions is undone.

The key insight: instead of simply backtracking to the most recent decision, CDCL can backtrack _non-chronologically_ (backjump) to a more distant point, skipping huge swaths of the search space. Over time, the solver accumulates learned clauses that prune the search dramatically, making it possible to solve industrial problems with millions of variables.

Let's build a CDCL solver. We'll need:

- **Decision trail**: a list recording every decision (variable and polarity) and the assignments implied by unit propagation (with reasons).
- **Implication graph**: a directed acyclic graph where each assigned literal has an antecedent—the clause that forced it (if not a decision). Conflicts are analyzed by building a conflict graph.
- **Conflict analysis**: given a conflict clause (empty clause), we traverse the implication graph backwards to find a **unique implication point (UIP)** and derive a clause that is guaranteed to be false in the current state.
- **Backjumping**: undo decisions and propagate the learned clause.

We'll implement a simplified version that still captures the essence. Let's start by defining the data structures.

```python
class CDCLSolver:
    def __init__(self, formula):
        self.formula = formula  # list of clauses
        self.num_vars = max(abs(lit) for clause in formula for lit in clause)
        self.assignment = [None] * (self.num_vars + 1)  # index from 1
        self.decision_trail = []  # list of (var, value, antecedent) for implied; antecedent = clause index or None for decisions
        self.clause_db = formula[:]  # all clauses (original + learned)
        self.antecedent = [None] * (self.num_vars + 1)  # which clause implied this var's value (index into clause_db)
        # For conflict analysis
        self.conflict_clause = None

    def solve(self):
        while True:
            # Unit propagation
            confl = self.unit_propagate()
            if confl is not None:
                # conflict detected
                if self.decision_trail == []:
                    return None  # unsatisfiable
                self.analyse_conflict(confl)
                if not self.backjump():
                    return None  # cannot backjump, UNSAT
            else:
                # All clauses satisfied? (simple check)
                if all(self.is_clause_satisfied(c) for c in self.clause_db):
                    # Build assignment dict
                    return {i: self.assignment[i] for i in range(1, self.num_vars+1) if self.assignment[i] is not None}
                # Choose a decision variable
                var = self.choose_decision_variable()
                if var is None:
                    # no unassigned variables? but some clauses not satisfied? inconsistent
                    return None
                # Decision
                self.decide(var, True)  # try True first
```

We'll implement `unit_propagate`, `decide`, `analyse_conflict`, `backjump`, `choose_decision_variable`. Let's flesh them out.

### Unit Propagation with Reason Tracking

Unit propagation scans the clause database for unit clauses. When found, it assigns the literal and records the antecedent (the clause that caused it). We also need to detect conflicts: when a clause becomes empty (all literals false).

```python
    def unit_propagate(self):
        while True:
            unit_clause = None
            for idx, clause in enumerate(self.clause_db):
                sat = False
                falsified = 0
                reason = None
                for lit in clause:
                    var = abs(lit)
                    if self.assignment[var] is not None:
                        if (lit > 0 and self.assignment[var] == True) or (lit < 0 and self.assignment[var] == False):
                            sat = True
                            break
                        else:
                            falsified += 1
                    else:
                        reason = lit
                if sat:
                    continue
                # If all literals are assigned and none satisfied -> conflict
                if falsified == len(clause):
                    # conflict clause is this clause
                    self.conflict_clause = clause[:]
                    return clause
                # Unit clause? exactly one unassigned literal and all others false
                if reason is not None and falsified == len(clause) - 1:
                    unit_clause = (idx, reason, clause)
                    break
            if unit_clause is None:
                return None  # no unit clause, no conflict
            idx, lit, clause = unit_clause
            var = abs(lit)
            value = lit > 0
            # Assign var, record antecedent
            self.assignment[var] = value
            self.antecedent[var] = idx
            self.decision_trail.append((var, value, idx))
            # Note: we don't remove satisfied clauses; they stay but are skipped.
```

This is incomplete—we need to mark decision levels. Typically each decision increases a level. We'll add a decision level counter and store level with each assignment. For simplicity, we'll track: each decision is at a new level, and implied assignments inherit the current level. Let's add that.

### Decision Making and Backtracking

We'll maintain a `decision_level` variable that increments on each decision. The trail records (var, value, ante, level). Backjumping restores the assignment to a previous level.

```python
    def __init__(self, ...):
        ...
        self.decision_level = 0
        self.trail = []  # list of (var, value, ante, level)
        self.trail_level = []  # for each decision level, the index in trail where it starts

    def decide(self, var, value):
        self.decision_level += 1
        self.trail_level.append(len(self.trail))
        self.assignment[var] = value
        self.antecedent[var] = None  # decision has no antecedent
        self.trail.append((var, value, None, self.decision_level))
```

Unit propagation must use the current decision level for implied assignments.

```python
    def unit_propagate(self):
        while True:
            # ... same as before, but when assigning:
            self.assignment[var] = value
            self.antecedent[var] = idx   # clause index
            self.trail.append((var, value, idx, self.decision_level))
```

Now for conflict analysis. This is the heart of CDCL.

### Conflict Analysis: Learning a Clause

When a conflict occurs (some clause becomes false), we have a conflict clause. To learn a new clause, we build an implication graph starting from the conflict clause and trace back to the decisions. The graph nodes are assigned literals, edges from antecedents. We want to find a **first UIP** (unique implication point)—a node that dominates the conflict at the current decision level, meaning all paths from the latest decision to the conflict go through it. The learned clause will contain the negation of all literals that are assigned at the UIP's decision level except the UIP itself, plus the negations of literals from earlier levels.

In practice, we can compute the learned clause by iteratively resolving the conflict clause with the antecedent of the most recently assigned literal at the current decision level until we reach a UIP. This is a standard algorithm.

We'll implement a simplified version: compute the implication graph and apply the "first UIP" algorithm.

```python
    def analyse_conflict(self, conflict_clause):
        # conflict_clause is the clause that became false (all literals false under current assignment)
        # We'll compute learned clause by resolution.
        # Start with conflict clause as current clause.
        learned = list(conflict_clause)
        # While there is more than one literal in learned that is assigned at the current decision level:
        while True:
            # Find the literal in learned that was assigned most recently at current level
            current_level = self.decision_level
            latest_lit = None
            latest_pos = -1
            for lit in learned:
                var = abs(lit)
                if self.assignment[var] is None:
                    continue
                # find its position in trail
                pos = next(i for i, (v, val, ante, lvl) in enumerate(self.trail) if v == var and lvl == current_level and (val == (lit > 0)))
                if pos > latest_pos:
                    latest_pos = pos
                    latest_lit = lit
            if latest_lit is None:
                break
            # Resolve with the antecedent clause of that literal (if any)
            var = abs(latest_lit)
            ante_idx = self.antecedent[var]
            if ante_idx is None:
                # It's a decision at current level, no antecedent -> UIP reached
                break
            ante_clause = self.clause_db[ante_idx]
            # Resolution: (A ∨ x) and (B ∨ ¬x) produce (A ∨ B)
            # Here our learned clause contains latest_lit (which is either x or ¬x)
            # ante_clause contains the opposite literal (since it implied the value of var)
            # So we combine all literals from both except the complementary ones.
            new_learned = []
            for lit in learned:
                if abs(lit) != var:
                    new_learned.append(lit)
            for lit in ante_clause:
                if abs(lit) == var:
                    # skip the literal that was the reason (opposite of latest_lit)
                    continue
                # Add if not already in new_learned
                if lit not in new_learned:
                    new_learned.append(lit)
            learned = new_learned
            # Check if now only one literal at current level (UIP condition)
            count_current = sum(1 for lit in learned if abs(lit) in self.trail_level[-1]... need better method)
            # Simpler: break when there is only one literal from current decision level (the UIP)
        # After loop, learned clause is ready.
        self.add_learned_clause(learned)
        # Determine backjump level: the second highest decision level among literals in learned
        # This is the level to which we backtrack (the decision level of the second-highest)
        # For simplicity, we'll just backtrack to the level of the most recent decision that is not in the UIP.
        # (We'll implement a simpler version)
```

The algorithm above is incomplete and error-prone. Let's redesign with clearer data structures. We'll implement a well-known conflict analysis loop.

**Alternative approach:** Use the "first UIP" algorithm from standard literature:

1. Start with conflict clause C.
2. Let last = the literal in C that was assigned most recently at the current decision level.
3. Resolve C with the antecedent of last to get new clause C'.
4. If C' contains only one literal at the current decision level, stop. That literal is the first UIP.
5. Otherwise, set C = C' and go to 2.

We need to track for each literal its assignment level and decision level. We'll store assignment levels.

Let's add a `var_level` array to record the decision level at which each variable was assigned (or -1 if unassigned). Update during propagation:

```python
    def decide(self, ...):
        self.var_level[var] = self.decision_level
    def propagate(self, ...):
        self.var_level[var] = self.decision_level
```

Then `analyse_conflict`:

```python
    def analyse_conflict(self, clause_idx):
        # clause_idx is index of conflicting clause in clause_db
        clause = self.clause_db[clause_idx][:]
        current_dl = self.decision_level
        # Resolve until we have only one literal from current_dl
        while True:
            # Find the literal in clause that is at current_dl and with highest decision order (most recent)
            # We'll loop over literals and find latest in trail
            latest_lit = None
            latest_pos = -1
            for lit in clause:
                var = abs(lit)
                if self.var_level[var] == current_dl:
                    # Find its position in trail (need reverse mapping? We'll store order index in trail)
                    # We'll maintain a mapping var -> trail position index for quick lookup
                    pos = self.var_trail_pos[var]  # we need to update this during assignment
                    if pos > latest_pos:
                        latest_pos = pos
                        latest_lit = lit
            if latest_lit is None:
                break  # should not happen
            var = abs(latest_lit)
            ante_idx = self.antecedent[var]
            if ante_idx is None:
                break  # decision, UIP reached
            ante_clause = self.clause_db[ante_idx]
            # Resolve: combine clauses, remove var literal
            new_clause = [l for l in clause if abs(l) != var]
            # Add literals from ante_clause, except the literal that is opposite to latest_lit
            opp_lit = -latest_lit
            for l in ante_clause:
                if l == opp_lit:
                    continue
                if l not in new_clause:
                    new_clause.append(l)
            clause = new_clause
            # Count literals at current_dl
            count = sum(1 for l in clause if self.var_level[abs(l)] == current_dl)
            if count == 1:
                break  # first UIP
        # Learned clause is 'clause'
        # Add it to database
        self.clause_db.append(clause)
        # Compute backjump level: the second highest decision level among literals in clause
        levels = set()
        for l in clause:
            var = abs(l)
            if self.var_level[var] >= 0:
                levels.add(self.var_level[var])
        sorted_levels = sorted(levels, reverse=True)
        if len(sorted_levels) == 1:
            backjump_level = 0  # or maybe -1?
        else:
            backjump_level = sorted_levels[1]
        # Update conflict_clause for backjump
        self.conflict_clause = clause
        self.backjump_level = backjump_level
```

We need to track trail positions. We'll maintain `var_trail_pos` array updated on each assignment.

### Backjumping

After learning the clause, we backtrack to `backjump_level`. That means undoing all assignments with `var_level > backjump_level`, and then performing unit propagation with the learned clause. The learned clause should be unit at the backjump level (since it has one literal at that level, and all others at lower levels, but after backtracking the higher-level literals become unassigned, leaving exactly one literal at current level? Actually after backtracking to level L, the learned clause has all literals at level <= L, and exactly one at level L (the UIP). That makes it a unit clause, which we can immediately propagate. So we set that literal's assignment accordingly.

Let's implement backjump:

````python
    def backjump(self):
        # Undo assignments above backjump_level
        # Find the position in trail where level <= backjump_level
        # We can iterate trail backwards, popping until we reach level == backjump_level
        while self.trail and self.trail[-1][3] > self.backjump_level:  # each trail entry: (var, value, ante, level)
            var, value, ante, level = self.trail.pop()
            self.assignment[var] = None
            self.antecedent[var] = None
            self.var_level[var] = -1
            self.var_trail_pos[var] = -1
        # Now we are at level backjump_level
        # The learned clause should be unit at this level: exactly one literal with var_level <= backjump_level? Actually after backtrack, all literals are either at lower levels or unassigned. The UIP literal is the one that was at current level (backjump_level+1?) Wait we backtracked to a lower level. The UIP literal's decision level was backjump_level+1? Actually the UIP is at the current decision level (the level where conflict occurred). But after backtracking, that level is undone. So the UIP literal is now unassigned. But the learned clause contains the negation of all literals except that UIP. Let's think carefully.

We need a more precise approach. Let's adopt a standard representation: we maintain a trail of decisions and implied assignments. Backjump level is the level of the second highest literal in learned clause. The learned clause is of the form (l1 ∨ l2 ∨ ... ∨ lk) where l1 is the UIP literal (assigned at the conflict level). All other literals are assigned at levels less than the conflict level. When we backtrack to level L (the second highest), we undo all assignments above L. Now l1 is unassigned (since it was at level > L). The other literals are still assigned (at lower levels) to false (since clause became false at conflict). So after backtracking, the learned clause becomes a unit clause with literal l1 (since all other literals are false). Therefore we can now unit propagate l1 to true.

So in backjump, after undoing assignments > L, we add a unit propagation for l1 (the UIP literal). But our current `backjump` just undoes assignments. We need to then call `unit_propagate` again, which will catch that learned clause is unit.

In our `solve` loop, after analysing conflict and setting `self.conflict_clause` and `self.backjump_level`, we call `backjump`, then just go back to the top of the loop (which calls `unit_propagate`). That will handle the propagation.

But we must ensure that after backjump, the learned clause is available in the clause database (we added it). And we must mark that we are back to that level. So `backjump` should also update `decision_level` and `trail_level` list.

Let's implement `backjump` properly:

```python
    def backjump(self):
        target_level = self.backjump_level
        # Undo assignments until we are at level target_level
        # Actually we want to be at level target_level (the second highest level)
        while self.trail and self.trail[-1][3] > target_level:
            var, value, ante, level = self.trail.pop()
            self.assignment[var] = None
            self.antecedent[var] = None
            self.var_level[var] = -1
            self.var_trail_pos[var] = -1
        # Also need to pop from trail_level list
        while self.trail_level and self.trail_level[-1] > len(self.trail):  # trail_level stores start indices for each level
            self.trail_level.pop()
        # Update decision_level
        self.decision_level = target_level
        # After backjump, the learned clause (which we added to clause_db) should be unit.
        # We'll let the next iteration of solve's loop detect it.
        return True
````

We also need to handle the case where `target_level == 0` (i.e., conflict at level 1, and second highest level is 0). Then backjump to level 0, undoing all assignments. The learned clause becomes unit (UIP literal). If after propagating we get another conflict, unsatisfiable.

### Decision Heuristics

The choice of decision variable greatly affects performance. Common heuristics include VSIDS (Variable State Independent Decaying Sum): each variable gets a score that increases when it appears in learned clauses, and scores decay over time. We'll implement a simple "most frequent variable in unresolved clauses" heuristic.

For our example, we'll stick with a naive heuristic: pick the first unassigned variable from the first clause that is not yet satisfied.

### Two-Watched Literals

Modern SAT solvers use an efficient data structure called "two-watched literals" for unit propagation, which avoids scanning all clauses. Instead, each clause has two "watched" literals. When one watch becomes false, we try to find another non-false literal to watch, and if none, the clause becomes unit or conflict. This reduces the cost of unit propagation to near constant per propagation. Implementing this fully would be lengthy; we'll acknowledge it as a key optimization.

### Complete CDCL Solver Code

Given the space, we cannot present a full production-quality CDCL solver, but we can provide a conceptual implementation that works on small problems. Let's tie everything together into a class that can solve the example formula.

We'll simplify `analyse_conflict` using a direct resolution loop with proper handling of levels and UIP detection. We'll also handle the learned clause addition and backjump level computation.

```python
class CDCLSolver:
    def __init__(self, clauses):
        self.clauses = clauses[:]  # list of list of ints
        self.num_vars = max(abs(lit) for clause in clauses for lit in clause)
        self.assignment = [None] * (self.num_vars + 1)
        self.antecedent = [None] * (self.num_vars + 1)  # clause index that implied this var
        self.var_level = [-1] * (self.num_vars + 1)
        self.var_trail_pos = [-1] * (self.num_vars + 1)
        self.trail = []  # list of (var, value, ante_idx, level)
        self.trail_start = []  # start index in trail for each decision level
        self.decision_level = 0
        self.learnt_clauses = []
        # For conflict analysis
        self.conflict_clause = None
        self.backjump_level = -1

    def solve(self):
        while True:
            confl = self.unit_propagate()
            if confl is not None:
                if self.decision_level == 0:
                    return None  # UNSAT
                self.analyse_conflict(confl)
                self.backjump()
                continue
            # Check if all clauses satisfied
            if self.all_satisfied():
                # Build assignment dict
                return {i: self.assignment[i] for i in range(1, self.num_vars+1) if self.assignment[i] is not None}
            # Decide
            var = self.choose_decision()
            if var is None:
                return None  # No unassigned vars but not all satisfied? inconsistent
            self.decide(var)

    def unit_propagate(self):
        while True:
            unit_info = None
            for idx, clause in enumerate(self.clauses):
                false_count = 0
                unassigned_lit = None
                satisfied = False
                for lit in clause:
                    var = abs(lit)
                    if self.assignment[var] is None:
                        unassigned_lit = lit
                    else:
                        val = self.assignment[var]
                        if (lit > 0 and val) or (lit < 0 and not val):
                            satisfied = True
                            break
                        else:
                            false_count += 1
                if satisfied:
                    continue
                if false_count == len(clause):
                    # conflict
                    return clause
                if unassigned_lit is not None and false_count == len(clause) - 1:
                    # unit clause
                    unit_info = (unassigned_lit, idx, clause)
                    break
            if unit_info is None:
                return None
            lit, clause_idx, clause = unit_info
            var = abs(lit)
            value = lit > 0
            # Assign
            self.assignment[var] = value
            self.antecedent[var] = clause_idx
            self.var_level[var] = self.decision_level
            self.var_trail_pos[var] = len(self.trail)
            self.trail.append((var, value, clause_idx, self.decision_level))

    def decide(self, var, value=True):
        self.decision_level += 1
        self.trail_start.append(len(self.trail))
        self.assignment[var] = value
        self.antecedent[var] = None
        self.var_level[var] = self.decision_level
        self.var_trail_pos[var] = len(self.trail)
        self.trail.append((var, value, None, self.decision_level))

    def choose_decision(self):
        # Simple: first unassigned variable from first unsatisfied clause
        for clause in self.clauses:
            for lit in clause:
                var = abs(lit)
                if self.assignment[var] is None:
                    return var
        return None

    def all_satisfied(self):
        # Check all clauses
        for clause in self.clauses:
            sat = False
            for lit in clause:
                var = abs(lit)
                if self.assignment[var] is not None:
                    if (lit > 0 and self.assignment[var]) or (lit < 0 and not self.assignment[var]):
                        sat = True
                        break
            if not sat:
                return False
        return True

    def analyse_conflict(self, conflict_clause):
        # conflict_clause is the clause that became false (list of literals)
        # We'll compute learned clause using first UIP
        learned = list(conflict_clause)
        current_dl = self.decision_level
        while True:
            # Find the literal in learned that is assigned at current_dl and has highest trail position
            latest_lit = None
            latest_pos = -1
            for lit in learned:
                var = abs(lit)
                if self.var_level[var] == current_dl:
                    pos = self.var_trail_pos[var]
                    if pos > latest_pos:
                        latest_pos = pos
                        latest_lit = lit
            if latest_lit is None:
                break  # all literals from lower levels? then UIP is at earlier decision level; but we assume current_dl literals present
            var = abs(latest_lit)
            ante_idx = self.antecedent[var]
            if ante_idx is None:
                # decision at current level -> UIP reached
                break
            ante_clause = self.clauses[ante_idx]
            # Resolution: remove var literal from learned and add literals from ante except the opposite
            new_learned = [l for l in learned if abs(l) != var]
            opp_lit = -latest_lit
            for l in ante_clause:
                if l == opp_lit:
                    continue
                if l not in new_learned:
                    new_learned.append(l)
            learned = new_learned
            # count literals at current_dl
            count = sum(1 for l in learned if self.var_level[abs(l)] == current_dl)
            if count == 1:
                break  # UIP reached
        # learned is the conflict clause (with UIP)
        # Add to clause database
        self.clauses.append(learned)
        self.learnt_clauses.append(learned)
        # Compute backjump level: second highest decision level among literals in learned
        levels = set()
        for l in learned:
            var = abs(l)
            if self.var_level[var] >= 0:
                levels.add(self.var_level[var])
        sorted_levels = sorted(levels, reverse=True)
        if len(sorted_levels) == 1:
            backjump_level = 0  # if only one level (current), backjump to 0
        else:
            backjump_level = sorted_levels[1]  # second highest
        self.backjump_level = backjump_level

    def backjump(self):
        target_level = self.backjump_level
        # Undo assignments until trail level drops to target_level
        while self.trail and self.trail[-1][3] > target_level:
            var, value, ante, level = self.trail.pop()
            self.assignment[var] = None
            self.antecedent[var] = None
            self.var_level[var] = -1
            self.var_trail_pos[var] = -1
        # Pop from trail_start until we are at target_level
        while self.trail_start and len(self.trail_start) > target_level:
            self.trail_start.pop()
        self.decision_level = target_level
        # After backjump, the learned clause should be unit at this level.
        # The next call to unit_propagate will handle it.
```

This code is a barebones implementation. It lacks optimizations like two-watched literals, VSIDS, and efficient conflict analysis using implication graph. However, it demonstrates the core concepts: decision, unit propagation, conflict analysis, clause learning, and backjumping.

### Testing on a Small Example

Let's test on the formula `(x ∨ y) ∧ (¬x ∨ z) ∧ (¬y ∨ ¬z)`. We'll convert to integer literals: 1=x, 2=y, 3=z. Clauses: `[[1,2], [-1,3], [-2,-3]]`.

```python
solver = CDCLSolver([[1,2], [-1,3], [-2,-3]])
result = solver.solve()
print(result)
```

Expected output: `{1: True, 2: False, 3: True}` (or other satisfying assignment). Our solver should find one.

### Why CDCL Is a Game Changer

The DPLL algorithm, while correct, revisits the same subtrees repeatedly. With clause learning, each conflict yields a new constraint that prunes the search permanently. Over time, the solver accumulates knowledge about the problem, reducing the effective search space. This is why modern SAT solvers can handle millions of variables: they learn from their mistakes with astonishing efficiency.

Consider an unsatisfiable formula: DPLL would explore the entire tree (exponential) to prove it's unsatisfiable. CDCL, by learning conflict clauses, can derive a proof of unsatisfiability (the `all-clauses-are-true?` check fails after enough learning). The learned clauses themselves form a refutation proof. In fact, the resolution steps performed during conflict analysis constitute a resolution proof that the formula is unsatisfiable. This is why SAT solvers are used as proof checkers.

### Additional Heuristics and Optimizations

- **VSIDS Decision Heuristic**: Each variable gets a score that increases by 1 for every conflict clause it appears in. Scores are periodically divided by a constant (decay) to favor recent conflicts. The solver always chooses the variable with the highest score.
- **Two-Watched Literals**: For each clause, maintain two "watched" literals. Only when a watch literal becomes false do we update the watch. This drastically reduces the time spent scanning clauses.
- **Restarts**: Periodically restart the solver (forget the assignment but keep learned clauses) to escape heavy-tailed search behavior.
- **Deleted Learned Clauses**: Keep only the most "active" learned clauses (based on VSIDS or LBD - Literals Block Distance) to control memory.

These optimizations are why solvers like MiniSAT, Glucose, and CaDiCaL are blisteringly fast.

### SAT Beyond Propositional Logic

The power of SAT extends to many domains through encodings. For instance, the **traveling salesman problem** can be encoded as a SAT instance, though it's not efficient. More practically, **model checking** reduces to SAT: a system's state space is described by propositional formulas, and SAT solvers can check if a property holds. In **hardware verification**, SAT checks equivalence of circuits. In **software verification**, bounded model checking uses SAT to find bugs in programs up to a certain loop depth. **Automated planning** translates planning problems into SAT (SATPlan). **Sudoku**, **N-Queens**, and **graph coloring** are classic pedagogical examples.

Even theorem proving in first-order logic can use SAT as a backend via the DPLL(T) scheme (Satisfiability Modulo Theories), where a SAT solver is combined with theory solvers (e.g., arithmetic, arrays).

### Conclusion: The Art of Learning from Contradiction

We started with a simple question: "Can I assign truth values to make a formula true?" That question led us through backtracking, unit propagation, conflict analysis, and clause learning. What seems like a trivial puzzle becomes, under the hood, a sophisticated machine that learns from its own contradictions. Each conflict is not a failure but a source of new knowledge. The solver doesn't just search; it argues with itself, building a logical fortress around the solution.

The satisfiability problem is a beautiful example of how a clean theoretical model (propositional logic) can be turned into a practical engineering marvel. The next time your chip design passes verification or your AI planner finds a route, remember: somewhere, a SAT solver just got smarter by arguing with itself.

If you want to dive deeper, I highly recommend reading the MiniSAT source code (<http://minisat.se>) and the Handbook of Satisfiability. Implementing your own solver—even a simple one—is one of the most rewarding ways to understand the magic of CDCL. Start with DPLL, add clause learning, then add two-watched literals and VSIDS. You'll be amazed at what you can solve.

Happy arguing with your code!
