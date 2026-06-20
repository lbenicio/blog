---
title: "Garbage Collection Algorithms: From Mark-and-Sweep to ZGC"
description: "A comprehensive exploration of garbage collection algorithms, from classic mark-and-sweep to modern concurrent collectors like G1, Shenandoah, and ZGC. Learn how automatic memory management works and the trade-offs that shape collector design."
date: "2022-11-22"
author: "Leonardo Benicio"
tags: ["garbage-collection", "memory", "jvm", "performance", "gc", "algorithms", "concurrency"]
categories: ["systems", "performance"]
draft: false
cover: "/static/assets/images/blog/garbage-collection-algorithms-mark-sweep-to-zgc.png"
coverAlt: "Abstract visualization of memory being automatically reclaimed, with live objects highlighted and unreachable objects fading away into recycled space"
---

Manual memory management is powerful but error-prone. Forget to free memory and you leak; free too early and you corrupt. Garbage collection promises to solve this by automatically reclaiming unused memory. But this convenience comes with costs and trade-offs that every systems programmer should understand. This post explores garbage collection from first principles to cutting-edge concurrent collectors.

## 1. Why Garbage Collection?

Consider the challenges of manual memory management:

```c
void process_request(Request* req) {
    char* buffer = malloc(1024);
    Result* result = compute(req, buffer);

    if (result->error) {
        // Oops! Forgot to free buffer
        return;
    }

    send_response(result);
    free(buffer);
    free(result);  // Did compute() allocate this? Or is it static?
}
```

Common bugs include:

- **Memory leaks:** Forgetting to free allocated memory
- **Use-after-free:** Accessing memory after it's been freed
- **Double-free:** Freeing the same memory twice
- **Dangling pointers:** Holding references to freed memory

Garbage collection eliminates these bugs by automatically determining when memory is no longer reachable and reclaiming it. The programmer allocates; the runtime frees.

### 1.1 The Basic Idea

A garbage collector's job is simple in concept:

1. Find all objects that the program can still access (live objects)
2. Reclaim memory from objects that can't be accessed (garbage)

The challenge is doing this efficiently without stopping the program for too long.

### 1.2 Reachability

An object is live if it's reachable from a set of root references:

- Local variables on the stack
- Global/static variables
- CPU registers
- JNI references (in Java)

Any object reachable from roots, directly or through a chain of references, is live. Everything else is garbage.

```text
Roots
  │
  ├──▶ Object A ──▶ Object B ──▶ Object C
  │         │
  │         └──▶ Object D
  │
  └──▶ Object E

Object F (unreachable - garbage)
Object G ──▶ Object H (unreachable cycle - garbage)
```

## 2. Reference Counting

The simplest approach: track how many references point to each object.

### 2.1 Basic Algorithm

```python
class Object:
    def __init__(self):
        self.ref_count = 1  # Creator holds a reference

    def add_ref(self):
        self.ref_count += 1

    def release(self):
        self.ref_count -= 1
        if self.ref_count == 0:
            for child in self.children:
                child.release()
            free(self)
```

When you copy a reference, increment the count. When a reference goes away, decrement it. When the count hits zero, the object is garbage.

### 2.2 Advantages

- **Immediate reclamation:** Objects are freed as soon as they become garbage
- **Incremental:** Work is spread across program execution
- **Simple to implement:** No need for complex graph traversal
- **Predictable pauses:** No stop-the-world collections

### 2.3 The Cycle Problem

Reference counting's fatal flaw:

```python
a = Object()  # a.ref_count = 1
b = Object()  # b.ref_count = 1

a.child = b   # b.ref_count = 2
b.child = a   # a.ref_count = 2

a = None      # a.ref_count = 1 (still > 0!)
b = None      # b.ref_count = 1 (still > 0!)

# Both objects are garbage but won't be collected
```

Cycles create mutual references that keep objects alive forever.

### 2.4 Solutions to Cycles

**Weak references:** References that don't contribute to the count.

```python
a.child = b           # Strong reference, increments count
b.parent = weak(a)    # Weak reference, doesn't increment
```

**Cycle detection:** Periodically run a tracing collector to find cycles. Python uses this approach.

**Cycle-aware designs:** Structure data to avoid cycles (trees instead of graphs).

### 2.5 Reference Counting Overhead

Even without cycles, reference counting has costs:

- **Space:** Every object needs a count field
- **Time:** Every reference assignment updates counts
- **Cache pollution:** Count updates touch memory across the heap
- **Thread safety:** Atomic operations needed for concurrent access

Despite these issues, reference counting is used in:

- Python (with cycle detection)
- Swift (with automatic reference counting, ARC)
- Rust's `Rc` and `Arc` types
- C++ `shared_ptr`

## 3. Mark-and-Sweep

The classic tracing collector: mark live objects, sweep away the rest.

### 3.1 Mark Phase

Starting from roots, traverse all reachable objects and mark them:

