-- Migration: Add rate_limit_history table
-- Date: 2026-02-02
-- Purpose: Track rate limit usage for LLM and ASR services

-- ============================================
-- Rate Limit History Table
-- ============================================
CREATE TABLE IF NOT EXISTS rate_limit_history (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  type TEXT NOT NULL,           -- 'llm' or 'asr'
  metric TEXT NOT NULL,          -- 'calls', 'duration', 'characters'
  amount INTEGER NOT NULL,       -- consumed amount
  tier TEXT NOT NULL,            -- user tier at the time of consumption
  metadata TEXT,                 -- JSON: {sessionId, model, text, etc}
  timestamp INTEGER NOT NULL,   -- Unix timestamp
  FOREIGN KEY (user_id) REFERENCES users(id)
);

-- Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_rate_limit_user_type ON rate_limit_history(user_id, type, timestamp);
CREATE INDEX IF NOT EXISTS idx_rate_limit_timestamp ON rate_limit_history(timestamp);
CREATE INDEX IF NOT EXISTS idx_rate_limit_tier ON rate_limit_history(tier);

-- ============================================
-- Migration Complete
-- ============================================
