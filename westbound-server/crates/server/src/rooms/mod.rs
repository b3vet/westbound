//! Rooms and players (WP N5.1, server side). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! Architecture (room tasks: one tokio task per room, bounded channels), Rooms, parties
//! and matchmaking → Rooms, Players, Time of day in multiplayer, Resource budget; docs/
//! MULTIPLAYER_PLAN.md → N5; wire: docs/PROTOCOL.md; runbook: docs/SERVER.md → "Rooms".
//!
//! | Module | What |
//! | --- | --- |
//! | this file | [`Rooms`] (the registry: create, join by code / id / Quick Join, browse, seats per account), [`RoomLink`] (a connection's handle on its seat), [`RoomParams`] |
//! | `room` | One room's state and rules, synchronous (joins, seats, host, runs, placements, the relay, one frame per tick per client) |
//! | `task` | The room's tokio task: its command queue and its 20 Hz tick |
//! | `clock` | The room clock (32 min cycle, UTC-derived, fixed, night) |
//! | `plausibility` | Checks on reported `PlayerState`s |
//! | `road` | Lane geometry, bounds and flow speeds on the loop |
//! | `traffic` | The traffic seam (`RoomTraffic`, `NoTraffic`) |
//! | `sim_traffic` | `RoomTraffic` over `sim::traffic::TrafficWorld` (`rooms.traffic = "sim"`, the default) |
//! | `traffic_stream` | N4.2: each client's traffic (area of interest, spawns, despawns, intents, corrections) |
//! | `car_ids` | N4.2: wire car ids (MP-D6: never reused within 30 s) |
//! | `metrics` | `wb_rooms`, `wb_room_tick_seconds`, offences, drops |
//!
//! **Locks.** The registry (`Shared::registry`, one `std::sync::Mutex`) is taken to create,
//! find or unregister a room and when a seat is taken or released: never per tick and never
//! across an `.await`. Lock order: the registry is released before the presence hub is
//! called. Per-tick data lives in the room task alone.

pub mod car_ids;
pub mod clock;
pub mod metrics;
pub mod plausibility;
pub mod road;
pub mod room;
pub mod sim_traffic;
mod task;
#[cfg(test)]
mod tests;
pub mod traffic;
pub mod traffic_stream;

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use protocol::{
    AccountId, ChatItem, Code, CrewTag, Density, DisplayName, ErrorCode, HitReport, Identity,
    PlayerState, RoomHostCommand, RoomListEntry, RoomSettings, RunEvent, TimeMode, Visibility,
};
use sqlx::SqliteConnection;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

pub use metrics::RoomMetrics;
pub use room::{Joined, Refusal};

use crate::config::{Config, ROOM_TRAFFIC_SIM};
use crate::map::ServerMap;
use crate::presence::{PresenceHub, RoomPresence};
use crate::sessions::SessionHandle;
use crate::tick::{MonotonicTickClock, TickClock};
use clock::{ClockShape, RoomTime};
use plausibility::CheckLimits;
use room::{Cmd, JoinReq, Room};
use sim_traffic::{GapRules, SimTraffic, SimTrafficData};
use traffic::{NoTraffic, RoomTraffic};
use traffic_stream::StreamRules;

/// `Error.detail` texts of the registry.
pub const DETAIL_SERVER_FULL: &str = "All rooms are full. Try again soon.";
pub const DETAIL_ROOM_NOT_FOUND: &str = "No room with that code.";
pub const DETAIL_PUBLIC_CREATE: &str = "Public rooms are run by the server.";
pub const DETAIL_ROOM_BUSY: &str = "The room did not answer. Try again.";

const KMH_PER_MPS: f64 = 3.6;
const MM_PER_M: f64 = 1_000.0;
const PCT: f64 = 100.0;
const MS_PER_S: u64 = 1_000;

