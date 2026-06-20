---
title: "A Deep Dive Into The Linux Completely Fair Scheduler (Cfs): Red Black Tree, Virtual Runtime, And Group Scheduling"
description: "A comprehensive technical exploration of a deep dive into the linux completely fair scheduler (cfs): red black tree, virtual runtime, and group scheduling, covering key concepts, practical implementations, and real-world applications."
date: "2023-02-19"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/a-deep-dive-into-the-linux-completely-fair-scheduler-(cfs)-red-black-tree,-virtual-runtime,-and-group-scheduling.png"
coverAlt: "Technical visualization representing a deep dive into the linux completely fair scheduler (cfs): red black tree, virtual runtime, and group scheduling"
---

# A Deep Dive Into The Linux Completely Fair Scheduler (CFS): Red-Black Trees, Virtual Runtime, and Group Scheduling

You sit down at your laptop, open a terminal, and run `stress --cpu 4` while simultaneously launching a browser, a code editor, and a video streaming app. Your operating system somehow keeps everything moving—cursor responsive, video smooth, compilation churning in the background. How does Linux decide which task gets the CPU next, and why does it feel so fair even when dozens of processes compete for attention?

The answer lies in the **Completely Fair Scheduler (CFS)**, introduced in Linux kernel 2.6.23 as a replacement for the O(1) scheduler. CFS is more than just another scheduling algorithm; it represents a fundamental shift in how we think about fairness in multitasking operating systems. Instead of discrete time slices and static priorities, CFS models an “ideal, precise multi-tasking CPU” and uses a clever mathematical abstraction—**virtual runtime**—to guarantee that every thread receives its fair share of processor time. Under the hood, it relies on a **red-black tree** to keep track of runnable tasks in O(log n) time, and through **group scheduling** it extends fairness from individual processes to entire user sessions or containers.

Understanding CFS is not just a nostalgic look at kernel history. It’s essential knowledge for anyone working with modern systems—from cloud infrastructure engineers tuning Kubernetes nodes, to developers debugging latency-sensitive applications, to system administrators troubleshooting unpredictable performance. The principles behind CFS also ripple outward into newer scheduling frameworks like `CFS (Bandwidth Control)` for cgroups v2, real‑time throttling, and even the design of scheduler queues in user‑space runtime systems like Rust’s Tokio or Go’s goroutine scheduler.

In this deep dive, we’ll peel back the layers of CFS. We’ll start with the problem space: what does “fairness” mean in a preemptive multi‑tasking system? Then we’ll examine the core concepts—virtual runtime, red‑black trees, and weighted fairness—with detailed examples and even a look at the kernel source code. We’ll explore group scheduling and bandwidth control, two features that make CFS the backbone of container and cloud workloads. Finally, we’ll discuss real‑world tuning, debugging tools, and the evolution toward newer schedulers like EEVDF. By the end, you’ll have a thorough understanding of how Linux keeps your system feeling fair, fast, and responsive.

---

## 1. The Problem of Fair Scheduling

### 1.1 What Is Fairness in a Multitasking System?

In a single‑CPU system, only one process can run at any instant. The operating system must multiplex the CPU among multiple ready processes, creating the illusion of parallelism. Fairness is the property that each process receives a share of CPU time proportional to its priority (or to some entitlement). But “fairness” can mean different things:

- **Proportional fairness**: Each process gets a share equal to its weight divided by the sum of all weights.
- **Starvation avoidance**: Every process eventually gets to run, regardless of priority.
- **Low latency for interactive tasks**: A task that just became ready (e.g., after waiting for I/O) should be scheduled quickly.

These goals sometimes conflict. Giving high priority to interactive tasks can steal cycles from CPU‑bound workloads, and ensuring perfect proportional fairness can increase context‑switch overhead.

Early Unix schedulers used simple multilevel feedback queues with fixed time slices (e.g., 100ms). A process’s priority was dynamically adjusted based on CPU usage and I/O waiting—but the approach was coarse and could lead to latency surprises. The O(1) scheduler in Linux 2.6 dramatically improved scalability by using per‑CPU runqueues and bitmaps, but it still struggled to provide good interactivity for desktop workloads and fairness under high load.

### 1.2 The Shortcomings of the O(1) Scheduler

