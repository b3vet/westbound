//! Quantization between physical units (meters, seconds, radians, m/s) and wire integers
//! (multiplayer handoff → Networking protocol → Encoding, quantization table).
//!
//! Rounding is `f64::round` (half away from zero, same as GDScript `round()`), applied to
//! `value × scale`, then the range rule:
//!
//! | Field | Wire | Scale | Out of range |
//! | --- | --- | --- | --- |
//! | `s` | u32 | 1 mm | **rejected** (`QuantError::OutOfRange`); wrap `s` into [0, L) first |
//! | `d` | i16 | 1 cm | clamped to ±`MAX_ABS_D_CM` (±100 m) |
//! | speed | u16 | 1 cm/s | clamped to 0..=`MAX_SPEED_CMS` (200 m/s) |
//! | heading | i16 | 1e-4 rad | **wrapped** by whole turns into [-π, π] when beyond ±3.14165, then clamped to ±`MAX_HEADING_E4` |
//! | lateral velocity | i16 | 1 cm/s | clamped to ±32767 (±327.67 m/s) |
//! | yaw rate | i16 | 1e-3 rad/s | clamped to ±32767 (±32.767 rad/s) |
//! | steer | i16 | 1e-4 | clamped to ±10000 (±1.0) |
//! | clearance | u16 | 1 mm | clamped to 0..=65535 (65.535 m) |
//! | multiplier | u32 | 1e-3 | clamped to 0..=u32::MAX |
//!
//! Non-finite inputs (NaN, ±inf) are always rejected with `QuantError::NotFinite`.
//! Ticks, ids and durations are integers already and need no helpers.

use crate::error::QuantError;
use crate::messages::{MAX_ABS_D_CM, MAX_ABS_I16, MAX_HEADING_E4, MAX_SPEED_CMS, MAX_STEER_E4};

/// Wire units per physical unit.
pub const S_PER_M: f64 = 1000.0;
pub const D_PER_M: f64 = 100.0;
pub const SPEED_PER_MPS: f64 = 100.0;
pub const HEADING_PER_RAD: f64 = 10_000.0;
pub const LAT_VEL_PER_MPS: f64 = 100.0;
pub const YAW_RATE_PER_RAD_S: f64 = 1000.0;
pub const STEER_PER_UNIT: f64 = 10_000.0;
pub const CLEARANCE_PER_M: f64 = 1000.0;
pub const MULTIPLIER_PER_UNIT: f64 = 1000.0;

fn finite(field: &'static str, v: f64) -> Result<f64, QuantError> {
    if v.is_finite() {
        Ok(v)
    } else {
        Err(QuantError::NotFinite { field })
    }
}

fn clamp_round(
    field: &'static str,
    v: f64,
    scale: f64,
    lo: f64,
    hi: f64,
) -> Result<f64, QuantError> {
    Ok((finite(field, v)? * scale).round().clamp(lo, hi))
}

/// `s` (m) → mm. Rejects values that round outside 0..=u32::MAX.
pub fn s_to_wire(s_m: f64) -> Result<u32, QuantError> {
    let q = (finite("s", s_m)? * S_PER_M).round();
    if !(0.0..=f64::from(u32::MAX)).contains(&q) {
        return Err(QuantError::OutOfRange {
            field: "s",
            value: s_m,
        });
    }
    Ok(q as u32)
}

pub fn s_from_wire(mm: u32) -> f64 {
    f64::from(mm) / S_PER_M
}

/// `d` (m) → cm, clamped to ±100 m.
pub fn d_to_wire(d_m: f64) -> Result<i16, QuantError> {
    let lim = f64::from(MAX_ABS_D_CM);
    Ok(clamp_round("d", d_m, D_PER_M, -lim, lim)? as i16)
}

pub fn d_from_wire(cm: i16) -> f64 {
    f64::from(cm) / D_PER_M
}

/// Speed (m/s) → cm/s, clamped to 0..=200 m/s.
pub fn speed_to_wire(v_mps: f64) -> Result<u16, QuantError> {
    Ok(clamp_round("speed", v_mps, SPEED_PER_MPS, 0.0, f64::from(MAX_SPEED_CMS))? as u16)
}

pub fn speed_from_wire(cms: u16) -> f64 {
    f64::from(cms) / SPEED_PER_MPS
}

/// Heading vs road (rad) → 1e-4 rad, wrapped into [-π, π].
pub fn heading_to_wire(rad: f64) -> Result<i16, QuantError> {
    let r = finite("heading", rad)?;
    let lim = f64::from(MAX_HEADING_E4);
    // Values that already round into ±MAX_HEADING_E4 (up to 3.14165) are kept, so every wire
    // value round-trips; anything beyond is wrapped by whole turns into [-π, π].
    let keep = (lim + 0.5) / HEADING_PER_RAD;
    let wrapped = if r.abs() < keep {
        r
    } else {
        let tau = std::f64::consts::TAU;
        r - tau * (r / tau).round()
    };
    Ok((wrapped * HEADING_PER_RAD).round().clamp(-lim, lim) as i16)
}

