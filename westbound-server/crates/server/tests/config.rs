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
    // N10.3 (owner: the disk is small): at most 3 daily backups, stale after 26 h.
    assert_eq!(c.backup.retention_days, 3);
    assert_eq!(c.backup.max_age_hours, 26);
    assert!(c.housekeeping.enabled);
    assert_eq!(c.housekeeping.min_free_mb, 500);
    assert_eq!(c.housekeeping.shadow_contacts_days, 30);
    assert_eq!(c.replays.set_aside_retention_days, 30);
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

/// N10.3: the backup count is bounded (the volume is small), the housekeeping keeps what
/// the server still needs, and every key is settable from the environment.
#[test]
fn housekeeping_and_backup_retention_are_validated() {
    let mut c = Config::default();
    with_secrets(&mut c);
    c.backup.retention_days = 32;
    c.backup.max_age_hours = 0;
    c.housekeeping.time_utc = "4pm".into();
    c.housekeeping.check_interval_secs = 0;
    c.housekeeping.batch_rows = 0;
    c.housekeeping.vacuum_min_free_pct = 101;
    c.housekeeping.runs_days = 7;
    c.housekeeping.admin_log_days = 1;
    c.housekeeping.board_periods_days = 3;
    let errs = c.validate().unwrap_err().0;
    assert_eq!(errs.len(), 9, "{errs:#?}");
    assert!(
        errs.iter().any(|e| e.contains("backup.retention_days")),
        "{errs:#?}"
    );
    assert!(
        errs.iter().any(|e| e.contains("housekeeping.runs_days")),
        "{errs:#?}"
    );
    // 0 keeps the rows; the edges are fine.
    let mut c = Config::default();
    with_secrets(&mut c);
    c.backup.retention_days = 31;
    c.housekeeping.runs_days = 0;
    c.housekeeping.admin_log_days = 0;
    c.housekeeping.board_periods_days = 8;
    c.housekeeping.shadow_contacts_days = 0;
    c.housekeeping.vacuum_min_free_pct = 0;
    c.validate().unwrap();
    let c = Config::from_toml_and_env(
        "",
        env(&[
            ("WB_BACKUP__RETENTION_DAYS", "2"),
            ("WB_HOUSEKEEPING__MIN_FREE_MB", "1000"),
            ("WB_HOUSEKEEPING__SHADOW_CONTACTS_DAYS", "14"),
            ("WB_REPLAYS__SET_ASIDE_RETENTION_DAYS", "7"),
            ("WB_AUTH__JWT_SECRET", JWT),
            ("WB_AUTH__DEVICE_SECRET_PEPPER", PEPPER),
        ]),
    )
    .unwrap();
    c.validate().unwrap();
    assert_eq!(c.backup.retention_days, 2);
    assert_eq!(c.housekeeping.min_free_bytes(), 1000 * 1_048_576);
    assert_eq!(c.housekeeping.shadow_contacts_days, 14);
    assert_eq!(c.replays.set_aside_retention_days, 7);
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

#[test]
fn leaderboard_and_runs_defaults_and_validation() {
    let mut c = Config::default();
    with_secrets(&mut c);
    // Spec: global top 100; replay for the top 100; crew = top 4 members; 30 submissions/h.
    assert_eq!(c.leaderboards.global_limit_max, 100);
    assert_eq!(c.leaderboards.replay_top_n, 100);
    assert_eq!(c.leaderboards.crew_top_members, 4);
    assert!(c.leaderboards.show_pending);
    assert_eq!(c.rate_limits.runs_per_hour, 30);
    assert!(c.runs.supported_builds.is_empty());
    assert!(c.runs.build_supported(0) && c.runs.build_supported(u32::MAX));
    c.validate().unwrap();

    c.runs.supported_builds = vec!["41".into(), "nope".into()];
    c.runs.max_score_per_minute = f64::NAN;
    c.runs.min_duration_s = 0.0;
    c.leaderboards.global_limit_default = 101;
    c.leaderboards.crew_top_members = 0;
    c.rate_limits.runs_per_hour = 0;
    let errs = c.validate().unwrap_err().0;
    for key in [
        "supported_builds",
        "max_score_per_minute",
        "min_duration_s",
        "global_limit_default",
        "crew_top_members",
        "rate_limits",
    ] {
        assert!(errs.iter().any(|e| e.contains(key)), "{key}: {errs:?}");
    }
}

#[test]
fn runs_env_overrides() {
    let c = Config::from_toml_and_env(
        "",
        env(&[
            ("WB_RUNS__SUPPORTED_BUILDS", "41, 42"),
            ("WB_RUNS__MIN_BUILD", "40"),
            ("WB_LEADERBOARDS__SHOW_PENDING", "false"),
            ("WB_RATE_LIMITS__RUNS_PER_HOUR", "12"),
        ]),
    )
    .unwrap();
    assert_eq!(c.runs.supported_build_numbers(), vec![41, 42]);
    assert!(c.runs.build_supported(42));
    assert!(!c.runs.build_supported(43));
    assert!(!c.runs.build_supported(39));
    assert!(!c.leaderboards.show_pending);
    assert_eq!(c.rate_limits.runs_per_hour, 12);
}

#[test]
fn social_defaults_validation_and_env() {
    let mut c = Config::default();
    with_secrets(&mut c);
    // Spec: crews of up to 16 members; reports rate-limited per account.
    assert_eq!(c.social.crew_max_members, 16);
    assert_eq!(c.social.max_friends, 100);
    assert_eq!(c.social.reports_per_day, 10);
    assert_eq!(c.rate_limits.social_per_hour, 60);
    c.validate().unwrap();

    c.social.max_friends = 0;
    c.social.crew_max_members = 0;
    c.social.crew_invite_code_len = 4;
    c.social.report_context_max_bytes = 1;
    c.rate_limits.social_burst = 0;
    let errs = c.validate().unwrap_err().0;
    for key in [
        "social.max_friends",
        "social.crew_max_members",
        "social.crew_invite_code_len",
        "social.report_context_max_bytes",
        "rate_limits",
    ] {
        assert!(errs.iter().any(|e| e.contains(key)), "{key}: {errs:?}");
    }

    let c = Config::from_toml_and_env(
        "[social]\nmax_friends = 50\n",
        env(&[
            ("WB_SOCIAL__CREW_MAX_MEMBERS", "8"),
            ("WB_RATE_LIMITS__SOCIAL_BURST", "5"),
        ]),
    )
    .unwrap();
    assert_eq!(c.social.max_friends, 50);
    assert_eq!(c.social.crew_max_members, 8);
    assert_eq!(c.rate_limits.social_burst, 5);
}

#[test]
fn rooms_traffic_streaming_defaults_and_validation() {
    let mut c = Config::default();
    with_secrets(&mut c);
    // N4.2: the sim ring streams by default (spec: 300 m behind, 900 m ahead; 5 Hz within
    // 100 m, 1 Hz otherwise; MP-D6: ids held 30 s).
    let r = &c.rooms;
    assert_eq!(r.traffic, westbound_server::config::ROOM_TRAFFIC_SIM);
    assert_eq!(
        (r.traffic_aoi_behind_m, r.traffic_aoi_ahead_m),
        (300.0, 900.0)
    );
    assert_eq!(
        (r.traffic_near_m, r.traffic_near_hz, r.traffic_far_hz),
        (100.0, 5, 1)
    );
    assert_eq!(r.traffic_car_id_hold_ms, 30_000);
    let p = westbound_server::rooms::RoomParams::from_config(&c).stream;
    assert_eq!(
        (p.aoi_behind_mm, p.aoi_ahead_mm, p.near_mm),
        (300_000, 900_000, 100_000)
    );
    assert_eq!((p.near_period_ticks, p.far_period_ticks), (4, 20));
    assert_eq!(p.car_id_hold_ticks, 600);
    c.validate().unwrap();

    c.rooms.traffic_near_hz = 0;
    c.rooms.traffic_far_hz = 21;
    c.rooms.traffic_aoi_hysteresis_m = -1.0;
    c.rooms.traffic_aoi_ahead_m = 12_000.0;
    let errs = c.validate().unwrap_err().0;
    assert_eq!(errs.len(), 4, "{errs:#?}");
}

#[test]
fn scoring_defaults_and_validation() {
    let mut c = Config::default();
    with_secrets(&mut c);
    // N6.1 (spec: ±300 ms, +0.35 m; crew +0.25× within 30 m, cap ×2; trains 1.0 s, 25, +2;
    // hits 0.3 m for 2 ticks).
    let s = &c.scoring;
    assert_eq!(
        (s.claim_timing_ms, s.claim_clearance_tolerance_m),
        (300, 0.35)
    );
    assert_eq!(
        (s.crew_range_m, s.crew_bonus_per_mate, s.crew_factor_cap),
        (30.0, 0.25, 2.0)
    );
    assert_eq!(
        (s.train_window_ms, s.train_points, s.train_multiplier_gain),
        (1_000, 25, 2.0)
    );
    assert_eq!((s.hit_overlap_m, s.hit_overlap_ticks), (0.3, 2));
    let r = westbound_server::rooms::RoomParams::from_config(&c).scoring;
    assert_eq!(r.verify.timing_ticks, 6);
    assert_eq!((r.lag_ticks, r.sync_ticks, r.train_ticks), (30, 20, 20));
    assert_eq!(r.crew_factor(0), 1.0);
    assert_eq!(r.crew_factor(2), 1.5);
    assert_eq!(r.crew_factor(7), 2.0, "capped");
    assert!(r.history_ticks >= 42, "the history covers stale states");
    c.validate().unwrap();

    c.scoring.claim_clearance_tolerance_m = -0.1;
    c.scoring.crew_factor_cap = 0.0;
    c.scoring.verify_min_acceptance_pct = 101.0;
    c.scoring.claim_queue = 0;
    c.scoring.official_lag_ms = 5_000;
    let errs = c.validate().unwrap_err().0;
    assert_eq!(errs.len(), 5, "{errs:#?}");
}

/// N10.2: the restart notice, the admin API, backups' hook and the new rate limits.
#[test]
fn ops_config_defaults_env_validation_and_redaction() {
    let mut c = Config::default();
    // Spec: a notice 60 s before a planned restart.
    assert_eq!(c.server.restart_notice_secs, 60);
    assert_eq!(c.server.restart_notice_reminders_secs, vec![30, 10]);
    assert!(c.admin.enabled && c.admin.token.is_empty());
    assert_eq!(c.admin.bind, "127.0.0.1:9091");
    assert!(c.admin_addr().is_none(), "no token: the admin API is off");
    assert!(c.backup.verify && c.backup.upload_command.is_empty());
    with_secrets(&mut c);
    c.validate().unwrap();

    let token = "admin-token-0123456789abcdef0123456789";
    let c = Config::from_toml_and_env(
        "",
        env(&[
            ("WB_AUTH__JWT_SECRET", JWT),
            ("WB_AUTH__DEVICE_SECRET_PEPPER", PEPPER),
            ("WB_ADMIN__TOKEN", token),
            ("WB_SERVER__RESTART_NOTICE_REMINDERS_SECS", "45, 5"),
            (
                "WB_BACKUP__UPLOAD_COMMAND",
                "/data/bin/rclone,copy,{file},offsite:wb",
            ),
            ("WB_RATE_LIMITS__WS_CONNECT_BURST", "7"),
        ]),
    )
    .unwrap();
    c.validate().unwrap();
    assert_eq!(c.server.restart_notice_reminders_secs, vec![45, 5]);
    assert_eq!(c.backup.upload_command[2], "{file}");
    assert_eq!(c.rate_limits.ws_connect_burst, 7);
    assert_eq!(c.admin_addr().unwrap().to_string(), "127.0.0.1:9091");
    assert!(
        !c.to_redacted_toml().contains(token),
        "the admin token is redacted"
    );
    assert!(Config::from_toml_and_env(
        "",
        env(&[("WB_SERVER__RESTART_NOTICE_REMINDERS_SECS", "soon")])
    )
    .is_err());
    // A shorter notice alone (reminders above it are skipped) stays valid.
    let mut short = Config::default();
    with_secrets(&mut short);
    short.server.restart_notice_secs = 20;
    short.validate().unwrap();

    for bad in [
        |c: &mut Config| c.admin.bind = "0.0.0.0:9091".into(),
        |c: &mut Config| c.admin.token = Secret::new("short"),
        |c: &mut Config| c.server.restart_notice_reminders_secs = vec![0],
        |c: &mut Config| c.server.restart_notice_secs = 70_000,
        |c: &mut Config| c.server.handover_ttl_secs = 0,
        |c: &mut Config| c.backup.upload_command = vec![String::new()],
        |c: &mut Config| c.rate_limits.ip_burst = 0,
        |c: &mut Config| c.rooms.create_per_hour = 0,
        |c: &mut Config| c.metrics.db_probe_interval_secs = 0,
    ] {
        let mut c = Config::default();
        with_secrets(&mut c);
        bad(&mut c);
        assert!(c.validate().is_err(), "{c:?}");
    }
}
