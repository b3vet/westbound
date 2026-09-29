//! SQL for `leaderboard_entries` (migration 0003). Ranking order is `score DESC,
//! achieved_at ASC, subject_id ASC` (ties: the earlier run wins, then the lower id), which
//! is the `leaderboard_rank` index, so every query here is an index walk:
//!
//! - top N: the first N index entries of (board, period);
//! - a rank: 1 + the entries ahead, counted as `score > s` plus the ties ahead
//!   (`score = s AND (achieved_at, subject_id) < (a, id)`), two index ranges;
//! - "around me": the nearest entries ahead and behind, each as a tie range and a
//!   strictly-higher / strictly-lower range, walked from the caller outwards (keyset, no
//!   OFFSET).
//!
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards" (views: global top 100, around
//! me, friends only), "Data model (SQLite)".

use sqlx::SqliteConnection;

/// One entry with the display fields of its account (none on the crew board).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryRow {
    pub subject_id: i64,
    pub account_id: Option<i64>,
    pub display_name: Option<String>,
    pub tag: Option<i64>,
    pub run_id: Option<i64>,
    pub score: i64,
    pub achieved_at: i64,
    pub verification: String,
    pub run_date: String,
}

/// An entry to write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewEntry<'a> {
    pub board: &'a str,
    pub period_key: &'a str,
    pub subject_id: i64,
    pub account_id: Option<i64>,
    pub run_id: Option<i64>,
    pub score: i64,
    pub achieved_at: i64,
    pub verification: &'a str,
    pub run_date: &'a str,
}

/// The first `limit` entries.
pub async fn top(
    conn: &mut SqliteConnection,
    board: &str,
    period: &str,
    limit: i64,
) -> sqlx::Result<Vec<EntryRow>> {
    sqlx::query_as!(
        EntryRow,
        r#"SELECT e.subject_id, e.account_id, a.display_name AS "display_name?: String",
                  a.tag AS "tag?: i64", e.run_id, e.score, e.achieved_at, e.verification,
                  e.run_date
           FROM leaderboard_entries e LEFT JOIN accounts a ON a.id = e.account_id
           WHERE e.board = ?1 AND e.period_key = ?2
           ORDER BY e.score DESC, e.achieved_at ASC, e.subject_id ASC
           LIMIT ?3"#,
        board,
        period,
        limit
    )
    .fetch_all(conn)
    .await
}

/// Entries in the board and period.
pub async fn count(conn: &mut SqliteConnection, board: &str, period: &str) -> sqlx::Result<i64> {
    sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "n!: i64" FROM leaderboard_entries
           WHERE board = ?1 AND period_key = ?2"#,
        board,
        period
    )
    .fetch_one(conn)
    .await
}

/// One subject's entry.
pub async fn entry(
    conn: &mut SqliteConnection,
    board: &str,
    period: &str,
    subject_id: i64,
) -> sqlx::Result<Option<EntryRow>> {
    sqlx::query_as!(
        EntryRow,
        r#"SELECT e.subject_id, e.account_id, a.display_name AS "display_name?: String",
                  a.tag AS "tag?: i64", e.run_id, e.score, e.achieved_at, e.verification,
                  e.run_date
           FROM leaderboard_entries e LEFT JOIN accounts a ON a.id = e.account_id
           WHERE e.board = ?1 AND e.period_key = ?2 AND e.subject_id = ?3"#,
        board,
        period,
        subject_id
    )
    .fetch_optional(conn)
    .await
}

/// Entries ranked ahead of (score, achieved_at, subject_id): its rank is this + 1.
pub async fn count_ahead(
    conn: &mut SqliteConnection,
    board: &str,
    period: &str,
    score: i64,
    achieved_at: i64,
    subject_id: i64,
) -> sqlx::Result<i64> {
    sqlx::query_scalar!(
        r#"SELECT (SELECT COUNT(*) FROM leaderboard_entries
                   WHERE board = ?1 AND period_key = ?2 AND score > ?3)
                + (SELECT COUNT(*) FROM leaderboard_entries
                   WHERE board = ?1 AND period_key = ?2 AND score = ?3
                     AND (achieved_at, subject_id) < (?4, ?5)) AS "n!: i64""#,
        board,
        period,
        score,
        achieved_at,
        subject_id
    )
    .fetch_one(conn)
    .await
}