The O(1) scheduler (named for its constant‑time operations) used a set of 140 priority lists mapped to a bitmap. Tasks were placed in queues depending on their static priority and a recalculated dynamic priority based on `sleep_avg`. While fast, the scheduler had several weaknesses:

- **Interactivity heuristic**: Distinguishing interactive from CPU‑bound tasks relied on a complex formula (sleep_avg) that could misclassify tasks, leading to jitter.
- **Unfair time distribution**: Because time slices were fixed discrete lengths (e.g., 100ms for normal priority), two processes with the same nice value could accumulate unequal runtime if they were repeatedly preempted at different points in their slice.
- **Load balancing issues**: Multi‑core systems required complex heuristics to move tasks between CPUs, and the scheduler didn’t handle NUMA topologies well.

These problems became more pronounced as multicore processors and diverse workloads (web servers, databases, interactive desktops) grew. The community recognized the need for a fundamentally different approach.

### 1.3 The Design Goals of CFS

Ingo Molnar, the author of CFS, articulated a simple philosophy: “The CFS scheduler tries to model an ‘ideal, precise multi‑tasking CPU.’ If there are n runnable tasks, the scheduler’s goal is to give each task 1/n of the processor time.” Instead of partitioning time into fixed slices and then adjusting priorities, CFS uses a continuous measure of how much CPU time each task _deserves_ versus how much it has _already received_. The task that has received the least amount of CPU (relative to its fair share) is always chosen to run next.

This approach elegantly solves:

- **Fairness**: Tasks with equal weight get exactly equal CPU time over any interval.
- **Starvation prevention**: The task with the smallest runtime (or virtual runtime) is always selected, so eventually every task is served.
- **Interactivity**: An I/O‑bound task that spends most of its time sleeping will have a very small runtime; when it wakes up, it will be scheduled immediately (or very soon) because its virtual runtime is far behind others.

Now let’s dive into the two core mechanisms that make this possible: virtual runtime and the red‑black tree.

---

## 2. Virtual Runtime: The Heart of CFS

### 2.1 The Ideal Multi‑Tasking CPU Model

Imagine a CPU that can run all runnable tasks simultaneously, each at a speed of 1/n of the real CPU. In such an ideal system, after t real seconds, each of n tasks would have accumulated exactly t/n seconds of CPU time. CFS’s goal is to approximate this ideal behaviour on a physical CPU where only one task runs at a time.

It does so by tracking **virtual runtime** (`vruntime`). For each task, `vruntime` is a monotonically increasing number representing how much CPU time the task has _actually_ received, but scaled by its priority weight. The key invariant is: under perfect fairness, all tasks would have the same `vruntime`. When a task runs, its `vruntime` advances faster if it has a lower priority (high nice value) and slower if it has a higher priority (low nice value). Thus, “fairness” means equalising `vruntime` across all tasks.

### 2.2 Calculating Virtual Runtime

The basic formula for updating `vruntime` during a scheduler tick or at context switch is:

```
vruntime += delta_exec * (NICE_0_LOAD / weight)
```

Where:

- `delta_exec` is the actual physical CPU time the task just consumed (in nanoseconds).
- `weight` is the task’s load weight derived from its nice value.
- `NICE_0_LOAD` is the weight corresponding to nice 0 (typically 1024). This constant normalises the scaling: a task with nice 0 (weight = NICE_0_LOAD) sees `vruntime` advance exactly as real time; a nicer task (higher nice value, lower weight) sees `vruntime` advance **faster** than real time; a “higher priority” task (lower nice value, higher weight) sees `vruntime` advance **slower**.

This scaling ensures that after equal physical time, low‑priority tasks accumulate more `vruntime` than high‑priority tasks. Consequently, the scheduler will choose high‑priority tasks more often because their `vruntime` is smaller.

Let’s illustrate with two tasks:

- Task A: nice 0 (weight 1024)
- Task B: nice 10 (weight roughly 110? – exact table in kernel source)

If both are CPU‑bound and run in a round‑robin fashion, after each gets 1 ms of CPU time, A’s `vruntime` increases by 1 ms (since weight = NICE_0_LOAD), while B’s `vruntime` increases by about 1 ms \* (1024 / 110) ≈ 9.3 ms. Hence B’s `vruntime` grows much faster. The scheduler will always pick the task with the smallest `vruntime`, which will be A most of the time. Over many cycles, A may run nine times for every one time B runs, approximating the expected weight ratio.

### 2.3 The Nice‑to‑Weight Mapping