```python
def mark(roots):
    worklist = list(roots)
    while worklist:
        obj = worklist.pop()
        if not obj.marked:
            obj.marked = True
            for child in obj.references:
                worklist.append(child)
```

This is essentially a graph traversal (DFS or BFS).

### 3.2 Sweep Phase

Walk through all objects; free unmarked ones:

```python
def sweep(heap):
    for obj in heap.all_objects():
        if obj.marked:
            obj.marked = False  # Reset for next collection
        else:
            heap.free(obj)
```

### 3.3 Stop-the-World

Basic mark-and-sweep requires stopping the program during collection. Why?

- During marking, we need a consistent view of the heap
- If the program modifies references while we're marking, we might miss live objects
- During sweep, we can't have the program allocating in memory we're freeing

This pause is called "stop-the-world" (STW) and is the primary challenge in GC design.

### 3.4 Advantages and Disadvantages

**Advantages:**

- Handles cycles naturally
- No per-object overhead (mark bit can be external)
- Well-understood algorithm

**Disadvantages:**

- Stop-the-world pauses
- Must traverse entire live set
- Heap becomes fragmented over time

## 4. Mark-Compact

Mark-and-sweep leaves holes in memory. Mark-compact adds a compaction phase.

### 4.1 The Compaction Process

After marking, slide all live objects to one end of the heap:

```text
Before compaction:
[Live][    ][Live][Live][    ][    ][Live]

After compaction:
[Live][Live][Live][Live][                ]
                        ↑
                    Free pointer
```

### 4.2 Challenges

Compaction requires updating all references to point to new locations:

```python
def compact(heap):
    # Calculate new addresses
    new_addr = heap.start
    for obj in heap.all_objects():
        if obj.marked:
            obj.forwarding_addr = new_addr
            new_addr += obj.size

    # Update all references
    for obj in heap.all_objects():
        if obj.marked:
            for ref in obj.references:
                ref.update(ref.target.forwarding_addr)

    # Move objects
    for obj in heap.all_objects():
        if obj.marked:
            move(obj, obj.forwarding_addr)
```

This requires multiple passes over the heap, making it slower than simple mark-sweep.

### 4.3 Benefits

- **No fragmentation:** Memory is always contiguous
- **Fast allocation:** Just bump a pointer
- **Better cache locality:** Related objects can be placed together

### 4.4 Variations

**Lisp 2 algorithm:** Three passes - compute addresses, update references, move objects.

**Threading:** Uses reference fields as a linked list during compaction (saves space).

**Sliding vs. arbitrary:** Sliding preserves allocation order; arbitrary can optimize layout.

## 5. Copying Collection

Instead of compacting in place, copy live objects to a new space.

### 5.1 Semi-Space Collector

Divide memory into two equal halves (semispaces):

```text
┌─────────────────┬─────────────────┐
│   From-space    │    To-space     │
│   (active)      │   (reserved)    │
└─────────────────┴─────────────────┘
```

Collection process:

1. Copy all live objects from "from-space" to "to-space"
2. Update all references to point to new locations
3. Swap the roles of the two spaces

```python
def collect():
    global from_space, to_space
    scan = to_space.start
    free = to_space.start

    # Copy roots
    for root in roots:
        root.target = copy(root.target)

    # Breadth-first copy
    while scan < free:
        obj = object_at(scan)
        for ref in obj.references:
            ref.target = copy(ref.target)
        scan += obj.size

    # Swap spaces
    from_space, to_space = to_space, from_space

def copy(obj):
    if obj.forwarding_addr:
        return obj.forwarding_addr

    new_obj = allocate_in_to_space(obj.size)
    copy_contents(obj, new_obj)
    obj.forwarding_addr = new_obj
    return new_obj
```

### 5.2 Cheney's Algorithm

The elegant BFS copying algorithm shown above. Uses the to-space itself as the work queue—no additional memory needed.

### 5.3 Trade-offs

**Advantages:**

- Very fast allocation (bump pointer)
- Compacts automatically
- Only touches live objects (fast if most objects are garbage)
- Simple implementation

**Disadvantages:**

- Wastes half the memory (only half is usable at any time)
- Copies everything, even long-lived objects
- Bad for large heaps (long pause to copy everything)

## 6. Generational Collection

Observation: most objects die young. This "generational hypothesis" is remarkably consistent across languages and applications.

### 6.1 The Generational Hypothesis

Studies show:

- 80-98% of objects die within one GC cycle of allocation
- Objects that survive multiple collections tend to live forever
- Allocating and collecting short-lived objects should be fast

### 6.2 Generational Design

Divide the heap into generations:

```text
┌──────────────────────────────────────────────────┐
│                    Old Generation                 │
│   (large, collected infrequently)                │
├──────────────────────────────────────────────────┤
│  Young Generation                                 │
│  ┌────────────────┬───────────┬───────────┐     │
│  │     Eden       │ Survivor0 │ Survivor1 │     │
│  │ (new objects)  │           │           │     │
│  └────────────────┴───────────┴───────────┘     │
└──────────────────────────────────────────────────┘
```

