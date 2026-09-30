//! Shared harness for the loop-room tests (soak, bench, determinism): a `TrafficWorld` on
//! loop_v1, the rule checker, and scripted bot players that drive like players (IDM behind
//! traffic, lane changes into gaps, never onto a closing lane) and report their state a few
//! ticks late, so the sim's extrapolation to the current tick is exercised.
#![allow(dead_code)]

use sim::map::LoopMap;
use sim::rng::Rng;
use sim::traffic::checker::{box_yaw, RuleChecker};
use sim::traffic::sim::PlayerInput;
use sim::traffic::{Density, MpTrafficRules, TrafficParams, TrafficWorld};

pub const PLAYER_LENGTH_M: f64 = 4.5;
pub const PLAYER_WIDTH_M: f64 = 1.9;
/// Bots report their state this many ticks late (150 ms at 20 Hz).
pub const REPORT_LAG_TICKS: u32 = 3;
const HISTORY: usize = 8;
/// A contact counts against traffic only when the bot kept its line and did not brake
/// beyond the clamp for this long before it (docs/TRAFFIC.md, rear-end prevention).
const QUIET_S: f64 = 3.0;
const BOT_A: f64 = 3.0;
const BOT_B: f64 = 4.0;
const BOT_T: f64 = 1.0;
const BOT_S0: f64 = 4.0;
const BOT_MAX_DECEL: f64 = 9.0;
const BOT_LC_S: f64 = 1.8;
const BOT_GAP_AHEAD_M: f64 = 30.0;
const BOT_GAP_BEHIND_M: f64 = 20.0;
const BOT_CLOSURE_LOOK_M: f64 = 700.0;

const SPAWN_GAP_AHEAD_M: f64 = 60.0;
const SPAWN_GAP_BEHIND_M: f64 = 100.0;

/// No vehicle in `lane` (or moving into it) from `behind` m behind s to `ahead` m ahead.
pub fn gap_is_clear(world: &TrafficWorld, s: f64, lane: i32, ahead: f64, behind: f64) -> bool {
    let st = &world.sim.state;
    for i in 0..st.capacity {
        if st.active[i] == 0 || (st.lane[i] != lane && st.target_lane[i] != lane) {
            continue;
        }
        let ds = world.sim.road.signed_delta(s, st.s[i]);
        if ds > -behind && ds < ahead {
            return false;
        }
    }
    true
}

pub fn map() -> LoopMap {
    LoopMap::from_json(include_str!("../../../../data/maps/loop_v1.json")).unwrap()
}

pub fn params() -> (TrafficParams, MpTrafficRules) {
    (
        TrafficParams::builtin().unwrap(),
        MpTrafficRules::builtin().unwrap(),
    )
}

#[derive(Clone)]
pub struct Bot {
    pub s: f64,
    pub d: f64,
    pub v: f64,
    pub v_lat: f64,
    pub v_des: f64,
    pub lane: i32,
    lc_from: f64,
    lc_to: f64,
    lc_t: f64,
    lc_on: bool,
    next_lc: f64,
    weave: bool,
    last_lateral_t: f64,
    last_hard_brake_t: f64,
    history: Vec<(u32, PlayerInput)>,
    touching: Vec<i32>,
    pub contacts: u64,
    pub rear_end_normal: u64,
}

pub struct Room {
    pub world: TrafficWorld,
    pub checker: RuleChecker,
    pub bots: Vec<Bot>,
    rng: Rng,
    pub time: f64,
    pub counts: Vec<usize>,
}

