#!/bin/bash


set -e

RESTATE_ADMIN="http://localhost:9070"
SVIX_CALLER_URL="http://svix-caller:9080"
KAFKA_CLUSTER="local"
KAFKA_TOPIC="webhook-events"
HANDLER_SERVICE="SvixCaller"
HANDLER_METHOD="process"

echo "Restate Handler Registration"

# Wait for Restate Admin API to be ready
echo ""
max_retries=30
retry=0

while [ $retry -lt $max_retries ]; do
    if curl --http1.1 -s "$RESTATE_ADMIN/services" >/dev/null 2>&1; then
                break
    fi
    retry=$((retry + 1))
    echo "  (attempt $retry/$max_retries)"
    sleep 2
done

if [ $retry -eq $max_retries ]; then
        exit 1
fi

# Check if svix-caller container is running
echo ""

if docker ps --filter "name=svix-caller" --filter "status=running" --format "{{.Names}}" | grep -q svix-caller; then
    echo "svix-caller container is running"
else
    echo "svix-caller container is not running."
    echo "Please start it with: docker compose up -d svix-caller"
    exit 1
fi

# Register the svix-caller service with Restate
echo ""

REGISTER_RESPONSE=$(curl --http1.1 -s -X POST "$RESTATE_ADMIN/deployments" \
    -H "Content-Type: application/json" \
    -d "{\"uri\": \"$SVIX_CALLER_URL\"}")

echo "Response: $REGISTER_RESPONSE"

# Check if registration was successful
if echo "$REGISTER_RESPONSE" | grep -q '"services"' || echo "$REGISTER_RESPONSE" | grep -q 'webhook'; then
    echo "Service registration succeeded"
else
    echo "Service registration may have failed. Response: $REGISTER_RESPONSE"
fi

# Create Kafka subscription
echo ""

SUBSCRIPTION_RESPONSE=$(curl --http1.1 -s -X POST "$RESTATE_ADMIN/subscriptions" \
    -H "Content-Type: application/json" \
    -d "{
        \"source\": \"kafka://$KAFKA_CLUSTER/$KAFKA_TOPIC\",
        \"sink\": \"service://$HANDLER_SERVICE/$HANDLER_METHOD\",
        \"options\": {
            \"auto.offset.reset\": \"earliest\"
        }
    }")

echo "Response: $SUBSCRIPTION_RESPONSE"

# Check if subscription was created
if echo "$SUBSCRIPTION_RESPONSE" | grep -q 'kafka://'; then
    echo "Kafka subscription created"
elif echo "$SUBSCRIPTION_RESPONSE" | grep -q 'already exists\|Subscription'; then
    echo "Kafka subscription already exists"
else
    echo "Kafka subscription may have failed. Response: $SUBSCRIPTION_RESPONSE"
fi

# Verify handler is registered
echo ""

SERVICES=$(curl --http1.1 -s "$RESTATE_ADMIN/services")
if echo "$SERVICES" | grep -q 'SvixCaller'; then
    echo "Handler verification succeeded: SvixCaller is registered"
else
    echo "Handler verification failed: SvixCaller not found in Restate services"
fi

# List active subscriptions
echo ""
curl --http1.1 -s "$RESTATE_ADMIN/subscriptions" | jq '.subscriptions[] | {source: .source, sink: .sink, status: .status}' 2>/dev/null || echo "  (could not fetch subscriptions)"

echo ""
echo ""
echo "Next steps:"
echo "  1. Create a payment: curl -X POST http://localhost:3001/payments"
echo "  2. Check merchant received webhook: curl http://localhost:4001/stats"
echo "  3. View Restate metrics: http://localhost:8080/ui"
