//! Scoring parity with the GDScript rule set (N6.1; multiplayer handoff → Testing:
//! "Scoring: every event, anti-exploit rule, banking and loss case"; the port must match
//! `src/scoring/`). Vectors: `crates/sim/vectors/scoring_*.json`, written by
//! `tools/server_data/export_sim_data.gd --only=scoring` (re-run it after any change to
//! src/scoring/ or the scoring tuning).
//!
//! - `scoring_hull.json`: `RoadHull.clearance` on 2,000 box pairs (libm trig on both sides).
//! - `scoring_<scenario>.json`: the whole rule set replayed tick by tick: the same cars on
//!   scripted lines, the same scripted player (speed changes and dips below the minimum,
//!   lane changes with yaw, shoulder visits, boost), the same run hooks (hits and the
//!   ghost, checkpoints, bonuses, night, run end); after every tick the events (kind,
//!   tag, points, multiplier, clearance, slot, value), `take_boost_fill()` and
//!   `Scoring.trace_hash()` must be the GDScript's, bit for bit.

use serde_json::Value;
use sim::scoring::hull;
use sim::scoring::{
    Kind, LaneRoad, PlayerTick, ScoreEventBuffer, Scoring, ScoringCars, ScoringParams, Tag,
};

fn hx(v: &Value) -> f64 {
    let s = v.as_str().expect("hex float");
    f64::from_bits(u64::from_str_radix(s, 16).expect("hex bits"))
}

fn doc(text: &str) -> Value {
    serde_json::from_str(text).expect("vector json")
}

#[test]
fn hull_clearance_matches_road_hull() {
    let d = doc(include_str!("../vectors/scoring_hull.json"));
    let mut exact = 0;
    let mut zero = 0;
    let cases = d["cases"].as_array().unwrap();
    for c in cases {
        let a: Vec<f64> = (0..11).map(|k| hx(&c[k])).collect();
        let got = hull::clearance(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]);
        let want = a[10];
        assert!(
            (got - want).abs() <= 1e-12 * want.abs().max(1.0),
            "clearance {got:e} vs {want:e} for {c}"
        );
        exact += usize::from(got.to_bits() == want.to_bits());
        zero += usize::from(want == 0.0);
    }
    assert!(
        zero > 100 && zero < cases.len() - 100,
        "overlaps and gaps both covered"
    );
    println!("hull: {exact} / {} bit-exact", cases.len());
}

/// A structure of arrays like `TrafficState`, as the trace's rig fills it.
struct Cars {
    active: Vec<bool>,
    vid: Vec<i32>,
    s: Vec<f64>,
    d: Vec<f64>,
    v: Vec<f64>,
    v_lat: Vec<f64>,
    length: Vec<f64>,
    width: Vec<f64>,
    lane: Vec<i32>,
    target: Vec<f64>,
    lat: Vec<f64>,
}

impl Cars {
    fn new(n: usize) -> Self {
        Self {
            active: vec![false; n],
            vid: vec![0; n],
            s: vec![0.0; n],
            d: vec![0.0; n],
            v: vec![0.0; n],
            v_lat: vec![0.0; n],
            length: vec![0.0; n],
            width: vec![0.0; n],
            lane: vec![0; n],
            target: vec![f64::NAN; n],
            lat: vec![0.0; n],
        }
    }
}

impl ScoringCars for Cars {
    fn capacity(&self) -> usize {
        self.active.len()
    }
    fn active(&self, i: usize) -> bool {
        self.active[i]
    }
    fn vehicle_id(&self, i: usize) -> i32 {
        self.vid[i]
    }
    fn s(&self, i: usize) -> f64 {
        self.s[i]
    }
    fn d(&self, i: usize) -> f64 {
        self.d[i]
    }
    fn v(&self, i: usize) -> f64 {
        self.v[i]
    }
    fn v_lat(&self, i: usize) -> f64 {
        self.v_lat[i]
    }
    fn length(&self, i: usize) -> f64 {
        self.length[i]
    }
    fn width(&self, i: usize) -> f64 {
        self.width[i]
    }
    fn lane(&self, i: usize) -> i32 {
        self.lane[i]
    }
}

/// GDScript's `signf`.
fn signf(x: f64) -> f64 {
    if x > 0.0 {
        1.0
    } else if x < 0.0 {
        -1.0
    } else {
        0.0
    }
}

const PRE_OPS: [&str; 6] = ["pv", "steer", "boost", "despawn", "csteer", "spawn"];

