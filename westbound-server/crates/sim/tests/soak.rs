//! Traffic soak on the loop (multiplayer handoff → Testing: "one simulated hour of the
//! full loop at each density has zero traffic-to-traffic collisions and stable density,
//! and every lane change is signaled for at least 1.0 s").
//!
//! - `soak_short_*` (normal suite): a few simulated minutes.
//! - `soak_hour_*` (`#[ignore]`): one simulated hour per density, faster than real time:
//!   `cargo test --release -p sim --test soak -- --ignored --nocapture`.
//!
//! Each run: a filled room at the density, bot players driving the loop (IDM, weaving,
//! reporting 150 ms late), the rule checker every tick. Asserts: no rule violation (signal
//! time, unsignaled moves, intents, collisions, clamp, brake flags, off road), no rear-end
//! of a bot driving normally, and the vehicle count within `DENSITY_TOL` of the target
//! after `SETTLE_S`, with no drift.

mod common;

use common::Room;
use sim::traffic::Density;

/// Allowed deviation of the vehicle count from the target, after the settle time.
const DENSITY_TOL: f64 = 0.05;
const SETTLE_S: f64 = 60.0;
const SAMPLE_S: f64 = 5.0;
const BOTS: usize = 6;

struct Report {
    density: Density,
    seconds: f64,
    target: usize,
    min: usize,
    max: usize,
    first_mean: f64,
    last_mean: f64,
}

fn soak(density: Density, seed: i64, seconds: f64) -> Report {
    let mut room = Room::new(density, seed, BOTS, true);
    run_soak(&mut room, density, seed, seconds)
}

fn run_soak(room: &mut Room, density: Density, seed: i64, seconds: f64) -> Report {
    let t0 = std::time::Instant::now();
    room.run(seconds, SAMPLE_S);
    let wall = t0.elapsed().as_secs_f64();
    let target = room.world.population.target();
    let settle = (SETTLE_S / SAMPLE_S) as usize;
    let tail = &room.counts[settle.min(room.counts.len())..];
    let min = *tail.iter().min().unwrap_or(&0);
    let max = *tail.iter().max().unwrap_or(&0);
    let half = tail.len() / 2;
    let mean = |x: &[usize]| x.iter().sum::<usize>() as f64 / x.len().max(1) as f64;
    let (first_mean, last_mean) = (mean(&tail[..half]), mean(&tail[half..]));
    let c = &room.checker.counts;
    let (contacts, rear) = room.contacts();
    let st = &room.world.sim;
    println!(
        "SOAK {density:?} seed {seed}: {seconds:.0} s simulated in {wall:.1} s wall ({:.0}x); vehicles target {target}, \
         after {SETTLE_S:.0} s min {min} max {max}, mean {first_mean:.1} -> {last_mean:.1}; signals {} moves {} cancels {} \
         intents {} (min lead {:.3} s), min blinker-to-motion {:.3} s; merges {} exits {} (cancelled {}) ramp entries {} \
         (blocked {}); collisions {} pairs {}; violations {}; bot contacts {contacts}, rear-ends of a normally driving bot {rear}",
        seconds / wall,
        c.signals,
        c.moves,
        c.cancels,
        c.intents,
        c.min_intent_lead_s,
        c.min_signal_s,
        st.stat_merges,
        st.stat_exits,
        st.stat_exit_cancels,
        room.world.population.stats.ramp_spawns,
        room.world.population.stats.ramp_spawn_blocked,
        c.collision_ticks,
        c.collision_pairs,
        room.checker.total_violations(),
    );
    println!(
        "SOAK {density:?} seed {seed}: body overlaps {} pair-ticks; single-player checker heading (+-0.28 rad at any \
         speed) adds {} pair-ticks, fastest {:.1} m/s",
        c.body_overlap_pairs, c.yaw_only_pairs, c.yaw_only_max_speed
    );
    assert_eq!(
        room.checker.total_violations(),
        0,
        "{}",
        room.checker.summary()
    );
    assert_eq!(rear, 0, "traffic rear-ended a bot driving normally");
    assert!(c.moves > 0 && c.intents > 0);
    assert!(c.min_signal_s >= 1.0 - 1e-9 && c.min_intent_lead_s >= 1.0 - 1e-9);
    Report {
        density,
        seconds,
        target,
        min,
        max,
        first_mean,
        last_mean,
    }
}

fn assert_stable(r: &Report) {
    let t = r.target as f64;
    assert!(
        (r.min as f64) >= t * (1.0 - DENSITY_TOL) && (r.max as f64) <= t * (1.0 + DENSITY_TOL),
        "{:?}: count {}..{} outside {}% of {}",
        r.density,
        r.min,
        r.max,
        DENSITY_TOL * 100.0,
        r.target
    );
    assert!(
        (r.last_mean - r.first_mean).abs() <= t * DENSITY_TOL * 0.5,
        "{:?}: the count drifts ({:.1} -> {:.1}) over {:.0} s",
        r.density,
        r.first_mean,
        r.last_mean,
        r.seconds
    );
}

#[test]
fn soak_short_normal() {
    let r = soak(Density::Normal, 7, 180.0);
    assert_stable(&r);
}

#[test]
fn soak_short_rush() {
    let r = soak(Density::Rush, 8, 120.0);
    assert_stable(&r);
}

#[test]
#[ignore = "one simulated hour; run with --release -- --ignored"]
fn soak_hour_light() {
    assert_stable(&soak(Density::Light, 101, 3600.0));
}

#[test]
#[ignore = "one simulated hour; run with --release -- --ignored"]
fn soak_hour_normal() {
    assert_stable(&soak(Density::Normal, 102, 3600.0));
}

#[test]
#[ignore = "one simulated hour; run with --release -- --ignored"]
fn soak_hour_rush() {
    assert_stable(&soak(Density::Rush, 103, 3600.0));
}

/// Not a gate: the same rush hour with the three MP-D5 safety extensions explicitly off
/// (the model before WP6.11 ported them to `traffic_sim.gd`, where they are on by default
/// too), to measure what they prevent. `SimConfig::multiplayer` takes the switches from
/// `MpTrafficRules` only, so clearing them here is enough. Prints the counts.
#[test]
#[ignore = "diagnostic; one simulated hour"]
fn soak_hour_rush_without_mp_extensions() {
    let mut mp = sim::traffic::MpTrafficRules::builtin().unwrap();
    mp.look_through_leaving_leaders = false;
    mp.predict_leader_braking = false;
    mp.anticipate_leader_braking = false;
    let mut room = Room::with_rules(Density::Rush, 103, BOTS, true, mp);
    room.run(3600.0, SAMPLE_S);
    let c = &room.checker.counts;
    println!(
        "WITHOUT MP EXTENSIONS rush 1 h: collision ticks {} pairs {} (body {}), decel violations {}, bot rear-ends {:?}",
        c.collision_ticks,
        c.collision_pairs,
        c.body_overlap_pairs,
        c.decel_violations,
        room.contacts()
    );
}
