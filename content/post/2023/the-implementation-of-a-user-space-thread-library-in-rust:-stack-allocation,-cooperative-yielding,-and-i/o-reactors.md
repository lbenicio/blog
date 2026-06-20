---
title: "The Implementation Of A User Space Thread Library In Rust: Stack Allocation, Cooperative Yielding, And I/O Reactors"
description: "A comprehensive technical exploration of the implementation of a user space thread library in rust: stack allocation, cooperative yielding, and i/o reactors, covering key concepts, practical implementations, and real-world applications."
date: "2023-03-04"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/the-implementation-of-a-user-space-thread-library-in-rust-stack-allocation-cooperative-yielding-and-io-reactors.png"
coverAlt: "Technical visualization representing the implementation of a user space thread library in rust: stack allocation, cooperative yielding, and i/o reactors"
---

# The Implementation of a User Space Thread Library in Rust: Stack Allocation, Cooperative Yielding, and I/O Reactors

## Introduction

Imagine you’re building a web server that must handle tens of thousands of concurrent connections. Your first instinct might be to create one operating system thread per connection – a classic, straightforward model. But threads are heavyweight: each consumes several megabytes of virtual memory for its stack, imposes kernel-mode scheduling overhead, and forces the OS to context‑switch between them even when work is trivial. At scale, threads become a bottleneck. The alternative – event‑driven, callback‑heavy code – trades thread explosion for complexity and splits your logic across hundreds of state machines. You end up fighting the framework rather than solving your problem.

What if you could have the simplicity of threading without the cost? This is the promise of **user‑space threads** – sometimes called _green threads_, _fibers_, or _coroutines_ – where the runtime manages context switching and scheduling entirely in user mode. The most famous example is Go’s goroutines: lightweight, stackful, and cooperatively scheduled. They let programmers write synchronous‑looking code that scales to millions of concurrent tasks. But Go gives you this as part of the language. What if you want the same power in Rust, where you control every allocation and every safety guarantee? You’d need to build it yourself.

That’s precisely what this post is about. We’ll walk through the design and implementation of a minimal user-space thread library in Rust, focusing on three critical components: **stack allocation** (how to set up and guard memory for each thread), **cooperative yielding** (how to switch between threads efficiently), and **I/O reactors** (how to integrate asynchronous I/O without blocking the entire runtime). Along the way, we’ll confront the challenges that make this non‑trivial: memory protection, platform‑specific context switch, safe resource management, and the delicate interplay between blocking and non‑blocking operations.

By the end, you will have a deep understanding of the engineering behind user‑space threading, and you will be able to apply these concepts in your own Rust projects – whether you are building a custom runtime, contributing to an existing one, or simply satisfying your curiosity about how the sausage is made.

## Background: Why Not Just Use OS Threads?

Before diving into implementation, it’s worth understanding the cost of OS threads in more detail. When you create a thread with `std::thread::spawn`, the operating system allocates a stack – typically 2 MiB to 8 MiB (and often a guard page). Multiply that by 10 000 connections, and you are looking at 20 GB of virtual memory just for stacks. Even if you never fault those pages, the virtual address space is consumed, and the kernel’s scheduler has to manage that many entities. Context switching between OS threads is expensive because it involves a trap into kernel mode, saving and restoring privileged state, and flushing TLB entries. Benchmarks show that a system call for a simple thread yield can cost several microseconds – far too much for high‑concurrency workloads.

User‑space threads avoid these costs. Stacks can be as small as a few kilobytes (if we trust the application not to overflow), context switches happen in a few nanoseconds by simply swapping registers, and all scheduling logic runs in user mode without kernel interaction. The catch is that we must implement everything ourselves: allocating stacks, performing context switches, and managing I/O without blocking the entire runtime. But Rust’s strong type system and zero‑cost abstractions make it an ideal language for this task – we can build safe abstractions on top of unsafe building blocks.

## Stack Allocation

### Why Custom Stacks?

A thread in user space needs its own call stack – a contiguous region of memory where function calls push frames. Unlike OS threads, we are not tied to the fixed per‑thread stack provided by the kernel. We can allocate stacks manually, control their size, and add protection against stack overflows. This flexibility is key to achieving low memory overhead.

### Raw Memory Allocation with `mmap`

