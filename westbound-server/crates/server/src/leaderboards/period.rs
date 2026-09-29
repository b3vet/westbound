//! Leaderboard periods and their keys. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! "Leaderboards" (Loop: monthly season and all-time; Journey: weekly and all-time; Daily
//! Drive: per UTC date; Distance: all-time).
//!
//! | Kind | Key | Span (UTC) |
//! | --- | --- | --- |
//! | Season | `YYYY-MM` | the calendar month |
//! | Week | `YYYY-Www` | the ISO 8601 week (Monday to Sunday; the year is the ISO week year) |
//! | Day | `YYYY-MM-DD` | the date |
//! | All | `all` | everything |
//!
//! Every key is computed from a UTC day number (days since 1970-01-01), so a period rolls
//! over at 00:00 UTC.

use crate::clock::{civil_from_days, days_from_civil, parse_date_days, SECS_PER_DAY};

/// The all-time period's key.
pub const ALL: &str = "all";
const DAYS_PER_WEEK: i64 = 7;
/// ISO weekday offset: 1970-01-01 was a Thursday (Monday = 0 → Thursday = 3).
const EPOCH_WEEKDAY_FROM_MONDAY: i64 = 3;
/// ISO week 1 is the week containing January 4th.
const ISO_WEEK1_DAY: u32 = 4;
/// December 28th is always in the last ISO week of its year.
const LAST_WEEK_DAY: u32 = 28;
const MONTHS: u32 = 12;
/// Four-digit years only (keys sort as text).
const MIN_YEAR: i64 = 1;
const MAX_YEAR: i64 = 9_999;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PeriodKind {
    Season,
    Week,
    Day,
    All,
}

impl PeriodKind {
    pub fn as_str(self) -> &'static str {
        match self {
            PeriodKind::Season => "season",
            PeriodKind::Week => "week",
            PeriodKind::Day => "day",
            PeriodKind::All => "all",
        }
    }
}

/// A concrete period: its kind, key and (except `All`) its UTC day span.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Period {
    pub kind: PeriodKind,
    pub key: String,
    /// First day (days since epoch), inclusive; `All`: `i64::MIN`.
    pub start_day: i64,
    /// Last day, exclusive; `All`: `i64::MAX`.
    pub end_day: i64,
}

impl Period {
    pub fn all() -> Period {
        Period {
            kind: PeriodKind::All,
            key: ALL.to_string(),
            start_day: i64::MIN,
            end_day: i64::MAX,
        }
    }

    /// The period of `kind` that contains `day`.
    pub fn containing(kind: PeriodKind, day: i64) -> Period {
        match kind {
            PeriodKind::All => Period::all(),
            PeriodKind::Day => Period {
                kind,
                key: date_key(day),
                start_day: day,
                end_day: day + 1,
            },
            PeriodKind::Season => {
                let (y, m, _) = civil_from_days(day);
                let start = days_from_civil(y, m, 1);
                let (ny, nm) = if m == MONTHS { (y + 1, 1) } else { (y, m + 1) };
                Period {
                    kind,
                    key: format!("{y:04}-{m:02}"),
                    start_day: start,
                    end_day: days_from_civil(ny, nm, 1),
                }
            }
            PeriodKind::Week => {
                let (iso_year, week) = iso_week(day);
                let start = day - weekday_from_monday(day);
                Period {
                    kind,
                    key: format!("{iso_year:04}-W{week:02}"),
                    start_day: start,
                    end_day: start + DAYS_PER_WEEK,
                }
            }
        }
    }

    /// The period of `kind` containing the unix time `t`.
    pub fn at(kind: PeriodKind, t: i64) -> Period {
        Period::containing(kind, t.div_euclid(SECS_PER_DAY))
    }

    /// Parses a key of `kind`; `None` if malformed or not a real period.
    pub fn parse(kind: PeriodKind, key: &str) -> Option<Period> {
        let day = match kind {
            PeriodKind::All => return (key == ALL).then(Period::all),
            PeriodKind::Day => parse_date_days(key)?,
            PeriodKind::Season => {
                let (y, m) = key.split_once('-')?;
                if y.len() != 4 || m.len() != 2 || !all_digits(y) || !all_digits(m) {
                    return None;
                }
                let (y, m): (i64, u32) = (y.parse().ok()?, m.parse().ok()?);
                if !(1..=MONTHS).contains(&m) {
                    return None;
                }
                days_from_civil(y, m, 1)
            }
            PeriodKind::Week => {
                let (y, w) = key.split_once("-W")?;
                if y.len() != 4 || w.len() != 2 || !all_digits(y) || !all_digits(w) {
                    return None;
                }
                let (y, w): (i64, i64) = (y.parse().ok()?, w.parse().ok()?);
                if w < 1 {
                    return None;
                }
                let jan4 = days_from_civil(y, 1, ISO_WEEK1_DAY);
                jan4 - weekday_from_monday(jan4) + (w - 1) * DAYS_PER_WEEK
            }
        };
        let (y, _, _) = civil_from_days(day);
        if !(MIN_YEAR..=MAX_YEAR).contains(&y) {
            return None;
        }
        // Round trip: rejects week 53 of a 52-week year, 2026-13, and the like.
        let p = Period::containing(kind, day);
        (p.key == key).then_some(p)
    }

