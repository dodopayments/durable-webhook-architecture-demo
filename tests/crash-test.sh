#!/bin/bash

# Reproduces the blog scenario: "Timeline of a Lost Webhook"
# Service crashes during webhook processing
#
# Expected Results:
#   OLD: Webhooks during crash window are LOST
#   NEW: ZERO webhook loss (Kafka buffering + durable recovery)
#
# Runtime: ~20 seconds

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

NUM_PAYMENTS=100
CRASH_DELAY=3  # Seconds to keep service down

# Use a pre-registered merchant ID with Svix
# Change this to your actual registered merchant ID
MERCHANT_ID="bc1852a0-6e4d-5399-a35a-391ceaf44f80"

print_test_header "Process Crash During Webhook Delivery"
echo "Blog Scenario: 'Timeline of a Lost Webhook'"
echo "Service crashes during in-flight webhook request"
echo "Using pre-registered Merchant ID: $MERCHANT_ID"
echo ""


print_section "OLD ARCHITECTURE CRASH TEST"
echo "Expected: Webhooks during crash window are LOST"
echo ""

# Reset merchant state for clean test
reset_merchant "http://localhost:4000"

# Get initial stats
OLD_STATS_BEFORE=$(get_merchant_stats "http://localhost:4000")
OLD_BEFORE=$(parse_total_received "$OLD_STATS_BEFORE")

echo "Sending $NUM_PAYMENTS payments with mid-test crash..."

# Start sending payments in background
(
    for i in $(seq 1 $NUM_PAYMENTS); do
        create_payment "http://localhost:3000" "$MERCHANT_ID" >/dev/null 2>&1 || true
        sleep 0.05  # Small delay between requests
    done
) &
SEND_PID=$!

# Kill service at ~50% completion
sleep 2.5
echo ""
echo "[CHAOS] Killing old-api container..."
kill_and_restart_service "old-api" "$CRASH_DELAY"
echo ""

# Wait for payment sending to complete
wait $SEND_PID 2>/dev/null || true

# Wait for webhooks
wait_for_webhooks 5

# Get final stats
OLD_STATS_AFTER=$(get_merchant_stats "http://localhost:4000")
OLD_AFTER=$(parse_total_received "$OLD_STATS_AFTER")
OLD_DELIVERED=$((OLD_AFTER - OLD_BEFORE))
OLD_LOSS=$((NUM_PAYMENTS - OLD_DELIVERED))

print_results "OLD ARCHITECTURE" "$NUM_PAYMENTS" "$OLD_DELIVERED" "~1-5%"

if [ "$OLD_LOSS" -gt 0 ]; then
    echo -e "${YELLOW}✓ Expected behavior: $OLD_LOSS webhooks lost during crash${NC}"
else
    echo -e "${YELLOW}⚠ Warning: No loss detected (crash timing may need adjustment)${NC}"
fi


print_section "NEW ARCHITECTURE CRASH TEST"
echo "Expected: ZERO webhook loss (durable recovery)"
echo ""

# Reset merchant state for clean test
reset_merchant "http://localhost:4001"

# Get initial stats
NEW_STATS_BEFORE=$(get_merchant_stats "http://localhost:4001")
NEW_BEFORE=$(parse_total_received "$NEW_STATS_BEFORE")

echo "Sending $NUM_PAYMENTS payments with mid-test crash..."

# Start sending payments in background
(
    for i in $(seq 1 $NUM_PAYMENTS); do
        create_payment "http://localhost:3001" "$MERCHANT_ID" >/dev/null 2>&1 || true
        sleep 0.05  # Small delay between requests
    done
) &
SEND_PID=$!

# Kill svix-caller at ~50% completion
sleep 2.5
echo ""
echo "[CHAOS] Killing svix-caller container..."
kill_and_restart_service "svix-caller" "$CRASH_DELAY"
echo ""

# Wait for payment sending to complete
wait $SEND_PID 2>/dev/null || true

# Wait for webhooks (longer for new arch + recovery)
echo "Waiting for Kafka buffering and recovery..."
wait_for_webhooks 45

# Get final stats
NEW_STATS_AFTER=$(get_merchant_stats "http://localhost:4001")
NEW_AFTER=$(parse_total_received "$NEW_STATS_AFTER")
NEW_DELIVERED=$((NEW_AFTER - NEW_BEFORE))
NEW_LOSS=$((NUM_PAYMENTS - NEW_DELIVERED))

print_results "NEW ARCHITECTURE" "$NUM_PAYMENTS" "$NEW_DELIVERED" "0%"

if [ "$NEW_LOSS" -eq 0 ]; then
    echo -e "${GREEN}✓ Perfect recovery: ALL webhooks delivered after crash${NC}"
else
    echo -e "${YELLOW}⚠ Some webhooks still processing (may need more wait time)${NC}"
fi


echo ""
echo -e "${GREEN}"
echo "════════════════════════════════════════════════════════════════"
echo "  CRASH TEST SUMMARY"
echo "════════════════════════════════════════════════════════════════"
echo -e "${NC}"
echo ""
echo "OLD ARCHITECTURE (In-Memory Webhooks):"
echo "  Created: $NUM_PAYMENTS | Delivered: $OLD_DELIVERED | Lost: $OLD_LOSS"
echo "  Loss Rate: $(awk -v loss=$OLD_LOSS -v total=$NUM_PAYMENTS 'BEGIN {printf "%.2f", (loss/total)*100}')%"
echo ""
echo "NEW ARCHITECTURE (Kafka + Durable Execution):"
echo "  Created: $NUM_PAYMENTS | Delivered: $NEW_DELIVERED | Lost: $NEW_LOSS"
echo "  Loss Rate: $(awk -v loss=$NEW_LOSS -v total=$NUM_PAYMENTS 'BEGIN {printf "%.2f", (loss/total)*100}')%"
echo ""
echo "KEY FINDING:"
if [ "$OLD_LOSS" -gt "$NEW_LOSS" ]; then
    echo -e "${GREEN}✓ New architecture demonstrates superior crash recovery${NC}"
    echo -e "  Old lost $OLD_LOSS webhooks, New lost $NEW_LOSS webhooks"
    exit 0
else
    echo -e "${YELLOW}⚠ Results inconclusive (may need timing adjustment)${NC}"
    exit 1
fi