On Unix systems, the typical way to allocate a stack is via `mmap`. We request a private anonymous mapping with `MAP_ANONYMOUS | MAP_PRIVATE`. The size can be chosen per thread – say 64 KiB for the stack itself plus a guard page. `mmap` gives us page‑aligned memory, which is necessary for setting protection bits. Here is a minimal function to create a stack:

```rust
use std::io;

#[cfg(target_os = "linux")]
unsafe fn create_stack(size: usize) -> io::Result<(usize, *mut u8)> {
    use libc::mmap;
    use libc::PROT_READ | PROT_WRITE;
    use libc::MAP_PRIVATE | MAP_ANONYMOUS;

    let addr = mmap(
        std::ptr::null_mut(),
        size,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS,
        -1,
        0,
    );
    if addr == libc::MAP_FAILED {
        return Err(io::Error::last_os_error());
    }
    // The returned pointer is the base of the mapping.
    // We'll use the top as the initial stack pointer.
    let top = (addr as usize) + size;
    Ok((addr as usize, top as *mut u8))
}
```

The stack grows downward on most architectures: the stack pointer starts at the high address and decreases as frames are pushed. Therefore, we store the top address (base + size) as the initial stack pointer.

### Guard Pages

A critical safety feature is the guard page – an inaccessible page at the bottom of the stack that triggers a segfault if the thread overflows. Without it, a stack overflow could silently corrupt adjacent memory. We can set the guard page after allocation using `mprotect`:

```rust
unsafe fn add_guard_page(stack_base: usize, guard_size: usize) -> io::Result<()> {
    // guard_size should be a multiple of page size (typically 4096)
    let result = libc::mprotect(
        stack_base as *mut libc::c_void,
        guard_size,
        libc::PROT_NONE,
    );
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
```

Now, if the thread’s stack pointer falls into the guard page, the CPU will raise a segmentation fault. We must then handle that fault. However, handling SIGSEGV in a multi‑threaded coroutine environment is tricky because the signal is delivered to the thread that caused the fault. One approach is to install a signal handler that uses `sigaltstack` to switch to an alternate stack, so the handler can run safely even if the main stack is corrupted. In our library, we can set up an alternate stack at initialization:

```rust
use libc::{SIGSTKSZ, sigaltstack, stack_t};

unsafe fn setup_alt_stack() -> io::Result<()> {
    let alt_stack = mmap(
        std::ptr::null_mut(),
        SIGSTKSZ,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS,
        -1,
        0,
    );
    if alt_stack == libc::MAP_FAILED {
        return Err(io::Error::last_os_error());
    }
    let stack = stack_t {
        ss_sp: alt_stack,
        ss_flags: 0,
        ss_size: SIGSTKSZ,
    };
    if sigaltstack(&stack, std::ptr::null_mut()) != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
```

Then in the SIGSEGV handler, we can print a stack trace and abort. For simplicity, many toy runtimes skip this and rely on the default crash, but production‑grade runtimes like Go handle this gracefully.

### Stack Growth Strategies

Fixed‑sized stacks are simple but risk overflow if a deep recursion occurs. Some runtimes implement **segmented stacks** (like old Go) or **split stacks** (like Rust’s own `#[unsafe_destructor]`). Segmented stacks allow the stack to grow by allocating extra chunks and linking them, but this adds complexity and slows down function prologues. For our minimal library, we stick to a generous fixed size (e.g., 256 KiB) and rely on the guard page to detect overflows. The user must be aware of stack depth – cooperative threads can always switch to a hand‑rolled stack‑less state machine if needed.

### Alignment Constraints

The x86‑64 ABI requires the stack pointer to be 16‑byte aligned before a `call` instruction. When we set the initial stack pointer, we must ensure it is aligned correctly. The top of the mapping is naturally aligned if the mapping size is a multiple of 16. But we also need to push an initial frame (the return address) and possibly fake a call frame for the entry function. Typically we set `rsp` to `top - 8` (simulating a call) and then align it further if needed. The exact method depends on the context switch implementation.

## Cooperative Yielding and Context Switching

### What Is a Context?

