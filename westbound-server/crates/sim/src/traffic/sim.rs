//! Traffic on one carriageway: IDM car following, MOBIL lane changes with telegraphing,
//! the fairness rules and reactions to players. A port of `src/traffic/traffic_sim.gd`
//! (`TrafficSim`) that keeps its structure: the same fields (without the leading `_`),
//! the same functions in the same order, the same arithmetic. On an open road with one
//! player and the single-player config it reproduces the GDScript sim bit for bit
//! (`tests/parity.rs`). Model and rules: docs/TRAFFIC.md; server rules: docs/SERVER.md →
//! Traffic simulation.
//!
//! What the server adds (multiplayer handoff → Traffic: server-authoritative with
//! intents), each marked `MP:` below:
//! - **Players are participants.** Up to `max_players` player entries (index
//!   `capacity + p` in the mirrors and the order) instead of one: leaders by lateral
//!   overlap, MOBIL's safety check with the player b_safe, no-ambush against each
//!   player's predicted position, reactions. Each player's reported state is
//!   extrapolated to the current tick (`PlayerInput::tick`).
//! - **The loop.** s wraps modulo L; every distance is `road.signed_delta`, and the
//!   leader / follower searches walk round the sorted order.
//! - **Intents.** Every lane-change decision is an event with its move-start tick and
//!   move time, known when the blinker comes on (`SimConfig::move_time_at_signal`); the
//!   minimum signal time is `SimConfig::signal_time_floor_s` (1.0 s on the server).
//! - **Ramps.** Exits into the off-ramp lane (a pseudo-lane right of the rightmost) and
//!   on-ramp merges (that pseudo-lane closed at the ramp's end: a mandatory merge);
//!   `population.rs` decides who exits and when a car enters.
//! - **Fixed rate.** With `near_radius_m = INF` every car runs its model every tick.
//!
//! Pure and allocation-free after `new`: `step`, `spawn`, `despawn`, `notify_hit` and
//! every query use preallocated vectors. Events go to `events` (fixed capacity).

use super::gd::{clampf, maxf, minf};
use super::idm;
use super::mobil;
use super::no_ambush;
use super::params::{MpTrafficRules, TrafficParams};
use super::road::RoadSpace;
use super::state::*;
use crate::rng::Rng;

/// Lane closures (WP6.2): at most this many at once; the road's own carry this tag.
pub const MAX_LANE_CLOSURES: usize = 32;
pub const ROAD_CLOSURE_TAG: i32 = -1;
/// MP: the ramps' merge walls (population.rs) and road works zones (tag = this + zone).
pub const RAMP_CLOSURE_TAG: i32 = -2;
pub const ZONE_CLOSURE_TAG_BASE: i32 = 1000;
/// Set-piece zones (WP6.3).
pub const MAX_SPEED_ZONES: usize = 8;
pub const MAX_HEADWAY_ZONES: usize = 4;
/// Lane-drop harmonisation zones (WP6.8): one per road lane drop.
pub const MAX_DROP_ZONES: usize = 8;
/// Longest lane-change cap a profile may ask for (WP6.9; per-slot ring size).
pub const WEAVE_CAP_MAX: usize = 8;

const PEND_HAZARD_ON: i32 = 1;
const PEND_HORN: i32 = 2;
const BLINKERS: i32 = FLAG_BLINKER_LEFT | FLAG_BLINKER_RIGHT;
const BRAKES: i32 = FLAG_BRAKE | FLAG_BRAKE_STRONG;
/// Smoothstep 3u^2 - 2u^3 and its derivative 6u(1 - u).
const SMOOTH_A: f64 = 3.0;
const SMOOTH_D: f64 = 6.0;
/// Bound on the intent's move-start tick search (a degenerate zero tick_dt).
const MOVE_TICKS_MAX: u32 = 1 << 20;
/// MP: the move time drawn at the signal is rounded to whole ms (the intent's
/// `duration_ms`), so a client's curve uses exactly the server's value.
const MOVE_TIME_STEPS_PER_S: f64 = 1_000.0;

/// What a sim event is. The first three are `TrafficSim.KIND_*` (the GDScript sim's
/// ScoreEventBuffer); the rest are the server's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    Horn,
    BrakeTap,
    /// value 1 = on, 0 = off.
    Hazards,
    /// MP: a lane change (or ramp exit) was signaled: `tick` (blinker on),
    /// `move_start_tick`, `target_lane`, `target_d`, `duration_s` (the move time; NaN
    /// when it is drawn later, `SimConfig::move_time_at_signal` off).
    Signal,
    /// MP: a signaled lane change was cancelled (blinker off, stays in lane).
    Cancel,
    /// MP: a vehicle entered (spawn) or left (despawn; tag `Exit` for an off-ramp).
    Spawned,
    Despawned,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventTag {
    None,
    BlindSpot,
    ClosePass,
    Honk,
    CutIn,
    Hit,
    /// MP: an off-ramp exit.
    Exit,
    /// MP: an on-ramp entry.
    Ramp,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SimEvent {
    pub kind: EventKind,
    pub tag: EventTag,
    pub slot: u32,
    pub vehicle_id: i32,
    pub tick: u32,
    pub value: f64,
    pub move_start_tick: u32,
    pub target_lane: i32,
    pub target_d: f64,
    pub duration_s: f64,
}

/// Fixed-capacity event list: pushing never allocates; overflow is counted and dropped.
#[derive(Debug, Clone)]
pub struct EventBuffer {
    events: Vec<SimEvent>,
    pub dropped: u64,
}

impl EventBuffer {
    pub fn new(capacity: usize) -> Self {
        EventBuffer {
            events: Vec::with_capacity(capacity),
            dropped: 0,
        }
    }

    #[inline]
    pub fn push(&mut self, e: SimEvent) {
        if self.events.len() < self.events.capacity() {
            self.events.push(e);
        } else {
            self.dropped += 1;
        }
    }

    pub fn clear(&mut self) {
        self.events.clear();
    }

    pub fn as_slice(&self) -> &[SimEvent] {
        &self.events
    }

    pub fn last_mut(&mut self) -> Option<&mut SimEvent> {
        self.events.last_mut()
    }

    pub fn len(&self) -> usize {
        self.events.len()
    }

    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
}

/// How the sim runs: the client's single-player rules (parity) or the server's.
#[derive(Debug, Clone, PartialEq)]
pub struct SimConfig {
    /// Vehicle slots.
    pub capacity: usize,
    pub max_players: usize,
    /// Every profile signals at least this long (single-player 0.5 s, server 1.0 s).
    pub signal_time_floor_s: f64,
    /// Vehicles further than this from every player run their model at the far rate
    /// (`TrafficTuning.far_tick_hz`); INF = every vehicle every tick (the server).
    pub near_radius_m: f64,
    /// MP: draw the move time when the blinker comes on (the intent carries it) instead
    /// of when the move starts (the GDScript order).
    pub move_time_at_signal: bool,
    /// Motorbike lane splitting.
    pub lane_split: bool,
    /// MP (not in the GDScript model): a leader that is signalling or moving out of the
    /// path does not hide what is ahead of it. Following (IDM) and MOBIL's own-safety
    /// check also judge the next vehicle on the path beyond it (`look_through_leader`).
    pub look_through: bool,
    /// MP (not in the GDScript model): MOBIL's own-safety check also judges each new
    /// leader as it will be when the car is in the lane (signal time + half the minimum
    /// move time on), with its current deceleration (`predicted_leader_safe`).
    pub predict_leaders: bool,
    /// MP (not in the GDScript model): when stopping behind the leader's own stopping
    /// point (at its current deceleration) needs more than the profile's comfortable b,
    /// the follower brakes for it now (`anticipation_accel`).
    pub anticipate_braking: bool,
    /// MP: a player's reported state is extrapolated at most this far.
    pub player_max_extrapolation_s: f64,
    /// The fixed step (intents' move-start ticks, player extrapolation).
    pub tick_dt: f64,
    pub events_capacity: usize,
}

impl SimConfig {
    /// The GDScript sim's rules (`TrafficSim` with `TrafficTuning` as exported).
    pub fn single_player(p: &TrafficParams) -> Self {
        let t = &p.tuning;
        SimConfig {
            capacity: t.max_active_vehicles,
            max_players: 1,
            signal_time_floor_s: t.signal_time_floor_s,
            near_radius_m: t.near_radius_m,
            move_time_at_signal: false,
            lane_split: true,
            look_through: false,
            predict_leaders: false,
            anticipate_braking: false,
            player_max_extrapolation_s: 0.0,
            tick_dt: 1.0 / f64::from(t.near_tick_hz),
            events_capacity: t.max_active_vehicles * 4 + 64,
        }
    }

    /// The server's rules (multiplayer handoff → Server simulation).
    pub fn multiplayer(p: &TrafficParams, mp: &MpTrafficRules) -> Self {
        SimConfig {
            capacity: mp.capacity,
            max_players: mp.max_players,
            signal_time_floor_s: mp.signal_time_floor_s,
            near_radius_m: f64::INFINITY,
            move_time_at_signal: true,
            lane_split: mp.lane_split,
            look_through: mp.look_through_leaving_leaders,
            predict_leaders: mp.predict_leader_braking,
            anticipate_braking: mp.anticipate_leader_braking,
            player_max_extrapolation_s: mp.player_max_extrapolation_s,
            tick_dt: 1.0 / p.net.tick_rate_hz,
            events_capacity: mp.capacity * 4 + 64,
        }
    }
}

/// A player as the sim sees it: road-frame position and velocity at a reported tick.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PlayerInput {
    pub s: f64,
    pub d: f64,
    /// ds/dt and dd/dt (road frame; see `from_vehicle`).
    pub s_dot: f64,
    pub d_dot: f64,
    pub length: f64,
    pub width: f64,
    /// The server tick this state is for (extrapolated to the current one).
    pub tick: u32,
}

impl PlayerInput {
    /// From a car's speed, lateral velocity and yaw relative to the road (GDScript
    /// `TrafficSim._read_player`): s_dot = (v cos yaw - v_lat sin yaw) / (1 - kappa d),
    /// d_dot = v sin yaw + v_lat cos yaw.
    #[allow(clippy::too_many_arguments)]
    pub fn from_vehicle(
        s: f64,
        d: f64,
        v: f64,
        v_lat: f64,
        yaw: f64,
        kappa: f64,
        length: f64,
        width: f64,
        tick: u32,
    ) -> Self {
        let cy = yaw.cos();
        let sy = yaw.sin();
        PlayerInput {
            s,
            d,
            s_dot: (v * cy - v_lat * sy) / (1.0 - kappa * d),
            d_dot: v * sy + v_lat * cy,
            length,
            width,
            tick,
        }
    }
}

/// What `spawn` copies (`SpawnSource.Record`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SpawnRecord {
    pub s: f64,
    pub lane: i32,
    /// NaN = the lane center.
    pub d: f64,
    pub v: f64,
    /// <= 0: the middle of the profile's range.
    pub v0: f64,
    pub type_id: i32,
    pub profile_id: i32,
    pub model_variant: i32,
    pub color_index: i32,
    pub flags: i32,
}

pub struct TrafficSim {
    pub state: TrafficState,
    pub road: RoadSpace,
    pub config: SimConfig,
    pub events: EventBuffer,

    // Counters (metrics, tests)
    pub stat_signals: u64,
    pub stat_hesitant_signals: u64,
    pub stat_moves: u64,
    pub stat_completed: u64,
    pub stat_cancel_player: u64,
    pub stat_cancel_hesitant: u64,
    pub stat_cancel_unsafe: u64,
    pub stat_model_updates: u64,
    pub stat_merges: u64,
    /// MP
    pub stat_exits: u64,
    pub stat_exit_cancels: u64,

    cap: usize,
    np: usize,
    rng_lc: Rng,
    rng_react: Rng,
    rng_spawn: Rng,
    headlights: bool,
    tick: u32,

    // Cached tuning (SI)
    max_decel: f64,
    scripted_decel: f64,
    brake_decel: f64,
    brake_strong: f64,
    look: f64,
    gap_floor: f64,
    lat_m: f64,
    near_r: f64,
    far_ratio: i32,
    window: f64,
    margin: f64,
    player_b_safe: f64,
    cooldown: f64,
    disc: f64,
    antic: f64,
    pl_a: f64,
    pl_b: f64,
    pl_t: f64,
    pl_s0: f64,
    hit_recover: f64,
    hit_swerve_m: f64,
    hit_swerve_s: f64,
    hit_decel: f64,
    hit_brake_s: f64,
    tap_decel: f64,
    tap_s: f64,
    cut_in_m: f64,
    blind_m: f64,
    blind_s: f64,
    blind_frac: f64,
    close_frac: f64,
    react_cool: f64,
    react_range: f64,
    split_max_v: f64,
    split_v0: f64,
    split_scan: f64,
    split_clear: f64,
    split_player_lat: f64,
    split_player_range: f64,

    // Per profile
    pa: Vec<f64>,
    pb: Vec<f64>,
    pt: Vec<f64>,
    pt_base: Vec<f64>,
    ps0: Vec<f64>,
    pdl: Vec<i32>,
    ppol: Vec<f64>,
    pth: Vec<f64>,
    pbias: Vec<f64>,
    pbsafe: Vec<f64>,
    psig: Vec<f64>,
    pmmin: Vec<f64>,
    pmmax: Vec<f64>,
    peval: Vec<f64>,
    pcancel: Vec<f64>,
    pkr: Vec<u8>,
    pkrl: Vec<i32>,
    psplit: Vec<u8>,
    pv0min: Vec<f64>,
    pv0max: Vec<f64>,
    // Per type
    tlen: Vec<f64>,
    twid: Vec<f64>,

    // Players (road frame), refreshed at the start of every step. MP: one entry each.
    p_on: Vec<u8>,
    p_in: Vec<PlayerInput>,
    pl_s: Vec<f64>,
    pl_v: Vec<f64>,
    pl_d: Vec<f64>,
    pl_vl: Vec<f64>,
    pl_len: Vec<f64>,
    pl_w: Vec<f64>,
    pl_lo: Vec<f64>,
    pl_hi: Vec<f64>,

    // Road cross-section at the reference player (constant on both road shapes)
    edge: f64,
    lw: f64,

    // Mirrors, capacity + max_players entries (players last)
    ks: Vec<f64>,
    kv: Vec<f64>,
    khl: Vec<f64>,
    klo: Vec<f64>,
    khi: Vec<f64>,
    kclo: Vec<f64>,
    kchi: Vec<f64>,
    ord: Vec<usize>,
    rank: Vec<usize>,
    n: usize,

