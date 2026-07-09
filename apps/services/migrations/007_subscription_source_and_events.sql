-- ============================================
-- 007: 订阅系统增强
-- 1. subscriptions 表加 source + last_reconciled_at
-- 2. 新建 subscription_events 审计表
-- ============================================

-- 订阅来源：creem（支付）、admin（手动授权）、promo（促销）
ALTER TABLE subscriptions ADD COLUMN source TEXT NOT NULL DEFAULT 'creem';

-- 上次调外部 API 对账的时间（Unix ms），用于 reconcile 节流
ALTER TABLE subscriptions ADD COLUMN last_reconciled_at INTEGER;

-- 复合索引：按来源+状态查询（Cron 对账用）
CREATE INDEX IF NOT EXISTS idx_sub_source_status ON subscriptions(source, status);

-- ============================================
-- 订阅变更事件表（审计日志）
-- 记录所有订阅状态变更，用于追溯和对账
-- ============================================
CREATE TABLE IF NOT EXISTS subscription_events (
  id              TEXT PRIMARY KEY,        -- UUID
  subscription_id TEXT,                    -- FK → subscriptions.id，admin 直接改 tier 时可为 null
  user_id         TEXT NOT NULL,           -- FK → users.id
  trigger         TEXT NOT NULL,           -- 'webhook' | 'cron' | 'admin' | 'resolve' | 'api'
  event_type      TEXT NOT NULL,           -- 'created' | 'status_changed' | 'tier_changed' | 'reconciled' | 'expired' | 'revoked'
  before_state    TEXT,                    -- JSON: { status?, tier?, cancelAtPeriodEnd? }
  after_state     TEXT,                    -- JSON: { status?, tier?, cancelAtPeriodEnd? }
  detail          TEXT,                    -- JSON: 补充信息
  created_at      INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_sub_events_user ON subscription_events(user_id);
CREATE INDEX IF NOT EXISTS idx_sub_events_sub ON subscription_events(subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_events_time ON subscription_events(created_at);
