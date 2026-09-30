//! Rooms over real WebSockets (N5.1): private rooms by code, the relay, the room clock in
//! `Pong`, reconnect within the seat hold, the hold running out, Quick Join and the
//! browser, the gateway's room errors, and N rooms × M bots in one process. The bots are
//! `bots::BotClient`s (scripted drivers). The load bench (20 rooms × 8 bots) is
//! `bench_20_rooms_of_8_bots` (ignored; run it in release, see docs/SERVER.md → Rooms).

mod common;

use std::sync::Arc;
use std::time::Duration;

use bots::{BotClient, BotConfig, RoomBot};
use common::TestServer;
use protocol::{
    Code, CodeRef, Density, ErrorCode, LeaveReason, LobbyCommand, MapHash, MemberConnection,
    MemberLeft, RoomEvent, RoomLeftReason, RoomRef, RoomSettings, TimeMode, Visibility,
};
use westbound_server::rooms::plausibility::Offence;
use westbound_server::rooms::RoomMetrics;
use westbound_server::Config;

const MAP: MapHash = MapHash([0xAB; 32]);
const BUILD: u32 = 100;

fn gw(c: &mut Config) {
    c.gateway.map_hashes = vec!["ab".repeat(32)];
    c.limits.max_connections = 1_000;
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

fn loop_map() -> Arc<sim::map::LoopMap> {
    Arc::new(
        westbound_server::map::builtin()
            .expect("loop_v1")
            .map
            .clone(),
    )
}

struct Player {
    token: String,
    account: u64,
}

async fn account(s: &TestServer) -> Player {
    let (account, token) = bots::http::device_account(&s.addr.to_string())
        .await
        .expect("device account");
    Player { token, account }
}

async fn connect(s: &TestServer, p: &Player, cfg: BotConfig) -> BotClient {
    let url = format!("ws://{}/ws", s.addr);
    BotClient::connect(&url, &p.token, MAP, BUILD, RoomBot::new(loop_map(), cfg))
        .await
        .expect("handshake")
}

fn offences(s: &TestServer) -> u64 {
    let m = s.state.rooms.metrics();
    Offence::ALL.iter().map(|o| m.offences(*o)).sum()
}

#[tokio::test]
async fn private_room_by_code_relay_and_room_clock() {
    let s = common::start_with(gw).await;
    let (pa, pb) = (account(&s).await, account(&s).await);
    let mut a = connect(&s, &pa, BotConfig::default()).await;
    a.join(LobbyCommand::RoomCreate(private(8))).await.unwrap();
    let code = a.bot.code.clone().expect("a code");
    let snap = a.bot.seen.last_snapshot.clone().unwrap();
    assert_eq!(snap.settings.visibility, Visibility::Private);
    assert!(snap.members[0].flags.host);
    assert_eq!(snap.clock.cycle_len_ms, 32 * 60_000);
    assert_eq!(snap.clock.day_len_ms, 22 * 60_000);
    let mut b = connect(&s, &pb, BotConfig::default()).await;
    b.join(LobbyCommand::RoomJoinCode(CodeRef { code: code.clone() }))
        .await
        .unwrap();
    assert_eq!(b.bot.room_id, a.bot.room_id);
    let (pid_a, pid_b) = (a.bot.player_id.unwrap(), b.bot.player_id.unwrap());
    assert_ne!(pid_a, pid_b);
    assert_eq!(s.state.rooms.room_count(), 1);
    assert_eq!(
        s.state.rooms.seat_of(protocol::AccountId(pa.account)),
        a.bot.room_id
    );

    let dur = Duration::from_secs(3);
    let (ra, rb) = tokio::join!(a.drive_for(dur), b.drive_for(dur));
    ra.unwrap();
    rb.unwrap();
    // Each saw the other at about 20 Hz, stamped near its own room-clock estimate.
    let (tick_b, n_b) = a.bot.seen.others[&pid_b];
    let (_, n_a) = b.bot.seen.others[&pid_a];
    assert!(
        n_b > 40 && n_a > 40,
        "relayed {n_b} and {n_a} states in 3 s"
    );
    let now = a.bot.server_now(a.now_ms()).unwrap();
    assert!((now - f64::from(tick_b)).abs() < 10.0, "{now} vs {tick_b}");
    assert!(a.bot.seen.pongs >= 1, "pongs carry the room clock");
    // Honest bots: no offences; one frame per tick at most.
    assert_eq!(offences(&s), 0);
    assert!(
        a.bot.seen.frames <= 3 * 20 + 10,
        "{} frames",
        a.bot.seen.frames
    );
    assert!(a.bot.seen.errors.is_empty(), "{:?}", a.bot.seen.errors);

    // The gateway's own room errors.
    b.join(LobbyCommand::RoomJoinCode(CodeRef { code }))
        .await
        .expect_err("already seated");
    assert_eq!(
        b.bot.seen.errors.last().unwrap().code,
        ErrorCode::AlreadyInRoom
    );
    let mut c = connect(&s, &account(&s).await, BotConfig::default()).await;
    c.join(LobbyCommand::RoomJoinCode(CodeRef {
        code: Code("ZZZZZZ".into()),
    }))
    .await
    .expect_err("no such room");
    assert_eq!(
        c.bot.seen.errors.last().unwrap().code,
        ErrorCode::RoomNotFound
    );
    let mut public = private(8);
    public.visibility = Visibility::Public;
    c.join(LobbyCommand::RoomCreate(public))
        .await
        .expect_err("public");
    assert_eq!(
        c.bot.seen.errors.last().unwrap().code,
        ErrorCode::NotAllowed
    );
    s.stop().await;
}

#[tokio::test]
async fn reconnect_within_the_seat_hold_keeps_the_seat() {
    let s = common::start_with(gw).await;
    let (pa, pb) = (account(&s).await, account(&s).await);
    let mut a = connect(&s, &pa, BotConfig::default()).await;
    a.join(LobbyCommand::RoomCreate(private(4))).await.unwrap();
    let code = a.bot.code.clone().unwrap();
    let mut b = connect(&s, &pb, BotConfig::default()).await;
    b.join(LobbyCommand::RoomJoinCode(CodeRef { code: code.clone() }))
        .await
        .unwrap();
    let pid_b = b.bot.player_id.unwrap();
    let (ra, rb) = tokio::join!(
        a.drive_for(Duration::from_secs(1)),
        b.drive_for(Duration::from_secs(1))
    );
    ra.unwrap();
    rb.unwrap();

    // B's network drops: A sees the seat held.
    let mut bot_b = b.close().await;
    let held = RoomEvent::Connection(MemberConnection {
        player_id: pid_b,
        connected: false,
    });
    assert!(a
        .pump_until(Duration::from_secs(5), |bot| bot
            .seen
            .room_events
            .contains(&held))
        .await
        .unwrap());
    // Back within 15 s: same seat, run intact, placed where it was.
    bot_b.reset_room();
    let placements = bot_b.seen.placements;
    let url = format!("ws://{}/ws", s.addr);
    let mut b2 = BotClient::connect(&url, &pb.token, MAP, BUILD, bot_b)
        .await
        .unwrap();
    b2.join(LobbyCommand::RoomJoinCode(CodeRef { code }))
        .await
        .unwrap();
    assert_eq!(b2.bot.player_id, Some(pid_b));
    assert!(b2.bot.seen.placements > placements);
    let back = RoomEvent::Connection(MemberConnection {
        player_id: pid_b,
        connected: true,
    });
    assert!(a
        .pump_until(Duration::from_secs(5), |bot| bot
            .seen
            .room_events
            .contains(&back))
        .await
        .unwrap());
    let (ra, rb) = tokio::join!(
        a.drive_for(Duration::from_secs(1)),
        b2.drive_for(Duration::from_secs(1))
    );
    ra.unwrap();
    rb.unwrap();
    assert!(a.bot.seen.run_results.is_empty(), "no run ended");
    assert_eq!(offences(&s), 0, "a reconnect placement is not a teleport");
    assert_eq!(RoomMetrics::get(&s.state.rooms.metrics().reconnects), 1);
    s.stop().await;
}

#[tokio::test]
async fn joining_another_room_releases_a_held_seat() {
    let s = common::start_with(gw).await;
    let (pa, pb) = (account(&s).await, account(&s).await);
    let mut a = connect(&s, &pa, BotConfig::default()).await;
    a.join(LobbyCommand::RoomCreate(private(4))).await.unwrap();
    let mut b = connect(&s, &pb, BotConfig::default()).await;
    b.join(LobbyCommand::RoomJoinCode(CodeRef {
        code: a.bot.code.clone().unwrap(),
    }))
    .await
    .unwrap();
    let (room_a, pid_b) = (a.bot.room_id, b.bot.player_id.unwrap());
    let mut bot_b = b.close().await;
    bot_b.reset_room();
    // Back online, B quick-joins a public room instead: the held seat goes at once.
    let url = format!("ws://{}/ws", s.addr);
    let mut b2 = BotClient::connect(&url, &pb.token, MAP, BUILD, bot_b)
        .await
        .unwrap();
    b2.join(LobbyCommand::QuickJoin(Default::default()))
        .await
        .unwrap();
    assert_ne!(b2.bot.room_id, room_a);
    let gone = RoomEvent::Leave(MemberLeft {
        player_id: pid_b,
        reason: LeaveReason::Left,
    });
    assert!(a
        .pump_until(Duration::from_secs(5), |bot| bot
            .seen
            .room_events
            .contains(&gone))
        .await
        .unwrap());
    assert_eq!(
        s.state.rooms.seat_of(protocol::AccountId(pb.account)),
        b2.bot.room_id
    );
    s.stop().await;
}

#[tokio::test]
async fn the_seat_hold_runs_out() {
    let s = common::start_with(|c| {
        gw(c);
        c.rooms.seat_hold_ms = 300;
    })
    .await;
    let (pa, pb) = (account(&s).await, account(&s).await);
    let mut a = connect(&s, &pa, BotConfig::default()).await;
    a.join(LobbyCommand::RoomCreate(private(4))).await.unwrap();
    let mut b = connect(&s, &pb, BotConfig::default()).await;
    b.join(LobbyCommand::RoomJoinCode(CodeRef {
        code: a.bot.code.clone().unwrap(),
    }))
    .await
    .unwrap();
    let pid_b = b.bot.player_id.unwrap();
    let _ = b.close().await;
    let gone = RoomEvent::Leave(MemberLeft {
        player_id: pid_b,
        reason: LeaveReason::TimedOut,
    });
    assert!(a
        .pump_until(Duration::from_secs(5), |bot| bot
            .seen
            .room_events
            .contains(&gone))
        .await
        .unwrap());
    assert_eq!(
        a.bot.seen.run_results.last().map(|r| r.end_reason),
        Some(protocol::RunEndReason::Disconnected)
    );
    assert_eq!(s.state.rooms.seat_of(protocol::AccountId(pb.account)), None);
    s.stop().await;
}

#[tokio::test]
async fn quick_join_browse_leave_and_the_room_cap() {
    let s = common::start_with(|c| {
        gw(c);
        c.limits.max_rooms = 1;
    })
    .await;
    let mut a = connect(&s, &account(&s).await, BotConfig::default()).await;
    let mut b = connect(&s, &account(&s).await, BotConfig::default()).await;
    a.join(LobbyCommand::QuickJoin(Default::default()))
        .await
        .unwrap();
    b.join(LobbyCommand::QuickJoin(Default::default()))
        .await
        .unwrap();
    assert_eq!(a.bot.room_id, b.bot.room_id, "the fullest public room");
    let snap = b.bot.seen.last_snapshot.clone().unwrap();
    assert_eq!(snap.settings.visibility, Visibility::Public);
    assert_eq!(snap.settings.density, Density::Normal);
    assert_eq!(snap.settings.time_mode, TimeMode::Cycle);
    assert!(snap.members.iter().all(|m| !m.flags.host));
    // The browser lists it; a join by id works; the cap refuses a second room.
    let rooms = s.state.rooms.browse();
    assert_eq!(rooms.len(), 1);
    assert_eq!((rooms[0].players, rooms[0].max_players), (2, 8));
    let mut c = connect(&s, &account(&s).await, BotConfig::default()).await;
    c.join(LobbyCommand::RoomCreate(private(4)))
        .await
        .expect_err("one room at most");
    assert_eq!(
        c.bot.seen.errors.last().unwrap().code,
        ErrorCode::ServerFull
    );
    c.join(LobbyCommand::RoomJoinId(RoomRef {
        room_id: rooms[0].room_id,
    }))
    .await
    .unwrap();
    // Leaving: told directly; the others see it.
    c.send(&[protocol::ClientMsg::LobbyCommand(LobbyCommand::RoomLeave(
        Default::default(),
    ))])
    .await
    .unwrap();
    assert!(c
        .pump_until(Duration::from_secs(5), |bot| bot.seen.room_left
            == Some(RoomLeftReason::Left))
        .await
        .unwrap());
    let left = RoomEvent::Leave(MemberLeft {
        player_id: c.bot.seen.last_snapshot.as_ref().unwrap().you,
        reason: LeaveReason::Left,
    });
    assert!(a
        .pump_until(Duration::from_secs(5), |bot| bot
            .seen
            .room_events
            .contains(&left))
        .await
        .unwrap());
    // Outside a room: leave and host commands answer not_in_room.
    c.send(&[protocol::ClientMsg::LobbyCommand(LobbyCommand::RoomLeave(
        Default::default(),
    ))])
    .await
    .unwrap();
    let n = c.bot.seen.errors.len();
    assert!(c
        .pump_until(Duration::from_secs(5), |bot| bot.seen.errors.len() > n)
        .await
        .unwrap());
    assert_eq!(c.bot.seen.errors.last().unwrap().code, ErrorCode::NotInRoom);
    s.stop().await;
}

/// `rooms` rooms of `per_room` bots driving for `secs`, all in this process.
async fn many_rooms(s: &TestServer, rooms: usize, per_room: usize, secs: u64) -> Vec<RoomBot> {
    let mut tasks = Vec::new();
    for r in 0..rooms {
        let host = account(s).await;
        let mut first = connect(s, &host, bot_cfg(r, 0)).await;
        first
            .join(LobbyCommand::RoomCreate(private(8)))
            .await
            .unwrap();
        let code = first.bot.code.clone().unwrap();
        let mut clients = vec![first];
        for k in 1..per_room {
            let p = account(s).await;
            let mut c = connect(s, &p, bot_cfg(r, k)).await;
            c.join(LobbyCommand::RoomJoinCode(CodeRef { code: code.clone() }))
                .await
                .unwrap();
            clients.push(c);
        }
        for mut c in clients {
            tasks.push(tokio::spawn(async move {
                c.drive_for(Duration::from_secs(secs)).await.unwrap();
                c.close().await
            }));
        }
    }
    let mut out = Vec::new();
    for t in tasks {
        out.push(t.await.unwrap());
    }
    out
}

fn bot_cfg(room: usize, k: usize) -> BotConfig {
    BotConfig {
        speed_mps: 30.0 + (room * 3 + k) as f64,
        ..BotConfig::default()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn four_rooms_of_four_bots() {
    let s = common::start_with(gw).await;
    let bots = many_rooms(&s, 4, 4, 3).await;
    assert_eq!(s.state.rooms.room_count(), 4);
    for b in &bots {
        assert_eq!(
            b.seen.others.len(),
            3,
            "sees exactly its room's other players"
        );
        assert!(
            b.seen.others.values().all(|(_, n)| *n > 30),
            "{:?}",
            b.seen.others
        );
        assert!(b.seen.errors.is_empty(), "{:?}", b.seen.errors);
    }
    assert_eq!(offences(&s), 0);
    s.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rooms_with_the_sim_traffic_ring() {
    let s = common::start_with(|c| {
        gw(c);
        c.rooms.traffic = westbound_server::config::ROOM_TRAFFIC_SIM.into();
    })
    .await;
    let bots = many_rooms(&s, 1, 2, 1).await;
    for b in &bots {
        assert_eq!(b.seen.others.len(), 1);
        assert!(b.seen.placements >= 1);
    }
    assert_eq!(offences(&s), 0);
    s.stop().await;
}

/// The N10 load shape on this machine: 20 rooms × 8 bots, bots and server in one process.
/// `ROOMS_BENCH_SECS` (20) sets the drive time, `ROOMS_BENCH_TRAFFIC` (`none` / `sim`) the
/// rooms' traffic. Run in release:
/// `cargo test --release -p server --test rooms bench_ -- --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn bench_20_rooms_of_8_bots() {
    let secs: u64 = std::env::var("ROOMS_BENCH_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(20);
    let traffic = std::env::var("ROOMS_BENCH_TRAFFIC").unwrap_or_else(|_| "none".into());
    let s = common::start_with(|c| {
        gw(c);
        c.rate_limits.enabled = false;
        c.rooms.traffic = traffic.clone();
    })
    .await;
    let m = s.state.rooms.metrics().clone();
    let cpu0 = process_cpu_s();
    let wall0 = std::time::Instant::now();
    let ticks0 = RoomMetrics::get(&m.ticks);
    let us0 = RoomMetrics::get(&m.tick_us_sum);
    let bots = many_rooms(&s, 20, 8, secs).await;
    let wall = wall0.elapsed().as_secs_f64();
    let cpu = process_cpu_s() - cpu0;
    let ticks = RoomMetrics::get(&m.ticks) - ticks0;
    let us = RoomMetrics::get(&m.tick_us_sum) - us0;
    let bytes: u64 = bots.iter().map(|b| b.seen.bytes).sum();
    let max_frame = bots.iter().map(|b| b.seen.max_frame).max().unwrap_or(0);
    println!(
        "ROOMS_BENCH traffic={traffic} rooms=20 bots=160 secs={secs} ticks={ticks} tick_mean_us={:.1} tick_p50_le_us={} tick_p99_le_us={} tick_max_us={} \
         room_cpu_pct_of_core={:.2} process_cpu_pct_of_core={:.1} (bots + gateway + rooms) down_bytes_per_player_s={:.0} max_frame={max_frame} offences={}",
        us as f64 / ticks.max(1) as f64,
        m.tick_quantile_us(0.5),
        m.tick_quantile_us(0.99),
        RoomMetrics::get(&m.tick_us_max),
        us as f64 / 1e6 / wall * 100.0,
        cpu / wall * 100.0,
        bytes as f64 / 160.0 / wall,
        offences(&s),
    );
    assert_eq!(offences(&s), 0);
    if !cfg!(debug_assertions) {
        assert!(m.tick_quantile_us(0.99) <= 5_000, "tick p99 under 5 ms");
    }
    s.stop().await;
}

/// This process's user + system CPU seconds (Linux `/proc/self/stat`; 0 elsewhere).
fn process_cpu_s() -> f64 {
    let Ok(stat) = std::fs::read_to_string("/proc/self/stat") else {
        return 0.0;
    };
    // Fields after the command name: state is field 3; utime and stime are 14 and 15.
    let Some(rest) = stat.rsplit_once(')').map(|(_, r)| r) else {
        return 0.0;
    };
    let f: Vec<&str> = rest.split_whitespace().collect();
    let ticks: f64 = f
        .get(11..13)
        .map(|v| v.iter().filter_map(|x| x.parse::<f64>().ok()).sum())
        .unwrap_or(0.0);
    // USER_HZ is 100 on Linux.
    ticks / 100.0
}
