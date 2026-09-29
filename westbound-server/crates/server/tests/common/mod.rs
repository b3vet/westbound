//! Shared helpers for the server integration tests: a real server on ephemeral
//! loopback ports with its database in a temp dir.
#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{HeaderMap, Request};
use serde_json::Value;
use tempfile::TempDir;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;
use tower::ServiceExt;
use westbound_server::auth::routes::DeviceCreated;
use westbound_server::clock::{ManualClock, SystemClock};
use westbound_server::config::Secret;
use westbound_server::metrics::Metrics;
use westbound_server::tick::TickClock;
use westbound_server::{db, AppState, Config, Server};

pub const JWT_SECRET: &str = "test-jwt-secret-0123456789abcdef0123456789";
pub const PEPPER: &str = "test-device-pepper-0123456789abcdef0123456";
/// The manual clock's start: 2026-09-21.
pub const T0: i64 = 1_790_000_000;
pub const DAY: i64 = 86_400;
/// The default test client: a public address, outside every trusted proxy range.
pub const CLIENT: &str = "198.51.100.10:40000";

pub type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

pub const STEP: Duration = Duration::from_millis(10);
pub const WAIT: Duration = Duration::from_secs(5);

pub struct TestServer {
    pub addr: SocketAddr,
    pub metrics_addr: SocketAddr,
    pub state: AppState,
    pub handle: JoinHandle<anyhow::Result<()>>,
    pub dir: TempDir,
}

/// Config for tests: loopback ephemeral ports, temp database, no nightly backup.
pub fn test_config(dir: &TempDir) -> Config {
    let mut c = Config::default();
    c.server.bind = "127.0.0.1:0".into();
    c.server.shutdown_grace_ms = 2_000;
    c.metrics.bind = "127.0.0.1:0".into();
    c.db.path = dir.path().join("test.db");
    c.backup.enabled = false;
    // The test client never closes on a fatal error; don't wait the production second.
    c.gateway.fatal_close_delay_ms = 20;
    c.backup.dir = dir.path().join("backups");
    c.auth.jwt_secret = Secret::new(JWT_SECRET);
    c.auth.device_secret_pepper = Secret::new(PEPPER);
    // Generous limits: the rate-limit tests set their own.
    let r = &mut c.rate_limits;
    r.device_create_per_hour = 100_000;
    r.device_create_burst = 100_000;
    r.auth_per_minute = 100_000;
    r.auth_burst = 100_000;
    r.account_per_minute = 100_000;
    r.account_burst = 100_000;
    r.runs_per_hour = 100_000;
    r.runs_burst = 100_000;
    r.social_per_hour = 100_000;
    r.social_burst = 100_000;
    c.validate().expect("test config is valid");
    c
}

pub async fn start() -> TestServer {
    start_with(|_| {}).await
}

pub async fn start_with(tweak: impl FnOnce(&mut Config)) -> TestServer {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = test_config(&dir);
    tweak(&mut cfg);
    cfg.validate().expect("tweaked test config is valid");
    let pool = db::connect(&cfg.db).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let server = Server::bind(cfg, pool).await.unwrap();
    serve(server, dir)
}

/// A server whose tick clock is a `ManualTickClock` (Pong tests).
pub async fn start_with_tick_clock(
    tweak: impl FnOnce(&mut Config),
    tick: Arc<dyn TickClock>,
) -> TestServer {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = test_config(&dir);
    tweak(&mut cfg);
    cfg.validate().expect("tweaked test config is valid");
    let pool = db::connect(&cfg.db).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::with_clocks(cfg, pool, Arc::new(SystemClock), tick).unwrap();
    let server = Server::bind_state(state).await.unwrap();
    serve(server, dir)
}

fn serve(server: Server, dir: TempDir) -> TestServer {
    let addr = server.local_addr();
    let metrics_addr = server.metrics_addr().unwrap();
    let state = server.state().clone();
    let handle = tokio::spawn(server.run());
    TestServer {
        addr,
        metrics_addr,
        state,
        handle,
        dir,
    }
}

impl TestServer {
    pub fn metrics(&self) -> &Arc<Metrics> {
        &self.state.metrics
    }

    /// Connects to the protocol gateway (`/ws`).
    pub async fn connect(&self) -> Ws {
        self.connect_path("/ws").await
    }

    /// Connects to the ops echo (`/ws/echo`).
    pub async fn connect_echo(&self) -> Ws {
        self.connect_path("/ws/echo").await
    }

    pub async fn connect_path(&self, path: &str) -> Ws {
        let url = format!("ws://{}{path}", self.addr);
        let (ws, resp) = tokio_tungstenite::connect_async(url).await.unwrap();
        assert_eq!(resp.status(), 101);
        ws
    }

