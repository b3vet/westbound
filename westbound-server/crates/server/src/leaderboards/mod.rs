//! Leaderboards: boards, periods, ranking, the top-N cache, and every write to
//! `leaderboard_entries` (single-player submissions via `runs`, multiplayer runs via
//! [`Leaderboards::record_multiplayer_run`], replay outcomes via
//! [`Leaderboards::set_run_verification`], admin removals).
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards", "Rooms → Leaderboard
//! eligibility", "Data model (SQLite)"; docs/SERVER.md → "Leaderboards & runs API".
//!
//! **Entries.** One per subject (an account; a crew on `loop_crew`) per board and period,
//! holding its best run: a write replaces it only with a strictly better score, so a tie
//! keeps the earlier run. Ranking: score descending, then the earlier `achieved_at`, then
//! the lower id (see `store`).
//!
//! **Which boards a run feeds** ([`targets`]): Journey → Journey (its ISO week and
//! all-time) and Distance; Daily Drive → Daily (its date) and Distance; a ranked Loop run
//! → Loop (its season and all-time) and, with a crew, Loop crew; a legacy upload → the
//! all-time period of its board. Periods come from the run's UTC date.

pub mod period;
pub mod routes;
pub mod store;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use sqlx::{SqliteConnection, SqlitePool};

use crate::clock::{parse_date_days, Clock};
use crate::config::LeaderboardsConfig;
use crate::names;
pub use period::{Period, PeriodKind};
use store::{EntryRow, NewEntry};

/// A leaderboard.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Board {
    /// Best single run in a public room (multiplayer; written by the server).
    Loop,
    /// Sum of a crew's top members' season-best Loop runs.
    LoopCrew,
    /// Best single-player Journey run.
    Journey,
    /// Best run on the day's seed.
    Daily,
    /// Longest single-player run (whole metres).
    Distance,
}

impl Board {
    pub const EVERY: [Board; 5] = [
        Board::Loop,
        Board::LoopCrew,
        Board::Journey,
        Board::Daily,
        Board::Distance,
    ];

    /// The id in URLs, JSON and the `board` column.
    pub fn id(self) -> &'static str {
        match self {
            Board::Loop => "loop",
            Board::LoopCrew => "loop_crew",
            Board::Journey => "journey",
            Board::Daily => "daily",
            Board::Distance => "distance",
        }
    }

    pub fn parse(s: &str) -> Option<Board> {
        Board::EVERY.into_iter().find(|b| b.id() == s)
    }

    /// The periods this board keeps; the first is the default.
    pub fn periods(self) -> &'static [PeriodKind] {
        match self {
            Board::Loop => &[PeriodKind::Season, PeriodKind::All],
            Board::LoopCrew => &[PeriodKind::Season],
            Board::Journey => &[PeriodKind::Week, PeriodKind::All],
            Board::Daily => &[PeriodKind::Day],
            Board::Distance => &[PeriodKind::All],
        }
    }

    /// Crews, not accounts, are ranked.
    pub fn is_crew(self) -> bool {
        self == Board::LoopCrew
    }

    /// The default (current) period at unix time `now`.
    pub fn current_period(self, now: i64) -> Period {
        Period::at(self.periods()[0], now)
    }

    /// Parses a period key this board keeps.
    pub fn parse_period(self, key: &str) -> Option<Period> {
        self.periods()
            .iter()
            .find_map(|&kind| Period::parse(kind, key))
    }
}

/// `runs.verification` (and the copy on each entry).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verification {
    /// Awaits its replay (N8); shown as "verifying" while `show_pending`.
    Pending,
    /// Server-authoritative (multiplayer), or its replay was accepted.
    Verified,
    /// Failed a plausibility check or its replay; never on a board.
    Rejected,
    /// Passed the plausibility checks and needed no replay.
    Unverified,
    /// An uploaded local personal best: marked, never used for rewards.
    Legacy,
}

impl Verification {
    pub fn as_str(self) -> &'static str {
        match self {
            Verification::Pending => "pending",
            Verification::Verified => "verified",
            Verification::Rejected => "rejected",
            Verification::Unverified => "unverified",
            Verification::Legacy => "legacy",
        }
    }

    pub fn parse(s: &str) -> Option<Verification> {
        [
            Verification::Pending,
            Verification::Verified,
            Verification::Rejected,
            Verification::Unverified,
            Verification::Legacy,
        ]
        .into_iter()
        .find(|v| v.as_str() == s)
    }

    /// Whether a run in this state may hold a board entry.
    pub fn may_rank(self, show_pending: bool) -> bool {
        match self {
            Verification::Verified | Verification::Unverified | Verification::Legacy => true,
            Verification::Pending => show_pending,
            Verification::Rejected => false,
        }
    }
}