pub fn heading_from_wire(e4: i16) -> f64 {
    f64::from(e4) / HEADING_PER_RAD
}

/// Lateral velocity (m/s) → cm/s, clamped to ±327.67 m/s.
pub fn lat_vel_to_wire(v_mps: f64) -> Result<i16, QuantError> {
    let lim = f64::from(MAX_ABS_I16);
    Ok(clamp_round("lat_vel", v_mps, LAT_VEL_PER_MPS, -lim, lim)? as i16)
}

pub fn lat_vel_from_wire(cms: i16) -> f64 {
    f64::from(cms) / LAT_VEL_PER_MPS
}

/// Yaw rate (rad/s) → mrad/s, clamped to ±32.767 rad/s.
pub fn yaw_rate_to_wire(rad_s: f64) -> Result<i16, QuantError> {
    let lim = f64::from(MAX_ABS_I16);
    Ok(clamp_round("yaw_rate", rad_s, YAW_RATE_PER_RAD_S, -lim, lim)? as i16)
}

pub fn yaw_rate_from_wire(mrad_s: i16) -> f64 {
    f64::from(mrad_s) / YAW_RATE_PER_RAD_S
}

/// Steering input (-1..1) → 1e-4, clamped to ±1.0.
pub fn steer_to_wire(steer: f64) -> Result<i16, QuantError> {
    let lim = f64::from(MAX_STEER_E4);
    Ok(clamp_round("steer", steer, STEER_PER_UNIT, -lim, lim)? as i16)
}

pub fn steer_from_wire(e4: i16) -> f64 {
    f64::from(e4) / STEER_PER_UNIT
}

/// Clearance (m) → mm, clamped to 0..=65.535 m.
pub fn clearance_to_wire(m: f64) -> Result<u16, QuantError> {
    Ok(clamp_round("clearance", m, CLEARANCE_PER_M, 0.0, f64::from(u16::MAX))? as u16)
}

pub fn clearance_from_wire(mm: u16) -> f64 {
    f64::from(mm) / CLEARANCE_PER_M
}

/// Multiplier (×) → ×1e-3, clamped to 0..=u32::MAX.
pub fn multiplier_to_wire(x: f64) -> Result<u32, QuantError> {
    Ok(clamp_round(
        "multiplier",
        x,
        MULTIPLIER_PER_UNIT,
        0.0,
        f64::from(u32::MAX),
    )? as u32)
}

pub fn multiplier_from_wire(milli: u32) -> f64 {
    f64::from(milli) / MULTIPLIER_PER_UNIT
}

/// A quantizable field, for table-driven tests and the golden quantization vectors.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Field {
    S,
    D,
    Speed,
    Heading,
    LatVel,
    YawRate,
    Steer,
    Clearance,
    Multiplier,
}

impl Field {
    pub const ALL: [Field; 9] = [
        Field::S,
        Field::D,
        Field::Speed,
        Field::Heading,
        Field::LatVel,
        Field::YawRate,
        Field::Steer,
        Field::Clearance,
        Field::Multiplier,
    ];