The mapping from nice value (‑20 to +19) to weight is not linear but exponential, following a fixed table used in many OS schedulers. The weight roughly doubles every “nice step” of 5. The kernel defines an array `sched_prio_to_weight[40]` that maps priority (0..39; 0 corresponds to nice ‑20, 39 to nice +19) to a weight. The values are chosen so that a task with nice 0 (priority 20) has weight 1024, nice ‑20 (priority 0) has weight 88761, and nice +19 (priority 39) has weight 15.

Why exponential? Because the difference in CPU share between two tasks with nice values 0 and 1 is much smaller than between 19 and 20. Users perceive CPU time logarithmically; the exponential mapping gives a consistent “feel” across the whole range.

### 2.4 When Is Virtual Runtime Updated?

`vruntime` is updated at three main events:

1. **Timer tick**: The kernel regularly checks whether the current task has exhausted its time quantum. In CFS, there is no fixed time slice; instead, the scheduler checks if the current task’s `vruntime` has grown beyond the minimum `vruntime` of any other runnable task by a certain threshold. This is known as the **dynamic timeslice** model.
2. **Voluntary preemption**: When a task calls `sched_yield()` or blocks on a mutex, the scheduler may switch to a task with smaller `vruntime`.
3. **Wake‑up**: When a task becomes runnable again (e.g., I/O completion), its `vruntime` may have been frozen during sleep. The scheduler then decides whether the new task should preempt the currently running task (wake‑up preemption).

The core scheduling decision loop can be summarised:

- Maintain a red‑black tree of runnable tasks keyed by `vruntime`.
- Pick the leftmost node (smallest `vruntime`) as the next task to run.
- While the task runs, its `vruntime` is increased at a rate proportional to `NICE_0_LOAD / weight`.
- When the `vruntime` of the current task becomes larger than the leftmost `vruntime` of the tree by a threshold (`sched_min_granularity`), a context switch is forced.

This threshold ensures that we don’t switch too often (to amortise the cost of context switching). It also provides a mechanism for controlling latency vs. throughput: modern kernels allow tuning via `sysctl` variables like `kernel.sched_latency_ns` and `kernel.sched_min_granularity_ns`.

---

## 3. Red‑Black Trees: The Data Structure Behind CFS

### 3.1 Why a Balanced Binary Search Tree?

The central operation of CFS is: **find the task with the smallest `vruntime` among all runnable tasks**. If there are N runnable tasks, we could maintain a sorted list, but insertion and deletion would be O(N). For a kernel that may have thousands of runnable threads, O(N) is unacceptable. A min‑heap could give O(log N) for both insertion and extraction, but the Linux kernel’s memory allocator and cache locality requirements favour a self‑balancing binary search tree, specifically a **red‑black tree**.

Red‑black trees provide guaranteed O(log N) time for insertion, deletion, and search of the minimum key. Moreover, they are in‑place (no extra allocation for heap nodes) and the tree structure is already widely used in other kernel subsystems (e.g., virtual memory management, I/O schedulers). The minimum element (leftmost node) can be cached and updated incrementally.

### 3.2 How CFS Uses the Red‑Black Tree

Each runqueue (`struct cfs_rq`) contains a `struct rb_root_cached` that holds the root of the tree and a pointer to the leftmost node. The key is the task’s `vruntime`, stored in `se.vruntime` (where `se` is the `sched_entity` embedded in each task’s `task_struct`). When a task becomes runnable (e.g., after creation or I/O wait ends), it is inserted into the tree. When it is scheduled away, it is removed (or its node is updated) and the leftmost pointer is refreshed.

Let’s look at the essential kernel functions (simplified from kernel/sched/fair.c):

```c
/*
 * Enqueue a scheduling entity into the cfs_rq's tree.
 * After insertion, we may need to reschedule if this task
 * has a smaller vruntime than the currently running task.
 */
static void
enqueue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
    update_curr(cfs_rq);  // Update current task's vruntime
    if (se != cfs_rq->curr) {  // Not already running
        __enqueue_entity(cfs_rq, se);
        se->on_rq = 1;
    }
    check_preempt_tick(cfs_rq, se);  // Possibly trigger preemption
}

static void __enqueue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    struct rb_node **link = &cfs_rq->tasks_timeline.rb_root.rb_node;
    struct rb_node *parent = NULL;
    struct sched_entity *entry;
    int leftmost = 1;

    while (*link) {
        parent = *link;
        entry = rb_entry(parent, struct sched_entity, run_node);
        if (entity_before(se, entry)) {
            link = &parent->rb_left;
        } else {
            link = &parent->rb_right;
            leftmost = 0;
        }
    }

    rb_link_node(&se->run_node, parent, link);
    rb_insert_color(&se->run_node, &cfs_rq->tasks_timeline);
    if (leftmost)
        cfs_rq->rb_leftmost = &se->run_node;
}
```

