//! MOBIL lane-change criteria, pure. Port of `src/traffic/mobil.gd` (`Mobil`). Spec:
//! Traffic → Lane changes: MOBIL.
//!
//!   incentive:  (a~c - ac) + p [(a~n - an) + (a~o - ao)] > delta_a_th + a_bias
//!   safety:     a~n >= -b_safe
//!
//! Keep-right bias is asymmetric: a_bias raises the threshold to the left and lowers it
//! to the right. When a player would be the new follower, b_safe tightens to the
//! tuning's player_b_safe (`b_safe_for`).

use super::gd::minf;

#[inline]
pub fn incentive(
    a_c_new: f64,
    a_c: f64,
    a_n_new: f64,
    a_n: f64,
    a_o_new: f64,
    a_o: f64,
    p: f64,
) -> f64 {
    (a_c_new - a_c) + p * ((a_n_new - a_n) + (a_o_new - a_o))
}

/// The threshold the incentive must exceed for a move in this direction.
#[inline]
pub fn threshold(a_th: f64, a_bias: f64, to_right: bool) -> f64 {
    if to_right {
        a_th - a_bias
    } else {
        a_th + a_bias
    }
}

#[inline]
pub fn accepts(incentive_value: f64, a_th: f64, a_bias: f64, to_right: bool) -> bool {
    incentive_value > threshold(a_th, a_bias, to_right)
}

/// The new follower's acceleration after the change must not be below -b_safe.
#[inline]
pub fn is_safe(a_n_new: f64, b_safe: f64) -> bool {
    a_n_new >= -b_safe
}

/// b_safe for this new follower: tightened to player_b_safe when it is a player.
#[inline]
pub fn b_safe_for(profile_b_safe: f64, follower_is_player: bool, player_b_safe: f64) -> f64 {
    if follower_is_player {
        minf(profile_b_safe, player_b_safe)
    } else {
        profile_b_safe
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asymmetric_bias() {
        assert_eq!(threshold(0.2, 0.3, true), 0.2 - 0.3);
        assert_eq!(threshold(0.2, 0.3, false), 0.2 + 0.3);
        assert!(accepts(0.0, 0.2, 0.3, true));
        assert!(!accepts(0.0, 0.2, 0.3, false));
        assert_eq!(b_safe_for(4.0, true, 2.0), 2.0);
        assert_eq!(b_safe_for(4.0, false, 2.0), 4.0);
        assert!(is_safe(-2.0, 2.0) && !is_safe(-2.0001, 2.0));
    }
}
