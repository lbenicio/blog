---
title: "Concurrency Primitives and Synchronization: From Spinlocks to Lock-Free Data Structures"
description: "A comprehensive exploration of concurrent programming fundamentals, covering mutexes, spinlocks, semaphores, condition variables, memory ordering, and lock-free programming techniques that enable safe parallel execution."
date: "2024-03-15"
author: "Leonardo Benicio"
tags: ["concurrency", "locks", "synchronization", "multithreading", "atomics", "fundamentals"]
categories: ["fundamentals", "systems"]
draft: false
cover: "static/images/blog/concurrency-primitives-locks-synchronization.png"
coverAlt: "Visualization of multiple threads coordinating access to shared resources through various synchronization primitives"
---

Concurrent programming transforms sequential code into parallel execution, unlocking the power of modern multicore processors. But with parallelism comes the challenge of coordinating access to shared resources. Race conditions lurk in code that appears correct, and subtle bugs emerge only under specific timing conditions. Understanding synchronization primitives from the hardware level up through high-level abstractions provides the foundation for writing correct, efficient concurrent programs.

## 1. The Concurrency Challenge

Why synchronization matters and what problems it solves.

### 1.1 Race Conditions

```text
The fundamental problem with shared mutable state:

Two threads incrementing a counter:
┌─────────────────────────────────────────────────────────┐
│  Initial: counter = 0                                   │
│                                                         │
│  Thread A              Thread B                         │
│  ─────────             ─────────                        │
│  read counter (0)                                       │
│                        read counter (0)                 │
│  add 1 → 1                                             │
│                        add 1 → 1                        │
│  write counter (1)                                      │
│                        write counter (1)                │
│                                                         │
│  Final: counter = 1  (should be 2!)                    │
└─────────────────────────────────────────────────────────┘

The increment operation (counter++) is not atomic:
1. Load value from memory
2. Add one to value
3. Store result to memory

Any interleaving of these steps between threads causes bugs.
```

### 1.2 Critical Sections

```text
Protecting shared resources:

┌─────────────────────────────────────────────────────────┐
│  Critical section: Code that accesses shared resources │
│                                                         │
│  // Non-critical section (thread-local work)           │
│  prepare_data();                                       │
│                                                         │
│  // Enter critical section                             │
│  lock(mutex);                                          │
│  ┌─────────────────────────────────────────┐           │
│  │  shared_counter++;                       │ Critical │
│  │  shared_list.append(item);               │ Section  │
│  └─────────────────────────────────────────┘           │
│  unlock(mutex);                                        │
│                                                         │
│  // Non-critical section                               │
│  process_results();                                    │
└─────────────────────────────────────────────────────────┘

Goals:
- Mutual exclusion: Only one thread in critical section
- Progress: If no thread in CS, one waiting thread can enter
- Bounded waiting: No thread waits forever
- Performance: Minimize time spent in synchronization
```

### 1.3 Atomicity Levels

```text
Different guarantees for different operations:

Level 1: Single memory access
- Reading/writing aligned word is atomic on most architectures
- int x = 5; // Atomic if x is aligned
- But: No ordering guarantees with other operations

Level 2: Read-modify-write (RMW)
- Atomic increment, compare-and-swap, etc.
- Hardware provides special instructions
- x.fetch_add(1); // Atomic increment

Level 3: Multiple operations
- Update multiple variables atomically
- Requires explicit synchronization
- transfer(a, b, amount); // Needs lock

Level 4: Transactions
- Arbitrary code executed atomically
- Database transactions, software transactional memory
- Most complex, highest overhead
```

## 2. Hardware Foundations

The atomic operations that make synchronization possible.

### 2.1 Atomic Instructions

```text
CPU provides atomic read-modify-write instructions:

Compare-And-Swap (CAS):
┌─────────────────────────────────────────────────────────┐
│  // Atomic: if *addr == expected, set *addr = desired  │
│  bool CAS(int *addr, int expected, int desired) {      │
│      // Hardware ensures atomicity                     │
│      if (*addr == expected) {                          │
│          *addr = desired;                              │
│          return true;                                  │
│      }                                                 │
│      return false;                                     │
│  }                                                     │
│                                                         │
│  x86: CMPXCHG instruction                              │
│  ARM: LDREX/STREX (load-link/store-conditional)        │
└─────────────────────────────────────────────────────────┘

Fetch-And-Add:
┌─────────────────────────────────────────────────────────┐
│  // Atomic: return old value, add to memory            │
│  int fetch_add(int *addr, int value) {                 │
│      int old = *addr;                                  │
│      *addr = old + value;                              │
│      return old;                                       │
│  }                                                     │
│                                                         │
│  x86: LOCK XADD instruction                            │
└─────────────────────────────────────────────────────────┘

Test-And-Set:
┌─────────────────────────────────────────────────────────┐
│  // Atomic: set to 1, return previous value            │
│  int test_and_set(int *addr) {                         │
│      int old = *addr;                                  │
│      *addr = 1;                                        │
│      return old;                                       │
│  }                                                     │
│                                                         │
│  x86: LOCK XCHG instruction                            │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Memory Barriers

```text
CPUs reorder memory operations for performance:

Without barriers:
┌─────────────────────────────────────────────────────────┐
│  // Thread A                // Thread B                 │
│  data = 42;                 while (!ready);            │
│  ready = true;              print(data);               │
│                                                         │
│  Problem: CPU might reorder ready = true before data!  │
│  Thread B could see ready=true but data=0              │
└─────────────────────────────────────────────────────────┘

Memory barrier types:

Load barrier (acquire):
- All loads after barrier see effects of loads before barrier
- Prevents load-load reordering

Store barrier (release):
- All stores before barrier complete before stores after
- Prevents store-store reordering

Full barrier:
- Combines load and store barriers
- Most expensive, strongest guarantee

x86 example:
// Store barrier
_mm_sfence();  // All prior stores complete

// Load barrier
_mm_lfence();  // All prior loads complete

// Full barrier
_mm_mfence();  // All prior memory ops complete
__sync_synchronize();  // GCC built-in
```

### 2.3 Cache Coherence Effects

```text
Atomic operations interact with cache coherence:

CAS on cached line:
┌─────────────────────────────────────────────────────────┐
│  1. Acquire exclusive ownership of cache line (MESI)   │
│  2. Perform atomic operation                           │
│  3. Other cores see invalidation                       │
│  4. They must re-fetch line to access                  │
│                                                         │
│  Cost: 50-100+ cycles for cross-core communication    │
└─────────────────────────────────────────────────────────┘

Contention impact:
┌─────────────────────────────────────────────────────────┐
│  Threads    │ Uncontended CAS │ Contended CAS          │
│  ───────────┼─────────────────┼────────────────────────│
│      1      │     10 ns       │    N/A                 │
│      2      │     10 ns       │    50 ns               │
│      4      │     10 ns       │   150 ns               │
│      8      │     10 ns       │   400 ns               │
│     16      │     10 ns       │  1000+ ns              │
└─────────────────────────────────────────────────────────┘

Cache line bouncing:
- High contention = line constantly moving between cores
- Each CAS pays full coherence penalty
- Solution: Reduce contention, use local operations
```

## 3. Spinlocks

The simplest synchronization primitive.

### 3.1 Basic Spinlock

```c
// Simplest spinlock using test-and-set
typedef struct {
    volatile int locked;
} spinlock_t;

void spin_lock(spinlock_t *lock) {
    while (__sync_lock_test_and_set(&lock->locked, 1)) {
        // Spin until we acquire the lock
    }
}

void spin_unlock(spinlock_t *lock) {
    __sync_lock_release(&lock->locked);
}

// Usage:
spinlock_t lock = {0};
spin_lock(&lock);
// Critical section
shared_counter++;
spin_unlock(&lock);
```

### 3.2 Test-and-Test-and-Set

```text
Problem with basic spinlock: Constant cache line bouncing

Every test_and_set acquires line exclusively, even while spinning.

Solution: Test-and-Test-and-Set (TTAS)
┌─────────────────────────────────────────────────────────┐
│  void spin_lock_ttas(spinlock_t *lock) {               │
│      while (1) {                                       │
│          // Spin on local cache (read-only)            │
│          while (lock->locked) {                        │
│              // No bus traffic while spinning          │
│              cpu_relax();  // Hint: we're spinning    │
│          }                                             │
│          // Try to acquire                             │
│          if (!__sync_lock_test_and_set(&lock->locked, 1))│
│              return;  // Got the lock!                 │
│      }                                                 │
│  }                                                     │
└─────────────────────────────────────────────────────────┘

Performance difference:
┌─────────────────────────────────────────────────────────┐
│  Threads │ TAS spinlock │ TTAS spinlock                │
│  ────────┼──────────────┼────────────────────────────  │
│     4    │   2.5M ops/s │   8M ops/s                   │
│     8    │   800K ops/s │   5M ops/s                   │
│    16    │   200K ops/s │   3M ops/s                   │
└─────────────────────────────────────────────────────────┘
```

### 3.3 Ticket Lock

```text
Problem: Basic spinlocks don't guarantee fairness

Thread might wait forever while others repeatedly acquire lock.

Ticket lock provides FIFO ordering:
┌─────────────────────────────────────────────────────────┐
│  typedef struct {                                       │
│      volatile unsigned int next_ticket;                │
│      volatile unsigned int now_serving;                │
│  } ticket_lock_t;                                      │
│                                                         │
│  void ticket_lock(ticket_lock_t *lock) {               │
│      // Get my ticket (atomic increment)              │
│      unsigned int my_ticket =                          │
│          __sync_fetch_and_add(&lock->next_ticket, 1);  │
│                                                         │
│      // Wait until my number is called                 │
│      while (lock->now_serving != my_ticket) {          │
│          cpu_relax();                                  │
│      }                                                 │
│  }                                                     │
│                                                         │
│  void ticket_unlock(ticket_lock_t *lock) {             │
│      // Call next number                               │
│      lock->now_serving++;                              │
│  }                                                     │
└─────────────────────────────────────────────────────────┘

Visualization:
next_ticket: 5  (next thread gets ticket 5)
now_serving: 3  (currently serving ticket 3)

Threads waiting: [3:running] [4:spinning] [5:spinning]...
```

### 3.4 When to Use Spinlocks

```text
Spinlocks are appropriate when:
✓ Critical section is very short (< 1 microsecond)
✓ Lock hold time is predictable
✓ Thread won't be preempted while holding lock
✓ Running on dedicated cores (no oversubscription)

