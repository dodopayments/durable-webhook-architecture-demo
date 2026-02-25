# Sequin Configuration Guide

After Docker is running, manually configure Sequin via browser to connect PostgreSQL → Kafka.

## Prerequisites: Create Replication Slot (REQUIRED)

Before accessing Sequin UI, create the replication slot in PostgreSQL:

```bash
docker compose exec postgres psql -U dodo -d dodo_demo -c "SELECT pg_create_logical_replication_slot('sequin_slot', 'pgoutput');"
```

Expected output:
```
pg_create_logical_replication_slot
------------------------------------
 (sequin_slot,0/28F07E8)
```

## Step 1: Access Sequin UI
```
http://localhost:7376
```

Click "Get started"

## Step 2: Connect Database

Click "Connect database" button

Fill in these values:
- **Host**: `postgres`
- **Port**: `5432`
- **Database**: `dodo_demo`
- **Username**: `dodo`
- **Password**: `dodo_pass`
- **Publication name**: `domain_events_pub`
- **Slot name**: `sequin_slot`

Click "Connect Database"

## Step 3: Create Kafka Sink

Click "Sinks" in left sidebar → "Create Sink"

Choose **Kafka** (the dots/nodes icon)

### Configure Tables:
- Change from "All" to "Include"
- Select only: `domain_events` table

### Configure Kafka:
- **Hosts**: `kafka:9092`
- **Topic**: `webhook-events`
- **Message format**: JSON

Keep other settings as default (Insert/Update/Delete enabled, Batch size 200)

Click "Create Sink"

## Step 4: Create Transform Function

After creating the sink, you need to add a transform to extract just the database record from Sequin's metadata wrapper.

1. In the Sink overview page, scroll to the **Transforms** section
2. Click **"+ Create new function"**
3. Fill in the function details:
   - **Function name**: `extract_record`
   - **Function type**: Transform function (should be pre-selected)
   - **Description**: Extracts database record from Sequin wrapper

4. Replace the code with:
   ```elixir
   def transform(action, record, changes, metadata) do
     record
   end
   ```

5. Click **"Create Function"**
6. Go back to the Sink (click back arrow or "Sinks" in left menu)
7. Click **"Edit"** on your Kafka sink
8. In the **Transforms** section, select `extract_record` from the dropdown
9. Click **"Save"** to apply the transform

This transform extracts just the `record` field (the actual database row) and removes Sequin's metadata wrapper, so Restate receives the event in the correct format.

## Step 5: Fix Replica Identity Warning

Run this SQL command:

```bash
docker compose exec postgres psql -U dodo -d dodo_demo -c \
  "ALTER TABLE \"public\".\"domain_events\" REPLICA IDENTITY FULL;"
```

Go back to Sequin UI and click "Refresh" in the blue notice box.

## Step 6: Test Pipeline

Create a test payment:

```bash
curl -X POST http://localhost:3001/payments \
  -H "Content-Type: application/json" \
  -d '{
    "merchant_id":"test-merchant-1",
    "amount":5000,
    "currency":"USD"
  }'
```

Check merchant received webhook:

```bash
curl http://localhost:4001/stats | jq .
```

Should show `total_received: 1`

## Done!

Sequin is now streaming PostgreSQL domain_events → Kafka → Restate → Svix pipeline is ready.

You can now run tests:
```bash
./scripts/run-tests.sh crash
```
