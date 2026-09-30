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
    pub leaderboards: LeaderboardsConfig,
    pub runs: RunsConfig,
    pub social: SocialConfig,
    pub replays: ReplaysConfig,
    pub rooms: RoomsConfig,
    pub scoring: ScoringConfig,
    /// N10.2: the admin API (live rooms, notices, stats) the `admin` CLI talks to.
    pub admin: AdminConfig,
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
    /// N10.2: on SIGTERM, seconds of `server_notice{restart}` before the rooms are handed
    /// over and the sockets close (spec: 60). The notice ends early once nobody is
    /// connected. 0 = no notice (the handover still runs).
    pub restart_notice_secs: u64,
    /// Reminders during the notice, as seconds left (those not below the notice are skipped).
    pub restart_notice_reminders_secs: Vec<u64>,
    /// How long the next instance recreates a handed-over room when a player rejoins it by
    /// code (docs/OPERATIONS.md → Restarts).
    pub handover_ttl_secs: u64,
}

/// `[admin]` (N10.2): the admin API on its own loopback listener.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AdminConfig {
    /// Serve the admin API (it also needs a token).
    pub enabled: bool,
    /// Loopback only, like the metrics listener.
    pub bind: String,
    /// Bearer token for the admin API (`WB_ADMIN__TOKEN`, at least 32 bytes). Empty: the
    /// API is off and the live admin commands (rooms, notices, kicks) are unavailable.
    pub token: Secret,
    /// How long an `admin` CLI command waits for the running server.
    pub request_timeout_ms: u64,
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
    /// N10.2: how often the server times a database probe and reads its sizes and queue
    /// depths for `/metrics`.
    pub db_probe_interval_secs: u64,
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
    /// N10.2: after each backup, open it read-only and run `PRAGMA integrity_check`.
    pub verify: bool,
    /// N10.2: optional off-site hook, run after each good backup: argv, `{file}` is the
    /// backup's path (no shell). Empty = off. docs/OPERATIONS.md → Off-site copies.
    pub upload_command: Vec<String>,
    /// The hook is killed after this long.
    pub upload_timeout_secs: u64,
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
    /// Run submissions (`POST /api/v1/runs` and `/runs/legacy`) per account, on top of
    /// the account limit: this many per hour, `runs_burst` at once.
    pub runs_per_hour: u32,
    pub runs_burst: u32,
    /// Social writes (friend requests, blocks, crew create / join, reports) per account, on
    /// top of the account limit: this many per hour, `social_burst` at once (N9.1).
    pub social_per_hour: u32,
    pub social_burst: u32,
    /// N10.2: every HTTP route (API, upgrades, deep-link files, invite pages, health) per
    /// client IP, on top of the route's own limit. Generous: players behind one carrier
    /// NAT share it.
    pub ip_per_minute: u32,
    pub ip_burst: u32,
    /// N10.2: WebSocket upgrades (`/ws`, `/ws/echo`) per client IP.
    pub ws_connect_per_minute: u32,
    pub ws_connect_burst: u32,
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

/// Deep links (N9.3; docs/SERVER.md → "Invite links and deep links"): the association
/// files and the `/r/<code>` invite page.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DeepLinksConfig {
    /// Directory holding `apple-app-site-association` and `assetlinks.json`. A file there
    /// wins; without one the file is generated from the app ids below, and without those
    /// the built-in (empty) placeholder is served.
    pub dir: PathBuf,
    /// Where the invite page's button opens the web build: `{code}` is the room or party
    /// code, `{origin}` is `server.public_origin` (for a web build on another host that must
    /// be told which server to use).
    pub web_join_url: String,
    /// iOS Universal Links: app ids (`TEAMID.bundle.id`) for `apple-app-site-association`.
    pub apple_app_ids: Vec<String>,
    /// Android App Links: the package name for `assetlinks.json`.
    pub android_package: String,
    /// Android App Links: SHA-256 fingerprints of the signing certificates (`AA:BB:...`).
    pub android_cert_sha256: Vec<String>,
    /// Store links on the invite page (empty: "coming soon").
    pub app_store_url: String,
    pub play_store_url: String,
    /// A custom URL scheme the native app registers (`<scheme>://r/<code>`); empty: the page
    /// shows no "open in the app" button (Universal / App Links open the app anyway).
    pub app_scheme: String,
}

impl Default for DeepLinksConfig {
    fn default() -> Self {
        Self {
            dir: PathBuf::new(),
            web_join_url: "https://b3vet.github.io/westbound/?room={code}".into(),
            apple_app_ids: Vec::new(),
            android_package: String::new(),
            android_cert_sha256: Vec::new(),
            app_store_url: String::new(),
            play_store_url: String::new(),
            app_scheme: String::new(),
        }
    }
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

/// Leaderboard reads, caching and the replay trigger (N7.1; docs/SERVER.md →
/// "Leaderboards & runs API").
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct LeaderboardsConfig {
    /// Until the replay verifier (N8) exists: whether `pending` runs (awaiting their
    /// replay) go on the boards, marked "verifying". When false they wait in `runs` and
    /// N8 writes them once verified. Applies to runs recorded from then on.
    pub show_pending: bool,
    /// `view=global`: entries returned when `limit` is left out, and the most allowed
    /// (spec: global top 100).
    pub global_limit_default: u32,
    pub global_limit_max: u32,
    /// `view=around_me`: ranks on each side of the caller when `limit` is left out, and
    /// the most allowed.
    pub around_me_default: u32,
    pub around_me_max: u32,
    /// A run that improves the player's entry and ranks within this many places of a
    /// board it is written to needs a replay (spec: "the top 100 of any board").
    pub replay_top_n: u32,
    /// Top-N cache per board and period: dropped on every write to it, and after this
    /// many seconds anyway (renames, admin CLI removals from another process).
    pub cache_ttl_secs: u64,
    /// Most board/period pairs cached at once; past it the cache starts over.
    pub cache_max_boards: usize,
    /// Loop crew board: a crew's score is the sum of its best this many members'
    /// season-best Loop runs (spec: top 4).
    pub crew_top_members: u32,
    /// Legacy personal-best upload (`POST /api/v1/runs/legacy`): the largest Journey
    /// score and Distance (metres) accepted; anything above is refused as `over_cap`.
    pub legacy_max_journey_score: u64,
    pub legacy_max_distance_m: f64,
}

/// Friends, blocks, crews and reports (N9.1; docs/SERVER.md → "Social API"). Spec:
/// "Rooms, parties and matchmaking" (friends, crews of up to 16), "Moderation" (reports
/// rate-limited per account).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SocialConfig {
    /// Accepted friends per account.
    pub max_friends: u32,
    /// Friend requests an account may have waiting on others at once.
    pub max_outgoing_requests: u32,
    /// Friend requests an account may have waiting on it at once (more are refused).
    pub max_incoming_requests: u32,
    /// Accounts one account may block.
    pub max_blocks: u32,
    /// Members per crew, the owner included (spec: 16).
    pub crew_max_members: u32,
    /// Characters in a crew invite code (from the protocol's code alphabet).
    pub crew_invite_code_len: u32,
    /// Reports one account may file per rolling 24 hours.
    pub reports_per_day: u32,
    /// Largest `context` of a report, as compact JSON.
    pub report_context_max_bytes: u32,
    /// Members per party, the leader included (N9.3; spec: up to 8; the wire allows 16).
    pub party_max_members: u32,
    /// A party member whose connection ended keeps their place this long; a new session
    /// takes it back (not in spec).
    pub party_member_hold_ms: u64,
}