    // Per slot
    acc_t: Vec<f64>,
    acc_n: Vec<i32>,
    due: Vec<u8>,
    mdt: Vec<f64>,
    lead: Vec<i64>,
    lead_gap: Vec<f64>,
    a_raw: Vec<f64>,
    mobil_t: Vec<f64>,
    will_cancel: Vec<u8>,
    tap_t: Vec<f64>,
    blind_t: Vec<f64>,
    prev_lead_p: Vec<i64>,
    swerve_dir: Vec<f64>,
    swerve_base: Vec<f64>,
    hit_hazard: Vec<u8>,
    lc_target_d: Vec<f64>,
    lc_split: Vec<i32>,
    split: Vec<i32>,
    hard_ok: Vec<u8>,
    hold: Vec<u8>,
    /// MP: the move time drawn when the blinker came on.
    lc_move_dur: Vec<f64>,
    /// MP: the tick the lateral move starts (`Signal` events), and the signal's tick.
    lc_move_tick: Vec<u32>,
    lc_signal_tick: Vec<u32>,
    /// MP: 1 = signaled or moving into the off-ramp lane.
    exiting: Vec<u8>,
    /// MP: distance driven in the last integration (ramp decisions).
    ds_last: Vec<f64>,
    exited: Vec<usize>,
    // WP6.8, per slot, from its last model tick (drop_tick): merge-zone fractions of its
    // own lane and the lanes left / right of it, its own closure's base urgency and
    // distance, and the speed-matching factor.
    cf_own: Vec<f64>,
    cf_left: Vec<f64>,
    cf_right: Vec<f64>,
    cf_base: Vec<f64>,
    cf_dist: Vec<f64>,
    match_: Vec<f64>,
    // WP6.8: this step's zipper candidates, in road order.
    cand: Vec<usize>,
    cand_n: usize,
    // Lane closures
    cl_lane: Vec<i32>,
    cl_s0: Vec<f64>,
    cl_s1: Vec<f64>,
    cl_tag: Vec<i32>,
    cl_zone: Vec<f64>,
    cl_base: Vec<f64>,
    cl_n: usize,
    merge_zone: f64,
    merge_urg: f64,
    merge_stop: f64,
    // Lane drops (WP6.8): harmonisation zones [s0, s1]; lanes >= first lane are dropping.
    dz_s0: Vec<f64>,
    dz_s1: Vec<f64>,
    dz_lane: Vec<i32>,
    dz_n: usize,
    drop_zone: f64,
    drop_urg_min: f64,
    drop_slow: f64,
    drop_after: f64,
    drop_v_through: f64,
    drop_v_merge: f64,
    yield_range: f64,
    yield_frac: f64,
    yield_decel: f64,
    foll_horizon: f64,
    drop_onset: f64,
    drop_view: f64,
    drop_release: f64,
    drop_floor: f64,
    drop_floor_until: f64,
    drop_narrow_max: f64,
    /// Fastest vehicle this step (bounds MOBIL's follower scan).
    vmax: f64,
    cl_lo: f64,
    cl_hi: f64,
    dz_lo: f64,
    dz_hi: f64,
    // Set-piece zones
    sz_lane: Vec<i32>,
    sz_s0: Vec<f64>,
    sz_s1: Vec<f64>,
    sz_v: Vec<f64>,
    sz_tag: Vec<i32>,
    sz_keep_s1: Vec<f64>,
    sz_keep_v: Vec<f64>,
    sz_n: usize,
    hz_s0: Vec<f64>,
    hz_s1: Vec<f64>,
    hz_k: Vec<f64>,
    hz_tag: Vec<i32>,
    hz_n: usize,
    pending: Vec<i32>,
    pending_tag: Vec<EventTag>,
    n_pending: usize,

    // Neighbor query results
    q_player: bool,

    // Racers weave harder (plan D17, WP6.9)
    pweave: Vec<u8>,
    w_tk: Vec<f64>,
    ws0: Vec<f64>,
    wb: Vec<f64>,
    wbsafe: Vec<f64>,
    wlook: Vec<f64>,
    wgain: Vec<f64>,
    wmax: Vec<f64>,
    wcool: Vec<f64>,
    wcap: Vec<i32>,
    wwin: Vec<f64>,
    wclock: f64,
    wvid: Vec<i32>,
    wn: Vec<i32>,
    wt: Vec<f64>,
}

/// No leader / follower.
const NONE: i64 = -1;

impl TrafficSim {
    /// `TrafficSim._init`. `rng_traffic` is the run's traffic stream (`ctx.rng_traffic`,
    /// i.e. `Rng::new(run_seed).derive("traffic")`).
    pub fn new(
        params: &TrafficParams,
        config: SimConfig,
        road: RoadSpace,
        rng_traffic: &Rng,
    ) -> Self {
        let t = &params.tuning;
        let cap = config.capacity;
        let np = config.max_players.max(1);
        let total = cap + np;
        let fz = |n: usize| vec![0.0f64; n];
        let pr = &params.profiles;
        let mut sim = TrafficSim {
            state: TrafficState::new(cap),
            events: EventBuffer::new(config.events_capacity),
            stat_signals: 0,
            stat_hesitant_signals: 0,
            stat_moves: 0,
            stat_completed: 0,
            stat_cancel_player: 0,
            stat_cancel_hesitant: 0,
            stat_cancel_unsafe: 0,
            stat_model_updates: 0,
            stat_merges: 0,
            stat_exits: 0,
            stat_exit_cancels: 0,
            cap,
            np,
            rng_lc: rng_traffic.derive("sim_lane_change"),
            rng_react: rng_traffic.derive("sim_react"),
            rng_spawn: rng_traffic.derive("sim_spawn"),
            headlights: false,
            tick: 0,
            max_decel: t.max_decel_mps2,
            scripted_decel: maxf(t.scripted_max_decel_mps2, t.max_decel_mps2),
            brake_decel: t.brake_light_decel_mps2,
            brake_strong: t.brake_light_strong_decel_mps2,
            look: t.idm_lookahead_m,
            gap_floor: t.idm_gap_floor_m,
            lat_m: t.lateral_margin_m,
            near_r: config.near_radius_m,
            far_ratio: t.far_tick_ratio.max(1),
            window: t.no_ambush_window_s,
            margin: t.no_ambush_margin_m,
            player_b_safe: t.player_b_safe_mps2,
            cooldown: t.lane_change_cooldown_s,
            disc: t.lane_discipline_bias_mps2,
            antic: t.player_lateral_anticipation_s,
            pl_a: t.player_idm_a_max_mps2,
            pl_b: t.player_idm_b_comfort_mps2,
            pl_t: t.player_idm_headway_s,
            pl_s0: t.player_idm_s0_m,
            hit_recover: t.hit_recover_s,
            hit_swerve_m: t.hit_swerve_m,
            hit_swerve_s: t.hit_swerve_s,
            hit_decel: t.hit_brake_decel_mps2,
            hit_brake_s: t.hit_brake_s,
            tap_decel: t.brake_tap_decel_mps2,
            tap_s: t.brake_tap_s,
            cut_in_m: t.cut_in_brake_tap_distance_m,
            blind_m: t.blind_spot_behind_m,
            blind_s: t.blind_spot_horn_s,
            blind_frac: t.blind_spot_horn_frac,
            close_frac: t.close_pass_horn_frac,
            react_cool: t.reaction_cooldown_s,
            react_range: 0.0,
            split_max_v: t.lane_split_max_traffic_mps,
            split_v0: t.lane_split_max_speed_mps,
            split_scan: t.lane_split_scan_m,
            split_clear: t.lane_split_clearance_m,
            split_player_lat: t.lane_split_player_lateral_mps,
            split_player_range: t.lane_split_player_range_m,
            pa: pr.iter().map(|p| p.a_max_mps2).collect(),
            pb: pr.iter().map(|p| p.b_comfort_mps2).collect(),
            pt: pr.iter().map(|p| p.headway_s).collect(),
            pt_base: pr.iter().map(|p| p.headway_s).collect(),
            ps0: pr.iter().map(|p| p.s0_m).collect(),
            pdl: pr.iter().map(|p| p.delta).collect(),
            ppol: pr.iter().map(|p| p.politeness).collect(),
            pth: pr.iter().map(|p| p.a_threshold_mps2).collect(),
            pbias: pr.iter().map(|p| p.a_bias_mps2).collect(),
            pbsafe: pr.iter().map(|p| p.b_safe_mps2).collect(),
            // TrafficRegistry: signal_s = max(signal_time_s, floor), with this config's floor.
            psig: pr
                .iter()
                .map(|p| maxf(p.signal_time_s, config.signal_time_floor_s))
                .collect(),
            pmmin: pr.iter().map(|p| p.move_min_s).collect(),
            pmmax: pr.iter().map(|p| p.move_max_s).collect(),
            peval: pr.iter().map(|p| p.eval_interval_s).collect(),
            pcancel: pr.iter().map(|p| p.cancel_p).collect(),
            pkr: pr.iter().map(|p| u8::from(p.keep_right)).collect(),
            pkrl: pr.iter().map(|p| p.keep_right_lanes.max(0)).collect(),
            psplit: pr
                .iter()
                .map(|p| u8::from(p.lane_split && config.lane_split))
                .collect(),
            pv0min: pr.iter().map(|p| p.v0_min_mps).collect(),
            pv0max: pr.iter().map(|p| p.v0_max_mps).collect(),
            tlen: params.types.iter().map(|x| x.length_m).collect(),
            twid: params.types.iter().map(|x| x.width_m).collect(),
            p_on: vec![0; np],
            p_in: vec![PlayerInput::default(); np],
            pl_s: fz(np),
            pl_v: fz(np),
            pl_d: fz(np),
            pl_vl: fz(np),
            pl_len: vec![t.player_length_m; np],
            pl_w: vec![t.player_width_m; np],
            pl_lo: vec![f64::NAN; np],
            pl_hi: vec![f64::NAN; np],
            edge: road.lanes_left_edge_d(0.0),
            lw: road.lane_width(0.0),
            road,
            ks: fz(total),
            kv: fz(total),
            khl: fz(total),
            klo: fz(total),
            khi: fz(total),
            kclo: fz(total),
            kchi: fz(total),
            ord: vec![0; total],
            rank: vec![0; total],
            n: 0,
            acc_t: fz(cap),
            acc_n: vec![0; cap],
            due: vec![0; cap],
            mdt: fz(cap),
            lead: vec![NONE; cap],
            lead_gap: fz(cap),
            a_raw: fz(cap),
            mobil_t: fz(cap),
            will_cancel: vec![0; cap],
            tap_t: fz(cap),
            blind_t: fz(cap),
            prev_lead_p: vec![NONE; cap],
            swerve_dir: fz(cap),
            swerve_base: fz(cap),
            hit_hazard: vec![0; cap],
            lc_target_d: fz(cap),
            lc_split: vec![0; cap],
            split: vec![0; cap],
            hard_ok: vec![0; cap],
            hold: vec![0; cap],
            lc_move_dur: fz(cap),
            lc_move_tick: vec![0; cap],
            lc_signal_tick: vec![0; cap],
            exiting: vec![0; cap],
            ds_last: fz(cap),
            exited: Vec::with_capacity(cap),
            cf_own: vec![f64::INFINITY; cap],
            cf_left: vec![f64::INFINITY; cap],
            cf_right: vec![f64::INFINITY; cap],
            cf_base: fz(cap),
            cf_dist: vec![f64::INFINITY; cap],
            match_: fz(cap),
            cand: vec![0; cap],
            cand_n: 0,
            cl_lane: vec![0; MAX_LANE_CLOSURES],
            cl_s0: fz(MAX_LANE_CLOSURES),
            cl_s1: fz(MAX_LANE_CLOSURES),
            cl_tag: vec![0; MAX_LANE_CLOSURES],
            cl_zone: fz(MAX_LANE_CLOSURES),
            cl_base: fz(MAX_LANE_CLOSURES),
            cl_n: 0,
            merge_zone: t.merge_zone_m,
            merge_urg: t.merge_urgency_mps2,
            merge_stop: t.merge_stop_margin_m,
            dz_s0: fz(MAX_DROP_ZONES),
            dz_s1: fz(MAX_DROP_ZONES),
            dz_lane: vec![0; MAX_DROP_ZONES],
            dz_n: 0,
            drop_zone: t.lane_drop_merge_zone_m,
            drop_urg_min: t.lane_drop_urgency_min_mps2,
            drop_slow: t.lane_drop_slow_zone_m,
            drop_after: t.lane_drop_slow_after_m,
            drop_v_through: t.lane_drop_through_mps,
            drop_v_merge: t.lane_drop_merge_lane_mps,
            yield_range: t.lane_drop_yield_range_m,
            yield_frac: t.lane_drop_yield_frac,
            yield_decel: t.lane_drop_yield_decel_mps2,
            foll_horizon: t.mobil_follower_horizon_s,
            drop_onset: t.lane_drop_brake_onset_frac,
            drop_view: t.lane_drop_view_m,
            drop_release: t.lane_drop_release_m,
            drop_floor: t.lane_drop_merge_floor_mps,
            drop_floor_until: t.lane_drop_merge_floor_until_m,
            drop_narrow_max: t.lane_drop_narrow_max_m,
            vmax: 0.0,
            cl_lo: f64::INFINITY,
            cl_hi: f64::NEG_INFINITY,
            dz_lo: f64::INFINITY,
            dz_hi: f64::NEG_INFINITY,
            sz_lane: vec![0; MAX_SPEED_ZONES],
            sz_s0: fz(MAX_SPEED_ZONES),
            sz_s1: fz(MAX_SPEED_ZONES),
            sz_v: fz(MAX_SPEED_ZONES),
            sz_tag: vec![0; MAX_SPEED_ZONES],
            sz_keep_s1: fz(MAX_SPEED_ZONES),
            sz_keep_v: fz(MAX_SPEED_ZONES),
            sz_n: 0,
            hz_s0: fz(MAX_HEADWAY_ZONES),
            hz_s1: fz(MAX_HEADWAY_ZONES),
            hz_k: fz(MAX_HEADWAY_ZONES),
            hz_tag: vec![0; MAX_HEADWAY_ZONES],
            hz_n: 0,
            pending: vec![0; cap],
            pending_tag: vec![EventTag::None; cap],
            n_pending: 0,
            q_player: false,
            pweave: Vec::new(),
            w_tk: Vec::new(),
            ws0: Vec::new(),
            wb: Vec::new(),
            wbsafe: Vec::new(),
            wlook: Vec::new(),
            wgain: Vec::new(),
            wmax: Vec::new(),
            wcool: Vec::new(),
            wcap: Vec::new(),
            wwin: Vec::new(),
            wclock: 0.0,
            wvid: vec![-1; cap],
            wn: vec![0; cap],
            wt: vec![0.0; cap * WEAVE_CAP_MAX],
            config,
        };
        sim.init_weave(params);
        let mut max_len = 0.0;
        for x in &sim.tlen {
            max_len = maxf(max_len, *x);
        }
        sim.react_range = sim.blind_m + max_len + t.player_length_m;
        sim.clear();
        sim
    }

    /// Removes every vehicle (state.clear()) and resets the counters. Players stay.
    pub fn clear(&mut self) {
        self.state.clear();
        self.n = 0;
        for p in 0..self.np {
            if self.p_on[p] == 1 {
                self.insert_player_entry(p);
            }
        }
        self.n_pending = 0;
        for i in 0..self.cap {
            self.pending[i] = 0;
            self.exiting[i] = 0;
        }
        self.stat_signals = 0;
        self.stat_hesitant_signals = 0;
        self.stat_moves = 0;
        self.stat_completed = 0;
        self.stat_cancel_player = 0;
        self.stat_cancel_hesitant = 0;
        self.stat_cancel_unsafe = 0;
        self.stat_model_updates = 0;
        self.stat_merges = 0;
        self.stat_exits = 0;
        self.stat_exit_cancels = 0;
    }

    // ------------------------------------------------------------ Players (MP)

    #[inline]
    fn is_player(&self, j: usize) -> bool {
        j >= self.cap
    }

    /// Index that stands for player p in `leader_of` (`capacity + p`).
    pub fn player_index(&self, p: usize) -> usize {
        self.cap + p
    }

    /// Adds or updates player p. A new player enters the order like the GDScript sim's
    /// player (first, at s = -INF, sorted at the next step).
    pub fn set_player(&mut self, p: usize, input: PlayerInput) {
        self.p_in[p] = input;
        self.pl_len[p] = input.length;
        self.pl_w[p] = input.width;
        self.khl[self.cap + p] = input.length * 0.5;
        if self.p_on[p] == 0 {
            self.p_on[p] = 1;
            self.insert_player_entry(p);
        }
    }

    /// The player's body size (GDScript `set_player_body`), keeping its state.
    pub fn set_player_body(&mut self, p: usize, length_m: f64, width_m: f64) {
        self.p_in[p].length = length_m;
        self.p_in[p].width = width_m;
        self.pl_len[p] = length_m;
        self.pl_w[p] = width_m;
        self.khl[self.cap + p] = length_m * 0.5;
    }

    pub fn remove_player(&mut self, p: usize) {
        if self.p_on[p] == 0 {
            return;
        }
        self.p_on[p] = 0;
        self.remove_entry(self.cap + p);
    }

    pub fn player_active(&self, p: usize) -> bool {
        self.p_on[p] == 1
    }