**Young generation:** Small, collected frequently. Most objects die here.

**Old generation:** Large, collected infrequently. Long-lived objects promoted here.

### 6.3 Minor vs. Major Collections

**Minor GC (young generation):**

1. Allocate in Eden until full
2. Copy survivors to a survivor space
3. Objects surviving multiple minor GCs are promoted to old generation
4. Fast because most objects are garbage

**Major GC (full heap):**

1. Triggered when old generation fills up
2. Collects both young and old generations
3. Much slower, but infrequent

### 6.4 The Write Barrier Problem

Old objects can reference young objects:

```java
oldObject.field = newObject;  // Inter-generational reference
```

When collecting the young generation, we must know about these references, or we'll incorrectly collect live young objects.

**Remembered sets:** Track references from old to young generation.

**Card marking:** Divide heap into "cards." Mark cards as dirty when they contain modified references.

```text
Old generation cards:
[Clean][Dirty][Clean][Clean][Dirty][Clean]
           │                   │
           └───────────────────┘
           These cards have references to young gen
```

During minor GC, only scan dirty cards for roots into young generation.

### 6.5 Write Barrier Implementation

Every reference store checks if it creates an inter-generational reference:

```c
void write_barrier(Object* obj, Object* ref, Object* new_value) {
    // Store the reference
    *ref = new_value;

    // If old-to-young reference, remember it
    if (is_old(obj) && is_young(new_value)) {
        mark_card_dirty(obj);
    }
}
```

This adds overhead to every reference assignment, but enables much faster minor collections.

## 7. Concurrent and Incremental Collection

Stop-the-world pauses are problematic for interactive and real-time applications. Concurrent collectors run alongside the application.

### 7.1 The Tri-Color Abstraction

Concurrent collectors use three colors to track marking progress:

- **White:** Not yet seen (potential garbage)
- **Gray:** Seen but children not yet scanned
- **Black:** Scanned (definitely live)

```text
Initial:
Roots ──▶ [White] ──▶ [White] ──▶ [White]

After starting:
Roots ──▶ [Gray] ──▶ [White] ──▶ [White]

After scanning gray:
Roots ──▶ [Black] ──▶ [Gray] ──▶ [White]

After completion:
Roots ──▶ [Black] ──▶ [Black] ──▶ [Black]
```

Collection completes when no gray objects remain. All white objects are garbage.

### 7.2 The Mutator Problem

While the collector runs, the application (the "mutator") can change references:

```java
// Collector has marked A black, B is white
A.field = B;  // Now black A points to white B
C.field = null;  // C was the only other reference to B

// B is now reachable only through A, but A is black and won't be rescanned
// B remains white and will be incorrectly collected!
```

This is the "lost object" problem. Two conditions must both be true:

1. A black object gets a reference to a white object
2. All gray paths to the white object are destroyed

### 7.3 Barrier Solutions

**Write barrier (snapshot-at-beginning):** Record old values before overwriting.

```c
void write_barrier(Object** field, Object* new_value) {
    Object* old_value = *field;
    if (old_value != null && is_white(old_value)) {
        mark_gray(old_value);  // Keep old value alive
    }
    *field = new_value;
}
```

**Write barrier (incremental update):** Mark new values when stored in black objects.

```c
void write_barrier(Object* obj, Object** field, Object* new_value) {
    *field = new_value;
    if (is_black(obj) && new_value != null && is_white(new_value)) {
        mark_gray(new_value);  // Or mark obj gray to rescan
    }
}
```

### 7.4 Incremental vs. Concurrent

**Incremental:** Collector runs in small steps between mutator execution (same thread).

```text
[Mutator][GC][Mutator][GC][Mutator][GC][Mutator]
```

**Concurrent:** Collector runs on separate threads, truly parallel with mutator.

```text
Thread 1: [Mutator][Mutator][Mutator][Mutator]
Thread 2: [   GC   ][   GC   ][   GC   ]
```

Concurrent collectors are more complex but achieve lower pause times.

## 8. The CMS Collector

The Concurrent Mark Sweep (CMS) collector was Java's first production concurrent collector.

### 8.1 Phases

1. **Initial Mark (STW):** Mark objects directly reachable from roots. Short pause.

2. **Concurrent Mark:** Traverse object graph concurrently with application. Uses write barriers to track changes.

3. **Remark (STW):** Fix up references changed during concurrent mark. Short pause.

4. **Concurrent Sweep:** Sweep garbage concurrently. Add to free lists.

### 8.2 Strengths and Weaknesses

**Strengths:**

- Short pause times (usually < 200ms)
- Good for interactive applications
- Well-tested, mature collector

**Weaknesses:**