/// `runs.mode`.
pub mod mode {
    pub const JOURNEY: &str = "journey";
    pub const DAILY: &str = "daily";
    pub const LOOP: &str = "loop";
    pub const LEGACY: &str = "legacy";
}

/// `runs.room_type` of multiplayer runs.
pub mod room_type {
    /// A public room (normal density, UTC clock): ranked.
    pub const PUBLIC: &str = "public";
    /// A private room left on the default density and clock: ranked.
    pub const PRIVATE: &str = "private";
    /// A private room with a custom density or clock: personal stats only.
    pub const PRIVATE_CUSTOM: &str = "private_custom";
    /// Room types whose runs go on the Loop boards.
    pub const RANKED: [&str; 2] = [PUBLIC, PRIVATE];
}

/// What the leaderboard logic needs of a `runs` row.
#[derive(Debug, Clone, PartialEq)]
pub struct RunFacts {
    pub id: i64,
    pub account_id: i64,
    pub mode: String,
    pub date: String,
    pub score: i64,
    pub distance_m: f64,
    pub room_type: Option<String>,
    pub legacy_board: Option<String>,
    pub verification: String,
    pub created_at: i64,
}

impl RunFacts {
    pub async fn load(conn: &mut SqliteConnection, run_id: i64) -> sqlx::Result<Option<RunFacts>> {
        sqlx::query_as!(
            RunFacts,
            "SELECT id, account_id, mode, date, score, distance_m, room_type, legacy_board,
                    verification, created_at
             FROM runs WHERE id = ?",
            run_id
        )
        .fetch_optional(conn)
        .await
    }

    fn verification(&self) -> Verification {
        Verification::parse(&self.verification).unwrap_or(Verification::Rejected)
    }
}

/// A board and period a run is written to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub board: Board,
    pub period: Period,
}

impl Target {
    /// Improving the player's entry here counts as beating their personal best (spec:
    /// replay trigger). All-time boards and the day's Daily board; weekly and season
    /// boards reset, so a first run there is not a personal best.
    pub fn is_personal_best(&self) -> bool {
        matches!(self.period.kind, PeriodKind::All | PeriodKind::Day)
    }
}

/// The boards and periods a run feeds (crew board excluded: see
/// `record_multiplayer_run`). Empty for a rejected-looking or unknown row.
pub fn targets(run: &RunFacts) -> Vec<Target> {
    let Some(day) = parse_date_days(&run.date) else {
        return Vec::new();
    };
    let at = |board: Board, kind: PeriodKind| Target {
        board,
        period: Period::containing(kind, day),
    };
    match run.mode.as_str() {
        mode::JOURNEY => vec![
            at(Board::Journey, PeriodKind::Week),
            at(Board::Journey, PeriodKind::All),
            at(Board::Distance, PeriodKind::All),
        ],
        mode::DAILY => vec![
            at(Board::Daily, PeriodKind::Day),
            at(Board::Distance, PeriodKind::All),
        ],
        mode::LOOP
            if run
                .room_type
                .as_deref()
                .is_some_and(|r| room_type::RANKED.contains(&r)) =>
        {
            vec![
                at(Board::Loop, PeriodKind::Season),
                at(Board::Loop, PeriodKind::All),
            ]
        }
        mode::LEGACY => match run.legacy_board.as_deref().and_then(Board::parse) {
            Some(b @ (Board::Journey | Board::Distance)) => vec![at(b, PeriodKind::All)],
            _ => Vec::new(),
        },
        _ => Vec::new(),
    }
}

/// The value a run ranks by on `board`: whole metres on Distance, else its score.
pub fn metric(board: Board, score: i64, distance_m: f64) -> i64 {
    if board == Board::Distance {
        if distance_m.is_finite() && distance_m > 0.0 {
            distance_m.floor().min(i64::MAX as f64) as i64
        } else {
            0
        }
    } else {
        score
    }
}

