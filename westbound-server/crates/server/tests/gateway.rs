//! `/ws` protocol gateway (N2.3): handshake outcomes, sessions, rate limits, Pong ticks,
//! live bans, limits. Real sockets against a real server (tests/common).
mod common;

use std::sync::Arc;
use std::time::Duration;

use common::{eventually, next_msg, TestServer, Ws};
use futures_util::{SinkExt, StreamExt};
use protocol::handshake::DETAIL_BANNED;
use protocol::{
    decode_server_frame, encode_frame, AccessToken, AccountId, ClientMsg, ErrorCode, Hello,
    LobbyCommand, MapHash, Ping, PlayerState, ServerMsg, Welcome, MAX_FRAME_LEN, PROTOCOL_VERSION,
};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::Message;
use westbound_server::metrics::{HandshakeResult, Metrics};
use westbound_server::msg_limits::client_type_index;
use westbound_server::tick::ManualTickClock;
use westbound_server::{accounts, admin, clock, Config};

/// The loop map hash the test server accepts.
const MAP: MapHash = MapHash([0xAB; 32]);
const BUILD: u32 = 100;

fn hex(h: &MapHash) -> String {
    h.0.iter().map(|b| format!("{b:02x}")).collect()
}

/// Gateway config for tests: production mode with `MAP` as the only accepted map.
fn gw(c: &mut Config) {
    c.gateway.map_hashes = vec![hex(&MAP)];
}

async fn start() -> TestServer {
    common::start_with(gw).await
}

async fn start_with(tweak: impl FnOnce(&mut Config)) -> TestServer {
    common::start_with(|c| {
        gw(c);
        tweak(c);
    })
    .await
}

