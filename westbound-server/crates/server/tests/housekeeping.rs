//! N10.3 housekeeping on the data volume: the daily pass's row retention (shadow
//! contacts, the admin log, handled reports, past Daily Drive days and Journey weeks,
//! runs without entries and what they must keep), batches, VACUUM when worth it, the file
//! prunes and the handover file, and the server's disk check (sizes, free space, the low
//! flag, the stale backup, the startup prune) on `/metrics` and `/admin/stats`.
//! docs/SERVER.md → "Housekeeping (N10.3)".

mod common;

use std::time::{Duration, SystemTime};

use common::*;
use westbound_server::clock::SECS_PER_DAY;
use westbound_server::housekeeping::{self, DailyReport};
use westbound_server::leaderboards::{Period, PeriodKind};
use westbound_server::metrics::Metrics;

const DAY: i64 = SECS_PER_DAY;

async fn exec(app: &TestApp, sql: String) {
    sqlx::query(sqlx::AssertSqlSafe(sql))
        .execute(app.db())
        .await
        .unwrap();
}

async fn count(app: &TestApp, sql: &'static str) -> i64 {
    sqlx::query_scalar(sql).fetch_one(app.db()).await.unwrap()
}

fn set_mtime(path: &std::path::Path, age: Duration) {
    std::fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(SystemTime::now() - age)
        .unwrap();
}

/// A run row (`created_at` as given) for `account`.
async fn run_row(app: &TestApp, id: i64, account: i64, mode: &str, verification: &str, at: i64) {
    let legacy = (mode == "legacy").then_some("journey");
    sqlx::query(
        "INSERT INTO runs (id, account_id, mode, map_or_seed, date, score, distance_m,
                           duration_s, verification, legacy_board, created_at)
         VALUES (?, ?, ?, '7', '2026-01-01', 100, 1000, 60, ?, ?, ?)",
    )
    .bind(id)
    .bind(account)
    .bind(mode)
    .bind(verification)
    .bind(legacy)
    .bind(at)
    .execute(app.db())
    .await
    .unwrap();
}

async fn entry(app: &TestApp, board: &str, period: &str, subject: i64, run: Option<i64>) {
    sqlx::query(
        "INSERT INTO leaderboard_entries (board, period_key, subject_id, account_id, run_id,
                                          score, achieved_at, verification, run_date)
         VALUES (?, ?, ?, NULL, ?, 100, 1, 'verified', '2026-01-01')",
    )
    .bind(board)
    .bind(period)
    .bind(subject)
    .bind(run)
    .execute(app.db())
    .await
    .unwrap();
}

