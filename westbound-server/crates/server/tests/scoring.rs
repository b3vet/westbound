//! Multiplayer scoring over real sockets (N6.1): bots drive through the room's traffic
//! (`bots::driver::TrafficDriver`), claim what the client's rules detect on their traffic
//! mirror (`bots::driver::Scorer`), and connect through a simulated mobile link (150 ms
//! RTT, ±30 ms jitter, 2 % of frames retransmitted). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
//! → Testing → Netcode harness ("claim acceptance above 99%"), Scoring in multiplayer.
//!
//! - honest bots: more than 99 % of their claims accepted, official scores synced;
//! - cheating bots (inflated clearance, fabricated cars, wrong timing): rejected.
//!
//! The long acceptance run is `acceptance_run_long` (ignored; `SCORING_SECS`, default
//! 300): `cargo test --release -p server --test scoring acceptance_run_long -- --ignored
//! --nocapture`.

mod common;

use std::sync::Arc;
use std::time::Duration;

use bots::{BotClient, BotConfig, Cheat, ClaimMode, DriveMode, LinkSim, RoomBot};
use common::TestServer;
use protocol::{CodeRef, Density, LobbyCommand, MapHash, RoomSettings, TimeMode, Visibility};
use westbound_server::rooms::plausibility::Offence;
use westbound_server::rooms::scoring::claims::Reject;
use westbound_server::rooms::RoomMetrics;
use westbound_server::Config;

const MAP: MapHash = MapHash([0xAB; 32]);
const BUILD: u32 = 100;

fn gw(c: &mut Config) {
    c.gateway.map_hashes = vec!["ab".repeat(32)];
    c.limits.max_connections = 1_000;
}

fn loop_map() -> Arc<sim::map::LoopMap> {
    Arc::new(
        westbound_server::map::builtin()
            .expect("loop_v1")
            .map
            .clone(),
    )
}

fn settings(density: Density) -> RoomSettings {
    RoomSettings {
        visibility: Visibility::Private,
        max_players: 8,
        density,
        time_mode: TimeMode::Cycle,
        fixed_cycle_ms: 0,
    }
}

async fn connect(s: &TestServer, cfg: BotConfig) -> BotClient {
    let (_, token) = bots::http::device_account(&s.addr.to_string())
        .await
        .expect("device account");
    let url = format!("ws://{}/ws", s.addr);
    BotClient::connect(&url, &token, MAP, BUILD, RoomBot::new(loop_map(), cfg))
        .await
        .expect("handshake")
}

/// One private room holding a bot per config; they drive for `secs`.
async fn room(s: &TestServer, cfgs: &[BotConfig], density: Density, secs: u64) -> Vec<RoomBot> {
    let mut clients = Vec::new();
    let mut code = None;
    for cfg in cfgs {
        let mut c = connect(s, *cfg).await;
        match &code {
            None => {
                c.join(LobbyCommand::RoomCreate(settings(density)))
                    .await
                    .unwrap();
                code = c.bot.code.clone();
            }
            Some(code) => c
                .join(LobbyCommand::RoomJoinCode(CodeRef { code: code.clone() }))
                .await
                .unwrap(),
        }
        clients.push(c);
    }
    let tasks: Vec<_> = clients
        .into_iter()
        .map(|mut c| {
            tokio::spawn(async move {
                c.drive_for(Duration::from_secs(secs)).await.unwrap();
                // Let the last claims be decided (and their answers arrive) before leaving.
                c.bot.scorer.stop_claims();
                c.drive_for(Duration::from_millis(2_500)).await.unwrap();
                c.close().await
            })
        })
        .collect();
    let mut out = Vec::new();
    for t in tasks {
        out.push(t.await.unwrap());
    }
    out
}

