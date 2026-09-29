//! Single-player run submissions (`POST /api/v1/runs`) and the one-time legacy
//! personal-best upload (`POST /api/v1/runs/legacy`). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
//! → "Leaderboards" (single-player runs: summary, plausibility checks, replay upload;
//! migration from Game Center / Play Games), "Data model (SQLite)" (`runs`).
//! Shapes: docs/SERVER.md → "Leaderboards & runs API".
//!
//! **Flow of a submission** (one `BEGIN IMMEDIATE` transaction):
//! 1. A known `idempotency_key` replays the stored answer (`duplicate: true`).
//! 2. The plausibility checks (`plausibility`); a failure stores the run as `rejected`.
//! 3. For each board and period the run feeds: does it improve the player's entry, and at
//!    what rank. A replay is required when it improves an entry and either ranks within
//!    `leaderboards.replay_top_n` or beats a personal best (all-time boards, the day's
//!    Daily). Then the run is `pending` (shown as "verifying" until N8 checks the
//!    replay), otherwise `unverified`.
//! 4. The improving entries are written (upsert only if better); `pending` ones only while
//!    `leaderboards.show_pending`.

pub mod daily_seed;
pub mod plausibility;
pub mod routes;

use serde::{Deserialize, Deserializer, Serialize};

use crate::leaderboards::{self, mode, Board, Placement, RunFacts, Target, Verification};

/// Largest score accepted: 2^53 − 1, so a client that holds JSON numbers as doubles
/// (Godot does) reads it back exactly.
pub const MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;
/// `idempotency_key`: 8–64 characters of `A–Z a–z 0–9 _ -` (a UUID fits).
const IDEMPOTENCY_KEY_LEN: std::ops::RangeInclusive<usize> = 8..=64;
/// `car`: 1–32 characters of `a–z 0–9 _ -`.
const CAR_ID_LEN: std::ops::RangeInclusive<usize> = 1..=32;
/// `runs.map_or_seed` of legacy runs.
const LEGACY_MAP: &str = "legacy";

/// `POST /api/v1/runs`: the `Events.run_over` results (docs/RUN.md; `RunStats.results`)
/// without the personal-best keys, plus the submission fields.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RunSubmission {
    /// Client-generated, unique per run (a UUID): a resubmission with the same key
    /// returns the first answer.
    pub idempotency_key: String,
    /// `journey` or `daily` (`RunContext.MODE_*`).
    pub mode: String,
    /// The run seed: a decimal string (preferred) or a JSON integer, 0..=2^63−1.
    #[serde(deserialize_with = "seed_from_json", serialize_with = "seed_to_json")]
    pub seed: i64,
    /// The UTC date the run was played, `YYYY-MM-DD`; for Daily Drive the seed's date.
    pub date: String,
    /// The car id.
    pub car: String,
    /// The client build number (as in the gateway `Hello`).
    pub client_build: u32,
    /// The banked (final) score.
    pub score: u64,
    pub distance_m: f64,
    pub duration_s: f64,
    pub legs_completed: u32,
    pub coast_reached: bool,
    pub best_chain: u64,
    pub best_multiplier: f64,
    pub passes: u32,
    pub close_passes: u32,
    pub threads: u32,
    pub cuts: u32,
    pub top_speed_kmh: f64,
    pub night_time_s: f64,
    pub hits: u32,
    #[serde(default)]
    pub journey_complete: bool,
    #[serde(default)]
    pub journey_time_s: f64,
    #[serde(default)]
    pub journey_distance_m: f64,
}

fn seed_from_json<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Seed {
        Int(i64),
        Text(String),
    }
    let v = match Seed::deserialize(d)? {
        Seed::Int(v) => v,
        Seed::Text(s)
            if !s.is_empty() && s.len() <= 19 && s.bytes().all(|b| b.is_ascii_digit()) =>
        {
            s.parse().map_err(serde::de::Error::custom)?
        }
        Seed::Text(_) => return Err(serde::de::Error::custom("seed must be a decimal string")),
    };
    if v < 0 {
        return Err(serde::de::Error::custom(
            "seed must be 0..=9223372036854775807",
        ));
    }
    Ok(v)
}

fn seed_to_json<S: serde::Serializer>(v: &i64, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&v.to_string())
}

