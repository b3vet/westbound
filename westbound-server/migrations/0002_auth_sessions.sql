-- N1.1 server accounts (device accounts, MP-D2). WESTBOUND_MULTIPLAYER_HANDOFF.md →
-- "Accounts and authentication", "Data model (SQLite)". Times are unix seconds.
--
-- accounts: token_version is the `ver` claim of access tokens; bumping it revokes
-- every outstanding access token of the account (logout everywhere). The device id a
-- client presents to recover its account is the account id itself (with its secret).
-- apple_sub / google_sub stay for MP-D2's provider sign-in. UNIQUE (display_name, tag)
-- from 0001 (display_name COLLATE NOCASE) keeps name#tag unique.

ALTER TABLE accounts ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0;

-- refresh_tokens gains rotation state. Nothing wrote to it before N1.1, so it is
-- rebuilt rather than altered.
--   token_hash    SHA-256 of the token (its primary key and lookup index)
--   family        random id shared by every token rotated from one sign-in; reuse of
--                 a rotated token revokes the whole family
--   rotated_from  token_hash of the token this one replaced (NULL for the first)
--   used_at       when this token was rotated (a second use is reuse)
--   revoked_at    logout, reuse detection or a ban on the family
DROP TABLE refresh_tokens;

CREATE TABLE refresh_tokens (
    token_hash   BLOB    PRIMARY KEY,
    account_id   INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    family       BLOB    NOT NULL,
    rotated_from BLOB,
    created_at   INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL,
    used_at      INTEGER,
    revoked_at   INTEGER
) WITHOUT ROWID;

CREATE INDEX refresh_tokens_account ON refresh_tokens (account_id);
CREATE INDEX refresh_tokens_family ON refresh_tokens (family);
CREATE INDEX refresh_tokens_expires ON refresh_tokens (expires_at);
