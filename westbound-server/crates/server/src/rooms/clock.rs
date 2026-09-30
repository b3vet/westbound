//! The room clock (N5.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Time of day in
//! multiplayer ("Cycle: 32 minutes long, with 22 minutes of day … and 10 minutes of night";
//! "Public rooms: the clock is derived from UTC time"; "Private rooms: the host can pick the
//! cycle, a fixed time of day, or permanent night"; "Night ×2"). Wire form: docs/PROTOCOL.md
//! §4 `RoomClock` (position in the cycle at a reference tick; clients advance it with
//! `server_now()` in `cycle` mode and hold it otherwise).
//!
//! **Agreement with the client.** The game's loop-mode clock (`src/run/room_clock.gd`,
//! `RoomClock.phase_s`) is `fposmod(unix_s - epoch, cycle)` with the numbers of
//! `data/tuning/loop.tres`. The server computes the same thing in integer milliseconds:
//! `cycle_ms = (unix_ms - epoch_ms) mod cycle_len_ms` ([`ClockShape::utc_cycle_ms`]). A room
//! reads the UTC time once, when it is created (its tick 0), and every later tick is exactly
//! `1000 / tick_rate_hz` ms on from it, so `cycle_ms` at tick T is the UTC-derived phase of
//! that instant, to the millisecond. `cycle` mode is UTC-derived in private rooms too (so a
//! private room left on its defaults matches the public clock and counts for the boards).
//! `fixed` holds `fixed_cycle_ms` (taken modulo the cycle); `night` holds the middle of the
//! night.

use protocol::{RoomClock, RoomSettings, TimeMode};

const MS_PER_S: i64 = 1_000;

/// The cycle's shape (from `[rooms]`, mirroring loop.tres).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockShape {
    /// Full cycle (spec: 32 min).
    pub cycle_len_ms: u32,
    /// Day part at the start of the cycle (spec: 22 min); night is the rest.
    pub day_len_ms: u32,
    /// UTC instant (ms since the Unix epoch) at which a cycle starts.
    pub epoch_unix_ms: i64,
}

impl ClockShape {
    /// Position in the cycle (ms, in `[0, cycle)`) at a UTC instant: the client's
    /// `RoomClock.phase_s()` in milliseconds.
    pub fn utc_cycle_ms(&self, unix_ms: i64) -> u32 {
        // In [0, cycle) and the cycle fits u32.
        (unix_ms - self.epoch_unix_ms).rem_euclid(i64::from(self.cycle_len_ms.max(1))) as u32
    }

    /// Where permanent night holds the clock: the middle of the night.
    pub fn night_hold_ms(&self) -> u32 {
        self.day_len_ms + (self.cycle_len_ms - self.day_len_ms) / 2
    }

    /// Night ×2 is on from the end of the day to the end of the cycle.
    pub fn is_night(&self, cycle_ms: u32) -> bool {
        cycle_ms >= self.day_len_ms
    }

    /// A host's fixed position taken into the cycle.
    pub fn normalize(&self, cycle_ms: u32) -> u32 {
        cycle_ms % self.cycle_len_ms.max(1)
    }
}

/// One room's time base: the UTC instant of its tick 0 and its tick rate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RoomTime {
    pub shape: ClockShape,
    /// UTC (ms) at room tick 0 (read once, when the room is created).
    pub start_unix_ms: i64,
    pub tick_rate_hz: u32,
}

impl RoomTime {
    /// The UTC instant (ms) of a room tick.
    pub fn unix_ms_at(&self, tick: u32) -> i64 {
        self.start_unix_ms + i64::from(tick) * MS_PER_S / i64::from(self.tick_rate_hz.max(1))
    }

    /// Position in the cycle at `tick` under a room's time mode.
    pub fn cycle_ms(&self, mode: TimeMode, fixed_cycle_ms: u32, tick: u32) -> u32 {
        match mode {
            TimeMode::Cycle => self.shape.utc_cycle_ms(self.unix_ms_at(tick)),
            TimeMode::Fixed => self.shape.normalize(fixed_cycle_ms),
            TimeMode::Night => self.shape.night_hold_ms(),
        }
    }

    /// The wire `RoomClock` at `tick` (snapshots and settings changes).
    pub fn clock_at(&self, settings: &RoomSettings, tick: u32) -> RoomClock {
        RoomClock {
            cycle_ms: self.cycle_ms(settings.time_mode, settings.fixed_cycle_ms, tick),
            cycle_len_ms: self.shape.cycle_len_ms,
            day_len_ms: self.shape.day_len_ms,
        }
    }

