//! Display names: `name#1234`, validation rules and generated default names.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Accounts and authentication" (display
//! names: name#1234 form, 3–16 characters, profanity-filtered), "Moderation".
//!
//! **Rules** (the part before `#`):
//! - 3–16 characters, after trimming surrounding whitespace (protocol cap: 16 chars);
//! - letters `A–Z a–z`, the Turkish letters `Ç ç Ğ ğ İ ı Ö ö Ş ş Ü ü`, digits `0–9`,
//!   and the separators space, `_`, `-`, `.`;
//! - starts and ends with a letter or digit, no two separators in a row, at least
//!   one letter;
//! - passes the profanity filter (`profanity.rs`).
//!
//! Composed characters only: a decomposed `ş` (s + combining cedilla) is rejected
//! because combining marks are not in the set.

use crate::profanity::ProfanityFilter;

pub const MIN_NAME_CHARS: usize = 3;
pub const MAX_NAME_CHARS: usize = protocol::types::MAX_NAME_CHARS;
/// Tags are `0000`–`9999` (protocol: `name_tag` 0–9999).
pub const MAX_TAG: u16 = protocol::messages::MAX_NAME_TAG;
pub const TAG_COUNT: u32 = MAX_TAG as u32 + 1;

const TURKISH_LETTERS: &str = "ÇçĞğİıÖöŞşÜü";
const SEPARATORS: &str = " _-.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum NameError {
    #[error("A name must be 3 to 16 characters.")]
    Length,
    #[error("Names may use letters, digits, spaces, '_', '-' and '.'.")]
    Charset,
    #[error("A name must start and end with a letter or digit, without two separators in a row.")]
    Shape,
    #[error("A name must contain at least one letter.")]
    NoLetter,
    #[error("That name is not allowed.")]
    NotAllowed,
}

impl NameError {
    /// The API error code: `name_not_allowed` for the filter, `invalid_name` otherwise.
    pub fn code(self) -> &'static str {
        match self {
            NameError::NotAllowed => "name_not_allowed",
            _ => "invalid_name",
        }
    }
}

fn is_letter(c: char) -> bool {
    c.is_ascii_alphabetic() || TURKISH_LETTERS.contains(c)
}

fn is_separator(c: char) -> bool {
    SEPARATORS.contains(c)
}

/// Checks a requested name and returns it trimmed.
pub fn validate(raw: &str, filter: &ProfanityFilter) -> Result<String, NameError> {
    validate_len(raw, filter, MIN_NAME_CHARS, MAX_NAME_CHARS)
}

/// The name rules with another length range (crew names, N9.1).
pub fn validate_len(
    raw: &str,
    filter: &ProfanityFilter,
    min_chars: usize,
    max_chars: usize,
) -> Result<String, NameError> {
    let name = raw.trim();
    let len = name.chars().count();
    if !(min_chars..=max_chars).contains(&len) {
        return Err(NameError::Length);
    }
    if !name
        .chars()
        .all(|c| is_letter(c) || c.is_ascii_digit() || is_separator(c))
    {
        return Err(NameError::Charset);
    }
    let first = name.chars().next().expect("non-empty");
    let last = name.chars().next_back().expect("non-empty");
    let doubled = name
        .chars()
        .zip(name.chars().skip(1))
        .any(|(a, b)| is_separator(a) && is_separator(b));
    if is_separator(first) || is_separator(last) || doubled {
        return Err(NameError::Shape);
    }
    if !name.chars().any(is_letter) {
        return Err(NameError::NoLetter);
    }
    if !filter.is_clean(name) {
        return Err(NameError::NotAllowed);
    }
    Ok(name.to_string())
}

/// `name#0042`.
pub fn full_name(name: &str, tag: u16) -> String {
    format!("{name}#{tag:04}")
}

/// Default-name words: every adjective + noun pair is at most 16 characters and
/// passes the filter (tested).
pub const ADJECTIVES: &[&str] = &[
    "Amber", "Brave", "Chrome", "Coastal", "Cobalt", "Copper", "Crimson", "Desert", "Dusk",
    "Dusty", "Electric", "Golden", "Lone", "Lucky", "Mellow", "Midnight", "Neon", "Nimble",
    "Quiet", "Rusty", "Scarlet", "Silent", "Solar", "Steady", "Sunset", "Swift", "Velvet", "Wild",
];
pub const NOUNS: &[&str] = &[
    "Bison", "Comet", "Coyote", "Cruiser", "Driver", "Drifter", "Eagle", "Falcon", "Fox", "Hawk",
    "Lynx", "Mirage", "Mustang", "Nomad", "Outlaw", "Pilot", "Racer", "Ranger", "Raven", "Rider",
    "Rover", "Stallion", "Viper", "Wolf",
];

/// A generated default name (`SwiftFalcon`) from a random number.
pub fn default_name(random: u32) -> String {
    let n = NOUNS.len() as u32;
    let a = ADJECTIVES.len() as u32;
    let adj = ADJECTIVES[((random / n) % a) as usize];
    let noun = NOUNS[(random % n) as usize];
    format!("{adj}{noun}")
}
