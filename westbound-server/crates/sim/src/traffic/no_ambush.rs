//! The no-ambush predicate, pure. Port of `src/traffic/no_ambush.gd` (`NoAmbush`).
//! Spec: Traffic → Fairness rule 2; multiplayer handoff → Server simulation ("the
//! no-ambush rule uses each player's predicted position": the sim calls this once per
//! player, with the player's state extrapolated to the current tick).
//!
//! - the car's target space: its body at `target_d`, moving along the road at its speed;
//! - the player's predicted space: its body moving at its road-frame velocity, grown by
//!   `margin` on every side;
//! - violation: the two boxes overlap at some t in [0, window] (exact per-axis
//!   intervals, intersected).

use super::gd::{maxf, minf};

#[allow(clippy::too_many_arguments)]
#[inline]
pub fn violates(
    car_s: f64,
    car_v: f64,
    car_length: f64,
    car_width: f64,
    target_d: f64,
    p_s: f64,
    p_v: f64,
    p_d: f64,
    p_v_lat: f64,
    p_length: f64,
    p_width: f64,
    window: f64,
    margin: f64,
) -> bool {
    let half_s = (car_length + p_length) * 0.5 + margin;
    let half_d = (car_width + p_width) * 0.5 + margin;
    // Longitudinal: |(p_s - car_s) + (p_v - car_v) t| < half_s
    let mut lo = 0.0;
    let mut hi = window;
    let ds = p_s - car_s;
    let rs = p_v - car_v;
    if rs == 0.0 {
        if ds.abs() >= half_s {
            return false;
        }
    } else {
        let t1 = (-half_s - ds) / rs;
        let t2 = (half_s - ds) / rs;
        lo = maxf(lo, minf(t1, t2));
        hi = minf(hi, maxf(t1, t2));
    }
    // Lateral: |(p_d - target_d) + p_v_lat t| < half_d
    let dd = p_d - target_d;
    if p_v_lat == 0.0 {
        if dd.abs() >= half_d {
            return false;
        }
    } else {
        let u1 = (-half_d - dd) / p_v_lat;
        let u2 = (half_d - dd) / p_v_lat;
        lo = maxf(lo, minf(u1, u2));
        hi = minf(hi, maxf(u1, u2));
    }
    lo < hi
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closing_player_and_disjoint_times() {
        // Player 30 m behind in the target lane, 25 m/s faster: reaches the car in ~1.2 s.
        assert!(violates(
            100.0, 25.0, 4.5, 1.9, 5.4, 70.0, 50.0, 5.4, 0.0, 4.5, 1.9, 1.5, 1.0
        ));
        // Same, 80 m behind: not within 1.5 s.
        assert!(!violates(
            100.0, 25.0, 4.5, 1.9, 5.4, 20.0, 50.0, 5.4, 0.0, 4.5, 1.9, 1.5, 1.0
        ));
        // Longitudinally overlapping, but drifting away laterally before it matters.
        assert!(!violates(
            100.0, 25.0, 4.5, 1.9, 5.4, 100.0, 25.0, 12.0, 2.0, 4.5, 1.9, 1.5, 1.0
        ));
    }
}
