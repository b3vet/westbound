//! Housekeeping on the data volume (N10.3). The owner's server has a small disk ("keep at
//! most 3 daily backups"), so everything the server writes under `/data` is capped.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Resource budget and deployment" (nightly
//! backups on the volume), "Data model (SQLite)"; docs/OPERATIONS.md → Disk space;
//! docs/SERVER.md → "Housekeeping (N10.3)".
//!
//! - **The disk check** (every `housekeeping.check_interval_secs`): what the database, its
//!   WAL, the replays, the backups and the rest of the data directory take, the volume's
//!   free space (`wb_disk_*`); below `min_free_mb` a warning and `wb_disk_low` (the nightly
//!   backup then skips and replay uploads answer 503); the newest backup's age
//!   (`wb_backup_stale` past `backup.max_age_hours`, with a warning); a
//!   `PRAGMA wal_checkpoint(TRUNCATE)` so the WAL file does not stay large.
//! - **The daily pass** (`housekeeping.time_utc`, after the nightly backup; also
//!   `admin housekeeping`): deletes, in batches of `batch_rows` with a pause between them,
//!   `shadow_contacts` rows, `admin_log` rows and handled reports past their retention,
//!   expired crew invites,
//!   leaderboard entries of Daily Drive days and Journey weeks that ended long ago, and runs
//!   that hold no entry any more; prunes the dated backups to their count and ages out
//!   other copies (manual backups, restore leftovers, stray `.tmp`); removes an expired
//!   room handover file; and runs `VACUUM` when a large share of the file is free pages
//!   and the volume has room for it.
//!
//! Replay files have their own sweep (`replays::retention`); expired refresh tokens are
//! dropped hourly (`app::maintenance`).

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use sqlx::SqlitePool;

use crate::app::AppState;
use crate::backup;
use crate::clock::SECS_PER_DAY;
use crate::config::{parse_hh_mm, Config, HousekeepingConfig};
use crate::leaderboards::{Board, Period, PeriodKind};
use crate::metrics::Metrics;

/// A warning that still holds (low disk, stale backup) is repeated this often.
const REWARN_SECS: i64 = 6 * 3_600;
/// Directory depth the disk walk follows (the data volume is shallow).
const MAX_WALK_DEPTH: usize = 8;
const PCT: u64 = 100;
/// VACUUM needs room for a second copy of the database (and its WAL) meanwhile.
const VACUUM_COPIES: u64 = 2;

/// Space on the filesystem that holds a path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct VolumeSpace {
    /// Free for an unprivileged user (the server runs as uid 65532).
    pub free_bytes: u64,
    pub total_bytes: u64,
}

/// The filesystem holding `path`, or its nearest existing ancestor (a directory not made
/// yet). `None` off Unix or when nothing can be read.
pub fn volume_space(path: &Path) -> Option<VolumeSpace> {
    let mut at = Some(path);
    while let Some(p) = at {
        let p = if p.as_os_str().is_empty() {
            Path::new(".")
        } else {
            p
        };
        if p.exists() {
            return statvfs(p);
        }
        at = p.parent();
    }
    None
}

/// Free bytes on the filesystem holding `path` (see [`volume_space`]).
pub fn free_bytes(path: &Path) -> Option<u64> {
    volume_space(path).map(|v| v.free_bytes)
}

#[cfg(unix)]
fn statvfs(p: &Path) -> Option<VolumeSpace> {
    let s = rustix::fs::statvfs(p).ok()?;
    Some(VolumeSpace {
        free_bytes: s.f_bavail.saturating_mul(s.f_frsize),
        total_bytes: s.f_blocks.saturating_mul(s.f_frsize),
    })
}

#[cfg(not(unix))]
fn statvfs(_: &Path) -> Option<VolumeSpace> {
    None
}

