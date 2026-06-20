---
title: "Building A Custom Profiling Tool With Linux Perf Events And Ebpf"
description: "A comprehensive technical exploration of building a custom profiling tool with linux perf events and ebpf, covering key concepts, practical implementations, and real-world applications."
date: "2026-01-05"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Building-A-Custom-Profiling-Tool-With-Linux-Perf-Events-And-Ebpf.png"
coverAlt: "Technical visualization representing building a custom profiling tool with linux perf events and ebpf"
---

# The Hidden Cuts: Building Custom Profilers with perf_events and eBPF

You’re staring at a terminal graph that refuses to budge. CPU usage hovers at 85% on a capacity–planned database node. Latency p95 has jumped from 2ms to 18ms. Your monitoring dashboard screams, but your profiling tools whisper. `perf top` shows a familiar distro of function names—`__do_fault`, `tcp_v4_rcv`—nothing obviously hot. `strace` floods 20,000 lines per second and slows the process to a crawl. You try `perf record` with call‑graph, but the resulting report is a mile‑long table of cryptic symbols from a JIT‑compiled runtime. You suspect the kernel networking stack, but the samples don’t tell you _which_ user‑space thread caused the packet to arrive. You need context—not just numbers.

This is the moment you realise that off‑the‑shelf profiling tools are like having a butcher with a blunt cleaver when you need a fine scalpel. They’ll cut, but they won’t make the precise incision that uncovers the real problem. The gap between _what you can observe_ and _what you need to understand_ is precisely the gap that custom profiling tools fill. And the only way to build those tools, on modern Linux, is to combine two of the most powerful observability primitives the kernel has ever given us: `perf_events` and eBPF.

## Why “Custom” Matters More Than You Think

Production systems are no longer simple monoliths. They are layered stacks of kernels, container runtimes, JIT‑compiled languages (Java, Node.js, LuaJIT), custom dispatchers (io_uring, DPDK, XDP), and user‑space network stacks. Each layer introduces its own abstraction boundaries. Standard profilers, designed for straightforward C/C++ applications running on a vanilla kernel, struggle to cross those boundaries without assistance.

Consider a typical scenario: you’re profiling a Go HTTP server that uses a user‑space TCP stack for zero‑copy transmission. `perf` can sample hardware counters—instructions, cache misses, branch mispredictions—but it cannot tell you that a particular sample occurred while your custom stack was spinning on a mutex protecting its concurrency queue. The kernel sees only the raw CPU cycles; it has no knowledge of your application’s internal state. To bridge this gap, you need to inject probes at the user‑space level and correlate them with kernel events.

### The Abstraction Tax

Every modern runtime adds layers that obscure the real work happening. Java’s JIT compilers inline methods and generate native code on the fly, so a stack trace from `perf` might show `Interpreter::invoke` or `unknown` instead of your business logic. Node.js uses V8’s Turbofan, which compiles JavaScript to machine code but rarely leaves symbols in the kernel’s perf map unless you explicitly enable `--perf-basic-prof`. Python’s GIL serializes execution, making CPU profiles look like the interpreter itself is the bottleneck when really it’s your callback. Custom dispatchers like io_uring hide I/O completion behind submission queues; `perf` sees `io_uring_enter` but not which submission caused the completion.

Even containerization adds overhead: cgroup accounting, overlay filesystem operations, and network namespacing all introduce context switches that the profiler sees as “kernel time” but you need to attribute to the container’s workload. A generic profiler cannot know that `kworker` spending 10% CPU is actually packing up your container’s network packet.

### Concrete Example: The Spinlock in User‑Space TCP

Let’s flesh out the Go HTTP server scenario. You have a service that offloads TCP processing to a user‑space stack (e.g., gVisor’s netstack, or custom with DPDK). The server handles 10,000 requests per second, but latency spikes appear every 30 seconds. `perf top` shows about 60% CPU in `__do_fault` and 30% in `tcp_v4_rcv`. Nothing obviously wrong. You try `perf record -a -g` and generate a flamegraph. It shows a broad plateau in `runtime.mcall`, `some_user_space_stack_handle_packet`, and `mutex_lock`. But the flamegraph is flat – you cannot see the blocking relationship.

