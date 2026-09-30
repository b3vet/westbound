//! A minimal in-process link simulation for bots (N6.1's claim-acceptance test; the full
//! delay / jitter / loss layer with its metrics is N4.4's). Spec: WESTBOUND_MULTIPLAYER_
//! HANDOFF.md → Testing → Netcode harness ("connect through an in-process delay layer
//! with configurable latency, jitter and loss"; acceptance at 150 ms RTT, ±30 ms jitter,
//! 2 % loss).
//!
//! Each direction delays every frame by half the RTT ± half the jitter (uniform). The
//! transport is a WebSocket over TCP, so a lost packet is not a lost frame: it is
//! retransmitted about one RTT later and holds up the frames behind it (frames keep
//! their order). `loss_pct` is that share of frames.

use std::collections::VecDeque;

use crate::driver::BotRng;

/// Link conditions.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LinkSim {
    pub rtt_ms: f64,
    /// Peak-to-peak RTT jitter (±half on each direction's half).
    pub jitter_ms: f64,
    pub loss_pct: f64,
}

impl LinkSim {
    /// The spec's acceptance conditions: 150 ms RTT, ±30 ms jitter, 2 % loss.
    pub const MOBILE: LinkSim = LinkSim {
        rtt_ms: 150.0,
        jitter_ms: 30.0,
        loss_pct: 2.0,
    };
}

/// One direction: items come out in order, each no earlier than its delay.
#[derive(Debug)]
pub struct DelayLine<T> {
    link: LinkSim,
    rng: BotRng,
    q: VecDeque<(u64, T)>,
    last_due: u64,
    /// Frames that were "lost" and retransmitted.
    pub retransmits: u64,
}

impl<T> DelayLine<T> {
    pub fn new(link: LinkSim, seed: u64) -> Self {
        Self {
            link,
            rng: BotRng::new(seed),
            q: VecDeque::new(),
            last_due: 0,
            retransmits: 0,
        }
    }

    pub fn push(&mut self, now_ms: u64, item: T) {
        let half = self.link.rtt_ms * 0.5;
        let jitter = self.link.jitter_ms * 0.5;
        let mut delay = half + self.rng.range(-jitter, jitter);
        if self.rng.unit() * 100.0 < self.link.loss_pct {
            self.retransmits += 1;
            delay += self.link.rtt_ms;
        }
        let due = (now_ms + delay.max(0.0).round() as u64).max(self.last_due);
        self.last_due = due;
        self.q.push_back((due, item));
    }

    /// The next item due by `now_ms`.
    pub fn pop_due(&mut self, now_ms: u64) -> Option<T> {
        if self.q.front().is_some_and(|(due, _)| *due <= now_ms) {
            self.q.pop_front().map(|(_, x)| x)
        } else {
            None
        }
    }

    pub fn is_empty(&self) -> bool {
        self.q.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delays_keep_order_and_the_mean() {
        let mut l = DelayLine::new(LinkSim::MOBILE, 3);
        let mut out = Vec::new();
        for k in 0..2_000u64 {
            l.push(k * 10, k);
        }
        let mut last = 0;
        let mut delays = Vec::new();
        for now in 0..30_000u64 {
            while let Some(k) = l.pop_due(now) {
                assert!(k >= last);
                last = k;
                delays.push(now - k * 10);
                out.push(k);
            }
        }
        assert_eq!(out.len(), 2_000);
        let mean = delays.iter().sum::<u64>() as f64 / delays.len() as f64;
        assert!((70.0..110.0).contains(&mean), "{mean}");
        assert!(
            l.retransmits > 10 && l.retransmits < 100,
            "{}",
            l.retransmits
        );
    }
}