#[tokio::test]
async fn the_daily_pass_prunes_rows_past_their_retention_in_batches() {
    let app = app_with(|c| {
        // Small batches: every table takes several statements.
        c.housekeeping.batch_rows = 2;
        c.housekeeping.batch_pause_ms = 0;
    })
    .await;
    let now = T0;
    // Shadow contacts: 5 older than 30 days, 2 recent.
    for (i, age) in [31, 40, 50, 60, 90, 29, 1].iter().enumerate() {
        sqlx::query(
            "INSERT INTO shadow_contacts (room_id, tick, player_a, player_b, speed,
                 disagreement_m, closing_mps, depth_m, ticks, created_at)
             VALUES (1, ?, 1, 2, 30, 0.1, 1, 0.2, 3, ?)",
        )
        .bind(i as i64)
        .bind(now - age * DAY)
        .execute(app.db())
        .await
        .unwrap();
    }
    // Admin log: 3 older than a year, 1 recent.
    for age in [400, 500, 366, 10] {
        sqlx::query(
            "INSERT INTO admin_log (actor, action, target, detail, created_at)
             VALUES ('cli', 'ban', '1', '', ?)",
        )
        .bind(now - age * DAY)
        .execute(app.db())
        .await
        .unwrap();
    }
    // Reports: old handled (goes), old unhandled (stays), recent handled (stays).
    for (handled, age) in [(1, 400), (0, 400), (1, 10)] {
        sqlx::query("INSERT INTO reports (reason, created_at, handled) VALUES ('other', ?, ?)")
            .bind(now - age * DAY)
            .bind(handled)
            .execute(app.db())
            .await
            .unwrap();
    }
    // Board periods: Daily days and Journey weeks older than 90 days go; recent ones,
    // seasons and all-time stay.
    let today = now.div_euclid(DAY);
    let day_key = |d: i64| Period::containing(PeriodKind::Day, today - d).key;
    let week_key = |d: i64| Period::containing(PeriodKind::Week, today - d).key;
    for s in 1..=3 {
        entry(&app, "daily", &day_key(200), s, None).await;
        entry(&app, "journey", &week_key(200), s, None).await;
    }
    entry(&app, "daily", &day_key(60), 1, None).await;
    entry(&app, "journey", &week_key(60), 1, None).await;
    entry(&app, "journey", "all", 1, None).await;
    entry(&app, "loop", "2020-01", 1, None).await;
    entry(&app, "distance", "all", 999, None).await;

    // Runs older than 90 days: only the ones nothing needs go.
    let (acc, _) = app.account().await;
    let old = now - 200 * DAY;
    run_row(&app, 1, acc, "journey", "verified", old).await; // goes
    run_row(&app, 2, acc, "journey", "rejected", old).await; // goes
    run_row(&app, 3, acc, "journey", "verified", old).await; // holds an entry
    run_row(&app, 4, acc, "legacy", "legacy", old).await; // legacy: once per board
    run_row(&app, 5, acc, "journey", "pending", old).await; // waits for its replay
    run_row(&app, 6, acc, "journey", "verified", old).await; // its replay file is kept
    run_row(&app, 7, acc, "journey", "verified", old).await; // replay row, file gone: goes
    run_row(&app, 8, acc, "daily", "unverified", old).await; // goes
    run_row(&app, 9, acc, "journey", "verified", now - 10 * DAY).await; // recent
    entry(&app, "distance", "all", acc, Some(3)).await;
    for (run, deleted) in [(6, None), (7, Some(now))] {
        sqlx::query(
            "INSERT INTO replays (run_id, file_path, status, created_at, file_deleted_at)
             VALUES (?, '/nowhere.wbr', 'done', ?, ?)",
        )
        .bind(run)
        .bind(old)
        .bind(deleted)
        .execute(app.db())
        .await
        .unwrap();
    }

    let r = housekeeping::run_daily(app.db(), &app.state.config, now).await;
    assert!(r.errors.is_empty(), "{r:?}");
    assert_eq!(r.shadow_contacts, 5, "{r:?}");
    assert_eq!(r.admin_log, 3, "{r:?}");
    assert_eq!(r.reports, 1, "{r:?}");
    assert_eq!(r.leaderboard_entries, 6, "{r:?}");
    assert_eq!(r.runs, 4, "{r:?}");
    assert_eq!(count(&app, "SELECT COUNT(*) FROM shadow_contacts").await, 2);
    assert_eq!(count(&app, "SELECT COUNT(*) FROM admin_log").await, 1);
    assert_eq!(count(&app, "SELECT COUNT(*) FROM reports").await, 2);
    assert_eq!(
        count(&app, "SELECT COUNT(*) FROM reports WHERE handled = 0").await,
        1
    );
    assert_eq!(
        count(&app, "SELECT COUNT(*) FROM leaderboard_entries").await,
        6
    );
    let left: Vec<i64> = sqlx::query_scalar("SELECT id FROM runs ORDER BY id")
        .fetch_all(app.db())
        .await
        .unwrap();
    assert_eq!(left, vec![3, 4, 5, 6, 9]);
    assert_eq!(
        count(&app, "SELECT COUNT(*) FROM replays").await,
        1,
        "the let-go replay row went with its run"
    );
    // The summary and the metrics.
    let s = r.summary();
    assert!(
        s.contains("shadow_contacts=5") && s.contains("runs=4"),
        "{s}"
    );
    let m = Metrics::default();
    r.record(&m, now);
    assert_eq!(m.deleted("runs"), 4);
    assert_eq!(m.deleted("leaderboard_entries"), 6);
    assert_eq!(Metrics::get(&m.housekeeping_last_unix), now as u64);
    let text = m.render("0", "t");
    assert!(
        text.contains("wb_housekeeping_rows_deleted_total{table=\"shadow_contacts\"} 5"),
        "{text}"
    );
    // Nothing left to do.
    let again = housekeeping::run_daily(app.db(), &app.state.config, now).await;
    assert_eq!(
        (again.shadow_contacts, again.admin_log, again.reports),
        (0, 0, 0)
    );
    assert_eq!((again.leaderboard_entries, again.runs), (0, 0));
}

