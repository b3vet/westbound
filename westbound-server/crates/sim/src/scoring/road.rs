//! [`ScoringRoad`] implementations: a road with a constant cross-section (the parity
//! traces' `StraightRoadPath`, and any road with fixed lanes) and the loop map (the
//! server's official score: the lane at the player's d and the shoulder test, as the
//! client's `LoopRoadPath` answers them, lane-count tapers included).
//!
//! Cross-section (docs/CONTRACTS.md §2, `RoadPath`): d is + right of travel; the median
//! barrier's face is at `median_half_width`; the lanes start `inner_shoulder` further
//! right; lane i spans `left + [i, i + 1) × lane_width`; the outer shoulder and the
//! guardrail follow the rightmost lane.

use super::rules::ScoringRoad;
use crate::map::LoopMap;

const MM_PER_M: f64 = 1_000.0;

/// A constant cross-section (`FixtureRoadPath` / `StraightRoadPath`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LaneRoad {
    pub lanes: i32,
    pub lane_width: f64,
    pub median_half_width: f64,
    pub inner_shoulder: f64,
    pub shoulder: f64,
    pub guardrail_offset: f64,
}

impl LaneRoad {
    pub fn lanes_left_edge_d(&self) -> f64 {
        self.median_half_width + self.inner_shoulder
    }

    pub fn lanes_right_edge_d(&self) -> f64 {
        self.lanes_left_edge_d() + f64::from(self.lanes) * self.lane_width
    }

    pub fn guardrail_d(&self) -> f64 {
        self.lanes_right_edge_d() + self.shoulder + self.guardrail_offset
    }

    pub fn lane_center_d(&self, lane: i32) -> f64 {
        self.lanes_left_edge_d() + (f64::from(lane) + 0.5) * self.lane_width
    }
}

impl ScoringRoad for LaneRoad {
    fn lane_index_at(&self, d: f64, _s: f64) -> i32 {
        lane_index(d, self.lanes_left_edge_d(), self.lane_width, self.lanes)
    }

    fn is_on_shoulder(&self, d: f64, _s: f64) -> bool {
        on_shoulder(
            d,
            self.median_half_width,
            self.lanes_left_edge_d(),
            self.lanes_right_edge_d(),
            self.guardrail_d(),
        )
    }
}

/// `RoadPath.lane_index_at`.
fn lane_index(d: f64, left: f64, width: f64, lanes: i32) -> i32 {
    let x = (d - left) / width;
    if x < 0.0 {
        return -1;
    }
    // GDScript's int() truncates; x >= 0 here.
    let i = x as i64;
    if i < i64::from(lanes) {
        i as i32
    } else {
        -1
    }
}

/// `RoadPath.is_on_shoulder`.
fn on_shoulder(d: f64, median: f64, left: f64, right: f64, guardrail: f64) -> bool {
    (d >= median && d < left) || (d > right && d <= guardrail)
}

/// The loop (`LoopRoadPath`): lane counts and widths per range, the right edge following
/// a lane-count change's smoothstep taper. `s` in metres, any lap (wrapped here).
#[derive(Debug, Clone, Copy)]
pub struct LoopRoad<'a> {
    pub map: &'a LoopMap,
}

impl<'a> LoopRoad<'a> {
    pub fn new(map: &'a LoopMap) -> Self {
        Self { map }
    }

    fn s_mm(&self, s: f64) -> u32 {
        self.map
            .wrap_mm((self.map.wrap_m(s) * MM_PER_M).floor() as i64)
    }

    pub fn median_half_width(&self) -> f64 {
        f64::from(self.map.cross_section.median_half_width_mm) / MM_PER_M
    }

    pub fn lanes_left_edge_d(&self) -> f64 {
        f64::from(
            self.map.cross_section.median_half_width_mm + self.map.cross_section.inner_shoulder_mm,
        ) / MM_PER_M
    }

    pub fn lane_width(&self, s: f64) -> f64 {
        f64::from(self.map.lane_range_at(self.s_mm(s)).lane_width_mm) / MM_PER_M
    }

