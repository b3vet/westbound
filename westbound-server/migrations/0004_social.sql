-- N9.1 social: friends, blocks, persistent crews, reports. WESTBOUND_MULTIPLAYER_HANDOFF.md →
-- "Rooms, parties and matchmaking" (friends and presence, crews, moderation), "Data model
-- (SQLite)", "Accounts → Account deletion". Times are unix seconds (UTC).
-- docs/SERVER.md → "Social API".

-- friends: one row per pair of accounts, a pending request or an accepted friendship.
--   account_a / account_b  the pair, lower id first (so a pair has one row whoever asked)
--   requester_id           who sent the request (one of the pair)
--   status                 'pending' (a request the other side may accept or decline) or
--                          'accepted'
--   id                     the request id the API hands out (`/friends/requests/{id}`)
-- Rows go with either account (ON DELETE CASCADE; accounts::delete also deletes them).
CREATE TABLE friends (
    id           INTEGER PRIMARY KEY,
    account_a    INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    account_b    INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    requester_id INTEGER NOT NULL,
    status       TEXT    NOT NULL CHECK (status IN ('pending', 'accepted')),
    created_at   INTEGER NOT NULL,
    accepted_at  INTEGER,
    CHECK (account_a < account_b),
    CHECK (requester_id IN (account_a, account_b)),
    UNIQUE (account_a, account_b)
);

-- The unique index serves lookups by account_a; this one serves account_b.
CREATE INDEX friends_b ON friends (account_b, status);
CREATE INDEX friends_a_status ON friends (account_a, status);

-- blocks: account_id blocked blocked_id. Blocking removes the pair's friends row; a block
-- in either direction refuses friend requests (and, from N9's room work, Quick Join
-- matches and invites).
CREATE TABLE blocks (
    account_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    blocked_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (account_id, blocked_id),
    CHECK (account_id != blocked_id)
) WITHOUT ROWID;

CREATE INDEX blocks_blocked ON blocks (blocked_id, account_id);

-- crews: persistent crews. AUTOINCREMENT: a disbanded crew's id is never reused (board
-- entries, reports and admin_log name crews by id).
--   name         3–24 characters, unique case-insensitively, profanity-filtered
--   tag          2–4 characters A–Z 0–9, stored upper case, unique, profanity-filtered
--   owner_id     the owner (also a crew_members row with role 'owner'). No cascade: an
--                account deletion hands the crew on first (or disbands it)
--   invite_code  how players join (`POST /crews/join`); rotated by the owner or officers
CREATE TABLE crews (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL COLLATE NOCASE UNIQUE,
    tag         TEXT    NOT NULL COLLATE NOCASE UNIQUE,
    owner_id    INTEGER NOT NULL REFERENCES accounts (id),
    invite_code TEXT    NOT NULL UNIQUE,
    created_at  INTEGER NOT NULL
);

-- crew_members: one crew per account (account_id is the key).
--   role       'owner' (exactly one per crew), 'officer' or 'member'
--   joined_at  ownership passes to the longest-standing officer, else member
CREATE TABLE crew_members (
    account_id INTEGER PRIMARY KEY REFERENCES accounts (id) ON DELETE CASCADE,
    crew_id    INTEGER NOT NULL REFERENCES crews (id) ON DELETE CASCADE,
    role       TEXT    NOT NULL CHECK (role IN ('owner', 'officer', 'member')),
    joined_at  INTEGER NOT NULL
);

CREATE INDEX crew_members_crew ON crew_members (crew_id, joined_at);

-- reports: player reports for moderation (`POST /reports`, `admin reports`).
--   reporter_id  NULL once the reporter deleted their account
--   target_id    NULL once the reported account was deleted: the report stays for the
--                moderation record (reason, context, time) without pointing at anyone
--   reason       'cheating', 'offensive_name', 'offensive_crew', 'harassment',
--                'griefing', 'other'
--   context      JSON object from the client (where the report came from: a room, a
--                board entry, a run), at most social.report_context_max_bytes
--   handled      0 until an admin marks it (`admin report-handle`), with handled_at
CREATE TABLE reports (
    id          INTEGER PRIMARY KEY,
    reporter_id INTEGER REFERENCES accounts (id) ON DELETE SET NULL,
    target_id   INTEGER REFERENCES accounts (id) ON DELETE SET NULL,
    reason      TEXT    NOT NULL CHECK (reason IN ('cheating', 'offensive_name', 'offensive_crew',
                                                   'harassment', 'griefing', 'other')),
    context     TEXT    NOT NULL DEFAULT '{}',
    created_at  INTEGER NOT NULL,
    handled     INTEGER NOT NULL DEFAULT 0 CHECK (handled IN (0, 1)),
    handled_at  INTEGER
);

-- Per-account report rate limit: the reporter's reports in the last day.
CREATE INDEX reports_reporter ON reports (reporter_id, created_at);
CREATE INDEX reports_handled ON reports (handled, created_at);
CREATE INDEX reports_target ON reports (target_id);