/// Replay uploads, the verification queue and replay retention (N8.1; docs/SERVER.md →
/// "Replays and verification"). Spec: "Leaderboards" (single-player runs, steps 3–5),
/// "Resource budget" (the verifier: one job at a time, `nice 10`, 1 GB).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ReplaysConfig {
    /// Where uploaded replays live (`<dir>/<run_id>.wbr`; the verifier's result files go
    /// to `<dir>/work/`). On the data volume.
    pub dir: PathBuf,
    /// Largest replay accepted (413 `body_too_large` above it). 4 MiB holds a 6-hour run.
    pub max_bytes: u64,
    /// The verifier command, one argv entry per item; each item may use `{replay}`,
    /// `{out}`, `{run_id}`, `{seed}`, `{mode}`, `{build}`, `{claimed_score}` and
    /// `{claimed_hits}`. Empty: no verifier (jobs wait as `pending`, runs stay
    /// "verifying"). Env: comma-separated.
    pub verifier_command: Vec<String>,
    /// Run the queue worker inside `serve`. Off when a sidecar runs `verify-worker`
    /// against the same database.
    pub worker_enabled: bool,
    /// A verifier run is killed after this long (the attempt fails).
    pub job_timeout_secs: u64,
    /// Attempts per job before it is `failed` (the run stays pending for an operator).
    pub max_attempts: u32,
    /// A failed attempt is retried after this long.
    pub retry_delay_secs: u64,
    /// The idle worker checks for jobs this often (an upload wakes it at once).
    pub poll_interval_secs: u64,
    /// Verified replays are kept while their run ranks within this on any board and
    /// period (spec: "deleted after verification except for current top-100 entries").
    pub keep_top_n: u32,
    /// How often the retention sweep runs (and finds orphan files).
    pub cleanup_interval_secs: u64,
}

/// Plausibility checks on single-player submissions (`POST /api/v1/runs`). Spec:
/// "Leaderboards" → single-player runs. The scoring numbers mirror the game's
/// `data/tuning/scoring.tres`, `legs.tres`, `lives.tres` and `vehicle.tres`; keep them
/// at or above the game's values (a bound, not a recomputation).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RunsConfig {
    /// Oldest client build (the protocol's u32 build number) whose runs are accepted.
    pub min_build: u32,
    /// Builds whose runs are accepted (decimal build numbers). Empty: every build from
    /// `min_build` on. N8 keeps a verifier per listed build (spec: build parity).
    pub supported_builds: Vec<String>,
    /// The banked score per minute of run time may not exceed this. A close pass at ×50,
    /// 250 km/h at night pays 30 × 50 × 2 × 2 = 6000; about 30 of those a minute.
    pub max_score_per_minute: f64,
    /// Runs shorter than this are treated as this long for the score rate (a crash in
    /// the first seconds with a few points is fine).
    pub min_duration_s: f64,
    /// Longest plausible run (the sun sets; journeys end at the coast).
    pub max_duration_s: f64,
    /// Highest plausible top speed: the fastest car (300 km/h) with boost (+8 %) and
    /// top-gear overshoot, rounded up.
    pub max_top_speed_kmh: f64,
    /// Distance may exceed top speed × duration by this fraction and this many metres
    /// (float rounding, the start line).
    pub distance_slack_pct: f64,
    pub distance_slack_m: f64,
    /// Each completed leg needs at least this much distance (legs.tres: 3.5 km legs; the
    /// first one starts a little in, forks change branch lengths).
    pub leg_min_length_m: f64,
    /// Checkpoints to the coast (legs.tres `legs_to_coast`): `coast_reached` needs this
    /// many legs.
    pub legs_to_coast: u32,
    /// Lives at the start (lives.tres). Hits ≤ lives + legs completed (a clean leg
    /// restores one).
    pub lives: u32,
    /// Base points and multiplier gains per event (scoring.tres).
    pub pass_points: f64,
    pub close_pass_points: f64,
    pub cut_points: f64,
    pub thread_points: f64,
    pub pass_multiplier_gain: f64,
    pub close_pass_multiplier_gain: f64,
    pub cut_multiplier_gain: f64,
    pub thread_multiplier_gain: f64,
    /// Starting multiplier (scoring.tres `multiplier_start`).
    pub multiplier_start: f64,
    /// Highest speed factor (scoring.tres `speed_factor_at_max`) and the night factor.
    pub speed_factor_max: f64,
    pub night_factor: f64,
    /// Most bonus points one leg can pay (legs.tres: clean 5000 + pace 3000 + threads
    /// 3000 + heat 5000 + objective 2500), before the night factor.
    pub leg_bonus_max_points: f64,
    /// Journey bonus at the coast (legs.tres `journey_bonus_points`).
    pub journey_bonus_points: f64,
    /// Headroom on the score bound from the stats, as a fraction.
    pub score_slack_pct: f64,
    /// A run's `date` (UTC) is accepted from this long before that day starts (clients
    /// with a fast clock)...
    pub date_early_secs: u64,
    /// ...until this long after it ends (a run finished near midnight, a retry after a
    /// network failure).
    pub date_late_secs: u64,
}

