//! Profanity filter for display names (and crew names later), from a normalized word
//! list that catches letter-for-number swaps. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! "Moderation" (display names), "Accounts and authentication" (display names).
//!
//! **Normalization** (applied to the list and to the checked text alike):
//! 1. Turkish folding and lowercasing: `İ I ı → i`, `ç → c`, `ğ → g`, `ö → o`, `ş → s`,
//!    `ü → u` (plus `â î û`).
//! 2. Leetspeak: `0→o 1→i/l 3→e 4→a 5→s 6→g 7→t 8→b 9→g @→a $→s !→i |→l/i +→t €→e`.
//!    `1` and `|` are ambiguous, so the text is checked twice (as `i`, then as `l`).
//! 3. Everything else that is not `a–z` is a separator: dropped from the joined text,
//!    and a token boundary. A lower-to-upper case change is a token boundary too
//!    (`BigWord` → `big`, `word`).
//!
//! **Matching.** Letters may repeat (`fuuuck` matches `fuck`, but `bob` does not match
//! `boob`). The list (`westbound-server/data/profanity.txt`) has three kinds of line:
//! - `word`: banned anywhere in the joined text (`xXwordXx`, `w.o.r.d`);
//! - `=word`: banned only as a whole token or the whole name (short words that hide
//!   inside ordinary ones: `=ass` rejects `Ass Man`, not `Classic`);
//! - `!word`: allowed; a banned match that lies wholly inside an allowed word is
//!   ignored (Scunthorpe, Essex, cocktail, therapist).

use std::sync::LazyLock;

/// The built-in list, compiled into the binary.
pub const BUILTIN_LIST: &str = include_str!("../../../data/profanity.txt");

static BUILTIN: LazyLock<ProfanityFilter> = LazyLock::new(|| {
    ProfanityFilter::parse(BUILTIN_LIST).expect("data/profanity.txt is valid (tested)")
});

#[derive(Debug, Clone, Default)]
pub struct ProfanityFilter {
    anywhere: Vec<Vec<u8>>,
    tokens: Vec<Vec<u8>>,
    allowed: Vec<Vec<u8>>,
}

/// Normalized text: `a–z` only, plus the token spans within it.
#[derive(Debug, Default)]
struct Normalized {
    text: Vec<u8>,
    tokens: Vec<(usize, usize)>,
}

impl ProfanityFilter {
    /// The filter built from `data/profanity.txt`.
    pub fn builtin() -> &'static ProfanityFilter {
        &BUILTIN
    }

    /// Parses a word list. Blank lines and `#` comments are skipped; every entry must
    /// normalize to at least two letters.
    pub fn parse(list: &str) -> Result<Self, String> {
        let mut f = ProfanityFilter::default();
        for (i, line) in list.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (kind, word) = match line.as_bytes()[0] {
                b'=' => (1, &line[1..]),
                b'!' => (2, &line[1..]),
                _ => (0, line),
            };
            let n = normalize(word, false);
            if n.text.len() < 2 || n.tokens.len() != 1 || word.chars().any(|c| c.is_ascii_digit()) {
                return Err(format!(
                    "line {}: `{line}` must be one word of letters (at least two)",
                    i + 1
                ));
            }
            match kind {
                0 => f.anywhere.push(n.text),
                1 => f.tokens.push(n.text),
                _ => f.allowed.push(n.text),
            }
        }
        Ok(f)
    }

    /// Number of (anywhere, token, allowed) entries.
    pub fn counts(&self) -> (usize, usize, usize) {
        (self.anywhere.len(), self.tokens.len(), self.allowed.len())
    }

    pub fn is_clean(&self, text: &str) -> bool {
        self.find(text).is_none()
    }

    /// The first banned list entry found in `text` (normalized), if any.
    pub fn find(&self, text: &str) -> Option<String> {
        for alt in [false, true] {
            let n = normalize(text, alt);
            if let Some(w) = self.find_in(&n) {
                return Some(String::from_utf8_lossy(w).into_owned());
            }
        }
        None
    }

    fn find_in(&self, n: &Normalized) -> Option<&[u8]> {
        let t = &n.text;
        for w in &self.anywhere {
            for start in 0..t.len() {
                if let Some(end) = match_repeats(w, t, start, None) {
                    if !self.excused(t, start, end) {
                        return Some(w);
                    }
                }
            }
        }
        let whole = (0, t.len());
        for w in &self.tokens {
            for &(s, e) in n.tokens.iter().chain(std::iter::once(&whole)) {
                if s < e && match_repeats(w, &t[..e], s, Some(e)).is_some() {
                    return Some(w);
                }
            }
        }
        None
    }

    /// True if `[start, end)` lies inside an occurrence of an allowed word.
    fn excused(&self, t: &[u8], start: usize, end: usize) -> bool {
        self.allowed.iter().any(|a| {
            (0..=start).any(|s| matches!(match_repeats(a, t, s, None), Some(e) if e >= end))
        })
    }
}

