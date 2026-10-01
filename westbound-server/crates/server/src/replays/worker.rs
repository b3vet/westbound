//! The verification queue worker (N8.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! "Leaderboards" (step 4: "jobs queue in SQLite and run one at a time with a timeout"),
//! "Resource budget" (the verifier: one job at a time, `nice 10`, 1 GB). docs/SERVER.md →
//! "Replays and verification".
//!
//! One worker task (in `serve`, or `westbound-server verify-worker` in a sidecar) takes the
//! oldest due `pending` job, marks it `running` (attempts + 1), and runs the configured
//! verifier command with the job's placeholders filled in, under `job_timeout_secs`
//! (killed when it runs over). The verifier writes its result JSON to `{out}` and exits 0
//! (accepted) or 1 (rejected); the worker applies the verdict with
//! `Leaderboards::set_run_verification`, marks the job `done` and lets retention decide
//! about the file. Anything else (another exit status, no or bad JSON, a timeout, a
//! missing file) is a failed attempt: the job goes back to `pending` after
//! `retry_delay_secs`, or becomes `failed` after `max_attempts`. Jobs are strictly
//! sequential: the next one starts only after the previous one finished. On start, jobs
//! left `running` by a stopped worker go back to `pending`.
//!
//! N8.3, build parity: a job this worker cannot verify is **set aside** at once instead of
//! being retried against the same verifier: status `set_aside` (N10.3; `failed` before)
//! with `{"error": ..., "unverifiable": true, "build": N}` as its result, the run still
//! "verifying". That is a command naming a
//! per-build file (an absolute argv entry built from `{build}`, like
//! `/verifier/{build}/westbound`) that does not exist here (nothing is run), or the
//! verifier's "cannot verify" (exit 3 with a result `error`: another tuning under the same
//! build number, a replay without inputs, an unknown car). Each worker start puts those
//! jobs back to `pending` (a new verifier image may know their build); jobs that failed
//! for another reason wait for `admin replay-requeue`.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use sqlx::SqlitePool;
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use super::{retention, status};
use crate::clock::Clock;
use crate::config::ReplaysConfig;
use crate::leaderboards::{Leaderboards, ReplayOutcome};

/// Verifier exit statuses (tools/verifier/verify_replay.gd).
pub const EXIT_ACCEPTED: i32 = 0;
pub const EXIT_REJECTED: i32 = 1;
/// "Cannot verify this replay here": not a verdict, and retrying the same verifier would
/// not change it (N8.3: set aside until a worker starts).
pub const EXIT_CANNOT: i32 = 3;
/// Output kept from the verifier for the logs (its tail).
const OUTPUT_TAIL_BYTES: usize = 2_000;

/// A claimed job: the run and what the verifier command needs.
#[derive(Debug, Clone)]
pub struct Job {
    pub run_id: i64,
    pub file_path: String,
    pub attempts: i64,
    pub seed: String,
    pub mode: String,
    pub build: i64,
    pub claimed_score: i64,
    pub claimed_hits: i64,
}

/// How one job ended.
#[derive(Debug, Clone, PartialEq)]
pub enum JobOutcome {
    /// A verdict was applied (the verifier's result JSON).
    Verdict { accepted: bool, result: Value },
    /// The attempt failed; the job is pending again (retry) or `failed` (`final_`).
    Failed { error: String, final_: bool },
    /// This worker cannot verify the job (its build has no verifier here, or the verifier
    /// answered "cannot verify"): `set_aside` until a worker starts (N8.3, N10.3).
    Unverifiable { error: String },
}

/// Why a job got no verdict.
enum NoVerdict {
    /// Worth another attempt (a crash, a timeout, a missing result).
    Failed(String),
    /// Not with this verifier (N8.3).
    Unverifiable(String),
}

/// The queue worker.
#[derive(Clone)]
pub struct Worker {
    pub db: SqlitePool,
    pub boards: Arc<Leaderboards>,
    pub cfg: ReplaysConfig,
    pub clock: Arc<dyn Clock>,
    /// Woken by each new upload.
    pub wake: Arc<Notify>,
}

impl Worker {
    /// Whether a verifier command is configured (without one, jobs wait in `pending`).
    pub fn configured(&self) -> bool {
        !self.cfg.verifier_command.is_empty()
    }

