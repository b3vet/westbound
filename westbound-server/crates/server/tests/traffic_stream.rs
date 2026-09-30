//! Traffic streaming (N4.2) without sockets: a `SimTraffic` ring with 8 scripted players,
//! every client frame decoded into a `bots::TrafficMirror` each tick. Pins the area of
//! interest (−300/+900 m with hysteresis), the mirror matching the server's set for each
//! client at every tick, the correction schedule (5 Hz within 100 m, 1 Hz otherwise), the
//! same-frame corrections for spawns and intents, intents' 1.0 s lead, lanes on the wire,
//! hit reactions (hazard + hard brake, corrections through the swerve, folded into a
//! spawn), car ids (never reused within the hold), determinism, and the traffic bytes.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Traffic → What the server sends; docs/SERVER.md
//! → "Traffic streaming (N4.2)".

use std::collections::HashMap;
use std::sync::Arc;

use bots::{MirrorRules, TrafficMirror};
use protocol::{
    decode_server_frame, Density, FrameBuilder, IntentKind, LaneChangePhase, RunState, ServerMsg,
};
use sim::map::LoopMap;
use sim::traffic::state::{LC_NONE, LC_SIGNALING};
use westbound_server::rooms::road::lane_center_d_mm;
use westbound_server::rooms::sim_traffic::{GapRules, SimTraffic, SimTrafficData};
use westbound_server::rooms::traffic::{PlayerView, RoomTraffic};
use westbound_server::rooms::traffic_stream::{correction_due, wire_lane, StreamRules};
use westbound_server::rooms::RoomParams;
use westbound_server::Config;

const DT: f64 = 0.05;
const ORIGIN: u32 = 5_000;

fn map() -> Arc<LoopMap> {
    Arc::new(
        westbound_server::map::builtin()
            .expect("loop_v1")
            .map
            .clone(),
    )
}

fn params() -> RoomParams {
    RoomParams::from_config(&Config::default())
}

fn rules() -> StreamRules {
    params().stream
}

fn gap() -> GapRules {
    params().gap
}

struct Driver {
    id: u16,
    s_m: f64,
    v: f64,
    lane: u8,
}

struct Harness {
    map: Arc<LoopMap>,
    t: SimTraffic,
    now: u32,
    drivers: Vec<Driver>,
    mirrors: HashMap<u16, TrafficMirror>,
    fb: FrameBuilder,
    /// Players whose next frame is their first (a join or a reconnect).
    joined: Vec<u16>,
    /// Every frame's bytes, hashed (determinism).
    hash: u64,
    frames: u64,
}

impl Harness {
    fn new(density: Density, seed: i64, drivers: Vec<Driver>) -> Self {
        Self::with_rules(density, seed, drivers, rules())
    }

    fn with_rules(density: Density, seed: i64, drivers: Vec<Driver>, r: StreamRules) -> Self {
        let map = map();
        let data = SimTrafficData::builtin().expect("sim data");
        let t = SimTraffic::new(&data, &map, density, seed, ORIGIN, gap(), r);
        let joined = drivers.iter().map(|d| d.id).collect();
        Self {
            map,
            t,
            now: ORIGIN,
            drivers,
            mirrors: HashMap::new(),
            fb: FrameBuilder::new(),
            joined,
            hash: 0xcbf2_9ce4_8422_2325,
            frames: 0,
        }
    }

    fn s_mm(&self, d: &Driver) -> u32 {
        self.map.wrap_mm((d.s_m * 1_000.0).round() as i64)
    }

    fn views(&self) -> Vec<PlayerView> {
        self.drivers
            .iter()
            .map(|d| {
                let s_mm = self.s_mm(d);
                PlayerView {
                    player_id: d.id,
                    tick: self.now,
                    s_mm,
                    d_cm: (lane_center_d_mm(&self.map, d.lane, s_mm) / 10) as i16,
                    speed_cms: (d.v * 100.0).round() as u16,
                    heading_e4: 0,
                    lat_vel_cms: 0,
                    run_state: RunState::Driving,
                    protected_until: 0,
                }
            })
            .collect()
    }

