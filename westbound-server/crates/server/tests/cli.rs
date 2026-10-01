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

#[tokio::test]
async fn admin_replays_lists_and_requeues_jobs() {
    use westbound_server::{accounts, db};
    let dir = tempfile::tempdir().unwrap();
    assert!(run(dir.path(), &["migrate"]).0);
    let cfg = westbound_server::config::DbConfig {
        path: dir.path().join("wb.db"),
        ..Default::default()
    };
    let pool = db::connect(&cfg).await.unwrap();
    let (ok, out, _) = run(dir.path(), &["admin", "replays"]);
    assert!(ok && out.contains("no replays"), "{out}");
    let mut conn = pool.acquire().await.unwrap();
    let (id, _) = accounts::insert_device_account(&mut conn, "LoneWolf", &[0u8; 32], 1_000)
        .await
        .unwrap();
    drop(conn);
    for (run_id, status) in [(1, "failed"), (2, "pending"), (3, "done")] {
        sqlx::query(
            "INSERT INTO runs (id, account_id, mode, map_or_seed, date, score, distance_m,
                               duration_s, verification, created_at)
             VALUES (?, ?, 'journey', '7', '2026-09-29', 100, 1000, 60, 'pending', ?)",
        )
        .bind(run_id)
        .bind(id)
        .bind(run_id)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO replays (run_id, file_path, status, created_at, attempts, result)
             VALUES (?, '/data/replays/x.wbr', ?, 1, 3, '{\"error\":\"timeout\"}')",
        )
        .bind(run_id)
        .bind(status)
        .execute(&pool)
        .await
        .unwrap();
    }
    let (ok, out, err) = run(dir.path(), &["admin", "replays"]);
    assert!(ok, "{err}");
    assert!(
        out.contains("failed 1") && out.contains("pending 1") && out.contains("done 1"),
        "{out}"
    );
    assert!(out.contains("failed run 1 after 3 attempts"), "{out}");
    let (ok, out, err) = run(dir.path(), &["admin", "replay-requeue"]);
    assert!(ok, "{err}");
    assert!(out.contains("1 replay job(s) requeued"), "{out}");
    let (status, attempts): (String, i64) =
        sqlx::query_as("SELECT status, attempts FROM replays WHERE run_id = 1")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!((status.as_str(), attempts), ("pending", 0));
    let (ok, out, _) = run(dir.path(), &["admin", "replay-requeue", "3"]);
    assert!(ok && out.contains("1 replay job(s)"), "{out}");
    db::close(&pool).await;
}

// ---------------------------------------------------------------------------- N10.2