/// How a run stands on one board and period (API: `placements`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Placement {
    pub board: String,
    pub period: String,
    /// The run's value on this board (points, or metres on `distance`).
    pub score: i64,
    /// The player's rank on this board after the run (the run's rank if it improved the
    /// entry), `null` without an entry.
    pub rank: Option<u64>,
    /// The run beat the player's entry here (or there was none).
    pub improved: bool,
    /// The entry's score before the run, `null` if there was none.
    pub previous_best: Option<i64>,
    /// The run now holds the player's entry here (false while a pending run waits for
    /// N8 with `show_pending = false`).
    pub on_board: bool,
}

/// A target with the run's standing, before anything is written.
#[derive(Debug, Clone)]
pub struct Planned {
    pub target: Target,
    pub placement: Placement,
}

/// Works out how a run with value(s) (`score`, `distance_m`) recorded at `at` by
/// `account_id` would place on each target. Read-only.
pub async fn plan(
    conn: &mut SqliteConnection,
    account_id: i64,
    targets: Vec<Target>,
    score: i64,
    distance_m: f64,
    at: i64,
) -> sqlx::Result<Vec<Planned>> {
    let mut out = Vec::with_capacity(targets.len());
    for target in targets {
        let (b, p) = (target.board.id(), target.period.key.as_str());
        let value = metric(target.board, score, distance_m);
        let current = store::entry(conn, b, p, account_id).await?;
        let improved = value > 0 && current.as_ref().is_none_or(|c| value > c.score);
        let rank = if improved {
            Some(store::count_ahead(conn, b, p, value, at, account_id).await? + 1)
        } else if let Some(c) = &current {
            Some(store::count_ahead(conn, b, p, c.score, c.achieved_at, account_id).await? + 1)
        } else {
            None
        };
        out.push(Planned {
            placement: Placement {
                board: b.to_string(),
                period: p.to_string(),
                score: value,
                rank: rank.map(|r| r as u64),
                improved,
                previous_best: current.map(|c| c.score),
                on_board: false,
            },
            target,
        });
    }
    Ok(out)
}

/// Writes a run's improving placements (upsert only if better). Returns the targets
/// written; sets `on_board` on those placements.
pub async fn apply(
    conn: &mut SqliteConnection,
    run: &RunFacts,
    planned: &mut [Planned],
    show_pending: bool,
) -> sqlx::Result<Vec<Target>> {
    let mut written = Vec::new();
    if !run.verification().may_rank(show_pending) {
        return Ok(written);
    }
    for p in planned.iter_mut().filter(|p| p.placement.improved) {
        let e = NewEntry {
            board: p.target.board.id(),
            period_key: &p.target.period.key,
            subject_id: run.account_id,
            account_id: Some(run.account_id),
            run_id: Some(run.id),
            score: p.placement.score,
            achieved_at: run.created_at,
            verification: &run.verification,
            run_date: &run.date,
        };
        if store::upsert_if_better(conn, &e).await? {
            p.placement.on_board = true;
            written.push(p.target.clone());
        }
    }
    Ok(written)
}