    /// Whether night ×2 is on at `tick`.
    pub fn is_night(&self, settings: &RoomSettings, tick: u32) -> bool {
        self.shape
            .is_night(self.cycle_ms(settings.time_mode, settings.fixed_cycle_ms, tick))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::{Density, Visibility};

    const SHAPE: ClockShape = ClockShape {
        cycle_len_ms: 1_920_000,
        day_len_ms: 1_320_000,
        epoch_unix_ms: 0,
    };

    fn settings(mode: TimeMode, fixed: u32) -> RoomSettings {
        RoomSettings {
            visibility: Visibility::Private,
            max_players: 8,
            density: Density::Normal,
            time_mode: mode,
            fixed_cycle_ms: fixed,
        }
    }

    /// The client's rule (`RoomClock.phase_s`: fposmod(unix_s - epoch, cycle)), in f64
    /// seconds as GDScript computes it.
    fn client_phase_ms(unix_ms: i64) -> f64 {
        let unix_s = unix_ms as f64 / 1000.0;
        unix_s.rem_euclid(1_920.0) * 1000.0
    }

    #[test]
    fn utc_phase_matches_the_client_rule_to_the_ms() {
        for unix_ms in [
            0,
            1,
            1_919_999,
            1_920_000,
            1_790_000_000_123,
            1_790_001_320_000,
            1_790_001_919_999,
            4_102_444_800_000,
        ] {
            let server = SHAPE.utc_cycle_ms(unix_ms);
            let client = client_phase_ms(unix_ms);
            assert!(
                (f64::from(server) - client).abs() < 1.0,
                "{unix_ms}: server {server}, client {client}"
            );
        }
        // Before the epoch still lands in [0, cycle).
        assert_eq!(SHAPE.utc_cycle_ms(-1), 1_919_999);
        assert_eq!(SHAPE.night_hold_ms(), 1_620_000);
        assert!(!SHAPE.is_night(1_319_999));
        assert!(SHAPE.is_night(1_320_000));
        assert!(SHAPE.is_night(1_919_999));
    }

    #[test]
    fn room_ticks_advance_the_utc_clock_by_50_ms() {
        let t = RoomTime {
            shape: SHAPE,
            // 100 ms before a night starts.
            start_unix_ms: 1_920_000 * 1_000 + 1_319_900,
            tick_rate_hz: 20,
        };
        let s = settings(TimeMode::Cycle, 0);
        assert_eq!(t.clock_at(&s, 0).cycle_ms, 1_319_900);
        assert_eq!(t.clock_at(&s, 1).cycle_ms, 1_319_950);
        assert!(!t.is_night(&s, 1));
        assert!(t.is_night(&s, 2));
        // Wraps into the next morning.
        let to_wrap = (1_920_000 - 1_319_900) / 50;
        assert_eq!(t.clock_at(&s, to_wrap).cycle_ms, 0);
        assert_eq!(t.clock_at(&s, 0).cycle_len_ms, 1_920_000);
        assert_eq!(t.clock_at(&s, 0).day_len_ms, 1_320_000);
        // Every tick is the UTC instant's phase.
        for tick in [0u32, 7, 12_345, 1_000_000] {
            assert_eq!(
                t.clock_at(&s, tick).cycle_ms,
                SHAPE.utc_cycle_ms(t.start_unix_ms + i64::from(tick) * 50)
            );
        }
    }

    #[test]
    fn fixed_and_night_hold() {
        let t = RoomTime {
            shape: SHAPE,
            start_unix_ms: 123_456,
            tick_rate_hz: 20,
        };
        let fixed = settings(TimeMode::Fixed, 600_000);
        assert_eq!(t.clock_at(&fixed, 0).cycle_ms, 600_000);
        assert_eq!(t.clock_at(&fixed, 99_999).cycle_ms, 600_000);
        assert!(!t.is_night(&fixed, 5));
        let wrapped = settings(TimeMode::Fixed, 1_920_000 + 5);
        assert_eq!(t.clock_at(&wrapped, 0).cycle_ms, 5);
        let night = settings(TimeMode::Night, 0);
        assert_eq!(t.clock_at(&night, 3).cycle_ms, 1_620_000);
        assert!(t.is_night(&night, 1_000_000));
    }
}