#[tokio::test]
async fn admin_player_ban_reason_delete_recompute_stats_log_backups() {
    use westbound_server::{accounts, db};
    let dir = tempfile::tempdir().unwrap();
    assert!(run(dir.path(), &["migrate"]).0);
    let cfg = westbound_server::config::DbConfig {
        path: dir.path().join("wb.db"),
        ..Default::default()
    };
    let pool = db::connect(&cfg).await.unwrap();
    let mut conn = pool.acquire().await.unwrap();
    let (id, tag) = accounts::insert_device_account(&mut conn, "LoneWolf", &[0u8; 32], 1_000)
        .await
        .unwrap();
    let (other, _) = accounts::insert_device_account(&mut conn, "DustyRider", &[1u8; 32], 1_000)
        .await
        .unwrap();
    drop(conn);
    let full = format!("lonewolf#{tag:04}");
    for (run_id, account, score) in [(1, id, 500), (2, id, 900), (3, other, 700)] {
        sqlx::query(
            "INSERT INTO runs (id, account_id, mode, map_or_seed, date, score, distance_m,
                               duration_s, verification, created_at)
             VALUES (?, ?, 'journey', '7', '2026-09-29', ?, 1000, 60, 'unverified', ?)",
        )
        .bind(run_id)
        .bind(account)
        .bind(score)
        .bind(run_id)
        .execute(&pool)
        .await
        .unwrap();
    }

    // Lookup by name#tag (case-insensitive) and by id.
    let (ok, out, err) = run(dir.path(), &["admin", "player", &full]);
    assert!(ok, "{err}");
    assert!(out.starts_with(&format!("account {id}\n")), "{out}");
    assert!(out.contains("banned no") && out.contains("runs 2"), "{out}");
    assert!(!run(dir.path(), &["admin", "player", "Nobody#0001"]).0);
    assert!(!run(dir.path(), &["admin", "player", "no-tag"]).0);

    // A ban with a reason, by name; shown by `player`. No admin API: the note says so.
    let (ok, out, err) = run(
        dir.path(),
        &["admin", "ban", &full, "7d", "--reason", "wall\nhacking"],
    );
    assert!(ok, "{err}");
    assert!(
        out.contains("banned until") && out.contains("admin API off"),
        "{out}"
    );
    let (_, out, _) = run(dir.path(), &["admin", "player", &id.to_string()]);
    assert!(out.contains("banned until"), "{out}");
    assert!(out.contains("reason=wall hacking"), "{out}");

    // Recompute rebuilds the journey all-time board from the runs.
    let (ok, out, err) = run(dir.path(), &["admin", "recompute", "journey", "all"]);
    assert!(ok, "{err}");
    assert!(
        out.contains("journey/all recomputed: 0 -> 2 entries"),
        "{out}"
    );
    let best: i64 = sqlx::query_scalar(
        "SELECT score FROM leaderboard_entries WHERE board = 'journey' AND account_id = ?",
    )
    .bind(id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(best, 900);
    assert!(!run(dir.path(), &["admin", "recompute", "nope", "all"]).0);

    // Stats (no server running: live says so), the log, backups.
    let (ok, out, err) = run(dir.path(), &["admin", "stats"]);
    assert!(ok, "{err}");
    assert!(
        out.contains("accounts 2") && out.contains("runs 3"),
        "{out}"
    );
    assert!(out.contains("accounts_banned 1"), "{out}");
    assert!(out.contains("live unavailable"), "{out}");
    let (ok, out, _) = run(dir.path(), &["admin", "log", "--limit", "5"]);
    assert!(ok && out.contains("cli recompute journey/all"), "{out}");
    assert!(
        out.lines().next().unwrap().contains("recompute"),
        "newest first: {out}"
    );
    let (ok, out, _) = run(dir.path(), &["admin", "backups"]);
    assert!(ok && out.contains("no backups"), "{out}");

    // The live commands need the admin API.
    let (ok, _, err) = run(dir.path(), &["admin", "rooms"]);
    assert!(!ok && err.contains("admin API is off"), "{err}");

    // Deleting needs --yes; then the account and its data are gone.
    let (ok, _, err) = run(dir.path(), &["admin", "delete-player", &id.to_string()]);
    assert!(!ok && err.contains("--yes"), "{err}");
    let (ok, out, err) = run(
        dir.path(),
        &["admin", "delete-player", &id.to_string(), "--yes"],
    );
    assert!(ok, "{err}");
    assert!(out.contains("deleted: runs=2"), "{out}");
    assert!(accounts::get(&pool, id).await.unwrap().is_none());
    // `report-resolve` is `report-handle`.
    assert!(!run(dir.path(), &["admin", "report-resolve", "99"]).0);
    db::close(&pool).await;
}

