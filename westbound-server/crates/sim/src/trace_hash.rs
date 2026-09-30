//! Port of `src/core/trace_hash.gd` (`TraceHash`): allocation-free 32-bit FNV-1a-style
//! hashing of sim state for determinism tests. Floats hash by their exact IEEE-754 bits,
//! so a seeded Rust trace and a seeded GDScript trace give the same numbers when the
//! states are bit-identical.

pub const SEED: u64 = 2_166_136_261;
const PRIME: u64 = 16_777_619;
const MASK32: u64 = 0xFFFF_FFFF;

/// `TraceHash.mix_int` (x is a GDScript int: 64-bit signed).
pub fn mix_int(h: u64, x: i64) -> u64 {
    let lo = (x as u64) & MASK32;
    let hi = ((x >> 32) as u64) & MASK32;
    let h = ((h ^ lo) * PRIME) & MASK32;
    ((h ^ hi) * PRIME) & MASK32
}

/// `TraceHash.mix_float`: the double's bits as a signed 64-bit int.
pub fn mix_float(h: u64, x: f64) -> u64 {
    mix_int(h, x.to_bits() as i64)
}

pub fn mix_bool(h: u64, x: bool) -> u64 {
    mix_int(h, i64::from(x))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negative_ints_hash_both_words() {
        assert_ne!(mix_int(SEED, -1), mix_int(SEED, 0xFFFF_FFFF));
        assert_ne!(mix_float(SEED, 0.0), mix_float(SEED, -0.0));
        assert!(mix_int(SEED, i64::MIN) <= MASK32);
    }
}