/// Replays one scenario; returns (ticks, events) compared.
fn replay(text: &str) -> (usize, usize) {
    let d = doc(text);
    let name = d["name"].as_str().unwrap().to_owned();
    let dt = hx(&d["dt"]);
    let ticks = d["ticks"].as_u64().unwrap() as usize;
    let cap = d["capacity"].as_u64().unwrap() as usize;
    let r = &d["road"];
    let road = LaneRoad {
        lanes: r["lanes"].as_i64().unwrap() as i32,
        lane_width: hx(&r["lane_width"]),
        median_half_width: hx(&r["median_half_width"]),
        inner_shoulder: hx(&r["inner_shoulder"]),
        shoulder: hx(&r["shoulder"]),
        guardrail_offset: hx(&r["guardrail_offset"]),
    };
    let params = ScoringParams::builtin().expect("scoring params");
    assert_eq!(
        params.body.max_active_vehicles, cap,
        "{name}: slot capacity"
    );
    assert_eq!(hx(&d["body"]["length"]), params.body.player_length_m);
    assert_eq!(hx(&d["body"]["width"]), params.body.player_width_m);
    let mut rules = Scoring::new(&params);
    let mut buf = ScoreEventBuffer::new(256);
    let mut cars = Cars::new(cap);
    let mut p = PlayerTick {
        s: hx(&d["player"]["s"]),
        d: hx(&d["player"]["d"]),
        v: hx(&d["player"]["v"]),
        yaw: 0.0,
        boost_active: false,
    };
    let mut p_target = f64::NAN;
    let mut p_lat = 0.0;
    let ops = d["ops"].as_array().unwrap();
    let events = d["events"].as_array().unwrap();
    let boosts = d["boost_fill"].as_array().unwrap();
    let hashes = d["hashes"].as_array().unwrap();
    assert_eq!(hashes.len(), ticks);
    let (mut oi, mut ei, mut bi) = (0usize, 0usize, 0usize);
    let tick_of = |v: &Value| v[0].as_u64().unwrap() as usize;
    for k in 1..=ticks {
        // 1. Ops before the motion, in recorded order.
        let mut post: Vec<&Value> = Vec::new();
        while oi < ops.len() && tick_of(&ops[oi]) == k {
            let op = &ops[oi];
            oi += 1;
            let kind = op[1].as_str().unwrap();
            if !PRE_OPS.contains(&kind) {
                post.push(op);
                continue;
            }
            match kind {
                "pv" => p.v = hx(&op[2]),
                "steer" => {
                    p_target = hx(&op[2]);
                    p_lat = hx(&op[3]);
                    p.yaw = hx(&op[4]);
                }
                "boost" => p.boost_active = op[2].as_bool().unwrap(),
                "despawn" => {
                    let i = op[2].as_u64().unwrap() as usize;
                    cars.active[i] = false;
                    cars.target[i] = f64::NAN;
                }
                "csteer" => {
                    let i = op[2].as_u64().unwrap() as usize;
                    cars.target[i] = hx(&op[3]);
                    cars.lat[i] = hx(&op[4]);
                    cars.lane[i] = op[5].as_i64().unwrap() as i32;
                }
                "spawn" => {
                    let i = op[2].as_u64().unwrap() as usize;
                    cars.active[i] = true;
                    cars.vid[i] = op[3].as_i64().unwrap() as i32;
                    cars.s[i] = hx(&op[4]);
                    cars.d[i] = hx(&op[5]);
                    cars.v[i] = hx(&op[6]);
                    cars.length[i] = hx(&op[7]);
                    cars.width[i] = hx(&op[8]);
                    cars.lane[i] = op[9].as_i64().unwrap() as i32;
                    cars.v_lat[i] = 0.0;
                }
                _ => unreachable!(),
            }
        }
        // 2. Motion: the rig's arithmetic.
        p.s += p.v * dt;
        if !p_target.is_nan() {
            let step = p_lat * dt;
            if (p_target - p.d).abs() <= step {
                p.d = p_target;
                p_target = f64::NAN;
            } else {
                p.d += signf(p_target - p.d) * step;
            }
        }
        for i in 0..cap {
            if !cars.active[i] {
                continue;
            }
            cars.s[i] += cars.v[i] * dt;
            if !cars.target[i].is_nan() {
                let cstep = cars.lat[i] * dt;
                if (cars.target[i] - cars.d[i]).abs() <= cstep {
                    cars.d[i] = cars.target[i];
                    cars.v_lat[i] = 0.0;
                    cars.target[i] = f64::NAN;
                } else {
                    cars.v_lat[i] = signf(cars.target[i] - cars.d[i]) * cars.lat[i];
                    cars.d[i] += signf(cars.target[i] - cars.d[i]) * cstep;
                }
            }
        }
        // 3. The rules.
        rules.step(dt, &p, &cars, &road, &mut buf);
        // 4. Hooks after the step.
        for op in post {
            match op[1].as_str().unwrap() {
                "hit" => {
                    rules.notify_hit(&mut buf);
                    rules.set_ghost(true);
                }
                "ghost_off" => rules.set_ghost(false),
                "checkpoint" => rules.notify_checkpoint(&mut buf),
                "bonus" => {
                    let tag = Tag::from_name(op[2].as_str().unwrap()).expect("bonus kind");
                    rules.award_bonus(tag, op[3].as_i64().unwrap(), &mut buf);
                }
                "night" => rules.set_night(op[2].as_bool().unwrap()),
                "run_end" => rules.notify_run_end(&mut buf),
                other => panic!("{name}: unknown op {other}"),
            }
        }
        // 5. Outputs.
        for got in buf.as_slice() {
            assert!(ei < events.len(), "{name} tick {k}: extra event {got:?}");
            let e = &events[ei];
            ei += 1;
            let at = format!("{name} tick {k} event {e}");
            assert_eq!(tick_of(e), k, "{at}: rust {got:?}");
            assert_eq!(
                Some(got.kind),
                Kind::from_name(e[1].as_str().unwrap()),
                "{at}"
            );
            assert_eq!(
                Some(got.tag),
                Tag::from_name(e[2].as_str().unwrap()),
                "{at}"
            );
            assert_eq!(got.points, e[3].as_i64().unwrap(), "{at}");
            assert_eq!(got.multiplier.to_bits(), hx(&e[4]).to_bits(), "{at}");
            let (gc, wc) = (got.clearance_m, hx(&e[5]));
            assert!(
                gc.to_bits() == wc.to_bits() || (gc - wc).abs() <= 1e-12,
                "{at}: clearance {gc:e}"
            );
            assert_eq!(i64::from(got.slot), e[6].as_i64().unwrap(), "{at}");
            assert_eq!(got.value.to_bits(), hx(&e[7]).to_bits(), "{at}");
        }
        buf.clear();
        let fill = rules.take_boost_fill();
        let want_fill = if bi < boosts.len() && tick_of(&boosts[bi]) == k {
            bi += 1;
            hx(&boosts[bi - 1][1])
        } else {
            0.0
        };
        assert_eq!(
            fill.to_bits(),
            want_fill.to_bits(),
            "{name} tick {k}: boost fill"
        );
        let want: u64 = hashes[k - 1].as_str().unwrap().parse().unwrap();
        assert_eq!(
            rules.trace_hash(),
            want,
            "{name} tick {k}: trace hash (multiplier {}, chain {}, banked {})",
            rules.multiplier(),
            rules.chain(),
            rules.banked()
        );
    }
    assert_eq!(ei, events.len(), "{name}: missing events");
    assert_eq!(
        rules.banked(),
        d["counts"]["banked"].as_i64().unwrap(),
        "{name}: final score"
    );
    assert_eq!(buf.dropped, 0);
    (ticks, ei)
}

