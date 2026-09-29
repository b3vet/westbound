//! The binary's subcommands end to end: check-config, migrate, backup, healthcheck,
//! and `serve` stopping cleanly on SIGTERM.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_westbound-server");

fn cmd(dir: &Path, port: u16) -> Command {
    let mut c = Command::new(BIN);
    c.env_clear()
        .env("WB_SERVER__BIND", format!("127.0.0.1:{port}"))
        .env("WB_DB__PATH", dir.join("wb.db"))
        .env("WB_BACKUP__DIR", dir.join("backups"))
        .env("WB_METRICS__ENABLED", "false")
        .env("WB_SERVER__SHUTDOWN_GRACE_MS", "1000")
        .env(
            "WB_AUTH__JWT_SECRET",
            "cli-test-jwt-secret-0123456789abcdef",
        )
        .env(
            "WB_AUTH__DEVICE_SECRET_PEPPER",
            "cli-test-device-pepper-0123456789abcdef",
        );
    c
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

#[test]
fn check_config_prints_redacted_and_rejects_bad_values() {
    let dir = tempfile::tempdir().unwrap();
    let secret = "0123456789abcdef0123456789abcdef-secret";
    let pepper = "cli-test-device-pepper-0123456789abcdef";
    let out = cmd(dir.path(), 8080)
        .env("WB_AUTH__JWT_SECRET", secret)
        .arg("check-config")
        .output()
        .unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("bind = \"127.0.0.1:8080\""), "{stdout}");
    assert!(!stdout.contains(secret));
    assert!(!stdout.contains(pepper));

    // Production refuses to start without the auth secrets; dev does not need them.
    let missing = cmd(dir.path(), 8080)
        .env_remove("WB_AUTH__JWT_SECRET")
        .env_remove("WB_AUTH__DEVICE_SECRET_PEPPER")
        .arg("check-config")
        .output()
        .unwrap();
    assert_eq!(missing.status.code(), Some(2));
    let err = String::from_utf8_lossy(&missing.stderr);
    assert!(err.contains("WB_AUTH__JWT_SECRET"), "{err}");
    assert!(err.contains("WB_AUTH__DEVICE_SECRET_PEPPER"), "{err}");
    let dev = cmd(dir.path(), 8080)
        .env_remove("WB_AUTH__JWT_SECRET")
        .env_remove("WB_AUTH__DEVICE_SECRET_PEPPER")
        .env("WB_SERVER__ENV", "dev")
        .arg("check-config")
        .output()
        .unwrap();
    assert!(dev.status.success());

    let bad = cmd(dir.path(), 8080)
        .env("WB_LIMITS__MAX_CONNECTIONS", "0")
        .arg("check-config")
        .output()
        .unwrap();
    assert_eq!(bad.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&bad.stderr).contains("max_connections"));
}

#[test]
fn migrate_then_backup() {
    let dir = tempfile::tempdir().unwrap();
    let st = cmd(dir.path(), 8080).arg("migrate").status().unwrap();
    assert!(st.success());
    assert!(dir.path().join("wb.db").exists());
    let dest = dir.path().join("manual.db");
    let st = cmd(dir.path(), 8080)
        .arg("backup")
        .arg(&dest)
        .status()
        .unwrap();
    assert!(st.success());
    assert!(dest.metadata().unwrap().len() > 0);
    // Refuses to overwrite.
    let st = cmd(dir.path(), 8080)
        .arg("backup")
        .arg(&dest)
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(!st.success());
}

#[test]
fn serve_is_healthy_then_stops_on_sigterm() {
    let dir = tempfile::tempdir().unwrap();
    let port = free_port();
    let unhealthy = cmd(dir.path(), port)
        .arg("healthcheck")
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(!unhealthy.success(), "nothing listening yet");

    let mut child = cmd(dir.path(), port)
        .arg("serve")
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let ok = cmd(dir.path(), port)
            .arg("healthcheck")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success();
        if ok {
            break;
        }
        assert!(Instant::now() < deadline, "server became healthy");
        std::thread::sleep(Duration::from_millis(50));
    }
    let st = Command::new("kill")
        .args(["-TERM", &child.id().to_string()])
        .status()
        .unwrap();
    assert!(st.success());
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        assert!(Instant::now() < deadline, "server exits after SIGTERM");
        std::thread::sleep(Duration::from_millis(20));
    };
    let out = child.wait_with_output().unwrap();
    let log = String::from_utf8_lossy(&out.stderr);
    assert!(status.success(), "{log}");
    assert!(log.contains("SIGTERM received"), "{log}");
    assert!(log.contains("database closed"), "{log}");
}

