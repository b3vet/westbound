//! Traffic parity with the GDScript models (multiplayer handoff → Testing: "the Rust IDM
//! and MOBIL match the GDScript versions on shared test vectors to within 1e-9").
//! Vectors: `crates/sim/vectors/*.json`, written by
//! `tools/server_data/export_sim_data.gd` (re-run it after any change to src/traffic/ or
//! the traffic tuning). Floats are IEEE-754 bits in hex, so every comparison below can be
//! exact; the spec's 1e-9 is checked too.
//!
//! - `rng`: the PCG32 port draws Godot's numbers bit for bit.
//! - `idm`, `mobil`, `no_ambush`, `player_velocity`: the pure models.
//! - `loop_closures`: the loop's lane closures and WP6.8 drop zones as the client computes them.
//! - `trace_*`: the whole sim replayed tick by tick against the GDScript sim (same seed,
//!   same player, same spawns): the state's trace hash after every tick and every event.

use serde_json::Value;
use sim::map::LoopMap;
use sim::rng::{derive_seed, Rng};
use sim::traffic::idm;
use sim::traffic::mobil;
use sim::traffic::no_ambush;
use sim::traffic::sim::{EventKind, EventTag, PlayerInput, SimConfig, SpawnRecord, TrafficSim};
use sim::traffic::{RoadSpace, TrafficParams};

const TOL: f64 = 1e-9;

fn hx(v: &Value) -> f64 {
    let s = v.as_str().expect("hex float");
    f64::from_bits(u64::from_str_radix(s, 16).expect("hex bits"))
}

fn doc(text: &str) -> Value {
    serde_json::from_str(text).expect("vector json")
}

/// Exact, or within the spec's 1e-9 (relative above 1). Returns true when bit-exact.
fn same(got: f64, want: f64, what: &str) -> bool {
    if got.to_bits() == want.to_bits() || (got.is_nan() && want.is_nan()) {
        return true;
    }
    assert!(
        (got.is_infinite() && want.is_infinite() && got.signum() == want.signum())
            || (got - want).abs() <= TOL * want.abs().max(1.0),
        "{what}: rust {got:e} vs gdscript {want:e}"
    );
    got == want
}

#[test]
fn rng_draws_match_godot() {
    let d = doc(include_str!("../vectors/rng.json"));
    let names: Vec<&str> = d["names"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_str().unwrap())
        .collect();
    let weights = [22.0, 40.0, 12.0, 0.0, 10.0, 6.0, 6.0];
    for c in d["cases"].as_array().unwrap() {
        let seed: i64 = c["seed"].as_str().unwrap().parse().unwrap();
        let mut r = Rng::new(seed);
        for u in c["unit"].as_array().unwrap() {
            assert_eq!(r.unit().to_bits(), hx(u).to_bits(), "unit, seed {seed}");
        }
        for x in c["int_m5_17"].as_array().unwrap() {
            assert_eq!(
                i64::from(r.int_range(-5, 17)),
                x.as_i64().unwrap(),
                "int_range, seed {seed}"
            );
        }
        for x in c["int_7_0"].as_array().unwrap() {
            assert_eq!(
                i64::from(r.int_range(7, 0)),
                x.as_i64().unwrap(),
                "int_range(7, 0), seed {seed}"
            );
        }
        for x in c["float_2_3p5"].as_array().unwrap() {
            assert_eq!(
                r.float_range(2.0, 3.5).to_bits(),
                hx(x).to_bits(),
                "float_range, seed {seed}"
            );
        }
        for x in c["chance_0p3"].as_array().unwrap() {
            assert_eq!(r.chance(0.3), x.as_bool().unwrap(), "chance, seed {seed}");
        }
        for x in c["pick"].as_array().unwrap() {
            assert_eq!(
                r.pick_weighted(&weights) as u64,
                x.as_u64().unwrap(),
                "pick_weighted, seed {seed}"
            );
        }
        let state: i64 = c["state"].as_str().unwrap().parse().unwrap();
        assert_eq!(r.state() as i64, state, "state, seed {seed}");
        for (k, x) in c["derive"].as_array().unwrap().iter().enumerate() {
            let want: i64 = x.as_str().unwrap().parse().unwrap();
            assert_eq!(
                derive_seed(seed, names[k]),
                want,
                "derive_seed({seed}, {})",
                names[k]
            );
        }
    }
    for c in d["traffic_chain"].as_array().unwrap() {
        let seed: i64 = c[0].as_str().unwrap().parse().unwrap();
        let traffic = Rng::new(seed).derive("traffic");
        assert_eq!(
            traffic.seed(),
            c[1].as_str().unwrap().parse::<i64>().unwrap()
        );
        assert_eq!(
            traffic.derive("sim_lane_change").seed(),
            c[2].as_str().unwrap().parse::<i64>().unwrap()
        );
    }
}