/// Rebuilds one account's entry from its best remaining eligible run (after a run was
/// removed or rejected). The crew board is a sum, not a run: N9 recomputes it.
pub async fn recompute(
    conn: &mut SqliteConnection,
    board: Board,
    period: &Period,
    account_id: i64,
    show_pending: bool,
) -> sqlx::Result<bool> {
    if board.is_crew() {
        return Ok(false);
    }
    store::delete(conn, board.id(), &period.key, account_id).await?;
    let value = if board == Board::Distance {
        "CAST(distance_m AS INTEGER)"
    } else {
        "score"
    };
    let (filter, range) = match (board, period.kind) {
        (Board::Journey, PeriodKind::All) => {
            ("(mode = 'journey' OR legacy_board = 'journey')", false)
        }
        (Board::Journey, _) => ("mode = 'journey'", true),
        (Board::Daily, _) => ("mode = 'daily'", true),
        (Board::Distance, _) => (
            "(mode IN ('journey', 'daily') OR legacy_board = 'distance')",
            false,
        ),
        (Board::Loop, kind) => (
            "mode = 'loop' AND room_type IN ('public', 'private')",
            kind != PeriodKind::All,
        ),
        (Board::LoopCrew, _) => return Ok(false),
    };
    let states = if show_pending {
        "('verified', 'unverified', 'legacy', 'pending')"
    } else {
        "('verified', 'unverified', 'legacy')"
    };
    let sql = format!(
        "SELECT id, {value} AS v, created_at, verification, date FROM runs
         WHERE account_id = ? AND verification IN {states} AND {filter}
           AND date >= ? AND date <= ? AND {value} > 0
         ORDER BY v DESC, created_at ASC, id ASC LIMIT 1"
    );
    let (from, to) = match (range, period.date_range()) {
        (true, Some(r)) => r,
        _ => ("0000-00-00".to_string(), "9999-99-99".to_string()),
    };
    // Built only from the static fragments above; every value is bound.
    let best: Option<(i64, i64, i64, String, String)> = sqlx::query_as(sqlx::AssertSqlSafe(sql))
        .bind(account_id)
        .bind(&from)
        .bind(&to)
        .fetch_optional(&mut *conn)
        .await?;
    let Some((run_id, score, created_at, verification, date)) = best else {
        return Ok(false);
    };
    store::upsert_if_better(
        conn,
        &NewEntry {
            board: board.id(),
            period_key: &period.key,
            subject_id: account_id,
            account_id: Some(account_id),
            run_id: Some(run_id),
            score,
            achieved_at: created_at,
            verification: &verification,
            run_date: &date,
        },
    )
    .await
}

/// A crew as the room knows it when a multiplayer run ends (N9 provides crews).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CrewSnapshot {
    pub crew_id: i64,
    /// Every member's account id (the run's account included).
    pub member_ids: Vec<i64>,
}

/// Where a multiplayer run was driven.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoomKind {
    /// Public room: normal density, UTC clock. Ranked.
    Public,
    /// Private room left on the default density and clock. Ranked.
    PrivateDefault,
    /// Private room with a custom density or clock: personal stats only.
    PrivateCustom,
}

impl RoomKind {
    pub fn as_str(self) -> &'static str {
        match self {
            RoomKind::Public => room_type::PUBLIC,
            RoomKind::PrivateDefault => room_type::PRIVATE,
            RoomKind::PrivateCustom => room_type::PRIVATE_CUSTOM,
        }
    }

    /// Spec "Rooms → Leaderboard eligibility".
    pub fn is_ranked(self) -> bool {
        self != RoomKind::PrivateCustom
    }
}

/// A finished multiplayer run with its server-official score (N6 calls
/// [`Leaderboards::record_multiplayer_run`] with it; nothing is submitted by the client).
#[derive(Debug, Clone, PartialEq)]
pub struct MultiplayerRun {
    pub account_id: i64,
    /// The map id, e.g. `loop_v1`.
    pub map_id: String,
    pub room: RoomKind,
    pub score: u32,
    pub duration_s: f64,
    pub distance_m: f64,
    /// The run's stats (the protocol's `RunResult` fields), stored as JSON.
    pub stats: serde_json::Value,
    pub car: String,
    pub client_build: u32,
    /// Unix seconds at the run's end: its date and season.
    pub ended_at: i64,
    /// The player's crew, when they have one (N9).
    pub crew: Option<CrewSnapshot>,
}

/// What `record_multiplayer_run` did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedRun {
    pub run_id: i64,
    /// The room counted for the official Loop boards.
    pub ranked: bool,
    pub placements: Vec<Placement>,
    /// The crew's new Loop crew score this season, when it changed.
    pub crew_score: Option<i64>,
}

/// How a replay verification ended (N8).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayOutcome {
    Accepted,
    Rejected,
}

// ---------------------------------------------------------------------------------------------
// The service: cached reads and writes that keep the cache honest
// ---------------------------------------------------------------------------------------------

/// A cached top of one board and period.
#[derive(Debug)]
struct CachedTop {
    built_at: i64,
    total: i64,
    rows: Arc<Vec<EntryRow>>,
}

/// Leaderboards over the database, with an in-memory top-N cache per board and period
/// (dropped on every write to that pair, and after `cache_ttl_secs`).
pub struct Leaderboards {
    db: SqlitePool,
    cfg: LeaderboardsConfig,
    clock: Arc<dyn Clock>,
    cache: Mutex<HashMap<(Board, String), Arc<CachedTop>>>,
}

impl std::fmt::Debug for Leaderboards {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Leaderboards").finish_non_exhaustive()
    }
}

