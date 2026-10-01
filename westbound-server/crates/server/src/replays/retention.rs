//! Replay retention (N8.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards"
//! ("replays are deleted after verification except for current top-100 entries").
//! docs/SERVER.md → "Replays and verification → Retention".
//!
//! - After a verdict (the worker) and on every sweep: a `done` job's file is deleted
//!   unless its run currently ranks within `replays.keep_top_n` on some board in a current
//!   period (N10.3: the day, week or season containing now, or all-time)
//!   (a rejected run holds no entries, so its file always goes). The row stays, with
//!   `file_deleted_at`, for audit.
//! - The sweep (every `cleanup_interval_secs` in `serve`) re-checks kept files (a run
//!   that dropped out of every top 100 loses its file), and deletes orphans in the
//!   replay directory older than an hour: `.wbr` files of no job (or of a job whose file
//!   was already let go), and temporary or result files.
//! - `pending`, `running` and `failed` jobs keep their files (the verifier needs them).
//! - N10.3: `set_aside` jobs (no verifier here knows their build) keep theirs for
//!   `set_aside_retention_days` after the upload; then the sweep lets the file go (the row
//!   stays `set_aside` with `file_deleted_at` and `purged_at` in its result, the run stays
//!   "verifying"). `admin replay-purge-set-aside` does the same by hand.

use std::path::Path;
use std::time::{Duration, SystemTime};

use sqlx::{SqliteConnection, SqlitePool};
use tokio_util::sync::CancellationToken;

use super::status;
use crate::clock::{Clock, SECS_PER_DAY};
use crate::config::ReplaysConfig;
use crate::leaderboards::{store, Board, Period, PeriodKind};
use crate::metrics::Metrics;

/// Set-aside jobs purged per statement.
const PURGE_BATCH: i64 = 500;

/// Temporary uploads and stale result files older than this are orphans.
const ORPHAN_AGE: Duration = Duration::from_secs(3_600);

/// What a sweep did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SweepReport {
    /// Verified replays whose files were deleted.
    pub deleted: u64,
    /// Verified replays kept (their run is in a top N).
    pub kept: u64,
    /// Files in the replay directory that no job needed.
    pub orphans: u64,
    /// N10.3: set-aside replays past `set_aside_retention_days` whose files were deleted.
    pub set_aside_purged: u64,
}

/// N10.3: set-aside jobs uploaded before `before` (unix seconds) lose their file: the row
/// stays `set_aside` with `file_deleted_at = now` and `purged_at` in its result (so no
/// worker start requeues it), and the run stays "verifying". Pre-N10.3 set-aside rows
/// (`failed` + `"unverifiable": true`) are moved to `set_aside` on the way. Returns how
/// many.
pub async fn purge_set_aside(db: &SqlitePool, before: i64, now: i64) -> anyhow::Result<u64> {
    let mut total = 0;
    loop {
        let rows: Vec<(i64, String)> = sqlx::query_as(
            "SELECT run_id, file_path FROM replays
             WHERE file_deleted_at IS NULL AND created_at < ? AND (status = ? OR (status = ?
               AND json_valid(result) AND json_extract(result, '$.unverifiable') = 1))
             ORDER BY created_at, run_id LIMIT ?",
        )
        .bind(before)
        .bind(status::SET_ASIDE)
        .bind(status::FAILED)
        .bind(PURGE_BATCH)
        .fetch_all(db)
        .await?;
        if rows.is_empty() {
            return Ok(total);
        }
        for (run_id, file) in &rows {
            sqlx::query(
                "UPDATE replays SET status = ?, file_deleted_at = ?,
                   result = json_set(CASE WHEN json_valid(result) THEN result ELSE '{}' END,
                                     '$.purged_at', ?)
                 WHERE run_id = ?",
            )
            .bind(status::SET_ASIDE)
            .bind(now)
            .bind(now)
            .bind(run_id)
            .execute(db)
            .await?;
            super::remove_file(Path::new(file)).await;
        }
        total += rows.len() as u64;
    }
}

