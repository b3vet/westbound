//! Bit-exact port of the client's seeded RNG (`src/core/rng.gd`, `Rng`), so a seeded
//! server run and a seeded GDScript run draw the same numbers. Spec: architecture rule 2
//! (deterministic by seed); WESTBOUND_MULTIPLAYER_HANDOFF.md → Testing (traffic parity).
//!
//! `Rng` wraps Godot's `RandomNumberGenerator`, which is PCG32 (`pcg32_random_r`, the
//! XSH-RR output of a 64-bit LCG) with Godot's fixed stream increment. The float and
//! bounded-integer draws follow Godot's `RandomPCG::randf` and `RandomPCG::random`
//! exactly, so every draw is identical bit for bit. Streams are derived by name with
//! 32-bit FNV-1a (`Rng.derive_seed`). Verified against vectors exported from Godot
//! (`vectors/rng.json`, tools/server_data/export_sim_data.gd).
//!
//! Allocation-free after construction; no global state.

/// Godot's `RandomPCG::DEFAULT_INC` (`PCG_DEFAULT_INC_64`).
const PCG_INC: u64 = 1_442_695_040_888_963_407;
const PCG_MULT: u64 = 6_364_136_223_846_793_005;
const FNV_OFFSET: u32 = 2_166_136_261;
const FNV_PRIME: u32 = 16_777_619;

/// A seeded PCG32 stream (Godot's `RandomNumberGenerator` with `seed` set).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rng {
    seed: i64,
    state: u64,
    inc: u64,
}

impl Rng {
    /// `Rng.new(seed)`: `RandomNumberGenerator.seed = seed` (`pcg32_srandom_r`).
    pub fn new(seed: i64) -> Self {
        let mut r = Rng {
            seed,
            state: 0,
            inc: (PCG_INC << 1) | 1,
        };
        r.next_u32();
        r.state = r.state.wrapping_add(seed as u64);
        r.next_u32();
        r
    }

    pub fn seed(&self) -> i64 {
        self.seed
    }

    /// A new independent stream derived from this stream's seed and `name`.
    pub fn derive(&self, name: &str) -> Rng {
        Rng::new(derive_seed(self.seed, name))
    }