/// What the server's files take on the data volume (the `disk` section of the admin
/// stats, `admin stats`, the `wb_disk_*` gauges).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct DiskUsage {
    /// The data directory: the database file's directory (`/data`).
    pub data_dir: String,
    /// The volume (`None` when it cannot be read).
    pub free_bytes: Option<u64>,
    pub total_bytes: Option<u64>,
    /// `housekeeping.min_free_mb`, and whether free space is below it.
    pub min_free_bytes: u64,
    pub low: bool,
    pub db_bytes: u64,
    pub wal_bytes: u64,
    pub shm_bytes: u64,
    /// `replays.dir` (with its `work/`).
    pub replays_bytes: u64,
    pub replays_files: u64,
    /// `backup.dir` (every file in it).
    pub backups_bytes: u64,
    /// Everything under the data directory.
    pub data_bytes: u64,
    /// The data directory less the database, replays and backups: restore leftovers, the
    /// handover file, tools such as an off-site `rclone`.
    pub other_bytes: u64,
}

/// Walks `dir` (not following links), calling `f(path, bytes)` for each regular file.
fn walk(dir: &Path, depth: usize, f: &mut dyn FnMut(&Path, u64)) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        let path = entry.path();
        if kind.is_dir() && depth < MAX_WALK_DEPTH {
            walk(&path, depth + 1, f);
        } else if kind.is_file() {
            f(&path, entry.metadata().map_or(0, |m| m.len()));
        }
    }
}

fn file_len(p: &Path) -> u64 {
    std::fs::metadata(p).map_or(0, |m| m.len())
}

fn sibling(db: &Path, suffix: &str) -> PathBuf {
    let mut s = db.as_os_str().to_owned();
    s.push(suffix);
    s.into()
}

/// The database's directory (`.` for a bare file name).
pub fn data_dir(cfg: &Config) -> PathBuf {
    match cfg.db.path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => PathBuf::from("."),
    }
}

/// Reads the sizes (a walk of the data directory, and of the replay and backup
/// directories when they live elsewhere) and the volume's free space. Blocking: call it
/// from `spawn_blocking` in the server.
pub fn disk_usage(cfg: &Config) -> DiskUsage {
    let data = data_dir(cfg);
    let db = cfg.db.path.clone();
    let (wal, shm) = (sibling(&db, "-wal"), sibling(&db, "-shm"));
    let replays = cfg.replays.dir.clone();
    let backups = cfg.backup.dir.clone();
    let mut u = DiskUsage {
        data_dir: data.display().to_string(),
        min_free_bytes: cfg.housekeeping.min_free_bytes(),
        db_bytes: file_len(&db),
        wal_bytes: file_len(&wal),
        shm_bytes: file_len(&shm),
        ..DiskUsage::default()
    };
    let (mut in_replays, mut in_backups, mut in_db) = (0u64, 0u64, 0u64);
    walk(&data, 0, &mut |p, n| {
        u.data_bytes += n;
        if p.starts_with(&replays) {
            in_replays += n;
            u.replays_files += 1;
        } else if p.starts_with(&backups) {
            in_backups += n;
        } else if p == db.as_path() || p == wal.as_path() || p == shm.as_path() {
            in_db += n;
        }
    });
    u.replays_bytes = in_replays;
    u.backups_bytes = in_backups;
    u.other_bytes = u.data_bytes.saturating_sub(in_replays + in_backups + in_db);
    if !replays.starts_with(&data) {
        walk(&replays, 0, &mut |_, n| {
            u.replays_bytes += n;
            u.replays_files += 1;
        });
    }
    if !backups.starts_with(&data) {
        walk(&backups, 0, &mut |_, n| u.backups_bytes += n);
    }
    if let Some(v) = volume_space(&data) {
        u.free_bytes = Some(v.free_bytes);
        u.total_bytes = Some(v.total_bytes);
        u.low = v.free_bytes < u.min_free_bytes;
    }
    u
}

