-- N10.3 housekeeping: set-aside replay jobs get their own status. docs/SERVER.md →
-- "Replays and verification" (the queue, retention), "Housekeeping (N10.3)".
--
-- replays.status gains 'set_aside': a job no verifier here can verify (N8.3: its build
-- has no verifier in the image, or the verifier answered "cannot verify"). Its run stays
-- "verifying"; every worker start puts it back to 'pending'; after
-- replays.set_aside_retention_days (or `admin replay-purge-set-aside`) its file is deleted
-- and the row stays 'set_aside' with file_deleted_at. Until now such jobs were 'failed'
-- with {"unverifiable": true, ...} as their result and counted as failed; they move here.
-- The column has no CHECK constraint (0003), so nothing else changes.
UPDATE replays SET status = 'set_aside'
WHERE status = 'failed' AND json_valid(result) AND json_extract(result, '$.unverifiable') = 1;
