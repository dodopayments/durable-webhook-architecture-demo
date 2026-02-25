# Local Setup

## Quick Start

**Requirements**: Docker Desktop running, Svix account (free at https://app.svix.com)

```bash
# 1. Get Svix token: https://app.svix.com → API Access (starts with testsk_)

# 2. Create .env
echo "SVIX_AUTH_TOKEN=testsk_your_token_here" > .env

# 3. Start all services
docker compose up -d && docker compose ps

# 4. Configure Sequin (ONE-TIME via browser)
# See SEQUIN_SETUP.md for browser UI steps:
# - Create replication slot
# - Connect PostgreSQL
# - Create Kafka sink
# - Add transform function

# 5. Register Restate handler
./scripts/register-restate-handler.sh

# 6. Create Svix application
# (Using merchant_id from init.sql database seed)
MERCHANT_ID="bc1852a0-6e4d-5399-a35a-391ceaf44f80"
curl 'https://api.eu.svix.com/api/v1/app' \
  -H 'Authorization: Bearer YOUR_SVIX_TOKEN' \
  -H 'Content-Type: application/json' \
  -d "{\"name\": \"Test Merchant\", \"uid\": \"$MERCHANT_ID\"}"

# 7. Create test payment
curl -X POST http://localhost:3001/payments \
  -H "Content-Type: application/json" \
  -d "{\"amount\": 1000, \"currency\": \"USD\", \"merchant_id\": \"$MERCHANT_ID\"}"

# 8. Verify in Svix Dashboard: https://dashboard.svix.com
docker compose logs svix-caller --tail 20 | grep "successfully"
```

## Notes

- **Merchant ID**: `bc1852a0-6e4d-5399-a35a-391ceaf44f80` is created in database initialization (infrastructure/postgres/init.sql). We use this same ID across the setup.
- **After `docker compose down -v`**: Re-run steps 3-7. Merchant ID stays the same.

## Testing

Run automated tests to verify the architecture:

```bash
./scripts/run-tests.sh crash
```

See [TESTING.md](./TESTING.md) for details.

## Additional Resources

- [SEQUIN_SETUP.md](./SEQUIN_SETUP.md) - Browser-based Sequin configuration
- [TESTING.md](./TESTING.md) - Running crash recovery tests
- [README.md](./README.md) - Architecture overview and blog post link