#[test]
fn idm_matches_gdscript() {
    let d = doc(include_str!("../vectors/idm.json"));
    let cases = d["cases"].as_array().unwrap();
    let mut exact = 0;
    let mut total = 0;
    for c in cases {
        let f = |k: usize| hx(&c[k]);
        let (v, v0, gap, dv, a, b, t, s0) = (f(0), f(1), f(2), f(3), f(4), f(5), f(6), f(7));
        let dl = c[8].as_i64().unwrap() as i32;
        let floor = f(9);
        let got = [
            idm::accel(v, v0, gap, dv, a, b, t, s0, dl, floor),
            idm::free_accel(v, v0, a, dl),
            idm::interaction_accel(v, gap, dv, a, b, t, s0, floor),
            idm::desired_gap(v, dv, a, b, t, s0),
            idm::equilibrium_gap(v, v0, t, s0, dl),
            idm::pow_int(v / v0, dl),
        ];
        for (k, g) in got.iter().enumerate() {
            total += 1;
            if same(*g, f(10 + k), &format!("idm column {k}, case {c}")) {
                exact += 1;
            }
        }
    }
    println!(
        "IDM parity: {exact}/{total} values bit-exact over {} cases",
        cases.len()
    );
    assert_eq!(exact, total, "IDM is not bit-exact");
}

#[test]
fn mobil_matches_gdscript() {
    let d = doc(include_str!("../vectors/mobil.json"));
    let cases = d["cases"].as_array().unwrap();
    for c in cases {
        let f = |k: usize| hx(&c[k]);
        let to_right = c[9].as_bool().unwrap();
        let is_player = c[11].as_bool().unwrap();
        let inc = mobil::incentive(f(0), f(1), f(2), f(3), f(4), f(5), f(6));
        assert!(same(inc, f(13), "incentive"));
        assert!(same(
            mobil::threshold(f(7), f(8), to_right),
            f(14),
            "threshold"
        ));
        assert_eq!(
            mobil::accepts(inc, f(7), f(8), to_right),
            c[15].as_bool().unwrap(),
            "accepts"
        );
        assert_eq!(
            mobil::is_safe(f(2), f(10)),
            c[16].as_bool().unwrap(),
            "is_safe"
        );
        assert!(same(
            mobil::b_safe_for(f(10), is_player, f(12)),
            f(17),
            "b_safe_for"
        ));
    }
    println!("MOBIL parity: {} cases bit-exact", cases.len());
}

#[test]
fn no_ambush_matches_gdscript() {
    let d = doc(include_str!("../vectors/no_ambush.json"));
    let cases = d["cases"].as_array().unwrap();
    let mut hits = 0;
    for c in cases {
        let f = |k: usize| hx(&c[k]);
        let got = no_ambush::violates(
            f(0),
            f(1),
            f(2),
            f(3),
            f(4),
            f(5),
            f(6),
            f(7),
            f(8),
            f(9),
            f(10),
            f(11),
            f(12),
        );
        assert_eq!(got, c[13].as_bool().unwrap(), "no-ambush case {c}");
        hits += usize::from(got);
    }
    println!("No-ambush parity: {} cases, {hits} violations", cases.len());
    assert!(
        hits > cases.len() / 10,
        "the vectors should exercise violations"
    );
}

#[test]
fn player_velocity_matches_gdscript() {
    let d = doc(include_str!("../vectors/player_velocity.json"));
    for c in d["cases"].as_array().unwrap() {
        let f = |k: usize| hx(&c[k]);
        let p = PlayerInput::from_vehicle(0.0, f(4), f(0), f(1), f(2), f(3), 4.5, 1.9, 0);
        // N8.2: both sides take cos / sin from DetMath: bit for bit.
        assert_eq!(p.s_dot.to_bits(), f(5).to_bits(), "s_dot {c}");
        assert_eq!(p.d_dot.to_bits(), f(6).to_bits(), "d_dot {c}");
    }
}

