-- N0: the tables N1 (device accounts) needs. WESTBOUND_MULTIPLAYER_HANDOFF.md → "Data model (SQLite)".
-- Times are unix seconds (UTC). Secrets and tokens are stored only as hashes.
-- Later milestones add friends, blocks, crews, runs, leaderboards, replays, reports, shadow_contacts.

CREATE TABLE accounts (
    id                 INTEGER PRIMARY KEY,
    display_name       TEXT    NOT NULL COLLATE NOCASE,
    tag                INTEGER NOT NULL CHECK (tag BETWEEN 0 AND 9999),
    device_secret_hash BLOB,
    apple_sub          TEXT UNIQUE,
    google_sub         TEXT UNIQUE,
    created_at         INTEGER NOT NULL,
    last_seen          INTEGER NOT NULL,
    banned_until       INTEGER,
    name_changed_at    INTEGER,
    UNIQUE (display_name, tag)
);

CREATE TABLE refresh_tokens (
    token_hash   BLOB    PRIMARY KEY,
    account_id   INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    expires_at   INTEGER NOT NULL,
    rotated_from BLOB,
    created_at   INTEGER NOT NULL
);

CREATE INDEX refresh_tokens_account ON refresh_tokens (account_id);
CREATE INDEX refresh_tokens_expires ON refresh_tokens (expires_at);

CREATE TABLE admin_log (
    id         INTEGER PRIMARY KEY,
    actor      TEXT    NOT NULL,
    action     TEXT    NOT NULL,
    target     TEXT    NOT NULL DEFAULT '',
    detail     TEXT    NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
);

CREATE INDEX admin_log_created ON admin_log (created_at);
