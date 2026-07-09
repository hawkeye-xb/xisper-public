-- Add role column to users table for admin access control
-- Values: 'user' (default), 'admin'
ALTER TABLE users ADD COLUMN role TEXT DEFAULT 'user';

-- Index for role-based queries
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);