/// Rooms and players (N5.1; docs/SERVER.md → "Rooms"). Spec: "Rooms, parties and
/// matchmaking" (up to 8 players, host rules, the room closes 60 s after it empties),
/// "Players" (spawning, protection, crash-out, rejoin, the 15 s seat hold, plausibility
/// checks), "Time of day in multiplayer" (the 32 min cycle). The clock and car numbers
/// mirror the game's `data/tuning/loop.tres`, `data/cars/*.tres` and
/// `data/tuning/vehicle.tres`; `tests/rooms_data.rs` pins them to those files.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RoomsConfig {
    /// Seats per room (spec: up to 8). Private rooms may ask for fewer.
    pub max_players: u8,
    /// A room with no seats closes after this long (spec: 60 s).
    pub empty_close_ms: u64,
    /// A dropped player's seat (and run) is held this long (spec: 15 s).
    pub seat_hold_ms: u64,
    /// Spawn and rejoin protection (spec: 3 s).
    pub protection_ms: u64,
    /// After a crash-out, the results toast shows this long before the respawn (spec: 3 s).
    pub crash_respawn_ms: u64,
    /// Spawns land this far behind the crew leader (spec: about 40 m).
    pub spawn_behind_leader_m: f64,
    /// The free-gap search around a spawn spot: this far either way, in steps of this, each
    /// candidate needing this much room to the nearest car in its lane.
    pub spawn_search_m: f64,
    pub spawn_step_m: f64,
    pub spawn_clear_m: f64,
    /// Room traffic: `sim` (the `sim` crate's ring runs with the players in it, spawns use
    /// its gaps, and each client is streamed its area of interest) or `none` (no cars).
    pub traffic: String,
    /// Traffic streaming (N4.2; spec: "each client receives the cars from 300 m behind to
    /// 900 m ahead"): a car is sent when it enters this area around the player's s...
    pub traffic_aoi_behind_m: f64,
    pub traffic_aoi_ahead_m: f64,
    /// ...and despawned once it is this much further out (not in spec: no flapping at
    /// the edge).
    pub traffic_aoi_hysteresis_m: f64,
    /// Correction rates (spec: 5 Hz within 100 m, at least 1 Hz otherwise).
    pub traffic_near_m: f64,
    pub traffic_near_hz: u32,
    pub traffic_far_hz: u32,
    /// A despawned car's id is not reused for this long (MP-D6: 30 s).
    pub traffic_car_id_hold_ms: u64,
    /// The day/night cycle and its day part (loop.tres `room_cycle_min`, `room_day_min`).
    pub cycle_len_ms: u32,
    pub day_len_ms: u32,
    /// UTC instant (ms) at which a cycle starts (loop.tres `room_clock_epoch_unix_s`).
    pub clock_epoch_unix_ms: i64,
    /// Bounded command queue of each room task (connections `try_send` into it).
    pub command_queue: usize,
    /// A join waits this long for the room task's answer.
    pub join_timeout_ms: u64,
    /// Fastest car's top speed with boost: night_viper 285 km/h × (1 + 8 %).
    pub max_speed_kmh: f64,
    /// Speed may exceed `max_speed_kmh` by this much (spec: × 1.1).
    pub speed_tolerance_pct: f64,
    /// Strongest forward acceleration: engine traction 9 + boost thrust 3 m/s².
    pub max_accel_mps2: f64,
    /// Fastest lateral movement (m/s): a lane change peaks near 8.5 m/s, a swerve more.
    pub max_lateral_speed_mps: f64,
    /// Acceleration and lateral movement may exceed the car's by this much (spec: × 1.2).
    pub capability_tolerance_pct: f64,
    /// `d` may pass the median barrier or the guardrail by this much before it is clamped.
    pub lateral_margin_m: f64,
    /// Position slack on the distance checks (quantization, jitter).
    pub position_slack_m: f64,
    /// States stamped this far past the room clock are refused.
    pub future_tolerance_ms: u64,
    /// States older than this (behind the room clock) are dropped as stale.
    pub stale_state_ms: u64,
    /// After a server placement, states far from it are dropped for this long (in flight).
    pub placement_grace_ms: u64,
    /// A state within this distance of a placement (plus its speed's reach) acknowledges it.
    pub placement_radius_m: f64,
    /// N10.2: `room_create` per account (survives reconnects): this many per hour, refilled
    /// evenly, `create_burst` at once. Empty rooms live 60 s, so without it one account
    /// could fill the room cap (not in spec).
    pub create_per_hour: u32,
    pub create_burst: u32,
}