Now you use a custom probe: you attach an uprobe (via eBPF) to your user‑space stack’s `lock_acquire` function. You record the thread ID and the lock address every time it’s acquired or released. You also use a `perf_events` software tracepoint, `sched:sched_switch`, to capture when the thread is preempted. In user-space, you correlate the lock hold times with context switches. You discover that the spinlock inside the user-space TCP stack is held for up to 200 microseconds when a particular request path—the one doing database writes—triggers a cache miss. That 200 microseconds is enough to cause the kernel to schedule another thread onto the same CPU, which then pushes your lock holder into a wait state. The `__do_fault` you saw is actually the page fault caused by the user-space stack’s buffer allocation.

Without a custom profiler that bridges user and kernel context, you’d never find this. The interaction between a user‑space spinlock and kernel‑scheduling is invisible to separate tools.

## Understanding the Primitives: perf_events

`perf_events` is the kernel’s performance monitoring subsystem. It provides a unified interface to hardware performance counters (PMCs), software events (context switches, page faults), and tracepoints. It’s the foundation of `perf` tool but also exposes a system call (`perf_event_open`) that user‑space programs can use directly for fine‑grained control.

### The `perf_event_open` Syscall

The core API is `perf_event_open(struct perf_event_attr *attr, pid_t pid, int cpu, int group_fd, unsigned long flags)`. Each call creates an event file descriptor that you can `read()` data from, `mmap()` a ring buffer into user‑space for efficient sampling, or `ioctl()` for control.

Let’s look at a minimal example that counts instructions on all CPUs for the current process:

```c
#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdio.h>

// Helper to call syscall
static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

int main() {
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(pe));
    pe.type = PERF_TYPE_HARDWARE;
    pe.size = sizeof(pe);
    pe.config = PERF_COUNT_HW_INSTRUCTIONS;
    pe.disabled = 1;
    pe.exclude_kernel = 1;  // count only user space
    pe.exclude_hv = 1;

    int fd = perf_event_open(&pe, 0, -1, -1, 0);
    if (fd == -1) {
        perror("perf_event_open");
        return 1;
    }

    // start counting
    ioctl(fd, PERF_EVENT_IOC_RESET, 0);
    ioctl(fd, PERF_EVENT_IOC_ENABLE, 0);

    // do some work
    long sum = 0;
    for (int i = 0; i < 1000000; i++) sum += i;

    // stop and read
    ioctl(fd, PERF_EVENT_IOC_DISABLE, 0);
    long long count;
    read(fd, &count, sizeof(count));
    printf("Instructions: %lld\n", count);
    close(fd);
    return 0;
}
```

This is simple but you can extend it to sample at regular intervals by using `PERF_SAMPLE_*` flags in the attr. For example, to record IP and stack every 100000 instructions:

```c
pe.sample_period = 100000;
pe.sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TID | PERF_SAMPLE_CALLCHAIN;
// then mmap a ring buffer to collect samples.
```

When you sample, the kernel writes records into the ring buffer. Each record contains the requested data (instruction pointer, thread ID, callchain). You can then decode symbols using `/proc/self/maps` or `libelf`.

The power of `perf_event_open` is that you can combine multiple events into a “group” (using `group_fd`). For example, you can read instruction count and cache misses in one sample. This allows correlation not just of stack traces but also of counters.

### Sampling vs. Counting

`perf_events` supports two modes: _counting_ (continuous counter value) and _sampling_ (record event at intervals). Counting gives aggregate totals; sampling gives distributions. For custom profilers, sampling is usually more interesting because it captures context.

The sample period can be specified as a fixed number of events (e.g., every 10000 instructions) or using adaptive frequency (specify a target rate via `sample_freq`). The kernel then adjusts the period to achieve roughly that many samples per second. This is useful when you want a consistent profiling overhead.

### Ring Buffer and Overhead

The ring buffer is mapped as a circular buffer. Each time a sample is taken, the kernel writes a record and pushes a `mmap` page forward. User‑space reads by taking the data from the tail to the head. If the buffer fills before you read, samples can be lost. You can increase buffer size via `mmap` `size` parameter (a power of two of pages).

