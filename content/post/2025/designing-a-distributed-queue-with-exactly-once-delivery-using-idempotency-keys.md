---
title: "Designing A Distributed Queue With Exactly Once Delivery Using Idempotency Keys"
description: "A comprehensive technical exploration of designing a distributed queue with exactly once delivery using idempotency keys, covering key concepts, practical implementations, and real-world applications."
date: "2025-05-22"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/assets/images/blog/Designing-A-Distributed-Queue-With-Exactly-Once-Delivery-Using-Idempotency-Keys.png"
coverAlt: "Technical visualization representing designing a distributed queue with exactly once delivery using idempotency keys"
---

# Designing A Distributed Queue With Exactly Once Delivery Using Idempotency Keys

### The Ghost in the Machine: Why Your Queue Doesn't Deliver "Exactly Once"

Imagine this: you are the lead engineer for a global e-commerce platform. It’s Cyber Monday. Traffic is a firehose. A customer clicks "Place Order." A charge runs on their credit card. The payment gateway responds with a `200 OK`. The system processes the order, updates inventory, and sends a confirmation email. Profit. Life is good.

Now, imagine the same scenario, but with a single, microscopic hiccup. The payment gateway’s response reaches your service, but before your service can acknowledge it, the network connection drops. Your client library, programmed for resilience, sees a timeout. It doesn't know the payment succeeded. It retries the request. The charge runs again. The customer is billed twice. The `200 OK` from the first request was lost in transit, but the effect was not.

This is the existential nightmare of distributed systems: the gap between what _happened_ and what we _know_ happened. At the heart of this nightmare lies the humble message queue—the backbone of asynchronous, decoupled architecture. In a perfect, synchronous world, an RPC call either succeeds or fails. In the asynchronous world of queues, messages have a lifetime beyond a single socket connection. They can be delivered, processed, poisoned, requeued, and redelivered. How, then, do we build a system that guarantees that a single logical action—a payment, a database write, a notification—happens exactly once, even when the network lies to us?

The answer, as we will explore in this post, is a deceptively simple concept called the **Idempotency Key**, and it represents a fundamental shift in how we think about state, transactions, and reliability. We are going to design a distributed queue from the ground up, specifically engineered to achieve exactly-once delivery through the careful application of idempotency. This journey will take us through the depths of distributed systems theory, practical engineering trade-offs, and real-world code. By the end, you'll have a mental blueprint for building or evaluating systems that can truly promise exactly-once semantics.

## 1. The Three Deliveries: At-Most-Once, At-Least-Once, and Exactly-Once

Before we dive into idempotency keys, let's ground ourselves in the three fundamental delivery guarantees that message queues offer. These are not just academic categories; they are the axes upon which your system’s reliability, performance, and complexity are balanced.

### At-Most-Once Delivery

This is the simplest and fastest guarantee. The message is delivered zero or one time. The producer sends the message to the broker; the broker delivers it to a consumer. If the consumer fails or the network hiccups, the message is simply lost. There are no retries. This is acceptable for scenarios where occasional data loss is tolerable—for example, non-critical metrics, clickstreams, or sensor readings where missing one data point doesn't cause harm. But in our e-commerce example, losing a payment request is a disaster.

**Pros:** Maximum throughput, minimal broker state, low latency.  
**Cons:** No recovery from failures, data loss is possible.

### At-Least-Once Delivery

Here, the guarantee is that the message will be delivered at least once, but potentially many times. The broker persists the message and waits for an acknowledgment (ACK) from the consumer. If the consumer crashes or the ACK is lost, the broker redelivers the message. This is the standard guarantee in most message queue systems (e.g., Apache Kafka, RabbitMQ with publisher confirms). However, it introduces duplication. The consumer must be prepared to handle the same message multiple times.

**Pros:** High durability, no message loss.  
**Cons:** Duplicate messages, requires idempotent processing on the consumer side.

### Exactly-Once Delivery

The holy grail: each message is delivered and processed exactly one time. This implies no loss and no duplication. Achieving exactly-once is notoriously difficult because it requires coordination across distributed components—producer, broker, consumer, and potentially external systems (like a database or payment API). Distributed transactions (like two-phase commit) can provide exactly-once, but at a severe performance and complexity cost. That’s why most practical systems settle for at-least-once plus idempotent consumers. But can we build a queue that itself provides exactly-once? That's our mission.

## 2. The Power of Idempotency