    /// Cancels and waits for `run()` to return.
    pub async fn stop(self) {
        self.state.shutdown.cancel();
        tokio::time::timeout(WAIT, self.handle)
            .await
            .expect("server stops in time")
            .unwrap()
            .unwrap();
        self.state.db.close().await;
    }
}

/// Polls `cond` until true or `WAIT` elapses.
pub async fn eventually(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !cond() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for: {what}"
        );
        tokio::time::sleep(STEP).await;
    }
}

/// Next data or close message, skipping pings/pongs.
pub async fn next_msg(ws: &mut Ws) -> Option<Message> {
    use futures_util::StreamExt;
    loop {
        let m = tokio::time::timeout(WAIT, ws.next())
            .await
            .expect("message in time")?;
        match m {
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => continue,
            Ok(m) => return Some(m),
            Err(_) => return None,
        }
    }
}

/// Sends a raw HTTP/1.1 request (must include `Connection: close`) and returns the
/// whole response text.
pub async fn raw_http(addr: SocketAddr, request: &str) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
    s.write_all(request.as_bytes()).await.unwrap();
    let mut buf = Vec::new();
    tokio::time::timeout(WAIT, s.read_to_end(&mut buf))
        .await
        .unwrap()
        .unwrap();
    String::from_utf8_lossy(&buf).into_owned()
}

// ---------------------------------------------------------------------------------------------
// In-process API calls (no sockets): the router with a manual clock
// ---------------------------------------------------------------------------------------------

pub struct TestApp {
    pub state: AppState,
    pub clock: Arc<ManualClock>,
    pub dir: TempDir,
}

#[derive(Debug)]
pub struct Resp {
    pub status: u16,
    pub headers: HeaderMap,
    pub json: Value,
}

impl Resp {
    /// The `error` code of an API error body.
    pub fn code(&self) -> &str {
        self.json["error"].as_str().unwrap_or("")
    }
}

pub async fn app() -> TestApp {
    app_with(|_| {}).await
}

pub async fn app_with(tweak: impl FnOnce(&mut Config)) -> TestApp {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = test_config(&dir);
    tweak(&mut cfg);
    cfg.validate().expect("tweaked test config is valid");
    let pool = db::connect(&cfg.db).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let clock = Arc::new(ManualClock::new(T0));
    let state = AppState::with_clock(cfg, pool, clock.clone()).unwrap();
    TestApp { state, clock, dir }
}

impl TestApp {
    pub fn db(&self) -> &sqlx::SqlitePool {
        &self.state.db
    }

    /// A raw request from `peer` with extra headers.
    pub async fn raw(
        &self,
        method: &str,
        path: &str,
        peer: &str,
        headers: &[(&str, &str)],
        body: Vec<u8>,
    ) -> Resp {
        let mut b = Request::builder().method(method).uri(path);
        for (k, v) in headers {
            b = b.header(*k, *v);
        }
        let mut req = b.body(Body::from(body)).unwrap();
        let peer: SocketAddr = peer.parse().unwrap();
        req.extensions_mut().insert(ConnectInfo(peer));
        let resp = westbound_server::app::router(self.state.clone())
            .oneshot(req)
            .await
            .unwrap();
        let status = resp.status().as_u16();
        let headers = resp.headers().clone();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes)
                .unwrap_or_else(|_| panic!("non-JSON body: {}", String::from_utf8_lossy(&bytes)))
        };
        Resp {
            status,
            headers,
            json,
        }
    }

    /// A JSON request from the default client, with an optional bearer token.
    pub async fn call(
        &self,
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> Resp {
        let auth = token.map(|t| format!("Bearer {t}"));
        let mut headers: Vec<(&str, &str)> = Vec::new();
        if let Some(a) = &auth {
            headers.push(("authorization", a));
        }
        let bytes = match body {
            Some(v) => {
                headers.push(("content-type", "application/json"));
                serde_json::to_vec(&v).unwrap()
            }
            None => Vec::new(),
        };
        self.raw(method, path, CLIENT, &headers, bytes).await
    }

    /// `POST /api/v1/auth/device`, asserting 201.
    pub async fn create_device(&self) -> DeviceCreated {
        let r = self.call("POST", "/api/v1/auth/device", None, None).await;
        assert_eq!(r.status, 201, "{:?}", r.json);
        serde_json::from_value(r.json).unwrap()
    }

    pub async fn refresh(&self, refresh_token: &str) -> Resp {
        self.call(
            "POST",
            "/api/v1/auth/refresh",
            None,
            Some(serde_json::json!({ "refresh_token": refresh_token })),
        )
        .await
    }

    pub async fn login(&self, account_id: &str, secret: &str) -> Resp {
        self.call(
            "POST",
            "/api/v1/auth/device/login",
            None,
            Some(serde_json::json!({ "account_id": account_id, "device_secret": secret })),
        )
        .await
    }

    pub async fn me(&self, token: &str) -> Resp {
        self.call("GET", "/api/v1/me", Some(token), None).await
    }

    pub async fn rename(&self, token: &str, name: &str) -> Resp {
        self.call(
            "PATCH",
            "/api/v1/me",
            Some(token),
            Some(serde_json::json!({ "display_name": name })),
        )
        .await
    }
}