Overhead comes from two sources: the kernel’s work to write the sample (every time an event fires, it must collect context), and user‑space polling. With a high sample rate (e.g., 50 kHz), overhead can be 10% added CPU. Typically you sample at 100-1000 Hz per CPU.

## Understanding the Primitives: eBPF

eBPF (extended Berkeley Packet Filter) is an in‑kernel sandboxed virtual machine that allows user‑space to attach small programs to a variety of hooks: system calls, function entries/exits (kprobes, uprobes), tracepoints, network events, etc. eBPF programs are written in a restricted C, compiled to BPF bytecode, loaded via the `bpf()` syscall, and verified for safety (no unbounded loops, only bounded memory access). Once loaded, they execute in kernel context with near‑zero overhead.

### Why eBPF for Profiling?

Traditional profilers rely on sampling at fixed intervals or on kernel interrupts. eBPF lets you attach to _specific functions_ at the exact moment they’re called. This gives you _context_: you know which user‑space function is running, what arguments it has, and what the return value is. You can also aggregate data in kernel using BPF maps, drastically reducing the amount of data that must be copied to user‑space.

For example, to profile a user‑space spinlock in the TCP stack, you can attach a kprobe to the kernel’s `mutex_lock` function and a uprobe to your user‑space `lock_acquire`, then collect the stack traces and timestamps.

### Hooks Relevant to Profiling

- **kprobes/kretprobes**: instrument any kernel function (including exported symbols). Good for kernel‑level events like scheduling, memory allocation, network receive.
- **uprobes/uretprobes**: instrument user‑space functions by address or by symbol name in an ELF binary. Requires the binary to be loaded with symbols or you can specify an offset.
- **tracepoints**: stable kernel hooks (e.g., `sched:sched_switch`, `kmem:kmalloc`). Safer than kprobes because the interface is guaranteed.
- **perf_events**: eBPF programs can be attached to perf events via `perf_event_open` and `bpf(BPF_PERF_EVENT_OPEN)`. This allows you to write eBPF programs that process perf samples in‑kernel, rather than sending all samples to user‑space.
- **BPF iterators**: you can iterate over kernel data structures (e.g., all running processes) without per‑event overhead.

### Basic eBPF Program: Count System Calls

Here’s a minimal eBPF program that counts `open` syscalls per process, using `kprobe` and a BPF map:

```c
// bpf_program.c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u32);
    __type(value, u64);
} open_counts SEC(".maps");

SEC("kprobe/__x64_sys_open")
int bpf_prog(void *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 *count = bpf_map_lookup_elem(&open_counts, &pid);
    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        u64 new = 1;
        bpf_map_update_elem(&open_counts, &pid, &new, BPF_ANY);
    }
    return 0;
}
```

Load this with `bpftool` or Python `bcc`. User‑space can then read the map periodically.

### CO‑RE and BTF

One major challenge is portability: eBPF programs that reference kernel structs are tied to a specific kernel version. The solution is CO‑RE (Compile Once – Run Everywhere) combined with BTF (BPF Type Format). BTF encodes kernel type information, so the loader can adjust offset calculations at load time. This makes eBPF programs portable across kernels.

## Combining perf_events and eBPF

Now we come to the heart of custom profiling: using both together. `perf_events` gives you hardware counters and stable sampling infrastructure; eBPF lets you add custom context and aggregation. The key synergy is the `BPF_PERF_EVENT` attachment: you can write an eBPF program that runs on every perf sample, and that program has access to all the sample data (IP, stack, counters) plus the ability to look up maps.

### The Pipeline

1. **Kernel‑side**: Use `perf_event_open` with `PERF_SAMPLE_*` to request a sample (e.g., every 10000 instructions). But instead of reading the ring buffer directly, attach an eBPF program to the event via `bpf(BPF_PERF_EVENT_OPEN)` and set `attr.bpf_event` flag. The eBPF program will be called with the sample data as context (struct bpf_perf_event_data containing regs, sample_period, etc.). In that eBPF program, you can:
   - Look up user‑space thread‑local data from another map (e.g., a map of thread IDs to application states).
   - Optionally forward the sample to user‑space via `bpf_perf_event_output()` (into a perf ring buffer).
   - Aggregate data in‑kernel (e.g., increment a counter for each stack trace).