    fn insert_player_entry(&mut self, p: usize) {
        let e = self.cap + p;
        let mut k = self.n;
        while k > 0 {
            self.ord[k] = self.ord[k - 1];
            self.rank[self.ord[k]] = k;
            k -= 1;
        }
        self.ord[0] = e;
        self.rank[e] = 0;
        self.n += 1;
        self.ks[e] = f64::NEG_INFINITY;
        self.kv[e] = 0.0;
        self.khl[e] = self.pl_len[p] * 0.5;
        self.klo[e] = f64::NAN;
        self.khi[e] = f64::NAN;
        self.kclo[e] = f64::NAN;
        self.kchi[e] = f64::NAN;
    }

    fn remove_entry(&mut self, e: usize) {
        let mut k = self.rank[e];
        while k + 1 < self.n {
            self.ord[k] = self.ord[k + 1];
            self.rank[self.ord[k]] = k;
            k += 1;
        }
        self.n -= 1;
    }

    // ------------------------------------------------------------ Tuning hooks

    /// Plan D11: every profile's IDM time headway T becomes its profile value x `scale`.
    pub fn set_headway_scale(&mut self, scale: f64) {
        for p in 0..self.pt.len() {
            self.pt[p] = self.pt_base[p] * scale;
        }
    }

    pub fn headway(&self, p: usize) -> f64 {
        self.pt[p]
    }

    /// Leader found at this vehicle's last model update: a slot, a player index, or -1.
    pub fn leader_of(&self, slot: usize) -> i64 {
        self.lead[slot]
    }

    pub fn leader_gap(&self, slot: usize) -> f64 {
        self.lead_gap[slot]
    }

    pub fn idm_accel(&self, slot: usize) -> f64 {
        self.a_raw[slot]
    }

    /// The current tick (the last `step`'s).
    pub fn tick(&self) -> u32 {
        self.tick
    }

    /// MP: the tick the signaled or running lateral move starts (0 when none).
    pub fn move_start_tick(&self, slot: usize) -> u32 {
        if self.state.lc_state[slot] == LC_NONE {
            0
        } else {
            self.lc_move_tick[slot]
        }
    }

    /// MP: the move time of the signaled or running lateral move (s).
    pub fn move_duration(&self, slot: usize) -> f64 {
        match self.state.lc_state[slot] {
            LC_MOVING => self.state.lc_duration[slot],
            LC_SIGNALING => self.lc_move_dur[slot],
            _ => 0.0,
        }
    }

    /// The d the signaled or running lateral move ends at.
    pub fn lc_target_d(&self, slot: usize) -> f64 {
        self.lc_target_d[slot]
    }

    /// MP: a signaled lane change that will be cancelled when its signal time ends (a
    /// hesitant driver's, decided when the blinker came on).
    pub fn will_cancel(&self, slot: usize) -> bool {
        self.state.lc_state[slot] == LC_SIGNALING && self.will_cancel[slot] == 1
    }

    /// MP: signaled or moving into an off-ramp.
    pub fn is_exiting(&self, slot: usize) -> bool {
        self.exiting[slot] == 1
    }

    /// MP: distance the vehicle drove in the last step (ramp decisions).
    pub fn last_step_distance(&self, slot: usize) -> f64 {
        self.ds_last[slot]
    }

    /// Live entries (vehicles and players) in order of s.
    pub fn order(&self) -> &[usize] {
        &self.ord[..self.n]
    }

    /// The first order position whose s is >= `s` (0..=n; players not yet placed sort
    /// first).
    pub fn order_lower_bound(&self, s: f64) -> usize {
        self.ord[..self.n].partition_point(|&j| self.ks[j] < s) % self.n.max(1)
    }

    /// Player p's position as the sim uses it this tick (extrapolated, wrapped).
    pub fn state_player_s(&self, p: usize) -> f64 {
        self.pl_s[p]
    }

    /// Player p's lateral position this tick.
    pub fn state_player_d(&self, p: usize) -> f64 {
        self.pl_d[p]
    }

    /// The road lane drops' merge zone and base urgency (WP6.8).
    pub fn drop_merge_params(&self) -> (f64, f64) {
        (self.drop_zone, self.drop_urg_min)
    }

    /// The last event pushed (to retag it).
    pub fn events_last_mut(&mut self) -> Option<&mut SimEvent> {
        self.events.last_mut()
    }

    // ------------------------------------------------------------ Spawning

    /// Commits one planned vehicle into a free slot (`TrafficSim.spawn`); None when full.
    /// The caller owns spacing. Allocation-free.
    pub fn spawn(&mut self, rec: &SpawnRecord) -> Option<usize> {
        if self.state.is_full() {
            return None;
        }
        let tid = rec.type_id as usize;
        let pid = rec.profile_id as usize;
        debug_assert!(tid < self.tlen.len() && pid < self.pa.len());
        let hl = self.tlen[tid] * 0.5;
        let ln = rec.lane;
        let s_rec = self.road.wrap(rec.s);
        let mut d = rec.d;
        if d.is_nan() {
            d = self.road.lane_center_d(ln, s_rec);
        }
        let i = self.state.allocate()?;
        let st = &mut self.state;
        st.s[i] = s_rec;
        st.d[i] = d;
        st.v[i] = rec.v;
        st.v0[i] = if rec.v0 > 0.0 {
            rec.v0
        } else {
            (self.pv0min[pid] + self.pv0max[pid]) * 0.5
        };
        st.length[i] = self.tlen[tid];
        st.width[i] = self.twid[tid];
        st.lane[i] = ln;
        st.target_lane[i] = ln;
        st.type_id[i] = rec.type_id;
        st.profile_id[i] = rec.profile_id;
        st.model_variant[i] = rec.model_variant;
        st.color_index[i] = rec.color_index;
        let mut f = rec.flags & !(FLAG_FAR | FLAG_HIT | BLINKERS | BRAKES);
        if self.headlights {
            f |= FLAG_HEADLIGHTS;
        }
        st.flags[i] = f;

        self.acc_t[i] = 0.0;
        self.acc_n[i] = self.state.vehicle_id[i] % self.far_ratio;
        self.due[i] = 0;
        self.mdt[i] = 0.0;
        self.lead[i] = NONE;
        self.lead_gap[i] = f64::INFINITY;
        self.a_raw[i] = 0.0;
        self.mobil_t[i] = self.rng_spawn.float_range(0.0, self.peval[pid]);
        self.will_cancel[i] = 0;
        self.tap_t[i] = -self.react_cool;
        self.blind_t[i] = 0.0;
        self.prev_lead_p[i] = NONE;
        self.swerve_dir[i] = 0.0;
        self.swerve_base[i] = d;
        self.hit_hazard[i] = 0;
        self.pending[i] = 0;
        self.lc_target_d[i] = d;
        self.lc_split[i] = 0;
        self.split[i] = 0;
        self.hard_ok[i] = 0;
        self.hold[i] = 0;
        self.cf_own[i] = f64::INFINITY;
        self.cf_left[i] = f64::INFINITY;
        self.cf_right[i] = f64::INFINITY;
        self.cf_base[i] = 0.0;
        self.cf_dist[i] = f64::INFINITY;
        self.match_[i] = 0.0;
        self.lc_move_dur[i] = 0.0;
        self.lc_move_tick[i] = 0;
        self.lc_signal_tick[i] = 0;
        self.exiting[i] = 0;
        self.ds_last[i] = 0.0;

        self.ks[i] = s_rec;
        self.kv[i] = rec.v;
        self.khl[i] = hl;
        self.refresh_interval(i);
        let mut k = self.n;
        while k > 0 && self.ks[self.ord[k - 1]] > s_rec {
            self.ord[k] = self.ord[k - 1];
            self.rank[self.ord[k]] = k;
            k -= 1;
        }
        self.ord[k] = i;
        self.rank[i] = k;
        self.n += 1;
        self.push_event(EventKind::Spawned, EventTag::None, i, 0.0);
        Some(i)
    }

    /// Frees a slot (`TrafficSim.despawn`). Ignores inactive slots.
    pub fn despawn(&mut self, slot: usize) {
        self.despawn_tagged(slot, EventTag::None);
    }

    fn despawn_tagged(&mut self, slot: usize, tag: EventTag) {
        if !self.state.is_active(slot) {
            return;
        }
        self.push_event(EventKind::Despawned, tag, slot, 0.0);
        self.remove_entry(slot);
        self.pending[slot] = 0;
        self.exiting[slot] = 0;
        self.state.free_slot(slot);
    }

    // ------------------------------------------------------------ Run hooks

    /// A player hit this car (`TrafficSim.notify_hit`; MP: the hitting player `p`
    /// decides the swerve direction).
    pub fn notify_hit(&mut self, slot: usize, p: usize) {
        if !self.state.is_active(slot) {
            return;
        }
        let f = self.state.flags[slot];
        if self.state.lc_state[slot] == LC_SIGNALING {
            self.cancel(slot);
        }
        if (f & FLAG_HIT) == 0 {
            self.hit_hazard[slot] = if (f & FLAG_HAZARD) != 0 { 0 } else { 1 };
            if self.hit_hazard[slot] == 1 {
                self.pending[slot] |= PEND_HAZARD_ON;
                self.n_pending += 1;
            }
        }
        self.state.flags[slot] = f | FLAG_HIT | FLAG_HAZARD;
        self.state.react_timer[slot] = self.hit_recover;
        if self.state.lc_state[slot] == LC_MOVING {
            self.swerve_dir[slot] = 0.0;
        } else {
            if self.swerve_dir[slot] == 0.0 {
                self.swerve_base[slot] = self.state.d[slot];
            }
            self.swerve_dir[slot] = if self.swerve_base[slot] >= self.pl_d[p] {
                1.0
            } else {
                -1.0
            };
        }
    }

    /// Sounds this car's horn at the next step.
    pub fn honk(&mut self, slot: usize, tag: EventTag) {
        if !self.state.is_active(slot) {
            return;
        }
        if self.pending[slot] == 0 {
            self.n_pending += 1;
        }
        self.pending[slot] |= PEND_HORN;
        self.pending_tag[slot] = tag;
    }

    /// A close pass: the car honks close_pass_horn_pct of the time. True when it honks.
    pub fn notify_close_pass(&mut self, slot: usize) -> bool {
        if !self.state.is_active(slot) || !self.rng_react.chance(self.close_frac) {
            return false;
        }
        self.honk(slot, EventTag::ClosePass);
        true
    }

    /// Headlights (the room clock). New spawns inherit the setting.
    pub fn set_headlights(&mut self, on: bool) {
        self.headlights = on;
        for k in 0..self.n {
            let i = self.ord[k];
            if !self.is_player(i) {
                self.state.set_flag(i, FLAG_HEADLIGHTS, on);
            }
        }
    }

    pub fn headlights(&self) -> bool {
        self.headlights
    }

    /// Scripted lane change (`TrafficSim.request_lane_change`).
    pub fn request_lane_change(&mut self, slot: usize, target_lane: i32) -> bool {
        if !self.state.is_active(slot)
            || self.state.lc_state[slot] != LC_NONE
            || (target_lane - self.state.lane[slot]).abs() != 1
            || (self.state.flags[slot] & FLAG_HIT) != 0
        {
            return false;
        }
        if self.split[slot] != 0 {
            return false;
        }
        if (self.state.flags[slot] & FLAG_SCRIPTED) != 0 {
            if target_lane < 0
                || target_lane >= self.road.lane_count(self.ks[slot])
                || self.closes_soon(target_lane, slot)
                || self
                    .eval_move(slot, self.lane_d(target_lane), target_lane, false, false)
                    .is_infinite()
            {
                return false;
            }
        } else if self
            .eval_target(slot, target_lane, false, false)
            .is_infinite()
        {
            return false;
        }
        self.start_signal(slot, target_lane, self.lane_d(target_lane), 0);
        true
    }

    pub fn is_lane_splitting(&self, slot: usize) -> bool {
        self.split[slot] != 0
    }

    // ------------------------------------------------------------ Set-piece hooks (WP6.2)

    pub fn set_scripted_v0(&mut self, slot: usize, v0: f64) {
        if self.state.is_active(slot) {
            self.state.v0[slot] = v0;
        }
    }

    pub fn scripted_brake_tap(&mut self, slot: usize) -> bool {
        if !self.state.is_active(slot)
            || self.tap_t[slot] > 0.0
            || (self.state.flags[slot] & FLAG_HIT) != 0
        {
            return false;
        }
        self.tap_t[slot] = self.tap_s;
        true
    }

    pub fn set_hard_decel_allowed(&mut self, slot: usize, on: bool) {
        if self.state.is_active(slot) {
            self.hard_ok[slot] = u8::from(on);
        }
    }

    pub fn set_merge_hold(&mut self, slot: usize, on: bool) {
        if self.state.is_active(slot) {
            self.hold[slot] = u8::from(on && (self.state.flags[slot] & FLAG_SCRIPTED) != 0);
        }
    }

    pub fn set_hazards(&mut self, slot: usize, on: bool) {
        if self.state.is_active(slot) && (self.state.flags[slot] & FLAG_HIT) == 0 {
            self.state.set_flag(slot, FLAG_HAZARD, on);
        }
    }

    pub fn release_scripted(&mut self, slot: usize, v0: f64) {
        if !self.state.is_active(slot) {
            return;
        }
        self.state.flags[slot] &= !FLAG_SCRIPTED;
        self.state.v0[slot] = v0;
        self.hard_ok[slot] = 0;
        self.hold[slot] = 0;
        self.mobil_t[slot] = self.cooldown;
    }

    // ------------------------------------------------------------ Lane closures (WP6.2)

    /// Adds a closure of `lane` over [s0, s1] (`add_lane_closure`). `zone_m` > 0: its
    /// merge zone (default merge_zone_m); `base`: the merge urgency where that zone
    /// starts. False when MAX_LANE_CLOSURES are live.
    pub fn add_lane_closure(
        &mut self,
        lane: i32,
        s0: f64,
        s1: f64,
        tag: i32,
        zone_m: f64,
        base: f64,
    ) -> bool {
        if self.cl_n >= MAX_LANE_CLOSURES {
            return false;
        }
        let c = self.cl_n;
        self.cl_lane[c] = lane;
        self.cl_s0[c] = s0;
        self.cl_s1[c] = s1;
        self.cl_tag[c] = tag;
        self.cl_zone[c] = if zone_m > 0.0 {
            zone_m
        } else {
            self.merge_zone
        };
        self.cl_base[c] = base;
        self.cl_n += 1;
        true
    }

    /// Removes every closure with this tag.
    pub fn remove_lane_closures(&mut self, tag: i32) {
        let mut w = 0;
        for c in 0..self.cl_n {
            if self.cl_tag[c] != tag {
                self.keep_closure(c, w);
                w += 1;
            }
        }
        self.cl_n = w;
    }

    pub fn lane_closure_count(&self) -> usize {
        self.cl_n
    }

    /// The road's lane-count changes become closures (`sync_road_closures`, once for
    /// the whole loop: its lane changes never move). A drop gets the long lane-drop
    /// merge zone and a harmonisation zone from its lane_ends sign (the road-space file
    /// has no signs: lane_drop_slow_zone_m before the taper, where loop_v1's stand) to
    /// lane_drop_slow_after_m past the lanes coming back (WP6.8).
    pub fn add_road_closures(&mut self) {
        for c in 0..self.road.lane_changes.len() {
            let f = self.road.lane_changes[c];
            let drop = f.after < f.before;
            for l in f.before.min(f.after)..f.before.max(f.after) {
                if drop {
                    self.add_lane_closure(
                        l,
                        f.s_start,
                        f.s_end,
                        ROAD_CLOSURE_TAG,
                        self.drop_zone,
                        self.drop_urg_min,
                    );
                } else {
                    self.add_lane_closure(l, f.s_start, f.s_end, ROAD_CLOSURE_TAG, 0.0, 0.0);
                }
            }
            if drop {
                let s0 = self.road.wrap(f.s_start - self.drop_slow);
                let s1 = self
                    .road
                    .wrap(self.lanes_back_s(f.s_end, f.before) + self.drop_after);
                self.add_lane_drop_zone(f.after, s0, s1);
            }
        }
    }

