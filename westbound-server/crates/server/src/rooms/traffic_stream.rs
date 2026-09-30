//! Traffic streaming (N4.2): what each client is told about the room's traffic ring. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → Traffic: server-authoritative with intents → What the
//! server sends (area of interest 300 m behind to 900 m ahead; corrections 5 Hz within
//! 100 m, at least 1 Hz otherwise), Resource budget (10 KB/s down per player); docs/
//! PROTOCOL.md §4 (`traffic_*`), §11 (streaming batches), §12 (lanes, car ids); MP-D6.
//! The exact schedule is in docs/SERVER.md → "Traffic streaming (N4.2)".
//!
//! [`TrafficStream`] sits beside the room's `TrafficSim` and reads it; it never changes
//! the simulation. Per room it maps sim slots (`vehicle_id`) to wire `car_id`s
//! ([`CarIds`]), turns the sim's events into intents, caches every car's wire state once
//! per tick, and detects hit reactions. Per client ([`ClientStream`]) it keeps the set of
//! cars the client has been told about and when each was last corrected, and writes the
//! client's `traffic_despawn`, `traffic_intent`, `traffic_spawn` and `traffic_correction`
//! batches into its tick frame, in that order.
//!
//! **Allocation-free per tick:** every per-slot and per-client buffer is sized at
//! creation (a new client allocates its buffers once, when it first gets a frame).

use protocol::{
    CorrectionEntry, EncodeError, FrameBuilder, IntentKind, LaneChangePhase, TrafficFlags,
    TrafficIntentEntry, TrafficSpawnEntry, MAX_LANES,
};
use sim::map::LoopMap;
use sim::traffic::state::{FLAG_BRAKE, FLAG_HAZARD, FLAG_HIT, LC_MOVING, LC_NONE, LC_SIGNALING};
use sim::traffic::{EventKind, TrafficSim};

use super::car_ids::CarIds;
use super::plausibility::tick_diff;

const MM_PER_M: f64 = 1_000.0;
const MS_PER_S: f64 = 1_000.0;
/// Wire lane of a ramp (MP-D6): off-ramp exits and on-ramp entries.
pub const RAMP_LANE: u8 = MAX_LANES - 1;
/// Wire sizes (docs/PROTOCOL.md §4): a batch message's header + count byte, the
/// correction batch's (with its tick), and each entry.
const BATCH_HEADER: isize = 4;
const CORRECTION_HEADER: isize = 8;
const DESPAWN_ENTRY: isize = 2;
const INTENT_ENTRY: isize = 14;
const SPAWN_ENTRY: isize = 23;
const CORRECTION_ENTRY: isize = 10;
/// Intents one room tick can hold (a rush ring signals about one lane change per tick).
const INTENTS_CAP: usize = 512;
/// Car-id releases held without the queue growing.
const RELEASES_CAP: usize = 4_096;
/// "Never" for a per-client tick mark.
const NO_TICK: u32 = u32::MAX;

/// The streaming schedule (`[rooms]` `traffic_*`, converted once).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StreamRules {
    /// Area of interest around the player's s: this far behind and ahead (mm)...
    pub aoi_behind_mm: i64,
    pub aoi_ahead_mm: i64,
    /// ...and a car already sent stays until it is this much further out (mm).
    pub hysteresis_mm: i64,
    /// Cars within this distance of the player (mm, either way) are "near".
    pub near_mm: i64,
    /// Correction periods (room ticks) for near and other cars.
    pub near_period_ticks: u32,
    pub far_period_ticks: u32,
    /// A released car id is not handed out again for this many ticks (MP-D6: 30 s).
    pub car_id_hold_ticks: u32,
}

/// The sim's reaction timings the intents carry (s; the exported traffic tuning).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReactionTimes {
    pub hit_recover_s: f64,
    pub hit_brake_s: f64,
    pub hit_swerve_s: f64,
    pub brake_tap_s: f64,
    pub tick_dt: f64,
}