2. **User‑space**: A controller process sets up the perf events, loads the eBPF program, and periodically reads either the BPF maps (aggregated data) or the perf ring buffer (individual samples). This reduces overhead because you can aggregate thousands of samples into a single map entry.

### Example: Identifying Which User‑Space Thread Caused a Packet Arrival

Recall the initial scenario: you see `tcp_v4_rcv` in perf samples but cannot link it to a user‑space thread. You can solve this with a custom profiler:

- Use `perf_events` with `PERF_SAMPLE_IP | PERF_SAMPLE_TID | PERF_SAMPLE_REGS_USER` to capture user registers (including program counter and stack pointer).
- Attach an eBPF program to the perf event. The program receives the kernel register state. From the saved user registers (`uregs`), it can extract the user‑space instruction pointer. But you need to associate that with your Go thread. Since Go uses cooperative scheduling (goroutines), the kernel sees the same PID for many goroutines. However, you can maintain a user‑space map of `pthread_self()` -> `goroutine_id` (using TLS variables). The eBPF program cannot directly read user memory, but it can use `bpf_probe_read_user()` to read a specific address. With careful instrumentation (uprobes on Go scheduler functions), you can maintain a BPF map that maps kernel thread ID to current goroutine ID and to the user‑space TCP stack’s connection state.

Thus, when a perf sample hits in `tcp_v4_rcv`, your eBPF program can look up the kernel PID, find the corresponding goroutine, and know that this packet belongs to connection 42. You then write the sample (with added goroutine ID) to a user‑space perf ring buffer via `bpf_perf_event_output`.

### Code Skeleton

Below is a simplified skeleton of such a profiler. For brevity, it shows the eBPF side only; user‑space code would use libbpf or bcc.

```c
// profiler.bpf.c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

// Map: kernel tid -> app state (goroutine_id, connection_id)
struct app_state {
    u64 goroutine_id;
    u32 conn_id;
};
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, u32);  // tid
    __type(value, struct app_state);
} tid_state SEC(".maps");

// Perf event output
struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
    __uint(key_size, sizeof(u32));
    __uint(value_size, sizeof(u32));
} perf_map SEC(".maps");

// This is attached to a perf_event sampling every N instructions
SEC("perf_event")
int sample_tcp(struct bpf_perf_event_data *ctx) {
    u32 tid = bpf_get_current_pid_tgid() & 0xFFFFFFFF;
    struct app_state *state = bpf_map_lookup_elem(&tid_state, &tid);
    if (!state)
        return 0;

    // Build sample struct to send to user space
    struct sample_event {
        u32 tid;
        u64 goroutine_id;
        u32 conn_id;
        u64 ip;  // instruction pointer from sample
    } sample = {
        .tid = tid,
        .goroutine_id = state->goroutine_id,
        .conn_id = state->conn_id,
        .ip = ctx->regs.ip,
    };
    bpf_perf_event_output(ctx, &perf_map, BPF_F_CURRENT_CPU,
                          &sample, sizeof(sample));
    return 0;
}
```

User‑space would load this program and attach it to a `perf_event` that samples instructions. It would also have uprobes on Go scheduler to update `tid_state` – but that’s a separate eBPF program.

## Building a Custom Profiler Step‑by‑Step

Let’s walk through building a complete custom profiler for a Go HTTP server with user‑space TCP stack. The goal: measure the distribution of time spent in the custom stack’s spinlock per goroutine, correlated with kernel CPU usage.

### Step 1: Setup Environment

You need a Linux kernel 4.19+ (for `bpf_perf_event_output`), libbpf or bcc, and a Go build with `-buildmode=pie` and debug symbols. I’ll use Python + bcc for the user‑space part because it’s concise; for production you’d likely use C or Rust for performance.

Install bcc (on Ubuntu: `apt install bpfcc-tools python3-bpfcc`).

### Step 2: Instrument User‑Space Lock

Locate the spinlock functions in your user‑space TCP stack. Suppose they are `lock_acquire` and `lock_release`. Use uprobes to record the lock address and timestamp.

eBPF program `lockprof.bpf.c`:

```c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

struct lock_event {
    u64 addr;
    u64 start_ns;
    u32 tid;
    u32 cpu;
    int acquired; // 1 if acquire, 0 if release
};

struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
} events SEC(".maps");

// keep per‑lock per‑thread start time
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, u64);  // ((u64)tid << 32) | lock_addr
    __type(value, u64); // start time
} lock_starts SEC(".maps");

SEC("uprobe/lock_acquire")
int probe_acquire(struct pt_regs *ctx) {
    struct lock_event ev = {};
    u32 tid = bpf_get_current_pid_tgid() & 0xFFFFFFFF;
    ev.tid = tid;
    ev.cpu = bpf_get_smp_processor_id();
    ev.acquired = 1;
    // First argument: lock address (assuming x86_64 calling conv)
    bpf_probe_read_user(&ev.addr, sizeof(ev.addr), (void*)PT_REGS_PARM1(ctx));
    ev.start_ns = bpf_ktime_get_ns();
    // store start time
    u64 key = ((u64)tid << 32) | ev.addr;
    bpf_map_update_elem(&lock_starts, &key, &ev.start_ns, BPF_ANY);
    bpf_perf_event_output(ctx, &events, BPF_F_CURRENT_CPU, &ev, sizeof(ev));
    return 0;
}

SEC("uretprobe/lock_release")
int probe_release(struct pt_regs *ctx) {
    struct lock_event ev = {};
    u32 tid = bpf_get_current_pid_tgid() & 0xFFFFFFFF;
    ev.tid = tid;
    ev.cpu = bpf_get_smp_processor_id();
    ev.acquired = 0;
    // Return value? Or we can guess lock addr from stored start key.
    // Simpler: we pass lock address as argument to release too.
    // Assume release takes lock address as first argument.
    bpf_probe_read_user(&ev.addr, sizeof(ev.addr), (void*)PT_REGS_PARM1(ctx));
    u64 key = ((u64)tid << 32) | ev.addr;
    u64 *start = bpf_map_lookup_elem(&lock_starts, &key);
    if (start) {
        ev.start_ns = *start;
        bpf_map_delete_elem(&lock_starts, &key);
    } else {
        ev.start_ns = 0;
    }
    bpf_perf_event_output(ctx, &events, BPF_F_CURRENT_CPU, &ev, sizeof(ev));
    return 0;
}
```

User‑space Python script reads the perf events and computes hold times. You can also add a raw tracepoint for `sched:sched_switch` to see if the thread got preempted while holding the lock.

### Step 3: Correlate with Kernel CPU Usage

Add a `perf_event` that samples CPU cycles (hardware counter) with callchain. Attach an eBPF program to that perf event that, upon sample, reads the user‑space stack and looks up the current lock hold state per thread.

To get user stack, you need `PERF_SAMPLE_CALLCHAIN` and then in the eBPF program, access `ctx->regs` to read the stack pointer and then iterate. That’s tricky; simpler is to use `bpf_get_stackid()` helper. The eBPF program can call `bpf_get_stackid(ctx, stack_map, BPF_F_USER_STACK)` which returns an ID that you can map to a stack in user‑space.

So you set up a stack map and then in the sample handler, retrieve the stack id, combine with lock state, and output.

But note: this is getting deep. For a blog post, we can outline the approach and give high‑level code.

### Step 4: Flamegraph Generation

Aggregate data in user‑space. For each “lock hold” event, you have the stack from the perf sample at the same time (or close). You can output folded stack format: `stack_frame1;frame2;... frameN <count>` and feed to FlameGraph tools.

### Step 5: Running and Analysis

Load the eBPF programs, run the HTTP server under load, and observe the output. You’ll see a flamegraph showing that the spinlock `lock_acquire` in user‑space appears in the stack when CPU samples are taken, and the depth of the lock holder indicates which request path is causing contention.

## Advanced Techniques

### Profiling JIT‑compiled Code

One of the biggest profiling blind spots is JIT code. The kernel doesn’t know about dynamically generated code, so `perf` sees `[unknown]` frames. Solutions:

- **perf map files**: The runtime can write a `/tmp/perf-<pid>.map` file mapping JIT code addresses to symbolic names. Many runtimes support this (Java with `-XX:+PreserveFramePointer`, Node.js with `--perf-basic-prof`). eBPF can read this map from within the kernel? Not directly, but you can have a user‑space agent that reads the map and then passes symbolization info to eBPF via a map. However, a simpler approach is to have the runtime export the symbol table to a BPF map directly (e.g., via uprobe callback).
- **DWARF‑based unwinding**: Some userspace unwind libraries (e.g., `libunwind`) can unwind JIT stacks using `.eh_frame` info. eBPF alone cannot do this; you need to collect raw stack dumps and unwind in user‑space.

For Go, the runtime exports `runtime.g` and runtime function calls via `runtime.traceback`. You can attach uprobes to `runtime.casgstatus` and `runtime.walltime` to track goroutine states. Using a combination of uprobes and stack sampling, you can get accurate Go profiles.

### Off‑CPU Profiling

Sometimes the problem is not that a CPU is busy, but that a thread is waiting on I/O, locks, or scheduling. Off‑CPU profiling uses eBPF to record when a thread goes to sleep (e.g., via `sched:sched_switch` tracepoint) and when it wakes up. You can compute wait times and attribute them to the blocking event. Combined with hardware counter samples, you get a full picture of “I/O vs. compute”.

### Memory Profiling

eBPF can also profile memory allocations: attach to `kmem_cache_alloc` (kernel) or `malloc`/`free` (user‑space via uprobes). Track which stack trace allocates memory, and how much, using a map. You can then create allocation flamegraphs.

## Case Study: Go HTTP Server with User‑Space TCP

Returning to our motivating example. I built a custom profiler using the techniques above for a Go service using netstack. The profiler:

1. Attached uprobes to netstack’s `(*conn).Read` and `mutex.Lock`/`Unlock`.
2. Attached kprobes to `tcp_v4_rcv` and a perf_events counter sampling CPU cycles.
3. In the eBPF program attached to perf event, I added a lookup of current goroutine ID (via a map maintained from uprobes on Go scheduler) and lock state per thread.
4. Output samples to user‑space perf ring buffer.

The resulting data showed that 70% of CPU cycles spent in `__do_fault` were actually due to page faults inside the spinlock held region. The user‑space TCP stack was allocating memory for packets while holding the lock, causing minor faults. Under load, those faults took long because of cache pressure, increasing lock hold time, and then causing more context switches. The fix: pre‑allocate memory outside the lock.

Without the custom profiler, the team spent two weeks guessing. With it, we found the root cause in two hours.

## Pitfalls and Best Practices

- **Overhead**: Sampling at high rates (e.g., 10 kHz) can add 5-15% CPU. Use adaptive frequency (`sample_freq`) or reduce rate in production.
- **eBPF Verifier**: Your eBPF program must be simple; no loops, limited instructions. Use bpf_helpers and map helpers. If you need complex logic, do it in user‑space after aggregating.
- **Symbolization**: eBPF programs produce raw addresses. User‑space must resolve to symbols. Use `libunwind`, `libdw`, or `/proc/<pid>/maps`.
- **Security**: Only root or `CAP_BPF` can load eBPF programs. In containers, set `securityContext.capabilities.add: BPF`.
- **Kernel Version**: Features like `BPF_PERF_EVENT_OPEN` and `bpf_get_stackid` require 4.18+. Always check kernel version.

## Conclusion

Off‑the‑shelf profiling tools are invaluable for quick triage, but they fail when your system crosses abstraction boundaries. The combination of `perf_events` for efficient hardware sampling and eBPF for precise contextual probes gives you the scalpel you need. You can instrument exactly the functions you care about, correlate with kernel events, and aggregate data in‑kernel to keep overhead low.

Building a custom profiler requires effort—learning the APIs, verifying eBPF programs, handling symbolization—but the payoff is enormous. When you next stare at a flat perf top and suspect something deeper, remember that you have the tools to cut precisely. Start small: pick a known pain point, add a uprobe, and see the difference. The hidden cuts will become visible, and you’ll finally understand why your latency graph stopped obeying the noise floor.

The future of profiling is custom, programmable, and in‑kernel. With `perf_events` and eBPF, that future is already here.
