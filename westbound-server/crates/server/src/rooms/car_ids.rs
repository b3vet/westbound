//! Traffic `car_id` allocation for one room (N4.2; MP-D6, docs/PROTOCOL.md §12): the wire's
//! u16 car ids come from a free list, and an id is never handed out again within
//! `hold_ticks` (30 s) of its release, so a despawn still in flight to a client can never
//! be confused with a new car. Id 0 is never used (`hit_report.car_id` 0 = not traffic).
//!
//! Released ids queue in release order; an allocation takes the oldest one once it has
//! been held long enough, else a fresh id. A room churns a few cars a minute through its
//! ramps, so the queue stays short and fresh ids last for days. Allocation-free once the
//! queue's capacity covers the releases of one hold period.

use std::collections::VecDeque;

use super::plausibility::tick_diff;

/// Ids 1..=65535.
const FIRST_ID: u32 = 1;
const LAST_ID: u32 = u16::MAX as u32;

#[derive(Debug, Clone)]
pub struct CarIds {
    hold_ticks: u32,
    next_fresh: u32,
    /// (id, release tick), oldest first.
    released: VecDeque<(u16, u32)>,
    live: u32,
    /// Allocations that had to take an id inside its hold (every fresh id in use and none
    /// held long enough). Never expected: 65,535 ids against about 1,700 live.
    pub early_reuses: u64,
}

impl CarIds {
    /// `queue_capacity`: releases the queue holds without growing.
    pub fn new(hold_ticks: u32, queue_capacity: usize) -> Self {
        Self {
            hold_ticks,
            next_fresh: FIRST_ID,
            released: VecDeque::with_capacity(queue_capacity),
            live: 0,
            early_reuses: 0,
        }
    }

    /// A car id for a car appearing at room tick `now`.
    pub fn alloc(&mut self, now: u32) -> u16 {
        self.live += 1;
        if let Some(&(id, at)) = self.released.front() {
            if tick_diff(at, now) >= i64::from(self.hold_ticks) {
                self.released.pop_front();
                return id;
            }
        }
        if self.next_fresh <= LAST_ID {
            let id = self.next_fresh as u16;
            self.next_fresh += 1;
            return id;
        }
        match self.released.pop_front() {
            Some((id, _)) => {
                self.early_reuses += 1;
                id
            }
            // Every id is live: cannot happen with a 1,600-car ring.
            None => 0,
        }
    }

    /// `id`'s car left at room tick `now`.
    pub fn release(&mut self, id: u16, now: u32) {
        if id == 0 {
            return;
        }
        self.live = self.live.saturating_sub(1);
        self.released.push_back((id, now));
    }

    /// Ids in use.
    pub fn live(&self) -> u32 {
        self.live
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_reuses_within_the_hold_and_never_zero() {
        let hold = 600;
        let mut ids = CarIds::new(hold, 16);
        let a = ids.alloc(0);
        let b = ids.alloc(0);
        assert_eq!((a, b), (1, 2));
        ids.release(a, 10);
        // Within the hold: fresh ids.
        assert_eq!(ids.alloc(11), 3);
        assert_eq!(ids.alloc(609), 4);
        // Held long enough: the released id comes back.
        assert_eq!(ids.alloc(610), a);
        assert_eq!(ids.live(), 4);
    }

    #[test]
    fn heavy_churn_keeps_the_rule() {
        // 2,000 live cars, one replaced every tick for 20 minutes: every reuse is at least
        // the hold after its release.
        let hold = 600;
        let mut ids = CarIds::new(hold, 1_024);
        let mut live: VecDeque<u16> = (0..2_000).map(|_| ids.alloc(0)).collect();
        let mut released_at = vec![None::<u32>; 65_536];
        for now in 1..24_000u32 {
            let out = live.pop_front().unwrap();
            ids.release(out, now);
            released_at[usize::from(out)] = Some(now);
            let id = ids.alloc(now);
            assert_ne!(id, 0);
            if let Some(t) = released_at[usize::from(id)] {
                assert!(now - t >= hold, "id {id} reused after {} ticks", now - t);
            }
            live.push_back(id);
        }
        assert_eq!(ids.early_reuses, 0);
        // Reuse kicks in: fresh ids stop growing once the queue holds old enough ids.
        assert!(ids.next_fresh < 3_000, "{}", ids.next_fresh);
    }

    #[test]
    fn wraps_through_the_tick_counter() {
        let mut ids = CarIds::new(600, 4);
        let a = ids.alloc(u32::MAX - 10);
        ids.release(a, u32::MAX - 10);
        assert_ne!(ids.alloc(100), a, "within the hold across the wrap");
        assert_eq!(ids.alloc(590), a);
    }
}