/// Multiplayer scoring (N6.1; docs/SERVER.md → "Scoring (N6.1)"). Spec: "Scoring in
/// multiplayer" (claims, verification, the official score, `ScoreSync`, hits, crew
/// proximity, trains), "Tuning reference". The scoring rules themselves are the game's
/// (`sim::scoring`, exported from `data/tuning/scoring.tres`); these are the server's.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ScoringConfig {
    /// A claim's tick must be within this of the server's own view of the event (spec:
    /// ±300 ms).
    pub claim_timing_ms: u64,
    /// A claimed clearance may be this much under the server's measurement, and a close
    /// pass or thread needs the server's under its threshold plus this (spec: +0.35 m).
    pub claim_clearance_tolerance_m: f64,
    /// Cuts: the named car's hull gap may pass the cut window by this much, the speed may
    /// be this much under the cut minimum (not in spec: 20 Hz states vs 120 Hz physics).
    pub cut_gap_tolerance_m: f64,
    pub cut_speed_tolerance_kmh: f64,
    /// A claim waits at most this long for the states that decide it (not in spec).
    pub claim_max_wait_ms: u64,
    /// Undecided claims held per player; more are rejected (not in spec).
    pub claim_queue: usize,
    /// The official score runs this far behind the room clock, so every claim, hit and
    /// crewmate pass of a tick is decided before the tick is paid (not in spec).
    pub official_lag_ms: u64,
    /// `ScoreSync` at least this often, and at every banking moment (spec: once a second).
    pub sync_interval_ms: u64,
    /// Crew proximity (spec): +0.25× per crewmate within 30 m on the loop, capped at ×2.0.
    pub crew_range_m: f64,
    pub crew_bonus_per_mate: f64,
    pub crew_factor_cap: f64,
    /// Trains (spec): the same car on the same side, or the same gap, within 1.0 s after a
    /// crewmate; 25 base points and +2 multiplier.
    pub train_window_ms: u64,
    pub train_points: i64,
    pub train_multiplier_gain: f64,
    /// Server hit detection (spec): hulls overlapping deeper than 0.3 m for 2+ ticks.
    pub hit_overlap_m: f64,
    pub hit_overlap_ticks: u32,
    /// A reported hit accounts for a server-detected contact this close in time (not in
    /// spec).
    pub hit_match_ms: u64,
    /// A reported traffic hit is accepted (the car reacts for everyone) when the server saw
    /// the hulls within this clearance of each other near its tick (not in spec).
    pub hit_confirm_clearance_m: f64,
    /// Leaderboard verification (deviation MP-D9): besides no plausibility offence and no
    /// unreported hit, a run needs at least this share of its decided claims accepted,
    /// once it has `verify_min_claims` of them.
    pub verify_min_acceptance_pct: f64,
    pub verify_min_claims: u32,
    /// The player hull the server measures with: the game's largest car (brute_v8 4.8 ×
    /// 1.95 m), so the server never measures a clearance larger than the client's for its
    /// body (not in spec: `PlayerState` has no car).
    pub player_length_m: f64,
    pub player_width_m: f64,
    /// Cars are tracked for passes from this far ahead of the player (not in spec).
    pub track_ahead_m: f64,
    /// `room_event.crew` session totals go out at most this often per crew (not in spec).
    pub crew_total_interval_ms: u64,
    /// N10.1 shadow collision logging: each player sees the other this long behind when
    /// the two views' disagreement is estimated (spec: remote players shown 100 ms behind).
    pub shadow_view_delay_ms: u64,
    /// One in this many of a room's shadow records (player contacts, unreported traffic
    /// contacts, refused hits) is logged, the first always (not in spec).
    pub shadow_log_every: u64,
}

impl Default for ScoringConfig {
    fn default() -> Self {
        Self {
            claim_timing_ms: 300,
            claim_clearance_tolerance_m: 0.35,
            cut_gap_tolerance_m: 2.0,
            cut_speed_tolerance_kmh: 5.0,
            claim_max_wait_ms: 1_000,
            claim_queue: 32,
            official_lag_ms: 1_500,
            sync_interval_ms: 1_000,
            crew_range_m: 30.0,
            crew_bonus_per_mate: 0.25,
            crew_factor_cap: 2.0,
            train_window_ms: 1_000,
            train_points: 25,
            train_multiplier_gain: 2.0,
            hit_overlap_m: 0.3,
            hit_overlap_ticks: 2,
            hit_match_ms: 1_500,
            hit_confirm_clearance_m: 1.0,
            verify_min_acceptance_pct: 90.0,
            verify_min_claims: 20,
            player_length_m: 4.8,
            player_width_m: 1.95,
            track_ahead_m: 60.0,
            crew_total_interval_ms: 1_000,
            shadow_view_delay_ms: 100,
            shadow_log_every: 10,
        }
    }
}

/// `rooms.traffic` values.
pub const ROOM_TRAFFIC_NONE: &str = "none";
pub const ROOM_TRAFFIC_SIM: &str = "sim";
const ROOM_TRAFFIC: &[&str] = &[ROOM_TRAFFIC_NONE, ROOM_TRAFFIC_SIM];
/// `scoring.official_lag_ms` bound: the scoring rings hold 64 ticks (3.2 s at 20 Hz).
const MAX_OFFICIAL_LAG_MS: u64 = 2_500;
/// `scoring.shadow_view_delay_ms` bound: with the official lag it stays inside the rings.
const MAX_SHADOW_VIEW_DELAY_MS: u64 = 500;
/// The area of interest must stay well inside the 25 km loop's half (wrapped distances).
const MAX_AOI_SPAN_M: f64 = 10_000.0;

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
/// `server_notice.seconds` is a u16.
const MAX_RESTART_NOTICE_SECS: u64 = u16::MAX as u64;
const LOG_FORMATS: &[&str] = &["text", "json"];
/// Crew invite codes: long enough not to be guessed under the rate limits, short enough to
/// type.
/// `replays.max_bytes` bounds: a header's worth, and 64 MiB.
const MIN_REPLAY_BYTES: u64 = 1_024;
const MAX_REPLAY_BYTES: u64 = 64 * 1024 * 1024;
const MIN_INVITE_CODE_LEN: u32 = 6;
const MAX_INVITE_CODE_LEN: u32 = 16;
/// A report's `context` must fit in a request body.
const MIN_REPORT_CONTEXT_BYTES: u32 = 2;
const MAX_REPORT_CONTEXT_BYTES: u32 = 4_096;

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            env: ENV_PRODUCTION.into(),
            bind: "0.0.0.0:8080".into(),
            public_origin: DEFAULT_PUBLIC_ORIGIN.into(),
            worker_threads: 2,
            shutdown_grace_ms: 5_000,
            restart_notice_secs: 60,
            restart_notice_reminders_secs: vec![30, 10],
            handover_ttl_secs: 600,
        }
    }
}