#[tokio::test]
async fn zero_retention_keeps_the_rows() {
    let app = app_with(|c| {
        let h = &mut c.housekeeping;
        h.shadow_contacts_days = 0;
        h.admin_log_days = 0;
        h.reports_days = 0;
        h.board_periods_days = 0;
        h.runs_days = 0;
    })
    .await;
    let old = T0 - 5_000 * DAY;
    exec(
        &app,
        format!(
            "INSERT INTO shadow_contacts (room_id, tick, player_a, player_b, speed,
                 disagreement_m, closing_mps, depth_m, ticks, created_at)
             VALUES (1, 1, 1, 2, 30, 0.1, 1, 0.2, 3, {old})"
        ),
    )
    .await;
    entry(&app, "daily", "2000-01-01", 1, None).await;
    let (acc, _) = app.account().await;
    run_row(&app, 1, acc, "journey", "verified", old).await;
    let r = housekeeping::run_daily(app.db(), &app.state.config, T0).await;
    assert_eq!(r, DailyReport::default());
}

#[tokio::test]
async fn vacuum_runs_only_when_a_large_share_is_free() {
    let app = app_with(|c| {
        c.housekeeping.min_free_mb = 0;
        c.housekeeping.batch_rows = 10_000;
    })
    .await;
    // Nothing free: no VACUUM.
    assert_eq!(
        housekeeping::maybe_vacuum(app.db(), &app.state.config)
            .await
            .unwrap(),
        None
    );
    // Fill, then let the pass delete it all: most of the file is free pages.
    let pad = "x".repeat(200);
    for i in 0..3_000 {
        sqlx::query(
            "INSERT INTO admin_log (actor, action, target, detail, created_at)
             VALUES ('cli', 'x', '', ?, ?)",
        )
        .bind(&pad)
        .bind(i)
        .execute(app.db())
        .await
        .unwrap();
    }
    let r = housekeeping::run_daily(app.db(), &app.state.config, T0).await;
    assert_eq!(r.admin_log, 3_000);
    let (before, after) = r.vacuum.expect("vacuumed");
    assert!(after < before / 2, "{before} -> {after}");
    // And not again.
    let r = housekeeping::run_daily(app.db(), &app.state.config, T0).await;
    assert_eq!(r.vacuum, None);
    // Off (0 %), or a file over the cap: never.
    let mut cfg = (*app.state.config).clone();
    cfg.housekeeping.vacuum_min_free_pct = 0;
    assert_eq!(
        housekeeping::maybe_vacuum(app.db(), &cfg).await.unwrap(),
        None
    );
}

#[tokio::test]
async fn the_pass_prunes_backup_files_and_an_expired_handover() {
    let app = app_with(|c| {
        c.backup.enabled = true;
        c.backup.retention_days = 3;
    })
    .await;
    let cfg = &app.state.config;
    let dir = &cfg.backup.dir;
    std::fs::create_dir_all(dir).unwrap();
    for d in 20..=26 {
        std::fs::write(dir.join(format!("westbound-2026-09-{d}.db")), b"db").unwrap();
    }
    let manual = dir.join("pre-deploy-2026-09-01.db");
    std::fs::write(&manual, b"db").unwrap();
    set_mtime(&manual, Duration::from_secs(8 * 86_400));
    let now = westbound_server::clock::unix_now_secs();
    let handover = westbound_server::handover::path_for(&cfg.db.path);
    westbound_server::handover::save(&handover, &[], now - 1_000, 600)
        .await
        .unwrap();
    let r = housekeeping::run_daily(app.db(), cfg, now).await;
    assert!(r.errors.is_empty(), "{r:?}");
    assert_eq!(r.backups_removed, 4);
    assert_eq!(r.other_files_removed, 1);
    assert!(r.handover_removed);
    assert!(!handover.exists() && !manual.exists());
    let left: Vec<String> = westbound_server::backup::list(dir)
        .unwrap()
        .into_iter()
        .map(|f| f.name)
        .collect();
    assert_eq!(
        left,
        vec![
            "westbound-2026-09-24.db",
            "westbound-2026-09-25.db",
            "westbound-2026-09-26.db"
        ]
    );
    // A fresh handover stays.
    westbound_server::handover::save(&handover, &[], now, 600)
        .await
        .unwrap();
    let r = housekeeping::run_daily(app.db(), cfg, now + 10).await;
    assert!(!r.handover_removed && handover.exists());
}

