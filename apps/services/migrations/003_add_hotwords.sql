-- Hotwords table: user-defined ASR hints, remote-hosted for cross-device sync
CREATE TABLE IF NOT EXISTS hotwords (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  text TEXT NOT NULL,
  normalized_text TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_hotwords_user_id ON hotwords(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_hotwords_user_normalized ON hotwords(user_id, normalized_text);
