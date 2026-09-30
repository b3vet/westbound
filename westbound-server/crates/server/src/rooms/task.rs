//! A room's tokio task (N5.1): owns the [`Room`], drains its bounded command queue as
//! commands arrive and runs one room tick per 20 Hz tick of the room's clock. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → Architecture ("Each room is one tokio task that owns
//! its state outright (no shared locks in the hot path). Rooms talk to connections only
//! through bounded channels."), Resource budget (room tick p99 under 5 ms).
//!
//! The timer fires in the **middle** of each clock tick, so a tick boundary never races it:
//! the clock's tick number, not the timer, says which room tick runs (a late wake-up runs
//! the latest tick once; the room's timers compare tick numbers, so none is missed). Each
//! tick's wall time goes into `wb_room_tick_seconds`.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc;
use tokio::time::{Instant, MissedTickBehavior};
use tokio_util::sync::CancellationToken;

use super::room::{Cmd, Room};
use super::Shared;
use crate::tick::TickClock;

const NANOS_PER_SEC: f64 = 1e9;
const FRACTION_ONE: f64 = 65_536.0;

pub(crate) async fn run(
    mut room: Room,
    mut rx: mpsc::Receiver<Cmd>,
    clock: Arc<dyn TickClock>,
    shared: Arc<Shared>,
    shutdown: CancellationToken,
) {
    let rate = f64::from(clock.rate_hz().max(1));
    let period = Duration::from_nanos((NANOS_PER_SEC / rate) as u64);
    let into = f64::from(clock.now().fraction) / FRACTION_ONE;
    // Delay to the middle of the current or next tick.
    let wait = (1.5 - into).rem_euclid(1.0);
    let mut interval = tokio::time::interval_at(Instant::now() + period.mul_f64(wait), period);
    interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let metrics = shared.metrics.clone();
    loop {
        tokio::select! {
            biased;
            _ = shutdown.cancelled() => {
                room.close();
                break;
            }
            _ = interval.tick() => {
                let t0 = std::time::Instant::now();
                let keep = room.advance_to(clock.now().tick);
                metrics.observe_tick(t0.elapsed());
                if !keep {
                    tracing::info!(room = room.id, "room closed (empty)");
                    break;
                }
            }
            cmd = rx.recv() => match cmd {
                Some(c) => room.on_cmd(c, clock.now().tick),
                None => break,
            },
        }
    }
    // Unregister first: later sends fail and the joins waiting in the queue are refused
    // (their reply channels drop with it).
    shared.unregister(room.id);
    rx.close();
}
