# Testing: Reproducing the Webhook Loss Problem

## The Problem

Dodo Payments was losing webhooks when services crashed mid-delivery. When the payment API crashed while sending webhooks to Svix:
- **Old Architecture**: Webhooks in-memory → lost forever (1-5% loss rate)
- **New Architecture**: Webhooks persisted in Kafka → automatically recovered after restart (0% loss)

**Blog Post**: [Building Reliable Webhooks at Scale](https://dodo.dev/blog/reliable-webhooks)

---

## Reproduce It

Run the crash test to see the difference:

```bash
./scripts/run-tests.sh crash
```

This will:
1. **Old Architecture**: Send 100 payments, kill API mid-stream → 1-5 webhooks lost
2. **New Architecture**: Send 100 payments, kill service mid-stream → 0 webhooks lost (Kafka recovers all)

## What The Script Does

| Test | What Happens | Expected Result |
|------|--------------|-----------------|
| `baseline` | Send 50 payments under normal conditions | 100% delivery both architectures |
| `crash` | Send 100 payments, crash service at 50% | Old: loses ~2-5, New: loses 0 |
| `all` | Run baseline + crash tests | See full comparison |

## Key Insight

```
OLD ARCHITECTURE:
  Payment API → Direct HTTP to Svix (in-memory queue)
  If crash → Webhooks lost

NEW ARCHITECTURE:
  Payment API → PostgreSQL trigger → Sequin → Kafka → Restate → Svix
  If crash → Kafka buffers, Restate recovers from journal
```

## Run Tests

```bash
# Baseline (normal operation, ~10s)
./scripts/run-tests.sh baseline

# Crash scenario, ~20s)
./scripts/run-tests.sh crash

# Both tests (~30s total)
./scripts/run-tests.sh all
```

Results saved to `results/test-report-*.txt`

---

## Why Two Tests?

### Baseline Test
**Proves both architectures work perfectly under normal conditions (no failures)**
- Old Architecture: 50 payments → 100% delivered
- New Architecture: 50 payments → 100% delivered

Shows **both are functional code**, not a quality issue

### Crash Test
**Reveals the architectural difference when service crashes mid-delivery**
- Old Architecture: 100 payments + crash → 1-5% lost
- New Architecture: 100 payments + crash → 0% lost

Shows **Kafka + durable execution recovers from crashes**, old architecture doesn't

**Together**: Baseline proves code works, crash test proves architecture matters