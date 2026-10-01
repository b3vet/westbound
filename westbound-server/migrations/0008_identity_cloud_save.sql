-- N11: Sign in with Apple / Google and cloud save. WESTBOUND_MULTIPLAYER_HANDOFF.md →
-- "Accounts and authentication"; docs/SERVER.md → "Sign in with Apple / Google",
-- "Cloud save". Times are unix seconds.
--
-- The provider subject stays where 0001 put it (accounts.apple_sub / google_sub, UNIQUE):
-- one Apple and one Google identity per account, each on at most one account.

-- identity_links: what the server keeps about a linked identity besides its subject.
--   email_hint            a masked address for the account screen (`j•••@gmail.com`), never
--                         the full address; NULL for Apple's private relay or no email
--   private_email         Apple's `is_private_email` (Hide My Email)
--   apple_client_id       the `aud` Apple issued the token for (Services ID or bundle id):
--                         revocation must name the same client
--   apple_refresh_sealed  Apple's refresh token from the authorization-code exchange,
--                         sealed (HMAC-CTR + tag under a key derived from the pepper); only
--                         used to revoke on unlink and account deletion. NULL without the
--                         Apple key or the code
CREATE TABLE identity_links (
    account_id           INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    provider             TEXT    NOT NULL CHECK (provider IN ('apple', 'google')),
    email_hint           TEXT,
    private_email        INTEGER NOT NULL DEFAULT 0,
    linked_at            INTEGER NOT NULL,
    last_used_at         INTEGER NOT NULL,
    apple_client_id      TEXT,
    apple_refresh_sealed BLOB,
    PRIMARY KEY (account_id, provider)
) WITHOUT ROWID;

-- device_secrets: extra device credentials. A provider sign-in on another device gives
-- that device its own secret (accounts.device_secret_hash keeps the first device's), so
-- every signed-in device can renew its session the same way. Stored like the first:
-- HMAC-SHA256 under the pepper. At most identity.max_device_secrets per account.
CREATE TABLE device_secrets (
    secret_hash  BLOB    PRIMARY KEY,
    account_id   INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE INDEX device_secrets_account ON device_secrets (account_id, last_used_at);

-- cloud_saves: one JSON document per account, replaced whole (old revisions are not
-- kept). `revision` counts up from 1 for optimistic concurrency (PUT with If-Match).
CREATE TABLE cloud_saves (
    account_id INTEGER PRIMARY KEY REFERENCES accounts (id) ON DELETE CASCADE,
    revision   INTEGER NOT NULL,
    data       TEXT    NOT NULL,
    bytes      INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
