//! N10.2 operations over real sockets: the planned restart (notice, reminders, drain,
//! handover, close 1012, the next instance restoring a room by code), the admin API
//! (token, stats, rooms, notices, kicks, room close), the per-IP and per-account rate
//! limits, request ids, the ops metrics, and restoring a backup into a fresh server.

mod common;

use std::time::Duration;

use common::{next_msg, TestServer, Ws};
use futures_util::SinkExt;
use protocol::{
    decode_server_frame, encode_frame, AccessToken, ClientMsg, Code, CodeRef, Density, ErrorCode,
    Hello, LobbyCommand, LobbyEvent, MapHash, NoticeKind, RoomLeftReason, RoomSettings,
    RunEndReason, ServerMsg, TimeMode, Visibility, PROTOCOL_VERSION,
};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::Message;
use westbound_server::admin_client::AdminClient;
use westbound_server::config::Secret;
use westbound_server::metrics::Metrics;
use westbound_server::{backup, handover, shutdown, Config};

const MAP: MapHash = MapHash([0xAB; 32]);
const BUILD: u32 = 100;
const ADMIN_TOKEN: &str = "test-admin-token-0123456789abcdef0123456789";

fn gw(c: &mut Config) {
    c.gateway.map_hashes = vec!["ab".repeat(32)];
}

/// `POST /api/v1/auth/device` → (account id, access token, device secret).
async fn create_account(s: &TestServer) -> (i64, String, String) {
    let resp = common::raw_http(
        s.addr,
        "POST /api/v1/auth/device HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(resp.starts_with("HTTP/1.1 201"), "{resp}");
    let v: serde_json::Value =
        serde_json::from_str(resp.split_once("\r\n\r\n").unwrap().1).unwrap();
    (
        v["account_id"].as_str().unwrap().parse().unwrap(),
        v["access_token"].as_str().unwrap().to_owned(),
        v["device_secret"].as_str().unwrap().to_owned(),
    )
}

async fn send(ws: &mut Ws, msgs: &[ClientMsg]) {
    let frame = encode_frame(msgs).unwrap();
    ws.send(Message::Binary(frame.to_vec().into()))
        .await
        .unwrap();
}

/// What the socket gives next: a decoded frame, or the close (its code).
enum Ev {
    Msgs(Vec<ServerMsg>),
    Closed(Option<CloseCode>),
}

async fn next_ev(ws: &mut Ws) -> Ev {
    match next_msg(ws).await {
        Some(Message::Binary(b)) => Ev::Msgs(decode_server_frame(&b).expect("server frame")),
        Some(Message::Close(f)) => Ev::Closed(f.map(|f| f.code)),
        None => Ev::Closed(None),
        Some(other) => panic!("unexpected {other:?}"),
    }
}

/// Skips messages until one matches; panics on a close.
async fn wait_for(ws: &mut Ws, what: &str, pred: impl Fn(&ServerMsg) -> bool) -> ServerMsg {
    loop {
        match next_ev(ws).await {
            Ev::Msgs(msgs) => {
                if let Some(m) = msgs.into_iter().find(|m| pred(m)) {
                    return m;
                }
            }
            Ev::Closed(c) => panic!("closed ({c:?}) waiting for {what}"),
        }
    }
}

/// Every message until the close, and the close code.
async fn until_close(ws: &mut Ws) -> (Vec<ServerMsg>, Option<CloseCode>) {
    let mut all = Vec::new();
    loop {
        match next_ev(ws).await {
            Ev::Msgs(m) => all.extend(m),
            Ev::Closed(c) => return (all, c),
        }
    }
}

/// Hello → Welcome; the rest of the Welcome frame.
async fn login(s: &TestServer, token: &str) -> (Ws, Vec<ServerMsg>) {
    let mut ws = s.connect().await;
    send(
        &mut ws,
        &[ClientMsg::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            client_build: BUILD,
            map_hash: MAP,
            access_token: AccessToken(token.to_owned()),
        })],
    )
    .await;
    let Ev::Msgs(mut msgs) = next_ev(&mut ws).await else {
        panic!("closed before Welcome");
    };
    assert!(
        matches!(msgs.first(), Some(ServerMsg::Welcome(_))),
        "{msgs:?}"
    );
    msgs.remove(0);
    (ws, msgs)
}