impl Default for AdminConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            bind: "127.0.0.1:9091".into(),
            token: Secret::default(),
            request_timeout_ms: 10_000,
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
            db_probe_interval_secs: 15,
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
            verify: true,
            upload_command: Vec::new(),
            upload_timeout_secs: 600,
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
            runs_per_hour: 30,
            runs_burst: 10,
            social_per_hour: 60,
            social_burst: 20,
            ip_per_minute: 600,
            ip_burst: 200,
            ws_connect_per_minute: 60,
            ws_connect_burst: 30,
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

impl Default for LeaderboardsConfig {
    fn default() -> Self {
        Self {
            show_pending: true,
            global_limit_default: 100,
            global_limit_max: 100,
            around_me_default: 10,
            around_me_max: 50,
            replay_top_n: 100,
            cache_ttl_secs: 60,
            cache_max_boards: 256,
            crew_top_members: 4,
            legacy_max_journey_score: 50_000_000,
            legacy_max_distance_m: 2_000_000.0,
        }
    }
}

impl Default for ReplaysConfig {
    fn default() -> Self {
        Self {
            dir: "/data/replays".into(),
            max_bytes: 4 * 1024 * 1024,
            verifier_command: Vec::new(),
            worker_enabled: true,
            job_timeout_secs: 1_800,
            max_attempts: 3,
            retry_delay_secs: 300,
            poll_interval_secs: 30,
            keep_top_n: 100,
            cleanup_interval_secs: 3_600,
        }
    }
}

impl Default for RoomsConfig {
    fn default() -> Self {
        Self {
            max_players: 8,
            empty_close_ms: 60_000,
            seat_hold_ms: 15_000,
            protection_ms: 3_000,
            crash_respawn_ms: 3_000,
            spawn_behind_leader_m: 40.0,
            spawn_search_m: 60.0,
            spawn_step_m: 5.0,
            spawn_clear_m: 15.0,
            traffic: ROOM_TRAFFIC_SIM.into(),
            traffic_aoi_behind_m: 300.0,
            traffic_aoi_ahead_m: 900.0,
            traffic_aoi_hysteresis_m: 20.0,
            traffic_near_m: 100.0,
            traffic_near_hz: 5,
            traffic_far_hz: 1,
            traffic_car_id_hold_ms: 30_000,
            cycle_len_ms: 32 * 60_000,
            day_len_ms: 22 * 60_000,
            clock_epoch_unix_ms: 0,
            command_queue: 256,
            join_timeout_ms: 2_000,
            max_speed_kmh: 307.8,
            speed_tolerance_pct: 10.0,
            max_accel_mps2: 12.0,
            max_lateral_speed_mps: 12.0,
            capability_tolerance_pct: 20.0,
            lateral_margin_m: 1.0,
            position_slack_m: 2.0,
            future_tolerance_ms: 500,
            stale_state_ms: 2_000,
            placement_grace_ms: 2_000,
            placement_radius_m: 30.0,
            create_per_hour: 30,
            create_burst: 5,
        }
    }
}

impl Default for SocialConfig {
    fn default() -> Self {
        Self {
            max_friends: 100,
            max_outgoing_requests: 50,
            max_incoming_requests: 100,
            max_blocks: 500,
            crew_max_members: 16,
            crew_invite_code_len: 8,
            reports_per_day: 10,
            report_context_max_bytes: 1_024,
            party_max_members: 8,
            party_member_hold_ms: 15_000,
        }
    }
}

impl Default for RunsConfig {
    fn default() -> Self {
        Self {
            min_build: 0,
            supported_builds: Vec::new(),
            max_score_per_minute: 200_000.0,
            min_duration_s: 10.0,
            max_duration_s: 6.0 * 3_600.0,
            max_top_speed_kmh: 360.0,
            distance_slack_pct: 5.0,
            distance_slack_m: 200.0,
            leg_min_length_m: 3_000.0,
            legs_to_coast: 8,
            lives: 2,
            pass_points: 10.0,
            close_pass_points: 30.0,
            cut_points: 15.0,
            thread_points: 50.0,
            pass_multiplier_gain: 1.0,
            close_pass_multiplier_gain: 3.0,
            cut_multiplier_gain: 1.0,
            thread_multiplier_gain: 5.0,
            multiplier_start: 1.0,
            speed_factor_max: 2.0,
            night_factor: 2.0,
            leg_bonus_max_points: 18_500.0,
            journey_bonus_points: 50_000.0,
            score_slack_pct: 1.0,
            date_early_secs: 3_600,
            date_late_secs: 6 * 3_600,
        }
    }
}

impl RunsConfig {
    /// `supported_builds` parsed (validated at startup).
    pub fn supported_build_numbers(&self) -> Vec<u32> {
        self.supported_builds
            .iter()
            .filter_map(|b| b.trim().parse().ok())
            .collect()
    }

    /// Whether runs from `build` are accepted.
    pub fn build_supported(&self, build: u32) -> bool {
        build >= self.min_build
            && (self.supported_builds.is_empty() || self.supported_build_numbers().contains(&build))
    }