fn honest(k: u64) -> BotConfig {
    BotConfig {
        speed_mps: 64.0 + (k % 4) as f64 * 2.0,
        accel_mps2: 8.0,
        drive: DriveMode::Traffic,
        claims: ClaimMode::Honest,
        link: Some(LinkSim::MOBILE),
        seed: 100 + k,
        ..BotConfig::default()
    }
}

struct Tally {
    sent: u64,
    accepted: u64,
    /// Rejected during a run (acceptance counts these)...
    rejected: u64,
    /// ...and claims that arrived after their run ended (not counted against anyone).
    no_run: u64,
}

fn tally(s: &TestServer, bots: &[RoomBot]) -> Tally {
    let m = s.state.rooms.metrics();
    Tally {
        sent: bots.iter().map(|b| u64::from(b.scorer.stats.total())).sum(),
        accepted: RoomMetrics::get(&m.claims_accepted),
        rejected: m.claims_rejected_total(),
        no_run: m.claims_rejected(Reject::NoRun),
    }
}

fn report(s: &TestServer, bots: &[RoomBot], what: &str) -> Tally {
    let m = s.state.rooms.metrics();
    let t = tally(s, bots);
    let reasons: Vec<String> = Reject::ALL
        .iter()
        .filter(|r| m.claims_rejected(**r) > 0)
        .map(|r| format!("{}={}", r.label(), m.claims_rejected(*r)))
        .collect();
    let decided = (t.accepted + t.rejected).max(1);
    println!(
        "SCORING {what}: bots={} claims_sent={} accepted={} rejected={} acceptance={:.2}% reasons=[{}] \
         syncs={} trains={} hits_confirmed={} hits_unreported={} late={}",
        bots.len(),
        t.sent,
        t.accepted,
        t.rejected,
        100.0 * t.accepted as f64 / decided as f64,
        reasons.join(" "),
        RoomMetrics::get(&m.score_syncs),
        RoomMetrics::get(&m.trains),
        RoomMetrics::get(&m.hits_confirmed),
        RoomMetrics::get(&m.hits_unreported),
        RoomMetrics::get(&m.scoring_late),
    );
    let offences: Vec<String> = Offence::ALL
        .iter()
        .filter(|o| m.offences(**o) > 0)
        .map(|o| format!("{}={}", o.label(), m.offences(*o)))
        .collect();
    println!(
        "  offences [{}], crash-outs {}, drops out_of_order={} stale={} in_flight={}",
        offences.join(" "),
        RoomMetrics::get(&m.crash_outs),
        m.drops("out_of_order"),
        m.drops("stale"),
        m.drops("in_flight"),
    );
    for b in bots {
        let st = b.scorer.stats;
        println!(
            "  bot {:?}: {:.1} m/s mean, {} lane changes, {} hits reported; sent {} (pass {} close {} thread {} cut {}), rejected {}, last sync {:?}",
            b.player_id,
            b.odometer_m / b.driven_s.max(1.0),
            b.driver.lane_changes,
            b.hits_reported,
            st.total(),
            st.passes,
            st.close_passes,
            st.threads,
            st.cuts,
            b.seen.claims_rejected(),
            b.seen.last_sync
        );
    }
    t
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn honest_bots_claims_are_accepted_over_a_mobile_link() {
    let s = common::start_with(gw).await;
    let cfgs: Vec<BotConfig> = (0..8).map(honest).collect();
    let bots = room(&s, &cfgs, Density::Rush, 30).await;
    let t = report(&s, &bots, "honest");
    assert!(t.accepted >= 15, "enough claims to measure: {}", t.accepted);
    assert_eq!(
        t.accepted + t.rejected + t.no_run,
        t.sent,
        "every claim decided"
    );
    // Above 99 % (with a few dozen claims: none rejected; the long run measures it).
    let decided = t.accepted + t.rejected;
    assert!(
        t.rejected == 0 || t.accepted as f64 > 0.99 * decided as f64,
        "acceptance above 99 %"
    );
    for b in &bots {
        assert!(b.seen.score_syncs >= 20, "at least one sync a second");
        assert!(b.seen.traffic.violations.is_empty());
    }
    // Scores reached the players (banked or on the chain).
    assert!(bots
        .iter()
        .filter_map(|b| b.seen.last_sync.as_ref())
        .any(|s| s.banked + s.chain > 0));
    s.stop().await;
}

/// Three cheats (one of each kind) in a room with five honest bots: every cheat's claims
/// are refused for the reason it cheats on, while the honest bots' go through.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cheating_bots_claims_are_rejected() {
    let s = common::start_with(gw).await;
    let cheats = [
        Cheat::InflateClearance,
        Cheat::FabricateCars,
        Cheat::WrongTiming,
    ];
    let cfgs: Vec<BotConfig> = (0..8u64)
        .map(|k| match k.checked_sub(5) {
            Some(c) => BotConfig {
                claims: ClaimMode::Cheat(cheats[c as usize]),
                ..honest(k)
            },
            None => honest(k),
        })
        .collect();
    let bots = room(&s, &cfgs, Density::Rush, 30).await;
    let t = report(&s, &bots, "cheating");
    let m = s.state.rooms.metrics();
    let (mut honest_sent, mut honest_rejected, mut cheat_sent, mut cheat_rejected) = (0, 0, 0, 0);
    for (b, cfg) in bots.iter().zip(&cfgs) {
        let sent = b.scorer.stats.total() as usize;
        let rejected = b.seen.claims_rejected();
        match cfg.claims {
            ClaimMode::Cheat(c) => {
                cheat_sent += sent;
                cheat_rejected += rejected;
                // A genuinely close pass claimed at 0.3 m can hold (the server's clearance
                // is within 0.35 m of it); everything else is refused, for its reason:
                // fabricated cars were never passed (or never sent), claims 1.5 s early
                // miss the timing window, inflated clearances fail the clearance check.
                if c == Cheat::InflateClearance {
                    assert!(rejected * 2 >= sent, "{c:?}: {rejected} of {sent} refused");
                } else {
                    assert_eq!(rejected, sent, "{c:?}: every claim refused");
                }
                if sent > 0 {
                    let why = match c {
                        Cheat::InflateClearance => m.claims_rejected(Reject::Clearance),
                        Cheat::FabricateCars => {
                            m.claims_rejected(Reject::UnknownCar)
                                + m.claims_rejected(Reject::NoPass)
                        }
                        Cheat::WrongTiming => {
                            m.claims_rejected(Reject::Timing) + m.claims_rejected(Reject::Cut)
                        }
                    };
                    assert!(why > 0, "{c:?}: no rejection for its reason");
                }
            }
            _ => {
                honest_sent += sent;
                honest_rejected += rejected;
            }
        }
    }
    assert!(cheat_sent >= 3, "the cheats claimed: {cheat_sent}");
    assert!(cheat_rejected as f64 >= 0.75 * cheat_sent as f64);
    assert!(
        honest_sent >= 5 && honest_rejected == 0,
        "{honest_rejected} of {honest_sent}"
    );
    assert_eq!(t.accepted + t.rejected + t.no_run, t.sent);
    s.stop().await;
}

/// The acceptance number for the handoff: 8 honest bots for `SCORING_SECS` (300).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn acceptance_run_long() {
    let secs: u64 = std::env::var("SCORING_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(300);
    let density = match std::env::var("SCORING_DENSITY").as_deref() {
        Ok("light") => Density::Light,
        Ok("rush") => Density::Rush,
        _ => Density::Normal,
    };
    let s = common::start_with(gw).await;
    let cfgs: Vec<BotConfig> = (0..8).map(honest).collect();
    let bots = room(&s, &cfgs, density, secs).await;
    let t = report(&s, &bots, &format!("honest long {secs}s {density:?}"));
    assert!(t.accepted as f64 >= 0.99 * (t.accepted + t.rejected) as f64);
    s.stop().await;
}
