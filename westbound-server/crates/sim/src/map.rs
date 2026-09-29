//! The loop map in road space (N3.2). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop
//! map ("s wraps modulo L. Every distance comparison uses the wrapped signed difference",
//! the road-space file, the hash check on join); docs/LOOP_MAP.md → Road-space file.
//!
//! [`LoopMap::from_json`] parses and validates `loop_v1.json` (the file the Godot editor
//! exports; every position and length in millimetres). The map is plain data plus the
//! wrap math every room system uses: positions are `u32` millimetres in `[0, L)` (the
//! protocol's `s`), distances along the loop are [`LoopMap::signed_delta_mm`] in
//! `[-L/2, L/2)`. Pure: no I/O, no clock; the server reads the bytes and hashes them.
//!
//! ```
//! let map = sim::map::LoopMap::from_json(r#"{"format_version": 1, "map_id": "m",
//!   "units": {"length": "mm", "speed": "km/h"}, "length_mm": 1000,
//!   "cross_section": {"median_half_width_mm": 500, "inner_shoulder_mm": 1200,
//!     "lane_width_mm": 3600, "shoulder_mm": 3000, "guardrail_offset_mm": 500},
//!   "sections": [{"index": 0, "id": "a", "s_start_mm": 0, "s_end_mm": 1000, "lanes": 3,
//!     "lane_flow_speeds_from_right_kmh": [100.0]}],
//!   "lanes": [{"s_start_mm": 0, "s_end_mm": 1000, "count": 3, "lane_width_mm": 3600, "taper_mm": 0}],
//!   "sectors": [{"index": 0, "s_mm": 0, "style": "toll_gantry", "start_finish": true}]}"#).unwrap();
//! assert_eq!(map.signed_delta_mm(900, 100), 200);
//! assert_eq!(map.wrap_mm(-1), 999);
//! ```

use std::fmt;

use serde::Deserialize;

/// The road-space format this code reads (`format_version`).
pub const FORMAT_VERSION: u32 = 1;
/// Millimetres per metre (the file's unit).
pub const MM_PER_M: f64 = 1000.0;

/// Why a road-space file was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapError(pub String);

impl fmt::Display for MapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "loop map: {}", self.0)
    }
}

impl std::error::Error for MapError {}