The `entity_before(se, entry)` compares `se->vruntime` with `entry->vruntime`. Note that to handle floating‑point like behaviour without floats, the comparison can be done with a trick using `s64 key = se->vruntime - entry->vruntime; if (key < 0) ...`. The tree is ordered by `vruntime`.

When the scheduler needs to pick the next task:

```c
static struct sched_entity *
pick_next_entity(struct cfs_rq *cfs_rq, struct sched_entity *curr)
{
    struct sched_entity *se = __pick_first_entity(cfs_rq);  // leftmost node
    // If there's a current task, check if it should stay
    if (curr) {
        if (se && !entity_before(se, curr))
            se = curr;
    }
    return se;
}

static inline struct sched_entity *
__pick_first_entity(struct cfs_rq *cfs_rq)
{
    struct rb_node *left = rb_first_cached(&cfs_rq->tasks_timeline);
    if (!left)
        return NULL;
    return rb_entry(left, struct sched_entity, run_node);
}
```

The beauty is that `__pick_first_entity` is O(1) because we cache the leftmost pointer. Only insertion/deletion require O(log N). In many systems, the number of runnable tasks is small (often <10), so even O(log N) is negligible.

### 3.3 Handling Identical Virtual Runtimes

What if two tasks have exactly the same `vruntime`? The tree requires a total order. The kernel breaks ties by using the process’s PID (or a scheduling group ID) as a secondary key. This ensures deterministic behaviour and prevents two tasks from being placed at the same tree node.

### 3.4 The Impact of Tree Rotations on Cache

A red‑black tree rotation modifies only a handful of pointers. Since each task’s `sched_entity` is allocated (actually embedded in `task_struct`), the tree nodes are physically scattered in memory. However, modern CPUs handle this reasonably well; the scheduler is not the hottest path in the kernel. For workloads with extremely high context‑switch rates, some embedded or real‑time kernels use simpler round‑robin schedulers.

---

## 4. Scheduling Classes: The Modular Scheduler Framework

CFS is not the only scheduler in Linux. The kernel uses a modular approach called **scheduling classes**, each handling a different set of tasks. There are five classes, ordered by priority:

1. **Stop class** (highest priority): Used for stop‑machine operations (e.g., CPU hot‑plug, kernel debugging). Cannot be preempted.
2. **Deadline class**: For real‑time tasks using the Earliest Deadline First (EDF) algorithm with constant bandwidth server.
3. **Real‑time class (RT)**: For traditional `SCHED_FIFO` and `SCHED_RR` tasks (POSIX real‑time). They run until blocked or preempted by a higher priority RT task.
4. **CFS class (Fair)**: Handles normal interactive and batch tasks (`SCHED_NORMAL`, `SCHED_BATCH`).
5. **Idle class** (lowest priority): Runs when no other task is runnable (idle loop). Also used for `SCHED_IDLE` tasks.

Each scheduling class implements a common interface: `enqueue_task`, `dequeue_task`, `pick_next_task`, `yield_task`, `check_preempt_curr`, etc. The main scheduler function `__schedule()` iterates through the classes in priority order, asking each to provide its next task. If the stop class has a task, it runs before any deadline task; if deadline has a task, it runs before any RT task; and so on. Only when no higher‑priority class has a runnable task does CFS get to choose.

This architecture allows subsystems like real‑time and deadline to coexist with fair scheduling. For most users, all normal applications run under CFS.

---

## 5. Group Scheduling: Hierarchical Fairness

### 5.1 The Motivation: Fairness Beyond Individual Processes

A traditional per‑process scheduler ensures that every process (or thread) gets its fair share of CPU. But consider this scenario: Alice runs ten CPU‑intensive processes, while Bob runs just one. In a per‑process fair scheduler, Alice’s ten processes each get roughly the same CPU time as Bob’s single process—so Alice’s processes collectively receive 10/11 of the CPU, leaving Bob with 1/11. This is grossly unfair to Bob from a user perspective.