/// `[rooms]` (and the tick rate and room cap) converted once to the units the rooms use.
#[derive(Debug, Clone, PartialEq)]
pub struct RoomParams {
    pub tick_rate_hz: u32,
    pub max_players: u8,
    pub max_rooms: usize,
    pub empty_close_ms: u64,
    pub seat_hold_ms: u64,
    pub protection_ms: u64,
    pub crash_respawn_ms: u64,
    pub placement_grace_ms: u64,
    pub spawn_behind_mm: u32,
    pub clock: ClockShape,
    pub command_queue: usize,
    pub join_timeout: Duration,
    pub checks: CheckLimits,
    pub gap: GapRules,
    /// `rooms.traffic = "sim"`.
    pub traffic_sim: bool,
    /// Traffic streaming (`rooms.traffic_*`).
    pub stream: StreamRules,
}

impl RoomParams {
    pub fn from_config(cfg: &Config) -> Self {
        let r = &cfg.rooms;
        let rate = u32::from(cfg.gateway.tick_rate_hz.max(1));
        let ms_ticks = |ms: u64| ms_to_ticks(ms, rate);
        Self {
            tick_rate_hz: rate,
            max_players: r.max_players,
            max_rooms: cfg.limits.max_rooms,
            empty_close_ms: r.empty_close_ms,
            seat_hold_ms: r.seat_hold_ms,
            protection_ms: r.protection_ms,
            crash_respawn_ms: r.crash_respawn_ms,
            placement_grace_ms: r.placement_grace_ms,
            spawn_behind_mm: (r.spawn_behind_leader_m * MM_PER_M).round() as u32,
            clock: ClockShape {
                cycle_len_ms: r.cycle_len_ms,
                day_len_ms: r.day_len_ms,
                epoch_unix_ms: r.clock_epoch_unix_ms,
            },
            command_queue: r.command_queue,
            join_timeout: Duration::from_millis(r.join_timeout_ms),
            checks: CheckLimits {
                tick_rate_hz: f64::from(rate),
                speed_cap_mps: r.max_speed_kmh / KMH_PER_MPS * (1.0 + r.speed_tolerance_pct / PCT),
                accel_cap_mps2: r.max_accel_mps2 * (1.0 + r.capability_tolerance_pct / PCT),
                lateral_cap_mps: r.max_lateral_speed_mps * (1.0 + r.capability_tolerance_pct / PCT),
                lateral_margin_m: r.lateral_margin_m,
                slack_m: r.position_slack_m,
                future_ticks: ms_ticks(r.future_tolerance_ms),
                stale_ticks: ms_ticks(r.stale_state_ms),
                placement_radius_m: r.placement_radius_m,
            },
            gap: GapRules {
                search_m: r.spawn_search_m,
                step_m: r.spawn_step_m,
                clear_m: r.spawn_clear_m,
            },
            traffic_sim: r.traffic == ROOM_TRAFFIC_SIM,
            stream: StreamRules {
                aoi_behind_mm: (r.traffic_aoi_behind_m * MM_PER_M).round() as i64,
                aoi_ahead_mm: (r.traffic_aoi_ahead_m * MM_PER_M).round() as i64,
                hysteresis_mm: (r.traffic_aoi_hysteresis_m * MM_PER_M).round() as i64,
                near_mm: (r.traffic_near_m * MM_PER_M).round() as i64,
                near_period_ticks: (rate / r.traffic_near_hz.max(1)).max(1),
                far_period_ticks: (rate / r.traffic_far_hz.max(1)).max(1),
                car_id_hold_ticks: ms_ticks(r.traffic_car_id_hold_ms),
            },
        }
    }

    /// Milliseconds as room ticks (rounded up: a hold never ends early).
    pub fn ms_to_ticks(&self, ms: u64) -> u32 {
        ms_to_ticks(ms, self.tick_rate_hz)
    }
}

fn ms_to_ticks(ms: u64, rate_hz: u32) -> u32 {
    u32::try_from((ms * u64::from(rate_hz)).div_ceil(MS_PER_S)).unwrap_or(u32::MAX)
}

