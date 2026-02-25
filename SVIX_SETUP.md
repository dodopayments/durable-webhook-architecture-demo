# Svix Setup Guide

Quick setup guide for integrating Svix Cloud webhook delivery.

## Step 1: Get Svix API Token

1. Sign up at https://app.svix.com
2. Go to **API Access** in the sidebar
3. Copy your API token (starts with `testsk_` for test environment)

## Step 2: Configure Environment

Create `.env` file in project root:

```bash
SVIX_AUTH_TOKEN=testsk_your_token_here
```

## Step 3: Start Services

```bash
# Build and start all services
docker compose up -d --build

# Wait for services to be healthy
docker compose ps
```

## Step 4: Register with Restate

```bash
./scripts/register-restate-handler.sh
```

This registers the `SvixCaller` service and creates the Kafka subscription.

## Step 5: Create Svix Application

Get a merchant_id from your database:

```bash
docker compose exec -T postgres psql -U dodo -d dodo_demo \
  -c "SELECT DISTINCT merchant_id FROM payments LIMIT 1;"
```

Create Svix application with matching UID:

```bash
curl 'https://api.eu.svix.com/api/v1/app' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_SVIX_TOKEN' \
  -d '{
    "name": "Merchant Name",
    "uid": "THE_MERCHANT_ID_FROM_DATABASE"
  }'
```

**Important:** The `uid` must exactly match the `merchant_id` from your database.

## Step 6: Test the Integration

Create a test payment:

```bash
curl -X POST http://localhost:3001/payments \
  -H "Content-Type: application/json" \
  -d '{"amount": 1000, "currency": "USD", "merchant_id": "YOUR_MERCHANT_ID"}'
```

## Step 7: Verify in Svix Dashboard

1. Go to https://dashboard.svix.com
2. Navigate to **Consumer Applications**
3. Find your merchant application
4. Click **Messages** tab
5. You should see `payment.succeeded` events

## Logs

Check if messages are being sent:

```bash
# Should show "Message sent to Svix successfully"
docker compose logs svix-caller --tail 50 | grep "successfully"
```

## Architecture

```
Payment → PostgreSQL → Sequin → Kafka → Restate → svix-caller → Svix Cloud → Merchant
```

The svix-caller service:
- Receives events from Restate (durable execution)
- Fetches enriched payload from data-service
- Sends to Svix Cloud API using merchant_id as application ID
- Svix handles delivery, retries, and signing

Done! Your webhooks are now delivered through Svix Cloud.
