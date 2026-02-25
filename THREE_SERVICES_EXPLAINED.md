## WHY 3 SERVICES?

**new-api**: Accepts payments (high traffic, fast)  
**data-service**: Provides fresh data (read-only, lightweight)  
**svix-caller**: Delivers webhooks (CPU-heavy, needs recovery)

## FULL FLOW TIMELINE

```
T=10:15:01  Customer sends: POST /payments {amount: 2500}
            ↓
T=10:15:02  new-api response: 201 {id, amount, status}
            ↓
T=10:15:03  DB trigger creates event
            ↓
T=10:15:04  Sequin reads from Kafka
            ↓
T=10:15:05  Restate calls svix-caller
            ↓
T=10:15:06  svix-caller calls: GET data-service:3002/payload/550e8400...
            ↓
T=10:15:07  data-service returns: {id, amount: 2500, status: succeeded}
            ↓
T=10:15:08  svix-caller calls: POST svix.com/api/v1/messages/
            ↓
T=10:15:09  Svix sends: POST merchant.com/webhooks
            ↓
T=10:15:10  Merchant responds: 200 OK
```

---

Each can crash independently and recover.   
If new-api crashes → data already in DB.  
If data-service crashes → Restate retries  
If svix-caller crashes → Restate auto-recovers from journal.

**OLD (1 service):** Everything in memory → crash = lost webhook (1-5% loss)
**NEW (3 services):** Everything durable → crash = auto-recovery (0% loss)



## SERVICE 1: new-api (Port 3001) - Payment Creator

**INPUT:**
```bash
POST http://localhost:3001/payments
{
  "amount": 2500,
  "currency": "USD"
}
```

**WHAT HAPPENS:**
1. Generates payment ID (UUID)
2. Saves to DB: `INSERT INTO payments (id, amount, currency, status) VALUES (...)`
3. PostgreSQL TRIGGER fires automatically → creates event in `domain_events` table

**HOW THE TRIGGER WORKS:**
```sql
-- When new-api executes INSERT into payments:
INSERT INTO payments (id, amount, currency, status)
VALUES ('550e8400...', 2500, 'USD', 'succeeded')

-- PostgreSQL automatically fires this trigger function:
CREATE TRIGGER payment_created AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION notify_payment_created();

CREATE FUNCTION notify_payment_created() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO domain_events (event_type, object_id, payload)
  VALUES (
    'payment.succeeded',
    NEW.id,                    -- The new payment's ID
    row_to_json(NEW)           -- The entire payment as JSON
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- CRITICAL: Both INSERTs happen in SAME transaction
-- If crash → BOTH succeed or BOTH fail (NO LOST EVENTS!)
```

**HOW SEQUIN & KAFKA WORK:**
```
1. PostgreSQL writes to WAL (Write-Ahead Log)
   ↓ Records every transaction

2. Sequin connects to PostgreSQL
   ↓ Reads WAL directly (zero database load)
   ↓ Sees: "INSERT INTO domain_events (...)"

3. Sequin publishes to Kafka
   ↓ Topic: "webhook-events"
   ↓ Message: {event_id, event_type, object_id}

4. Kafka persists to disk
   ↓ Replicated across brokers (durable)

5. Restate ingress consumes from Kafka
   ↓ Gets the event, calls svix-caller
```

**OUTPUT:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "amount": 2500,
  "currency": "USD",
  "status": "succeeded"
}
```

**DB STATE:**
- `payments` table: 1 row with payment
- `domain_events` table: 1 row with event (created by trigger)

---

## SERVICE 2: data-service (Port 3002) - Data Provider

**INPUT:** (called by svix-caller)
```bash
GET http://localhost:3002/payload/550e8400-e29b-41d4-a716-446655440000
```

**WHAT HAPPENS:**
1. Queries DB: `SELECT * FROM payments WHERE id = '550e8400...'`
2. Returns **FRESH** current payment data (not a snapshot)

**OUTPUT:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "amount": 2500,
  "currency": "USD",
  "status": "succeeded",
  "created_at": "2024-01-30T10:15:00Z"
}
```

**KEY POINT - Why data-service exists:**

**Scenario 1: Webhook sent IMMEDIATELY (before refund)**
```
T=10:15:00  Payment created: amount=$25
T=10:15:15  Webhook sent before refund occurs
T=10:15:30  Customer refunded: amount=$0
```
Result: Webhook sends correct amount ($25) because it was delivered before the refund.

**Scenario 2: Webhook DELAYED (after refund)**
```
T=10:15:00  Payment created: amount=$25
            ↓ Event created

T=10:15:15  Event queued in Restate
            ↓ (not sent yet)

T=10:15:30  Customer refunded: amount=$0
            ↓ Payment record updated in DB

T=10:16:00  Webhook finally processes (delayed)

WITHOUT data-service:
  Sends stale snapshot from event: amount=$25 (INCORRECT)
  Merchant thinks payment succeeded for $25 but it was refunded!

WITH data-service:
  Fetches fresh data: SELECT * FROM payments
  Gets current amount: $0 (CORRECT)
  Merchant gets accurate webhook with current refund state
```

**Why this matters:**
Webhooks can be delayed due to:
- High load (queue processing time)
- Network issues
- Service retries
- Kubernetes pod restarts