fn run(dir: &Path, args: &[&str]) -> (bool, String, String) {
    let out = cmd(dir, 8080).args(args).output().unwrap();
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[tokio::test]
async fn admin_ban_unban_rename() {
    use westbound_server::{accounts, db};
    let dir = tempfile::tempdir().unwrap();
    assert!(run(dir.path(), &["migrate"]).0);
    let cfg = westbound_server::config::DbConfig {
        path: dir.path().join("wb.db"),
        ..Default::default()
    };
    let pool = db::connect(&cfg).await.unwrap();
    let mut conn = pool.acquire().await.unwrap();
    let (id, _) = accounts::insert_device_account(&mut conn, "LoneWolf", &[0u8; 32], 1_000)
        .await
        .unwrap();
    drop(conn);
    let ids = id.to_string();

    let before = westbound_server::clock::unix_now_secs();
    let (ok, out, err) = run(dir.path(), &["admin", "ban", &ids, "7d"]);
    assert!(ok, "{err}");
    assert!(out.contains("banned until"), "{out}");
    let acc = accounts::get(&pool, id).await.unwrap().unwrap();
    let until = acc.banned_until.unwrap();
    assert!((before + 7 * 86_400..=before + 7 * 86_400 + 60).contains(&until));

    let (ok, out, _) = run(dir.path(), &["admin", "ban", &ids, "perm"]);
    assert!(ok && out.contains("permanently"), "{out}");
    assert_eq!(
        accounts::get(&pool, id)
            .await
            .unwrap()
            .unwrap()
            .banned_until,
        Some(accounts::PERMANENT_BAN_UNTIL)
    );

    let (ok, out, _) = run(dir.path(), &["admin", "unban", &ids]);
    assert!(ok && out.contains("unbanned"), "{out}");
    assert_eq!(
        accounts::get(&pool, id)
            .await
            .unwrap()
            .unwrap()
            .banned_until,
        None
    );

    let (ok, out, err) = run(dir.path(), &["admin", "rename", &ids, "Road Runner"]);
    assert!(ok, "{err}");
    assert!(out.contains("renamed to Road Runner#"), "{out}");
    let acc = accounts::get(&pool, id).await.unwrap().unwrap();
    assert_eq!(acc.display_name, "Road Runner");
    assert!(acc.name_changed_at.is_some());

    // Refusals: bad duration, unknown account, a name the filter rejects.
    assert!(!run(dir.path(), &["admin", "ban", &ids, "7y"]).0);
    assert!(!run(dir.path(), &["admin", "ban", "999", "1d"]).0);
    assert!(!run(dir.path(), &["admin", "unban", "999"]).0);
    let (ok, _, err) = run(dir.path(), &["admin", "rename", &ids, "Sh1t"]);
    assert!(!ok);
    assert!(err.contains("not allowed"), "{err}");

    let log: Vec<(String, String, String)> =
        sqlx::query_as("SELECT actor, action, target FROM admin_log ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    let expected = [
        ("cli", "ban"),
        ("cli", "ban"),
        ("cli", "unban"),
        ("cli", "rename"),
    ];
    assert_eq!(log.len(), expected.len(), "{log:?}");
    for ((actor, action, target), (ea, eb)) in log.iter().zip(expected) {
        assert_eq!(
            (actor.as_str(), action.as_str(), target.as_str()),
            (ea, eb, ids.as_str())
        );
    }
    db::close(&pool).await;
}

#[tokio::test]
async fn admin_remove_run_and_entry() {
    use westbound_server::{accounts, db};
    let dir = tempfile::tempdir().unwrap();
    assert!(run(dir.path(), &["migrate"]).0);
    let cfg = westbound_server::config::DbConfig {
        path: dir.path().join("wb.db"),
        ..Default::default()
    };
    let pool = db::connect(&cfg).await.unwrap();
    let mut conn = pool.acquire().await.unwrap();
    let (id, _) = accounts::insert_device_account(&mut conn, "LoneWolf", &[0u8; 32], 1_000)
        .await
        .unwrap();
    drop(conn);
    for (run_id, score) in [(1, 500), (2, 900)] {
        sqlx::query(
            "INSERT INTO runs (id, account_id, mode, map_or_seed, date, score, distance_m,
                               duration_s, verification, created_at)
             VALUES (?, ?, 'journey', '7', '2026-09-29', ?, 1000, 60, 'unverified', ?)",
        )
        .bind(run_id)
        .bind(id)
        .bind(score)
        .bind(run_id)
        .execute(&pool)
        .await
        .unwrap();
    }
    sqlx::query(
        "INSERT INTO leaderboard_entries (board, period_key, subject_id, account_id, run_id,
                                          score, achieved_at, verification, run_date)
         VALUES ('journey', 'all', ?, ?, 2, 900, 2, 'unverified', '2026-09-29')",
    )
    .bind(id)
    .bind(id)
    .execute(&pool)
    .await
    .unwrap();

    let (ok, out, err) = run(dir.path(), &["admin", "remove-run", "2"]);
    assert!(ok, "{err}");
    assert!(out.contains("journey/all"), "{out}");
    let best: i64 = sqlx::query_scalar("SELECT score FROM leaderboard_entries")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(best, 500, "rebuilt from the next best run");
    let ids = id.to_string();
    let (ok, out, err) = run(
        dir.path(),
        &["admin", "remove-entry", "journey", "all", &ids],
    );
    assert!(ok, "{err}");
    assert!(out.contains("removed"), "{out}");
    // Refusals: unknown run, entry, board or period.
    assert!(!run(dir.path(), &["admin", "remove-run", "2"]).0);
    assert!(
        !run(
            dir.path(),
            &["admin", "remove-entry", "journey", "all", &ids]
        )
        .0
    );
    assert!(!run(dir.path(), &["admin", "remove-entry", "nope", "all", &ids]).0);
    assert!(
        !run(
            dir.path(),
            &["admin", "remove-entry", "journey", "2026-09", &ids]
        )
        .0
    );
    let log: Vec<String> = sqlx::query_scalar("SELECT action FROM admin_log ORDER BY id")
        .fetch_all(&pool)
        .await
        .unwrap();
    assert_eq!(log, vec!["remove_run", "remove_entry"]);
    db::close(&pool).await;
}