Spinlocks are inappropriate when:
✗ Critical section might block (I/O, allocation)
✗ Hold time varies significantly
✗ More threads than cores
✗ Thread might be preempted (priority inversion)

CPU hint for spinning:
// x86: PAUSE instruction
// ARM: YIELD instruction
// Reduces power, helps hyperthreading
void cpu_relax() {
    __asm__ __volatile__("pause" ::: "memory");
}
```

## 4. Mutexes and Blocking Locks

When spinning wastes resources.

### 4.1 Mutex Internals

```text
Mutex: Block thread instead of spinning

Conceptual implementation:
┌─────────────────────────────────────────────────────────┐
│  typedef struct {                                       │
│      int locked;                                       │
│      queue_t waiters;  // Threads waiting for lock     │
│  } mutex_t;                                            │
│                                                         │
│  void mutex_lock(mutex_t *m) {                         │
│      if (!try_lock(&m->locked)) {                      │
│          // Add self to wait queue                     │
│          enqueue(&m->waiters, current_thread);         │
│          // Block until woken                          │
│          block_current_thread();                       │
│      }                                                 │
│  }                                                     │
│                                                         │
│  void mutex_unlock(mutex_t *m) {                       │
│      m->locked = 0;                                    │
│      if (!empty(&m->waiters)) {                        │
│          thread_t *next = dequeue(&m->waiters);        │
│          wake_thread(next);                            │
│      }                                                 │
│  }                                                     │
└─────────────────────────────────────────────────────────┘

Linux futex (Fast Userspace muTEX):
- Uncontended case: No system call needed
- Contended: System call to block/wake
- Best of both worlds
```

### 4.2 Futex Details

```c
// Linux futex-based mutex

typedef struct {
    int state;  // 0=unlocked, 1=locked-no-waiters, 2=locked-with-waiters
} futex_mutex_t;

void futex_lock(futex_mutex_t *m) {
    int c;
    // Fast path: uncontended
    if ((c = __sync_val_compare_and_swap(&m->state, 0, 1)) == 0)
        return;  // Got lock, no syscall needed

    // Slow path: contended
    do {
        // Mark as having waiters
        if (c == 2 || __sync_val_compare_and_swap(&m->state, 1, 2) != 0) {
            // Block in kernel until state changes
            syscall(SYS_futex, &m->state, FUTEX_WAIT, 2, NULL, NULL, 0);
        }
    } while ((c = __sync_val_compare_and_swap(&m->state, 0, 2)) != 0);
}

void futex_unlock(futex_mutex_t *m) {
    // Unlock
    if (__sync_fetch_and_sub(&m->state, 1) != 1) {
        // There were waiters
        m->state = 0;
        syscall(SYS_futex, &m->state, FUTEX_WAKE, 1, NULL, NULL, 0);
    }
}
```

### 4.3 Adaptive Mutexes

```text
Hybrid approach: Spin briefly, then block

┌─────────────────────────────────────────────────────────┐
│  void adaptive_lock(mutex_t *m) {                      │
│      int spin_count = 0;                               │
│      const int MAX_SPINS = 1000;                       │
│                                                         │
│      while (!try_lock(m)) {                            │
│          if (spin_count < MAX_SPINS) {                 │
│              // Owner is running? Spin a bit          │
│              if (is_owner_running(m)) {                │
│                  cpu_relax();                          │
│                  spin_count++;                         │
│                  continue;                             │
│              }                                         │
│          }                                             │
│          // Spinning didn't help, block               │
│          block_wait(m);                                │
│          spin_count = 0;                               │
│      }                                                 │
│  }                                                     │
└─────────────────────────────────────────────────────────┘

Why this works:
- Short critical sections: Spinning avoids syscall overhead
- Long critical sections: Blocking avoids wasting CPU
- Owner preempted: Blocking is better than spinning
```

### 4.4 Priority Inheritance

```text
Priority inversion problem:

Without priority inheritance:
┌─────────────────────────────────────────────────────────┐
│  Low priority thread L holds lock                      │
│  High priority thread H waits for lock                 │
│  Medium priority thread M preempts L                   │
│                                                         │
│  Result: H waits for M (lower priority!) to finish    │
│  This is priority inversion                            │
└─────────────────────────────────────────────────────────┘

With priority inheritance:
┌─────────────────────────────────────────────────────────┐
│  L holds lock, H waits                                 │
│  L temporarily inherits H's priority                   │
│  M cannot preempt L                                    │
│  L finishes, releases lock, priority returns to normal│
│  H gets lock immediately                               │
└─────────────────────────────────────────────────────────┘

Real-world: Mars Pathfinder (1997)
- Priority inversion caused system resets
- Fixed with priority inheritance
```

## 5. Reader-Writer Locks

Optimizing for read-heavy workloads.

### 5.1 Basic Reader-Writer Lock

```text
Allow multiple readers OR one writer:

┌─────────────────────────────────────────────────────────┐
│  State transitions:                                     │
│                                                         │
│  ┌─────────┐  read_lock   ┌─────────┐                  │
│  │  Free   │ ───────────► │ Reading │                  │
│  │         │ ◄─────────── │ (n > 0) │                  │
│  └────┬────┘  read_unlock └────┬────┘                  │
│       │                        │                        │
│       │write_lock              │ (blocked)             │
│       ▼                        │                        │
│  ┌─────────┐                   │                        │
│  │ Writing │ ◄─────────────────┘ (when n = 0)          │
│  │         │                                            │
│  └─────────┘                                            │
│                                                         │
│  Concurrent readers: ✓ Yes                             │
│  Reader + Writer:    ✗ No                              │
│  Writer + Writer:    ✗ No                              │
└─────────────────────────────────────────────────────────┘
```

### 5.2 Implementation

```c
typedef struct {
    int readers;        // Number of active readers
    int writer;         // Writer active flag
    int write_waiters;  // Writers waiting
    mutex_t mutex;      // Protects state
    cond_t read_ok;     // Readers can proceed
    cond_t write_ok;    // Writer can proceed
} rwlock_t;

void read_lock(rwlock_t *rw) {
    mutex_lock(&rw->mutex);
    // Wait if writer active or writers waiting (writer preference)
    while (rw->writer || rw->write_waiters > 0) {
        cond_wait(&rw->read_ok, &rw->mutex);
    }
    rw->readers++;
    mutex_unlock(&rw->mutex);
}

void read_unlock(rwlock_t *rw) {
    mutex_lock(&rw->mutex);
    rw->readers--;
    if (rw->readers == 0) {
        cond_signal(&rw->write_ok);  // Wake waiting writer
    }
    mutex_unlock(&rw->mutex);
}

void write_lock(rwlock_t *rw) {
    mutex_lock(&rw->mutex);
    rw->write_waiters++;
    while (rw->readers > 0 || rw->writer) {
        cond_wait(&rw->write_ok, &rw->mutex);
    }
    rw->write_waiters--;
    rw->writer = 1;
    mutex_unlock(&rw->mutex);
}

void write_unlock(rwlock_t *rw) {
    mutex_lock(&rw->mutex);
    rw->writer = 0;
    cond_broadcast(&rw->read_ok);  // Wake all readers
    cond_signal(&rw->write_ok);    // Wake one writer
    mutex_unlock(&rw->mutex);
}
```

### 5.3 Scalability Issues

```text
Problem: Reader lock still causes contention

Every read_lock/read_unlock modifies shared counter:
- Cache line bounces between cores
- Scales poorly with many readers

Solutions:

1. Per-CPU reader counts:
┌─────────────────────────────────────────────────────────┐
│  struct percpu_rwlock {                                │
│      int reader_count[NUM_CPUS];  // Per-CPU counters  │
│      int writer;                                       │
│  };                                                    │
│                                                         │
│  read_lock: increment local CPU's counter (no sharing) │
│  write_lock: Wait for ALL per-CPU counters to be 0    │
└─────────────────────────────────────────────────────────┘

2. Seqlock (optimistic readers):
┌─────────────────────────────────────────────────────────┐
│  Readers don't acquire lock at all                     │
│  Writers increment sequence number before/after        │
│  Readers check: did sequence change during read?       │
│  If so, retry                                          │
└─────────────────────────────────────────────────────────┘

3. RCU (Read-Copy-Update):
- Readers are wait-free (no synchronization)
- Writers create new version, wait for readers to finish
- Covered in advanced section
```

### 5.4 Seqlock Implementation

```c
typedef struct {
    unsigned int sequence;  // Even = unlocked, Odd = write in progress
    // Protected data follows
} seqlock_t;

// Writer side
void write_seqlock(seqlock_t *sl) {
    sl->sequence++;  // Odd: write starting
    __sync_synchronize();  // Memory barrier
}

void write_sequnlock(seqlock_t *sl) {
    __sync_synchronize();  // Memory barrier
    sl->sequence++;  // Even again: write complete
}

// Reader side (no lock!)
unsigned int read_seqbegin(seqlock_t *sl) {
    unsigned int seq;
    do {
        seq = sl->sequence;
    } while (seq & 1);  // Wait if write in progress
    __sync_synchronize();
    return seq;
}

int read_seqretry(seqlock_t *sl, unsigned int seq) {
    __sync_synchronize();
    return sl->sequence != seq;  // True if must retry
}

// Usage:
unsigned int seq;
do {
    seq = read_seqbegin(&lock);
    // Read shared data (might be inconsistent)
    value = shared_data;
} while (read_seqretry(&lock, seq));
// Now value is consistent
```

## 6. Condition Variables

Waiting for arbitrary conditions.

### 6.1 Condition Variable Basics

```text
Wait for a condition to become true:

┌─────────────────────────────────────────────────────────┐
│  Producer-Consumer with condition variable:            │
│                                                         │
│  Producer:                                             │
│  mutex_lock(&m);                                       │
│  buffer[tail++] = item;                                │
│  cond_signal(&not_empty);  // Wake one consumer        │
│  mutex_unlock(&m);                                     │
│                                                         │
│  Consumer:                                             │
│  mutex_lock(&m);                                       │
│  while (is_empty()) {  // While, not if!              │
│      cond_wait(&not_empty, &m);  // Releases mutex     │
│  }                                                     │
│  item = buffer[head++];                                │
│  mutex_unlock(&m);                                     │
└─────────────────────────────────────────────────────────┘

Why "while" not "if"?
- Spurious wakeups (pthread allows them)
- Multiple waiters: Only one gets the item
- Condition might change before we reacquire mutex
```

### 6.2 Wait Mechanics

```text
cond_wait() does three things atomically:

1. Release the mutex
2. Add thread to condition's wait queue
3. Block thread

┌─────────────────────────────────────────────────────────┐
│  // This would be wrong (race condition):              │
│  mutex_unlock(&m);   // ← Another thread could signal │
│  wait(&cond);        //   here and we'd miss it!      │
│  mutex_lock(&m);                                       │
│                                                         │
│  // cond_wait does this atomically:                    │
│  cond_wait(&cond, &m) {                                │
│      atomically {                                      │
│          unlock(m);                                    │
│          add_to_waitqueue(cond, self);                 │
│          block();                                      │
│      }                                                 │
│      // When woken:                                    │
│      lock(m);  // Reacquire before returning          │
│  }                                                     │
└─────────────────────────────────────────────────────────┘
```

### 6.3 Signal vs Broadcast

```text
cond_signal(): Wake ONE waiting thread
cond_broadcast(): Wake ALL waiting threads

When to use signal:
- Any waiter can handle the condition
- Exactly one thread should proceed
- Producer-consumer with single item

When to use broadcast:
- Waiters have different predicates
- State change affects multiple waiters
- Shutdown notification

Example needing broadcast:
┌─────────────────────────────────────────────────────────┐
│  // Thread 1 waits for x > 10                          │
│  while (x <= 10) cond_wait(&c, &m);                    │
│                                                         │
│  // Thread 2 waits for x > 20                          │
│  while (x <= 20) cond_wait(&c, &m);                    │
│                                                         │
│  // Thread 3 sets x = 15                               │
│  x = 15;                                               │
│  cond_signal(&c);  // Wrong! Might wake Thread 2      │
│  cond_broadcast(&c);  // Correct: both check condition│
└─────────────────────────────────────────────────────────┘
```

### 6.4 Bounded Buffer Example

```c
typedef struct {
    int buffer[SIZE];
    int head, tail, count;
    mutex_t mutex;
    cond_t not_full;
    cond_t not_empty;
} bounded_buffer_t;

void produce(bounded_buffer_t *bb, int item) {
    mutex_lock(&bb->mutex);

    // Wait while buffer is full
    while (bb->count == SIZE) {
        cond_wait(&bb->not_full, &bb->mutex);
    }

    // Add item
    bb->buffer[bb->tail] = item;
    bb->tail = (bb->tail + 1) % SIZE;
    bb->count++;

    // Signal: buffer is no longer empty
    cond_signal(&bb->not_empty);

    mutex_unlock(&bb->mutex);
}

int consume(bounded_buffer_t *bb) {
    mutex_lock(&bb->mutex);

    // Wait while buffer is empty
    while (bb->count == 0) {
        cond_wait(&bb->not_empty, &bb->mutex);
    }

    // Remove item
    int item = bb->buffer[bb->head];
    bb->head = (bb->head + 1) % SIZE;
    bb->count--;

    // Signal: buffer is no longer full
    cond_signal(&bb->not_full);

    mutex_unlock(&bb->mutex);
    return item;
}
```

## 7. Semaphores

Generalized synchronization counters.

### 7.1 Semaphore Operations

```text
Semaphore: Integer counter with atomic operations

P (wait/down): Decrement, block if would go negative
V (signal/up): Increment, wake one waiter

┌─────────────────────────────────────────────────────────┐
│  void sem_wait(sem_t *s) {                             │
│      while (s->count <= 0) {                           │
│          block();                                      │
│      }                                                 │
│      s->count--;  // Atomic with check                 │
│  }                                                     │
│                                                         │
│  void sem_post(sem_t *s) {                             │
│      s->count++;                                       │
│      if (waiters_exist()) {                            │
│          wake_one();                                   │
│      }                                                 │
│  }                                                     │
└─────────────────────────────────────────────────────────┘

Types:
- Binary semaphore (count 0 or 1): Like mutex
- Counting semaphore: Track multiple resources
```

### 7.2 Common Patterns

```text
1. Mutual exclusion (binary semaphore):
sem_t mutex = 1;
sem_wait(&mutex);  // Enter critical section
// Critical section
sem_post(&mutex);  // Leave critical section

2. Resource pool:
sem_t pool = N;  // N resources available
sem_wait(&pool);  // Get a resource
use_resource();
sem_post(&pool);  // Return resource

3. Signaling between threads:
sem_t done = 0;

Thread A:                Thread B:
do_work();               sem_wait(&done);
sem_post(&done);         use_result();

4. Barrier (rendezvous):
sem_t barrier1 = 0, barrier2 = 0;

Thread A:                Thread B:
phase1_A();              phase1_B();
sem_post(&barrier1);     sem_post(&barrier2);
sem_wait(&barrier2);     sem_wait(&barrier1);
phase2_A();              phase2_B();
```

### 7.3 Producer-Consumer with Semaphores

```c
#define BUFFER_SIZE 10

int buffer[BUFFER_SIZE];
int in = 0, out = 0;

sem_t empty;  // Count of empty slots
sem_t full;   // Count of filled slots
sem_t mutex;  // Mutual exclusion

void init() {
    sem_init(&empty, BUFFER_SIZE);  // All slots empty
    sem_init(&full, 0);             // No items yet
    sem_init(&mutex, 1);            // Binary semaphore
}