    /// One room tick: drivers move, the ring steps, every client's frame is decoded into
    /// its mirror. Returns each client's messages of the tick.
    fn step(&mut self) -> HashMap<u16, Vec<ServerMsg>> {
        self.now += 1;
        for d in &mut self.drivers {
            d.s_m = self.map.wrap_m(d.s_m + d.v * DT);
        }
        let views = self.views();
        self.t.tick(self.now, &views);
        let mut out = HashMap::new();
        for k in 0..self.drivers.len() {
            let (id, s_mm) = (self.drivers[k].id, self.s_mm(&self.drivers[k]));
            let joined = self.joined.contains(&id);
            self.fb.clear();
            self.t.write_client(id, s_mm, joined, &mut self.fb);
            let mirror = self
                .mirrors
                .entry(id)
                .or_insert_with(|| TrafficMirror::new(MirrorRules::default()));
            if joined {
                mirror.reset();
            }
            let mut msgs = Vec::new();
            if !self.fb.is_empty() {
                self.frames += 1;
                for b in self.fb.as_bytes() {
                    self.hash = (self.hash ^ u64::from(*b)).wrapping_mul(0x100_0000_01b3);
                }
                mirror.begin_frame();
                for m in decode_server_frame(self.fb.as_bytes()).expect("a valid frame") {
                    assert!(mirror.on_msg(&m, s_mm, &self.map), "only traffic: {m:?}");
                    msgs.push(m);
                }
                mirror.end_frame();
            }
            out.insert(id, msgs);
        }
        self.joined.clear();
        out
    }

    /// The server's set for each client equals the mirror, and the area rules hold.
    fn check(&self) {
        let st = &self.t.world().sim.state;
        let stream = self.t.stream();
        let r = rules();
        for d in &self.drivers {
            let center = self.s_mm(d);
            let mirror = &self.mirrors[&d.id];
            assert!(
                mirror.violations.is_empty(),
                "player {}: {:#?}",
                d.id,
                mirror.violations
            );
            let mut known: Vec<u16> = stream.known(d.id).collect();
            known.sort_unstable();
            assert_eq!(mirror.ids(), known, "player {} at tick {}", d.id, self.now);
            for i in 0..st.capacity {
                if st.active[i] == 1 && stream.in_aoi(center, i) {
                    assert!(
                        known.binary_search(&stream.car_id(i)).is_ok(),
                        "car {} in the area of player {} not sent",
                        stream.car_id(i),
                        d.id
                    );
                }
            }
            for (&id, car) in &mirror.cars {
                let slot = stream.slot_of(id).expect("a known car is live");
                assert!(
                    stream.in_outer(center, slot),
                    "car {id} outside the area kept"
                );
                // The schedule: due when (tick + car_id) % period == 0, 4 ticks near the
                // player, 20 otherwise; so never more than 20 ticks without one.
                let age = self.now - car.corrected_tick;
                assert!(age < r.far_period_ticks, "car {id} corrected {age} ago");
                let period = if stream.is_near(center, slot) {
                    r.near_period_ticks
                } else {
                    r.far_period_ticks
                };
                if correction_due(self.now, id, period) {
                    assert_eq!(age, 0, "car {id} due at tick {}", self.now);
                }
                if age == 0 {
                    assert_eq!(car.s_mm, stream.s_mm(slot), "car {id} corrected to its s");
                }
            }
        }
        assert_eq!(stream.stats.deferred, 0);
        assert_eq!(stream.stats.intents_dropped, 0);
    }
}

fn eight_drivers() -> Vec<Driver> {
    // Fast and slow, both directions of traffic flow relative to them, one across the seam.
    let speeds = [60.0, 45.0, 33.0, 25.0, 70.0, 40.0, 28.0, 52.0];
    let starts = [
        1_000.0, 3_200.0, 6_400.0, 9_000.0, 12_000.0, 16_500.0, 19_800.0, 24_700.0,
    ];
    (0..8)
        .map(|k| Driver {
            id: k as u16 + 1,
            s_m: starts[k],
            v: speeds[k],
            lane: (k % 2) as u8,
        })
        .collect()
}

#[test]
fn rush_hour_mirrors_match_the_area_of_interest_every_tick() {
    let mut h = Harness::new(Density::Rush, 11, eight_drivers());
    let ticks = 1_200; // 60 s
    let mut bytes: HashMap<u16, u64> = HashMap::new();
    for _ in 0..ticks {
        let msgs = h.step();
        for (id, m) in msgs {
            *bytes.entry(id).or_default() += m
                .iter()
                .map(|x| protocol::Message::encoded_len(x) as u64)
                .sum::<u64>();
        }
        h.check();
    }
    let mut spawns = 0;
    let mut lane_changes = 0;
    for (id, m) in &h.mirrors {
        let c = &m.counts;
        spawns += c.spawns;
        lane_changes += c.lane_changes;
        // The join burst, then the area's churn: well under the 10 KB/s budget with the
        // other players' states (≈ 3.5 KB/s) on top.
        let per_s = bytes[id] as f64 / (f64::from(ticks) * DT);
        println!(
            "player {id}: {} cars, traffic {per_s:.0} B/s, {} spawns, {} despawns, {} intents \
             ({} lane changes), {} corrections, lead >= {:?} ticks, gaps near {} / all {}",
            m.cars.len(),
            c.spawns,
            c.despawns,
            c.intents,
            c.lane_changes,
            c.corrections,
            m.min_lead_ticks,
            m.max_near_gap,
            m.max_gap,
        );
        assert!(per_s < 3_000.0, "player {id}: {per_s} B/s of traffic");
        assert!(m.max_gap <= 20 && m.max_near_gap <= 4);
        if let Some(l) = m.min_lead_ticks {
            assert!(l >= 20);
        }
    }
    assert!(spawns > 8 * 40, "every player saw its area fill and churn");
    assert!(lane_changes > 50, "intents flow ({lane_changes})");
    assert_eq!(h.t.stream().early_id_reuses(), 0);
}