Idempotency is a property of an operation: applying it multiple times has the same effect as applying it once. Mathematically, an operation `f` is idempotent if `f(f(x)) = f(x)`. In distributed systems, we often design our endpoints to be idempotent—for example, setting a value, updating a record to a specific state, or creating a resource only if it doesn't exist. If a client retries a request, the server detects that the operation has already been performed and returns the same result without side effects.

But idempotency is not free. It requires the client to supply a unique identifier (the idempotency key) for each operation, and the server to store the results of completed operations (at least for a while). This is the exact pattern we will embed into the queue itself.

### Why Idempotency Keys?

Consider a REST API for payments. Stripe popularized idempotency keys: each payment request includes an `Idempotency-Key` header—a UUID generated by the client. If the client times out and retries with the same key, Stripe returns the original response (e.g., `200 OK` with the charge ID) rather than charging again. The key is stored for a short time (typically 24 hours) and cleaned up.

Now generalize this to a queue. Instead of idempotent endpoints, we want idempotent message delivery. The consumer processes a message and produces some side effect (e.g., updating a database, calling an external API). If the same message is delivered multiple times, we need to ensure the side effect happens only once. We _could_ make the consumer idempotent, but that puts the burden on every consumer application. Instead, we can design the queue itself to prevent duplicate processing. The queue broker can keep track of which idempotency keys have been successfully processed, and refuse to deliver duplicates.

This is the core idea of an **idempotency-key aware queue**. Let's design it step by step.

## 3. Overview of the Distributed Queue Architecture

Our system has three main components:

- **Producer**: submits messages to the queue. Each message must include an idempotency key.
- **Queue Broker**: the central service that receives, stores, and delivers messages. It must be highly available and partitioned.
- **Consumer**: receives messages, processes them, and acknowledges completion.

