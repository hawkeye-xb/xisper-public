-- Migration: Initial database schema
-- Date: 2026-02-02
-- Purpose: Create users table and other base tables

-- ============================================
-- Users Table
-- ============================================
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,           -- Logto sub (Subject ID)
  email TEXT,
  tier TEXT DEFAULT 'free',      -- User tier: free, pro, vip
  quota_reset_at INTEGER,        -- Quota reset timestamp (Unix timestamp)
  created_at INTEGER NOT NULL,   -- Creation timestamp
  updated_at INTEGER NOT NULL,   -- Last update timestamp
  metadata TEXT                  -- JSON: extra fields for extensibility
);

-- Create indexes for query optimization
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_tier ON users(tier);

-- ============================================
-- Tasks Table
-- ============================================
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  status TEXT NOT NULL,          -- Status: pending, processing, completed, failed
  r2_key TEXT,                   -- R2 file path
  tokens_used INTEGER DEFAULT 0, -- AI tokens consumed
  error_message TEXT,            -- Error message (if failed)
  created_at INTEGER NOT NULL,   -- Creation timestamp
  completed_at INTEGER,          -- Completion timestamp
  FOREIGN KEY (user_id) REFERENCES users(id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_tasks_user_id ON tasks(user_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at);

-- ============================================
-- Quota History Table
-- ============================================
CREATE TABLE IF NOT EXISTS quota_history (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  task_id TEXT,                  -- Related task ID (optional)
  tokens_used INTEGER NOT NULL,  -- Tokens consumed in this record
  timestamp INTEGER NOT NULL,    -- Record timestamp
  FOREIGN KEY (user_id) REFERENCES users(id),
  FOREIGN KEY (task_id) REFERENCES tasks(id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_quota_history_user_id ON quota_history(user_id);
CREATE INDEX IF NOT EXISTS idx_quota_history_timestamp ON quota_history(timestamp);
CREATE INDEX IF NOT EXISTS idx_quota_history_task_id ON quota_history(task_id);

-- ============================================
-- Migration Complete
-- ============================================