#[test]
fn weave_120hz_is_tick_identical() {
    let (t, e) = replay(include_str!("../vectors/scoring_weave_120hz.json"));
    println!("scoring weave_120hz: {t} ticks, {e} events identical");
}

#[test]
fn weave_20hz_is_tick_identical() {
    let (t, e) = replay(include_str!("../vectors/scoring_weave_20hz.json"));
    println!("scoring weave_20hz: {t} ticks, {e} events identical");
}

#[test]
fn edges_120hz_is_tick_identical() {
    let (t, e) = replay(include_str!("../vectors/scoring_edges_120hz.json"));
    println!("scoring edges_120hz: {t} ticks, {e} events identical");
}

/// Every event kind and loss reason of the rule set occurs somewhere in the traces.
#[test]
fn the_traces_cover_every_rule() {
    let mut kinds = std::collections::HashSet::new();
    let mut tags = std::collections::HashSet::new();
    for text in [
        include_str!("../vectors/scoring_weave_120hz.json"),
        include_str!("../vectors/scoring_weave_20hz.json"),
        include_str!("../vectors/scoring_edges_120hz.json"),
    ] {
        for e in doc(text)["events"].as_array().unwrap() {
            kinds.insert(e[1].as_str().unwrap().to_owned());
            tags.insert(e[2].as_str().unwrap().to_owned());
        }
    }
    for k in Kind::ALL {
        if k != Kind::Train {
            assert!(kinds.contains(k.name()), "no {} in the traces", k.name());
        }
    }
    for t in [
        "checkpoint",
        "cash_out",
        "hit",
        "hesitated",
        "run_end",
        "clean",
        "pace",
    ] {
        assert!(tags.contains(t), "no tag {t} in the traces");
    }
}
