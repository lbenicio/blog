---
title: "Building A Custom Scheduler For Linux: Cfs Vs. O(1) Scheduler Details And Implementation"
description: "A comprehensive technical exploration of building a custom scheduler for linux: cfs vs. o(1) scheduler details and implementation, covering key concepts, practical implementations, and real-world applications."
date: "2026-04-06"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Building-A-Custom-Scheduler-For-Linux-Cfs-Vs.-O(1)-Scheduler-Details-And-Implementation.png"
coverAlt: "Technical visualization representing building a custom scheduler for linux: cfs vs. o(1) scheduler details and implementation"
---

# The Linux Scheduler: From Fairness to Custom Domination

Imagine you are the sole traffic conductor at the busiest intersection in a metropolis. You have thousands of vehicles—cars, buses, bicycles, and ambulances—all arriving simultaneously. Your job is not just to move them through, but to do so with perfect fairness, ensuring a bicycle isn’t starved by a semi-truck, while also guaranteeing an ambulance (a real-time task) gets through immediately. You have exactly zero seconds to decide who goes next. This is the unenviable job of the Linux Scheduler, and for decades, the kernel’s approach to this problem has dictated everything from the responsiveness of your desktop to the throughput of a database server.

Every piece of software you run—from a background cron job to a demanding video game—is nothing more than a series of threads vying for the CPU. The programmer who writes these threads often ignores the scheduling layer entirely, relying on the tacit promise of the Operating System: "I will make sure everyone gets a turn, and it will look like they are all running simultaneously." But this promise is a delicate illusion, and the mechanism behind it is a fascinating battleground of algorithmic trade-offs.

For the systems programmer, the kernel hacker, or the performance engineer, understanding this battleground is not academic; it is essential. The default scheduler is a one-size-fits-all solution. It is designed for the average workload. But what if your workload is not average? What if you are running a latency-sensitive financial trading engine that cannot tolerate the inherent "fairness" overhead of the default algorithm? What if you are mining cryptocurrency and simply want to maximize raw throughput, ignoring fairness entirely? The default scheduler will stubbornly give each process a "fair" share, dragging down your specific metrics. To escape this tyranny of the average, you must understand the internals, and ultimately, build a custom scheduler.

This blog post is a deep dive into that very process. We will:

- Deconstruct the Linux scheduler’s history and core algorithms (O(1), CFS, EEVDF).
- Dissect the data structures and decision points that govern who runs next.
- Explore real-time scheduling classes and the `sched_ext` (eBPF-based) framework.
- Walk through writing a custom scheduler module, from design to deployment.
- Benchmark and analyze the impact of custom policies on real workloads.
- Discuss the pitfalls, performance considerations, and when you should—or should not—roll your own scheduler.

By the end, you will not only understand how Linux decides what to run next, but you will be equipped to bend that decision to your will.

---

## Chapter 1: A Brief History of CPU Scheduling in Linux

### The First Era: The O(n) Scheduler (Linux 0.01 – 2.4)

In the early days, Linux used a simple round-robin scheduler. Every process had a time slice, and the scheduler iterated over a circular linked list of all runnable processes. The complexity was O(n) with respect to the number of tasks. As systems grew from tens to hundreds of processes, this linear scan became a bottleneck. The scheduler spent more time deciding who to run than actually running them.

### The O(1) Scheduler (Linux 2.5 – 2.6.22)

The O(1) scheduler, introduced by Ingo Molnár, brought constant-time scheduling decisions. It employed two arrays of priority queues: an active array and an expired array. Each priority level (140 levels, 0-99 for real-time, 100-139 for nice) had its own runqueue. The scheduler picked the highest priority non-empty queue, ran a process from it, and when its time slice expired, moved it to the expired array. When the active array emptied, the arrays were swapped.

This was brilliant for its time. It gave strict priority to real-time tasks and provided a simple fairness mechanism via time slices proportional to nice values. However, it had flaws:

- **Starvation of interactive tasks**: A CPU-bound task with a high nice value could still dominate if there were few other tasks.
- **Poor responsiveness**: The scheduler couldn’t dynamically adapt to interactive vs. batch behavior.
- **Overhead of time-slice recalculation**: Every 200ms, the scheduler recalculated time slices for all tasks, causing cache trashing.

### The Completely Fair Scheduler (CFS) – A Paradigm Shift (since Linux 2.6.23)

