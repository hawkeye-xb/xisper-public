-- AI Services Template - Database Schema
-- 用途：定义所有数据库表结构
-- 创建时间：2026-01-31

-- ============================================
-- 用户扩展表
-- 用于存储 Logto 以外的业务数据
-- ============================================
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,           -- Logto sub (Subject ID)
  email TEXT UNIQUE,             -- 邮箱（唯一约束，防止重复注册）
  tier TEXT DEFAULT 'free',      -- 用户等级: free, pro, vip
  role TEXT DEFAULT 'user',      -- 角色: user, admin
  quota_reset_at INTEGER,        -- 配额重置时间 (Unix timestamp)
  created_at INTEGER NOT NULL,   -- 创建时间
  updated_at INTEGER NOT NULL,   -- 更新时间
  metadata TEXT                  -- JSON 扩展字段，用于存储额外信息
);

-- 创建索引以优化查询性能
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_unique
  ON users(email)
  WHERE email IS NOT NULL AND email != '';
CREATE INDEX IF NOT EXISTS idx_users_tier ON users(tier);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

-- ============================================
-- 任务记录表
-- 记录所有 AI 处理任务
-- ============================================
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  status TEXT NOT NULL,          -- 状态: pending, processing, completed, failed
  r2_key TEXT,                   -- R2 存储的文件路径
  tokens_used INTEGER DEFAULT 0, -- AI 消耗的 tokens 数量
  error_message TEXT,            -- 错误信息（如果失败）
  created_at INTEGER NOT NULL,   -- 创建时间
  completed_at INTEGER,          -- 完成时间
  FOREIGN KEY (user_id) REFERENCES users(id)
);

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_tasks_user_id ON tasks(user_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at);

-- ============================================
-- 配额使用历史表
-- 用于账单统计和用量分析
-- ============================================
CREATE TABLE IF NOT EXISTS quota_history (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  task_id TEXT,                  -- 关联的任务 ID（可选）
  tokens_used INTEGER NOT NULL,  -- 本次消耗的 tokens
  timestamp INTEGER NOT NULL,    -- 记录时间
  FOREIGN KEY (user_id) REFERENCES users(id),
  FOREIGN KEY (task_id) REFERENCES tasks(id)
);

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_quota_history_user_id ON quota_history(user_id);
CREATE INDEX IF NOT EXISTS idx_quota_history_timestamp ON quota_history(timestamp);
CREATE INDEX IF NOT EXISTS idx_quota_history_task_id ON quota_history(task_id);

-- ============================================
-- 订阅记录表
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

-- 每个用户最多一个 active/past_due 订阅
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_one_active_per_user
  ON subscriptions(user_id)
  WHERE status IN ('active', 'past_due');

-- Creem 订阅 ID 唯一（允许多个 NULL，覆盖非 Creem 来源的订阅）
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_creem_sub_id_unique
  ON subscriptions(creem_subscription_id)
  WHERE creem_subscription_id IS NOT NULL;

-- Polar 订阅 ID 唯一（允许多个 NULL，覆盖非 Polar 来源的订阅）
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_polar_sub_id_unique
  ON subscriptions(polar_subscription_id)
  WHERE polar_subscription_id IS NOT NULL;

-- Paddle 订阅 ID 唯一（允许多个 NULL，覆盖非 Paddle 来源的订阅）
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_paddle_sub_id_unique
  ON subscriptions(paddle_subscription_id)
  WHERE paddle_subscription_id IS NOT NULL;

-- ============================================
-- 订阅变更事件表（审计日志）
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
-- 初始化完成
-- ============================================
