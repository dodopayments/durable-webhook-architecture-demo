#!/bin/bash


set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_TYPE="${1:-baseline}"

# Source helper functions
source "$PROJECT_ROOT/tests/lib/helpers.sh"

# Create results directory
RESULTS_DIR="$PROJECT_ROOT/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="$RESULTS_DIR/test-report-$TIMESTAMP.txt"

# Redirect output to both terminal and file
exec > >(tee -a "$REPORT_FILE") 2>&1

echo ""
echo "Report will be saved to: $REPORT_FILE"
echo ""

# Main test execution
case "$TEST_TYPE" in
    baseline)
        check_services
        bash "$PROJECT_ROOT/tests/baseline-test.sh"
        ;;

    crash)
        check_services
        bash "$PROJECT_ROOT/tests/crash-test.sh"
        ;;

    all)
        check_services
        echo "Running all tests..."
        echo ""
        bash "$PROJECT_ROOT/tests/baseline-test.sh"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        bash "$PROJECT_ROOT/tests/crash-test.sh"
        ;;

    *)
        echo -e "${RED}Unknown test type: $TEST_TYPE${NC}"
        echo ""
        echo "Usage: $0 [test-type]"
        echo ""
        echo "Test Types:"
        echo "  baseline     - Run baseline load tests (default)"
        echo "  crash        - Process crash scenario"
        echo "  all          - Run all tests"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}"
echo "════════════════════════════════════════════════════════════════"
echo "════════════════════════════════════════════════════════════════"
echo -e "${NC}"
echo ""
echo "Summary:"
echo "  OLD ARCHITECTURE: Demonstrates webhook loss in failure scenarios"
echo "  NEW ARCHITECTURE: Shows 99.99%+ reliability with durable execution"
echo ""
echo "Key Findings:"
echo "  1. Process crashes → In-memory webhooks lost (old)"
echo "  2. Kafka + Durable execution → Full crash recovery (new)"
echo ""
echo "Next Steps:"
echo "  1. Review the blog post for architectural details"
echo "  2. Examine code differences between architectures"
echo "  3. Check logs: docker compose logs svix-caller"
echo ""
echo ""