/// Counters for tests and logs.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct StreamStats {
    /// Intents that did not fit the room's per-tick buffer.
    pub intents_dropped: u64,
    /// Intents, spawns or corrections left for a later tick because a frame was full.
    pub deferred: u64,
    /// Hit reactions seen (hazard + hard brake intents).
    pub hits: u64,
}

#[derive(Debug, Clone, Copy)]
struct PendingIntent {
    slot: u32,
    car_id: u16,
    kind: IntentKind,
    start_tick: u32,
    move_start_tick: u32,
    /// Sim lane (from the median); converted per frame.
    target_lane: i32,
    duration_ms: u16,
}

/// One client's view: which car each sim slot is to it, and its correction clock.
#[derive(Debug)]
pub struct ClientStream {
    player_id: u16,
    /// Per sim slot: the car id the client was sent (0: none).
    known: Vec<u16>,
    /// The slots with `known != 0`, in the order they were sent.
    known_slots: Vec<u32>,
    /// Per slot: room tick of the last scheduled correction (at spawn: the spawn tick minus
    /// `car_id mod far period`, to spread the phases). Spawn and intent corrections do not
    /// move it.
    last_sent: Vec<u32>,
    /// Per slot: the tick the slot was queued in `urgent` (dedupe).
    mark: Vec<u32>,
    /// This tick's slots that must be corrected now (spawned, intents, hit reactions).
    urgent: Vec<u32>,
}

impl ClientStream {
    fn new(player_id: u16, slots: usize) -> Self {
        Self {
            player_id,
            known: vec![0; slots],
            known_slots: Vec::with_capacity(slots),
            last_sent: vec![0; slots],
            mark: vec![NO_TICK; slots],
            urgent: Vec::with_capacity(slots),
        }
    }

    fn reset(&mut self) {
        for &s in &self.known_slots {
            self.known[s as usize] = 0;
        }
        self.known_slots.clear();
        self.urgent.clear();
        for m in &mut self.mark {
            *m = NO_TICK;
        }
    }

    fn queue_urgent(&mut self, slot: usize, now: u32) {
        if self.mark[slot] != now {
            self.mark[slot] = now;
            self.urgent.push(slot as u32);
        }
    }
}

pub struct TrafficStream {
    rules: StreamRules,
    react: ReactionTimes,
    map: LoopMap,
    ids: CarIds,
    /// Room tick of world tick 0 (the adapter's origin).
    origin: u32,
    now: u32,
    /// Per sim slot: its car id (0: empty) and the sim `vehicle_id` it belongs to.
    car: Vec<u16>,
    vid: Vec<i32>,
    /// Per slot, this tick's wire state and the lane count at its s.
    s_mm: Vec<u32>,
    d_cm: Vec<i16>,
    v_cms: Vec<u16>,
    lanes: Vec<u8>,
    /// Hit reactions: react_timer after the last step (0: not hit) and the reaction's
    /// start tick.
    hit_rt: Vec<f64>,
    hit_tick: Vec<u32>,
    /// Ticks after a hit during which the car is corrected every tick (the swerve).
    swerve_ticks: u32,
    intents: Vec<PendingIntent>,
    clients: Vec<ClientStream>,
    pub stats: StreamStats,
}

/// Wire lane (0 = rightmost of `n`; `RAMP_LANE` for the ramp pseudo-lane and beyond).
pub fn wire_lane(sim_lane: i32, n: u8) -> u8 {
    let n = i32::from(n);
    if sim_lane >= n {
        return RAMP_LANE;
    }
    (n - 1 - sim_lane.max(0)).clamp(0, i32::from(RAMP_LANE) - 1) as u8
}

/// Back from the wire (what a client does): the sim lane (0 = next to the median).
pub fn sim_lane(wire: u8, n: u8) -> i32 {
    if wire == RAMP_LANE {
        i32::from(n)
    } else {
        i32::from(n) - 1 - i32::from(wire)
    }
}