/// A board read (the `GET /api/v1/boards/{board}` body).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoardView {
    pub board: String,
    pub period: String,
    /// `season`, `week`, `day` or `all`.
    pub period_kind: String,
    /// First and last UTC date of the period (`null` for `all`).
    pub period_start: Option<String>,
    pub period_end: Option<String>,
    /// `global`, `around_me` or `friends`.
    pub view: String,
    /// Entries in this board and period.
    pub total: i64,
    pub entries: Vec<BoardEntry>,
    /// The caller's own entry (authenticated reads), `null` if they have none.
    pub me: Option<BoardEntry>,
    /// False until friends exist (N9): the friends view is then empty.
    pub friends_available: bool,
    pub generated_at: i64,
}

/// One ranked entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoardEntry {
    /// 1-based; ties go to the earlier run, so ranks never repeat. In the friends view,
    /// the rank among the caller and their friends.
    pub rank: u64,
    /// Decimal string; `null` on the crew board.
    pub account_id: Option<String>,
    /// Decimal string on the crew board, else `null`.
    pub crew_id: Option<String>,
    pub display_name: Option<String>,
    /// The `#1234` suffix.
    pub tag: Option<u16>,
    /// `display_name#0042`.
    pub full_name: Option<String>,
    /// The player's crew tag (`null` until crews, N9).
    pub crew_tag: Option<String>,
    /// Points, or whole metres on `distance`.
    pub score: i64,
    /// `pending`, `verified`, `unverified` or `legacy`.
    pub verification: String,
    /// Awaiting its replay: show "verifying".
    pub verifying: bool,
    /// An uploaded local personal best: show the legacy marker.
    pub legacy: bool,
    /// Decimal string; `null` on the crew board.
    pub run_id: Option<String>,
    /// The run's UTC date, `YYYY-MM-DD`.
    pub run_date: String,
    /// When the run was recorded (unix seconds).
    pub achieved_at: i64,
}

impl BoardEntry {
    fn from_row(board: Board, rank: u64, r: &EntryRow) -> BoardEntry {
        let tag = r.tag.and_then(|t| u16::try_from(t).ok());
        let full_name = match (&r.display_name, tag) {
            (Some(n), Some(t)) => Some(names::full_name(n, t)),
            _ => None,
        };
        BoardEntry {
            rank,
            account_id: r.account_id.map(|id| id.to_string()),
            crew_id: board.is_crew().then(|| r.subject_id.to_string()),
            display_name: r.display_name.clone(),
            tag,
            full_name,
            crew_tag: None,
            score: r.score,
            verification: r.verification.clone(),
            verifying: r.verification == Verification::Pending.as_str(),
            legacy: r.verification == Verification::Legacy.as_str(),
            run_id: r.run_id.map(|id| id.to_string()),
            run_date: r.run_date.clone(),
            achieved_at: r.achieved_at,
        }
    }
}

/// The three views.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum View {
    Global,
    AroundMe,
    Friends,
}

impl View {
    pub fn parse(s: &str) -> Option<View> {
        match s {
            "global" => Some(View::Global),
            "around_me" => Some(View::AroundMe),
            "friends" => Some(View::Friends),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            View::Global => "global",
            View::AroundMe => "around_me",
            View::Friends => "friends",
        }
    }
}

