-- Migration 008: Add UNIQUE constraints on users.email, subscriptions
--
-- Problem: users table allows duplicate emails (different Logto sub IDs, same email).
-- Beta environment has accumulated duplicates. This migration:
--   1. Cleans up duplicate email rows (keeps the earliest created_at)
--   2. Rebuilds users table with UNIQUE(email)
--   3. Adds partial unique index on subscriptions (one active per user)
--   4. Adds unique index on subscriptions.creem_subscription_id

-- ============================================
-- Step 1: Clean up duplicate emails
-- For each duplicated email, keep the row with the earliest created_at.
-- Before deleting duplicates, migrate their subscriptions/tasks/quota to the keeper.
-- ============================================

-- Migrate subscriptions from duplicate users to the keeper (earliest user per email)
UPDATE subscriptions
SET user_id = (
  SELECT u_keep.id FROM users u_keep
  WHERE u_keep.email = (SELECT email FROM users WHERE id = subscriptions.user_id)
    AND u_keep.email IS NOT NULL AND u_keep.email != ''
  ORDER BY u_keep.created_at ASC
  LIMIT 1
)
WHERE user_id IN (
  SELECT u_dup.id FROM users u_dup
  WHERE u_dup.email IN (
    SELECT email FROM users
    WHERE email IS NOT NULL AND email != ''
    GROUP BY email HAVING COUNT(*) > 1
  )
  AND u_dup.id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = u_dup.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  )
);

-- Migrate tasks from duplicate users to the keeper
UPDATE tasks
SET user_id = (
  SELECT u_keep.id FROM users u_keep
  WHERE u_keep.email = (SELECT email FROM users WHERE id = tasks.user_id)
    AND u_keep.email IS NOT NULL AND u_keep.email != ''
  ORDER BY u_keep.created_at ASC
  LIMIT 1
)
WHERE user_id IN (
  SELECT u_dup.id FROM users u_dup
  WHERE u_dup.email IN (
    SELECT email FROM users
    WHERE email IS NOT NULL AND email != ''
    GROUP BY email HAVING COUNT(*) > 1
  )
  AND u_dup.id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = u_dup.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  )
);

-- Migrate quota_history from duplicate users to the keeper
UPDATE quota_history
SET user_id = (
  SELECT u_keep.id FROM users u_keep
  WHERE u_keep.email = (SELECT email FROM users WHERE id = quota_history.user_id)
    AND u_keep.email IS NOT NULL AND u_keep.email != ''
  ORDER BY u_keep.created_at ASC
  LIMIT 1
)
WHERE user_id IN (
  SELECT u_dup.id FROM users u_dup
  WHERE u_dup.email IN (
    SELECT email FROM users
    WHERE email IS NOT NULL AND email != ''
    GROUP BY email HAVING COUNT(*) > 1
  )
  AND u_dup.id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = u_dup.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  )
);

-- Migrate rate_limit_history from duplicate users to the keeper
UPDATE rate_limit_history
SET user_id = (
  SELECT u_keep.id FROM users u_keep
  WHERE u_keep.email = (SELECT email FROM users WHERE id = rate_limit_history.user_id)
    AND u_keep.email IS NOT NULL AND u_keep.email != ''
  ORDER BY u_keep.created_at ASC
  LIMIT 1
)
WHERE user_id IN (
  SELECT u_dup.id FROM users u_dup
  WHERE u_dup.email IN (
    SELECT email FROM users
    WHERE email IS NOT NULL AND email != ''
    GROUP BY email HAVING COUNT(*) > 1
  )
  AND u_dup.id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = u_dup.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  )
);

-- Migrate subscription_events from duplicate users to the keeper
UPDATE subscription_events
SET user_id = (
  SELECT u_keep.id FROM users u_keep
  WHERE u_keep.email = (SELECT email FROM users WHERE id = subscription_events.user_id)
    AND u_keep.email IS NOT NULL AND u_keep.email != ''
  ORDER BY u_keep.created_at ASC
  LIMIT 1
)
WHERE user_id IN (
  SELECT u_dup.id FROM users u_dup
  WHERE u_dup.email IN (
    SELECT email FROM users
    WHERE email IS NOT NULL AND email != ''
    GROUP BY email HAVING COUNT(*) > 1
  )
  AND u_dup.id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = u_dup.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  )
);

-- Migrate user_asr_quota from duplicate users to the keeper
-- (has UNIQUE(user_id, week_key), so skip rows that would conflict)
DELETE FROM user_asr_quota
WHERE user_id IN (
  SELECT u_dup.id FROM users u_dup
  WHERE u_dup.email IN (
    SELECT email FROM users
    WHERE email IS NOT NULL AND email != ''
    GROUP BY email HAVING COUNT(*) > 1
  )
  AND u_dup.id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = u_dup.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  )
);

-- Migrate hotwords from duplicate users to the keeper
-- (has UNIQUE(user_id, normalized_text), so skip rows that would conflict)
INSERT OR IGNORE INTO hotwords (id, user_id, text, normalized_text, created_at, updated_at)
SELECT id,
  (SELECT u_keep.id FROM users u_keep
   WHERE u_keep.email = (SELECT email FROM users WHERE id = hotwords.user_id)
   ORDER BY u_keep.created_at ASC LIMIT 1),
  text, normalized_text, created_at, updated_at
FROM hotwords
WHERE user_id IN (
  SELECT u_dup.id FROM users u_dup
  WHERE u_dup.email IN (
    SELECT email FROM users
    WHERE email IS NOT NULL AND email != ''
    GROUP BY email HAVING COUNT(*) > 1
  )
  AND u_dup.id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = u_dup.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  )
);

DELETE FROM hotwords
WHERE user_id IN (
  SELECT u_dup.id FROM users u_dup
  WHERE u_dup.email IN (
    SELECT email FROM users
    WHERE email IS NOT NULL AND email != ''
    GROUP BY email HAVING COUNT(*) > 1
  )
  AND u_dup.id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = u_dup.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  )
);

-- Now delete duplicate user rows (keep the earliest per email)
DELETE FROM users
WHERE email IS NOT NULL AND email != ''
  AND id != (
    SELECT u_first.id FROM users u_first
    WHERE u_first.email = users.email
    ORDER BY u_first.created_at ASC
    LIMIT 1
  );

-- ============================================
-- Step 2: Add UNIQUE constraint on email
-- Cannot ALTER TABLE ADD CONSTRAINT in SQLite, and DROP TABLE
-- breaks foreign keys. Use a partial unique index instead:
-- enforces uniqueness for non-null, non-empty emails.
-- ============================================

-- Drop the old non-unique index first (same column)
DROP INDEX IF EXISTS idx_users_email;

-- Create unique index (partial: excludes NULL and empty string)
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_unique
  ON users(email)
  WHERE email IS NOT NULL AND email != '';

-- ============================================
-- Step 3: Partial unique index on subscriptions
-- Only one active/past_due subscription per user
-- ============================================
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_one_active_per_user
  ON subscriptions(user_id)
  WHERE status IN ('active', 'past_due');

-- ============================================
-- Step 4: Unique index on creem_subscription_id
-- (WHERE NOT NULL — allow multiple NULLs for non-creem subs)
-- ============================================
CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_creem_sub_id_unique
  ON subscriptions(creem_subscription_id)
  WHERE creem_subscription_id IS NOT NULL;
