//! Friends presence over a real WebSocket (N9.1): `lobby_command.presence_subscribe`, the
//! snapshot, pushes when friends connect, disconnect, change rooms (the N5 seam), are
//! added, removed, blocked or deleted, and unsubscribing. Real sockets against a real
//! server (tests/common), with access tokens from `POST /api/v1/auth/device`.

mod common;

use common::{next_msg, TestServer, Ws};
use futures_util::SinkExt;
use protocol::{
    decode_server_frame, encode_frame, AccessToken, AccountId, ClientMsg, FriendPresence, Hello,
    LobbyCommand, LobbyEvent, MapHash, Ping, PresenceStatus, PresenceSubscribe, ServerMsg,
    PROTOCOL_VERSION,
};
use tokio_tungstenite::tungstenite::Message;
use westbound_server::presence::RoomPresence;
use westbound_server::social::friends;
use westbound_server::{accounts, names, Config};

const MAP: MapHash = MapHash([0xAB; 32]);

fn gw(c: &mut Config) {
    c.gateway.map_hashes = vec!["ab".repeat(32)];
}

struct Player {
    id: i64,
    token: String,
    full_name: String,
}

async fn create_account(s: &TestServer) -> Player {
    let resp = common::raw_http(
        s.addr,
        "POST /api/v1/auth/device HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(resp.starts_with("HTTP/1.1 201"), "{resp}");
    let v: serde_json::Value =
        serde_json::from_str(resp.split_once("\r\n\r\n").unwrap().1).unwrap();
    let id: i64 = v["account_id"].as_str().unwrap().parse().unwrap();
    let acc = accounts::get(&s.state.db, id).await.unwrap().unwrap();
    Player {
        id,
        token: v["access_token"].as_str().unwrap().to_owned(),
        full_name: names::full_name(&acc.display_name, acc.tag),
    }
}

async fn befriend(s: &TestServer, a: &Player, b: &Player) {
    let (_, req) = friends::send_request(&s.state, a.id, &b.full_name)
        .await
        .unwrap();
    friends::accept(&s.state, b.id, req.request_id.parse().unwrap())
        .await
        .unwrap();
}

async fn send(ws: &mut Ws, msgs: &[ClientMsg]) {
    let frame = encode_frame(msgs).unwrap();
    ws.send(Message::Binary(frame.to_vec().into()))
        .await
        .unwrap();
}

async fn recv(ws: &mut Ws) -> Vec<ServerMsg> {
    match next_msg(ws).await {
        Some(Message::Binary(b)) => decode_server_frame(&b).expect("server frame decodes"),
        other => panic!("expected a binary frame, got {other:?}"),
    }
}

/// The next frame, which must hold only presence messages; their entries.
async fn presence(ws: &mut Ws) -> Vec<FriendPresence> {
    let mut out = Vec::new();
    for m in recv(ws).await {
        let ServerMsg::LobbyEvent(LobbyEvent::Presence(p)) = m else {
            panic!("expected presence, got {m:?}");
        };
        out.extend(p.friends);
    }
    out
}

async fn login(s: &TestServer, p: &Player) -> Ws {
    let mut ws = s.connect().await;
    send(
        &mut ws,
        &[ClientMsg::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            client_build: 1,
            map_hash: MAP,
            access_token: AccessToken(p.token.clone()),
        })],
    )
    .await;
    let msgs = recv(&mut ws).await;
    assert!(
        matches!(msgs.as_slice(), [ServerMsg::Welcome(_)]),
        "{msgs:?}"
    );
    ws
}

fn subscribe(enabled: bool) -> ClientMsg {
    ClientMsg::LobbyCommand(LobbyCommand::PresenceSubscribe(PresenceSubscribe {
        enabled,
    }))
}

fn entry(p: &Player, status: PresenceStatus, room_id: u32, joinable: bool) -> FriendPresence {
    FriendPresence {
        account_id: AccountId(p.id as u64),
        status,
        room_id,
        joinable,
    }
}

fn offline(p: &Player) -> FriendPresence {
    entry(p, PresenceStatus::Offline, 0, false)
}

fn online(p: &Player) -> FriendPresence {
    entry(p, PresenceStatus::Online, 0, false)
}

