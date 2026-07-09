-- Paddle Payment Fields Migration
--
-- Adds Paddle-specific fields to subscriptions table for triple payment provider support.

-- 1. Add Paddle columns to subscriptions table
ALTER TABLE subscriptions ADD COLUMN paddle_subscription_id TEXT;
ALTER TABLE subscriptions ADD COLUMN paddle_customer_id TEXT;

-- 2. Create indexes for Paddle subscription lookups
CREATE INDEX IF NOT EXISTS idx_sub_paddle_sub_id ON subscriptions(paddle_subscription_id);

-- 3. Create unique index for Paddle subscription IDs
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_paddle_sub_id_unique
  ON subscriptions(paddle_subscription_id)
  WHERE paddle_subscription_id IS NOT NULL;