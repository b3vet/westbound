//! Port of `src/scoring/road_hull.gd` (`RoadHull`): oriented boxes in road space and the
//! hull-to-hull clearance between two of them (spec: Lives, hits and crashes: "collision
//! boxes are oriented boxes in road space, inset 8 cm"; Scoring: "minimum hull-to-hull
//! clearance"). Same expressions in the same order, so the results are the GDScript's
//! bits (the trig is `detmath`'s on both sides, N8.2).
//!
//! A box is its centre (s, d), its heading relative to the road `yaw` (rad, + nose right:
//! forward axis (cos yaw, sin yaw) in (s, d)), its half-length and half-width (callers pass
//! hull half-sizes, already inset).
//!
//! [`penetration`] is the multiplayer addition (N6, the server's hit cross-check: "overlap
//! deeper than 0.3 m"): how far two overlapping boxes interpenetrate.

use crate::detmath;
use crate::traffic::gd::{maxf, minf};

/// Minimum distance between the two boxes; 0 when they overlap or touch.
#[allow(clippy::too_many_arguments)]
pub fn clearance(
    s1: f64,
    d1: f64,
    yaw1: f64,
    hl1: f64,
    hw1: f64,
    s2: f64,
    d2: f64,
    yaw2: f64,
    hl2: f64,
    hw2: f64,
) -> f64 {
    let (n1, c1) = detmath::sin_cos(yaw1);
    let (n2, c2) = detmath::sin_cos(yaw2);
    clearance_cs(s1, d1, c1, n1, hl1, hw1, s2, d2, c2, n2, hl2, hw2)
}

/// [`clearance`] with each heading as its (cos, sin) (`RoadHull.clearance_cs`: the scoring
/// passes the player's once per tick and a traffic car's from its velocity direction).
#[allow(clippy::too_many_arguments)]
pub fn clearance_cs(
    s1: f64,
    d1: f64,
    c1: f64,
    n1: f64,
    hl1: f64,
    hw1: f64,
    s2: f64,
    d2: f64,
    c2: f64,
    n2: f64,
    hl2: f64,
    hw2: f64,
) -> f64 {
    let ds = s2 - s1;
    let dd = d2 - d1;
    let b1 = Axes {
        c: c1,
        n: n1,
        hl: hl1,
        hw: hw1,
    };
    let b2 = Axes {
        c: c2,
        n: n2,
        hl: hl2,
        hw: hw2,
    };
    // Separating-axis test on the four box axes: forward (c, n) and right (-n, c).
    if !(separated(ds, dd, c1, n1, &b1, &b2)
        || separated(ds, dd, -n1, c1, &b1, &b2)
        || separated(ds, dd, c2, n2, &b1, &b2)
        || separated(ds, dd, -n2, c2, &b1, &b2))
    {
        return 0.0;
    }
    // Disjoint convex polygons: the closest pair always includes a vertex of one of them,
    // so the minimum over the 8 corner-to-box distances is exact.
    let mut best = f64::INFINITY;
    for i in 0..2 {
        let sx = f64::from(i * 2 - 1);
        for j in 0..2 {
            let sy = f64::from(j * 2 - 1);
            let ps = s1 + sx * hl1 * c1 - sy * hw1 * n1;
            let pd = d1 + sx * hl1 * n1 + sy * hw1 * c1;
            best = minf(best, point_distance(ps, pd, s2, d2, c2, n2, hl2, hw2));
            let ps = s2 + sx * hl2 * c2 - sy * hw2 * n2;
            let pd = d2 + sx * hl2 * n2 + sy * hw2 * c2;
            best = minf(best, point_distance(ps, pd, s1, d1, c1, n1, hl1, hw1));
        }
    }
    best
}

