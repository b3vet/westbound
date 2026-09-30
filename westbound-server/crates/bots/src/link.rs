//! The in-process delay layer for bots (N4.4): each direction of a bot's connection is a
//! [`DelayLine`] with its own one-way delay, jitter and loss, and its statistics. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → Testing → Netcode harness ("connect through an
//! in-process delay layer with configurable latency, jitter and loss"; acceptance at
//! 150 ms RTT, ±30 ms jitter, 2 % loss). The Godot side's twin is
//! `src/net/traffic/dev/net_delay_link.gd` (docs/NET_TRAFFIC.md → The fake authority).
//!
//! - **Delay:** each frame waits the direction's one-way delay ± half its jitter (uniform).
//!   [`LinkSim::symmetric`] splits an RTT evenly: `rtt/2 ± jitter/2` each way, so the round
//!   trip spans `rtt ± jitter`.
//! - **Stream** ([`LinkMode::Stream`], the default: the WebSocket over TCP): a lost packet
//!   is not a lost frame. It is retransmitted after `rto_ms` (lost again: after twice that,
//!   and so on) and holds up every frame behind it: frames always come out in order, a
//!   frame is never earlier than the one before it (head-of-line blocking).
//! - **Datagram** ([`LinkMode::Datagram`], for experiments with a later UDP transport): a
//!   lost frame is gone, and jitter reorders frames.
//!
//! Everything is seeded ([`BotRng`]): the same seed and the same pushes give the same
//! schedule. Times are the caller's milliseconds.

use std::collections::VecDeque;

use crate::driver::BotRng;

const PCT: f64 = 100.0;
/// Delay histogram: 1 ms bins up to this; longer delays count in the last bin.
const HIST_MS: usize = 2_000;
/// Linux's minimum TCP retransmission timeout (ms), and the Godot harness's
/// `test_link_rto_ms`.
pub const TCP_MIN_RTO_MS: f64 = 200.0;
/// A retransmission lost again doubles the wait (TCP's back-off), at most this often.
const MAX_BACKOFFS: u32 = 6;

/// How lost frames behave.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LinkMode {
    /// TCP: late (retransmitted), in order.
    #[default]
    Stream,
    /// UDP: gone; jitter reorders.
    Datagram,
}

/// One direction's conditions.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DirSim {
    /// Mean one-way delay (ms).
    pub delay_ms: f64,
    /// Peak-to-peak jitter (ms): each frame's delay is `delay_ms ± jitter_ms / 2`.
    pub jitter_ms: f64,
    /// Share of frames lost (%).
    pub loss_pct: f64,
}

/// Link conditions, per direction.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LinkSim {
    /// Client → server.
    pub up: DirSim,
    /// Server → client.
    pub down: DirSim,
    pub mode: LinkMode,
    /// Stream mode: how long a lost frame takes to be retransmitted (ms).
    pub rto_ms: f64,
}

impl LinkSim {
    /// The spec's acceptance conditions: 150 ms RTT, ±30 ms jitter, 2 % loss, over TCP.
    pub const MOBILE: LinkSim = LinkSim::symmetric(150.0, 30.0, 2.0);

    /// An RTT split evenly between the directions, the jitter and loss on both, TCP.
    pub const fn symmetric(rtt_ms: f64, jitter_ms: f64, loss_pct: f64) -> Self {
        let dir = DirSim {
            delay_ms: rtt_ms * 0.5,
            jitter_ms: jitter_ms * 0.5,
            loss_pct,
        };
        LinkSim {
            up: dir,
            down: dir,
            mode: LinkMode::Stream,
            rto_ms: TCP_MIN_RTO_MS,
        }
    }

    pub const fn with_mode(mut self, mode: LinkMode) -> Self {
        self.mode = mode;
        self
    }

    /// The mean round trip (ms).
    pub fn rtt_ms(&self) -> f64 {
        self.up.delay_ms + self.down.delay_ms
    }
}

