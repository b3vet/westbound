//! Database: WAL mode, migrations, online backup and the nightly backup run.

use sqlx::Row;
use westbound_server::config::{BackupConfig, DbConfig};
use westbound_server::{backup, clock, db};

fn db_config(dir: &tempfile::TempDir, name: &str) -> DbConfig {
    DbConfig {
        path: dir.path().join("nested").join(name),
        ..DbConfig::default()
    }
}

async fn tables(pool: &sqlx::SqlitePool) -> Vec<String> {
    sqlx::query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_sqlx%' ORDER BY name")
        .fetch_all(pool)
        .await
        .unwrap()
        .iter()
        .map(|r| r.get::<String, _>(0))
        .collect()
}

#[tokio::test]
async fn migrations_apply_in_wal_mode_and_are_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let pool = db::connect(&db_config(&dir, "wb.db")).await.unwrap();
    let mode: String = sqlx::query_scalar("PRAGMA journal_mode")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(mode, "wal");
    let fk: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(fk, 1);
    db::migrate(&pool).await.unwrap();
    db::migrate(&pool).await.unwrap();
    assert_eq!(
        tables(&pool).await,
        vec![
            "accounts",
            "admin_log",
            "blocks",
            "cloud_saves",
            "crew_members",
            "crews",
            "device_secrets",
            "friends",
            "identity_links",
            "leaderboard_entries",
            "refresh_tokens",
            "replays",
            "reports",
            "runs",
            "shadow_contacts"
        ]
    );
    assert!(db::ping(&pool).await);

    // Refresh tokens go with their account (account deletion, N1).
    sqlx::query("INSERT INTO accounts (id, display_name, tag, created_at, last_seen) VALUES (1, 'Rider', 1234, 0, 0)")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO refresh_tokens (token_hash, account_id, family, expires_at, created_at) VALUES (x'01', 1, x'02', 10, 0)")
        .execute(&pool)
        .await
        .unwrap();
    let dup = sqlx::query("INSERT INTO accounts (display_name, tag, created_at, last_seen) VALUES ('RIDER', 1234, 0, 0)")
        .execute(&pool)
        .await;
    assert!(dup.is_err(), "name#tag is unique, case-insensitively");
    sqlx::query("DELETE FROM accounts WHERE id = 1")
        .execute(&pool)
        .await
        .unwrap();
    let left: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM refresh_tokens")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(left, 0);
    db::close(&pool).await;
}

#[tokio::test]
async fn online_backup_is_a_consistent_copy() {
    let dir = tempfile::tempdir().unwrap();
    let pool = db::connect(&db_config(&dir, "live.db")).await.unwrap();
    db::migrate(&pool).await.unwrap();
    db::admin_log(&pool, "test", "marker", "t", "before backup")
        .await
        .unwrap();

    let dest = dir.path().join("out").join("copy.db");
    db::backup_to(&pool, &dest).await.unwrap();
    assert!(
        db::backup_to(&pool, &dest).await.is_err(),
        "never overwrites"
    );
    db::admin_log(&pool, "test", "marker", "t", "after backup")
        .await
        .unwrap();

    let copy = db::connect(&DbConfig {
        path: dest,
        ..DbConfig::default()
    })
    .await
    .unwrap();
    let details: Vec<String> =
        sqlx::query_scalar("SELECT detail FROM admin_log WHERE action = 'marker'")
            .fetch_all(&copy)
            .await
            .unwrap();
    assert_eq!(details, vec!["before backup"]);
    // The copy is a working database with the migration history.
    db::migrate(&copy).await.unwrap();
    assert_eq!(tables(&copy).await.len(), 15);
    db::close(&copy).await;
    db::close(&pool).await;
}

#[tokio::test]
async fn nightly_run_writes_dated_file_and_prunes() {
    let dir = tempfile::tempdir().unwrap();
    let pool = db::connect(&db_config(&dir, "live.db")).await.unwrap();
    db::migrate(&pool).await.unwrap();
    // N10.3: a count of daily backups (the new one and one more).
    let cfg = BackupConfig {
        dir: dir.path().join("backups"),
        retention_days: 2,
        ..BackupConfig::default()
    };
    std::fs::create_dir_all(&cfg.dir).unwrap();
    std::fs::write(cfg.dir.join("westbound-2026-09-01.db"), b"old").unwrap();
    std::fs::write(cfg.dir.join("westbound-2026-09-25.db"), b"recent").unwrap();

    let now = clock::parse_date_days("2026-09-29").unwrap() * clock::SECS_PER_DAY + 3 * 3600;
    let path = backup::run_once(&pool, &cfg, now).await.unwrap();
    assert_eq!(path, cfg.dir.join("westbound-2026-09-29.db"));
    assert!(path.exists());
    assert!(!cfg.dir.join("westbound-2026-09-01.db").exists());
    assert!(cfg.dir.join("westbound-2026-09-25.db").exists());
    assert!(!cfg.dir.join("westbound-2026-09-29.db.tmp").exists());

    // A second run the same day replaces the file.
    backup::run_once(&pool, &cfg, now + 60).await.unwrap();
    let logged: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM admin_log WHERE action = 'backup'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(logged, 2);
    db::close(&pool).await;
}