fn ms(s: f64) -> u16 {
    if s.is_finite() {
        (s * MS_PER_S).round().clamp(0.0, f64::from(u16::MAX)) as u16
    } else {
        0
    }
}

/// How far `b` is ahead of `a` on a loop of `len` mm: `LoopMap::signed_delta_mm` (in
/// `[-L/2, L/2)`) without its division, for positions in `[0, L)` (it runs for every car
/// and client each tick).
fn wrapped_delta(len: u32, a: u32, b: u32) -> i64 {
    let x = i64::from(b) - i64::from(a);
    let len = i64::from(len);
    let half = len / 2;
    if x >= len - half {
        x - len
    } else if x < -half {
        x + len
    } else {
        x
    }
}

fn byte(x: i32) -> u8 {
    u8::try_from(x).unwrap_or(u8::MAX)
}

impl TrafficStream {
    /// Streams `sim` (filled, at world tick 0 = room tick `origin`).
    pub fn new(
        rules: StreamRules,
        react: ReactionTimes,
        map: &LoopMap,
        sim: &TrafficSim,
        origin: u32,
    ) -> Self {
        let cap = sim.state.capacity;
        let swerve_ticks = (react.hit_swerve_s / react.tick_dt).ceil() as u32 + 1;
        let mut t = Self {
            rules,
            react,
            map: map.clone(),
            ids: CarIds::new(rules.car_id_hold_ticks, RELEASES_CAP),
            origin,
            now: origin.wrapping_add(sim.tick()),
            car: vec![0; cap],
            vid: vec![0; cap],
            s_mm: vec![0; cap],
            d_cm: vec![0; cap],
            v_cms: vec![0; cap],
            lanes: vec![0; cap],
            hit_rt: vec![0.0; cap],
            hit_tick: vec![0; cap],
            swerve_ticks,
            intents: Vec::with_capacity(INTENTS_CAP),
            clients: Vec::new(),
            stats: StreamStats::default(),
        };
        t.reconcile(sim);
        t.cache(sim);
        t
    }

    // ------------------------------------------------------------------ Room side

    /// Starts room tick `now` (before the world steps): last tick's intents go.
    pub fn begin_tick(&mut self) {
        self.intents.clear();
    }

    /// After each world step: ids for new cars and released ids for gone ones, the
    /// step's intents, hit reactions. `origin` is the room tick of world tick 0.
    pub fn after_step(&mut self, sim: &TrafficSim, origin: u32) {
        self.origin = origin;
        self.now = origin.wrapping_add(sim.tick());
        self.reconcile(sim);
        self.collect_events(sim);
        self.detect_hits(sim);
    }

    /// After the room tick's steps: every car's wire state for the frames.
    pub fn end_tick(&mut self, sim: &TrafficSim) {
        self.cache(sim);
    }

    /// The room tick the stream is at (the correction batches' tick).
    pub fn now(&self) -> u32 {
        self.now
    }

    fn reconcile(&mut self, sim: &TrafficSim) {
        let st = &sim.state;
        for i in 0..st.capacity {
            let active = st.active[i] == 1;
            if self.car[i] != 0 && (!active || st.vehicle_id[i] != self.vid[i]) {
                self.ids.release(self.car[i], self.now);
                self.car[i] = 0;
            }
            if active && self.car[i] == 0 {
                self.car[i] = self.ids.alloc(self.now);
                self.vid[i] = st.vehicle_id[i];
                self.hit_rt[i] = 0.0;
            }
        }
    }

    fn push_intent(&mut self, p: PendingIntent) {
        if self.intents.len() < self.intents.capacity() {
            self.intents.push(p);
        } else {
            self.stats.intents_dropped += 1;
        }
    }

