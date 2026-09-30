//! The road-space queries the traffic sim needs (the GDScript `RoadPath` subset: lane
//! count, lane width, left edge, lane centers, lane flow speeds) plus the loop's wrap
//! math. Two shapes:
//!
//! - an open straight road (`RoadSpace::straight`): the parity fixture, the same numbers
//!   as the client's `StraightRoadPath`; `signed_delta(a, b)` is exactly `b - a`;
//! - the loop (`RoadSpace::from_loop`), built from [`LoopMap`]: s wraps modulo L and every
//!   distance is the wrapped signed difference (multiplayer handoff → The loop map).
//!
//! All queries are allocation-free (binary searches over vectors built once).

use crate::map::{LoopMap, RampKind, MM_PER_M};

/// `Units.KMH_PER_MPS`.
pub const KMH_PER_MPS: f64 = 3.6;

/// A lane-count change: lanes `min(before, after)..max(before, after)` are closed over
/// `[s_start, s_end]` (the change's start and taper), as `TrafficSim.sync_road_closures`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LaneCountChange {
    pub s_start: f64,
    pub s_end: f64,
    pub before: i32,
    pub after: i32,
}

/// A ramp on the right side (loop only).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RampSpan {
    pub on: bool,
    /// Off-ramp: where the diverge starts; on-ramp: where the merge starts.
    pub s: f64,
    pub length: f64,
}

/// A road works zone (loop only; the room toggles it).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClosureZoneSpan {
    pub s_start: f64,
    pub s_end: f64,
    pub lanes_closed_from_right: i32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RoadSpace {
    /// L on a loop (m), 0 on an open road.
    period: f64,
    left_edge_d: f64,
    range_start: Vec<f64>,
    range_count: Vec<i32>,
    range_width: Vec<f64>,
    section_start: Vec<f64>,
    /// Per section, lane flow speeds from the rightmost lane (m/s).
    section_flows: Vec<Vec<f64>>,
    pub lane_changes: Vec<LaneCountChange>,
    pub ramps: Vec<RampSpan>,
    pub closure_zones: Vec<ClosureZoneSpan>,
}

impl RoadSpace {
    /// An open straight road with a constant cross-section (the client's
    /// `StraightRoadPath`), lane flow speeds from `TrafficTuning`.
    pub fn straight(
        lanes: i32,
        left_edge_d: f64,
        lane_width: f64,
        flows_from_right_mps: &[f64],
    ) -> Self {
        RoadSpace {
            period: 0.0,
            left_edge_d,
            range_start: vec![f64::NEG_INFINITY],
            range_count: vec![lanes],
            range_width: vec![lane_width],
            section_start: vec![f64::NEG_INFINITY],
            section_flows: vec![flows_from_right_mps.to_vec()],
            lane_changes: Vec::new(),
            ramps: Vec::new(),
            closure_zones: Vec::new(),
        }
    }

    /// The loop map in metres.
    pub fn from_loop(map: &LoopMap) -> Self {
        let m = |mm: u32| f64::from(mm) / MM_PER_M;
        let cs = &map.cross_section;
        let mut lane_changes = Vec::new();
        let n = map.lanes.len();
        for (i, r) in map.lanes.iter().enumerate() {
            let prev = &map.lanes[(i + n - 1) % n];
            if prev.count != r.count {
                lane_changes.push(LaneCountChange {
                    s_start: m(r.s_start_mm),
                    s_end: m(r.s_start_mm) + m(r.taper_mm),
                    before: i32::from(prev.count),
                    after: i32::from(r.count),
                });
            }
        }
        RoadSpace {
            period: map.length_m(),
            left_edge_d: m(cs.median_half_width_mm) + m(cs.inner_shoulder_mm),
            range_start: map.lanes.iter().map(|r| m(r.s_start_mm)).collect(),
            range_count: map.lanes.iter().map(|r| i32::from(r.count)).collect(),
            range_width: map.lanes.iter().map(|r| m(r.lane_width_mm)).collect(),
            section_start: map.sections.iter().map(|s| m(s.s_start_mm)).collect(),
            section_flows: map
                .sections
                .iter()
                .map(|s| {
                    s.lane_flow_speeds_from_right_kmh
                        .iter()
                        .map(|k| k / KMH_PER_MPS)
                        .collect()
                })
                .collect(),
            lane_changes,
            ramps: map
                .ramps
                .iter()
                .map(|r| RampSpan {
                    on: r.kind == RampKind::On,
                    s: m(r.s_mm),
                    length: m(r.length_mm),
                })
                .collect(),
            closure_zones: map
                .closure_zones
                .iter()
                .map(|z| ClosureZoneSpan {
                    s_start: m(z.s_start_mm),
                    s_end: m(z.s_end_mm),
                    lanes_closed_from_right: i32::from(z.lanes_closed_from_right),
                })
                .collect(),
        }
    }

    /// L (m) on a loop, 0 on an open road (`RoadPath.period_m`).
    #[inline]
    pub fn period(&self) -> f64 {
        self.period
    }

    /// s modulo L in `[0, L)` on a loop; unchanged on an open road.
    #[inline]
    pub fn wrap(&self, s: f64) -> f64 {
        if self.period > 0.0 {
            let r = s.rem_euclid(self.period);
            if r >= self.period {
                0.0
            } else {
                r
            }
        } else {
            s
        }
    }