/// What the registry (the browser, Quick Join, presence) knows about a live room; the
/// room task keeps it current.
#[derive(Debug)]
pub struct RoomInfo {
    pub room_id: u32,
    pub code: Code,
    pub visibility: Visibility,
    pub max_players: u8,
    players: AtomicU8,
    density: AtomicU8,
    night: AtomicBool,
}

impl RoomInfo {
    fn new(room_id: u32, code: Code, settings: &RoomSettings) -> Self {
        Self {
            room_id,
            code,
            visibility: settings.visibility,
            max_players: settings.max_players,
            players: AtomicU8::new(0),
            density: AtomicU8::new(settings.density.to_u8()),
            night: AtomicBool::new(false),
        }
    }

    pub fn players(&self) -> u8 {
        self.players.load(Ordering::Relaxed)
    }

    pub fn density(&self) -> Density {
        Density::from_u8(self.density.load(Ordering::Relaxed)).unwrap_or(Density::Normal)
    }

    pub fn night(&self) -> bool {
        self.night.load(Ordering::Relaxed)
    }

    fn set_players(&self, n: usize) {
        self.players
            .store(u8::try_from(n).unwrap_or(u8::MAX), Ordering::Relaxed);
    }

    fn set_density(&self, d: Density) {
        self.density.store(d.to_u8(), Ordering::Relaxed);
    }

    /// Returns true when it changed.
    fn set_night(&self, night: bool) -> bool {
        self.night.swap(night, Ordering::Relaxed) != night
    }
}

#[derive(Clone)]
struct Entry {
    tx: mpsc::Sender<Cmd>,
    info: Arc<RoomInfo>,
    clock: Arc<dyn TickClock>,
}

#[derive(Default)]
struct Registry {
    rooms: HashMap<u32, Entry>,
    codes: HashMap<Code, u32>,
    /// Account → the room holding its seat (connected or held).
    seats: HashMap<AccountId, u32>,
}