    /// `(name, value)` of every number that must be finite and non-negative.
    fn numbers(&self) -> [(&'static str, f64); 21] {
        [
            ("max_score_per_minute", self.max_score_per_minute),
            ("min_duration_s", self.min_duration_s),
            ("max_duration_s", self.max_duration_s),
            ("max_top_speed_kmh", self.max_top_speed_kmh),
            ("distance_slack_pct", self.distance_slack_pct),
            ("distance_slack_m", self.distance_slack_m),
            ("leg_min_length_m", self.leg_min_length_m),
            ("pass_points", self.pass_points),
            ("close_pass_points", self.close_pass_points),
            ("cut_points", self.cut_points),
            ("thread_points", self.thread_points),
            ("pass_multiplier_gain", self.pass_multiplier_gain),
            (
                "close_pass_multiplier_gain",
                self.close_pass_multiplier_gain,
            ),
            ("cut_multiplier_gain", self.cut_multiplier_gain),
            ("thread_multiplier_gain", self.thread_multiplier_gain),
            ("multiplier_start", self.multiplier_start),
            ("speed_factor_max", self.speed_factor_max),
            ("night_factor", self.night_factor),
            ("leg_bonus_max_points", self.leg_bonus_max_points),
            ("journey_bonus_points", self.journey_bonus_points),
            ("score_slack_pct", self.score_slack_pct),
        ]
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
        self.validate_main(&mut errs);
        self.validate_ops(&mut errs);
        if errs.is_empty() {
            Ok(())
        } else {
            Err(ConfigErrors(errs))
        }
    }

    /// N10.2: `[admin]`, the restart notice, backups' hook, the new rate limits.
    fn validate_ops(&self, errs: &mut Vec<String>) {
        let s = &self.server;
        // Reminders at or above the notice are skipped (lowering the notice alone, e.g. to
        // fit a platform's stop timeout, must not break startup).
        if s.restart_notice_reminders_secs.contains(&0) {
            errs.push("server.restart_notice_reminders_secs entries must be at least 1".into());
        }
        if s.restart_notice_secs > MAX_RESTART_NOTICE_SECS {
            errs.push(format!(
                "server.restart_notice_secs must be at most {MAX_RESTART_NOTICE_SECS} (server_notice.seconds is a u16)"
            ));
        }
        if s.handover_ttl_secs == 0 {
            errs.push("server.handover_ttl_secs must be at least 1".into());
        }
        let a = &self.admin;
        if a.enabled {
            match a.bind.parse::<SocketAddr>() {
                Ok(addr) if addr.ip().is_loopback() => {}
                Ok(_) => errs.push(format!(
                    "admin.bind `{}` must be a loopback address (127.0.0.1 or ::1)",
                    a.bind
                )),
                Err(_) => errs.push(format!(
                    "admin.bind `{}` is not an ip:port socket address",
                    a.bind
                )),
            }
        }
        if !a.token.is_empty() && a.token.expose().len() < MIN_JWT_SECRET_BYTES {
            errs.push(format!(
                "admin.token must be at least {MIN_JWT_SECRET_BYTES} bytes (or empty: API off)"
            ));
        }
        if a.request_timeout_ms == 0 {
            errs.push("admin.request_timeout_ms must be at least 1".into());
        }
        let b = &self.backup;
        if b.upload_command.iter().any(|x| x.is_empty()) {
            errs.push("backup.upload_command entries must not be empty".into());
        }
        if !b.upload_command.is_empty() && b.upload_timeout_secs == 0 {
            errs.push("backup.upload_timeout_secs must be at least 1".into());
        }
        let r = &self.rate_limits;
        if r.enabled
            && [
                r.ip_per_minute,
                r.ip_burst,
                r.ws_connect_per_minute,
                r.ws_connect_burst,
            ]
            .contains(&0)
        {
            errs.push("rate_limits.ip_* and ws_connect_* must be at least 1".into());
        }
        if self.rooms.create_per_hour == 0 || self.rooms.create_burst == 0 {
            errs.push("rooms.create_per_hour and rooms.create_burst must be at least 1".into());
        }
        if self.metrics.db_probe_interval_secs == 0 {
            errs.push("metrics.db_probe_interval_secs must be at least 1".into());
        }
    }

    fn validate_main(&self, errs: &mut Vec<String>) {
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
                r.runs_per_hour,
                r.runs_burst,
                r.social_per_hour,
                r.social_burst,
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
        self.validate_leaderboards(errs);
        self.validate_social(errs);
        self.validate_deeplinks(errs);
        self.validate_replays(errs);
        self.validate_rooms(errs);
        self.validate_scoring(errs);
    }

    fn validate_leaderboards(&self, errs: &mut Vec<String>) {
        let b = &self.leaderboards;
        if b.global_limit_max == 0 || b.global_limit_default == 0 {
            errs.push("leaderboards.global_limit_default and _max must be at least 1".into());
        }
        if b.global_limit_default > b.global_limit_max {
            errs.push("leaderboards.global_limit_default must be at most global_limit_max".into());
        }
        if b.around_me_max == 0 || b.around_me_default > b.around_me_max {
            errs.push(
                "leaderboards.around_me_max must be at least 1 and around_me_default at most it"
                    .into(),
            );
        }
        if b.crew_top_members == 0 {
            errs.push("leaderboards.crew_top_members must be at least 1".into());
        }
        if b.cache_max_boards == 0 {
            errs.push("leaderboards.cache_max_boards must be at least 1".into());
        }
        if !(b.legacy_max_distance_m.is_finite() && b.legacy_max_distance_m >= 0.0) {
            errs.push("leaderboards.legacy_max_distance_m must be a number >= 0".into());
        }
        let r = &self.runs;
        for (name, v) in r.numbers() {
            if !(v.is_finite() && v >= 0.0) {
                errs.push(format!("runs.{name} must be a number >= 0"));
            }
        }
        if !(r.min_duration_s > 0.0 && r.max_duration_s > r.min_duration_s) {
            errs.push("runs.min_duration_s must be above 0 and below runs.max_duration_s".into());
        }
        if r.multiplier_start < 1.0 || r.speed_factor_max < 1.0 || r.night_factor < 1.0 {
            errs.push(
                "runs.multiplier_start, speed_factor_max and night_factor must be at least 1"
                    .into(),
            );
        }
        for build in &r.supported_builds {
            if build.trim().parse::<u32>().is_err() {
                errs.push(format!(
                    "runs.supported_builds entry `{build}` must be a build number (0..=4294967295)"
                ));
            }
        }
    }

    fn validate_replays(&self, errs: &mut Vec<String>) {
        let r = &self.replays;
        if r.dir.as_os_str().is_empty() {
            errs.push("replays.dir must be set".into());
        }
        if r.max_bytes < MIN_REPLAY_BYTES || r.max_bytes > MAX_REPLAY_BYTES {
            errs.push(format!(
                "replays.max_bytes must be {MIN_REPLAY_BYTES}..={MAX_REPLAY_BYTES}"
            ));
        }
        if r.verifier_command.iter().any(|a| a.is_empty()) {
            errs.push("replays.verifier_command entries must not be empty".into());
        }
        for (name, v) in [
            ("job_timeout_secs", r.job_timeout_secs),
            ("poll_interval_secs", r.poll_interval_secs),
            ("cleanup_interval_secs", r.cleanup_interval_secs),
            ("max_attempts", u64::from(r.max_attempts)),
            ("keep_top_n", u64::from(r.keep_top_n)),
        ] {
            if v == 0 {
                errs.push(format!("replays.{name} must be at least 1"));
            }
        }
    }

    fn validate_rooms(&self, errs: &mut Vec<String>) {
        let r = &self.rooms;
        if r.max_players == 0 || r.max_players > protocol::messages::MAX_ROOM_PLAYERS {
            errs.push(format!(
                "rooms.max_players must be 1..={}",
                protocol::messages::MAX_ROOM_PLAYERS
            ));
        }
        if r.cycle_len_ms == 0 || r.day_len_ms > r.cycle_len_ms {
            errs.push(
                "rooms.cycle_len_ms must be at least 1 and rooms.day_len_ms at most it".into(),
            );
        }
        if r.command_queue == 0 || r.join_timeout_ms == 0 {
            errs.push("rooms.command_queue and rooms.join_timeout_ms must be at least 1".into());
        }
        for (name, v) in [
            ("spawn_behind_leader_m", r.spawn_behind_leader_m),
            ("spawn_search_m", r.spawn_search_m),
            ("spawn_clear_m", r.spawn_clear_m),
            ("speed_tolerance_pct", r.speed_tolerance_pct),
            ("capability_tolerance_pct", r.capability_tolerance_pct),
            ("lateral_margin_m", r.lateral_margin_m),
            ("position_slack_m", r.position_slack_m),
            ("placement_radius_m", r.placement_radius_m),
            ("traffic_aoi_behind_m", r.traffic_aoi_behind_m),
            ("traffic_aoi_ahead_m", r.traffic_aoi_ahead_m),
            ("traffic_aoi_hysteresis_m", r.traffic_aoi_hysteresis_m),
            ("traffic_near_m", r.traffic_near_m),
        ] {
            if !(v.is_finite() && v >= 0.0) {
                errs.push(format!("rooms.{name} must be a number >= 0"));
            }
        }
        for (name, v) in [
            ("max_speed_kmh", r.max_speed_kmh),
            ("max_accel_mps2", r.max_accel_mps2),
            ("max_lateral_speed_mps", r.max_lateral_speed_mps),
            ("spawn_step_m", r.spawn_step_m),
        ] {
            if !(v.is_finite() && v > 0.0) {
                errs.push(format!("rooms.{name} must be a number above 0"));
            }
        }
        if !ROOM_TRAFFIC.contains(&r.traffic.as_str()) {
            errs.push(format!("rooms.traffic must be one of {ROOM_TRAFFIC:?}"));
        }
        let rate = u32::from(self.gateway.tick_rate_hz);
        for (name, v) in [
            ("traffic_near_hz", r.traffic_near_hz),
            ("traffic_far_hz", r.traffic_far_hz),
        ] {
            // (A zero tick rate is the gateway's error.)
            if v == 0 || (rate > 0 && v > rate) {
                errs.push(format!(
                    "rooms.{name} must be between 1 and gateway.tick_rate_hz"
                ));
            }
        }
        if r.traffic_aoi_behind_m + r.traffic_aoi_ahead_m + 2.0 * r.traffic_aoi_hysteresis_m
            >= MAX_AOI_SPAN_M
        {
            errs.push(format!(
                "rooms.traffic_aoi_* must span less than {MAX_AOI_SPAN_M} m (half the loop)"
            ));
        }
    }

    fn validate_scoring(&self, errs: &mut Vec<String>) {
        let c = &self.scoring;
        for (name, v) in [
            ("claim_clearance_tolerance_m", c.claim_clearance_tolerance_m),
            ("cut_gap_tolerance_m", c.cut_gap_tolerance_m),
            ("cut_speed_tolerance_kmh", c.cut_speed_tolerance_kmh),
            ("crew_range_m", c.crew_range_m),
            ("crew_bonus_per_mate", c.crew_bonus_per_mate),
            ("train_multiplier_gain", c.train_multiplier_gain),
            ("hit_overlap_m", c.hit_overlap_m),
            ("hit_confirm_clearance_m", c.hit_confirm_clearance_m),
            ("track_ahead_m", c.track_ahead_m),
        ] {
            if !(v.is_finite() && v >= 0.0) {
                errs.push(format!("scoring.{name} must be a number >= 0"));
            }
        }
        for (name, v) in [
            ("crew_factor_cap", c.crew_factor_cap),
            ("player_length_m", c.player_length_m),
            ("player_width_m", c.player_width_m),
        ] {
            if !(v.is_finite() && v > 0.0) {
                errs.push(format!("scoring.{name} must be a number above 0"));
            }
        }
        if !(0.0..=100.0).contains(&c.verify_min_acceptance_pct) {
            errs.push("scoring.verify_min_acceptance_pct must be 0..=100".into());
        }
        if c.claim_queue == 0 || c.hit_overlap_ticks == 0 || c.sync_interval_ms == 0 {
            errs.push(
                "scoring.claim_queue, hit_overlap_ticks and sync_interval_ms must be at least 1"
                    .into(),
            );
        }
        if c.train_points < 0 {
            errs.push("scoring.train_points must be >= 0".into());
        }
        // The shadow check reads states this far before the official horizon.
        if c.shadow_log_every == 0 || c.shadow_view_delay_ms > MAX_SHADOW_VIEW_DELAY_MS {
            errs.push(format!(
                "scoring.shadow_log_every must be at least 1 and scoring.shadow_view_delay_ms \
                 at most {MAX_SHADOW_VIEW_DELAY_MS}"
            ));
        }
        // The scoring rings keep 64 ticks of states: the official lag must stay well inside.
        if c.official_lag_ms > MAX_OFFICIAL_LAG_MS || c.claim_max_wait_ms > c.official_lag_ms {
            errs.push(format!(
                "scoring.official_lag_ms must be at most {MAX_OFFICIAL_LAG_MS} and \
                 scoring.claim_max_wait_ms at most scoring.official_lag_ms"
            ));
        }
    }

    fn validate_social(&self, errs: &mut Vec<String>) {
        let s = &self.social;
        for (name, v) in [
            ("max_friends", s.max_friends),
            ("max_outgoing_requests", s.max_outgoing_requests),
            ("max_incoming_requests", s.max_incoming_requests),
            ("max_blocks", s.max_blocks),
            ("crew_max_members", s.crew_max_members),
            ("reports_per_day", s.reports_per_day),
            ("party_max_members", s.party_max_members),
        ] {
            if v == 0 {
                errs.push(format!("social.{name} must be at least 1"));
            }
        }
        if s.party_max_members > u32::from(protocol::messages::MAX_PARTY_MEMBERS) {
            errs.push(format!(
                "social.party_max_members must be 1..={}",
                protocol::messages::MAX_PARTY_MEMBERS
            ));
        }
        if !(MIN_INVITE_CODE_LEN..=MAX_INVITE_CODE_LEN).contains(&s.crew_invite_code_len) {
            errs.push(format!(
                "social.crew_invite_code_len must be {MIN_INVITE_CODE_LEN}..={MAX_INVITE_CODE_LEN}"
            ));
        }
        if !(MIN_REPORT_CONTEXT_BYTES..=MAX_REPORT_CONTEXT_BYTES)
            .contains(&s.report_context_max_bytes)
        {
            errs.push(format!(
                "social.report_context_max_bytes must be {MIN_REPORT_CONTEXT_BYTES}..={MAX_REPORT_CONTEXT_BYTES}"
            ));
        }
    }

    fn validate_deeplinks(&self, errs: &mut Vec<String>) {
        let d = &self.deeplinks;
        let url = d.web_join_url.as_str();
        if !(url.starts_with("https://") || url.starts_with("http://")) || !url.contains("{code}") {
            errs.push("deeplinks.web_join_url must be an http(s) URL containing {code}".into());
        }
        for id in &d.apple_app_ids {
            if !is_apple_app_id(id) {
                errs.push(format!(
                    "deeplinks.apple_app_ids: `{id}` is not TEAMID.bundle.id"
                ));
            }
        }
        if !d.android_package.is_empty() && !is_android_package(&d.android_package) {
            errs.push(format!(
                "deeplinks.android_package `{}` is not a package name",
                d.android_package
            ));
        }
        for f in &d.android_cert_sha256 {
            if !is_sha256_fingerprint(f) {
                errs.push(format!(
                    "deeplinks.android_cert_sha256: `{f}` is not 32 hex pairs separated by ':'"
                ));
            }
        }
        for (name, v) in [
            ("app_store_url", &d.app_store_url),
            ("play_store_url", &d.play_store_url),
        ] {
            if !v.is_empty() && !v.starts_with("https://") {
                errs.push(format!("deeplinks.{name} must be an https:// URL"));
            }
        }
        if !d.app_scheme.is_empty() && !is_url_scheme(&d.app_scheme) {
            errs.push(format!(
                "deeplinks.app_scheme `{}` is not a URL scheme",
                d.app_scheme
            ));
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

    /// The admin API's address: enabled **and** a token set (N10.2).
    pub fn admin_addr(&self) -> Option<SocketAddr> {
        (self.admin.enabled && !self.admin.token.is_empty())
            .then(|| self.admin.bind.parse().expect("validated"))
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
        for secret in [
            &mut c.auth.jwt_secret,
            &mut c.auth.device_secret_pepper,
            &mut c.admin.token,
        ] {
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

/// Bytes in a SHA-256 certificate fingerprint (`deeplinks.android_cert_sha256`).
const SHA256_BYTES: usize = 32;

/// `TEAMID.bundle.id`: an alphanumeric team id, a dot, then a bundle id.
fn is_apple_app_id(id: &str) -> bool {
    let Some((team, bundle)) = id.split_once('.') else {
        return false;
    };
    !team.is_empty()
        && team.chars().all(|c| c.is_ascii_alphanumeric())
        && !bundle.is_empty()
        && bundle
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
}

/// `com.example.app`: at least two dot-separated identifiers.
fn is_android_package(p: &str) -> bool {
    p.split('.').count() >= 2
        && p.split('.').all(|part| {
            part.starts_with(|c: char| c.is_ascii_alphabetic())
                && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
}

/// `AA:BB:...`: 32 hex pairs separated by colons.
fn is_sha256_fingerprint(f: &str) -> bool {
    let parts: Vec<&str> = f.split(':').collect();
    parts.len() == SHA256_BYTES
        && parts
            .iter()
            .all(|p| p.len() == 2 && p.chars().all(|c| c.is_ascii_hexdigit()))
}

/// RFC 3986: a letter, then letters, digits, `+`, `-`, `.`.
fn is_url_scheme(s: &str) -> bool {
    s.starts_with(|c: char| c.is_ascii_alphabetic())
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
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
        // Items take the type of the default's items (integers for
        // `server.restart_notice_reminders_secs`), strings otherwise.
        toml::Value::Array(items) => {
            let ints = matches!(items.first(), Some(toml::Value::Integer(_)));
            let mut out = Vec::new();
            for s in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
                out.push(if ints {
                    toml::Value::Integer(s.parse().with_context(|| {
                        format!("env override {key}: expected comma-separated integers")
                    })?)
                } else {
                    toml::Value::String(s.to_string())
                });
            }
            toml::Value::Array(out)
        }
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