/// Every API error has `{error, message}`.
pub fn assert_error(r: &Resp, status: u16, code: &str) {
    assert_eq!(r.status, status, "{:?}", r.json);
    assert_eq!(r.code(), code, "{:?}", r.json);
    assert!(
        r.json["message"].as_str().is_some_and(|m| !m.is_empty()),
        "{:?}",
        r.json
    );
}

// ---------------------------------------------------------------------------------------------
// Runs and leaderboards (N7.1)
// ---------------------------------------------------------------------------------------------

/// T0's UTC date (a Monday, ISO week 2026-W39).
pub const T0_DATE: &str = "2026-09-21";

/// A plausible Journey submission (defaults of `[runs]`): 400 s at up to 280 km/h, five
/// legs, room for scores up to about 500 000.
pub fn journey_run(key: &str, score: u64, distance_m: f64) -> Value {
    serde_json::json!({
        "idempotency_key": key,
        "mode": "journey",
        "seed": "123456789",
        "date": T0_DATE,
        "car": "coupe",
        "client_build": 1,
        "score": score,
        "distance_m": distance_m,
        "duration_s": 400.0,
        "legs_completed": 5,
        "coast_reached": false,
        "best_chain": 5000,
        "best_multiplier": 20.0,
        "passes": 200,
        "close_passes": 50,
        "threads": 10,
        "cuts": 20,
        "top_speed_kmh": 280.0,
        "night_time_s": 0.0,
        "hits": 1,
        "journey_complete": false,
        "journey_time_s": 0.0,
        "journey_distance_m": 0.0
    })
}

/// A plausible Daily Drive submission on `date` with that date's seed.
pub fn daily_run(key: &str, date: &str, score: u64) -> Value {
    let seed = westbound_server::runs::daily_seed::daily_seed_for_date(date).unwrap();
    let mut v = journey_run(key, score, 20_000.0);
    v["mode"] = "daily".into();
    v["date"] = date.into();
    v["seed"] = seed.to_string().into();
    v
}

impl TestApp {
    /// A new device account: (id, access token).
    pub async fn account(&self) -> (i64, String) {
        let d = self.create_device().await;
        (
            d.session.account_id.parse().unwrap(),
            d.session.access_token,
        )
    }

    /// `POST /api/v1/runs`.
    pub async fn submit(&self, token: &str, body: Value) -> Resp {
        self.call("POST", "/api/v1/runs", Some(token), Some(body))
            .await
    }

    /// `POST /api/v1/runs`, asserting a new receipt (201).
    pub async fn submit_ok(&self, token: &str, body: Value) -> Value {
        let r = self.submit(token, body).await;
        assert_eq!(r.status, 201, "{:?}", r.json);
        r.json
    }

    /// `GET /api/v1/boards/<path_and_query>`.
    pub async fn board(&self, token: Option<&str>, path_and_query: &str) -> Resp {
        self.call(
            "GET",
            &format!("/api/v1/boards/{path_and_query}"),
            token,
            None,
        )
        .await
    }

    /// `GET /api/v1/boards/<path_and_query>`, asserting 200.
    pub async fn board_ok(&self, token: Option<&str>, path_and_query: &str) -> Value {
        let r = self.board(token, path_and_query).await;
        assert_eq!(r.status, 200, "{path_and_query}: {:?}", r.json);
        r.json
    }
}

/// `(account_id, score)` of each entry of a board body, in order.
pub fn ranking(board: &Value) -> Vec<(String, i64)> {
    board["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| {
            (
                e["account_id"].as_str().unwrap_or("").to_string(),
                e["score"].as_i64().unwrap(),
            )
        })
        .collect()
}

/// The `rank` of each entry of a board body.
pub fn ranks(board: &Value) -> Vec<u64> {
    board["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["rank"].as_u64().unwrap())
        .collect()
}

/// Access tokens that outlive tests moving the clock by days.
pub fn long_tokens(c: &mut Config) {
    c.auth.access_token_ttl_secs = 60 * DAY as u64;
    c.auth.refresh_token_ttl_secs = 90 * DAY as u64;
}

/// `app()` with `long_tokens`.
pub async fn runs_app() -> TestApp {
    app_with(long_tokens).await
}

/// 00:00 UTC of T0's date.
pub const T0_MIDNIGHT: i64 = T0 - T0.rem_euclid(DAY);