/// What the registry and every room share.
pub struct Shared {
    pub params: RoomParams,
    pub map: Arc<ServerMap>,
    pub presence: Arc<PresenceHub>,
    pub metrics: Arc<RoomMetrics>,
    registry: Mutex<Registry>,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Registry> {
        // Single map operations under the lock: a poisoned lock is still consistent.
        self.registry.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn seat_taken(&self, account: AccountId, room_id: u32) {
        self.lock().seats.insert(account, room_id);
    }

    /// The seat in `room_id` is gone; presence clears unless the account sits elsewhere.
    fn seat_released(&self, account: AccountId, room_id: u32) {
        let mine = {
            let mut reg = self.lock();
            let mine = reg.seats.get(&account) == Some(&room_id);
            if mine {
                reg.seats.remove(&account);
            }
            mine
        };
        if mine {
            self.presence.set_room(account, None);
        }
    }

    /// Presence for a seat in `room_id`: in the room (`Some(joinable)`) or not (`None`,
    /// a held seat). Skipped when the account's seat is in another room now.
    fn set_presence(&self, account: AccountId, room_id: u32, joinable: Option<bool>) {
        if self.lock().seats.get(&account) != Some(&room_id) {
            return;
        }
        self.presence.set_room(
            account,
            joinable.map(|joinable| RoomPresence { room_id, joinable }),
        );
    }

    fn unregister(&self, room_id: u32) {
        let mut reg = self.lock();
        if let Some(e) = reg.rooms.remove(&room_id) {
            reg.codes.remove(&e.info.code);
            RoomMetrics::dec(&self.metrics.rooms);
        }
        reg.seats.retain(|_, r| *r != room_id);
    }
}

/// Builds a room's traffic: (settings, seed, room tick of its creation).
pub type TrafficFactory =
    Arc<dyn Fn(&RoomSettings, i64, u32) -> Box<dyn RoomTraffic> + Send + Sync>;

/// Injection points for tests (and N4.2's traffic).
#[derive(Clone)]
pub struct RoomHooks {
    /// A fresh room clock at the tick rate (tick 0 = now).
    pub tick_clock: Arc<dyn Fn(u32) -> Arc<dyn TickClock> + Send + Sync>,
    /// UTC now, in ms since the Unix epoch (a room's tick 0 for the day/night cycle).
    pub utc_ms: Arc<dyn Fn() -> i64 + Send + Sync>,
    pub traffic: TrafficFactory,
}

impl RoomHooks {
    /// Real clocks; traffic as `rooms.traffic` says.
    pub fn standard(params: &RoomParams, map: &Arc<ServerMap>) -> anyhow::Result<Self> {
        let traffic: TrafficFactory = if params.traffic_sim {
            let data = SimTrafficData::builtin().map_err(anyhow::Error::msg)?;
            let map = map.clone();
            let (gap, rules) = (params.gap, params.stream);
            Arc::new(move |s: &RoomSettings, seed, origin| {
                Box::new(SimTraffic::new(
                    &data, &map.map, s.density, seed, origin, gap, rules,
                )) as Box<dyn RoomTraffic>
            })
        } else {
            Arc::new(|_: &RoomSettings, _, _| Box::new(NoTraffic) as Box<dyn RoomTraffic>)
        };
        Ok(Self {
            tick_clock: Arc::new(|rate| {
                Arc::new(MonotonicTickClock::new(rate)) as Arc<dyn TickClock>
            }),
            utc_ms: Arc::new(unix_now_ms),
            traffic,
        })
    }
}

/// UTC now (ms).
pub fn unix_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// Where a join goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JoinTarget {
    /// `room_create`: a new private room with these settings.
    Create(RoomSettings),
    /// `room_join_code`.
    Code(Code),
    /// `room_join_id` (the browser, a friend's Join button).
    Id(u32),
    /// `quick_join`: the public room with the most players that has a seat, else a new one.
    Quick,
}

/// The rooms registry (`AppState.rooms`).
pub struct Rooms {
    shared: Arc<Shared>,
    next_id: AtomicU32,
    shutdown: CancellationToken,
    hooks: RoomHooks,
    /// Tests: builds the traffic of rooms created from now on instead of `hooks.traffic`.
    traffic_override: Mutex<Option<TrafficFactory>>,
}

impl std::fmt::Debug for Rooms {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Rooms")
            .field("rooms", &self.room_count())
            .finish_non_exhaustive()
    }
}

impl Rooms {
    pub fn new(
        cfg: &Config,
        map: Arc<ServerMap>,
        presence: Arc<PresenceHub>,
        shutdown: CancellationToken,
    ) -> anyhow::Result<Self> {
        let params = RoomParams::from_config(cfg);
        let hooks = RoomHooks::standard(&params, &map)?;
        Ok(Self::with_hooks(params, map, presence, shutdown, hooks))
    }

    pub fn with_hooks(
        params: RoomParams,
        map: Arc<ServerMap>,
        presence: Arc<PresenceHub>,
        shutdown: CancellationToken,
        hooks: RoomHooks,
    ) -> Self {
        Self {
            shared: Arc::new(Shared {
                params,
                map,
                presence,
                metrics: Arc::new(RoomMetrics::default()),
                registry: Mutex::new(Registry::default()),
            }),
            next_id: AtomicU32::new(1),
            shutdown,
            hooks,
            traffic_override: Mutex::new(None),
        }
    }

    /// Tests (probes around the traffic): rooms created from now on get their traffic from
    /// `factory`.
    pub fn set_traffic_factory(&self, factory: TrafficFactory) {
        *self
            .traffic_override
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(factory);
    }

    pub fn params(&self) -> &RoomParams {
        &self.shared.params
    }

    pub fn metrics(&self) -> &Arc<RoomMetrics> {
        &self.shared.metrics
    }