    /// How far `b` is ahead of `a`: exactly `b - a` on an open road, the wrapped signed
    /// difference in `[-L/2, L/2)` on a loop (both in `[0, L)`).
    #[inline]
    pub fn signed_delta(&self, a: f64, b: f64) -> f64 {
        let x = b - a;
        if self.period > 0.0 {
            let half = self.period * 0.5;
            if x >= half {
                return x - self.period;
            }
            if x < -half {
                return x + self.period;
            }
        }
        x
    }

    #[inline]
    fn range_index(&self, s: f64) -> usize {
        let s = self.wrap(s);
        self.range_start
            .partition_point(|x| *x <= s)
            .saturating_sub(1)
    }

    #[inline]
    pub fn lane_count(&self, s: f64) -> i32 {
        self.range_count[self.range_index(s)]
    }

    #[inline]
    pub fn lane_width(&self, s: f64) -> f64 {
        self.range_width[self.range_index(s)]
    }

    #[inline]
    pub fn lanes_left_edge_d(&self, _s: f64) -> f64 {
        self.left_edge_d
    }

    /// d of lane `lane`'s center (`RoadPath.lane_center_d`).
    #[inline]
    pub fn lane_center_d(&self, lane: i32, s: f64) -> f64 {
        self.lanes_left_edge_d(s) + (f64::from(lane) + 0.5) * self.lane_width(s)
    }

    /// Right edge of the rightmost driving lane. On the loop it follows a lane change's
    /// taper: from `s_start` the edge moves from the previous count to the new one along
    /// a smoothstep over the taper (docs/LOOP_MAP.md → Road-space file, `lanes`).
    pub fn lanes_right_edge_d(&self, s: f64) -> f64 {
        let mut lanes = f64::from(self.lane_count(s));
        for c in &self.lane_changes {
            let into = self.signed_delta(c.s_start, s);
            let taper = c.s_end - c.s_start;
            if into >= 0.0 && into < taper {
                let u = into / taper;
                let k = u * u * (3.0 - 2.0 * u);
                lanes = f64::from(c.before) + (f64::from(c.after) - f64::from(c.before)) * k;
            }
        }
        self.lanes_left_edge_d(s) + lanes * self.lane_width(s)
    }

    #[inline]
    pub fn section_index(&self, s: f64) -> usize {
        let s = self.wrap(s);
        self.section_start
            .partition_point(|x| *x <= s)
            .saturating_sub(1)
    }

    pub fn section_count(&self) -> usize {
        self.section_start.len()
    }

    /// Flow speed of lane `lane` of `lanes` (`TrafficTuning.lane_flow_speed_mps` on the
    /// open road, the section's list on the loop: `LoopRoadPath.lane_flow_speed_mps`).
    #[inline]
    pub fn lane_flow_speed_mps(&self, lane: i32, lanes: i32, s: f64) -> f64 {
        let list = &self.section_flows[self.section_index(s)];
        let i = (lanes - 1 - lane).clamp(0, list.len() as i32 - 1);
        list[i as usize]
    }

    /// Start of each lane range (m) and its lane count (loop fill, density).
    pub fn lane_ranges(&self) -> impl Iterator<Item = (f64, f64, i32)> + '_ {
        (0..self.range_start.len()).map(move |i| {
            let end = if i + 1 < self.range_start.len() {
                self.range_start[i + 1]
            } else if self.period > 0.0 {
                self.period
            } else {
                f64::INFINITY
            };
            (self.range_start[i], end, self.range_count[i])
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn straight_road_is_exact() {
        let r = RoadSpace::straight(3, 1.7, 3.6, &[25.0, 30.0]);
        assert_eq!(r.signed_delta(10.0, 3.0), 3.0 - 10.0);
        assert_eq!(r.lane_count(-1e9), 3);
        assert_eq!(r.lane_center_d(1, 0.0), 1.7 + 1.5 * 3.6);
        assert_eq!(r.lane_flow_speed_mps(2, 3, 0.0), 25.0);
        assert_eq!(r.lane_flow_speed_mps(0, 3, 0.0), 30.0);
    }

    #[test]
    fn loop_wraps_and_steps_lanes() {
        let map = LoopMap::from_json(include_str!("../../../../data/maps/loop_v1.json")).unwrap();
        let r = RoadSpace::from_loop(&map);
        assert_eq!(r.period(), 25_000.0);
        assert_eq!(r.signed_delta(24_990.0, 10.0), 20.0);
        assert_eq!(r.signed_delta(10.0, 24_990.0), -20.0);
        assert_eq!(r.wrap(-1.0), 24_999.0);
        assert_eq!(r.lane_count(100.0), 3);
        assert_eq!(r.lane_count(1_000.0), 4);
        assert_eq!(r.lane_count(6_500.0), 2);
        assert_eq!(r.lane_count(25_100.0), 3);
        // 3 -> 4 at 320, 4 -> 3 at 4450, 3 -> 2, 2 -> 3, 3 -> 4 (city), 4 -> 3 (farmland).
        assert_eq!(r.lane_changes.len(), 6);
        assert_eq!(r.ramps.len(), 4);
        // City flows, rightmost lane 85 km/h.
        assert_eq!(r.lane_flow_speed_mps(3, 4, 17_000.0), 85.0 / 3.6);
    }
}