impl Room {
    pub fn new(density: Density, seed: i64, bots: usize, weave: bool) -> Room {
        let (params, mp) = params();
        let world = TrafficWorld::new(&params, &mp, &map(), density, seed);
        let checker = RuleChecker::new(&params, &world.sim, true);
        let mut rng = Rng::new(seed).derive("bots");
        let mut list = Vec::new();
        for b in 0..bots {
            // Spawn in a gap (as the room will: multiplayer handoff → Players, spawning).
            let mut s = world.sim.road.wrap(150.0 + b as f64 * 3_100.0);
            let mut lane = 0;
            for _ in 0..2_000 {
                let lanes = world.sim.road.lane_count(s);
                lane = rng.int_range(0, lanes - 1);
                if gap_is_clear(&world, s, lane, SPAWN_GAP_AHEAD_M, SPAWN_GAP_BEHIND_M) {
                    break;
                }
                s = world.sim.road.wrap(s + 10.0);
            }
            let lanes = world.sim.road.lane_count(s);
            let v_des = rng.float_range(110.0, 200.0) / 3.6;
            let d = world.sim.road.lane_center_d(lane, s);
            list.push(Bot {
                s,
                d,
                v: world.sim.road.lane_flow_speed_mps(lane, lanes, s),
                v_lat: 0.0,
                v_des,
                lane,
                lc_from: d,
                lc_to: d,
                lc_t: 0.0,
                lc_on: false,
                next_lc: rng.float_range(4.0, 10.0),
                weave,
                // Spawn protection (3 s) counts as not driving normally yet.
                last_lateral_t: 0.0,
                last_hard_brake_t: -100.0,
                history: Vec::with_capacity(HISTORY),
                touching: Vec::new(),
                contacts: 0,
                rear_end_normal: 0,
            });
        }
        Room {
            world,
            checker,
            bots: list,
            rng,
            time: 0.0,
            counts: Vec::new(),
        }
    }

    /// One tick: bots drive and report (late), the world ticks, the checker observes.
    pub fn tick(&mut self) {
        let dt = self.world.dt();
        let now = self.world.tick_index();
        for b in 0..self.bots.len() {
            self.drive_bot(b, dt);
            let bot = &mut self.bots[b];
            let input = PlayerInput {
                s: bot.s,
                d: bot.d,
                s_dot: bot.v,
                d_dot: bot.v_lat,
                length: PLAYER_LENGTH_M,
                width: PLAYER_WIDTH_M,
                tick: now + 1,
            };
            if bot.history.len() == HISTORY {
                bot.history.remove(0);
            }
            bot.history.push((now + 1, input));
            let lag = (REPORT_LAG_TICKS as usize).min(bot.history.len() - 1);
            let reported = bot.history[bot.history.len() - 1 - lag].1;
            self.world.set_player(b, reported);
        }
        let tick = self.world.tick();
        self.time += dt;
        self.debug_trace(tick);
        self.checker.observe(&self.world.sim, tick);
        for b in 0..self.bots.len() {
            self.check_contacts(b);
        }
    }

    pub fn run(&mut self, seconds: f64, sample_every_s: f64) {
        let dt = self.world.dt();
        let n = (seconds / dt).round() as u64;
        let every = (sample_every_s / dt).round().max(1.0) as u64;
        for k in 0..n {
            self.tick();
            if (k + 1) % every == 0 {
                self.counts.push(self.world.sim.state.count);
            }
        }
    }

