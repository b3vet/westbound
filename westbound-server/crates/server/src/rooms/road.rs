//! Lane geometry on the loop for rooms (N5.1): lane centres, the lane at a lateral offset,
//! the lateral bounds a car can reach, and flow speeds, all in the road-space file's
//! millimetres. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map (lane count and width
//! per s range), Players → Spawning ("at the section's flow speed").
//!
//! **Conventions** (docs/CONTRACTS.md §2, the client's `RoadPath`): `d` is positive to the
//! right of travel and the player's carriageway is `d > 0`; lane 0 is next to the median
//! (the fast lane) and indices grow to the right. Lane `i`'s centre is
//! `median_half_width + inner_shoulder + (i + 0.5) × lane_width`. The wire's `d_cm` carries
//! this `d` unchanged (the codecs only scale it). See the N5.1 handoff for the PROTOCOL.md
//! wording ("+ = left", "lane 0 = rightmost") that disagrees with the contract.

use sim::map::LoopMap;

/// Millimetres per centimetre.
pub const MM_PER_CM: i64 = 10;
/// cm/s per km/h (1 km/h = 100 000 cm / 3600 s).
pub const CMS_PER_KMH: f64 = 100_000.0 / 3_600.0;

/// Left edge of the driving lanes (mm): median half-width + inner shoulder.
pub fn lanes_left_edge_mm(map: &LoopMap) -> i64 {
    i64::from(map.cross_section.median_half_width_mm)
        + i64::from(map.cross_section.inner_shoulder_mm)
}

/// Lane width at s (mm).
pub fn lane_width_mm(map: &LoopMap, s_mm: u32) -> i64 {
    i64::from(map.lane_range_at(s_mm).lane_width_mm)
}

/// Centre of lane `lane` (0 = next to the median) at s, in mm.
pub fn lane_center_d_mm(map: &LoopMap, lane: u8, s_mm: u32) -> i64 {
    lanes_left_edge_mm(map) + (2 * i64::from(lane) + 1) * lane_width_mm(map, s_mm) / 2
}

/// The lane containing `d_mm` at s, clamped to the lanes that exist there (a car on a
/// shoulder counts as in the nearest lane).
pub fn lane_at(map: &LoopMap, d_mm: i64, s_mm: u32) -> u8 {
    let count = i64::from(map.lane_count_at(s_mm).max(1));
    let x = (d_mm - lanes_left_edge_mm(map)).div_euclid(lane_width_mm(map, s_mm).max(1));
    // In [0, count) and count ≤ 255.
    x.clamp(0, count - 1) as u8
}

/// The most lanes the road is wide at s: inside a lane-count taper the edge still moves
/// between the old and the new count, so the wider of the two counts.
pub fn lanes_wide_at(map: &LoopMap, s_mm: u32) -> u8 {
    let r = map.lane_range_at(s_mm);
    let s = map.wrap_mm(i64::from(s_mm));
    let into = s.saturating_sub(r.s_start_mm);
    if r.taper_mm > 0 && into < r.taper_mm {
        let before = map.lane_count_at(map.wrap_mm(i64::from(r.s_start_mm) - 1));
        r.count.max(before)
    } else {
        r.count
    }
}

/// Lateral range a car can reach at s (mm): from the median barrier's face to the
/// guardrail's (the client's `median_barrier_d` .. `guardrail_d`).
pub fn d_bounds_mm(map: &LoopMap, s_mm: u32) -> (i64, i64) {
    let c = &map.cross_section;
    let lo = i64::from(c.median_half_width_mm);
    let hi = lanes_left_edge_mm(map)
        + i64::from(lanes_wide_at(map, s_mm)) * lane_width_mm(map, s_mm)
        + i64::from(c.shoulder_mm)
        + i64::from(c.guardrail_offset_mm);
    (lo, hi)
}

/// Flow speed (cm/s) of lane `lane` (0 = next to the median) at s: the section's lane flow
/// speed for the lanes that exist there.
pub fn flow_speed_cms(map: &LoopMap, lane: u8, s_mm: u32) -> u16 {
    let lanes = map.lane_count_at(s_mm);
    let kmh = map.lane_flow_speed_kmh(lane.min(lanes.saturating_sub(1)), lanes, s_mm);
    // Flow speeds are a few hundred km/h at most: well inside u16 cm/s.
    (kmh * CMS_PER_KMH)
        .round()
        .clamp(0.0, f64::from(protocol::messages::MAX_SPEED_CMS)) as u16
}

