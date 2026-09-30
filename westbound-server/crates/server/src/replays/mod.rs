//! Replay uploads, the verification queue and replay retention (N8.1). Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards" (single-player runs, steps 3–5:
//! the replay upload when a run needs one; a headless verifier plays it back; "jobs queue
//! in SQLite and run one at a time with a timeout; replays are deleted after verification
//! except for current top-100 entries"; build parity), "Resource budget" (the verifier:
//! one job at a time, `nice 10`, 1 GB), "Data model" (`replays`). docs/SERVER.md →
//! "Replays and verification"; the file format: docs/REPLAY_FORMAT.md.
//!
//! - `POST /api/v1/runs/{run_id}/replay` (`routes`): the owner uploads the `.wbr` bytes
//!   of a run whose receipt said `replay_required` (still `pending`). The header must name
//!   that run (id, seed, mode, date, build). The file goes to `<dir>/<run_id>.wbr` and a
//!   `pending` job row into `replays`; a second upload answers the first (idempotent).
//! - The queue worker (`worker`): one job at a time, it spawns the configured verifier
//!   command with a timeout, reads the result JSON and applies the verdict with
//!   `Leaderboards::set_run_verification`. With no verifier configured the jobs wait in
//!   `pending` and the runs stay "verifying".
//! - Retention (`retention`): after a verdict, and on a periodic sweep, a verified
//!   replay's file is deleted unless its run ranks within `keep_top_n` somewhere.

pub mod format;
pub mod retention;
pub mod routes;
pub mod worker;

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::config::ReplaysConfig;

/// `replays.status` values.
pub mod status {
    pub const PENDING: &str = "pending";
    pub const RUNNING: &str = "running";
    pub const DONE: &str = "done";
    pub const FAILED: &str = "failed";
}

/// The file name of a run's replay.
pub fn file_name(run_id: i64) -> String {
    format!("{run_id}.wbr")
}

/// `<dir>/<run_id>.wbr`.
pub fn file_path(cfg: &ReplaysConfig, run_id: i64) -> PathBuf {
    cfg.dir.join(file_name(run_id))
}

/// Where the verifier writes its result for a job.
pub fn work_dir(cfg: &ReplaysConfig) -> PathBuf {
    cfg.dir.join("work")
}

/// The answer to an upload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadReceipt {
    /// Decimal string.
    pub run_id: String,
    /// The job's status (`pending`, `running`, `done`, `failed`).
    pub status: String,
    /// This run already had a replay: this is it (nothing was stored).
    pub duplicate: bool,
    pub size_bytes: i64,
}

/// Why an upload was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UploadError {
    /// No such run (404 `unknown_run`).
    UnknownRun,
    /// Another account's run (403 `not_owner`).
    NotOwner,
    /// The run's receipt did not ask for a replay, or its verification is settled (409).
    NotRequired,
    /// Not a replay file (400 `invalid_replay`).
    Invalid(String),
    /// A replay of another run: id, seed, mode, date or build differ (400 `replay_mismatch`).
    Mismatch(String),
}

/// What the upload needs of the run.
#[derive(Debug, Clone)]
pub struct RunRow {
    pub account_id: i64,
    pub mode: String,
    pub map_or_seed: String,
    pub date: String,
    pub build: i64,
    pub verification: String,
    pub replay_required: bool,
}