#[tokio::test]
async fn admin_reports_and_crews() {
    use westbound_server::{accounts, db};
    let dir = tempfile::tempdir().unwrap();
    assert!(run(dir.path(), &["migrate"]).0);
    let cfg = westbound_server::config::DbConfig {
        path: dir.path().join("wb.db"),
        ..Default::default()
    };
    let pool = db::connect(&cfg).await.unwrap();
    let mut conn = pool.acquire().await.unwrap();
    let (a, _) = accounts::insert_device_account(&mut conn, "LoneWolf", &[0u8; 32], 1_000)
        .await
        .unwrap();
    let (b, _) = accounts::insert_device_account(&mut conn, "DustyRider", &[0u8; 32], 1_000)
        .await
        .unwrap();
    drop(conn);
    for (reporter, target, reason, handled) in [(a, b, "cheating", 0), (b, a, "griefing", 1)] {
        sqlx::query(
            "INSERT INTO reports (reporter_id, target_id, reason, context, created_at, handled)
             VALUES (?, ?, ?, '{\"source\":\"room\"}', 2000, ?)",
        )
        .bind(reporter)
        .bind(target)
        .bind(reason)
        .bind(handled)
        .execute(&pool)
        .await
        .unwrap();
    }
    sqlx::query(
        "INSERT INTO crews (id, name, tag, owner_id, invite_code, created_at)
         VALUES (5, 'Night Riders', 'NR', ?, 'ABCDEFGH', 0)",
    )
    .bind(a)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO crew_members (account_id, crew_id, role, joined_at) VALUES (?, 5, 'owner', 0)",
    )
    .bind(a)
    .execute(&pool)
    .await
    .unwrap();

    let (ok, out, err) = run(dir.path(), &["admin", "reports"]);
    assert!(ok, "{err}");
    assert_eq!(out.lines().count(), 2, "{out}");
    let (ok, out, _) = run(dir.path(), &["admin", "reports", "--unhandled"]);
    assert!(ok);
    assert_eq!(out.lines().count(), 1, "{out}");
    assert!(
        out.starts_with(&format!(
            "#1 2000 reporter={a} target={b} reason=cheating unhandled"
        )),
        "{out}"
    );
    let (ok, out, err) = run(dir.path(), &["admin", "report-handle", "1"]);
    assert!(ok && out.contains("marked handled"), "{out}{err}");
    let (ok, out, _) = run(dir.path(), &["admin", "reports", "--unhandled"]);
    assert!(ok && out.contains("no unhandled reports"), "{out}");
    assert!(!run(dir.path(), &["admin", "report-handle", "9"]).0);

    let (ok, out, err) = run(dir.path(), &["admin", "crew-rename", "5", "Day Riders"]);
    assert!(ok, "{err}");
    assert!(out.contains("renamed to Day Riders [NR]"), "{out}");
    let (ok, out, err) = run(dir.path(), &["admin", "crew-rename", "5", "--tag", "dr"]);
    assert!(ok, "{err}");
    assert!(out.contains("[DR]"), "{out}");
    let (ok, _, err) = run(dir.path(), &["admin", "crew-rename", "5", "Sh1t Crew"]);
    assert!(!ok);
    assert!(err.contains("not allowed"), "{err}");
    assert!(!run(dir.path(), &["admin", "crew-rename", "9", "Nope Crew"]).0);
    let (ok, out, err) = run(dir.path(), &["admin", "crew-disband", "5"]);
    assert!(ok, "{err}");
    assert!(out.contains("crew 5 disbanded"), "{out}");
    assert!(!run(dir.path(), &["admin", "crew-disband", "5"]).0);
    let members: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM crew_members")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(members, 0);
    let log: Vec<String> = sqlx::query_scalar("SELECT action FROM admin_log ORDER BY id")
        .fetch_all(&pool)
        .await
        .unwrap();
    assert_eq!(
        log,
        vec![
            "report_handle",
            "crew_rename",
            "crew_rename",
            "crew_disband"
        ]
    );
    db::close(&pool).await;
}
