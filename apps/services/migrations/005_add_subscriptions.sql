-- ============================================
-- Subscription records table
-- Stores subscription information from the Creem payment platform
-- ============================================
CREATE TABLE IF NOT EXISTS subscriptions (
  id TEXT PRIMARY KEY,                    -- Internal ID (UUID)
  user_id TEXT NOT NULL,                  -- References users.id
  creem_subscription_id TEXT,             -- Creem subscription ID
  creem_customer_id TEXT,                 -- Creem customer ID
  creem_checkout_id TEXT,                 -- Creem checkout ID
  plan TEXT NOT NULL DEFAULT 'pro',       -- pro / enterprise
  status TEXT NOT NULL DEFAULT 'active',  -- active / canceled / expired / paused / past_due
  current_period_start INTEGER,           -- Unix timestamp
  current_period_end INTEGER,             -- Unix timestamp
  cancel_at_period_end INTEGER DEFAULT 0, -- 1 = cancel at period end
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  metadata TEXT,                          -- JSON extension field
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_creem_sub_id ON subscriptions(creem_subscription_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON subscriptions(status);