/// What a [`DelayLine`] did.
#[derive(Debug, Clone)]
pub struct LinkStats {
    /// Frames and bytes pushed (`push_sized` counts bytes).
    pub frames: u64,
    pub bytes: u64,
    /// Frames that were lost at least once: retransmitted (stream) or dropped (datagram).
    pub lost: u64,
    /// Stream: retransmissions (a frame lost twice counts twice).
    pub retransmits: u64,
    /// Datagram: frames never delivered.
    pub dropped: u64,
    /// Stream: frames held back behind a late one (head-of-line blocking).
    pub held: u64,
    /// Datagram: frames that overtook an earlier one.
    pub reordered: u64,
    /// Scheduled delay of every delivered frame (ms): 1 ms bins.
    hist: Vec<u32>,
    sum_ms: f64,
    max_ms: u64,
    min_ms: u64,
}

impl Default for LinkStats {
    fn default() -> Self {
        Self {
            frames: 0,
            bytes: 0,
            lost: 0,
            retransmits: 0,
            dropped: 0,
            held: 0,
            reordered: 0,
            hist: vec![0; HIST_MS + 1],
            sum_ms: 0.0,
            max_ms: 0,
            min_ms: u64::MAX,
        }
    }
}

impl LinkStats {
    fn observe(&mut self, delay_ms: u64) {
        let bin = usize::try_from(delay_ms).unwrap_or(HIST_MS).min(HIST_MS);
        self.hist[bin] += 1;
        self.sum_ms += delay_ms as f64;
        self.max_ms = self.max_ms.max(delay_ms);
        self.min_ms = self.min_ms.min(delay_ms);
    }

    /// Delivered (scheduled) frames.
    pub fn delivered(&self) -> u64 {
        self.hist.iter().map(|&n| u64::from(n)).sum()
    }

    pub fn mean_ms(&self) -> f64 {
        self.sum_ms / self.delivered().max(1) as f64
    }

    pub fn max_ms(&self) -> u64 {
        self.max_ms
    }

    pub fn min_ms(&self) -> u64 {
        if self.min_ms == u64::MAX {
            0
        } else {
            self.min_ms
        }
    }

    /// The delay (ms) at or below which `q` (0..1) of the delivered frames were.
    pub fn quantile_ms(&self, q: f64) -> u64 {
        let total = self.delivered();
        if total == 0 {
            return 0;
        }
        let need = ((q * total as f64).ceil() as u64).max(1);
        let mut seen = 0;
        for (ms, &n) in self.hist.iter().enumerate() {
            seen += u64::from(n);
            if seen >= need {
                return ms as u64;
            }
        }
        HIST_MS as u64
    }

    /// Adds another line's counts (a report over many bots).
    pub fn merge(&mut self, o: &LinkStats) {
        self.frames += o.frames;
        self.bytes += o.bytes;
        self.lost += o.lost;
        self.retransmits += o.retransmits;
        self.dropped += o.dropped;
        self.held += o.held;
        self.reordered += o.reordered;
        for (a, b) in self.hist.iter_mut().zip(&o.hist) {
            *a += b;
        }
        self.sum_ms += o.sum_ms;
        self.max_ms = self.max_ms.max(o.max_ms);
        self.min_ms = self.min_ms.min(o.min_ms);
    }

    /// Share of pushed frames lost at least once (%).
    pub fn loss_pct(&self) -> f64 {
        PCT * self.lost as f64 / self.frames.max(1) as f64
    }
}

/// One direction: frames come out no earlier than their delay (see the module docs).
#[derive(Debug)]
pub struct DelayLine<T> {
    dir: DirSim,
    mode: LinkMode,
    rto_ms: f64,
    rng: BotRng,
    /// (due, sequence, item), in due order (stream: also push order).
    q: VecDeque<(u64, u64, T)>,
    last_due: u64,
    seq: u64,
    /// Datagram: the highest sequence delivered so far (reordering).
    last_out: Option<u64>,
    pub stats: LinkStats,
}

impl<T> DelayLine<T> {
    /// A line for one direction of `link`.
    pub fn new(link: LinkSim, up: bool, seed: u64) -> Self {
        Self::with_dir(
            if up { link.up } else { link.down },
            link.mode,
            link.rto_ms,
            seed,
        )
    }

    pub fn with_dir(dir: DirSim, mode: LinkMode, rto_ms: f64, seed: u64) -> Self {
        Self {
            dir,
            mode,
            rto_ms,
            rng: BotRng::new(seed),
            q: VecDeque::new(),
            last_due: 0,
            seq: 0,
            last_out: None,
            stats: LinkStats::default(),
        }
    }

