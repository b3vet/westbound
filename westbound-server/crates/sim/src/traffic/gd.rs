//! GDScript's scalar helpers with Godot's exact semantics, so the port computes the same
//! bits as the client (`maxf`, `minf`, `clampf` are Godot's `MAX`/`MIN`/`CLAMP`
//! templates: plain comparisons, which differ from `f64::max` for signed zeros and NaN).

#[inline]
pub fn maxf(a: f64, b: f64) -> f64 {
    if a > b {
        a
    } else {
        b
    }
}

#[inline]
pub fn minf(a: f64, b: f64) -> f64 {
    if a < b {
        a
    } else {
        b
    }
}

#[inline]
pub fn clampf(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn godot_semantics() {
        assert!(maxf(-0.0, 0.0).is_sign_positive());
        assert!(maxf(0.0, -0.0).is_sign_negative());
        assert!(minf(0.0, -0.0).is_sign_negative());
        assert_eq!(maxf(f64::NAN, 1.0), 1.0);
        assert!(maxf(1.0, f64::NAN).is_nan());
        assert_eq!(clampf(5.0, 0.0, 1.0), 1.0);
    }
}