/// Up to `limit` entries ranked just ahead of the given position, nearest first.
pub async fn ahead(
    conn: &mut SqliteConnection,
    board: &str,
    period: &str,
    score: i64,
    achieved_at: i64,
    subject_id: i64,
    limit: i64,
) -> sqlx::Result<Vec<EntryRow>> {
    let mut rows = sqlx::query_as!(
        EntryRow,
        r#"SELECT e.subject_id, e.account_id, a.display_name AS "display_name?: String",
                  a.tag AS "tag?: i64", e.run_id, e.score, e.achieved_at, e.verification,
                  e.run_date
           FROM leaderboard_entries e LEFT JOIN accounts a ON a.id = e.account_id
           WHERE e.board = ?1 AND e.period_key = ?2 AND e.score = ?3
             AND (e.achieved_at, e.subject_id) < (?4, ?5)
           ORDER BY e.achieved_at DESC, e.subject_id DESC
           LIMIT ?6"#,
        board,
        period,
        score,
        achieved_at,
        subject_id,
        limit
    )
    .fetch_all(&mut *conn)
    .await?;
    let rest = limit - rows.len() as i64;
    if rest > 0 {
        rows.extend(
            sqlx::query_as!(
                EntryRow,
                r#"SELECT e.subject_id, e.account_id, a.display_name AS "display_name?: String",
                          a.tag AS "tag?: i64", e.run_id, e.score, e.achieved_at,
                          e.verification, e.run_date
                   FROM leaderboard_entries e LEFT JOIN accounts a ON a.id = e.account_id
                   WHERE e.board = ?1 AND e.period_key = ?2 AND e.score > ?3
                   ORDER BY e.score ASC, e.achieved_at DESC, e.subject_id DESC
                   LIMIT ?4"#,
                board,
                period,
                score,
                rest
            )
            .fetch_all(&mut *conn)
            .await?,
        );
    }
    Ok(rows)
}

/// Up to `limit` entries ranked just behind the given position, nearest first.
pub async fn behind(
    conn: &mut SqliteConnection,
    board: &str,
    period: &str,
    score: i64,
    achieved_at: i64,
    subject_id: i64,
    limit: i64,
) -> sqlx::Result<Vec<EntryRow>> {
    let mut rows = sqlx::query_as!(
        EntryRow,
        r#"SELECT e.subject_id, e.account_id, a.display_name AS "display_name?: String",
                  a.tag AS "tag?: i64", e.run_id, e.score, e.achieved_at, e.verification,
                  e.run_date
           FROM leaderboard_entries e LEFT JOIN accounts a ON a.id = e.account_id
           WHERE e.board = ?1 AND e.period_key = ?2 AND e.score = ?3
             AND (e.achieved_at, e.subject_id) > (?4, ?5)
           ORDER BY e.achieved_at ASC, e.subject_id ASC
           LIMIT ?6"#,
        board,
        period,
        score,
        achieved_at,
        subject_id,
        limit
    )
    .fetch_all(&mut *conn)
    .await?;
    let rest = limit - rows.len() as i64;
    if rest > 0 {
        rows.extend(
            sqlx::query_as!(
                EntryRow,
                r#"SELECT e.subject_id, e.account_id, a.display_name AS "display_name?: String",
                          a.tag AS "tag?: i64", e.run_id, e.score, e.achieved_at,
                          e.verification, e.run_date
                   FROM leaderboard_entries e LEFT JOIN accounts a ON a.id = e.account_id
                   WHERE e.board = ?1 AND e.period_key = ?2 AND e.score < ?3
                   ORDER BY e.score DESC, e.achieved_at ASC, e.subject_id ASC
                   LIMIT ?4"#,
                board,
                period,
                score,
                rest
            )
            .fetch_all(&mut *conn)
            .await?,
        );
    }
    Ok(rows)
}