The same problem arises in containerised environments: a Kubernetes pod may run dozens of containers, each containing multiple threads. Without group scheduling, a pod that spawns many threads could starve other pods.

CFS solves this with **group scheduling**: the scheduler can treat a group of tasks (e.g., all tasks belonging to a user, or all tasks inside a cgroup) as a single scheduling entity. The group is assigned a weight (derived from its own nice value or shares), and the CPU time is first divided fairly among groups, then within each group among its member tasks and subgroups.

### 5.2 How Group Scheduling Works

Internally, CFS uses a two‑level (or multi‑level) hierarchy of **scheduling entities** (`struct sched_entity`). A top‑level entity may represent either a single task or a **task group** (`struct task_group`). Each task group contains its own `cfs_rq` (runqueue) with its own red‑black tree of child entities. The task group itself participates in the parent runqueue’s tree, with its own `vruntime` that advances based on the total CPU time consumed by all tasks within the group.

The algorithm works as follows:

1. When the scheduler picks the next task, it descends the hierarchy. Starting from the root runqueue (per‑CPU), it selects the leftmost entity. If that entity is a task group, it recurses into that group’s runqueue to pick the leftmost entity within it, and so on, until it reaches a leaf (a single task).
2. After each scheduling decision, the `vruntime` of each entity in the path is updated proportionally to the CPU time consumed by the leaf task.

The tricky part is scaling: a group’s share of the CPU is determined by its weight relative to sibling groups. Within a group, its own tasks compete using the same virtual runtime mechanism. The group’s `vruntime` advances at a rate scaled by the total weight of tasks inside the group. This is analogous to how a task’s `vruntime` is scaled by its weight, but here the group’s weight is the sum of the weights of its runnable children (or a configurable shares value).

### 5.3 Configuring Group Scheduling via cgroups

Group scheduling is exposed to users via the **CPU controller** of cgroups v1 and v2. In cgroups v2, the `cpu.weight` parameter sets the relative share for a cgroup. For example:

```
# Create two groups
mkdir /sys/fs/cgroup/cpu/A
mkdir /sys/fs/cgroup/cpu/B

# Set weights (default 100)
echo 200 > /sys/fs/cgroup/cpu/A/cpu.weight
echo 100 > /sys/fs/cgroup/cpu/B/cpu.weight

# Move processes to groups
echo $PID_A > /sys/fs/cgroup/cpu/A/cgroup.procs
echo $PID_B > /sys/fs/cgroup/cpu/B/cgroup.procs
```

Now, even if group A runs many threads while group B runs only one, group A will get roughly twice the CPU of group B (200 vs 100 shares). Inside each group, its own tasks share the group’s allocated CPU proportionally to their nice values.

This feature is the foundation of resource management in Docker, Kubernetes, and systemd. It ensures that a misbehaving container cannot monopolise the CPU, and it allows administrators to set guarantees and limits.

### 5.4 Nested Hierarchies and Overhead

Cgroups can be nested arbitrarily deep (within reason). Each level adds a level of tree traversal during scheduling. In practice, the extra overhead is negligible for typical hierarchies (2–3 levels). However, extremely deep hierarchies (e.g., hundreds of cgroups) can increase scheduling latency. The kernel provides the `cgroup_no_v1` boot parameter to disable unused controllers and reduce complexity.

---

## 6. CFS Bandwidth Control: Throttling and Limits

### 6.1 The Need for Bandwidth Control

While group scheduling ensures proportional fairness based on weights, sometimes you need **hard limits**: a container must not exceed 20% of a CPU core, even if the system is idle. Or you want to guarantee a minimum CPU amount. CFS bandwidth control, configured via the cgroup cpu controller, provides these capabilities using a **runtime‑based accounting** model.

Historically known as `CFS quota` and `CFS period`, the feature allows setting:

- `cpu.cfs_quota_us`: The maximum amount of CPU time (in microseconds) that all tasks in the group can collectively consume over a period.
- `cpu.cfs_period_us`: The length of the period (default 100ms).

For example, to limit a container to 20% of a CPU:

```
echo 20000 > /sys/fs/cgroup/cpu/container/cpu.cfs_quota_us
echo 100000 > /sys/fs/cgroup/cpu/container/cpu.cfs_period_us
```