/// Matches `word` at `t[start..]`, each letter repeatable (`fuuck` ~ `fuck`), taking as
/// few repeats as possible. Returns the end of the match; with `must_end`, only a
/// match ending exactly there counts.
fn match_repeats(word: &[u8], t: &[u8], start: usize, must_end: Option<usize>) -> Option<usize> {
    fn go(w: &[u8], t: &[u8], wi: usize, ti: usize, must_end: Option<usize>) -> Option<usize> {
        if wi == w.len() {
            return match must_end {
                Some(e) if e != ti => None,
                _ => Some(ti),
            };
        }
        if ti >= t.len() || t[ti] != w[wi] {
            return None;
        }
        let mut k = ti + 1;
        loop {
            if let Some(end) = go(w, t, wi + 1, k, must_end) {
                return Some(end);
            }
            if k < t.len() && t[k] == w[wi] {
                k += 1;
            } else {
                return None;
            }
        }
    }
    go(word, t, 0, start, must_end)
}

/// Folds one character to `a–z` (possibly after leetspeak mapping), or `None` for a
/// separator. `alt` picks the second reading of `1` and `|`.
fn fold(c: char, alt: bool) -> Option<u8> {
    let c = match c {
        'İ' | 'I' | 'ı' | 'î' | 'Î' => 'i',
        'ç' | 'Ç' => 'c',
        'ğ' | 'Ğ' => 'g',
        'ö' | 'Ö' => 'o',
        'ş' | 'Ş' => 's',
        'ü' | 'Ü' | 'û' | 'Û' => 'u',
        'â' | 'Â' => 'a',
        '0' => 'o',
        '1' | '|' => {
            if alt {
                'l'
            } else {
                'i'
            }
        }
        '!' => 'i',
        '3' | '€' => 'e',
        '4' | '@' => 'a',
        '5' | '$' => 's',
        '6' | '9' => 'g',
        '7' | '+' => 't',
        '8' => 'b',
        c => c.to_ascii_lowercase(),
    };
    c.is_ascii_lowercase().then_some(c as u8)
}

fn normalize(s: &str, alt: bool) -> Normalized {
    let mut n = Normalized::default();
    let mut token_start: Option<usize> = None;
    let mut prev_lower = false;
    for c in s.chars() {
        match fold(c, alt) {
            Some(b) => {
                let upper = c.is_uppercase();
                if upper && prev_lower {
                    if let Some(s0) = token_start.take() {
                        n.tokens.push((s0, n.text.len()));
                    }
                }
                if token_start.is_none() {
                    token_start = Some(n.text.len());
                }
                n.text.push(b);
                prev_lower = c.is_lowercase();
            }
            None => {
                if let Some(s0) = token_start.take() {
                    n.tokens.push((s0, n.text.len()));
                }
                prev_lower = false;
            }
        }
    }
    if let Some(s0) = token_start {
        n.tokens.push((s0, n.text.len()));
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeats_and_anchoring() {
        assert_eq!(match_repeats(b"fuck", b"xfuuuckx", 1, None), Some(7));
        assert_eq!(match_repeats(b"boob", b"bob", 0, None), None);
        assert_eq!(match_repeats(b"boob", b"booob", 0, None), Some(5));
        assert_eq!(match_repeats(b"ass", b"asss", 0, Some(4)), Some(4));
        assert_eq!(match_repeats(b"ass", b"assx", 0, Some(4)), None);
    }

    #[test]
    fn tokens_split_on_separators_and_case() {
        let n = normalize("Big_AssHat 4ss", false);
        assert_eq!(n.text, b"bigasshatass");
        assert_eq!(n.tokens, vec![(0, 3), (3, 6), (6, 9), (9, 12)]);
    }
}
