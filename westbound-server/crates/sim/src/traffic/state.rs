//! Traffic on one carriageway as a structure of arrays with fixed capacity. Port of
//! `src/traffic/traffic_state.gd` (`TrafficState`), same fields, same slot allocation
//! order and the same trace hash. Every vector is allocated once in `new` and never
//! resized; a slot is live when `active[i] == 1`.
//!
//! Units: SI, road space, right-positive d. On a loop, `s` is wrapped into `[0, L)`.

use crate::trace_hash::{mix_float, mix_int, SEED};

/// `TrafficState.LaneChange`.
pub const LC_NONE: i32 = 0;
pub const LC_SIGNALING: i32 = 1;
pub const LC_MOVING: i32 = 2;

pub const FLAG_BRAKE: i32 = 1 << 0;
pub const FLAG_BRAKE_STRONG: i32 = 1 << 1;
pub const FLAG_BLINKER_LEFT: i32 = 1 << 2;
pub const FLAG_BLINKER_RIGHT: i32 = 1 << 3;
pub const FLAG_HAZARD: i32 = 1 << 4;
pub const FLAG_HEADLIGHTS: i32 = 1 << 5;
pub const FLAG_HIGH_BEAM: i32 = 1 << 6;
pub const FLAG_SCRIPTED: i32 = 1 << 7;
pub const FLAG_HIT: i32 = 1 << 8;
pub const FLAG_FAR: i32 = 1 << 9;

#[derive(Debug, Clone)]
pub struct TrafficState {
    pub capacity: usize,
    pub count: usize,
    pub next_vehicle_id: i32,
    pub active: Vec<u8>,
    pub vehicle_id: Vec<i32>,
    pub s: Vec<f64>,
    pub d: Vec<f64>,
    pub v: Vec<f64>,
    pub v0: Vec<f64>,
    pub v_lat: Vec<f64>,
    pub accel: Vec<f64>,
    pub length: Vec<f64>,
    pub width: Vec<f64>,
    pub lane: Vec<i32>,
    pub target_lane: Vec<i32>,
    pub lc_state: Vec<i32>,
    pub lc_timer: Vec<f64>,
    pub lc_duration: Vec<f64>,
    pub lc_start_d: Vec<f64>,
    pub react_timer: Vec<f64>,
    pub type_id: Vec<i32>,
    pub profile_id: Vec<i32>,
    pub model_variant: Vec<i32>,
    pub color_index: Vec<i32>,
    pub flags: Vec<i32>,
    free: Vec<i32>,
    free_top: usize,
}

impl TrafficState {
    pub fn new(slots: usize) -> Self {
        let f = || vec![0.0f64; slots];
        let n = || vec![0i32; slots];
        let mut st = TrafficState {
            capacity: slots,
            count: 0,
            next_vehicle_id: 1,
            active: vec![0; slots],
            vehicle_id: n(),
            s: f(),
            d: f(),
            v: f(),
            v0: f(),
            v_lat: f(),
            accel: f(),
            length: f(),
            width: f(),
            lane: n(),
            target_lane: n(),
            lc_state: n(),
            lc_timer: f(),
            lc_duration: f(),
            lc_start_d: f(),
            react_timer: f(),
            type_id: n(),
            profile_id: n(),
            model_variant: n(),
            color_index: n(),
            flags: n(),
            free: n(),
            free_top: 0,
        };
        st.clear();
        st
    }

    /// Frees every slot and restarts vehicle ids.
    pub fn clear(&mut self) {
        self.count = 0;
        self.next_vehicle_id = 1;
        self.free_top = self.capacity;
        for i in 0..self.capacity {
            self.active[i] = 0;
            // Lowest slot on top, so allocation order is 0, 1, 2, ...
            self.free[i] = (self.capacity - 1 - i) as i32;
            self.reset_slot(i);
        }
    }

    /// Claims a free slot, zeroes it and assigns a fresh vehicle_id. None when full.
    pub fn allocate(&mut self) -> Option<usize> {
        if self.free_top == 0 {
            return None;
        }
        self.free_top -= 1;
        let i = self.free[self.free_top] as usize;
        self.reset_slot(i);
        self.active[i] = 1;
        self.vehicle_id[i] = self.next_vehicle_id;
        self.next_vehicle_id += 1;
        self.count += 1;
        Some(i)
    }