    /// Runs jobs one at a time until `shutdown`.
    pub async fn run(self, shutdown: CancellationToken) {
        match self.recover().await {
            Ok(0) => {}
            Ok(n) => tracing::info!(jobs = n, "replay jobs left running were requeued"),
            Err(e) => tracing::warn!(
                error = %e,
                "requeueing running replay jobs failed (is the server's database on this volume?)"
            ),
        }
        match self.requeue_unverifiable().await {
            Ok(0) => {}
            Ok(n) => tracing::info!(
                jobs = n,
                "replay jobs set aside as unverifiable were requeued (this verifier may know their build)"
            ),
            Err(e) => tracing::warn!(error = %e, "requeueing unverifiable replay jobs failed"),
        }
        tracing::info!(
            command = %self.cfg.verifier_command.join(" "),
            timeout_secs = self.cfg.job_timeout_secs,
            "replay verification worker started"
        );
        let poll = Duration::from_secs(self.cfg.poll_interval_secs);
        loop {
            if shutdown.is_cancelled() {
                return;
            }
            let ran = tokio::select! {
                _ = shutdown.cancelled() => return,
                r = self.run_next() => r,
            };
            match ran {
                Ok(Some(_)) => continue,
                Ok(None) => {}
                Err(e) => tracing::warn!(error = %e, "replay queue error"),
            }
            tokio::select! {
                _ = shutdown.cancelled() => return,
                _ = self.wake.notified() => {}
                _ = tokio::time::sleep(poll) => {}
            }
        }
    }

    /// Jobs a stopped worker left `running` go back to `pending` (their attempt counts).
    pub async fn recover(&self) -> sqlx::Result<u64> {
        let (pending, running) = (status::PENDING, status::RUNNING);
        let now = self.clock.now();
        let done = sqlx::query!(
            "UPDATE replays SET status = ?, not_before = ? WHERE status = ?",
            pending,
            now,
            running
        )
        .execute(&self.db)
        .await?;
        Ok(done.rows_affected())
    }

    /// Jobs set aside as unverifiable by a worker (N8.3) go back to `pending`, their
    /// attempts reset: called when a worker starts, whose verifier may know their build.
    /// Purged ones (their file let go, N10.3) stay. The pre-N10.3 form (`failed` with
    /// `"unverifiable": true`) counts too.
    pub async fn requeue_unverifiable(&self) -> sqlx::Result<u64> {
        let now = self.clock.now();
        let done = sqlx::query(
            "UPDATE replays SET status = ?, attempts = 0, not_before = ?
             WHERE file_deleted_at IS NULL AND (status = ? OR (status = ?
               AND json_valid(result) AND json_extract(result, '$.unverifiable') = 1))",
        )
        .bind(status::PENDING)
        .bind(now)
        .bind(status::SET_ASIDE)
        .bind(status::FAILED)
        .execute(&self.db)
        .await?;
        Ok(done.rows_affected())
    }

    /// Claims the oldest due job and processes it. `None` when no job is due (or no
    /// verifier is configured).
    pub async fn run_next(&self) -> anyhow::Result<Option<(i64, JobOutcome)>> {
        if !self.configured() {
            return Ok(None);
        }
        let Some(job) = self.claim().await? else {
            return Ok(None);
        };
        let outcome = self.process(&job).await?;
        Ok(Some((job.run_id, outcome)))
    }

