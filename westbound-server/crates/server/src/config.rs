//! Server configuration: a TOML file plus `WB_<SECTION>__<KEY>` environment overrides,
//! validated at startup. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Tuning reference",
//! "Resource budget and deployment" (caps), "Server tech stack" (bounded everything).
//! Every number the spec names lives here, never as a literal in the handlers.

use std::fmt;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context};
use serde::{Deserialize, Serialize};

/// Prefix for environment overrides: `WB_LIMITS__MAX_CONNECTIONS=200`.
pub const ENV_PREFIX: &str = "WB_";
/// Environment variable naming the config file (the `--config` flag wins).
pub const ENV_CONFIG_PATH: &str = "WB_CONFIG";
/// Env vars with the prefix that are not config keys.
const ENV_NON_KEYS: &[&str] = &[ENV_CONFIG_PATH];

/// A string that never appears in logs or `Debug` output (tokens, secrets).
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Secret(String);

impl Secret {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }
    pub fn expose(&self) -> &str {
        &self.0
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            f.write_str("Secret(<empty>)")
        } else {
            f.write_str("Secret(<redacted>)")
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub server: ServerConfig,
    pub log: LogConfig,
    pub db: DbConfig,
    pub limits: LimitsConfig,
    pub metrics: MetricsConfig,
    pub backup: BackupConfig,
    pub auth: AuthConfig,
    pub http: HttpConfig,
    pub rate_limits: RateLimitsConfig,
    pub deeplinks: DeepLinksConfig,
    pub gateway: GatewayConfig,
    pub ws_rate_limits: WsRateLimitsConfig,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ServerConfig {
    /// `production` (default) or `dev`. Outside `dev` the auth secrets are required;
    /// in `dev`, empty secrets fall back to fixed, public development values.
    pub env: String,
    /// Public listener (HTTP API, `/ws`, deep-link files). The TLS proxy forwards here.
    pub bind: String,
    /// The public `https://` origin clients reach (TLS terminated by the proxy).
    /// Used for links the server hands out (invite links from N9) and logged at start.
    pub public_origin: String,
    /// tokio worker threads. Spec: 2 by default (design budget is 1 vCPU).
    pub worker_threads: usize,
    /// On SIGTERM: how long open sockets get to receive their close frame and the
    /// in-flight HTTP requests get to finish before the process exits.
    pub shutdown_grace_ms: u64,
    /// N10 hook: seconds of `ServerNotice` before a planned restart. 0 = off (N0).
    pub restart_notice_secs: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct LogConfig {
    /// `tracing` env-filter directive, e.g. `info` or `info,westbound_server=debug`.
    /// `RUST_LOG` overrides it when set.
    pub level: String,
    /// `text` or `json`.
    pub format: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DbConfig {
    /// SQLite file (WAL mode). The parent directory is created if missing.
    pub path: PathBuf,
    pub max_connections: u32,
    pub busy_timeout_ms: u64,
    /// Apply pending migrations when `serve` starts.
    pub migrate_on_start: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct LimitsConfig {
    /// Spec: 16 KB maximum per inbound message.
    pub max_message_bytes: usize,
    /// Spec: per-connection outbound queue of 64 frames; a client that falls behind
    /// is disconnected.
    pub outbound_queue_frames: usize,
    /// Spec: a ping every 2 s.
    pub ping_interval_ms: u64,
    /// Spec: the connection is dead after 8 s of silence.
    pub dead_after_ms: u64,
    /// Spec hard caps: 40 rooms, 400 connections.
    pub max_rooms: usize,
    pub max_connections: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct MetricsConfig {
    pub enabled: bool,
    /// Prometheus text on its own listener; must be a loopback address.
    pub bind: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct BackupConfig {
    /// Nightly online backup inside the server (MP-D1).
    pub enabled: bool,
    pub dir: PathBuf,
    /// UTC wall-clock time of the nightly run, `HH:MM`.
    pub time_utc: String,
    /// Dated files older than this many days are deleted after each run.
    pub retention_days: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AuthConfig {
    /// HS256 signing secret for access tokens. Required outside `server.env = "dev"`,
    /// at least `MIN_JWT_SECRET_BYTES` long. Environment only, never logged.
    pub jwt_secret: Secret,
    /// Server pepper for device-secret hashes (HMAC-SHA256 key). Required outside
    /// `dev`, at least `MIN_JWT_SECRET_BYTES` long, different from `jwt_secret`.
    /// Never rotate it: stored device-secret hashes depend on it.
    pub device_secret_pepper: Secret,
    /// Spec: access tokens live 1 hour.
    pub access_token_ttl_secs: u64,
    /// Spec: refresh tokens live 30 days (each rotation issues a fresh 30 days).
    pub refresh_token_ttl_secs: u64,
    /// Spec: a display name can be changed once every 30 days.
    pub rename_cooldown_secs: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RateLimitsConfig {
    /// Turns every HTTP rate limit off (never in production).
    pub enabled: bool,
    /// `POST /api/v1/auth/device` per client IP: this many per hour, refilled
    /// evenly, with `device_create_burst` available at once.
    pub device_create_per_hour: u32,
    pub device_create_burst: u32,
    /// The other `/api/v1/auth/*` routes (login, refresh, logout, providers) per IP.
    pub auth_per_minute: u32,
    pub auth_burst: u32,
    /// Authenticated routes (`/me`, `/account`, later everything) per account.
    pub account_per_minute: u32,
    pub account_burst: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct HttpConfig {
    /// CORS allow-list for the HTTP API (the web build is served from another
    /// origin). `["*"]` allows any origin (local dev); auth uses bearer tokens,
    /// not cookies.
    pub cors_allowed_origins: Vec<String>,
    /// Largest accepted JSON request body on `/api/*`.
    pub max_body_bytes: usize,
    /// CIDRs of reverse proxies whose `X-Forwarded-For` is believed (Coolify's
    /// proxy reaches the container from a Docker network). A peer outside these
    /// is the client itself and its `X-Forwarded-For` is ignored.
    pub trusted_proxies: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DeepLinksConfig {
    /// Directory holding `apple-app-site-association` and `assetlinks.json`.
    /// Empty, or a missing file, serves the built-in placeholder.
    pub dir: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct GatewayConfig {
    /// The first message must be `Hello`, within this long after the upgrade
    /// (else a fatal `handshake_required`).
    pub hello_timeout_ms: u64,
    /// Server tick rate announced in `Welcome` and used by `Pong` (spec: 20 Hz).
    pub tick_rate_hz: u8,
    /// Oldest `Hello.client_build` accepted (older → `update_required`).
    pub min_client_build: u32,
    /// Accepted `Hello.map_hash` values, 64 hex characters each (the SHA-256 of the loop's
    /// road-space file; N3 provides `loop_v1`'s). Empty: any hash in `server.env = "dev"`,
    /// none in production (every `Hello` gets `map_mismatch`).
    pub map_hashes: Vec<String>,
    /// How often live sessions are re-checked against the database for bans, deleted
    /// accounts and revoked tokens (the admin CLI is a separate process).
    pub ban_recheck_ms: u64,
    /// After a fatal `Error`, wait up to this long for the client to close before sending
    /// the close frame, so the error is not read together with the close (some clients,
    /// Godot's `WebSocketPeer` among them, then drop the error).
    pub fatal_close_delay_ms: u64,
    /// Serve the `/ws/echo` ops route (the echo-check page and the echo tools).
    pub echo_enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct WsRateLimitsConfig {
    /// Per-connection limits on every client → server message type (`/ws`).
    pub enabled: bool,
    /// Each type: messages per second refilled evenly, and the burst available at once.
    pub ping_per_sec: f64,
    pub ping_burst: u32,
    pub lobby_command_per_sec: f64,
    pub lobby_command_burst: u32,
    pub player_state_per_sec: f64,
    pub player_state_burst: u32,
    pub score_claim_per_sec: f64,
    pub score_claim_burst: u32,
    pub hit_report_per_sec: f64,
    pub hit_report_burst: u32,
    pub run_event_per_sec: f64,
    pub run_event_burst: u32,
    pub quick_chat_per_sec: f64,
    pub quick_chat_burst: u32,
    pub room_host_command_per_sec: f64,
    pub room_host_command_burst: u32,
    /// Every dropped message takes one token from this bucket; a client that empties it is
    /// disconnected with a fatal `rate_limited`.
    pub violation_per_sec: f64,
    pub violation_burst: u32,
    /// After a drop, a non-fatal `rate_limited` error goes out at most this often.
    pub notice_interval_ms: u64,
}

/// Production domain (owner, 2026-09-29).
pub const DEFAULT_PUBLIC_ORIGIN: &str = "https://westbound.sipsakrandevu.com";
/// The web build on GitHub Pages, until it moves to the production domain.
pub const WEB_BUILD_ORIGIN: &str = "https://b3vet.github.io";
pub const MIN_JWT_SECRET_BYTES: usize = 32;
/// `server.env` values.
pub const ENV_PRODUCTION: &str = "production";
pub const ENV_DEV: &str = "dev";
const SERVER_ENVS: &[&str] = &[ENV_PRODUCTION, ENV_DEV];
/// Bounds for `http.max_body_bytes`.
const MIN_BODY_BYTES: usize = 256;
const MAX_BODY_BYTES: usize = 1024 * 1024;
const MIN_MESSAGE_BYTES: usize = 1024;
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
const MAX_WORKER_THREADS: usize = 64;
const LOG_FORMATS: &[&str] = &["text", "json"];

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            env: ENV_PRODUCTION.into(),
            bind: "0.0.0.0:8080".into(),
            public_origin: DEFAULT_PUBLIC_ORIGIN.into(),
            worker_threads: 2,
            shutdown_grace_ms: 5_000,
            restart_notice_secs: 0,
        }
    }
}

impl Default for LogConfig {
    fn default() -> Self {
        Self {
            level: "info".into(),
            format: "text".into(),
        }
    }
}

impl Default for DbConfig {
    fn default() -> Self {
        Self {
            path: "/data/westbound.db".into(),
            max_connections: 4,
            busy_timeout_ms: 5_000,
            migrate_on_start: true,
        }
    }
}

impl Default for LimitsConfig {
    fn default() -> Self {
        Self {
            max_message_bytes: 16 * 1024,
            outbound_queue_frames: 64,
            ping_interval_ms: 2_000,
            dead_after_ms: 8_000,
            max_rooms: 40,
            max_connections: 400,
        }
    }
}

impl Default for MetricsConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            bind: "127.0.0.1:9090".into(),
        }
    }
}

impl Default for BackupConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            dir: "/data/backups".into(),
            time_utc: "03:17".into(),
            retention_days: 7,
        }
    }
}

impl Default for HttpConfig {
    fn default() -> Self {
        Self {
            cors_allowed_origins: vec![DEFAULT_PUBLIC_ORIGIN.into(), WEB_BUILD_ORIGIN.into()],
            max_body_bytes: 4 * 1024,
            // Loopback and the private ranges Docker networks use: Coolify's proxy
            // reaches the container from one of these. Public peers never match.
            trusted_proxies: [
                "127.0.0.0/8",
                "::1/128",
                "10.0.0.0/8",
                "172.16.0.0/12",
                "192.168.0.0/16",
                "fc00::/7",
            ]
            .map(String::from)
            .to_vec(),
        }
    }
}

impl Default for AuthConfig {
    fn default() -> Self {
        Self {
            jwt_secret: Secret::default(),
            device_secret_pepper: Secret::default(),
            access_token_ttl_secs: 3_600,
            refresh_token_ttl_secs: 30 * 86_400,
            rename_cooldown_secs: 30 * 86_400,
        }
    }
}

impl Default for RateLimitsConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            device_create_per_hour: 5,
            device_create_burst: 5,
            auth_per_minute: 30,
            auth_burst: 10,
            account_per_minute: 120,
            account_burst: 30,
        }
    }
}

