//! The server tick clock used by `Pong` (docs/PROTOCOL.md §1 Clock sync: `server_now =
//! server_tick + tick_fraction / 65536`). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! Networking protocol → Clock sync; the 20 Hz tick from "Room tasks".
//!
//! Outside a room there is one server-wide clock: 20 Hz ticks counted from process start.
//! A session inside a room (N5.1) answers `Ping` with that room's clock instead (the room's
//! `TickClock`, started at room creation; `rooms::RoomHooks::tick_clock`);
//! `gateway::pong_clock` is the one place that picks the clock. Injected through `AppState`
//! so tests can pin the tick (`ManualTickClock`).

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

const NANOS_PER_SEC: u128 = 1_000_000_000;
/// `tick_fraction` is in 1/65536 of a tick.
const FRACTION_BITS: u32 = 16;

/// A tick and the elapsed part of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TickTime {
    /// Wraps at `u32::MAX` (6.8 years at 20 Hz).
    pub tick: u32,
    /// 1/65536 of a tick.
    pub fraction: u16,
}

impl TickTime {
    /// Ticks as a float (tests, logs).
    pub fn as_f64(self) -> f64 {
        f64::from(self.tick) + f64::from(self.fraction) / f64::from(1u32 << FRACTION_BITS)
    }
}

/// Converts elapsed nanoseconds at `rate_hz` into a tick and fraction (truncating).
pub fn tick_at(elapsed_nanos: u128, rate_hz: u32) -> TickTime {
    let scaled = elapsed_nanos * u128::from(rate_hz);
    let whole = scaled / NANOS_PER_SEC;
    let rem = scaled % NANOS_PER_SEC;
    TickTime {
        // Wrapping by design: the protocol's tick is a wrapping u32.
        tick: whole as u32,
        fraction: ((rem << FRACTION_BITS) / NANOS_PER_SEC) as u16,
    }
}

/// Where `Pong` reads the server tick from.
pub trait TickClock: Send + Sync + 'static {
    fn now(&self) -> TickTime;
    fn rate_hz(&self) -> u32;
}

/// Ticks since this clock was created (process start for the server-wide clock).
#[derive(Debug)]
pub struct MonotonicTickClock {
    start: Instant,
    rate_hz: u32,
}

impl MonotonicTickClock {
    pub fn new(rate_hz: u32) -> Self {
        Self {
            start: Instant::now(),
            rate_hz,
        }
    }
}

impl TickClock for MonotonicTickClock {
    fn now(&self) -> TickTime {
        tick_at(self.start.elapsed().as_nanos(), self.rate_hz)
    }

    fn rate_hz(&self) -> u32 {
        self.rate_hz
    }
}

/// A tick clock that only moves when told to (tests).
#[derive(Debug)]
pub struct ManualTickClock {
    nanos: AtomicU64,
    rate_hz: u32,
}

impl ManualTickClock {
    pub fn new(rate_hz: u32) -> Self {
        Self {
            nanos: AtomicU64::new(0),
            rate_hz,
        }
    }

    /// Sets the elapsed time since the clock's start.
    pub fn set_nanos(&self, nanos: u64) {
        self.nanos.store(nanos, Ordering::SeqCst);
    }
}

impl TickClock for ManualTickClock {
    fn now(&self) -> TickTime {
        tick_at(u128::from(self.nanos.load(Ordering::SeqCst)), self.rate_hz)
    }

    fn rate_hz(&self) -> u32 {
        self.rate_hz
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: u128 = 1_000_000;

    #[test]
    fn ticks_and_fractions_at_20_hz() {
        assert_eq!(
            tick_at(0, 20),
            TickTime {
                tick: 0,
                fraction: 0
            }
        );
        // 50 ms per tick.
        assert_eq!(
            tick_at(50 * MS, 20),
            TickTime {
                tick: 1,
                fraction: 0
            }
        );
        assert_eq!(
            tick_at(625 * MS, 20),
            TickTime {
                tick: 12,
                fraction: 32_768
            }
        );
        assert_eq!(
            tick_at(1_000 * MS + 12_500_000, 20),
            TickTime {
                tick: 20,
                fraction: 16_384
            }
        );
        // The fraction never reaches a whole tick.
        assert_eq!(
            tick_at(50 * MS - 1, 20),
            TickTime {
                tick: 0,
                fraction: 65_535
            }
        );
        assert!((tick_at(625 * MS, 20).as_f64() - 12.5).abs() < 1e-9);
    }

    #[test]
    fn wraps_like_the_wire_u32() {
        // 2^32 ticks of 50 ms, then two more.
        let one_wrap = (u128::from(u32::MAX) + 1) * 50 * MS;
        let t = tick_at(one_wrap + 100 * MS, 20);
        assert_eq!(
            t,
            TickTime {
                tick: 2,
                fraction: 0
            }
        );
    }

    #[test]
    fn clocks() {
        let m = ManualTickClock::new(20);
        m.set_nanos(75_000_000);
        assert_eq!(
            m.now(),
            TickTime {
                tick: 1,
                fraction: 32_768
            }
        );
        let c = MonotonicTickClock::new(20);
        assert_eq!(c.rate_hz(), 20);
        let a = c.now().as_f64();
        let b = c.now().as_f64();
        assert!(b >= a);
    }
}