#[test]
fn loop_closures_match_gdscript() {
    let d = doc(include_str!("../vectors/loop_closures.json"));
    let map = LoopMap::from_json(include_str!("../../../data/maps/loop_v1.json")).unwrap();
    let params = TrafficParams::builtin().unwrap();
    let road = RoadSpace::from_loop(&map);
    assert_eq!(road.period(), hx(&d["length_m"]));
    let mut sim = TrafficSim::new(
        &params,
        SimConfig::single_player(&params),
        road,
        &Rng::new(1),
    );
    sim.add_road_closures();
    assert_eq!(
        sim.lane_closure_count() * 2,
        d["closures"].as_u64().unwrap() as usize
    );
    let zones = d["drop_zones"].as_array().unwrap();
    assert_eq!(sim.lane_drop_zone_count(), zones.len());
    for (z, pair) in zones.iter().enumerate() {
        assert!(same(sim.lane_drop_zone_s0(z), hx(&pair[0]), "drop zone s0"));
        assert!(
            (sim.lane_drop_zone_s1(z) - hx(&pair[1])).abs() <= TOL * 1e4,
            "drop zone s1"
        );
    }
    // On the ring every distance is the wrapped signed difference, so a closure more than
    // L/2 ahead reads as behind; only distances well inside that horizon are compared
    // (the sim looks at most lane_drop_merge_zone_m + lane_drop_view_m ahead).
    let horizon = sim.road.period() * 0.5 - 1000.0;
    let lanes = (d["samples"][0].as_array().unwrap().len() - 1) / 2;
    let mut compared = 0;
    for row in d["samples"].as_array().unwrap() {
        let s = hx(&row[0]);
        for lane in 0..lanes {
            let want_ahead = hx(&row[1 + 2 * lane]);
            let want_frac = hx(&row[2 + 2 * lane]);
            let got_ahead = sim.closure_ahead(lane as i32, s);
            let got_frac = sim.merge_zone_frac(lane as i32, s);
            // Wrapped vs unwrapped arithmetic: equal within 1e-8 m.
            if want_ahead < horizon {
                compared += 1;
                assert!(
                    got_ahead == want_ahead || (got_ahead - want_ahead).abs() <= 1e-8,
                    "closure_ahead(lane {lane}, s {s}): {got_ahead} vs {want_ahead}"
                );
            } else {
                assert!(
                    got_ahead >= horizon,
                    "closure_ahead(lane {lane}, s {s}): {got_ahead}"
                );
            }
            if want_frac
                * params
                    .tuning
                    .merge_zone_m
                    .max(params.tuning.lane_drop_merge_zone_m)
                < horizon
            {
                assert!(
                    got_frac == want_frac || (got_frac - want_frac).abs() <= 1e-11,
                    "merge_zone_frac(lane {lane}, s {s}): {got_frac} vs {want_frac}"
                );
            } else {
                assert!(
                    got_frac >= 1.0,
                    "merge_zone_frac(lane {lane}, s {s}): {got_frac}"
                );
            }
        }
    }
    assert!(compared > 500, "too few samples compared: {compared}");
}

// ---------------------------------------------------------------- Tick-level traces

struct Player {
    s: f64,
    d: f64,
    v: f64,
    v_lat: f64,
    lc_from: f64,
    lc_to: f64,
    lc_t0: i64,
    lc_dur: f64,
}

fn event_kind_name(k: EventKind) -> Option<&'static str> {
    match k {
        EventKind::Horn => Some("horn"),
        EventKind::BrakeTap => Some("brake_tap"),
        EventKind::Hazards => Some("hazards"),
        _ => None,
    }
}

fn tag_name(t: EventTag) -> &'static str {
    match t {
        EventTag::BlindSpot => "blind_spot",
        EventTag::ClosePass => "close_pass",
        EventTag::Honk => "honk",
        EventTag::CutIn => "cut_in",
        EventTag::Hit => "hit",
        _ => "",
    }
}