CFS, designed by Con Kolivas and later refined by Ingo Molnár, threw out the concept of fixed time slices. Instead, it models the CPU as an ideal, perfectly fair multitasking processor. In an ideal system, each runnable task would get `1/N` of the CPU. Since that’s impossible in discrete time, CFS approximates it using a **virtual runtime** (`vruntime`).

**Key idea**: CFS keeps all runnable tasks in a red-black tree keyed by `vruntime`. The task with the smallest `vruntime` (i.e., the one that has received the least CPU time) is always chosen to run. When a task runs, its `vruntime` increases. The rate of increase is proportional to the inverse of its weight (derived from nice value). A higher weight (lower nice value) means `vruntime` increases more slowly, giving the task more CPU time.

CFS is tickless: it uses a high-resolution timer to preempt a running task when its time slice (a target latency, typically 4–20ms) expires. The scheduler does not have a fixed scheduling frequency; it dynamically decides when to reschedule based on `vruntime` comparisons.

The result is an elegant algorithm that:

- Provides near-perfect fairness over the long term.
- Naturally differentiates between interactive (short bursts) and batch (long bursts) tasks.
- Scales gracefully to thousands of processes.
- Adds O(log N) cost per scheduling decision (red-black tree insertion/removal) versus O(1) but with much better properties.

However, CFS is not without its own trade-offs. In the next chapter, we’ll open the black box.

---

## Chapter 2: Deep Inside CFS – Data Structures, Algorithms, and Real-World Behavior

### The Runqueue and the Red-Black Tree

Every CPU in a Linux system has its own runqueue (struct `rq`). Embedded within is the CFS runqueue (struct `cfs_rq`), which contains:

- **`tasks_timeline`**: the root of the red-black tree.
- **`min_vruntime`**: the base virtual runtime for the queue. Newly forked tasks start with `min_vruntime` (plus some margin) to prevent them from dominating the CPU.
- **`nr_running`**: number of tasks in this runqueue.
- **`exec_clock`**: time spent executing tasks.

The red-black tree is self-balancing, ensuring O(log N) insertion, removal, and min-fetch operations. Each node is a `sched_entity` (struct `sched_entity`), which contains:

- **`vruntime`**: the virtual runtime of this entity.
- **`load.weight`**: the load weight derived from the nice value.
- **`on_rq`**: flag indicating if the entity is on the runqueue.
- **`sum_exec_runtime`**: total actual runtime.

When the scheduler decides to preempt the current task (or after a voluntary sleep/wake), it calls `pick_next_task_fair()`, which simply retrieves the leftmost node in the tree—the one with the smallest `vruntime`. That task gets the CPU.

### Weight, Nice Values, and Load

The nice value (-20 to +19) maps to a weight using a precomputed table. A nice of 0 has a weight of 1024. Each increment of 1 yields a factor of about 1.25 difference. So nice=1 => weight ~819, nice=-1 => weight ~1277. The formula:

```
weight = 1024 / (1.25)^nice
```

For nice > 0, weight < 1024; for nice < 0, weight > 1024. The total load of the runqueue is the sum of weights of all runnable tasks. When a task runs for a given amount of actual time, its `vruntime` is updated as:

```
vruntime += delta_exec * NICE_0_LOAD / task_weight
```

where `NICE_0_LOAD` is 1024. So a task with weight 2048 (nice -10) will see its `vruntime` increase half as fast as a weight-1024 task. It will get roughly twice the CPU time over any interval.

**Example**: Two tasks: A (nice=0, weight=1024) and B (nice=-10, weight=2048). Over a 10 ms window, if both are constantly runnable, A will get about 3.3 ms, B about 6.7 ms. That’s the fairness defined by the nice values.

### Preemption and the Scheduling Tick

CFS does not rely on a periodic timer tick for preemption, though older kernels used a 250Hz or 1000Hz tick. Modern kernels are **tickless** (or dyntick): the timer interrupt is only fired when at least one task is runnable. But preemption still occurs based on two mechanisms:

1. **Periodic tick**: If CONFIG_HZ is set, a timer fires at that frequency and calls `scheduler_tick()`. For each scheduling entity, it checks if the task has exceeded its **time slice** (a per-task target latency, usually `sched_latency` which defaults to 6ms for 8 tasks, scaling up with more tasks). If so, the task is preempted.