    /// Where the lanes a drop took away come back after it (`_lanes_back_s`): the end of
    /// the widening's taper back to `lanes` lanes within lane_drop_narrow_max_m, else
    /// `s_taper_end`.
    fn lanes_back_s(&self, s_taper_end: f64, lanes: i32) -> f64 {
        let mut best = f64::INFINITY;
        let mut out = s_taper_end;
        for c in 0..self.road.lane_changes.len() {
            let f = self.road.lane_changes[c];
            let ahead = self.road.signed_delta(s_taper_end, f.s_start);
            if ahead >= 0.0 && ahead <= self.drop_narrow_max && f.after >= lanes && ahead < best {
                best = ahead;
                out = s_taper_end + ahead + (f.s_end - f.s_start);
            }
        }
        out
    }

    /// Lane-drop harmonisation zone over [s0, s1] (`add_lane_drop_zone`): lanes below
    /// `first_lane` capped at lane_drop_through_kmh, from it on at lane_drop_merge_lane_kmh.
    pub fn add_lane_drop_zone(&mut self, first_lane: i32, s0: f64, s1: f64) -> bool {
        if self.dz_n >= MAX_DROP_ZONES {
            return false;
        }
        self.dz_lane[self.dz_n] = first_lane;
        self.dz_s0[self.dz_n] = s0;
        self.dz_s1[self.dz_n] = s1;
        self.dz_n += 1;
        true
    }

    pub fn lane_drop_zone_count(&self) -> usize {
        self.dz_n
    }

    pub fn lane_drop_zone_s0(&self, z: usize) -> f64 {
        self.dz_s0[z]
    }

    pub fn lane_drop_zone_s1(&self, z: usize) -> f64 {
        self.dz_s1[z]
    }

    /// The harmonised speed limit for profile p at `front` in `lane` (`lane_drop_limit_at`).
    pub fn lane_drop_limit_at(&self, lane: i32, front: f64, p: usize) -> f64 {
        let mut lim = f64::INFINITY;
        for z in 0..self.dz_n {
            if self.road.signed_delta(self.dz_s1[z], front) > 0.0 {
                continue;
            }
            let vz = if lane >= self.dz_lane[z] {
                self.drop_v_merge
            } else {
                self.drop_v_through
            };
            let ahead = self.road.signed_delta(front, self.dz_s0[z]);
            if ahead <= 0.0 {
                lim = minf(lim, vz);
            } else if ahead < self.drop_view {
                lim = minf(lim, (vz * vz + 2.0 * self.pb[p] * ahead).sqrt());
            }
        }
        lim
    }

    /// The fraction of its merge zone left before the next closure of `lane` ahead of s
    /// (0 at or inside it, >= 1 before its zone), INF with none (`merge_zone_frac`).
    pub fn merge_zone_frac(&self, lane: i32, s: f64) -> f64 {
        let mut best = f64::INFINITY;
        for c in 0..self.cl_n {
            if self.cl_lane[c] == lane && self.road.signed_delta(s, self.cl_s1[c]) >= 0.0 {
                best = minf(
                    best,
                    maxf(self.road.signed_delta(s, self.cl_s0[c]), 0.0) / self.cl_zone[c],
                );
            }
        }
        best
    }

    /// Distance from s to the start of the next closure of `lane` still ahead of s (0
    /// inside one), INF when none. MP: wrapped distances.
    pub fn closure_ahead(&self, lane: i32, s: f64) -> f64 {
        let mut best = f64::INFINITY;
        for c in 0..self.cl_n {
            if self.cl_lane[c] == lane && self.road.signed_delta(s, self.cl_s1[c]) >= 0.0 {
                best = minf(best, maxf(self.road.signed_delta(s, self.cl_s0[c]), 0.0));
            }
        }
        best
    }

    /// Lane t closes within its merge zone ahead of vehicle i's front.
    fn closes_soon(&self, t: i32, i: usize) -> bool {
        self.merge_zone_frac(t, self.ks[i] + self.khl[i]) < 1.0
    }

    fn keep_closure(&mut self, from: usize, to: usize) {
        self.cl_lane[to] = self.cl_lane[from];
        self.cl_s0[to] = self.cl_s0[from];
        self.cl_s1[to] = self.cl_s1[from];
        self.cl_tag[to] = self.cl_tag[from];
        self.cl_zone[to] = self.cl_zone[from];
        self.cl_base[to] = self.cl_base[from];
    }

    fn closure_wall_accel(&self, i: usize, vi: f64, v0: f64, p: usize) -> f64 {
        let cur = self.state.lane[i];
        if self.state.lc_state[i] == LC_MOVING && self.state.target_lane[i] != cur {
            return f64::INFINITY;
        }
        let dist = self.closure_ahead(cur, self.ks[i] + self.khl[i]);
        if dist > self.look {
            return f64::INFINITY;
        }
        idm::accel(
            vi,
            v0,
            maxf(dist - self.merge_stop, self.gap_floor),
            vi,
            self.pa[p],
            self.pb[p],
            self.pt[p],
            self.ps0[p],
            self.pdl[p],
            self.gap_floor,
        )
    }

    fn consider_merge(&mut self, i: usize) {
        if self.state.lc_state[i] != LC_NONE {
            return;
        }
        if self.split[i] != 0 {
            self.consider_split_exit(i);
            return;
        }
        let cur = self.state.lane[i];
        let base = self.cf_base[i];
        let urgency = base + (self.merge_urg - base) * clampf(1.0 - self.cf_own[i], 0.0, 1.0);
        // WP6.8: a road drop is left on the car's own advantage plus the urgency.
        let own = base > 0.0;
        let gl = self.eval_target(i, cur - 1, true, own) + urgency;
        let gr = self.eval_target(i, cur + 1, true, own) + urgency;
        let mut t = -1;
        if gl > 0.0 && gl >= gr {
            t = cur - 1;
        } else if gr > 0.0 {
            t = cur + 1;
        }
        if t < 0 {
            return;
        }
        self.start_signal(i, t, self.lane_d(t), 0);
        self.will_cancel[i] = 0;
        self.stat_merges += 1;
    }

    // ------------------------------------------------------------ Set-piece zones (WP6.3)

    #[allow(clippy::too_many_arguments)]
    pub fn add_speed_zone(
        &mut self,
        lane: i32,
        s0: f64,
        s1: f64,
        v_max: f64,
        tag: i32,
        keep_after_m: f64,
        keep_v: f64,
    ) -> bool {
        if self.sz_n >= MAX_SPEED_ZONES {
            return false;
        }
        let z = self.sz_n;
        self.sz_lane[z] = lane;
        self.sz_s0[z] = s0;
        self.sz_s1[z] = s1;
        self.sz_v[z] = v_max;
        self.sz_tag[z] = tag;
        self.sz_keep_s1[z] = s1 + keep_after_m;
        self.sz_keep_v[z] = keep_v;
        self.sz_n += 1;
        true
    }

    pub fn kept_by_zone(&self, i: usize) -> bool {
        let si = self.ks[i];
        let lane = self.state.lane[i];
        for z in 0..self.sz_n {
            if self.sz_lane[z] == lane
                && self.kv[i] < self.sz_keep_v[z]
                && self.road.signed_delta(si, self.sz_keep_s1[z]) >= 0.0
                && self.road.signed_delta(si, self.sz_s0[z]) < self.look
            {
                return true;
            }
        }
        false
    }

    pub fn add_headway_zone(&mut self, s0: f64, s1: f64, scale: f64, tag: i32) -> bool {
        if self.hz_n >= MAX_HEADWAY_ZONES {
            return false;
        }
        let z = self.hz_n;
        self.hz_s0[z] = s0;
        self.hz_s1[z] = s1;
        self.hz_k[z] = scale;
        self.hz_tag[z] = tag;
        self.hz_n += 1;
        true
    }

    pub fn remove_zones(&mut self, tag: i32) {
        let mut w = 0;
        for z in 0..self.sz_n {
            if self.sz_tag[z] != tag {
                self.sz_lane[w] = self.sz_lane[z];
                self.sz_s0[w] = self.sz_s0[z];
                self.sz_s1[w] = self.sz_s1[z];
                self.sz_v[w] = self.sz_v[z];
                self.sz_tag[w] = self.sz_tag[z];
                self.sz_keep_s1[w] = self.sz_keep_s1[z];
                self.sz_keep_v[w] = self.sz_keep_v[z];
                w += 1;
            }
        }
        self.sz_n = w;
        w = 0;
        for z in 0..self.hz_n {
            if self.hz_tag[z] != tag {
                self.hz_s0[w] = self.hz_s0[z];
                self.hz_s1[w] = self.hz_s1[z];
                self.hz_k[w] = self.hz_k[z];
                self.hz_tag[w] = self.hz_tag[z];
                w += 1;
            }
        }
        self.hz_n = w;
    }

    pub fn speed_limit_at(&self, lane: i32, front: f64, p: usize) -> f64 {
        let mut lim = f64::INFINITY;
        for z in 0..self.sz_n {
            if self.sz_lane[z] != lane || self.road.signed_delta(front, self.sz_s1[z]) < 0.0 {
                continue;
            }
            let ahead = self.road.signed_delta(front, self.sz_s0[z]);
            if ahead <= 0.0 {
                lim = minf(lim, self.sz_v[z]);
            } else if ahead < self.look {
                lim = minf(
                    lim,
                    (self.sz_v[z] * self.sz_v[z] + 2.0 * self.pb[p] * ahead).sqrt(),
                );
            }
        }
        lim
    }

    pub fn headway_scale_at(&self, s: f64) -> f64 {
        let mut k = 1.0;
        for z in 0..self.hz_n {
            if self.road.signed_delta(self.hz_s0[z], s) >= 0.0
                && self.road.signed_delta(s, self.hz_s1[z]) >= 0.0
            {
                k = minf(k, self.hz_k[z]);
            }
        }
        k
    }

    /// Set-piece speed zones and lane-drop zones alike, for vehicle i in `lane`
    /// (`_speed_zone_accel`).
    fn speed_zone_accel(&self, lane: i32, i: usize, vi: f64, v0: f64, p: usize) -> f64 {
        let front = self.ks[i] + self.khl[i];
        let mut a = if self.sz_n > 0 {
            self.set_zone_accel(lane, front, vi, v0, p)
        } else {
            f64::INFINITY
        };
        if self.dz_n == 0 || !self.in_dz_reach(front) {
            return a;
        }
        let lim = self.lane_drop_limit_at(lane, front, p);
        if lim < v0 {
            a = minf(a, idm::free_accel(vi, lim, self.pa[p], self.pdl[p]));
        }
        for z in 0..self.dz_n {
            let vz = if lane >= self.dz_lane[z] {
                self.drop_v_merge
            } else {
                self.drop_v_through
            };
            if vi > vz && self.road.signed_delta(front, self.dz_s1[z]) >= 0.0 {
                a = minf(
                    a,
                    self.drop_brake(self.road.signed_delta(front, self.dz_s0[z]), vz, vi, p),
                );
            }
        }
        a
    }

    /// The set-piece speed zones' part of speed_zone_accel (WP6.3).
    fn set_zone_accel(&self, lane: i32, front: f64, vi: f64, v0: f64, p: usize) -> f64 {
        let lim = self.speed_limit_at(lane, front, p);
        if lim >= v0 {
            return f64::INFINITY;
        }
        let mut a = idm::free_accel(vi, lim, self.pa[p], self.pdl[p]);
        for z in 0..self.sz_n {
            if self.sz_lane[z] != lane || vi <= self.sz_v[z] {
                continue;
            }
            let ahead = self.road.signed_delta(front, self.sz_s0[z]);
            if ahead > 0.0 && ahead < self.look {
                a = minf(a, (self.sz_v[z] * self.sz_v[z] - vi * vi) / (2.0 * ahead));
            }
        }
        a
    }

    /// Lane-drop zones (WP6.8): the constant deceleration that brings a vehicle at vi down
    /// to vz `ahead` metres on, eased in, never more than b (`_drop_brake`).
    fn drop_brake(&self, ahead: f64, vz: f64, vi: f64, p: usize) -> f64 {
        if ahead <= 0.0 || ahead >= self.drop_view {
            return f64::INFINITY;
        }
        let req = (vz * vz - vi * vi) / (2.0 * ahead);
        maxf(
            req * clampf(
                (-req / self.pb[p] - self.drop_onset) / (1.0 - self.drop_onset),
                0.0,
                1.0,
            ),
            -self.pb[p],
        )
    }

    /// WP6.8, once per model tick of vehicle i (`_drop_tick`): caches its merge-zone
    /// fractions, own closure's base urgency and distance and the speed-matching factor;
    /// returns (the drop zones' acceleration limit, the matched desired speed).
    fn drop_tick(&mut self, i: usize, front: f64, vi: f64, v0: f64, p: usize) -> (f64, f64) {
        let mut own = f64::INFINITY;
        let mut left = f64::INFINITY;
        let mut right = f64::INFINITY;
        let mut base = 0.0;
        let mut dist = f64::INFINITY;
        let lane = self.state.lane[i];
        if self.cl_n > 0 && self.in_cl_reach(front) {
            for c in 0..self.cl_n {
                if self.road.signed_delta(front, self.cl_s1[c]) < 0.0 {
                    continue;
                }
                let dl = self.cl_lane[c] - lane;
                if !(-1..=1).contains(&dl) {
                    continue;
                }
                let d = maxf(self.road.signed_delta(front, self.cl_s0[c]), 0.0);
                let u = d / self.cl_zone[c];
                if dl == 0 {
                    if u < own {
                        own = u;
                        base = self.cl_base[c];
                        dist = d;
                    }
                } else if dl < 0 {
                    left = minf(left, u);
                } else {
                    right = minf(right, u);
                }
            }
        }
        self.cf_own[i] = own;
        self.cf_left[i] = left;
        self.cf_right[i] = right;
        self.cf_base[i] = base;
        self.cf_dist[i] = dist;
        let mut m = if own < 1.0 && base > 0.0 { 1.0 } else { 0.0 };
        let mut acc = f64::INFINITY;
        let mut lim = f64::INFINITY;
        if self.dz_n > 0 && self.in_dz_reach(front) {
            for z in 0..self.dz_n {
                let s1z = self.dz_s1[z];
                let past = self.road.signed_delta(s1z, front);
                if past > 0.0 {
                    m = maxf(m, 1.0 - past / self.drop_release);
                    continue;
                }
                let vz = if lane >= self.dz_lane[z] {
                    self.drop_v_merge
                } else {
                    self.drop_v_through
                };
                let ahead = self.road.signed_delta(front, self.dz_s0[z]);
                if ahead <= 0.0 {
                    lim = minf(lim, vz);
                    m = 1.0;
                } else if ahead < self.drop_view {
                    lim = minf(lim, (vz * vz + 2.0 * self.pb[p] * ahead).sqrt());
                    if vi > vz {
                        acc = minf(acc, self.drop_brake(ahead, vz, vi, p));
                    }
                }
            }
        }
        if (self.state.flags[i] & FLAG_SCRIPTED) != 0 || self.split[i] != 0 {
            m = 0.0;
        }
        self.match_[i] = m;
        let v0e = if v0 < self.drop_v_merge {
            v0 + (self.drop_v_merge - v0) * m
        } else {
            v0
        };
        if lim < v0e {
            acc = minf(acc, idm::free_accel(vi, lim, self.pa[p], self.pdl[p]));
        }
        (acc, v0e)
    }

    fn clear_drop_cache(&mut self, i: usize) {
        self.cf_own[i] = f64::INFINITY;
        self.cf_left[i] = f64::INFINITY;
        self.cf_right[i] = f64::INFINITY;
        self.cf_base[i] = 0.0;
        self.cf_dist[i] = f64::INFINITY;
        self.match_[i] = 0.0;
    }

