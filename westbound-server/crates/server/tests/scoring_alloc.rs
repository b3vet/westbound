//! No allocations per tick in room scoring (N6.1; working rule 6, the `traffic_alloc.rs`
//! pattern): a rush-hour ring with 8 players, their states, claims (honest ones from the
//! client's rules on the same traffic, and bogus ones), hits and a rejoin, a run ended and
//! restarted, go through `RoomScoring` without allocating once its queues are warm. A
//! counting global allocator counts every allocation on the test's thread while enabled;
//! building the claim messages (the gateway's decoding allocates them) is left out.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use protocol::{
    ClaimCar, ClaimKind, Density, FrameBuilder, HitReport, HitTarget, PlayerState, RunState,
    ScoreClaim, Side,
};
use sim::scoring::{Kind, LoopRoad, PlayerTick, ScoreEventBuffer, Scoring, ScoringParams};
use westbound_server::rooms::road::lane_center_d_mm;
use westbound_server::rooms::scoring::RoomScoring;
use westbound_server::rooms::sim_traffic::{SimTraffic, SimTrafficData};
use westbound_server::rooms::traffic::{PlayerView, RoomTraffic};
use westbound_server::rooms::{RoomMetrics, RoomParams};
use westbound_server::Config;

struct Counting;

static ALLOCS: AtomicUsize = AtomicUsize::new(0);
thread_local! {
    static ON: Cell<bool> = const { Cell::new(false) };
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ON.with(|c| c.get()) {
            ALLOCS.fetch_add(1, Ordering::Relaxed);
        }
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if ON.with(|c| c.get()) {
            ALLOCS.fetch_add(1, Ordering::Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

const PLAYERS: usize = 8;

#[test]
fn scoring_a_rush_room_allocates_nothing() {
    let map = westbound_server::map::builtin()
        .expect("loop_v1")
        .map
        .clone();
    let data = SimTrafficData::builtin().expect("sim data");
    let params = RoomParams::from_config(&Config::default());
    let origin = 100;
    let mut t = SimTraffic::new(
        &data,
        &map,
        Density::Rush,
        9,
        origin,
        params.gap,
        params.stream,
    )
    .with_history(params.scoring.history_ticks);
    let metrics = Arc::new(RoomMetrics::default());
    let mut sc = RoomScoring::new(params.scoring.clone(), &map, metrics.clone());
    let rules = ScoringParams::builtin().expect("scoring params");
    // The players drive straight, faster than the traffic, away from the seam.
    let speeds = [62.0, 55.0, 48.0, 66.0, 58.0, 51.0, 64.0, 60.0];
    let lanes = [0u8, 1, 2, 1, 0, 2, 1, 0];
    let mut s: Vec<f64> = (0..PLAYERS).map(|k| 1_000.0 + 2_500.0 * k as f64).collect();
    let mut detect: Vec<Scoring> = (0..PLAYERS).map(|_| Scoring::new(&rules)).collect();
    let mut buf = ScoreEventBuffer::new(64);
    for p in 0..PLAYERS {
        let id = p as u16 + 1;
        sc.add_player(id, (p % 2) as u8);
        sc.start_run(id, 1, origin, (s[p] * 1_000.0) as u32);
    }
    let mut views: Vec<PlayerView> = Vec::with_capacity(PLAYERS);
    let mut frames: Vec<FrameBuilder> = (0..PLAYERS).map(|_| FrameBuilder::new()).collect();
    let mut claims: Vec<(u16, ScoreClaim)> = Vec::with_capacity(64);
    let mut now = origin;
    let mut claim_id = 0u16;
    let mut run = |ticks: u32, now: &mut u32, counted: bool| {
        for k in 0..ticks {
            *now += 1;
            views.clear();
            for p in 0..PLAYERS {
                s[p] += speeds[p] * 0.05;
                let s_mm = map.wrap_mm((s[p] * 1_000.0).round() as i64);
                let d_mm = lane_center_d_mm(&map, lanes[p], s_mm);
                views.push(PlayerView {
                    player_id: p as u16 + 1,
                    tick: *now,
                    s_mm,
                    d_cm: (d_mm / 10) as i16,
                    speed_cms: (speeds[p] * 100.0) as u16,
                    heading_e4: 0,
                    lat_vel_cms: 0,
                    run_state: RunState::Driving,
                    protected_until: 0,
                });
            }
            t.tick(*now, &views);
            // Each client is streamed its area (claims may only name cars it was sent).
            for (p, v) in views.iter().enumerate() {
                frames[p].clear();
                t.write_client(v.player_id, v.s_mm, *now == origin + 1, &mut frames[p]);
            }
            ON.with(|c| c.set(counted));
            for v in &views {
                let st = PlayerState {
                    tick: v.tick,
                    s_mm: v.s_mm,
                    d_cm: v.d_cm,
                    speed_cms: v.speed_cms,
                    run_state: RunState::Driving,
                    ..PlayerState::default()
                };
                sc.on_state(v.player_id, &st, false, 0);
            }
            // The client's rules on the same traffic make the honest claims (outside the
            // count: decoding a claim allocates it in the gateway, not in the room).
            ON.with(|c| c.set(false));
            claims.clear();
            let road = LoopRoad::new(&map);
            for (p, v) in views.iter().enumerate() {
                let player = PlayerTick {
                    s: f64::from(v.s_mm) / 1_000.0,
                    d: f64::from(v.d_cm) / 100.0,
                    v: speeds[p],
                    yaw: 0.0,
                    boost_active: false,
                };
                buf.clear();
                detect[p].step(0.05, &player, &t.world().sim.state, &road, &mut buf);
                for e in buf.as_slice() {
                    let kind = match e.kind {
                        Kind::Pass => ClaimKind::Pass,
                        Kind::ClosePass => ClaimKind::ClosePass,
                        _ => continue,
                    };
                    let slot = e.slot as usize;
                    // The rules see a car wrapping at the seam "pass" (they take s as
                    // unwrapped, as on the client): only cars at the player count.
                    let car_s = t.world().sim.state.s[slot];
                    if map.signed_delta_m(player.s, car_s).abs() > 50.0 {
                        continue;
                    }
                    let car_id = t.stream().car_id(slot);
                    claim_id = claim_id.wrapping_add(1);
                    claims.push((
                        v.player_id,
                        ScoreClaim {
                            claim_id,
                            tick: *now,
                            kind,
                            side: Side::None,
                            cars: vec![ClaimCar {
                                car_id,
                                clearance_mm: (e.clearance_m * 1_000.0) as u16,
                            }],
                        },
                    ));
                }
            }
            if k % 40 == 7 {
                claim_id = claim_id.wrapping_add(1);
                claims.push((
                    3,
                    ScoreClaim {
                        claim_id,
                        tick: *now,
                        kind: ClaimKind::Pass,
                        side: Side::Left,
                        cars: vec![ClaimCar {
                            car_id: 60_000,
                            clearance_mm: 900,
                        }],
                    },
                ));
            }
            ON.with(|c| c.set(counted));
            for (pid, c) in &claims {
                sc.on_claim(*pid, c, *now);
            }
            if k % 150 == 20 {
                let hit = HitReport {
                    tick: *now,
                    target: HitTarget::Barrier,
                    car_id: 0,
                    lives_left: 1,
                };
                sc.on_hit(2, &hit, *now);
                sc.rejoin(4, *now);
            }
            sc.tick(*now, &mut t, &map, &|tick| tick % 400 > 200);
            if k == ticks / 2 {
                // A run ends (everything decided and paid) and a new one starts.
                let _ = sc.end_run(5, *now, &mut t, &map, &|_| false);
                sc.start_run(5, 2, *now, views[4].s_mm);
            }
            sc.outbox.clear();
            sc.crew_events.clear();
            ON.with(|c| c.set(false));
        }
    };
    run(200, &mut now, false);
    ALLOCS.store(0, Ordering::Relaxed);
    run(600, &mut now, true);
    let allocs = ALLOCS.load(Ordering::Relaxed);
    let accepted = RoomMetrics::get(&metrics.claims_accepted);
    let rejected = metrics.claims_rejected_total();
    println!("scoring: {accepted} claims accepted, {rejected} rejected, {allocs} allocations");
    let unknown =
        metrics.claims_rejected(westbound_server::rooms::scoring::claims::Reject::UnknownCar);
    assert!(accepted > 20, "honest claims went through: {accepted}");
    assert!(unknown > 0, "the bogus ones did not");
    assert!(
        rejected as f64 <= unknown as f64 + 0.01 * accepted as f64,
        "honest claims on the server's own traffic are accepted ({rejected} rejected)"
    );
    assert_eq!(allocs, 0, "no allocation per tick in room scoring");
}