void producer(int item) {
    sem_wait(&empty);     // Wait for empty slot
    sem_wait(&mutex);     // Enter critical section

    buffer[in] = item;
    in = (in + 1) % BUFFER_SIZE;

    sem_post(&mutex);     // Leave critical section
    sem_post(&full);      // Signal: one more item
}

int consumer() {
    sem_wait(&full);      // Wait for item
    sem_wait(&mutex);     // Enter critical section

    int item = buffer[out];
    out = (out + 1) % BUFFER_SIZE;

    sem_post(&mutex);     // Leave critical section
    sem_post(&empty);     // Signal: one more empty slot
    return item;
}
```

### 7.4 Semaphores vs Condition Variables

```text
Semaphores:
✓ Simpler mental model (just a counter)
✓ Can signal before wait (signal is "remembered")
✓ Good for counting resources
✗ No built-in mutex, must manage separately
✗ Easy to misuse (forget to signal)

Condition Variables:
✓ Paired with mutex (clearer ownership)
✓ Flexible predicates (any condition)
✓ broadcast() for multiple waiters
✗ Spurious wakeups require while loop
✗ Signal is "lost" if no one waiting

Generally prefer condition variables for new code.
Semaphores still useful for specific patterns.
```

## 8. Memory Ordering and Atomics

The foundation of lock-free programming.

### 8.1 C++11/C11 Memory Model

```text
Memory orderings from weakest to strongest:

memory_order_relaxed:
- Only guarantees atomicity
- No ordering constraints
- Fastest, but hardest to reason about

memory_order_acquire:
- All reads/writes after this see prior writes
- Used for lock acquisition

memory_order_release:
- All prior reads/writes complete before this
- Used for lock release

memory_order_acq_rel:
- Combines acquire and release
- For read-modify-write operations

memory_order_seq_cst:
- Sequential consistency
- All threads see same order
- Slowest, but easiest to reason about
```

### 8.2 Atomic Operations

```cpp
#include <atomic>

std::atomic<int> counter{0};

// Relaxed: Just atomic, no ordering
counter.store(5, std::memory_order_relaxed);
int x = counter.load(std::memory_order_relaxed);

// Acquire-release: Synchronization
std::atomic<bool> ready{false};
int data;

// Writer (release)
data = 42;
ready.store(true, std::memory_order_release);

// Reader (acquire)
while (!ready.load(std::memory_order_acquire));
assert(data == 42);  // Guaranteed!

// Compare-and-swap
int expected = 0;
bool success = counter.compare_exchange_strong(
    expected, 1, std::memory_order_acq_rel);

// Fetch-and-add
int old = counter.fetch_add(1, std::memory_order_relaxed);
```

### 8.3 The Happens-Before Relationship

```text
Happens-before establishes ordering:

A happens-before B if:
1. A is sequenced-before B in same thread
2. A synchronizes-with B (release/acquire pair)
3. A happens-before X and X happens-before B (transitive)

Example:
┌─────────────────────────────────────────────────────────┐
│  Thread 1:                Thread 2:                     │
│  x = 1;           (a)                                   │
│  y = 2;           (b)                                   │
│  flag.store(true, (c)     while(!flag.load(acquire));(d)│
│    release);              r1 = y;               (e)     │
│                           r2 = x;               (f)     │
│                                                         │
│  (a) sequenced-before (b) sequenced-before (c)         │
│  (c) synchronizes-with (d)                             │
│  (d) sequenced-before (e) sequenced-before (f)         │
│                                                         │
│  Therefore: (a),(b) happen-before (e),(f)              │
│  Result: r1 = 2, r2 = 1 guaranteed                     │
└─────────────────────────────────────────────────────────┘
```

### 8.4 Common Pitfalls

```text
1. Data race (undefined behavior):
int x = 0;
// Thread 1: x = 1;
// Thread 2: int y = x;
// Not atomic, not synchronized = UB!

2. Relaxed ordering surprise:
std::atomic<int> x{0}, y{0};
// Thread 1: x.store(1, relaxed); y.store(1, relaxed);
// Thread 2: r1 = y.load(relaxed); r2 = x.load(relaxed);
// Possible: r1 = 1, r2 = 0 (reordering allowed!)

3. ABA problem:
// CAS sees expected value, assumes nothing changed
// But: value changed A→B→A, state is different!
// Solution: Use tagged pointers or hazard pointers

4. False sharing:
struct { std::atomic<int> a; std::atomic<int> b; };
// a and b in same cache line = contention!
// Solution: alignas(64) padding
```

## 9. Lock-Free Data Structures

Synchronization without locks.

### 9.1 Lock-Free Stack

```cpp
template<typename T>
class LockFreeStack {
    struct Node {
        T data;
        Node* next;
    };

    std::atomic<Node*> head{nullptr};

public:
    void push(T value) {
        Node* new_node = new Node{value, nullptr};
        new_node->next = head.load(std::memory_order_relaxed);

        // Keep trying until CAS succeeds
        while (!head.compare_exchange_weak(
            new_node->next, new_node,
            std::memory_order_release,
            std::memory_order_relaxed));
    }

