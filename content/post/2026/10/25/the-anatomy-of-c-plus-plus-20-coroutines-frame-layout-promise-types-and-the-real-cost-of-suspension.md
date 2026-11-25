---
title: "The Anatomy of C++20 Coroutines: Frame Layout, Promise Types, and the Real Cost of Suspension"
description: "A systems-level tour of how the compiler lowers co_await, co_yield, and co_return into a heap-allocated state machine: the coroutine frame, the promise protocol, the ramp/resume/destroy triple, and what a suspension actually costs."
date: "2026-10-25"
author: "Leonardo Benicio"
tags: ["c++","coroutines","compilers","concurrency","abi","systems-programming"]
categories: ["Computer Science","Software Engineering"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/the-anatomy-of-c-plus-plus-20-coroutines-frame-layout-promise-types-and-the-real-cost-of-suspension-2026-10-25.jpg"
coverAlt: "Isometric technical illustration of a glowing translucent slab representing a heap-allocated coroutine frame with internal compartments, connected by curved cyan arcs to two small square nodes representing a caller and a resumer, floating above a thin stack of translucent plates that represents a conventional call stack, all on a dark navy grid background."
---

# The Anatomy of C++20 Coroutines: Frame Layout, Promise Types, and the Real Cost of Suspension

## Two Families of Coroutines

Every coroutine implementation answers one question first: where does the suspended state live?

The stackful answer is a separate stack. A stackful coroutine is a thread-like object with its own stack segment — typically 4 KiB at the small end, 64 KiB to 1 MiB at the comfortable end — plus a saved register file. Suspending means switching the stack pointer and the callee-saved registers; resuming means switching back. Because the coroutine has a stack of its own, *any* function on that stack can suspend, no matter how deep in the call tree it sits. That property is what makes stackful designs pleasant: `read(fd, buf, n)` can block the coroutine without infecting every caller with a new type signature. Go's goroutines, Java's virtual threads, and fibers in Boost.Context all live in this family.

The stackless answer is a compiler-generated state machine. There is no separate stack. Suspension means returning to the caller, and the compiler has transformed the function so that a later call can jump back to the point where it left off. The suspended state — the subset of locals that must survive the suspension — is stored in a heap-allocated *coroutine frame*. C++20 coroutines, Rust `async fn`, JavaScript generators, and Python's `async def` are all stackless.

The trade-offs are sharp and worth stating explicitly, because the rest of this article is about the price paid for the stackless choice.

**Memory per suspended computation.** A stackful coroutine pays a full stack even if it only needs a few dozen live bytes at a suspension point. A stackless coroutine pays exactly the frame the compiler computed — the promise, the parameters, and the locals and temporaries that live across a suspension point. That is often a few hundred bytes. If a design needs millions of concurrent suspended operations, this difference is decisive.

**Suspension depth.** A stackful coroutine can suspend from anywhere. A stackless coroutine can only suspend at points the compiler can see, and only if the caller's code is prepared to receive the suspension. This is the origin of *function coloring*: in Rust, `async fn` can only be awaited from another `async fn`; in C++, `co_await` can only appear inside a coroutine. The color propagates up the call graph, and every boundary where colored code meets uncolored code needs an adapter.

**Resumption cost.** A stackful switch is a handful of instructions but touches a different stack region, which is usually cold in cache. A stackless resume is an indirect call into a generated function that must reload spilled state from the frame — also cold in cache. Neither is free; both are dominated by memory latency rather than by instruction count.

One thing C++20 deliberately does *not* provide is a scheduler. There is no executor, no thread pool, no `spawn`. The language provides exactly one mechanism — a function can suspend itself and be resumed later by anyone holding a handle — and pushes all policy into library code. That decision is why the **promise type** is the center of gravity for the whole feature, and why two C++20 coroutine libraries can share the syntax and share nothing else.

## The Language-Level Contract

A function is a coroutine if its body contains `co_await`, `co_yield`, or `co_return`. No attribute, no keyword on the declaration: the presence of one of those three expressions inside the body is the entire trigger. This means a function's coroutine-ness is invisible at its declaration site, which is a persistent source of surprise during code review and a persistent source of work for tooling.

The standard imposes a set of restrictions that follow from the lowering. A coroutine cannot be a constructor, a destructor, or `main`. It cannot be `constexpr` or `consteval`. Its return type cannot be deduced with `auto`, because the promise type is looked up *from the return type* and that lookup must happen before the body is analyzed. And `co_await` cannot appear in a default argument, in the initializer of a static or thread-local variable, or inside a handler — that last restriction exists because a `catch` block's control flow does not fit the frame's resume-index model.

The return type determines the promise type. The compiler looks up `std::coroutine_traits<R, Args...>::promise_type`, and the primary template defaults to `R::promise_type`. That default is why the common pattern is a nested `promise_type` inside the task or generator class. Specializing `coroutine_traits` is how you make an existing return type — one you do not own, such as `std::future` — work as a coroutine return type without touching it.

The promise object is the coroutine's control surface. The compiler calls into it at fixed points, and the set of members it may call is small enough to enumerate:

- `get_return_object()` — called once, on the ramp path, to produce the value the caller receives.
- `initial_suspend()` — returns an awaitable; if it suspends, the coroutine is lazy and the body does not run until someone resumes it.
- `final_suspend() noexcept` — returns an awaitable; controls what happens when the body finishes.
- `return_value(v)` or `return_void()` — exactly one of these must exist. `co_return v;` calls the former; `co_return;` and falling off the end of the body call the latter. Having both is ill-formed; having neither is ill-formed if the body can reach `co_return`.
- `unhandled_exception()` — called if an exception escapes the body.
- `yield_value(v)` — called by `co_yield v;`, which is defined to be exactly `co_await promise.yield_value(v)`.
- `await_transform(e)` — an optional hook that intercepts every `co_await e` in the body.

That last one deserves emphasis because it is the most powerful and most underused member. If the promise defines `await_transform`, the compiler rewrites `co_await e` into `co_await promise.await_transform(e)` before doing anything else. A library can therefore accept `co_await std::chrono::seconds{1}` without any `operator co_await` on `std::chrono::seconds`, and can equally *reject* awaits it does not want by deleting the overload. It is also how some libraries implement structured cancellation: the transform wraps the awaiter so that a cancelled scope never reaches `await_suspend`.

## The Lowering: Ramp, Resume, Destroy

The compiler turns one coroutine into three functions plus one heap object.

The **ramp** function keeps the coroutine's original name and signature. This is what the caller actually invokes. It allocates the frame, copies the parameters into it, constructs the promise, calls `get_return_object()`, awaits `initial_suspend()`, and — if the coroutine did not suspend there — jumps into the body. If it did suspend, the ramp returns the return object immediately and the body has not executed a single statement.

The **resume** function is the state machine. It is entered with a pointer to the frame, reads the resume index from the frame, and jumps to the code for the corresponding suspension point. Everything after that point runs until the next suspension or until the body finishes.

The **destroy** function tears the frame down. It needs the resume index too, because destruction must run the destructors for exactly those locals that were in scope at the point where the coroutine is parked. A coroutine destroyed while suspended inside a loop must run the destructors of that iteration's locals and no others. This is why the resume index is not merely a jump target: it encodes lexical scope state.

The **frame** holds the promise, the parameters, the locals and temporaries that live across a suspension point, and the resume index. Its layout is implementation-defined, but on the platforms that use the Itanium C++ ABI — Clang and GCC on Linux and macOS — the layout is roughly: a pointer to the resume function, a pointer to the destroy function, the resume index, then the promise, then the copied parameters, then the suspension-spanning locals. The frame pointer is the address of the first field, and `coroutine_handle<Promise>::promise()` is a fixed-offset pointer computation from that address. The promise is not found by a lookup; it is found by adding a compile-time constant.

Two consequences of this design are worth internalizing.

First, the frame contains only what must survive a suspension. A local that is created and destroyed between two suspension points never enters the frame; it lives in the resume function's own stack frame like any other local. The frame size is therefore a function of the *suspension structure* of the coroutine, not of its total local-variable count. Moving a variable so that it does not cross a suspension point can shrink the frame.

Second, parameters are copied by value into the frame. A parameter declared `std::string s` is copied or moved into the frame at ramp time and lives there for the coroutine's lifetime. A parameter declared `const std::string& s` is stored as a reference — a pointer — and the coroutine will dereference it after resuming. If the referent was a temporary in the caller's expression, the coroutine holds a dangling reference from the moment the ramp returns. For a lazy coroutine that is suspended at `initial_suspend`, this is not a subtle race; it is an immediate use-after-free on the first resume. The same reasoning applies to `this` in a member coroutine: the object is not copied, only the pointer is stored, so the object must outlive the coroutine.

## The Promise Type in Practice

A minimal task type makes the protocol concrete. The following skeleton omits the awaiter and the handle management, which are the subject of the next section, but shows the promise surface.

```cpp
template <class T>
class task {
public:
  struct promise_type {
    std::variant<std::monostate, T, std::exception_ptr> result;
    std::coroutine_handle<> continuation{};

    task get_return_object() {
      return task{std::coroutine_handle<promise_type>::from_promise(*this)};
    }
    std::suspend_always initial_suspend() noexcept { return {}; }

    struct final_awaiter {
      bool await_ready() noexcept { return false; }
      std::coroutine_handle<>
      await_suspend(std::coroutine_handle<promise_type> h) noexcept {
        auto c = h.promise().continuation;
        return c ? c : std::noop_coroutine();
      }
      void await_resume() noexcept {}
    };
    final_awaiter final_suspend() noexcept { return {}; }

    void return_value(T v) { result.template emplace<1>(std::move(v)); }
    void unhandled_exception() {
      result.template emplace<2>(std::current_exception());
    }
  };
  // ...
private:
  std::coroutine_handle<promise_type> h_;
};
```

Three decisions in that snippet are load-bearing.

`initial_suspend` returns `std::suspend_always`, making the task lazy. The body does not run until someone awaits the task. Eager coroutines — where `initial_suspend` returns `std::suspend_never` — start executing inside the ramp, before the caller has received the return object. That is occasionally what you want for a fire-and-forget job, but it makes the return object's lifetime subtle: the coroutine may already have finished, and possibly already destroyed its own frame, by the time the ramp returns.

`final_suspend` returns an awaitable that never reports `await_ready() == true`, so the coroutine parks at its final suspend point instead of running off the end. Parking is what keeps the frame alive long enough for the awaiting coroutine to read `result`. If `final_suspend` returned `std::suspend_never`, the frame would be destroyed automatically as the body completes, and any handle the awaiter holds would dangle. Almost every task type parks at the end and lets the awaiter call `destroy()` explicitly.

`unhandled_exception` stores the exception rather than rethrowing. Rethrowing from `unhandled_exception` is legal but calls `std::terminate` if it escapes, so storing an `exception_ptr` and rethrowing it in `await_resume` is the usual pattern. Note that `unhandled_exception` is called *before* `final_suspend`, so the parked frame always carries a fully-formed result — either a value or an exception.

The remaining piece is the awaiter protocol: what `await_ready`, `await_suspend`, and `await_resume` do, why `await_suspend` has three permitted return types, and how symmetric transfer avoids the stack growth that naive resumption would cause. That is where the frame layout and the promise type meet the executor, and where most of the real cost of suspension lives.

## The Awaiter Protocol

The promise type defines the coroutine's control surface, but the awaiter defines the behavior of a single `co_await` expression. When the compiler sees `co_await e` inside a coroutine body, it performs a fixed sequence of rewrites. First, if the promise has an `await_transform` member, `e` is replaced by `promise.await_transform(e)`. Then, if the resulting type has an `operator co_await`, it is called to produce an awaiter. Otherwise, the expression itself must be an awaiter. An awaiter is any type with three member functions: `await_ready`, `await_suspend`, and `await_resume`. The compiler does not require a base class or a concept; it simply looks up those names.

The protocol is deliberately small, but each of the three functions has subtleties that affect correctness and performance.

### await_ready

`bool await_ready()` is the fast path. The compiler calls it before doing anything else. If it returns `true`, the coroutine does not suspend: `await_resume` is called immediately, and the `co_await` expression evaluates to its result. If it returns `false`, the coroutine is about to suspend, and the compiler proceeds to `await_suspend`.

The purpose of `await_ready` is to avoid the cost of suspension when the awaited operation has already completed. A future that is already satisfied, a mutex that is uncontended, a channel with a buffered value: all of these can report ready and skip the frame spill, the indirect call, and the resumption. This is not just an optimization; it is often required for correctness in lock-free algorithms, where a suspension between a check and an action would introduce a race. An awaiter that cannot answer `await_ready` without blocking must return `false` and do the check inside `await_suspend`, where it can atomically decide whether to suspend.

### await_suspend

`await_suspend` is where the coroutine actually suspends. It is called with a `std::coroutine_handle<>` referring to the current coroutine. The handle is the awaiter's only way to resume the coroutine later. The awaiter typically stores it somewhere — in a wait queue, in a callback, in a completion port — and arranges for `handle.resume()` to be called when the operation completes.

The return type of `await_suspend` is where the protocol gets interesting. There are three permitted forms, and they differ in how control returns to the caller.

**`void`**: The coroutine is considered suspended. Control returns to the caller of `resume()` (or to the resumer, if the coroutine was resumed by another coroutine). The awaiter is responsible for eventually calling `handle.resume()`. This is the simplest form and the one most awaiters use.

**`bool`**: The coroutine suspends if and only if the returned value is `true`. If `false`, the coroutine is resumed immediately, without returning to the caller. This form exists to close a race window. Consider an awaiter that checks a condition in `await_ready` and returns `false`, then checks again in `await_suspend` under a lock. If the condition is now satisfied, returning `false` avoids a suspension that would have to be immediately undone. The compiler generates a branch: on `true`, it returns to the caller; on `false`, it calls `await_resume` and continues. This is cheaper than suspending and resuming, but it still involves the `await_suspend` call and the branch.

**`std::coroutine_handle<>`**: The coroutine suspends, and the returned handle is resumed *instead of* returning to the caller. This is **symmetric transfer**. The compiler generates a tail call to the returned handle's resume function. If the returned handle is `std::noop_coroutine()`, control returns to the caller as usual. Symmetric transfer is the mechanism that prevents stack overflow in chains of coroutines that await each other.

### await_resume

`await_resume` is called when the coroutine is resumed, or immediately after `await_ready` returns `true`. Its return value becomes the value of the `co_await` expression. It may return `void`, in which case the `co_await` expression has no value. It may throw; if it does, the exception propagates out of the `co_await` expression as if it were thrown by the awaited operation.

The awaiter's lifetime is not specified by the standard beyond the fact that it must be alive during the calls to the three functions. The compiler typically stores the awaiter in the coroutine frame if it must survive a suspension, or on the resume function's stack if it does not. This is another place where the frame layout and the awaiter protocol interact: an awaiter with a large state that crosses a suspension point will enlarge the frame.

### Symmetric Transfer

Symmetric transfer deserves a closer look because it is the answer to a problem that naive coroutine resumption creates. Suppose coroutine A awaits coroutine B. When B completes, it needs to resume A. If B's `final_suspend` awaiter simply calls `A_handle.resume()` from within B's resume function, the call stack grows: A's resume function called B's resume function, which called A's resume function again. In a deep chain of awaits — a recursive task, a pipeline of stages — this can exhaust the stack.

Symmetric transfer avoids this by making the resumption a tail call. When `await_suspend` returns a handle, the compiler does not return to the caller; it jumps to the handle's resume function. The current coroutine's resume function is not on the stack when the next one starts. In B's `final_suspend`, the awaiter's `await_suspend` returns A's handle. The compiler tail-calls A's resume function, and B's frame is left parked. The stack does not grow.

The tail call is not guaranteed by the standard to be a tail call in the assembly, but the design of the protocol makes it possible, and implementations do emit it. This is why `final_suspend` awaiters in task types return `std::coroutine_handle<>` rather than calling `resume()` directly. The difference between `c.resume(); return;` and `return c;` is the difference between a stack overflow and a constant-depth resume chain.

`std::noop_coroutine()` is the handle to return when there is no continuation. It is a coroutine handle whose resume function does nothing and returns. Returning it from `await_suspend` is equivalent to returning `void` in terms of control flow, but it keeps the tail-call shape uniform.

---

## Frame Allocation and the Cost of Suspension

The frame is the coroutine's heap-allocated state. The ramp function allocates it before copying parameters and constructing the promise. The allocation is performed by `operator new` — specifically, the compiler looks for an `operator new` in the promise type, then in `std::coroutine_traits`, then falls back to the global `operator new`. The size passed is the frame size computed by the compiler. The corresponding `operator delete` is looked up in the same order and called by the destroy function.

This allocation is the most visible cost of a coroutine, and it is the one most often cited as the reason C++20 coroutines are 'slow.' The reality is more nuanced. The allocation can be elided entirely, and even when it is not, it is only one part of the suspension cost.

### Heap Allocation Elision

The standard permits the compiler to elide the frame allocation if it can prove that the coroutine's frame does not outlive the caller's frame. This optimization is called **Heap Allocation Elision** (HALO), though the name is a backronym: it was coined to contrast with the allocation it removes. When HALO applies, the frame is placed on the caller's stack, and the coroutine becomes as cheap as a regular function call — no heap allocation, no lock, no allocator metadata.

HALO is not guaranteed. It requires the compiler to prove that the coroutine handle never escapes the caller's scope, that the coroutine is fully inlined, and that the coroutine's lifetime is strictly nested within the caller's. In practice, this is rare for coroutines that are stored in task objects, passed to executors, or resumed by I/O completions. It is more common for simple generators that are consumed in a loop within a single function, and for coroutines that are awaited immediately and never stored. But because it is an optimization, not a language guarantee, portable code cannot rely on it. A library that needs predictable performance must provide a custom allocator or a frame pool.

### The Anatomy of a Suspension

When a coroutine suspends, several things happen. First, the compiler stores the resume index into the frame. Second, it spills the live locals and temporaries that cross the suspension point into the frame. Third, it calls `await_suspend` on the awaiter. Fourth, depending on the return type of `await_suspend`, it either returns to the caller, resumes immediately, or tail-calls another coroutine.

The cost of these steps is dominated by memory traffic, not by instruction count. The resume index store is a single word. The spills are a handful of stores to the frame. The `await_suspend` call is an indirect call if the awaiter is polymorphic, or a direct call if it is not. The return to the caller is a return instruction. On a hot cache, this can be a few dozen cycles. On a cold cache, the frame is a cache miss, and the cost is dominated by the latency of fetching the frame from memory.

The frame is allocated on the heap, so it is not in the same cache lines as the caller's stack. The first access to the frame after allocation is a cache miss. The promise is inside the frame, so accessing the promise is another cache miss if the frame is cold. The resume index is in the frame, so the resume function's first action — loading the index — is another cache miss. These misses can be overlapped if the hardware can prefetch, but the frame is often allocated and immediately used, leaving little time for prefetching.

### The Anatomy of a Resumption

Resumption is the reverse. The resumer calls `handle.resume()`, which is an indirect call to the resume function. The resume function loads the resume index from the frame, jumps to the corresponding code, and reloads the spilled locals from the frame. The reloads are loads from memory, and if the frame is still cold, they are cache misses. The jump is an indirect branch, which may be mispredicted if the coroutine has multiple suspension points and the branch predictor cannot track them.

The indirect call to the resume function is itself a source of overhead. Unlike a normal function call, which the compiler can inline or at least predict, the resume function is called through a function pointer stored in the frame. The branch predictor may learn the target if the same coroutine is resumed repeatedly, but in a workload with many coroutines, the target changes on every resume, and the predictor may thrash.

### Measuring the Cost

It is tempting to quote a single number for the cost of a coroutine switch, but the number varies by two orders of magnitude depending on cache state, allocator behavior, and the awaiter's implementation. A suspended coroutine that is resumed immediately, with its frame still in L1 cache, can switch in a few nanoseconds. A coroutine that is resumed after an I/O completion, with its frame evicted to DRAM, pays hundreds of nanoseconds just to fetch the frame. The allocator adds its own cost: a `malloc`/`free` pair can be tens of nanoseconds in the best case and much more under contention.

The honest summary is that the cost of suspension is the cost of a heap allocation plus the cost of a cache miss plus the cost of an indirect branch. None of these are inherent to the idea of a coroutine; they are consequences of the stackless design and the decision to allocate the frame on the heap. A stackful coroutine pays a different set of costs: a stack switch, which is also a cache miss, but no allocation per suspension. A hand-written state machine pays neither allocation nor indirect call, but requires the programmer to write the state machine by hand.

### Mitigations

The first mitigation is to avoid suspending when the operation is already complete. `await_ready` returning `true` skips the entire suspension path. This is why a good awaiter checks for the fast path before doing anything expensive.

The second is to use a custom allocator for the frame. The promise type can define `operator new` and `operator delete`, and the compiler will use them for the frame. A pool allocator that recycles frames of the same size can turn the allocation into a few pointer operations. This is a common technique in coroutine libraries that need to support millions of concurrent tasks.

The third is to keep the frame small. The frame size is determined by the promise, the parameters, and the locals that cross suspension points. Moving a large local into a nested scope that does not cross a suspension point removes it from the frame. Passing a parameter by reference instead of by value avoids a copy into the frame, but requires the referent to outlive the coroutine. The trade-offs are the same as for any manual state machine.

The fourth is to use symmetric transfer to keep the resume chain on the stack. Without it, a chain of awaits grows the stack and pays the cost of pushing and popping frames. With it, the chain is a series of tail calls, and the stack depth is constant.

The fifth is to question whether a coroutine is needed at all. A function that never suspends — one whose `co_await` expressions are always ready — still pays the coroutine tax: the frame allocation (unless HALO applies), the ramp function, the promise construction, and the final suspend. If the suspension is rare, a callback or a hand-written state machine may be cheaper. The coroutine's value is in the cases where suspension is common and the alternative is a deeply nested callback pyramid or a manual state machine that is hard to read and harder to verify.

---

## The Coroutine Handle Is a Pointer

`std::coroutine_handle<Promise>` is the only interface the language gives you to a suspended coroutine, and it is worth being precise about what it is: a trivially copyable, standard-layout wrapper around a single pointer to the coroutine frame. On the Itanium ABI that pointer addresses the frame's first field — the resume function pointer — and every other operation on the handle is a fixed-offset computation from that address. `promise()` is not a lookup; it is `frame + kPromiseOffset`. `from_promise(P&)` is the inverse, `&p - kPromiseOffset`. The offset is a compile-time constant determined by the frame layout, and it is the same for every coroutine with the same promise type and the same suspension structure.

`std::coroutine_handle<>` — shorthand for `std::coroutine_handle<void>` — is the type-erased form. It can hold a handle to any coroutine, and converting to it from `coroutine_handle<Promise>` is implicit and free, because both are just a pointer. Converting back is not implicit: you need `from_address` or a cast, and the cast is only safe if you know the promise type is correct. Type erasure costs you `promise()`; `done()` still works, because it reads the resume index, which is in the frame regardless of promise type; `resume()` and `destroy()` still work, because they go through the function pointers stored in the frame.

The members that matter:

- `resume()` calls the resume function pointer. It is undefined behavior to call it on a handle that is already done, or on a coroutine that is currently running. Resumption is synchronous: it runs on the calling thread until the next suspension.
- `destroy()` calls the destroy function pointer. It is undefined behavior to call it on a running coroutine.
- `done()` reads the resume index and compares it against the sentinel value that marks the final suspend point. It returns `false` for a coroutine that has not started, `false` while suspended at an intermediate point, and `true` once the body has finished and the coroutine is parked at `final_suspend`.
- `operator bool` reports whether the handle is non-null.
- `address()` returns the raw frame pointer; `from_address(void*)` wraps one.
- Comparison operators and a `std::hash` specialization exist, so handles can be keys in a hash map — useful for mapping a frame back to an owning task.

The handle does not own the frame, and this is the single most important fact about it. Copying a handle does not copy the coroutine. Letting a handle go out of scope does not destroy the coroutine. Two handles to the same frame that both call `destroy()` are a double free. A handle used after the frame has been destroyed is a dangling pointer with no protection. The handle is a view, not a resource.

Nothing about the handle is thread-safe in the sense of synchronization. It is trivially copyable, so passing one between threads is fine, but `resume()` must not be called concurrently on the same coroutine, and `resume()` must not race with `destroy()`. The frame's resume index is an ordinary word, not an atomic. A coroutine resumed from an I/O completion thread and destroyed from the owning thread needs external synchronization — a mutex, a reference count, or a strict ownership protocol that guarantees only one thread ever touches the handle at a time.

## Ownership, Parking, and the Final Suspend Contract

Every coroutine frame is destroyed exactly once, and the mechanism is chosen by `final_suspend`. If `final_suspend` returns an awaitable whose `await_ready()` is `true` — the canonical case being `std::suspend_never` — the coroutine does not park. The body finishes, the compiler inserts a call to the destroy function, and the frame is gone before `resume()` returns to its caller. If `final_suspend` returns an awaitable whose `await_ready()` is `false` — `std::suspend_always`, or a custom awaiter — the coroutine parks at the final suspend point. The frame stays alive, `done()` starts returning `true`, and someone must eventually call `destroy()` on a handle.

These two cases are mutually exclusive, and the choice has consequences that ripple through the entire task type.

Parking is almost always what a task type wants, because it keeps the promise alive long enough for the awaiting coroutine to read the result. If `final_suspend` were `suspend_never`, the frame would be destroyed the instant the body completed, and any handle the awaiter holds — including the one it is about to read `promise().result` from — would dangle. So the pattern is: park at the end, and let the awaiter destroy the frame after it has extracted the result.

That makes the handle owning in practice, even though the handle itself is not. The usual solution is to wrap the handle in an RAII type — the task object itself — that destroys the frame in its destructor if the handle is non-null. The task is move-only, and moving it transfers the handle and nulls the source. The task's destructor is the single point of destruction, and the invariant is that a non-null handle in a task object means a parked frame that this object owns.

There is a subtlety in the await chain that makes symmetric transfer a correctness requirement rather than a mere optimization. Suppose task A awaits task B. A's awaiter holds B's handle. When B's body finishes, B parks at `final_suspend`, and its final awaiter returns A's handle. The compiler tail-calls A's resume function. B's resume function is no longer on the stack — the tail call replaced it. A's `await_resume` then reads B's result from B's promise and destroys B's frame. That is safe precisely because B's code is not executing. If B's `final_suspend` instead called `A_handle.resume()` as an ordinary call, B's resume function would still be on the stack when A ran, and destroying B's frame from A would free memory that B's stack frame still refers to. The tail-call shape is what makes the awaiter-destroys-the-awaited-frame pattern sound.

The other half of the contract is that a coroutine must not be destroyed while it is running. `destroy()` on a coroutine that is currently executing — or that has been resumed and has not yet suspended — is undefined behavior. In practice this means the owner must not destroy a task that is currently being awaited by another coroutine, and the executor must not destroy a task that is currently on a run queue. The frame's lifetime is bounded by the suspension points, and the owner is responsible for knowing which side of a suspension point the coroutine is on.

## Generators: co_yield as a Suspension

A generator is the simplest useful coroutine, and it is worth looking at because it exposes the mechanics of suspension without the complexity of an executor. The syntax `co_yield v;` is defined by the standard to be exactly `co_await promise.yield_value(v);`. There is no separate yield machinery. The compiler rewrites the yield into an await, and the promise's `yield_value` decides what happens.

A typical generator promise stores the yielded value — or a pointer to it — and returns an awaiter that suspends the coroutine and transfers control back to the consumer. `initial_suspend` returns `suspend_always`, so the generator is lazy and does not run until the consumer asks for the first value. `final_suspend` returns `suspend_always`, so the consumer can observe completion through `done()` before the frame is destroyed.

The consumer is an input iterator. `operator++` resumes the coroutine; the coroutine runs until the next `co_yield` or until the body finishes; control returns to the iterator. `operator*` reads the value out of the promise. `operator==` compares the handle against a sentinel that checks `done()`. The generator object owns the handle and destroys the frame in its destructor, which is why a generator that is abandoned mid-iteration still runs the destructors of the locals that were in scope at the yield point — the destroy function uses the resume index to pick the right scope to unwind.

The frame of a generator is usually small, but the yielded value is a design decision with a lifetime consequence. If `yield_value` stores the value by value in the promise, the frame grows by `sizeof(T)` and the consumer reads a copy. If it stores a pointer or a reference, the frame stays small, but the referent must outlive the suspension — which is why generators that yield references usually yield members of the promise or of the generator object itself, not locals of the body. A local yielded by reference is a dangling reference the moment the consumer reads it, because the local's storage is in the frame and the frame's contents at that slot are not guaranteed to be preserved across the suspension.

`co_yield` is not cheaper than `co_await`. It is exactly the same suspension: a resume index store, a spill of the locals that cross the yield, an indirect call to `await_suspend`, and a return to the consumer. On the next `operator++`, an indirect call to the resume function and a reload of the spilled state. The only difference is that the awaiter comes from the promise instead of from the user, and the control transfer is symmetric in both directions — the generator suspends and returns to the consumer, and the consumer resumes the generator. The cost is identical.

## Exceptions and the Frame

Exceptions interact with coroutines in three places, and each has a rule that follows from the frame model.

The first is `unhandled_exception`. When an exception escapes the coroutine body, the compiler calls `promise.unhandled_exception()` from an implicit catch block it generates around the body. The promise decides what happens. The common choice is to store `std::current_exception()` in the promise and let the awaiter rethrow it in `await_resume`. Rethrowing directly from `unhandled_exception` is legal, but if that exception escapes, the standard calls `std::terminate` — the coroutine has no caller to propagate to, because the body is executing inside the resume function, which was invoked through a function pointer with no exception specification.

The ordering is fixed: the body throws, `unhandled_exception` runs, and then `final_suspend` is awaited. This means a parked frame always carries a complete result — either a value or an `exception_ptr` — before any awaiter can observe it. The awaiter's `await_resume` inspects the promise and either returns the value or rethrows the stored exception. The exception is not propagated through the resume call; it is stored and rethrown later, at the point where the awaiting coroutine can handle it.

The second is the restriction on `co_await` inside a catch handler. The standard forbids it, and the reason is the resume index model. The resume index encodes a point in the coroutine's control flow, and the frame layout has no slot for an in-flight exception. A catch handler's state includes the exception being handled, which lives in the runtime's exception machinery, not in the frame. The compiler cannot represent resuming into the middle of a catch block because it cannot reconstruct the exception state on resume. The workaround is to catch the exception, store it somewhere in the frame, and rethrow it outside the handler — or, more commonly, to not catch at all and let `unhandled_exception` do the work.

The third is the `noexcept` on `final_suspend`. The standard requires it, and the reason is the same as the `terminate` rule above: `final_suspend` is called from the resume function, at a point where there is no caller to propagate to. If it threw, the only sensible outcome would be termination, so the standard makes that explicit by requiring `noexcept` and letting the compiler enforce it.

## await_transform as the Extension Point

`await_transform` is the promise's opportunity to rewrite every `co_await` in the body before the compiler looks for an awaiter. The lookup order is: if the promise has an `await_transform`, `co_await e` becomes `co_await promise.await_transform(e)`; then, if the result has an `operator co_await`, that is called; otherwise the result must itself be an awaiter. Because the transform runs first, it can intercept types the library does not own — including types from the standard library — and it can intercept them without touching their definitions.

This makes `await_transform` the natural place for cross-cutting concerns. A cancellation-aware transform wraps the awaiter so that `await_suspend` first checks a cancellation token and, if the operation is already cancelled, resumes the coroutine immediately with an exception instead of registering with the underlying operation. A timeout transform wraps the awaiter so that `await_suspend` registers a timer alongside the operation and resumes with a timeout error if the timer fires first. A tracing transform logs every suspension point and the time spent suspended, without the coroutine body knowing anything about it.

The transform can also reject awaits. Deleting the overload for a type makes `co_await` on that type a compile error inside the coroutine, even if the type has a perfectly good `operator co_await` of its own. This is how a library enforces a policy — inside my coroutines, you may only await my awaitables — and it is a compile-time check with no runtime cost.

The cost of `await_transform` is that it runs on every `co_await`, and any wrapper it returns is stored in the frame if it crosses a suspension point. A transform that returns a large wrapper by value enlarges the frame at every suspension in the coroutine. A transform that returns a reference to a wrapper stored elsewhere — in the promise, or in a per-coroutine context object — keeps the frame small, at the cost of lifetime bookkeeping. The transform is a powerful hook, but it is not free, and a library that uses it heavily should measure the frame size it produces.

---

## The Frame Layout in Detail

The Itanium C++ ABI, used by Clang and GCC on Linux and macOS, specifies a layout for the coroutine frame that is worth walking through field by field, because every operation on a coroutine handle is a fixed-offset computation from the frame pointer. The frame begins with a pointer to the resume function, followed by a pointer to the destroy function, followed by the resume index. These three fields are the frame's header. The resume function pointer is what `coroutine_handle::resume()` calls. The destroy function pointer is what `coroutine_handle::destroy()` calls. The resume index is a small integer that tells the resume function where to jump and tells the destroy function which scope to unwind.

After the header comes the promise object. Its offset is a compile-time constant determined by the promise type's alignment and size. `coroutine_handle<Promise>::promise()` computes `frame + kPromiseOffset`, and `from_promise(P&)` computes `&p - kPromiseOffset`. The offset is the same for every coroutine with the same promise type, but it can differ between promise types because of alignment. The compiler knows the offset at the point where it generates the handle operations, so `promise()` is not a lookup; it is an address computation.

After the promise come the parameters that were copied into the frame. Parameters declared by value are stored directly; parameters declared by reference are stored as pointers. The order and padding follow the same rules as a struct with those members. After the parameters come the locals and temporaries that live across a suspension point. The compiler performs a liveness analysis to determine exactly which locals must be stored in the frame. A local that is created and destroyed between two suspension points does not enter the frame; it lives in the resume function's own stack frame. A local that is live across a suspension point is assigned a slot in the frame, and the compiler generates stores to spill it before the suspension and loads to reload it after the resumption.

The resume index is not merely a jump target. It encodes the lexical scope state at the suspension point. When the destroy function runs, it uses the resume index to determine which locals were in scope and must be destroyed. A coroutine destroyed while suspended inside a loop must run the destructors of that iteration's locals and no others. The resume index is how the destroy function knows which iteration it was in. This is why the index is stored in the frame rather than in a register: it must survive the suspension, and it must be readable by the destroy function even if the coroutine never resumes.

The frame's size is computed by the compiler from the promise, the parameters, and the suspension-spanning locals. It is passed to `operator new` when the frame is allocated. The size is not the same as the size of the coroutine's local variables; it is the size of the state that must survive suspension. A coroutine with many locals that are all created and destroyed between suspension points can have a small frame. A coroutine with a single large local that crosses a suspension point will have a frame at least that large.

## Custom Allocators for Coroutine Frames

The frame allocation is performed by `operator new`, and the compiler looks for that operator in a specific order. First, it looks for an `operator new` in the promise type. If the promise type has a member `operator new`, that is used. Second, it looks for an `operator new` in `std::coroutine_traits<R, Args...>`. This allows a library to provide an allocator for a return type it does not own, such as `std::future`. Third, it falls back to the global `operator new`. The corresponding `operator delete` is looked up in the same order and called by the destroy function.

The promise type's `operator new` is typically declared as `static void* operator new(std::size_t size)`. The `size` argument is the frame size computed by the compiler. The promise can also define `operator delete` as `static void operator delete(void* ptr, std::size_t size)`. The size is passed again so that a pool allocator can return the block to the correct free list without storing metadata. If the promise defines `operator new` but not `operator delete`, the compiler will use the global `operator delete`, which is a mismatch if the custom `operator new` allocated from a pool. So both must be defined together.

A pool allocator for coroutine frames is a common optimization. The idea is to allocate frames in fixed-size blocks from a large slab, and to recycle blocks when the coroutine is destroyed. Because the frame size is known at compile time for a given coroutine type, the pool can be specialized for that size. A simple implementation uses a free list: `operator new` pops a block from the free list, and `operator delete` pushes it back. The free list can be thread-local to avoid synchronization, or it can be a lock-free stack if frames are allocated and freed across threads. The pool must handle alignment: the frame may require alignment greater than the default `alignof(std::max_align_t)`, and the allocator must respect that. The compiler passes the alignment to `operator new` if the promise defines an aligned overload, or the promise can use `alignas` on the frame.

The `std::coroutine_traits` customization is the mechanism for providing an allocator for a return type you do not control. For example, if you want `std::future<int>` to use a pool allocator, you specialize `std::coroutine_traits<std::future<int>>` and define a nested `promise_type` that has the desired `operator new` and `operator delete`. The primary template defaults to `R::promise_type`, so specializing `coroutine_traits` is how you inject a promise into a foreign return type. This is also how you can change the promise's behavior — its `initial_suspend`, its `final_suspend`, its `await_transform` — without modifying the return type.

## Heap Allocation Elision in Practice

Heap Allocation Elision (HALO) is the optimization that removes the frame allocation entirely by placing the frame on the caller's stack. It is permitted by the standard but not required, and its applicability depends on the compiler's ability to prove that the frame does not outlive the caller's frame. The conditions are roughly: the coroutine is fully inlined into the caller, the coroutine handle never escapes the caller's scope, and the coroutine's lifetime is strictly nested within the caller's. When these hold, the compiler can allocate the frame as a local variable in the caller's stack frame, and the ramp, resume, and destroy functions become ordinary code that operates on that local.

In practice, HALO is most likely to apply to simple generators that are consumed in a loop within a single function, and to coroutines that are awaited immediately and never stored. It is less likely to apply to coroutines that are stored in task objects, passed to executors, or resumed by I/O completions, because the handle escapes and the compiler cannot prove the lifetime bound. The optimization also requires the coroutine to be inlined, which may not happen if the coroutine is large or if the compiler's inlining heuristics decide against it. Because HALO is not guaranteed, portable code cannot rely on it. A library that needs predictable performance must provide a custom allocator or a frame pool.

To encourage HALO, write coroutines that are small and that are awaited immediately. Avoid storing the coroutine handle in a member variable or passing it to a function that is not inlined. Avoid making the coroutine's return object outlive the caller's scope. If the coroutine is a generator, consume it in a range-based for loop in the same function where it is created. These are not guarantees, but they improve the odds. Some compilers provide flags to report whether HALO was applied, and inspecting the assembly for calls to `operator new` is a reliable way to check.

## The Real Cost of Suspension: A Microbenchmark

It is tempting to quote a single number for the cost of a coroutine switch, but the number varies by two orders of magnitude depending on cache state, allocator behavior, and the awaiter's implementation. A suspended coroutine that is resumed immediately, with its frame still in L1 cache, can switch in a few nanoseconds. A coroutine that is resumed after an I/O completion, with its frame evicted to DRAM, pays hundreds of nanoseconds just to fetch the frame. The allocator adds its own cost: a `malloc`/`free` pair can be tens of nanoseconds in the best case and much more under contention.

The cost of a suspension is the sum of several components. First, the compiler stores the resume index into the frame. Second, it spills the live locals and temporaries that cross the suspension point into the frame. Third, it calls `await_suspend` on the awaiter. Fourth, depending on the return type of `await_suspend`, it either returns to the caller, resumes immediately, or tail-calls another coroutine. The first two steps are memory stores; the third is a call; the fourth is a return or a jump. On a hot cache, this can be a few dozen cycles. On a cold cache, the frame is a cache miss, and the cost is dominated by the latency of fetching the frame from memory.

The cost of a resumption is the reverse. The resumer calls `handle.resume()`, which is an indirect call to the resume function. The resume function loads the resume index from the frame, jumps to the corresponding code, and reloads the spilled locals from the frame. The reloads are loads from memory, and if the frame is still cold, they are cache misses. The jump is an indirect branch, which may be mispredicted if the coroutine has multiple suspension points and the branch predictor cannot track them. The indirect call to the resume function is itself a source of overhead: unlike a normal function call, which the compiler can inline or at least predict, the resume function is called through a function pointer stored in the frame. The branch predictor may learn the target if the same coroutine is resumed repeatedly, but in a workload with many coroutines, the target changes on every resume, and the predictor may thrash.

The honest summary is that the cost of suspension is the cost of a heap allocation plus the cost of a cache miss plus the cost of an indirect branch. None of these are inherent to the idea of a coroutine; they are consequences of the stackless design and the decision to allocate the frame on the heap. A stackful coroutine pays a different set of costs: a stack switch, which is also a cache miss, but no allocation per suspension. A hand-written state machine pays neither allocation nor indirect call, but requires the programmer to write the state machine by hand.

## Thread Safety and the Coroutine Handle

The coroutine handle is trivially copyable, so passing one between threads is fine, but `resume()` must not be called concurrently on the same coroutine, and `resume()` must not race with `destroy()`. The frame's resume index is an ordinary word, not an atomic. A coroutine resumed from an I/O completion thread and destroyed from the owning thread needs external synchronization — a mutex, a reference count, or a strict ownership protocol that guarantees only one thread ever touches the handle at a time. The handle does not own the frame, and copying a handle does not copy the coroutine. Letting a handle go out of scope does not destroy the coroutine. Two handles to the same frame that both call `destroy()` are a double free. A handle used after the frame has been destroyed is a dangling pointer with no protection. The handle is a view, not a resource.

The ownership protocol is usually implemented by wrapping the handle in an RAII type. The task object owns the handle and destroys the frame in its destructor if the handle is non-null. The task is move-only, and moving it transfers the handle and nulls the source. The task's destructor is the single point of destruction, and the invariant is that a non-null handle in a task object means a parked frame that this object owns. This works well for single-threaded executors, but for multi-threaded executors, the ownership must be shared or transferred explicitly. A common pattern is to use a reference count on the frame, incremented when a handle is copied into a new owner and decremented when an owner releases it. The frame is destroyed when the count reaches zero. The reference count must be atomic if handles can be copied across threads.

## The Promise's `get_return_object` and the Ramp

`get_return_object()` is called once, on the ramp path, before `initial_suspend` is awaited. It produces the value that the caller receives. The return object is typically a handle wrapper that owns the coroutine frame. The timing matters: `get_return_object` runs before the coroutine body starts, so the return object is available to the caller even if the coroutine suspends at `initial_suspend` and never runs. If `initial_suspend` returns `std::suspend_never`, the coroutine body runs inside the ramp, before the caller receives the return object. This is an eager coroutine. The subtlety is that the coroutine may finish and destroy its frame before the ramp returns. If the return object holds a handle to the frame, that handle is dangling. Eager coroutines are therefore dangerous unless the return object does not hold a handle, or unless `final_suspend` parks the coroutine so the frame stays alive. Most task types use `std::suspend_always` for `initial_suspend`, making them lazy. The body does not run until someone resumes the coroutine, and the return object is safely in the caller's hands before any body code executes.

## `co_return` and the Final Suspend

`co_return v;` calls `promise.return_value(v)`. `co_return;` and falling off the end of the body call `promise.return_void()`. Exactly one of these must exist in the promise type. Having both is ill-formed; having neither is ill-formed if the body can reach `co_return`. After `return_value` or `return_void` is called, the coroutine awaits `final_suspend`. If `final_suspend` returns an awaitable whose `await_ready()` is `true`, the coroutine does not park; the frame is destroyed automatically, and `resume()` returns to its caller. If `final_suspend` returns an awaitable whose `await_ready()` is `false`, the coroutine parks at the final suspend point. The frame stays alive, `done()` starts returning `true`, and someone must eventually call `destroy()` on a handle. The ordering is fixed: `return_value` or `return_void` first, then `final_suspend`. If an exception escapes the body, `unhandled_exception` is called before `final_suspend`. The parked frame always carries a complete result — either a value or an `exception_ptr` — before any awaiter can observe it.

## The Awaiter's Lifetime and the Frame

The awaiter's lifetime is not specified by the standard beyond the fact that it must be alive during the calls to `await_ready`, `await_suspend`, and `await_resume`. The compiler typically stores the awaiter in the coroutine frame if it must survive a suspension, or on the resume function's stack if it does not. An awaiter that is created and destroyed between two suspension points does not enter the frame. An awaiter that crosses a suspension point is stored in the frame, and its size contributes to the frame size. A large awaiter — one that holds a buffer, a callback, or a complex state — can significantly enlarge the frame. The awaiter's destructor is called when the awaiter goes out of scope, which is after `await_resume` returns or throws. If `await_resume` throws, the exception propagates out of the `co_await` expression as if it were thrown by the awaited operation. The awaiter's destructor still runs as part of the unwinding.

## The `co_await` Operator Lookup

The lookup order for `co_await e` is precise. First, if the promise has an `await_transform` member, `e` is replaced by `promise.await_transform(e)`. Second, if the resulting type has an `operator co_await`, it is called to produce an awaiter. The `operator co_await` can be a member function or a free function. Third, if neither applies, the expression itself must be an awaiter. An awaiter is any type with the three member functions `await_ready`, `await_suspend`, and `await_resume`. The compiler does not require a base class or a concept; it simply looks up those names. The standard awaiters `std::suspend_always` and `std::suspend_never` satisfy this protocol. `std::noop_coroutine()` is a handle, not an awaiter, but it is the handle to return from `await_suspend` when there is no continuation. The lookup is done at compile time, and the compiler generates a direct call to `await_ready`, `await_suspend`, and `await_resume` if the awaiter type is known. If the awaiter is polymorphic, the calls may be indirect.

## Generators: The Iterator and the Frame

A generator's consumer is an input iterator. `operator++` resumes the coroutine; the coroutine runs until the next `co_yield` or until the body finishes; control returns to the iterator. `operator*` reads the value out of the promise. `operator==` compares the handle against a sentinel that checks `done()`. The generator object owns the handle and destroys the frame in its destructor, which is why a generator that is abandoned mid-iteration still runs the destructors of the locals that were in scope at the yield point — the destroy function uses the resume index to pick the right scope to unwind. The frame of a generator is usually small, but the yielded value is a design decision with a lifetime consequence. If `yield_value` stores the value by value in the promise, the frame grows by `sizeof(T)` and the consumer reads a copy. If it stores a pointer or a reference, the frame stays small, but the referent must outlive the suspension — which is why generators that yield references usually yield members of the promise or of the generator object itself, not locals of the body. A local yielded by reference is a dangling reference the moment the consumer reads it, because the local's storage is in the frame and the frame's contents at that slot are not guaranteed to be preserved across the suspension. `co_yield` is not cheaper than `co_await`. It is exactly the same suspension: a resume index store, a spill of the locals that cross the yield, an indirect call to `await_suspend`, and a return to the consumer. On the next `operator++`, an indirect call to the resume function and a reload of the spilled state. The only difference is that the awaiter comes from the promise instead of from the user, and the control transfer is symmetric in both directions — the generator suspends and returns to the consumer, and the consumer resumes the generator. The cost is identical.

## Exceptions: `unhandled_exception` and the Frame

Exceptions interact with coroutines in three places, and each has a rule that follows from the frame model. The first is `unhandled_exception`. When an exception escapes the coroutine body, the compiler calls `promise.unhandled_exception()` from an implicit catch block it generates around the body. The promise decides what happens. The common choice is to store `std::current_exception()` in the promise and let the awaiter rethrow it in `await_resume`. Rethrowing directly from `unhandled_exception` is legal, but if that exception escapes, the standard calls `std::terminate` — the coroutine has no caller to propagate to, because the body is executing inside the resume function, which was invoked through a function pointer with no exception specification. The ordering is fixed: the body throws, `unhandled_exception` runs, and then `final_suspend` is awaited. This means a parked frame always carries a complete result — either a value or an `exception_ptr` — before any awaiter can observe it. The awaiter's `await_resume` inspects the promise and either returns the value or rethrows the stored exception. The exception is not propagated through the resume call; it is stored and rethrown later, at the point where the awaiting coroutine can handle it. The second is the restriction on `co_await` inside a catch handler. The standard forbids it, and the reason is the resume index model. The resume index encodes a point in the coroutine's control flow, and the frame layout has no slot for an in-flight exception. A catch handler's state includes the exception being handled, which lives in the runtime's exception machinery, not in the frame. The compiler cannot represent resuming into the middle of a catch block because it cannot reconstruct the exception state on resume. The workaround is to catch the exception, store it somewhere in the frame, and rethrow it outside the handler — or, more commonly, to not catch at all and let `unhandled_exception` do the work. The third is the `noexcept` on `final_suspend`. The standard requires it, and the reason is the same as the `terminate` rule above: `final_suspend` is called from the resume function, at a point where there is no caller to propagate to. If it threw, the only sensible outcome would be termination, so the standard makes that explicit by requiring `noexcept` and letting the compiler enforce it.