    /// This step's reach of the closures and drop zones (`_update_drop_reach`). On a
    /// loop every vehicle is in reach (an equivalent shortcut-free path: out of reach,
    /// drop_tick computes what clear_drop_cache sets).
    fn update_drop_reach(&mut self) {
        self.cl_lo = f64::INFINITY;
        self.cl_hi = f64::NEG_INFINITY;
        for c in 0..self.cl_n {
            self.cl_lo = minf(self.cl_lo, self.cl_s0[c] - self.cl_zone[c]);
            self.cl_hi = maxf(self.cl_hi, self.cl_s1[c]);
        }
        self.dz_lo = f64::INFINITY;
        self.dz_hi = f64::NEG_INFINITY;
        for z in 0..self.dz_n {
            self.dz_lo = minf(self.dz_lo, self.dz_s0[z] - self.drop_view);
            self.dz_hi = maxf(self.dz_hi, self.dz_s1[z] + self.drop_release);
        }
    }

    #[inline]
    fn in_cl_reach(&self, front: f64) -> bool {
        self.road.period() > 0.0 || (front > self.cl_lo && front <= self.cl_hi)
    }

    #[inline]
    fn in_dz_reach(&self, front: f64) -> bool {
        self.road.period() > 0.0 || (front > self.dz_lo && front < self.dz_hi)
    }

    /// Next order position ahead of `kk` (wrapping on a loop); None at an open road's end.
    #[inline]
    fn next_k(&self, kk: usize) -> Option<usize> {
        if kk + 1 < self.n {
            Some(kk + 1)
        } else if self.road.period() > 0.0 && self.n > 0 {
            Some(0)
        } else {
            None
        }
    }

    /// Previous order position (wrapping on a loop); None at an open road's start.
    #[inline]
    fn prev_k(&self, kk: usize) -> Option<usize> {
        if kk > 0 {
            Some(kk - 1)
        } else if self.road.period() > 0.0 && self.n > 0 {
            Some(self.n - 1)
        } else {
            None
        }
    }

    /// WP6.8 zipper, the through lane (`_yield_accel`): vehicle i (rank k) beside a lane
    /// that closes within its merge zone eases off for the nearest car still in that
    /// lane ahead of it. INF: no yield.
    #[allow(clippy::too_many_arguments)]
    fn yield_accel(&self, i: usize, k: usize, vi: f64, v0: f64, p: usize, hw_t: f64) -> f64 {
        if self.cand_n == 0 || self.state.lc_state[i] == LC_MOVING || self.cf_own[i] < 1.0 {
            return f64::INFINITY;
        }
        let cur = self.state.lane[i];
        let si = self.ks[i];
        // Candidates are in road order: those ranked after i first, then (on a loop) the
        // ones past the seam.
        let first = self.cand[..self.cand_n].partition_point(|&j| self.rank[j] <= k);
        let wrap = self.road.period() > 0.0;
        let total = if wrap {
            self.cand_n
        } else {
            self.cand_n - first
        };
        for x in 0..total {
            let c = (first + x) % self.cand_n;
            let j = self.cand[c];
            if j == i {
                break;
            }
            let ahead = self.road.signed_delta(si, self.ks[j]);
            if ahead > self.yield_range || ahead < 0.0 {
                break;
            }
            if (self.state.lane[j] - cur).abs() != 1
                || (self.state.lc_state[j] == LC_SIGNALING && self.state.target_lane[j] != cur)
            {
                continue;
            }
            let gap = ahead - self.khl[j] - self.khl[i];
            let dv = vi - self.kv[j];
            let soft = minf(self.yield_decel, self.pb[p]);
            if dv > 0.0 && (gap <= self.ps0[p] || dv * dv > 2.0 * soft * (gap - self.ps0[p])) {
                return f64::INFINITY;
            }
            let ay = idm::accel(
                vi,
                v0,
                gap,
                dv,
                self.pa[p],
                self.pb[p],
                hw_t,
                self.ps0[p],
                self.pdl[p],
                self.gap_floor,
            );
            return maxf(ay, -soft);
        }
        f64::INFINITY
    }

    /// WP6.8: booth traffic of a set-piece slow zone keeps its lane (`_zone_held`).
    fn zone_held(&self, i: usize) -> bool {
        self.sz_n > 0
            && self.kv[i] < self.drop_floor
            && self.cf_dist[i] > self.drop_floor_until
            && self.kept_by_zone(i)
    }

    /// WP6.8: this step's zipper candidates, in road order (`_collect_yield_candidates`).
    fn collect_yield_candidates(&mut self) {
        for k in 0..self.n {
            let j = self.ord[k];
            if self.is_player(j)
                || self.cf_own[j] >= self.yield_frac
                || self.state.lc_state[j] == LC_MOVING
                || self.hold[j] == 1
                || self.split[j] != 0
                || (self.state.flags[j] & FLAG_HIT) != 0
                || self.zone_held(j)
            {
                continue;
            }
            self.cand[self.cand_n] = j;
            self.cand_n += 1;
        }
    }

    /// WP6.8 zipper, the merging side (`_merge_gap_accel`): a car still in a dropping lane
    /// lines up behind the nearest vehicle ahead of it in the lane it merges into and
    /// drops back behind one beside it that is at least as fast. INF: nothing to do.
    #[allow(clippy::too_many_arguments)]
    fn merge_gap_accel(&self, i: usize, k: usize, vi: f64, v0: f64, p: usize, hw_t: f64) -> f64 {
        let st = self.state.lc_state[i];
        if st == LC_MOVING
            || self.cf_own[i] >= self.yield_frac
            || self.cf_base[i] <= 0.0
            || (vi <= self.drop_floor && self.cf_dist[i] > self.drop_floor_until)
            || self.zone_held(i)
        {
            return f64::INFINITY;
        }
        let cur = self.state.lane[i];
        let mut t = self.state.target_lane[i];
        if st != LC_SIGNALING {
            t = cur - 1;
            if t < 0 || self.cf_left[i] < 1.0 {
                t = cur + 1;
                if t >= self.road.lane_count(self.ks[i]) || self.cf_right[i] < 1.0 {
                    return f64::INFINITY;
                }
            }
        }
        let tc = self.lane_d(t);
        let half = self.lw * 0.5;
        let si = self.ks[i];
        let soft = minf(self.yield_decel, self.pb[p]);
        let mut left = self.n.saturating_sub(1);
        let mut kb = self.prev_k(k);
        while let Some(x) = kb {
            if left == 0 {
                break;
            }
            left -= 1;
            let j = self.ord[x];
            kb = self.prev_k(x);
            if self.road.signed_delta(self.ks[j], si) >= self.khl[i] + self.khl[j] {
                break;
            }
            if self.klo[j] < tc + half && self.khi[j] > tc - half && self.kv[j] >= vi {
                return -soft;
            }
        }
        let mut left = self.n.saturating_sub(1);
        let mut kk = self.next_k(k);
        while let Some(x) = kk {
            if left == 0 {
                break;
            }
            left -= 1;
            let j = self.ord[x];
            kk = self.next_k(x);
            let ahead = self.road.signed_delta(si, self.ks[j]);
            if ahead > self.yield_range {
                break;
            }
            if self.klo[j] < tc + half && self.khi[j] > tc - half {
                let gap = ahead - self.khl[j] - self.khl[i];
                if gap <= 0.0 && self.kv[j] < vi {
                    continue;
                }
                let ay = idm::accel(
                    vi,
                    v0,
                    gap,
                    vi - self.kv[j],
                    self.pa[p],
                    self.pb[p],
                    hw_t,
                    self.ps0[p],
                    self.pdl[p],
                    self.gap_floor,
                );
                return maxf(ay, -soft);
            }
        }
        f64::INFINITY
    }

    // ------------------------------------------------------------ Tick

    /// Advances traffic by dt (`TrafficSim.step`): players are read (and extrapolated to
    /// `tick`), every vehicle integrates, then the due vehicles run their model.
    /// Events of this step are appended to `events` (the caller clears it).
    pub fn step(&mut self, dt: f64, tick: u32) {
        self.tick = tick;
        if self.n_pending > 0 {
            self.emit_pending();
        }
        self.wclock += dt; // WP6.9: the lane-change cap's clock
        self.read_players(dt);
        let ref_s = self.reference_s();
        self.edge = self.road.lanes_left_edge_d(ref_s);
        self.lw = self.road.lane_width(ref_s);
        let period = self.road.period();
        // 1. Schedule (near / far) and integrate every vehicle over dt.
        let mut vmax = 0.0;
        for k in 0..self.n {
            let i = self.ord[k];
            if self.is_player(i) {
                continue;
            }
            let far = self.dist_to_players(i) > self.near_r;
            let f = self.state.flags[i];
            let nf = if far { f | FLAG_FAR } else { f & !FLAG_FAR };
            if nf != f {
                self.state.flags[i] = nf;
            }
            let mut due = 1;
            if far {
                self.acc_t[i] += dt;
                self.acc_n[i] += 1;
                if self.acc_n[i] >= self.far_ratio {
                    self.mdt[i] = self.acc_t[i];
                    self.acc_t[i] = 0.0;
                    self.acc_n[i] = 0;
                } else {
                    due = 0;
                }
            } else {
                self.mdt[i] = dt + self.acc_t[i];
                self.acc_t[i] = 0.0;
                self.acc_n[i] = 0;
            }
            self.due[i] = due;
            let a = self.state.accel[i];
            let v = self.kv[i];
            let mut s = self.ks[i];
            let s_before = s;
            let mut nv = v + a * dt;
            if nv < 0.0 {
                if a < 0.0 {
                    s -= v * v / (2.0 * a);
                }
                nv = 0.0;
            } else {
                s += (v + nv) * 0.5 * dt;
            }
            self.ds_last[i] = s - s_before;
            if period > 0.0 && s >= period {
                s -= period;
            }
            self.ks[i] = s;
            self.kv[i] = nv;
            self.state.s[i] = s;
            self.state.v[i] = nv;
            vmax = maxf(vmax, nv);
            if due == 0 {
                let vl = self.state.v_lat[i];
                if vl != 0.0 {
                    self.state.d[i] += vl * dt;
                    self.refresh_interval(i);
                }
            }
        }
        self.vmax = vmax;
        if self.cl_n > 0 || self.dz_n > 0 {
            self.update_drop_reach();
        }
        self.sort();
        // 2. Model accelerations of the due vehicles, everyone at the same instant.
        self.cand_n = 0;
        if self.cl_n > 0 {
            self.collect_yield_candidates();
        }
        for k in 0..self.n {
            let i = self.ord[k];
            if !self.is_player(i) && self.due[i] == 1 {
                self.step_accel(i, k);
            }
        }
        // 3. Lane changes, hit recovery, reactions.
        for k in 0..self.n {
            let i = self.ord[k];
            if !self.is_player(i) && self.due[i] == 1 {
                self.step_lateral(i);
            }
        }
        // MP: vehicles that finished moving into an off-ramp leave.
        for x in 0..self.exited.len() {
            let i = self.exited[x];
            self.stat_exits += 1;
            self.despawn_tagged(i, EventTag::Exit);
        }
        self.exited.clear();
    }

    /// The s the lane geometry is read at (GDScript: the player's).
    fn reference_s(&self) -> f64 {
        for p in 0..self.np {
            if self.p_on[p] == 1 {
                return self.pl_s[p];
            }
        }
        0.0
    }

    /// Distance to the nearest player (INF with none).
    fn dist_to_players(&self, i: usize) -> f64 {
        let mut best = f64::INFINITY;
        for p in 0..self.np {
            if self.p_on[p] == 1 {
                best = minf(best, self.road.signed_delta(self.pl_s[p], self.ks[i]).abs());
            }
        }
        best
    }

    // ------------------------------------------------------------ Model: acceleration

    fn step_accel(&mut self, i: usize, k: usize) {
        let si = self.ks[i];
        let vi = self.kv[i];
        let mut v0 = self.state.v0[i];
        let mut margin = self.lat_m;
        if self.split[i] != 0 {
            v0 = minf(v0, self.split_v0);
            margin = self.split_clear;
        }
        let p = self.state.profile_id[i] as usize;
        let front = si + self.khl[i];
        let mut drop_a = f64::INFINITY;
        if self.cl_n > 0 || self.dz_n > 0 {
            if (self.cl_n > 0 && self.in_cl_reach(front))
                || (self.dz_n > 0 && self.in_dz_reach(front))
            {
                // WP6.8: closures, drop zones, speed matching.
                let (acc, v0e) = self.drop_tick(i, front, vi, v0, p);
                drop_a = acc;
                v0 = v0e;
            } else if self.match_[i] != 0.0
                || self.cf_own[i] != f64::INFINITY
                || self.cf_left[i] != f64::INFINITY
                || self.cf_right[i] != f64::INFINITY
            {
                self.clear_drop_cache(i);
            }
        }
        let lo = self.klo[i] - margin;
        let hi = self.khi[i] + margin;
        let mut lead = NONE;
        let mut left = self.n.saturating_sub(1);
        let mut kk = self.next_k(k);
        while let Some(x) = kk {
            if left == 0 {
                break;
            }
            left -= 1;
            let j = self.ord[x];
            if self.road.signed_delta(si, self.ks[j]) > self.look {
                break;
            }
            if self.klo[j] < hi && self.khi[j] > lo {
                lead = j as i64;
                break;
            }
            kk = self.next_k(x);
        }
        let lead_k = kk;
        let mut a: f64;
        let mut gap = f64::INFINITY;
        let hw_t = if self.hz_n == 0 {
            self.pt[p]
        } else {
            self.pt[p] * self.headway_scale_at(si)
        };
        if lead >= 0 {
            let l = lead as usize;
            gap = self.road.signed_delta(si, self.ks[l]) - self.khl[l] - self.khl[i];
            a = if self.pweave[p] == 1 && !self.is_player(l) {
                // WP6.9: a weaving profile behind a traffic car (never behind a player).
                idm::accel(
                    vi,
                    v0,
                    gap,
                    vi - self.kv[l],
                    self.pa[p],
                    self.wb[p],
                    hw_t * self.w_tk[p],
                    self.ws0[p],
                    self.pdl[p],
                    self.gap_floor,
                )
            } else {
                idm::accel(
                    vi,
                    v0,
                    gap,
                    vi - self.kv[l],
                    self.pa[p],
                    self.pb[p],
                    hw_t,
                    self.ps0[p],
                    self.pdl[p],
                    self.gap_floor,
                )
            };
        } else {
            a = idm::free_accel(vi, v0, self.pa[p], self.pdl[p]);
        }
        if self.config.look_through && lead >= 0 {
            // MP: past a leader leaving the path, the next one counts too.
            a = minf(
                a,
                self.look_through_accel(i, lead as usize, lead_k, lo, hi, false, vi, v0, p, hw_t),
            );
        }
        if self.config.anticipate_braking && lead >= 0 {
            a = minf(a, self.anticipation_accel(lead as usize, gap, vi, p));
        }
        if self.cl_n > 0 {
            a = minf(a, self.closure_wall_accel(i, vi, v0, p));
        }
        if self.sz_n > 0 {
            a = minf(a, self.set_zone_accel(self.state.lane[i], front, vi, v0, p));
        }
        a = minf(a, drop_a); // WP6.8 drop zones
        if self.cl_n > 0 && (self.state.flags[i] & (FLAG_SCRIPTED | FLAG_HIT)) == 0 {
            if self.cf_left[i] < 1.0 || self.cf_right[i] < 1.0 {
                a = minf(a, self.yield_accel(i, k, vi, v0, p, hw_t)); // WP6.8 zipper: through lane
            }
            if self.cf_own[i] < self.yield_frac {
                a = minf(a, self.merge_gap_accel(i, k, vi, v0, p, hw_t)); // WP6.8: merging car
            }
        }
        self.lead[i] = lead;
        self.lead_gap[i] = gap;
        self.a_raw[i] = a;
        self.stat_model_updates += 1;

        // Brake tap when a player cuts in less than cut_in_brake_tap_distance_m ahead.
        let mdt = self.mdt[i];
        let mut tap = self.tap_t[i];
        if tap > -self.react_cool {
            tap = maxf(tap - mdt, -self.react_cool);
        }
        let lead_p = lead >= 0 && self.is_player(lead as usize);
        if lead_p && self.prev_lead_p[i] != lead && gap < self.cut_in_m && tap <= -self.react_cool {
            tap = self.tap_s;
            self.push_event(EventKind::BrakeTap, EventTag::CutIn, i, gap);
        }
        self.tap_t[i] = tap;
        self.prev_lead_p[i] = if lead_p { lead } else { NONE };
        if tap > 0.0 {
            a = minf(a, -self.tap_decel);
        }
        let f = self.state.flags[i];
        if (f & FLAG_HIT) != 0 && self.hit_recover - self.state.react_timer[i] < self.hit_brake_s {
            a = minf(a, -self.hit_decel);
        }
        // Fairness rule 4: never beyond the clamp outside announced set pieces.
        let lim = if (f & FLAG_SCRIPTED) != 0 && self.hard_ok[i] == 1 {
            self.scripted_decel
        } else {
            self.max_decel
        };
        if a < -lim {
            a = -lim;
        }
        self.state.accel[i] = a;
        // Fairness rule 3: readable braking.
        let mut nf = f & !BRAKES;
        if a < -self.brake_decel {
            nf |= FLAG_BRAKE;
        }
        if a < -self.brake_strong {
            nf |= FLAG_BRAKE_STRONG;
        }
        if nf != f {
            self.state.flags[i] = nf;
        }
    }

