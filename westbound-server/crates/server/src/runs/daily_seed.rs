//! Server port of the game's Daily Drive seed (`src/core/rng.gd`: `Rng.daily_seed`,
//! `Rng.derive_seed`, `Rng.fnv1a32`), so `POST /api/v1/runs` can check that a Daily run's
//! seed matches its date. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards"
//! (plausibility: "the Daily Drive seed matches the date").
//!
//! Must match GDScript bit for bit: `tests/runs.rs` checks it against vectors exported
//! from Godot (`tools/server_data/export_daily_seed_vectors.gd` →
//! `tests/data/daily_seed_vectors.json`). Re-export them if `rng.gd` changes.

/// 32-bit FNV-1a offset basis and prime (as in `rng.gd`).
const FNV_OFFSET: u32 = 2_166_136_261;
const FNV_PRIME: u32 = 16_777_619;
/// `derive_seed` keeps the high word below 2^31 so the seed is a non-negative int.
const HIGH_MASK: u32 = 0x7FFF_FFFF;

/// 32-bit FNV-1a over the UTF-8 bytes of `text` (GDScript's `((h ^ b) * prime) & mask`
/// equals a wrapping u32 multiply).
pub fn fnv1a32(text: &str) -> u32 {
    text.bytes().fold(FNV_OFFSET, |h, b| {
        (h ^ u32::from(b)).wrapping_mul(FNV_PRIME)
    })
}

/// Stable 63-bit child seed from a parent seed and a stream name:
/// `key = "<parent>/<name>"`, `(fnv(key) & 0x7FFFFFFF) << 32 | fnv(key + "#")`.
pub fn derive_seed(parent: i64, name: &str) -> i64 {
    let key = format!("{parent}/{name}");
    let hi = fnv1a32(&key) & HIGH_MASK;
    let lo = fnv1a32(&format!("{key}#"));
    (i64::from(hi) << 32) | i64::from(lo)
}

/// The Daily Drive seed of a UTC date (identical for every player that day).
pub fn daily_seed(year: i64, month: u32, day: u32) -> i64 {
    derive_seed(0, &format!("daily-{year:04}-{month:02}-{day:02}"))
}

/// The Daily Drive seed of a `YYYY-MM-DD` date, if it is a real date.
pub fn daily_seed_for_date(date: &str) -> Option<i64> {
    let days = crate::clock::parse_date_days(date)?;
    let (y, m, d) = crate::clock::civil_from_days(days);
    Some(daily_seed(y, m, d))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_values() {
        // From tests/data/daily_seed_vectors.json (Godot 4.7).
        assert_eq!(fnv1a32("daily-2026-09-29"), 1_369_075_905);
        assert_eq!(daily_seed(2026, 9, 29), 2_538_700_399_935_769_545);
        assert_eq!(derive_seed(-7, "props"), 4_398_515_231_736_351_933);
        assert_eq!(
            daily_seed_for_date("2024-01-01"),
            Some(3_740_553_747_566_830_985)
        );
        assert_eq!(daily_seed_for_date("2025-02-29"), None);
    }
}