    async fn claim(&self) -> sqlx::Result<Option<Job>> {
        let now = self.clock.now();
        let (pending, running) = (status::PENDING, status::RUNNING);
        let mut tx = self.db.begin_with("BEGIN IMMEDIATE").await?;
        let next = sqlx::query_scalar!(
            r#"SELECT run_id AS "run_id!" FROM replays WHERE status = ? AND not_before <= ?
               ORDER BY created_at, run_id LIMIT 1"#,
            pending,
            now
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(run_id) = next else {
            return Ok(None);
        };
        sqlx::query!(
            "UPDATE replays SET status = ?, attempts = attempts + 1, started_at = ? WHERE run_id = ?",
            running,
            now,
            run_id
        )
        .execute(&mut *tx)
        .await?;
        let row = sqlx::query!(
            r#"SELECT r.file_path, r.attempts, u.map_or_seed, u.mode, u.build, u.score,
                      COALESCE(json_extract(u.stats, '$.hits'), 0) AS "hits!: i64"
               FROM replays r JOIN runs u ON u.id = r.run_id WHERE r.run_id = ?"#,
            run_id
        )
        .fetch_one(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(Some(Job {
            run_id,
            file_path: row.file_path,
            attempts: row.attempts,
            seed: row.map_or_seed,
            mode: row.mode,
            build: row.build,
            claimed_score: row.score,
            claimed_hits: row.hits,
        }))
    }

    /// Runs the verifier for a claimed job and records what happened.
    pub async fn process(&self, job: &Job) -> anyhow::Result<JobOutcome> {
        let started = std::time::Instant::now();
        let outcome = match self.verify(job).await {
            Ok((accepted, result)) => {
                let verdict = if accepted {
                    ReplayOutcome::Accepted
                } else {
                    ReplayOutcome::Rejected
                };
                let found = self
                    .boards
                    .set_run_verification(job.run_id, verdict)
                    .await?;
                let v = if accepted { "accepted" } else { "rejected" };
                let text = result.to_string();
                let (done, now) = (status::DONE, self.clock.now());
                sqlx::query!(
                    "UPDATE replays SET status = ?, verdict = ?, result = ?, finished_at = ?
                     WHERE run_id = ?",
                    done,
                    v,
                    text,
                    now,
                    job.run_id
                )
                .execute(&self.db)
                .await?;
                let field = |k: &str| result.get(k).map_or_else(String::new, |x| x.to_string());
                let (reason, recomputed, diff, unreported, violations, diverged) = (
                    result
                        .get("reason")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .to_string(),
                    field("recomputed_score"),
                    field("diff_pct"),
                    field("unreported_hits"),
                    field("violation_count"),
                    field("traffic_diverged_at_s"),
                );
                tracing::info!(
                    run_id = job.run_id,
                    verdict = v,
                    run_found = found,
                    %reason,
                    recomputed_score = %recomputed,
                    claimed_score = job.claimed_score,
                    diff_pct = %diff,
                    unreported_hits = %unreported,
                    violations = %violations,
                    traffic_diverged_at_s = %diverged,
                    secs = started.elapsed().as_secs_f64(),
                    "replay verified"
                );
                if let Err(e) = retention::after_verdict(&self.db, &self.cfg, job.run_id, now).await
                {
                    tracing::warn!(run_id = job.run_id, error = %e, "replay retention failed");
                }
                JobOutcome::Verdict { accepted, result }
            }
            Err(NoVerdict::Failed(error)) => self.fail(job, error).await?,
            Err(NoVerdict::Unverifiable(error)) => self.set_aside(job, error).await?,
        };
        Ok(outcome)
    }

    async fn fail(&self, job: &Job, error: String) -> anyhow::Result<JobOutcome> {
        let now = self.clock.now();
        let final_ = job.attempts >= i64::from(self.cfg.max_attempts);
        let result = serde_json::json!({ "error": error }).to_string();
        if final_ {
            let failed = status::FAILED;
            sqlx::query!(
                "UPDATE replays SET status = ?, result = ?, finished_at = ? WHERE run_id = ?",
                failed,
                result,
                now,
                job.run_id
            )
            .execute(&self.db)
            .await?;
            tracing::warn!(run_id = job.run_id, attempts = job.attempts, %error, "replay verification failed for good");
        } else {
            let pending = status::PENDING;
            let retry_at = now + i64::try_from(self.cfg.retry_delay_secs).unwrap_or(i64::MAX);
            sqlx::query!(
                "UPDATE replays SET status = ?, result = ?, not_before = ? WHERE run_id = ?",
                pending,
                result,
                retry_at,
                job.run_id
            )
            .execute(&self.db)
            .await?;
            tracing::warn!(run_id = job.run_id, attempts = job.attempts, %error, "replay verification attempt failed; retrying later");
        }
        Ok(JobOutcome::Failed { error, final_ })
    }

    /// Sets a job aside as unverifiable here (N8.3): `set_aside` (N10.3) with the reason,
    /// until a worker starts. The run stays pending ("verifying") and the file is kept
    /// (up to `replays.set_aside_retention_days`).
    async fn set_aside(&self, job: &Job, error: String) -> anyhow::Result<JobOutcome> {
        let now = self.clock.now();
        let result = serde_json::json!({
            "error": error,
            "unverifiable": true,
            "build": job.build,
        })
        .to_string();
        sqlx::query("UPDATE replays SET status = ?, result = ?, finished_at = ? WHERE run_id = ?")
            .bind(status::SET_ASIDE)
            .bind(result)
            .bind(now)
            .bind(job.run_id)
            .execute(&self.db)
            .await?;
        tracing::warn!(
            run_id = job.run_id,
            build = job.build,
            %error,
            "replay cannot be verified by this verifier; set aside until a verifier with its build starts"
        );
        Ok(JobOutcome::Unverifiable { error })
    }

    /// The first per-build file the command names that is not here: an argv entry built
    /// from a `{build}` template (and no other placeholder) that is an absolute path
    /// (`/verifier/{build}/westbound`).
    pub fn missing_build_file(&self, job: &Job) -> Option<String> {
        let build = job.build.to_string();
        self.cfg
            .verifier_command
            .iter()
            .filter(|a| a.contains("{build}"))
            .map(|a| a.replace("{build}", &build))
            .filter(|p| !p.contains('{'))
            .find(|p| Path::new(p).is_absolute() && !Path::new(p).exists())
    }

    /// Runs the verifier command: `(accepted, result JSON)`, or why there is no verdict.
    async fn verify(&self, job: &Job) -> Result<(bool, Value), NoVerdict> {
        if !Path::new(&job.file_path).exists() {
            return Err(NoVerdict::Failed(format!(
                "the replay file {} is missing",
                job.file_path
            )));
        }
        if let Some(missing) = self.missing_build_file(job) {
            return Err(NoVerdict::Unverifiable(format!(
                "no verifier for build {} here ({missing} is missing)",
                job.build
            )));
        }
        let work = super::work_dir(&self.cfg);
        tokio::fs::create_dir_all(&work)
            .await
            .map_err(|e| NoVerdict::Failed(format!("creating {}: {e}", work.display())))?;
        let out = work.join(format!("{}.json", job.run_id));
        super::remove_file(&out).await;
        let args = self.command_for(job, &out);
        let mut cmd = tokio::process::Command::new(&args[0]);
        cmd.args(&args[1..])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let child = cmd
            .spawn()
            .map_err(|e| NoVerdict::Failed(format!("starting the verifier `{}`: {e}", args[0])))?;
        let limit = Duration::from_secs(self.cfg.job_timeout_secs);
        let output = match tokio::time::timeout(limit, child.wait_with_output()).await {
            Ok(Ok(o)) => o,
            Ok(Err(e)) => return Err(NoVerdict::Failed(format!("waiting for the verifier: {e}"))),
            Err(_) => {
                super::remove_file(&out).await;
                return Err(NoVerdict::Failed(format!(
                    "the verifier ran over {} s and was killed",
                    self.cfg.job_timeout_secs
                )));
            }
        };
        let code = output.status.code();
        let parsed = tokio::fs::read(&out)
            .await
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
        super::remove_file(&out).await;
        let accepted = parsed
            .as_ref()
            .and_then(|v| v.get("accepted"))
            .and_then(Value::as_bool);
        match (code, accepted, parsed) {
            (Some(EXIT_ACCEPTED), Some(true), Some(v)) => Ok((true, v)),
            (Some(EXIT_REJECTED), Some(false), Some(v)) => Ok((false, v)),
            (Some(EXIT_CANNOT), None, Some(v)) if v.get("error").is_some_and(Value::is_string) => {
                Err(NoVerdict::Unverifiable(truncate(
                    v.get("error").and_then(Value::as_str).unwrap_or_default(),
                )))
            }
            (code, _, parsed) => Err(NoVerdict::Failed(format!(
                "no verdict (exit {code:?}, result {}): {}",
                parsed.map_or("missing".to_string(), |v| truncate(&v.to_string())),
                tail(&output.stdout, &output.stderr)
            ))),
        }
    }

    /// The verifier argv with the job's placeholders filled in.
    pub fn command_for(&self, job: &Job, out: &Path) -> Vec<String> {
        let out = out.to_string_lossy();
        self.cfg
            .verifier_command
            .iter()
            .map(|a| {
                a.replace("{replay}", &job.file_path)
                    .replace("{out}", &out)
                    .replace("{run_id}", &job.run_id.to_string())
                    .replace("{seed}", &job.seed)
                    .replace("{mode}", &job.mode)
                    .replace("{build}", &job.build.to_string())
                    .replace("{claimed_score}", &job.claimed_score.to_string())
                    .replace("{claimed_hits}", &job.claimed_hits.to_string())
            })
            .collect()
    }
}

fn truncate(s: &str) -> String {
    if s.len() <= OUTPUT_TAIL_BYTES {
        return s.to_string();
    }
    let mut end = OUTPUT_TAIL_BYTES;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &s[..end])
}

/// The last part of the verifier's output (stderr, then stdout).
fn tail(stdout: &[u8], stderr: &[u8]) -> String {
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(stderr),
        String::from_utf8_lossy(stdout)
    );
    let t = text.trim();
    if t.len() <= OUTPUT_TAIL_BYTES {
        return t.to_string();
    }
    let mut start = t.len() - OUTPUT_TAIL_BYTES;
    while !t.is_char_boundary(start) {
        start += 1;
    }
    format!("…{}", &t[start..])
}

/// Where a job's result goes (tests).
pub fn result_path(cfg: &ReplaysConfig, run_id: i64) -> PathBuf {
    super::work_dir(cfg).join(format!("{run_id}.json"))
}
