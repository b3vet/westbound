//! Shared helpers for the server integration tests: a real server on ephemeral
//! loopback ports with its database in a temp dir.
#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use tempfile::TempDir;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;
use westbound_server::metrics::Metrics;
use westbound_server::{db, AppState, Config, Server};

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
    c.backup.dir = dir.path().join("backups");
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

    pub async fn connect(&self) -> Ws {
        let url = format!("ws://{}/ws", self.addr);
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