impl RunSubmission {
    /// Field checks that make a body malformed (400), as opposed to implausible.
    pub fn validate(&self) -> Result<(), String> {
        let key_ok = IDEMPOTENCY_KEY_LEN.contains(&self.idempotency_key.len())
            && self
                .idempotency_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
        if !key_ok {
            return Err("idempotency_key must be 8-64 characters of A-Z a-z 0-9 _ -".into());
        }
        if self.mode != mode::JOURNEY && self.mode != mode::DAILY {
            return Err("mode must be `journey` or `daily`".into());
        }
        if crate::clock::parse_date_days(&self.date).is_none() {
            return Err("date must be a real YYYY-MM-DD date".into());
        }
        let car_ok = CAR_ID_LEN.contains(&self.car.len())
            && self
                .car
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-');
        if !car_ok {
            return Err("car must be 1-32 characters of a-z 0-9 _ -".into());
        }
        if self.score > MAX_SAFE_INTEGER || self.best_chain > MAX_SAFE_INTEGER {
            return Err(format!(
                "score and best_chain must be at most {MAX_SAFE_INTEGER}"
            ));
        }
        for (name, v) in [
            ("distance_m", self.distance_m),
            ("duration_s", self.duration_s),
            ("best_multiplier", self.best_multiplier),
            ("top_speed_kmh", self.top_speed_kmh),
            ("night_time_s", self.night_time_s),
            ("journey_time_s", self.journey_time_s),
            ("journey_distance_m", self.journey_distance_m),
        ] {
            if !(v.is_finite() && v >= 0.0) {
                return Err(format!("{name} must be a number >= 0"));
            }
        }
        Ok(())
    }

    /// The stats stored in `runs.stats` (everything but the identifying fields).
    pub fn stats_json(&self) -> serde_json::Value {
        serde_json::json!({
            "distance_m": self.distance_m,
            "duration_s": self.duration_s,
            "legs_completed": self.legs_completed,
            "coast_reached": self.coast_reached,
            "best_chain": self.best_chain,
            "best_multiplier": self.best_multiplier,
            "passes": self.passes,
            "close_passes": self.close_passes,
            "threads": self.threads,
            "cuts": self.cuts,
            "top_speed_kmh": self.top_speed_kmh,
            "night_time_s": self.night_time_s,
            "hits": self.hits,
            "journey_complete": self.journey_complete,
            "journey_time_s": self.journey_time_s,
            "journey_distance_m": self.journey_distance_m,
        })
    }
}

/// The answer to a submission (stored with the run and replayed for its key).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunReceipt {
    /// Decimal string.
    pub run_id: String,
    /// `pending`, `unverified` or `rejected`.
    pub verification: String,
    /// Show the run as "verifying" (it awaits its replay).
    pub verifying: bool,
    /// Why it was rejected (a `plausibility::Rejection` code), else `null`.
    pub reason: Option<String>,
    /// Upload the replay (N8's endpoint): the run entered a top N or beat a personal best.
    pub replay_required: bool,
    /// This key was already submitted; this is the first answer.
    pub duplicate: bool,
    /// Where the run stands on each board and period it feeds (empty when rejected).
    pub placements: Vec<Placement>,
}

/// Parameters of a submission that the handler resolves from the request and state.
pub struct SubmitContext<'a> {
    pub db: &'a sqlx::SqlitePool,
    pub runs: &'a crate::config::RunsConfig,
    pub boards: &'a leaderboards::Leaderboards,
    pub account_id: i64,
    pub now: i64,
}

/// A stored answer for this account and key, if any.
async fn stored_receipt(
    conn: &mut sqlx::SqliteConnection,
    account_id: i64,
    key: &str,
) -> anyhow::Result<Option<RunReceipt>> {
    let stored = sqlx::query_scalar!(
        "SELECT response FROM runs WHERE account_id = ? AND idempotency_key = ?",
        account_id,
        key
    )
    .fetch_optional(conn)
    .await?
    .flatten();
    Ok(match stored {
        Some(json) => {
            let mut r: RunReceipt = serde_json::from_str(&json)?;
            r.duplicate = true;
            Some(r)
        }
        None => None,
    })
}

