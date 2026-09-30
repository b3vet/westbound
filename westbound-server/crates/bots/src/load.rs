//! N10.1: what the load test reads off the server: its Prometheus text (`/metrics`, the
//! localhost metrics listener) parsed into a [`Scrape`], windows between two scrapes
//! (counter deltas, histogram quantiles), and `/proc/<pid>` for a server on this machine.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Testing → Load test; Resource budget.

use std::collections::HashMap;
use std::time::Instant;

/// One `/metrics` scrape: every sample by its full name (`name{labels}`).
#[derive(Debug, Clone)]
pub struct Scrape {
    pub at: Instant,
    values: HashMap<String, f64>,
}

impl Scrape {
    /// Parses Prometheus text (comments skipped; the last value per line).
    pub fn parse(text: &str, at: Instant) -> Self {
        let mut values = HashMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.rsplit_once(' ') else {
                continue;
            };
            if let Ok(v) = value.parse::<f64>() {
                values.insert(key.to_owned(), v);
            }
        }
        Self { at, values }
    }

    /// A sample by its full name (`wb_rooms`, `wb_room_claims_total{verdict="accepted"}`);
    /// 0 when absent.
    pub fn get(&self, key: &str) -> f64 {
        self.values.get(key).copied().unwrap_or(0.0)
    }

    pub fn has(&self, key: &str) -> bool {
        self.values.contains_key(key)
    }

    /// The sum of every sample of metric `name` (all label sets).
    pub fn sum(&self, name: &str) -> f64 {
        let open = format!("{name}{{");
        self.values
            .iter()
            .filter(|(k, _)| k.as_str() == name || k.starts_with(&open))
            .map(|(_, v)| v)
            .sum()
    }

    /// The samples of metric `name` with a label, as (label value, value), sorted by
    /// label value.
    pub fn labelled(&self, name: &str, label: &str) -> Vec<(String, f64)> {
        let open = format!("{name}{{");
        let key = format!("{label}=\"");
        let mut out: Vec<(String, f64)> = self
            .values
            .iter()
            .filter(|(k, _)| k.starts_with(&open))
            .filter_map(|(k, v)| {
                let rest = &k[k.find(&key)? + key.len()..];
                Some((rest[..rest.find('"')?].to_owned(), *v))
            })
            .collect();
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// Histogram `name`'s cumulative buckets (upper bound, count), `+Inf` last.
    pub fn buckets(&self, name: &str) -> Vec<(f64, f64)> {
        let mut b: Vec<(f64, f64)> = self
            .labelled(&format!("{name}_bucket"), "le")
            .into_iter()
            .map(|(le, n)| {
                let bound = if le == "+Inf" {
                    f64::INFINITY
                } else {
                    le.parse().unwrap_or(f64::INFINITY)
                };
                (bound, n)
            })
            .collect();
        b.sort_by(|x, y| x.0.total_cmp(&y.0));
        b
    }
}

/// `end − start` of a counter.
pub fn delta(start: &Scrape, end: &Scrape, key: &str) -> f64 {
    end.get(key) - start.get(key)
}

/// The bucket bound at or below which `q` (0..1) of histogram `name`'s observations
/// between the two scrapes fell (∞: the overflow bucket; 0 without observations).
pub fn window_quantile(start: &Scrape, end: &Scrape, name: &str, q: f64) -> f64 {
    let (a, b) = (start.buckets(name), end.buckets(name));
    let d: Vec<(f64, f64)> = b
        .iter()
        .map(|&(le, n)| {
            let before = a.iter().find(|x| x.0 == le).map_or(0.0, |x| x.1);
            (le, n - before)
        })
        .collect();
    let total = d.last().map_or(0.0, |x| x.1);
    if total <= 0.0 {
        return 0.0;
    }
    let need = (q * total).ceil();
    d.iter()
        .find(|x| x.1 >= need)
        .map_or(f64::INFINITY, |x| x.0)
}

/// A process's CPU seconds and resident memory, from `/proc/<pid>` (Linux).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ProcSample {
    pub cpu_s: f64,
    pub rss_bytes: u64,
    pub rss_peak_bytes: u64,
}

/// `USER_HZ` (clock ticks per second in `/proc/<pid>/stat`).
const USER_HZ: f64 = 100.0;
const BYTES_PER_KB: u64 = 1_024;

pub fn read_proc(pid: u32) -> Option<ProcSample> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = stat.rsplit_once(')')?.1;
    let f: Vec<&str> = rest.split_whitespace().collect();
    let num = |i: usize| f.get(i).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0);
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    let kb = |key: &str| {
        status
            .lines()
            .find_map(|l| l.strip_prefix(key))
            .and_then(|v| v.split_whitespace().next()?.parse::<u64>().ok())
            .unwrap_or(0)
    };
    Some(ProcSample {
        cpu_s: (num(11) + num(12)) / USER_HZ,
        rss_bytes: kb("VmRSS:") * BYTES_PER_KB,
        rss_peak_bytes: kb("VmHWM:") * BYTES_PER_KB,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "# HELP wb_rooms Live rooms.\n# TYPE wb_rooms gauge\nwb_rooms 20\n\
        wb_room_tick_seconds_bucket{le=\"0.0005\"} 10\nwb_room_tick_seconds_bucket{le=\"0.001\"} 10\n\
        wb_room_tick_seconds_bucket{le=\"+Inf\"} 10\n\
        wb_room_claims_total{verdict=\"accepted\"} 5\n\
        wb_room_claims_total{verdict=\"rejected\",reason=\"timing\"} 1\n\
        process_cpu_seconds_total 1.5\n";
    const B: &str = "wb_rooms 20\n\
        wb_room_tick_seconds_bucket{le=\"0.0005\"} 100\nwb_room_tick_seconds_bucket{le=\"0.001\"} 109\n\
        wb_room_tick_seconds_bucket{le=\"+Inf\"} 110\n\
        wb_room_claims_total{verdict=\"accepted\"} 25\n\
        wb_room_claims_total{verdict=\"rejected\",reason=\"timing\"} 1\n\
        process_cpu_seconds_total 4.0\n";

    #[test]
    fn scrapes_parse_and_window() {
        let now = Instant::now();
        let (a, b) = (Scrape::parse(A, now), Scrape::parse(B, now));
        assert_eq!(a.get("wb_rooms"), 20.0);
        assert_eq!(a.get("nope"), 0.0);
        assert!(!a.has("nope"));
        assert_eq!(delta(&a, &b, "process_cpu_seconds_total"), 2.5);
        assert_eq!(b.sum("wb_room_claims_total"), 26.0);
        assert_eq!(
            b.labelled("wb_room_claims_total", "verdict"),
            vec![("accepted".into(), 25.0), ("rejected".into(), 1.0)]
        );
        // The window: 100 ticks, 90 ≤ 0.5 ms, 9 ≤ 1 ms, 1 above.
        assert_eq!(window_quantile(&a, &b, "wb_room_tick_seconds", 0.5), 0.0005);
        assert_eq!(window_quantile(&a, &b, "wb_room_tick_seconds", 0.99), 0.001);
        assert_eq!(
            window_quantile(&a, &b, "wb_room_tick_seconds", 1.0),
            f64::INFINITY
        );
        assert_eq!(window_quantile(&a, &a, "wb_room_tick_seconds", 0.99), 0.0);
    }

    #[test]
    fn proc_reads_this_process() {
        if cfg!(target_os = "linux") {
            let p = read_proc(std::process::id()).expect("/proc/self");
            assert!(p.rss_bytes > 0 && p.rss_peak_bytes >= p.rss_bytes);
        }
    }
}
