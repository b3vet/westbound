//! Parties over real WebSockets (N9.3): create / join / leave / kick with the state to
//! every member, invites to online friends only, blocks, Quick Join fitting the whole party
//! (a new public room when none fits) and the party as one crew, the leader moving the
//! party (members follow into private rooms too), a member's Quick Join going to the
//! leader, a member going alone leaving the party, and a dropped member's place held. The
//! players are `bots::BotClient`s with device accounts.

mod common;

use std::time::Duration;

use bots::{BotClient, BotConfig, RoomBot};
use common::TestServer;
use protocol::{
    AccountId, AccountRef, Code, CodeRef, Density, ErrorCode, LobbyCommand, LobbyEvent, MapHash,
    PartyLeft, PartyLeftReason, PartyState, RoomSettings, TimeMode, Visibility,
};
use westbound_server::social::friends;
use westbound_server::{accounts, names, Config};

const MAP: MapHash = MapHash([0xAB; 32]);
const BUILD: u32 = 100;
const WAIT: Duration = Duration::from_secs(5);

fn gw(c: &mut Config) {
    c.gateway.map_hashes = vec!["ab".repeat(32)];
    c.limits.max_connections = 1_000;
    c.rooms.traffic = "none".into();
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

async fn connect(s: &TestServer, p: &Player) -> BotClient {
    let url = format!("ws://{}/ws", s.addr);
    let map = std::sync::Arc::new(
        westbound_server::map::builtin()
            .expect("loop_v1")
            .map
            .clone(),
    );
    BotClient::connect(
        &url,
        &p.token,
        MAP,
        BUILD,
        RoomBot::new(map, BotConfig::default()),
    )
    .await
    .expect("handshake")
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

/// The latest party state the bot has seen.
fn party(c: &BotClient) -> Option<PartyState> {
    c.bot.seen.lobby_events.iter().rev().find_map(|e| match e {
        LobbyEvent::PartyState(s) => Some(s.clone()),
        _ => None,
    })
}

/// Waits for a party state with `n` members.
async fn party_of(c: &mut BotClient, n: usize) -> PartyState {
    let ok = c
        .pump_until(WAIT, |b| {
            b.seen.lobby_events.iter().rev().find_map(|e| match e {
                LobbyEvent::PartyState(s) => Some(s.members.len()),
                _ => None,
            }) == Some(n)
        })
        .await
        .unwrap();
    assert!(ok, "no party state of {n}: {:?}", c.bot.seen.lobby_events);
    party(c).unwrap()
}

async fn error_code(c: &mut BotClient) -> ErrorCode {
    let before = c.bot.seen.errors.len();
    let ok = c
        .pump_until(WAIT, |b| b.seen.errors.len() > before)
        .await
        .unwrap();
    assert!(ok, "no error");
    c.bot.seen.errors.last().unwrap().code
}

/// Waits for the bot to be seated (a follow brings an unrequested snapshot).
async fn seated(c: &mut BotClient, snapshots: u32) {
    let ok = c
        .pump_until(WAIT, |b| b.seen.snapshots > snapshots)
        .await
        .unwrap();
    assert!(ok, "no room snapshot (followed?)");
}

/// The crew slot the bot got in its own room's snapshot.
fn own_crew(c: &BotClient) -> u8 {
    let s = c.bot.seen.last_snapshot.as_ref().expect("snapshot");
    s.members
        .iter()
        .find(|m| m.player_id == s.you)
        .map(|m| m.crew_slot)
        .unwrap()
}

fn private() -> RoomSettings {
    RoomSettings {
        visibility: Visibility::Private,
        max_players: 8,
        density: Density::Normal,
        time_mode: TimeMode::Cycle,
        fixed_cycle_ms: 0,
    }
}

async fn form_party(leader: &mut BotClient, others: &mut [&mut BotClient]) -> Code {
    lobby(leader, LobbyCommand::PartyCreate(Default::default())).await;
    let code = party_of(leader, 1).await.code;
    for (i, o) in others.iter_mut().enumerate() {
        lobby(o, LobbyCommand::PartyJoin(CodeRef { code: code.clone() })).await;
        party_of(o, i + 2).await;
    }
    party_of(leader, others.len() + 1).await;
    code
}

#[tokio::test]
async fn create_join_leave_kick_and_refusals() {
    let s = common::start_with(|c| {
        gw(c);
        c.social.party_max_members = 3;
    })
    .await;
    let (pa, pb, pc, pd) = (
        player(&s).await,
        player(&s).await,
        player(&s).await,
        player(&s).await,
    );
    let (mut a, mut b, mut c, mut d) = (
        connect(&s, &pa).await,
        connect(&s, &pb).await,
        connect(&s, &pc).await,
        connect(&s, &pd).await,
    );
    lobby(&mut b, LobbyCommand::PartyLeave(Default::default())).await;
    assert_eq!(error_code(&mut b).await, ErrorCode::PartyNotFound);
    lobby(
        &mut b,
        LobbyCommand::PartyJoin(CodeRef {
            code: Code("ZZZZZZ".into()),
        }),
    )
    .await;
    assert_eq!(error_code(&mut b).await, ErrorCode::PartyNotFound);
    let code = form_party(&mut a, &mut [&mut b, &mut c]).await;
    let st = party(&a).unwrap();
    assert_eq!(st.leader, pa.account());
    assert_eq!(
        st.members.iter().map(|m| m.account_id).collect::<Vec<_>>(),
        vec![pa.account(), pb.account(), pc.account()],
        "members in join order"
    );
    // Full at party_max_members.
    lobby(
        &mut d,
        LobbyCommand::PartyJoin(CodeRef { code: code.clone() }),
    )
    .await;
    assert_eq!(error_code(&mut d).await, ErrorCode::PartyFull);
    // Only the leader kicks.
    lobby(
        &mut b,
        LobbyCommand::PartyKick(AccountRef {
            account_id: pc.account(),
        }),
    )
    .await;
    assert_eq!(error_code(&mut b).await, ErrorCode::NotPartyLeader);
    lobby(
        &mut a,
        LobbyCommand::PartyKick(AccountRef {
            account_id: pc.account(),
        }),
    )
    .await;
    let kicked = LobbyEvent::PartyLeft(PartyLeft {
        reason: PartyLeftReason::Kicked,
    });
    assert!(c
        .pump_until(WAIT, |x| x.seen.lobby_events.contains(&kicked))
        .await
        .unwrap());
    party_of(&mut b, 2).await;
    // The leader leaves: B leads the party of one.
    lobby(&mut a, LobbyCommand::PartyLeave(Default::default())).await;
    let st = party_of(&mut b, 1).await;
    assert_eq!(st.leader, pb.account());
    assert_eq!(s.state.parties.count(), 1);
    s.stop().await;
}

#[tokio::test]
async fn invites_go_to_online_friends_and_blocks_hold() {
    let s = common::start_with(gw).await;
    let (pa, pb, pc, pd) = (
        player(&s).await,
        player(&s).await,
        player(&s).await,
        player(&s).await,
    );
    befriend(&s, &pa, &pb).await;
    befriend(&s, &pa, &pd).await;
    let mut a = connect(&s, &pa).await;
    let mut b = connect(&s, &pb).await;
    let mut c = connect(&s, &pc).await;
    // C is not A's friend: refused. D is a friend but offline: refused.
    lobby(
        &mut a,
        LobbyCommand::PartyInvite(AccountRef {
            account_id: pc.account(),
        }),
    )
    .await;
    assert_eq!(error_code(&mut a).await, ErrorCode::NotAllowed);
    lobby(
        &mut a,
        LobbyCommand::PartyInvite(AccountRef {
            account_id: pd.account(),
        }),
    )
    .await;
    assert_eq!(error_code(&mut a).await, ErrorCode::NotAllowed);
    // B is online: the invite makes A a party and reaches B with its code.
    lobby(
        &mut a,
        LobbyCommand::PartyInvite(AccountRef {
            account_id: pb.account(),
        }),
    )
    .await;
    let st = party_of(&mut a, 1).await;
    let got = b
        .pump_until(WAIT, |x| {
            x.seen
                .lobby_events
                .iter()
                .any(|e| matches!(e, LobbyEvent::PartyInvite(_)))
        })
        .await
        .unwrap();
    assert!(got);
    let invite = b
        .bot
        .seen
        .lobby_events
        .iter()
        .find_map(|e| match e {
            LobbyEvent::PartyInvite(i) => Some(i.clone()),
            _ => None,
        })
        .unwrap();
    assert_eq!(invite.from.account_id, pa.account());
    assert_eq!(invite.code, st.code);
    // Accepting is party_join with the invite's code.
    lobby(
        &mut b,
        LobbyCommand::PartyJoin(CodeRef { code: invite.code }),
    )
    .await;
    party_of(&mut b, 2).await;
    // C blocked B: C can't join the party by its code.
    friends::block(&s.state, pc.id, pb.id).await.unwrap();
    lobby(&mut c, LobbyCommand::PartyJoin(CodeRef { code: st.code })).await;
    assert_eq!(error_code(&mut c).await, ErrorCode::Blocked);
    // Quick Join never matches C's room for the party (C blocked a member).
    c.join(LobbyCommand::QuickJoin(Default::default()))
        .await
        .unwrap();
    a.join(LobbyCommand::QuickJoin(Default::default()))
        .await
        .unwrap();
    assert_ne!(
        a.bot.room_id, c.bot.room_id,
        "a blocked player's room is skipped"
    );
    seated(&mut b, 0).await;
    assert_eq!(b.bot.room_id, a.bot.room_id);
    s.stop().await;
}

/// The live-check scenario on the server: two parties' worth of players, Quick Join
/// fitting the whole party (a new room when none fits), the party one crew.
#[tokio::test]
async fn quick_join_fits_the_whole_party_as_one_crew() {
    let s = common::start_with(|c| {
        gw(c);
        c.rooms.max_players = 4;
    })
    .await;
    let mut ps = Vec::new();
    for _ in 0..6 {
        ps.push(player(&s).await);
    }
    let mut bots = Vec::new();
    for p in &ps {
        bots.push(connect(&s, p).await);
    }
    let (solo, party) = bots.split_at_mut(2);
    // Two solo players fill half of a public room.
    for b in solo.iter_mut() {
        b.join(LobbyCommand::QuickJoin(Default::default()))
            .await
            .unwrap();
    }
    let solo_room = solo[0].bot.room_id;
    assert_eq!(solo[1].bot.room_id, solo_room);
    // A party of three: that room has 2 free seats, so Quick Join opens a new one.
    let (leader, rest) = party.split_at_mut(1);
    let (b, rest) = rest.split_at_mut(1);
    let (c, lone) = rest.split_at_mut(1);
    form_party(&mut leader[0], &mut [&mut b[0], &mut c[0]]).await;
    leader[0]
        .join(LobbyCommand::QuickJoin(Default::default()))
        .await
        .unwrap();
    seated(&mut b[0], 0).await;
    seated(&mut c[0], 0).await;
    let room = leader[0].bot.room_id;
    assert_ne!(room, solo_room, "the solo room can't fit three");
    assert_eq!(b[0].bot.room_id, room);
    assert_eq!(c[0].bot.room_id, room);
    let crew = own_crew(&leader[0]);
    assert_eq!(own_crew(&b[0]), crew, "the party is one crew");
    assert_eq!(own_crew(&c[0]), crew);
    assert_ne!(
        own_crew(&solo[0]),
        own_crew(&solo[1]),
        "solo players: a crew each"
    );
    // A lone player now: the fullest public room that fits (the party's, 3 of 4).
    lone[0]
        .join(LobbyCommand::QuickJoin(Default::default()))
        .await
        .unwrap();
    assert_eq!(lone[0].bot.room_id, room);
    assert_ne!(
        own_crew(&lone[0]),
        crew,
        "not in the party: not in its crew"
    );
    s.stop().await;
}

#[tokio::test]
async fn the_leader_moves_the_party_and_members_follow_or_go_alone() {
    let s = common::start_with(gw).await;
    let (pa, pb, pc, px) = (
        player(&s).await,
        player(&s).await,
        player(&s).await,
        player(&s).await,
    );
    let mut a = connect(&s, &pa).await;
    let mut b = connect(&s, &pb).await;
    let mut c = connect(&s, &pc).await;
    let mut x = connect(&s, &px).await;
    let code = {
        lobby(&mut a, LobbyCommand::PartyCreate(Default::default())).await;
        let code = party_of(&mut a, 1).await.code;
        lobby(
            &mut b,
            LobbyCommand::PartyJoin(CodeRef { code: code.clone() }),
        )
        .await;
        party_of(&mut b, 2).await;
        code
    };
    // A member's Quick Join waits for the leader's pick.
    lobby(&mut b, LobbyCommand::QuickJoin(Default::default())).await;
    assert_eq!(error_code(&mut b).await, ErrorCode::NotPartyLeader);
    // The leader creates a private room: B follows.
    a.join(LobbyCommand::RoomCreate(private())).await.unwrap();
    seated(&mut b, 0).await;
    assert_eq!(b.bot.room_id, a.bot.room_id);
    // C joins the party while A is seated: C follows into A's room.
    lobby(&mut c, LobbyCommand::PartyJoin(CodeRef { code })).await;
    seated(&mut c, 0).await;
    assert_eq!(c.bot.room_id, a.bot.room_id);
    // The leader moves on (Quick Join): both members follow.
    let (sb, sc) = (b.bot.seen.snapshots, c.bot.seen.snapshots);
    let first = a.bot.room_id;
    lobby(&mut a, LobbyCommand::RoomLeave(Default::default())).await;
    a.join(LobbyCommand::QuickJoin(Default::default()))
        .await
        .unwrap();
    seated(&mut b, sb).await;
    seated(&mut c, sc).await;
    assert_ne!(a.bot.room_id, first);
    assert_eq!(b.bot.room_id, a.bot.room_id);
    assert_eq!(c.bot.room_id, a.bot.room_id);
    // A member who joins another room goes alone and leaves the party.
    x.join(LobbyCommand::RoomCreate(private())).await.unwrap();
    lobby(&mut c, LobbyCommand::RoomLeave(Default::default())).await;
    c.join(LobbyCommand::RoomJoinCode(CodeRef {
        code: x.bot.code.clone().unwrap(),
    }))
    .await
    .unwrap();
    let left = LobbyEvent::PartyLeft(PartyLeft {
        reason: PartyLeftReason::Left,
    });
    assert!(c.bot.seen.lobby_events.contains(&left));
    party_of(&mut a, 2).await;
    assert!(s.state.parties.view(pc.account()).is_none());
    s.stop().await;
}

#[tokio::test]
async fn a_dropped_member_keeps_the_place_and_gets_the_state_back() {
    let s = common::start_with(|c| {
        gw(c);
        c.social.party_member_hold_ms = 400;
    })
    .await;
    let (pa, pb) = (player(&s).await, player(&s).await);
    let mut a = connect(&s, &pa).await;
    let mut b = connect(&s, &pb).await;
    form_party(&mut a, &mut [&mut b]).await;
    // B drops and reconnects within the hold: the state comes right after Welcome.
    let _ = b.close().await;
    let mut b = connect(&s, &pb).await;
    party_of(&mut b, 2).await;
    // Gone for longer than the hold: B leaves the party.
    let _ = b.close().await;
    party_of(&mut a, 1).await;
    assert!(s.state.parties.view(pb.account()).is_none());
    s.stop().await;
}