#[test]
fn verify_backup_and_restore_refuse_bad_input_and_a_running_server() {
    let dir = tempfile::tempdir().unwrap();
    assert!(run(dir.path(), &["migrate"]).0);
    let backup = dir.path().join("b.db");
    let st = cmd(dir.path(), 8080)
        .arg("backup")
        .arg(&backup)
        .status()
        .unwrap();
    assert!(st.success());
    let (ok, out, err) = run(dir.path(), &["verify-backup", backup.to_str().unwrap()]);
    assert!(ok, "{err}");
    assert!(
        out.starts_with("ok ") && out.contains("migrations"),
        "{out}"
    );
    let junk = dir.path().join("junk.db");
    std::fs::write(&junk, b"not a database at all, not even close").unwrap();
    assert!(!run(dir.path(), &["verify-backup", junk.to_str().unwrap()]).0);

    // Something answers HTTP on the server's port: restore refuses without --force.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        use std::io::{Read, Write};
        for mut s in listener.incoming().flatten() {
            let mut buf = [0u8; 1024];
            let _ = s.read(&mut buf);
            let _ =
                s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
        }
    });
    let out = cmd(dir.path(), port)
        .args(["restore", backup.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("stop it first"));
    // Nothing on the port: the restore goes ahead, keeping the old file.
    let (ok, out, err) = run(dir.path(), &["restore", backup.to_str().unwrap()]);
    assert!(ok, "{err}");
    assert!(
        out.contains("previous database:") && out.contains("before-restore"),
        "{out}"
    );
    let kept = std::fs::read_dir(dir.path())
        .unwrap()
        .filter_map(|e| e.ok())
        .any(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with("wb.db.before-restore-")
        });
    assert!(kept);
    assert!(!run(dir.path(), &["restore", junk.to_str().unwrap()]).0);
}

/// `serve` on SIGTERM with a connected player: the restart notice, reminders, then close
/// 1012, a clean exit and the handover file. The admin CLI reaches the running server.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn serve_sigterm_sends_the_restart_notice_then_closes_1012() {
    use futures_util::{SinkExt, StreamExt};
    use protocol::{
        decode_server_frame, encode_frame, AccessToken, ClientMsg, Hello, MapHash, NoticeKind,
        ServerMsg, PROTOCOL_VERSION,
    };
    use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
    use tokio_tungstenite::tungstenite::Message;

    let dir = tempfile::tempdir().unwrap();
    let (port, admin_port) = (free_port(), free_port());
    let token = "cli-admin-token-0123456789abcdef0123456789";
    let with_env = |mut c: Command| {
        c.env("WB_GATEWAY__MAP_HASHES", "ab".repeat(32))
            .env("WB_SERVER__RESTART_NOTICE_SECS", "3")
            .env("WB_SERVER__RESTART_NOTICE_REMINDERS_SECS", "1")
            .env("WB_ADMIN__TOKEN", token)
            .env("WB_ADMIN__BIND", format!("127.0.0.1:{admin_port}"));
        c
    };
    let mut child = with_env(cmd(dir.path(), port))
        .arg("serve")
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !cmd(dir.path(), port)
        .arg("healthcheck")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success()
    {
        assert!(Instant::now() < deadline, "server became healthy");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let (_, access) = bots::http::device_account(&format!("127.0.0.1:{port}"))
        .await
        .unwrap();
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/ws"))
        .await
        .unwrap();
    let hello = encode_frame(&[ClientMsg::Hello(Hello {
        protocol_version: PROTOCOL_VERSION,
        client_build: 1,
        map_hash: MapHash([0xAB; 32]),
        access_token: AccessToken(access),
    })])
    .unwrap();
    ws.send(Message::Binary(hello.to_vec().into()))
        .await
        .unwrap();
    let first = ws.next().await.unwrap().unwrap();
    assert!(matches!(first, Message::Binary(_)), "{first:?}");

    // The admin CLI against the running server.
    let admin = |args: &[&str]| {
        let out = with_env(cmd(dir.path(), port))
            .arg("admin")
            .args(args)
            .output()
            .unwrap();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).into_owned(),
            String::from_utf8_lossy(&out.stderr).into_owned(),
        )
    };
    let (ok, out, err) = admin(&["stats"]);
    assert!(ok, "{err}");
    assert!(out.contains("live_sessions 1"), "{out}");
    let (ok, out, err) = admin(&["rooms"]);
    assert!(ok && out.contains("no live rooms"), "{out}{err}");
    let (ok, out, err) = admin(&["notice", "Hello drivers"]);
    assert!(ok && out.contains("1 session(s)"), "{out}{err}");
    let (ok, out, err) = admin(&["kick", "99999"]);
    assert!(ok && out.contains("not connected"), "{out}{err}");

    let st = Command::new("kill")
        .args(["-TERM", &child.id().to_string()])
        .status()
        .unwrap();
    assert!(st.success());
    let mut notices = Vec::new();
    let close = loop {
        let m = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .expect("frames until the close");
        match m {
            Some(Ok(Message::Binary(b))) => {
                for msg in decode_server_frame(&b).unwrap() {
                    if let ServerMsg::ServerNotice(n) = msg {
                        notices.push((n.kind, n.seconds));
                    }
                }
            }
            Some(Ok(Message::Close(f))) => break f.map(|f| f.code),
            Some(Ok(_)) => {}
            other => panic!("unexpected {other:?}"),
        }
    };
    assert_eq!(close, Some(CloseCode::Restart));
    assert!(notices.contains(&(NoticeKind::Info, 0)), "{notices:?}");
    assert!(notices.contains(&(NoticeKind::Restart, 3)), "{notices:?}");
    assert!(notices.contains(&(NoticeKind::Restart, 1)), "{notices:?}");
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        assert!(Instant::now() < deadline, "server exits after the notice");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let out = child.wait_with_output().unwrap();
    let log = String::from_utf8_lossy(&out.stderr);
    assert!(status.success(), "{log}");
    assert!(log.contains("restart notice sent"), "{log}");
    assert!(log.contains("rooms handed over"), "{log}");
    assert!(log.contains("database closed"), "{log}");
    assert!(dir.path().join("room-handover.json").exists());
}

