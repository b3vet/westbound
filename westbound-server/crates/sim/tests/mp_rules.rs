//! The server's traffic rules (multiplayer handoff → Traffic → Server simulation), one
//! test each: 1.0 s minimum signal time for every profile with intents that name the
//! move-start tick and move time; players as participants (leaders, MOBIL followers with
//! the player b_safe, cancels), any player index; players extrapolated to the current
//! tick; the loop's seam; ramps and density; hits; road works; determinism.

mod common;

use common::Room;
use sim::map::LoopMap;
use sim::rng::Rng;
use sim::traffic::sim::{EventKind, EventTag, PlayerInput, SimConfig, SpawnRecord, TrafficSim};
use sim::traffic::state::{FLAG_HAZARD, FLAG_HIT, LC_MOVING, LC_NONE};
use sim::traffic::{Density, MpTrafficRules, RoadSpace, TrafficParams, TrafficWorld};

const KMH: f64 = 1.0 / 3.6;

fn setup(lanes: i32) -> (TrafficParams, TrafficSim) {
    let params = TrafficParams::builtin().unwrap();
    let mp = MpTrafficRules::builtin().unwrap();
    let road = RoadSpace::straight(
        lanes,
        1.7,
        3.6,
        &params.tuning.lane_flow_speeds_from_right_mps,
    );
    let sim = TrafficSim::new(
        &params,
        SimConfig::multiplayer(&params, &mp),
        road,
        &Rng::new(5).derive("traffic"),
    );
    (params, sim)
}

fn add(
    sim: &mut TrafficSim,
    params: &TrafficParams,
    s: f64,
    lane: i32,
    profile: &str,
    ty: &str,
    v_kmh: f64,
) -> usize {
    let rec = SpawnRecord {
        s,
        lane,
        d: f64::NAN,
        v: v_kmh * KMH,
        v0: v_kmh * KMH,
        type_id: params.type_index(ty).unwrap() as i32,
        profile_id: params.profile_index(profile).unwrap() as i32,
        model_variant: 0,
        color_index: 0,
        flags: 0,
    };
    sim.spawn(&rec).unwrap()
}

fn player(sim: &TrafficSim, s: f64, lane: i32, v_kmh: f64, tick: u32) -> PlayerInput {
    PlayerInput {
        s,
        d: sim.road.lane_center_d(lane, s),
        s_dot: v_kmh * KMH,
        d_dot: 0.0,
        length: 4.5,
        width: 1.9,
        tick,
    }
}

#[test]
fn every_profile_signals_at_least_one_second_and_moves_at_the_intent_tick() {
    let params = TrafficParams::builtin().unwrap();
    let floor = MpTrafficRules::builtin().unwrap().signal_time_floor_s;
    for prof in &params.profiles {
        let (_, mut sim) = setup(3);
        let ty = params.types
            [params.spawn.types_for_profile[params.profile_index(&prof.id).unwrap()][0] as usize]
            .id
            .clone();
        let slot = add(&mut sim, &params, 100.0, 1, &prof.id, &ty, 100.0);
        let dt = sim.config.tick_dt;
        sim.step(dt, 1);
        sim.events.clear();
        assert!(
            sim.request_lane_change(slot, 2),
            "{}: request refused",
            prof.id
        );
        let sig = *sim
            .events
            .as_slice()
            .iter()
            .find(|e| e.kind == EventKind::Signal)
            .expect("a Signal intent");
        let lead = f64::from(sig.move_start_tick - sig.tick) * dt;
        assert!(lead >= floor - 1e-9, "{}: intent lead {lead} s", prof.id);
        assert!(
            sig.duration_s >= prof.move_min_s && sig.duration_s <= prof.move_max_s,
            "{}: move time",
            prof.id
        );
        let d0 = sim.state.d[slot];
        let mut moved_at = None;
        let mut started_at = None;
        let mut done_lane = None;
        for k in 2..200u32 {
            sim.step(dt, k);
            if started_at.is_none() && sim.state.lc_state[slot] == LC_MOVING {
                started_at = Some(k);
                assert_eq!(
                    sim.state.lc_duration[slot], sig.duration_s,
                    "{}: announced move time",
                    prof.id
                );
            }
            if moved_at.is_none() && sim.state.d[slot] != d0 {
                moved_at = Some(k);
            }
            if started_at.is_some() && done_lane.is_none() && sim.state.lc_state[slot] == LC_NONE {
                done_lane = Some(sim.state.lane[slot]);
            }
        }
        assert_eq!(
            started_at,
            Some(sig.move_start_tick),
            "{}: the move starts at the intent's tick",
            prof.id
        );
        let first_motion = f64::from(moved_at.unwrap() - 1) * dt;
        assert!(
            first_motion >= floor - 1e-9,
            "{}: moved after {first_motion} s",
            prof.id
        );
        assert_eq!(done_lane, Some(2), "{}: the change completes", prof.id);
    }
}