    /// Queues a frame sent at `now_ms`.
    pub fn push(&mut self, now_ms: u64, item: T) {
        self.push_sized(now_ms, item, 0);
    }

    /// Queues a frame of `bytes` sent at `now_ms`.
    pub fn push_sized(&mut self, now_ms: u64, item: T, bytes: usize) {
        self.stats.frames += 1;
        self.stats.bytes += bytes as u64;
        let jitter = self.dir.jitter_ms * 0.5;
        let mut delay = self.dir.delay_ms + self.rng.range(-jitter, jitter);
        let mut lost = false;
        match self.mode {
            LinkMode::Stream => {
                let mut rto = self.rto_ms;
                let mut k = 0;
                while k < MAX_BACKOFFS && self.rng.unit() * PCT < self.dir.loss_pct {
                    lost = true;
                    self.stats.retransmits += 1;
                    delay += rto;
                    rto *= 2.0;
                    k += 1;
                }
            }
            LinkMode::Datagram => {
                if self.rng.unit() * PCT < self.dir.loss_pct {
                    self.stats.lost += 1;
                    self.stats.dropped += 1;
                    return;
                }
            }
        }
        if lost {
            self.stats.lost += 1;
        }
        let own = now_ms + delay.max(0.0).round() as u64;
        let seq = self.seq;
        self.seq += 1;
        match self.mode {
            LinkMode::Stream => {
                let due = own.max(self.last_due);
                if due > own {
                    self.stats.held += 1;
                }
                self.last_due = due;
                self.stats.observe(due - now_ms);
                self.q.push_back((due, seq, item));
            }
            LinkMode::Datagram => {
                self.stats.observe(own - now_ms);
                // Keep the queue in due order (ties: push order).
                let at = self.q.partition_point(|(d, s, _)| (*d, *s) <= (own, seq));
                self.q.insert(at, (own, seq, item));
            }
        }
    }

    /// The next frame due by `now_ms`.
    pub fn pop_due(&mut self, now_ms: u64) -> Option<T> {
        if self.q.front().is_some_and(|(due, ..)| *due <= now_ms) {
            let (_, seq, item) = self.q.pop_front()?;
            if self.last_out.is_some_and(|l| seq < l) {
                self.stats.reordered += 1;
            }
            self.last_out = Some(self.last_out.map_or(seq, |l| l.max(seq)));
            Some(item)
        } else {
            None
        }
    }

    /// When the next frame is due (ms), if any.
    pub fn next_due(&self) -> Option<u64> {
        self.q.front().map(|(d, ..)| *d)
    }

    pub fn is_empty(&self) -> bool {
        self.q.is_empty()
    }

    pub fn len(&self) -> usize {
        self.q.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pushes one frame every `every` ms for `n` frames and drains the line every ms:
    /// (the items in delivery order, each one's delay in ms).
    fn run_every(line: &mut DelayLine<u64>, n: u64, every: u64) -> (Vec<u64>, Vec<u64>) {
        let (mut out, mut delays) = (Vec::new(), Vec::new());
        let end = n * every + 20_000;
        for now in 0..end {
            if now % every == 0 && now / every < n {
                line.push_sized(now, now / every, 100);
            }
            while let Some(k) = line.pop_due(now) {
                delays.push(now - k * every);
                out.push(k);
            }
        }
        (out, delays)
    }

    /// A frame every 10 ms.
    fn run(line: &mut DelayLine<u64>, n: u64) -> (Vec<u64>, Vec<u64>) {
        run_every(line, n, 10)
    }

    fn hash(v: &[u64]) -> u64 {
        v.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, &x| {
            (h ^ x).wrapping_mul(0x0100_0000_01b3)
        })
    }

