//! Seams for the social features the leaderboards read (N9: friends, persistent crews).
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards" (views: friends only; the Loop
//! crew board), "Rooms, parties and matchmaking" (friends, crews).
//!
//! Until N9 there are no `friends` or `crew_members` tables, so both answer "not
//! available". N9 replaces the bodies (one indexed query each); the board queries already
//! take their result (`leaderboards::store::of_subjects` ranks any id list).

use sqlx::SqliteConnection;

/// The account's accepted friends, or `None` while friends do not exist (the friends
/// view then answers an empty list with `friends_available: false`).
///
/// N9: `SELECT account_b FROM friends WHERE account_a = ? AND status = 'accepted'
/// UNION SELECT account_a FROM friends WHERE account_b = ? AND status = 'accepted'`.
pub async fn friend_ids(
    _conn: &mut SqliteConnection,
    _account_id: i64,
) -> sqlx::Result<Option<Vec<i64>>> {
    Ok(None)
}

/// The account's crew, if any (`None` until crews exist): the subject of its entries on
/// the Loop crew board ("me" and "around me" there).
///
/// N9: `SELECT crew_id FROM crew_members WHERE account_id = ?`.
pub async fn crew_of(_conn: &mut SqliteConnection, _account_id: i64) -> sqlx::Result<Option<i64>> {
    Ok(None)
}
