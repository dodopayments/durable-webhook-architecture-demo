#!/bin/bash

# ==============================================================================
# HELPER FUNCTIONS: Shared utilities for webhook tests
# ==============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored test header
print_test_header() {
    local test_name=$1
    echo -e "${BLUE}"
    echo "════════════════════════════════════════════════════════════════"
    echo "  TEST: $test_name"
    echo "════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

# Print section header
print_section() {
    local section_name=$1
    echo ""
    echo -e "${YELLOW}[$section_name]${NC}"
}

# Create a payment via API
# Usage: create_payment <api-url> <merchant-id>
create_payment() {
    local api_url=$1
    local merchant_id=${2:-"test-merchant"}
    local amount=$((RANDOM % 10000 + 1000))

    curl -s -X POST "$api_url/payments" \
        -H "Content-Type: application/json" \
        -d "{\"merchant_id\":\"$merchant_id\",\"amount\":$amount,\"currency\":\"USD\"}" \
        -o /dev/null -w "%{http_code}"
}

# Get merchant webhook stats
# Usage: get_merchant_stats <merchant-url>
get_merchant_stats() {
    local merchant_url=$1
    curl -s "$merchant_url/stats"
}

# Reset merchant webhook state
# Usage: reset_merchant <merchant-url>
reset_merchant() {
    local merchant_url=$1
    curl -s -X POST "$merchant_url/reset" -o /dev/null
    echo "✓ Reset merchant state: $merchant_url"
}

# Parse total received from stats JSON
# Usage: parse_total_received <stats-json>
parse_total_received() {
    local stats=$1
    echo "$stats" | grep -o '"total_received":[0-9]*' | grep -o '[0-9]*'
}

# Parse unique payments from stats JSON
# Usage: parse_unique_payments <stats-json>
parse_unique_payments() {
    local stats=$1
    echo "$stats" | grep -o '"unique_payments":[0-9]*' | grep -o '[0-9]*'
}

# Kill a Docker service and restart after delay
# Usage: kill_and_restart_service <service-name> <delay-seconds>
kill_and_restart_service() {
    local service=$1
    local delay=$2

    echo "[CHAOS] Killing service: $service"
    docker kill "$service" 2>/dev/null || true

    echo "[CHAOS] Service killed. Waiting ${delay}s before restart..."
    sleep "$delay"

    echo "[CHAOS] Restarting service: $service"
    docker start "$service" >/dev/null
    sleep 1  # Give it a moment to fully start
    echo "[CHAOS] Service restarted."
}

# Print test results in a formatted table
# Usage: print_results <arch-name> <payments-created> <webhooks-received> <expected-loss>
print_results() {
    local arch=$1
    local created=$2
    local received=$3
    local expected_loss=${4:-"0%"}

    local loss=0
    local delivery_rate="100%"

    if [ "$created" -gt 0 ]; then
        loss=$((created - received))
        if [ "$loss" -lt 0 ]; then
            loss=0
            received=$created  # Cap at created (from previous tests)
        fi
        local rate=$((received * 100 / created))
        delivery_rate="${rate}%"
    fi

    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║     $arch RESULTS"
    echo "╠════════════════════════════════════════╣"
    echo "║ Payments Created:  $created"
    echo "║ Webhooks Received: $received"
    echo "║ Webhooks Lost:     $loss"
    echo "║ Delivery Rate:     $delivery_rate"
    echo "║ Expected Loss:     $expected_loss"
    echo "╚════════════════════════════════════════╝"
    echo ""
}

# Wait for async processing to complete
# Usage: wait_for_webhooks <seconds>
wait_for_webhooks() {
    local seconds=${1:-3}
    echo -n "Waiting ${seconds}s for webhook processing"
    for i in $(seq 1 $seconds); do
        echo -n "."
        sleep 1
    done
    echo " done"
}

# Check if Docker services are running
check_services() {
    echo "Checking if Docker services are running..."
    if ! docker ps | grep -q "old-api"; then
        echo -e "${RED}ERROR: Services not running. Start with:${NC}"
        echo "  docker compose up -d"
        exit 1
    fi
    echo "✓ Services are running"
    echo ""
}