#[test]
fn spawns_carry_lanes_and_lane_changes_from_the_right() {
    let mut h = Harness::new(Density::Normal, 5, eight_drivers());
    let mut checked_lc = 0;
    let mut ramp = 0;
    for _ in 0..600 {
        let msgs = h.step();
        let st = &h.t.world().sim.state;
        for m in msgs.values().flatten() {
            let ServerMsg::TrafficSpawn(sp) = m else {
                continue;
            };
            for e in &sp.cars {
                let slot = h.t.stream().slot_of(e.car_id).expect("live");
                let n = h.map.lane_count_at(e.s_mm);
                assert_eq!(e.lane, wire_lane(st.lane[slot], n), "car {}", e.car_id);
                ramp += usize::from(e.lane == 7);
                assert_eq!(e.vehicle, st.type_id[slot] as u8);
                assert_eq!(e.profile, st.profile_id[slot] as u8);
                if st.lc_state[slot] == LC_NONE {
                    assert_eq!(e.lc_phase, LaneChangePhase::None);
                    assert_eq!((e.lc_target_lane, e.lc_move_start_tick), (0, 0));
                } else {
                    checked_lc += 1;
                    let want = if st.lc_state[slot] == LC_SIGNALING {
                        LaneChangePhase::Signaling
                    } else {
                        LaneChangePhase::Moving
                    };
                    assert_eq!(e.lc_phase, want);
                    assert_eq!(e.lc_target_lane, wire_lane(st.target_lane[slot], n));
                    let sim = &h.t.world().sim;
                    assert_eq!(e.lc_move_start_tick, ORIGIN + sim.move_start_tick(slot));
                    assert!(e.lc_duration_ms > 0);
                }
            }
        }
        h.check();
    }
    assert!(checked_lc > 0, "some cars entered an area mid lane change");
    println!("{checked_lc} spawns mid lane change, {ramp} on a ramp");
}

#[test]
fn intents_reach_every_client_that_has_the_car() {
    let mut h = Harness::new(Density::Rush, 21, eight_drivers());
    let mut seen = 0;
    // Hesitant cancels sent ahead: (car, tick).
    let mut ahead: HashMap<(u16, u32), u16> = HashMap::new();
    let mut hesitant = 0;
    for _ in 0..800 {
        let msgs = h.step();
        for (id, list) in &msgs {
            let d = h.drivers.iter().find(|d| d.id == *id).unwrap();
            let center = h.s_mm(d);
            for m in list {
                let ServerMsg::TrafficIntent(it) = m else {
                    continue;
                };
                for (k, e) in it.intents.iter().enumerate() {
                    seen += 1;
                    let slot = h.t.stream().slot_of(e.car_id).unwrap();
                    assert!(h.t.stream().in_outer(center, slot));
                    match e.kind {
                        IntentKind::LaneChange => {
                            assert_eq!(e.start_tick, h.now, "sent at decision time");
                            assert!(e.move_start_tick >= e.start_tick + 20);
                            assert!(e.duration_ms > 0);
                        }
                        IntentKind::Cancel if e.start_tick > h.now => {
                            // A hesitant's cancel, dated at the signal's end; with its lane
                            // change when the client had the car (a spawn carries the
                            // signal otherwise).
                            if k > 0 && it.intents[k - 1].car_id == e.car_id {
                                let lc = &it.intents[k - 1];
                                assert_eq!(lc.kind, IntentKind::LaneChange);
                                assert_eq!(e.start_tick, lc.move_start_tick);
                            }
                            assert_eq!(e.move_start_tick, e.start_tick);
                            ahead.insert((e.car_id, e.start_tick), *id);
                            hesitant += 1;
                        }
                        IntentKind::Cancel => {
                            assert_eq!(e.start_tick, h.now);
                            assert!(
                                !ahead.contains_key(&(e.car_id, h.now)),
                                "car {} cancelled twice",
                                e.car_id
                            );
                        }
                        _ => assert_eq!(e.start_tick, h.now),
                    }
                }
            }
        }
        // At a hesitant cancel's tick the server's car stays in its lane.
        let st = &h.t.world().sim.state;
        for &(car, t) in ahead.keys() {
            if t == h.now {
                if let Some(slot) = h.t.stream().slot_of(car) {
                    assert_eq!(st.lc_state[slot], LC_NONE, "car {car} moved at {t}");
                }
            }
        }
        h.check();
    }
    assert!(seen > 20, "{seen} intents");
    assert!(hesitant > 0, "hesitant drivers' cancels are sent ahead");
    println!("{seen} intents, {hesitant} hesitant cancels sent ahead");
}

