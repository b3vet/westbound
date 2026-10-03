//! Room invites over real WebSockets (protocol 2; the owner's request "there is no way to
//! invite my friends or crew into a private room in online mode"): a seated player invites
//! an online friend or crewmate, who gets `lobby_event.room_invite` and joins by its code;
//! the refusals (not seated, yourself, a stranger, a blocked crewmate, offline, a protocol 1
//! client, already in the room, the room full, a repeat while showing, the per-minute
//! limit) and the expiry. The players are `bots::BotClient`s with device accounts.

mod common;

use std::sync::Arc;
use std::time::Duration;

use bots::{BotClient, BotConfig, RoomBot};
use common::TestServer;
use protocol::{
    AccountId, AccountRef, CodeRef, Density, ErrorCode, ErrorMsg, LobbyCommand, LobbyEvent,
    MapHash, RoomInvite, RoomSettings, TimeMode, Visibility,
};
use westbound_server::clock::ManualClock;
use westbound_server::social::room_invites as ri;
use westbound_server::social::{crews, friends};
use westbound_server::{accounts, names, Config};

const MAP: MapHash = MapHash([0xAB; 32]);
const BUILD: u32 = 100;
const WAIT: Duration = Duration::from_secs(5);
/// Long enough for a frame that should not come.
const QUIET: Duration = Duration::from_millis(300);

fn gw(c: &mut Config) {
    c.gateway.map_hashes = vec!["ab".repeat(32)];
    c.limits.max_connections = 1_000;
    c.rooms.traffic = "none".into();
    // The refusal tests send many lobby commands back to back.
    c.ws_rate_limits.lobby_command_burst = 100;
}

struct Player {
    id: i64,
    token: String,
    full_name: String,
}

impl Player {
    fn account(&self) -> AccountId {
        AccountId(self.id as u64)
    }
}

async fn player(s: &TestServer) -> Player {
    let (account, token) = bots::http::device_account(&s.addr.to_string())
        .await
        .expect("device account");
    let id = account as i64;
    let acc = accounts::get(&s.state.db, id).await.unwrap().unwrap();
    Player {
        id,
        token,
        full_name: names::full_name(&acc.display_name, acc.tag),
    }
}

async fn connect_as(s: &TestServer, p: &Player, version: u16) -> BotClient {
    let url = format!("ws://{}/ws", s.addr);
    let map = Arc::new(
        westbound_server::map::builtin()
            .expect("loop_v1")
            .map
            .clone(),
    );
    BotClient::connect_as(
        &url,
        &p.token,
        MAP,
        BUILD,
        RoomBot::new(map, BotConfig::default()),
        version,
    )
    .await
    .expect("handshake")
}

async fn connect(s: &TestServer, p: &Player) -> BotClient {
    connect_as(s, p, protocol::PROTOCOL_VERSION).await
}

async fn befriend(s: &TestServer, a: &Player, b: &Player) {
    let (_, req) = friends::send_request(&s.state, a.id, &b.full_name)
        .await
        .unwrap();
    friends::accept(&s.state, b.id, req.request_id.parse().unwrap())
        .await
        .unwrap();
}

async fn lobby(c: &mut BotClient, cmd: LobbyCommand) {
    c.send(&[protocol::ClientMsg::LobbyCommand(cmd)])
        .await
        .unwrap();
}

async fn invite(c: &mut BotClient, to: &Player) {
    lobby(
        c,
        LobbyCommand::RoomInvite(AccountRef {
            account_id: to.account(),
        }),
    )
    .await;
}

/// The next error the bot gets.
async fn refusal(c: &mut BotClient) -> ErrorMsg {
    let before = c.bot.seen.errors.len();
    let ok = c
        .pump_until(WAIT, |b| b.seen.errors.len() > before)
        .await
        .unwrap();
    assert!(ok, "no error");
    c.bot.seen.errors.last().unwrap().clone()
}

async fn refused(c: &mut BotClient, to: &Player, code: ErrorCode, detail: &str) {
    invite(c, to).await;
    let e = refusal(c).await;
    assert_eq!((e.code, e.detail.0.as_str()), (code, detail));
    assert!(!e.fatal);
}

fn invites(c: &BotClient) -> Vec<RoomInvite> {
    c.bot
        .seen
        .lobby_events
        .iter()
        .filter_map(|e| match e {
            LobbyEvent::RoomInvite(i) => Some(i.clone()),
            _ => None,
        })
        .collect()
}