    // ------------------------------------------------------------ Model: lateral

    fn step_lateral(&mut self, i: usize) {
        let mdt = self.mdt[i];
        let st = self.state.lc_state[i];
        let f = self.state.flags[i];
        if st == LC_SIGNALING {
            self.tick_signaling(i, mdt);
        } else if st == LC_MOVING {
            self.tick_moving(i, mdt);
        } else if (f & FLAG_HIT) == 0
            && self.cl_n > 0
            && self.hold[i] == 0
            && self.cf_own[i] < 1.0
            && !self.zone_held(i)
        {
            // Mandatory merge: every model tick within merge_zone_m of the closure, or a
            // MOBIL interval after a cancelled one; further out (a road drop's long zone,
            // WP6.8) at the profile's MOBIL interval.
            let p = self.state.profile_id[i] as usize;
            let mt = minf(self.mobil_t[i], self.peval[p]) - mdt;
            if mt <= 0.0 {
                self.mobil_t[i] = if self.cf_dist[i] < self.merge_zone {
                    0.0
                } else {
                    self.peval[p]
                };
                self.consider_merge(i);
            } else {
                self.mobil_t[i] = mt;
            }
        } else if (f & (FLAG_HIT | FLAG_SCRIPTED)) == 0 {
            let mt = self.mobil_t[i] - mdt;
            if mt <= 0.0 {
                let p = self.state.profile_id[i] as usize;
                self.mobil_t[i] = self.peval[p];
                if self.split[i] != 0 {
                    self.consider_split_exit(i);
                } else if self.sz_n > 0 && self.kept_by_zone(i) {
                    // WP6.3: slow zone traffic keeps its lane
                } else {
                    self.consider_lane_change(i);
                    if self.psplit[p] == 1 && self.state.lc_state[i] == LC_NONE {
                        self.consider_split(i);
                    }
                }
            } else {
                self.mobil_t[i] = mt;
            }
        }
        if (f & FLAG_HIT) != 0 {
            self.tick_hit(i, mdt);
        }
        if self.dist_to_players(i) < self.react_range {
            self.tick_reactions(i, mdt);
        }
        self.refresh_interval(i);
    }

    fn tick_signaling(&mut self, i: usize, mdt: f64) {
        let timer = self.state.lc_timer[i] + mdt;
        self.state.lc_timer[i] = timer;
        let ok = !self
            .eval_move(
                i,
                self.lc_target_d[i],
                self.state.target_lane[i],
                false,
                false,
            )
            .is_infinite();
        // Fairness rule 2: a player entered the target gap (or its predicted space).
        if !ok && self.q_player {
            self.cancel(i);
            self.stat_cancel_player += 1;
            return;
        }
        if timer < self.state.lc_duration[i] {
            return;
        }
        if self.will_cancel[i] == 1 {
            self.cancel(i);
            self.stat_cancel_hesitant += 1;
        } else if !ok {
            self.cancel(i);
            self.stat_cancel_unsafe += 1;
        } else {
            // Fairness rule 1: lateral motion only after the full signal time.
            let p = self.state.profile_id[i] as usize;
            self.state.lc_state[i] = LC_MOVING;
            self.state.lc_timer[i] = 0.0;
            self.state.lc_start_d[i] = self.state.d[i];
            if self.config.move_time_at_signal {
                self.state.lc_duration[i] = self.lc_move_dur[i];
            } else {
                let mn = self.pmmin[p];
                let mx = self.pmmax[p];
                self.state.lc_duration[i] = if mx <= mn {
                    mn
                } else {
                    self.rng_lc.float_range(mn, mx)
                };
            }
            self.lc_move_tick[i] = self.tick;
            self.stat_moves += 1;
        }
    }

    fn tick_moving(&mut self, i: usize, mdt: f64) {
        let dur = self.state.lc_duration[i];
        let tm = self.state.lc_timer[i] + mdt;
        self.state.lc_timer[i] = tm;
        let t = self.state.target_lane[i];
        let tc = self.lc_target_d[i];
        if tm >= dur {
            if self.state.d[i] != tc {
                // Last lateral step with the blinker still on; finish next model tick.
                self.state.d[i] = tc;
                self.state.v_lat[i] = 0.0;
                return;
            }
            self.state.lane[i] = t;
            self.state.d[i] = tc;
            self.state.v_lat[i] = 0.0;
            self.state.lc_state[i] = LC_NONE;
            self.state.lc_timer[i] = 0.0;
            self.state.lc_duration[i] = 0.0;
            self.state.flags[i] &= !BLINKERS;
            self.split[i] = self.lc_split[i];
            self.lc_split[i] = 0;
            self.mobil_t[i] = self.cooldown_of(i);
            self.stat_completed += 1;
            if self.exiting[i] == 1 {
                self.exited.push(i);
            }
            return;
        }
        let d0 = self.state.lc_start_d[i];
        let span = tc - d0;
        let u = tm / dur;
        self.state.d[i] = d0 + span * u * u * (SMOOTH_A - 2.0 * u);
        self.state.v_lat[i] = span * SMOOTH_D * u * (1.0 - u) / dur;
    }

    fn tick_hit(&mut self, i: usize, mdt: f64) {
        let mut rt = self.state.react_timer[i] - mdt;
        let dir = self.swerve_dir[i];
        if dir != 0.0 && self.state.lc_state[i] == LC_NONE {
            let elapsed = self.hit_recover - rt;
            if elapsed < self.hit_swerve_s && rt > 0.0 {
                // Out and back: smoothstep up over the first half, down over the second.
                let u = elapsed / self.hit_swerve_s;
                let mut x = 2.0 * u;
                let mut sgn = 1.0;
                if u > 0.5 {
                    x = 2.0 - x;
                    sgn = -1.0;
                }
                let off = self.hit_swerve_m * x * x * (SMOOTH_A - 2.0 * x);
                let rate = self.hit_swerve_m * SMOOTH_D * x * (1.0 - x) * 2.0 / self.hit_swerve_s;
                self.state.d[i] = self.swerve_base[i] + dir * off;
                self.state.v_lat[i] = dir * sgn * rate;
            } else {
                self.state.d[i] = self.swerve_base[i];
                self.state.v_lat[i] = 0.0;
                self.swerve_dir[i] = 0.0;
            }
        }
        if rt <= 0.0 {
            rt = 0.0;
            let mut f = self.state.flags[i] & !FLAG_HIT;
            if self.hit_hazard[i] == 1 {
                f &= !FLAG_HAZARD;
                self.hit_hazard[i] = 0;
                self.push_event(EventKind::Hazards, EventTag::Hit, i, 0.0);
            }
            self.state.flags[i] = f;
            self.mobil_t[i] = self.cooldown;
        }
        self.state.react_timer[i] = rt;
    }

    fn tick_reactions(&mut self, i: usize, mdt: f64) {
        // Blind spot: one lane over, a player's center up to blind_spot_behind_m behind
        // the car's. MP: any player.
        let mut bt = self.blind_t[i];
        if bt < 0.0 {
            bt = minf(bt + mdt, 0.0);
        } else if self.player_in_blind_spot(i) {
            bt += mdt;
            if bt >= self.blind_s {
                bt = -self.react_cool;
                if self.rng_react.chance(self.blind_frac) {
                    self.push_event(EventKind::Horn, EventTag::BlindSpot, i, 0.0);
                }
            }
        } else {
            bt = 0.0;
        }
        self.blind_t[i] = bt;
    }

    fn player_in_blind_spot(&self, i: usize) -> bool {
        for p in 0..self.np {
            if self.p_on[p] == 0 {
                continue;
            }
            let rel = self.road.signed_delta(self.pl_s[p], self.ks[i]);
            let same_path = self.klo[i] < self.pl_hi[p] && self.khi[i] > self.pl_lo[p];
            if !same_path
                && rel >= 0.0
                && rel <= self.blind_m
                && (self.pl_d[p] - self.state.d[i]).abs() < self.lw + self.lw * 0.5
            {
                return true;
            }
        }
        false
    }

    // ------------------------------------------------------------ Lane changes

    fn consider_lane_change(&mut self, i: usize) {
        let cur = self.state.lane[i];
        let mut gl = self.eval_target(i, cur - 1, true, false);
        let mut gr = self.eval_target(i, cur + 1, true, false);
        if self.pweave[self.state.profile_id[i] as usize] == 1 {
            // WP6.9: weaving racers look ahead (and keep to their lane-change cap).
            if !self.weave_cap_ok(i) {
                return;
            }
            gl += self.weave_bonus_of(i, cur - 1, cur);
            gr += self.weave_bonus_of(i, cur + 1, cur);
            if gl > 0.0 || gr > 0.0 {
                self.weave_note_change(i);
            }
        }
        if gl > 0.0 && gl >= gr {
            self.start_signal(i, cur - 1, self.lane_d(cur - 1), 0);
        } else if gr > 0.0 {
            self.start_signal(i, cur + 1, self.lane_d(cur + 1), 0);
        }
    }

    fn consider_split(&mut self, i: usize) {
        let ln = self.state.lane[i];
        if self.cl_n > 0
            && (self.closes_soon(ln, i)
                || self.closes_soon(ln - 1, i)
                || self.closes_soon(ln + 1, i))
        {
            return;
        }
        if self.sz_n > 0 && self.slow_zone_beside(i) {
            return;
        }
        let lead = self.lead[i];
        if lead < 0
            || self.is_player(lead as usize)
            || self.kv[lead as usize] >= self.split_max_v
            || self.lead_gap[i] > self.split_scan
            || self.state.v0[i] <= self.split_max_v
        {
            return;
        }
        if self.player_changing_lanes_near(i) {
            return;
        }
        let cur = self.state.lane[i];
        let half = self.lw * 0.5;
        if cur > 0
            && !self
                .eval_move(i, self.lane_d(cur) - half, cur, false, false)
                .is_infinite()
        {
            self.start_signal(i, cur, self.lane_d(cur) - half, -1);
        } else if cur < self.road.lane_count(self.ks[i]) - 1
            && !self
                .eval_move(i, self.lane_d(cur) + half, cur, false, false)
                .is_infinite()
        {
            self.start_signal(i, cur, self.lane_d(cur) + half, 1);
        }
    }

    /// "Never during the player's lane change": any player moving sideways nearby.
    fn player_changing_lanes_near(&self, i: usize) -> bool {
        for p in 0..self.np {
            if self.p_on[p] == 1
                && self.pl_vl[p].abs() > self.split_player_lat
                && self.road.signed_delta(self.pl_s[p], self.ks[i]).abs() < self.split_player_range
            {
                return true;
            }
        }
        false
    }

    fn slow_zone_beside(&self, i: usize) -> bool {
        let front = self.ks[i] + self.khl[i];
        let cur = self.state.lane[i];
        for z in 0..self.sz_n {
            if (self.sz_lane[z] - cur).abs() <= 1
                && self.road.signed_delta(front, self.sz_s1[z]) >= 0.0
                && self.road.signed_delta(front, self.sz_s0[z]) < self.look
            {
                return true;
            }
        }
        false
    }

    fn consider_split_exit(&mut self, i: usize) {
        let si = self.ks[i];
        let di = self.state.d[i];
        let mut kk = self.rank[i] + 1;
        let mut steps = 1;
        if self.sz_n > 0 && self.slow_zone_beside(i) {
            steps = self.n;
        }
        while steps < self.n {
            if kk == self.n {
                if self.road.period() <= 0.0 {
                    break;
                }
                kk = 0;
            }
            let j = self.ord[kk];
            if self.road.signed_delta(si, self.ks[j]) > self.split_scan {
                break;
            }
            if !self.is_player(j)
                && self.kv[j] < self.split_max_v
                && (self.state.d[j] - di).abs() < self.lw
            {
                return;
            }
            kk += 1;
            steps += 1;
        }
        let cur = self.state.lane[i];
        let other = cur + self.split[i];
        if !self
            .eval_move(i, self.lane_d(cur), cur, false, false)
            .is_infinite()
        {
            self.start_signal(i, cur, self.lane_d(cur), 0);
        } else if !self
            .eval_move(i, self.lane_d(other), other, false, false)
            .is_infinite()
        {
            self.start_signal(i, other, self.lane_d(other), 0);
        }
    }

    /// Starts the blinker for a lateral move to target_d (lane t; `split` = entering a
    /// lane split on that side, else 0). MP: emits the `Signal` intent.
    fn start_signal(&mut self, i: usize, t: i32, target_d: f64, split: i32) {
        let p = self.state.profile_id[i] as usize;
        self.state.lc_state[i] = LC_SIGNALING;
        self.state.target_lane[i] = t;
        self.state.lc_timer[i] = 0.0;
        self.state.lc_duration[i] = self.psig[p];
        self.lc_target_d[i] = target_d;
        self.lc_split[i] = split;
        self.split[i] = 0;
        let mut f = self.state.flags[i] & !BLINKERS;
        f |= if target_d < self.state.d[i] {
            FLAG_BLINKER_LEFT
        } else {
            FLAG_BLINKER_RIGHT
        };
        self.state.flags[i] = f;
        let pc = self.pcancel[p];
        self.will_cancel[i] = 0;
        if pc > 0.0 {
            self.stat_hesitant_signals += 1;
            if self.rng_lc.chance(pc) {
                self.will_cancel[i] = 1;
            }
        }
        self.stat_signals += 1;
        self.refresh_interval(i);
        // MP: the intent. The move starts at the model tick the signal timer reaches
        // the signal time (the same float accumulation as tick_signaling, every tick due).
        let mut move_dur = f64::NAN;
        if self.config.move_time_at_signal {
            let mn = self.pmmin[p];
            let mx = self.pmmax[p];
            move_dur = if mx <= mn {
                mn
            } else {
                self.rng_lc.float_range(mn, mx)
            };
            move_dur = (move_dur * MOVE_TIME_STEPS_PER_S).round() / MOVE_TIME_STEPS_PER_S;
            self.lc_move_dur[i] = move_dur;
        }
        let sig = self.state.lc_duration[i];
        let mut timer = 0.0;
        let mut ticks: u32 = 0;
        while timer < sig && ticks < MOVE_TICKS_MAX {
            timer += self.config.tick_dt;
            ticks += 1;
        }
        self.lc_signal_tick[i] = self.tick;
        self.lc_move_tick[i] = self.tick.wrapping_add(ticks);
        let e = SimEvent {
            kind: EventKind::Signal,
            tag: if self.exiting[i] == 1 {
                EventTag::Exit
            } else {
                EventTag::None
            },
            slot: i as u32,
            vehicle_id: self.state.vehicle_id[i],
            tick: self.tick,
            value: 0.0,
            move_start_tick: self.lc_move_tick[i],
            target_lane: t,
            target_d,
            duration_s: move_dur,
        };
        self.events.push(e);
    }

