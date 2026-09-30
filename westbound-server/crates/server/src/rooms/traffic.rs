//! The room's traffic seam (N5.1 → N4.2). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Traffic:
//! server-authoritative with intents ("Players are in the simulation: each player is a
//! vehicle at its latest reported state"), Players → Spawning ("The server picks a gap in
//! traffic about 40 m behind your crew leader").
//!
//! A room owns one `Box<dyn RoomTraffic>`: [`NoTraffic`] (no cars; every spawn request is
//! already a free gap; `rooms.traffic = "none"`) or the `sim` crate's ring
//! (`sim_traffic::SimTraffic`, the default): it reads the players every tick, streams
//! `TrafficSpawn/Despawn/Intent/Correction` into each client's frame (N4.2,
//! `traffic_stream`), and moves a spawn request into a real gap.
//!
//! Contract for implementations (the room loop's rules): no blocking, no I/O, and no
//! per-tick allocation where practical (the room hands out reused buffers).

use protocol::{Density, FrameBuilder, RunState};
use sim::map::LoopMap;

use super::car_history::CarHistory;

/// A player as traffic sees it: the latest accepted state (clamped), extrapolation is the
/// traffic's own business.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlayerView {
    pub player_id: u16,
    /// Room tick of the state.
    pub tick: u32,
    pub s_mm: u32,
    pub d_cm: i16,
    pub speed_cms: u16,
    /// Heading relative to the road (1e-4 rad) and lateral velocity (cm/s), as reported.
    pub heading_e4: i16,
    pub lat_vel_cms: i16,
    pub run_state: RunState,
    /// Spawn / rejoin protection runs until this room tick (no traffic hits; traffic may
    /// also give the player room).
    pub protected_until: u32,
}

/// Where the room wants to put a player, and where it goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpawnSpot {
    pub s_mm: u32,
    /// Lane from the median (0 = fast lane), as on the client.
    pub lane: u8,
    /// Lane centre (cm, + right of travel).
    pub d_cm: i16,
    /// The lane's flow speed (cm/s).
    pub speed_cms: u16,
}

/// A room's traffic. Every method runs on the room task.
pub trait RoomTraffic: Send {
    /// One room tick, after the players' states for it were taken. `players` holds every
    /// seated player with a state (disconnected seats included: their car stays put).
    fn tick(&mut self, tick: u32, players: &[PlayerView]);

    /// The host changed the density (private rooms), or the room started with it.
    fn set_density(&mut self, density: Density);

    /// Night started or ended (the room clock): traffic headlights.
    fn set_night(&mut self, night: bool);

    /// Appends this client's traffic messages (spawns, despawns, intents, corrections for
    /// its area of interest around `s_mm`) to its tick frame. `joined` is true on the
    /// tick the client got its `RoomSnapshot` (send it its whole area).
    fn write_client(&mut self, player_id: u16, s_mm: u32, joined: bool, frame: &mut FrameBuilder);

    /// A seat was released (the player left, was kicked or timed out).
    fn player_left(&mut self, player_id: u16);

    /// A player's hit on traffic car `car_id` was accepted (N6 decides that): the car's
    /// scripted reaction (swerve, hard brake, hazards), streamed to every client that has
    /// the car. False when there is no such car. Nothing calls this before N6.
    fn hit_car(&mut self, _player_id: u16, _car_id: u16) -> bool {
        false
    }

    /// N6.1: the traffic of the last room ticks (claim verification, the hit
    /// cross-check). `None` without traffic.
    fn car_history(&self) -> Option<&CarHistory> {
        None
    }

    /// N6.1: whether car `car_id` is one this player's client was streamed (in its area of
    /// interest). A claim naming any other car is rejected.
    fn client_has(&self, _player_id: u16, _car_id: u16) -> bool {
        false
    }

    /// The free gap nearest `want` (same lane or a neighbour, within a few tens of metres),
    /// for a spawn, respawn or rejoin. The spot's speed is the traffic's local flow.
    fn free_gap(&self, map: &LoopMap, want: SpawnSpot) -> SpawnSpot;
}

/// No traffic (`rooms.traffic = "none"`): nothing to stream, and every spot is free.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoTraffic;

impl RoomTraffic for NoTraffic {
    fn tick(&mut self, _tick: u32, _players: &[PlayerView]) {}

    fn set_density(&mut self, _density: Density) {}

    fn set_night(&mut self, _night: bool) {}

    fn write_client(
        &mut self,
        _player_id: u16,
        _s_mm: u32,
        _joined: bool,
        _frame: &mut FrameBuilder,
    ) {
    }

    fn player_left(&mut self, _player_id: u16) {}

    fn free_gap(&self, _map: &LoopMap, want: SpawnSpot) -> SpawnSpot {
        want
    }
}