    /// `pcg32_random_r`: the next raw 32-bit output (Godot's `randi()`).
    pub fn next_u32(&mut self) -> u32 {
        let old = self.state;
        self.state = old.wrapping_mul(PCG_MULT).wrapping_add(self.inc);
        let xorshifted = (((old >> 18) ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        xorshifted.rotate_right(rot)
    }

    /// Uniform float in [0, 1] (Godot's `randf()`: a 32-bit float, widened).
    pub fn unit(&mut self) -> f64 {
        let proto = self.next_u32();
        if proto == 0 {
            return 0.0;
        }
        let m = (self.next_u32() | 0x8000_0001) as f32;
        // ldexpf(m, -32 - clz(proto)): the result is a normal f32, so scaling by an exact
        // power of two is exact.
        let e = -32 - proto.leading_zeros() as i32;
        let scale = f32::from_bits(((127 + e) as u32) << 23);
        f64::from(m * scale)
    }

    /// `from + (to - from) * randf()`.
    pub fn float_range(&mut self, from: f64, to: f64) -> f64 {
        from + (to - from) * self.unit()
    }

    /// Uniform int in [from, to], inclusive (Godot's `randi_range`).
    pub fn int_range(&mut self, from: i32, to: i32) -> i32 {
        if from == to {
            return from;
        }
        let lo = i64::from(from.min(to));
        let hi = i64::from(from.max(to));
        let diff = (hi - lo) as u32;
        if diff == u32::MAX {
            return (i64::from(self.next_u32()) + lo) as i32;
        }
        (i64::from(self.bounded(diff + 1)) + lo) as i32
    }

    /// True with probability p.
    pub fn chance(&mut self, p: f64) -> bool {
        self.unit() < p
    }

    /// Index into `weights` chosen proportionally to its (non-negative) weight.
    pub fn pick_weighted(&mut self, weights: &[f64]) -> usize {
        let mut total = 0.0;
        for w in weights {
            total += w;
        }
        let mut r = self.unit() * total;
        for (i, w) in weights.iter().enumerate() {
            r -= w;
            if r < 0.0 {
                return i;
            }
        }
        weights.len().saturating_sub(1)
    }

    /// Opaque generator state (Godot's `RandomNumberGenerator.state`).
    pub fn state(&self) -> u64 {
        self.state
    }

    pub fn set_state(&mut self, state: u64) {
        self.state = state;
    }

    /// `pcg32_boundedrand_r`.
    fn bounded(&mut self, bound: u32) -> u32 {
        let threshold = bound.wrapping_neg() % bound;
        loop {
            let r = self.next_u32();
            if r >= threshold {
                return r % bound;
            }
        }
    }
}

/// 32-bit FNV-1a over the UTF-8 bytes of `text`, continuing from `h`.
pub fn fnv1a32_from(text: &str, mut h: u32) -> u32 {
    for b in text.bytes() {
        h = (h ^ u32::from(b)).wrapping_mul(FNV_PRIME);
    }
    h
}

/// 32-bit FNV-1a over the UTF-8 bytes of `text`.
pub fn fnv1a32(text: &str) -> u32 {
    fnv1a32_from(text, FNV_OFFSET)
}

/// Stable 63-bit child seed from a parent seed and a stream name (`Rng.derive_seed`).
/// Allocation-free: the key `"<parent>/<name>"` is hashed piecewise.
pub fn derive_seed(parent: i64, name: &str) -> i64 {
    let mut buf = [0u8; 24];
    let digits = format_i64(parent, &mut buf);
    let mut h = fnv1a32_from(digits, FNV_OFFSET);
    h = fnv1a32_from("/", h);
    h = fnv1a32_from(name, h);
    let hi = h & 0x7FFF_FFFF;
    let lo = fnv1a32_from("#", h);
    (i64::from(hi) << 32) | i64::from(lo)
}

/// Decimal digits of `x` into `buf` (no allocation).
fn format_i64(x: i64, buf: &mut [u8; 24]) -> &str {
    let mut n = x.unsigned_abs();
    let mut i = buf.len();
    loop {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    if x < 0 {
        i -= 1;
        buf[i] = b'-';
    }
    std::str::from_utf8(&buf[i..]).unwrap_or("0")
}

/// Stream names of `src/core/rng.gd`.
pub const STREAM_TRAFFIC: &str = "traffic";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_draws_match_godot() {
        // Godot 4.7: RandomNumberGenerator.seed = 1; randi(), randi().
        let mut r = Rng::new(1);
        assert_eq!(r.next_u32(), 1_811_587_497);
        assert_eq!(r.next_u32(), 683_407_368);
        assert_eq!(r.state() as i64, -6_618_438_155_849_649_559);
        // seed = 12345; randf() x 2.
        let mut r = Rng::new(12345);
        assert_eq!(r.unit(), 0.252_041_906_118_392_94);
        assert_eq!(r.unit(), 0.666_673_004_627_227_8);
    }

    #[test]
    fn derive_seed_formats_like_gdscript() {
        let mut buf = [0u8; 24];
        assert_eq!(format_i64(i64::MIN, &mut buf), "-9223372036854775808");
        assert_eq!(format_i64(0, &mut buf), "0");
        assert_eq!(format_i64(-7, &mut buf), "-7");
        // Same key hashed in one piece.
        let key = "42/traffic";
        let h = fnv1a32(key);
        let want = (i64::from(h & 0x7FFF_FFFF) << 32) | i64::from(fnv1a32(&format!("{key}#")));
        assert_eq!(derive_seed(42, "traffic"), want);
    }

    #[test]
    fn int_range_is_inclusive_and_ordered() {
        let mut r = Rng::new(9);
        let mut seen = [false; 5];
        for _ in 0..200 {
            let x = r.int_range(3, -1);
            assert!((-1..=3).contains(&x));
            seen[(x + 1) as usize] = true;
        }
        assert!(seen.iter().all(|s| *s));
        assert_eq!(r.int_range(4, 4), 4);
    }
}
