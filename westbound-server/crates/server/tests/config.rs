//! Config: defaults match the spec, file + env layering, validation, redaction.

use westbound_server::config::{Config, Secret};

fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[test]
fn defaults_are_valid_and_match_the_spec() {
    let c = Config::default();
    c.validate().unwrap();
    assert_eq!(c.server.worker_threads, 2);
    assert_eq!(c.limits.max_message_bytes, 16 * 1024);
    assert_eq!(c.limits.outbound_queue_frames, 64);
    assert_eq!(c.limits.ping_interval_ms, 2_000);
    assert_eq!(c.limits.dead_after_ms, 8_000);
    assert_eq!(c.limits.max_rooms, 40);
    assert_eq!(c.limits.max_connections, 400);
    assert_eq!(c.backup.retention_days, 7);
    assert_eq!(c.backup.dir.to_str(), Some("/data/backups"));
    assert!(c.metrics_addr().unwrap().ip().is_loopback());
    assert_eq!(
        c.server.public_origin,
        "https://westbound.sipsakrandevu.com"
    );
    assert_eq!(
        c.http.cors_allowed_origins,
        vec![
            "https://westbound.sipsakrandevu.com",
            "https://b3vet.github.io"
        ]
    );
}

#[test]
fn example_config_file_parses_to_the_defaults() {
    let text = include_str!("../../../config/server.example.toml");
    let c = Config::from_toml_and_env(text, Vec::new()).unwrap();
    c.validate().unwrap();
    assert_eq!(c, Config::default());
}

#[test]
fn file_then_env_overrides() {
    let text = r#"
        [server]
        bind = "127.0.0.1:9000"
        [limits]
        max_connections = 100
    "#;
    let c = Config::from_toml_and_env(
        text,
        env(&[
            ("WB_LIMITS__MAX_CONNECTIONS", "250"),
            ("WB_SERVER__WORKER_THREADS", "4"),
            ("WB_LOG__FORMAT", "json"),
            ("WB_METRICS__ENABLED", "false"),
            (
                "WB_HTTP__CORS_ALLOWED_ORIGINS",
                "https://a.example, https://b.example",
            ),
            ("WB_AUTH__JWT_SECRET", "0123456789abcdef0123456789abcdef"),
            ("WB_CONFIG", "/ignored/by/the/loader.toml"),
            ("PATH", "/usr/bin"),
        ]),
    )
    .unwrap();
    c.validate().unwrap();
    assert_eq!(c.server.bind, "127.0.0.1:9000");
    assert_eq!(c.limits.max_connections, 250);
    assert_eq!(c.server.worker_threads, 4);
    assert_eq!(c.log.format, "json");
    assert!(!c.metrics.enabled);
    assert_eq!(
        c.http.cors_allowed_origins,
        vec!["https://a.example", "https://b.example"]
    );
    assert_eq!(c.auth.jwt_secret.expose().len(), 32);
}

#[test]
fn bad_env_overrides_fail_loudly() {
    for (k, v) in [
        ("WB_LIMITS__MAX_CONECTIONS", "5"),
        ("WB_LIMITS__MAX_CONNECTIONS", "lots"),
        ("WB_METRICS__ENABLED", "maybe"),
        ("WB_NOSECTION", "1"),
    ] {
        let r = Config::from_toml_and_env("", env(&[(k, v)]));
        assert!(r.is_err(), "{k}={v} should be rejected");
    }
}

#[test]
fn unknown_file_keys_are_rejected() {
    assert!(Config::from_toml_and_env("[server]\nbindd = \"x\"\n", Vec::new()).is_err());
    assert!(Config::from_toml_and_env("[nope]\n", Vec::new()).is_err());
}

#[test]
fn validation_collects_every_error() {
    let mut c = Config::default();
    c.server.bind = "not-an-address".into();
    c.server.worker_threads = 0;
    c.log.format = "xml".into();
    c.limits.max_message_bytes = 10;
    c.limits.outbound_queue_frames = 0;
    c.limits.dead_after_ms = c.limits.ping_interval_ms;
    c.limits.max_rooms = 0;
    c.limits.max_connections = 0;
    c.metrics.bind = "10.0.0.5:9090".into();
    c.backup.time_utc = "25:00".into();
    c.backup.retention_days = 0;
    c.auth.jwt_secret = Secret::new("short");
    c.http.cors_allowed_origins = vec!["example.com".into()];
    c.server.public_origin = "https://example.com/path".into();
    let errs = c.validate().unwrap_err().0;
    assert_eq!(errs.len(), 14, "{errs:#?}");
}

#[test]
fn load_reads_file_and_validates() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("server.toml");
    std::fs::write(&path, "[limits]\nmax_rooms = 0\n").unwrap();
    let err = Config::load(Some(&path), Vec::new()).unwrap_err();
    assert!(format!("{err:#}").contains("max_rooms"), "{err:#}");
    std::fs::write(&path, "[limits]\nmax_rooms = 12\n").unwrap();
    assert_eq!(
        Config::load(Some(&path), Vec::new())
            .unwrap()
            .limits
            .max_rooms,
        12
    );
    assert!(Config::load(Some(&dir.path().join("missing.toml")), Vec::new()).is_err());
}

#[test]
fn secrets_never_print() {
    let mut c = Config::default();
    let secret = "super-secret-signing-key-0123456789";
    c.auth.jwt_secret = Secret::new(secret);
    assert!(!format!("{c:?}").contains(secret));
    assert!(!c.to_redacted_toml().contains(secret));
    assert!(c.to_redacted_toml().contains("<redacted>"));
}