/// The entries of the given subjects (a JSON array of ids), in rank order: the friends
/// view. N9 passes the caller and their friends.
pub async fn of_subjects(
    conn: &mut SqliteConnection,
    board: &str,
    period: &str,
    subject_ids_json: &str,
    limit: i64,
) -> sqlx::Result<Vec<EntryRow>> {
    sqlx::query_as!(
        EntryRow,
        r#"SELECT e.subject_id, e.account_id, a.display_name AS "display_name?: String",
                  a.tag AS "tag?: i64", e.run_id, e.score, e.achieved_at, e.verification,
                  e.run_date
           FROM leaderboard_entries e LEFT JOIN accounts a ON a.id = e.account_id
           WHERE e.board = ?1 AND e.period_key = ?2
             AND e.subject_id IN (SELECT value FROM json_each(?3))
           ORDER BY e.score DESC, e.achieved_at ASC, e.subject_id ASC
           LIMIT ?4"#,
        board,
        period,
        subject_ids_json,
        limit
    )
    .fetch_all(conn)
    .await
}

/// Inserts the entry, or replaces the subject's entry only if `score` is strictly higher
/// (an equal score keeps the earlier run). Returns whether anything was written.
pub async fn upsert_if_better(conn: &mut SqliteConnection, e: &NewEntry<'_>) -> sqlx::Result<bool> {
    let done = sqlx::query!(
        "INSERT INTO leaderboard_entries
             (board, period_key, subject_id, account_id, run_id, score, achieved_at,
              verification, run_date)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (board, period_key, subject_id) DO UPDATE SET
             account_id = excluded.account_id, run_id = excluded.run_id,
             score = excluded.score, achieved_at = excluded.achieved_at,
             verification = excluded.verification, run_date = excluded.run_date
         WHERE excluded.score > leaderboard_entries.score",
        e.board,
        e.period_key,
        e.subject_id,
        e.account_id,
        e.run_id,
        e.score,
        e.achieved_at,
        e.verification,
        e.run_date
    )
    .execute(conn)
    .await?;
    Ok(done.rows_affected() == 1)
}

/// Inserts the entry, or replaces it when the score differs (a computed entry: the crew
/// board's sum). Returns whether anything was written.
pub async fn put_if_changed(conn: &mut SqliteConnection, e: &NewEntry<'_>) -> sqlx::Result<bool> {
    let done = sqlx::query!(
        "INSERT INTO leaderboard_entries
             (board, period_key, subject_id, account_id, run_id, score, achieved_at,
              verification, run_date)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (board, period_key, subject_id) DO UPDATE SET
             account_id = excluded.account_id, run_id = excluded.run_id,
             score = excluded.score, achieved_at = excluded.achieved_at,
             verification = excluded.verification, run_date = excluded.run_date
         WHERE excluded.score != leaderboard_entries.score",
        e.board,
        e.period_key,
        e.subject_id,
        e.account_id,
        e.run_id,
        e.score,
        e.achieved_at,
        e.verification,
        e.run_date
    )
    .execute(conn)
    .await?;
    Ok(done.rows_affected() == 1)
}

/// Removes one entry. Returns whether it existed.
pub async fn delete(
    conn: &mut SqliteConnection,
    board: &str,
    period: &str,
    subject_id: i64,
) -> sqlx::Result<bool> {
    let done = sqlx::query!(
        "DELETE FROM leaderboard_entries WHERE board = ? AND period_key = ? AND subject_id = ?",
        board,
        period,
        subject_id
    )
    .execute(conn)
    .await?;
    Ok(done.rows_affected() == 1)
}

/// (board, period_key, subject_id) of every entry a run set.
pub async fn entries_of_run(
    conn: &mut SqliteConnection,
    run_id: i64,
) -> sqlx::Result<Vec<(String, String, i64)>> {
    let rows = sqlx::query!(
        r#"SELECT board, period_key, subject_id AS "subject_id!" FROM leaderboard_entries
           WHERE run_id = ?"#,
        run_id
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| (r.board, r.period_key, r.subject_id))
        .collect())
}

/// Sum of the best `top` season scores on the Loop board among `member_ids_json` (a JSON
/// array of account ids): a crew's Loop crew score.
pub async fn crew_sum(
    conn: &mut SqliteConnection,
    loop_board: &str,
    season: &str,
    member_ids_json: &str,
    top: i64,
) -> sqlx::Result<i64> {
    sqlx::query_scalar!(
        r#"SELECT COALESCE(SUM(score), 0) AS "n!: i64" FROM (
               SELECT score FROM leaderboard_entries
               WHERE board = ?1 AND period_key = ?2
                 AND subject_id IN (SELECT value FROM json_each(?3))
               ORDER BY score DESC LIMIT ?4)"#,
        loop_board,
        season,
        member_ids_json,
        top
    )
    .fetch_one(conn)
    .await
}