/// What a daily pass did.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct DailyReport {
    /// Rows deleted.
    pub shadow_contacts: u64,
    pub admin_log: u64,
    pub reports: u64,
    pub leaderboard_entries: u64,
    pub runs: u64,
    /// Expired crew invites.
    pub crew_invites: u64,
    /// Dated backups beyond `backup.retention_days`, and other copies aged out.
    pub backups_removed: u64,
    pub other_files_removed: u64,
    /// An expired `room-handover.json` was deleted.
    pub handover_removed: bool,
    /// `VACUUM` ran: the database's size before and after.
    pub vacuum: Option<(u64, u64)>,
    /// Steps that failed (the others still ran).
    pub errors: Vec<String>,
}

impl DailyReport {
    /// One line for the log, the admin log and the CLI.
    pub fn summary(&self) -> String {
        let vacuum = self
            .vacuum
            .map_or("no".to_string(), |(b, a)| format!("{b}->{a}"));
        format!(
            "shadow_contacts={} admin_log={} reports={} leaderboard_entries={} runs={} \
             crew_invites={} backups_removed={} other_files_removed={} handover_removed={} \
             vacuum={vacuum} errors={}",
            self.shadow_contacts,
            self.admin_log,
            self.reports,
            self.leaderboard_entries,
            self.runs,
            self.crew_invites,
            self.backups_removed,
            self.other_files_removed,
            self.handover_removed,
            self.errors.len()
        )
    }

    /// Adds the pass to the metrics.
    pub fn record(&self, m: &Metrics, now: i64) {
        for (table, n) in [
            ("shadow_contacts", self.shadow_contacts),
            ("admin_log", self.admin_log),
            ("reports", self.reports),
            ("leaderboard_entries", self.leaderboard_entries),
            ("runs", self.runs),
            ("crew_invites", self.crew_invites),
        ] {
            m.count_deleted(table, n);
        }
        if self.vacuum.is_some() {
            Metrics::inc(&m.db_vacuums);
        }
        Metrics::add(&m.housekeeping_failures, self.errors.len() as u64);
        Metrics::set(&m.housekeeping_last_unix, u64::try_from(now).unwrap_or(0));
    }
}

/// The cutoff (unix seconds) `days` before `now`; `None` for 0 (keep).
fn cutoff(now: i64, days: u32) -> Option<i64> {
    (days > 0).then(|| now - i64::from(days) * SECS_PER_DAY)
}

/// Runs `sql` (binds: `?1` the cutoff, `?2` the batch size) until it deletes less than a
/// batch; pauses between full batches.
async fn delete_batches(
    db: &SqlitePool,
    h: &HousekeepingConfig,
    sql: &'static str,
    cutoff: i64,
) -> sqlx::Result<u64> {
    let mut total = 0;
    loop {
        let n = sqlx::query(sql)
            .bind(cutoff)
            .bind(i64::from(h.batch_rows))
            .execute(db)
            .await?
            .rows_affected();
        total += n;
        if n < u64::from(h.batch_rows) {
            return Ok(total);
        }
        tokio::time::sleep(Duration::from_millis(h.batch_pause_ms)).await;
    }
}

/// Leaderboard entries of Daily Drive days and Journey weeks that ended more than
/// `days` ago (the period containing that day and later ones stay). Seasons and all-time
/// boards are kept.
async fn prune_board_periods(
    db: &SqlitePool,
    h: &HousekeepingConfig,
    now: i64,
) -> sqlx::Result<u64> {
    if h.board_periods_days == 0 {
        return Ok(0);
    }
    let day = now.div_euclid(SECS_PER_DAY) - i64::from(h.board_periods_days);
    let mut total = 0;
    for (board, kind) in [
        (Board::Daily, PeriodKind::Day),
        (Board::Journey, PeriodKind::Week),
    ] {
        let keep_from = Period::containing(kind, day).key;
        loop {
            let n = sqlx::query(
                "DELETE FROM leaderboard_entries WHERE (board, period_key, subject_id) IN (
                     SELECT board, period_key, subject_id FROM leaderboard_entries
                     WHERE board = ?1 AND period_key < ?2 AND period_key <> 'all' LIMIT ?3)",
            )
            .bind(board.id())
            .bind(&keep_from)
            .bind(i64::from(h.batch_rows))
            .execute(db)
            .await?
            .rows_affected();
            total += n;
            if n < u64::from(h.batch_rows) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(h.batch_pause_ms)).await;
        }
    }
    Ok(total)
}