**Solution: data-service ensures ALWAYS current state**
```rust
// Option A: NO data-service (store snapshot)
async fn send_webhook(event) {
  let payment = event.snapshot;  // OLD, created at 10:15:00
  send_to_svix(&payment).await;  // Sends amount: 2500
}

// Option B: WITH data-service (fetch fresh)
async fn send_webhook(event) {
  // Fetch at delivery time (10:16:00)
  let payment = fetch_from_data_service(event.object_id).await;
  // Query: SELECT * FROM payments WHERE id = '550e8400...'
  // Returns CURRENT amount from database (might be $0 if refunded)
  send_to_svix(&payment).await;  // Sends correct current state
}
```

---

## SERVICE 3: svix-caller (Port 9080) - Webhook Sender

**HOW IT REGISTERS WITH RESTATE:**

```
Step 1: svix-caller starts
  ├─ Defines Trait: #[restate_sdk::service] trait SvixCaller
  ├─ Implements: impl SvixCaller for SvixCallerImpl { ... }
  └─ Registers: HttpServer.bind(SvixCallerImpl.serve())
                 ↓ Tells Restate: "I run at http://svix-caller:9080"

Step 2: Script registers Kafka subscription
  └─ POST http://restate:8080/subscriptions
     ├─ source: kafka topic "webhook-events"
     └─ sink: SvixCaller.process() method
                 ↓ Tells Restate: "Route Kafka events to my process() method"

Step 3: Kafka publishes event
  └─ Topic: webhook-events
     Message: {event_type, object_id, merchant_id, payload}

Step 4: Restate ingress sees event
  ├─ Reads from Kafka
  ├─ Looks up subscription: "webhook-events" → SvixCaller.process()
  └─ Makes HTTP call: POST http://svix-caller:9080/SvixCaller/process
```

**INPUT:** (HTTP POST from Restate Ingress)
```
POST http://svix-caller:9080/SvixCaller/process

Body:
{
  "event_type": "payment.succeeded",
  "object_id": "550e8400-e29b-41d4-a716-446655440000",
  "merchant_id": "merchant-123",
  "id": 12345,
  "payload": {...}
}
```

**WHAT HAPPENS (Restate Calls SvixCaller.process()):**

```
async fn process(&self, _ctx: Context<'_>, event: Json<DomainEvent>) {
    // ↑ Restate calls this trait method
    // ↑ _ctx contains Restate journal for crash recovery

    STEP 1: Fetch fresh payment data
      ├─ GET http://data-service:3002/payload/550e8400...
      ├─ _ctx.run() journals this step
      └─ If crash here, Restate knows: "Fetch not completed"
         On restart, retry fetch

    STEP 2: Send to Svix API
      ├─ POST https://api.svix.com/api/v1/messages/
      ├─ Body: {event_type, payload with fresh data}
      ├─ _ctx.run() journals this step
      └─ If crash here, Restate knows: "Send not completed"
         On restart, skip fetch (already done), retry send only

    STEP 3: Return to Restate
      ├─ Returns: Ok(format!("sent_to_svix:..."))
      ├─ Restate journals: "SvixCaller.process() completed"
      └─ If crash already happened: Restate marked it done
         On restart, skip everything, move to next event
}
```

**RESTATE DURABILITY IN ACTION:**

```
Timeline:

T=0ms    Restate reads event from Kafka
T=1ms    Calls: SvixCaller.process(event)
T=2ms    → STEP 1: fetch_from_data_service()
T=50ms   Data service returns payment data
T=50ms   Restate journals: "STEP 1 succeeded" (Saved to disk)
T=51ms   → STEP 2: send_to_svix()
T=100ms  HTTP timeout! Process crashes

CRASH HAPPENS HERE:
  Restate journal has: {
    "event": {...},
    "steps_completed": ["fetch"],
    "steps_pending": ["send"]
  }

T=5000ms  svix-caller restarts
T=5001ms  Restate replays: SvixCaller.process(event)
T=5002ms  Reads journal: "fetch already done, skip it"
T=5003ms  → STEP 2: send_to_svix() (RETRY only this)
T=5050ms  Success!
T=5051ms  Restate journals: "All steps completed"

RESULT:
  Payment data fetched once (not twice)
  Sent to Svix once (not duplicate)
  No manual intervention needed
  Automatic recovery ensured
```

**WHY Call data-service (Not query DB directly)?**

```rust
// Option 1: svix-caller queries database directly
async fn call_svix(event) {
  // Requires: DB credentials, connection pool, schema knowledge
  let payment = sqlx::query_as(
    "SELECT * FROM payments WHERE id = $1"
  ).fetch_one(&db).await?;
  send_to_svix(&payment).await;
}
Problems:
  svix-caller tightly coupled to database
  Can't scale svix-caller independently
  If you change payment table schema → svix-caller breaks
  Database connection pool conflicts

// Option 2: Call data-service via HTTP
async fn call_svix(event) {
  // Just make HTTP request
  let payment = reqwest::Client::new()
    .get(&format!("http://data-service:3002/payload/{}", event.object_id))
    .send().await?
    .json().await?;
  send_to_svix(&payment).await;
}
Benefits:
  Loose coupling (services independent)
  Each service scales separately
  Can change payment schema without touching svix-caller
  data-service owns database schema
  Clean separation of concerns
```

**OUTPUT:** Svix sends to merchant:
```http
POST https://joes-tshirt-shop.com/webhooks
Content-Type: application/json
Svix-Signature: v1,g0hM9SsE+OTPJTGt...

{
  "event_id": "aa0e8400...",
  "event_type": "payment.succeeded",
  "payment": {
    "id": "550e8400...",
    "amount": 2500,
    "currency": "USD",
    "status": "succeeded"
  }
}
```

**OUTPUT:** Merchant's response:
```
200 OK
```

---