A thread’s execution context consists of the CPU registers (general‑purpose, stack pointer, instruction pointer, flags), the FPU/SSE state (if used), and any platform‑specific state. For a minimal user‑space thread, we only need to save and restore the registers that the caller‑saves conventions require. In the System V AMD64 ABI, the registers that _must_ be preserved across function calls are: `rbx`, `rbp`, `r12`–`r15`, and `rsp`. The other registers (`rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`–`r11`, `xmm0`–`xmm15`) can be freely clobbered by the callee. However, because our context switch is a function that deliberately transfers control to another thread, we need to save all registers that are in use at the point of yield. In practice, we save all callee‑saved registers (including the return address which is pushed on the stack by the `call` instruction). The instruction pointer is implicitly saved as the return address on the stack. Our `switch` function will:

1. Save the current thread’s `rsp` and all callee‑saved registers into a context structure.
2. Load the new thread’s `rsp` and registers from its context structure.
3. Return to the new thread’s execution point (by popping its return address).

This is essentially a coroutine switch.

### Writing the Context Switch in Inline Assembly

Rust offers the `asm!` macro for inline assembly, but we still need to be careful about register clobbers and correct calling conventions. We define a function `switch` that takes two mutable references to `Context` structs (current and next) and performs the swap. The `Context` struct holds the saved registers:

```rust
#[repr(C)]
struct Context {
    rsp: usize,
    rbp: usize,
    rbx: usize,
    r12: usize,
    r13: usize,
    r14: usize,
    r15: usize,
}
```

The switch function in assembly (x86‑64, AT&T syntax) might look like:

```rust
#[cfg(target_arch = "x86_64")]
unsafe fn switch(current: &mut Context, next: &Context) {
    asm!(
        // Save current registers
        "mov %rsp, {cur_rsp}",
        "mov %rbp, {cur_rbp}",
        "mov %rbx, {cur_rbx}",
        "mov %r12, {cur_r12}",
        "mov %r13, {cur_r13}",
        "mov %r14, {cur_r14}",
        "mov %r15, {cur_r15}",
        // Load next registers
        "mov {next_rsp}, %rsp",
        "mov {next_rbp}, %rbp",
        "mov {next_rbx}, %rbx",
        "mov {next_r12}, %r12",
        "mov {next_r13}, %r13",
        "mov {next_r14}, %r14",
        "mov {next_r15}, %r15",
        // Return to next thread
        "ret",
        cur_rsp = out(reg) current.rsp,
        cur_rbp = out(reg) current.rbp,
        cur_rbx = out(reg) current.rbx,
        cur_r12 = out(reg) current.r12,
        cur_r13 = out(reg) current.r13,
        cur_r14 = out(reg) current.r14,
        cur_r15 = out(reg) current.r15,
        next_rsp = in(reg) next.rsp,
        next_rbp = in(reg) next.rbp,
        next_rbx = in(reg) next.rbx,
        next_r12 = in(reg) next.r12,
        next_r13 = in(reg) next.r13,
        next_r14 = in(reg) next.r14,
        next_r15 = in(reg) next.r15,
        options(noreturn, nostack)
    );
}
```

There are subtle issues: the `ret` instruction relies on the stack having the return address of the new thread. When we initially create a thread, we must set its stack so that a `ret` would jump to the thread’s entry function. That means we push a fake return address on the stack. Additionally, we need to ensure the stack pointer is correctly aligned when `ret` is executed (16‑byte alignment at the call site). The above template assumes the new thread’s `rsp` already points to a valid return address.

### Initializing a Thread’s Context

When we spawn a new user‑space thread, we allocate its stack, then set up the initial context as follows:

- Choose a small function that the thread will start executing. Usually a wrapper: `thread_entry`.
- Allocate space on the stack for the context structure (or just set the registers directly via the stack).
- Push a “return address” that points to `thread_entry`.
- Set `rsp` to the address of that return address minus 8 (since we push it).
- Set `rbp` to 0 (to mark the bottom of the stack chain).
- Set other callee‑saved registers to 0 (they don’t matter initially).

A realistic implementation might use a helper function that is called from the context switch. When the scheduler switches to this new thread for the first time, it will `ret` into `thread_entry`. That function then calls the user’s closure. When the closure finishes, `thread_entry` marks the thread as dead and yields back to the scheduler.

Example `thread_entry`:

