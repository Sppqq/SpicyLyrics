-- Report statuses and threads (answers to the sender, their replies).
ALTER TABLE reports ADD COLUMN status TEXT NOT NULL DEFAULT 'open';
ALTER TABLE reports ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  report_id   TEXT NOT NULL,
  created_at  INTEGER NOT NULL,              -- unix seconds
  author      TEXT NOT NULL,                 -- 'user' | 'dev'
  text        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_report ON messages (report_id, id);
CREATE INDEX IF NOT EXISTS reports_status ON reports (status, created_at);