/// Runs older than `runs_days` that no leaderboard entry holds, walking the table by id
/// in batches. Kept whatever their age: legacy uploads (their uniqueness is the
/// once-per-board rule), runs still waiting for their replay (`pending`), and runs whose
/// replay file is still there (a set-aside or kept replay).
async fn prune_runs(db: &SqlitePool, h: &HousekeepingConfig, now: i64) -> sqlx::Result<u64> {
    let Some(before) = cutoff(now, h.runs_days) else {
        return Ok(0);
    };
    let mut after = 0i64;
    let mut total = 0;
    loop {
        let ids: Vec<(i64, i64)> =
            sqlx::query_as("SELECT id, created_at FROM runs WHERE id > ? ORDER BY id LIMIT ?")
                .bind(after)
                .bind(i64::from(h.batch_rows))
                .fetch_all(db)
                .await?;
        let Some(&(last, last_at)) = ids.last() else {
            return Ok(total);
        };
        let n = sqlx::query(
            "DELETE FROM runs WHERE id > ?1 AND id <= ?2 AND created_at < ?3
               AND mode <> 'legacy' AND verification <> 'pending'
               AND NOT EXISTS (SELECT 1 FROM leaderboard_entries e WHERE e.run_id = runs.id)
               AND NOT EXISTS (SELECT 1 FROM replays p
                               WHERE p.run_id = runs.id AND p.file_deleted_at IS NULL)",
        )
        .bind(after)
        .bind(last)
        .bind(before)
        .execute(db)
        .await?
        .rows_affected();
        total += n;
        // Ids grow with time: a batch ending in a recent run is the last one to look at.
        if last_at >= before || ids.len() < h.batch_rows as usize {
            return Ok(total);
        }
        after = last;
        if n > 0 {
            tokio::time::sleep(Duration::from_millis(h.batch_pause_ms)).await;
        }
    }
}

/// `VACUUM` when at least `vacuum_min_free_pct` of the file is free pages, the file is at
/// most `vacuum_max_mb`, and the volume has room for two copies plus the floor. Returns
/// the size before and after, or `None` when it was not worth it (or not safe).
pub async fn maybe_vacuum(db: &SqlitePool, cfg: &Config) -> anyhow::Result<Option<(u64, u64)>> {
    let h = &cfg.housekeeping;
    if h.vacuum_min_free_pct == 0 {
        return Ok(None);
    }
    let (pages, free_pages, bytes) = db_size(db).await?;
    if pages == 0 || free_pages * PCT < u64::from(h.vacuum_min_free_pct) * pages {
        return Ok(None);
    }
    if bytes > h.vacuum_max_mb.saturating_mul(crate::config::BYTES_PER_MB) {
        tracing::info!(
            db_bytes = bytes,
            free_pages,
            "housekeeping: database over housekeeping.vacuum_max_mb, not vacuumed"
        );
        return Ok(None);
    }
    let need = bytes
        .saturating_mul(VACUUM_COPIES)
        .saturating_add(h.min_free_bytes());
    if free_bytes(&cfg.db.path).is_some_and(|free| free < need) {
        tracing::warn!(
            db_bytes = bytes,
            need,
            "housekeeping: not enough free space to VACUUM the database"
        );
        return Ok(None);
    }
    sqlx::query("VACUUM").execute(db).await?;
    checkpoint(db).await?;
    let (_, _, after) = db_size(db).await?;
    Ok(Some((bytes, after)))
}