// ---------------------------------------------------------------------------- N10.3

/// N10.3: `admin replays` lists set-aside jobs apart from failed ones;
/// `admin replay-purge-set-aside` deletes their files; `admin backups` shows the count and
/// the newest backup's age; `admin stats` has the disk numbers; `admin housekeeping` runs
/// the daily pass.
#[tokio::test]
async fn admin_set_aside_purge_backups_disk_and_housekeeping() {
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
    let replays = dir.path().join("replays");
    std::fs::create_dir_all(&replays).unwrap();
    let now = westbound_server::clock::unix_now_secs();
    for (run_id, status, result, age_days) in [
        (
            1,
            "set_aside",
            r#"{"error":"no verifier for build 7 here","unverifiable":true,"build":7}"#,
            40,
        ),
        (
            2,
            "set_aside",
            r#"{"error":"no verifier for build 8 here","unverifiable":true,"build":8}"#,
            2,
        ),
        (3, "failed", r#"{"error":"timeout"}"#, 40),
    ] {
        sqlx::query(
            "INSERT INTO runs (id, account_id, mode, map_or_seed, date, score, distance_m,
                               duration_s, verification, created_at)
             VALUES (?, ?, 'journey', '7', '2026-09-29', 100, 1000, 60, 'pending', ?)",
        )
        .bind(run_id)
        .bind(id)
        .bind(now)
        .execute(&pool)
        .await
        .unwrap();
        let file = replays.join(format!("{run_id}.wbr"));
        std::fs::write(&file, b"replay").unwrap();
        sqlx::query(
            "INSERT INTO replays (run_id, file_path, status, created_at, attempts, result)
             VALUES (?, ?, ?, ?, 1, ?)",
        )
        .bind(run_id)
        .bind(file.to_string_lossy().into_owned())
        .bind(status)
        .bind(now - age_days * 86_400)
        .bind(result)
        .execute(&pool)
        .await
        .unwrap();
    }
    let (ok, out, err) = run(dir.path(), &["admin", "replays"]);
    assert!(ok, "{err}");
    assert!(
        out.contains("set_aside 2") && out.contains("failed 1"),
        "{out}"
    );
    assert!(out.contains("set aside run 1 (build 7"), "{out}");
    assert!(out.contains("failed run 3 after 1 attempts"), "{out}");
    let (ok, out, err) = run(dir.path(), &["admin", "replay-purge-set-aside"]);
    assert!(ok, "{err}");
    assert!(out.starts_with("1 set-aside replay job(s) purged"), "{out}");
    assert!(!replays.join("1.wbr").exists(), "older than 30 days: gone");
    assert!(replays.join("2.wbr").exists() && replays.join("3.wbr").exists());
    let (ok, _, err) = run(
        dir.path(),
        &["admin", "replay-purge-set-aside", "--older-than", "perm"],
    );
    assert!(!ok && err.contains("--older-than"), "{err}");
    let (ok, out, _) = run(
        dir.path(),
        &["admin", "replay-purge-set-aside", "--older-than", "1d"],
    );
    assert!(ok && out.starts_with("1 set-aside"), "{out}");
    let (ok, out, _) = run(dir.path(), &["admin", "replays"]);
    assert!(ok && out.contains("set_aside_purged 2"), "{out}");

    // Backups: five dated files, the newest 30 h old: STALE; the count is shown.
    let backups = dir.path().join("backups");
    std::fs::create_dir_all(&backups).unwrap();
    let days = [
        "2026-09-25",
        "2026-09-26",
        "2026-09-27",
        "2026-09-28",
        "2026-09-29",
    ];
    for (i, day) in days.iter().enumerate() {
        let p = backups.join(format!("westbound-{day}.db"));
        std::fs::write(&p, b"db").unwrap();
        let age = Duration::from_secs(30 * 3_600 + (4 - i as u64) * 86_400);
        std::fs::File::options()
            .write(true)
            .open(&p)
            .unwrap()
            .set_modified(std::time::SystemTime::now() - age)
            .unwrap();
    }
    let (ok, out, err) = run(dir.path(), &["admin", "backups"]);
    assert!(ok, "{err}");
    assert!(out.contains("dated backups: 5 (at most 3 kept)"), "{out}");
    assert!(
        out.contains("newest: westbound-2026-09-29.db 30 h old: STALE"),
        "{out}"
    );
    let (ok, out, err) = run(dir.path(), &["admin", "stats"]);
    assert!(ok, "{err}");
    for key in [
        "disk_free_bytes ",
        "disk_db_bytes ",
        "disk_backups_bytes ",
        "backup_files 5",
        "backup_stale true",
    ] {
        assert!(out.contains(key), "{key}: {out}");
    }

    // The daily pass by hand: the dated backups down to 3, an old shadow contact gone.
    sqlx::query(
        "INSERT INTO shadow_contacts (room_id, tick, player_a, player_b, speed, disagreement_m,
                                      closing_mps, depth_m, ticks, created_at)
         VALUES (1, 1, 1, 2, 30, 0.1, 1, 0.2, 3, ?)",
    )
    .bind(now - 60 * 86_400)
    .execute(&pool)
    .await
    .unwrap();
    let (ok, out, err) = run(dir.path(), &["admin", "housekeeping"]);
    assert!(ok, "{err}");
    assert!(out.contains("shadow_contacts=1"), "{out}");
    assert!(out.contains("backups_removed=2"), "{out}");
    assert!(out.contains("replays: files_deleted=0"), "{out}");
    assert_eq!(std::fs::read_dir(&backups).unwrap().count(), 3);
    assert!(backups.join("westbound-2026-09-29.db").exists());
    let (ok, out, _) = run(dir.path(), &["admin", "log", "--limit", "1"]);
    assert!(ok && out.contains("cli housekeeping"), "{out}");
    db::close(&pool).await;
}