/// Replays one GDScript trace; returns the number of ticks that matched before the first
/// divergence (all of them when it holds), and a description of the divergence.
fn replay(text: &str) -> (usize, usize, Option<String>) {
    let d = doc(text);
    let params = TrafficParams::builtin().unwrap();
    let lanes = d["lanes"].as_i64().unwrap() as i32;
    let dt = hx(&d["dt"]);
    let ticks = d["ticks"].as_u64().unwrap() as usize;
    let mut cfg = SimConfig::single_player(&params);
    cfg.signal_time_floor_s = hx(&d["signal_time_floor_s"]);
    cfg.near_radius_m = hx(&d["near_radius_m"]);
    cfg.tick_dt = dt;
    let road = RoadSpace::straight(
        lanes,
        hx(&d["left_edge_d"]),
        hx(&d["lane_width"]),
        &params.tuning.lane_flow_speeds_from_right_mps,
    );
    let seed = d["seed"].as_i64().unwrap();
    let mut sim = TrafficSim::new(
        &params,
        cfg,
        road.clone(),
        &Rng::new(seed).derive("traffic"),
    );
    let pl = &d["player"];
    let (plen, pw) = (hx(&pl["length"]), hx(&pl["width"]));
    let s0 = hx(&pl["s"]);
    let mut p = Player {
        s: s0,
        d: road.lane_center_d(pl["lane"].as_i64().unwrap() as i32, s0),
        v: hx(&pl["v"]),
        v_lat: 0.0,
        lc_from: 0.0,
        lc_to: 0.0,
        lc_t0: -1,
        lc_dur: 0.0,
    };
    let input = |p: &Player, k: u32| {
        PlayerInput::from_vehicle(p.s, p.d, p.v, p.v_lat, 0.0, 0.0, plen, pw, k)
    };
    sim.set_player(0, input(&p, 0));
    let ops = d["ops"].as_array().unwrap();
    let mut oi = 0;
    let apply = |sim: &mut TrafficSim, op: &Value| {
        let o = op.as_array().unwrap();
        match o[1].as_str().unwrap() {
            "headway_scale" => sim.set_headway_scale(hx(&o[2])),
            "closure" => {
                sim.add_lane_closure(
                    o[2].as_i64().unwrap() as i32,
                    hx(&o[3]),
                    hx(&o[4]),
                    o[5].as_i64().unwrap() as i32,
                    hx(&o[6]),
                    hx(&o[7]),
                );
            }
            "drop_zone" => {
                sim.add_lane_drop_zone(o[2].as_i64().unwrap() as i32, hx(&o[3]), hx(&o[4]));
            }
            "spawn" => {
                let rec = SpawnRecord {
                    s: hx(&o[2]),
                    lane: o[3].as_i64().unwrap() as i32,
                    d: hx(&o[4]),
                    v: hx(&o[5]),
                    v0: hx(&o[6]),
                    type_id: o[7].as_i64().unwrap() as i32,
                    profile_id: o[8].as_i64().unwrap() as i32,
                    model_variant: o[9].as_i64().unwrap() as i32,
                    color_index: o[10].as_i64().unwrap() as i32,
                    flags: o[11].as_i64().unwrap() as i32,
                };
                assert!(sim.spawn(&rec).is_some(), "spawn failed");
            }
            "despawn" => sim.despawn(o[2].as_u64().unwrap() as usize),
            "hit" => sim.notify_hit(o[2].as_u64().unwrap() as usize, 0),
            "close_pass" => {
                sim.notify_close_pass(o[2].as_u64().unwrap() as usize);
            }
            other => panic!("unknown op {other}"),
        }
    };
    while oi < ops.len() && ops[oi][0].as_u64().unwrap() == 0 {
        apply(&mut sim, &ops[oi]);
        oi += 1;
    }
    let script = pl["script"].as_array().unwrap();
    let mut si = 0;
    let hashes = d["hashes"].as_array().unwrap();
    let events = d["events"].as_array().unwrap();
    let mut ei = 0;
    for k in 1..=ticks {
        while si < script.len() && script[si][0].as_u64().unwrap() as usize == k {
            let e = script[si].as_array().unwrap();
            if e[1] == "lane" {
                p.lc_from = p.d;
                p.lc_to = road.lane_center_d(e[2].as_i64().unwrap() as i32, p.s);
                p.lc_t0 = k as i64;
                p.lc_dur = hx(&e[3]);
            } else {
                p.v = hx(&e[2]);
            }
            si += 1;
        }
        p.s += p.v * dt;
        if p.lc_t0 >= 0 {
            let u = (k as i64 - p.lc_t0) as f64 * dt / p.lc_dur;
            if u >= 1.0 {
                p.d = p.lc_to;
                p.v_lat = 0.0;
                p.lc_t0 = -1;
            } else {
                let span = p.lc_to - p.lc_from;
                p.d = p.lc_from + span * u * u * (3.0 - 2.0 * u);
                p.v_lat = span * 6.0 * u * (1.0 - u) / p.lc_dur;
            }
        }
        sim.set_player(0, input(&p, k as u32));
        sim.events.clear();
        sim.step(dt, k as u32);
        for e in sim.events.as_slice() {
            let Some(kind) = event_kind_name(e.kind) else {
                continue;
            };
            let want = events.get(ei).map(|w| w.as_array().unwrap());
            let ok = want.is_some_and(|w| {
                w[0].as_u64().unwrap() as usize == k
                    && w[1] == kind
                    && w[2].as_u64().unwrap() == u64::from(e.slot)
                    && hx(&w[3]).to_bits() == e.value.to_bits()
                    && w[4] == tag_name(e.tag)
            });
            if !ok {
                return (
                    k - 1,
                    ticks,
                    Some(format!(
                        "tick {k}: event {kind} slot {} vs {want:?}",
                        e.slot
                    )),
                );
            }
            ei += 1;
        }
        if events
            .get(ei)
            .is_some_and(|w| w[0].as_u64().unwrap() as usize == k)
        {
            return (
                k - 1,
                ticks,
                Some(format!("tick {k}: missing event {:?}", events[ei])),
            );
        }
        while oi < ops.len() && ops[oi][0].as_u64().unwrap() as usize == k {
            apply(&mut sim, &ops[oi]);
            oi += 1;
        }
        let want: u64 = hashes[k - 1].as_str().unwrap().parse().unwrap();
        if sim.state.trace_hash() != want {
            return (k - 1, ticks, Some(format!("tick {k}: state hash differs")));
        }
    }
    // WP9.6: the long-merge guard held as often as in the GDScript sim.
    if let Some(want) = d["stats"]["long_merge_holds"].as_u64() {
        if sim.stat_long_merge_holds != want {
            return (
                ticks,
                ticks,
                Some(format!(
                    "long_merge_holds {} vs {want}",
                    sim.stat_long_merge_holds
                )),
            );
        }
    }
    (ticks, ticks, None)
}

