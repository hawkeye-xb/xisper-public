-- ============================================
-- 007: Subscription system enhancements
-- 1. Add source + last_reconciled_at to the subscriptions table
-- 2. Create the subscription_events audit table
-- ============================================

-- Subscription source: creem (payment), admin (manual grant), promo (promotion)
ALTER TABLE subscriptions ADD COLUMN source TEXT NOT NULL DEFAULT 'creem';

-- Last time the external API was called for reconciliation (Unix ms), used to throttle reconcile
ALTER TABLE subscriptions ADD COLUMN last_reconciled_at INTEGER;

-- Composite index: query by source + status (for Cron reconciliation)
CREATE INDEX IF NOT EXISTS idx_sub_source_status ON subscriptions(source, status);

-- ============================================
-- Subscription change events table (audit log)
-- Records all subscription state changes for tracing and reconciliation
-- ============================================
CREATE TABLE IF NOT EXISTS subscription_events (
  id              TEXT PRIMARY KEY,        -- UUID
  subscription_id TEXT,                    -- FK → subscriptions.id; can be null when admin changes tier directly
  user_id         TEXT NOT NULL,           -- FK → users.id
  trigger         TEXT NOT NULL,           -- 'webhook' | 'cron' | 'admin' | 'resolve' | 'api'
  event_type      TEXT NOT NULL,           -- 'created' | 'status_changed' | 'tier_changed' | 'reconciled' | 'expired' | 'revoked'
  before_state    TEXT,                    -- JSON: { status?, tier?, cancelAtPeriodEnd? }
  after_state     TEXT,                    -- JSON: { status?, tier?, cancelAtPeriodEnd? }
  detail          TEXT,                    -- JSON: additional details
  created_at      INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_sub_events_user ON subscription_events(user_id);
CREATE INDEX IF NOT EXISTS idx_sub_events_sub ON subscription_events(subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_events_time ON subscription_events(created_at);
