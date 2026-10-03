-- Crew invites: a crew member invites a friend to the crew (the owner's request "there is no
-- way to invite my friends to my crew"). WESTBOUND_MULTIPLAYER_HANDOFF.md → "Rooms, parties
-- and matchmaking → Crews (persistent)" (joined by an invite code: an invite carries the
-- crew to the friend instead), "Friends and presence" (blocking). docs/SERVER.md → "Social
-- API → Crew invites". Times are unix seconds (UTC).

-- crew_invites: one waiting invite per crew and invitee (a second invite renews it).
--   id          the invite id the API hands out; AUTOINCREMENT, so an answered invite's id
--               never comes back for another invite (a client's stale list cannot answer it)
--   crew_id     the crew; the invite goes with the crew (disband deletes it too)
--   account_id  the invitee; the invite goes with the account (accounts::delete also
--               deletes it)
--   inviter_id  the member who sent it. Their account deletion deletes the invite
--               (social::on_account_delete), so this is never NULL in practice
--   expires_at  created_at + social.crew_invite_ttl_hours; expired rows are ignored by every
--               read and deleted by the daily housekeeping pass
-- Accepting joins the crew (the join-by-code checks) and deletes the row; declining deletes
-- it; joining the crew any other way deletes it.
CREATE TABLE crew_invites (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    crew_id    INTEGER NOT NULL REFERENCES crews (id) ON DELETE CASCADE,
    account_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    inviter_id INTEGER REFERENCES accounts (id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    UNIQUE (crew_id, account_id)
);

-- The invitee's list (newest first, unexpired), and the crew's pending count is served by
-- the unique index; the sender's side for account deletion.
CREATE INDEX crew_invites_account ON crew_invites (account_id, expires_at);
CREATE INDEX crew_invites_inviter ON crew_invites (inviter_id);
CREATE INDEX crew_invites_expires ON crew_invites (expires_at);