The broker maintains a persistent store for messages (like Kafka's log) plus a separate deduplication store that maps idempotency keys to the outcome of the message (e.g., "pending" or "processed").

The lifecycle of a message:

1. **Produce**: Producer generates a globally unique idempotency key (e.g., UUID v4). It sends the message payload and the key to the broker. The broker checks if this key has already been seen. If yes, it returns the existing result (if any) and discards the duplicate. If not, it accepts the message and stores it.
2. **Deliver**: The broker assigns the message to a consumer. The consumer does not acknowledge immediately; it processes the message and then sends an ACK with the idempotency key.
3. **Acknowledge**: The broker marks the idempotency key as "processed" and may store the output (the consumer's response) for later retrieval. The message is then removed from the active queue.
4. **Redelivery**: If the consumer fails to ACK within a timeout (or sends a NACK), the broker may attempt to redeliver the same message to another consumer (or the same one after a delay). But because the idempotency key is still in "pending" state, the new delivery will be treated as a new attempt. Only after a successful ACK does the key become "processed".

The critical insight: the broker must ensure that a message with a given idempotency key is processed exactly once _across all consumers and across all delivery attempts_. This means the broker must be the single source of truth for the state of each key. This introduces consistency challenges—exactly the kind that distributed systems are infamous for.

## 4. The Producer Side: Generating and Retrying

### Generating Idempotency Keys

The simplest approach is for the producer to generate a random UUID for each unique logical operation. But we must ensure that the same logical operation always generates the same key. For example, if a payment is being retried, we must reuse the same key that was used in the original attempt. This implies that the producer must store the mapping (e.g., request context -> key) across retries. Typically, the producer (the service that initiates the action) assigns a key at the very start of the operation and stores it in a local database or an in-memory cache with persistence.

**Practical scenario**: A booking service receives a request to reserve a seat. It generates an idempotency key, writes the request details (with key) into a local database, and sends the message to the queue. If the send fails (timeout), it retries the send with the same key. The broker detects the duplicate and returns success. The booking service then returns to the client the result.

### Handling Duplicate Production

The producer must also be prepared for the scenario where the broker received the message but the producer's send ACK was lost. The producer will retry. The broker sees the same key and knows that the message is already accepted (and possibly already processed). It should return the outcome of the original processing. This requires the broker to store the result of processing (e.g., the consumer's response) for each idempotency key, at least until the producer's retry window expires.

**Implementation detail**: The producer's send API should be idempotent. It takes an idempotency key, a message payload, and an optional TTL. If the key already exists in the broker's dedup store, the broker returns the stored result. If not, it accepts the message, schedules it for delivery, and returns a pending status.

### Choosing an Idempotency Key Scope

What constitutes a "logical operation"? The key must be unique across the entire queue (or partitioned per topic/queue). If two different producers accidentally generate the same UUID (extremely unlikely with proper random generation), the system would reject one of them. But that's a feature, not a bug: it prevents unintended duplicates.

**Best practice**: Use a combination of a producer identifier and a sequence number, or a globally unique UUID v4. For high-throughput systems, UUID v4 generation is fast and collision probability is negligible (2^122 possible values).

## 5. The Queue Broker: Storage and Deduplication

The broker is the heart of the system. It must be:

- **Durable**: Messages and dedup state must survive crashes.
- **Consistent**: The dedup store must be strongly consistent to prevent double processing. Strong consistency, however, conflicts with high availability in a distributed system (CAP theorem). We'll address this later.
- **Scalable**: The broker should be horizontally partitioned by message key (e.g., hash of idempotency key) to distribute load.

### Storage Models

1. **Separate Dedup Store**: Use a strongly consistent database like a SQL database with a unique constraint on the idempotency key column. The broker atomically inserts the key when accepting a message, then updates its status when the consumer ACKs. This is simple but can become a bottleneck.

2. **Log-Based Dedup (like Kafka with exactly-once semantics)**: Apache Kafka achieves exactly-once processing (in its "transactional API") by using atomic commits to a compacted topic. Each idempotency key is written as a record. The broker's internal log has a single writer per partition, so ordering and dedup can be handled in the log. However, Kafka's exactly-once relies on the consumer writing its own offsets and using idempotent producers. Our design is more generic.

3. **Distributed Key-Value Store with Compare-and-Set**: Use a system like etcd, ZooKeeper, or a strongly consistent NoSQL store (e.g., MongoDB with read concern "linearizable") to store key-state pairs. The broker uses atomic compare-and-set to ensure that only one write (the first) succeeds for a given key.

For our design, we'll use a relational database with unique constraints, as it's easiest to reason about. We'll assume the broker runs on a single master node for the dedup store (which can be replicated synchronously for durability). In production, you'd shard the dedup store across multiple databases by hashing the idempotency key.

### Message Acceptance Flow

1. **Producer sends** `AcceptMessage(key, payload)`.
2. **Broker** queries dedup store for `key`:
   - If exists and status is "processed": return the stored result (which may be the consumer's response or a success marker).
   - If exists and status is "pending": return "pending" (or the stored result if processing completed but not yet stored).
   - If not exists: insert new row with status "pending", message payload, and timestamp. Then enqueue the message to the delivery mechanism (e.g., a queue topic or database-backed queue). Return "accepted".
3. **Broker** then delivers the message to a consumer.

### Handling Duplicate Accepts

If the broker itself is clustered, we must ensure that two instances don't accept the same idempotency key simultaneously. This is a classic distributed concurrency issue. The simplest solution is to route all requests for a given key to a single partition (e.g., by consistent hashing). Within that partition, a single leader handles writes using a local lock or a database transactional insert. This gives us linearizability per key.

### De-duplication Store Schema

```sql
CREATE TABLE dedup (
    idempotency_key VARCHAR(64) PRIMARY KEY,
    status ENUM('pending', 'processed') NOT NULL DEFAULT 'pending',
    payload BLOB,  -- original message
    result BLOB,   -- optional result from consumer
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMP,
    ttl TIMESTAMP  -- expiry for cleanup
);
```

We also need a queue table (or an external message broker) to hold messages awaiting delivery:

```sql
CREATE TABLE message_queue (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    idempotency_key VARCHAR(64) NOT NULL,
    payload BLOB,
    status ENUM('delivered', 'acknowledged', 'redelivering') DEFAULT 'delivered',
    consumer_id VARCHAR(128),
    delivery_attempt INT DEFAULT 0,
    created_at TIMESTAMP
);
```

## 6. The Consumer Side: Processing and Acknowledging

The consumer receives a message from the broker. It must:

1. **Process the message**: Execute the business logic (e.g., call payment gateway, update DB).
2. **Acknowledge**: Send an ACK back to the broker with the idempotency key, optionally including a result.

The broker will then update the dedup store status to "processed" and store the result. If the consumer crashes before sending the ACK, the broker's delivery timeout will trigger a redelivery. But thanks to the dedup store, the same idempotency key will not cause a double execution—even if the second delivery arrives at a different consumer, the broker will detect that the key is still "pending" (since the first consumer never ACKed). Wait, that's a problem: if the first consumer partially processed the message (side effect happened) but crashed before ACKing, then the broker will redeliver the message, and the new consumer will re-execute the side effect, leading to duplication. Our idempotency key mechanism only works **if the consumer writes its ACK atomically with the side effect**.

This is the crux of exactly-once delivery. We need to ensure that the side effect and the ACK are atomic. That typically means using a transactional protocol or an external idempotency receiver.

### The Consumer's Atomic Commit Problem

Consider a consumer that updates a bank account balance. The consumer writes "deduct $10" to the database, then sends an ACK to the broker. If the database write succeeds but the ACK is lost, the broker will redeliver the message. The new consumer will attempt the write again, causing double deduction.

To avoid this, the consumer must either:

- **Use an idempotent side effect**: The database write is designed to be idempotent (e.g., using a unique constraint on the idempotency key in the database). Then double execution is safe.
- **Write the ACK in the same transaction**: The consumer can store the idempotency key in its own database as part of the same transaction that updates the account. Then, before processing a message, it checks if the key exists in its local database. If it does, it skips processing and pretends success. This moves the dedup logic to the consumer.

Many systems choose the second approach: the queue provides at-least-once, and the consumer is responsible for idempotency. However, our goal is to build a queue that provides exactly-once _on its own_, so we want to relieve the consumer from this burden. Can we make the ACK atomic with the side effect? Yes, by making the broker and the consumer's database participants in a distributed transaction (e.g., via two-phase commit). That's heavy.

Alternatively, we can use **outbox pattern**: The consumer writes the result (including the side effect) into an outbox table, and a separate process (or the broker) consumes the outbox atomically. But again, complexity.

**Simpler approach**: The broker can enable exactly-once at the cost of storing the consumer's result and then delivering that result on redelivery. But the consumer's side effect is still a problem. We'll revisit this in the "Fault Tolerance" section.

For now, let's assume the consumer's side effect is idempotent. For example, the consumer sets a field to a specific value (e.g., "status = charged") rather than incrementing a counter. Then double execution is harmless.

### Consumer ACK Flow

1. Consumer receives message with `key` and `payload`.
2. Consumer processes payload.
3. Consumer sends `Acknowledge(key, result)` to broker.
4. Broker updates dedup store: status = 'processed', result = result.
5. Broker may then delete the message from the active queue.

If the consumer crashes after processing but before ACK, the broker will eventually timeout and redeliver. The second consumer will process the same payload. If the side effect is idempotent, it's okay. If not... problem.

## 7. Handling Failures and Consistency

Distributed systems are defined by their failure modes. Let's examine the key failure scenarios in our queue and how idempotency keys help (or don't).

### Producer Fails After Sending

The producer sends a message but crashes. The message is safely in the broker. When the producer recovers, it may or may not retry. If it retries with the same idempotency key, the broker returns the current state. The logical operation (e.g., placing an order) is still in progress. This is fine.

### Broker Crashes After Accepting But Before Storing

If the broker crashes between receiving the message and writing to the dedup store, the producer will see an error or timeout. It will retry. The new leader (if clustered) will have no record of the key, so it will accept the duplicate. This is okay because we have no record of the original. However, if the original write _partially_ succeeded (dedup row created but message not enqueued), we risk losing the message. To prevent loss, we need atomic writes: the dedup insert and the queue insert must be in the same transaction. Our schema design with a SQL database ensures this.

### Consumer Crashes Mid-Processing

As discussed, this is the Achilles' heel. The broker redelivers the message to a different consumer (or the same after recovery). The second consumer will re-execute the side effect. If the side effect is not idempotent, we get duplication. Can we prevent this?

One solution: **Consumer-provided idempotency check**. The broker includes the idempotency key in every delivery attempt. The consumer, before acting, checks if it has already processed this key (by looking up in its own database). If yes, it returns a cached result. This is essentially at-least-once with consumer-side dedup. Our queue can facilitate this by ensuring the key is always present, but the consumer must implement the check.

Another solution: **Transactional ACK**. The consumer writes its side effect and the ACK (a special row in a separate table) in a single transaction. The broker then polls for ACKs from the consumer's database (or the consumer pushes the ACK after the transaction commits). This is exactly the pattern used by systems like Kafka with exactly-once sinks (e.g., Kafka Connect). But it couples the broker with the consumer's database.

We can design the broker to support an "exactly-once sink" mode: the consumer uses a transactional outbox that includes a "processed marker" for the idempotency key. The broker can read that outbox atomically with the side effect. But this is beyond the scope of a general-purpose queue.

For our design, we will declare that our queue provides exactly-once delivery under the assumption that the consumer's processing is idempotent. This is the practical compromise: we guarantee no duplicate messages are delivered to the consumer _unless_ the consumer crashes before ACKing, and in that case the consumer must tolerate a single re-execution. However, by using idempotency keys, we can ensure that even if a message is delivered twice, the business effect is the same.

### Network Partitions

What if a partition separates the broker from the consumer? The consumer may be processing but unable to ACK. The broker's timeout will cause redelivery to another consumer (if any). The original consumer may still be processing. Could both consumers process the same message simultaneously? Possibly, if the network partition splits the consumer group. For example, with a standard queue like RabbitMQ, a message is in flight to one consumer; if the connection breaks, the broker re-queues it and another consumer picks it up. The two consumers might process it concurrently. Our idempotency key doesn't prevent concurrent execution; it only helps if the side effect is idempotent. This is a fundamental limitation of asynchronous queues without distributed locks.

To avoid concurrent duplicate processing, we need to ensure that once a message is delivered, it is not redelivered until a definitive timeout. This is what most queues do. However, during a network partition, the timeout may expire prematurely. We can minimize this by using larger timeouts and heartbeat mechanisms. But it's not bulletproof.

**Takeaway**: In practice, "exactly-once" in distributed queues is always a combination of at-least-once plus idempotent processing, and the guarantee is probabilistic. Our idempotency key approach raises the bar but does not eliminate all edge cases.

## 8. Code Examples: A Simplified Implementation

Let's implement a minimal version of the broker in Python using SQLite for demonstration. This will illustrate the core logic.

### Broker API (pseudo-code)

```python
import sqlite3
import uuid
from datetime import datetime, timedelta

class DistributedQueue:
    def __init__(self, db_path):
        self.conn = sqlite3.connect(db_path, isolation_level=None)  # autocommit?
        self.init_db()

    def init_db(self):
        c = self.conn.cursor()
        c.execute('''
            CREATE TABLE IF NOT EXISTS dedup (
                idempotency_key TEXT PRIMARY KEY,
                status TEXT DEFAULT 'pending',
                payload BLOB,
                result BLOB,
                created_at TEXT
            )
        ''')
        c.execute('''
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                idempotency_key TEXT,
                payload BLOB,
                state TEXT DEFAULT 'pending',
                consumer TEXT,
                delivery_count INTEGER DEFAULT 0,
                created_at TEXT
            )
        ''')
        self.conn.commit()

    def accept_message(self, idempotency_key, payload):
        c = self.conn.cursor()
        # Attempt to insert if not exists
        try:
            c.execute('''
                INSERT INTO dedup (idempotency_key, status, payload, created_at)
                VALUES (?, 'pending', ?, ?)
            ''', (idempotency_key, payload, datetime.utcnow().isoformat()))
            self.conn.commit()
        except sqlite3.IntegrityError:
            # Key already exists; fetch current status
            c.execute('SELECT status, result FROM dedup WHERE idempotency_key = ?', (idempotency_key,))
            row = c.fetchone()
            if row:
                status, result = row
                if status == 'processed':
                    return ('duplicate_processed', result)
                else:
                    return ('duplicate_pending', None)
            # Should not happen, but just in case
            return ('error', None)

        # Insert message into queue
        c.execute('''
            INSERT INTO messages (idempotency_key, payload, state, created_at)
            VALUES (?, ?, 'pending', ?)
        ''', (idempotency_key, payload, datetime.utcnow().isoformat()))
        self.conn.commit()
        return ('accepted', None)

    def deliver_message(self, consumer_id):
        # Fetch next pending message
        c = self.conn.cursor()
        c.execute('''
            SELECT id, idempotency_key, payload FROM messages
            WHERE state = 'pending' AND (consumer IS NULL OR consumer = ?)
            ORDER BY id LIMIT 1
        ''', (consumer_id,))
        row = c.fetchone()
        if row:
            msg_id, key, payload = row
            c.execute('''
                UPDATE messages SET state = 'delivered', consumer = ?, delivery_count = delivery_count + 1
                WHERE id = ?
            ''', (consumer_id, msg_id))
            self.conn.commit()
            return (key, payload)
        return None

    def acknowledge(self, idempotency_key, result):
        c = self.conn.cursor()
        # Update dedup store
        c.execute('''
            UPDATE dedup SET status = 'processed', result = ? WHERE idempotency_key = ?
        ''', (result, idempotency_key))
        # Delete message from queue (or mark as done)
        c.execute('''
            UPDATE messages SET state = 'acknowledged' WHERE idempotency_key = ?
        ''', (idempotency_key,))
        self.conn.commit()
```

This is a single-node implementation. In production, you'd use a distributed database and handle concurrency with row-level locks (the unique constraint already ensures atomicity for the first insert).

### Consumer Example

```python
class PaymentConsumer:
    def __init__(self, broker, db_connection):
        self.broker = broker
        self.db = db_connection

    def process_next(self):
        msg = self.broker.deliver_message(consumer_id='payment-consumer-1')
        if not msg:
            return
        key, payload = msg
        # Assume payload is a dict with payment_id, amount, etc.
        # Check if we already processed this key (if we want extra safety)
        # But we rely on idempotent side effect: update a payment record status.
        # Example: update payments SET status='charged' WHERE payment_id = ?
        # This is idempotent because setting status to 'charged' twice is fine.
        self.db.execute("UPDATE payments SET status = 'charged' WHERE payment_id = ?",
                        (payload['payment_id'],))
        # If no rows updated, it may be already charged, but that's ok.
        # After processing, ACK.
        self.broker.acknowledge(key, "success")
```

## 9. Performance and Trade-offs

Idempotency key-based exactly-once delivery adds overhead:

- **Storage**: Dedup store grows with each unique key. Must implement TTL cleanup (e.g., delete keys older than 24 hours).
- **Write Amplification**: For each message accepted, we insert into two tables. For ACK, we update both.
- **Latency**: The producer must wait for the broker to confirm uniqueness. This can be mitigated by batching.
- **Throughput**: The dedup store becomes a bottleneck. Sharding by key helps.

**Comparison to Kafka's Exactly-Once Semantics (EOS)**

Kafka achieves exactly-once by using idempotent producers (per-partition sequence numbers) and transactions that atomically commit offsets and writes to a sink. This is more efficient because it leverages the log structure; the broker does not need a separate dedup store for each key. However, Kafka's exactly-once is limited to a single partition and requires the consumer to write its offsets in the same transaction. Our approach is more general and doesn't require the consumer to modify its storage system, but it is more heavy.

**When to use our design?**

- When you need exactly-once delivery across multiple consumers and the side effect is idempotent.
- When you want to offload dedup logic from consumers.
- When you can tolerate the overhead of a secondary store.

## 10. Beyond the Basics: Advanced Features

### Exactly-Once with Non-Idempotent Consumers

If the consumer's side effect is not idempotent (e.g., appending a row to a log), we need stronger guarantees. One approach is to have the broker act as a two-phase coordinator: deliver the message, wait for the consumer to execute, then finalize. The consumer must agree to commit or abort. This is essentially distributed transactions.

Another approach: use **compensating actions**. If a duplicate is detected, the queue can issue a compensating message to undo the duplicate. This is complex.

Better: redesign the consumer to be idempotent. Often, it's easier to add a unique constraint in the consumer's database (e.g., a table of processed idempotency keys) than to build full transactional support.

### Idempotency Key Cleanup

Keys must expire. The broker should periodically purge keys older than a configurable TTL. The TTL should be longer than the maximum possible retry window. For example, if a producer might retry for up to 1 minute, and a consumer might take 5 minutes to process, set TTL to 1 hour.

### Message Ordering

Our design does not guarantee ordering across messages with different idempotency keys. But if you need FIFO per key (or per group), you can use the unique key to order: since each key appears only once, ordering can be done by assigning a monotonically increasing sequence ID to each key at the producer. However, typical FIFO queues (like SQS FIFO) use a message group ID and rely on ordering within a group. Our idempotency key can serve as both the dedup token and the grouping key.

## 11. Conclusion

We've journeyed from the ghost in the machine—the heart-stopping duplicate billing—to the architectural depths of a distributed queue designed for exactly-once delivery. The idempotency key is not a silver bullet; it requires careful handling of consumer failures and side effects. But it is a powerful pattern that shifts the burden of deduplication from the consumer to the infrastructure, enabling simpler and more robust applications.

As you design your next system, ask not "how do I prevent duplicates?" but "how do I make my system idempotent?" Build your queues with idempotency key awareness, and you'll sleep better on Cyber Monday.

The code you write today may not be perfect, but it can be exactly-once enough.