    fn drive_bot(&mut self, b: usize, dt: f64) {
        let road = self.world.sim.road.clone();
        let st = &self.world.sim.state;
        let time = self.time;
        let lanes_here = road.lane_count(self.bots[b].s);
        // Leader: nearest traffic car ahead overlapping the bot's lateral span.
        let (s, d) = (self.bots[b].s, self.bots[b].d);
        let (lo, hi) = (
            d - PLAYER_WIDTH_M * 0.5 - 0.2,
            d + PLAYER_WIDTH_M * 0.5 + 0.2,
        );
        let mut gap = f64::INFINITY;
        let mut lead_v = 0.0;
        for i in 0..st.capacity {
            if st.active[i] == 0 {
                continue;
            }
            let ds = road.signed_delta(s, st.s[i]);
            if ds <= 0.0 || ds > 400.0 {
                continue;
            }
            let hw = st.width[i] * 0.5;
            if st.d[i] + hw < lo || st.d[i] - hw > hi {
                continue;
            }
            let g = ds - (st.length[i] + PLAYER_LENGTH_M) * 0.5;
            if g < gap {
                gap = g;
                lead_v = st.v[i];
            }
        }
        let bot = &mut self.bots[b];
        let free = 1.0 - (bot.v / bot.v_des).powi(4);
        let mut a = BOT_A * free;
        if gap.is_finite() {
            let ss = BOT_S0
                + (bot.v * BOT_T + bot.v * (bot.v - lead_v) / (2.0 * (BOT_A * BOT_B).sqrt()))
                    .max(0.0);
            let r = ss / gap.max(0.1);
            a = BOT_A * (free - r * r);
        }
        a = a.max(-BOT_MAX_DECEL);
        if a < -6.0 {
            bot.last_hard_brake_t = time;
        }
        bot.v = (bot.v + a * dt).max(0.0);
        bot.s = road.wrap(bot.s + bot.v * dt);
        // Lateral: a running lane change, or a new one (weaving, or out of a closing lane).
        if bot.lc_on {
            bot.lc_t += dt;
            let u = (bot.lc_t / BOT_LC_S).min(1.0);
            let span = bot.lc_to - bot.lc_from;
            bot.d = bot.lc_from + span * u * u * (3.0 - 2.0 * u);
            bot.v_lat = span * 6.0 * u * (1.0 - u) / BOT_LC_S;
            bot.last_lateral_t = time;
            if u >= 1.0 {
                bot.lc_on = false;
                bot.v_lat = 0.0;
            }
            return;
        }
        let ahead_lanes = road.lane_count(bot.s + BOT_CLOSURE_LOOK_M).min(lanes_here);
        let must = bot.lane >= ahead_lanes;
        let want = bot.weave && time >= bot.next_lc;
        if !(must || want) {
            return;
        }
        bot.next_lc = time + 6.0;
        let to = if must || bot.lane + 1 >= ahead_lanes {
            bot.lane - 1
        } else if bot.lane == 0 {
            1
        } else if (bot.s * 7.0) as i64 % 2 == 0 {
            bot.lane - 1
        } else {
            bot.lane + 1
        };
        if to < 0 || to >= ahead_lanes {
            return;
        }
        let td = road.lane_center_d(to, bot.s);
        let (tlo, thi) = (td - 1.8, td + 1.8);
        for i in 0..st.capacity {
            if st.active[i] == 0 {
                continue;
            }
            let ds = road.signed_delta(bot.s, st.s[i]);
            let hw = st.width[i] * 0.5;
            if st.d[i] + hw < tlo || st.d[i] - hw > thi {
                continue;
            }
            let reach = (st.length[i] + PLAYER_LENGTH_M) * 0.5;
            if ds > -(BOT_GAP_BEHIND_M + reach) && ds < BOT_GAP_AHEAD_M + reach {
                return;
            }
        }
        bot.lc_on = true;
        bot.lc_t = 0.0;
        bot.lc_from = bot.d;
        bot.lc_to = td;
        bot.lane = to;
    }

    fn check_contacts(&mut self, b: usize) {
        let sim = &self.world.sim;
        let st = &sim.state;
        let road = &sim.road;
        let time = self.time;
        let bot = &mut self.bots[b];
        let mut now_touching = Vec::new();
        for i in 0..st.capacity {
            if st.active[i] == 0 {
                continue;
            }
            let ds = road.signed_delta(bot.s, st.s[i]);
            if ds.abs() >= (st.length[i] + PLAYER_LENGTH_M) * 0.5 {
                continue;
            }
            if self.checker.overlap(
                0.0,
                bot.d,
                PLAYER_LENGTH_M,
                PLAYER_WIDTH_M,
                box_yaw(bot.v_lat, bot.v),
                ds,
                st.d[i],
                st.length[i],
                st.width[i],
                box_yaw(st.v_lat[i], st.v[i]),
            ) {
                let vid = st.vehicle_id[i];
                now_touching.push(vid);
                if !bot.touching.contains(&vid) {
                    bot.contacts += 1;
                    let rear = ds < 0.0;
                    if rear
                        && time - bot.last_lateral_t >= QUIET_S
                        && time - bot.last_hard_brake_t >= QUIET_S
                    {
                        bot.rear_end_normal += 1;
                        if std::env::var("SOAK_DEBUG").is_ok() {
                            println!(
                                "REAR t={time:.2} bot {b} s={:.1} d={:.2} v={:.2} | car slot {i} ds={ds:.2} d={:.2} v={:.2} a={:.2} lane={} tl={} lc={} lead={} gap={:.2} flags={:#x} profile={}",
                                bot.s, bot.d, bot.v, st.d[i], st.v[i], st.accel[i], st.lane[i], st.target_lane[i],
                                st.lc_state[i], sim.leader_of(i), sim.leader_gap(i), st.flags[i], st.profile_id[i]
                            );
                        }
                    }
                }
            }
        }
        bot.touching = now_touching;
    }