pub async fn load_run(
    conn: &mut sqlx::SqliteConnection,
    run_id: i64,
) -> sqlx::Result<Option<RunRow>> {
    let row = sqlx::query!(
        r#"SELECT account_id, mode, map_or_seed, date, build, verification,
                  COALESCE(json_extract(response, '$.replay_required'), 0) AS "replay_required!: i64"
           FROM runs WHERE id = ?"#,
        run_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(row.map(|r| RunRow {
        account_id: r.account_id,
        mode: r.mode,
        map_or_seed: r.map_or_seed,
        date: r.date,
        build: r.build,
        verification: r.verification,
        replay_required: r.replay_required != 0,
    }))
}

/// The header must be a replay of this run.
pub fn check_header(h: &format::Header, run_id: i64, run: &RunRow) -> Result<(), UploadError> {
    let m = |what: &str| {
        Err(UploadError::Mismatch(format!(
            "the replay's {what} is not the run's"
        )))
    };
    if h.run_id != run_id {
        return m("run id");
    }
    if h.seed.to_string() != run.map_or_seed {
        return m("seed");
    }
    if h.mode != run.mode {
        return m("mode");
    }
    if h.date != run.date {
        return m("date");
    }
    if i64::from(h.client_build) != run.build {
        return m("client build");
    }
    Ok(())
}

/// A job's current row, if the run has a replay.
pub async fn job_status(
    conn: &mut sqlx::SqliteConnection,
    run_id: i64,
) -> sqlx::Result<Option<(String, i64)>> {
    let row = sqlx::query!(
        "SELECT status, size_bytes FROM replays WHERE run_id = ?",
        run_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(row.map(|r| (r.status, r.size_bytes)))
}

/// Stores an upload (see the module docs). Returns the receipt and whether it is new.
pub async fn upload(
    db: &sqlx::SqlitePool,
    cfg: &ReplaysConfig,
    account_id: i64,
    run_id: i64,
    bytes: &[u8],
    now: i64,
) -> anyhow::Result<Result<(UploadReceipt, bool), UploadError>> {
    let mut conn = db.acquire().await?;
    let Some(run) = load_run(&mut conn, run_id).await? else {
        return Ok(Err(UploadError::UnknownRun));
    };
    if run.account_id != account_id {
        return Ok(Err(UploadError::NotOwner));
    }
    if let Some((status, size)) = job_status(&mut conn, run_id).await? {
        return Ok(Ok((receipt(run_id, status, true, size), false)));
    }
    if !run.replay_required
        || run.verification != crate::leaderboards::Verification::Pending.as_str()
    {
        return Ok(Err(UploadError::NotRequired));
    }
    let header = match format::parse(bytes) {
        Ok(h) => h,
        Err(why) => return Ok(Err(UploadError::Invalid(why))),
    };
    if let Err(e) = check_header(&header, run_id, &run) {
        return Ok(Err(e));
    }
    drop(conn);
    // Write to a temporary name, then (holding the write lock) rename and insert, so two
    // racing uploads store one file and one row.
    tokio::fs::create_dir_all(&cfg.dir).await?;
    let dest = file_path(cfg, run_id);
    let tmp = cfg
        .dir
        .join(format!("{}.{}.tmp", file_name(run_id), random_suffix()));
    tokio::fs::write(&tmp, bytes).await?;
    let size = i64::try_from(bytes.len())?;
    let path = dest.to_string_lossy().into_owned();
    let mut tx = db.begin_with("BEGIN IMMEDIATE").await?;
    if let Some((status, size)) = job_status(&mut tx, run_id).await? {
        drop(tx);
        let _ = tokio::fs::remove_file(&tmp).await;
        return Ok(Ok((receipt(run_id, status, true, size), false)));
    }
    if let Err(e) = tokio::fs::rename(&tmp, &dest).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(e.into());
    }
    let pending = status::PENDING;
    sqlx::query!(
        "INSERT INTO replays (run_id, file_path, status, created_at, size_bytes, not_before)
         VALUES (?, ?, ?, ?, ?, ?)",
        run_id,
        path,
        pending,
        now,
        size,
        now
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    tracing::info!(run_id, account_id, size, "replay uploaded");
    Ok(Ok((
        receipt(run_id, pending.to_string(), false, size),
        true,
    )))
}

fn receipt(run_id: i64, status: String, duplicate: bool, size_bytes: i64) -> UploadReceipt {
    UploadReceipt {
        run_id: run_id.to_string(),
        status,
        duplicate,
        size_bytes,
    }
}

fn random_suffix() -> String {
    let mut b = [0u8; 8];
    getrandom::fill(&mut b).expect("random bytes");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Deletes a file, ignoring one that is already gone.
pub async fn remove_file(path: &Path) {
    match tokio::fs::remove_file(path).await {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            tracing::warn!(error = %e, path = %path.display(), "removing a replay file failed")
        }
    }
}
