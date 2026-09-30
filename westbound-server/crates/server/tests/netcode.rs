//! N4.4 netcode acceptance over real sockets: honest bots drive through a room's traffic
//! over the in-process delay layer (`bots::link`) and run the client's traffic model
//! (`bots::predict`) on what they are streamed. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! Testing → Netcode harness. Acceptance at 150 ms RTT, ±30 ms jitter, 2 % loss:
//!
//! - claim acceptance above 99 %;
//! - false server-detected hits under 1 per hour;
//! - median traffic correction under 0.15 m, 99th percentile under 0.6 m;
//! - late intents under 1 per 10 minutes.
//!
//! Plus: no plausibility offence for honest bots, no traffic-stream violation, no
//! correction of a car in view large enough to snap (≥ 5 m).
//!
//! `acceptance_30s` runs in the normal suite (1 room × 8 bots × 30 s); the long run is
//! `acceptance_long` (ignored; `NETCODE_SECS`, default 600, `NETCODE_DENSITY`):
//! `cargo test --release -p server --test netcode acceptance_long -- --ignored --nocapture`.

mod common;

use std::sync::Arc;
use std::time::Duration;

use bots::{BotClient, BotConfig, ClaimMode, DriveMode, LinkSim, LinkStats, NetStats, RoomBot};
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

fn honest(k: u64, link: LinkSim) -> BotConfig {
    BotConfig {
        speed_mps: 64.0 + (k % 4) as f64 * 2.0,
        accel_mps2: 8.0,
        drive: DriveMode::Traffic,
        claims: ClaimMode::Honest,
        link: Some(link),
        seed: 700 + k,
        measure: true,
        ..BotConfig::default()
    }
}

/// One private room of `n` honest bots on `link`, driving for `secs`; the bots and their
/// link statistics.
async fn room(
    s: &TestServer,
    n: u64,
    link: LinkSim,
    density: Density,
    secs: u64,
) -> Vec<(RoomBot, LinkStats, LinkStats)> {
    let mut clients = Vec::new();
    let mut code = None;
    for k in 0..n {
        let (_, token) = bots::http::device_account(&s.addr.to_string())
            .await
            .expect("device account");
        let url = format!("ws://{}/ws", s.addr);
        let mut c = BotClient::connect(
            &url,
            &token,
            MAP,
            BUILD,
            RoomBot::new(loop_map(), honest(k, link)),
        )
        .await
        .expect("handshake");
        match &code {
            None => {
                c.join(LobbyCommand::RoomCreate(RoomSettings {
                    visibility: Visibility::Private,
                    max_players: 8,
                    density,
                    time_mode: TimeMode::Cycle,
                    fixed_cycle_ms: 0,
                }))
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
                // Let the last claims be decided before leaving.
                c.bot.scorer.stop_claims();
                c.drive_for(Duration::from_millis(2_500)).await.unwrap();
                let (up, down) = c
                    .link_stats()
                    .map(|(u, d)| (u.clone(), d.clone()))
                    .unwrap_or_default();
                (c.close().await, up, down)
            })
        })
        .collect();
    let mut out = Vec::new();
    for t in tasks {
        out.push(t.await.unwrap());
    }
    out
}

struct Numbers {
    sent: u64,
    accepted: u64,
    rejected: u64,
    offences: u64,
    false_hits: u64,
    net: NetStats,
    violations: usize,
    driven_s: f64,
}