    pub fn lane_count(&self, s: f64) -> i32 {
        i32::from(self.map.lane_count_at(self.s_mm(s)))
    }

    /// Right edge of the driving lanes, following the taper of the lane change in force.
    pub fn lanes_right_edge_d(&self, s: f64) -> f64 {
        let sm = self.s_mm(s);
        let ranges = &self.map.lanes;
        let j = ranges.partition_point(|r| r.s_start_mm <= sm).saturating_sub(1);
        let r = &ranges[j];
        let mut nl = f64::from(r.count);
        if j > 0 && r.taper_mm > 0 && sm < r.s_start_mm + r.taper_mm {
            let n0 = f64::from(ranges[j - 1].count);
            let s0 = f64::from(r.s_start_mm);
            let t = ((f64::from(sm) - s0) / f64::from(r.taper_mm)).clamp(0.0, 1.0);
            nl = n0 + (nl - n0) * (t * t * (3.0 - 2.0 * t));
        }
        self.lanes_left_edge_d() + nl * self.lane_width(s)
    }

    pub fn guardrail_d(&self, s: f64) -> f64 {
        let c = &self.map.cross_section;
        self.lanes_right_edge_d(s)
            + f64::from(c.shoulder_mm) / MM_PER_M
            + f64::from(c.guardrail_offset_mm) / MM_PER_M
    }
}

impl ScoringRoad for LoopRoad<'_> {
    fn lane_index_at(&self, d: f64, s: f64) -> i32 {
        lane_index(d, self.lanes_left_edge_d(), self.lane_width(s), self.lane_count(s))
    }

    fn is_on_shoulder(&self, d: f64, s: f64) -> bool {
        on_shoulder(
            d,
            self.median_half_width(),
            self.lanes_left_edge_d(),
            self.lanes_right_edge_d(s),
            self.guardrail_d(s),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROAD: LaneRoad = LaneRoad {
        lanes: 3,
        lane_width: 3.6,
        median_half_width: 0.5,
        inner_shoulder: 1.2,
        shoulder: 3.0,
        guardrail_offset: 0.5,
    };

    #[test]
    fn lanes_and_shoulders() {
        assert_eq!(ROAD.lane_index_at(1.69, 0.0), -1);
        assert_eq!(ROAD.lane_index_at(1.71, 0.0), 0);
        assert_eq!(ROAD.lane_index_at(ROAD.lane_center_d(2), 0.0), 2);
        assert_eq!(ROAD.lane_index_at(12.6, 0.0), -1);
        assert!(ROAD.is_on_shoulder(1.0, 0.0));
        assert!(!ROAD.is_on_shoulder(0.4, 0.0), "inside the median barrier");
        assert!(ROAD.is_on_shoulder(13.0, 0.0));
        assert!(!ROAD.is_on_shoulder(ROAD.lane_center_d(1), 0.0));
    }

    #[test]
    fn the_loop_agrees_with_its_lane_ranges() {
        let map =
            LoopMap::from_json(include_str!("../../../../data/maps/loop_v1.json")).expect("loop_v1");
        let road = LoopRoad::new(&map);
        for r in &map.lanes {
            let s = f64::from(r.s_start_mm + r.taper_mm) / MM_PER_M + 1.0;
            let n = i32::from(r.count);
            assert_eq!(road.lane_count(s), n);
            let w = f64::from(r.lane_width_mm) / MM_PER_M;
            let left = road.lanes_left_edge_d();
            assert_eq!(road.lane_index_at(left + (f64::from(n) - 0.5) * w, s), n - 1);
            assert_eq!(road.lane_index_at(left + (f64::from(n) + 0.5) * w, s), -1);
            assert!(road.is_on_shoulder(left + f64::from(n) * w + 0.5, s));
            // Any lap.
            let lap = map.length_m();
            assert_eq!(road.lane_count(s + 3.0 * lap), n);
        }
    }
}