    pub fn room_count(&self) -> usize {
        self.shared.lock().rooms.len()
    }

    /// The room holding the account's seat (connected or held).
    pub fn seat_of(&self, account: AccountId) -> Option<u32> {
        self.shared.lock().seats.get(&account).copied()
    }

    /// A live room's info.
    pub fn info(&self, room_id: u32) -> Option<Arc<RoomInfo>> {
        self.shared
            .lock()
            .rooms
            .get(&room_id)
            .map(|e| e.info.clone())
    }

    /// The room with this code, if live.
    pub fn find_code(&self, code: &Code) -> Option<u32> {
        self.shared.lock().codes.get(code).copied()
    }

    /// Public rooms for `lobby_event.room_list`: fullest first, at most 64.
    pub fn browse(&self) -> Vec<RoomListEntry> {
        let reg = self.shared.lock();
        let mut out: Vec<RoomListEntry> = reg
            .rooms
            .values()
            .filter(|e| e.info.visibility == Visibility::Public)
            .map(|e| RoomListEntry {
                room_id: e.info.room_id,
                players: e.info.players(),
                max_players: e.info.max_players,
                density: e.info.density(),
                night: e.info.night(),
            })
            .collect();
        out.sort_by_key(|r| (std::cmp::Reverse(r.players), r.room_id));
        out.truncate(usize::from(protocol::messages::MAX_ROOM_LIST));
        out
    }

    /// Settings of a new public room: the spec's normal density and the UTC clock.
    pub fn public_settings(&self) -> RoomSettings {
        RoomSettings {
            visibility: Visibility::Public,
            max_players: self.shared.params.max_players,
            density: Density::Normal,
            time_mode: TimeMode::Cycle,
            fixed_cycle_ms: 0,
        }
    }

    /// Creates a room and starts its task. `Err` past `limits.max_rooms`.
    pub fn create(&self, mut settings: RoomSettings) -> Result<u32, Refusal> {
        let p = &self.shared.params;
        settings.max_players = settings.max_players.clamp(1, p.max_players);
        settings.fixed_cycle_ms = p.clock.normalize(settings.fixed_cycle_ms);
        let mut reg = self.shared.lock();
        if reg.rooms.len() >= p.max_rooms {
            return Err(Refusal::new(ErrorCode::ServerFull, DETAIL_SERVER_FULL));
        }
        let id = loop {
            let id = self.next_id.fetch_add(1, Ordering::Relaxed);
            if id != 0 && !reg.rooms.contains_key(&id) {
                break id;
            }
        };
        let code = loop {
            let c = Code(crate::social::crews::new_invite_code(
                protocol::types::CODE_LEN as u32,
            ));
            if !reg.codes.contains_key(&c) {
                break c;
            }
        };
        let clock = (self.hooks.tick_clock)(p.tick_rate_hz);
        let start_unix_ms = (self.hooks.utc_ms)();
        let time = RoomTime {
            shape: p.clock,
            start_unix_ms,
            tick_rate_hz: p.tick_rate_hz,
        };
        let origin = clock.now().tick;
        let seed = start_unix_ms ^ i64::from(id);
        let factory = self
            .traffic_override
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .unwrap_or_else(|| self.hooks.traffic.clone());
        let traffic = factory(&settings, seed, origin);
        let info = Arc::new(RoomInfo::new(id, code.clone(), &settings));
        let (tx, rx) = mpsc::channel(p.command_queue);
        let room = Room::new(
            id,
            code.clone(),
            settings.clone(),
            time,
            self.shared.clone(),
            info.clone(),
            traffic,
        );
        reg.rooms.insert(
            id,
            Entry {
                tx,
                info,
                clock: clock.clone(),
            },
        );
        reg.codes.insert(code.clone(), id);
        drop(reg);
        RoomMetrics::inc(&self.shared.metrics.rooms);
        RoomMetrics::inc(&self.shared.metrics.rooms_created);
        tracing::info!(
            room = id,
            code = %code.0,
            visibility = ?settings.visibility,
            density = ?settings.density,
            time_mode = ?settings.time_mode,
            max_players = settings.max_players,
            "room created"
        );
        tokio::spawn(task::run(
            room,
            rx,
            clock,
            self.shared.clone(),
            self.shutdown.clone(),
        ));
        Ok(id)
    }

