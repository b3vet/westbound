//! A short history of the room's traffic (N6.1), for claim verification and the hit
//! cross-check. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Scoring in multiplayer →
//! Server-authoritative scoring ("The server checks each claim against its own traffic
//! state and the player's reported state at that tick").
//!
//! A player's state for room tick T arrives a little later (its one-way delay); the room
//! pairs it with the traffic **at T**, so every live car is recorded after each world step
//! into a ring of `depth` ticks (the room keeps `rooms.stale_state_ms` of states, and so
//! of traffic). A record is compact (28 bytes): the wire car id, the sim lane, s in mm (as
//! the wire), and d, speed, lateral speed and body size as `f32`. Recording copies the
//! live cars once per tick (about 0.9k at normal density, ~25 KB), into buffers allocated
//! once: nothing allocates per tick.

use sim::traffic::TrafficState;

const NO_TICK: u32 = u32::MAX;
const MM_PER_M: f64 = 1_000.0;

/// One car at one tick.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct CarSample {
    pub car_id: u16,
    /// Sim lane (0 = next to the median); the ramp pseudo-lane is the lane count.
    pub lane: i8,
    /// s wrapped into [0, L), mm.
    pub s_mm: u32,
    /// Lateral offset (m, + right of travel).
    pub d: f32,
    /// Speed along the road and lateral speed (m/s).
    pub v: f32,
    pub v_lat: f32,
    /// Body size (m).
    pub length: f32,
    pub width: f32,
}

impl CarSample {
    /// Heading relative to the road as scoring turns traffic hulls: atan2(v_lat, v).
    pub fn yaw(&self) -> f64 {
        f64::from(self.v_lat).atan2(f64::from(self.v))
    }
}

#[derive(Debug)]
pub struct CarHistory {
    depth: usize,
    cap: usize,
    /// Per ring entry: the room tick it holds (NO_TICK: empty) and how many cars.
    ticks: Vec<u32>,
    counts: Vec<usize>,
    cars: Vec<CarSample>,
    latest: Option<u32>,
}

impl CarHistory {
    /// `depth` ticks of up to `cap` cars (the sim's slot capacity).
    pub fn new(depth: usize, cap: usize) -> Self {
        let depth = depth.max(1);
        Self {
            depth,
            cap,
            ticks: vec![NO_TICK; depth],
            counts: vec![0; depth],
            cars: vec![CarSample::default(); depth * cap],
            latest: None,
        }
    }

    pub fn depth(&self) -> usize {
        self.depth
    }

    /// The latest recorded room tick.
    pub fn latest_tick(&self) -> Option<u32> {
        self.latest
    }

    /// Records the live cars after the world step for room tick `tick`; `car_id(slot)`
    /// maps a sim slot to its wire id (0: none, skipped).
    pub fn record(&mut self, tick: u32, st: &TrafficState, car_id: impl Fn(usize) -> u16) {
        let e = tick as usize % self.depth;
        let base = e * self.cap;
        let mut n = 0;
        for i in 0..st.capacity.min(self.cap) {
            if st.active[i] == 0 {
                continue;
            }
            let id = car_id(i);
            if id == 0 {
                continue;
            }
            self.cars[base + n] = CarSample {
                car_id: id,
                lane: st.lane[i].clamp(i32::from(i8::MIN), i32::from(i8::MAX)) as i8,
                s_mm: (st.s[i] * MM_PER_M).round().max(0.0) as u32,
                d: st.d[i] as f32,
                v: st.v[i] as f32,
                v_lat: st.v_lat[i] as f32,
                length: st.length[i] as f32,
                width: st.width[i] as f32,
            };
            n += 1;
        }
        self.ticks[e] = tick;
        self.counts[e] = n;
        self.latest = Some(tick);
    }

    /// Records a tick from ready-made samples (tests, and traffic that is not the sim).
    pub fn record_samples(&mut self, tick: u32, samples: &[CarSample]) {
        let e = tick as usize % self.depth;
        let n = samples.len().min(self.cap);
        self.cars[e * self.cap..e * self.cap + n].copy_from_slice(&samples[..n]);
        self.ticks[e] = tick;
        self.counts[e] = n;
        self.latest = Some(tick);
    }

    /// The cars at room tick `tick`, if it is still in the ring.
    pub fn at(&self, tick: u32) -> Option<&[CarSample]> {
        let e = tick as usize % self.depth;
        if self.ticks[e] != tick {
            return None;
        }
        let base = e * self.cap;
        Some(&self.cars[base..base + self.counts[e]])
    }

    /// Car `car_id` at room tick `tick`.
    pub fn car_at(&self, tick: u32, car_id: u16) -> Option<&CarSample> {
        self.at(tick)?.iter().find(|c| c.car_id == car_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_keeps_depth_ticks() {
        let mut h = CarHistory::new(4, 8);
        let mut st = TrafficState::new(8);
        st.active[2] = 1;
        st.s[2] = 12.3456;
        st.d[2] = 5.5;
        st.v[2] = 30.0;
        st.v_lat[2] = 1.0;
        st.length[2] = 4.5;
        st.width[2] = 1.8;
        st.lane[2] = 1;
        st.active[5] = 1;
        for t in 100..106 {
            h.record(t, &st, |slot| if slot == 5 { 0 } else { 40 + slot as u16 });
        }
        assert_eq!(h.latest_tick(), Some(105));
        assert!(h.at(101).is_none(), "overwritten");
        let cars = h.at(103).expect("in the ring");
        assert_eq!(cars.len(), 1, "id 0 is skipped");
        let c = h.car_at(105, 42).expect("car 42");
        assert_eq!(c.s_mm, 12_346);
        assert_eq!(c.lane, 1);
        assert!((c.yaw() - (1.0f64).atan2(30.0)).abs() < 1e-6);
        assert!(h.car_at(105, 7).is_none());
    }
}