async fn invite_count(c: &mut BotClient, n: usize) -> RoomInvite {
    let ok = c
        .pump_until(WAIT, |b| {
            b.seen
                .lobby_events
                .iter()
                .filter(|e| matches!(e, LobbyEvent::RoomInvite(_)))
                .count()
                >= n
        })
        .await
        .unwrap();
    assert!(ok, "no room invite #{n}: {:?}", c.bot.seen.lobby_events);
    invites(c).pop().unwrap()
}

async fn seated(c: &mut BotClient, snapshots: u32) {
    let ok = c
        .pump_until(WAIT, |b| b.seen.snapshots > snapshots)
        .await
        .unwrap();
    assert!(ok, "no room snapshot");
}

fn private(max_players: u8) -> RoomSettings {
    RoomSettings {
        visibility: Visibility::Private,
        max_players,
        density: Density::Normal,
        time_mode: TimeMode::Cycle,
        fixed_cycle_ms: 0,
    }
}

async fn create_room(c: &mut BotClient, max_players: u8) -> (u32, protocol::Code) {
    let n = c.bot.seen.snapshots;
    lobby(c, LobbyCommand::RoomCreate(private(max_players))).await;
    seated(c, n).await;
    let snap = c.bot.seen.last_snapshot.clone().unwrap();
    (snap.room_id, snap.code)
}

/// `a` and `b` in one crew (`a` owns it).
async fn crewmates(s: &TestServer, a: &Player, b: &Player, name: &str, tag: &str) {
    let v = crews::create(&s.state, a.id, name, tag).await.unwrap();
    crews::join(&s.state, b.id, v.invite_code.as_deref().unwrap())
        .await
        .unwrap();
}

#[tokio::test]
async fn a_friend_and_a_crewmate_get_the_invite_and_join_by_its_code() {
    let s = common::start_with(gw).await;
    let (pa, pb, pc) = (player(&s).await, player(&s).await, player(&s).await);
    befriend(&s, &pa, &pb).await;
    crewmates(&s, &pa, &pc, "Room Crew", "RC").await;
    let mut a = connect(&s, &pa).await;
    let mut b = connect(&s, &pb).await;
    let mut c = connect(&s, &pc).await;
    let (room_id, code) = create_room(&mut a, 8).await;

    invite(&mut a, &pb).await;
    let inv = invite_count(&mut b, 1).await;
    assert_eq!(inv.from.account_id, pa.account());
    assert_eq!(
        names::full_name(&inv.from.display_name.0, inv.from.name_tag),
        pa.full_name
    );
    assert_eq!((inv.room_id, &inv.code), (room_id, &code));
    assert_eq!(inv.visibility, Visibility::Private);
    assert_eq!((inv.players, inv.max_players), (1, 8));
    assert_eq!(inv.expires_in_s, 120);
    // Accepting is the join by code.
    let n = b.bot.seen.snapshots;
    lobby(
        &mut b,
        LobbyCommand::RoomJoinCode(CodeRef { code: inv.code }),
    )
    .await;
    seated(&mut b, n).await;
    assert_eq!(b.bot.seen.last_snapshot.as_ref().unwrap().room_id, room_id);

    // A crewmate who is not a friend may be invited too; the count is current.
    invite(&mut a, &pc).await;
    let inv = invite_count(&mut c, 1).await;
    assert_eq!((inv.room_id, inv.players), (room_id, 2));
    // Any seated player may invite (not only the host): B invites C as well.
    befriend(&s, &pb, &pc).await;
    invite(&mut b, &pc).await;
    let inv = invite_count(&mut c, 2).await;
    assert_eq!(inv.from.account_id, pb.account());
    assert!(a.bot.seen.errors.is_empty(), "{:?}", a.bot.seen.errors);
    assert_eq!(
        s.metrics()
            .room_invites
            .load(std::sync::atomic::Ordering::Relaxed),
        3
    );
    s.stop().await;
}