    fn cancel(&mut self, i: usize) {
        self.state.lc_state[i] = LC_NONE;
        self.state.target_lane[i] = self.state.lane[i];
        self.state.lc_timer[i] = 0.0;
        self.state.lc_duration[i] = 0.0;
        self.state.flags[i] &= !BLINKERS;
        self.will_cancel[i] = 0;
        self.mobil_t[i] = self.cooldown_of(i);
        if self.lc_split[i] == 0
            && (self.state.d[i] - self.lane_d(self.state.lane[i])).abs() > self.lw * 0.5 * 0.5
        {
            // A cancelled return from a lane split keeps riding the boundary.
            self.split[i] = if self.state.d[i] > self.lane_d(self.state.lane[i]) {
                1
            } else {
                -1
            };
        }
        self.lc_split[i] = 0;
        self.refresh_interval(i);
        if self.exiting[i] == 1 {
            self.exiting[i] = 0;
            self.stat_exit_cancels += 1;
        }
        self.push_event(EventKind::Cancel, EventTag::None, i, 0.0);
    }

    /// MOBIL for a move of vehicle i into lane t (`_eval_target`): -INF when not allowed,
    /// else incentive minus threshold (> 0 = accept), or 0 without the incentive.
    /// `own_only` (a mandatory merge out of a road drop, WP6.8): the car's own advantage.
    fn eval_target(&mut self, i: usize, t: i32, with_incentive: bool, own_only: bool) -> f64 {
        self.q_player = false;
        let lanes = self.road.lane_count(self.ks[i]);
        if t < 0 || t >= lanes {
            return f64::NEG_INFINITY;
        }
        if self.cl_n > 0 && self.closes_soon(t, i) {
            return f64::NEG_INFINITY;
        }
        let krl = self.pkrl[self.state.profile_id[i] as usize];
        if krl > 0 && t < self.state.lane[i] && t < lanes - krl {
            return f64::NEG_INFINITY;
        }
        self.eval_move(i, self.lane_d(t), t, with_incentive, own_only)
    }

    /// Safety (and optionally MOBIL's incentive) of a lateral move of vehicle i to tc,
    /// ending in lane t (`_eval_move`). MP: no-ambush against every player.
    fn eval_move(
        &mut self,
        i: usize,
        tc: f64,
        t: i32,
        with_incentive: bool,
        own_only: bool,
    ) -> f64 {
        self.q_player = false;
        let si = self.ks[i];
        let cur = self.state.lane[i];
        let p = self.state.profile_id[i] as usize;
        let vi = self.kv[i];
        let wi = self.state.width[i];
        let hw = wi * 0.5;
        let lo = tc - hw - self.lat_m;
        let hi = tc + hw + self.lat_m;
        let k = self.rank[i];
        let periodic = self.road.period() > 0.0;
        // New leader and new follower in the target lane (claims count).
        let mut lead = NONE;
        let mut left = self.n.saturating_sub(1);
        let mut kk = self.next_k(k);
        while let Some(x) = kk {
            if left == 0 {
                break;
            }
            left -= 1;
            let j = self.ord[x];
            if self.road.signed_delta(si, self.ks[j]) > self.look {
                break;
            }
            if self.kclo[j] < hi && self.kchi[j] > lo {
                lead = j as i64;
                break;
            }
            kk = self.next_k(x);
        }
        let lead_k = kk;
        let mut foll = NONE;
        let mut foll_left = self.n.saturating_sub(1);
        let mut k_foll = self.prev_k(k);
        while let Some(x) = k_foll {
            if foll_left == 0 {
                k_foll = None;
                break;
            }
            foll_left -= 1;
            let j = self.ord[x];
            if self.road.signed_delta(self.ks[j], si) > self.look {
                break;
            }
            if self.kclo[j] < hi && self.kchi[j] > lo {
                foll = j as i64;
                break;
            }
            k_foll = self.prev_k(x);
        }
        let mut v0 = self.state.v0[i];
        if v0 < self.drop_v_merge && (self.cl_n > 0 || self.dz_n > 0) && self.split[i] == 0 {
            v0 += (self.drop_v_merge - v0) * self.match_[i]; // WP6.8: as in step_accel
        }
        // WP6.9: a weaving profile's b_safe toward traffic followers.
        let bsafe = if self.pweave[p] == 0 {
            self.pbsafe[p]
        } else {
            self.wbsafe[p]
        };
        let mut a_c_new: f64;
        if lead >= 0 {
            let l = lead as usize;
            let gl = self.road.signed_delta(si, self.ks[l]) - self.khl[l] - self.khl[i];
            if gl <= 0.0 {
                self.q_player = self.is_player(l);
                return f64::NEG_INFINITY;
            }
            a_c_new = if self.pweave[p] == 1 && !self.is_player(l) {
                // WP6.9: its IDM toward traffic.
                idm::accel(
                    vi,
                    v0,
                    gl,
                    vi - self.kv[l],
                    self.pa[p],
                    self.wb[p],
                    self.pt[p] * self.w_tk[p],
                    self.ws0[p],
                    self.pdl[p],
                    self.gap_floor,
                )
            } else {
                idm::accel(
                    vi,
                    v0,
                    gl,
                    vi - self.kv[l],
                    self.pa[p],
                    self.pb[p],
                    self.pt[p],
                    self.ps0[p],
                    self.pdl[p],
                    self.gap_floor,
                )
            };
            let own_bsafe = if self.is_player(l) {
                self.pbsafe[p]
            } else {
                bsafe
            };
            if a_c_new < -own_bsafe {
                self.q_player = self.is_player(l);
                return f64::NEG_INFINITY;
            }
            if self.config.look_through {
                // MP: a new leader leaving the target lane hides nothing.
                let a2 = self.look_through_accel(i, l, lead_k, lo, hi, true, vi, v0, p, self.pt[p]);
                if a2 < -bsafe {
                    return f64::NEG_INFINITY;
                }
                a_c_new = minf(a_c_new, a2);
            }
            if self.config.predict_leaders
                && !self.predicted_leaders_safe(i, l, lead_k, lo, hi, vi, v0, p, bsafe)
            {
                self.q_player = self.is_player(l);
                return f64::NEG_INFINITY;
            }
        } else {
            a_c_new = idm::free_accel(vi, v0, self.pa[p], self.pdl[p]);
        }
        if self.sz_n > 0 || self.dz_n > 0 {
            a_c_new = minf(a_c_new, self.speed_zone_accel(t, i, vi, v0, p));
        }
        let mut a_n_new = 0.0;
        if foll >= 0 {
            let fo = foll as usize;
            let gf = self.road.signed_delta(self.ks[fo], si) - self.khl[i] - self.khl[fo];
            if gf <= 0.0 {
                self.q_player = self.is_player(fo);
                return f64::NEG_INFINITY;
            }
            a_n_new = self.follower_accel(fo, gf, self.kv[fo] - vi);
            let b = mobil::b_safe_for(bsafe, self.is_player(fo), self.player_b_safe);
            if !mobil::is_safe(a_n_new, b) {
                self.q_player = self.is_player(fo);
                return f64::NEG_INFINITY;
            }
            // WP6.8: every faster vehicle behind it on the target path that would reach the
            // gap within mobil_follower_horizon_s must be safe too, when the new follower
            // does not shield the lane (a splitting bike, a lane changer, a player).
            let reach = (maxf(self.vmax, self.fastest_player()) - vi) * self.foll_horizon;
            let mut kb = k_foll.and_then(|x| self.prev_k(x));
            if !self.is_player(fo) && self.split[fo] == 0 && self.state.lc_state[fo] == LC_NONE {
                kb = None;
            }
            let mut left = foll_left;
            while let Some(x) = kb {
                if left == 0 {
                    break;
                }
                left -= 1;
                let j = self.ord[x];
                kb = self.prev_k(x);
                let behind = self.road.signed_delta(self.ks[j], si);
                let gj = behind - self.khl[i] - self.khl[j];
                if gj > reach || behind > self.look {
                    break;
                }
                let vj = self.kv[j];
                if vj <= vi
                    || gj > (vj - vi) * self.foll_horizon
                    || !(self.kclo[j] < hi && self.kchi[j] > lo)
                {
                    continue;
                }
                let bj = mobil::b_safe_for(bsafe, self.is_player(j), self.player_b_safe);
                if !mobil::is_safe(self.follower_accel(j, gj, vj - vi), bj) {
                    self.q_player = self.is_player(j);
                    return f64::NEG_INFINITY;
                }
            }
        }
        // Fairness rule 2: no ambush (MP: against every player's predicted position).
        for pp in 0..self.np {
            if self.p_on[pp] == 0 {
                continue;
            }
            // On a loop the car is the origin and the player sits at its wrapped offset;
            // on the open road the absolute positions (bit-identical to GDScript).
            let (car_s, p_s) = if periodic {
                (0.0, self.road.signed_delta(si, self.pl_s[pp]))
            } else {
                (si, self.pl_s[pp])
            };
            if no_ambush::violates(
                car_s,
                vi,
                self.state.length[i],
                wi,
                tc,
                p_s,
                self.pl_v[pp],
                self.pl_d[pp],
                self.pl_vl[pp],
                self.pl_len[pp],
                self.pl_w[pp],
                self.window,
                self.margin,
            ) {
                self.q_player = true;
                return f64::NEG_INFINITY;
            }
        }
        if !with_incentive {
            return 0.0;
        }
        if own_only {
            return a_c_new - self.a_raw[i];
        }
        let mut a_n = 0.0;
        if foll >= 0 {
            let fo = foll as usize;
            if lead >= 0 {
                let l = lead as usize;
                a_n = self.follower_accel_lp(
                    fo,
                    self.road.signed_delta(self.ks[fo], self.ks[l]) - self.khl[l] - self.khl[fo],
                    self.kv[fo] - self.kv[l],
                    self.is_player(l),
                );
            } else {
                a_n = self.follower_accel(fo, f64::INFINITY, 0.0);
            }
        }
        // Old follower (physical path behind i).
        let olo = self.klo[i] - self.lat_m;
        let ohi = self.khi[i] + self.lat_m;
        let mut of = NONE;
        let mut left = self.n.saturating_sub(1);
        let mut kb = self.prev_k(k);
        while let Some(x) = kb {
            if left == 0 {
                break;
            }
            left -= 1;
            let j = self.ord[x];
            if self.road.signed_delta(self.ks[j], si) > self.look {
                break;
            }
            if self.klo[j] < ohi && self.khi[j] > olo {
                of = j as i64;
                break;
            }
            kb = self.prev_k(x);
        }
        let mut a_o = 0.0;
        let mut a_o_new = 0.0;
        if of >= 0 {
            let o = of as usize;
            a_o = self.follower_accel(
                o,
                self.road.signed_delta(self.ks[o], si) - self.khl[i] - self.khl[o],
                self.kv[o] - vi,
            );
            let ol = self.lead[i];
            if ol >= 0 && ol != of {
                let l = ol as usize;
                a_o_new = self.follower_accel_lp(
                    o,
                    self.road.signed_delta(self.ks[o], self.ks[l]) - self.khl[l] - self.khl[o],
                    self.kv[o] - self.kv[l],
                    self.is_player(l),
                );
            } else {
                a_o_new = self.follower_accel(o, f64::INFINITY, 0.0);
            }
        }
        let inc = mobil::incentive(
            a_c_new,
            self.a_raw[i],
            a_n_new,
            a_n,
            a_o_new,
            a_o,
            self.ppol[p],
        );
        // Keep-right bias, plus lane discipline (fairness rule 7).
        let lanes = self.road.lane_count(si);
        let to_right = t > cur;
        let mut bias = self.pbias[p];
        if to_right {
            if self.pkr[p] == 1 || v0 < self.road.lane_flow_speed_mps(cur, lanes, si) {
                bias += self.disc;
            }
        } else if v0 < self.road.lane_flow_speed_mps(t, lanes, si) {
            bias += self.disc;
        }
        inc - mobil::threshold(self.pth[p], bias, to_right)
    }

    /// The fastest player's speed (GDScript: `_kv[_P]`); -INF with none.
    fn fastest_player(&self) -> f64 {
        let mut v = f64::NEG_INFINITY;
        for p in 0..self.np {
            if self.p_on[p] == 1 {
                v = maxf(v, self.kv[self.cap + p]);
            }
        }
        v
    }

    /// MP look-through: while the leader `l` (at order position `lk`) is signalling or
    /// moving out of the path [lo, hi] (its target does not overlap it), the next vehicle
    /// on the path beyond it counts too: the most restrictive IDM acceleration of those
    /// (INF when `l` stays on the path; -INF when one of them already overlaps i). `claims`:
    /// match paths by claims (MOBIL's target lane) instead of physical intervals.
    #[allow(clippy::too_many_arguments)]
    fn look_through_accel(
        &self,
        i: usize,
        l: usize,
        lk: Option<usize>,
        lo: f64,
        hi: f64,
        claims: bool,
        vi: f64,
        v0: f64,
        p: usize,
        hw_t: f64,
    ) -> f64 {
        let si = self.ks[i];
        let mut a = f64::INFINITY;
        let mut cur = l;
        let mut kk = lk.and_then(|x| self.next_k(x));
        let mut left = self.n.saturating_sub(2);
        while self.leaving_path(cur, lo, hi) {
            let mut next = NONE;
            while let Some(x) = kk {
                if left == 0 {
                    break;
                }
                left -= 1;
                let j = self.ord[x];
                kk = self.next_k(x);
                if j == i {
                    break;
                }
                if self.road.signed_delta(si, self.ks[j]) > self.look {
                    break;
                }
                let (jlo, jhi) = if claims {
                    (self.kclo[j], self.kchi[j])
                } else {
                    (self.klo[j], self.khi[j])
                };
                if jlo < hi && jhi > lo {
                    next = j as i64;
                    break;
                }
            }
            if next < 0 {
                break;
            }
            let j = next as usize;
            let gap = self.road.signed_delta(si, self.ks[j]) - self.khl[j] - self.khl[i];
            if gap <= 0.0 {
                return f64::NEG_INFINITY;
            }
            a = minf(
                a,
                idm::accel(
                    vi,
                    v0,
                    gap,
                    vi - self.kv[j],
                    self.pa[p],
                    self.pb[p],
                    hw_t,
                    self.ps0[p],
                    self.pdl[p],
                    self.gap_floor,
                ),
            );
            cur = j;
        }
        a
    }

    /// MP: the new leader `l` (and, with look-through, the ones beyond it while they leave
    /// the path) extrapolated `signal + move_min / 2` seconds on with its current
    /// acceleration (a player holds its speed), against vehicle i holding its speed: the
    /// gap must stay open and IDM's acceleration there must not be below -b_safe.
    #[allow(clippy::too_many_arguments)]
    fn predicted_leaders_safe(
        &self,
        i: usize,
        l: usize,
        lk: Option<usize>,
        lo: f64,
        hi: f64,
        vi: f64,
        v0: f64,
        p: usize,
        bsafe: f64,
    ) -> bool {
        let tau = self.psig[p] + 0.5 * self.pmmin[p];
        let si = self.ks[i];
        let mut cur = l;
        let mut kk = lk.and_then(|x| self.next_k(x));
        let mut left = self.n.saturating_sub(2);
        loop {
            let vl = self.kv[cur];
            let al = if self.is_player(cur) {
                0.0
            } else {
                self.state.accel[cur]
            };
            let v_end = vl + al * tau;
            let (vl_t, dl) = if v_end >= 0.0 {
                (v_end, (vl + v_end) * 0.5 * tau)
            } else {
                (0.0, vl * vl / (-2.0 * al))
            };
            let gap = self.road.signed_delta(si, self.ks[cur]) - self.khl[cur] - self.khl[i] + dl
                - vi * tau;
            if gap <= 0.0 {
                return false;
            }
            let a = idm::accel(
                vi,
                v0,
                gap,
                vi - vl_t,
                self.pa[p],
                self.pb[p],
                self.pt[p],
                self.ps0[p],
                self.pdl[p],
                self.gap_floor,
            );
            if a < -bsafe {
                return false;
            }
            if !(self.config.look_through && self.leaving_path(cur, lo, hi)) {
                return true;
            }
            let mut next = NONE;
            while let Some(x) = kk {
                if left == 0 {
                    break;
                }
                left -= 1;
                let j = self.ord[x];
                kk = self.next_k(x);
                if j == i || self.road.signed_delta(si, self.ks[j]) > self.look {
                    break;
                }
                if self.kclo[j] < hi && self.kchi[j] > lo {
                    next = j as i64;
                    break;
                }
            }
            if next < 0 {
                return true;
            }
            cur = next as usize;
        }
    }

