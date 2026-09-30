-- N8.1 replay uploads and the verification queue. WESTBOUND_MULTIPLAYER_HANDOFF.md →
-- "Leaderboards" (single-player runs, steps 3–5: jobs queue in SQLite and run one at a
-- time with a timeout; replays are deleted after verification except for current
-- top-100 entries). docs/SERVER.md → "Replays and verification". Times are unix seconds.
--
-- replays (created in 0003) is the job queue, one row per uploaded replay:
--   status          'pending' (waiting for the worker; with no verifier configured jobs
--                   stay here), 'running' (the worker has it), 'done' (a verdict was
--                   applied: see verdict), 'failed' (max_attempts used up; the run stays
--                   "verifying" until an operator requeues it)
--   result          the verifier's result JSON (done), or the last error (failed)
--   size_bytes      the uploaded file's size
--   attempts        verifier runs started for this job
--   not_before      a pending job is not started before this (retry delay)
--   started_at      the current or last attempt's start
--   finished_at     when it became done or failed
--   verdict         'accepted' | 'rejected' (done only)
--   file_deleted_at the file was removed by retention (the row stays for audit)
-- No rows existed before N8.1 (0003 created the table without an upload route).
ALTER TABLE replays ADD COLUMN size_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE replays ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE replays ADD COLUMN not_before INTEGER NOT NULL DEFAULT 0;
ALTER TABLE replays ADD COLUMN started_at INTEGER;
ALTER TABLE replays ADD COLUMN finished_at INTEGER;
ALTER TABLE replays ADD COLUMN verdict TEXT CHECK (verdict IN ('accepted', 'rejected'));
ALTER TABLE replays ADD COLUMN file_deleted_at INTEGER;

DROP INDEX replays_status;
-- The worker's pick: the oldest pending job that may start now.
CREATE INDEX replays_queue ON replays (status, not_before, created_at, run_id);
