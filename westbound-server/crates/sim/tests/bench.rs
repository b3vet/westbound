//! Tick cost of a full loop room's traffic at 20 Hz (multiplayer handoff → Resource
//! budget: 20 full rooms on 1 vCPU at <= 50 %, room tick p99 < 5 ms). Prints the
//! microseconds per `TrafficWorld::tick` (sim step + ramps and density upkeep, 8
//! players) at each density; the budget share is 20 rooms x 20 ticks/s x the mean.
//!
//!   cargo test --release -p sim --test bench -- --nocapture
//!
//! Debug builds print too (slow); the assertions apply to release builds only.

mod common;

use std::time::Instant;

use common::Room;
use sim::traffic::Density;

/// Release: 30 s warm-up, 120 s measured per density; debug builds (the normal test
/// suite) a short smoke run.
const WARMUP_S: f64 = if cfg!(debug_assertions) { 2.0 } else { 30.0 };
const MEASURE_S: f64 = if cfg!(debug_assertions) { 5.0 } else { 120.0 };
const ROOMS: f64 = 20.0;
const TICK_HZ: f64 = 20.0;
/// The spec's room tick p99 (the whole room, of which traffic is the bulk).
const P99_BUDGET_US: f64 = 5_000.0;
/// Traffic's share of 50 % of one vCPU for 20 rooms.
const CPU_BUDGET_FRAC: f64 = 0.5;

fn bench(density: Density) -> (f64, f64, f64, f64) {
    let mut room = Room::new(density, 11, 8, true);
    let dt = room.world.dt();
    for _ in 0..(WARMUP_S / dt) as u32 {
        room.tick();
    }
    let n = (MEASURE_S / dt) as usize;
    let mut us = Vec::with_capacity(n);
    for _ in 0..n {
        // The bots drive (outside the timing), then only the world's tick is timed.
        room.drive_bots_and_report();
        let t0 = Instant::now();
        room.world.tick();
        us.push(t0.elapsed().as_secs_f64() * 1e6);
        room.time += dt;
    }
    us.sort_by(|a, b| a.total_cmp(b));
    let mean = us.iter().sum::<f64>() / n as f64;
    let median = us[n / 2];
    let p99 = us[n * 99 / 100];
    let share = ROOMS * TICK_HZ * mean / 1e6;
    let vehicles = room.world.sim.state.count;
    println!(
        "BENCH {density:?}: {vehicles} vehicles + 8 players, {n} ticks: mean {mean:.0} us, median {median:.0} us, \
         p99 {p99:.0} us, max {:.0} us per tick; 20 rooms x 20 Hz = {:.1} % of one core",
        us[n - 1],
        share * 100.0
    );
    (mean, median, p99, share)
}

#[test]
fn bench_room_tick() {
    let mut worst_share: f64 = 0.0;
    for d in [Density::Light, Density::Normal, Density::Rush] {
        let (_, _, p99, share) = bench(d);
        worst_share = worst_share.max(share);
        if !cfg!(debug_assertions) {
            assert!(p99 < P99_BUDGET_US, "{d:?}: p99 {p99:.0} us");
        }
    }
    if !cfg!(debug_assertions) {
        assert!(
            worst_share < CPU_BUDGET_FRAC,
            "20 rooms need {:.0} % of a core",
            worst_share * 100.0
        );
    }
}