    fn collect_events(&mut self, sim: &TrafficSim) {
        for e in sim.events.as_slice() {
            let slot = e.slot as usize;
            if slot >= self.car.len() || self.car[slot] == 0 || self.vid[slot] != e.vehicle_id {
                continue;
            }
            let base = PendingIntent {
                slot: e.slot,
                car_id: self.car[slot],
                kind: IntentKind::Cancel,
                start_tick: self.origin.wrapping_add(e.tick),
                move_start_tick: self.origin.wrapping_add(e.tick),
                target_lane: 0,
                duration_ms: 0,
            };
            match e.kind {
                EventKind::Signal => self.push_intent(PendingIntent {
                    kind: IntentKind::LaneChange,
                    move_start_tick: self.origin.wrapping_add(e.move_start_tick),
                    target_lane: e.target_lane,
                    duration_ms: ms(e.duration_s),
                    ..base
                }),
                EventKind::Cancel => self.push_intent(base),
                // A cut-in brake tap: a short hard brake.
                EventKind::BrakeTap => self.push_intent(PendingIntent {
                    kind: IntentKind::HardBrake,
                    duration_ms: ms(self.react.brake_tap_s),
                    ..base
                }),
                // Hazards come with the hit reactions (`detect_hits`); horns stay
                // client-side (spec: "traffic reactions like horns ... are not networked");
                // spawns and despawns are `reconcile`'s.
                EventKind::Hazards
                | EventKind::Horn
                | EventKind::Spawned
                | EventKind::Despawned => {}
            }
        }
    }

    /// A hit reaction starts when a car's react timer is set (first hit) or reset (hit
    /// again while recovering): hazards for the rest of the recovery and a hard brake for
    /// the rest of `hit_brake_s`, and corrections every tick through the swerve.
    fn detect_hits(&mut self, sim: &TrafficSim) {
        let st = &sim.state;
        for i in 0..st.capacity {
            if st.active[i] == 0 || (st.flags[i] & FLAG_HIT) == 0 {
                self.hit_rt[i] = 0.0;
                continue;
            }
            let rt = st.react_timer[i];
            let started = self.hit_rt[i] <= 0.0 || rt > self.hit_rt[i];
            self.hit_rt[i] = rt;
            if !started || self.car[i] == 0 {
                continue;
            }
            self.stats.hits += 1;
            self.hit_tick[i] = self.now;
            let elapsed = self.react.hit_recover_s - rt;
            let base = PendingIntent {
                slot: i as u32,
                car_id: self.car[i],
                kind: IntentKind::Hazard,
                start_tick: self.now,
                move_start_tick: self.now,
                target_lane: 0,
                duration_ms: ms(rt),
            };
            self.push_intent(base);
            self.push_intent(PendingIntent {
                kind: IntentKind::HardBrake,
                duration_ms: ms((self.react.hit_brake_s - elapsed).max(0.0)),
                ..base
            });
        }
    }

    fn cache(&mut self, sim: &TrafficSim) {
        let st = &sim.state;
        let len = i64::from(self.map.length_mm());
        for i in 0..st.capacity {
            if st.active[i] == 0 {
                continue;
            }
            let s = ((st.s[i] * MM_PER_M).round() as i64).rem_euclid(len) as u32;
            self.s_mm[i] = s;
            self.d_cm[i] = protocol::quant::d_to_wire(st.d[i]).unwrap_or(0);
            self.v_cms[i] = protocol::quant::speed_to_wire(st.v[i].max(0.0)).unwrap_or(0);
            self.lanes[i] = self.map.lane_count_at(s);
        }
    }

    fn hit_urgent(&self, slot: usize) -> bool {
        self.hit_rt[slot] > 0.0
            && tick_diff(self.hit_tick[slot], self.now) <= i64::from(self.swerve_ticks)
    }

    // ------------------------------------------------------------------ Lookups

    /// The car id of sim slot `slot` (0: empty).
    pub fn car_id(&self, slot: usize) -> u16 {
        self.car.get(slot).copied().unwrap_or(0)
    }

    /// The sim slot of car `car_id`.
    pub fn slot_of(&self, car_id: u16) -> Option<usize> {
        if car_id == 0 {
            return None;
        }
        self.car.iter().position(|&c| c == car_id)
    }