#[test]
fn hit_reactions_stream_hazard_hard_brake_and_swerve_corrections() {
    let mut drivers = eight_drivers();
    drivers.truncate(2);
    let mut h = Harness::new(Density::Normal, 3, drivers);
    for _ in 0..5 {
        h.step();
    }
    // The car nearest ahead of player 1.
    let center = h.s_mm(&h.drivers[0]);
    let st = &h.t.world().sim.state;
    let slot = (0..st.capacity)
        .filter(|&i| st.active[i] == 1)
        .min_by_key(|&i| {
            let d = h.map.signed_delta_mm(center, h.t.stream().s_mm(i));
            if d > 0 {
                d
            } else {
                i64::MAX
            }
        })
        .unwrap();
    let car = h.t.stream().car_id(slot);
    assert!(h.t.notify_hit(1, car));
    assert!(!h.t.notify_hit(1, 0));
    let msgs = h.step();
    let hit_tick = h.now;
    let intents: Vec<_> = msgs[&1]
        .iter()
        .filter_map(|m| match m {
            ServerMsg::TrafficIntent(i) => Some(i.intents.clone()),
            _ => None,
        })
        .flatten()
        .filter(|e| e.car_id == car)
        .collect();
    let hazard = intents.iter().find(|e| e.kind == IntentKind::Hazard);
    let brake = intents.iter().find(|e| e.kind == IntentKind::HardBrake);
    let (hazard, brake) = (hazard.expect("hazard"), brake.expect("hard brake"));
    assert_eq!((hazard.start_tick, brake.start_tick), (hit_tick, hit_tick));
    assert_eq!(hazard.duration_ms, 4_000, "hit_recover_s");
    assert_eq!(brake.duration_ms, 1_000, "hit_brake_s");
    assert_eq!(h.t.stream().stats.hits, 1);
    // Corrected every tick through the swerve (1.2 s).
    for _ in 0..24 {
        h.step();
        let m = &h.mirrors[&1];
        assert_eq!(
            m.cars[&car].corrected_tick, h.now,
            "swerving car corrected each tick"
        );
    }
    // A player joining now gets the car with its hazards and the time left.
    let s_m = h.drivers[0].s_m;
    h.drivers.push(Driver {
        id: 9,
        s_m,
        v: 30.0,
        lane: 2,
    });
    h.joined.push(9);
    let msgs = h.step();
    let spawn = msgs[&9]
        .iter()
        .find_map(|m| match m {
            ServerMsg::TrafficSpawn(s) => s.cars.iter().find(|e| e.car_id == car).cloned(),
            _ => None,
        })
        .expect("the hit car is spawned");
    assert!(spawn.flags.hazard);
    let late: Vec<_> = msgs[&9]
        .iter()
        .filter_map(|m| match m {
            ServerMsg::TrafficIntent(i) => Some(i.intents.clone()),
            _ => None,
        })
        .flatten()
        .filter(|e| e.car_id == car)
        .collect();
    let hz = late
        .iter()
        .find(|e| e.kind == IntentKind::Hazard)
        .expect("hazard");
    assert_eq!(*hz, *hazard, "the same hazard, from the hit's tick");
    assert!(
        late.iter().all(|e| e.kind != IntentKind::HardBrake),
        "the brake is over"
    );
    h.check();
}