#[tokio::test]
async fn refusals() {
    let s = common::start_with(|c| {
        gw(c);
        c.social.room_invites_per_minute = 6;
    })
    .await;
    let (pa, pb, pc, pd, pe, pf, pg) = (
        player(&s).await,
        player(&s).await,
        player(&s).await,
        player(&s).await,
        player(&s).await,
        player(&s).await,
        player(&s).await,
    );
    befriend(&s, &pa, &pb).await;
    befriend(&s, &pa, &pe).await;
    befriend(&s, &pa, &pf).await;
    crewmates(&s, &pa, &pc, "Block Crew", "BC").await;
    let mut a = connect(&s, &pa).await;
    let mut b = connect(&s, &pb).await;
    let mut c = connect(&s, &pc).await;
    let mut d = connect(&s, &pd).await;
    // F's game is a protocol 1 build: still welcome, but it can't decode the invite.
    let mut f = connect_as(&s, &pf, 1).await;
    assert_eq!(f.welcome.protocol_version, protocol::PROTOCOL_VERSION);

    // Not seated.
    refused(&mut a, &pb, ErrorCode::NotInRoom, ri::DETAIL_NOT_SEATED).await;
    let (_, code) = create_room(&mut a, 2).await;
    // Yourself; a stranger (online: the answer does not say so); a friend who is offline.
    refused(&mut a, &pa, ErrorCode::NotAllowed, ri::DETAIL_SELF).await;
    refused(&mut a, &pd, ErrorCode::NotAllowed, ri::DETAIL_NOT_RELATED).await;
    refused(&mut a, &pe, ErrorCode::NotAllowed, ri::DETAIL_OFFLINE).await;
    refused(&mut a, &pf, ErrorCode::NotAllowed, ri::DETAIL_OLD_CLIENT).await;
    // A crewmate who blocked A (still in the crew): refused like a stranger.
    friends::block(&s.state, pc.id, pa.id).await.unwrap();
    refused(&mut a, &pc, ErrorCode::NotAllowed, ri::DETAIL_NOT_RELATED).await;
    // B is invited; a repeat while it shows is refused.
    invite(&mut a, &pb).await;
    invite_count(&mut b, 1).await;
    refused(
        &mut a,
        &pb,
        ErrorCode::NotAllowed,
        ri::DETAIL_ALREADY_INVITED,
    )
    .await;
    // B joins: already in the room; the room (2 seats) is full for anyone else.
    let n = b.bot.seen.snapshots;
    lobby(&mut b, LobbyCommand::RoomJoinCode(CodeRef { code })).await;
    seated(&mut b, n).await;
    refused(&mut a, &pb, ErrorCode::NotAllowed, ri::DETAIL_ALREADY_HERE).await;
    befriend(&s, &pa, &pg).await;
    let mut g = connect(&s, &pg).await;
    refused(&mut a, &pg, ErrorCode::RoomFull, ri::DETAIL_ROOM_FULL).await;
    // Nobody else heard anything; the connections are fine.
    for x in [&mut c, &mut d, &mut f, &mut g] {
        x.pump_until(QUIET, |_| false).await.unwrap();
        assert!(invites(x).is_empty());
    }
    assert!(a.bot.seen.errors.iter().all(|e| !e.fatal));
    s.stop().await;
}

#[tokio::test]
async fn the_per_minute_limit() {
    let s = common::start_with(|c| {
        gw(c);
        c.social.room_invites_per_minute = 2;
    })
    .await;
    let a_p = player(&s).await;
    let mut others = Vec::new();
    for _ in 0..3 {
        let p = player(&s).await;
        befriend(&s, &a_p, &p).await;
        let c = connect(&s, &p).await;
        others.push((p, c));
    }
    let mut a = connect(&s, &a_p).await;
    create_room(&mut a, 8).await;
    for (p, c) in others.iter_mut().take(2) {
        invite(&mut a, p).await;
        invite_count(c, 1).await;
    }
    let (p3, c3) = &mut others[2];
    refused(&mut a, p3, ErrorCode::RateLimited, ri::DETAIL_TOO_MANY).await;
    c3.pump_until(QUIET, |_| false).await.unwrap();
    assert!(invites(c3).is_empty());
    s.stop().await;
}

#[tokio::test]
async fn an_invite_can_be_repeated_once_it_expired() {
    let clock = Arc::new(ManualClock::new(common::T0));
    let s = common::start_with_clock(
        |c| {
            gw(c);
            common::long_tokens(c);
            c.social.room_invite_ttl_secs = 30;
        },
        clock.clone(),
    )
    .await;
    let (pa, pb) = (player(&s).await, player(&s).await);
    befriend(&s, &pa, &pb).await;
    let mut a = connect(&s, &pa).await;
    let mut b = connect(&s, &pb).await;
    create_room(&mut a, 8).await;
    invite(&mut a, &pb).await;
    assert_eq!(invite_count(&mut b, 1).await.expires_in_s, 30);
    clock.advance(29);
    refused(
        &mut a,
        &pb,
        ErrorCode::NotAllowed,
        ri::DETAIL_ALREADY_INVITED,
    )
    .await;
    clock.advance(1);
    invite(&mut a, &pb).await;
    invite_count(&mut b, 2).await;
    assert!(s.state.room_invites.len() <= 1);
    s.stop().await;
}