fn settings() -> RoomSettings {
    RoomSettings {
        visibility: Visibility::Private,
        max_players: 4,
        density: Density::Rush,
        time_mode: TimeMode::Fixed,
        fixed_cycle_ms: 600_000,
    }
}

fn create(s: RoomSettings) -> ClientMsg {
    ClientMsg::LobbyCommand(LobbyCommand::RoomCreate(s))
}

fn join_code(code: &Code) -> ClientMsg {
    ClientMsg::LobbyCommand(LobbyCommand::RoomJoinCode(CodeRef { code: code.clone() }))
}

fn leave() -> ClientMsg {
    ClientMsg::LobbyCommand(LobbyCommand::RoomLeave(Default::default()))
}

/// Creates a room; its snapshot.
async fn create_room(ws: &mut Ws) -> protocol::RoomSnapshot {
    send(ws, &[create(settings())]).await;
    match wait_for(ws, "snapshot", |m| matches!(m, ServerMsg::RoomSnapshot(_))).await {
        ServerMsg::RoomSnapshot(s) => s,
        _ => unreachable!(),
    }
}

fn restart_notice(m: &ServerMsg) -> Option<u16> {
    match m {
        ServerMsg::ServerNotice(n) if n.kind == NoticeKind::Restart => Some(n.seconds),
        _ => None,
    }
}