    /// SOAK_TRACE="slot,slot,...:from_tick:to_tick": prints those slots every tick.
    fn debug_trace(&self, tick: u32) {
        // SOAK_AREA="s0:s1:tick,tick,...": every vehicle in [s0, s1] at those ticks.
        if let Ok(spec) = std::env::var("SOAK_AREA") {
            let p: Vec<&str> = spec.split(':').collect();
            let (s0, s1): (f64, f64) = (p[0].parse().unwrap(), p[1].parse().unwrap());
            if p[2].split(',').any(|t| t.parse::<u32>().ok() == Some(tick)) {
                let st = &self.world.sim.state;
                for i in 0..st.capacity {
                    if st.active[i] == 1 && st.s[i] >= s0 && st.s[i] <= s1 {
                        println!(
                            "AREA {tick} slot {i} s {:.2} d {:.2} v {:.2} a {:.2} lane {} tl {} lc {} lead {} len {:.1}",
                            st.s[i], st.d[i], st.v[i], st.accel[i], st.lane[i], st.target_lane[i], st.lc_state[i],
                            self.world.sim.leader_of(i), st.length[i]
                        );
                    }
                }
            }
        }
        let Ok(spec) = std::env::var("SOAK_TRACE") else {
            return;
        };
        let mut parts = spec.split(':');
        let slots: Vec<usize> = parts
            .next()
            .unwrap_or("")
            .split(',')
            .filter_map(|x| x.parse().ok())
            .collect();
        let from: u32 = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
        let to: u32 = parts
            .next()
            .and_then(|x| x.parse().ok())
            .unwrap_or(u32::MAX);
        if tick < from || tick > to {
            return;
        }
        let sim = &self.world.sim;
        let st = &sim.state;
        for &i in &slots {
            if st.active[i] == 0 {
                continue;
            }
            println!(
                "TRACE {tick} slot {i} vid {} s {:.2} d {:.2} v {:.2} a {:.2} lane {} tl {} lc {} timer {:.2} lead {} gap {:.2} idm {:.2} flags {:#x} prof {} type {}",
                st.vehicle_id[i], st.s[i], st.d[i], st.v[i], st.accel[i], st.lane[i], st.target_lane[i], st.lc_state[i],
                st.lc_timer[i], sim.leader_of(i), sim.leader_gap(i), sim.idm_accel(i), st.flags[i], st.profile_id[i], st.type_id[i]
            );
        }
        for e in sim.events.as_slice() {
            if slots.contains(&(e.slot as usize)) {
                println!(
                    "TRACE {tick} event {:?} slot {} target {} move {}",
                    e.kind, e.slot, e.target_lane, e.move_start_tick
                );
            }
        }
    }

    pub fn contacts(&self) -> (u64, u64) {
        let c = self.bots.iter().map(|b| b.contacts).sum();
        let r = self.bots.iter().map(|b| b.rear_end_normal).sum();
        (c, r)
    }

    pub fn rng(&mut self) -> &mut Rng {
        &mut self.rng
    }
}