Now the tasks inside the group can use at most 20ms of CPU per 100ms period. If they exceed the quota, they are **throttled** (blocked from running) until the next period begins.

### 6.2 How Bandwidth Control Works Under the Hood

CFS bandwidth is implemented as an extension of group scheduling. Each `cfs_rq` in a throttled group accumulates runtime used (`cfs_rq->runtime_remaining`), which is decremented from a pool of runtime budget (`cfs_bandwidth->runtime`). Initially, the budget is filled to `quota` at the start of each period. When a task in the group runs, its consumed time is subtracted from the group’s remaining runtime. If the runtime goes to zero (or below), the group is marked as throttled: all its tasks are dequeued from the main runqueue and placed on a separate throttled list. At the start of the next period, the budget is refreshed, and the tasks are re‑enqueued.

For multi‑core systems, the quota is shared across all CPUs on which the group’s tasks run. This is known as **global bandwidth** (as opposed to per‑CPU quotas in some earlier designs). Accounting is done with a distributed locking scheme to avoid cache line bouncing.

In cgroups v2, the interface has been simplified: `cpu.max` sets “quota period” and “maximum”. For example:

```
# Set 0.5 CPU limit
echo "50000 100000" > /sys/fs/cgroup/cpu/mygroup/cpu.max
```

Additionally, cgroups v2 supports **burst** mode (`cpu.max.burst`), allowing a group to temporarily use extra CPU beyond the quota if the system has spare capacity, as long as it doesn’t exceed the burst limit.

### 6.3 Practical Implications for Containers

Container orchestrators rely on CFS bandwidth control to enforce CPU limits. For example, Docker’s `--cpus=1.5` flag internally sets `quota` = 150000 and `period` = 100000. This ensures the container cannot use more than 1.5 CPU cores on average.

However, a known issue is that a container with a low quota and many threads can suffer from **throttling latency**. Because the quota is shared among all threads, if one thread uses a large chunk of the quota early in the period, the remaining threads may be throttled even though the container overall hasn’t exhausted its logical share (the exact timing matters). This can lead to uneven performance, especially for latency‑sensitive microservices. Mitigations include using burst mode, larger periods, or switching to the DEADLINE scheduler.

---

## 7. CFS and NUMA: Balancing Act

### 7.1 NUMA Topology and Memory Locality

Modern servers are built with multiple memory controllers (NUMA nodes) to increase bandwidth. A process running on a CPU in Node 0 accesses local RAM faster than memory attached to Node 1. The Linux scheduler must decide on which CPU (and which NUMA node) to place a task to maximise performance. This is the realm of **NUMA scheduling** and load balancing.

CFS, like its predecessors, performs periodic load balancing across CPUs and NUMA nodes. However, balance decisions must consider memory affinity: moving a task to a different NUMA node may increase cache misses and memory latency.

### 7.2 Automatic NUMA Balancing (Auto‑NUMA)

Starting from kernel 3.8, Linux introduced **automatic NUMA balancing** (`numa_balancing`). This feature monitors memory accesses by sampling the page fault handler. If a task touches many pages on a remote NUMA node, the kernel can migrate the task to that node (or the pages to the task) to improve locality. CFS interacts with this feature by adjusting load balancing based on “NUMA scores”.

The `sched_numa_balancing` sysctl can be set on the fly (`echo 1 > /proc/sys/kernel/numa_balancing`). When enabled, the scheduler periodically scans each task’s address space for NUMA hints. The scan rate is adaptive: tasks that show strong local memory affinity are scanned less frequently.

### 7.3 Load Balancing in CFS

The CFS load balancer runs on each CPU every few milliseconds (via the idle loop or the scheduler tick) and also when the system is idle. It uses per‑CPU runqueues and maintains a **load** metric (the sum of the weights of all runnable tasks on that CPU). When imbalance exceeds a threshold, the busiest CPU tries to pull tasks from the least loaded (or vice versa). The algorithm is complex, but in essence it uses a multi‑pass approach:

1. **fastpath**: Check if immediate local imbalance exists.
2. **Domain walk**: Iterate over scheduling domains (groups of CPUs sharing cache or memory). Within each domain, compute the busiest group.
3. **Task selection**: Choose a task to migrate based on cache affinity, idle timestamps, and NUMA distance.