impl Leaderboards {
    pub fn new(db: SqlitePool, cfg: LeaderboardsConfig, clock: Arc<dyn Clock>) -> Self {
        Self {
            db,
            cfg,
            clock,
            cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn config(&self) -> &LeaderboardsConfig {
        &self.cfg
    }

    /// Drops the cached top of one board and period.
    pub fn invalidate(&self, board: Board, period_key: &str) {
        self.cache_lock().remove(&(board, period_key.to_string()));
    }

    /// Drops every cached top (account deletion, renames).
    pub fn invalidate_all(&self) {
        self.cache_lock().clear();
    }

    pub fn invalidate_targets(&self, targets: &[Target]) {
        let mut c = self.cache_lock();
        for t in targets {
            c.remove(&(t.board, t.period.key.clone()));
        }
    }

    /// Number of cached board/period pairs (tests).
    pub fn cached_boards(&self) -> usize {
        self.cache_lock().len()
    }

    fn cache_lock(&self) -> std::sync::MutexGuard<'_, HashMap<(Board, String), Arc<CachedTop>>> {
        self.cache.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// The top `global_limit_max` of a board and period and its entry count, from the
    /// cache when fresh.
    async fn cached_top(&self, board: Board, period: &str) -> sqlx::Result<Arc<CachedTop>> {
        let now = self.clock.now();
        let key = (board, period.to_string());
        let ttl = i64::try_from(self.cfg.cache_ttl_secs).unwrap_or(i64::MAX);
        if let Some(hit) = self.cache_lock().get(&key) {
            if now.saturating_sub(hit.built_at) < ttl {
                return Ok(hit.clone());
            }
        }
        let mut conn = self.db.acquire().await?;
        let limit = i64::from(self.cfg.global_limit_max);
        let rows = store::top(&mut conn, board.id(), period, limit).await?;
        let total = store::count(&mut conn, board.id(), period).await?;
        let top = Arc::new(CachedTop {
            built_at: now,
            total,
            rows: Arc::new(rows),
        });
        let mut c = self.cache_lock();
        if c.len() >= self.cfg.cache_max_boards {
            c.clear();
        }
        c.insert(key, top.clone());
        Ok(top)
    }

    /// Reads a board. `caller` is the authenticated account, if any; `limit` is already
    /// validated for the view.
    pub async fn read(
        &self,
        board: Board,
        period: &Period,
        view: View,
        limit: u32,
        caller: Option<i64>,
    ) -> sqlx::Result<BoardView> {
        let now = self.clock.now();
        let (b, p) = (board.id(), period.key.as_str());
        let top = self.cached_top(board, p).await?;
        let mut conn = self.db.acquire().await?;
        let subject = match caller {
            Some(id) if board.is_crew() => crate::social::crew_of(&mut conn, id).await?,
            other => other,
        };
        let me_row = match subject {
            Some(s) => store::entry(&mut conn, b, p, s).await?,
            None => None,
        };
        let me_rank = match &me_row {
            Some(r) => Some(
                store::count_ahead(&mut conn, b, p, r.score, r.achieved_at, r.subject_id).await?
                    as u64
                    + 1,
            ),
            None => None,
        };
        let mut friends_available = false;
        let entries = match view {
            View::Global => top
                .rows
                .iter()
                .take(limit as usize)
                .enumerate()
                .map(|(i, r)| BoardEntry::from_row(board, i as u64 + 1, r))
                .collect(),
            View::AroundMe => match (&me_row, me_rank) {
                (Some(me), Some(rank)) => {
                    self.around(&mut conn, board, p, me, rank, i64::from(limit))
                        .await?
                }
                _ => Vec::new(),
            },
            View::Friends => {
                let friends = match caller {
                    Some(id) if !board.is_crew() => {
                        crate::social::friend_ids(&mut conn, id).await?
                    }
                    _ => None,
                };
                match (friends, caller) {
                    (Some(mut ids), Some(me)) => {
                        friends_available = true;
                        ids.push(me);
                        let json = serde_json::to_string(&ids).unwrap_or_else(|_| "[]".into());
                        let limit = i64::from(self.cfg.global_limit_max);
                        store::of_subjects(&mut conn, b, p, &json, limit)
                            .await?
                            .iter()
                            .enumerate()
                            .map(|(i, r)| BoardEntry::from_row(board, i as u64 + 1, r))
                            .collect()
                    }
                    _ => Vec::new(),
                }
            }
        };
        let (period_start, period_end) = period.date_range().unzip();
        Ok(BoardView {
            board: b.to_string(),
            period: p.to_string(),
            period_kind: period.kind.as_str().to_string(),
            period_start,
            period_end,
            view: view.as_str().to_string(),
            total: top.total,
            entries,
            me: me_row.map(|r| BoardEntry::from_row(board, me_rank.unwrap_or(0), &r)),
            friends_available,
            generated_at: now,
        })
    }

    /// `2 × side + 1` entries centred on the caller (rank `rank`); at the top or bottom
    /// of the board the window shifts so it still holds as many entries as exist.
    async fn around(
        &self,
        conn: &mut SqliteConnection,
        board: Board,
        period: &str,
        me: &EntryRow,
        rank: u64,
        side: i64,
    ) -> sqlx::Result<Vec<BoardEntry>> {
        let b = board.id();
        let want = 2 * side;
        let ahead = store::ahead(
            conn,
            b,
            period,
            me.score,
            me.achieved_at,
            me.subject_id,
            want,
        )
        .await?;
        let behind = store::behind(
            conn,
            b,
            period,
            me.score,
            me.achieved_at,
            me.subject_id,
            want,
        )
        .await?;
        // Take `side` from each side, then give a short side's remainder to the other.
        let mut n_ahead = (side as usize).min(ahead.len());
        let n_behind = (side as usize + (side as usize - n_ahead)).min(behind.len());
        n_ahead = (n_ahead + (side as usize).saturating_sub(n_behind)).min(ahead.len());
        let first_rank = rank - n_ahead as u64;
        let rows = ahead[..n_ahead]
            .iter()
            .rev()
            .chain(std::iter::once(me))
            .chain(behind[..n_behind].iter());
        Ok(rows
            .enumerate()
            .map(|(i, r)| BoardEntry::from_row(board, first_rank + i as u64, r))
            .collect())
    }

    /// Records a finished multiplayer run (N6): stores it as `verified` (the server holds
    /// the official score) and, when the room is ranked, writes the Loop board for the
    /// run's season and all-time, then the crew's Loop crew score for the season.
    pub async fn record_multiplayer_run(
        &self,
        run: &MultiplayerRun,
    ) -> anyhow::Result<RecordedRun> {
        let date = period::date_key(run.ended_at.div_euclid(crate::clock::SECS_PER_DAY));
        let stats = serde_json::to_string(&run.stats)?;
        let mut tx = self.db.begin_with("BEGIN IMMEDIATE").await?;
        let score = i64::from(run.score);
        let build = i64::from(run.client_build);
        let room = run.room.as_str();
        let verified = Verification::Verified.as_str();
        let run_id = sqlx::query!(
            "INSERT INTO runs (account_id, mode, map_or_seed, date, score, distance_m, duration_s,
                               stats, car, build, room_type, verification, created_at)
             VALUES (?, 'loop', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            run.account_id,
            run.map_id,
            date,
            score,
            run.distance_m,
            run.duration_s,
            stats,
            run.car,
            build,
            room,
            verified,
            run.ended_at
        )
        .execute(&mut *tx)
        .await?
        .last_insert_rowid();
        let facts = RunFacts::load(&mut tx, run_id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("run {run_id} vanished"))?;
        let targets = targets(&facts);
        let mut planned = plan(
            &mut tx,
            run.account_id,
            targets,
            score,
            run.distance_m,
            run.ended_at,
        )
        .await?;
        let mut written = apply(&mut tx, &facts, &mut planned, self.cfg.show_pending).await?;
        let mut crew_score = None;
        if let (true, Some(crew)) = (run.room.is_ranked(), &run.crew) {
            let season = Period::at(PeriodKind::Season, run.ended_at);
            let members = serde_json::to_string(&crew.member_ids)?;
            let top = i64::from(self.cfg.crew_top_members);
            let sum =
                store::crew_sum(&mut tx, Board::Loop.id(), &season.key, &members, top).await?;
            let changed = store::put_if_changed(
                &mut tx,
                &NewEntry {
                    board: Board::LoopCrew.id(),
                    period_key: &season.key,
                    subject_id: crew.crew_id,
                    account_id: None,
                    run_id: None,
                    score: sum,
                    achieved_at: run.ended_at,
                    verification: verified,
                    run_date: &date,
                },
            )
            .await?;
            if changed {
                crew_score = Some(sum);
                written.push(Target {
                    board: Board::LoopCrew,
                    period: season,
                });
            }
        }
        tx.commit().await?;
        self.invalidate_targets(&written);
        Ok(RecordedRun {
            run_id,
            ranked: run.room.is_ranked(),
            placements: planned.into_iter().map(|p| p.placement).collect(),
            crew_score,
        })
    }

    /// Applies a replay verdict (N8). Accepted: the run becomes `verified`, its entries
    /// say so, and (when pending runs were kept off the boards) it is written now.
    /// Rejected: the run becomes `rejected` and every entry it held is rebuilt from the
    /// player's next best run. Returns false for an unknown run.
    pub async fn set_run_verification(
        &self,
        run_id: i64,
        outcome: ReplayOutcome,
    ) -> anyhow::Result<bool> {
        let mut tx = self.db.begin_with("BEGIN IMMEDIATE").await?;
        let Some(mut facts) = RunFacts::load(&mut tx, run_id).await? else {
            return Ok(false);
        };
        let mut touched: Vec<Target> = Vec::new();
        match outcome {
            ReplayOutcome::Accepted => {
                let v = Verification::Verified.as_str();
                sqlx::query!("UPDATE runs SET verification = ? WHERE id = ?", v, run_id)
                    .execute(&mut *tx)
                    .await?;
                sqlx::query!(
                    "UPDATE leaderboard_entries SET verification = ? WHERE run_id = ?",
                    v,
                    run_id
                )
                .execute(&mut *tx)
                .await?;
                facts.verification = v.to_string();
                let t = targets(&facts);
                touched.extend(t.iter().cloned());
                let mut planned = plan(
                    &mut tx,
                    facts.account_id,
                    t,
                    facts.score,
                    facts.distance_m,
                    facts.created_at,
                )
                .await?;
                apply(&mut tx, &facts, &mut planned, self.cfg.show_pending).await?;
            }
            ReplayOutcome::Rejected => {
                let v = Verification::Rejected.as_str();
                sqlx::query!(
                    "UPDATE runs SET verification = ?, reject_reason = 'replay' WHERE id = ?",
                    v,
                    run_id
                )
                .execute(&mut *tx)
                .await?;
                for (board, period, subject) in store::entries_of_run(&mut tx, run_id).await? {
                    let (Some(b), true) = (Board::parse(&board), subject == facts.account_id)
                    else {
                        continue;
                    };
                    let Some(p) = b.parse_period(&period) else {
                        continue;
                    };
                    recompute(&mut tx, b, &p, subject, self.cfg.show_pending).await?;
                    touched.push(Target {
                        board: b,
                        period: p,
                    });
                }
            }
        }
        tx.commit().await?;
        self.invalidate_targets(&touched);
        Ok(true)
    }
}

/// What `remove_run` did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemovedRun {
    pub account_id: i64,
    /// Entries the run held, each rebuilt from the player's next best run.
    pub entries: Vec<(String, String)>,
    pub replay_file: Option<String>,
}

/// Admin: deletes a run (and its replay), then rebuilds every entry it held from the
/// player's next best run. `None` if there is no such run.
pub async fn remove_run(
    pool: &SqlitePool,
    cfg: &LeaderboardsConfig,
    run_id: i64,
) -> anyhow::Result<Option<RemovedRun>> {
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let Some(facts) = RunFacts::load(&mut tx, run_id).await? else {
        return Ok(None);
    };
    let held = store::entries_of_run(&mut tx, run_id).await?;
    let replay_file = sqlx::query_scalar!("SELECT file_path FROM replays WHERE run_id = ?", run_id)
        .fetch_optional(&mut *tx)
        .await?;
    sqlx::query!("DELETE FROM replays WHERE run_id = ?", run_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query!("DELETE FROM leaderboard_entries WHERE run_id = ?", run_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query!("DELETE FROM runs WHERE id = ?", run_id)
        .execute(&mut *tx)
        .await?;
    let mut entries = Vec::new();
    for (board, period, subject) in held {
        if let Some((b, p)) = Board::parse(&board).and_then(|b| Some((b, b.parse_period(&period)?)))
        {
            recompute(&mut tx, b, &p, subject, cfg.show_pending).await?;
        }
        entries.push((board, period));
    }
    tx.commit().await?;
    if let Some(path) = &replay_file {
        remove_replay_file(path).await;
    }
    Ok(Some(RemovedRun {
        account_id: facts.account_id,
        entries,
        replay_file,
    }))
}

/// Admin: deletes one account's entry on a board and period (not rebuilt: it comes back
/// only with a new run). Returns whether it existed.
pub async fn remove_entry(
    pool: &SqlitePool,
    board: Board,
    period: &Period,
    subject_id: i64,
) -> sqlx::Result<bool> {
    let mut conn = pool.acquire().await?;
    store::delete(&mut conn, board.id(), &period.key, subject_id).await
}

/// Deletes a replay file after its row is gone; a missing file is fine.
pub async fn remove_replay_file(path: &str) {
    match tokio::fs::remove_file(path).await {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => tracing::warn!(error = %e, "removing a replay file failed"),
    }
}
