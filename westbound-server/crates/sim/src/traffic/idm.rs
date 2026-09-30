//! Intelligent Driver Model, pure. Port of `src/traffic/idm.gd` (`Idm`), function for
//! function. Spec: Traffic → Longitudinal model: IDM; multiplayer handoff → Server
//! simulation ("a port of the client model").
//!
//!   a  = a_max * [1 - (v / v0)^delta - (s* / s)^2]
//!   s* = s0 + max(0, v T + v dv / (2 sqrt(a_max b)))
//!
//! The power is repeated multiplication (`pow_int`), so results are bit-identical to the
//! GDScript model (checked by `vectors/idm.json`). The 6 m/s^2 clamp is the sim's.

use super::gd::maxf;

/// Full IDM acceleration. `gap = INF` means a free road (no leader).
#[allow(clippy::too_many_arguments)]
#[inline]
pub fn accel(
    v: f64,
    v0: f64,
    gap: f64,
    dv: f64,
    a_max: f64,
    b: f64,
    headway: f64,
    s0: f64,
    delta: i32,
    gap_floor: f64,
) -> f64 {
    let free = 1.0 - pow_int(v / v0, delta);
    if gap.is_infinite() {
        return a_max * free;
    }
    let r = desired_gap(v, dv, a_max, b, headway, s0) / maxf(gap, gap_floor);
    a_max * (free - r * r)
}

/// Free-road term only: a_max * (1 - (v / v0)^delta).
#[inline]
pub fn free_accel(v: f64, v0: f64, a_max: f64, delta: i32) -> f64 {
    a_max * (1.0 - pow_int(v / v0, delta))
}

/// Interaction term only: -a_max * (s* / s)^2 (a follower that holds its speed: the
/// player in MOBIL's safety check). 0 on a free road.
#[allow(clippy::too_many_arguments)]
#[inline]
pub fn interaction_accel(
    v: f64,
    gap: f64,
    dv: f64,
    a_max: f64,
    b: f64,
    headway: f64,
    s0: f64,
    gap_floor: f64,
) -> f64 {
    if gap.is_infinite() {
        return 0.0;
    }
    let r = desired_gap(v, dv, a_max, b, headway, s0) / maxf(gap, gap_floor);
    -a_max * r * r
}

/// s*: the desired dynamic gap (m).
#[inline]
pub fn desired_gap(v: f64, dv: f64, a_max: f64, b: f64, headway: f64, s0: f64) -> f64 {
    s0 + maxf(0.0, v * headway + v * dv / (2.0 * (a_max * b).sqrt()))
}

/// Steady-state gap behind a leader at the same constant speed v; INF when v >= v0.
#[inline]
pub fn equilibrium_gap(v: f64, v0: f64, headway: f64, s0: f64, delta: i32) -> f64 {
    let k = 1.0 - pow_int(v / v0, delta);
    if k <= 0.0 {
        return f64::INFINITY;
    }
    (s0 + v * headway) / k.sqrt()
}

/// x^n for n >= 0 by repeated squaring (exact IEEE ops, no libm).
#[inline]
pub fn pow_int(x: f64, n: i32) -> f64 {
    let mut result = 1.0;
    let mut base = x;
    let mut e = n;
    while e > 0 {
        if e & 1 != 0 {
            result *= base;
        }
        base *= base;
        e >>= 1;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_road_and_equilibrium() {
        assert_eq!(pow_int(2.0, 4), 16.0);
        assert_eq!(pow_int(3.0, 0), 1.0);
        let a = accel(20.0, 30.0, f64::INFINITY, 0.0, 1.5, 2.0, 1.3, 2.0, 4, 0.1);
        assert_eq!(a, free_accel(20.0, 30.0, 1.5, 4));
        // At the equilibrium gap behind a same-speed leader the acceleration is ~0.
        let s = equilibrium_gap(20.0, 30.0, 1.3, 2.0, 4);
        let a = accel(20.0, 30.0, s, 0.0, 1.5, 2.0, 1.3, 2.0, 4, 0.1);
        assert!(a.abs() < 1e-12, "{a}");
        assert!(equilibrium_gap(30.0, 30.0, 1.3, 2.0, 4).is_infinite());
        assert_eq!(
            interaction_accel(10.0, f64::INFINITY, 0.0, 1.0, 1.0, 1.0, 1.0, 0.1),
            0.0
        );
    }
}