    /// Car ids in use.
    pub fn live_ids(&self) -> u32 {
        self.ids.live()
    }

    pub fn early_id_reuses(&self) -> u64 {
        self.ids.early_reuses
    }

    /// Wire s (mm) of slot `slot` this tick.
    pub fn s_mm(&self, slot: usize) -> u32 {
        self.s_mm[slot]
    }

    /// Distance from `center` to slot `slot` along the loop (mm, + ahead).
    fn delta(&self, center: u32, slot: usize) -> i64 {
        wrapped_delta(self.map.length_mm(), center, self.s_mm[slot])
    }

    /// Whether car `slot` is inside the area of interest around `center` (without the
    /// hysteresis: where cars are sent).
    pub fn in_aoi(&self, center: u32, slot: usize) -> bool {
        let d = self.delta(center, slot);
        d >= -self.rules.aoi_behind_mm && d <= self.rules.aoi_ahead_mm
    }

    /// Inside the area plus the hysteresis (where sent cars stay).
    pub fn in_outer(&self, center: u32, slot: usize) -> bool {
        let d = self.delta(center, slot);
        let h = self.rules.hysteresis_mm;
        d >= -self.rules.aoi_behind_mm - h && d <= self.rules.aoi_ahead_mm + h
    }

    /// The car ids `player_id` has been told about (spawned, not despawned).
    pub fn known(&self, player_id: u16) -> impl Iterator<Item = u16> + '_ {
        self.clients
            .iter()
            .filter(move |c| c.player_id == player_id)
            .flat_map(|c| c.known_slots.iter().map(|&s| c.known[s as usize]))
    }

    // ------------------------------------------------------------------ Clients

    /// A seat went: its view is dropped (buffers kept for the next client).
    pub fn player_left(&mut self, player_id: u16) {
        if let Some(c) = self.clients.iter_mut().find(|c| c.player_id == player_id) {
            c.reset();
            c.player_id = 0;
        }
    }

    fn client_index(&mut self, player_id: u16) -> usize {
        if let Some(i) = self.clients.iter().position(|c| c.player_id == player_id) {
            return i;
        }
        let slots = self.car.len();
        if let Some(i) = self.clients.iter().position(|c| c.player_id == 0) {
            self.clients[i].reset();
            self.clients[i].player_id = player_id;
            return i;
        }
        // A new seat (joins allocate; ticks do not).
        self.clients.push(ClientStream::new(player_id, slots));
        self.clients.len() - 1
    }

    /// Appends `player_id`'s traffic for this tick to its frame: despawns, intents,
    /// spawns (with the hit reactions of spawned cars), corrections (docs/SERVER.md →
    /// "Traffic streaming"). `center` is the player's s (mm); `joined`: the client got its
    /// room snapshot this tick (it starts from nothing: every car in its area is spawned).
    pub fn write_client(
        &mut self,
        sim: &TrafficSim,
        player_id: u16,
        center: u32,
        joined: bool,
        fb: &mut FrameBuilder,
    ) {
        if player_id == 0 {
            return;
        }
        let ci = self.client_index(player_id);
        let mut c = std::mem::replace(&mut self.clients[ci], ClientStream::empty());
        if joined {
            c.reset();
        }
        c.urgent.clear();
        // Bytes left in the frame. Every car spawned or given an intent is corrected in the
        // same frame, so its correction entry (and the batch's header) is set aside first.
        let mut left = fb.remaining() as isize - CORRECTION_HEADER;
        self.write_despawns(&mut c, center, fb, &mut left);
        self.write_intents(&mut c, fb, &mut left);
        let first_spawned = c.urgent.len();
        self.write_spawns(sim, &mut c, center, fb, &mut left);
        self.write_spawn_reactions(sim, &mut c, first_spawned, fb, &mut left);
        self.write_corrections(&mut c, center, fb);
        self.clients[ci] = c;
    }

    fn write_despawns(
        &mut self,
        c: &mut ClientStream,
        center: u32,
        fb: &mut FrameBuilder,
        left: &mut isize,
    ) {
        let mut k = 0;
        'batches: while k < c.known_slots.len() {
            let Ok(mut batch) = fb.traffic_despawns() else {
                break;
            };
            while k < c.known_slots.len() {
                let slot = c.known_slots[k] as usize;
                let id = c.known[slot];
                if self.car[slot] == id && self.in_outer(center, slot) {
                    k += 1;
                    continue;
                }
                let need = DESPAWN_ENTRY + if batch.is_empty() { BATCH_HEADER } else { 0 };
                if *left < need {
                    self.stats.deferred += 1;
                    break 'batches;
                }
                match batch.push(&id) {
                    Ok(()) => {
                        *left -= need;
                        c.known[slot] = 0;
                        c.known_slots.swap_remove(k);
                    }
                    Err(EncodeError::BatchFull { .. }) => continue 'batches,
                    Err(_) => break 'batches,
                }
            }
        }
    }

    fn intent_entry(&self, p: &PendingIntent) -> TrafficIntentEntry {
        let target_lane = if p.kind == IntentKind::LaneChange {
            wire_lane(p.target_lane, self.lanes[p.slot as usize])
        } else {
            0
        };
        TrafficIntentEntry {
            car_id: p.car_id,
            kind: p.kind,
            start_tick: p.start_tick,
            move_start_tick: p.move_start_tick,
            target_lane,
            duration_ms: p.duration_ms,
        }
    }

    fn write_intents(&mut self, c: &mut ClientStream, fb: &mut FrameBuilder, left: &mut isize) {
        let now = self.now;
        let mut k = 0;
        'batches: while k < self.intents.len() {
            let Ok(mut batch) = fb.traffic_intents() else {
                break;
            };
            while k < self.intents.len() {
                let p = self.intents[k];
                let slot = p.slot as usize;
                // Only cars this client already has: a spawn carries the rest.
                if c.known[slot] == 0 || c.known[slot] != p.car_id || self.car[slot] != p.car_id {
                    k += 1;
                    continue;
                }
                let corr = if c.mark[slot] == now {
                    0
                } else {
                    CORRECTION_ENTRY
                };
                let need = INTENT_ENTRY + corr + if batch.is_empty() { BATCH_HEADER } else { 0 };
                if *left < need {
                    self.stats.deferred += 1;
                    break 'batches;
                }
                match batch.push(&self.intent_entry(&p)) {
                    Ok(()) => {
                        *left -= need;
                        c.queue_urgent(slot, now);
                        k += 1;
                    }
                    Err(EncodeError::BatchFull { .. }) => continue 'batches,
                    Err(_) => break 'batches,
                }
            }
        }
    }

    fn wants_spawn(&self, sim: &TrafficSim, c: &ClientStream, center: u32, slot: usize) -> bool {
        sim.state.active[slot] == 1
            && self.car[slot] != 0
            && c.known[slot] == 0
            && self.in_aoi(center, slot)
    }

    fn write_spawns(
        &mut self,
        sim: &TrafficSim,
        c: &mut ClientStream,
        center: u32,
        fb: &mut FrameBuilder,
        left: &mut isize,
    ) {
        let now = self.now;
        let cap = sim.state.capacity;
        let far = self.rules.far_period_ticks.max(1);
        let mut slot = 0;
        'batches: while slot < cap {
            // Find the next car before opening a batch.
            while slot < cap && !self.wants_spawn(sim, c, center, slot) {
                slot += 1;
            }
            if slot >= cap {
                break;
            }
            let Ok(mut batch) = fb.traffic_spawns() else {
                break;
            };
            while slot < cap {
                if !self.wants_spawn(sim, c, center, slot) {
                    slot += 1;
                    continue;
                }
                let need = SPAWN_ENTRY
                    + CORRECTION_ENTRY
                    + if batch.is_empty() { BATCH_HEADER } else { 0 };
                if *left < need {
                    // The rest come next tick.
                    self.stats.deferred += 1;
                    break 'batches;
                }
                let e = self.spawn_entry(sim, slot);
                match batch.push(&e) {
                    Ok(()) => {
                        *left -= need;
                        c.known[slot] = e.car_id;
                        c.known_slots.push(slot as u32);
                        // Phase-spread the periodic corrections by car id.
                        c.last_sent[slot] = now.wrapping_sub(u32::from(e.car_id) % far);
                        c.queue_urgent(slot, now);
                        slot += 1;
                    }
                    Err(EncodeError::BatchFull { .. }) => continue 'batches,
                    Err(_) => break 'batches,
                }
            }
        }
    }

    /// A car spawned in the middle of a hit reaction: its hazards and hard brake with the
    /// time left (the spawn's flags say they are on, not for how long).
    fn write_spawn_reactions(
        &mut self,
        sim: &TrafficSim,
        c: &mut ClientStream,
        first: usize,
        fb: &mut FrameBuilder,
        left: &mut isize,
    ) {
        let st = &sim.state;
        let now = self.now;
        let hit = |slot: usize| (st.flags[slot] & FLAG_HIT) != 0 && st.react_timer[slot] > 0.0;
        if !c.urgent[first..].iter().any(|&s| hit(s as usize)) {
            return;
        }
        let Ok(mut batch) = fb.traffic_intents() else {
            self.stats.deferred += 1;
            return;
        };
        for u in first..c.urgent.len() {
            let slot = c.urgent[u] as usize;
            if !hit(slot) {
                continue;
            }
            let rt = st.react_timer[slot];
            let brake = self.react.hit_brake_s - (self.react.hit_recover_s - rt);
            let mut p = PendingIntent {
                slot: slot as u32,
                car_id: self.car[slot],
                kind: IntentKind::Hazard,
                start_tick: now,
                move_start_tick: now,
                target_lane: 0,
                duration_ms: ms(rt),
            };
            for kind in [IntentKind::Hazard, IntentKind::HardBrake] {
                if kind == IntentKind::HardBrake {
                    if brake <= 0.0 {
                        continue;
                    }
                    p.kind = kind;
                    p.duration_ms = ms(brake);
                }
                let need = INTENT_ENTRY + if batch.is_empty() { BATCH_HEADER } else { 0 };
                if *left < need || batch.push(&self.intent_entry(&p)).is_err() {
                    self.stats.deferred += 1;
                    return;
                }
                *left -= need;
            }
        }
    }

    fn spawn_entry(&self, sim: &TrafficSim, slot: usize) -> TrafficSpawnEntry {
        let st = &sim.state;
        let n = self.lanes[slot];
        let lc = st.lc_state[slot];
        let (phase, target, move_start, dur) = if lc == LC_NONE {
            (LaneChangePhase::None, 0, 0, 0)
        } else {
            (
                if lc == LC_SIGNALING {
                    LaneChangePhase::Signaling
                } else {
                    debug_assert_eq!(lc, LC_MOVING);
                    LaneChangePhase::Moving
                },
                wire_lane(st.target_lane[slot], n),
                self.origin.wrapping_add(sim.move_start_tick(slot)),
                ms(sim.move_duration(slot)),
            )
        };
        TrafficSpawnEntry {
            car_id: self.car[slot],
            vehicle: byte(st.type_id[slot]),
            color: byte(st.color_index[slot]),
            profile: byte(st.profile_id[slot]),
            lane: wire_lane(st.lane[slot], n),
            s_mm: self.s_mm[slot],
            d_cm: self.d_cm[slot],
            speed_cms: self.v_cms[slot],
            lc_phase: phase,
            lc_target_lane: target,
            lc_move_start_tick: move_start,
            lc_duration_ms: dur,
            flags: TrafficFlags {
                hazard: (st.flags[slot] & FLAG_HAZARD) != 0,
                braking: (st.flags[slot] & FLAG_BRAKE) != 0,
            },
        }
    }

    fn correction(&self, slot: usize) -> CorrectionEntry {
        CorrectionEntry {
            car_id: self.car[slot],
            s_mm: self.s_mm[slot],
            d_cm: self.d_cm[slot],
            speed_cms: self.v_cms[slot],
        }
    }

    /// The tick's correction batch: first the cars spawned or given an intent this frame
    /// (their space was set aside), then every car whose period is up (near: 5 Hz, else
    /// 1 Hz) or that is swerving from a hit. Whatever does not fit waits for next tick.
    fn write_corrections(&mut self, c: &mut ClientStream, center: u32, fb: &mut FrameBuilder) {
        let now = self.now;
        let mut u = 0;
        let mut k = 0;
        'batches: while u < c.urgent.len() || k < c.known_slots.len() {
            let Ok(mut batch) = fb.traffic_corrections(now) else {
                self.stats.deferred += 1;
                break;
            };
            while u < c.urgent.len() {
                let slot = c.urgent[u] as usize;
                match batch.push(&self.correction(slot)) {
                    Ok(()) => u += 1,
                    Err(EncodeError::BatchFull { .. }) => continue 'batches,
                    Err(_) => {
                        self.stats.deferred += 1;
                        break 'batches;
                    }
                }
            }
            while k < c.known_slots.len() {
                let slot = c.known_slots[k] as usize;
                if c.mark[slot] == now {
                    k += 1;
                    continue;
                }
                let near = self.delta(center, slot).abs() <= self.rules.near_mm;
                let period = if near {
                    self.rules.near_period_ticks
                } else {
                    self.rules.far_period_ticks
                };
                if tick_diff(c.last_sent[slot], now) < i64::from(period) && !self.hit_urgent(slot) {
                    k += 1;
                    continue;
                }
                match batch.push(&self.correction(slot)) {
                    Ok(()) => {
                        c.last_sent[slot] = now;
                        k += 1;
                    }
                    Err(EncodeError::BatchFull { .. }) => continue 'batches,
                    Err(_) => {
                        self.stats.deferred += 1;
                        break 'batches;
                    }
                }
            }
        }
    }
}