impl Default for GatewayConfig {
    fn default() -> Self {
        Self {
            hello_timeout_ms: 5_000,
            tick_rate_hz: protocol::handshake::DEFAULT_TICK_RATE_HZ,
            min_client_build: 0,
            map_hashes: Vec::new(),
            ban_recheck_ms: 30_000,
            fatal_close_delay_ms: 1_000,
            echo_enabled: true,
        }
    }
}

impl Default for WsRateLimitsConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            // The client pings every 2 s.
            ping_per_sec: 2.0,
            ping_burst: 5,
            lobby_command_per_sec: 5.0,
            lobby_command_burst: 10,
            // 20 Hz uploads plus jitter bunching.
            player_state_per_sec: 25.0,
            player_state_burst: 40,
            // About two claims a second, more in trains.
            score_claim_per_sec: 10.0,
            score_claim_burst: 20,
            hit_report_per_sec: 5.0,
            hit_report_burst: 10,
            run_event_per_sec: 2.0,
            run_event_burst: 5,
            quick_chat_per_sec: 1.0,
            quick_chat_burst: 3,
            room_host_command_per_sec: 2.0,
            room_host_command_burst: 5,
            violation_per_sec: 5.0,
            violation_burst: 100,
            notice_interval_ms: 1_000,
        }
    }
}

