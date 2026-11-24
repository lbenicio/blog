---
title: "Lease-Based Work Assignment: Designing a Fault-Tolerant Scheduler Without a Global Lock"
description: "A design for a distributed scheduler that replaces a global assignment lock with partitioned, fenced ownership leases, durable work records, worker-side deadlines, and stale-write rejection."
date: "2026-08-25"
author: "Leonardo Benicio"
tags: ["distributed systems","scheduling","leases","fault tolerance","concurrency","system design"]
categories: ["Distributed Systems","Systems Design","Parallel Computing"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/lease-based-work-assignment-designing-a-fault-tolerant-scheduler-without-a-global-lock-2026-08-25.jpg"
coverAlt: "Isometric diagram of a partitioned scheduler granting time-bounded lease tokens to worker nodes and storage endpoints rejecting stale tokens at fenced write gates"
---

Scheduling is often described as choosing what runs next. In a distributed system, the harder problem is granting the right to run. A scheduler that assigns work to workers must prevent two workers from running the same unit at the same time, recover quickly when a worker dies, avoid a central lock that serializes every decision, and remain fair across tenants. This article describes a design for a lease-based work assignment layer. The central idea is to replace a long-lived global lock with short-lived, fenced ownership leases granted per shard, plus an explicit worker protocol and a completion protocol that rejects stale work. The design is not a consensus algorithm and does not pretend that leases remove the need for coordination. It confines coordination to small partitions and to bounded time.

The design targets a common class of systems: a pool of stateless or semi-stateless workers pull work from a central service; work units range from milliseconds to hours; the service must survive worker crashes, scheduler restarts, network partitions, and long stop-the-world pauses; and the business requires neither lost work nor duplicate side effects, or at least a clear and bounded duplicate window. The discussion is deliberately implementation-neutral. It assumes a durable metadata store that can perform linearizable operations within a shard, a set of workers that can be paused or partitioned, and external resources that can either be made idempotent or taught to reject stale owners. Where those assumptions fail, the article says so.

## 1. The assignment problem and its requirements

A work unit is an identified piece of computation. It has a payload, a priority, a deadline, a retry policy, and a result. A worker is a process with finite capacity, labels, and a liveness signal. Assignment is the act of binding a work unit to a worker for an interval. Execution is what the worker does after assignment. Completion is the act of publishing a result and moving the work unit to a terminal or retryable state.

The naive implementation is a single global lock around a queue and an assignment table. A scheduler takes the lock, pops work, marks it assigned, releases the lock. This is easy to reason about. It also has three problems. First, the lock serializes all assignment decisions, so throughput is bounded by one critical section even when workers and work are naturally partitioned. Second, if the lock is held while checking worker health or writing to a remote store, a slow dependency becomes a global stop-the-world event. Third, a global lock encourages long critical sections for batching, which increases tail latency. For small systems, the naive implementation is correct and should not be replaced. For large systems, the lock becomes the scheduler.

The requirements for a better design are concrete:

- Safety of ownership: for a given work unit, at most one worker may have a valid execution lease at a time, unless the work is explicitly marked as safe for concurrent execution.
- No lost work: once a work unit is admitted durably, a crash of a worker, scheduler, or metadata node must not cause it to disappear.
- Bounded recovery: after a worker fails, the work unit should be reassigned after a bounded delay, not after an unbounded timeout or manual intervention.
- No global serialization: assignment decisions for independent work units should proceed in parallel, with contention limited to a partition or a single work unit.
- Fairness: capacity should be shared according to tenant weights, priorities, or deadlines, not according to which worker happens to poll first.
- Observability: operators must be able to answer which worker owns a unit, why it was reassigned, how often leases expire, and whether stale completions are being rejected.

The requirements conflict. Short leases improve recovery but increase the chance that a slow but healthy worker loses ownership. Long leases reduce churn but delay recovery. Strong fencing requires cooperation from external resources, which increases integration cost. Exactly-once side effects are impossible in general without a transactional boundary; the design must make the achievable guarantee explicit.

## 2. Leases, locks, and fencing tokens

A lease is a grant of ownership for a bounded interval. The grantor promises not to grant the same ownership to another holder until the lease expires, subject to its clock and safety margin. The holder promises to stop using the ownership before the lease expires, subject to its own conservative deadline. A lease is not a lock that is released only by its holder. It is a time-bounded capability that can be allowed to expire. That difference is the whole point.

In a single process, a mutex is released by the thread that acquired it. If the thread crashes, the operating system or the process must recover the mutex. In a distributed system, a worker can be alive but unable to reach the scheduler. The scheduler cannot distinguish a paused worker from a dead one using heartbeats alone. A lease turns that uncertainty into a bounded time window: the scheduler may reassign after expiry, and the old holder must stop before the new holder starts. The window is only safe if clocks and pauses are bounded, or if stale holders are fenced at the resource they touch.

Fencing is the second half of the mechanism. Every grant of a work unit increments a monotonically increasing epoch. The worker receives the epoch with the lease. Every write to a resource that could be affected by the work includes the epoch. The resource accepts a write only if the epoch is greater than or equal to the highest epoch it has seen for that work unit. A stale worker that resumes after being paused can still run code, but its writes are rejected. Fencing converts an uncertain liveness problem into a concrete authorization check.

There are three common ways to fence:

1. The resource itself stores a fencing token per work unit and rejects lower tokens. This is the strongest and simplest model when the resource is a database row, object store key, or internal service that can be changed.
2. The lease token is a signed capability with an expiry and a sequence number, and the resource validates the signature and expiry. This avoids a per-write control-plane call but requires clock synchronization and a trusted verifier.
3. The resource uses conditional writes based on a version or generation field. This is a special case of the first model and is often available in object stores and databases.

Fencing does not prevent duplicate execution. It prevents duplicate effects. A stale worker may still burn CPU, call a read-only API, or produce a result that is discarded. If the side effect cannot be fenced, the system cannot promise at-most-once effects. It can promise at-least-once execution and best-effort deduplication. That distinction must appear in the API contract, not only in an architecture diagram.

A lease duration is chosen from four quantities:

`T_lease = T_exec_slice + T_clock_error + T_pause + T_grace`

`T_exec_slice` is the maximum time a worker is allowed to execute before renewing or checking in. `T_clock_error` is the maximum expected skew between the grantor and worker clocks, including NTP adjustments. `T_pause` is the maximum pause the system is willing to tolerate without losing ownership. `T_grace` is a safety margin for message delay and scheduling jitter. The formula is not a proof. It is a budget. If the actual pause exceeds `T_pause`, the old worker may still be running when the new worker starts; fencing is then the only protection.

Long leases and short leases are both legitimate. A short lease, for example a few seconds, is appropriate when work is small, workers are reliable, and recovery latency matters. A long lease is appropriate when work is expensive to restart, when the scheduler and workers are co-located, or when the external resource has no fencing and the system relies on time bounds. In every case, the lease should be shorter than the business tolerance for duplicate execution, not shorter than the average task duration.

## 3. Architecture: partitioned lease managers

The design partitions work by a stable key, usually a hash of the work unit identifier. Each partition has a lease manager. The lease manager is the only component that grants leases for work in its partition. It owns a durable assignment table and a log of grant, renew, complete, and expire operations. The partition is the unit of serialization. Two work units in different partitions can be assigned concurrently. Two work units in the same partition are serialized by the partition's sequencer, but that sequencer should do very little: validate a candidate, increment an epoch, write a grant record, and return.

The partition count is a capacity decision. Too few partitions create hot shards and unnecessary contention. Too many partitions increase metadata overhead, leader-election churn, and the cost of background scanning. A useful starting point is to make the number of partitions large enough that each partition can be handled by one scheduler thread or one modest database transaction stream, and small enough that each partition has enough work to amortize its fixed costs. The number should be chosen before load testing and then changed only with an explicit rebalance plan, because moving a partition moves its lease table and its fencing epochs.

The lease manager does not need to be a full consensus group if the underlying metadata store provides linearizable compare-and-swap or append operations per partition. It does need a single writer per partition at any time. That single writer can be elected by a consensus service, by a database lease, or by a primary-backup mechanism. The election is a separate problem from work leases; it should be rare and should not be on the hot path of every assignment. The work lease is a short-lived grant to a worker. The manager leadership is a longer-lived grant to a scheduler process. Confusing the two leads to designs where every task assignment requires a consensus round.

Workers interact with the lease manager through a small API: acquire, renew, complete, fail, and heartbeat. Workers may long-poll for work. The manager maintains a per-worker view of capacity and a per-partition queue of eligible work. It grants leases greedily within a partition, respecting worker labels, priority, and tenant weight. It does not attempt a globally optimal assignment. Global optimization requires a global view and a global lock; the design prefers local greedy decisions with good enough fairness and explicit rebalancing.

The durable state is split into three records. The work record contains the work identifier, partition, state, payload reference, priority, deadline, retry count, and the current epoch. The lease record contains the lease identifier, work identifier, epoch, holder, grant time, expiry time, and renewal deadline. The worker record contains the worker identifier, capacity, labels, last heartbeat, and a count of held leases. The work record is the source of truth for whether work is pending, leased, running, succeeded, failed, or dead. The lease record is the source of truth for who may currently execute. The worker record is a cache for placement and fairness; it must not be used as proof of liveness.

A grant is a compare-and-swap on the work record: if the state is pending or expired, and the version matches, then set state to leased, increment the epoch, set the lease fields, and append a grant event. A renewal is a compare-and-swap on the lease record: if the lease identifier, epoch, and holder match, and the lease has not been revoked, then extend the expiry. A completion is a compare-and-swap on the work record: if the epoch matches the current epoch, then set state to succeeded and store the result reference. A stale completion finds an epoch mismatch and is rejected. This is the entire safety core. Everything else is policy, scheduling, and operations.

## 4. State machine and data model

The work state machine should be small enough to model and large enough to diagnose. A minimal set is:

- `Pending`: admitted and eligible for assignment.
- `Leased`: a lease has been granted but the worker has not acknowledged execution.
- `Running`: the worker has acknowledged and is executing.
- `Succeeded`: a result has been accepted for the current epoch.
- `Failed`: the worker reported a terminal failure for the current epoch.
- `Expired`: the lease expired without completion; the work is eligible for retry.
- `Dead`: retries are exhausted or the work was cancelled.

The transitions are:

`Pending -> Leased`: grant a lease with epoch `e`. The previous epoch is `e - 1`.
`Leased -> Running`: worker acknowledges with lease id and epoch `e`.
`Running -> Succeeded`: worker completes with epoch `e`; result is stored.
`Running -> Failed`: worker reports failure with epoch `e`; retry policy applies.
`Leased | Running -> Expired`: the lease expiry passes without a valid renewal or completion.
`Expired -> Pending`: the retry policy allows another attempt.
`Expired -> Dead`: retries are exhausted or the deadline has passed.

An epoch is not a retry count. A retry count increases when work fails and is retried. An epoch increases on every grant, including a re-grant after expiry, a re-grant after a worker reports failure, and a re-grant after an operator forces reassignment. Epochs must be monotonic per work unit and persisted before the lease is returned. If epochs reset after a metadata restore, fencing breaks. The epoch sequence must be part of the durable work record and must be backed up with it.

A lease record should include a renewal deadline separate from the expiry. The renewal deadline is the point after which the worker must have sent a renewal or the manager will mark the lease as suspect. The expiry is the point after which the manager may grant a new lease. The gap between them is the recovery window. It absorbs delayed renewals, scheduler failover, and the time needed to append an expiry event. The gap should not be so large that recovery is slow, and not so small that a healthy worker loses ownership during a normal garbage-collection pause.

A worker record is intentionally soft state. It can be rebuilt from heartbeats and leases. It should not be consulted for safety decisions. If the worker record says a worker is healthy but the lease table says the lease is expired, the lease wins. If the worker record says a worker is gone but the lease has not expired, the lease wins until expiry. This ordering prevents a stale health cache from causing double assignment.

The payload should be stored outside the lease table. The lease table is hot and small. Payloads can be large and should live in an object store or a separate blob service. The work record stores a reference, a content hash, and an encryption key identifier if needed. The worker fetches the payload after acquiring the lease. Fetching before acquiring a lease is allowed only if the payload is immutable and the fetch is not considered ownership. The rule is simple: the lease grants the right to produce effects, not the right to read bytes.

## 5. The grant path

The grant path is the hot path. It should do as little as possible while preserving the safety invariants. A partition manager loop can be described as follows:

```
loop:
  candidates = select_eligible(partition, now)
  workers = select_available_workers(partition, now)
  for work in candidates ordered by priority, deadline, age:
    for worker in workers ordered by fit, tenant credit, locality:
      if worker.capacity <= 0:
        continue
      if not labels_match(work, worker):
        continue
      if not tenant_allows(work, worker):
        continue
      grant = try_grant(work.id, worker.id, now)
      if grant is not None:
        worker.capacity -= 1
        send_lease(worker, grant)
        break
  wait_for_event_or_timeout()
```

The important part is not the loop structure. It is `try_grant`. That function must be a compare-and-swap or an append to a per-partition log that is applied by a state machine. It must check the current state, the current version, the lease expiry, and the worker's eligibility. It must increment the epoch and persist the grant before the lease is returned to the worker. If the process crashes after persisting the grant but before sending it, the worker never receives the lease. The lease will expire and the work will be retried. That is a liveness cost, not a safety violation. If the process sends the lease before persisting it, a crash can lose the lease record and allow a second grant after restart. That is a safety violation. Persist first, send second.

Batching grants is useful but dangerous. A batch of grants can be applied as one log record if the state machine validates every work unit and every epoch in the batch. The batch should be formed under the partition's sequencer, not by multiple schedulers racing on the same table. If a batch fails validation for one work unit, the manager should not abort the entire batch unless the log record is atomic. It can split the batch or mark the failed candidate for a later retry. The goal is to amortize the cost of durable writes without creating a large rollback surface.

Candidate selection should avoid scanning the entire partition on every loop. Maintain an index of eligible work ordered by priority and deadline. Maintain a separate index of leases that are near expiry. Maintain a per-worker queue of leases that may be renewed. A periodic scan is still needed for recovery and for work that was missed due to an index bug, but the hot path should not depend on a full scan. The scan should be rate-limited and should not hold the partition sequencer for long.

The manager should reserve capacity before granting. If a worker can run ten tasks and the manager grants eleven because two grants raced, the worker will either reject one or run it late. Rejection is a wasted grant. Late execution is a missed deadline. The reservation can be a local counter in the manager if the manager is the only grantor for that worker. If multiple partitions grant to the same worker, the reservation must be shared or the worker must enforce its own capacity. A common pattern is to let the worker advertise capacity in units and let each partition hold a small credit. The worker rejects leases beyond its actual capacity, and the manager treats rejection as a failed grant. That creates a feedback loop but avoids a global capacity lock.

Grant ordering matters for fairness. A strict priority queue can starve low-priority work. The manager should use priority aging: a low-priority work unit's effective priority increases with its queue age. It should also use tenant credits. Each tenant has a weight and a burst allowance. The manager grants work in proportion to the tenant's weight, but it does not block a tenant completely when another tenant is idle. This is a local decision per partition. Global fairness across partitions is approximate, which is acceptable if work is evenly partitioned and tenant work is not concentrated in a few hot keys.

## 6. The worker protocol

A worker is not a passive recipient. It has a lifecycle that must be explicit. The states are idle, requesting, holding, executing, renewing, completing, and draining. The worker maintains a local queue of leases. It should not accept more leases than it can start within a bounded time. Accepting a lease and then letting it sit idle is a self-inflicted expiry. The worker should advertise capacity that reflects its actual concurrency, not its CPU count or its hope.

When the worker acquires a lease, it checks the lease identifier, work identifier, epoch, and expiry. It sets a local deadline using a monotonic clock. The local deadline should be earlier than the grantor's expiry by a conservative margin. The margin covers message delay, clock skew, and the worker's own scheduling latency. If the worker cannot start the task before the local deadline, it should return the lease early rather than start late. Returning early is cheaper than being fenced later.

During execution, the worker sends renewals at a fixed cadence. A renewal is not a heartbeat that says the worker is alive. It is a request to extend a specific lease. The request includes the lease id, work id, epoch, and a progress token if the work supports progress tracking. The manager validates the lease and extends it. If the manager rejects the renewal, the worker must treat the lease as lost. It should stop at the next safe point, abort if the task supports cancellation, and report the lost lease with its epoch. It must not continue to write without fencing.

The worker should distinguish three failure modes:

1. The task fails with a deterministic error. The worker reports failure for the current epoch. The manager applies the retry policy. A deterministic error may still be retryable if the policy says so, but the worker should not classify it as a lease failure.
2. The lease is lost. The worker reports lost ownership. The manager does not count this as a task failure by default; it counts it as an ownership event. The work may be retried with a new epoch. Repeated lease loss is a signal of worker pause, network instability, or an undersized lease.
3. The worker is shutting down. It stops acquiring, completes or returns held leases, and exits. A graceful drain is not a crash. It should be fast and should not rely on lease expiry for every task.

The worker must persist enough local state to avoid duplicate side effects across its own restarts. If a worker crashes after writing a result but before acknowledging completion, it may restart and try again. The result store should key results by work id and epoch, or by an idempotency key derived from them. A completion for an older epoch is rejected by the scheduler. A completion for the current epoch is accepted once. If the worker retries the same completion, the result store should return the existing result rather than create a second one. The scheduler's completion handler should be idempotent: a duplicate completion for the same work id and epoch returns success.

Long-running work needs a different protocol. A task that runs for hours cannot rely on a single lease. It should be split into chunks, each with its own lease or with a checkpoint that can be resumed by another worker. The checkpoint must be written with a fencing token. If a worker is paused for an hour, it may resume and try to write a checkpoint for an old epoch. The checkpoint store must reject it. The next worker resumes from the last committed checkpoint. This is not exactly-once execution; it is exactly-once state transition for the checkpoint. The task may have performed external side effects between checkpoints. Those side effects need their own idempotency keys or a transactional outbox.

## 7. Failure detection, partitions, and split brain

Heartbeats are liveness hints, not truth. A missed heartbeat can mean a crashed worker, a paused worker, a network partition, a scheduler overload, or a metrics pipeline problem. The scheduler should use two thresholds. The first is a suspicion threshold. When a worker misses heartbeats past suspicion, the scheduler stops granting new leases to that worker and marks its leases as at risk. It does not reassign them yet. The second is the lease expiry plus grace. Only then may the scheduler grant a new lease. The gap between suspicion and expiry is the time to avoid unnecessary churn.

A network partition can produce a worker that still talks to its external resource but not to the scheduler. The worker's lease expires at the scheduler. The scheduler grants a new lease to another worker. The old worker is still running. This is where fencing is required. If the external resource rejects stale epochs, the old worker may run but cannot commit effects. If the resource does not support fencing, the system has a split-brain window. The only safe options are to make the work idempotent, to tolerate duplicates, or to isolate the resource with a lease-aware proxy that validates epochs. A proxy is a real component with its own availability and latency cost. It is not free, but it is often cheaper than changing every resource.

Clock behavior deserves explicit treatment. The grantor's expiry is evaluated in the grantor's clock. The worker's local deadline is evaluated in the worker's monotonic clock. Wall-clock jumps, NTP steps, and virtual-machine pauses can break naive comparisons. The worker should not compute `expiry_time - wall_clock_now` using a wall clock that can jump. It should record the monotonic time at which the lease was received and set a timer for a conservative duration. The conservative duration is the lease duration minus the maximum one-way delay and minus a safety margin. If the worker's monotonic clock is also paused during a virtual-machine suspend, the timer may fire late. Fencing is still the backstop. Do not rely on a timer alone for safety.

Split brain at the scheduler level is a separate concern. If two lease managers believe they own the same partition, they can both grant leases and produce conflicting epochs. The partition leadership mechanism must provide a single writer, or the metadata store must reject stale writes with a leader epoch. A common bug is to use a work lease as a scheduler leadership lease. They have different scopes. The scheduler leadership lease protects the partition's mutation stream. The work lease protects the work unit against worker staleness. Both need fencing, but they are not the same fencing token. A new partition leader should increment a leadership epoch and reject writes from the old leader. It should not reset work epochs. It should continue them.

Graceful shutdown is not a failure, but it must be designed. When a manager shuts down, it should stop granting, flush the log, and release leadership. Workers holding leases should be allowed to renew through another manager if the partition is available, or they should be told to drain. Draining is a policy: finish current work if it is short, or return the lease if it is long. The manager should not delete lease records on shutdown. Deleting a lease record is equivalent to declaring the work unowned, which can cause double execution. Let leases expire or transfer them explicitly with a new epoch.

## 8. Durability, completion, and side effects

The durable work record is the source of truth for the work's lifecycle. The lease record is the source of truth for current ownership. The result store is the source of truth for successful output. These three stores must agree on the work id and epoch. If they are separate systems, the completion protocol must handle partial failure. A worker may write the result and then crash before marking the work succeeded. The result is durable, but the work is still running or expired. A retry may execute the work again. The result store should deduplicate by work id and epoch. If the retry gets a new epoch, it may produce a second result. The scheduler must decide which result is authoritative.

The simplest protocol is to make the result store accept a write only if the epoch is the current epoch in the lease manager. That requires a transaction across two systems, which is usually not available. A practical alternative is to store every result with its epoch and let the work record point to the accepted epoch. The worker writes the result under `work_id/epoch`. It then calls complete with the epoch. The manager checks the epoch. If it is current, it sets the accepted result pointer and marks the work succeeded. If the worker crashes after writing the result but before completing, the result is orphaned. A retry with a new epoch writes a new result. The manager accepts the new epoch and points to it. The old result remains as garbage and can be cleaned up by a retention policy. This is at-least-once execution with epoch-keyed results. It is simple and robust. It does not promise exactly-once effects, but it prevents a stale result from being accepted as current.

If the side effect is an external API call, the same pattern applies. The API should accept an idempotency key that includes the work id and epoch. If the API does not support idempotency, the caller can use an outbox: write the intent to a durable outbox in the same transaction as the completion, and let a separate relay deliver it. The relay uses the outbox row id as the idempotency key. The outbox row is marked delivered only after the API confirms. If the relay crashes, it retries. The API may receive duplicates unless it supports idempotency. The outbox reduces the duplicate window but does not eliminate it. To eliminate it, the external system must participate in the protocol.

Fencing at the resource is the strongest pattern. Suppose the resource is a database row that represents the work's output. The row has an `owner_epoch` column. A worker writes `UPDATE output SET value = ?, owner_epoch = ? WHERE work_id = ? AND owner_epoch < ?`. The condition rejects stale epochs. If the worker is paused and resumes after a new worker has written a higher epoch, the old write affects zero rows. The worker should treat zero rows as a lost lease and stop. This pattern requires the resource to know the work id and to have an epoch column. It is a small schema change compared with the cost of debugging duplicate effects. For object stores, conditional writes with an ETag or generation number can provide a similar check, but the token must be stored in the object metadata or derived from the object key. For message queues, the queue may not support fencing; the consumer must deduplicate by epoch and work id.

The completion path should be idempotent and monotonic. A completion for epoch `e` should succeed if the work is currently leased or running at epoch `e`. It should return an already-completed response if the work is succeeded at epoch `e`. It should reject the completion if the current epoch is greater than `e`. It should not allow a completion at a lower epoch to overwrite a result at a higher epoch. The same rule applies to failure reports. A stale failure should not mark a currently running attempt as failed. It should be logged as a stale event and ignored. This monotonic rule is easy to state and easy to test. It is also easy to violate if the code checks only the work id and not the epoch.

## 9. Rebalancing, fairness, and capacity

Rebalancing is not about moving running work. It is about changing where future work is granted. Running work is expensive to move and may not support checkpointing. The scheduler should prefer to drain a worker by granting fewer new leases rather than by revoking existing leases. Revocation is a tool for overload, policy violations, or operator intervention. It should be rare and should increment the epoch. A revoked worker must stop and report lost ownership. The work is then eligible for a new lease. Revocation is not free: it may duplicate side effects, waste computation, and increase tail latency.

Fairness can be implemented with a hierarchy of queues. At the top, tenants have weights. At the next level, work classes have priorities. At the bottom, individual work units have deadlines and ages. The manager grants from the highest effective priority first, but it uses a deficit round-robin or weighted fair queueing scheme to prevent starvation. A simple approximation is to maintain a credit per tenant. Each grant consumes credit in proportion to the work's cost. The manager refills credits at a fixed rate. When a tenant has no credit, its work waits unless all other tenants are idle. This is local fairness. Global fairness requires coordination across partitions, which is expensive. A practical compromise is to partition work so that each tenant's work is spread across many partitions, then rely on the law of large numbers. Hot tenants with a single hot key will still need explicit isolation.

Capacity is not just a count of tasks. Work units have different resource profiles. A CPU-bound task and an I/O-bound task should not consume the same slot. A worker can advertise multiple capacity dimensions: CPU tokens, memory tokens, I/O tokens, and a maximum number of concurrent tasks. The manager matches work requirements to available tokens. This turns assignment into a multi-dimensional bin-packing problem. Exact bin packing is too expensive and too global. The manager should use a greedy fit with a small number of dimensions and a fallback to a generic slot. If the fit is wrong, the worker can reject the lease and report a capacity error. The manager should learn from rejections and reduce the worker's advertised capacity for that dimension.

Preemption should be explicit. Some work classes are preemptible; others are not. A preemptible task must have a checkpoint or a cancellation point. When the manager needs to free capacity, it selects a preemptible lease with the lowest priority and revokes it. The worker stops at the next checkpoint and reports preemption. The work returns to pending with a retry count that does not count as a failure. Non-preemptible work is never revoked for capacity reasons. It may still expire if the worker dies. This distinction prevents the scheduler from turning a capacity shortage into a correctness problem.

Locality is a soft preference. If work reads a large dataset, granting it to a worker near the data reduces network cost. But locality must not override safety or fairness. The manager can use a locality score as a tiebreaker. It should not wait indefinitely for a local worker if a remote worker is available and the deadline is near. The same applies to worker affinity: a work unit may have a preferred worker because of a cache, but the lease is still time-bounded and fenced. Affinity is an optimization, not an ownership rule.

## 10. Scaling and capacity planning

The design scales with the number of partitions, not with the number of workers. Each partition has a single writer and a durable log. The maximum grant rate per partition is bounded by the log append rate, the state-machine apply rate, and the network round trip to workers. If one partition can handle a few thousand grants per second in a given deployment, then the total grant rate is roughly the partition count times that rate, minus hot-shard effects. These numbers are deployment-specific and should be measured, not assumed. The important point is that the design has a horizontal scaling knob and a clear bottleneck.

Hot shards are the main scaling risk. A hot shard can arise from a single high-volume tenant, a popular work key, or a poor hash function. The manager should detect hot shards by measuring grant rate, queue depth, and lease expiry rate per partition. It should not automatically split a partition on the hot path. Splitting requires moving work records, preserving epochs, and updating routing. It is a controlled operation. A simpler mitigation is to add a sub-key to the partition hash for work that is known to be high-volume, so that the work is spread across more partitions. This changes the partition mapping for new work only. Existing work stays in its original partition until it drains. The routing layer must know both the old and new mapping during the transition.

Metadata size is another constraint. The lease table holds only active leases and recent history. Completed work should be moved to a result store or an archive. The work record can be compacted after a retention period. The epoch must be retained for at least as long as any stale worker could present a completion. If a worker can be paused for a week, the epoch must be retained for a week. This is a policy decision. In practice, the maximum pause is usually bounded by the platform's live-migration or suspend timeout. The system should document that bound. If it cannot, it should retain epochs indefinitely or use a fencing token that is globally monotonic and does not depend on per-work history.

Worker capacity planning should account for lease overhead. A worker that holds many short leases spends time on acquire, renew, and complete calls. The overhead per lease should be small compared with the work itself. If it is not, the batch size should increase or the lease duration should be longer. Long-polling reduces empty responses but consumes connection slots. A mixed strategy works well: long-poll with a short timeout, then back off with jitter. The scheduler should return a small batch of leases when work is abundant and a single lease when work is scarce. Batching improves throughput but increases the blast radius of a worker crash. The worker should acknowledge each lease individually so that a crash does not lose the whole batch.

Backpressure is essential. When the queue is full, the admission layer should reject new work with a retryable error, not accept it and let it age past its deadline. When workers are saturated, the scheduler should stop granting and let the queue grow only to a configured limit. When a partition is overloaded, the routing layer should shed load or redirect to another partition if the work is relocatable. Backpressure should be visible in metrics: queue depth, admission rejects, grant latency, and lease expiry rate. A scheduler that accepts unbounded work is a scheduler that eventually fails under its own backlog.

## 11. API shape and a reference protocol

The API should be small and explicit. The exact transport is less important than the semantics. A reference protocol has these calls:

- `enqueue(work_id, payload_ref, priority, deadline, tenant, labels)`: idempotent by work id. Returns accepted or already exists.
- `acquire(worker_id, capacity, labels, max_wait)`: returns zero or more leases. Each lease contains work id, lease id, epoch, expiry, payload ref, and a renewal deadline.
- `renew(lease_id, work_id, epoch, progress)`: returns extended expiry or a rejection with a reason.
- `complete(lease_id, work_id, epoch, result_ref)`: returns accepted, already completed, or stale epoch.
- `fail(lease_id, work_id, epoch, error_class, retryable)`: returns accepted or stale epoch.
- `heartbeat(worker_id, capacity, load)`: returns a capacity hint and a drain flag.

The acquire response should include the grantor's identity and a signed lease token if workers are not trusted. The token should contain the work id, epoch, expiry, and a signature. The worker presents the token to the resource. The resource validates the signature and expiry. This avoids a control-plane call per write. The token must be short-lived and must not be reusable after expiry. If the resource needs revocation before expiry, the token must include a revocation epoch that the resource can check against a local cache. That is a more complex design; it is appropriate only when the resource cannot tolerate a stale write until expiry.

A reference grant flow looks like this:

```
worker -> manager: acquire(worker_id, capacity=4, labels={gpu:false}, max_wait=30s)
manager -> store: select eligible work in partition p
manager -> store: CAS work e from pending to leased, epoch=e+1, holder=worker
store -> manager: grant record
manager -> worker: lease(work_id, lease_id, epoch=e+1, expiry=T, payload_ref)
worker -> manager: renew(lease_id, epoch=e+1)
manager -> store: CAS lease, extend expiry
worker -> resource: write with fencing token (work_id, epoch=e+1)
resource -> worker: accepted or stale
worker -> manager: complete(lease_id, epoch=e+1, result_ref)
manager -> store: CAS work, accept result if epoch matches
```

The worker should send a renew only when it is still executing. A worker that is about to complete should not renew. The manager should accept a completion even if the lease has expired by a small grace period, provided the epoch is still current and no new lease has been granted. This reduces the race between a completion and an expiry sweep. The grace period is not a safety extension; it is a bookkeeping convenience. If a new lease has been granted, the old completion is stale and must be rejected. The epoch check handles this without needing a separate grace rule.

The manager should return structured rejection reasons. `LEASE_EXPIRED` means the worker should stop and report lost ownership. `LEASE_REVOKED` means an operator or policy revoked the lease; the worker should stop and not retry the same epoch. `INVALID_EPOCH` means the worker is stale. `CAPACITY` means the worker advertised more than it can run. `THROTTLED` means the tenant or partition is over budget. These reasons let the worker choose the right behavior. A generic `ERROR` forces the worker to guess, which leads to duplicate execution or abandoned work.

## 12. Testing and verification

A lease-based scheduler is a temporal system. Unit tests that mock a clock are not enough. The test harness needs a deterministic simulator with a virtual clock, controllable message delivery, worker pauses, process crashes, and partition leadership changes. The simulator should run the real state-machine code, not a simplified model. It should inject events in every order that the model allows. For each run, it should check a set of invariants:

- No two workers hold valid leases for the same work unit at the same epoch.
- Epochs for a work unit are strictly increasing across grants.
- A completion is accepted only if its epoch equals the current epoch and the work is leased or running.
- A stale completion never changes the accepted result pointer.
- A work unit that is admitted and not cancelled eventually reaches succeeded, failed, or dead under a fair scheduler and a finite retry policy.
- A worker that loses its lease cannot commit a side effect through a fenced resource.

The first invariant is the core safety property. It is not enough to check that the lease table never has two active rows for the same work. A lease can be valid in the worker's local state after the table has expired it. The simulator must model the worker's conservative deadline and the resource's fencing check. The invariant is about the resource's accepted writes, not about the table alone. If the resource is not part of the simulation, the test cannot prove the end-to-end property.

Model checking is valuable for the state machine. A small TLA-style model or an equivalent explicit-state model can explore the interleavings of grant, renew, expire, complete, and leader change. The model should include an abstract resource with an epoch check. It should not try to model the entire production system. The goal is to find missing epoch checks, double grants after leader change, and completion races. Property-based tests can complement model checking by generating random work, workers, and failures. The generator should produce long pauses, clock jumps, and network partitions more often than a uniform random distribution would. Real systems have correlated failures, and the tests should too.

Fault injection should include stop-the-world pauses that exceed the lease duration. This is the test that catches designs that rely on timers alone. The worker should resume, attempt to write, and be rejected by the fenced resource. The scheduler should have already granted the work to another worker. The old worker should report lost ownership and stop. If the old worker's write succeeds, the fencing path is broken. The test should also include a scheduler crash after persisting a grant but before sending it, a worker crash after writing a result but before completing, and a network partition that isolates the worker from the scheduler but not from the resource. These are the cases that produce duplicate execution or lost work in real deployments.

Load tests should measure more than throughput. They should measure grant latency, lease expiry rate, renewal failure rate, stale completion rate, and the age of pending work at the 50th, 95th, and 99th percentiles. A scheduler can have high throughput and terrible tail latency because it grants long batches to a few workers while others idle. The load test should include tenant skew, worker heterogeneity, and hot partitions. It should also include a slow metadata store, because the grant path is sensitive to append latency. When the store slows down, the scheduler should reduce grant rate and increase lease duration or admit less work. It should not build an unbounded in-memory queue of grants that it cannot persist.

## 13. Operations and observability

The operator needs a narrative, not just metrics. For a given work unit, the system should be able to show a timeline: admitted, granted to worker A at epoch 1, renewed twice, lease expired, granted to worker B at epoch 2, completed, result accepted. For a given worker, it should show held leases, renewals, lost leases, and capacity rejections. For a partition, it should show grant rate, queue depth, leader epoch, and log append latency. These views are not optional. Without them, debugging a duplicate effect becomes a forensic exercise in log archaeology.

Key metrics include:

- `leases_granted_total` and `leases_expired_total` by partition and tenant.
- `lease_renewal_failures_total` by reason, especially stale epoch and expired lease.
- `stale_completions_total` and `stale_failures_total`.
- `pending_work_age_seconds` as a histogram.
- `grant_latency_seconds` and `grant_batch_size`.
- `worker_capacity_rejections_total`.
- `partition_leader_changes_total`.
- `fenced_write_rejections_total` at the resource.

A high lease expiry rate can mean workers are pausing, leases are too short, the scheduler is overloaded, or the network is slow. It should not be treated as a single alarm. A high stale completion rate can mean workers are resuming after long pauses or the scheduler is granting too aggressively. A high capacity rejection rate means the worker advertisement is wrong or the matching policy is too optimistic. These metrics should be correlated with work class and worker pool, because a global average hides the problem.

Security matters because a lease is an authorization to act. Lease tokens should be signed and bound to the work unit, epoch, and expiry. Workers should authenticate to the manager with mutual TLS or an equivalent mechanism. The manager should not accept a lease renewal from a worker that does not hold the lease, even if the worker knows the lease id. The lease id should be unguessable, but secrecy is not a substitute for authentication. A compromised worker can always abuse the leases it holds; the goal is to limit the blast radius and make revocation possible. Revocation should increment the epoch and publish a revocation event. Resources that cache tokens should have a short cache TTL or a revocation check. There is a trade-off between per-write control-plane calls and the time window in which a revoked token is still accepted.

Multi-tenancy adds another layer. A tenant should not be able to starve other tenants by flooding the admission queue or by holding leases without executing. The manager should enforce per-tenant admission limits, per-tenant lease limits, and per-tenant queue age targets. It should also isolate tenants at the partition level where possible. A noisy tenant that creates hot partitions should be moved to a dedicated partition set or throttled. Fairness is not a property that emerges from a global queue; it is an explicit policy that must be measured and tuned.

## 14. Alternatives and when not to use leases

Leases are not always the right answer. A single global lock is simpler and can be correct for low-throughput systems. A database row lock held for the duration of a task is usually a bad idea because the task duration is unbounded and the lock consumes a connection. A queue with a visibility timeout is a lease-like mechanism, but it often lacks an epoch and relies on the consumer to delete the message. That is sufficient for at-least-once work when duplicate effects are harmless. It is not sufficient for non-idempotent side effects without an additional fencing layer.

Optimistic concurrency control with a version number is another alternative. A worker reads the work record, computes, and writes back only if the version is unchanged. This works for short, compute-only tasks. It fails for long tasks because the version changes while the worker is computing, causing repeated aborts. It also does not solve the stale-worker problem: a paused worker can resume and write with an old version, and the store will reject it, but the worker may have already performed external side effects. Fencing at the resource is still needed.

Consensus per work unit is stronger but more expensive. It can provide a linearizable ownership register, but it puts a consensus round on the critical path of every assignment. For high-volume work, that is usually too much. Partitioned leases with a single writer per partition and fencing at the resource are a better fit for throughput. For low-volume, high-value work, per-work consensus may be justified. The choice depends on the cost of a duplicate effect and the rate of work.

Static assignment is underrated. If work is long-lived and workers are stable, a consistent-hash assignment without leases can be simpler. The failure case is a worker that dies while holding work. The system must detect the failure and reassign. Without leases, it needs another failure detector and a way to prevent the old worker from writing. That is a lease in disguise. The lesson is not that leases are always necessary; it is that any dynamic assignment scheme needs a bounded ownership interval or a fencing mechanism.

Use leases when work is dynamic, workers are unreliable, and duplicate effects are costly. Do not use leases when work is trivially idempotent and a simple visibility timeout is enough. Do not use leases when the external resource cannot be fenced and the system cannot tolerate duplicates; in that case, the correct design is to serialize the work through a single writer or to use a transactional resource that can enforce the ownership check. Leases do not create safety out of nothing. They move the safety requirement to the clock bound and the fencing check.

## 15. A worked scenario: long-running media processing

Consider a media processing system that transcodes large files. Work units are video segments. A segment may take several minutes. The output is written to an object store. The object store supports conditional writes with a generation number, and the system can store the lease epoch in the object metadata. The scheduler partitions work by video id. Each partition has a lease manager. Workers pull leases, fetch the segment, transcode it, and write the output.

A lease might be 60 seconds, with a renewal every 15 seconds. A worker that loses its lease must stop at the next checkpoint. The segment is split into chunks, and each chunk is written to a temporary object keyed by work id, epoch, and chunk number. The final object is assembled only after all chunks are present and the epoch is still current. If a worker is paused for two minutes, its lease expires. The scheduler grants the segment to another worker at a higher epoch. The old worker resumes and tries to write a chunk with the old epoch. The object store rejects the conditional write because the generation token is stale. The old worker reports lost ownership and exits. The new worker starts from the last committed checkpoint. Some CPU work is duplicated, but no output is corrupted. The accepted final object is the one assembled under the current epoch.

This scenario shows the division of responsibility. The lease manager bounds ownership in time. The worker stops at checkpoints. The object store enforces the epoch. The checkpoint format allows resumption. The system does not promise that the transcoding computation happens once. It promises that the accepted output corresponds to one epoch and that stale writes do not corrupt it. That is a useful guarantee. It is also honest. If the business required exactly-once computation for billing, the design would need a transactional ledger that records the accepted epoch and charges only once. The ledger would be the fenced resource for billing, separate from the object store.

The scenario also shows why lease duration is a policy choice. A 60-second lease with 15-second renewals tolerates a 45-second pause before expiry, minus safety margin. A two-minute pause is beyond the budget. The worker loses ownership and the work is retried. If pauses of two minutes are common, the lease should be longer or the work should checkpoint more frequently. There is no universal value. The correct value is derived from the platform's pause distribution, the cost of retry, and the tolerance for duplicate CPU work.

## 16. Summary of the design rules

The design can be reduced to a small set of rules. Partition work and serialize only within a partition. Grant time-bounded leases, not indefinite locks. Persist the grant before sending it. Increment a monotonic epoch on every grant. Make the worker compute a conservative local deadline and stop before the grantor's expiry. Reject stale completions by epoch. Fence external side effects at the resource, or make them idempotent. Treat heartbeats as hints and lease expiry as the reassignment trigger. Rebalance by draining, not by stealing running work. Measure lease expiry, stale completion, and pending age, not just throughput. Document the duplicate window and the assumptions that make it safe.

The most common failure mode in lease-based systems is not a broken clock or a network partition. It is a design that grants a lease, then performs an unbounded operation under the assumption that the lease is a lock. The second most common failure is a completion path that checks only the work id and not the epoch. The third is a resource that accepts writes without a fencing token. These are not exotic distributed-systems problems. They are interface problems. The lease protocol is only as strong as the weakest write path that ignores it.

A well-designed lease scheduler is not a single component. It is a contract between the admission layer, the partition manager, the worker runtime, and the resource that stores effects. The contract says: ownership is temporary, epochs are monotonic, stale writes are rejected, and duplicates are bounded. When all parties honor the contract, the scheduler can assign work at high volume without a global lock and recover from failures without manual intervention. When one party ignores the contract, the system falls back to hope. Hope is not a consistency model.

The design described here is deliberately conservative. It does not claim that leases solve consensus, and it does not hide the cost of fencing. It accepts that some work will be retried and some CPU will be wasted. In exchange, it provides a clear safety argument, a bounded recovery window, and an operational model that can be tested. For systems where duplicate side effects are expensive, that trade-off is usually the right one. For systems where duplicates are free, a simpler visibility timeout may be enough. The engineer's job is to know which system they are building.