```rust
unsafe extern "C" fn thread_entry() {
    // The scheduler placed a pointer to the thread object somewhere
    // (maybe in a register before switch, or at a known location).
    // For simplicity, assume we have a Thread struct pointer in %r12.
    // But we can also store it in a static/thread-local variable.
    // After the closure completes, we call scheduler::exit_current_thread().
}
```

### The Scheduler and Yielding

The scheduler maintains a queue of ready threads. The `yield` function calls the scheduler’s `switch_to_next` which picks the next thread from the queue and performs the context switch. Here is a simplified scheduler:

```rust
struct Scheduler {
    threads: VecDeque<Thread>,
    current: Option<usize>, // index or pointer
}

impl Scheduler {
    fn switch_to_next(&mut self) {
        // Save current thread's context.
        // Push it back to queue if still ready.
        // Pop next thread from queue.
        // Restore its context (which will `ret` into its execution).
    }
}
```

The tricky part is that during the context switch, the scheduler’s own stack is being used, but we must ensure that the scheduler does not use the stack of the thread being switched away from. Typically, the scheduler runs on a dedicated “scheduler stack” or at least uses a small temporary stack (e.g., via `alloca`). However, for simplicity, many implementations let the scheduler run on the stack of whichever thread called `yield`. That works because we save the thread’s stack pointer in its context, so when we restore another thread, the scheduler’s stack frames (which live on the original thread’s stack) are no longer in use. The scheduler’s local variables are still on the old stack, but if the old thread is never resumed, that memory is lost. The proper way is to have the scheduler perform the switch on a separate global stack, but that adds complexity.

In practice, you can keep the scheduler’s state in static variables and use a small inline function that does the context switch, ensuring that the compiler does not allocate large temporaries on the stack. For a production runtime, this design is critical.

## I/O Reactors

### The Problem: Blocking in User‑Space Threads

A user‑space thread is just a stack and register set. If it calls a blocking system call (e.g., `read` on a socket that has no data), the entire OS thread hosting the user‑space runtime blocks. That stops all other user‑space threads from running. To avoid that, we must never block in the kernel. Instead, we use non‑blocking I/O and integrate with an event loop (reactor) that can wake up the calling thread when the I/O is ready.

### Epoll / kqueue Integration

On Linux, the standard mechanism is `epoll`. We create an epoll file descriptor, register all sockets we care about, and then in the scheduler loop, we poll epoll for events. When data arrives, we mark the corresponding user‑space thread as ready and add it to the scheduler queue.

But we also need a way to wake the scheduler when a thread voluntarily yields. Otherwise, the scheduler might block on `epoll_wait` forever while threads are ready. A common trick is to use an `eventfd` (or a pipe) that the scheduler includes in the epoll set. When a thread calls `yield`, it writes to the `eventfd`, waking the scheduler from `epoll_wait`. The scheduler then processes the new ready thread.

### Design of a Reactor

A reactor typically runs in a dedicated OS thread (or in the main scheduler loop) and performs the following:

1. Maintains a mapping from file descriptor to the user‑space thread that is waiting on it.
2. Exposes an `await_read(fd)` or `await_write(fd)` function that registers the current thread with the reactor, marks it as blocked, and yields.
3. When the reactor detects an event (via epoll), it looks up the thread associated with the fd and moves it to the ready queue.

The reactor can be integrated directly into the scheduler. Many coroutine libraries are structured as a single OS thread running an event loop that alternates between executing coroutines and checking for I/O events. This is similar to how `tokio` works at its core (though tokio uses `mio` and a state machine rather than stackful coroutines).

### Example: Async Read

Here is a simplified abstraction:

```rust
struct Reactor {
    epoll_fd: RawFd,
    waiting: HashMap<RawFd, ThreadId>,
    wake_event: EventFd,
}

impl Reactor {
    fn await_read(&mut self, fd: RawFd) {
        let current = scheduler::current_thread_id();
        self.waiting.insert(fd, current);
        // Register fd with epoll for readable events
        // Then yield back to scheduler
        scheduler::yield();
        // When we resume, fd is ready or timeout, we can read without blocking
    }
}
```

To make this safe, we need to ensure that the reactor does not hold references to thread objects that might be moved or deallocated. Using thread IDs or weak references is safer.

