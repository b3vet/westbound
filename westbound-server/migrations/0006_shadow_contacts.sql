-- N10.1 shadow collision logging. WESTBOUND_MULTIPLAYER_HANDOFF.md → Players ("Shadow
-- collision logging": every moment two players' collision boxes would have overlapped,
-- from both reported states at the same tick, with how much their views disagreed; the
-- aggregates go into the admin stats), Data model (`shadow_contacts`: room_id, tick,
-- player_a, player_b, speed, disagreement_m). docs/SERVER.md → "Load test and shadow
-- collisions (N10.1)". Times are unix seconds.
--
-- One row per contact (consecutive overlapping ticks of one pair):
--   room_id, tick     the room and its tick of the contact's first overlapping state
--   player_a/_b       the two players' account ids (a < b); room player ids are
--                     per room and meaningless later
--   speed             the pair's mean forward speed at the first tick (m/s)
--   disagreement_m    the largest disagreement of the two players' views (m)
--   closing_mps       the largest difference of their speeds over the contact (m/s)
--   depth_m           the deepest overlap (m)
--   ticks             how many room ticks the boxes overlapped
--   created_at        when the contact ended
-- Accounts are not foreign keys: a deleted account's contacts stay as anonymous numbers.
CREATE TABLE shadow_contacts (
    id             INTEGER PRIMARY KEY,
    room_id        INTEGER NOT NULL,
    tick           INTEGER NOT NULL,
    player_a       INTEGER NOT NULL,
    player_b       INTEGER NOT NULL,
    speed          REAL    NOT NULL,
    disagreement_m REAL    NOT NULL,
    closing_mps    REAL    NOT NULL,
    depth_m        REAL    NOT NULL,
    ticks          INTEGER NOT NULL,
    created_at     INTEGER NOT NULL
);
-- The admin stats read the recent ones.
CREATE INDEX shadow_contacts_created ON shadow_contacts (created_at);