#[tokio::test]
async fn presence_subscribe_snapshot_and_pushes() {
    let s = common::start_with(gw).await;
    let (a, b, c) = (
        create_account(&s).await,
        create_account(&s).await,
        create_account(&s).await,
    );
    befriend(&s, &a, &b).await;

    // Snapshot: B is offline.
    let mut wa = login(&s, &a).await;
    send(&mut wa, &[subscribe(true)]).await;
    assert_eq!(presence(&mut wa).await, vec![offline(&b)]);
    assert!(s.state.presence.is_subscribed(AccountId(a.id as u64)));

    // B connects: pushed as online. B's own snapshot shows A online.
    let mut wb = login(&s, &b).await;
    assert_eq!(presence(&mut wa).await, vec![online(&b)]);
    send(&mut wb, &[subscribe(true)]).await;
    assert_eq!(presence(&mut wb).await, vec![online(&a)]);

    // The N5 seam: B joins a room with space, then leaves it.
    let bid = AccountId(b.id as u64);
    s.state.presence.set_room(
        bid,
        Some(RoomPresence {
            room_id: 7,
            joinable: true,
        }),
    );
    assert_eq!(
        presence(&mut wa).await,
        vec![entry(&b, PresenceStatus::InRoom, 7, true)]
    );
    s.state.presence.set_room(
        bid,
        Some(RoomPresence {
            room_id: 7,
            joinable: false,
        }),
    );
    assert_eq!(
        presence(&mut wa).await,
        vec![entry(&b, PresenceStatus::InRoom, 7, false)]
    );
    s.state.presence.set_room(bid, None);
    assert_eq!(presence(&mut wa).await, vec![online(&b)]);

    // A new friendship is pushed to a subscriber at once.
    befriend(&s, &c, &a).await;
    assert_eq!(presence(&mut wa).await, vec![offline(&c)]);
    // Removing a friend shows them offline to the subscriber (then nothing more).
    friends::remove(&s.state, a.id, c.id).await.unwrap();
    assert_eq!(presence(&mut wa).await, vec![offline(&c)]);

    // B disconnects: pushed as offline.
    wb.close(None).await.unwrap();
    assert_eq!(presence(&mut wa).await, vec![offline(&b)]);

    // Unsubscribed: B connecting again pushes nothing (the Pong is A's next frame).
    send(&mut wa, &[subscribe(false)]).await;
    let mut wb = login(&s, &b).await;
    send(&mut wa, &[ClientMsg::Ping(Ping { client_time_ms: 5 })]).await;
    assert!(matches!(
        recv(&mut wa).await.as_slice(),
        [ServerMsg::Pong(_)]
    ));
    assert!(!s.state.presence.is_subscribed(AccountId(a.id as u64)));

    // Subscribing again: a fresh snapshot. A Ping in the same frame is answered first.
    send(
        &mut wa,
        &[ClientMsg::Ping(Ping { client_time_ms: 6 }), subscribe(true)],
    )
    .await;
    assert!(matches!(
        recv(&mut wa).await.as_slice(),
        [ServerMsg::Pong(_)]
    ));
    assert_eq!(presence(&mut wa).await, vec![online(&b)]);

    // Blocking ends the friendship: B shows offline to A, and A to B.
    send(&mut wb, &[subscribe(true)]).await;
    assert_eq!(presence(&mut wb).await, vec![online(&a)]);
    friends::block(&s.state, a.id, b.id).await.unwrap();
    assert_eq!(presence(&mut wa).await, vec![offline(&b)]);
    assert_eq!(presence(&mut wb).await, vec![offline(&a)]);

    // A's session ends: its subscription goes with it.
    wa.close(None).await.unwrap();
    common::eventually("A's subscription ends", || {
        !s.state.presence.is_subscribed(AccountId(a.id as u64))
    })
    .await;
    drop(wb);
    s.stop().await;
}

#[tokio::test]
async fn deleted_friend_goes_offline_and_is_dropped() {
    let s = common::start_with(gw).await;
    let (a, d) = (create_account(&s).await, create_account(&s).await);
    befriend(&s, &a, &d).await;
    let mut wa = login(&s, &a).await;
    send(&mut wa, &[subscribe(true)]).await;
    assert_eq!(presence(&mut wa).await, vec![offline(&d)]);
    let mut wd = login(&s, &d).await;
    assert_eq!(presence(&mut wa).await, vec![online(&d)]);

    // D deletes the account over HTTP: friends see it offline at once, its socket ends.
    let resp = common::raw_http(
        s.addr,
        &format!(
            "DELETE /api/v1/account HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer {}\r\n\
             Content-Length: 0\r\nConnection: close\r\n\r\n",
            d.token
        ),
    )
    .await;
    assert!(resp.starts_with("HTTP/1.1 204"), "{resp}");
    assert_eq!(presence(&mut wa).await, vec![offline(&d)]);
    let msgs = recv(&mut wd).await;
    assert!(
        matches!(msgs.as_slice(), [ServerMsg::Error(e)] if e.fatal && e.code == protocol::ErrorCode::AuthFailed),
        "{msgs:?}"
    );
    // Nothing more about D reaches A.
    send(&mut wa, &[ClientMsg::Ping(Ping { client_time_ms: 1 })]).await;
    assert!(matches!(
        recv(&mut wa).await.as_slice(),
        [ServerMsg::Pong(_)]
    ));
    s.stop().await;
}

#[tokio::test]
async fn replaced_session_keeps_the_friend_online() {
    let s = common::start_with(gw).await;
    let (a, b) = (create_account(&s).await, create_account(&s).await);
    befriend(&s, &a, &b).await;
    let mut wa = login(&s, &a).await;
    send(&mut wa, &[subscribe(true)]).await;
    assert_eq!(presence(&mut wa).await, vec![offline(&b)]);
    let mut wb1 = login(&s, &b).await;
    assert_eq!(presence(&mut wa).await, vec![online(&b)]);
    // B signs in on another device: the old session is kicked, B never went offline.
    let _wb2 = login(&s, &b).await;
    let msgs = recv(&mut wb1).await;
    assert!(
        matches!(msgs.as_slice(), [ServerMsg::Error(e)] if e.fatal),
        "{msgs:?}"
    );
    // Its cleanup has run once the server closed it.
    assert!(matches!(
        next_msg(&mut wb1).await,
        Some(Message::Close(_)) | None
    ));
    send(&mut wa, &[ClientMsg::Ping(Ping { client_time_ms: 1 })]).await;
    assert!(matches!(
        recv(&mut wa).await.as_slice(),
        [ServerMsg::Pong(_)]
    ));
    s.stop().await;
}