- No compaction (fragmentation over time)
- "Concurrent mode failure" when old gen fills during marking
- Higher CPU overhead (collector threads compete with application)
- Deprecated in Java 9, removed in Java 14

### 8.3 Failure Modes

**Concurrent mode failure:** Old generation fills before concurrent collection completes. Falls back to full STW collection.

**Promotion failure:** Not enough contiguous space in old gen for promoted objects. Also triggers full GC.

These failures cause long pauses, defeating CMS's purpose.

## 9. The G1 Collector

Garbage-First (G1) became Java's default collector in Java 9. It aims for predictable pause times.

### 9.1 Region-Based Heap

G1 divides the heap into equal-sized regions (1-32 MB):

```text
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ E │ E │ S │ O │ O │ O │ H │ H │   │   │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
E = Eden, S = Survivor, O = Old, H = Humongous (large objects)
```

Regions can change roles. No fixed-size generations.

### 9.2 Collection Sets

G1 doesn't collect the entire heap at once. It selects a "collection set" of regions to evacuate:

- Young collection: All young regions
- Mixed collection: Young regions + some old regions with most garbage

This is the "garbage first" insight: collect regions with the most garbage for best efficiency.

### 9.3 Remembered Sets

Each region maintains a remembered set (RSet) of references from outside the region:

```text
Region A               Region B
┌─────────────┐       ┌─────────────┐
│   Object    │──────▶│   Object    │
│             │       │             │
│   RSet: {}  │       │ RSet: {A}   │
└─────────────┘       └─────────────┘
```

RSets enable collecting a region without scanning the entire heap. The trade-off is memory overhead (5-20% of heap).

### 9.4 Concurrent Marking

G1's marking is similar to CMS:

1. **Initial Mark (STW, piggybacks on young GC)**
2. **Concurrent Mark:** SATB (snapshot-at-beginning) write barrier
3. **Remark (STW):** Process SATB buffers
4. **Cleanup (STW):** Identify empty regions, sort regions by garbage ratio

### 9.5 Pause Time Goals

G1 accepts a pause time target (e.g., 200ms):

```bash
java -XX:MaxGCPauseMillis=200 MyApp
```

G1 adjusts the collection set size to meet this target. Fewer regions = shorter pause, less memory reclaimed.

### 9.6 Performance Characteristics

- **Pause times:** More predictable than CMS, typically 50-200ms
- **Throughput:** Slightly lower than Parallel GC due to write barriers
- **Memory:** Higher footprint due to remembered sets
- **Best for:** Large heaps (4GB+), applications needing predictable latency

## 10. Shenandoah

Shenandoah aims for ultra-low pause times (< 10ms) regardless of heap size.

### 10.1 Key Innovation: Concurrent Compaction

Unlike G1, Shenandoah compacts concurrently with the application:

1. Objects are copied while the application runs
2. References are updated concurrently
3. Forwarding pointers enable concurrent access to moved objects

### 10.2 The Brooks Pointer

Every object has an indirection pointer (Brooks pointer):

```text
┌────────────────────────────────────┐
│ Brooks Pointer │ Object Data       │
│ (self or fwd)  │                   │
└────────────────────────────────────┘
```

Normally points to itself. During evacuation, points to the new location:

```text
Old location:
┌────────────────────────────────────┐
│ ──────────────────┐ Object Data    │
└───────────────────│────────────────┘
                    │
                    ▼
New location:      ┌────────────────────────────────────┐
                   │ (self)         │ Object Data       │
                   └────────────────────────────────────┘
```

All reads go through the Brooks pointer. This adds overhead but enables concurrent evacuation.

### 10.3 Load Reference Barrier

Every reference load checks and potentially updates the reference:

```c
Object* load_reference(Object** ref) {
    Object* obj = *ref;
    if (is_forwarded(obj)) {
        Object* new_obj = obj->brooks_pointer;
        *ref = new_obj;  // Update reference in place
        return new_obj;
    }
    return obj;
}
```

This "self-healing" ensures references are updated as they're used.

### 10.4 Phases

1. **Initial Mark (STW):** ~1ms
2. **Concurrent Mark:** Traverse heap
3. **Final Mark (STW):** ~1ms
4. **Concurrent Cleanup:** Reclaim empty regions
5. **Concurrent Evacuation:** Copy and update references
6. **Init Update Refs (STW):** ~1ms
7. **Concurrent Update Refs:** Update remaining references
8. **Final Update Refs (STW):** ~1ms

Total STW time: typically 4-10ms regardless of heap size!

### 10.5 Trade-offs

**Strengths:**

- Ultra-low pause times
- Scales to huge heaps
- Full compaction

**Weaknesses:**

- Lower throughput (barrier overhead)
- More CPU usage
- Memory overhead (Brooks pointers)

## 11. ZGC

Z Garbage Collector (ZGC) targets sub-millisecond pauses for multi-terabyte heaps.

### 11.1 Colored Pointers

ZGC uses pointer coloring instead of object headers:

```text
64-bit pointer:
┌──────────┬───┬───┬───┬───┬────────────────────────────────┐
│ Unused   │ F │ R │ M1│ M0│     Object Address (42 bits)   │
│ (16 bits)│   │   │   │   │                                │
└──────────┴───┴───┴───┴───┴────────────────────────────────┘
F = Finalizable, R = Remapped, M1/M0 = Marked bits
```

The color bits encode GC state. The same object can be accessed through different "views" based on pointer color.

### 11.2 Load Barrier

Like Shenandoah, ZGC uses a load barrier:

```c
Object* load_reference(Object** ref) {
    Object* obj = *ref;
    if (needs_barrier(obj)) {
        obj = slow_path(obj, ref);
    }
    return obj;
}
```

The barrier checks pointer color. If the color is wrong for the current GC phase, it fixes the reference.

### 11.3 Multi-Mapping

ZGC maps the same physical memory at multiple virtual addresses:

```text
Virtual Address Space:
┌────────────────────────┐  ◄── "Marked0" view
│                        │
├────────────────────────┤  ◄── "Marked1" view
│                        │
├────────────────────────┤  ◄── "Remapped" view
│                        │
└────────────────────────┘
         │ │ │
         ▼ ▼ ▼
    Same physical memory
```

This enables changing an object's "color" by changing which view you use, without modifying the object.

### 11.4 Concurrent Operations

Almost everything in ZGC is concurrent:

- Marking
- Relocation set selection
- Reference processing
- Object relocation
- Root scanning (mostly)

STW pauses are only for:

- Root scanning start/end (< 1ms)
- A few internal bookkeeping operations

### 11.5 Performance

- **Pause times:** < 1ms, typically 200-500μs
- **Heap sizes:** Tested to 16TB
- **Throughput:** Comparable to G1, less than Parallel GC
- **Memory:** Requires 64-bit, uses more virtual address space

### 11.6 Use Cases

ZGC excels for:

- Large heap applications (hundreds of GB to TB)
- Latency-critical services
- Applications that can't tolerate pause time variance

## 12. Comparison of Modern Collectors

| Collector  | Pause Time        | Throughput | Memory Overhead    | Best For                    |
| ---------- | ----------------- | ---------- | ------------------ | --------------------------- |
| Parallel   | High (seconds)    | Highest    | Low                | Batch processing            |
| G1         | Medium (50-200ms) | Good       | Medium (RSets)     | General purpose             |
| Shenandoah | Low (< 10ms)      | Lower      | Medium (Brooks)    | Latency-sensitive           |
| ZGC        | Ultra-low (< 1ms) | Lower      | Higher (multi-map) | Large heaps, strict latency |

### 12.1 Choosing a Collector

**Use Parallel GC when:**

- Throughput is the only concern
- Pauses are acceptable (batch jobs)
- Heap is moderate size (< 4GB)

**Use G1 when:**

- Balanced throughput and latency needed
- Heap is large (4GB+)
- Pause time predictability matters

**Use Shenandoah when:**

- Pause times must be < 10ms
- Some throughput can be sacrificed
- Heap is large but not huge

**Use ZGC when:**

- Pause times must be < 1ms
- Heap is very large (100GB+)
- Running on modern 64-bit hardware

## 13. GC in Other Languages

### 13.1 Go's GC

Go uses a concurrent, tri-color mark-and-sweep collector:

- **Non-generational:** Treats all objects equally
- **Non-compacting:** Uses size-segregated allocation to reduce fragmentation
- **Very low pauses:** Typically < 1ms
- **Write barriers:** Hybrid barrier for concurrent marking

Go optimizes for low latency over throughput, matching its target of network services.

### 13.2 .NET's GC

.NET has a sophisticated generational collector:

- **Three generations:** Gen0 (short-lived), Gen1 (medium), Gen2 (long-lived)
- **Server vs. Workstation:** Different configurations for different workloads
- **Background GC:** Concurrent collection of Gen2
- **Large Object Heap:** Separate heap for large objects (> 85KB)

### 13.3 Python's GC

Python combines reference counting with generational cycle detection:

- **Reference counting:** Immediate reclamation, no cycles
- **Cycle detector:** Generational tracing for cycles
- **GIL interaction:** GC runs under the Global Interpreter Lock

The reference counting base makes Python's GC deterministic for most objects.

### 13.4 Rust: No GC

Rust proves that some applications don't need GC:

- **Ownership system:** Compiler tracks lifetimes
- **Automatic deallocation:** Drop trait called at scope exit
- **No runtime overhead:** Memory management resolved at compile time

The trade-off is programmer effort and learning curve.

## 14. Tuning Garbage Collection

### 14.1 Measuring GC Performance

Key metrics to monitor:

```bash
# JVM GC logging
java -Xlog:gc*:file=gc.log:time,uptime:filecount=5,filesize=10M MyApp

# Important metrics:
# - Pause times (p50, p99, max)
# - Throughput (time not in GC)
# - Allocation rate
# - Promotion rate
# - Live data size
```