    /// Name used in `vectors/quantization.json`.
    pub fn name(self) -> &'static str {
        match self {
            Field::S => "s",
            Field::D => "d",
            Field::Speed => "speed",
            Field::Heading => "heading",
            Field::LatVel => "lat_vel",
            Field::YawRate => "yaw_rate",
            Field::Steer => "steer",
            Field::Clearance => "clearance",
            Field::Multiplier => "multiplier",
        }
    }

    /// Physical → wire, widened to i64.
    pub fn to_wire(self, v: f64) -> Result<i64, QuantError> {
        Ok(match self {
            Field::S => i64::from(s_to_wire(v)?),
            Field::D => i64::from(d_to_wire(v)?),
            Field::Speed => i64::from(speed_to_wire(v)?),
            Field::Heading => i64::from(heading_to_wire(v)?),
            Field::LatVel => i64::from(lat_vel_to_wire(v)?),
            Field::YawRate => i64::from(yaw_rate_to_wire(v)?),
            Field::Steer => i64::from(steer_to_wire(v)?),
            Field::Clearance => i64::from(clearance_to_wire(v)?),
            Field::Multiplier => i64::from(multiplier_to_wire(v)?),
        })
    }

    /// Wire units per physical unit.
    pub fn scale(self) -> f64 {
        match self {
            Field::S => S_PER_M,
            Field::D => D_PER_M,
            Field::Speed => SPEED_PER_MPS,
            Field::Heading => HEADING_PER_RAD,
            Field::LatVel => LAT_VEL_PER_MPS,
            Field::YawRate => YAW_RATE_PER_RAD_S,
            Field::Steer => STEER_PER_UNIT,
            Field::Clearance => CLEARANCE_PER_M,
            Field::Multiplier => MULTIPLIER_PER_UNIT,
        }
    }

    /// Inclusive valid wire range.
    pub fn wire_range(self) -> (i64, i64) {
        match self {
            Field::S => (0, i64::from(u32::MAX)),
            Field::D => (-i64::from(MAX_ABS_D_CM), i64::from(MAX_ABS_D_CM)),
            Field::Speed => (0, i64::from(MAX_SPEED_CMS)),
            Field::Heading => (-i64::from(MAX_HEADING_E4), i64::from(MAX_HEADING_E4)),
            Field::LatVel | Field::YawRate => (-i64::from(MAX_ABS_I16), i64::from(MAX_ABS_I16)),
            Field::Steer => (-i64::from(MAX_STEER_E4), i64::from(MAX_STEER_E4)),
            Field::Clearance => (0, i64::from(u16::MAX)),
            Field::Multiplier => (0, i64::from(u32::MAX)),
        }
    }

    /// Wire → physical.
    pub fn from_wire(self, w: i64) -> f64 {
        w as f64 / self.scale()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edges_round_trip_for_every_field() {
        for f in Field::ALL {
            let (lo, hi) = f.wire_range();
            for w in [lo, lo + 1, 0.max(lo), hi - 1, hi] {
                let phys = f.from_wire(w);
                assert_eq!(f.to_wire(phys).unwrap(), w, "{} wire {w}", f.name());
            }
        }
    }

    #[test]
    fn physical_round_trip_is_within_half_a_step() {
        for f in Field::ALL {
            let (lo, hi) = f.wire_range();
            let step = 1.0 / f.scale();
            for i in 0..=200 {
                let phys =
                    f.from_wire(lo) + (f.from_wire(hi) - f.from_wire(lo)) * f64::from(i) / 200.0;
                let back = f.from_wire(f.to_wire(phys).unwrap());
                assert!(
                    (back - phys).abs() <= step * 0.5 + 1e-9,
                    "{} {phys} -> {back}",
                    f.name()
                );
            }
        }
    }

    #[test]
    fn s_rejects_out_of_range() {
        assert_eq!(s_to_wire(0.0).unwrap(), 0);
        assert_eq!(s_to_wire(-0.0004).unwrap(), 0);
        assert!(matches!(
            s_to_wire(-0.0005),
            Err(QuantError::OutOfRange { .. })
        ));
        assert_eq!(s_to_wire(4_294_967.295).unwrap(), u32::MAX);
        assert!(matches!(
            s_to_wire(4_294_967.296),
            Err(QuantError::OutOfRange { .. })
        ));
        assert_eq!(s_to_wire(25_000.0).unwrap(), 25_000_000);
    }

    #[test]
    fn clamped_fields_saturate() {
        assert_eq!(d_to_wire(1e9).unwrap(), MAX_ABS_D_CM);
        assert_eq!(d_to_wire(-1e9).unwrap(), -MAX_ABS_D_CM);
        assert_eq!(speed_to_wire(-3.0).unwrap(), 0);
        assert_eq!(speed_to_wire(1e6).unwrap(), MAX_SPEED_CMS);
        assert_eq!(lat_vel_to_wire(-1e6).unwrap(), -i16::MAX);
        assert_eq!(yaw_rate_to_wire(1e6).unwrap(), i16::MAX);
        assert_eq!(steer_to_wire(1.5).unwrap(), MAX_STEER_E4);
        assert_eq!(clearance_to_wire(-1.0).unwrap(), 0);
        assert_eq!(clearance_to_wire(1e9).unwrap(), u16::MAX);
        assert_eq!(multiplier_to_wire(1e12).unwrap(), u32::MAX);
    }

    #[test]
    fn heading_wraps() {
        let pi = std::f64::consts::PI;
        assert_eq!(heading_to_wire(pi).unwrap(), MAX_HEADING_E4);
        assert_eq!(heading_to_wire(-pi).unwrap(), -MAX_HEADING_E4);
        assert_eq!(heading_to_wire(2.0 * pi + 0.5).unwrap(), 5000);
        assert_eq!(heading_to_wire(-2.0 * pi - 0.5).unwrap(), -5000);
        assert_eq!(heading_to_wire(0.12345).unwrap(), 1235);
    }

    #[test]
    fn rounding_is_half_away_from_zero() {
        assert_eq!(d_to_wire(0.005).unwrap(), 1);
        assert_eq!(d_to_wire(-0.005).unwrap(), -1);
        assert_eq!(speed_to_wire(0.125).unwrap(), 13);
    }

    #[test]
    fn non_finite_is_rejected_everywhere() {
        for f in Field::ALL {
            for v in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
                assert!(
                    matches!(f.to_wire(v), Err(QuantError::NotFinite { .. })),
                    "{}",
                    f.name()
                );
            }
        }
    }
}