#[test]
fn disk_usage_sorts_the_data_directory() {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = test_config(&dir);
    cfg.housekeeping.min_free_mb = 0;
    std::fs::write(&cfg.db.path, vec![0u8; 1_000]).unwrap();
    std::fs::write(dir.path().join("test.db-wal"), vec![0u8; 100]).unwrap();
    std::fs::create_dir_all(cfg.replays.dir.join("work")).unwrap();
    std::fs::write(cfg.replays.dir.join("1.wbr"), vec![0u8; 50]).unwrap();
    std::fs::write(cfg.replays.dir.join("work/1.json"), vec![0u8; 5]).unwrap();
    std::fs::create_dir_all(&cfg.backup.dir).unwrap();
    std::fs::write(
        cfg.backup.dir.join("westbound-2026-09-29.db"),
        vec![0u8; 700],
    )
    .unwrap();
    std::fs::write(dir.path().join("test.db.before-restore-1"), vec![0u8; 30]).unwrap();
    let u = housekeeping::disk_usage(&cfg);
    assert_eq!((u.db_bytes, u.wal_bytes), (1_000, 100));
    assert_eq!((u.replays_bytes, u.replays_files), (55, 2));
    assert_eq!(u.backups_bytes, 700);
    assert_eq!(u.other_bytes, 30);
    assert_eq!(u.data_bytes, 1_885);
    assert!(u.free_bytes.unwrap() > 0 && u.total_bytes.unwrap() >= u.free_bytes.unwrap());
    assert!(!u.low);
    cfg.housekeeping.min_free_mb = u64::MAX / (2 * 1_048_576);
    assert!(housekeeping::disk_usage(&cfg).low);
    // A directory not made yet: the nearest existing ancestor's volume.
    assert!(housekeeping::free_bytes(&dir.path().join("a/b/c")).is_some());
}

/// The server's disk check: the gauges, the low flag (replay uploads then wait), the stale
/// backup, and the startup prune of the dated backups; `/admin/stats` has a `disk` section.
#[tokio::test]
async fn the_disk_check_publishes_the_volume_and_flags_problems() {
    let dir = tempfile::tempdir().unwrap();
    let backups = dir.path().join("backups");
    std::fs::create_dir_all(&backups).unwrap();
    for d in 24..=28 {
        let p = backups.join(format!("westbound-2026-09-{d}.db"));
        std::fs::write(&p, b"db").unwrap();
        set_mtime(
            &p,
            Duration::from_secs(u64::try_from(30 - d).unwrap() * 86_400),
        );
    }
    let s = start_in(dir, |c| {
        c.housekeeping.enabled = true;
        c.housekeeping.check_interval_secs = 1;
        // Far more than any disk: the volume is "low".
        c.housekeeping.min_free_mb = u64::MAX / (4 * 1_048_576);
        c.backup.enabled = true;
    })
    .await;
    let m = s.metrics().clone();
    eventually("the disk check ran", || {
        Metrics::get(&m.disk_total_bytes) > 0
            && Metrics::get(&m.backup_files) == 3
            && Metrics::get(&m.db_wal_checkpoints) >= 1
    })
    .await;
    assert_eq!(Metrics::get(&m.disk_low), 1);
    assert!(Metrics::get(&m.disk_backups_bytes) > 0);
    assert_eq!(Metrics::get(&m.backup_stale), 1, "the newest is 2 days old");
    assert!(Metrics::get(&m.backup_newest_age_secs) >= 2 * 86_400 - 60);
    let names: Vec<String> = westbound_server::backup::list(&s.dir.path().join("backups"))
        .unwrap()
        .into_iter()
        .map(|f| f.name)
        .collect();
    assert_eq!(names.len(), 3, "pruned to the count at startup: {names:?}");
    assert_eq!(names[0], "westbound-2026-09-26.db");
    let text = raw_http(
        s.metrics_addr,
        "GET /metrics HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
    )
    .await;
    for line in [
        "wb_disk_low 1",
        "wb_backup_stale 1",
        "wb_backup_files 3",
        "wb_disk_free_bytes ",
        "wb_replay_jobs{status=\"set_aside\"} 0",
        "wb_housekeeping_rows_deleted_total{table=\"runs\"} 0",
    ] {
        assert!(text.contains(line), "{line} missing:\n{text}");
    }
    let stats = raw_http(
        s.metrics_addr,
        "GET /admin/stats HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
    )
    .await;
    let body = stats.split("\r\n\r\n").nth(1).unwrap_or_default();
    let json: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    let disk = &json["disk"];
    assert!(disk["free_bytes"].as_u64().is_some(), "{stats}");
    assert_eq!(disk["low"], true, "{stats}");
    assert_eq!(disk["backup_files"], 3, "{stats}");
    assert_eq!(disk["backups_kept_max"], 3, "{stats}");
    assert_eq!(disk["backup_stale"], true, "{stats}");
    s.stop().await;
}