### Integrating with the Scheduler

The scheduler loop can look like this pseudocode:

```rust
loop {
    // Check for I/O events with a short timeout (e.g., 1ms) or infinite (if no threads ready).
    let events = epoll_wait(epoll_fd, timeout);
    for event in events {
        if event.fd == wake_event {
            // Drain the wakeup buffer
        } else if let Some(thread_id) = waiting.remove(event.fd) {
            // Move thread to ready queue
        }
    }
    // If ready queue is not empty, switch to next thread.
    if let Some(next) = ready_queue.pop_front() {
        switch_to(next);
    } else {
        // Epoll_wait with no timeout (since no threads are ready)
        // But we need to be able to wake if a thread becomes ready via yield.
        // So we use eventfd to break out of epoll_wait.
    }
}
```

The reactor is the heart of concurrency. It allows the runtime to handle thousands of connections without ever blocking the OS thread.

## Putting It All Together: A Minimal Echo Server

Let’s sketch a complete example that ties together stack allocation, context switching, and reactor I/O. We’ll write a simple echo server that accepts connections and echoes back data.

```rust
// Assume we have a runtime struct that includes scheduler and reactor.
fn main() {
    let mut runtime = Runtime::new();

    // Spawn a listener coroutine
    runtime.spawn(|| {
        let listener = TcpListener::bind("127.0.0.1:8080").unwrap();
        listener.set_nonblocking(true).unwrap();

        let reactor = runtime.reactor();

        loop {
            // Non-blocking accept using reactor
            match reactor.accept(&listener) {
                Ok((stream, addr)) => {
                    // Spawn a new coroutine to handle this connection
                    runtime.spawn(move || {
                        handle_client(stream, reactor);
                    });
                }
                Err(e) if e.kind() == WouldBlock => {
                    // reactor.accept already yields, so we just continue
                }
                Err(e) => panic!("accept error: {}", e),
            }
        }
    });

    runtime.run(); // Starts scheduler loop
}

fn handle_client(stream: TcpStream, reactor: &Reactor) {
    let mut buf = [0u8; 1024];
    loop {
        // reactor.read will yield if no data
        let n = reactor.read(&mut buf, &stream).unwrap();
        if n == 0 {
            break; // connection closed
        }
        reactor.write_all(&buf[..n], &stream).unwrap();
    }
}
```

This looks synchronous but under the hood, `reactor.read` and `reactor.accept` use non‑blocking I/O and yield the current coroutine if the operation would block. The runtime switches to other coroutines while waiting. This is the same model that Go’s netpoller provides.

## Challenges and Safety Considerations

### Stack Overflow Detection

We mentioned guard pages, but they only work if we catch the SIGSEGV. In a library setting, installing a signal handler may conflict with the user’s own handler. A more robust approach is to use `mmap` with `MAP_GROWSDOWN` on Linux, which automatically extends the stack downwards as needed (but this only works for the main thread’s stack, not for mmaped regions). For user‑space threads, we are on our own. Some runtimes allocate stacks with a red zone and check stack usage in the prologue, but that incurs overhead. For a minimal library, we choose to trust the user.

### Memory Safety in Unsafe Code

Context switching involves raw pointer manipulation and assembly. It is extremely unsafe. We must ensure that no mutable references to a thread’s stack are held while the thread is running (since it’s being mutated). The `Context` struct lives on the heap or in a static, and we must guarantee that its memory is valid for as long as any thread refers to it. Deallocating a thread’s stack while another thread might be resumed on it would cause undefined behavior. We need to carefully manage lifetimes – usually by never deallocating until the thread has finished and all references to it are gone.

### Panic Handling

If a user‑space thread panics, we must handle it gracefully: catch the unwind, clean up resources (deallocate the stack, wake any waiting threads), and continue. Rust’s `catch_unwind` can be used inside the thread entry wrapper. However, if the panic is caused by a stack overflow (guard page hit), the standard unwinding mechanisms may fail because the stack is corrupted. In that case, abort is the only safe option.

### Portability

The context switch code is platform‑specific. We have discussed x86‑64, but ARM, AArch64, RISC‑V, and others have different calling conventions and register sets. Writing portable user‑space threads requires `cfg` attributes for each architecture. The stack allocation also differs on Windows (using `VirtualAlloc` instead of `mmap`). A production library would need to abstract these details.

