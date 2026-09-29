-- N7.1 leaderboards and the runs API. WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards",
-- "Data model (SQLite)". Times are unix seconds (UTC); dates are 'YYYY-MM-DD' (UTC).
-- docs/SERVER.md → "Leaderboards & runs API".

-- runs: every submitted or server-recorded run, rejected ones included (for audit).
--   mode            'journey' | 'daily' (single-player submissions), 'loop' (multiplayer,
--                   written by the server), 'legacy' (an uploaded local personal best)
--   map_or_seed     the run seed as a decimal string (single-player), the map id ('loop_v1')
--                   or 'legacy'
--   date            the UTC date the run was played; for Daily Drive, the seed's date.
--                   Weekly / season periods are derived from it
--   score           the banked score (legacy distance items: 0)
--   stats           JSON: the run_over stats (docs/SERVER.md lists the keys)
--   build           the client build number (u32, as in the protocol's Hello)
--   room_type       NULL for single-player; 'public', 'private' (defaults: ranked) or
--                   'private_custom' (custom density or clock: personal stats only)
--   verification    pending (awaits its replay, N8; shown as "verifying"), verified
--                   (multiplayer, or replay accepted), unverified (plausible, no replay
--                   needed), rejected (failed a check; kept, never on a board), legacy
--   legacy_board    the board of a legacy upload; UNIQUE with the account = once per board
--   idempotency_key the client's key; UNIQUE with the account (double submits)
--   response        the JSON body answered to the submission (replayed for a duplicate)
CREATE TABLE runs (
    id              INTEGER PRIMARY KEY,
    account_id      INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    mode            TEXT    NOT NULL CHECK (mode IN ('journey', 'daily', 'loop', 'legacy')),
    map_or_seed     TEXT    NOT NULL,
    date            TEXT    NOT NULL,
    score           INTEGER NOT NULL CHECK (score >= 0),
    distance_m      REAL    NOT NULL,
    duration_s      REAL    NOT NULL,
    stats           TEXT    NOT NULL DEFAULT '{}',
    car             TEXT    NOT NULL DEFAULT '',
    build           INTEGER NOT NULL DEFAULT 0,
    room_type       TEXT CHECK (room_type IN ('public', 'private', 'private_custom')),
    verification    TEXT    NOT NULL
        CHECK (verification IN ('pending', 'verified', 'rejected', 'unverified', 'legacy')),
    reject_reason   TEXT,
    legacy_board    TEXT,
    idempotency_key TEXT,
    response        TEXT,
    created_at      INTEGER NOT NULL,
    UNIQUE (account_id, idempotency_key),
    UNIQUE (account_id, legacy_board)
);

CREATE INDEX runs_account ON runs (account_id, mode, date);

-- leaderboard_entries: the best entry per subject per board and period.
--   board        'loop', 'loop_crew', 'journey', 'daily', 'distance'
--   period_key   'YYYY-MM' (Loop season), 'YYYY-Www' (ISO week, Journey weekly),
--                'YYYY-MM-DD' (Daily Drive), 'all'
--   subject_id   the account id; the crew id on 'loop_crew'
--   account_id   the account (NULL on 'loop_crew'); deleting the account deletes the row
--   run_id       the run that set it (NULL on 'loop_crew': a sum of members' bests)
--   score        the ranked value: points, or whole metres on 'distance'
--   achieved_at  when the run was recorded: ties rank the earlier run first
--   verification the run's verification when written (kept in step by N8)
--   run_date     the run's date, shown on the board
CREATE TABLE leaderboard_entries (
    board        TEXT    NOT NULL,
    period_key   TEXT    NOT NULL,
    subject_id   INTEGER NOT NULL,
    account_id   INTEGER REFERENCES accounts (id) ON DELETE CASCADE,
    run_id       INTEGER REFERENCES runs (id) ON DELETE CASCADE,
    score        INTEGER NOT NULL,
    achieved_at  INTEGER NOT NULL,
    verification TEXT    NOT NULL,
    run_date     TEXT    NOT NULL,
    PRIMARY KEY (board, period_key, subject_id)
) WITHOUT ROWID;

-- Ranking order: score DESC, achieved_at ASC, subject_id ASC. Top N and "around me" walk
-- this index; a rank is a count over it.
CREATE INDEX leaderboard_rank
    ON leaderboard_entries (board, period_key, score DESC, achieved_at, subject_id);
CREATE INDEX leaderboard_account ON leaderboard_entries (account_id);
CREATE INDEX leaderboard_run ON leaderboard_entries (run_id);

-- replays: uploaded replays of runs (N8 adds the upload route and the verifier queue).
--   file_path  the replay file (absolute, under data/replays/); deleted with the account
--   status     the verifier's state, e.g. 'queued', 'verifying', 'accepted', 'rejected'
--   result     the verifier's details (JSON)
CREATE TABLE replays (
    run_id     INTEGER PRIMARY KEY REFERENCES runs (id) ON DELETE CASCADE,
    file_path  TEXT    NOT NULL,
    status     TEXT    NOT NULL,
    result     TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX replays_status ON replays (status, created_at);