impl WsRateLimitsConfig {
    /// `(name, per_sec, burst)` for every limited type and the violation bucket.
    pub fn entries(&self) -> [(&'static str, f64, u32); 9] {
        [
            ("ping", self.ping_per_sec, self.ping_burst),
            (
                "lobby_command",
                self.lobby_command_per_sec,
                self.lobby_command_burst,
            ),
            (
                "player_state",
                self.player_state_per_sec,
                self.player_state_burst,
            ),
            (
                "score_claim",
                self.score_claim_per_sec,
                self.score_claim_burst,
            ),
            ("hit_report", self.hit_report_per_sec, self.hit_report_burst),
            ("run_event", self.run_event_per_sec, self.run_event_burst),
            ("quick_chat", self.quick_chat_per_sec, self.quick_chat_burst),
            (
                "room_host_command",
                self.room_host_command_per_sec,
                self.room_host_command_burst,
            ),
            ("violation", self.violation_per_sec, self.violation_burst),
        ]
    }
}

/// Parses a 64-hex-character map hash.
pub fn parse_map_hash(s: &str) -> Option<protocol::MapHash> {
    let s = s.trim();
    if s.len() != 2 * protocol::types::MAP_HASH_LEN || !s.is_ascii() {
        return None;
    }
    let mut out = [0u8; protocol::types::MAP_HASH_LEN];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(s.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(protocol::MapHash(out))
}

/// Validation failures, all of them at once.
#[derive(Debug, thiserror::Error)]
#[error("invalid config:\n  - {}", .0.join("\n  - "))]
pub struct ConfigErrors(pub Vec<String>);

impl Config {
    /// Loads `path` (if given) over the defaults, applies `WB_*` overrides from
    /// `env`, and validates.
    pub fn load<I>(path: Option<&Path>, env: I) -> anyhow::Result<Config>
    where
        I: IntoIterator<Item = (String, String)>,
    {
        let text = match path {
            Some(p) => std::fs::read_to_string(p)
                .with_context(|| format!("reading config file {}", p.display()))?,
            None => String::new(),
        };
        let cfg = Self::from_toml_and_env(&text, env)?;
        cfg.validate()?;
        Ok(cfg)
    }

    /// Parses TOML text over the defaults and applies env overrides. No validation.
    pub fn from_toml_and_env<I>(text: &str, env: I) -> anyhow::Result<Config>
    where
        I: IntoIterator<Item = (String, String)>,
    {
        let defaults = toml::Table::try_from(Config::default()).context("serializing defaults")?;
        let file: toml::Table = toml::from_str(text).context("parsing config TOML")?;
        let mut merged = defaults.clone();
        merge_tables(&mut merged, file);
        let mut overrides: Vec<(String, String)> = env
            .into_iter()
            .filter(|(k, _)| k.starts_with(ENV_PREFIX) && !ENV_NON_KEYS.contains(&k.as_str()))
            .collect();
        overrides.sort();
        for (key, raw) in overrides {
            apply_env_override(&mut merged, &defaults, &key, &raw)?;
        }
        let cfg: Config = merged
            .try_into()
            .context("config does not match the schema")?;
        Ok(cfg)
    }

    pub fn validate(&self) -> Result<(), ConfigErrors> {
        let mut errs = Vec::new();
        let s = &self.server;
        if !SERVER_ENVS.contains(&s.env.as_str()) {
            errs.push(format!("server.env must be one of {SERVER_ENVS:?}"));
        }
        if s.bind.parse::<SocketAddr>().is_err() {
            errs.push(format!(
                "server.bind `{}` is not an ip:port socket address",
                s.bind
            ));
        }
        if !is_origin(&s.public_origin) {
            errs.push(format!(
                "server.public_origin `{}` must be an origin like https://example.com (no path)",
                s.public_origin
            ));
        }
        if s.worker_threads == 0 || s.worker_threads > MAX_WORKER_THREADS {
            errs.push(format!(
                "server.worker_threads must be 1..={MAX_WORKER_THREADS}"
            ));
        }
        if tracing_subscriber::EnvFilter::try_new(&self.log.level).is_err() {
            errs.push(format!(
                "log.level `{}` is not a valid filter directive",
                self.log.level
            ));
        }
        if !LOG_FORMATS.contains(&self.log.format.as_str()) {
            errs.push(format!("log.format must be one of {LOG_FORMATS:?}"));
        }
        if self.db.path.as_os_str().is_empty() {
            errs.push("db.path must be set".into());
        }
        if self.db.max_connections == 0 {
            errs.push("db.max_connections must be at least 1".into());
        }
        let l = &self.limits;
        if !(MIN_MESSAGE_BYTES..=MAX_MESSAGE_BYTES).contains(&l.max_message_bytes) {
            errs.push(format!(
                "limits.max_message_bytes must be {MIN_MESSAGE_BYTES}..={MAX_MESSAGE_BYTES}"
            ));
        }
        if l.outbound_queue_frames == 0 {
            errs.push("limits.outbound_queue_frames must be at least 1".into());
        }
        if l.ping_interval_ms == 0 {
            errs.push("limits.ping_interval_ms must be at least 1".into());
        }
        if l.dead_after_ms <= l.ping_interval_ms {
            errs.push("limits.dead_after_ms must be greater than limits.ping_interval_ms".into());
        }
        if l.max_rooms == 0 {
            errs.push("limits.max_rooms must be at least 1".into());
        }
        if l.max_connections == 0 {
            errs.push("limits.max_connections must be at least 1".into());
        }
        // `Welcome` carries both as u16 milliseconds.
        if l.ping_interval_ms > u64::from(u16::MAX) || l.dead_after_ms > u64::from(u16::MAX) {
            errs.push(format!(
                "limits.ping_interval_ms and limits.dead_after_ms must be at most {}",
                u16::MAX
            ));
        }
        let g = &self.gateway;
        if g.hello_timeout_ms == 0 {
            errs.push("gateway.hello_timeout_ms must be at least 1".into());
        }
        if g.tick_rate_hz == 0 || g.tick_rate_hz > protocol::messages::MAX_TICK_RATE_HZ {
            errs.push(format!(
                "gateway.tick_rate_hz must be 1..={}",
                protocol::messages::MAX_TICK_RATE_HZ
            ));
        }
        for h in &g.map_hashes {
            if parse_map_hash(h).is_none() {
                errs.push(format!(
                    "gateway.map_hashes entry `{h}` must be 64 hex characters (a SHA-256)"
                ));
            }
        }
        if g.ban_recheck_ms == 0 {
            errs.push("gateway.ban_recheck_ms must be at least 1".into());
        }
        let w = &self.ws_rate_limits;
        if w.enabled {
            for (name, per_sec, burst) in w.entries() {
                if !(per_sec.is_finite() && per_sec > 0.0) || burst == 0 {
                    errs.push(format!(
                        "ws_rate_limits.{name}_per_sec must be above 0 and ws_rate_limits.{name}_burst at least 1"
                    ));
                }
            }
        }
        if self.metrics.enabled {
            match self.metrics.bind.parse::<SocketAddr>() {
                Ok(a) if a.ip().is_loopback() => {}
                Ok(_) => errs.push(format!(
                    "metrics.bind `{}` must be a loopback address (127.0.0.1 or ::1)",
                    self.metrics.bind
                )),
                Err(_) => errs.push(format!(
                    "metrics.bind `{}` is not an ip:port socket address",
                    self.metrics.bind
                )),
            }
        }
        if self.backup.enabled {
            if self.backup.dir.as_os_str().is_empty() {
                errs.push("backup.dir must be set when backups are enabled".into());
            }
            if parse_hh_mm(&self.backup.time_utc).is_none() {
                errs.push(format!(
                    "backup.time_utc `{}` must be HH:MM (UTC)",
                    self.backup.time_utc
                ));
            }
            if self.backup.retention_days == 0 {
                errs.push("backup.retention_days must be at least 1".into());
            }
        }
        let a = &self.auth;
        for (key, secret) in [
            ("auth.jwt_secret", &a.jwt_secret),
            ("auth.device_secret_pepper", &a.device_secret_pepper),
        ] {
            if secret.is_empty() {
                if !self.is_dev() {
                    errs.push(format!(
                        "{key} is required (set WB_{}); only server.env = \"dev\" may leave it empty",
                        key.to_ascii_uppercase().replace('.', "__")
                    ));
                }
            } else if secret.expose().len() < MIN_JWT_SECRET_BYTES {
                errs.push(format!(
                    "{key} must be at least {MIN_JWT_SECRET_BYTES} bytes"
                ));
            }
        }
        if !a.jwt_secret.is_empty() && a.jwt_secret == a.device_secret_pepper {
            errs.push("auth.device_secret_pepper must differ from auth.jwt_secret".into());
        }
        if a.access_token_ttl_secs == 0 || a.refresh_token_ttl_secs <= a.access_token_ttl_secs {
            errs.push(
                "auth.access_token_ttl_secs must be at least 1 and below auth.refresh_token_ttl_secs"
                    .into(),
            );
        }
        let r = &self.rate_limits;
        if r.enabled
            && [
                r.device_create_per_hour,
                r.device_create_burst,
                r.auth_per_minute,
                r.auth_burst,
                r.account_per_minute,
                r.account_burst,
            ]
            .contains(&0)
        {
            errs.push("rate_limits.* rates and bursts must be at least 1".into());
        }
        if !(MIN_BODY_BYTES..=MAX_BODY_BYTES).contains(&self.http.max_body_bytes) {
            errs.push(format!(
                "http.max_body_bytes must be {MIN_BODY_BYTES}..={MAX_BODY_BYTES}"
            ));
        }
        for p in &self.http.trusted_proxies {
            if crate::ratelimit::Cidr::parse(p).is_none() {
                errs.push(format!(
                    "http.trusted_proxies entry `{p}` must be a CIDR like 10.0.0.0/8 or an IP"
                ));
            }
        }
        for o in &self.http.cors_allowed_origins {
            if o != "*" && !is_origin(o) {
                errs.push(format!(
                    "http.cors_allowed_origins entry `{o}` must be `*` or an http(s) origin"
                ));
            }
        }
        if errs.is_empty() {
            Ok(())
        } else {
            Err(ConfigErrors(errs))
        }
    }

    /// `server.env = "dev"`: development defaults for the auth secrets.
    pub fn is_dev(&self) -> bool {
        self.server.env == ENV_DEV
    }

    pub fn bind_addr(&self) -> SocketAddr {
        self.server.bind.parse().expect("validated")
    }

    pub fn metrics_addr(&self) -> Option<SocketAddr> {
        self.metrics
            .enabled
            .then(|| self.metrics.bind.parse().expect("validated"))
    }

    pub fn ping_interval(&self) -> Duration {
        Duration::from_millis(self.limits.ping_interval_ms)
    }

    pub fn dead_after(&self) -> Duration {
        Duration::from_millis(self.limits.dead_after_ms)
    }

    pub fn hello_timeout(&self) -> Duration {
        Duration::from_millis(self.gateway.hello_timeout_ms)
    }

    pub fn shutdown_grace(&self) -> Duration {
        Duration::from_millis(self.server.shutdown_grace_ms)
    }

    /// Effective config as TOML with secrets redacted (for `check-config`).
    pub fn to_redacted_toml(&self) -> String {
        let mut c = self.clone();
        for secret in [&mut c.auth.jwt_secret, &mut c.auth.device_secret_pepper] {
            if !secret.is_empty() {
                *secret = Secret::new("<redacted>");
            }
        }
        toml::to_string_pretty(&c).unwrap_or_else(|e| format!("# cannot render config: {e}"))
    }
}

/// `http(s)://host[:port]`, no path, no trailing slash.
fn is_origin(s: &str) -> bool {
    let rest = s
        .strip_prefix("https://")
        .or_else(|| s.strip_prefix("http://"));
    matches!(rest, Some(r) if !r.is_empty() && !r.contains('/') && !r.contains(char::is_whitespace))
}

/// `HH:MM` → minutes after midnight.
pub fn parse_hh_mm(s: &str) -> Option<u32> {
    let (h, m) = s.split_once(':')?;
    if h.len() != 2 || m.len() != 2 {
        return None;
    }
    let h: u32 = h.parse().ok()?;
    let m: u32 = m.parse().ok()?;
    (h < 24 && m < 60).then_some(h * 60 + m)
}

fn merge_tables(base: &mut toml::Table, over: toml::Table) {
    for (k, v) in over {
        match (base.get_mut(&k), v) {
            (Some(toml::Value::Table(b)), toml::Value::Table(o)) => merge_tables(b, o),
            (_, v) => {
                base.insert(k, v);
            }
        }
    }
}

/// `WB_LIMITS__MAX_CONNECTIONS=200` sets `limits.max_connections`. The value is
/// parsed according to the type of the default at that path, so unknown keys and
/// bad values fail loudly instead of being ignored.
fn apply_env_override(
    merged: &mut toml::Table,
    defaults: &toml::Table,
    key: &str,
    raw: &str,
) -> anyhow::Result<()> {
    let path: Vec<String> = key[ENV_PREFIX.len()..]
        .split("__")
        .map(|p| p.to_ascii_lowercase())
        .collect();
    if path.len() != 2 || path.iter().any(|p| p.is_empty()) {
        bail!("env override {key}: expected WB_<SECTION>__<KEY>");
    }
    let (section, field) = (&path[0], &path[1]);
    let template = defaults
        .get(section)
        .and_then(|s| s.as_table())
        .and_then(|t| t.get(field))
        .with_context(|| format!("env override {key}: unknown config key {section}.{field}"))?;
    let value = match template {
        toml::Value::String(_) => toml::Value::String(raw.to_string()),
        toml::Value::Integer(_) => toml::Value::Integer(
            raw.trim()
                .parse()
                .with_context(|| format!("env override {key}: expected an integer"))?,
        ),
        toml::Value::Float(_) => toml::Value::Float(
            raw.trim()
                .parse()
                .with_context(|| format!("env override {key}: expected a number"))?,
        ),
        toml::Value::Boolean(_) => toml::Value::Boolean(match raw.trim() {
            "1" | "true" | "yes" | "on" => true,
            "0" | "false" | "no" | "off" => false,
            _ => bail!("env override {key}: expected true/false"),
        }),
        toml::Value::Array(_) => toml::Value::Array(
            raw.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|s| toml::Value::String(s.to_string()))
                .collect(),
        ),
        _ => bail!("env override {key}: this key cannot be set from the environment"),
    };
    let table = merged
        .entry(section.clone())
        .or_insert_with(|| toml::Value::Table(toml::Table::new()));
    let table = table
        .as_table_mut()
        .with_context(|| format!("config section {section} is not a table"))?;
    table.insert(field.clone(), value);
    Ok(())
}