    #[test]
    fn stream_keeps_order_the_mean_and_the_loss() {
        // A frame every room tick (50 ms), as the server sends them.
        let mut l = DelayLine::new(LinkSim::MOBILE, false, 3);
        let (out, delays) = run_every(&mut l, 20_000, 50);
        assert_eq!(out.len(), 20_000, "nothing is lost on a stream");
        assert!(out.windows(2).all(|w| w[0] < w[1]), "in order");
        let s = &l.stats;
        assert_eq!(s.frames, 20_000);
        assert_eq!(s.bytes, 2_000_000);
        assert_eq!(s.delivered(), 20_000);
        // 2 % retransmitted (a few twice); each holds up the frames behind it.
        assert!((1.6..2.4).contains(&s.loss_pct()), "{}", s.loss_pct());
        assert!(s.retransmits >= s.lost);
        assert!(s.held > s.lost, "head-of-line blocking");
        assert_eq!(s.dropped, 0);
        // 75 ± 15 ms, plus the retransmissions' 200 ms on 2 % and the frames they hold
        // up (~3 more each).
        assert!(s.min_ms() >= 60 && s.quantile_ms(0.5) <= 80, "{s:?}");
        assert!((80.0..92.0).contains(&s.mean_ms()), "{}", s.mean_ms());
        assert!(s.quantile_ms(0.99) >= 200, "{}", s.quantile_ms(0.99));
        assert!(s.max_ms() >= 275 && s.max_ms() < 1_000, "{}", s.max_ms());
        // The scheduled delays are what the frames saw.
        let mean = delays.iter().sum::<u64>() as f64 / delays.len() as f64;
        assert!((mean - s.mean_ms()).abs() < 1.0);
    }

    #[test]
    fn datagrams_drop_and_reorder() {
        let link = LinkSim::symmetric(150.0, 60.0, 5.0).with_mode(LinkMode::Datagram);
        let mut l = DelayLine::new(link, true, 9);
        let (out, delays) = run(&mut l, 20_000);
        let s = &l.stats;
        assert_eq!(s.dropped, s.lost);
        assert_eq!(out.len() as u64, 20_000 - s.dropped);
        assert!((4.4..5.6).contains(&s.loss_pct()), "{}", s.loss_pct());
        assert!(
            s.reordered > 100,
            "jitter of 30 ms > the 10 ms spacing reorders"
        );
        assert_eq!(s.retransmits + s.held, 0);
        assert!(delays.iter().all(|&d| (60..=90).contains(&d)), "no waits");
    }

    #[test]
    fn directions_are_their_own() {
        let link = LinkSim {
            up: DirSim {
                delay_ms: 20.0,
                jitter_ms: 0.0,
                loss_pct: 0.0,
            },
            down: DirSim {
                delay_ms: 130.0,
                jitter_ms: 10.0,
                loss_pct: 0.0,
            },
            ..LinkSim::MOBILE
        };
        assert_eq!(link.rtt_ms(), 150.0);
        let mut up = DelayLine::new(link, true, 1);
        let mut down = DelayLine::new(link, false, 1);
        let (_, du) = run(&mut up, 1_000);
        let (_, dd) = run(&mut down, 1_000);
        assert!(du.iter().all(|&d| d == 20));
        assert!(dd.iter().all(|&d| (125..=135).contains(&d)));
    }

    #[test]
    fn the_schedule_is_deterministic_by_seed() {
        let go = |seed: u64| {
            let mut l = DelayLine::new(LinkSim::MOBILE, false, seed);
            let (out, delays) = run(&mut l, 5_000);
            (hash(&out), hash(&delays), l.stats.retransmits)
        };
        assert_eq!(go(42), go(42));
        assert_ne!(go(42).1, go(43).1);
        let dg = |seed: u64| {
            let link = LinkSim::MOBILE.with_mode(LinkMode::Datagram);
            let mut l = DelayLine::new(link, true, seed);
            let (out, delays) = run(&mut l, 5_000);
            (hash(&out), hash(&delays))
        };
        assert_eq!(dg(7), dg(7));
        assert_ne!(dg(7), dg(8));
    }

    #[test]
    fn stats_merge_and_quantiles() {
        let mut a = DelayLine::new(LinkSim::symmetric(100.0, 0.0, 0.0), true, 1);
        let mut b = DelayLine::new(LinkSim::symmetric(300.0, 0.0, 0.0), true, 1);
        run(&mut a, 100);
        run(&mut b, 100);
        let mut m = LinkStats::default();
        m.merge(&a.stats);
        m.merge(&b.stats);
        assert_eq!(m.delivered(), 200);
        assert_eq!(m.quantile_ms(0.5), 50);
        assert_eq!(m.quantile_ms(0.99), 150);
        assert_eq!((m.min_ms(), m.max_ms()), (50, 150));
        assert!((m.mean_ms() - 100.0).abs() < 1e-9);
    }
}