fn http_get(path: &str) -> String {
    format!("GET {path} HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn planned_restart_notice_handover_and_rejoin_by_code() {
    let a = common::start_with(|c| {
        gw(c);
        c.server.restart_notice_secs = 2;
        c.server.restart_notice_reminders_secs = vec![1];
    })
    .await;
    let (_, t1, _) = create_account(&a).await;
    let (_, t2, _) = create_account(&a).await;
    let (_, t3, _) = create_account(&a).await;
    let (mut driver, _) = login(&a, &t1).await;
    let snap = create_room(&mut driver).await;
    let code = snap.code.clone();
    let (mut lobby, _) = login(&a, &t2).await;

    let st = a.state.clone();
    let restart = tokio::spawn(async move { shutdown::restart(&st, std::future::pending()).await });
    // 1. The notice reaches the room and the lobby.
    let n = wait_for(&mut driver, "notice", |m| restart_notice(m).is_some()).await;
    assert_eq!(restart_notice(&n), Some(2));
    wait_for(&mut lobby, "notice", |m| restart_notice(m).is_some()).await;
    // 2. Draining: health 503 draining, no new rooms, a new session gets the notice.
    let health = common::raw_http(a.addr, &http_get("/api/v1/health")).await;
    assert!(health.starts_with("HTTP/1.1 503"), "{health}");
    assert!(health.contains("\"status\":\"draining\""), "{health}");
    send(&mut lobby, &[create(settings())]).await;
    let e = wait_for(&mut lobby, "refusal", |m| matches!(m, ServerMsg::Error(_))).await;
    let ServerMsg::Error(e) = e else {
        unreachable!()
    };
    assert_eq!(e.code, ErrorCode::ServerFull);
    assert!(!e.fatal);
    assert!(e.detail.0.contains("restarting"), "{e:?}");
    let (mut late, rest) = login(&a, &t3).await;
    let left = rest
        .iter()
        .find_map(restart_notice)
        .expect("notice after Welcome");
    assert!((1..=2).contains(&left), "{left}");
    // 3. The reminder at 1 s left.
    let r = wait_for(&mut driver, "reminder", |m| restart_notice(m) == Some(1)).await;
    assert_eq!(restart_notice(&r), Some(1));
    // 4. The run ends as room_closed, then the socket closes with 1012.
    let (msgs, close) = until_close(&mut driver).await;
    let result = msgs.iter().find_map(|m| match m {
        ServerMsg::RunResult(r) => Some(r.clone()),
        _ => None,
    });
    let result = result.expect("the run's result before the close");
    assert_eq!(result.end_reason, RunEndReason::RoomClosed);
    assert!(
        !msgs
            .iter()
            .any(|m| matches!(m, ServerMsg::LobbyEvent(LobbyEvent::RoomLeft(_)))),
        "a restart does not send room_left (the client rejoins)"
    );
    assert_eq!(close, Some(CloseCode::Restart));
    assert_eq!(until_close(&mut lobby).await.1, Some(CloseCode::Restart));
    assert_eq!(until_close(&mut late).await.1, Some(CloseCode::Restart));
    tokio::time::timeout(common::WAIT, restart)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(Metrics::get(&a.metrics().rooms_handed_over), 1);
    assert!(Metrics::get(&a.metrics().server_notices) >= 2);
    let dir = a.stop_keep_dir().await;

    // The handover file holds the room.
    let path = handover::path_for(&dir.path().join("test.db"));
    let h = handover::load(&path).await.expect("handover file");
    assert_eq!(h.rooms.len(), 1);
    assert_eq!(h.rooms[0].code, code.0);
    assert_eq!(h.rooms[0].settings, settings());

    // 5. The next instance: the player rejoins by code into a room with the same settings.
    let b = common::start_in(dir, gw).await;
    let (mut again, _) = login(&b, &t1).await;
    send(&mut again, &[join_code(&code)]).await;
    let snap = wait_for(&mut again, "snapshot", |m| {
        matches!(m, ServerMsg::RoomSnapshot(_))
    })
    .await;
    let ServerMsg::RoomSnapshot(snap) = snap else {
        unreachable!()
    };
    assert_eq!(snap.code, code);
    assert_eq!(snap.settings, settings());
    assert_eq!(Metrics::get(&b.metrics().rooms_restored), 1);
    // A second player finds the same room; an unknown code is still unknown.
    let (mut other, _) = login(&b, &t2).await;
    send(&mut other, &[join_code(&code)]).await;
    let s2 = wait_for(&mut other, "snapshot", |m| {
        matches!(m, ServerMsg::RoomSnapshot(_))
    })
    .await;
    let ServerMsg::RoomSnapshot(s2) = s2 else {
        unreachable!()
    };
    assert_eq!(s2.room_id, snap.room_id);
    assert_eq!(b.state.rooms.room_count(), 1);
    let (mut third, _) = login(&b, &t3).await;
    send(&mut third, &[join_code(&Code("ZZZ999".into()))]).await;
    let e = wait_for(&mut third, "error", |m| matches!(m, ServerMsg::Error(_))).await;
    assert!(matches!(e, ServerMsg::Error(e) if e.code == ErrorCode::RoomNotFound));
    b.stop().await;
}

#[tokio::test]
async fn restart_notice_ends_early_when_nobody_is_connected() {
    let s = common::start_with(|c| {
        gw(c);
        c.server.restart_notice_secs = 60;
    })
    .await;
    let st = s.state.clone();
    let t = tokio::time::Instant::now();
    tokio::time::timeout(common::WAIT, shutdown::restart(&st, std::future::pending()))
        .await
        .expect("no sessions: no 60 s wait");
    assert!(t.elapsed() < Duration::from_secs(3));
    assert!(s.state.shutdown.is_cancelled());
    s.stop().await;
}

fn api(s: &TestServer) -> AdminClient {
    AdminClient::new(
        s.admin_addr.expect("admin API on"),
        ADMIN_TOKEN,
        common::WAIT,
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn admin_api_token_stats_rooms_notice_kick_and_close() {
    let off = common::start_with(gw).await;
    assert!(off.admin_addr.is_none(), "no token: no admin API");
    off.stop().await;

    let s = common::start_with(|c| {
        gw(c);
        c.admin.token = Secret::new(ADMIN_TOKEN);
    })
    .await;
    let bad = AdminClient::new(
        s.admin_addr.unwrap(),
        "wrong-token-0123456789abcdef0123456789",
        common::WAIT,
    );
    let e = bad
        .get::<serde_json::Value>("/admin/v1/stats")
        .await
        .unwrap_err();
    assert!(format!("{e:#}").contains("401"), "{e:#}");
    assert_eq!(Metrics::get(&s.metrics().admin_denied), 1);

    let (_, t1, _) = create_account(&s).await;
    let (id2, t2, _) = create_account(&s).await;
    let (mut driver, _) = login(&s, &t1).await;
    let snap = create_room(&mut driver).await;
    let (mut other, _) = login(&s, &t2).await;
    let api = api(&s);

    let stats: westbound_server::admin_api::LiveStats = api.get("/admin/v1/stats").await.unwrap();
    assert_eq!((stats.sessions, stats.rooms, stats.seats), (2, 1, 1));
    assert!(!stats.draining);
    let rooms: Vec<serde_json::Value> = api.get("/admin/v1/rooms").await.unwrap();
    assert_eq!(rooms.len(), 1);
    assert_eq!(rooms[0]["code"], snap.code.0);
    assert_eq!(rooms[0]["visibility"], "private");

    // A notice to everyone.
    let v: serde_json::Value = api
        .post(
            "/admin/v1/notice",
            &serde_json::json!({"kind": "maintenance", "seconds": 600, "text": "Maintenance at 20:00 UTC"}),
        )
        .await
        .unwrap();
    assert_eq!(v["sessions"], 2);
    for ws in [&mut driver, &mut other] {
        let n = wait_for(ws, "notice", |m| matches!(m, ServerMsg::ServerNotice(_))).await;
        let ServerMsg::ServerNotice(n) = n else {
            unreachable!()
        };
        assert_eq!(n.kind, NoticeKind::Maintenance);
        assert_eq!(n.seconds, 600);
        assert_eq!(n.text.0, "Maintenance at 20:00 UTC");
    }
    assert!(api
        .post::<serde_json::Value>(
            "/admin/v1/notice",
            &serde_json::json!({"kind": "nope", "text": "x"})
        )
        .await
        .is_err());

    // A kick ends the session now.
    let v: serde_json::Value = api
        .post(
            &format!("/admin/v1/kick/{id2}"),
            &serde_json::json!({"reason": "banned"}),
        )
        .await
        .unwrap();
    assert_eq!(v["kicked"], true);
    let e = wait_for(&mut other, "fatal", |m| matches!(m, ServerMsg::Error(_))).await;
    assert!(matches!(e, ServerMsg::Error(e) if e.code == ErrorCode::Banned && e.fatal));

    // Closing the room: the message, the run's result, room_left{closed}.
    let v: serde_json::Value = api
        .post(
            &format!("/admin/v1/rooms/{}/close", snap.code.0.to_lowercase()),
            &serde_json::json!({"message": "Closed by an admin"}),
        )
        .await
        .unwrap();
    assert_eq!(v["closed"], true);
    let mut seen = (false, false, false);
    while !(seen.0 && seen.1 && seen.2) {
        let Ev::Msgs(msgs) = next_ev(&mut driver).await else {
            panic!("closed")
        };
        for m in msgs {
            match m {
                ServerMsg::ServerNotice(n) if n.kind == NoticeKind::Info => {
                    assert_eq!(n.text.0, "Closed by an admin");
                    seen.0 = true;
                }
                ServerMsg::RunResult(r) => {
                    assert_eq!(r.end_reason, RunEndReason::RoomClosed);
                    seen.1 = true;
                }
                ServerMsg::LobbyEvent(LobbyEvent::RoomLeft(l)) => {
                    assert_eq!(l.reason, RoomLeftReason::Closed);
                    assert!(seen.0 && seen.1, "notice and result come first");
                    seen.2 = true;
                }
                _ => {}
            }
        }
    }
    common::eventually("room gone", || s.state.rooms.room_count() == 0).await;
    let e = api
        .post::<serde_json::Value>("/admin/v1/rooms/ABC234/close", &serde_json::json!({}))
        .await
        .unwrap_err();
    assert!(format!("{e:#}").contains("404"), "{e:#}");
    let actions: Vec<String> =
        sqlx::query_scalar("SELECT action FROM admin_log WHERE actor = 'api' ORDER BY id")
            .fetch_all(&s.state.db)
            .await
            .unwrap();
    assert_eq!(actions, vec!["notice", "room_close"]);
    assert!(Metrics::get(&s.metrics().admin_requests) >= 6);
    s.stop().await;
}

#[tokio::test]
async fn every_route_is_limited_per_ip_and_upgrades_too() {
    let s = common::start_with(|c| {
        gw(c);
        c.rate_limits.ip_per_minute = 1;
        c.rate_limits.ip_burst = 3;
    })
    .await;
    for _ in 0..3 {
        let r = common::raw_http(s.addr, &http_get("/api/v1/health")).await;
        assert!(r.starts_with("HTTP/1.1 200"), "{r}");
    }
    for path in [
        "/api/v1/health",
        "/r/ABC234",
        "/.well-known/assetlinks.json",
    ] {
        let r = common::raw_http(s.addr, &http_get(path)).await;
        assert!(r.starts_with("HTTP/1.1 429"), "{path}: {r}");
        assert!(r.to_ascii_lowercase().contains("retry-after:"), "{r}");
    }
    // Another client (behind a trusted proxy) has its own bucket.
    let r = common::raw_http(
        s.addr,
        "GET /api/v1/health HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 203.0.113.9\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(r.starts_with("HTTP/1.1 200"), "{r}");
    s.stop().await;

    let s = common::start_with(|c| {
        gw(c);
        c.rate_limits.ws_connect_per_minute = 1;
        c.rate_limits.ws_connect_burst = 2;
    })
    .await;
    let _a = s.connect().await;
    let _b = s.connect().await;
    let url = format!("ws://{}/ws", s.addr);
    let err = tokio_tungstenite::connect_async(url).await.unwrap_err();
    assert!(format!("{err}").contains("429"), "{err}");
    let r = common::raw_http(s.addr, &http_get("/api/v1/health")).await;
    assert!(
        r.starts_with("HTTP/1.1 200"),
        "plain routes are not upgrades: {r}"
    );
    s.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn room_create_is_limited_per_account_across_reconnects() {
    let s = common::start_with(|c| {
        gw(c);
        c.rooms.create_per_hour = 1;
        c.rooms.create_burst = 2;
    })
    .await;
    let (_, token, _) = create_account(&s).await;
    let (mut ws, _) = login(&s, &token).await;
    for _ in 0..2 {
        create_room(&mut ws).await;
        send(&mut ws, &[leave()]).await;
        wait_for(&mut ws, "room_left", |m| {
            matches!(m, ServerMsg::LobbyEvent(LobbyEvent::RoomLeft(_)))
        })
        .await;
    }
    send(&mut ws, &[create(settings())]).await;
    let e = wait_for(&mut ws, "refusal", |m| matches!(m, ServerMsg::Error(_))).await;
    assert!(
        matches!(&e, ServerMsg::Error(e) if e.code == ErrorCode::RateLimited && !e.fatal),
        "{e:?}"
    );
    drop(ws);
    // A new connection does not reset it.
    let (mut ws, _) = login(&s, &token).await;
    send(&mut ws, &[create(settings())]).await;
    let e = wait_for(&mut ws, "refusal", |m| matches!(m, ServerMsg::Error(_))).await;
    assert!(
        matches!(&e, ServerMsg::Error(e) if e.code == ErrorCode::RateLimited),
        "{e:?}"
    );
    assert_eq!(Metrics::get(&s.metrics().room_create_limited), 2);
    // Another account still can.
    let (_, other, _) = create_account(&s).await;
    let (mut ws2, _) = login(&s, &other).await;
    create_room(&mut ws2).await;
    s.stop().await;
}

#[tokio::test]
async fn request_ids_and_ops_metrics() {
    let s = common::start_with(|c| {
        gw(c);
        c.metrics.db_probe_interval_secs = 1;
    })
    .await;
    let r = common::raw_http(s.addr, &http_get("/api/v1/health")).await;
    let id_line = r
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("x-request-id:"))
        .expect("a request id");
    assert!(id_line.len() > "x-request-id: ".len() + 8, "{id_line}");
    let r = common::raw_http(
        s.addr,
        "GET /api/v1/health HTTP/1.1\r\nHost: t\r\nX-Request-Id: trace-42\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(r.contains("x-request-id: trace-42"), "{r}");
    let r = common::raw_http(
        s.addr,
        "GET /api/v1/health HTTP/1.1\r\nHost: t\r\nX-Request-Id: bad id!\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(!r.contains("bad id!"), "{r}");

    common::eventually("a db probe ran", || {
        Metrics::get(&s.metrics().db_pool_size) > 0
    })
    .await;
    let text = common::raw_http(s.metrics_addr, &http_get("/metrics")).await;
    for name in [
        "wb_server_draining 0",
        "wb_db_probe_seconds",
        "wb_db_file_bytes",
        "wb_replay_jobs{status=\"pending\"} 0",
        "wb_reports_unhandled 0",
        "wb_log_events_total{level=\"error\"}",
        "wb_backup_last_success_timestamp_seconds",
        "process_start_time_seconds",
        "wb_room_create_limited_total 0",
        "wb_rooms_handed_over_total 0",
    ] {
        assert!(text.contains(name), "{name} missing:\n{text}");
    }
    s.stop().await;
}

#[tokio::test]
async fn a_backup_restores_into_a_fresh_server() {
    let a = common::start_with(gw).await;
    let (id, _, secret) = create_account(&a).await;
    let cfg = westbound_server::config::BackupConfig {
        dir: a.dir.path().join("backups"),
        ..Default::default()
    };
    let file = backup::run_once(&a.state.db, &cfg, westbound_server::clock::unix_now_secs())
        .await
        .unwrap();
    let copy = tempfile::tempdir().unwrap();
    let kept = copy.path().join("backup.db");
    std::fs::copy(&file, &kept).unwrap();
    a.stop().await;

    // A fresh volume: restore, then start a server on it.
    let fresh = tempfile::tempdir().unwrap();
    let db = westbound_server::config::DbConfig {
        path: fresh.path().join("test.db"),
        ..Default::default()
    };
    let r = backup::restore(&db, &kept, 1).await.unwrap();
    assert!(r.previous.is_none());
    let b = common::start_in(fresh, gw).await;
    let body =
        serde_json::json!({"account_id": id.to_string(), "device_secret": secret}).to_string();
    let resp = common::raw_http(
        b.addr,
        &format!(
            "POST /api/v1/auth/device/login HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        ),
    )
    .await;
    assert!(
        resp.starts_with("HTTP/1.1 200"),
        "the account came back: {resp}"
    );
    let restores: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM admin_log WHERE action = 'restore'")
            .fetch_one(&b.state.db)
            .await
            .unwrap();
    assert_eq!(restores, 1);
    b.stop().await;
}

/// The planned restart against a **running container** (N10.2's SIGTERM check; CI or by
/// hand, see docs/OPERATIONS.md): `WB_CONTAINER=<name> WB_CONTAINER_ADDR=127.0.0.1:8080
/// cargo test -p server --test ops -- --ignored container`. The container must accept the
/// all-0xAB map hash (`WB_GATEWAY__MAP_HASHES`) and have a short notice
/// (`WB_SERVER__RESTART_NOTICE_SECS=3`).
#[tokio::test]
#[ignore = "needs a running container (WB_CONTAINER, WB_CONTAINER_ADDR)"]
async fn container_sigterm_sends_the_notice_then_closes_1012() {
    let name = std::env::var("WB_CONTAINER").expect("WB_CONTAINER");
    let addr = std::env::var("WB_CONTAINER_ADDR").expect("WB_CONTAINER_ADDR");
    let (_, token) = bots::http::device_account(&addr).await.expect("account");
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
        .await
        .expect("upgrade");
    send(
        &mut ws,
        &[ClientMsg::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            client_build: BUILD,
            map_hash: MAP,
            access_token: AccessToken(token),
        })],
    )
    .await;
    let Ev::Msgs(w) = next_ev(&mut ws).await else {
        panic!("closed before Welcome")
    };
    assert!(matches!(w.first(), Some(ServerMsg::Welcome(_))), "{w:?}");
    let snap = create_room(&mut ws).await;
    println!("in room {} ({})", snap.code.0, snap.room_id);
    let st = std::process::Command::new("docker")
        .args(["kill", "--signal", "TERM", &name])
        .status()
        .unwrap();
    assert!(st.success());
    let n = wait_for(&mut ws, "restart notice", |m| restart_notice(m).is_some()).await;
    println!("notice: {n:?}");
    let (msgs, close) = until_close(&mut ws).await;
    let ended = msgs
        .iter()
        .any(|m| matches!(m, ServerMsg::RunResult(r) if r.end_reason == RunEndReason::RoomClosed));
    println!("run ended room_closed: {ended}; close: {close:?}");
    assert!(ended);
    assert_eq!(close, Some(CloseCode::Restart));
}
