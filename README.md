# Reliable Webhook Architecture Demo

This is a webhook replication of the Dodo Payments production architecture. Read the full blog post here: [Building Reliable Webhooks at Scale](https://dodo.dev/blog/reliable-webhooks)

Production-grade webhook delivery system replicating Dodo Payments' reliable webhook infrastructure at scale.

#### Quick Start **Local setup:** See [LOCAL_SETUP.md](./LOCAL_SETUP.md)


## The Problem

When Joe runs his T-shirt shop, he needs instant notifications when customers pay. If your webhook system crashes mid-delivery, those payment notifications vanish forever. Customers get charged, but Joe never fulfills orders.

This demo shows how to build webhooks that never lose events, even during service crashes, network failures, database downtime, or deployment rollouts.

## Architecture Overview

```
Payment Created → PostgreSQL → Sequin (CDC) → Kafka → Restate → Svix Cloud → Merchant
     ↓              (WAL)         (Stream)    (Queue)  (Durable)  (Delivery)   (Joe's Shop)
   Atomic         Capture       Reliable    Ordering  Execution   Retries      Receives
   Writes         Changes       Transport   Preserved Guaranteed  Signing      Webhook
```

## Real-World Example: Joe's T-Shirt Shop

### The Setup

- **Dodo Payments**: Payment processor
- **Joe's T-Shirt Shop**: Merchant using Dodo to accept payments
- **Customer**: Buys a t-shirt for $25

### The Flow

#### 1. Payment is Created (Atomic Event Capture)

```bash
POST /payments
{
  "amount": 2500,
  "currency": "USD",
  "merchant_id": "joes-tshirt-shop"
}
```

The API service writes to PostgreSQL with a **database trigger** that atomically creates both the payment record and domain event record in a single transaction.

**Why atomic?** If we crash after writing the payment but before writing the event, the webhook is lost forever.

#### 2. Change Data Capture (Sequin)

Sequin monitors PostgreSQL's Write-Ahead Log (WAL) and detects new events:

```sql
SELECT * FROM domain_events WHERE merchant_id = 'joes-tshirt-shop';
-- event_type: 'payment.succeeded'
-- object_id: '550e8400-e29b-41d4-a716-446655440000'
```

**Why CDC?** Reading the WAL is more reliable than polling tables. It captures every change with exactly-once delivery guarantees.

#### 3. Kafka Streaming

Sequin publishes events to Kafka topic `webhook-events` with ordering preserved per merchant.

**Why Kafka?** Provides reliable, ordered delivery with events persisted to disk and replicated across brokers.

#### 4. Restate (Durable Execution)

Restate consumes from Kafka and invokes `SvixCaller.process()`:

```rust
async fn process(event: DomainEvent) -> Result<String> {
    // 1. Fetch enriched payload from data-service
    let payment = fetch_payment_details(event.object_id);

    // 2. Send to Svix Cloud
    svix.message().create(
        event.merchant_id,  // "joes-tshirt-shop"
        MessageIn {
            event_type: "payment.succeeded",
            payload: payment
        }
    );
}
```

**Why Restate?** If the service crashes mid-execution, Restate automatically retries from the last successful step. It's like a database transaction for your entire workflow.

**Crash recovery example:**
- Crashes after fetching payload but before Svix API call → Restate retries just the Svix call
- Crashes after Svix API call succeeds → Restate marks complete, moves to next event
- Network timeout → Restate retries with exponential backoff

#### 5. Svix Cloud (Webhook Delivery)

Svix receives the event and handles delivery to Joe's shop with automatic retries, cryptographic signing, and monitoring.

```http
POST https://joes-tshirt-shop.com/webhooks
Content-Type: application/json
Svix-Signature: v1,g0hM9SsE+OTPJTGt...

{
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "event_type": "payment.succeeded",
  "payment": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "amount": 2500,
    "currency": "USD",
    "status": "succeeded"
  }
}
```

**Svix handles:**
- Cryptographic signing (HMAC-SHA256)
- Automatic retries with exponential backoff
- Delivery monitoring and alerting
- Customer portal for debugging webhooks

#### 6. Joe's Shop Receives Webhook

```javascript
app.post('/webhooks', (req, res) => {
  // Verify signature
  svix.webhooks.verify(req.body, req.headers);

  // Process event
  const { payment } = req.body;
  fulfillOrder(payment.id);

  res.status(200).send('OK');
});
```

## Key Components

| Component | Role |
|-----------|------|
| **PostgreSQL + Triggers** | Atomic event capture |
| **Sequin (CDC)** | Reliable event extraction |
| **Kafka** | Durable event streaming |
| **Restate** | Durable workflow execution |
| **Svix** | Webhook delivery platform |

## Reliability Guarantees

| Failure Scenario | How It's Handled |
|-----------------|------------------|
| API crashes after payment | Trigger ensures event is written atomically |
| Sequin crashes | Resumes from last WAL position |
| Kafka broker fails | Replication keeps events safe |
| Restate crashes mid-processing | Resumes from last journal entry |
| Svix API timeout | Restate retries with backoff |
| Merchant endpoint down | Svix retries for 3 days |

## Architecture Comparison

### Svix for Webhook Delivery

**Why Svix?**
- Automatic webhook signing (HMAC-SHA256)
- Delivery monitoring & alerts
- Customer self-service portal
- Advanced features (transformations, filtering, rate limiting)
- Reliable retries for 3 days with exponential backoff

Focus on your core product while Svix handles webhook delivery infrastructure.

## Architecture Principles

### 1. Atomic Event Capture

```sql
CREATE OR REPLACE FUNCTION notify_payment_created()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO domain_events (event_type, object_id, merchant_id, payload)
  VALUES ('payment.succeeded', NEW.id, NEW.merchant_id, row_to_json(NEW));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### 2. Change Data Capture

```
AVOID - Traditional Polling: SELECT * FROM events WHERE created_at > last_poll
  - Misses events during high load
  - Adds load to database

BETTER - CDC (Sequin): Read from PostgreSQL WAL
  - Zero impact on database performance
  - Captures every change
  - Exactly-once delivery
```

### 3. Durable Execution

```rust
// WITHOUT Restate: Crash = restart from beginning
async fn deliver_webhook(event) {
  let payload = fetch_payload(event.id);
  send_to_svix(payload);
}

// WITH Restate: Crash = resume from last step
#[restate_sdk::service]
async fn deliver_webhook(ctx, event) {
  let payload = ctx.run(|| fetch_payload(event.id)).await;  // Cached
  ctx.run(|| send_to_svix(payload)).await;                   // Idempotent
}
```

### 4. Separation of Concerns

Each component has a single responsibility and can fail independently without data loss:

```
Payment API:      Accepts payments, writes to database
PostgreSQL:       Source of truth for payment data
Sequin:           Reliable event extraction
Kafka:            Durable event streaming
Restate:          Durable workflow execution
Svix:             Webhook delivery infrastructure
```

## Real-World Example: Dodo Payments

This demo replicates the Dodo Payments production architecture:
- PostgreSQL + triggers for atomicity
- Sequin for CDC (Change Data Capture)
- Kafka for event streaming
- Restate for durable execution
- **Svix for webhook delivery** ← This exact architecture

These principles are battle-tested in production at Dodo Payments.

## Common Pitfalls Avoided

### AVOID: Event Creation in Application Code
```javascript
// Race condition - crash between writes = lost event
await db.payments.create(payment);
await db.events.create(event);
```

### BETTER: Event Creation in Database Trigger
```sql
-- Atomic - both succeed or both fail
CREATE TRIGGER payment_created AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION notify_payment_created();
```

### AVOID: Direct HTTP Calls Without Durability
```javascript
// Crash = lost event
app.post('/payments', async (req, res) => {
  await db.payments.create(req.body);
  await axios.post('https://merchant.com/webhook', event);
});
```

### BETTER: Async Processing with Durability
```javascript
// Event persisted, delivery guaranteed
app.post('/payments', async (req, res) => {
  await db.payments.create(req.body);  // Trigger creates event
  res.json({ success: true });
  // Sequin → Kafka → Restate handles delivery
});
```

## Documentation

- **[LOCAL_SETUP.md](./LOCAL_SETUP.md)** - Local development setup guide
- **[SVIX_SETUP.md](./SVIX_SETUP.md)** - Svix Cloud integration guide
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Detailed architecture explanation (if exists)

**External Resources:**
- Sequin Docs: https://docs.sequinstream.com
- Restate Docs: https://docs.restate.dev
- Svix Docs: https://docs.svix.com

## Blog Post

Read the full story: [Building Reliable Webhooks: How Dodo Payments Delivers 100% of Events](https://dodo.dev/blog/reliable-webhooks)

---

**Built to demonstrate production-grade webhook architecture using battle-tested open source tools.**

**Interested in building your own webhook system instead of using Svix?** Checkout branch [`inhouse-webhook-no-svix`](https://github.com/your-repo/tree/inhouse-webhook-no-svix) for an in-house webhook implementation.