/// Records a submission (see the module docs). Returns the receipt and whether it is new.
pub async fn submit(
    ctx: SubmitContext<'_>,
    sub: &RunSubmission,
) -> anyhow::Result<(RunReceipt, bool)> {
    let cfg = ctx.boards.config();
    let mut tx = ctx.db.begin_with("BEGIN IMMEDIATE").await?;
    if let Some(r) = stored_receipt(&mut tx, ctx.account_id, &sub.idempotency_key).await? {
        return Ok((r, false));
    }
    let verdict = plausibility::check(ctx.runs, sub, ctx.now);
    let score = i64::try_from(sub.score)?;
    let facts_template = RunFacts {
        id: 0,
        account_id: ctx.account_id,
        mode: sub.mode.clone(),
        date: sub.date.clone(),
        score,
        distance_m: sub.distance_m,
        room_type: None,
        legacy_board: None,
        verification: String::new(),
        created_at: ctx.now,
    };
    let mut planned = match verdict {
        Ok(()) => {
            let t = leaderboards::targets(&facts_template);
            leaderboards::plan(&mut tx, ctx.account_id, t, score, sub.distance_m, ctx.now).await?
        }
        Err(_) => Vec::new(),
    };
    let replay_top_n = u64::from(cfg.replay_top_n);
    let replay_required = planned.iter().any(|p| {
        p.placement.improved
            && (p.target.is_personal_best() || p.placement.rank.is_some_and(|r| r <= replay_top_n))
    });
    let verification = match verdict {
        Err(_) => Verification::Rejected,
        Ok(()) if replay_required => Verification::Pending,
        Ok(()) => Verification::Unverified,
    };
    let reason = verdict.err().map(|r| r.code());
    let seed = sub.seed.to_string();
    let stats = sub.stats_json().to_string();
    let build = i64::from(sub.client_build);
    let v = verification.as_str();
    let run_id = sqlx::query!(
        "INSERT INTO runs (account_id, mode, map_or_seed, date, score, distance_m, duration_s,
                           stats, car, build, verification, reject_reason, idempotency_key,
                           created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ctx.account_id,
        sub.mode,
        seed,
        sub.date,
        score,
        sub.distance_m,
        sub.duration_s,
        stats,
        sub.car,
        build,
        v,
        reason,
        sub.idempotency_key,
        ctx.now
    )
    .execute(&mut *tx)
    .await?
    .last_insert_rowid();
    let facts = RunFacts {
        id: run_id,
        verification: v.to_string(),
        ..facts_template
    };
    let written = leaderboards::apply(&mut tx, &facts, &mut planned, cfg.show_pending).await?;
    let receipt = RunReceipt {
        run_id: run_id.to_string(),
        verification: v.to_string(),
        verifying: verification == Verification::Pending,
        reason: reason.map(str::to_string),
        replay_required,
        duplicate: false,
        placements: planned.into_iter().map(|p| p.placement).collect(),
    };
    let json = serde_json::to_string(&receipt)?;
    sqlx::query!("UPDATE runs SET response = ? WHERE id = ?", json, run_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    ctx.boards.invalidate_targets(&written);
    match reason {
        Some(r) => tracing::info!(
            account_id = ctx.account_id,
            run_id,
            reason = r,
            "run rejected"
        ),
        None => tracing::debug!(
            account_id = ctx.account_id,
            run_id,
            verification = v,
            "run recorded"
        ),
    }
    Ok((receipt, true))
}

// ---------------------------------------------------------------------------------------------
// Legacy personal bests
// ---------------------------------------------------------------------------------------------

/// `POST /api/v1/runs/legacy`.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LegacyUpload {
    /// One item per board, each board at most once.
    pub entries: Vec<LegacyItem>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LegacyItem {
    /// `journey` (best score) or `distance` (longest run, whole metres).
    pub board: String,
    /// The personal best: points on `journey`, metres on `distance`. At least 1.
    pub score: u64,
}

/// Boards a legacy personal best may go on (their all-time period). Daily Drive bests
/// have no date and Loop is multiplayer-only.
pub const LEGACY_BOARDS: [Board; 2] = [Board::Journey, Board::Distance];

/// The answer for one legacy item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LegacyResult {
    pub board: String,
    /// `accepted`, `already_uploaded` (once per account per board) or `over_cap`.
    pub status: String,
    /// Decimal string of the stored legacy run (`accepted`).
    pub run_id: Option<String>,
    /// Where the account stands on the board's all-time period after the upload.
    pub placement: Option<Placement>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LegacyReceipt {
    pub results: Vec<LegacyResult>,
}

impl LegacyUpload {
    pub fn validate(&self) -> Result<Vec<Board>, String> {
        if self.entries.is_empty() || self.entries.len() > LEGACY_BOARDS.len() {
            return Err(format!(
                "entries must hold 1-{} items, one per board",
                LEGACY_BOARDS.len()
            ));
        }
        let mut boards = Vec::with_capacity(self.entries.len());
        for item in &self.entries {
            let b = Board::parse(&item.board)
                .filter(|b| LEGACY_BOARDS.contains(b))
                .ok_or_else(|| "legacy boards: journey, distance".to_string())?;
            if boards.contains(&b) {
                return Err(format!("board `{}` given twice", item.board));
            }
            if item.score == 0 || item.score > MAX_SAFE_INTEGER {
                return Err(format!(
                    "score must be 1..={MAX_SAFE_INTEGER} (leave out boards without a best)"
                ));
            }
            boards.push(b);
        }
        Ok(boards)
    }
}

/// Stores each legacy best once per account and board as a `legacy` run and writes its
/// all-time entry if better. Over-cap items are refused (`over_cap`), never stored.
pub async fn upload_legacy(
    ctx: SubmitContext<'_>,
    up: &LegacyUpload,
) -> anyhow::Result<LegacyReceipt> {
    let boards = up.validate().map_err(anyhow::Error::msg)?;
    let cfg = ctx.boards.config();
    let date = leaderboards::period::date_key(ctx.now.div_euclid(crate::clock::SECS_PER_DAY));
    let mut tx = ctx.db.begin_with("BEGIN IMMEDIATE").await?;
    let mut results = Vec::with_capacity(boards.len());
    let mut written: Vec<Target> = Vec::new();
    for (item, board) in up.entries.iter().zip(boards) {
        let over_cap = match board {
            Board::Distance => item.score as f64 > cfg.legacy_max_distance_m,
            _ => item.score > cfg.legacy_max_journey_score,
        };
        let mut result = LegacyResult {
            board: board.id().to_string(),
            status: "accepted".into(),
            run_id: None,
            placement: None,
        };
        if over_cap {
            result.status = "over_cap".into();
            results.push(result);
            continue;
        }
        let exists = sqlx::query_scalar!(
            r#"SELECT id AS "id!" FROM runs WHERE account_id = ? AND legacy_board = ?"#,
            ctx.account_id,
            board.id()
        )
        .fetch_optional(&mut *tx)
        .await?;
        if exists.is_some() {
            result.status = "already_uploaded".into();
            results.push(result);
            continue;
        }
        let score = i64::try_from(item.score)?;
        let (run_score, distance) = match board {
            Board::Distance => (0, score as f64),
            _ => (score, 0.0),
        };
        let v = Verification::Legacy.as_str();
        let b = board.id();
        let run_id = sqlx::query!(
            "INSERT INTO runs (account_id, mode, map_or_seed, date, score, distance_m, duration_s,
                               verification, legacy_board, created_at)
             VALUES (?, 'legacy', ?, ?, ?, ?, 0, ?, ?, ?)",
            ctx.account_id,
            LEGACY_MAP,
            date,
            run_score,
            distance,
            v,
            b,
            ctx.now
        )
        .execute(&mut *tx)
        .await?
        .last_insert_rowid();
        let facts = RunFacts {
            id: run_id,
            account_id: ctx.account_id,
            mode: mode::LEGACY.to_string(),
            date: date.clone(),
            score: run_score,
            distance_m: distance,
            room_type: None,
            legacy_board: Some(b.to_string()),
            verification: v.to_string(),
            created_at: ctx.now,
        };
        let targets = leaderboards::targets(&facts);
        let mut planned = leaderboards::plan(
            &mut tx,
            ctx.account_id,
            targets,
            run_score,
            distance,
            ctx.now,
        )
        .await?;
        written.extend(leaderboards::apply(&mut tx, &facts, &mut planned, cfg.show_pending).await?);
        result.run_id = Some(run_id.to_string());
        result.placement = planned.into_iter().next().map(|p| p.placement);
        results.push(result);
    }
    tx.commit().await?;
    ctx.boards.invalidate_targets(&written);
    Ok(LegacyReceipt { results })
}