CFS also uses **cgroup‑aware load balancing**: tasks from the same cgroup are balanced together.

---

## 8. Interactivity and Tuning Parameters

### 8.1 How CFS Handles I/O‑Bound Tasks

One of CFS’s strengths is its natural handling of interactive (I/O‑bound) tasks. When a task sleeps (e.g., waiting for keyboard input), its `vruntime` does not increase. When it wakes up, it likely has a very small `vruntime` compared to CPU‑bound tasks that have been accumulating runtime. Therefore, the scheduler will almost immediately preempt the current CPU‑bound task and run the woken task. This results in low latency for interactive workloads—mouse movements, key presses, and network responses.

To prevent **thrashing** (where a CPU‑bound task is constantly preempted by a rapid series of wake‑ups), the scheduler uses a parameter called **wakeup preemption** granularity. If the woken task’s `vruntime` is not significantly smaller than the current task’s, it won’t preempt immediately. This is tuned by `sched_wakeup_granularity_ns`.

### 8.2 Tuning CFS via sysctl

While CFS works well for most workloads out of the box, system administrators can tune several parameters to match their needs:

- `kernel.sched_latency_ns` (default 12,000,000 = 12 ms): The scheduler’s target for the length of a “scheduling period”. For `n` tasks, each task will be scheduled at least once per `sched_latency / n` on average. Making this smaller increases latency sensitivity but also increases context‑switch overhead.
- `kernel.sched_min_granularity_ns` (default 1,500,000 = 1.5 ms): The minimum time a task will run before being preempted. This prevents the scheduler from switching too often.
- `kernel.sched_wakeup_granularity_ns` (default 2,000,000 = 2 ms): The threshold for wake‑up preemption.
- `kernel.sched_migration_cost_ns` (default 500,000): Cost of migrating a task; used in load balancing decisions.
- `kernel.sched_nr_migrate` (default 32): Maximum number of tasks moved in a single load balance pass.

For latency‑sensitive applications (e.g., audio streaming, online gaming), one might reduce `sched_min_granularity` and `sched_latency`. For high‑throughput batch processing, increasing these values reduces overhead.

### 8.3 The Sleeper Fairness Controversy

A much‑discussed aspect of CFS is how it treats tasks that sleep. In early versions, a sleeping task’s `vruntime` was not static—it could be artificially set to the current minimum `vruntime` upon wake‑up. This gave interactive tasks an even larger boost, but it was considered unfair because a task that sleeps voluntarily could eventually consume more CPU than its fair share when many such tasks wake up simultaneously (the “killer sleeper” problem). Modern CFS uses **sleeper fairness**: the `vruntime` of a waking task is clipped to `min_vruntime - sched_latency`, ensuring it cannot exceed a certain benefit. The exact algorithm is complex, but the general principle is that the scheduler approximates fairness for both CPU‑bound and I/O‑bound tasks.

---

## 9. Debugging and Observing CFS

### 9.1 Reading /proc/<pid>/sched

Each process exposes scheduling statistics in `/proc/<pid>/sched` (requires CONFIG_SCHEDSTATS). For example:

```
$ cat /proc/1/sched
systemd (1, #threads: 1)
---------------------------------------------------------
se.exec_start                      :     133792100.714671
se.vruntime                        :             0.099952
se.sum_exec_runtime                :              4.123456
se.nr_migrations                   :                   12
nr_switches                        :                 3452
nr_voluntary_switches              :                 3350
nr_involuntary_switches            :                  102
...
```

- `se.vruntime`: The task’s virtual runtime in nanoseconds (shown in seconds for readability).
- `se.sum_exec_runtime`: Total CPU time consumed (nanoseconds).
- `nr_switches`: Total number of context switches.

You can compare `vruntime` values across processes to see which one is currently “ahead” or “behind”.

### 9.2 Perf and Tracepoints

The `perf sched` command can record and visualise scheduling events:

```
perf sched record -- sleep 10
perf sched latency
perf sched map
perf sched timehist
```

This shows how long each task waited for the CPU, which tasks were running, and the duration of scheduling slices.

Additionally, the tracepoint `sched:sched_switch` provides in‑depth data. You can enable it with:

```
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
cat /sys/kernel/debug/tracing/trace
```

### 9.3 `/proc/sched_debug`

For a detailed snapshot of the scheduler’s state per CPU, use:

```
cat /proc/sched_debug
```