    /// First and last date (`YYYY-MM-DD`, inclusive) of the span; `None` for `All`.
    pub fn date_range(&self) -> Option<(String, String)> {
        (self.kind != PeriodKind::All)
            .then(|| (date_key(self.start_day), date_key(self.end_day - 1)))
    }

    pub fn contains_day(&self, day: i64) -> bool {
        (self.start_day..self.end_day).contains(&day)
    }
}

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// `YYYY-MM-DD` of a day number.
pub fn date_key(day: i64) -> String {
    let (y, m, d) = civil_from_days(day);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Monday = 0 … Sunday = 6.
pub fn weekday_from_monday(day: i64) -> i64 {
    (day + EPOCH_WEEKDAY_FROM_MONDAY).rem_euclid(DAYS_PER_WEEK)
}

/// ISO 8601 (week-numbering year, week 1..=53) of a day.
pub fn iso_week(day: i64) -> (i64, i64) {
    // The week belongs to the year of its Thursday.
    let thursday = day - weekday_from_monday(day) + EPOCH_WEEKDAY_FROM_MONDAY;
    let (year, _, _) = civil_from_days(thursday);
    let jan1 = days_from_civil(year, 1, 1);
    (year, (thursday - jan1) / DAYS_PER_WEEK + 1)
}

/// ISO weeks in a year (52 or 53).
pub fn iso_weeks_in_year(year: i64) -> i64 {
    iso_week(days_from_civil(year, MONTHS, LAST_WEEK_DAY)).1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(s: &str) -> i64 {
        parse_date_days(s).unwrap()
    }

    #[test]
    fn iso_weeks_match_known_dates() {
        // (date, ISO week key) pairs from the ISO 8601 calendar.
        for (d, w) in [
            ("2026-09-29", "2026-W40"),
            ("2026-01-01", "2026-W01"),
            ("2025-12-29", "2026-W01"),
            ("2027-01-01", "2026-W53"),
            ("2027-01-03", "2026-W53"),
            ("2027-01-04", "2027-W01"),
            ("2021-01-03", "2020-W53"),
            ("2024-12-30", "2025-W01"),
            ("2005-01-02", "2004-W53"),
            ("2008-12-29", "2009-W01"),
            ("1970-01-01", "1970-W01"),
        ] {
            assert_eq!(Period::containing(PeriodKind::Week, day(d)).key, w, "{d}");
        }
        assert_eq!(iso_weeks_in_year(2026), 53);
        assert_eq!(iso_weeks_in_year(2025), 52);
        assert_eq!(iso_weeks_in_year(2020), 53);
    }

    #[test]
    fn week_spans_monday_to_sunday() {
        let p = Period::containing(PeriodKind::Week, day("2026-09-29"));
        assert_eq!(
            p.date_range().unwrap(),
            ("2026-09-28".into(), "2026-10-04".into())
        );
        assert_eq!(weekday_from_monday(day("2026-09-28")), 0);
        assert_eq!(Period::parse(PeriodKind::Week, "2026-W40"), Some(p));
    }

    #[test]
    fn seasons_and_days() {
        let s = Period::containing(PeriodKind::Season, day("2024-02-29"));
        assert_eq!(s.key, "2024-02");
        assert_eq!(
            s.date_range().unwrap(),
            ("2024-02-01".into(), "2024-02-29".into())
        );
        let dec = Period::containing(PeriodKind::Season, day("2026-12-31"));
        assert_eq!(dec.end_day, day("2027-01-01"));
        assert_eq!(Period::at(PeriodKind::Day, 1_790_000_000).key, "2026-09-21");
        assert_eq!(Period::at(PeriodKind::All, 0).key, "all");
    }

    #[test]
    fn parse_rejects_bad_keys() {
        for (kind, key) in [
            (PeriodKind::Season, "2026-13"),
            (PeriodKind::Season, "2026-1"),
            (PeriodKind::Season, "26-01"),
            (PeriodKind::Season, "2026-0a"),
            (PeriodKind::Season, "+026-01"),
            (PeriodKind::Week, "2025-W53"),
            (PeriodKind::Week, "2026-W00"),
            (PeriodKind::Week, "2026-W54"),
            (PeriodKind::Week, "2026W40"),
            (PeriodKind::Week, "2026-40"),
            (PeriodKind::Day, "2026-02-30"),
            (PeriodKind::Day, "2026-9-29"),
            (PeriodKind::All, "ALL"),
            (PeriodKind::Day, "all"),
        ] {
            assert_eq!(Period::parse(kind, key), None, "{key}");
        }
        for (kind, key) in [
            (PeriodKind::Season, "2026-09"),
            (PeriodKind::Week, "2026-W53"),
            (PeriodKind::Week, "2020-W53"),
            (PeriodKind::Day, "2024-02-29"),
            (PeriodKind::All, "all"),
        ] {
            assert_eq!(Period::parse(kind, key).unwrap().key, key);
        }
    }

    #[test]
    fn every_day_round_trips() {
        // Four years of days: each key parses back to the same period and contains the day.
        let start = day("2024-01-01");
        for d in start..start + 4 * 366 {
            for kind in [PeriodKind::Season, PeriodKind::Week, PeriodKind::Day] {
                let p = Period::containing(kind, d);
                assert!(p.contains_day(d));
                assert_eq!(Period::parse(kind, &p.key).as_ref(), Some(&p));
            }
        }
    }
}
