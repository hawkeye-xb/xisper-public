-- Migration 009: Independent admin_accounts table
-- Admin authentication is separate from Logto user system.
-- Passwords stored as PBKDF2 hashes.

CREATE TABLE IF NOT EXISTS admin_accounts (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,   -- format: pbkdf2:iterations:salt_hex:hash_hex
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_accounts_username
  ON admin_accounts(username);