    /// MP: the deceleration that stops a follower at vi (profile p) s0 behind where its
    /// leader `l`, `gap` ahead, stops at its current deceleration; applied only when it
    /// exceeds the comfortable b (an emergency IDM would react to too late: a racer
    /// closing at 50 m/s on a car braking at the clamp into a queue). INF otherwise.
    fn anticipation_accel(&self, l: usize, gap: f64, vi: f64, p: usize) -> f64 {
        let vl = self.kv[l];
        let al = if self.is_player(l) {
            0.0
        } else {
            self.state.accel[l]
        };
        let stop_l = if al < 0.0 {
            vl * vl / (-2.0 * al)
        } else if vl <= 0.0 {
            0.0
        } else {
            return f64::INFINITY;
        };
        let room = gap - self.ps0[p] + stop_l;
        let a_stop = if room > 0.0 {
            -(vi * vi) / (2.0 * room)
        } else {
            f64::NEG_INFINITY
        };
        if a_stop < -self.pb[p] {
            a_stop
        } else {
            f64::INFINITY
        }
    }

    /// A vehicle signalling or moving to a target whose body does not overlap [lo, hi].
    fn leaving_path(&self, j: usize, lo: f64, hi: f64) -> bool {
        if self.is_player(j) || self.state.lc_state[j] == LC_NONE {
            return false;
        }
        let hw = self.state.width[j] * 0.5;
        let t = self.lc_target_d[j];
        !(t - hw < hi && t + hw > lo)
    }

    /// IDM acceleration of follower f (slot or a player) at this gap / closing speed.
    /// A player is judged as holding its speed (interaction term only).
    fn follower_accel(&self, f: usize, gap: f64, dv: f64) -> f64 {
        self.follower_accel_lp(f, gap, dv, false)
    }

    /// `_follower_accel(f, gap, dv, lead_is_player)`: a weaving follower behind traffic
    /// uses its IDM toward traffic (WP6.9), behind a player its ordinary one.
    fn follower_accel_lp(&self, f: usize, gap: f64, dv: f64, lead_is_player: bool) -> f64 {
        if self.is_player(f) {
            return idm::interaction_accel(
                self.kv[f],
                gap,
                dv,
                self.pl_a,
                self.pl_b,
                self.pl_t,
                self.pl_s0,
                self.gap_floor,
            );
        }
        let p = self.state.profile_id[f] as usize;
        if self.pweave[p] == 1 && !lead_is_player {
            return idm::accel(
                self.kv[f],
                self.state.v0[f],
                gap,
                dv,
                self.pa[p],
                self.wb[p],
                self.pt[p] * self.w_tk[p],
                self.ws0[p],
                self.pdl[p],
                self.gap_floor,
            );
        }
        idm::accel(
            self.kv[f],
            self.state.v0[f],
            gap,
            dv,
            self.pa[p],
            self.pb[p],
            self.pt[p],
            self.ps0[p],
            self.pdl[p],
            self.gap_floor,
        )
    }

    // ------------------------------------------------------------ Racers weave harder (plan D17, WP6.9)
    // Profiles with any DriverProfile "Weaving" field set (the racer): toward a TRAFFIC
    // leader their own T / s0 / b, MOBIL's b_safe toward traffic followers their own
    // (never above the clamp), a lookahead lane-pace bonus in MOBIL's incentive, their own
    // cooldown and a cap on discretionary lane changes per window. Toward players nothing
    // changes. Allocation-free after `new`.

    fn init_weave(&mut self, params: &TrafficParams) {
        for (p, d) in params.profiles.iter().enumerate() {
            let hw = d.idm_headway_vs_traffic_s;
            self.w_tk.push(if hw >= 0.0 && d.raw_headway_s > 0.0 {
                hw / d.raw_headway_s
            } else {
                1.0
            });
            self.ws0.push(if d.idm_s0_vs_traffic_m >= 0.0 {
                d.idm_s0_vs_traffic_m
            } else {
                self.ps0[p]
            });
            self.wb.push(if d.idm_b_comfort_vs_traffic_mps2 > 0.0 {
                d.idm_b_comfort_vs_traffic_mps2
            } else {
                self.pb[p]
            });
            let bs = if d.mobil_b_safe_vs_traffic_mps2 > 0.0 {
                d.mobil_b_safe_vs_traffic_mps2
            } else {
                self.pbsafe[p]
            };
            self.wbsafe.push(minf(bs, self.max_decel));
            self.wlook.push(maxf(d.lookahead_lane_choice_m, 0.0));
            self.wgain.push(d.lookahead_gain_per_s);
            self.wmax.push(d.lookahead_incentive_max_mps2);
            self.wcool.push(if d.lane_change_cooldown_s >= 0.0 {
                d.lane_change_cooldown_s
            } else {
                self.cooldown
            });
            let cap = d.lane_change_cap_count.clamp(0, WEAVE_CAP_MAX as i32);
            self.wcap.push(cap);
            self.wwin.push(d.lane_change_cap_window_s);
            let on = hw >= 0.0
                || d.idm_s0_vs_traffic_m >= 0.0
                || d.idm_b_comfort_vs_traffic_mps2 > 0.0
                || d.mobil_b_safe_vs_traffic_mps2 > 0.0
                || self.wlook[p] > 0.0
                || d.lane_change_cooldown_s >= 0.0
                || cap > 0;
            self.pweave.push(u8::from(on));
        }
    }

    /// True when profile p weaves.
    pub fn weaves(&self, p: usize) -> bool {
        self.pweave[p] == 1
    }

    /// MOBIL cooldown of vehicle i after a lane change (`_cooldown_of`).
    fn cooldown_of(&self, i: usize) -> f64 {
        let p = self.state.profile_id[i] as usize;
        if self.pweave[p] == 0 {
            self.cooldown
        } else {
            self.wcool[p]
        }
    }

    /// The lookahead term of a move of vehicle i from lane `cur` into lane t (`_weave_bonus`).
    fn weave_bonus_of(&self, i: usize, t: i32, cur: i32) -> f64 {
        let p = self.state.profile_id[i] as usize;
        let look = self.wlook[p];
        if look <= 0.0 || t < 0 || t >= self.road.lane_count(self.ks[i]) {
            return 0.0;
        }
        let diff =
            self.weave_pace(i, self.lane_d(t), look) - self.weave_pace(i, self.lane_d(cur), look);
        clampf(self.wgain[p] * diff, -self.wmax[p], self.wmax[p])
    }

    /// The pace of the lane centred at `c` ahead of vehicle i (`_weave_pace`).
    fn weave_pace(&self, i: usize, c: f64, look: f64) -> f64 {
        let p = self.state.profile_id[i] as usize;
        let hw = self.state.width[i] * 0.5;
        let lo = c - hw - self.lat_m;
        let hi = c + hw + self.lat_m;
        let si = self.ks[i];
        let v0 = self.state.v0[i];
        let h = look / v0;
        let t_gap = self.pt[p] * self.w_tk[p];
        let mut pace = v0;
        let mut left = self.n.saturating_sub(1);
        let mut kk = self.next_k(self.rank[i]);
        while let Some(x) = kk {
            if left == 0 {
                break;
            }
            left -= 1;
            let j = self.ord[x];
            kk = self.next_k(x);
            let ahead = self.road.signed_delta(si, self.ks[j]);
            if ahead > look {
                break;
            }
            if self.klo[j] < hi && self.khi[j] > lo {
                let vj = self.kv[j];
                let gap = ahead - self.khl[j] - self.khl[i];
                pace = minf(pace, maxf(gap + vj * h - self.ws0[p] - vj * t_gap, 0.0) / h);
            }
        }
        pace
    }

    /// Vehicle i may start another discretionary lane change (`_weave_cap_ok`).
    fn weave_cap_ok(&mut self, i: usize) -> bool {
        let p = self.state.profile_id[i] as usize;
        let cap = self.wcap[p];
        if cap <= 0 {
            return true;
        }
        if self.wvid[i] != self.state.vehicle_id[i] {
            self.wvid[i] = self.state.vehicle_id[i];
            self.wn[i] = 0;
        }
        let n = self.wn[i];
        if n < cap {
            return true;
        }
        let k = ((n - cap) as usize) % WEAVE_CAP_MAX;
        self.wclock - self.wt[i * WEAVE_CAP_MAX + k] >= self.wwin[p]
    }

    /// Notes that vehicle i may be starting a discretionary lane change now.
    fn weave_note_change(&mut self, i: usize) {
        if self.wcap[self.state.profile_id[i] as usize] <= 0 {
            return;
        }
        if self.wvid[i] != self.state.vehicle_id[i] {
            self.wvid[i] = self.state.vehicle_id[i];
            self.wn[i] = 0;
        }
        let k = (self.wn[i] as usize) % WEAVE_CAP_MAX;
        self.wt[i * WEAVE_CAP_MAX + k] = self.wclock;
        self.wn[i] += 1;
    }

    // ------------------------------------------------------------ Ramps (MP)

    /// The off-ramp pseudo-lane at s: one right of the rightmost lane.
    pub fn ramp_lane(&self, s: f64) -> i32 {
        self.road.lane_count(s)
    }

    /// An exit into the off-ramp: vehicle `slot` (in the rightmost lane, no lane change
    /// running) signals right and moves into the ramp lane with the usual telegraphing,
    /// safety and no-ambush checks; it despawns when the move completes. False when the
    /// move is not allowed now.
    pub fn try_exit(&mut self, slot: usize) -> bool {
        if !self.state.is_active(slot)
            || self.state.lc_state[slot] != LC_NONE
            || self.split[slot] != 0
            || (self.state.flags[slot] & (FLAG_HIT | FLAG_SCRIPTED)) != 0
        {
            return false;
        }
        let ramp = self.ramp_lane(self.ks[slot]);
        if self.state.lane[slot] != ramp - 1 {
            return false;
        }
        let td = self.lane_d(ramp);
        if self.eval_move(slot, td, ramp, false, false).is_infinite() {
            return false;
        }
        self.exiting[slot] = 1;
        self.start_signal(slot, ramp, td, 0);
        self.will_cancel[slot] = 0;
        true
    }

    /// True when nothing (vehicle or player) has its claimed lateral interval within
    /// [d_lo, d_hi] from `behind_m` behind to `ahead_m` ahead of s (bumper to bumper for
    /// a body of `length`). Allocation-free.
    pub fn space_clear(
        &self,
        s: f64,
        length: f64,
        d_lo: f64,
        d_hi: f64,
        behind_m: f64,
        ahead_m: f64,
    ) -> bool {
        for k in 0..self.n {
            let j = self.ord[k];
            let (lo, hi) = if self.is_player(j) {
                (self.klo[j], self.khi[j])
            } else {
                (self.kclo[j], self.kchi[j])
            };
            if !(lo < d_hi && hi > d_lo) {
                continue;
            }
            let ds = self.road.signed_delta(s, self.ks[j]);
            let reach = self.khl[j] + length * 0.5;
            if ds > -(behind_m + reach) && ds < ahead_m + reach {
                return false;
            }
        }
        true
    }

    // ------------------------------------------------------------ Helpers

    /// Lane center d (lane geometry of this tick).
    #[inline]
    pub fn lane_d(&self, lane: i32) -> f64 {
        self.edge + (f64::from(lane) + 0.5) * self.lw
    }

    /// `_read_player`, per player: the reported state extrapolated to this tick.
    fn read_players(&mut self, dt: f64) {
        for p in 0..self.np {
            if self.p_on[p] == 0 {
                continue;
            }
            let inp = self.p_in[p];
            let mut s = inp.s;
            let mut d = inp.d;
            let lag = self.tick.wrapping_sub(inp.tick);
            if lag > 0 && lag < u32::MAX / 2 {
                let age = minf(f64::from(lag) * dt, self.config.player_max_extrapolation_s);
                if age > 0.0 {
                    s += inp.s_dot * age;
                    d += inp.d_dot * age;
                }
            }
            s = self.road.wrap(s);
            self.pl_s[p] = s;
            self.pl_d[p] = d;
            self.pl_v[p] = inp.s_dot;
            self.pl_vl[p] = inp.d_dot;
            self.pl_lo[p] = d - self.pl_w[p] * 0.5;
            self.pl_hi[p] = d + self.pl_w[p] * 0.5;
            let ahead = self.pl_vl[p] * self.antic;
            let e = self.cap + p;
            self.ks[e] = s;
            self.kv[e] = self.pl_v[p];
            self.klo[e] = self.pl_lo[p] + minf(0.0, ahead);
            self.khi[e] = self.pl_hi[p] + maxf(0.0, ahead);
            self.kclo[e] = self.klo[e];
            self.kchi[e] = self.khi[e];
        }
    }

    /// Insertion sort of the order by s (nearly sorted every tick: ~O(n)).
    fn sort(&mut self) {
        let mut swapped = false;
        for k in 1..self.n {
            let x = self.ord[k];
            let sx = self.ks[x];
            let mut m = k as i64 - 1;
            while m >= 0 && self.ks[self.ord[m as usize]] > sx {
                self.ord[(m + 1) as usize] = self.ord[m as usize];
                m -= 1;
            }
            if m != k as i64 - 1 {
                self.ord[(m + 1) as usize] = x;
                swapped = true;
            }
        }
        if swapped {
            for k in 0..self.n {
                self.rank[self.ord[k]] = k;
            }
        }
    }

    fn refresh_interval(&mut self, i: usize) {
        let hw = self.state.width[i] * 0.5;
        let d = self.state.d[i];
        let mut lo = d - hw;
        let mut hi = d + hw;
        let st = self.state.lc_state[i];
        if st == LC_NONE {
            if self.split[i] != 0 {
                self.kclo[i] = d - self.lw * 0.5;
                self.kchi[i] = d + self.lw * 0.5;
            } else {
                self.kclo[i] = lo;
                self.kchi[i] = hi;
            }
        } else {
            let tc = self.lc_target_d[i];
            let clo = minf(lo, tc - hw);
            let chi = maxf(hi, tc + hw);
            self.kclo[i] = clo;
            self.kchi[i] = chi;
            if st == LC_MOVING {
                lo = clo;
                hi = chi;
            }
        }
        self.klo[i] = lo;
        self.khi[i] = hi;
    }

    fn emit_pending(&mut self) {
        for k in 0..self.n {
            let i = self.ord[k];
            if self.is_player(i) {
                continue;
            }
            let pb = self.pending[i];
            if pb == 0 {
                continue;
            }
            if (pb & PEND_HAZARD_ON) != 0 {
                self.push_event(EventKind::Hazards, EventTag::Hit, i, 1.0);
            }
            if (pb & PEND_HORN) != 0 {
                let tag = self.pending_tag[i];
                self.push_event(EventKind::Horn, tag, i, 0.0);
            }
            self.pending[i] = 0;
        }
        self.n_pending = 0;
    }

    #[inline]
    fn push_event(&mut self, kind: EventKind, tag: EventTag, i: usize, value: f64) {
        let e = SimEvent {
            kind,
            tag,
            slot: i as u32,
            vehicle_id: self.state.vehicle_id[i],
            tick: self.tick,
            value,
            move_start_tick: self.tick,
            target_lane: 0,
            target_d: 0.0,
            duration_s: 0.0,
        };
        self.events.push(e);
    }

    /// Sim-side bookkeeping hash (the order and per-slot model state) for determinism
    /// tests beyond `state.trace_hash()`.
    pub fn internal_hash(&self, mut h: u64) -> u64 {
        use crate::trace_hash::{mix_float, mix_int};
        h = mix_int(h, self.n as i64);
        for k in 0..self.n {
            let i = self.ord[k];
            h = mix_int(h, i as i64);
            if !self.is_player(i) {
                h = mix_float(h, self.mobil_t[i]);
                h = mix_int(h, self.lead[i]);
            }
        }
        h
    }
}
