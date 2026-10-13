-- Reports sent from the app (Settings -> Reports). Photos live in R2 under "<id>/<n>.<ext>".
CREATE TABLE IF NOT EXISTS reports (
  id          TEXT PRIMARY KEY,
  created_at  INTEGER NOT NULL,          -- unix seconds
  kind        TEXT NOT NULL,             -- 'manual' | 'auto'
  error_kind  TEXT,                      -- what failed, for 'auto'
  message     TEXT,                      -- what the user wrote
  app_version TEXT,
  build       TEXT,
  channel     TEXT,
  os          TEXT,
  device      TEXT,
  locale      TEXT,
  install_id  TEXT,                      -- random per install, not tied to any account
  ip_hash     TEXT,                      -- salted hash, only for rate limits
  log         TEXT,
  photos      INTEGER NOT NULL DEFAULT 0,
  photo_exts  TEXT NOT NULL DEFAULT '',  -- e.g. 'jpg,png'
  status      TEXT NOT NULL DEFAULT 'open',  -- open | in_progress | closed
  updated_at  INTEGER NOT NULL DEFAULT 0     -- last message or status change
);
CREATE INDEX IF NOT EXISTS reports_created ON reports (created_at);
CREATE INDEX IF NOT EXISTS reports_install ON reports (install_id, created_at);
CREATE INDEX IF NOT EXISTS reports_ip ON reports (ip_hash, created_at);
CREATE INDEX IF NOT EXISTS reports_status ON reports (status, created_at);
CREATE TABLE IF NOT EXISTS messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  report_id   TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  author      TEXT NOT NULL,                 -- 'user' | 'dev'
  text        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_report ON messages (report_id, id);