/// Whether `run_id` ranks within `n` on any board in a **current** period right now (the
/// period containing `now`, or all-time). N10.3: past Daily Drive days, Journey weeks and
/// Loop seasons no longer keep a file (spec: "except for current top-100 entries"), so the
/// kept files stay bounded.
pub async fn in_top(
    conn: &mut SqliteConnection,
    run_id: i64,
    n: u32,
    now: i64,
) -> sqlx::Result<bool> {
    for (board, period, subject) in store::entries_of_run(conn, run_id).await? {
        let current = Board::parse(&board)
            .and_then(|b| b.parse_period(&period))
            .is_some_and(|p| p.kind == PeriodKind::All || Period::at(p.kind, now).key == p.key);
        if !current {
            continue;
        }
        let Some(e) = store::entry(conn, &board, &period, subject).await? else {
            continue;
        };
        let ahead =
            store::count_ahead(conn, &board, &period, e.score, e.achieved_at, subject).await?;
        if ahead < i64::from(n) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Deletes a verified run's replay file unless the run is in a top N. Returns whether
/// the file was deleted.
pub async fn after_verdict(
    db: &SqlitePool,
    cfg: &ReplaysConfig,
    run_id: i64,
    now: i64,
) -> anyhow::Result<bool> {
    let mut conn = db.acquire().await?;
    let row = sqlx::query!(
        "SELECT file_path, status, file_deleted_at FROM replays WHERE run_id = ?",
        run_id
    )
    .fetch_optional(&mut *conn)
    .await?;
    let Some(row) = row else {
        return Ok(false);
    };
    if row.status != status::DONE || row.file_deleted_at.is_some() {
        return Ok(false);
    }
    if in_top(&mut conn, run_id, cfg.keep_top_n, now).await? {
        return Ok(false);
    }
    sqlx::query!(
        "UPDATE replays SET file_deleted_at = ? WHERE run_id = ?",
        now,
        run_id
    )
    .execute(&mut *conn)
    .await?;
    drop(conn);
    super::remove_file(Path::new(&row.file_path)).await;
    tracing::debug!(run_id, "replay file deleted (not in a top list)");
    Ok(true)
}

/// One retention pass (see the module docs).
pub async fn sweep(db: &SqlitePool, cfg: &ReplaysConfig, now: i64) -> anyhow::Result<SweepReport> {
    let mut report = SweepReport::default();
    let done = status::DONE;
    let kept_files = sqlx::query_scalar!(
        r#"SELECT run_id AS "run_id!" FROM replays WHERE status = ? AND file_deleted_at IS NULL
           ORDER BY run_id"#,
        done
    )
    .fetch_all(db)
    .await?;
    for run_id in kept_files {
        if after_verdict(db, cfg, run_id, now).await? {
            report.deleted += 1;
        } else {
            report.kept += 1;
        }
    }
    if cfg.set_aside_retention_days > 0 {
        let before = now - i64::from(cfg.set_aside_retention_days) * SECS_PER_DAY;
        report.set_aside_purged = purge_set_aside(db, before, now).await?;
    }
    report.orphans = remove_orphans(db, cfg).await?;
    Ok(report)
}

/// Files in the replay directory (and its work directory) that no job needs, once they
/// are an hour old (an upload renames its file into place just before its row commits).
async fn remove_orphans(db: &SqlitePool, cfg: &ReplaysConfig) -> anyhow::Result<u64> {
    let live: std::collections::HashSet<i64> = sqlx::query_scalar!(
        r#"SELECT run_id AS "run_id!" FROM replays WHERE file_deleted_at IS NULL"#
    )
    .fetch_all(db)
    .await?
    .into_iter()
    .collect();
    let mut removed = 0;
    for dir in [cfg.dir.clone(), super::work_dir(cfg)] {
        let mut entries = match tokio::fs::read_dir(&dir).await {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e.into()),
        };
        while let Some(entry) = entries.next_entry().await? {
            let meta = entry.metadata().await?;
            if !meta.is_file() {
                continue;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            let old = meta
                .modified()
                .ok()
                .and_then(|m| SystemTime::now().duration_since(m).ok())
                .is_some_and(|age| age >= ORPHAN_AGE);
            let orphan = old
                && match name.strip_suffix(".wbr") {
                    Some(id) => id.parse::<i64>().map_or(true, |id| !live.contains(&id)),
                    None => name.ends_with(".tmp") || name.ends_with(".json"),
                };
            if orphan {
                super::remove_file(&path).await;
                removed += 1;
            }
        }
    }
    Ok(removed)
}

/// The periodic sweep, every `cleanup_interval_secs` until `shutdown`.
pub async fn periodic(
    db: SqlitePool,
    cfg: ReplaysConfig,
    clock: std::sync::Arc<dyn Clock>,
    metrics: std::sync::Arc<Metrics>,
    shutdown: CancellationToken,
) {
    let mut tick = tokio::time::interval(Duration::from_secs(cfg.cleanup_interval_secs));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = shutdown.cancelled() => return,
            _ = tick.tick() => {}
        }
        match sweep(&db, &cfg, clock.now()).await {
            Ok(r) if r.deleted + r.orphans + r.set_aside_purged > 0 => {
                metrics.count_deleted("replays_set_aside", r.set_aside_purged);
                tracing::info!(
                    deleted = r.deleted,
                    kept = r.kept,
                    orphans = r.orphans,
                    set_aside_purged = r.set_aside_purged,
                    "replay retention sweep"
                );
            }
            Ok(_) => {}
            Err(e) => tracing::warn!(error = %e, "replay retention sweep failed"),
        }
    }
}