/// The start gantry's spawn points (the ones right after sector 0, the start / finish
/// line): `(s_mm, lane)` in the file's order. Falls back to 150 m past s = 0 in lane 0
/// when the map has none.
pub fn start_spawn_points(map: &LoopMap) -> impl Iterator<Item = (u32, u8)> + '_ {
    let start = map.sectors.first().map_or(0, |g| g.s_mm);
    // The nearest spawn s at or after the start line.
    let first_s = map.spawn_points.iter().map(|p| p.s_mm).min_by_key(|&s| {
        map.signed_delta_mm(start, s)
            .rem_euclid(i64::from(map.length_mm()))
    });
    let fallback = (first_s.is_none()).then_some((
        map.wrap_mm(i64::from(start) + DEFAULT_SPAWN_PAST_START_MM),
        0u8,
    ));
    map.spawn_points
        .iter()
        .filter(move |p| Some(p.s_mm) == first_s)
        .map(|p| (p.s_mm, p.lane))
        .chain(fallback)
}

/// Where a map without spawn points starts its players (the loop's own rule: 150 m past
/// the start / finish gantry).
const DEFAULT_SPAWN_PAST_START_MM: i64 = 150_000;

#[cfg(test)]
mod tests {
    use super::*;

    fn loop_v1() -> std::sync::Arc<crate::map::ServerMap> {
        crate::map::builtin().expect("loop_v1")
    }

    #[test]
    fn lane_centres_and_lanes_follow_the_contract() {
        let m = loop_v1();
        let map = &m.map;
        // 0.5 m median half-width + 1.2 m inner shoulder, 3.6 m lanes (CONTRACTS.md §2).
        assert_eq!(lanes_left_edge_mm(map), 1_700);
        assert_eq!(lane_center_d_mm(map, 0, 0), 3_500);
        assert_eq!(lane_center_d_mm(map, 2, 0), 10_700);
        assert_eq!(lane_at(map, 3_500, 0), 0);
        assert_eq!(lane_at(map, 10_700, 0), 2);
        assert_eq!(
            lane_at(map, -5_000, 0),
            0,
            "the median side clamps to lane 0"
        );
        assert_eq!(
            lane_at(map, 40_000, 0),
            2,
            "the shoulder clamps to the slow lane"
        );
        // The desert widens to 4 lanes at 320 m.
        assert_eq!(lane_at(map, 40_000, 2_000_000), 3);
        // 3 lanes at s = 0: guardrail at 1.7 + 10.8 + 3.0 + 0.5 m.
        assert_eq!(d_bounds_mm(map, 0), (500, 16_000));
        assert_eq!(d_bounds_mm(map, 2_000_000).1, 19_600);
    }

    #[test]
    fn tapers_keep_the_wider_count() {
        let m = loop_v1();
        let map = &m.map;
        let r = map
            .lanes
            .iter()
            .find(|r| r.taper_mm > 0 && r.s_start_mm > 0)
            .copied()
            .expect("loop_v1 has a tapered lane change");
        let before = map.lane_count_at(r.s_start_mm - 1);
        assert_eq!(lanes_wide_at(map, r.s_start_mm), r.count.max(before));
        assert_eq!(lanes_wide_at(map, r.s_start_mm + r.taper_mm), r.count);
    }

    #[test]
    fn flow_speeds_and_the_start_spawns() {
        let m = loop_v1();
        let map = &m.map;
        // Desert at 1 km, 4 lanes: 185 km/h in the fast lane, 100 km/h in the slow one.
        assert_eq!(flow_speed_cms(map, 0, 1_000_000), 5_139);
        assert_eq!(flow_speed_cms(map, 3, 1_000_000), 2_778);
        let starts: Vec<(u32, u8)> = start_spawn_points(map).collect();
        assert!(!starts.is_empty());
        assert!(starts.iter().all(|(s, _)| *s == starts[0].0));
        assert_eq!(starts[0].0, 150_000, "150 m past the start / finish gantry");
        let lanes: Vec<u8> = starts.iter().map(|(_, l)| *l).collect();
        assert_eq!(usize::from(map.lane_count_at(starts[0].0)), lanes.len());
    }
}