This output (verbose) shows each runqueue’s tree, the current task, load averages, and more. It’s invaluable for understanding why a particular task isn’t getting CPU.

### 9.4 Practical Example: Measuring Fairness

Let’s run an experiment: create two CPU‑bound threads with different nice values and observe their CPU time. Write a simple C program:

```c
#include <stdio.h>
#include <unistd.h>
#include <sched.h>

void burn_cpu() {
    volatile unsigned long long i;
    for (;;) i++;
}

int main() {
    pid_t pid = fork();
    if (pid == 0) {
        // Child: nice +10
        setpriority(PRIO_PROCESS, 0, 10);
        burn_cpu();
    } else {
        // Parent: nice 0
        setpriority(PRIO_PROCESS, 0, 0);
        burn_cpu();
    }
    return 0;
}
```

Compile and run for, say, 10 seconds. Then check `/proc/<pid>/sched` to view `se.sum_exec_runtime`. The parent (nice 0) should have consumed roughly 9 times more CPU than the child (nice 10), reflecting the weight ratio (1024 vs ~110). This is a direct visualisation of CFS weighted fairness.

---

## 10. Limitations and Evolution: The Road to EEVDF

### 10.1 Known Issues with CFS

Despite its elegance, CFS has limitations:

- **Latency tail in overloaded systems**: When many tasks are runnable, the scheduler’s focus on minimising `vruntime` differences can cause frequent context switches, leading to high overhead and unpredictable latency for individual tasks.
- **Fairness over short vs long timescales**: The definition of “fair” is asymptotic. Over very short windows (microseconds), a task may not get exactly its fair share due to granularity.
- **Group scheduling complexity**: Deep cgroup hierarchies can increase scheduling overhead and make load balancing less efficient.
- **Interactivity vs bandwidth trade‑off**: Wake‑up preemption can cause cache thrashing if many I/O‑bound tasks compete.

### 10.2 The Emergence of EEVDF

In 2022, Peter Zijlstra proposed replacing CFS with the **Earliest Eligible Virtual Deadline First (EEVDF)** scheduler, a design based on a well‑studied algorithm from the real‑time systems community. EEVDF maintains a virtual deadline per task and selects the task with the earliest deadline. It can provide stronger latency guarantees and lower tail latency under high load while still achieving proportional fairness. The patchset was merged into Linux kernel 6.6, making EEVDF the default scheduler.

EEVDF uses a similar red‑black tree (now keyed by `deadline` instead of `vruntime`) and also supports group scheduling. It aims to reduce the inherent oscillation in CFS where tasks sometimes receive bursts of CPU followed by waiting, leading to more consistent scheduling.

### 10.3 Should You Care?

If you’re running a kernel >= 6.6, your “CFS” is actually EEVDF. However, the concepts of virtual runtime, red‑black trees, and group scheduling remain largely the same. Understanding CFS provides a solid foundation for grasping EEVDF, and many debugging tools (`/proc/sched_debug`, `perf sched`) still work with the new scheduler. Moreover, CFS is still the scheduler of choice in older systems, which are widespread in production.

---

## 11. Conclusion

The Completely Fair Scheduler isn’t just a clever algorithm—it’s a philosophy turned into code. By redefining the scheduling problem as an equilibrium of virtual runtime, CFS eliminates the need for complex interactivity heuristics and ad‑hoc time slices. It leverages a well‑understood data structure (red‑black trees) to perform its core operation with logarithmic complexity, and extends fairness across users and containers through group scheduling and bandwidth control.

CFS has shaped how we build and manage systems, from the kernel’s internal design to container orchestrators like Kubernetes. Its legacy lives on in EEVDF, and the basic principles—virtual runtime, weighted fairness, hierarchical scheduling—remain central to operating system design.

Next time you run a heavy compilation while streaming a movie and your system remains snappy, think about the little red‑black tree inside your kernel, carefully tracking every nanosecond of virtual runtime to keep everything fair. That is the quiet magic of CFS.

---

_Further Reading:_

- Linux kernel source: `kernel/sched/fair.c`
- Ingrid M. Garcia, “The Linux Scheduler: A Decade of Progress” (2020)
- Documentation: `Documentation/scheduler/sched-design-CFS.rst`
- LWN article: “CFS group scheduling” (2007)
- “EEVDF Scheduler”, LWN 2022: https://lwn.net/Articles/900643/