/// `POST /api/v1/auth/device` over a real socket → (account id, access token).
async fn create_account(s: &TestServer) -> (i64, String) {
    let resp = common::raw_http(
        s.addr,
        "POST /api/v1/auth/device HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(resp.starts_with("HTTP/1.1 201"), "{resp}");
    let body = resp.split_once("\r\n\r\n").unwrap().1;
    let v: serde_json::Value = serde_json::from_str(body).unwrap();
    let id: i64 = v["account_id"].as_str().unwrap().parse().unwrap();
    (id, v["access_token"].as_str().unwrap().to_owned())
}

fn hello(version: u16, build: u32, map: MapHash, token: &str) -> ClientMsg {
    ClientMsg::Hello(Hello {
        protocol_version: version,
        client_build: build,
        map_hash: map,
        access_token: AccessToken(token.to_owned()),
    })
}

fn ping(t: u32) -> ClientMsg {
    ClientMsg::Ping(Ping { client_time_ms: t })
}

async fn send(ws: &mut Ws, msgs: &[ClientMsg]) {
    let frame = encode_frame(msgs).unwrap();
    ws.send(Message::Binary(frame.to_vec().into()))
        .await
        .unwrap();
}

/// The next server frame, decoded (panics on a close or a text frame).
async fn recv(ws: &mut Ws) -> Vec<ServerMsg> {
    match next_msg(ws).await {
        Some(Message::Binary(b)) => decode_server_frame(&b).expect("server frame decodes"),
        other => panic!("expected a binary frame, got {other:?}"),
    }
}

fn close_code(m: Option<Message>) -> Option<CloseCode> {
    match m {
        Some(Message::Close(Some(f))) => Some(f.code),
        _ => None,
    }
}

/// Expects one fatal `Error` with `code`, then the close (1008, or 1011 for `internal`).
async fn expect_fatal(ws: &mut Ws, code: ErrorCode) -> String {
    let msgs = recv(ws).await;
    let [ServerMsg::Error(e)] = msgs.as_slice() else {
        panic!("expected one Error, got {msgs:?}");
    };
    assert_eq!(e.code, code, "{e:?}");
    assert!(e.fatal, "{e:?}");
    assert_eq!(close_code(next_msg(ws).await), Some(CloseCode::Policy));
    e.detail.0.clone()
}

/// Hello → Welcome with a fresh account; returns the socket, the Welcome and the account.
async fn login(s: &TestServer) -> (Ws, Welcome, i64, String) {
    let (id, token) = create_account(s).await;
    let (ws, w) = login_as(s, &token).await;
    (ws, w, id, token)
}

async fn login_as(s: &TestServer, token: &str) -> (Ws, Welcome) {
    let mut ws = s.connect().await;
    send(&mut ws, &[hello(PROTOCOL_VERSION, BUILD, MAP, token)]).await;
    let msgs = recv(&mut ws).await;
    let [ServerMsg::Welcome(w)] = msgs.as_slice() else {
        panic!("expected Welcome, got {msgs:?}");
    };
    (ws, w.clone())
}

async fn refused(s: &TestServer, msg: ClientMsg, code: ErrorCode) {
    let mut ws = s.connect().await;
    send(&mut ws, &[msg]).await;
    expect_fatal(&mut ws, code).await;
}

#[tokio::test]
async fn full_handshake_welcome_session_and_pong() {
    let s = start().await;
    let (mut ws, w, id, _) = login(&s).await;
    assert_eq!(w.protocol_version, PROTOCOL_VERSION);
    assert_eq!(w.account_id, AccountId(id as u64));
    assert_eq!(w.tick_rate_hz, 20, "spec: 20 Hz");
    assert_eq!(w.ping_interval_ms, 2_000, "spec: ping every 2 s");
    assert_eq!(w.timeout_ms, 8_000, "spec: dead after 8 s");
    assert_eq!(usize::from(w.max_frame_bytes), MAX_FRAME_LEN);
    let m = s.metrics().clone();
    assert_eq!(m.handshakes(HandshakeResult::Ok), 1);
    assert_eq!(Metrics::get(&m.ws_sessions), 1);
    let session = s
        .state
        .sessions
        .get(AccountId(id as u64))
        .expect("registered");
    assert_eq!(session.account_id.0, id as u64);

    // Ping → Pong with the server-wide tick (non-zero after start, so a client samples it).
    send(&mut ws, &[ping(4242)]).await;
    let msgs = recv(&mut ws).await;
    let [ServerMsg::Pong(p)] = msgs.as_slice() else {
        panic!("expected Pong, got {msgs:?}");
    };
    assert_eq!(p.client_time_ms, 4242);
    assert!(p.server_tick > 0 || p.tick_fraction > 0);
    assert_eq!(m.messages_in(client_type_index(0x02).unwrap()), 1);
    assert_eq!(m.messages_in(client_type_index(0x01).unwrap()), 1);

    // Room traffic without a room is dropped quietly; the connection stays.
    let ps = ClientMsg::PlayerState(PlayerState::default());
    send(&mut ws, &[ps, ping(5)]).await;
    let msgs = recv(&mut ws).await;
    assert!(matches!(msgs.as_slice(), [ServerMsg::Pong(p)] if p.client_time_ms == 5));

    // A lobby command gets a non-fatal answer until N9.
    send(
        &mut ws,
        &[ClientMsg::LobbyCommand(LobbyCommand::QuickJoin(
            Default::default(),
        ))],
    )
    .await;
    let msgs = recv(&mut ws).await;
    assert!(
        matches!(msgs.as_slice(), [ServerMsg::Error(e)] if e.code == ErrorCode::NotAllowed && !e.fatal),
        "{msgs:?}"
    );

    // The Prometheus text carries the gateway counters.
    let text = common::raw_http(
        s.metrics_addr,
        "GET /metrics HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
    )
    .await;
    for line in [
        "wb_ws_sessions 1",
        "wb_ws_handshakes_total{result=\"ok\"} 1",
        "wb_ws_handshakes_total{result=\"map_mismatch\"} 0",
        "wb_ws_messages_in_total{type=\"ping\"} 2",
        "wb_ws_messages_in_total{type=\"player_state\"} 1",
        "wb_ws_messages_in_total{type=\"lobby_command\"} 1",
        "wb_ws_rate_limited_total{type=\"ping\"} 0",
        "wb_ws_kicks_total{reason=\"banned\"} 0",
    ] {
        assert!(text.contains(line), "missing `{line}` in:\n{text}");
    }

    ws.close(None).await.unwrap();
    eventually("session released", || s.state.sessions.is_empty()).await;
    eventually("gauge back to 0", || Metrics::get(&m.ws_sessions) == 0).await;
    s.stop().await;
}

#[tokio::test]
async fn hello_and_ping_in_one_frame_get_welcome_and_pong_in_one_frame() {
    let s = start().await;
    let (_, token) = create_account(&s).await;
    let mut ws = s.connect().await;
    send(
        &mut ws,
        &[hello(PROTOCOL_VERSION, BUILD, MAP, &token), ping(9)],
    )
    .await;
    let msgs = recv(&mut ws).await;
    assert!(
        matches!(msgs.as_slice(), [ServerMsg::Welcome(_), ServerMsg::Pong(p)] if p.client_time_ms == 9),
        "{msgs:?}"
    );
    s.stop().await;
}

#[tokio::test]
async fn wrong_protocol_versions() {
    let s = start().await;
    let (_, token) = create_account(&s).await;
    // An older client must update; a newer one is ahead of this deploy.
    refused(
        &s,
        hello(PROTOCOL_VERSION - 1, BUILD, MAP, &token),
        ErrorCode::UpdateRequired,
    )
    .await;
    refused(
        &s,
        hello(PROTOCOL_VERSION + 1, BUILD, MAP, &token),
        ErrorCode::ServerOutdated,
    )
    .await;
    // A future Hello that no longer decodes here still gets the version answer from its
    // frozen prefix (peek_hello_version).
    for (version, code) in [
        (PROTOCOL_VERSION + 1, ErrorCode::ServerOutdated),
        (PROTOCOL_VERSION - 1, ErrorCode::UpdateRequired),
    ] {
        let mut frame = encode_frame(&[hello(version, BUILD, MAP, &token)])
            .unwrap()
            .to_vec();
        frame.push(0xEE);
        frame[1] += 1;
        assert!(protocol::decode_client_frame(&frame).is_err());
        let mut ws = s.connect().await;
        ws.send(Message::Binary(frame.into())).await.unwrap();
        expect_fatal(&mut ws, code).await;
    }
    let m = s.metrics();
    assert_eq!(m.handshakes(HandshakeResult::UpdateRequired), 2);
    assert_eq!(m.handshakes(HandshakeResult::ServerOutdated), 2);
    assert_eq!(m.handshakes(HandshakeResult::Ok), 0);
    s.stop().await;
}

#[tokio::test]
async fn old_client_build_must_update() {
    let s = start_with(|c| c.gateway.min_client_build = BUILD + 1).await;
    let (_, token) = create_account(&s).await;
    refused(
        &s,
        hello(PROTOCOL_VERSION, BUILD, MAP, &token),
        ErrorCode::UpdateRequired,
    )
    .await;
    s.stop().await;
}

#[tokio::test]
async fn bad_expired_and_revoked_tokens_fail_auth() {
    let s = start().await;
    let (id, token) = create_account(&s).await;
    refused(
        &s,
        hello(PROTOCOL_VERSION, BUILD, MAP, ""),
        ErrorCode::AuthFailed,
    )
    .await;
    refused(
        &s,
        hello(PROTOCOL_VERSION, BUILD, MAP, "not.a.jwt"),
        ErrorCode::AuthFailed,
    )
    .await;
    // Tampered signature.
    let mut bad = token.clone();
    bad.pop();
    bad.push(if token.ends_with('A') { 'B' } else { 'A' });
    refused(
        &s,
        hello(PROTOCOL_VERSION, BUILD, MAP, &bad),
        ErrorCode::AuthFailed,
    )
    .await;
    // Expired: issued two hours ago with a one-hour lifetime.
    let two_hours_ago = clock::unix_now_secs() - 7_200;
    let (expired, _) = s.state.auth.issue_access(id, 0, two_hours_ago).unwrap();
    refused(
        &s,
        hello(PROTOCOL_VERSION, BUILD, MAP, &expired),
        ErrorCode::AuthFailed,
    )
    .await;
    // Revoked: a token version that no longer matches.
    let (stale, _) = s
        .state
        .auth
        .issue_access(id, 99, clock::unix_now_secs())
        .unwrap();
    refused(
        &s,
        hello(PROTOCOL_VERSION, BUILD, MAP, &stale),
        ErrorCode::AuthFailed,
    )
    .await;
    assert_eq!(s.metrics().handshakes(HandshakeResult::AuthFailed), 5);
    assert!(s.state.sessions.is_empty());
    s.stop().await;
}

#[tokio::test]
async fn banned_account_is_refused_at_hello() {
    let s = start().await;
    let (id, token) = create_account(&s).await;
    admin::ban(&s.state.db, id, "7d", clock::unix_now_secs())
        .await
        .unwrap();
    let mut ws = s.connect().await;
    send(&mut ws, &[hello(PROTOCOL_VERSION, BUILD, MAP, &token)]).await;
    assert_eq!(
        expect_fatal(&mut ws, ErrorCode::Banned).await,
        DETAIL_BANNED
    );
    // Unbanned: welcome again.
    admin::unban(&s.state.db, id).await.unwrap();
    login_as(&s, &token).await;
    assert_eq!(s.metrics().handshakes(HandshakeResult::Banned), 1);
    s.stop().await;
}

#[tokio::test]
async fn map_mismatch_before_auth() {
    let s = start().await;
    // Checked before the token (PROTOCOL.md §5): even a garbage token gets map_mismatch.
    refused(
        &s,
        hello(PROTOCOL_VERSION, BUILD, MapHash([0; 32]), "garbage"),
        ErrorCode::MapMismatch,
    )
    .await;
    assert_eq!(s.metrics().handshakes(HandshakeResult::MapMismatch), 1);
    s.stop().await;

    // Production with no configured map accepts none.
    let s = common::start().await;
    let (_, token) = create_account(&s).await;
    refused(
        &s,
        hello(PROTOCOL_VERSION, BUILD, MAP, &token),
        ErrorCode::MapMismatch,
    )
    .await;
    s.stop().await;

    // Dev with no configured map accepts any (the live check sends all zeros).
    let s = common::start_with(|c| c.server.env = "dev".into()).await;
    let (_, token) = create_account(&s).await;
    let mut ws = s.connect().await;
    send(
        &mut ws,
        &[hello(PROTOCOL_VERSION, BUILD, MapHash([0; 32]), &token)],
    )
    .await;
    assert!(matches!(
        recv(&mut ws).await.as_slice(),
        [ServerMsg::Welcome(_)]
    ));
    s.stop().await;
}

#[tokio::test]
async fn no_hello_within_the_timeout() {
    let s = start_with(|c| c.gateway.hello_timeout_ms = 200).await;
    let mut ws = s.connect().await;
    let detail = expect_fatal(&mut ws, ErrorCode::HandshakeRequired).await;
    assert_eq!(detail, westbound_server::gateway::DETAIL_HELLO_TIMEOUT);
    assert_eq!(s.metrics().handshakes(HandshakeResult::HelloTimeout), 1);
    s.stop().await;
}

#[tokio::test]
async fn other_message_before_hello() {
    let s = start().await;
    refused(&s, ping(1), ErrorCode::HandshakeRequired).await;
    assert_eq!(
        s.metrics().handshakes(HandshakeResult::HandshakeRequired),
        1
    );
    s.stop().await;
}

#[tokio::test]
async fn undecodable_first_frames_are_malformed() {
    let s = start().await;
    for frame in [vec![0xFF], vec![0x01, 0x05, 0x00, 0x01], vec![0x02, 0x04]] {
        let mut ws = s.connect().await;
        ws.send(Message::Binary(frame.into())).await.unwrap();
        expect_fatal(&mut ws, ErrorCode::Malformed).await;
    }
    // Protocol frames are binary only.
    let mut ws = s.connect().await;
    ws.send(Message::Text("hello".into())).await.unwrap();
    expect_fatal(&mut ws, ErrorCode::Malformed).await;
    assert_eq!(s.metrics().handshakes(HandshakeResult::Malformed), 4);
    s.stop().await;
}

#[tokio::test]
async fn after_welcome_second_hello_or_bad_frame_is_malformed() {
    let s = start().await;
    let (mut ws, _, _, token) = login(&s).await;
    send(&mut ws, &[hello(PROTOCOL_VERSION, BUILD, MAP, &token)]).await;
    expect_fatal(&mut ws, ErrorCode::Malformed).await;
    let (mut ws, _) = login_as(&s, &token).await;
    ws.send(Message::Binary(vec![0x02, 0x09, 0x00].into()))
        .await
        .unwrap();
    expect_fatal(&mut ws, ErrorCode::Malformed).await;
    eventually("sessions released", || s.state.sessions.is_empty()).await;
    s.stop().await;
}

#[tokio::test]
async fn duplicate_login_kicks_the_older_session() {
    let s = start().await;
    let (mut old, _, id, token) = login(&s).await;
    let (mut new, _) = login_as(&s, &token).await;
    let detail = expect_fatal(&mut old, ErrorCode::NotAllowed).await;
    assert_eq!(detail, westbound_server::gateway::DETAIL_REPLACED);
    // The newer session is the registered one and keeps working.
    send(&mut new, &[ping(3)]).await;
    assert!(matches!(
        recv(&mut new).await.as_slice(),
        [ServerMsg::Pong(_)]
    ));
    let m = s.metrics().clone();
    eventually("old connection gone", || {
        Metrics::get(&m.ws_connections) == 1
    })
    .await;
    assert_eq!(s.state.sessions.len(), 1);
    assert_eq!(Metrics::get(&m.ws_sessions), 1);
    assert_eq!(Metrics::get(&m.ws_sessions_replaced), 1);
    assert_eq!(m.kicks("replaced"), 1);
    let live = s.state.sessions.get(AccountId(id as u64)).unwrap();
    assert!(!live.is_closed());
    s.stop().await;
}

#[tokio::test]
async fn rate_limits_drop_then_disconnect() {
    let s = start_with(|c| {
        let r = &mut c.ws_rate_limits;
        r.ping_per_sec = 0.001;
        r.ping_burst = 2;
        r.violation_per_sec = 0.001;
        r.violation_burst = 4;
        // One notice per test run, so the fatal error arrives alone.
        r.notice_interval_ms = 600_000;
    })
    .await;
    let (mut ws, _, _, _) = login(&s).await;
    // Four pings in one frame: two answered, two dropped, one non-fatal notice.
    send(&mut ws, &[ping(1), ping(2), ping(3), ping(4)]).await;
    let msgs = recv(&mut ws).await;
    match msgs.as_slice() {
        [ServerMsg::Pong(a), ServerMsg::Pong(b), ServerMsg::Error(e)] => {
            assert_eq!((a.client_time_ms, b.client_time_ms), (1, 2));
            assert_eq!(e.code, ErrorCode::RateLimited);
            assert!(!e.fatal);
        }
        other => panic!("unexpected {other:?}"),
    }
    let m = s.metrics().clone();
    let ping_i = client_type_index(0x02).unwrap();
    assert_eq!(m.rate_limited(ping_i), 2);
    // Other types have their own buckets.
    send(&mut ws, &[ClientMsg::PlayerState(PlayerState::default())]).await;
    // Two more drops use up the violation bucket; the next one disconnects.
    send(&mut ws, &[ping(5), ping(6), ping(7)]).await;
    expect_fatal(&mut ws, ErrorCode::RateLimited).await;
    assert_eq!(m.rate_limited(ping_i), 5);
    assert_eq!(Metrics::get(&m.ws_rate_limit_closed), 1);
    s.stop().await;
}

#[tokio::test]
async fn pong_reports_the_injected_tick_clock() {
    let tick = Arc::new(ManualTickClock::new(20));
    let s = common::start_with_tick_clock(gw, tick.clone()).await;
    let (mut ws, _, _, _) = login(&s).await;
    // (elapsed, expected tick, expected fraction) at 20 Hz = 50 ms per tick.
    for (nanos, t, f) in [
        (625_000_000u64, 12u32, 32_768u16),
        (1_012_500_000, 20, 16_384),
        (3_600_000_000_000, 72_000, 0),
        (49_999_999, 0, 65_535),
    ] {
        tick.set_nanos(nanos);
        send(&mut ws, &[ping(nanos as u32)]).await;
        let msgs = recv(&mut ws).await;
        let [ServerMsg::Pong(p)] = msgs.as_slice() else {
            panic!("expected Pong, got {msgs:?}");
        };
        assert_eq!(
            (p.client_time_ms, p.server_tick, p.tick_fraction),
            (nanos as u32, t, f)
        );
    }
    s.stop().await;
}

#[tokio::test]
async fn live_admin_ban_drops_the_socket() {
    let s = start_with(|c| c.gateway.ban_recheck_ms = 100).await;
    let (mut ws, _, id, _) = login(&s).await;
    let (mut other, _, _, _) = login(&s).await;
    // The admin CLI's own function, as `westbound-server admin ban <id> 7d` runs it.
    admin::ban(&s.state.db, id, "7d", clock::unix_now_secs())
        .await
        .unwrap();
    assert_eq!(
        expect_fatal(&mut ws, ErrorCode::Banned).await,
        DETAIL_BANNED
    );
    let m = s.metrics().clone();
    eventually("session removed", || s.state.sessions.len() == 1).await;
    assert_eq!(m.kicks("banned"), 1);
    // The unbanned player is untouched.
    send(&mut other, &[ping(1)]).await;
    assert!(matches!(
        recv(&mut other).await.as_slice(),
        [ServerMsg::Pong(_)]
    ));
    s.stop().await;
}

#[tokio::test]
async fn deleted_account_is_dropped_by_the_sweep() {
    let s = start_with(|c| c.gateway.ban_recheck_ms = 100).await;
    let (mut ws, _, id, _) = login(&s).await;
    accounts::delete(&s.state.db, id, "test").await.unwrap();
    let detail = expect_fatal(&mut ws, ErrorCode::AuthFailed).await;
    assert_eq!(detail, westbound_server::gateway::DETAIL_REVOKED);
    assert_eq!(s.metrics().kicks("revoked"), 1);
    s.stop().await;
}

#[tokio::test]
async fn oversize_frame_closes_1009() {
    let s = start().await;
    let (mut ws, _, _, _) = login(&s).await;
    let max = s.state.config.limits.max_message_bytes;
    ws.send(Message::Binary(vec![0x04; max + 1].into()))
        .await
        .unwrap();
    assert_eq!(close_code(next_msg(&mut ws).await), Some(CloseCode::Size));
    let m = s.metrics().clone();
    eventually("oversize counted", || {
        Metrics::get(&m.ws_oversize_closed) == 1
    })
    .await;
    eventually("session released", || s.state.sessions.is_empty()).await;
    // Before Hello too.
    let mut ws = s.connect().await;
    ws.send(Message::Binary(vec![0x01; max + 1].into()))
        .await
        .unwrap();
    assert_eq!(close_code(next_msg(&mut ws).await), Some(CloseCode::Size));
    s.stop().await;
}

#[tokio::test]
async fn silent_session_times_out() {
    let s = start_with(|c| {
        c.limits.ping_interval_ms = 100;
        c.limits.dead_after_ms = 500;
    })
    .await;
    let (ws, w, _, _) = login(&s).await;
    assert_eq!((w.ping_interval_ms, w.timeout_ms), (100, 500));
    // Never polled again: no pong, no pings.
    let m = s.metrics().clone();
    eventually("timed out", || Metrics::get(&m.ws_timeout_closed) == 1).await;
    eventually("session released", || s.state.sessions.is_empty()).await;
    drop(ws);
    s.stop().await;
}

#[tokio::test]
async fn responsive_session_survives_keepalive() {
    let s = start_with(|c| {
        c.limits.ping_interval_ms = 100;
        c.limits.dead_after_ms = 500;
        // Pings every 100 ms here, above the production ping rate limit.
        c.ws_rate_limits.ping_per_sec = 20.0;
    })
    .await;
    let (ws, _, _, _) = login(&s).await;
    let (mut tx, mut rx) = ws.split();
    // Client pings like NetClient (every interval) and reads everything.
    let reader = tokio::spawn(async move {
        let mut pongs = 0u32;
        while let Some(Ok(m)) = rx.next().await {
            if let Message::Binary(b) = m {
                pongs += decode_server_frame(&b)
                    .unwrap()
                    .iter()
                    .filter(|m| matches!(m, ServerMsg::Pong(_)))
                    .count() as u32;
            }
        }
        pongs
    });
    for i in 0..12 {
        let frame = encode_frame(&[ping(i)]).unwrap();
        tx.send(Message::Binary(frame.to_vec().into()))
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(Metrics::get(&s.metrics().ws_timeout_closed), 0);
    assert_eq!(s.state.sessions.len(), 1);
    s.state.shutdown.cancel();
    let pongs = tokio::time::timeout(common::WAIT, reader)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(pongs, 12);
    s.stop().await;
}

#[tokio::test]
async fn shutdown_closes_sessions_1001() {
    let s = start().await;
    let (mut ws, _, _, _) = login(&s).await;
    s.state.shutdown.cancel();
    assert_eq!(close_code(next_msg(&mut ws).await), Some(CloseCode::Away));
    let state = s.state.clone();
    s.stop().await;
    assert!(state.sessions.is_empty());
}

#[tokio::test]
async fn fatal_error_is_sent_before_the_close_with_a_gap() {
    let s = start_with(|c| c.gateway.fatal_close_delay_ms = 400).await;
    // A client that does not close: the close frame follows after the delay, so the Error
    // is never read in the same socket read as the close.
    let mut ws = s.connect().await;
    send(&mut ws, &[ping(1)]).await;
    let msgs = recv(&mut ws).await;
    assert!(matches!(msgs.as_slice(), [ServerMsg::Error(e)] if e.fatal));
    let t = tokio::time::Instant::now();
    assert_eq!(close_code(next_msg(&mut ws).await), Some(CloseCode::Policy));
    assert!(
        t.elapsed() >= Duration::from_millis(350),
        "{:?}",
        t.elapsed()
    );

    // A client that closes on the fatal error (as NetClient does) is let go at once.
    let s2 = start_with(|c| c.gateway.fatal_close_delay_ms = 10_000).await;
    let mut ws = s2.connect().await;
    send(&mut ws, &[ping(1)]).await;
    let msgs = recv(&mut ws).await;
    assert!(matches!(msgs.as_slice(), [ServerMsg::Error(e)] if e.fatal));
    let t = tokio::time::Instant::now();
    ws.close(None).await.unwrap();
    while let Some(Ok(m)) = tokio::time::timeout(common::WAIT, ws.next()).await.unwrap() {
        if matches!(m, Message::Close(_)) {
            break;
        }
    }
    let m = s2.metrics().clone();
    eventually("connection released", || {
        Metrics::get(&m.ws_connections) == 0
    })
    .await;
    assert!(t.elapsed() < Duration::from_secs(2), "{:?}", t.elapsed());
    s.stop().await;
    s2.stop().await;
}
