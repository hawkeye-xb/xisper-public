-- ============================================
-- 订阅记录表
-- 存储 Creem 支付平台的订阅信息
-- ============================================
CREATE TABLE IF NOT EXISTS subscriptions (
  id TEXT PRIMARY KEY,                    -- 内部 ID (UUID)
  user_id TEXT NOT NULL,                  -- 关联 users.id
  creem_subscription_id TEXT,             -- Creem 订阅 ID
  creem_customer_id TEXT,                 -- Creem 客户 ID
  creem_checkout_id TEXT,                 -- Creem checkout ID
  plan TEXT NOT NULL DEFAULT 'pro',       -- pro / enterprise
  status TEXT NOT NULL DEFAULT 'active',  -- active / canceled / expired / paused / past_due
  current_period_start INTEGER,           -- Unix timestamp
  current_period_end INTEGER,             -- Unix timestamp
  cancel_at_period_end INTEGER DEFAULT 0, -- 1 = 到期后取消
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  metadata TEXT,                          -- JSON 扩展字段
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_creem_sub_id ON subscriptions(creem_subscription_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON subscriptions(status);