    /// Resolves `target` (creating a room for `Create` and, when nothing fits, `Quick`).
    fn resolve(&self, target: &JoinTarget) -> Result<u32, Refusal> {
        match target {
            JoinTarget::Create(s) => {
                if s.visibility != Visibility::Private {
                    return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_PUBLIC_CREATE));
                }
                self.create(s.clone())
            }
            JoinTarget::Code(c) => self
                .find_code(c)
                .ok_or(Refusal::new(ErrorCode::RoomNotFound, DETAIL_ROOM_NOT_FOUND)),
            JoinTarget::Id(id) => {
                if self.shared.lock().rooms.contains_key(id) {
                    Ok(*id)
                } else {
                    Err(Refusal::new(ErrorCode::RoomNotFound, DETAIL_ROOM_NOT_FOUND))
                }
            }
            JoinTarget::Quick => {
                let best = {
                    let reg = self.shared.lock();
                    reg.rooms
                        .values()
                        .filter(|e| {
                            e.info.visibility == Visibility::Public
                                && e.info.players() < e.info.max_players
                        })
                        .max_by_key(|e| (e.info.players(), std::cmp::Reverse(e.info.room_id)))
                        .map(|e| e.info.room_id)
                };
                match best {
                    Some(id) => Ok(id),
                    None => self.create(self.public_settings()),
                }
            }
        }
    }

    /// Takes a seat for `session` (its account) in the target room, or takes back the
    /// account's seat there. A seat the account holds in another room is released first.
    pub async fn join(
        &self,
        target: JoinTarget,
        session: &SessionHandle,
        identity: Identity,
        crew_tag: CrewTag,
    ) -> Result<RoomLink, Refusal> {
        let room_id = self.resolve(&target)?;
        let account = session.account_id;
        let (entry, elsewhere) = {
            let reg = self.shared.lock();
            let entry = reg
                .rooms
                .get(&room_id)
                .cloned()
                .ok_or(Refusal::new(ErrorCode::RoomNotFound, DETAIL_ROOM_NOT_FOUND))?;
            let elsewhere = reg
                .seats
                .get(&account)
                .filter(|&&r| r != room_id)
                .and_then(|r| reg.rooms.get(r))
                .map(|e| e.tx.clone());
            (entry, elsewhere)
        };
        let timeout = self.shared.params.join_timeout;
        if let Some(tx) = elsewhere {
            let _ = tokio::time::timeout(timeout, tx.send(Cmd::Release { account })).await;
        }
        let (reply, rx) = oneshot::channel();
        let req = Cmd::Join(JoinReq {
            session: session.clone(),
            identity,
            crew_tag,
            reply,
        });
        let busy = Refusal::new(ErrorCode::Internal, DETAIL_ROOM_BUSY);
        let gone = Refusal::new(ErrorCode::RoomNotFound, DETAIL_ROOM_NOT_FOUND);
        match tokio::time::timeout(timeout, entry.tx.send(req)).await {
            Ok(Ok(())) => {}
            Ok(Err(_)) => return Err(gone),
            Err(_) => return Err(busy),
        }
        let joined = match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(r)) => r?,
            Ok(Err(_)) => return Err(gone),
            Err(_) => return Err(busy),
        };
        Ok(RoomLink {
            room_id,
            player_id: joined.player_id,
            session_id: session.session_id,
            reconnected: joined.reconnected,
            tx: entry.tx,
            clock: entry.clock,
            active: joined.active,
            metrics: self.shared.metrics.clone(),
            send_timeout: timeout,
        })
    }
}