/// Distance from point (ps, pd) to the solid box centred at (cs, cd) with forward axis
/// (c, n) = (cos yaw, sin yaw); 0 inside.
#[allow(clippy::too_many_arguments)]
pub fn point_distance(ps: f64, pd: f64, cs: f64, cd: f64, c: f64, n: f64, hl: f64, hw: f64) -> f64 {
    let rs = ps - cs;
    let rd = pd - cd;
    let x = maxf((rs * c + rd * n).abs() - hl, 0.0);
    let y = maxf((-rs * n + rd * c).abs() - hw, 0.0);
    (x * x + y * y).sqrt()
}

/// How deep two boxes interpenetrate (m): the smallest overlap of their projections over
/// the four box axes (the separating-axis minimum translation distance); 0 when they are
/// apart or only touch. Multiplayer: the server's hit cross-check.
#[allow(clippy::too_many_arguments)]
pub fn penetration(
    s1: f64,
    d1: f64,
    yaw1: f64,
    hl1: f64,
    hw1: f64,
    s2: f64,
    d2: f64,
    yaw2: f64,
    hl2: f64,
    hw2: f64,
) -> f64 {
    let (n1, c1) = detmath::sin_cos(yaw1);
    let (n2, c2) = detmath::sin_cos(yaw2);
    let b1 = Axes {
        c: c1,
        n: n1,
        hl: hl1,
        hw: hw1,
    };
    let b2 = Axes {
        c: c2,
        n: n2,
        hl: hl2,
        hw: hw2,
    };
    let (ds, dd) = (s2 - s1, d2 - d1);
    let mut depth = f64::INFINITY;
    for (ax, ay) in [(c1, n1), (-n1, c1), (c2, n2), (-n2, c2)] {
        let (r1, r2) = (b1.radius(ax, ay), b2.radius(ax, ay));
        depth = minf(depth, r1 + r2 - (ds * ax + dd * ay).abs());
    }
    maxf(depth, 0.0)
}

/// A box's axes and half sizes.
struct Axes {
    c: f64,
    n: f64,
    hl: f64,
    hw: f64,
}

impl Axes {
    /// Half the box's extent along the axis (ax, ay).
    #[inline]
    fn radius(&self, ax: f64, ay: f64) -> f64 {
        self.hl * (self.c * ax + self.n * ay).abs() + self.hw * (-self.n * ax + self.c * ay).abs()
    }
}

fn separated(ds: f64, dd: f64, ax: f64, ay: f64, b1: &Axes, b2: &Axes) -> bool {
    let r1 = b1.radius(ax, ay);
    let r2 = b2.radius(ax, ay);
    (ds * ax + dd * ay).abs() > r1 + r2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn side_by_side_and_overlap() {
        // Two unrotated 4 x 2 boxes, 3 m apart centre to centre laterally: 1 m clear.
        assert!((clearance(0.0, 0.0, 0.0, 2.0, 1.0, 0.0, 3.0, 0.0, 2.0, 1.0) - 1.0).abs() < 1e-12);
        assert_eq!(
            clearance(0.0, 0.0, 0.0, 2.0, 1.0, 1.0, 1.5, 0.0, 2.0, 1.0),
            0.0
        );
        // Corner to corner: (1, 1) apart diagonally.
        let c = clearance(0.0, 0.0, 0.0, 2.0, 1.0, 5.0, 3.0, 0.0, 2.0, 1.0);
        assert!((c - 2f64.sqrt()).abs() < 1e-12);
    }

    #[test]
    fn penetration_depth() {
        assert_eq!(
            penetration(0.0, 0.0, 0.0, 2.0, 1.0, 0.0, 3.0, 0.0, 2.0, 1.0),
            0.0
        );
        // 0.4 m lateral overlap.
        let p = penetration(0.0, 0.0, 0.0, 2.0, 1.0, 0.5, 1.6, 0.0, 2.0, 1.0);
        assert!((p - 0.4).abs() < 1e-12, "{p}");
        // Rotation is covered: a yawed box overlapping corner-first.
        let q = penetration(0.0, 0.0, 0.3, 2.0, 1.0, 0.0, 2.2, 0.0, 2.0, 1.0);
        assert!(q > 0.0 && q < 1.0, "{q}");
    }
}