    bool pop(T& result) {
        Node* old_head = head.load(std::memory_order_relaxed);

        while (old_head != nullptr) {
            if (head.compare_exchange_weak(
                old_head, old_head->next,
                std::memory_order_acquire,
                std::memory_order_relaxed)) {
                result = old_head->data;
                // Problem: When to delete old_head?
                // Other threads might still reference it!
                return true;
            }
        }
        return false;  // Stack was empty
    }
};
```

### 9.2 Memory Reclamation Problem

```text
When can we free memory in lock-free structures?

Problem:
┌─────────────────────────────────────────────────────────┐
│  Thread A                    Thread B                   │
│  old = head.load()                                      │
│                              pop() removes old         │
│                              delete old  ← WRONG!       │
│  access old->next  ← CRASH!                            │
└─────────────────────────────────────────────────────────┘

Solutions:

1. Hazard pointers:
- Each thread publishes pointers it's using
- Before freeing, check no thread has hazard on it
- Safe but adds overhead

2. Epoch-based reclamation:
- Global epoch counter
- Thread records current epoch when accessing
- Free only when all threads moved past epoch

3. Reference counting:
- Each node has atomic reference count
- Increment before access, decrement after
- Free when count reaches zero

4. RCU (Read-Copy-Update):
- Readers never block
- Writers wait for grace period
- Linux kernel uses extensively
```

### 9.3 Lock-Free Queue

```cpp
template<typename T>
class LockFreeQueue {
    struct Node {
        T data;
        std::atomic<Node*> next{nullptr};
    };

    std::atomic<Node*> head;
    std::atomic<Node*> tail;

public:
    LockFreeQueue() {
        Node* dummy = new Node{};
        head.store(dummy);
        tail.store(dummy);
    }

    void enqueue(T value) {
        Node* new_node = new Node{value};

        while (true) {
            Node* last = tail.load(std::memory_order_acquire);
            Node* next = last->next.load(std::memory_order_acquire);

            if (last == tail.load(std::memory_order_acquire)) {
                if (next == nullptr) {
                    // Try to link new node
                    if (last->next.compare_exchange_weak(
                            next, new_node,
                            std::memory_order_release)) {
                        // Success, try to move tail
                        tail.compare_exchange_weak(
                            last, new_node,
                            std::memory_order_release);
                        return;
                    }
                } else {
                    // Tail fell behind, help move it
                    tail.compare_exchange_weak(
                        last, next,
                        std::memory_order_release);
                }
            }
        }
    }

    // Dequeue similar but from head...
};
```

### 9.4 When to Use Lock-Free

```text
Lock-free advantages:
✓ No deadlock possible
✓ No priority inversion
✓ Progress guarantee (system-wide)
✓ Often better under high contention

Lock-free disadvantages:
✗ Much harder to implement correctly
✗ Memory reclamation is tricky
✗ May have worse single-thread performance
✗ Debugging is extremely difficult

Use lock-free when:
- High contention expected
- Hard real-time requirements
- Need to avoid priority inversion
- Simple data structure (stack, queue)

Use locks when:
- Low contention
- Complex operations
- Easier maintenance preferred
- Performance isn't extreme requirement
```

### 9.5 Read-Copy-Update (RCU)

```text
RCU: Optimized for read-heavy workloads in kernel

Core idea:
- Readers access data without any synchronization
- Writers create new version, atomically swap pointer
- Old version freed after all readers finish

┌─────────────────────────────────────────────────────────┐
│  Reading (no locks!):                                   │
│  rcu_read_lock();     // Just disable preemption       │
│  ptr = rcu_dereference(global_ptr);                    │
│  use(ptr->data);                                       │
│  rcu_read_unlock();                                    │
│                                                         │
│  Writing:                                              │
│  new = kmalloc(sizeof(*new));                          │
│  *new = *old;         // Copy old data                 │
│  new->field = value;  // Modify                        │
│  rcu_assign_pointer(global_ptr, new);  // Publish      │
│  synchronize_rcu();   // Wait for readers              │
│  kfree(old);          // Now safe to free              │
└─────────────────────────────────────────────────────────┘

Grace period:
┌─────────────────────────────────────────────────────────┐
│  Time →                                                 │
│  ├──────────────────────────────────────────────────►  │
│  │     update     │← grace period →│ reclaim          │
│  │                │                 │                  │
│  Reader A: ████████                                    │
│  Reader B:     ████████████                            │
│  Reader C:              ██████                         │
│                                 │                      │
│  After all readers that started before update finish,  │
│  it's safe to free old data.                           │
└─────────────────────────────────────────────────────────┘

Advantages:
- Zero-overhead readers (no atomics, no cache bouncing)
- Scales perfectly with reader count
- Widely used in Linux kernel
```

## 10. Practical Guidelines

Applying concurrency knowledge effectively.

### 10.1 Design Principles

```text
1. Minimize shared mutable state:
- Thread-local data where possible
- Immutable shared data
- Message passing over shared memory

2. Coarse vs fine-grained locking:
- Start coarse (one big lock)
- Profile to find contention
- Split locks where needed

3. Lock ordering:
- Always acquire locks in same order
- Prevents deadlock
- Document and enforce order

4. Avoid holding locks across I/O:
- I/O is slow and unpredictable
- Hold lock, copy data, release, then do I/O
```

### 10.2 Common Patterns

```text
Thread-safe singleton:
static MyClass& getInstance() {
    static MyClass instance;  // C++11: thread-safe
    return instance;
}

