-- Migration: Add ASR quota storage in D1 (replaces KV for free tier users)
-- Date: 2026-03-21
-- Purpose: Store ASR quota usage in D1 to avoid KV daily write limit

-- ============================================
-- User ASR Quota Table (replaces KV storage)
-- ============================================
CREATE TABLE IF NOT EXISTS user_asr_quota (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  week_key TEXT NOT NULL,           -- Week identifier (e.g., "2026-W12")
  duration_used INTEGER NOT NULL DEFAULT 0,   -- Duration used in seconds
  characters_used INTEGER NOT NULL DEFAULT 0, -- Characters used
  tier TEXT NOT NULL DEFAULT 'free',         -- User tier at time of record
  updated_at INTEGER NOT NULL,               -- Last update timestamp
  created_at INTEGER NOT NULL,
  UNIQUE(user_id, week_key)          -- Composite unique constraint: one record per user per week
);

CREATE INDEX IF NOT EXISTS idx_user_asr_quota_user_week ON user_asr_quota(user_id, week_key);
