//! Port of `src/scoring/score_event_buffer.gd` (`ScoreEventBuffer`) and the kinds and tags
//! of `score_events.gd` / `scoring_rule_set.gd` / `scoring.gd`: a preallocated event
//! buffer the rules write into (allocation-free; a full buffer drops the new event and
//! counts it). Kinds and tags are enums here; [`Kind::name`] and [`Tag::name`] are the
//! GDScript StringNames (the parity traces compare them).

/// Event kinds (CONTRACTS §7 and the rule set's own).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Pass,
    ClosePass,
    Cut,
    Thread,
    Banked,
    ChainLost,
    Hesitated,
    TooSlow,
    ShoulderPenalty,
    Slipstream,
    Bonus,
    SunNudge,
    NearMiss,
    /// Multiplayer (N6): a crew train link, paid by the server.
    Train,
}

impl Kind {
    pub const ALL: [Kind; 14] = [
        Kind::Pass,
        Kind::ClosePass,
        Kind::Cut,
        Kind::Thread,
        Kind::Banked,
        Kind::ChainLost,
        Kind::Hesitated,
        Kind::TooSlow,
        Kind::ShoulderPenalty,
        Kind::Slipstream,
        Kind::Bonus,
        Kind::SunNudge,
        Kind::NearMiss,
        Kind::Train,
    ];

    /// The GDScript StringName.
    pub fn name(self) -> &'static str {
        match self {
            Kind::Pass => "pass",
            Kind::ClosePass => "close_pass",
            Kind::Cut => "cut",
            Kind::Thread => "thread",
            Kind::Banked => "banked",
            Kind::ChainLost => "chain_lost",
            Kind::Hesitated => "hesitated",
            Kind::TooSlow => "too_slow",
            Kind::ShoulderPenalty => "shoulder_penalty",
            Kind::Slipstream => "slipstream",
            Kind::Bonus => "bonus",
            Kind::SunNudge => "sun_nudge",
            Kind::NearMiss => "near_miss",
            Kind::Train => "train",
        }
    }

    pub fn from_name(n: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|k| k.name() == n)
    }
}

/// Event tags: bank / loss reasons (`ScoreEvents.REASON_*`) and bonus kinds
/// (`LegTracker.BONUS_*`, the run's journey bonus).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Tag {
    #[default]
    None,
    Checkpoint,
    CashOut,
    Hit,
    Hesitated,
    RunEnd,
    /// Multiplayer: "Rejoin crew" forfeits the unbanked chain.
    Rejoin,
    Clean,
    Pace,
    Threads,
    Heat,
    Objective,
    Journey,
}

impl Tag {
    pub const ALL: [Tag; 13] = [
        Tag::None,
        Tag::Checkpoint,
        Tag::CashOut,
        Tag::Hit,
        Tag::Hesitated,
        Tag::RunEnd,
        Tag::Rejoin,
        Tag::Clean,
        Tag::Pace,
        Tag::Threads,
        Tag::Heat,
        Tag::Objective,
        Tag::Journey,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Tag::None => "",
            Tag::Checkpoint => "checkpoint",
            Tag::CashOut => "cash_out",
            Tag::Hit => "hit",
            Tag::Hesitated => "hesitated",
            Tag::RunEnd => "run_end",
            Tag::Rejoin => "rejoin",
            Tag::Clean => "clean",
            Tag::Pace => "pace",
            Tag::Threads => "threads",
            Tag::Heat => "heat",
            Tag::Objective => "objective",
            Tag::Journey => "journey",
        }
    }

    pub fn from_name(n: &str) -> Option<Tag> {
        Tag::ALL.into_iter().find(|t| t.name() == n)
    }
}

/// One event record (the buffer's columns).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScoreRecord {
    pub kind: Kind,
    pub tag: Tag,
    pub points: i64,
    pub multiplier: f64,
    /// -1 when not applicable.
    pub clearance_m: f64,
    /// Traffic slot, or -1.
    pub slot: i32,
    pub value: f64,
}

/// Fixed-capacity event buffer: `push` never allocates.
#[derive(Debug, Clone)]
pub struct ScoreEventBuffer {
    records: Vec<ScoreRecord>,
    capacity: usize,
    pub dropped: u64,
}

impl ScoreEventBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            records: Vec::with_capacity(capacity),
            capacity,
            dropped: 0,
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    pub fn as_slice(&self) -> &[ScoreRecord] {
        &self.records
    }

    /// `push(kind, points, multiplier, clearance_m, slot, value, tag)`; false (and a drop
    /// counted) when full.
    #[allow(clippy::too_many_arguments)]
    pub fn push(
        &mut self,
        kind: Kind,
        points: i64,
        multiplier: f64,
        clearance_m: f64,
        slot: i32,
        value: f64,
        tag: Tag,
    ) -> bool {
        if self.records.len() >= self.capacity {
            self.dropped += 1;
            return false;
        }
        self.records.push(ScoreRecord {
            kind,
            tag,
            points,
            multiplier,
            clearance_m,
            slot,
            value,
        });
        true
    }

    /// A state-change event (`kind`, value 1 on / 0 off).
    pub fn push_flag(&mut self, kind: Kind, on: bool) -> bool {
        self.push(
            kind,
            0,
            0.0,
            -1.0,
            -1,
            if on { 1.0 } else { 0.0 },
            Tag::None,
        )
    }

    /// Forgets the events (keeps `dropped`).
    pub fn clear(&mut self) {
        self.records.clear();
    }

    /// Clears events and the drop counter.
    pub fn reset(&mut self) {
        self.records.clear();
        self.dropped = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_buffer_drops_the_new_event() {
        let mut b = ScoreEventBuffer::new(2);
        assert!(b.push_flag(Kind::TooSlow, true));
        assert!(b.push(Kind::Pass, 10, 1.0, 2.0, 3, 0.0, Tag::None));
        assert!(!b.push_flag(Kind::TooSlow, false));
        assert_eq!(b.len(), 2);
        assert_eq!(b.dropped, 1);
        b.clear();
        assert!(b.is_empty());
        assert_eq!(b.dropped, 1);
        b.reset();
        assert_eq!(b.dropped, 0);
    }

    #[test]
    fn names_round_trip() {
        for k in Kind::ALL {
            assert_eq!(Kind::from_name(k.name()), Some(k));
        }
        for t in Tag::ALL {
            assert_eq!(Tag::from_name(t.name()), Some(t));
        }
    }
}