2. **Wake-up preemption**: When a task wakes up (e.g., from I/O), its `vruntime` may be lower than the currently running task's. CFS then checks a heuristic: if the waking task’s `vruntime` is `thresh` (default 1ms) lower, the running task is preempted immediately. This ensures interactive tasks get responsive treatment.

### Group Scheduling and Control Groups

CFS supports hierarchical scheduling via **control groups (cgroups)** and the `cpu` controller. Each cgroup has its own `cfs_rq` and its own red-black tree of tasks or child groups. The scheduler treats a group as a single scheduling entity, with a weight and `vruntime` scaled by the group’s share. This allows system administrators to allocate CPU shares to groups of processes (e.g., guaranteeing 50% to a Docker container).

The computation becomes recursive: at each level, the scheduler picks the group entity with the smallest `vruntime`, then descends into that group’s runqueue to pick a task. This adds another layer but is crucial for multi-tenant environments.

### Load Balancing

CFS is per-CPU. To keep CPUs equally loaded, the kernel runs periodic load balancing in the scheduler_tick and also during idle rebalancing. The balancing algorithm calculates the **load** (weighted by nice) of each CPU and moves tasks from overloaded CPUs to underloaded ones. It uses a statistic called **PELT (Per-Entity Load Tracking)**.

PELT tracks the history of a task’s utilization over time using a decaying sum. Each task has a `load_avg` that records its recent CPU usage. The runqueue sums these to get the total load. This is more accurate than simple weighted runnable count because it captures how much a task actually uses the CPU (interactive tasks may sleep a lot).

Balancing decisions are made at two grain sizes:

- **Idle balance**: When a CPU becomes idle, it pulls tasks from busier CPUs.
- **Active balance**: To fix long-term imbalances, a CPU can forcibly migrate a running task (with a context switch) to another CPU.

But load balancing is expensive (cache affinity loss, overhead of moving structures). The kernel uses heuristics like **wake-up affinity** (trying to wake a task on the CPU it last ran on) and **NUMA awareness** to minimize migrations.

---

## Chapter 3: Beyond CFS – Real-Time Scheduling and the Deadline Scheduler

CFS is the default `SCHED_OTHER` policy. But Linux supports three other scheduling classes, each with different semantics.

### SCHED_FIFO and SCHED_RR

These are POSIX real-time policies. They have priorities from 1 (lowest) to 99 (highest). `SCHED_FIFO` (First In, First Out) runs the highest priority FIFO task until it voluntarily yields or blocks. No time slice. `SCHED_RR` (Round Robin) adds a time slice, and after expiration the task is moved to the tail of its priority queue.

These are not preempted by CFS tasks (CFS has priority 0). This is dangerous: a busy-looping FIFO task at priority 99 can lock up the system (even kernel threads run at lower real-time priorities). The kernel mitigates by throttling real-time tasks that hog the CPU via `/proc/sys/kernel/sched_rt_period_us` and `sched_rt_runtime_us`.

### SCHED_DEADLINE – The Real-Time Guru

Introduced in Linux 3.14, `SCHED_DEADLINE` implements the **Earliest Deadline First (EDF)** algorithm with a constant bandwidth server (CBS). It is for hard real-time applications. Each task declares three parameters:

- `runtime`: how much CPU time it needs per period.
- `deadline`: relative deadline (from release time).
- `period`: how often it is released.

The scheduler maintains a ready queue ordered by absolute deadline. The task with the earliest deadline runs. The CBS ensures that no task can exceed its runtime budget, preventing overload. This is ideal for audio/video processing, robotics controllers, and deterministic packet processing.

