-- Polar Payment Fields Migration
--
-- Adds Polar-specific fields to subscriptions table for dual payment provider support.
--
-- Creem fields already exist: creem_subscription_id, creem_customer_id, creem_checkout_id
-- Polar fields to add: polar_subscription_id, polar_customer_id, polar_checkout_id

-- 1. Add Polar columns to subscriptions table
ALTER TABLE subscriptions ADD COLUMN polar_subscription_id TEXT;
ALTER TABLE subscriptions ADD COLUMN polar_customer_id TEXT;
ALTER TABLE subscriptions ADD COLUMN polar_checkout_id TEXT;

-- 2. Create indexes for Polar subscription lookups
CREATE INDEX IF NOT EXISTS idx_sub_polar_sub_id ON subscriptions(polar_subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_polar_checkout_id ON subscriptions(polar_checkout_id);

-- 3. Create unique index for Polar subscription IDs
-- (allows multiple NULLs, but ensures unique Polar subscription IDs)
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_polar_sub_id_unique
  ON subscriptions(polar_subscription_id)
  WHERE polar_subscription_id IS NOT NULL;