fn check_trace(name: &str, text: &str) {
    let (held, ticks, why) = replay(text);
    println!(
        "tick-level parity {name}: {held}/{ticks} ticks identical{}",
        why.as_deref()
            .map(|w| format!(" (first divergence: {w})"))
            .unwrap_or_default()
    );
    assert!(
        why.is_none(),
        "{name}: diverged after {held} ticks: {}",
        why.unwrap_or_default()
    );
}

#[test]
fn trace_sp_weave_120hz() {
    check_trace(
        "sp_weave_120hz",
        include_str!("../vectors/trace_sp_weave_120hz.json"),
    );
}

#[test]
fn trace_sp_closure_120hz() {
    check_trace(
        "sp_closure_120hz",
        include_str!("../vectors/trace_sp_closure_120hz.json"),
    );
}

/// WP9.6: a semi crawling out of a closing lane while a car comes up in the lane beyond
/// its target (`long_crawl_held`; the vector's stats count the holds).
#[test]
fn trace_sp_long_merge_120hz() {
    let text = include_str!("../vectors/trace_sp_long_merge_120hz.json");
    assert!(
        doc(text)["stats"]["long_merge_holds"].as_u64().unwrap() > 0,
        "the scenario exercises the guard"
    );
    check_trace("sp_long_merge_120hz", text);
}

#[test]
fn trace_mp_weave_20hz() {
    check_trace(
        "mp_weave_20hz",
        include_str!("../vectors/trace_mp_weave_20hz.json"),
    );
}

#[test]
fn trace_mp_lane_drop_20hz() {
    check_trace(
        "mp_lane_drop_20hz",
        include_str!("../vectors/trace_mp_lane_drop_20hz.json"),
    );
}