**Example**: A video decoder needs 10ms of CPU every 40ms with a deadline of 30ms. Using `SCHED_DEADLINE`, you guarantee it will never miss a frame (assuming the system isn't overallocated).

### Mixing Scheduling Policies

Tasks from different scheduling classes are handled by a priority hierarchy: `SCHED_DEADLINE` > `SCHED_FIFO`/`SCHED_RR` > `SCHED_NORMAL` (CFS) > `SCHED_IDLE` (lowest, only runs when no one else needs CPU). Within the same class, the rules of that class apply.

This hierarchy is implemented by the core scheduler function `__schedule()`, which first checks the deadline runqueue, then the real-time runqueue, then the CFS runqueue, then the idle task.

---

## Chapter 4: The Case for Custom Scheduling

Given all this sophistication, why would anyone want to replace the scheduler? Because the "average workload" assumption breaks for specific domains.

### The Tyranny of Fairness

CFS’s greatest strength—long-term fairness—is also its Achilles’ heel for **latency-sensitive workloads**. Consider a high-frequency trading (HFT) application that must react to a market event within microseconds. The application comprises two threads:

- **Produce thread**: reads network packets, processes, and places orders.
- **Consume thread**: retrieves confirmations.

Under CFS, if the produce thread does a compute-intensive calculation (e.g., pricing model), it may run for several milliseconds. Meanwhile, the consume thread needs to run to process an incoming ACK. CFS will not preempt the produce thread until its `vruntime` exceeds that of the consume thread, which could take up to `sched_latency` (4-6ms). That’s eternity for HFT.

You could raise the produce thread’s priority via nice, but that only gives it a larger share—it still may be preempted. Using real-time FIFO would work, but then you have to worry about priority inversion and potential starvation of other critical threads.

What you really want is a scheduler that:

- **Runs the most time-critical thread with minimal delay**.
- **Only schedules non-critical threads when no critical thread is runnable**.
- **Allows you to specify deadlines or latency requirements per task**.

That is not CFS. That is a custom schedule.

### Throughput-Oriented Workloads

At the opposite end, consider a cryptocurrency miner (e.g., Bitcoin mining ASIC simulator in software, or a GPU+CPU batch job). The miner doesn’t care about fairness or latency. It wants to maximize the number of hashes per second. Context switches are pure overhead. Ideally, the miner would run uninterrupted for a long time (e.g., 100ms+), then yield. But CFS, with its default target latency of 6ms, will preempt the miner every few ms to give time to other tasks. That causes cache pollution and TLB flush overhead.

You could set the miner’s nice value to a high number (e.g., 19), giving it a very small weight. But then CFS would still preempt it often because its `vruntime` increases quickly relative to other tasks? Actually, nice=19 gives it a weight of about 15, so its `vruntime` increases very fast (by factor 1024/15 ≈ 68). That means it will quickly become the "most unfair" and be preempted after a very short run (since other tasks have lower `vruntime`). Wait—the idea is the opposite: you want the miner to run for longer. But making its nice high means it gets very little CPU share overall. That’s not what you want.

Actually, to maximize throughput for a batch job, you want to minimize preemption. You could set the miner to `SCHED_FIFO` priority 1 (lowest real-time) and run it continuously. But that would starve everything else. Maybe you want to run it on a dedicated isolated CPU (`isolcpus` kernel parameter) and use cpusets to pin it. That is effectively a custom scheduling environment.

But the best approach is a scheduler that understands “this task is a batch job; give it a large time quantum and only preempt if absolutely necessary.”

### The HPC Database

Database servers like PostgreSQL or MySQL have many threads: connection handlers, log writers, checkpoint processes, etc. Database workloads are often I/O bound with short CPU bursts. In a typical CFS environment, a thread that does a disk read will sleep, then wake up when data arrives. On wake-up, CFS may preempt the currently running thread if the waking thread’s `vruntime` is lower. That can cause frequent context switches. It may be better to let the current thread finish its slice before preempting, to avoid thrashing the cache.

Some databases pin threads to CPUs and use busy-polling. Others rely on the `SCHED_DEADLINE` or custom policies.

### The Embedded/RTOS Domain

Linux is increasingly used in embedded systems with real-time constraints (drones, medical devices, car infotainment). While the kernel provides `SCHED_DEADLINE` and PREEMPT_RT (a set of patches that make the kernel fully preemptible), sometimes these aren’t enough. For example, you may have a periodic control loop that must run every 1ms with jitter < 10µs. The kernel’s scheduler desision can introduce jitter due to IRQ handling and other interrupts. Some developers use **scheduling isolation** and write custom scheduler plugins using eBPF (sched_ext) to precisely control when tasks run.

---

## Chapter 5: Building a Custom Scheduler – Options and Trade-offs

Before writing a kernel module, consider your options:

1. **Tune Existing Parameters**: You can change `sched_latency`, `sched_min_granularity`, `sched_wakeup_granularity` via sysctl. Real-time and deadline policies may suffice.
2. **Pin Tasks to CPUs**: Using `taskset` or cpusets, you can isolate workloads and reduce interference.
3. **Use cgroups and CPU Shares**: Group your workload into a cgroup with a high share, and other tasks into low-share groups. This provides coarse control.
4. **Kernel Module with Custom Schedule Class**: This is the nuclear option. You implement a new scheduling class (e.g., `SCHED_EXTREME_LATENCY`) by hooking into the kernel’s schedule loop.
5. **eBPF Scheduler via sched_ext**: Since Linux 6.12, the kernel has support for eBPF-based schedulers. This is safer and easier to develop than a kernel module.

We will focus on **sched_ext** as it is the modern way. But we also discuss writing a kernel module for completeness.

### The sched_ext Framework

`sched_ext` is a BPF program that acts as a scheduler. It runs in a safe, sandboxed environment within the kernel. You write BPF code that implements the scheduling policy. The BPF program is called during:

- `select_cpu`: choose a CPU for a task when it wakes.
- `enqueue`: after a task becomes runnable.
- `dequeue`: before a task stops being runnable.
- `tick`: periodic tick (optional).
- `balance`, `running`, etc.

The BPF code can maintain its own data structures (maps), decide which task to run next, and preempt the current task. It uses a set of helper functions (e.g., `scx_bpf_dispatch` to make a task runnable on a CPU).

The advantage of `sched_ext` is that you cannot crash the kernel with a buggy scheduler; the BPF verifier ensures memory safety. You can also hot-swap schedulers without rebooting.

### What We Will Build: A Latency-Optimized Scheduler (sched_latency_champ)

We want a scheduler that:

- Gives immediate CPU to any task that has a "latency critical" marker (we can use a cgroup file or bpf task storage).
- Allows non-critical tasks to run only when no critical tasks are runnable.
- For critical tasks, we use a simple FIFO within priority levels (like real-time) but with a time cap to prevent starvation of other critical tasks.
- For non-critical tasks, we implement a naive round-robin with a large time slice (like 50ms) to minimize context switches.

Our scheduler will be named `sched_latency_champ`. We'll implement it using `sched_ext`.

---

## Chapter 6: Implementing sched_latency_champ

### Prerequisites

You need a kernel with `CONFIG_SCHED_CLASS_EXT` and `CONFIG_BPF` enabled. Recent Fedora, Ubuntu, and Arch kernels support it. You also need `bpftool`, `clang`, `llvm`, and `libbpf-dev`.

### Step 1: Define the BPF Program Structure

Create a file `latency_champ.bpf.c`:

```c
#include <scx/common.bpf.h>
#include <linux/sched.h>

char _license[] SEC("license") = "GPL";

/* We'll use a BPF map to store per-task latency critical flag */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10000);
    __type(key, u32);  // tgid (task group id)
    __type(value, u8); // 1 = critical, 0 = normal
} task_latency_critical SEC(".maps");

/* Maps for critical and normal runqueues per CPU */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 2); // 0=critical, 1=normal
    __type(key, u32); // index (0 or 1)
    __type(value, struct bpf_list_head); // list of tasks
} cpu_queues SEC(".maps") = {
    .value = { .max_entries = 10000, .value_size = sizeof(u32) },
};
```

Actually, we need to maintain a list of task IDs per CPU for each priority class. We'll use BPF linked lists (available from 6.10+). But for simplicity, we can use a per-CPU array of simple FIFO arrays (ring buffers). We'll skip linked list complexity and use a simple array with head/tail indices.

Let's define a simpler approach: For each CPU, we maintain two static arrays (ring buffers) for critical and normal task PIDs, with head and tail pointers. We'll store them in a per-CPU struct.

```c
struct cpu_queue {
    u32 critical_head;
    u32 critical_tail;
    u32 normal_head;
    u32 normal_tail;
    u32 critical_tasks[256];
    u32 normal_tasks[256];
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct cpu_queue);
} cpu_state SEC(".maps");
```

### Step 2: Implement the Scheduling Hooks

We need to implement the following BPF functions (they are defined by `scx`):

- `sched_init` (optional)
- `sched_select_cpu` (not needed for our simple policy)
- `sched_enqueue`: called when a task becomes runnable.
- `sched_dequeue`: called when a task stops being runnable (e.g., blocks).
- `sched_tick`: called periodically.
- `sched_running`: called when a task starts running.
- `sched_stopping`: called when a task stops running.

Our policy:

- When a critical task becomes runnable, if the current CPU is idle or running a non-critical task, we preempt immediately. If the current CPU is running a critical task with higher priority (we'll assign simple priority via nice), we maybe let it finish.
- To implement preemption, we can set a flag in the task's BPF local storage. When a higher-priority task arrives, we notify the scheduler to reschedule.

We'll use the `scx_bpf_kick_cpu` helper to trigger a reschedule on a target CPU.

### Step 3: Enqueue Logic

```c
static bool is_critical(struct task_struct *p) {
    u32 tgid = p->tgid;
    u8 *val = bpf_map_lookup_elem(&task_latency_critical, &tgid);
    return val && *val;
}

static void critical_enqueue(struct task_struct *p, u32 cpu) {
    struct cpu_queue *q = bpf_map_lookup_elem(&cpu_state, &(u32){0});
    if (!q) return;
    if (q->critical_tail - q->critical_head >= 256) return; // full
    q->critical_tasks[q->critical_tail % 256] = p->pid;
    q->critical_tail++;
}

static void normal_enqueue(struct task_struct *p, u32 cpu) {
    // similar
}
```

### Step 4: Pick Next Task

We'll implement a helper that returns the PID of the next task to run, picking from critical queue first, then normal.

```c
static u32 pick_next(struct cpu_queue *q) {
    if (q->critical_head < q->critical_tail) {
        u32 pid = q->critical_tasks[q->critical_head % 256];
        q->critical_head++;
        return pid;
    }
    if (q->normal_head < q->normal_tail) {
        u32 pid = q->normal_tasks[q->normal_head % 256];
        q->normal_head++;
        return pid;
    }
    return 0;
}
```

### Step 5: Tick Function

In the tick, if the current task is normal and there is a critical task waiting, we preempt.

```c
void BPF_STRUCT_OPS(latency_champ_tick, struct task_struct *p)
{
    u32 cpu = bpf_get_smp_processor_id();
    struct cpu_queue *q = bpf_map_lookup_elem(&cpu_state, &(u32){0});
    if (!q) return;
    if (q->critical_head < q->critical_tail && !is_critical(p)) {
        // There is a critical task waiting, and current is not critical.
        // Request reschedule on this CPU.
        scx_bpf_kick_cpu(cpu, SCX_KICK_IDLE);
    }
}
```

### Step 6: Running and Stopping

We don't need to do much; we just need to update our queue when a task starts/stops. But we already removed from queue in `pick_next`. However, `sched_running` is called after dispatching a task. We could use it to track current task state.

The scheduler must also handle voluntary sleep: when a task blocks, it should be removed from the runqueue. That's done in `sched_dequeue` called by the core.

### Step 7: Tie Everything Together with struct sched_ext_ops

```c
SEC(".struct_ops")
struct sched_ext_ops latency_champ_ops = {
    .enqueue           = (void *)latency_champ_enqueue,
    .dequeue           = (void *)latency_champ_dequeue,
    .tick              = (void *)latency_champ_tick,
    .running           = (void *)latency_champ_running,
    .stopping          = (void *)latency_champ_stopping,
    .select_cpu        = (void *)latency_champ_select_cpu,
    .name              = "latency_champ",
};
```

### Step 8: User-Space Loader

We need a userspace program that loads the BPF object and sets the scheduler on a specific cgroup. The `scx` user-space library provides tools.

Example using `scx_loader`:

```c
// loader.c (simplified)
#include <scx/scx_user.h>
int main() {
    struct scx_open_opts opts = { .sched_name = "latency_champ" };
    int scx_fd = scx_open(SCX_OPEN_DEFAULT, SCX_POLICY_BPF);
    // apply to cgroup
    scx_attach_cgroup(scx_fd, "/sys/fs/cgroup/myworkload");
    // run
    sleep(100);
    scx_close(scx_fd);
}
```

### Step 9: Testing and Tuning

After compiling and loading, we can use `bpftool` to inspect the scheduler maps. We can also assign critical flag to specific tasks by writing to the BPF map:

```bash
# Set critical flag for PID 1234
bpftool map update id <map_id> key hex 1234 00 00 00 value 01
```

We can then run a latency-sensitive application (e.g., `stress-ng` with `--cyclic`) and observe reduced latency.

---

## Chapter 7: Performance Analysis and Benchmarking

To verify our custom scheduler works, we need to measure:

- **Latency**: Use `cyclictest` (from rt-tests) to measure scheduling latency. Run it with a high priority under CFS vs. under our custom scheduler with critical tag.
- **Throughput**: Use `iperf` and a CPU-bound calculation (e.g., `openssl speed`) to see if non-critical jobs suffer excessive overhead.

We'll run tests on a machine with 8 cores.

### CFS Baseline

```
# Run cyclictest with SCHED_OTHER priority 0
cyclictest -t1 -p 80 -n -i 100 -m -l 100000
```

Typical results: min 2 µs, avg 10 µs, max 300 µs (due to occasional interference).

### Custom Scheduler

First, load the scheduler and attach to the cgroup containing `cyclictest`. Mark the `cyclictest` process as critical:

```
bpftool map update id 73 key 0 0 0 00 00 00 00 00 00 00 00 value 01
```

Then run `cyclictest` again. Ideally, max latency reduces to < 50 µs.

We should also run a background CPU burner (e.g., `stress --cpu 8`) in the same cgroup but tagged as non-critical. Under CFS, `cyclictest` would be preempted often. Under our scheduler, the burner will only run when no critical tasks are runnable, so latencies should stay low.

### Throughput Impact

Measure the burner's throughput. Under CFS, with 8 burners and one cyclictest, each burner gets roughly 1/9 of CPU. Under our scheduler, the burners get much less (maybe 50% of CPU total). That's the trade-off: we sacrifice overall throughput for latency. Custom schedulers are not about fairness; they are about meeting specific goals.

---

## Chapter 8: Pitfalls and Production Considerations

### Safety and Security

A buggy eBPF scheduler can still cause resource starvation or deadlock. Always test in a development environment. For production, use the `scx` safety features: set `SCX_OPS_NO_PRED` or `SCX_OPS_RUNNING` appropriately.

### Complexity of Scheduling Classes

Our simple FIFO+RR queue does not handle:

- Multiple priorities within critical tasks.
- Load balancing across CPUs.
- Task migration between queues.
- Interaction with real-time tasks.
- Nice values.

Real-world custom schedulers become very complex. Many deployments use hierarchical scheduling (e.g., cgroup shares) rather than full custom.

### Integration with Kernel Features

Custom schedulers must cooperate with features like cgroup v2, NUMA balancing, energy-aware scheduling (EAS), and ARM big.LITTLE. The `sched_ext` framework provides some hooks for these (e.g., `update_load_avg`), but you must handle them.

### The Legacy Approach: Kernel Module Scheduler

If you cannot use `sched_ext` (older kernel), you can write a kernel module that registers a new scheduling class. This involves:

- Defining a `sched_class` structure with function pointers.
- Implementing all methods: `enqueue_task`, `dequeue_task`, `pick_next_task`, `put_prev_task`, `task_tick`, `set_curr_task`, etc.
- Adding hooks in `__schedule()` to call your class before CFS.

This is extremely difficult and dangerous. One mistake can panic the kernel. For most users, `sched_ext` is the better path.

---

## Chapter 9: When NOT to Write a Custom Scheduler

Let's be pragmatic. In many cases, existing mechanisms are sufficient:

- **You need low latency for a few threads**: Use `SCHED_FIFO` or `SCHED_DEADLINE` with appropriate parameters. Or use `isolcpus` and pin threads to isolated cores.
- **You need throughput for a batch job**: Pin it to a dedicated core, or use `chrt -b 0` to set batch scheduling policy (SCHED_BATCH), which is like CFS but with longer slices.
- **You need fair sharing among containers**: Use cgroup cpu shares, not custom scheduler.
- **You have mixed workloads**: Use cgroup hierarchies: put latency-critical workloads in a high-shares cgroup, batch in low-shares.

Only go custom if you have extreme, non-negotiable requirements that no combination of existing features can meet.

---

## Chapter 10: The Future of Linux Scheduling

The kernel community is actively working on better schedulers. The introduction of `sched_ext` opens the door for user-space innovation. Expect to see specialized schedulers for:

- **Cloud-native workloads** with vCPU overcommit.
- **AI/ML accelerators** where GPU and CPU scheduling need to be coordinated.
- **Virtualized environments** where a host wants to manage guest scheduling.

The EEVDF (Earliest Eligible Virtual Deadline First) scheduler, a successor to CFS, has been merged in Linux 6.6. It improves CFS by adding deadline-awareness and better handling of latency-sensitive tasks. EEVDF still provides fairness but can be tuned to prioritize certain tasks.

But even with EEVDF, the need for custom scheduling will remain for the most demanding applications.

---

## Conclusion

We began with a traffic conductor and ended with a BPF-powered, latency-optimized scheduler running on a modern Linux kernel. Along the way, we dissected CFS, explored real-time policies, and implemented a custom scheduler using `sched_ext`.

The Linux scheduler is not a monolithic black box. It is a modular, extensible framework that you can tailor to your exact workload. While most developers will never need to write a scheduler, understanding the principles—virutual runtime, load tracking, scheduling classes—empowers you to tune your systems far beyond the defaults.

The next time you measure a 50-microsecond latency spike and blame the network, remember: the scheduler might be the invisible hand causing it. And now you have the tools to change that hand.

So go ahead, think about your workload’s true requirements. Do you need fairness? Or do you need an ambulance to get through the intersection every time, even if it means the bicycle waits a few seconds longer? With Linux, you can build the traffic light that answers that question.

---

# Appendix: Full Code for latency_champ.bpf.c (Simplified)

```c
// latency_champ.bpf.c - A minimal sched_ext scheduler prioritizing "critical" tasks.
#include <scx/common.bpf.h>
#include <vmlinux.h>

char _license[] SEC("license") = "GPL";

struct queue {
    u32 head;
    u32 tail;
    u32 tasks[256];
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct queue);
} critical_queue SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct queue);
} normal_queue SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10000);
    __type(key, u32);
    __type(value, u8);
} task_critical SEC(".maps");

static bool is_critical(struct task_struct *p) {
    u32 tgid = p->tgid;
    u8 *val = bpf_map_lookup_elem(&task_critical, &tgid);
    return val && *val;
}

static void enqueue_to_queue(struct queue *q, u32 pid) {
    u32 idx = q->tail % 256;
    if (q->tail - q->head < 256) {
        q->tasks[idx] = pid;
        q->tail++;
    }
}

static u32 dequeue_from_queue(struct queue *q) {
    if (q->head < q->tail) {
        u32 idx = q->head % 256;
        u32 pid = q->tasks[idx];
        q->head++;
        return pid;
    }
    return 0;
}

void BPF_STRUCT_OPS(latency_champ_enqueue, struct task_struct *p, u32 enq_flags) {
    u32 cpu = bpf_get_smp_processor_id();
    u32 pid = p->pid;
    struct queue *q;

    if (is_critical(p)) {
        q = bpf_map_lookup_elem(&critical_queue, &(u32){0});
    } else {
        q = bpf_map_lookup_elem(&normal_queue, &(u32){0});
    }
    if (q) enqueue_to_queue(q, pid);
}

void BPF_STRUCT_OPS(latency_champ_dequeue, struct task_struct *p, u32 deq_flags) {
    // Dequeue is handled by pick_next; no action needed.
}

u32 BPF_STRUCT_OPS(latency_champ_select_cpu, struct task_struct *p, u32 prev_cpu, u64 wake_flags) {
    // Simple: keep on previous CPU, or use any idle CPU.
    s32 cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags);
    return cpu;
}

void BPF_STRUCT_OPS(latency_champ_tick, struct task_struct *p) {
    u32 cpu = bpf_get_smp_processor_id();
    struct queue *cq = bpf_map_lookup_elem(&critical_queue, &(u32){0});
    if (!cq) return;
    // If current task is not critical and there is a critical task waiting, reschedule.
    if (!is_critical(p) && cq->head < cq->tail) {
        scx_bpf_kick_cpu(cpu, SCX_KICK_IDLE);
    }
}

struct task_struct *BPF_STRUCT_OPS(latency_champ_running, struct task_struct *p) {
    // Not needed; just return p.
    return p;
}

void BPF_STRUCT_OPS(latency_champ_stopping, struct task_struct *p, bool runnable) {
    // If task is still runnable, we need to re-enqueue? Actually, the core
    // will call enqueue again if runnable. So nothing to do.
}

SEC(".struct_ops")
struct sched_ext_ops latency_champ_ops = {
    .enqueue           = (void *)latency_champ_enqueue,
    .dequeue           = (void *)latency_champ_dequeue,
    .select_cpu        = (void *)latency_champ_select_cpu,
    .tick              = (void *)latency_champ_tick,
    .running           = (void *)latency_champ_running,
    .stopping          = (void *)latency_champ_stopping,
    .name              = "latency_champ",
};
```

Compile:

```bash
clang -target bpf -O2 -c latency_champ.bpf.c -o latency_champ.bpf.o
```

Load with `scx_loader` or `bpftool struct_ops`.

---

This blog post is intentionally deep, covering history, internals, advanced usage, and hands-on custom scheduling. It should empower any systems programmer to deeply understand and control one of the most critical subsystems in Linux.