Double-checked locking (fixed):
std::atomic<MyClass*> instance{nullptr};
std::mutex mtx;

MyClass* getInstance() {
    MyClass* tmp = instance.load(std::memory_order_acquire);
    if (tmp == nullptr) {
        std::lock_guard<std::mutex> lock(mtx);
        tmp = instance.load(std::memory_order_relaxed);
        if (tmp == nullptr) {
            tmp = new MyClass();
            instance.store(tmp, std::memory_order_release);
        }
    }
    return tmp;
}

Thread pool pattern:
- Fixed set of worker threads
- Task queue with mutex + condition variable
- Workers wait for tasks, execute, repeat
```

### 10.3 Debugging Concurrent Code

```text
Tools for finding concurrency bugs:

Thread Sanitizer (TSan):
g++ -fsanitize=thread program.cpp
./a.out
# Reports data races at runtime

Helgrind (Valgrind):
valgrind --tool=helgrind ./program
# Detects lock order violations, races

Static analysis:
- Clang Thread Safety Analysis
- Annotate code with thread safety attributes

Stress testing:
- Run with many threads
- Vary timing with delays
- Use CPU affinity to force interleaving

Logging:
- Log lock acquisitions/releases
- Include thread ID and timestamp
- Replay to understand ordering
```

### 10.4 Performance Tuning

```text
Contention profiling:
perf record -e lock:* ./program
perf report

Linux lock statistics:
echo 1 > /proc/sys/kernel/lock_stat
cat /proc/lock_stat

Reducing contention:
1. Shorten critical sections
2. Use reader-writer locks for read-heavy
3. Partition data (per-thread or per-CPU)
4. Batch operations to reduce lock frequency
5. Consider lock-free for hot paths

Cache-friendly synchronization:
- Align lock structures to cache lines
- Avoid false sharing between locks
- Group related data under same lock
```

### 10.5 Deadlock Prevention and Detection

```text
Deadlock conditions (all four required):
1. Mutual exclusion: Resources held exclusively
2. Hold and wait: Hold one, wait for another
3. No preemption: Can't force release
4. Circular wait: A waits for B waits for A

Prevention strategies:

Lock ordering:
┌─────────────────────────────────────────────────────────┐
│  // Always acquire in consistent order                 │
│  #define LOCK_ACCOUNT 1                                │
│  #define LOCK_TRANSFER 2                               │
│                                                         │
│  void transfer(Account *from, Account *to, int amt) {  │
│      // Order by address to ensure consistency         │
│      Account *first = from < to ? from : to;          │
│      Account *second = from < to ? to : from;         │
│      lock(&first->mutex);                              │
│      lock(&second->mutex);                             │
│      // Transfer...                                    │
│      unlock(&second->mutex);                           │
│      unlock(&first->mutex);                            │
│  }                                                     │
└─────────────────────────────────────────────────────────┘

Try-lock with backoff:
┌─────────────────────────────────────────────────────────┐
│  bool acquire_both(mutex *a, mutex *b) {               │
│      while (true) {                                    │
│          lock(a);                                      │
│          if (try_lock(b)) {                            │
│              return true;  // Got both                 │
│          }                                             │
│          unlock(a);                                    │
│          // Backoff to avoid livelock                  │
│          usleep(rand() % 1000);                        │
│      }                                                 │
│  }                                                     │
└─────────────────────────────────────────────────────────┘

Deadlock detection:
- Build lock graph at runtime
- Detect cycles periodically
- Break deadlock by aborting transaction
- Used in databases (transaction rollback)
```

### 10.6 Testing Concurrent Code

```text
Concurrency testing is notoriously difficult:

1. Stress testing:
┌─────────────────────────────────────────────────────────┐
│  // Run many threads with random timing                │
│  for (int t = 0; t < NUM_THREADS; t++) {               │
│      spawn_thread([&] {                                │
│          for (int i = 0; i < ITERATIONS; i++) {        │
│              random_delay();                           │
│              do_operation();                           │
│              verify_invariants();                      │
│          }                                             │
│      });                                               │
│  }                                                     │
└─────────────────────────────────────────────────────────┘

2. Systematic testing (model checking):
- Explore all possible interleavings
- Tools: CHESS, CDSChecker, Relacy
- Exhaustive but slow

3. Fuzzing with thread scheduling:
- Inject random delays at sync points
- Force unusual interleavings
- Often finds bugs stress testing misses

4. Assertions and invariants:
- Check data structure consistency
- Assert lock is held when accessing data
- Use debug builds with extra checks

5. Logging and replay:
- Record thread schedules and operations
- Replay deterministically to reproduce bugs
- Essential for debugging heisenbugs
```

Concurrent programming requires thinking about not just what operations occur, but in what order they might occur across threads. From the hardware-level atomic instructions through spinlocks, mutexes, and condition variables to sophisticated lock-free algorithms, each layer builds on the foundations below. The key insights remain constant: minimize sharing, protect what must be shared, understand the memory model, and always verify correctness with appropriate tools. Mastering these primitives enables you to harness the full power of modern multicore systems while avoiding the subtle bugs that make concurrent programming notoriously difficult. Whether you choose locks for their simplicity or venture into lock-free territory for performance, the principles of synchronization guide you toward correct, efficient parallel programs.