impl ClientStream {
    /// A placeholder while the real one is borrowed out (no allocation: empty vectors).
    fn empty() -> Self {
        Self {
            player_id: 0,
            known: Vec::new(),
            known_slots: Vec::new(),
            last_sent: Vec::new(),
            mark: Vec::new(),
            urgent: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fast_delta_is_the_maps() {
        let map = crate::map::builtin().expect("loop_v1").map.clone();
        let len = map.length_mm();
        let points = [0, 1, len / 2 - 1, len / 2, len / 2 + 1, len - 1, 12_345_678];
        for &a in &points {
            for &b in &points {
                assert_eq!(
                    wrapped_delta(len, a, b),
                    map.signed_delta_mm(a, b),
                    "{a} -> {b}"
                );
            }
        }
        // Odd and even lengths against the map's formula.
        for len in [7u32, 8] {
            for a in 0..len {
                for b in 0..len {
                    let half = i64::from(len) / 2;
                    let want =
                        (i64::from(b) - i64::from(a) + half).rem_euclid(i64::from(len)) - half;
                    assert_eq!(wrapped_delta(len, a, b), want, "L {len}: {a} -> {b}");
                }
            }
        }
    }

    #[test]
    fn lanes_count_from_the_right_on_the_wire() {
        // 3 lanes: sim 0 (median) = wire 2, sim 2 = wire 0; the ramp pseudo-lane = 7.
        assert_eq!(wire_lane(0, 3), 2);
        assert_eq!(wire_lane(2, 3), 0);
        assert_eq!(wire_lane(3, 3), RAMP_LANE);
        assert_eq!(wire_lane(4, 3), RAMP_LANE);
        assert_eq!(wire_lane(0, 4), 3);
        for n in 1..=4u8 {
            for l in 0..=i32::from(n) {
                assert_eq!(sim_lane(wire_lane(l, n), n), l);
            }
        }
    }
}