fn err<T>(msg: impl Into<String>) -> Result<T, MapError> {
    Err(MapError(msg.into()))
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Units {
    pub length: String,
    pub speed: String,
}

/// How the file was generated (informational; the hash covers it).
#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
pub struct Generator {
    pub name: String,
    pub version: u32,
    pub seed: i64,
    pub section_length_mm: u32,
    #[serde(default)]
    pub edits: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct CrossSection {
    pub median_half_width_mm: u32,
    pub inner_shoulder_mm: u32,
    pub lane_width_mm: u32,
    pub shoulder_mm: u32,
    pub guardrail_offset_mm: u32,
}

/// One section (desert, canyon, coast, city, farmland in `loop_v1`).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Section {
    pub index: u32,
    pub id: String,
    pub s_start_mm: u32,
    pub s_end_mm: u32,
    /// The section's nominal lane count (the `lanes` ranges hold the exact counts by s).
    pub lanes: u8,
    /// Lane flow speeds, lane from the right first (km/h).
    pub lane_flow_speeds_from_right_kmh: Vec<f64>,
}

/// A lane-count range. From `s_start_mm` the right edge moves from the previous count to
/// `count` along a smoothstep over `taper_mm` (geometry only: the count steps at
/// `s_start_mm`, as on the client).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct LaneRange {
    pub s_start_mm: u32,
    pub s_end_mm: u32,
    pub count: u8,
    pub lane_width_mm: u32,
    pub taper_mm: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Tunnel {
    pub index: u32,
    pub s_start_mm: u32,
    pub s_end_mm: u32,
    pub lanes: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Bridge {
    pub sector: u32,
    pub s_start_mm: u32,
    pub s_end_mm: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RampKind {
    /// Traffic leaves the loop: the diverge starts at `s_mm`.
    Off,
    /// Traffic joins the loop: the merge starts at `s_mm`.
    On,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Ramp {
    pub pair: u32,
    pub kind: RampKind,
    pub side: String,
    pub section: u32,
    pub s_mm: u32,
    pub length_mm: u32,
}

/// A road works zone the server may toggle (tapers included in `s_start..s_end`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct ClosureZone {
    pub index: u32,
    pub section: u32,
    pub s_start_mm: u32,
    pub s_end_mm: u32,
    pub taper_mm: u32,
    pub lanes_closed_from_right: u8,
    pub default_on: bool,
}

/// A sector gantry (the multiplayer checkpoint).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Sector {
    pub index: u32,
    pub s_mm: u32,
    pub style: String,
    pub start_finish: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct SpawnPoint {
    pub s_mm: u32,
    /// Lane index from the median (0 = leftmost), as on the client.
    pub lane: u8,
}

/// The file as written (`LoopExport.road_space`); [`LoopMap`] is the validated form.
#[derive(Debug, Clone, PartialEq, Deserialize)]
struct RawMap {
    format_version: u32,
    map_id: String,
    units: Units,
    #[serde(default)]
    generator: Generator,
    length_mm: u32,
    cross_section: CrossSection,
    sections: Vec<Section>,
    lanes: Vec<LaneRange>,
    #[serde(default)]
    tunnels: Vec<Tunnel>,
    #[serde(default)]
    bridge: Option<Bridge>,
    #[serde(default)]
    ramps: Vec<Ramp>,
    #[serde(default)]
    closure_zones: Vec<ClosureZone>,
    sectors: Vec<Sector>,
    #[serde(default)]
    spawn_points: Vec<SpawnPoint>,
}

/// A validated loop map. Positions are millimetres in `[0, L)`.
#[derive(Debug, Clone, PartialEq)]
pub struct LoopMap {
    pub map_id: String,
    pub generator: Generator,
    pub cross_section: CrossSection,
    pub sections: Vec<Section>,
    pub lanes: Vec<LaneRange>,
    pub tunnels: Vec<Tunnel>,
    pub bridge: Option<Bridge>,
    pub ramps: Vec<Ramp>,
    pub closure_zones: Vec<ClosureZone>,
    pub sectors: Vec<Sector>,
    pub spawn_points: Vec<SpawnPoint>,
    length_mm: u32,
}

impl LoopMap {
    /// Parses and validates a road-space file.
    pub fn from_json(text: &str) -> Result<Self, MapError> {
        let raw: RawMap = serde_json::from_str(text)
            .map_err(|e| MapError(format!("not a road-space file: {e}")))?;
        let map = LoopMap {
            map_id: raw.map_id,
            generator: raw.generator,
            cross_section: raw.cross_section,
            sections: raw.sections,
            lanes: raw.lanes,
            tunnels: raw.tunnels,
            bridge: raw.bridge,
            ramps: raw.ramps,
            closure_zones: raw.closure_zones,
            sectors: raw.sectors,
            spawn_points: raw.spawn_points,
            length_mm: raw.length_mm,
        };
        if raw.format_version != FORMAT_VERSION {
            return err(format!(
                "format_version {} (this server reads {FORMAT_VERSION})",
                raw.format_version
            ));
        }
        if raw.units.length != "mm" || raw.units.speed != "km/h" {
            return err(format!(
                "units must be mm and km/h, got {} and {}",
                raw.units.length, raw.units.speed
            ));
        }
        map.validate()?;
        Ok(map)
    }

    // ------------------------------------------------------------ Wrap math

    /// Loop length L (mm).
    pub fn length_mm(&self) -> u32 {
        self.length_mm
    }

    /// Loop length L (m).
    pub fn length_m(&self) -> f64 {
        f64::from(self.length_mm) / MM_PER_M
    }

    /// Any s (mm, unwrapped, possibly negative) modulo L, in `[0, L)`.
    pub fn wrap_mm(&self, s: i64) -> u32 {
        // In [0, L) and L fits u32.
        s.rem_euclid(i64::from(self.length_mm)) as u32
    }

    /// Wrapped signed distance from `a` to `b` along the loop (mm), in `[-L/2, L/2)`: how
    /// far `b` is ahead of `a` (negative: behind). The rule for every distance comparison.
    pub fn signed_delta_mm(&self, a: u32, b: u32) -> i64 {
        let l = i64::from(self.length_mm);
        let half = l / 2;
        (i64::from(b) - i64::from(a) + half).rem_euclid(l) - half
    }

    /// The same in metres for float positions (the client's `LoopRoadPath.signed_delta`).
    pub fn signed_delta_m(&self, a_m: f64, b_m: f64) -> f64 {
        let l = self.length_m();
        (b_m - a_m + l * 0.5).rem_euclid(l) - l * 0.5
    }

    /// Any s (m) modulo L, in `[0, L)`.
    pub fn wrap_m(&self, s_m: f64) -> f64 {
        let l = self.length_m();
        let r = s_m.rem_euclid(l);
        if r >= l {
            0.0
        } else {
            r
        }
    }

    /// The unwrapped s nearest `reference` (unwrapped mm) that lands on `wrapped`: how a
    /// client keeps counting s past L while the wire carries `s mod L`.
    pub fn unwrap_near(&self, reference: i64, wrapped: u32) -> i64 {
        reference + self.signed_delta_mm(self.wrap_mm(reference), wrapped)
    }

    /// Lap index of an unwrapped s (s in `[q L, (q + 1) L)` is lap q).
    pub fn lap_of(&self, s: i64) -> i64 {
        s.div_euclid(i64::from(self.length_mm))
    }

    /// Whether `x` lies in the half-open span `[a, a + len)` along the loop (wrapping).
    pub fn in_span(&self, x: u32, a: u32, len: u32) -> bool {
        let d = self.signed_delta_mm(a, x);
        let d = if d < 0 {
            d + i64::from(self.length_mm)
        } else {
            d
        };
        d < i64::from(len)
    }

    // ------------------------------------------------------------ Queries

    /// Driving lanes at s (the count steps at each range's `s_start_mm`).
    pub fn lane_count_at(&self, s_mm: u32) -> u8 {
        self.lanes[self.lane_range_index(s_mm)].count
    }

    /// The lane range containing s.
    pub fn lane_range_at(&self, s_mm: u32) -> &LaneRange {
        &self.lanes[self.lane_range_index(s_mm)]
    }

    fn lane_range_index(&self, s_mm: u32) -> usize {
        let s = self.wrap_mm(i64::from(s_mm));
        self.lanes
            .partition_point(|r| r.s_start_mm <= s)
            .saturating_sub(1)
    }

    /// Index of the section containing s.
    pub fn section_index_at(&self, s_mm: u32) -> usize {
        let s = self.wrap_mm(i64::from(s_mm));
        self.sections
            .partition_point(|x| x.s_start_mm <= s)
            .saturating_sub(1)
    }

    pub fn section_at(&self, s_mm: u32) -> &Section {
        &self.sections[self.section_index_at(s_mm)]
    }

    /// Flow speed (km/h) of lane `lane` (0 = next to the median) of `lanes` lanes in the
    /// section at s (the client's `LoopRoadPath.lane_flow_speed_mps` rule).
    pub fn lane_flow_speed_kmh(&self, lane: u8, lanes: u8, s_mm: u32) -> f64 {
        let list = &self.section_at(s_mm).lane_flow_speeds_from_right_kmh;
        let from_right = i64::from(lanes) - 1 - i64::from(lane);
        let i = from_right.clamp(0, list.len() as i64 - 1) as usize;
        list[i]
    }

    /// Number of sector gantries.
    pub fn sector_count(&self) -> usize {
        self.sectors.len()
    }

    /// The sector s lies in: the index of the last gantry at or before s (sector k runs
    /// from gantry k to gantry k + 1).
    pub fn sector_at(&self, s_mm: u32) -> usize {
        let s = self.wrap_mm(i64::from(s_mm));
        let i = self.sectors.partition_point(|g| g.s_mm <= s);
        if i == 0 {
            self.sectors.len() - 1
        } else {
            i - 1
        }
    }

    /// The next gantry ahead of s (strictly ahead) and the distance to it (mm, > 0).
    pub fn next_sector(&self, s_mm: u32) -> (usize, u32) {
        let next = (self.sector_at(s_mm) + 1) % self.sectors.len();
        let s = self.wrap_mm(i64::from(s_mm));
        let g = self.sectors[next].s_mm;
        let d = if g > s { g - s } else { g + self.length_mm - s };
        (next, d)
    }

    /// The gantry crossed moving forward from `from` to `to` (wrapped mm; a step shorter
    /// than L/2 and shorter than a sector), if any: `from` is before the line, `to` on or
    /// past it.
    pub fn sector_crossed(&self, from: u32, to: u32) -> Option<usize> {
        let step = self.signed_delta_mm(from, to);
        if step <= 0 {
            return None;
        }
        self.sectors.iter().position(|g| {
            let d = self.signed_delta_mm(from, g.s_mm);
            d > 0 && d <= step
        })
    }

    /// The tunnel containing s, if any.
    pub fn tunnel_at(&self, s_mm: u32) -> Option<&Tunnel> {
        let s = self.wrap_mm(i64::from(s_mm));
        self.tunnels
            .iter()
            .find(|t| s >= t.s_start_mm && s < t.s_end_mm)
    }

    /// The road works zone containing s, if any (whether it is on is the room's state).
    pub fn closure_zone_at(&self, s_mm: u32) -> Option<&ClosureZone> {
        let s = self.wrap_mm(i64::from(s_mm));
        self.closure_zones
            .iter()
            .find(|z| s >= z.s_start_mm && s < z.s_end_mm)
    }

    // ------------------------------------------------------------ Validation

    fn validate(&self) -> Result<(), MapError> {
        let l = self.length_mm;
        if l == 0 || l > u32::MAX / 2 {
            return err(format!("length_mm {l} out of range"));
        }
        if self.map_id.is_empty() {
            return err("map_id is empty");
        }
        if self.cross_section.lane_width_mm == 0 {
            return err("cross_section.lane_width_mm is 0");
        }
        self.validate_sections()?;
        self.validate_lanes()?;
        self.validate_sectors()?;
        for t in &self.tunnels {
            if t.s_start_mm >= t.s_end_mm || t.s_end_mm > l || t.lanes == 0 {
                return err(format!("tunnel {} is not a span inside [0, L)", t.index));
            }
        }
        if let Some(b) = &self.bridge {
            if b.s_start_mm >= b.s_end_mm || b.s_end_mm > l {
                return err("the bridge is not a span inside [0, L)");
            }
            if b.sector as usize >= self.sectors.len() {
                return err(format!("the bridge's sector {} does not exist", b.sector));
            }
        }
        for r in &self.ramps {
            let Some(sec) = self.sections.get(r.section as usize) else {
                return err(format!("ramp pair {} names section {}", r.pair, r.section));
            };
            if r.length_mm == 0 || r.s_mm < sec.s_start_mm || r.s_mm >= sec.s_end_mm {
                return err(format!(
                    "ramp pair {} ({:?}) lies outside its section",
                    r.pair, r.kind
                ));
            }
            if r.side != "right" {
                return err(format!(
                    "ramp pair {}: side {} (only right)",
                    r.pair, r.side
                ));
            }
        }
        for z in &self.closure_zones {
            if self.sections.get(z.section as usize).is_none() {
                return err(format!(
                    "closure zone {} names section {}",
                    z.index, z.section
                ));
            }
            if z.s_start_mm >= z.s_end_mm
                || z.s_end_mm > l
                || u64::from(z.taper_mm) * 2 >= u64::from(z.s_end_mm - z.s_start_mm)
            {
                return err(format!(
                    "closure zone {} is not a span with room for its tapers",
                    z.index
                ));
            }
            let lanes = self
                .lane_count_at(z.s_start_mm)
                .min(self.lane_count_at(z.s_end_mm - 1));
            if z.lanes_closed_from_right == 0 || z.lanes_closed_from_right >= lanes {
                return err(format!(
                    "closure zone {} closes {} of {} lanes",
                    z.index, z.lanes_closed_from_right, lanes
                ));
            }
        }
        for p in &self.spawn_points {
            if p.s_mm >= l {
                return err(format!("spawn point at {} mm lies past L", p.s_mm));
            }
            if p.lane >= self.lane_count_at(p.s_mm) {
                return err(format!(
                    "spawn point at {} mm: lane {} of {}",
                    p.s_mm,
                    p.lane,
                    self.lane_count_at(p.s_mm)
                ));
            }
        }
        Ok(())
    }

    fn validate_sections(&self) -> Result<(), MapError> {
        if self.sections.is_empty() {
            return err("no sections");
        }
        let mut at = 0u32;
        for (i, s) in self.sections.iter().enumerate() {
            if s.index as usize != i {
                return err(format!("section {} is listed at position {i}", s.index));
            }
            if s.s_start_mm != at || s.s_end_mm <= s.s_start_mm {
                return err(format!(
                    "section {} ({}) does not continue the loop at {at} mm",
                    i, s.id
                ));
            }
            if s.lanes == 0 {
                return err(format!("section {} has no lanes", s.id));
            }
            if s.lane_flow_speeds_from_right_kmh.is_empty()
                || s.lane_flow_speeds_from_right_kmh
                    .iter()
                    .any(|v| !v.is_finite() || *v <= 0.0)
            {
                return err(format!("section {} needs positive lane flow speeds", s.id));
            }
            at = s.s_end_mm;
        }
        if at != self.length_mm {
            return err(format!(
                "sections end at {at} mm, not at L = {} mm",
                self.length_mm
            ));
        }
        Ok(())
    }

    fn validate_lanes(&self) -> Result<(), MapError> {
        if self.lanes.is_empty() {
            return err("no lane ranges");
        }
        let mut at = 0u32;
        for r in &self.lanes {
            if r.s_start_mm != at || r.s_end_mm <= r.s_start_mm {
                return err(format!(
                    "lane range at {} mm does not continue at {at} mm",
                    r.s_start_mm
                ));
            }
            if r.count == 0 || r.lane_width_mm == 0 {
                return err(format!("lane range at {} mm has no lanes", r.s_start_mm));
            }
            if r.taper_mm > r.s_end_mm - r.s_start_mm {
                return err(format!(
                    "lane range at {} mm: taper longer than the range",
                    r.s_start_mm
                ));
            }
            at = r.s_end_mm;
        }
        if at != self.length_mm {
            return err(format!("lane ranges end at {at} mm, not at L"));
        }
        Ok(())
    }

    fn validate_sectors(&self) -> Result<(), MapError> {
        if self.sectors.is_empty() {
            return err("no sectors");
        }
        let mut prev: Option<u32> = None;
        for (i, g) in self.sectors.iter().enumerate() {
            if g.index as usize != i {
                return err(format!("sector {} is listed at position {i}", g.index));
            }
            if g.s_mm >= self.length_mm || prev.is_some_and(|p| g.s_mm <= p) {
                return err(format!(
                    "sector {i} at {} mm is out of order or past L",
                    g.s_mm
                ));
            }
            prev = Some(g.s_mm);
        }
        let starts = self.sectors.iter().filter(|g| g.start_finish).count();
        if starts != 1 || !self.sectors[0].start_finish {
            return err("sector 0, and only it, must be the start/finish line");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The committed map (the server's copy).
    const LOOP_V1: &str = include_str!("../../../data/maps/loop_v1.json");

    fn loop_v1() -> LoopMap {
        LoopMap::from_json(LOOP_V1).expect("loop_v1 is valid")
    }

    #[test]
    fn loop_v1_parses() {
        let m = loop_v1();
        assert_eq!(m.map_id, "loop_v1");
        assert_eq!(m.length_mm(), 25_000_000);
        assert_eq!(m.length_m(), 25_000.0);
        assert_eq!(m.sections.len(), 5);
        assert_eq!(m.sector_count(), 6);
        assert_eq!(m.tunnels.len(), 2);
        assert_eq!(m.ramps.len(), 4);
        assert_eq!(m.closure_zones.len(), 5);
        assert!(m.closure_zones.iter().all(|z| !z.default_on));
        assert_eq!(m.bridge.map(|b| b.sector), Some(3));
        assert_eq!(m.cross_section.lane_width_mm, 3_600);
        assert!(!m.spawn_points.is_empty());
    }

    #[test]
    fn wrapped_signed_difference() {
        let m = loop_v1();
        let l = i64::from(m.length_mm());
        assert_eq!(m.signed_delta_mm(0, 0), 0);
        assert_eq!(m.signed_delta_mm(1_000, 3_000), 2_000);
        assert_eq!(m.signed_delta_mm(3_000, 1_000), -2_000);
        // Across the seam, both ways.
        assert_eq!(m.signed_delta_mm(24_999_000, 1_000), 2_000);
        assert_eq!(m.signed_delta_mm(1_000, 24_999_000), -2_000);
        // The half-open range [-L/2, L/2).
        assert_eq!(m.signed_delta_mm(0, 12_500_000), -12_500_000);
        assert_eq!(m.signed_delta_mm(0, 12_499_999), 12_499_999);
        for (a, b) in [
            (0u32, 7u32),
            (24_000_000, 300_000),
            (12_000_000, 13_000_000),
            (5, 24_999_999),
        ] {
            let d = m.signed_delta_mm(a, b);
            assert!((-l / 2..l / 2).contains(&d));
            assert_eq!(m.wrap_mm(i64::from(a) + d), b, "a + delta lands on b");
            assert_eq!(m.signed_delta_mm(b, a), if d == -l / 2 { d } else { -d });
        }
        // Metres, as on the client.
        assert!((m.signed_delta_m(24_990.0, 10.0) - 20.0).abs() < 1e-9);
        assert!((m.signed_delta_m(10.0, 24_990.0) + 20.0).abs() < 1e-9);
        assert!((m.wrap_m(25_010.5) - 10.5).abs() < 1e-9);
        assert!((m.wrap_m(-1.0) - 24_999.0).abs() < 1e-9);
        // Wrapping and laps.
        assert_eq!(m.wrap_mm(-1), 24_999_999);
        assert_eq!(m.wrap_mm(3 * l + 5), 5);
        assert_eq!(m.lap_of(3 * l + 5), 3);
        assert_eq!(m.lap_of(-1), -1);
        // A client counting past L: the nearest unwrapped s for a wrapped wire position.
        assert_eq!(m.unwrap_near(2 * l - 1_000, 500), 2 * l + 500);
        assert_eq!(m.unwrap_near(2 * l + 1_000, 24_999_500), 2 * l - 500);
        assert!(m.in_span(100, 24_999_900, 300));
        assert!(!m.in_span(300, 24_999_900, 300));
    }

    #[test]
    fn lane_counts_by_s() {
        let m = loop_v1();
        assert_eq!(m.lane_count_at(0), 3, "the desert starts on 3 lanes");
        assert_eq!(m.lane_count_at(319_999), 3);
        assert_eq!(
            m.lane_count_at(320_000),
            4,
            "the count steps at the range start"
        );
        assert_eq!(m.lane_count_at(2_500_000), 4);
        assert_eq!(m.lane_count_at(4_450_000), 3);
        // Tunnel 0 narrows to two.
        let t0 = m.tunnels[0];
        assert_eq!(t0.lanes, 2);
        assert_eq!(m.lane_count_at(t0.s_start_mm), 2);
        assert_eq!(m.lane_count_at((t0.s_start_mm + t0.s_end_mm) / 2), 2);
        assert_eq!(m.tunnel_at(t0.s_start_mm + 1).map(|t| t.index), Some(0));
        assert_eq!(m.lane_count_at(m.tunnels[1].s_start_mm), 3);
        assert_eq!(m.lane_count_at(17_000_000), 4, "the city");
        assert_eq!(m.lane_count_at(24_999_999), 3, "the farmland to the seam");
        assert_eq!(m.section_at(24_999_999).id, "farmland");
        assert_eq!(m.section_at(0).id, "desert");
        assert_eq!(m.section_at(15_000_000).id, "city");
        // Flow speeds, from the right; the fast lane is lane 0.
        assert_eq!(m.lane_flow_speed_kmh(3, 4, 1_000_000), 100.0);
        assert_eq!(m.lane_flow_speed_kmh(0, 4, 1_000_000), 185.0);
        assert_eq!(m.lane_flow_speed_kmh(0, 3, 16_000_000), 135.0);
        // Road works and every spawn point on a lane.
        assert_eq!(m.closure_zone_at(700_000).map(|z| z.index), Some(0));
        assert!(m.closure_zone_at(2_000_000).is_none());
        for p in &m.spawn_points {
            assert!(p.lane < m.lane_count_at(p.s_mm));
        }
    }

    #[test]
    fn sectors() {
        let m = loop_v1();
        assert_eq!(m.sector_at(0), 0);
        assert_eq!(m.sector_at(4_166_666), 0);
        assert_eq!(m.sector_at(4_166_667), 1);
        assert_eq!(m.sector_at(24_999_999), 5);
        assert_eq!(m.next_sector(24_999_000), (0, 1_000));
        assert_eq!(m.next_sector(0), (1, 4_166_667));
        assert_eq!(m.next_sector(12_499_000), (3, 1_000));
        assert_eq!(m.sectors[3].style, "suspension_bridge");
        // Crossings, the start/finish line across the seam included.
        assert_eq!(m.sector_crossed(24_999_900, 50), Some(0));
        assert_eq!(m.sector_crossed(4_166_600, 4_166_667), Some(1));
        assert_eq!(
            m.sector_crossed(4_166_667, 4_166_700),
            None,
            "on the line is crossed once"
        );
        assert_eq!(m.sector_crossed(100, 50), None, "backwards");
        // Every sector is about L/6.
        for g in 0..m.sector_count() {
            let next = (g + 1) % m.sector_count();
            let span = m.signed_delta_mm(m.sectors[g].s_mm, m.sectors[next].s_mm);
            let span = if span <= 0 {
                span + i64::from(m.length_mm())
            } else {
                span
            };
            assert!((span - 4_166_667).abs() <= 1, "sector {g} is {span} mm");
        }
    }

    #[test]
    fn refuses_bad_files() {
        let bad_version = LOOP_V1.replacen("\"format_version\": 1", "\"format_version\": 2", 1);
        assert!(LoopMap::from_json(&bad_version).is_err());
        let gap = LOOP_V1.replacen(
            "\"s_start_mm\": 5000000, \"s_end_mm\": 10000000",
            "\"s_start_mm\": 5000001, \"s_end_mm\": 10000000",
            1,
        );
        assert!(LoopMap::from_json(&gap).unwrap_err().0.contains("section"));
        let long = LOOP_V1.replacen("\"length_mm\": 25000000", "\"length_mm\": 25000001", 1);
        assert!(LoopMap::from_json(&long).is_err());
        assert!(LoopMap::from_json("{}").is_err());
        assert!(LoopMap::from_json("not json").is_err());
    }
}
