//! N1.1 display names and the profanity filter: rules, leetspeak, separators, Turkish,
//! repeated letters, whole-word entries, allow-listed false positives, default names.

use westbound_server::names::{self, NameError, ADJECTIVES, NOUNS};
use westbound_server::profanity::{ProfanityFilter, BUILTIN_LIST};

fn filter() -> &'static ProfanityFilter {
    ProfanityFilter::builtin()
}

#[test]
fn builtin_list_parses_and_is_modest() {
    let f = ProfanityFilter::parse(BUILTIN_LIST).unwrap();
    let (anywhere, tokens, allowed) = f.counts();
    assert!(anywhere >= 40 && tokens >= 15 && allowed >= 20);
    assert!(anywhere + tokens < 200, "keep the list small and curated");
}

#[test]
fn list_format_errors() {
    assert!(ProfanityFilter::parse("# c\n\nword\n=wd\n!words\n").is_ok());
    for bad in ["a", "=b", "two words", "l33t", "!x"] {
        assert!(ProfanityFilter::parse(bad).is_err(), "{bad}");
    }
}

#[test]
fn catches_obvious_and_disguised_words() {
    for dirty in [
        "fuck",
        "FUCK",
        "MotherFucker",
        "xXfuckXx",
        "f.u.c.k",
        "f_u-c k",
        "fuuuuck",
        "sh1t",
        "5h1t",
        "$hit",
        "c0ck",
        "B1tch",
        "b!tch",
        "d1ck",
        "n1gg3r",
        "p0rn",
        "h1tl3r",
        "cunt",
        // whole-word entries
        "ass",
        "a55",
        "4ss",
        "Big Ass",
        "BigAss",
        "Big_4ss",
        "a.s.s",
        "Tits",
        "cum",
        // Turkish, with folding and leetspeak
        "orospu",
        "0r0spu",
        "OROSPU",
        "Orospu Çocuğu",
        "amk",
        "AMK",
        "s1kt1r",
        "siktir",
        "Sik",
        "piç",
        "p1ç",
        "yarrak",
        "yarak",
        "amcık",
        "AMCIK",
        "ibne",
        "1bne",
        "yavşak",
        "yavsak",
        "şerefsiz",
        // a clean word elsewhere does not excuse a second, bad occurrence
        "Scunthorpe cunt",
        "Essexsex",
    ] {
        assert!(filter().find(dirty).is_some(), "should be caught: {dirty}");
    }
}

#[test]
fn allows_ordinary_words_and_false_positives() {
    for clean in [
        "SwiftFalcon",
        "Scunthorpe",
        "Essex Rider",
        "Middlesex",
        "Cocktail",
        "Peacock",
        "Hitchcock",
        "Classic",
        "Bassist",
        "Assassin",
        "Passenger",
        "Cucumber",
        "Document",
        "Titan",
        "Grape",
        "Therapist",
        "Skyscraper",
        "Dickens",
        "Nazım",
        "Nazik",
        "Shiitake",
        "Sıkışık",
        "Japan",
        "Bob",
        "Picnic",
        "Sikke",
        "Kartal",
        "Şahin",
        "Gökhan",
        "Road Runner",
        "Racer42",
        "Epic",
        "Canal",
        "Analog",
        "Spice",
        "Raccoon",
    ] {
        assert_eq!(filter().find(clean), None, "false positive: {clean}");
    }
}

#[test]
fn name_rules() {
    let ok = |s: &str| names::validate(s, filter());
    assert_eq!(ok("abc").unwrap(), "abc");
    assert_eq!(ok("  Road Runner ").unwrap(), "Road Runner");
    assert_eq!(ok("ŞahinÇiğdemÖzÜ").unwrap(), "ŞahinÇiğdemÖzÜ");
    assert_eq!(ok("x_y-z.1").unwrap(), "x_y-z.1");
    assert_eq!(ok("abcdefghijklmnop").unwrap().chars().count(), 16);
    assert_eq!(ok("ab"), Err(NameError::Length));
    assert_eq!(ok("abcdefghijklmnopq"), Err(NameError::Length));
    assert_eq!(ok("ağğğğğğğğğğğğğğğ").unwrap().chars().count(), 16);
    assert_eq!(ok("name#1234"), Err(NameError::Charset));
    assert_eq!(ok("José"), Err(NameError::Charset));
    assert_eq!(ok("s\u{0327}ahin"), Err(NameError::Charset), "decomposed");
    assert_eq!(ok("a\u{200B}bc"), Err(NameError::Charset));
    assert_eq!(ok("Rider😀"), Err(NameError::Charset));
    assert_eq!(ok("_abc"), Err(NameError::Shape));
    assert_eq!(ok("abc-"), Err(NameError::Shape));
    assert_eq!(ok("a  b"), Err(NameError::Shape));
    assert_eq!(ok("a-.b"), Err(NameError::Shape));
    assert_eq!(ok("12345"), Err(NameError::NoLetter));
    assert_eq!(ok("1.2.3"), Err(NameError::NoLetter));
    assert_eq!(ok("Sh1tHead"), Err(NameError::NotAllowed));
    assert_eq!(NameError::NotAllowed.code(), "name_not_allowed");
    assert_eq!(NameError::Charset.code(), "invalid_name");
    assert_eq!(names::full_name("Rider", 7), "Rider#0007");
}

#[test]
fn every_default_name_is_valid_and_clean() {
    let mut seen = std::collections::HashSet::new();
    for a in ADJECTIVES {
        for n in NOUNS {
            let name = format!("{a}{n}");
            assert!(
                names::validate(&name, filter()).as_deref() == Ok(name.as_str()),
                "{name}"
            );
            seen.insert(name);
        }
    }
    let total = ADJECTIVES.len() * NOUNS.len();
    assert_eq!(seen.len(), total);
    // The generator reaches every pair.
    let generated: std::collections::HashSet<String> =
        (0..total as u32).map(names::default_name).collect();
    assert_eq!(generated.len(), total);
    assert!(names::default_name(u32::MAX).len() <= names::MAX_NAME_CHARS);
}
