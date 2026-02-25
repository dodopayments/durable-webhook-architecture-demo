#!/bin/bash

# Tests webhook delivery under normal conditions
# Expected: 100% delivery for both architectures
#
# Runtime: ~10 seconds

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

NUM_PAYMENTS=50

print_test_header "Baseline (Normal Operation)"


print_section "OLD ARCHITECTURE"

# Reset merchant state for clean test
reset_merchant "http://localhost:4000"

# Get initial stats
OLD_STATS_BEFORE=$(get_merchant_stats "http://localhost:4000")
OLD_BEFORE=$(parse_total_received "$OLD_STATS_BEFORE")

echo "Sending $NUM_PAYMENTS payments..."
START_TIME=$(date +%s)

# Send payments concurrently
for i in $(seq 1 $NUM_PAYMENTS); do
    create_payment "http://localhost:3000" "test-old-$i" >/dev/null &
done
wait

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "✓ Sent $NUM_PAYMENTS payments in ${ELAPSED}s"

# Wait for webhooks
wait_for_webhooks 2

# Get final stats
OLD_STATS_AFTER=$(get_merchant_stats "http://localhost:4000")
OLD_AFTER=$(parse_total_received "$OLD_STATS_AFTER")
OLD_DELIVERED=$((OLD_AFTER - OLD_BEFORE))

print_results "OLD ARCHITECTURE" "$NUM_PAYMENTS" "$OLD_DELIVERED" "0%"


print_section "NEW ARCHITECTURE"

# Reset merchant state for clean test
reset_merchant "http://localhost:4001"

# Get initial stats
NEW_STATS_BEFORE=$(get_merchant_stats "http://localhost:4001")
NEW_BEFORE=$(parse_total_received "$NEW_STATS_BEFORE")

echo "Sending $NUM_PAYMENTS payments..."
START_TIME=$(date +%s)

# Send payments concurrently
for i in $(seq 1 $NUM_PAYMENTS); do
    create_payment "http://localhost:3001" "test-new-$i" >/dev/null &
done
wait

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "✓ Sent $NUM_PAYMENTS payments in ${ELAPSED}s"

# Wait for webhooks (new arch has more latency)
wait_for_webhooks 5

# Get final stats
NEW_STATS_AFTER=$(get_merchant_stats "http://localhost:4001")
NEW_AFTER=$(parse_total_received "$NEW_STATS_AFTER")
NEW_DELIVERED=$((NEW_AFTER - NEW_BEFORE))

print_results "NEW ARCHITECTURE" "$NUM_PAYMENTS" "$NEW_DELIVERED" "0%"


echo -e "${GREEN}"
echo "════════════════════════════════════════════════════════════════"
echo "  BASELINE TEST SUMMARY"
echo "════════════════════════════════════════════════════════════════"
echo -e "${NC}"
echo ""
echo "OLD ARCHITECTURE:"
echo "  Created: $NUM_PAYMENTS | Delivered: $OLD_DELIVERED | Loss: $((NUM_PAYMENTS - OLD_DELIVERED))"
echo ""
echo "NEW ARCHITECTURE:"
echo "  Created: $NUM_PAYMENTS | Delivered: $NEW_DELIVERED | Loss: $((NUM_PAYMENTS - NEW_DELIVERED))"
echo ""

if [ "$OLD_DELIVERED" -ge $((NUM_PAYMENTS - 2)) ] && [ "$NEW_DELIVERED" -ge $((NUM_PAYMENTS - 2)) ]; then
    echo -e "${GREEN}✓ PASSED: Both architectures delivering webhooks reliably${NC}"
    exit 0
else
    echo -e "${RED}✗ FAILED: Unexpected webhook loss in baseline test${NC}"
    exit 1
fi