    /// Releases slot i (despawn).
    pub fn free_slot(&mut self, i: usize) {
        debug_assert!(self.active[i] == 1, "free_slot: slot {i} is not active");
        self.active[i] = 0;
        self.free[self.free_top] = i as i32;
        self.free_top += 1;
        self.count -= 1;
    }

    #[inline]
    pub fn is_active(&self, i: usize) -> bool {
        self.active[i] == 1
    }

    pub fn is_full(&self) -> bool {
        self.free_top == 0
    }

    #[inline]
    pub fn has_flag(&self, i: usize, flag: i32) -> bool {
        (self.flags[i] & flag) != 0
    }

    #[inline]
    pub fn set_flag(&mut self, i: usize, flag: i32, on: bool) {
        if on {
            self.flags[i] |= flag;
        } else {
            self.flags[i] &= !flag;
        }
    }

    /// `TrafficState.hash_into`: every live slot, exact bits.
    pub fn hash_into(&self, mut h: u64) -> u64 {
        h = mix_int(h, self.count as i64);
        h = mix_int(h, i64::from(self.next_vehicle_id));
        for i in 0..self.capacity {
            if self.active[i] == 0 {
                continue;
            }
            h = mix_int(h, i as i64);
            h = mix_int(h, i64::from(self.vehicle_id[i]));
            h = mix_float(h, self.s[i]);
            h = mix_float(h, self.d[i]);
            h = mix_float(h, self.v[i]);
            h = mix_float(h, self.v0[i]);
            h = mix_float(h, self.v_lat[i]);
            h = mix_float(h, self.accel[i]);
            h = mix_float(h, self.length[i]);
            h = mix_float(h, self.width[i]);
            h = mix_int(h, i64::from(self.lane[i]));
            h = mix_int(h, i64::from(self.target_lane[i]));
            h = mix_int(h, i64::from(self.lc_state[i]));
            h = mix_float(h, self.lc_timer[i]);
            h = mix_float(h, self.lc_duration[i]);
            h = mix_float(h, self.lc_start_d[i]);
            h = mix_float(h, self.react_timer[i]);
            h = mix_int(h, i64::from(self.type_id[i]));
            h = mix_int(h, i64::from(self.profile_id[i]));
            h = mix_int(h, i64::from(self.model_variant[i]));
            h = mix_int(h, i64::from(self.color_index[i]));
            h = mix_int(h, i64::from(self.flags[i]));
        }
        h
    }

    pub fn trace_hash(&self) -> u64 {
        self.hash_into(SEED)
    }

    fn reset_slot(&mut self, i: usize) {
        self.vehicle_id[i] = 0;
        self.s[i] = 0.0;
        self.d[i] = 0.0;
        self.v[i] = 0.0;
        self.v0[i] = 0.0;
        self.v_lat[i] = 0.0;
        self.accel[i] = 0.0;
        self.length[i] = 0.0;
        self.width[i] = 0.0;
        self.lane[i] = 0;
        self.target_lane[i] = 0;
        self.lc_state[i] = LC_NONE;
        self.lc_timer[i] = 0.0;
        self.lc_duration[i] = 0.0;
        self.lc_start_d[i] = 0.0;
        self.react_timer[i] = 0.0;
        self.type_id[i] = 0;
        self.profile_id[i] = 0;
        self.model_variant[i] = 0;
        self.color_index[i] = 0;
        self.flags[i] = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocation_order_and_reuse() {
        let mut st = TrafficState::new(3);
        assert_eq!(st.allocate(), Some(0));
        assert_eq!(st.allocate(), Some(1));
        st.free_slot(0);
        assert_eq!(st.allocate(), Some(0));
        assert_eq!(st.vehicle_id[0], 3);
        assert_eq!(st.allocate(), Some(2));
        assert_eq!(st.allocate(), None);
        assert_eq!(st.count, 3);
    }
}