#[test]
fn joining_again_resends_the_whole_area_and_leaving_forgets() {
    let mut drivers = eight_drivers();
    drivers.truncate(3);
    let mut h = Harness::new(Density::Normal, 8, drivers);
    for _ in 0..40 {
        h.step();
    }
    let before = h.mirrors[&2].cars.len();
    assert!(before > 20);
    // A reconnect: the room says `joined` again; the client starts from nothing.
    h.joined.push(2);
    let msgs = h.step();
    let spawned: usize = msgs[&2]
        .iter()
        .map(|m| match m {
            ServerMsg::TrafficSpawn(s) => s.cars.len(),
            ServerMsg::TrafficDespawn(_) => panic!("no despawns for a fresh client"),
            _ => 0,
        })
        .sum();
    assert_eq!(spawned, h.mirrors[&2].cars.len());
    h.check();
    // Leaving: the stream forgets the client.
    h.t.player_left(3);
    assert_eq!(h.t.stream().known(3).count(), 0);
    h.drivers.retain(|d| d.id != 3);
    h.mirrors.remove(&3);
    for _ in 0..5 {
        h.step();
        h.check();
    }
}

#[test]
fn streaming_is_deterministic() {
    let run = || {
        let mut h = Harness::new(Density::Rush, 99, eight_drivers());
        for _ in 0..200 {
            h.step();
        }
        (h.hash, h.frames)
    };
    assert_eq!(run(), run());
}

#[test]
fn car_ids_are_never_reused_within_the_hold() {
    // A short hold and the ring at its target, so the off-ramps take cars out and the
    // on-ramps bring new ones in: every reuse is at least the hold after the release, and
    // while a car lives its id stays its own.
    let mut r = rules();
    r.car_id_hold_ticks = 40;
    let mut drivers = eight_drivers();
    drivers.truncate(1);
    let mut h = Harness::with_rules(Density::Rush, 17, drivers, r);
    let cap = h.t.world().sim.state.capacity;
    let mut owner: HashMap<u16, i32> = HashMap::new();
    let mut released: HashMap<u16, u32> = HashMap::new();
    let mut reused = 0;
    for _ in 0..3_600 {
        h.step();
        let st = &h.t.world().sim.state;
        let mut live: HashMap<u16, i32> = HashMap::new();
        for i in 0..cap {
            if st.active[i] == 1 {
                let id = h.t.stream().car_id(i);
                assert_ne!(id, 0);
                assert!(live.insert(id, st.vehicle_id[i]).is_none(), "id {id} twice");
            }
        }
        for (id, vid) in &owner {
            if live.get(id) != Some(vid) {
                released.entry(*id).or_insert(h.now);
            }
        }
        for (id, vid) in &live {
            match owner.get(id) {
                Some(v) if v == vid => {}
                _ => {
                    if let Some(t) = released.remove(id) {
                        reused += 1;
                        assert!(h.now - t >= 40, "id {id} back after {} ticks", h.now - t);
                    }
                }
            }
        }
        owner = live;
        h.check();
    }
    println!("{reused} ids reused");
    assert!(reused > 0, "the churn reused ids");
}

/// The streaming's own cost per room tick (8 clients), next to the ring's step (wall time
/// on this thread). Run in release:
/// `cargo test --release -p server --test traffic_stream bench_ -- --ignored --nocapture`.
#[test]
#[ignore]
fn bench_streaming_cost_per_room_tick() {
    for density in [Density::Normal, Density::Rush] {
        let mut h = Harness::new(density, 13, eight_drivers());
        for _ in 0..40 {
            h.step();
        }
        let ticks = 1_200u32;
        let (mut sim_ns, mut stream_ns) = (Vec::new(), Vec::new());
        for _ in 0..ticks {
            h.now += 1;
            for d in &mut h.drivers {
                d.s_m = h.map.wrap_m(d.s_m + d.v * DT);
            }
            let views = h.views();
            let t0 = std::time::Instant::now();
            h.t.tick(h.now, &views);
            let t1 = std::time::Instant::now();
            for v in &views {
                h.fb.clear();
                h.t.write_client(v.player_id, v.s_mm, false, &mut h.fb);
            }
            let t2 = std::time::Instant::now();
            sim_ns.push((t1 - t0).as_nanos() as u64);
            stream_ns.push((t2 - t1).as_nanos() as u64);
        }
        let stat = |v: &mut Vec<u64>| {
            v.sort_unstable();
            let mean = v.iter().sum::<u64>() as f64 / v.len() as f64 / 1e3;
            (
                mean,
                v[v.len() / 2] as f64 / 1e3,
                v[v.len() * 99 / 100] as f64 / 1e3,
            )
        };
        let (sm, s50, s99) = stat(&mut sim_ns);
        let (wm, w50, w99) = stat(&mut stream_ns);
        println!(
            "STREAM_BENCH {density:?}: ring step (with the stream's bookkeeping) mean {sm:.0} us, \
             p50 {s50:.0}, p99 {s99:.0}; 8 clients' traffic writes mean {wm:.0} us, p50 {w50:.0}, \
             p99 {w99:.0}"
        );
    }
}