### 14.2 Common Tuning Parameters

**Heap sizing:**

```bash
-Xms4g -Xmx4g          # Fixed heap size (recommended for production)
-XX:MaxRAMPercentage=75 # Use 75% of container memory
```

**Generation sizing (G1):**

```bash
-XX:NewRatio=2          # Old gen is 2x young gen
-XX:G1NewSizePercent=5  # Min young gen as % of heap
-XX:G1MaxNewSizePercent=60  # Max young gen
```

**Pause time targets:**

```bash
-XX:MaxGCPauseMillis=200      # G1, ZGC, Shenandoah
-XX:GCPauseIntervalMillis=500 # Minimum time between pauses
```

### 14.3 Tuning Philosophy

1. **Start with defaults:** Modern collectors are well-tuned
2. **Measure, don't guess:** Use GC logs and metrics
3. **Understand the workload:** Allocation rate, object lifetimes, live set size
4. **Make one change at a time:** Isolate effects
5. **Test under production load:** Synthetic benchmarks can be misleading

### 14.4 Common Issues and Solutions

**Long young GC pauses:**

- Reduce young generation size
- Check for large object allocation
- Verify promotion rate isn't too high

**Frequent full GCs:**

- Increase heap size
- Check for memory leaks
- Tune old generation size

**High GC CPU usage:**

- Reduce allocation rate
- Use object pooling
- Consider off-heap storage

## 15. Advanced Topics

### 15.1 Finalizers and Phantom References

Java's finalization is problematic:

```java
protected void finalize() {
    // Don't do this!
    // - Unpredictable timing
    // - Can resurrect objects
    // - Delays collection
}
```

Use `Cleaner` or `PhantomReference` instead:

```java
Cleaner cleaner = Cleaner.create();
cleaner.register(object, () -> cleanup());
```

### 15.2 Off-Heap Memory

Avoid GC overhead by allocating outside the heap:

```java
ByteBuffer buffer = ByteBuffer.allocateDirect(1024 * 1024);
// Memory is off-heap, managed by OS
```

Libraries like Chronicle Map and MapDB use off-heap storage for large data sets.

### 15.3 Escape Analysis and Allocation Elimination

JIT compilers can eliminate allocations:

```java
void process() {
    Point p = new Point(1, 2);  // Might not allocate!
    return p.x + p.y;
}
```

If `p` doesn't escape the method, the JIT can:

- **Scalar replacement:** Replace object with its fields
- **Stack allocation:** Allocate on stack instead of heap
- **Elimination:** Remove allocation entirely if unused

### 15.4 NUMA-Aware GC

On NUMA systems, memory access latency varies:

```text
┌─────────────┐     ┌─────────────┐
│   CPU 0     │     │   CPU 1     │
│  Local Mem  │────▶│  Remote Mem │ Slower!
└─────────────┘     └─────────────┘
```

NUMA-aware collectors try to:

- Allocate objects on the local node
- Keep related objects on the same node
- Balance collector threads across nodes

G1 and ZGC have experimental NUMA support.

## 16. The Future of GC

### 16.1 Generational ZGC

Coming in Java 21+, generational ZGC adds generations to ZGC:

- Young generation collected more frequently
- Old generation collected concurrently
- Better throughput than non-generational ZGC
- Same ultra-low pause times

### 16.2 Value Types

Project Valhalla brings value types to Java:

```java
value class Point {
    int x;
    int y;
}
```

Value types are:

- Allocated inline (no object header)
- Passed by value (no references)
- No identity (can't synchronize)

This dramatically reduces allocation rate and GC pressure for many workloads.

### 16.3 GC for Persistent Memory

NVM (Non-Volatile Memory) changes GC requirements:

- Objects survive process restarts
- Must handle crash consistency
- Different performance characteristics than DRAM

Research is ongoing for GC designs that handle persistent heaps.

### 16.4 Machine Learning for GC

ML can optimize GC decisions:

- Predict object lifetimes for better tenuring
- Optimize collection timing based on allocation patterns
- Tune parameters automatically based on workload

Early research shows promising results, but production adoption is limited.

## 17. Real-World GC War Stories

Understanding theory is valuable, but seeing how GC affects real systems cements the knowledge. Here are instructive examples from production environments.

### 17.1 The Twitter Fail Whale

In Twitter's early days, long GC pauses contributed to their infamous "Fail Whale" error page. Their Ruby application used a stop-the-world collector that would pause for seconds under load.

The solution involved multiple strategies:

- Moving to a concurrent JVM-based service architecture
- Implementing aggressive caching to reduce object allocation
- Breaking monolithic services into smaller, more manageable heaps
- Careful tuning of young generation sizes to match object lifetimes

The lesson: GC pause times scale with live data. Smaller heaps mean shorter pauses.

### 17.2 LinkedIn's G1 Migration

LinkedIn documented their migration from CMS to G1 for their large-scale Java services. Key findings:

- G1 reduced tail latency variance significantly
- Full GC events dropped from weekly to nearly never
- Memory overhead increased due to remembered sets
- Initial tuning was critical—default settings weren't optimal

They recommended:

```bash
# LinkedIn's G1 starting configuration
-XX:+UseG1GC
-XX:MaxGCPauseMillis=100
-XX:G1HeapRegionSize=32m
-XX:InitiatingHeapOccupancyPercent=35
```

### 17.3 Discord's JVM to Go Migration

Discord migrated their Read States service from JVM to Go specifically due to GC issues:

- The service had 250 million messages to track
- JVM GC pauses caused latency spikes every few minutes
- Large heap size (300GB) made pauses unavoidable

Go's GC, designed for low latency, provided:

- Sub-millisecond pauses
- More predictable performance
- Lower memory overhead for their data structure patterns

This illustrates that sometimes the right fix isn't tuning—it's changing the platform.

### 17.4 Azul's Pauseless GC

Azul Systems built specialized hardware and software for pauseless GC:

- Custom CPU with hardware read barriers
- C4 collector with concurrent marking and compaction
- Pauses consistently under 1ms for heaps over 100GB

While expensive, Azul proved that GC pauses aren't inevitable—they're engineering trade-offs.

## 18. GC-Friendly Programming Patterns

Good code works with the GC, not against it. These patterns reduce allocation pressure and improve collection efficiency.

### 18.1 Object Pooling

Instead of allocating new objects, reuse them:

```java
public class ConnectionPool {
    private final Queue<Connection> pool = new ConcurrentLinkedQueue<>();

    public Connection acquire() {
        Connection conn = pool.poll();
        if (conn == null) {
            conn = new Connection();
        }
        return conn;
    }

    public void release(Connection conn) {
        conn.reset();
        pool.offer(conn);
    }
}
```

Pooling is especially effective for:

- Large objects (reduce allocation cost)
- Frequently allocated objects (reduce GC pressure)
- Objects with expensive initialization

### 18.2 Avoiding Boxing

Primitive boxing creates garbage:

```java
// Bad: Creates Integer objects
List<Integer> values = new ArrayList<>();
for (int i = 0; i < 1000000; i++) {
    values.add(i);  // Autoboxing creates Integer
}

// Better: Use primitive collections
IntList values = new IntArrayList();
for (int i = 0; i < 1000000; i++) {
    values.add(i);  // No boxing
}
```

Libraries like Eclipse Collections, FastUtil, and Trove provide primitive collections.

### 18.3 String Optimization

Strings are allocation-heavy:

```java
// Bad: Creates many intermediate strings
String result = "";
for (String s : strings) {
    result += s;  // New String each iteration
}

// Better: StringBuilder
StringBuilder sb = new StringBuilder();
for (String s : strings) {
    sb.append(s);  // Modifies buffer in place
}
String result = sb.toString();

// Even better: String.join() or Stream.collect()
String result = String.join("", strings);
```

### 18.4 Lazy Initialization

Don't allocate until needed:

```java
public class LazyHolder {
    private ExpensiveObject obj;

    public ExpensiveObject get() {
        if (obj == null) {
            obj = new ExpensiveObject();
        }
        return obj;
    }
}
```

For thread safety, use double-checked locking or holder class pattern.

### 18.5 Off-Heap Data Structures

For large data sets, consider off-heap storage:

```java
// On-heap: 1 million entries = ~40MB + GC pressure
Map<Long, Long> onHeap = new HashMap<>();

// Off-heap: Same data, no GC impact
Chronicle chronicle = ChronicleMapBuilder
    .of(Long.class, Long.class)
    .entries(1_000_000)
    .create();
```

Libraries like Chronicle Map, MapDB, and RocksDB provide off-heap alternatives.

### 18.6 Allocation-Free Algorithms

Some algorithms can avoid allocation entirely:

```java
// Allocating version
public List<Integer> findPrimes(int max) {
    List<Integer> primes = new ArrayList<>();
    // ... populate list
    return primes;
}

// Allocation-free version
public void forEachPrime(int max, IntConsumer consumer) {
    // ... call consumer.accept() for each prime
}
```

The callback pattern moves allocation to the caller's choice.

## 19. Debugging GC Issues

When GC becomes a problem, systematic debugging is essential.

### 19.1 GC Logging Best Practices

Enable comprehensive logging:

```bash
# Java 11+ unified logging
java -Xlog:gc*=info:file=gc.log:time,uptime,level,tags:filecount=10,filesize=100m

# Key patterns to grep:
# - "Pause" - STW events
# - "Concurrent" - Background work
# - "Allocation Failure" - Why GC triggered
# - "Promotion Failure" - Tenuring problems
```

### 19.2 Key Metrics to Monitor

Track these in production:

```java
// Using JMX
for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
    System.out.println(gc.getName() + ": " +
        gc.getCollectionCount() + " collections, " +
        gc.getCollectionTime() + " ms total");
}
```

Important metrics:

- **GC frequency:** Collections per minute
- **GC duration:** p50, p99, max pause times
- **Throughput:** Time not spent in GC
- **Allocation rate:** MB/s of new allocations
- **Promotion rate:** MB/s promoted to old generation
- **Live data size:** Old gen occupancy after full GC

### 19.3 Heap Dump Analysis

When you suspect a leak:

```bash
# Trigger heap dump
jcmd <pid> GC.heap_dump /tmp/heap.hprof

# Analyze with Eclipse MAT, VisualVM, or YourKit
# Look for:
# - Dominator trees (what holds most memory)
# - Leak suspects (unexpected retainers)
# - Duplicate objects (repeated allocations)
```

### 19.4 Allocation Profiling

Find allocation hotspots:

```bash
# Java Flight Recorder
java -XX:+FlightRecorder -XX:StartFlightRecording=duration=60s,filename=profile.jfr

# async-profiler for allocation profiling
./profiler.sh -e alloc -f alloc.html <pid>
```

### 19.5 Common GC Anti-Patterns

**Humongous allocations in G1:**

```java
// G1 region size = 32MB
byte[] huge = new byte[33 * 1024 * 1024];  // Humongous allocation!
// These are expensive and can cause fragmentation
```

**Finalizer abuse:**

```java
// Finalizers delay collection by at least one GC cycle
protected void finalize() {
    closeResource();  // Don't do this!
}

// Use try-with-resources instead
try (Resource r = new Resource()) {
    // ...
}
```

**Reference leaks:**

```java
// Common leak: static collections
static List<Object> cache = new ArrayList<>();
public void process(Object o) {
    cache.add(o);  // Never removed! Memory leak.
}
```

## 20. GC Across Different Workloads

Different applications have different GC needs. Here's how to think about GC for various workload types.

### 20.1 Batch Processing

Characteristics:

- Large data volumes
- Throughput matters more than latency
- Predictable workload patterns

Recommendations:

```bash
# Maximize throughput with Parallel GC
-XX:+UseParallelGC
-XX:ParallelGCThreads=8
-Xms16g -Xmx16g
```

### 20.2 Web Services

Characteristics:

- Request-response patterns
- Latency-sensitive
- Variable load

Recommendations:

```bash
# G1 for balanced performance
-XX:+UseG1GC
-XX:MaxGCPauseMillis=50
-XX:G1HeapRegionSize=16m
```

### 20.3 Trading Systems

Characteristics:

- Ultra-low latency required
- Predictable worst-case performance
- Often Java + native code

Recommendations:

```bash
# ZGC for minimal pauses
-XX:+UseZGC
-XX:SoftMaxHeapSize=8g
-XX:ZCollectionInterval=0  # Only collect when needed

# Or completely avoid GC in hot path
# - Pre-allocate all objects
# - Use primitive arrays
# - Off-heap data structures
```

### 20.4 Big Data (Spark, Flink)

Characteristics:

- Very large heaps
- Mix of long-lived and short-lived data
- Managed frameworks with their own memory management

Recommendations:

```bash
# Often use aggressive young gen sizing
-XX:+UseG1GC
-XX:NewRatio=1  # Equal young and old
-XX:MaxGCPauseMillis=200

# Spark-specific: configure off-heap memory
spark.memory.offHeap.enabled=true
spark.memory.offHeap.size=8g
```

## 21. Summary

Garbage collection has evolved from simple mark-and-sweep to sophisticated concurrent collectors:

- **Reference counting** is simple but can't handle cycles
- **Mark-and-sweep** handles cycles but fragments memory
- **Copying collection** compacts but wastes space
- **Generational collection** exploits the weak generational hypothesis
- **Concurrent collectors** minimize pause times at the cost of throughput

Modern collectors like G1, Shenandoah, and ZGC offer different trade-offs:

- **G1:** Balanced performance, predictable pauses, good default choice
- **Shenandoah:** Sub-10ms pauses, concurrent compaction
- **ZGC:** Sub-millisecond pauses, scales to terabytes

Key insights for practitioners:

1. **Choose the right collector:** Match GC to workload characteristics
2. **Measure before tuning:** GC logs are your friend
3. **Reduce allocation rate:** The best GC is no GC
4. **Understand trade-offs:** Latency vs. throughput vs. memory
5. **Write GC-friendly code:** Pooling, primitive collections, lazy initialization

Garbage collection remains an active research area. As applications demand ever-larger heaps and ever-lower latencies, collectors continue to evolve. Understanding GC internals helps you write better code, tune more effectively, and choose the right tools for your applications.

The collector that runs invisibly in the background is the result of decades of computer science research. Appreciate it—and understand it—every time you allocate an object without worrying about when to free it.
