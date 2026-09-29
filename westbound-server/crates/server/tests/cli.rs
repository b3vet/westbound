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
        .env("WB_SERVER__SHUTDOWN_GRACE_MS", "1000");
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
    let out = cmd(dir.path(), 8080)
        .env("WB_AUTH__JWT_SECRET", secret)
        .arg("check-config")
        .output()
        .unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("bind = \"127.0.0.1:8080\""), "{stdout}");
    assert!(!stdout.contains(secret));

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
