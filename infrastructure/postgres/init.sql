-- Dodo Webhook Demo - PostgreSQL Initialization

-- TABLES

CREATE TABLE IF NOT EXISTS payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    amount BIGINT NOT NULL,
    currency VARCHAR(3) NOT NULL DEFAULT 'USD',
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    merchant_id UUID NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS domain_events (
    id BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(100) NOT NULL,
    object_id UUID NOT NULL,
    merchant_id UUID NOT NULL,
    payload JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- INDEXES

CREATE INDEX IF NOT EXISTS idx_payments_merchant_id ON payments(merchant_id);
CREATE INDEX IF NOT EXISTS idx_payments_status ON payments(status);
CREATE INDEX IF NOT EXISTS idx_domain_events_merchant_id ON domain_events(merchant_id);
CREATE INDEX IF NOT EXISTS idx_domain_events_created_at ON domain_events(created_at);

-- PUBLICATION FOR CDC (Sequin)

DROP PUBLICATION IF EXISTS domain_events_pub CASCADE;
CREATE PUBLICATION domain_events_pub FOR TABLE domain_events;

-- TRIGGERS

CREATE OR REPLACE FUNCTION notify_payment_status_change()
RETURNS TRIGGER AS $$
BEGIN
    -- Insert event on INSERT or if status changed on UPDATE
    IF (TG_OP = 'INSERT') OR (OLD.status IS DISTINCT FROM NEW.status) THEN
        INSERT INTO domain_events (event_type, object_id, merchant_id, payload)
        VALUES (
            'payment.' || LOWER(NEW.status),
            NEW.id,
            NEW.merchant_id,
            jsonb_build_object(
                'payment_id', NEW.id,
                'amount', NEW.amount,
                'currency', NEW.currency,
                'status', NEW.status,
                'merchant_id', NEW.merchant_id
            )
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS payment_status_change_trigger ON payments;
CREATE TRIGGER payment_status_change_trigger
AFTER INSERT OR UPDATE ON payments
FOR EACH ROW
EXECUTE FUNCTION notify_payment_status_change();

-- PERMISSIONS

GRANT ALL ON payments TO dodo;
GRANT ALL ON domain_events TO dodo;
GRANT ALL ON SEQUENCE domain_events_id_seq TO dodo;

-- INITIAL DATA

INSERT INTO payments (merchant_id, amount, currency, status)
VALUES ('bc1852a0-6e4d-5399-a35a-391ceaf44f80'::UUID, 1000, 'USD', 'pending')
ON CONFLICT DO NOTHING;
