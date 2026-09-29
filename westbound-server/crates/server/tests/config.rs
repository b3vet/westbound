//! Config: defaults match the spec, file + env layering, validation, redaction.

use westbound_server::config::{Config, Secret};

const JWT: &str = "0123456789abcdef0123456789abcdef";
const PEPPER: &str = "fedcba9876543210fedcba9876543210";

/// The two secrets production requires.
fn with_secrets(c: &mut Config) {
    c.auth.jwt_secret = Secret::new(JWT);
    c.auth.device_secret_pepper = Secret::new(PEPPER);
}

fn secret_env() -> Vec<(String, String)> {
    env(&[
        ("WB_AUTH__JWT_SECRET", JWT),
        ("WB_AUTH__DEVICE_SECRET_PEPPER", PEPPER),
    ])
}

fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[test]
fn defaults_are_valid_and_match_the_spec() {
    let mut c = Config::default();
    assert_eq!(c.server.env, "production");
    with_secrets(&mut c);
    c.validate().unwrap();
    // Accounts (spec): 1 h access tokens, 30-day refresh tokens, rename every 30 days.
    assert_eq!(c.auth.access_token_ttl_secs, 3_600);
    assert_eq!(c.auth.refresh_token_ttl_secs, 30 * 86_400);
    assert_eq!(c.auth.rename_cooldown_secs, 30 * 86_400);
    assert!(c.rate_limits.enabled);
    assert_eq!(c.rate_limits.device_create_per_hour, 5);
    assert_eq!(c.http.max_body_bytes, 4_096);
    assert!(c.http.trusted_proxies.contains(&"10.0.0.0/8".to_string()));
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
    assert_eq!(c, Config::default());
    let c = Config::from_toml_and_env(text, secret_env()).unwrap();
    c.validate().unwrap();
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
            ("WB_AUTH__JWT_SECRET", JWT),
            ("WB_AUTH__DEVICE_SECRET_PEPPER", PEPPER),
            ("WB_HTTP__TRUSTED_PROXIES", "10.0.0.0/8, 172.16.0.0/12"),
            ("WB_RATE_LIMITS__DEVICE_CREATE_PER_HOUR", "10"),
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
    assert_eq!(c.auth.device_secret_pepper.expose(), PEPPER);
    assert_eq!(c.http.trusted_proxies, vec!["10.0.0.0/8", "172.16.0.0/12"]);
    assert_eq!(c.rate_limits.device_create_per_hour, 10);
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
    c.server.env = "staging".into();
    c.auth.access_token_ttl_secs = 0;
    c.rate_limits.auth_burst = 0;
    c.http.max_body_bytes = 1;
    c.http.trusted_proxies = vec!["10.0.0.0/99".into()];
    // + auth.device_secret_pepper missing
    let errs = c.validate().unwrap_err().0;
    assert_eq!(errs.len(), 20, "{errs:#?}");
}

#[test]
fn load_reads_file_and_validates() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("server.toml");
    std::fs::write(&path, "[limits]\nmax_rooms = 0\n").unwrap();
    let err = Config::load(Some(&path), secret_env()).unwrap_err();
    assert!(format!("{err:#}").contains("max_rooms"), "{err:#}");
    std::fs::write(&path, "[limits]\nmax_rooms = 12\n").unwrap();
    assert_eq!(
        Config::load(Some(&path), secret_env())
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
    let pepper = "super-secret-device-pepper-0123456789";
    c.auth.device_secret_pepper = Secret::new(pepper);
    assert!(!format!("{c:?}").contains(secret));
    assert!(!c.to_redacted_toml().contains(secret));
    assert!(!format!("{c:?}").contains(pepper));
    assert!(!c.to_redacted_toml().contains(pepper));
    assert!(c.to_redacted_toml().contains("<redacted>"));
}

#[test]
fn auth_secrets_are_required_outside_dev() {
    let mut c = Config::default();
    let errs = c.validate().unwrap_err().0;
    assert_eq!(errs.len(), 2, "{errs:#?}");
    assert!(errs[0].contains("WB_AUTH__JWT_SECRET"), "{errs:#?}");
    assert!(
        errs[1].contains("WB_AUTH__DEVICE_SECRET_PEPPER"),
        "{errs:#?}"
    );
    // Too short, or the same value twice.
    c.auth.jwt_secret = Secret::new("x".repeat(31));
    c.auth.device_secret_pepper = Secret::new(PEPPER);
    assert_eq!(c.validate().unwrap_err().0.len(), 1);
    c.auth.jwt_secret = Secret::new(PEPPER);
    assert_eq!(c.validate().unwrap_err().0.len(), 1);
    // dev may leave them empty (public development values are used), but not short.
    let mut dev = Config::default();
    dev.server.env = "dev".into();
    dev.validate().unwrap();
    dev.auth.jwt_secret = Secret::new("short");
    assert_eq!(dev.validate().unwrap_err().0.len(), 1);
    // config/dev.toml is a dev config.
    let text = include_str!("../../../config/dev.toml");
    let c = Config::from_toml_and_env(text, Vec::new()).unwrap();
    assert!(c.is_dev());
    c.validate().unwrap();
}

#[test]
fn gateway_defaults_and_validation() {
    let mut c = Config::default();
    with_secrets(&mut c);
    // Spec: 20 Hz tick; per-type WebSocket limits on.
    assert_eq!(c.gateway.tick_rate_hz, 20);
    assert!(c.gateway.map_hashes.is_empty());
    assert!(c.gateway.echo_enabled);
    assert!(c.ws_rate_limits.enabled);
    assert_eq!(c.ws_rate_limits.entries().len(), 9);
    c.validate().unwrap();

    c.gateway.map_hashes = vec!["ab".repeat(32), "AB".repeat(32)];
    c.validate().unwrap();
    assert_eq!(
        westbound_server::config::parse_map_hash(&"0f".repeat(32)).map(|h| h.0),
        Some([0x0F; 32])
    );

    c.gateway.map_hashes = vec!["abc".into(), "zz".repeat(32)];
    c.gateway.hello_timeout_ms = 0;
    c.gateway.tick_rate_hz = 0;
    c.gateway.ban_recheck_ms = 0;
    c.limits.dead_after_ms = 70_000;
    c.ws_rate_limits.ping_burst = 0;
    c.ws_rate_limits.player_state_per_sec = f64::NAN;
    c.ws_rate_limits.violation_per_sec = 0.0;
    let errs = c.validate().unwrap_err().0;
    assert_eq!(errs.len(), 9, "{errs:#?}");
    c.ws_rate_limits.enabled = false;
    assert_eq!(c.validate().unwrap_err().0.len(), 6);
}

#[test]
fn gateway_env_overrides() {
    let hash = "cd".repeat(32);
    let c = Config::from_toml_and_env(
        "",
        env(&[
            ("WB_GATEWAY__MAP_HASHES", &format!("{hash}, {hash}")),
            ("WB_GATEWAY__HELLO_TIMEOUT_MS", "2500"),
            ("WB_WS_RATE_LIMITS__PING_PER_SEC", "0.5"),
            ("WB_WS_RATE_LIMITS__ENABLED", "false"),
        ]),
    )
    .unwrap();
    assert_eq!(c.gateway.map_hashes, vec![hash.clone(), hash]);
    assert_eq!(c.gateway.hello_timeout_ms, 2_500);
    assert_eq!(c.ws_rate_limits.ping_per_sec, 0.5);
    assert!(!c.ws_rate_limits.enabled);
}
