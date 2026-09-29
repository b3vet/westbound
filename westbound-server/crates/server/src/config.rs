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
    pub deeplinks: DeepLinksConfig,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ServerConfig {
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

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AuthConfig {
    /// HS256 signing secret for access tokens (used from N1). Empty is allowed in
    /// N0; when set it must be at least `MIN_JWT_SECRET_BYTES` long.
    pub jwt_secret: Secret,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct HttpConfig {
    /// CORS allow-list for the HTTP API (the web build is served from another
    /// origin). `["*"]` allows any origin (local dev); auth uses bearer tokens,
    /// not cookies.
    pub cors_allowed_origins: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DeepLinksConfig {
    /// Directory holding `apple-app-site-association` and `assetlinks.json`.
    /// Empty, or a missing file, serves the built-in placeholder.
    pub dir: PathBuf,
}

/// Production domain (owner, 2026-09-29).
pub const DEFAULT_PUBLIC_ORIGIN: &str = "https://westbound.sipsakrandevu.com";
/// The web build on GitHub Pages, until it moves to the production domain.
pub const WEB_BUILD_ORIGIN: &str = "https://b3vet.github.io";
pub const MIN_JWT_SECRET_BYTES: usize = 32;
const MIN_MESSAGE_BYTES: usize = 1024;
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
const MAX_WORKER_THREADS: usize = 64;
const LOG_FORMATS: &[&str] = &["text", "json"];

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
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
        }
    }
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
        let secret = &self.auth.jwt_secret;
        if !secret.is_empty() && secret.expose().len() < MIN_JWT_SECRET_BYTES {
            errs.push(format!(
                "auth.jwt_secret must be at least {MIN_JWT_SECRET_BYTES} bytes when set"
            ));
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

    pub fn shutdown_grace(&self) -> Duration {
        Duration::from_millis(self.server.shutdown_grace_ms)
    }

    /// Effective config as TOML with secrets redacted (for `check-config`).
    pub fn to_redacted_toml(&self) -> String {
        let mut c = self.clone();
        if !c.auth.jwt_secret.is_empty() {
            c.auth.jwt_secret = Secret::new("<redacted>");
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