#[test]
fn any_player_is_a_leader_and_traffic_never_touches_it() {
    let (params, mut sim) = setup(1);
    let car = add(&mut sim, &params, 100.0, 0, "commuter", "sedan", 120.0);
    let dt = sim.config.tick_dt;
    let mut ps = 170.0;
    let pv = 70.0;
    for k in 1..=1200u32 {
        ps += pv * KMH * dt;
        sim.set_player(5, player(&sim, ps, 0, pv, k));
        sim.step(dt, k);
        let gap = ps - sim.state.s[car] - (4.5 + sim.state.length[car]) * 0.5;
        assert!(gap > 1.0, "tick {k}: gap {gap}");
    }
    assert_eq!(sim.leader_of(car), sim.player_index(5) as i64);
    assert!(
        (sim.state.v[car] - pv * KMH).abs() < 0.5,
        "follows the player's speed"
    );
}

#[test]
fn a_player_as_new_follower_tightens_b_safe_and_signals_cancel_for_it() {
    let (params, mut sim) = setup(3);
    let dt = sim.config.tick_dt;
    let car = add(&mut sim, &params, 200.0, 1, "commuter", "sedan", 100.0);
    // Player 2 closing in lane 0: 40 m behind at 150 km/h.
    sim.set_player(2, player(&sim, 160.0, 0, 150.0, 1));
    sim.step(dt, 1);
    assert!(
        !sim.request_lane_change(car, 0),
        "refused: the player would have to brake too hard"
    );
    // Far behind: allowed; then the player closes in during the signal: cancelled.
    sim.set_player(2, player(&sim, -200.0, 0, 150.0, 2));
    sim.step(dt, 2);
    assert!(sim.request_lane_change(car, 0));
    let before = sim.stat_cancel_player;
    sim.set_player(2, player(&sim, 185.0, 0, 150.0, 3));
    sim.step(dt, 3);
    assert_eq!(
        sim.stat_cancel_player,
        before + 1,
        "the signal is cancelled for the player"
    );
    assert_eq!(sim.state.lc_state[car], LC_NONE);
    assert!(sim
        .events
        .as_slice()
        .iter()
        .any(|e| e.kind == EventKind::Cancel));
}

#[test]
fn players_are_extrapolated_to_the_current_tick() {
    let (_, mut sim) = setup(3);
    let dt = sim.config.tick_dt;
    let max = MpTrafficRules::builtin()
        .unwrap()
        .player_max_extrapolation_s;
    let input = PlayerInput {
        s: 500.0,
        d: 5.3,
        s_dot: 40.0,
        d_dot: 1.0,
        length: 4.5,
        width: 1.9,
        tick: 10,
    };
    sim.set_player(0, input);
    sim.step(dt, 14);
    assert!((sim.state_player_s(0) - (500.0 + 40.0 * 4.0 * dt)).abs() < 1e-9);
    assert!((sim.state_player_d(0) - (5.3 + 4.0 * dt)).abs() < 1e-9);
    sim.step(dt, 100);
    assert!(
        (sim.state_player_s(0) - (500.0 + 40.0 * max)).abs() < 1e-9,
        "capped"
    );
    sim.remove_player(0);
    assert!(!sim.player_active(0));
}

#[test]
fn leaders_are_found_across_the_loop_seam() {
    let params = TrafficParams::builtin().unwrap();
    let mp = MpTrafficRules::builtin().unwrap();
    let map = LoopMap::from_json(include_str!("../../../data/maps/loop_v1.json")).unwrap();
    let road = RoadSpace::from_loop(&map);
    let l = road.period();
    let mut sim = TrafficSim::new(
        &params,
        SimConfig::multiplayer(&params, &mp),
        road,
        &Rng::new(1),
    );
    let a = add(&mut sim, &params, l - 30.0, 0, "commuter", "sedan", 110.0);
    let b = add(&mut sim, &params, 15.0, 0, "truck", "semi", 80.0);
    let dt = sim.config.tick_dt;
    sim.step(dt, 1);
    assert_eq!(sim.leader_of(a), b as i64, "the truck past the seam leads");
    let gap0 = sim.leader_gap(a);
    assert!(
        (gap0 - (45.0 - (sim.state.length[a] + sim.state.length[b]) * 0.5)).abs() < 1.0,
        "gap {gap0}"
    );
    let mut wrapped = false;
    for k in 2..=2400u32 {
        sim.step(dt, k);
        let st = &sim.state;
        let gap = sim.road.signed_delta(st.s[a], st.s[b]) - (st.length[a] + st.length[b]) * 0.5;
        if (st.d[a] - st.d[b]).abs() < 1.0 {
            assert!(
                gap > 0.5 || gap < -(st.length[a] + st.length[b]),
                "tick {k}: gap {gap} in one lane"
            );
        }
        assert!(st.s[a] >= 0.0 && st.s[a] < l && st.s[b] < l);
        wrapped |= st.s[a] < 100.0;
    }
    assert!(wrapped, "the follower crossed the seam too");
}

