-- AI Services Template - Database Schema
-- Purpose: defines all database table structures
-- Created: 2026-01-31

-- ============================================
-- User extension table
-- Stores business data beyond Logto
-- ============================================
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,           -- Logto sub (Subject ID)
  email TEXT UNIQUE,             -- Email (unique constraint to prevent duplicate registration)
  tier TEXT DEFAULT 'free',      -- User tier: free, pro, vip
  role TEXT DEFAULT 'user',      -- Role: user, admin
  quota_reset_at INTEGER,        -- Quota reset time (Unix timestamp)
  created_at INTEGER NOT NULL,   -- Creation time
  updated_at INTEGER NOT NULL,   -- Update time
  metadata TEXT                  -- JSON extension field for additional information
);

-- Create indexes to optimize query performance
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_unique
  ON users(email)
  WHERE email IS NOT NULL AND email != '';
CREATE INDEX IF NOT EXISTS idx_users_tier ON users(tier);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

-- ============================================
-- Task records table
-- Records all AI processing tasks
-- ============================================
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  status TEXT NOT NULL,          -- Status: pending, processing, completed, failed
  r2_key TEXT,                   -- File path stored in R2
  tokens_used INTEGER DEFAULT 0, -- Number of tokens consumed by AI
  error_message TEXT,            -- Error message (if failed)
  created_at INTEGER NOT NULL,   -- Creation time
  completed_at INTEGER,          -- Completion time
  FOREIGN KEY (user_id) REFERENCES users(id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_tasks_user_id ON tasks(user_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at);

-- ============================================
-- Quota usage history table
-- Used for billing statistics and usage analysis
-- ============================================
CREATE TABLE IF NOT EXISTS quota_history (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  task_id TEXT,                  -- Associated task ID (optional)
  tokens_used INTEGER NOT NULL,  -- Tokens consumed this time
  timestamp INTEGER NOT NULL,    -- Record time
  FOREIGN KEY (user_id) REFERENCES users(id),
  FOREIGN KEY (task_id) REFERENCES tasks(id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_quota_history_user_id ON quota_history(user_id);
CREATE INDEX IF NOT EXISTS idx_quota_history_timestamp ON quota_history(timestamp);
CREATE INDEX IF NOT EXISTS idx_quota_history_task_id ON quota_history(task_id);

-- ============================================
-- Subscription records table
-- ============================================
CREATE TABLE IF NOT EXISTS subscriptions (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL,
  source                TEXT NOT NULL DEFAULT 'creem',  -- 'creem' | 'polar' | 'admin' | 'promo'
  plan                  TEXT NOT NULL DEFAULT 'pro_monthly',
  status                TEXT NOT NULL DEFAULT 'active', -- active | past_due | canceled | paused | expired
  cancel_at_period_end  INTEGER NOT NULL DEFAULT 0,
  current_period_start  INTEGER,
  current_period_end    INTEGER,
  last_reconciled_at    INTEGER,
  creem_subscription_id TEXT,
  creem_customer_id     TEXT,
  creem_checkout_id     TEXT,
  polar_subscription_id TEXT,
  polar_customer_id    TEXT,
  polar_checkout_id    TEXT,
  paddle_subscription_id TEXT,
  paddle_customer_id   TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  metadata              TEXT,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_sub_user_id ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_sub_status ON subscriptions(status);
CREATE INDEX IF NOT EXISTS idx_sub_creem_sub_id ON subscriptions(creem_subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_polar_sub_id ON subscriptions(polar_subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_paddle_sub_id ON subscriptions(paddle_subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_source_status ON subscriptions(source, status);

-- At most one active/past_due subscription per user
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_one_active_per_user
  ON subscriptions(user_id)
  WHERE status IN ('active', 'past_due');

-- Creem subscription ID is unique (multiple NULLs allowed, covering non-Creem subscriptions)
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_creem_sub_id_unique
  ON subscriptions(creem_subscription_id)
  WHERE creem_subscription_id IS NOT NULL;

-- Polar subscription ID is unique (multiple NULLs allowed, covering non-Polar subscriptions)
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_polar_sub_id_unique
  ON subscriptions(polar_subscription_id)
  WHERE polar_subscription_id IS NOT NULL;

-- Paddle subscription ID is unique (multiple NULLs allowed, covering non-Paddle subscriptions)
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_paddle_sub_id_unique
  ON subscriptions(paddle_subscription_id)
  WHERE paddle_subscription_id IS NOT NULL;

-- ============================================
-- Subscription change events table (audit log)
-- ============================================
CREATE TABLE IF NOT EXISTS subscription_events (
  id              TEXT PRIMARY KEY,
  subscription_id TEXT,
  user_id         TEXT NOT NULL,
  trigger         TEXT NOT NULL,
  event_type      TEXT NOT NULL,
  before_state    TEXT,
  after_state     TEXT,
  detail          TEXT,
  created_at      INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_sub_events_user ON subscription_events(user_id);
CREATE INDEX IF NOT EXISTS idx_sub_events_sub ON subscription_events(subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_events_time ON subscription_events(created_at);

-- ============================================
-- Initialization complete
-- ============================================