/// Pages, free pages and bytes of the database file.
async fn db_size(db: &SqlitePool) -> sqlx::Result<(u64, u64, u64)> {
    let pages: i64 = sqlx::query_scalar("PRAGMA page_count")
        .fetch_one(db)
        .await?;
    let free: i64 = sqlx::query_scalar("PRAGMA freelist_count")
        .fetch_one(db)
        .await?;
    let page: i64 = sqlx::query_scalar("PRAGMA page_size").fetch_one(db).await?;
    let (pages, free, page) = (
        u64::try_from(pages).unwrap_or(0),
        u64::try_from(free).unwrap_or(0),
        u64::try_from(page).unwrap_or(0),
    );
    Ok((pages, free, pages.saturating_mul(page)))
}

/// `PRAGMA wal_checkpoint(TRUNCATE)`: copies the WAL into the database and truncates it
/// (it cannot while a reader holds an older snapshot; the next check tries again).
/// Returns whether it completed.
pub async fn checkpoint(db: &SqlitePool) -> sqlx::Result<bool> {
    let (busy, _log, _done): (i64, i64, i64) = sqlx::query_as("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_one(db)
        .await?;
    Ok(busy == 0)
}

/// Deletes `room-handover.json` once it has expired (a restart writes a fresh one).
async fn prune_handover(db_path: &Path, now: i64) -> anyhow::Result<bool> {
    let path = crate::handover::path_for(db_path);
    match crate::handover::load(&path).await {
        Some(h) if now >= h.expires_at => {
            tokio::fs::remove_file(&path).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

/// The files part of the daily pass (also run once when the server starts, so a lower
/// `backup.retention_days` takes effect at the deploy): dated backups beyond the count
/// (only with backups on), other copies past `backup.other_retention_days`.
pub fn prune_files(cfg: &Config, now: i64, report: &mut DailyReport) {
    let b = &cfg.backup;
    if b.enabled && b.dir.is_dir() {
        match backup::prune(&b.dir, b.retention_days, None) {
            Ok(r) => report.backups_removed += r.len() as u64,
            Err(e) => report.errors.push(format!("pruning backups: {e}")),
        }
    }
    match backup::prune_other(&b.dir, &cfg.db.path, b.other_retention_days, now) {
        Ok(r) => report.other_files_removed += r.len() as u64,
        Err(e) => report.errors.push(format!("pruning other copies: {e}")),
    }
}

/// The daily pass (see the module docs). Every step runs even when another failed; the
/// failures are in `errors`.
pub async fn run_daily(db: &SqlitePool, cfg: &Config, now: i64) -> DailyReport {
    let h = &cfg.housekeeping;
    let mut r = DailyReport::default();
    let tables: [(&str, &'static str, u32, &mut u64); 3] = [
        (
            "shadow_contacts",
            "DELETE FROM shadow_contacts WHERE id IN
               (SELECT id FROM shadow_contacts WHERE created_at < ?1 ORDER BY created_at LIMIT ?2)",
            h.shadow_contacts_days,
            &mut r.shadow_contacts,
        ),
        (
            "admin_log",
            "DELETE FROM admin_log WHERE id IN
               (SELECT id FROM admin_log WHERE created_at < ?1 ORDER BY created_at LIMIT ?2)",
            h.admin_log_days,
            &mut r.admin_log,
        ),
        (
            "reports",
            "DELETE FROM reports WHERE id IN
               (SELECT id FROM reports WHERE handled = 1 AND created_at < ?1 LIMIT ?2)",
            h.reports_days,
            &mut r.reports,
        ),
    ];
    let mut errors = Vec::new();
    for (table, sql, days, out) in tables {
        let Some(before) = cutoff(now, days) else {
            continue;
        };
        match delete_batches(db, h, sql, before).await {
            Ok(n) => *out = n,
            Err(e) => errors.push(format!("pruning {table}: {e}")),
        }
    }
    r.errors.append(&mut errors);
    match prune_board_periods(db, h, now).await {
        Ok(n) => r.leaderboard_entries = n,
        Err(e) => r.errors.push(format!("pruning leaderboard periods: {e}")),
    }
    match prune_runs(db, h, now).await {
        Ok(n) => r.runs = n,
        Err(e) => r.errors.push(format!("pruning runs: {e}")),
    }
    // Expired crew invites (every read ignores them already; no retention to configure).
    match delete_batches(
        db,
        h,
        "DELETE FROM crew_invites WHERE id IN
           (SELECT id FROM crew_invites WHERE expires_at <= ?1 LIMIT ?2)",
        now,
    )
    .await
    {
        Ok(n) => r.crew_invites = n,
        Err(e) => r.errors.push(format!("pruning crew invites: {e}")),
    }
    prune_files(cfg, now, &mut r);
    match prune_handover(&cfg.db.path, now).await {
        Ok(removed) => r.handover_removed = removed,
        Err(e) => r.errors.push(format!("removing the room handover: {e:#}")),
    }
    match maybe_vacuum(db, cfg).await {
        Ok(v) => r.vacuum = v,
        Err(e) => r.errors.push(format!("vacuum: {e:#}")),
    }
    r
}

/// Warnings already given (repeated every `REWARN_SECS` while they hold).
#[derive(Debug, Default)]
struct Watch {
    low_since: Option<i64>,
    low_warned: i64,
    stale_since: Option<i64>,
    stale_warned: i64,
}

/// One disk check: sizes and free space, the backups' freshness, a WAL checkpoint.
async fn check_once(state: &AppState, now: i64, watch: &mut Watch) {
    let cfg = state.config.clone();
    let m = &state.metrics;
    let usage = tokio::task::spawn_blocking({
        let cfg = cfg.clone();
        move || disk_usage(&cfg)
    })
    .await;
    if let Ok(u) = usage {
        Metrics::set(&m.disk_free_bytes, u.free_bytes.unwrap_or(0));
        Metrics::set(&m.disk_total_bytes, u.total_bytes.unwrap_or(0));
        Metrics::set(&m.disk_low, u64::from(u.low));
        Metrics::set(&m.disk_data_bytes, u.data_bytes);
        Metrics::set(&m.disk_replays_bytes, u.replays_bytes);
        Metrics::set(&m.disk_replays_files, u.replays_files);
        Metrics::set(&m.disk_backups_bytes, u.backups_bytes);
        Metrics::set(&m.disk_other_bytes, u.other_bytes);
        if u.low {
            if watch.low_since.is_none() || now - watch.low_warned >= REWARN_SECS {
                tracing::warn!(
                    free_bytes = u.free_bytes.unwrap_or(0),
                    min_free_bytes = u.min_free_bytes,
                    db_bytes = u.db_bytes + u.wal_bytes,
                    replays_bytes = u.replays_bytes,
                    backups_bytes = u.backups_bytes,
                    other_bytes = u.other_bytes,
                    "disk space low on the data volume: backups skip and replay uploads wait \
                     until there is room (docs/OPERATIONS.md → Disk space)"
                );
                watch.low_warned = now;
            }
            watch.low_since.get_or_insert(now);
        } else if watch.low_since.take().is_some() {
            tracing::info!(
                free_bytes = u.free_bytes.unwrap_or(0),
                "disk space on the data volume is back above the floor"
            );
        }
    }
    if cfg.backup.enabled {
        let (dir, max_age) = (cfg.backup.dir.clone(), cfg.backup.max_age_hours);
        let status = tokio::task::spawn_blocking(move || backup::status(&dir, now, max_age)).await;
        if let Ok(Ok(s)) = status {
            let newest = s.files.iter().map(|f| f.modified_unix).max().unwrap_or(0);
            Metrics::set(&m.backup_files, s.files.len() as u64);
            Metrics::set(&m.backup_newest_unix, u64::try_from(newest).unwrap_or(0));
            Metrics::set(
                &m.backup_newest_age_secs,
                s.newest_age_secs
                    .map_or(0, |a| u64::try_from(a).unwrap_or(0)),
            );
            // No backup at all is stale only once the server has been up that long (a
            // fresh volume waits for its first night).
            let up_long = state.started.elapsed().as_secs() > max_age.saturating_mul(3_600);
            let stale = s.stale && (s.newest_age_secs.is_some() || up_long);
            Metrics::set(&m.backup_stale, u64::from(stale));
            if stale {
                if watch.stale_since.is_none() || now - watch.stale_warned >= REWARN_SECS {
                    tracing::warn!(
                        newest = s.newest().map_or("none", |f| f.name.as_str()),
                        age_secs = s.newest_age_secs.unwrap_or(-1),
                        max_age_hours = max_age,
                        "the newest backup is stale: check the nightly backup's log lines \
                         (`nightly backup failed` / `skipped`)"
                    );
                    watch.stale_warned = now;
                }
                watch.stale_since.get_or_insert(now);
            } else {
                watch.stale_since = None;
            }
        }
    }
    match checkpoint(&state.db).await {
        Ok(_) => Metrics::inc(&m.db_wal_checkpoints),
        Err(e) => tracing::debug!(error = %e, "wal checkpoint failed"),
    }
    Metrics::set(&m.db_wal_bytes, file_len(&sibling(&cfg.db.path, "-wal")));
}

/// The daily pass inside the server: the report into the metrics, the log and the admin
/// log; the board cache dropped when entries went.
async fn daily(state: &AppState, now: i64) {
    let report = run_daily(&state.db, &state.config, now).await;
    report.record(&state.metrics, now);
    if report.leaderboard_entries > 0 {
        state.boards.invalidate_all();
    }
    for e in &report.errors {
        tracing::warn!(error = %e, "housekeeping step failed");
    }
    tracing::info!(summary = %report.summary(), "housekeeping pass");
    if let Err(e) =
        crate::db::admin_log(&state.db, "system", "housekeeping", "", &report.summary()).await
    {
        tracing::warn!(error = %e, "housekeeping: admin_log not written");
    }
}

/// The disk check every `check_interval_secs` and the daily pass at `time_utc`, until
/// shutdown. The first check runs at once, with the file prunes.
pub async fn periodic(state: AppState) {
    let h = state.config.housekeeping.clone();
    let Some(minutes) = parse_hh_mm(&h.time_utc) else {
        return;
    };
    let mut next_daily = backup::next_run_after(state.clock.now(), minutes);
    let mut tick = tokio::time::interval(Duration::from_secs(h.check_interval_secs));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut watch = Watch::default();
    let mut first = true;
    loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => return,
            _ = tick.tick() => {}
        }
        let now = state.clock.now();
        if first {
            first = false;
            let mut r = DailyReport::default();
            let cfg = state.config.clone();
            let r = tokio::task::spawn_blocking(move || {
                prune_files(&cfg, now, &mut r);
                r
            })
            .await
            .unwrap_or_default();
            if r.backups_removed + r.other_files_removed > 0 {
                tracing::info!(
                    backups_removed = r.backups_removed,
                    other_files_removed = r.other_files_removed,
                    "housekeeping: old backups pruned at startup"
                );
            }
            for e in &r.errors {
                tracing::warn!(error = %e, "housekeeping step failed");
            }
            Metrics::add(&state.metrics.housekeeping_failures, r.errors.len() as u64);
        }
        check_once(&state, now, &mut watch).await;
        if now >= next_daily {
            daily(&state, now).await;
            next_daily = backup::next_run_after(now, minutes);
        }
    }
}