#[test]
fn ramps_let_cars_leave_and_enter_with_telegraphed_moves() {
    let mut room = Room::new(Density::Normal, 21, 0, false);
    let mut signal_tick = std::collections::HashMap::new();
    let (mut exits, mut entries, mut merged) = (0, 0, 0);
    let mut ramp_cars = std::collections::HashSet::new();
    let dt = room.world.dt();
    for _ in 0..(240.0 / dt) as u32 {
        room.tick();
        let sim = &room.world.sim;
        for e in sim.events.as_slice() {
            match (e.kind, e.tag) {
                (EventKind::Signal, EventTag::Exit) => {
                    signal_tick.insert(e.vehicle_id, e.tick);
                }
                (EventKind::Despawned, EventTag::Exit) => {
                    let t0 = signal_tick
                        .get(&e.vehicle_id)
                        .copied()
                        .expect("exit signalled first");
                    assert!(
                        f64::from(e.tick - t0) * dt >= 1.0 + 1.5 - 1e-9,
                        "signal + move before leaving"
                    );
                    exits += 1;
                }
                (EventKind::Spawned, EventTag::Ramp) => {
                    entries += 1;
                    ramp_cars.insert(e.vehicle_id);
                }
                _ => {}
            }
        }
        let st = &sim.state;
        for i in 0..st.capacity {
            if st.active[i] == 1
                && ramp_cars.contains(&st.vehicle_id[i])
                && st.lane[i] < sim.road.lane_count(st.s[i])
            {
                ramp_cars.remove(&st.vehicle_id[i]);
                merged += 1;
            }
        }
    }
    assert_eq!(
        room.checker.total_violations(),
        0,
        "{}",
        room.checker.summary()
    );
    assert!(exits > 3 && entries > 3, "exits {exits}, entries {entries}");
    assert!(
        merged >= entries - 3,
        "on-ramp cars merge onto the road: {merged} of {entries}"
    );
}

#[test]
fn a_density_change_moves_the_ring_through_the_ramps() {
    let mut room = Room::new(Density::Light, 22, 0, false);
    let light = room.world.population.target();
    assert_eq!(room.world.sim.state.count, light);
    room.world.set_density(Density::Normal);
    let normal = room.world.population.target();
    room.run(120.0, 60.0);
    let after = room.world.sim.state.count;
    assert!(
        after > light + 40 && after <= normal,
        "{light} -> {after} (target {normal})"
    );
    room.world.set_density(Density::Light);
    room.run(180.0, 60.0);
    assert!(
        room.world.sim.state.count < after,
        "exits bring it back down"
    );
    assert_eq!(
        room.checker.total_violations(),
        0,
        "{}",
        room.checker.summary()
    );
}

#[test]
fn a_hit_by_a_player_swerves_away_from_that_player_with_hazards() {
    let (params, mut sim) = setup(3);
    let dt = sim.config.tick_dt;
    let car = add(&mut sim, &params, 100.0, 1, "commuter", "sedan", 100.0);
    sim.set_player(4, player(&sim, 97.0, 2, 100.0, 1));
    sim.step(dt, 1);
    sim.notify_hit(car, 4);
    assert!(sim.state.flags[car] & (FLAG_HIT | FLAG_HAZARD) == FLAG_HIT | FLAG_HAZARD);
    sim.events.clear();
    sim.step(dt, 2);
    assert!(sim
        .events
        .as_slice()
        .iter()
        .any(|e| e.kind == EventKind::Hazards && e.value == 1.0));
    for k in 3..15u32 {
        sim.step(dt, k);
    }
    assert!(
        sim.state.d[car] < sim.road.lane_center_d(1, 0.0),
        "swerves left, away from the player on its right"
    );
}

#[test]
fn road_works_close_their_lanes() {
    let map = LoopMap::from_json(include_str!("../../../data/maps/loop_v1.json")).unwrap();
    let mut world = TrafficWorld::builtin(&map, Density::Normal, 23).unwrap();
    let base = world.sim.lane_closure_count();
    assert!(world.set_road_works(1, true));
    assert_eq!(world.sim.lane_closure_count(), base + 1);
    let zone = world.sim.road.closure_zones[1];
    for _ in 0..(90.0 / world.dt()) as u32 {
        world.tick();
    }
    let st = &world.sim.state;
    let lanes = world.sim.road.lane_count(zone.s_start);
    for i in 0..st.capacity {
        if st.active[i] == 1 && st.s[i] > zone.s_start && st.s[i] < zone.s_end {
            assert!(
                st.lane[i] < lanes - 1 || st.lc_state[i] != LC_NONE,
                "slot {i} drives in the closed lane"
            );
        }
    }
    assert!(world.set_road_works(1, false));
    assert_eq!(world.sim.lane_closure_count(), base);
    assert!(!world.set_road_works(99, true));
}

#[test]
fn a_room_is_deterministic_by_seed() {
    let run = |seed: i64| {
        let mut room = Room::new(Density::Normal, seed, 4, true);
        let mut h = sim::trace_hash::SEED;
        for _ in 0..400 {
            room.tick();
            h = room.world.sim.state.hash_into(h);
            h = room.world.sim.internal_hash(h);
        }
        h
    };
    assert_eq!(run(31), run(31));
    assert_ne!(run(31), run(32));
}