/// A connection's seat: where its room messages go, and the room clock for `Pong`.
pub struct RoomLink {
    pub room_id: u32,
    pub player_id: u16,
    pub session_id: u64,
    /// The seat was taken back (a reconnect or a second login).
    pub reconnected: bool,
    tx: mpsc::Sender<Cmd>,
    clock: Arc<dyn TickClock>,
    active: Arc<AtomicBool>,
    metrics: Arc<RoomMetrics>,
    send_timeout: Duration,
}

impl std::fmt::Debug for RoomLink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RoomLink")
            .field("room_id", &self.room_id)
            .field("player_id", &self.player_id)
            .field("active", &self.is_active())
            .finish_non_exhaustive()
    }
}

impl RoomLink {
    /// False once the room let the seat go (kicked, closed, taken by a newer login).
    pub fn is_active(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }

    /// The room's tick clock (`Pong.server_tick` inside a room).
    pub fn clock(&self) -> &dyn TickClock {
        self.clock.as_ref()
    }

    /// Non-blocking; a full room queue drops the message (counted).
    fn post(&self, cmd: Cmd) {
        if let Err(mpsc::error::TrySendError::Full(_)) = self.tx.try_send(cmd) {
            self.metrics.count_drop("queue_full");
        }
    }

    pub fn state(&self, state: PlayerState) {
        self.post(Cmd::State {
            player_id: self.player_id,
            session_id: self.session_id,
            state,
        });
    }

    pub fn run_event(&self, event: RunEvent) {
        self.post(Cmd::Run {
            player_id: self.player_id,
            session_id: self.session_id,
            event,
        });
    }

    pub fn hit(&self, hit: HitReport) {
        self.post(Cmd::Hit {
            player_id: self.player_id,
            session_id: self.session_id,
            hit,
        });
    }

    pub fn host(&self, cmd: RoomHostCommand) {
        self.post(Cmd::Host {
            player_id: self.player_id,
            session_id: self.session_id,
            cmd,
        });
    }

    pub fn chat(&self, item: ChatItem) {
        self.post(Cmd::Chat {
            player_id: self.player_id,
            session_id: self.session_id,
            item,
        });
    }

    /// `room_leave`: waits for queue space (bounded by the join timeout).
    pub async fn leave(&self) {
        let cmd = Cmd::Leave {
            player_id: self.player_id,
            session_id: self.session_id,
        };
        let _ = tokio::time::timeout(self.send_timeout, self.tx.send(cmd)).await;
    }

    /// The connection ended: the room holds the seat. Must arrive, so it waits for space.
    pub async fn disconnected(&self) {
        let cmd = Cmd::Disconnected {
            player_id: self.player_id,
            session_id: self.session_id,
        };
        let _ = tokio::time::timeout(self.send_timeout, self.tx.send(cmd)).await;
    }
}

/// The account's room identity: display name, `#tag` and persistent crew tag (one query).
pub async fn identity_of(
    conn: &mut SqliteConnection,
    account: AccountId,
) -> sqlx::Result<(Identity, CrewTag)> {
    let id = i64::try_from(account.0).unwrap_or(i64::MAX);
    let player = crate::social::player(conn, id).await?;
    let (name, tag, crew) = match player {
        Some(p) => (p.display_name, p.tag, p.crew_tag.unwrap_or_default()),
        None => (String::new(), 0, String::new()),
    };
    let display_name = DisplayName::new(name).unwrap_or_else(|_| DisplayName(FALLBACK_NAME.into()));
    let identity = Identity {
        account_id: account,
        display_name,
        name_tag: tag.min(protocol::messages::MAX_NAME_TAG),
    };
    Ok((identity, CrewTag::new(crew).unwrap_or_default()))
}

/// Shown for an account whose name does not fit the wire rules (never expected).
const FALLBACK_NAME: &str = "Driver";