## Performance Considerations

Context switches in user space are orders of magnitude faster than kernel‑level thread switches. Benchmarks show that a minimal yield (save/restore registers) takes about 10–20 nanoseconds, whereas an OS thread yield (via `sched_yield` or futex) takes a few microseconds. However, there is a cost: calling the scheduler and managing the ready queue adds some overhead. For CPU‑bound tasks, the scheduler can become a bottleneck. Many runtimes use work stealing (like Tokio’s multi‑threaded runtime) to distribute work across multiple OS threads, each running its own scheduler.

### Cache Locality

User‑space threads that share data heavily can benefit from running on the same CPU cache. With a single OS thread, all coroutines share the L1 cache, which is excellent. But if you run multiple OS threads, you need to be careful about false sharing.

### Memory Overhead

If each coroutine uses a 64 KiB stack and we have 10 000 coroutines, that’s 640 MiB of virtual memory. With guard pages and alignment, the actual RSS may be lower because pages are only faulted when used. However, 10 000 coroutines each with 64 KiB stack is still more memory than 10 000 OS threads (which use 8 MiB each). The advantage is that we can support far more concurrent tasks than OS threads.

### Comparison to Async/Await

Rust’s native async/await model (with futures) uses stackless coroutines: the state is captured in a single struct generated by the compiler, and the stack is not preserved across yield points. This is extremely efficient (no per‑yield stack allocation), but it requires all blocking operations to be wrapped in `poll` methods and re‑executed. Writing complex recursive algorithms in async code can be painful. Stackful coroutines, on the other hand, let you write ordinary synchronous code. The trade‑off is stack size and context switch overhead. Our library is stackful; for many applications the extra overhead is negligible.

## Advanced Topics and Future Directions

### Work Stealing Scheduler

A single OS thread cannot exploit multiple cores. A multi‑threaded runtime can have one scheduler per CPU core, each with its own ready queue. If one scheduler runs out of work, it steals tasks from another’s queue. This is how Tokio and Go’s runtime scale. Implementing work stealing requires careful atomic operations. Our minimal library can be extended to support multiple OS threads by having the scheduler loop run in each OS thread and coordinating via shared queues.

### Integration with Existing Async Runtimes

Why build your own when you can use Tokio? Because sometimes you need control, or you want to blend stackful coroutines with async I/O. It is possible to write a runtime that presents a future‑based interface but internally uses stackful coroutines – akin to what the `may` crate does. Alternatively, you can implement a reactor that implements the `AsyncRead` and `AsyncWrite` traits from the `futures` crate, allowing your coroutines to interoperate with Tokio’s ecosystem.

### Debugging and Profiling

User‑space threads are invisible to the debugger. Tools like `gdb` and `perf` see only the OS thread. Debugging a coroutine that has been suspended is hard because its stack is not on the call chain. Some runtimes implement “thread local” storage to help, but it remains an area of active research. For Rust, you can use `backtrace` crate to capture a stack trace at the point of yield, but that only works if the coroutine is currently running.

## Conclusion

We have journeyed through the construction of a user‑space thread library in Rust, confronting three fundamental components: stack allocation with guard pages, low‑level context switching via inline assembly, and I/O reactor integration. Along the way we encountered the unsafety that lies at the heart of all runtime systems, and we saw how Rust’s abstractions can tame it – if carefully applied.

Building your own user‑space threads is an illuminating exercise: it demystifies how languages like Go achieve massive concurrency, and it gives you a deep appreciation for the challenges that runtime authors face. While you would rarely need to reinvent this wheel, understanding these internals makes you a better systems programmer. You can contribute to existing runtimes, diagnose performance issues, and design systems that truly scale.

If you are interested in production‑ready implementations, check out the `tokio` ecosystem for async Rust, or the `may` crate for stackful coroutines. For a deeper dive, read the source code of Go’s runtime or the Linux kernel’s `swapcontext` implementation. And if you decide to build your own, may your stacks be guarded and your context switches swift.

---

_This blog post was written as an educational deep‑dive. The code snippets are illustrative and not production‑ready. Always consult the documentation for `unsafe` and inline assembly usage._