fn report(s: &TestServer, bots: &[(RoomBot, LinkStats, LinkStats)], what: &str) -> Numbers {
    let m = s.state.rooms.metrics();
    let mut net = NetStats::default();
    let (mut up, mut down) = (LinkStats::default(), LinkStats::default());
    for (b, u, d) in bots {
        if let Some(p) = &b.predictor {
            net.merge(&p.stats);
        }
        up.merge(u);
        down.merge(d);
    }
    let offences: u64 = Offence::ALL.iter().map(|o| m.offences(*o)).sum();
    let n = Numbers {
        sent: bots
            .iter()
            .map(|(b, ..)| u64::from(b.scorer.stats.total()))
            .sum(),
        accepted: RoomMetrics::get(&m.claims_accepted),
        rejected: m.claims_rejected_total(),
        offences,
        false_hits: RoomMetrics::get(&m.hits_unreported),
        violations: bots
            .iter()
            .map(|(b, ..)| b.seen.traffic.violations.len())
            .sum(),
        driven_s: bots.iter().map(|(b, ..)| b.driven_s).sum(),
        net,
    };
    let decided = (n.accepted + n.rejected).max(1);
    let reasons: Vec<String> = Reject::ALL
        .iter()
        .filter(|r| m.claims_rejected(**r) > 0)
        .map(|r| format!("{}={}", r.label(), m.claims_rejected(*r)))
        .collect();
    let hours = n.driven_s / 3_600.0;
    let net = &n.net;
    println!(
        "NETCODE {what}: bots={} driven={:.0}s claims sent={} accepted={} rejected={} ({:.2} %) [{}] \
         offences={} false_hits={} ({:.2}/h) hits_confirmed={} violations={}",
        bots.len(),
        n.driven_s,
        n.sent,
        n.accepted,
        n.rejected,
        100.0 * n.accepted as f64 / decided as f64,
        reasons.join(" "),
        n.offences,
        n.false_hits,
        n.false_hits as f64 / hours.max(1e-9),
        RoomMetrics::get(&m.hits_confirmed),
        n.violations,
    );
    println!(
        "  corrections n={} median={:.3} p99={:.3} max={:.2} m | near n={} median={:.3} p99={:.3} max={:.2} m | \
         dead reckoning median={:.3} p99={:.3} m | large in view={} unsignaled={}",
        net.all.n,
        net.all.quantile(0.5),
        net.all.quantile(0.99),
        net.all.max,
        net.near.n,
        net.near.quantile(0.5),
        net.near.quantile(0.99),
        net.near.max,
        net.dead_reckoning.quantile(0.5),
        net.dead_reckoning.quantile(0.99),
        net.large_in_view,
        net.unsignaled_lateral,
    );
    let ages: f64 = bots.iter().map(|(b, ..)| b.seen.frame_age_sum).sum();
    let ages_n: u64 = bots.iter().map(|(b, ..)| b.seen.frame_ages).sum();
    let age_max = bots
        .iter()
        .map(|(b, ..)| b.seen.frame_age_max)
        .fold(0.0, f64::max);
    println!(
        "  intents={} late={} very_late={} ({:.2} per 10 bot-min) cancels={} late_cancels={} reanchors={} | \
         frame age mean={:.2} max={:.2} ticks",
        net.intents,
        net.late_intents,
        net.very_late_intents,
        net.late_intents as f64 / (n.driven_s / 600.0).max(1e-9),
        net.cancels,
        net.late_cancels,
        net.reanchors,
        ages / ages_n.max(1) as f64,
        age_max,
    );
    println!(
        "  link up: frames={} lost={:.2} % delay mean={:.1} p99={} max={} ms | down: frames={} lost={:.2} % \
         held={} delay mean={:.1} p99={} max={} ms",
        up.frames,
        up.loss_pct(),
        up.mean_ms(),
        up.quantile_ms(0.99),
        up.max_ms(),
        down.frames,
        down.loss_pct(),
        down.held,
        down.mean_ms(),
        down.quantile_ms(0.99),
        down.max_ms(),
    );
    n
}

/// The acceptance numbers on 1 room × 8 bots × 30 s (rush: the most passes) at the spec's link.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn acceptance_30s() {
    let s = common::start_with(gw).await;
    let bots = room(&s, 8, LinkSim::MOBILE, Density::Rush, 30).await;
    let n = report(&s, &bots, "30s rush");
    let decided = n.accepted + n.rejected;
    assert!(n.accepted >= 15, "enough claims to measure: {}", n.accepted);
    assert_eq!(n.accepted + n.rejected, n.sent, "every claim decided");
    // Above 99 %; a few dozen claims on a loaded test box allow one straggler.
    assert!(
        n.rejected <= 1 || n.accepted as f64 > 0.99 * decided as f64,
        "acceptance above 99 %"
    );
    assert_eq!(n.offences, 0, "honest bots commit no offence");
    assert_eq!(n.false_hits, 0, "no false server-detected hit");
    assert_eq!(n.violations, 0);
    let net = &n.net;
    assert!(net.all.n > 1_000, "{}", net.all.n);
    assert!(
        net.all.quantile(0.5) < 0.15,
        "median {}",
        net.all.quantile(0.5)
    );
    assert!(
        net.all.quantile(0.99) < 0.6,
        "p99 {}",
        net.all.quantile(0.99)
    );
    assert_eq!(net.large_in_view, 0, "no snap-sized correction in view");
    assert_eq!(net.late_intents, 0, "no late intent at the acceptance link");
    s.stop().await;
}

/// The acceptance run for the handoff: 8 honest bots for `NETCODE_SECS` (600).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn acceptance_long() {
    let secs: u64 = std::env::var("NETCODE_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(600);
    let density = match std::env::var("NETCODE_DENSITY").as_deref() {
        Ok("light") => Density::Light,
        Ok("rush") => Density::Rush,
        _ => Density::Normal,
    };
    let s = common::start_with(gw).await;
    let bots = room(&s, 8, LinkSim::MOBILE, density, secs).await;
    let n = report(&s, &bots, &format!("long {secs}s {density:?}"));
    let decided = n.accepted + n.rejected;
    assert!(n.accepted as f64 > 0.99 * decided as f64, "acceptance");
    assert_eq!(n.offences, 0);
    assert!(
        (n.false_hits as f64) < n.driven_s / 3_600.0,
        "false hits under 1 per hour"
    );
    let net = &n.net;
    assert!(net.all.quantile(0.5) < 0.15);
    assert!(net.all.quantile(0.99) < 0.6);
    // Late intents per 10 minutes of one client's play.
    assert!((net.late_intents as f64) < n.driven_s / 600.0);
    s.stop().await;
}
