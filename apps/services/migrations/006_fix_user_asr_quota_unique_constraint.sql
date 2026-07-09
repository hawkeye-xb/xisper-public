-- Migration: Fix user_asr_quota UNIQUE constraint
-- Date: 2026-04-02
-- Purpose: Allow multiple weeks per user with composite UNIQUE(user_id, week_key)

-- ============================================
-- Drop and Recreate user_asr_quota Table
-- ============================================

-- Step 1: Backup existing data
CREATE TABLE IF NOT EXISTS user_asr_quota_backup AS SELECT * FROM user_asr_quota;

-- Step 2: Drop the old table
DROP TABLE IF EXISTS user_asr_quota;

-- Step 3: Recreate with correct constraints
CREATE TABLE user_asr_quota (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  week_key TEXT NOT NULL,           -- Week identifier (e.g., "2026-W12")
  duration_used INTEGER NOT NULL DEFAULT 0,   -- Duration used in seconds
  characters_used INTEGER NOT NULL DEFAULT 0, -- Characters used
  tier TEXT NOT NULL DEFAULT 'free',         -- User tier at time of record
  updated_at INTEGER NOT NULL,               -- Last update timestamp
  created_at INTEGER NOT NULL,
  UNIQUE(user_id, week_key)          -- ✅ Composite unique constraint
);

-- Step 4: Restore data from backup
INSERT INTO user_asr_quota SELECT * FROM user_asr_quota_backup;

-- Step 5: Recreate index
CREATE INDEX IF NOT EXISTS idx_user_asr_quota_user_week ON user_asr_quota(user_id, week_key);

-- Step 6: Clean up backup table
DROP TABLE user_asr_quota_backup;

-- ============================================
-- Migration Complete
-- ============================================
